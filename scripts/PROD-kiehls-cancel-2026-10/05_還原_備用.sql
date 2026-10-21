-- ============================================================================
--  05 還原（備用；✅ 會改資料）—— 把 02 取消的品項與 02 改過單頭的訂單，還原成 02 之前的樣子
--  契爾氏化妝水（G02596-01）團 GRP-20260910-027
--  日期：2026-10-21　阿寫寫、⛔ 阿審（Codex）審過之前不要貼；平常不用貼，老闆決定撤回 02 才貼
-- ============================================================================
--  ★ 為什麼要有這支：⛔ 02 之後要救這批，只能用這份，不能用後台「復原取消」，也不能用採購單「回復斷貨」
--    ・後台訂單頁「復原取消」鈕：02 整單取消的單頭蓋了斷貨時間 → 鈕根本不顯示
--      （apps/admin/src/components/OrderDetail.tsx:815-819，要單頭沒有斷貨標記才出現）。
--    ・就算直接呼叫 rpc_restore_cancelled_order（最新 20261013000000:1480）：守衛 2（:1516-1520）看到單頭有斷貨標記，
--      一律擋下、叫人「到對應的採購單按『回復斷貨』」，什麼都不改。
--      單子留著、沒整單取消的那幾張：品項有斷貨標記，它也只還沒有斷貨標記的品項（:1587-1599），守衛 6 擋下（:1605-1608）。
--    ・採購單「回復斷貨」rpc_restore_stockout_po（20260812000000）只認 stockout_po_id；02 沒有斷貨單、不寫這一欄 → 接不到。
--      ⇒ 守衛 2 叫人去按的那顆鈕，對這批是無效的；看到那句紅字請改貼這份。
--  ★ 這份在做什麼（整份只有一個 DO 區塊＝同一次；任何一步不對就整筆取消、什麼都沒改）
--    ① 找「最近一次 02」（用 02 寫進編輯歷史的那一句原因認）
--    ② 先檢查（任何寫入之前）：那一次取消的品項現在都還是那一刻的樣子（已取消、斷貨時間＝那一刻、
--       之後沒人改過）；02 整單取消／收尾完成的單也一樣沒人改過；還原後不會跟同一位客人在
--       同一團的其他進行中訂單撞在一起。任何一項不對 → 【停】，什麼都沒改（要改人工處理）。
--    ③ 還原（依 02 寫的編輯歷史裡「改之前」那個值）：
--       ・品項：已取消 → 改之前的狀態（等貨中），斷貨時間清空
--       ・02 整單取消的單：已取消 → 改之前的狀態（已確認／出貨中／可取貨…），取消時間清空，
--         單頭斷貨時間「等於 02 那一刻」的清空（02 之前就有的斷貨時間不動）
--       ・02 收尾成已完成的單：已完成 → 改之前的狀態；完成時間是 02 那一刻蓋的才清空
--       ・每一筆都再寫一列編輯歷史（原因「還原：契爾氏化妝水叫錯款式批次取消（撤回 2026-10-21 那一次）」）；
--         02 寫的那幾列留著（編輯歷史只能新增、不能刪，20260605000001:27-28）
--    ④ 自我驗算
--  ★ 只還原 02 做的：認法是 02 寫的那一句原因＋02 那一刻的時間。松山那筆（老闆 10/21 手動刪除品項、整單一併取消）
--    的編輯歷史原因不同 → 這份不碰它，它維持已取消。
--  ★ 還原不了的（會在結尾那行寫出來）：
--    ・02 第 5 步還回的「從店內庫存配貨」不會自動配回去（同刪除品項的取捨，20260827040000:48-49）；
--      01 第③段預期 0 筆。有的話要店家重新配一次。
--    ・03 發出去的通知收不回來。
--    ・品項／單頭的「最後修改人、修改時間」會變成這次還原的人與時間。
--    ・02 之後如果店家已經把錯貨收進來，還原回「出貨中」的單不會自己變可取貨（貨是在 02 之後收的）。
--  ★ 要填的一行：p_operator（同 02，老闆本人 UUID）；空的會直接【停】。
--  ★ 重貼：已經還原過的會顯示「已經還原過，這次什麼都沒改」。
--  ★ 看到什麼要停：紅字【停】→ 什麼都沒改，截圖給 CEO；⛔ 不要重貼
-- ============================================================================

DO $kiehls_undo$
DECLARE
  -- ╔════════ 要填的一行（CEO 在老闆確認後填）════════╗
  p_operator      uuid := NULL;   -- ⬅ 操作人：01 第⑨段列出、老闆確認過的本人 UUID；⛔ 空的會直接停
  -- ╚════════════════════════════════════════════════╝
  c_campaign_no   CONSTANT text := 'GRP-20260910-027';
  c_sku_code      CONSTANT text := 'G02596-01';
  -- ⛔ 跟 02 逐字相同，不要改字
  c_tag_item      CONSTANT text := '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消';
  c_tag_cancel    CONSTANT text := '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消（這張單沒有其他待取品項，整單取消）';
  c_tag_done      CONSTANT text := '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消（其他品項都取過了，訂單收尾為完成）';
  c_tag_release   CONSTANT text := '契爾氏叫錯款式批次取消';
  c_tag_undo      CONSTANT text := '還原：契爾氏化妝水叫錯款式批次取消（撤回 2026-10-21 那一次）';
  v_now           timestamptz := now();
  v_tenant        uuid;
  v_campaign      bigint;
  v_sku           bigint;
  v_t0            timestamptz;
  v_cnt           int;
  v_marked        int;
  v_bad           int;
  v_items         bigint[];
  v_ord_cancel    bigint[];
  v_ord_done      bigint[];
  v_dup           text;
  v_rel_notes     int;
  v_notified      int;
  n_items         int := 0;
  n_cancel        int := 0;
  n_done          int := 0;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  IF p_operator IS NULL THEN
    RAISE EXCEPTION '【停】操作人 p_operator 是空的。要由 CEO 把老闆確認過的本人 UUID 填進去再貼。什麼都沒改。';
  END IF;

  -- ── 1. 對象 ──
  SELECT count(*) INTO v_cnt FROM public.group_buy_campaigns WHERE campaign_no = c_campaign_no;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】團號 % 在系統裡查到 % 個（要剛好 1 個）。什麼都沒改，請截圖給 CEO。', c_campaign_no, v_cnt;
  END IF;
  SELECT id, tenant_id INTO v_campaign, v_tenant FROM public.group_buy_campaigns WHERE campaign_no = c_campaign_no;
  SELECT count(*) INTO v_cnt FROM public.skus WHERE sku_code = c_sku_code AND tenant_id = v_tenant;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】商品碼 % 在這家公司查到 % 個（要剛好 1 個）。什麼都沒改，請截圖給 CEO。', c_sku_code, v_cnt;
  END IF;
  SELECT id INTO v_sku FROM public.skus WHERE sku_code = c_sku_code AND tenant_id = v_tenant;

  IF NOT EXISTS (SELECT 1 FROM auth.users u
                  WHERE u.id = p_operator
                    AND (u.raw_app_meta_data ->> 'tenant_id') = v_tenant::text
                    AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')) THEN
    RAISE EXCEPTION '【停】操作人 % 不是這家公司的總部帳號（或根本不是登入帳號）。請用 01 第⑨段列出、老闆確認過的本人 UUID。什麼都沒改。', p_operator;
  END IF;

  -- ── 2. 最近一次 02 ──
  SELECT max(a.created_at) INTO v_t0
    FROM public.customer_order_audit_log a
    JOIN public.customer_order_items i ON i.id = a.entity_id
    JOIN public.customer_orders co ON co.id = i.order_id
   WHERE a.entity_type = 'item' AND a.field = 'status' AND a.edit_reason = c_tag_item
     AND co.campaign_id = v_campaign AND i.sku_id = v_sku;
  IF v_t0 IS NULL THEN
    RAISE EXCEPTION '【停】找不到 02 做過的紀錄，沒有東西可以還原。什麼都沒改。';
  END IF;

  -- ── 3. 上鎖：先單頭、再品項（同 02）──
  BEGIN
    PERFORM 1
       FROM public.customer_orders co
      WHERE co.campaign_id = v_campaign
        AND EXISTS (SELECT 1 FROM public.customer_order_items x WHERE x.order_id = co.id AND x.sku_id = v_sku)
      ORDER BY co.id
        FOR UPDATE;
    PERFORM 1
       FROM public.customer_order_items x
      WHERE x.order_id IN (SELECT co.id FROM public.customer_orders co
                            WHERE co.campaign_id = v_campaign
                              AND EXISTS (SELECT 1 FROM public.customer_order_items y
                                           WHERE y.order_id = co.id AND y.sku_id = v_sku))
      ORDER BY x.id
        FOR UPDATE;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION '【停】有人正在操作這幾張訂單，等了 15 秒還拿不到。什麼都沒改，請過幾分鐘再貼一次。';
  END;

  -- ── 4. 那一次 02 取消的品項、改過的單頭 ──
  SELECT count(*) INTO v_marked
    FROM public.customer_order_audit_log a
   WHERE a.entity_type = 'item' AND a.field = 'status' AND a.edit_reason = c_tag_item AND a.created_at = v_t0;

  SELECT array_agg(x.id ORDER BY x.id) INTO v_items
    FROM public.customer_order_items x
   WHERE x.status = 'cancelled' AND x.stockout_at = v_t0
     AND EXISTS (SELECT 1 FROM public.customer_order_audit_log a
                  WHERE a.order_id = x.order_id AND a.entity_type = 'item' AND a.entity_id = x.id
                    AND a.field = 'status' AND a.edit_reason = c_tag_item AND a.created_at = v_t0);
  v_cnt := COALESCE(array_length(v_items, 1), 0);

  IF v_cnt = 0 THEN
    IF EXISTS (SELECT 1 FROM public.customer_order_audit_log a
                WHERE a.edit_reason = c_tag_undo AND a.created_at > v_t0) THEN
      RAISE NOTICE '已經還原過了（02 那一次之後有還原紀錄），這次什麼都沒改。';
      RETURN;
    END IF;
    RAISE EXCEPTION '【停】02 取消的那 % 筆現在都不是那時候的樣子，而且沒有還原紀錄（有人用別的方式動過）。不能自動還原，什麼都沒改，請截圖給 CEO。', v_marked;
  END IF;
  IF v_cnt <> v_marked THEN
    RAISE EXCEPTION '【停】02 那一次取消了 % 筆，現在只剩 % 筆還是那時候的樣子（有人動過）。不能自動還原，什麼都沒改，請截圖給 CEO。', v_marked, v_cnt;
  END IF;

  -- 之後沒人改過：修改時間還是 02 那一刻（任何人改過任何欄位，修改時間都會變，觸發器 20260423120000:329-332）
  SELECT count(*) INTO v_bad FROM public.customer_order_items x WHERE x.id = ANY (v_items) AND x.updated_at <> v_t0;
  IF v_bad > 0 THEN
    RAISE EXCEPTION '【停】02 取消的品項裡有 % 筆在 02 之後又被改過。不能自動還原，什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  SELECT array_agg(a.order_id ORDER BY a.order_id) INTO v_ord_cancel
    FROM public.customer_order_audit_log a
   WHERE a.entity_type = 'order' AND a.field = 'status' AND a.edit_reason = c_tag_cancel AND a.created_at = v_t0;
  SELECT array_agg(a.order_id ORDER BY a.order_id) INTO v_ord_done
    FROM public.customer_order_audit_log a
   WHERE a.entity_type = 'order' AND a.field = 'status' AND a.edit_reason = c_tag_done AND a.created_at = v_t0;

  SELECT count(*) INTO v_bad
    FROM public.customer_orders co
   WHERE co.id = ANY (COALESCE(v_ord_cancel, '{}'::bigint[]))
     AND NOT (co.status = 'cancelled' AND co.cancelled_at = v_t0 AND co.updated_at = v_t0);
  IF v_bad > 0 THEN
    RAISE EXCEPTION '【停】02 整單取消的單裡有 % 張在 02 之後又被改過。不能自動還原，什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;
  SELECT count(*) INTO v_bad
    FROM public.customer_orders co
   WHERE co.id = ANY (COALESCE(v_ord_done, '{}'::bigint[]))
     AND NOT (co.status = 'completed' AND co.updated_at = v_t0);
  IF v_bad > 0 THEN
    RAISE EXCEPTION '【停】02 收尾成已完成的單裡有 % 張在 02 之後又被改過。不能自動還原，什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  -- 還原後會不會跟同一位客人在同一團的其他進行中訂單撞在一起
  -- （條件照 rpc_restore_cancelled_order 守衛 5，20261013000000:1535-1564；唯一索引 20261013000000:253-260）
  SELECT string_agg(COALESCE(st.name, '?') || ' ' || co2.order_no, '、') INTO v_dup
    FROM public.customer_orders co
    JOIN public.customer_orders co2
      ON co2.tenant_id = co.tenant_id AND co2.campaign_id = co.campaign_id
     AND co2.channel_id = co.channel_id AND co2.member_id = co.member_id
     AND co2.order_kind = co.order_kind AND co2.id <> co.id
     AND co2.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND co2.order_no NOT LIKE 'SP-%' AND co2.order_no NOT LIKE 'WS-%'
     AND co2.aid_board_id IS NULL AND co2.transferred_from_order_id IS NULL
    LEFT JOIN public.stores st ON st.id = co2.pickup_store_id
   WHERE co.id = ANY (COALESCE(v_ord_cancel, '{}'::bigint[]))
     AND co.order_kind <> 'restock'
     AND co.order_no NOT LIKE 'SP-%' AND co.order_no NOT LIKE 'WS-%'
     AND co.aid_board_id IS NULL AND co.transferred_from_order_id IS NULL;
  IF v_dup IS NOT NULL THEN
    RAISE EXCEPTION '【停】有客人在同一團已經另外有進行中的訂單（%），還原會變成兩張。不能自動還原，什麼都沒改，請截圖給 CEO。', v_dup;
  END IF;

  -- ════════ 以下開始寫入 ════════
  BEGIN
    -- ── 5. 品項還原（改之前的狀態從 02 的編輯歷史拿）──
    UPDATE public.customer_order_items x
       SET status      = a.before_value #>> '{}',
           stockout_at = NULL,
           updated_by  = p_operator,
           updated_at  = v_now
      FROM public.customer_order_audit_log a
     WHERE x.id = ANY (v_items)
       AND a.order_id = x.order_id AND a.entity_type = 'item' AND a.entity_id = x.id
       AND a.field = 'status' AND a.edit_reason = c_tag_item AND a.created_at = v_t0;
    GET DIAGNOSTICS n_items = ROW_COUNT;
    IF n_items <> v_cnt THEN
      RAISE EXCEPTION '【停】品項只還原到 % 筆（應為 %），整筆取消、什麼都沒改，請截圖給 CEO。', n_items, v_cnt;
    END IF;

    INSERT INTO public.customer_order_audit_log
      (tenant_id, order_id, entity_type, entity_id, field,
       before_value, after_value, edit_reason, operator_id)
    SELECT a.tenant_id, a.order_id, 'item', a.entity_id, 'status',
           to_jsonb('cancelled'::text), a.before_value, c_tag_undo, p_operator
      FROM public.customer_order_audit_log a
     WHERE a.entity_type = 'item' AND a.field = 'status' AND a.edit_reason = c_tag_item AND a.created_at = v_t0
       AND a.entity_id = ANY (v_items);

    -- ── 6. 02 整單取消的單還原 ──
    UPDATE public.customer_orders co
       SET status       = a.before_value #>> '{}',
           cancelled_at = NULL,
           stockout_at  = CASE WHEN co.stockout_at = v_t0 THEN NULL ELSE co.stockout_at END,  -- 只清 02 蓋的
           updated_by   = p_operator,
           updated_at   = v_now
      FROM public.customer_order_audit_log a
     WHERE co.id = ANY (COALESCE(v_ord_cancel, '{}'::bigint[]))
       AND a.order_id = co.id AND a.entity_type = 'order' AND a.field = 'status'
       AND a.edit_reason = c_tag_cancel AND a.created_at = v_t0;
    GET DIAGNOSTICS n_cancel = ROW_COUNT;

    -- ── 7. 02 收尾成已完成的單還原（完成時間是 02 那一刻蓋的才清空：_close_orders_all_items_settled 用 COALESCE 保留舊值 20260808000000:79）──
    UPDATE public.customer_orders co
       SET status       = a.before_value #>> '{}',
           completed_at = CASE WHEN co.completed_at = v_t0 THEN NULL ELSE co.completed_at END,
           updated_by   = p_operator,
           updated_at   = v_now
      FROM public.customer_order_audit_log a
     WHERE co.id = ANY (COALESCE(v_ord_done, '{}'::bigint[]))
       AND a.order_id = co.id AND a.entity_type = 'order' AND a.field = 'status'
       AND a.edit_reason = c_tag_done AND a.created_at = v_t0;
    GET DIAGNOSTICS n_done = ROW_COUNT;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION '【停】還原時撞到「一位客人一團一張進行中訂單」的限制（%）。整筆取消、什麼都沒改，請截圖給 CEO。', SQLERRM;
  END;

  IF n_cancel <> COALESCE(array_length(v_ord_cancel, 1), 0) OR n_done <> COALESCE(array_length(v_ord_done, 1), 0) THEN
    RAISE EXCEPTION '【停】單頭只還原到整單取消 % 張、收尾完成 % 張（應為 %、%），整筆取消、什麼都沒改，請截圖給 CEO。',
      n_cancel, n_done, COALESCE(array_length(v_ord_cancel, 1), 0), COALESCE(array_length(v_ord_done, 1), 0);
  END IF;

  INSERT INTO public.customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  SELECT a.tenant_id, a.order_id, 'order', a.order_id, 'status',
         a.after_value, a.before_value, c_tag_undo, p_operator
    FROM public.customer_order_audit_log a
   WHERE a.entity_type = 'order' AND a.field = 'status' AND a.created_at = v_t0
     AND a.edit_reason IN (c_tag_cancel, c_tag_done);

  -- ── 8. 自我驗算 ──
  SELECT count(*) INTO v_bad
    FROM public.customer_order_items x
    JOIN public.customer_order_audit_log a
      ON a.order_id = x.order_id AND a.entity_type = 'item' AND a.entity_id = x.id
     AND a.field = 'status' AND a.edit_reason = c_tag_item AND a.created_at = v_t0
   WHERE x.id = ANY (v_items)
     AND NOT (x.status = a.before_value #>> '{}' AND x.stockout_at IS NULL);
  IF v_bad > 0 THEN
    RAISE EXCEPTION '【停】自我驗算沒過：有 % 筆品項沒有回到 02 之前的狀態。整筆取消、什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;
  SELECT count(*) INTO v_bad
    FROM public.customer_orders co
    JOIN public.customer_order_audit_log a
      ON a.order_id = co.id AND a.entity_type = 'order' AND a.field = 'status'
     AND a.edit_reason IN (c_tag_cancel, c_tag_done) AND a.created_at = v_t0
   WHERE co.status <> a.before_value #>> '{}'
      OR (a.edit_reason = c_tag_cancel AND co.cancelled_at IS NOT NULL)
      OR co.stockout_at = v_t0;
  IF v_bad > 0 THEN
    RAISE EXCEPTION '【停】自我驗算沒過：有 % 張單頭沒有回到 02 之前的狀態。整筆取消、什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;
  SELECT count(*) INTO v_cnt
    FROM public.customer_order_audit_log a
   WHERE a.edit_reason = c_tag_undo AND a.created_at = v_now;
  IF v_cnt <> n_items + n_cancel + n_done THEN
    RAISE EXCEPTION '【停】自我驗算沒過：還原的編輯歷史有 % 列（應為 %）。整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt, n_items + n_cancel + n_done;
  END IF;

  -- 還原不了的，算出來寫在結尾
  SELECT count(*) INTO v_rel_notes
    FROM public.inventory_deduction_notes nn
   WHERE position(c_tag_release IN COALESCE(nn.reason, '')) > 0;
  SELECT count(*) INTO v_notified
    FROM public.notifications n
   WHERE n.tenant_id = v_tenant AND n.category = 'stockout' AND n.title = '商品斷貨通知'
     AND n.created_at >= v_t0
     AND n.body LIKE '%因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。'
     AND n.member_id IN (SELECT co.member_id FROM public.customer_order_items x
                           JOIN public.customer_orders co ON co.id = x.order_id
                          WHERE x.id = ANY (v_items) AND co.member_id IS NOT NULL);

  RAISE NOTICE '✅ 還原完成：品項 % 筆回到 02 之前；整單取消的單 % 張、收尾完成的單 % 張回到 02 之前的狀態。還原不了的：02 還回的店內庫存配貨 % 張減抵單（要店家重新配）、03 發出去的通知 % 則（收不回來）。',
    n_items, n_cancel, n_done, v_rel_notes, v_notified;
END $kiehls_undo$;

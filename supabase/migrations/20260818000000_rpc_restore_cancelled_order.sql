-- ============================================================
-- rpc_restore_cancelled_order — 取消的顧客訂單「復原取消」
--
-- 需求：店員誤按取消、或客人取消後又反悔，目前**沒有任何路徑**可以把單救回來。
--   全 DB 唯一會把 customer_orders.status 從 'cancelled' 改回去的是
--   rpc_restore_stockout_po（20260812000000），而它只認 stockout_at IS NOT NULL
--   的列 —— 手動取消的單 stockout_at 是 NULL，完全在它的還原範圍外。
--   前端 /orders 的「已取消」那顆鈕是 disabled 的死胡同。
--
-- ── 為什麼「還原單頭」就幾乎等於還原整張單 ──
--   rpc_cancel_aid_order（最新 20260816000070）**只動單頭**，一列品項都沒碰：
--   品項留在 pending。而所有下游口徑（開團名額 / _sku_commitment 的 promised /
--   撿貨需求）都同時濾 co.status 與 coi.status，所以單頭一變 cancelled 名額與
--   可分配量就自動放回去，變回 pending/confirmed 也自動回來 —— 不需要、也不可以
--   自己去補寫庫存異動（配單當下本來就沒扣庫存，rpc_record_pickup 才扣）。
--
--   唯一的例外是 rpc_delete_order_item（20260707000040）：它先把品項標
--   cancelled，刪到最後一列才把單頭 cancelled。這種單直接還原單頭會得到
--   「活著但一件品項都沒有」的空殼單，所以本函式要一併還原那幾列 —— 見下。
--
-- ── 品項還原範圍：兩道限制夾住，缺一就會生出幽靈品項 ──
--   (a) 只在「一件 active 品項都不剩」時才還原。還有 active 品項就完全不碰
--       cancelled 列 —— 部分轉出（rpc_transfer_order_partial）也把搬走的來源列標成
--       cancelled，貨已經在別人的單上，復活等於憑空生貨。
--   (b) 只還 `updated_at` 與單頭 `cancelled_at` **逐字相等**的列。兩者在同一個交易
--       裡都是 NOW()（＝交易時間戳，trg_touch_coi 也是 NOW()），相等 ⇔ 同一個交易被
--       取消，剛好就是 rpc_delete_order_item 刪掉最後一項的那一列。刻意不用「相差
--       幾秒內」的區間：那會把取消前一兩秒被搬走 / 被手動刪掉的列一起撈進來。
--   stockout_at IS NOT NULL 的列一律不還（那是斷貨，歸採購單的回復斷貨管）。
--
-- ── 守衛（擋下來比做半套好，對齊 rpc_restore_stockout_po 的取捨）──
--   1. 非 cancelled → 擋。'expired' 不在範圍（逾期是另一條線，沒有 expired_at
--      可判、也沒有對應的取消動作可逆）。
--   2. stockout_at IS NOT NULL（斷貨取消）→ 擋，指去採購單按「回復斷貨」。
--      單獨復原會讓 stockout_po_id 的連動、campaign_items、補貨鏈全部對不上。
--   3. transferred_from_order_id IS NOT NULL（互助 / 轉給別人的轉入單）→ 擋。
--      取消時 rpc_cancel_aid_order 已經把來源單從 transferred_out 退回
--      confirmed/ready，貨在來源單上；再把轉入單救活 = 兩張單掛同一批貨，
--      正是 CLAUDE.md 反覆記載的「幽靈品項」。正解是回來源單重新轉一次。
--   4. SP-（現貨直配）→ 擋。那條路的取消語意是「把貨退回可分配」，要再配就重開
--      一張（rpc_create_spot_sale 會重新驗現在還有幾件可配）；而且它靠 DN 減抵單
--      過取貨閘門 Path D，DN 的覆蓋在取消時已被 trigger 永久釋放（見下），
--      硬救回來會是一張過不了閘門的死單。
--   5. customer_orders_trio_kind_active_uniq（最新 20260816000060）：
--      同 (tenant, campaign, channel, member, order_kind) 只能有一張 active 單，
--      cancelled 不佔 slot。客人取消後重新下單是最常見的情境 —— 直接 UPDATE 會
--      撞唯一索引噴英文 duplicate key，所以先自己查一次、報單號給店員看。
--      比對用 `=`（不是 IS NOT DISTINCT FROM）刻意對齊索引語意：任一欄 NULL
--      在唯一索引裡就不算衝突。
--   6. 還原後仍然沒有任何 active/picked_up 品項 → 擋（空殼單救回來沒有意義）。
--
-- ── 復原後的狀態怎麼決定 ──
--   照 rpc_restore_stockout_po:653-677 的同一套規則，不另外發明：
--     有 picked_up ＋ 還有待取     → partially_completed
--     有 picked_up ＋ 沒有待取     → completed
--     confirmed_at IS NOT NULL     → confirmed（被 PR 鎖定過）
--     否則                          → pending
--   接著 confirmed 再過一次 is_order_pickup_ready → ready，這一段與
--   rpc_cancel_aid_order:203-212 的來源單還原逐字同一套（波次早跑完的話
--   confirmed 再也不會被 mark_shipping 推進，會永遠卡住）。
--   刻意**不**開放 pending → ready：沒確認過的單不該直接跳可取貨。
--   從 shipping 取消的單只能回到 confirmed：取消時 transfer chain 已經被反向
--   回收（貨回到轉出端），要重新派一次，所以連 shipping_at 一起清掉
--   （清時間戳讓 status 一致的作法對齊 20260814020010:76-95）。
--
-- ── 兩件「不還原」，是刻意的 ──
--   a) 庫存減抵單（inventory_deduction_notes）的覆蓋：訂單進 cancelled 時
--      trg_release_idn_coverage（20260813002000）已經永久釋放，該檔檔頭
--      :31-33 明載「訂單事後被回復不會自動長回覆蓋 —— 保守方向（寧可誠實顯示
--      未到貨，不可憑空放行），需要時店家重開減抵單即可」。本函式照辦。
--   b) 開團名額上限：名額是即時算的（campaign_items 沒有實體已售欄位），復原
--      會重新吃掉名額，理論上可能超過 cap_qty。不擋 —— 擋下去等於逼店員先去改
--      團設定才救得回單，而超額在快速開團控制頁看得到，交給人判斷。
--
-- ── 儲值金 ──
--   取消時 rpc_cancel_aid_order 用 rpc_wallet_refund 把 wallet_paid_amount 退回
--   會員餘額（wallet_paid_amount 保留歷史值不清零），所以復原要對稱地用
--   rpc_wallet_spend 扣回去。餘額不夠時它自己 RAISE（rpcError.ts 已有中文翻譯），
--   整個交易 rollback —— 這正是我們要的：不能讓單復活卻沒收到錢。
--   ⚠ 不可以拿 payment_status 判斷收過錢沒（CLAUDE.md：全站恆為 'unpaid'）。
--
-- ── 通知 ──
--   不發。手動取消本來就不發通知（全 repo 只有斷貨鏈那 6 個 notifications
--   寫入點），rpc_restore_stockout_po 會發是因為「先前發過斷貨取消通知」。
--   這裡沒發過取消通知，補一則「您的訂單已恢復」反而讓客人一頭霧水。
--
-- 基底版本（每支都重新 grep 確認，不信文件）：
--   _check_order_edit_qty_perm = 20260629000010（唯一版本）
--   is_order_pickup_ready      = 20260704000000（最新）
--   rpc_wallet_spend           = 20260422120002（唯一版本）
--   rpc_cancel_aid_order       = 20260816000070（最新，本函式的鏡像對象，不修改）
--   customer_order_audit_log   = 20260605000001；field CHECK 含 'status' 見 20260625000000
--   customer_orders_trio_kind_active_uniq = 20260816000060（最新）
--   rpc_restore_cancelled_order 為新增
--
-- rollback:
--   DROP FUNCTION IF EXISTS public.rpc_restore_cancelled_order(BIGINT, UUID, TEXT);
--   （已復原的單不自動回滾；customer_order_audit_log 有留 field='status'
--     cancelled → X 的紀錄可對照人工改回，儲值金看 wallet_ledger 的 spend）
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_restore_cancelled_order(
  p_order_id BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order        customer_orders%ROWTYPE;
  v_src          customer_orders%ROWTYPE;
  v_item_ids     BIGINT[] := ARRAY[]::BIGINT[];
  v_items        INTEGER  := 0;
  v_has_picked   BOOLEAN  := FALSE;
  v_has_active   BOOLEAN  := FALSE;
  v_new_status   TEXT;
  v_pickable     BOOLEAN  := FALSE;
  v_dup_no       TEXT;
  v_wallet       NUMERIC  := 0;
  v_wallet_id    BIGINT;
  v_redispatch   BOOLEAN  := FALSE;
BEGIN
  -- 與 rpc_cancel_aid_order 同一把鎖：不能一邊取消一邊復原
  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  -- 權限 + tenant 隔離 + FOR UPDATE（HQ tier 全部 / 店長限 app_metadata.stores
  -- 含本單 pickup_store；與改數量 / 刪品項同一道閘）
  v_order := public._check_order_edit_qty_perm(p_order_id);

  -- ── 守衛 1：只復原「已取消」 ──
  IF v_order.status <> 'cancelled' THEN
    RAISE EXCEPTION '訂單 % 目前是「%」，不是已取消的單，沒有東西可以復原',
      v_order.order_no, v_order.status;
  END IF;

  -- ── 守衛 2：斷貨取消歸採購單管 ──
  IF v_order.stockout_at IS NOT NULL THEN
    RAISE EXCEPTION '訂單 % 是供應商斷貨造成的取消，請到對應的採購單按「回復斷貨」一併還原；單獨復原這張單會讓採購 / 開團商品 / 補貨鏈的連動對不上',
      v_order.order_no;
  END IF;

  -- ── 守衛 3：轉入單（互助 / 轉給別人）──
  IF v_order.transferred_from_order_id IS NOT NULL THEN
    SELECT * INTO v_src FROM customer_orders WHERE id = v_order.transferred_from_order_id;
    RAISE EXCEPTION '訂單 % 是轉入單，取消時貨已經還給來源單 %（目前「%」）。請直接到來源單重新轉一次，復原這張會變成兩張單掛著同一批貨',
      v_order.order_no, COALESCE(v_src.order_no, '?'), COALESCE(v_src.status, '?');
  END IF;

  -- ── 守衛 4：現貨直配 ──
  IF v_order.order_no LIKE 'SP-%' THEN
    RAISE EXCEPTION '現貨直配單 % 的取消就是「把貨退回可分配」，沒有復原這個動作：請重新建立一張現貨直配單（會重新檢查現在還有幾件可以配）',
      v_order.order_no;
  END IF;

  -- ── 守衛 5：一會員一活動一張 active 單 ──
  -- 條件逐欄對齊 customer_orders_trio_kind_active_uniq 的 key 與 predicate。
  -- 用 `=` 而非 IS NOT DISTINCT FROM：唯一索引把 NULL 當互不相同，任一欄 NULL
  -- 本來就不會衝突，這裡跟著回 NULL → 不誤擋。
  IF v_order.campaign_id IS NOT NULL
     AND v_order.order_kind IS NOT NULL
     AND v_order.order_kind <> 'restock' THEN
    SELECT co.order_no INTO v_dup_no
      FROM customer_orders co
     WHERE co.tenant_id   = v_order.tenant_id
       AND co.campaign_id = v_order.campaign_id
       AND co.channel_id  = v_order.channel_id
       AND co.member_id   = v_order.member_id
       AND co.order_kind  = v_order.order_kind
       AND co.id <> p_order_id
       AND co.status NOT IN ('transferred_out', 'expired', 'cancelled')
       AND co.order_no NOT LIKE 'SP-%'
     ORDER BY co.id
     LIMIT 1;

    IF v_dup_no IS NOT NULL THEN
      RAISE EXCEPTION '這位客人在同一檔團已經有一張進行中的訂單 %，同一檔團一位客人只能有一張單。請改在那張單上加品項，不要復原這張',
        v_dup_no;
    END IF;
  END IF;

  -- ── 品項還原 ──
  -- active 集合與 rpc_record_pickup 的 v_active_remaining、
  -- _close_orders_all_items_settled 同一套，不另外定義。
  SELECT EXISTS (SELECT 1 FROM customer_order_items x
                  WHERE x.order_id = p_order_id AND x.status = 'picked_up'),
         EXISTS (SELECT 1 FROM customer_order_items x
                  WHERE x.order_id = p_order_id
                    AND x.status IN ('pending', 'reserved', 'ready'))
    INTO v_has_picked, v_has_active;

  -- 只有「一件 active 品項都不剩」才需要還原品項 —— 那就是
  -- rpc_delete_order_item 刪到最後一項連帶取消整單的空殼單。
  -- 兩道限制缺一不可：
  --   (a) 還有 active 品項就完全不碰 cancelled 列。部分轉出（rpc_transfer_order_partial）
  --       把搬走的來源列標成 cancelled，貨已經在別人的單上，復活就是憑空生貨
  --       （CLAUDE.md 反覆記載的幽靈品項）。
  --   (b) updated_at 與單頭 cancelled_at **逐字相等**才還。兩者在同一個交易裡都是
  --       NOW()（＝交易時間戳，trg_touch_coi 也是 NOW()），所以相等 ⇔ 同一個交易被
  --       取消。刻意不用「相差幾秒內」的區間：那會把剛好在取消前一兩秒被搬走或被
  --       手動刪掉的列一起撈進來。
  --   斷貨列（stockout_at IS NOT NULL）一律不還，那歸採購單的回復斷貨管。
  IF NOT v_has_active AND v_order.cancelled_at IS NOT NULL THEN
    WITH upd AS (
      UPDATE customer_order_items coi
         SET status     = 'pending',
             updated_by = p_operator,
             updated_at = NOW()
       WHERE coi.order_id = p_order_id
         AND coi.status = 'cancelled'
         AND coi.stockout_at IS NULL
         AND coi.updated_at = v_order.cancelled_at
       RETURNING coi.id
    )
    SELECT COALESCE(ARRAY_AGG(id), ARRAY[]::BIGINT[]) INTO v_item_ids FROM upd;

    v_has_active := COALESCE(array_length(v_item_ids, 1), 0) > 0;
  END IF;
  v_items := COALESCE(array_length(v_item_ids, 1), 0);

  -- ── 守衛 6：救回來要有東西 ──
  IF NOT v_has_picked AND NOT v_has_active THEN
    RAISE EXCEPTION '訂單 % 沒有任何可以復原的品項（品項都已取消或斷貨），請改開一張新單',
      v_order.order_no;
  END IF;

  -- ── 儲值金：取消時退了多少就扣回多少（餘額不足會在這裡 RAISE 並整筆 rollback）──
  IF COALESCE(v_order.wallet_paid_amount, 0) > 0 AND v_order.member_id IS NOT NULL THEN
    v_wallet_id := rpc_wallet_spend(
      v_order.tenant_id,
      v_order.member_id,
      v_order.wallet_paid_amount,
      'customer_order',
      p_order_id,
      p_operator
    );
    v_wallet := v_order.wallet_paid_amount;
  END IF;

  -- ── 單頭狀態重算（規則同 rpc_restore_stockout_po:653-677）──
  IF v_has_picked AND v_has_active THEN
    v_new_status := 'partially_completed';
  ELSIF v_has_picked THEN
    v_new_status := 'completed';
  ELSIF v_order.confirmed_at IS NOT NULL THEN
    v_new_status := 'confirmed';
  ELSE
    v_new_status := 'pending';
  END IF;

  -- 派貨中被取消的單：transfer chain 已經反向回收，貨回到轉出端 → 要重新派。
  -- 回傳這個旗標讓前端把「需要重新派貨」講出來，不然店員會以為貨還在路上。
  v_redispatch := EXISTS (
    SELECT 1 FROM transfers t
     WHERE t.customer_order_id = p_order_id
       AND t.tenant_id = v_order.tenant_id
       AND t.status = 'cancelled'
  );

  UPDATE customer_orders
     SET status       = v_new_status,
         cancelled_at = NULL,
         -- 回到未出貨狀態就把出貨/到貨時間戳清掉，讓 status 與時間戳一致
         -- （對齊 20260814020010 的作法）；下面若過了取貨閘門會再補 ready_at。
         shipping_at  = CASE WHEN v_new_status IN ('pending', 'confirmed')
                             THEN NULL ELSE shipping_at END,
         ready_at     = CASE WHEN v_new_status IN ('pending', 'confirmed')
                             THEN NULL ELSE ready_at END,
         completed_at = CASE WHEN v_new_status = 'completed'
                             THEN COALESCE(completed_at, NOW()) ELSE NULL END,
         updated_by   = p_operator,
         updated_at   = NOW()
   WHERE id = p_order_id;

  -- 貨其實已經到店了就直接推 ready（同 rpc_cancel_aid_order 還原來源單那一段）：
  -- 波次早就跑完的話 confirmed 不會再被 mark_shipping 推進，會永遠卡住。
  IF v_new_status = 'confirmed' THEN
    v_pickable := public.is_order_pickup_ready(p_order_id);
    IF v_pickable THEN
      UPDATE customer_orders
         SET status     = 'ready',
             ready_at   = COALESCE(ready_at, NOW()),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = p_order_id
         AND status = 'confirmed';
      v_new_status := 'ready';
    END IF;
  END IF;

  -- ── 稽核 ──
  IF v_items > 0 THEN
    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    )
    SELECT v_order.tenant_id, p_order_id, 'item', x, 'status',
           to_jsonb('cancelled'::TEXT), to_jsonb('pending'::TEXT),
           format('復原取消訂單時一併還原%s',
                  COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
           p_operator
      FROM unnest(v_item_ids) AS x;
  END IF;

  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_order.tenant_id, p_order_id, 'order', p_order_id, 'status',
    to_jsonb('cancelled'::TEXT), to_jsonb(v_new_status),
    format('復原取消（還原品項 %s 項%s%s）%s',
           v_items,
           CASE WHEN v_wallet > 0
                THEN format('、重扣儲值金 %s', trim_scale(v_wallet)::TEXT) ELSE '' END,
           CASE WHEN v_redispatch THEN '、原派貨已回收需重派' ELSE '' END,
           COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
    p_operator
  );

  RETURN jsonb_build_object(
    'order_id',         p_order_id,
    'order_no',         v_order.order_no,
    'status',           v_new_status,
    'items_restored',   v_items,
    'pickup_ready',     v_pickable,
    'needs_redispatch', v_redispatch,
    'wallet_recharged', v_wallet,
    'wallet_ledger_id', v_wallet_id,
    -- 減抵單覆蓋刻意不還原（trg_release_idn_coverage 的釋放是不可逆的），
    -- 前端要提醒店家「需要的話請重開減抵單」
    'idn_coverage_restored', FALSE
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_restore_cancelled_order(BIGINT, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_restore_cancelled_order(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_restore_cancelled_order(BIGINT, UUID, TEXT) IS
  '復原取消的顧客訂單（rpc_cancel_aid_order 的反向）：單頭 cancelled → '
  '取消前的狀態（有 picked_up → partially_completed/completed；confirmed_at 有值 → '
  'confirmed，否則 pending；confirmed 再過 is_order_pickup_ready → ready），'
  '清 cancelled_at 與已失效的出貨時間戳，一併還原「與單頭同一交易被取消」的品項，'
  '並把取消時退掉的儲值金重新扣回。'
  '守衛：非 cancelled / 斷貨取消（走採購單回復斷貨）/ 轉入單（回來源單重轉）/ '
  '現貨直配（重開一張）/ 同團同會員已有 active 單 / 沒有可復原的品項 → 一律擋下。'
  '刻意不還原庫存減抵單覆蓋（20260813002000 的釋放不可逆）、不發通知（取消時本來就沒發）。';

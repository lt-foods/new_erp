-- ============================================================================
--  05 還原（備用；✅ 會改資料）—— 撤回 02：把 02 取消的單，逐張用後台「復原取消」鈕那一支救回來
--  限量團超賣三團（洗面乳 024／辣椒醬 048／微燻李 018）
--  日期：2026-10-28　阿寫寫、⛔ 阿審（Codex）審過之前不要貼；平常不用貼，老闆決定撤回 02 才貼
-- ============================================================================
--  ★ 用的是現成的「復原取消」：rpc_restore_cancelled_order（最新 20261013000000:1480；
--    後台 apps/admin/src/app/(protected)/orders/page.tsx:835-849、OrderDetail.tsx 的「復原取消」鈕呼叫的就是它）。
--    它自己會：單頭回到取消前（有確認時間→已確認，沒有→待確認；貨已到店→直接可取貨 :1624-1673）、
--    清取消時間、儲值金「取消時退多少就扣回多少」（餘額不夠會紅字、整筆不做 :1611-1622）、寫編輯歷史（:1675-1700）。
--    ⚠ 它有權限檢查 _check_order_edit_qty_perm（20260629000010:18，讀登入者的 JWT：tenant_id、app_metadata.role）。
--      SQL Editor 沒有登入者 → 這份在同一個交易裡把「操作人」的身分放進 request.jwt.claims（只在這次有效，
--      寫法同 repo 測試 scripts/rpc-tests.sql 等），角色照 auth.users 裡那個帳號自己的 app_metadata.role。
--  ★ 只還原「最近一次 02」取消的單（用 02 寫進編輯歷史的那一句原因＋那一刻的時間認），而且那張單 02 之後沒人再動過
--    （單頭還是已取消、取消時間＝修改時間＝02 那一刻）。有人動過 → 【停】、什麼都不改，改人工處理。
--  ★ ⛔ 不還原 TF0001 與 0040（辣椒醬那一對）：
--    ・TF0001 是轉入單，復原取消的守衛 3 一律擋（:1522-1527）。
--    ・只救 0040 的話，貨會回到 0040 原本的客人、原本的店，而不是 TF0001 經國店那位 → 跟 02 之前不一樣。
--    ⇒ 這一對要撤回請人工：後台對 0040 按「復原取消」，再重新「轉給別人」到經國店。結尾那行也會寫。
--  ★ 只認名單：02 那 73 張＋0040 的單號（跟 02 第 1 步逐字相同），而且編輯歷史是「→ 已取消」、這家公司；名單外一律不碰。
--  ★ 還原後還要人工的（結尾那行會明列，不會寫「完成」）：
--    ・復原取消回傳「要重新派貨」（needs_redispatch）的單（02 只取消待確認／已確認，預期 0 張）。
--    ・互助板帶來的單：取消時量已還回互助貼文（20260826000010:85-110），復原取消不會再扣回。
--  ★ 會停下來的情況（都是什麼都不改）：
--    ・同一位客人在同一團已經有另一張進行中的單（守衛 5 :1535-1564）—— 例如老闆已經幫 0006 古華、0018 忠順補了 1 件
--      （補的時候會開一張新單），那兩張就救不回來；這份會先列出撞到的單號再停。
--    ・儲值金餘額不夠扣回。
--  ★ 還原不了的：取消時被觸發器釋放的庫存減抵單覆蓋（trg_release_idn_coverage）不會自己長回來（取消鈕本來就這樣）；
--    02 寫的編輯歷史留著（只能新增、不能刪）。
-- ============================================================================

DO $oversell_undo$
DECLARE
  -- ╔════════ 要填的一行（CEO 在老闆確認後填，跟 02 同一個人）════════╗
  p_operator      uuid := NULL;   -- ⬅ 操作人 UUID；⛔ 空的會直接停
  -- ╚═══════════════════════════════════════════════════════════╝
  c_tag           CONSTANT text := '限量超賣：2026-10-28 老闆核准批次取消';
  c_tag_undo      CONSTANT text := '還原：限量超賣批次取消（撤回 2026-10-28 那一次）';
  c_skip_nos      CONSTANT text[] := ARRAY['GRP-20261016-048-TF0001', 'GRP-20261016-048-0040'];
  v_tenant        uuid;
  v_role          text;
  v_camp_ids      bigint[];
  v_t0            timestamptz;
  v_ids           bigint[];
  v_allow_nos     text[];     -- 02 那 73 張＋0040 的名單（只還原名單內的）
  v_redispatch    text := '';
  v_aid           text;
  v_cnt           int;
  v_bad           text;
  v_ret           jsonb;
  n_done          int := 0;
  v_wallet        numeric := 0;
  r               record;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  IF p_operator IS NULL THEN
    RAISE EXCEPTION '【停】操作人 p_operator 是空的。什麼都沒改。';
  END IF;

  SELECT array_agg(id ORDER BY id), count(DISTINCT tenant_id), min(tenant_id::text)::uuid INTO v_camp_ids, v_cnt, v_tenant
    FROM public.group_buy_campaigns
   WHERE campaign_no IN ('GRP-20261015-024', 'GRP-20261016-048', 'GRP-20261021-018');
  IF cardinality(v_camp_ids) IS DISTINCT FROM 3 OR v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】三個團查到的不對（要 3 個、同一家公司）。什麼都沒改，請截圖給 CEO。';
  END IF;

  SELECT COALESCE(u.raw_app_meta_data ->> 'role', '') INTO v_role
    FROM auth.users u
   WHERE u.id = p_operator AND (u.raw_app_meta_data ->> 'tenant_id') = v_tenant::text
     AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant');
  IF NOT FOUND THEN
    RAISE EXCEPTION '【停】操作人 % 不是這家公司的總部帳號。什麼都沒改。', p_operator;
  END IF;

  -- 最近一次 02
  SELECT max(a.created_at) INTO v_t0
    FROM public.customer_order_audit_log a JOIN public.customer_orders co ON co.id = a.order_id
   WHERE a.edit_reason = c_tag AND a.entity_type = 'order' AND a.field = 'status' AND co.campaign_id = ANY (v_camp_ids);
  IF v_t0 IS NULL THEN
    RAISE EXCEPTION '【停】找不到 02 的紀錄（02 沒貼過？）。什麼都沒改。';
  END IF;

  -- 02 的名單（跟 02 第 1 步逐字相同）
  v_allow_nos :=
       ARRAY(SELECT 'GRP-20261015-024-' || lpad(n::text, 4, '0') FROM generate_series(6, 46) n)
    || ARRAY['GRP-20261015-024-INT0047']
    || ARRAY(SELECT 'GRP-20261016-048-' || lpad(n::text, 4, '0') FROM generate_series(27, 43) n WHERE n <> 40)
    || ARRAY['GRP-20261016-048-TF0001', 'GRP-20261016-048-0040']
    || ARRAY(SELECT 'GRP-20261021-018-' || lpad(n::text, 4, '0') FROM generate_series(18, 31) n);

  -- 02 那一次取消的單：名單內、編輯歷史是「→ cancelled」、這家公司（不含 TF0001／0040）
  SELECT array_agg(co.id ORDER BY co.order_no) INTO v_ids
    FROM public.customer_order_audit_log a JOIN public.customer_orders co ON co.id = a.order_id
   WHERE a.edit_reason = c_tag AND a.entity_type = 'order' AND a.field = 'status' AND a.created_at = v_t0
     AND a.after_value = to_jsonb('cancelled'::text) AND a.tenant_id = v_tenant AND a.entity_id = co.id
     AND co.campaign_id = ANY (v_camp_ids) AND co.tenant_id = v_tenant
     AND co.order_no = ANY (v_allow_nos) AND co.order_no <> ALL (c_skip_nos);
  IF v_ids IS NULL THEN
    RAISE EXCEPTION '【停】02 那一次沒有可以還原的單。什麼都沒改。';
  END IF;

  -- 鎖
  BEGIN
    PERFORM 1 FROM public.customer_orders WHERE id = ANY (v_ids) ORDER BY id FOR UPDATE;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION '【停】有人正在操作這幾張訂單，等了 15 秒還拿不到。什麼都沒改，請過幾分鐘再貼一次。';
  END;

  -- 重貼：全部都不是已取消了 → 已經還原過
  IF NOT EXISTS (SELECT 1 FROM public.customer_orders WHERE id = ANY (v_ids) AND status = 'cancelled') THEN
    RAISE NOTICE '已經還原過（02 那一次的 % 張都不是已取消了），這次什麼都沒改。', cardinality(v_ids);
    RETURN;
  END IF;

  -- 02 之後沒人動過：還是已取消、取消時間＝修改時間＝02 那一刻
  SELECT string_agg(co.order_no || '＝' || co.status, '、') INTO v_bad
    FROM public.customer_orders co
   WHERE co.id = ANY (v_ids)
     AND NOT (co.status = 'cancelled' AND co.cancelled_at = v_t0 AND co.updated_at = v_t0);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】這幾張在 02 之後被動過（或已經救回一部分）：%。什麼都沒改，改人工處理，請截圖給 CEO。', v_bad;
  END IF;

  -- 守衛 5 先查（條件照 rpc_restore_cancelled_order :1541-1558），一次列出全部撞到的
  SELECT string_agg(o.order_no || '（撞 ' || d.order_no || '）', '、') INTO v_bad
    FROM public.customer_orders o
    JOIN public.customer_orders d
      ON d.tenant_id = o.tenant_id AND d.campaign_id = o.campaign_id AND d.channel_id = o.channel_id
     AND d.member_id = o.member_id AND d.order_kind = o.order_kind AND d.id <> o.id
     AND d.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND d.order_no NOT LIKE 'SP-%' AND d.order_no NOT LIKE 'WS-%'
     AND d.aid_board_id IS NULL AND d.transferred_from_order_id IS NULL
   WHERE o.id = ANY (v_ids) AND o.order_kind IS NOT NULL AND o.order_kind <> 'restock';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】這幾張救回來會跟同一位客人在同一團的進行中訂單撞在一起（一人一團一張）：%。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  -- 用操作人的身分（只在這個交易裡有效）
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', p_operator, 'role', 'authenticated', 'tenant_id', v_tenant,
                       'app_metadata', jsonb_build_object('tenant_id', v_tenant, 'role', v_role))::text, true);

  FOR r IN SELECT co.id, co.order_no FROM public.customer_orders co WHERE co.id = ANY (v_ids) ORDER BY co.order_no LOOP
    v_ret := public.rpc_restore_cancelled_order(r.id, p_operator, c_tag_undo);
    n_done := n_done + 1;
    v_wallet := v_wallet + COALESCE((v_ret ->> 'wallet_recharged')::numeric, 0);
    IF COALESCE((v_ret ->> 'needs_redispatch')::boolean, FALSE) THEN
      v_redispatch := v_redispatch || CASE WHEN v_redispatch = '' THEN '' ELSE '、' END || r.order_no;
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claims', '', true);

  -- 自我驗算
  SELECT string_agg(co.order_no || '＝' || co.status, '、') INTO v_bad
    FROM public.customer_orders co
   WHERE co.id = ANY (v_ids) AND co.status IN ('cancelled', 'expired', 'transferred_out');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】驗算不過：這幾張沒有救回來：%。整筆取消、什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  -- 互助板帶來的單：取消時量已還回互助貼文（20260826000010:85-110），復原取消不會再扣回 → 要人工
  SELECT string_agg(DISTINCT co.order_no, '、') INTO v_aid
    FROM public.customer_orders co
   WHERE co.id = ANY (v_ids)
     AND (co.aid_board_id IS NOT NULL
          OR EXISTS (SELECT 1 FROM public.customer_order_transfer_links l WHERE l.dest_order_id = co.id AND l.aid_board_id IS NOT NULL));

  IF v_redispatch <> '' OR v_aid IS NOT NULL THEN
    RAISE NOTICE '⚠ 還原了 % 張，但「沒有完全回到 02 之前」，還有人工要做：% %（辣椒醬 TF0001／0040 這一對也沒有還原：0040 按「復原取消」後重新轉單到經國店）。用過儲值金的已重新扣回 % 元。請截圖給 CEO。',
      n_done,
      CASE WHEN v_redispatch <> '' THEN '【要重新派貨】' || v_redispatch || '；' ELSE '' END,
      CASE WHEN v_aid IS NOT NULL THEN '【互助貼文的量要人工扣回】' || v_aid || '；' ELSE '' END,
      trim_scale(v_wallet);
  ELSE
    RAISE NOTICE '完成：還原 % 張。⚠ 辣椒醬 TF0001／0040 這一對沒有還原（要人工：0040 按「復原取消」後重新轉單到經國店）。用過儲值金的已重新扣回 % 元。請貼 04 看最後一段。',
      n_done, trim_scale(v_wallet);
  END IF;
END
$oversell_undo$;

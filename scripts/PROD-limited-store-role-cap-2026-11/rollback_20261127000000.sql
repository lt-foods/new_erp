-- ============================================================================
-- rollback_20261127000000.sql —— 整個還原 20261127000000_limited_campaign_store_role_cap.sql
--
-- ✅ 會改正式系統。由老闆本人貼進 Supabase SQL Editor（整份一個交易）。
-- 順序：
--   0. 前置檢查：三支線上必須是 20261127000000 版或基底版（別人改過就停下）；
--   1. rpc_create_store_internal_order 逐字還原成 20261013000000_transfer_always_new_order.sql:2228 那版；
--   2. rpc_update_order_item_qty 逐字還原成 20260629000010_rpc_order_qty_store_manager.sql:84 那版；
--   3. rpc_restore_cancelled_order 逐字還原成 20261013000000_transfer_always_new_order.sql:1480 那版；
--   4. DROP _caller_is_store_role、_campaign_is_limited。
--   權限：CREATE OR REPLACE 保留原本的 GRANT／REVOKE，不動。
-- 前端不用跟著退（前端只多一行提示，不呼叫新函式）。
-- 可重貼：CREATE OR REPLACE ＋ DROP ... IF EXISTS。
-- 還原後 md5 應回到：879557850032331e9475268f5a03cffd／7b1f474beb80d2b5ae0b70f586d25cb7／7c9c1801252437301f2ba226b54546ad
-- ============================================================================

DO $precheck$
DECLARE
  v_bad  TEXT[] := ARRAY[]::TEXT[];
  v_rec  RECORD;
  v_oid  REGPROCEDURE;
  v_md5  TEXT;
BEGIN
  -- 資料庫版本：錯誤訊息用的 trim_scale 要 PostgreSQL 13 以上
  IF current_setting('server_version_num')::int < 130000 THEN
    v_bad := v_bad || format('資料庫版本 %s 太舊（要 PostgreSQL 13 以上，trim_scale 才有）',
                             current_setting('server_version'));
  END IF;

  -- 要用到的欄位
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'group_buy_campaigns' AND column_name = 'total_cap_qty';
  IF NOT FOUND THEN v_bad := v_bad || '找不到欄位 group_buy_campaigns.total_cap_qty'::TEXT; END IF;
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'campaign_items' AND column_name = 'cap_qty';
  IF NOT FOUND THEN v_bad := v_bad || '找不到欄位 campaign_items.cap_qty'::TEXT; END IF;
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'group_buy_campaigns' AND column_name = 'close_type';
  IF NOT FOUND THEN v_bad := v_bad || '找不到欄位 group_buy_campaigns.close_type'::TEXT; END IF;

  FOR v_rec IN
    SELECT *
      FROM (VALUES
        ('public.rpc_create_store_internal_order(bigint, bigint, jsonb, uuid, text)', TRUE,
         '879557850032331e9475268f5a03cffd', '03831e21f155452db4ec556e4504df22'),
        ('public.rpc_update_order_item_qty(bigint, bigint, numeric, uuid, text)', TRUE,
         '7b1f474beb80d2b5ae0b70f586d25cb7', '488806de2f781f83dc1e609cc0f676dc'),
        ('public.rpc_restore_cancelled_order(bigint, uuid, text)', TRUE,
         '7c9c1801252437301f2ba226b54546ad', '5475a4c53397f066b083c6670644e05c')
      ) AS t(sig, must_exist, md5_base, md5_new)
  LOOP
    v_oid := to_regprocedure(v_rec.sig);
    IF v_oid IS NULL THEN
      IF v_rec.must_exist THEN
        v_bad := v_bad || format('找不到函式 %s（名稱或參數型別跟預期不一樣）', v_rec.sig);
      END IF;
      CONTINUE;
    END IF;
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5 FROM pg_proc p WHERE p.oid = v_oid;
    IF v_md5 IS DISTINCT FROM v_rec.md5_base AND v_md5 IS DISTINCT FROM v_rec.md5_new THEN
      v_bad := v_bad || format('%s 線上內文不是預期的版本（線上 md5=%s）；可能有人改過，請先比對再決定',
                               v_rec.sig, v_md5);
    END IF;
  END LOOP;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。不符的項目：\n%',
      array_to_string(v_bad, E'\n');
  END IF;
END;
$precheck$;


-- 1. 店長叫貨（20261013000000:2228 逐字）
CREATE OR REPLACE FUNCTION rpc_create_store_internal_order(
  p_campaign_id  BIGINT,
  p_store_id     BIGINT,
  p_items        JSONB,
  p_operator     UUID,
  p_notes        TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id    UUID;
  v_campaign_no  TEXT;
  v_campaign_st  TEXT;
  v_member_id    BIGINT;
  v_channel_id   BIGINT;
  v_seq          INT;
  v_order_no     TEXT;
  v_order_id     BIGINT;
  v_item         JSONB;
  v_ci_id        BIGINT;
  v_ci_sku       BIGINT;
  v_ci_price     NUMERIC;
  v_qty          NUMERIC;
  v_unit_price   NUMERIC;
BEGIN
  -- campaign 驗證
  SELECT tenant_id, campaign_no, status
    INTO v_tenant_id, v_campaign_no, v_campaign_st
    FROM group_buy_campaigns WHERE id = p_campaign_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_campaign_st NOT IN ('open','closed') THEN
    RAISE EXCEPTION 'campaign % is %; only open/closed accept internal order',
                    p_campaign_id, v_campaign_st;
  END IF;

  -- p_items 不可空
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;

  -- 取得 / 建立 store_internal member
  v_member_id := rpc_get_or_create_store_member(p_store_id, p_operator);

  -- 取該店任一 line_channel；無則 fallback 到第一個 channel
  SELECT id INTO v_channel_id
    FROM line_channels
   WHERE tenant_id = v_tenant_id AND home_store_id = p_store_id
   LIMIT 1;

  IF v_channel_id IS NULL THEN
    SELECT id INTO v_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id
     LIMIT 1;
  END IF;

  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION 'no line_channel available for tenant';
  END IF;

  -- 找既有 (UNIQUE: tenant+campaign+channel+member)
  -- 20261013：索引同步放行轉入單（transferred_from_order_id IS NOT NULL，20261013000000），
  --   這裡跟著排除 —— 店與店轉貨收進來的轉入單不能拿來追加，否則追加的貨不會進總倉撿貨。
  SELECT id INTO v_order_id FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = p_campaign_id
     AND channel_id  = v_channel_id
     AND member_id   = v_member_id
     AND transferred_from_order_id IS NULL;

  IF v_order_id IS NULL THEN
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id AND campaign_id = p_campaign_id;
    v_order_no := v_campaign_no || '-INT' || lpad(v_seq::text, 4, '0');

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      pickup_store_id, status, notes, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_no, p_campaign_id, v_channel_id, v_member_id,
      p_store_id, 'pending',
      COALESCE(p_notes, '【店長內部叫貨】'),
      p_operator, p_operator
    ) RETURNING id INTO v_order_id;
  END IF;

  -- 寫 items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
    v_qty   := (v_item ->> 'qty')::NUMERIC;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'qty must be > 0';
    END IF;

    SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
      FROM campaign_items
     WHERE id = v_ci_id AND tenant_id = v_tenant_id AND campaign_id = p_campaign_id;
    IF v_ci_price IS NULL THEN
      RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
    END IF;

    -- 自帶 unit_price 覆寫 (88 折用)；NULL 則用 list price
    v_unit_price := COALESCE((v_item ->> 'unit_price')::NUMERIC, v_ci_price);
    IF v_unit_price < 0 THEN
      RAISE EXCEPTION 'unit_price cannot be negative';
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_id, v_ci_id, v_ci_sku, v_qty, v_unit_price,
      'pending', 'store_internal', p_operator, p_operator
    );
  END LOOP;

  RETURN v_order_id;
END;
$$;


-- 2. 改訂單數量（20260629000010:84 逐字）
CREATE OR REPLACE FUNCTION public.rpc_update_order_item_qty(
  p_order_id BIGINT,
  p_item_id  BIGINT,
  p_new_qty  NUMERIC,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   NUMERIC;
  v_row   customer_order_items;
BEGIN
  -- 1. 權限檢查：HQ 全部 / 店長限 app_metadata.stores 內 pickup_store
  v_order := _check_order_edit_qty_perm(p_order_id);

  -- 2. 訂單狀態閘：僅 pending（被 PR 鎖定變 confirmed 後就擋下）
  IF v_order.status <> 'pending' THEN
    RAISE EXCEPTION '訂單狀態為 %,僅 待確認 訂單可改數量', v_order.status;
  END IF;

  -- 3. 輸入驗證（配合 schema CHECK qty > 0，刪品項另走 RPC）
  IF p_new_qty IS NULL OR p_new_qty <= 0 THEN
    RAISE EXCEPTION 'qty must be > 0';
  END IF;

  SELECT qty INTO v_old
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  -- 4. no-op 短路
  IF v_old = p_new_qty THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id;
    RETURN v_row;
  END IF;

  UPDATE customer_order_items
     SET qty        = p_new_qty,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  -- 5. 稽核
  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'qty',
     to_jsonb(v_old), to_jsonb(p_new_qty), p_reason, p_operator);

  RETURN v_row;
END;
$$;


-- 3. 復原已取消的單（20261013000000:1480 逐字）
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
  -- 20261013：補齊索引後來加的豁免（WS- 20260901010000、aid_board_id 20260824060000、
  --   轉入單 20261013000000）—— 那些單不佔 slot，不該擋住復原。
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
       AND co.order_no NOT LIKE 'WS-%'
       AND co.aid_board_id IS NULL
       AND co.transferred_from_order_id IS NULL
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


-- 4. 拿掉新函式（上面三支還原後已經沒有人呼叫）
DROP FUNCTION IF EXISTS public._caller_is_store_role();
DROP FUNCTION IF EXISTS public._campaign_is_limited(BIGINT);

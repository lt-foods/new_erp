-- ============================================================
-- 加單頁抵減改版：抵減單要有帳上現貨；可指定客人「現貨直售」
--
-- 動機：加單頁的「庫存抵減單」原本隨手就能開（例：2026-08-05 松山店
--   測試單原因只填「a」），跟庫存完全脫鉤 —— 但抵減的本意是「店內現貨
--   吸收這部分需求」，帳上根本沒貨也能抵，之後客人取貨 sale 扣帳就會
--   把店倉打成負數。而店家實際最常見的情境是：客人當面要一件、店內
--   架上就有 → 想直接「把店內庫存加給這個客人」，一步完成。
--
-- 改法：
--   1. rpc_create_offset_order 加庫存閘門：每個 SKU 檢查店倉帳上可用
--      （on_hand − reserved）≥ 抵減量，不足就擋、提示先到庫存總覽入帳。
--      （與 rpc_create_inventory_deduction 同一套規則）
--   2. 新增 rpc_create_offset_sale「現貨直售」：指定客人 + 數量，
--      一個交易內完成 —— 建客人訂單（rpc_create_customer_orders）、
--      開抵減單（rpc_create_offset_order，讓採購聚合不多買）、
--      當下交貨結案（rpc_record_pickup：sale 扣店庫存、訂單完成）。
--      與到店取貨同一套帳，之後不會重複扣。
--
-- 基底版本：
--   rpc_create_offset_order    = 20260516000001（唯一版本）
--   rpc_create_customer_orders = 20260805000140（只呼叫、不改）
--   rpc_record_pickup          = 20260801000000（只呼叫、不改）
-- rollback：重跑 20260516000001 的 rpc_create_offset_order；
--   DROP FUNCTION IF EXISTS public.rpc_create_offset_sale(BIGINT,BIGINT,BIGINT,BIGINT,TEXT,JSONB,TEXT,UUID);
-- ============================================================

-- ------------------------------------------------------------
-- 1. rpc_create_offset_order + 庫存閘門
--    （基底 20260516000001 逐字保留，僅插入店倉現貨檢查段）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_create_offset_order(
  p_campaign_id BIGINT,
  p_store_id    BIGINT,
  p_items       JSONB,         -- [{campaign_item_id, qty}], qty 必須 < 0
  p_reason      TEXT,
  p_operator    UUID
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
  v_store_loc    BIGINT;
  v_chk          RECORD;
  v_have         NUMERIC;
  v_sku_label    TEXT;
BEGIN
  -- 必填驗證
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION '抵減原因 (p_reason) 必填';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;

  -- qty 全為負驗證
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) e
    WHERE (e->>'qty')::numeric >= 0
  ) THEN
    RAISE EXCEPTION '抵減單所有品項 qty 必須 < 0';
  END IF;

  -- campaign 驗證
  SELECT tenant_id, campaign_no, status
    INTO v_tenant_id, v_campaign_no, v_campaign_st
    FROM group_buy_campaigns WHERE id = p_campaign_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_campaign_st NOT IN ('open', 'closed') THEN
    RAISE EXCEPTION 'campaign % is %; only open/closed accept offset order',
                    p_campaign_id, v_campaign_st;
  END IF;

  -- 店倉帳上現貨閘門（20260805000200）：抵減 = 用店內現貨吸收需求，
  -- 帳上要真的有貨。不足 → 先到「庫存總覽」依商品新增庫存。
  SELECT s.location_id INTO v_store_loc FROM stores s WHERE s.id = p_store_id;
  IF v_store_loc IS NULL THEN
    RAISE EXCEPTION '分店 % 不存在或未綁定倉別', p_store_id;
  END IF;
  FOR v_chk IN
    SELECT ci.sku_id, SUM(-(e->>'qty')::numeric) AS need
      FROM jsonb_array_elements(p_items) e
      JOIN campaign_items ci ON ci.id = (e->>'campaign_item_id')::bigint
                            AND ci.campaign_id = p_campaign_id
     GROUP BY ci.sku_id
  LOOP
    SELECT COALESCE(sb.on_hand - sb.reserved, 0) INTO v_have
      FROM stock_balances sb
     WHERE sb.tenant_id = v_tenant_id
       AND sb.location_id = v_store_loc
       AND sb.sku_id = v_chk.sku_id;
    IF NOT FOUND THEN v_have := 0; END IF;
    IF v_have < v_chk.need THEN
      SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
        INTO v_sku_label FROM skus s WHERE s.id = v_chk.sku_id;
      RAISE EXCEPTION '「%」店內帳上現貨不足：可用 % 件、要抵減 % 件。請先到「庫存總覽」對該商品新增庫存，再開抵減單',
        COALESCE(v_sku_label, v_chk.sku_id::text), v_have, v_chk.need;
    END IF;
  END LOOP;

  -- 取得 / 建立 store_internal member
  v_member_id := rpc_get_or_create_store_member(p_store_id, p_operator);

  -- 取該店任一 line_channel；無則 fallback 到 tenant 第一個
  SELECT id INTO v_channel_id
    FROM line_channels
   WHERE tenant_id = v_tenant_id AND home_store_id = p_store_id
   LIMIT 1;
  IF v_channel_id IS NULL THEN
    SELECT id INTO v_channel_id FROM line_channels
     WHERE tenant_id = v_tenant_id LIMIT 1;
  END IF;
  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION 'no line_channel available for tenant';
  END IF;

  -- 簡化：同 store + 同 campaign 共用一張 offset 單；UNIQUE 衝突時
  -- 累加 items 到既有單（沿用 20260516000001 的行為）。
  -- 20260805000200：排除已取消/失效的舊單 —— 復用一張 cancelled 抵減單會讓
  -- 取貨閘門的 Path D'（只認 active offset）認不到，現貨直售會卡在「尚未實收到貨」。
  -- customer_orders_trio_kind_active_uniq 本來就只管 active 單，開新單不會撞 UNIQUE。
  SELECT id INTO v_order_id FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = p_campaign_id
     AND channel_id  = v_channel_id
     AND member_id   = v_member_id
     AND order_kind  = 'offset'
     AND status NOT IN ('cancelled', 'expired', 'transferred_out');

  IF v_order_id IS NULL THEN
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id AND campaign_id = p_campaign_id
       AND order_kind = 'offset';
    v_order_no := v_campaign_no || '-OFF' || lpad(v_seq::text, 4, '0');

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      pickup_store_id, order_kind, status, notes, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_no, p_campaign_id, v_channel_id, v_member_id,
      p_store_id, 'offset', 'confirmed',
      '[庫存抵減單] ' || p_reason,
      p_operator, p_operator
    ) RETURNING id INTO v_order_id;
  ELSE
    -- 既有 offset 單，累加 notes（保留歷次原因）
    UPDATE customer_orders SET
      notes      = COALESCE(notes, '') || E'\n[追加] ' || p_reason,
      updated_by = p_operator
    WHERE id = v_order_id;
  END IF;

  -- 寫 items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
    v_qty   := (v_item ->> 'qty')::NUMERIC;

    SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
      FROM campaign_items
     WHERE id = v_ci_id AND tenant_id = v_tenant_id AND campaign_id = p_campaign_id;
    IF v_ci_price IS NULL THEN
      RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_id, v_ci_id, v_ci_sku, v_qty, v_ci_price,
      'pending', 'store_internal', p_operator, p_operator
    );
  END LOOP;

  RETURN v_order_id;
END;
$$;

COMMENT ON FUNCTION rpc_create_offset_order(BIGINT, BIGINT, JSONB, TEXT, UUID) IS
  '庫存抵減單（負數訂單）：店內已有現貨、讓採購聚合少買。'
  '20260805000200 加店倉帳上現貨閘門（on_hand − reserved ≥ 抵減量），'
  '不足時提示先到庫存總覽依商品新增庫存。';

-- ------------------------------------------------------------
-- 2. rpc_create_offset_sale — 現貨直售：店內庫存直接加給指定客人
--    建客人訂單 + 抵減單（採購不多買）+ 當下交貨結案（sale 扣店庫存）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_offset_sale(
  p_campaign_id BIGINT,
  p_channel_id  BIGINT,
  p_store_id    BIGINT,
  p_member_id   BIGINT,
  p_nickname    TEXT,
  p_items       JSONB,     -- [{campaign_item_id, qty}], qty > 0 整數
  p_reason      TEXT,
  p_operator    UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order_id   BIGINT;
  v_order_no   TEXT;
  v_offset_id  BIGINT;
  v_offset_no  TEXT;
  v_ids        BIGINT[];
  v_qtys       JSONB;
  v_total      NUMERIC;
  v_reason     TEXT;
BEGIN
  IF p_member_id IS NULL THEN
    RAISE EXCEPTION '現貨直售必須指定客人（純抵減請走 rpc_create_offset_order）';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) e
     WHERE (e->>'qty')::numeric <= 0
        OR (e->>'qty')::numeric <> FLOOR((e->>'qty')::numeric)
  ) THEN
    RAISE EXCEPTION '現貨直售品項數量必須為正整數';
  END IF;

  SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_total
    FROM jsonb_array_elements(p_items) e;

  -- 1) 建立 / 併入客人訂單（黑名單、cap、團狀態等檢查沿用一般加單）
  SELECT r.out_order_id, r.out_order_no INTO v_order_id, v_order_no
    FROM public.rpc_create_customer_orders(
      p_campaign_id, p_channel_id,
      jsonb_build_array(jsonb_build_object(
        'member_id', p_member_id,
        'nickname', p_nickname,
        'pickup_store_id', p_store_id,
        'items', p_items
      ))
    ) r
   LIMIT 1;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION '建立客人訂單失敗';
  END IF;

  -- 2) 開抵減單（負數）：採購聚合不會為這幾件多買。
  --    內含店倉現貨閘門 — 帳上沒貨會在這裡擋下、整筆 rollback。
  v_reason := COALESCE(NULLIF(TRIM(p_reason), ''),
                       format('現貨直售 %s', v_order_no));
  v_offset_id := rpc_create_offset_order(
    p_campaign_id, p_store_id,
    (SELECT jsonb_agg(jsonb_build_object(
              'campaign_item_id', (e->>'campaign_item_id')::bigint,
              'qty', -((e->>'qty')::numeric)))
       FROM jsonb_array_elements(p_items) e),
    v_reason, p_operator
  );
  SELECT order_no INTO v_offset_no FROM customer_orders WHERE id = v_offset_id;

  -- 3) 當下交貨結案：sale 扣店庫存、品項 picked_up、訂單完成。
  --    取貨閘門由抵減單的 Path D'（20260805000180）放行。
  --    加單可能把數量併進既有未取行 → 用 p_item_qtys 只取本次的量（會拆行）。
  SELECT array_agg(x.id), jsonb_object_agg(x.id::text, x.take)
    INTO v_ids, v_qtys
    FROM (
      SELECT DISTINCT ON (coi.campaign_item_id)
             coi.id, LEAST(req.qty, coi.qty) AS take
        FROM (
          SELECT (e->>'campaign_item_id')::bigint AS ci_id,
                 SUM((e->>'qty')::numeric) AS qty
            FROM jsonb_array_elements(p_items) e
           GROUP BY 1
        ) req
        JOIN customer_order_items coi
          ON coi.order_id = v_order_id
         AND coi.campaign_item_id = req.ci_id
         AND coi.status IN ('pending', 'reserved', 'ready')
       ORDER BY coi.campaign_item_id, coi.id DESC
    ) x;

  IF v_ids IS NULL OR array_length(v_ids, 1) = 0 THEN
    RAISE EXCEPTION '找不到剛建立的訂單品項，無法交貨';
  END IF;

  PERFORM public.rpc_record_pickup(
    v_order_id, v_ids, p_operator,
    format('現貨直售（抵減單 %s）：店內現貨交貨', v_offset_no),
    v_qtys
  );

  RETURN jsonb_build_object(
    'order_id', v_order_id, 'order_no', v_order_no,
    'offset_order_id', v_offset_id, 'offset_order_no', v_offset_no,
    'delivered_qty', v_total
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_offset_sale(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, JSONB, TEXT, UUID) IS
  '現貨直售：店內庫存直接加給指定客人。一個交易內 = 建客人訂單 + 抵減單'
  '（採購不多買）+ rpc_record_pickup 交貨結案（sale 扣店庫存，與到店取貨同一套帳）。'
  '店倉帳上現貨不足會被抵減單閘門擋下。';

REVOKE ALL ON FUNCTION public.rpc_create_offset_sale(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, JSONB, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_offset_sale(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, JSONB, TEXT, UUID) TO authenticated;

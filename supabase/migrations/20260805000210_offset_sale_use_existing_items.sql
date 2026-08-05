-- ============================================================
-- 現貨直售修正：先交付客人「已經下過的訂單」，不要重複加一筆
--
-- 事故：2026-08-05 23:56 松山店 GRP-20260805-035-0001（Peggy）。
--   店員先用加單頁建了訂單（1 件、pending），18 秒後對同一位客人做「現貨直售」
--   1 件 —— 20260805000200 的 rpc_create_offset_sale 一律呼叫
--   rpc_create_customer_orders 再加一筆，於是 1 件變 2 件（1 待取 + 1 已取），
--   應收從 $139 變 $278。店員要的是「把他已經訂的那件用店內現貨交給他」。
--
-- 修法 1：先用既有的未取品項，不夠才補建
--   以 (member, campaign, store, sku) 找 status IN (pending,reserved,ready) 的行，
--   由舊到新吃掉要交的量；仍不足的部分才呼叫 rpc_create_customer_orders 補。
--   完全沒下過單的客人行為不變（照舊建單再交貨）。
--
-- 修法 2：改開「庫存減抵單」而不是抵減單（負數訂單）
--   抵減單在 v_order_shortage 是永久的負需求；但現貨直售當下就把品項標成
--   picked_up，picked_up 本來就離開該檢視的需求池（它只算 coi.status='pending'）
--   —— 兩者相加 = 同一件被扣兩次，採購會少買。
--   改寫 inventory_deduction_notes（20260805000170）：
--     - v_order_shortage 不看這張表 → 不會重複扣採購
--     - rpc_get_ship_vs_demand_for_transfers 的 demand 是「所有未取消品項」
--       （含已取貨），covered 加上減抵量後 short 才正確
--     - 取貨閘門走 Path D（減抵單視同到貨），新建的行也放得過
--
-- 基底版本：20260805000200_offset_sale_and_stock_gate 的 rpc_create_offset_sale
--   （rpc_create_offset_order 不動 —— 純抵減那條路的語意沒變）
-- rollback: 重跑 20260805000200 的 rpc_create_offset_sale。
-- ============================================================

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
  v_store     stores%ROWTYPE;
  r           RECORD;
  x           RECORD;
  v_left      NUMERIC;
  v_take      NUMERIC;
  v_total     NUMERIC := 0;
  v_avail     NUMERIC;
  v_shortfall JSONB;
  v_order_no  TEXT;
  v_note      inventory_deduction_notes%ROWTYPE;
  v_sku_label TEXT;
  v_ord       RECORD;
  v_orders    INT := 0;
  v_reused    NUMERIC := 0;
  v_added     NUMERIC := 0;
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

  SELECT * INTO v_store FROM stores WHERE id = p_store_id;
  IF NOT FOUND OR v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 不存在或未綁定倉別', p_store_id;
  END IF;

  -- 需求彙總（同 SKU 多列先合併）
  DROP TABLE IF EXISTS _os_req;
  CREATE TEMP TABLE _os_req ON COMMIT DROP AS
  SELECT (e->>'campaign_item_id')::bigint AS ci_id,
         ci.sku_id,
         SUM((e->>'qty')::numeric)        AS qty
    FROM jsonb_array_elements(p_items) e
    JOIN campaign_items ci
      ON ci.id = (e->>'campaign_item_id')::bigint
     AND ci.campaign_id = p_campaign_id
   GROUP BY 1, 2;

  IF (SELECT COUNT(*) FROM _os_req) <> (
        SELECT COUNT(DISTINCT (e->>'campaign_item_id')::bigint) FROM jsonb_array_elements(p_items) e) THEN
    RAISE EXCEPTION '有品項不屬於這個開團';
  END IF;

  SELECT SUM(qty) INTO v_total FROM _os_req;

  -- 同組併發：鎖住 (店, 團, 客人) 免得兩台同時各建一筆
  PERFORM pg_advisory_xact_lock(hashtext(format('offsale:%s:%s:%s:%s',
    v_store.tenant_id, p_campaign_id, p_store_id, p_member_id)));

  -- 店倉可用量檢查（現貨要先在帳上；庫存總覽可依商品新增庫存）
  FOR r IN SELECT * FROM _os_req LOOP
    SELECT COALESCE(sb.on_hand - sb.reserved, 0) INTO v_avail
      FROM stock_balances sb
     WHERE sb.tenant_id = v_store.tenant_id
       AND sb.location_id = v_store.location_id
       AND sb.sku_id = r.sku_id
     FOR UPDATE;
    IF NOT FOUND THEN v_avail := 0; END IF;
    IF v_avail < r.qty THEN
      SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
        INTO v_sku_label FROM skus s WHERE s.id = r.sku_id;
      RAISE EXCEPTION '「%」店內帳上現貨不足：可用 % 件、要交 % 件。請先到「庫存總覽」對該商品新增庫存',
        COALESCE(v_sku_label, r.sku_id::text), v_avail, r.qty;
    END IF;
  END LOOP;

  -- ① 這位客人在本團本店「已經下過、還沒取」的量
  DROP TABLE IF EXISTS _os_have;
  CREATE TEMP TABLE _os_have ON COMMIT DROP AS
  SELECT q.sku_id, COALESCE(SUM(coi.qty), 0) AS qty
    FROM (SELECT DISTINCT sku_id FROM _os_req) q
    LEFT JOIN customer_orders co
      ON co.tenant_id       = v_store.tenant_id
     AND co.campaign_id     = p_campaign_id
     AND co.pickup_store_id = p_store_id
     AND co.member_id       = p_member_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND co.transferred_from_order_id IS NULL
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
    LEFT JOIN customer_order_items coi
      ON coi.order_id = co.id
     AND coi.sku_id   = q.sku_id
     AND coi.status IN ('pending', 'reserved', 'ready')
   GROUP BY q.sku_id;

  -- ② 不足的部分才補建訂單（既有的量直接拿來交，不重複加）
  SELECT jsonb_agg(jsonb_build_object('campaign_item_id', r.ci_id,
                                      'qty', r.qty - COALESCE(h.qty, 0)))
    INTO v_shortfall
    FROM _os_req r
    LEFT JOIN _os_have h ON h.sku_id = r.sku_id
   WHERE r.qty - COALESCE(h.qty, 0) > 0;

  SELECT COALESCE(SUM(LEAST(r.qty, COALESCE(h.qty, 0))), 0),
         COALESCE(SUM(GREATEST(r.qty - COALESCE(h.qty, 0), 0)), 0)
    INTO v_reused, v_added
    FROM _os_req r LEFT JOIN _os_have h ON h.sku_id = r.sku_id;

  IF v_shortfall IS NOT NULL THEN
    SELECT c.out_order_no INTO v_order_no
      FROM public.rpc_create_customer_orders(
        p_campaign_id, p_channel_id,
        jsonb_build_array(jsonb_build_object(
          'member_id', p_member_id,
          'nickname', p_nickname,
          'pickup_store_id', p_store_id,
          'items', v_shortfall
        ))
      ) c
     LIMIT 1;
  END IF;

  -- ③ 決定實際要交哪幾行（由舊到新吃滿，含剛補建/併入的量）
  DROP TABLE IF EXISTS _os_take;
  CREATE TEMP TABLE _os_take (order_id BIGINT, item_id BIGINT, take NUMERIC) ON COMMIT DROP;

  FOR r IN SELECT * FROM _os_req LOOP
    v_left := r.qty;
    FOR x IN
      SELECT coi.id, coi.order_id, coi.qty
        FROM customer_orders co
        JOIN customer_order_items coi
          ON coi.order_id = co.id
         AND coi.sku_id   = r.sku_id
         AND coi.status IN ('pending', 'reserved', 'ready')
       WHERE co.tenant_id       = v_store.tenant_id
         AND co.campaign_id     = p_campaign_id
         AND co.pickup_store_id = p_store_id
         AND co.member_id       = p_member_id
         AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
         AND co.transferred_from_order_id IS NULL
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       ORDER BY coi.id
       FOR UPDATE OF coi
    LOOP
      EXIT WHEN v_left <= 0;
      v_take := LEAST(x.qty, v_left);
      INSERT INTO _os_take VALUES (x.order_id, x.id, v_take);
      v_left := v_left - v_take;
    END LOOP;
    IF v_left > 0 THEN
      RAISE EXCEPTION '找不到足夠的訂單品項可交貨（還差 % 件），請重新整理畫面再試', v_left;
    END IF;
  END LOOP;

  -- ④ 開庫存減抵單（不是抵減單）：picked_up 本身就會離開採購需求池，
  --    再開負數訂單會讓同一件被扣兩次；減抵單只當收貨頁的 coverage。
  INSERT INTO inventory_deduction_notes (
    tenant_id, note_no, campaign_id, store_id, sku_id, transfer_id,
    qty, reason, created_by
  )
  SELECT v_store.tenant_id,
         'DN' || to_char(NOW(), 'YYMMDD') || lpad(nextval('deduction_note_seq')::text, 4, '0'),
         p_campaign_id, p_store_id, r.sku_id, NULL,
         r.qty,
         COALESCE(NULLIF(TRIM(p_reason), ''), '加單頁現貨直售'),
         p_operator
    FROM _os_req r
  RETURNING * INTO v_note;   -- 多 SKU 時取最後一張，回傳用

  INSERT INTO inventory_deduction_note_items (note_id, order_id, order_item_id, qty)
  SELECT n.id, t.order_id, t.item_id, t.take
    FROM _os_take t
    JOIN customer_order_items coi ON coi.id = t.item_id
    JOIN inventory_deduction_notes n
      ON n.tenant_id = v_store.tenant_id AND n.campaign_id = p_campaign_id
     AND n.store_id = p_store_id AND n.sku_id = coi.sku_id
     AND n.created_at = v_note.created_at AND n.cancelled_at IS NULL;

  -- ⑤ 逐訂單交貨結案（sale 扣店庫存，與到店取貨同一套帳）
  FOR v_ord IN SELECT DISTINCT order_id FROM _os_take LOOP
    -- 待補貨的行也可以用現貨交 → 先解除擋板
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = NOW()
      FROM _os_take t
     WHERE t.order_id = v_ord.order_id AND coi.id = t.item_id
       AND coi.backorder_at IS NOT NULL;

    PERFORM public.rpc_record_pickup(
      v_ord.order_id,
      (SELECT array_agg(t.item_id) FROM _os_take t WHERE t.order_id = v_ord.order_id),
      p_operator,
      format('現貨直售（減抵單 %s）：店內現貨交貨', v_note.note_no),
      (SELECT jsonb_object_agg(t.item_id::text, t.take)
         FROM _os_take t WHERE t.order_id = v_ord.order_id)
    );
    v_orders := v_orders + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'note_no', v_note.note_no,
    'order_no', COALESCE(v_order_no,
                 (SELECT co.order_no FROM _os_take t JOIN customer_orders co ON co.id = t.order_id LIMIT 1)),
    'delivered_qty', v_total,
    'reused_qty', v_reused,   -- 直接交付客人原本就下過的量
    'added_qty', v_added,     -- 客人沒下過、這次才補建的量
    'orders', v_orders
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_offset_sale(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, JSONB, TEXT, UUID) IS
  '現貨直售：店內庫存直接交給指定客人。先交付客人「已下單未取」的品項，不夠才補建訂單'
  '（20260805000210 修正重複加單）；開庫存減抵單當 coverage，再走 rpc_record_pickup'
  '交貨結案（sale 扣店庫存）。不開抵減單 —— picked_up 已離開採購需求池，再抵會少買。';

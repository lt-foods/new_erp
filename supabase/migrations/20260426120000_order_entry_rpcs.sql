-- ============================================================
-- Order Entry RPCs — 小幫手代客 key 訂單 MVP-0
-- 對應 docs/PRD-訂單取貨模組.md §7.3、docs/TEST-order-entry-mvp0.md
--
-- 4 個 RPC：
--   D1. rpc_search_members            — autocomplete 顧客
--   D2. rpc_search_skus_for_campaign  — autocomplete 活動內 SKU
--   D3. rpc_search_aliases            — autocomplete LINE 暱稱
--   D4. rpc_bind_line_alias           — 綁定 / 改綁
--   D5. rpc_create_customer_orders    — 批建訂單（合併同顧客）
-- ============================================================

-- --------------------------------------------------------
-- D1. rpc_search_members
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_search_members(
  p_term  TEXT,
  p_limit INT DEFAULT 20
) RETURNS TABLE (
  id          BIGINT,
  member_no   TEXT,
  name        TEXT,
  phone       TEXT,
  avatar_url  TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_term   TEXT := COALESCE(NULLIF(TRIM(p_term), ''), NULL);
  v_lim    INT  := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  RETURN QUERY
  SELECT m.id, m.member_no, m.name, m.phone, m.avatar_url
    FROM members m
   WHERE m.tenant_id = v_tenant
     AND (
       v_term IS NULL
       OR m.name      ILIKE '%' || v_term || '%'
       OR m.member_no ILIKE '%' || v_term || '%'
       OR m.phone     ILIKE '%' || v_term || '%'
     )
   ORDER BY m.created_at DESC
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_members TO authenticated;

-- --------------------------------------------------------
-- D2. rpc_search_skus_for_campaign
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_search_skus_for_campaign(
  p_campaign_id BIGINT,
  p_term        TEXT,
  p_limit       INT DEFAULT 20
) RETURNS TABLE (
  campaign_item_id BIGINT,
  sku_id           BIGINT,
  sku_code         TEXT,
  product_name     TEXT,
  variant_name     TEXT,
  unit_price       NUMERIC,
  cap_qty          NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_term   TEXT := COALESCE(NULLIF(TRIM(p_term), ''), NULL);
  v_lim    INT  := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  PERFORM 1 FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;

  RETURN QUERY
  SELECT ci.id, s.id, s.sku_code,
         COALESCE(s.product_name, p.name), s.variant_name,
         ci.unit_price, ci.cap_qty
    FROM campaign_items ci
    JOIN skus s     ON s.id = ci.sku_id
    JOIN products p ON p.id = s.product_id
   WHERE ci.tenant_id   = v_tenant
     AND ci.campaign_id = p_campaign_id
     AND (
       v_term IS NULL
       OR s.sku_code     ILIKE '%' || v_term || '%'
       OR s.variant_name ILIKE '%' || v_term || '%'
       OR p.name         ILIKE '%' || v_term || '%'
       OR s.product_name ILIKE '%' || v_term || '%'
     )
   ORDER BY ci.sort_order, p.name
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_skus_for_campaign TO authenticated;

-- --------------------------------------------------------
-- D3. rpc_search_aliases
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_search_aliases(
  p_channel_id BIGINT,
  p_term       TEXT,
  p_limit      INT DEFAULT 20
) RETURNS TABLE (
  alias_id    BIGINT,
  nickname    TEXT,
  member_id   BIGINT,
  member_no   TEXT,
  member_name TEXT,
  phone       TEXT,
  avatar_url  TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_term   TEXT := COALESCE(NULLIF(TRIM(p_term), ''), NULL);
  v_lim    INT  := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  RETURN QUERY
  SELECT a.id, a.nickname, m.id, m.member_no, m.name, m.phone, m.avatar_url
    FROM customer_line_aliases a
    JOIN members m ON m.id = a.member_id
   WHERE a.tenant_id  = v_tenant
     AND a.channel_id = p_channel_id
     AND (v_term IS NULL OR a.nickname ILIKE '%' || v_term || '%')
   ORDER BY a.updated_at DESC
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_aliases TO authenticated;

-- --------------------------------------------------------
-- D4. rpc_bind_line_alias  (upsert)
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_bind_line_alias(
  p_channel_id BIGINT,
  p_nickname   TEXT,
  p_member_id  BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_nickname IS NULL OR TRIM(p_nickname) = '' THEN
    RAISE EXCEPTION 'nickname is required';
  END IF;
  PERFORM 1 FROM line_channels WHERE id = p_channel_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'channel % not in tenant', p_channel_id; END IF;
  PERFORM 1 FROM members WHERE id = p_member_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;

  INSERT INTO customer_line_aliases (
    tenant_id, channel_id, nickname, member_id, created_by, updated_by
  ) VALUES (
    v_tenant, p_channel_id, TRIM(p_nickname), p_member_id, auth.uid(), auth.uid()
  )
  ON CONFLICT (tenant_id, channel_id, nickname) DO UPDATE
    SET member_id  = EXCLUDED.member_id,
        updated_by = auth.uid()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_bind_line_alias TO authenticated;

-- --------------------------------------------------------
-- D5. rpc_create_customer_orders
--   p_rows JSONB:
--   [
--     {
--       "member_id":1, "nickname":"小美", "pickup_store_id":2,
--       "items":[ {"campaign_item_id":10, "qty":3}, ... ]
--     }, ...
--   ]
--   合併規則：同 (campaign, channel, member) → 走 UNIQUE upsert，items 累加同 campaign_item_id
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_customer_orders(
  p_campaign_id BIGINT,
  p_channel_id  BIGINT,
  p_rows        JSONB
) RETURNS TABLE (out_order_id BIGINT, out_order_no TEXT, out_item_count INT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_status       TEXT;
  v_campaign_no  TEXT;
  v_row          JSONB;
  v_item         JSONB;
  v_member_id    BIGINT;
  v_pickup_store BIGINT;
  v_nickname     TEXT;
  v_order_id     BIGINT;
  v_order_no     TEXT;
  v_seq          INT;
  v_ci_id        BIGINT;
  v_ci_price     NUMERIC;
  v_qty          NUMERIC;
  v_ci_sku       BIGINT;
  v_existing_qty NUMERIC;
  v_count        INT;
BEGIN
  -- 活動驗證 + status='open' 才能 key 單（決議 A）
  SELECT status, campaign_no INTO v_status, v_campaign_no
    FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF v_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'campaign % is %; only open campaigns accept manual entry',
                    p_campaign_id, v_status;
  END IF;

  PERFORM 1 FROM line_channels WHERE id = p_channel_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'channel % not in tenant', p_channel_id; END IF;

  IF p_rows IS NULL OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'p_rows is empty';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_member_id    := (v_row ->> 'member_id')::BIGINT;
    v_pickup_store := (v_row ->> 'pickup_store_id')::BIGINT;
    v_nickname     := v_row ->> 'nickname';

    IF v_member_id IS NULL THEN RAISE EXCEPTION 'member_id required'; END IF;
    IF v_pickup_store IS NULL THEN RAISE EXCEPTION 'pickup_store_id required'; END IF;

    PERFORM 1 FROM members WHERE id = v_member_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', v_member_id; END IF;
    PERFORM 1 FROM stores WHERE id = v_pickup_store AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', v_pickup_store; END IF;

    -- 找既有訂單（UNIQUE: tenant+campaign+channel+member）
    SELECT id INTO v_order_id FROM customer_orders
     WHERE tenant_id = v_tenant
       AND campaign_id = p_campaign_id
       AND channel_id  = p_channel_id
       AND member_id   = v_member_id;

    IF v_order_id IS NULL THEN
      -- 產生 order_no = {campaign_no}-{seq}
      SELECT COUNT(*) + 1 INTO v_seq FROM customer_orders
       WHERE tenant_id = v_tenant AND campaign_id = p_campaign_id;
      v_order_no := v_campaign_no || '-' || lpad(v_seq::text, 4, '0');

      INSERT INTO customer_orders (
        tenant_id, order_no, campaign_id, channel_id, member_id,
        nickname_snapshot, pickup_store_id, status, created_by, updated_by
      ) VALUES (
        v_tenant, v_order_no, p_campaign_id, p_channel_id, v_member_id,
        v_nickname, v_pickup_store, 'pending', v_user, v_user
      ) RETURNING id INTO v_order_id;
    ELSE
      -- 既有：更新 nickname_snapshot / pickup_store
      UPDATE customer_orders SET
        nickname_snapshot = COALESCE(v_nickname, nickname_snapshot),
        pickup_store_id   = v_pickup_store,
        updated_by        = v_user
      WHERE id = v_order_id
      RETURNING order_no INTO v_order_no;
    END IF;

    -- items：同 campaign_item_id 累加；否則新增
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_row -> 'items')
    LOOP
      v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
      v_qty   := (v_item ->> 'qty')::NUMERIC;
      IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'qty must be > 0'; END IF;

      SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
        FROM campaign_items
       WHERE id = v_ci_id AND tenant_id = v_tenant AND campaign_id = p_campaign_id;
      IF v_ci_price IS NULL THEN
        RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
      END IF;

      SELECT coi.qty INTO v_existing_qty FROM customer_order_items coi
       WHERE coi.order_id = v_order_id AND coi.campaign_item_id = v_ci_id;

      IF v_existing_qty IS NULL THEN
        INSERT INTO customer_order_items (
          tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
          status, source, created_by, updated_by
        ) VALUES (
          v_tenant, v_order_id, v_ci_id, v_ci_sku, v_qty, v_ci_price,
          'pending', 'manual', v_user, v_user
        );
      ELSE
        UPDATE customer_order_items coi SET
          qty        = v_existing_qty + v_qty,
          updated_by = v_user
        WHERE coi.order_id = v_order_id AND coi.campaign_item_id = v_ci_id;
      END IF;
    END LOOP;

    SELECT COUNT(*) INTO v_count FROM customer_order_items coi WHERE coi.order_id = v_order_id;
    out_order_id   := v_order_id;
    out_order_no   := v_order_no;
    out_item_count := v_count;
    RETURN NEXT;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_create_customer_orders TO authenticated;

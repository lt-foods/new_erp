-- ============================================================
-- 2026-07-20: 補貨 ride-along 單 items 一律鎖現售價（不分內部/真會員）
--
-- 需求（使用者 2026-07-20 定案，取代 20260714000090 的舊定案）：
--   「魚子燒賣分店價180 零售265，訂單上面的單價是呈現零售價格才對」
--   補貨 ride-along 單（RR-<id>、order_kind='restock'）即使掛【內部】xx店，
--   customer_order_items.unit_price 也應該是零售價（prices scope='retail'）——
--   店端直接對內部單取貨/儲值金結帳時收的就是這個價，不能是分店進貨價。
--
-- 舊行為（20260714000090）：內部單 items 存分店價 snapshot、轉手給真會員時
--   才改鎖現售價；只有建單時指定真會員才直接鎖現售價。
-- 新行為：ride-along 單 items 一律鎖建單當下現售價（查無現售價 fallback 分店價）。
--   restock_request_lines 照舊一律存分店價（總倉↔分店對帳、補貨成本鏈不受影響；
--   訂單明細頁的「分店價」欄本來就是另查 prices scope='branch' 即時顯示）。
--   轉手鎖現售價邏輯（partial/to_store）保留不動——轉手當下重鎖最新現售價。
--
-- 基底版本：
--   rpc_create_restock_request = 20260714000090（線上現行、4 參數簽名），
--   僅改 item 定價區塊（原本 IF NOT v_member_is_internal 才查現售價 → 一律查）。
-- Rollback：CREATE OR REPLACE 回 20260714000090 版；backfill 回復無必要
--   （unit_price 改回分店價可由 restock_request_lines.unit_price 對 sku 回填）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_create_restock_request(
  p_store_id  BIGINT,
  p_lines     JSONB,
  p_notes     TEXT   DEFAULT NULL,
  p_member_id BIGINT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_request_id   BIGINT;
  v_line         JSONB;
  v_sku_id       BIGINT;
  v_count        INT := 0;
  v_is_virtual   BOOLEAN;
  v_campaign_id  BIGINT;
  v_channel_id   BIGINT;
  v_order_id     BIGINT;
  v_order_no     TEXT;
  v_campaign_item_id BIGINT;
  v_unit_price   NUMERIC;
  v_qty          NUMERIC;
  v_member_id    BIGINT;
  v_member_is_internal BOOLEAN := TRUE;
  v_retail_price NUMERIC;
  v_item_price   NUMERIC;
  v_now          TIMESTAMPTZ := NOW();
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create restock request', v_role;
  END IF;

  -- 店端 role 只能建自家店申請。「自己店」由 app_metadata.stores 店名經
  -- _jwt_store_ids() 推導（本系統 JWT 無 store_id claim，見 20260707000080 同型修法）。
  IF v_role IN ('store_manager','store_staff') THEN
    IF NOT (p_store_id = ANY (public._jwt_store_ids())) THEN
      RAISE EXCEPTION 'store role can only create request for own store';
    END IF;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', p_store_id; END IF;

  -- 1. 建 restock_request
  INSERT INTO restock_requests (
    tenant_id, requesting_store_id, status, notes,
    requested_by, requested_at, created_by, updated_by
  ) VALUES (
    v_tenant, p_store_id, 'pending', p_notes,
    v_user, NOW(), v_user, v_user
  ) RETURNING id INTO v_request_id;

  -- 2. 建 sentinel campaign + channel + customer_order
  --    ride-along 單預設掛店內部會員（【內部】xx店），貨到後轉手給客人；
  --    建單時也可直接指定真會員 → 貨到即該會員的可取貨訂單（免轉手）。
  v_campaign_id := public._restock_sentinel_campaign(v_tenant);
  v_channel_id  := public._restock_sentinel_channel(v_tenant, p_store_id);

  IF p_member_id IS NOT NULL THEN
    SELECT (m.member_type = 'store_internal') INTO v_member_is_internal
      FROM members m
     WHERE m.id = p_member_id AND m.tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'member % not in tenant', p_member_id;
    END IF;
    v_member_id := p_member_id;
  ELSE
    v_member_id := public.rpc_get_or_create_store_member(p_store_id, v_user);
    v_member_is_internal := TRUE;
  END IF;

  v_order_no := 'RR-' || v_request_id::TEXT;

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id, pickup_store_id,
    status, order_kind, order_type, external_source, external_order_no,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_order_no, v_campaign_id, v_channel_id, v_member_id, p_store_id,
    'pending', 'restock', 'regular', 'manual', v_order_no,
    CASE WHEN v_member_is_internal THEN '【內部】補貨申請 #' ELSE '【指定會員】補貨申請 #' END
      || v_request_id::TEXT,
    v_user, v_user
  ) RETURNING id INTO v_order_id;

  -- 3. 跑每一個 line:寫 restock_request_lines + customer_order_items
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku_id := (v_line ->> 'sku_id')::BIGINT;
    v_qty    := (v_line ->> 'qty')::NUMERIC;
    v_unit_price := COALESCE((v_line ->> 'unit_price')::NUMERIC, 0);

    SELECT p.is_virtual INTO v_is_virtual
      FROM skus s
      JOIN products p ON p.id = s.product_id
     WHERE s.id = v_sku_id AND s.tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sku % not in tenant', v_sku_id;
    END IF;
    IF v_is_virtual THEN
      RAISE EXCEPTION 'restock request cannot use virtual sku %', v_sku_id;
    END IF;

    IF v_qty <= 0 THEN
      RAISE EXCEPTION 'line qty must be > 0';
    END IF;

    INSERT INTO restock_request_lines (
      tenant_id, request_id, sku_id, qty, unit_price, notes,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_request_id, v_sku_id, v_qty, v_unit_price,
      v_line ->> 'notes', v_user, v_user
    );

    -- sentinel campaign_item per sku
    v_campaign_item_id := public._restock_sentinel_campaign_item(
      v_tenant, v_campaign_id, v_sku_id, v_unit_price
    );

    -- ride-along 單 items 一律鎖建單當下現售價（不分內部/真會員；查無現售價
    -- 或現售價 ≤ 0（未設定的髒資料）fallback 分店價）。店端對此單取貨/結帳收的
    -- 是零售價；分店進貨價只存 restock_request_lines（訂單明細頁「分店價」欄
    -- 另查 prices scope='branch'）。
    SELECT price INTO v_retail_price
      FROM prices
     WHERE tenant_id = v_tenant
       AND sku_id    = v_sku_id
       AND scope     = 'retail'
       AND price     > 0
       AND effective_from <= v_now
       AND (effective_to IS NULL OR effective_to > v_now)
     ORDER BY effective_from DESC
     LIMIT 1;
    v_item_price := COALESCE(v_retail_price, v_unit_price);

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant, v_order_id, v_campaign_item_id, v_sku_id, v_qty, v_item_price,
      'pending', 'manual', v_user, v_user
    );

    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  RETURN v_request_id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_create_restock_request(BIGINT, JSONB, TEXT, BIGINT)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_restock_request IS
  'Case 2：分店建補貨申請（pending 狀態、限真實 SKU，同步建 restock customer_order）。'
  'p_member_id 預設 NULL＝掛店內部會員(【內部】xx店)。ride-along 單 items 一律鎖建單'
  '當下現售價(scope=retail、無則分店價)；restock_request_lines 存分店價。'
  '店端角色只能建自家店申請（_jwt_store_ids() 判定）。基底 20260714000090。';

-- ----------------------------------------------------------------
-- Backfill：存量未完成 ride-along 單 items 改為當下現售價。
-- 範圍：order_kind='restock' 且 status ∈ pending/confirmed/shipping/ready、
--       item 非 cancelled、該 SKU 查得到現售價（>0；0 元視同未設定不套）。
-- 已完成/部分完成的單涉及既成交易，不回溯改價。
-- 套用當下 prod 掃描：約 150 個 item / 80 張單在列（RR-126 魚子燒賣 180→265 等）。
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_fixed INTEGER := 0;
BEGIN
  UPDATE customer_order_items coi
     SET unit_price = f.retail,
         updated_at = NOW()
    FROM (
      SELECT coi2.id AS item_id, pr.price AS retail
        FROM customer_order_items coi2
        JOIN customer_orders co ON co.id = coi2.order_id
        JOIN LATERAL (
          SELECT p2.price
            FROM prices p2
           WHERE p2.tenant_id = coi2.tenant_id
             AND p2.sku_id    = coi2.sku_id
             AND p2.scope     = 'retail'
             AND p2.price     > 0
             AND p2.effective_from <= NOW()
             AND (p2.effective_to IS NULL OR p2.effective_to > NOW())
           ORDER BY p2.effective_from DESC
           LIMIT 1
        ) pr ON TRUE
       WHERE co.order_kind = 'restock'
         AND co.status IN ('pending','confirmed','shipping','ready')
         AND coi2.status <> 'cancelled'
         AND coi2.unit_price IS DISTINCT FROM pr.price
    ) f
   WHERE coi.id = f.item_id;
  GET DIAGNOSTICS v_fixed = ROW_COUNT;
  RAISE NOTICE 'Backfill: % 個 ride-along 單 item 改為現售價', v_fixed;
END $$;

-- ============================================================
-- rpc_search_skus_for_campaign：in_campaign CTE 也排除「已軟刪 SKU / 下架商品」
--
-- 既有問題：siblings CTE 已 filter s.status='active' AND p.status='active'，
-- 但 in_campaign CTE（已加進 campaign 的 items）沒過濾 SKU/商品狀態。
-- 結果：SKU 在 rpc_delete_sku 後（status='discontinued'）若 campaign_items
-- 仍存在（因有 customer_order_items 引用而無法被 resync 刪掉），admin 加單
-- 下拉仍會出現該 SKU，可能讓使用者誤加到新訂單。
--
-- 實例：GB20260522-C000315 含 G00127-01（已軟刪）顯示為 $0 選項。
--
-- 修法：in_campaign 也要求 s.status='active' AND p.status='active'。
-- 既有訂單明細不受影響（訂單列項 sku_label 已固化、不靠這個 RPC 顯示）。
-- ============================================================

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
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_term   TEXT := COALESCE(NULLIF(TRIM(p_term), ''), NULL);
  v_lim    INT  := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  PERFORM 1 FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;

  RETURN QUERY
  WITH campaign_products AS (
    SELECT DISTINCT s.product_id
      FROM campaign_items ci
      JOIN skus s ON s.id = ci.sku_id
     WHERE ci.tenant_id = v_tenant
       AND ci.campaign_id = p_campaign_id
  ),
  in_campaign AS (
    SELECT ci.id          AS x_ci_id,
           s.id           AS x_sku_id,
           s.sku_code     AS x_sku_code,
           COALESCE(s.product_name, p.name) AS x_product_name,
           s.variant_name AS x_variant_name,
           ci.unit_price  AS x_unit_price,
           ci.cap_qty     AS x_cap_qty,
           ci.sort_order  AS x_sort_order,
           p.name         AS x_p_name
      FROM campaign_items ci
      JOIN skus s     ON s.id = ci.sku_id
      JOIN products p ON p.id = s.product_id
     WHERE ci.tenant_id   = v_tenant
       AND ci.campaign_id = p_campaign_id
       AND s.status = 'active'        -- ★ 新增：排除軟刪 SKU
       AND p.status = 'active'        -- ★ 新增：排除下架商品
  ),
  siblings AS (
    SELECT NULL::BIGINT   AS x_ci_id,
           s.id           AS x_sku_id,
           s.sku_code     AS x_sku_code,
           COALESCE(s.product_name, p.name) AS x_product_name,
           s.variant_name AS x_variant_name,
           COALESCE((
             SELECT pr.price
               FROM prices pr
              WHERE pr.tenant_id = v_tenant
                AND pr.sku_id = s.id
                AND pr.scope = 'retail'
                AND pr.effective_to IS NULL
              ORDER BY pr.effective_from DESC
              LIMIT 1
           ), 0)::NUMERIC AS x_unit_price,
           NULL::NUMERIC  AS x_cap_qty,
           999999::INT    AS x_sort_order,
           p.name         AS x_p_name
      FROM skus s
      JOIN products p ON p.id = s.product_id
     WHERE s.tenant_id = v_tenant
       AND s.status = 'active'
       AND p.status = 'active'
       AND s.product_id IN (SELECT product_id FROM campaign_products)
       AND NOT EXISTS (
         SELECT 1 FROM campaign_items ci
          WHERE ci.tenant_id = v_tenant
            AND ci.campaign_id = p_campaign_id
            AND ci.sku_id = s.id
       )
  ),
  combined AS (
    SELECT * FROM in_campaign
    UNION ALL
    SELECT * FROM siblings
  )
  SELECT c.x_ci_id, c.x_sku_id, c.x_sku_code, c.x_product_name,
         c.x_variant_name, c.x_unit_price, c.x_cap_qty
    FROM combined c
   WHERE (
     v_term IS NULL
     OR c.x_sku_code     ILIKE '%' || v_term || '%'
     OR c.x_variant_name ILIKE '%' || v_term || '%'
     OR c.x_p_name       ILIKE '%' || v_term || '%'
     OR c.x_product_name ILIKE '%' || v_term || '%'
   )
   ORDER BY (c.x_ci_id IS NULL), c.x_sort_order, c.x_product_name
   LIMIT v_lim;
END;
$$;

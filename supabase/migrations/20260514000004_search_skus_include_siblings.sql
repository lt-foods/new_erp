-- ============================================================
-- 擴 rpc_search_skus_for_campaign 把同商品的其他 SKU 也撈進來
--
-- 背景：原本 search 只回 campaign_items 內的 SKU；
-- 加單時若使用者想下別的規格（例如同商品「芒果」/「草莓」）就找不到。
--
-- 變更：
--   - 改回傳：campaign_items 內 SKU + 同商品其他 active SKU（campaign_item_id=NULL）
--   - 兄弟 SKU 的 unit_price 用 prices(scope='retail') 最新值；查不到回 0
--   - 排序：is_in_campaign 先（true 在前），再依 sort_order / product_name
--
-- UI 端如挑到 campaign_item_id=NULL 的 SKU，下單前會 lazy 呼叫
-- rpc_upsert_campaign_item 補進 campaign_items（unit_price 用回傳值）。
--
-- Scope: 重建 RPC（簽章不變），不動其他物件
-- Rollback: 重新 apply 20260426120000_order_entry_rpcs.sql 中的 D2 段
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
  -- 既有：campaign_items 內 SKU（已加進此團）
  in_campaign AS (
    SELECT ci.id AS campaign_item_id,
           s.id AS sku_id, s.sku_code,
           COALESCE(s.product_name, p.name) AS product_name,
           s.variant_name,
           ci.unit_price,
           ci.cap_qty,
           ci.sort_order,
           p.name AS p_name
      FROM campaign_items ci
      JOIN skus s     ON s.id = ci.sku_id
      JOIN products p ON p.id = s.product_id
     WHERE ci.tenant_id   = v_tenant
       AND ci.campaign_id = p_campaign_id
  ),
  -- 新：同商品的其他 active SKU（不在 campaign_items 中）
  siblings AS (
    SELECT NULL::BIGINT AS campaign_item_id,
           s.id AS sku_id, s.sku_code,
           COALESCE(s.product_name, p.name) AS product_name,
           s.variant_name,
           COALESCE((
             SELECT pr.price
               FROM prices pr
              WHERE pr.tenant_id = v_tenant
                AND pr.sku_id = s.id
                AND pr.scope = 'retail'
                AND pr.effective_to IS NULL
              ORDER BY pr.effective_from DESC
              LIMIT 1
           ), 0)::NUMERIC AS unit_price,
           NULL::NUMERIC AS cap_qty,
           999999::INT AS sort_order,
           p.name AS p_name
      FROM skus s
      JOIN products p ON p.id = s.product_id
     WHERE s.tenant_id = v_tenant
       AND s.status = 'active'
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
  SELECT campaign_item_id, sku_id, sku_code, product_name, variant_name, unit_price, cap_qty
    FROM combined
   WHERE (
     v_term IS NULL
     OR sku_code     ILIKE '%' || v_term || '%'
     OR variant_name ILIKE '%' || v_term || '%'
     OR p_name       ILIKE '%' || v_term || '%'
     OR product_name ILIKE '%' || v_term || '%'
   )
   ORDER BY (campaign_item_id IS NULL), sort_order, product_name
   LIMIT v_lim;
END;
$$;

COMMENT ON FUNCTION public.rpc_search_skus_for_campaign(BIGINT, TEXT, INT) IS
  'Search SKUs for campaign order entry. Returns existing campaign_items + sibling SKUs (same product, status=active, not in campaign_items, campaign_item_id=NULL). UI lazy-adds chosen siblings via rpc_upsert_campaign_item.';

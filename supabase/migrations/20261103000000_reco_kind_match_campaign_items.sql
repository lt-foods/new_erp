-- ============================================================================
-- 推薦：「同品類最近開過」也看團內品項，不只看開團的主商品（Alex 2026-11-03）
--
-- 症狀：GRP-20261027-024「🍳活力早餐系列🍳」（10/28 開團中）品項含
--   (B)紅龍嚴選鮪魚罐 180g，週曆系統預選照樣推「爭鮮鮪魚罐（185g/罐）」。
-- 原因：_reco_kind_features 只用 group_buy_campaigns.product_id 的 product_kinds
--   對品類 —— 系列團的主商品品類是「早餐」，團內各 SKU 的品類（鮪魚罐、玉米罐）
--   完全看不到；同款的向量比對（recent_open）也只比主商品名。
-- 修法：同品類的團 = 主商品品類相同，或團內任一非贈品 SKU 的 variant_name
--   含該品類字（品類 ≥ 2 個字才比，避免「茶」這類單字誤中）。
--   kind_unfinished / kind_days / kind_opens_60d 都跟著吃到 → 沒結束就不推、
--   食品打 75 折、理由列出來（列品項名，例「紅龍嚴選鮪魚罐」）。
--
-- 基底：_reco_kind_features 20261101000220（之後沒有人改過）。
-- Rollback：重跑 20261101000220 裡的 _reco_kind_features。
-- 套用後：UPDATE reco_predictions SET computed_at = '-infinity';
--         SELECT reco_refresh_predictions(1000); 再重排預選。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._reco_kind_features(p_tenant UUID, p_kind TEXT, p_before TIMESTAMPTZ, p_asof BOOLEAN)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH g0 AS (
    SELECT g.id, g.start_at, g.status, p.name,
           EXISTS (SELECT 1 FROM product_kinds k
                    WHERE k.product_id = g.product_id AND k.tenant_id = p_tenant AND k.kind = p_kind) AS by_product,
           (SELECT regexp_replace(s.variant_name, '^\s*[\(（][A-Za-z0-9]+[\)）]\s*', '')
              FROM campaign_items ci JOIN skus s ON s.id = ci.sku_id
             WHERE ci.campaign_id = g.id AND NOT COALESCE(ci.is_gift, FALSE)
               AND char_length(p_kind) >= 2 AND strpos(s.variant_name, p_kind) > 0
             ORDER BY ci.sort_order NULLS LAST, ci.id
             LIMIT 1) AS item_name
      FROM group_buy_campaigns g
      JOIN products p ON p.id = g.product_id
     WHERE p_kind IS NOT NULL AND g.tenant_id = p_tenant
       AND g.owner_store_id IS NULL AND g.status <> 'cancelled'
       AND g.start_at >= p_before - interval '180 days'
       AND (g.status <> 'draft' OR (NOT p_asof AND g.start_at < p_before + interval '14 days'))
  ), g AS (
    SELECT g0.id, g0.start_at, g0.status,
           CASE WHEN g0.by_product THEN g0.name ELSE g0.item_name END AS name,
           EXISTS (SELECT 1 FROM customer_orders co
                    WHERE co.campaign_id = g0.id AND co.status IN ('ready', 'partially_completed', 'completed')) AS arrived
      FROM g0
     WHERE g0.by_product OR g0.item_name IS NOT NULL
  ), done AS (
    SELECT * FROM g WHERE g.status <> 'draft' AND g.start_at < p_before
  ), last AS (
    SELECT * FROM done ORDER BY start_at DESC LIMIT 1
  ), unf AS (
    SELECT * FROM g
     WHERE CASE WHEN p_asof
                THEN g.status <> 'draft' AND g.start_at < p_before AND g.start_at >= p_before - interval '10 days'
                ELSE g.start_at >= p_before - interval '45 days'
                     AND (g.status IN ('draft', 'open', 'closed') OR NOT g.arrived)
           END
  )
  SELECT CASE WHEN p_kind IS NULL THEN jsonb_build_object('kind', NULL) ELSE jsonb_build_object(
    'kind', p_kind,
    'kind_days', (SELECT ((p_before AT TIME ZONE 'Asia/Taipei')::date - (start_at AT TIME ZONE 'Asia/Taipei')::date) FROM last),
    'kind_last_name', (SELECT name FROM last),
    'kind_last_date', (SELECT (start_at AT TIME ZONE 'Asia/Taipei')::date FROM last),
    'kind_opens_60d', (SELECT count(*) FROM done WHERE start_at >= p_before - interval '60 days'),
    'kind_unfinished', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'name', name, 'start', (start_at AT TIME ZONE 'Asia/Taipei')::date,
                          'status', status, 'arrived', arrived) ORDER BY start_at) FROM unf), '[]'::jsonb))
  END;
$$;
REVOKE ALL ON FUNCTION public._reco_kind_features(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- rpc_resync_campaign_from_product — 權限收緊為「僅管理員」
--
--   20260620000010 原本 gate 是 HQ 層（owner/admin/hq_manager/hq_accountant/''）。
--   使用者要求（2026-05-20）：重新同步只給管理員，hq_manager / hq_accountant
--   / 店家一律拒絕（UI 藏鈕同時 server-side 也要 enforce）。
--
--   本 migration 以 CREATE OR REPLACE 重貼整個函式，兩處差異：
--     1. 權限收緊：v_role NOT IN ('owner','admin','')  ← '' = legacy/dev admin
--        （10 是 HQ：含 hq_manager/hq_accountant）
--     2. 修 role 讀取路徑 BUG：10（及 8f56463）誤用 auth.jwt() ->> 'role'，
--        該頂層 claim 對登入者一律是 'authenticated' → 連管理員都被擋。
--        改讀 auth.jwt() -> 'app_metadata' ->> 'role'（canonical，
--        對齊 20260502010000 / 20260513000007 / 20260605000004）。
--   其餘行為（draft/open 限定、active SKU 缺零售價拒跑不寫 0、待確認訂單
--   回填、dry_run 預覽、稽核）與 10 完全相同。
--
--   Scope: 僅 CREATE OR REPLACE FUNCTION + GRANT
--   Rollback: 重新 apply 20260620000010（還原成 HQ gate）
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_resync_campaign_from_product(
  p_campaign_id BIGINT,
  p_dry_run     BOOLEAN DEFAULT TRUE,
  p_operator    UUID    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  -- ⚠ 業務 role 在 app_metadata.role；JWT 頂層 role 對 admin 是 'authenticated'
  -- （沿用 20260502010000 / 20260513000007 等的 canonical path，別用 auth.jwt()->>'role'）
  v_role      TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_op        UUID := COALESCE(p_operator, auth.uid());
  v_camp      group_buy_campaigns%ROWTYPE;
  v_prod_name TEXT;
  v_bad_cnt   INT;
  v_bad_list  TEXT;
  v_name_changed   BOOLEAN := FALSE;
  v_items_repriced INT := 0;
  v_skus_added     INT := 0;
  v_orders         INT := 0;
  v_lines          INT := 0;
  v_amt_before     NUMERIC := 0;
  v_amt_after      NUMERIC := 0;
  v_items_json     JSONB;
  v_result         JSONB;
BEGIN
  -- ---------- 權限：僅管理員 ----------
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  -- 僅管理員（owner/admin；'' = legacy/dev admin，對齊 reference_admin_jwt_role_null）
  -- hq_manager / hq_accountant / 店家一律拒絕
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION '權限不足：僅管理員可重新同步開團（role=%）', v_role;
  END IF;

  -- ---------- 開團 + 狀態守門 ----------
  SELECT * INTO v_camp
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF v_camp.id IS NULL THEN
    RAISE EXCEPTION 'campaign % 不在 tenant 內', p_campaign_id;
  END IF;
  IF v_camp.status NOT IN ('draft','open') THEN
    RAISE EXCEPTION '只有草稿/開團中的開團可以重新同步（目前狀態：%）', v_camp.status;
  END IF;

  -- ---------- 守門：已在 campaign_items 的 active SKU 必須都有有效零售價 ----------
  SELECT COUNT(*),
         string_agg(s.sku_code, ', ' ORDER BY s.sku_code)
    INTO v_bad_cnt, v_bad_list
    FROM campaign_items ci
    JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
   WHERE ci.campaign_id = p_campaign_id
     AND ci.tenant_id   = v_tenant
     AND s.status = 'active'
     AND COALESCE((
           SELECT pr.price FROM prices pr
            WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
              AND pr.scope = 'retail' AND pr.effective_to IS NULL
            ORDER BY pr.effective_from DESC LIMIT 1
         ), 0) <= 0;
  IF v_bad_cnt > 0 THEN
    RAISE EXCEPTION '仍有 % 個 active SKU 沒有有效零售價，請先到商品頁設定售價（避免回填成 0）：%',
      v_bad_cnt, v_bad_list;
  END IF;

  -- ---------- 名稱 ----------
  IF v_camp.product_id IS NOT NULL THEN
    SELECT name INTO v_prod_name
      FROM products WHERE id = v_camp.product_id AND tenant_id = v_tenant;
  END IF;
  v_name_changed := (v_prod_name IS NOT NULL AND v_prod_name IS DISTINCT FROM v_camp.name);

  -- ---------- 預覽數字（mutation 前算好，預覽 / 實跑共用）----------
  SELECT COUNT(*),
         jsonb_agg(jsonb_build_object(
           'sku_id', t.sku_id, 'sku_code', t.sku_code,
           'old_price', t.old_price, 'new_price', t.new_price
         ) ORDER BY t.sku_code)
    INTO v_items_repriced, v_items_json
    FROM (
      SELECT ci.sku_id, s.sku_code, ci.unit_price AS old_price,
             (SELECT pr.price FROM prices pr
               WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
                 AND pr.scope = 'retail' AND pr.effective_to IS NULL
               ORDER BY pr.effective_from DESC LIMIT 1) AS new_price
        FROM campaign_items ci
        JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
       WHERE ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
         AND s.status = 'active'
    ) t
   WHERE t.old_price IS DISTINCT FROM t.new_price;

  SELECT COUNT(*) INTO v_skus_added
    FROM skus s
   WHERE v_camp.product_id IS NOT NULL
     AND s.tenant_id  = v_tenant
     AND s.product_id = v_camp.product_id
     AND s.status     = 'active'
     AND NOT EXISTS (SELECT 1 FROM campaign_items ci
                      WHERE ci.campaign_id = p_campaign_id
                        AND ci.tenant_id = v_tenant AND ci.sku_id = s.id)
     AND COALESCE((
           SELECT pr.price FROM prices pr
            WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
              AND pr.scope = 'retail' AND pr.effective_to IS NULL
            ORDER BY pr.effective_from DESC LIMIT 1
         ), 0) > 0;

  -- 受影響的「待確認」訂單：只算單價真的會變的明細與其訂單
  SELECT COUNT(DISTINCT co.id) FILTER (
           WHERE coi.unit_price IS DISTINCT FROM rc.new_price),
         COUNT(*) FILTER (
           WHERE coi.unit_price IS DISTINCT FROM rc.new_price)
    INTO v_orders, v_lines
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN LATERAL (
      SELECT (SELECT pr.price FROM prices pr
                WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                  AND pr.scope = 'retail' AND pr.effective_to IS NULL
                ORDER BY pr.effective_from DESC LIMIT 1) AS new_price
    ) rc ON TRUE
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending';

  SELECT
    COALESCE(SUM(coi.qty * coi.unit_price), 0),
    COALESCE(SUM(coi.qty * COALESCE(
       CASE WHEN s.status = 'active' THEN
         (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1)
       END, coi.unit_price)), 0)
    INTO v_amt_before, v_amt_after
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending';

  v_result := jsonb_build_object(
    'dry_run',             p_dry_run,
    'campaign_id',         p_campaign_id,
    'campaign_no',         v_camp.campaign_no,
    'campaign_status',     v_camp.status,
    'name_before',         v_camp.name,
    'name_after',          COALESCE(v_prod_name, v_camp.name),
    'name_changed',        v_name_changed,
    'items',               COALESCE(v_items_json, '[]'::jsonb),
    'items_repriced',      v_items_repriced,
    'skus_added',          v_skus_added,
    'pending_orders',      v_orders,
    'pending_order_lines', v_lines,
    'amount_before',       v_amt_before,
    'amount_after',        v_amt_after
  );

  IF p_dry_run THEN
    RETURN v_result;
  END IF;

  -- ================= 實跑（單一交易，出錯全 rollback）=================

  IF v_name_changed THEN
    UPDATE group_buy_campaigns
       SET name = v_prod_name, updated_at = NOW()
     WHERE id = p_campaign_id AND tenant_id = v_tenant;
  END IF;

  UPDATE campaign_items ci
     SET unit_price = (SELECT pr.price FROM prices pr
                         WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
                           AND pr.scope = 'retail' AND pr.effective_to IS NULL
                         ORDER BY pr.effective_from DESC LIMIT 1),
         updated_at = NOW(),
         updated_by = v_op
    FROM skus s
   WHERE ci.sku_id = s.id AND s.tenant_id = ci.tenant_id
     AND ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
     AND s.status = 'active'
     AND ci.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  INSERT INTO campaign_items
    (tenant_id, campaign_id, sku_id, unit_price, sort_order, created_by, updated_by)
  SELECT v_tenant, p_campaign_id, s.id,
         (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1),
         999, v_op, v_op
    FROM skus s
   WHERE v_camp.product_id IS NOT NULL
     AND s.tenant_id  = v_tenant
     AND s.product_id = v_camp.product_id
     AND s.status     = 'active'
     AND NOT EXISTS (SELECT 1 FROM campaign_items ci
                      WHERE ci.campaign_id = p_campaign_id
                        AND ci.tenant_id = v_tenant AND ci.sku_id = s.id)
     AND COALESCE((SELECT pr.price FROM prices pr
                    WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
                      AND pr.scope = 'retail' AND pr.effective_to IS NULL
                    ORDER BY pr.effective_from DESC LIMIT 1), 0) > 0
  ON CONFLICT (campaign_id, sku_id) DO NOTHING;

  -- 先寫稽核（讀 mutation 前的 before 值）
  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  SELECT co.tenant_id, co.id, 'item', coi.id, 'unit_price',
         to_jsonb(coi.unit_price),
         to_jsonb((SELECT pr.price FROM prices pr
                     WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                       AND pr.scope = 'retail' AND pr.effective_to IS NULL
                     ORDER BY pr.effective_from DESC LIMIT 1)),
         '開團「重新同步商品/價格」批次回填（待確認訂單）',
         COALESCE(v_op, co.updated_by, co.created_by, v_camp.created_by)
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending'
     AND coi.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  -- 再回填待確認訂單明細單價
  UPDATE customer_order_items coi
     SET unit_price = (SELECT pr.price FROM prices pr
                         WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                           AND pr.scope = 'retail' AND pr.effective_to IS NULL
                         ORDER BY pr.effective_from DESC LIMIT 1),
         updated_at = NOW(),
         updated_by = v_op
    FROM customer_orders co, skus s
   WHERE coi.order_id = co.id
     AND s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
     AND co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending'
     AND coi.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  RETURN v_result || jsonb_build_object('applied', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_resync_campaign_from_product(BIGINT, BOOLEAN, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_resync_campaign_from_product(BIGINT, BOOLEAN, UUID) IS
  '開團重新同步：名稱←product、campaign_items 單價←現行零售價、補 active SKU、'
  '回填 status=pending 訂單明細並寫 customer_order_audit_log。'
  'draft/open 限定、僅管理員(owner/admin) 限定、active SKU 缺有效零售價則拒跑、p_dry_run 預設只預覽。';

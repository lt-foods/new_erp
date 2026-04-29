-- ============================================================================
-- 修正 rpc_create_picking_wave 撞 unique constraint
--
-- Bug：
--   原本 INSERT picking_wave_items 的 GROUP BY 含 ci.campaign_id，
--   但 unique constraint 是 (wave_id, sku_id, store_id) 不含 campaign。
--   當 2 個以上 campaigns 共用同 SKU、同分店訂單時，會產生多筆 (wave, sku, store)
--   觸發：duplicate key value violates unique constraint
--   "picking_wave_items_wave_id_sku_id_store_id_key"
--
-- 修正：
--   GROUP BY 移除 ci.campaign_id；qty 用 SUM 跨 campaign 累加。
--   campaign_id 保留 MIN(ci.campaign_id) 作代表（用於 v_pr_progress 粗略歸屬）。
--   多 campaign 共 SKU+store 時會歸到 MIN id 的那張 PR，可接受的計算精度損失。
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_create_picking_wave(
  p_tenant_id   UUID,
  p_campaign_ids BIGINT[],
  p_wave_date   DATE,
  p_wave_code   TEXT,
  p_operator    UUID
) RETURNS BIGINT AS $$
DECLARE
  v_wave_id     BIGINT;
  v_item_count  INTEGER;
  v_store_count INTEGER;
  v_total_qty   NUMERIC(18,3);
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('picking_wave:create:' || p_tenant_id::text));

  INSERT INTO picking_waves (tenant_id, wave_code, wave_date, status, created_by, updated_by)
  VALUES (p_tenant_id, p_wave_code, p_wave_date, 'draft', p_operator, p_operator)
  RETURNING id INTO v_wave_id;

  -- 跨 campaign 同 (sku, store) 合併 qty；campaign_id 取 MIN 作代表
  INSERT INTO picking_wave_items (
    tenant_id, wave_id, sku_id, store_id, qty, campaign_id, created_by, updated_by
  )
  SELECT p_tenant_id, v_wave_id, coi.sku_id, co.pickup_store_id,
         SUM(coi.qty), MIN(ci.campaign_id), p_operator, p_operator
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    JOIN campaign_items ci ON ci.id = coi.campaign_item_id
   WHERE ci.campaign_id = ANY(p_campaign_ids)
     AND coi.tenant_id = p_tenant_id
     AND coi.status IN ('pending','reserved')
   GROUP BY coi.sku_id, co.pickup_store_id
  HAVING SUM(coi.qty) > 0;

  SELECT COUNT(*),
         COUNT(DISTINCT store_id),
         COALESCE(SUM(qty), 0)
    INTO v_item_count, v_store_count, v_total_qty
    FROM picking_wave_items
   WHERE wave_id = v_wave_id;

  UPDATE picking_waves
     SET item_count = v_item_count,
         store_count = v_store_count,
         total_qty = v_total_qty
   WHERE id = v_wave_id;

  INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, created_by)
  VALUES (p_tenant_id, v_wave_id, 'wave_created',
          jsonb_build_object('wave_code', p_wave_code, 'campaign_ids', p_campaign_ids,
                             'item_count', v_item_count, 'store_count', v_store_count),
          p_operator);

  RETURN v_wave_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

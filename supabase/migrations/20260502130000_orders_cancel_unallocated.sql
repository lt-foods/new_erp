-- 擴充 rpc_mark_orders_shipping_for_wave：
-- - picked_qty > 0 的 store 對應訂單 → shipping
-- - wave 涉及但 picked_qty <= 0 / NULL 的 store 對應訂單 → cancelled
--   （表示已決定不派貨給這 store，訂單視同取消）

DROP FUNCTION IF EXISTS rpc_mark_orders_shipping_for_wave(BIGINT, UUID);

CREATE OR REPLACE FUNCTION rpc_mark_orders_shipping_for_wave(
  p_wave_id  BIGINT,
  p_operator UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id UUID;
  v_wave_date DATE;
  v_wave_code TEXT;
  v_shipped   INTEGER;
  v_cancelled INTEGER;
BEGIN
  SELECT tenant_id, wave_date, wave_code INTO v_tenant_id, v_wave_date, v_wave_code
    FROM picking_waves WHERE id = p_wave_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;

  -- 1. 撿到貨 → shipping
  WITH affected AS (
    UPDATE customer_orders co
       SET status = 'shipping',
           updated_at = NOW(),
           updated_by = p_operator
      FROM group_buy_campaigns gbc
     WHERE co.tenant_id = v_tenant_id
       AND co.campaign_id = gbc.id
       AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = v_wave_date
       AND co.pickup_store_id IN (
         SELECT DISTINCT store_id
           FROM picking_wave_items
          WHERE wave_id = p_wave_id
            AND COALESCE(picked_qty, 0) > 0
       )
       AND co.status IN ('pending','confirmed','reserved')
    RETURNING co.id
  )
  SELECT COUNT(*) INTO v_shipped FROM affected;

  -- 2. wave 涉及但沒撿到 → cancelled
  WITH affected AS (
    UPDATE customer_orders co
       SET status = 'cancelled',
           notes = COALESCE(co.notes || E'\n', '') || '[auto-cancelled by ' || v_wave_code || '：沒撿到貨]',
           updated_at = NOW(),
           updated_by = p_operator
      FROM group_buy_campaigns gbc
     WHERE co.tenant_id = v_tenant_id
       AND co.campaign_id = gbc.id
       AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = v_wave_date
       AND co.pickup_store_id IN (
         SELECT DISTINCT store_id
           FROM picking_wave_items
          WHERE wave_id = p_wave_id
            AND COALESCE(picked_qty, 0) <= 0
       )
       AND co.pickup_store_id NOT IN (
         -- 安全網：若同 store 也有撿到貨的 item，就不取消
         SELECT DISTINCT store_id
           FROM picking_wave_items
          WHERE wave_id = p_wave_id
            AND COALESCE(picked_qty, 0) > 0
       )
       AND co.status IN ('pending','confirmed','reserved')
    RETURNING co.id
  )
  SELECT COUNT(*) INTO v_cancelled FROM affected;

  RETURN jsonb_build_object('shipped', v_shipped, 'cancelled', v_cancelled);
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_mark_orders_shipping_for_wave(BIGINT, UUID) TO authenticated;

-- 一次性：對 wave 12 重跑（會把 0001/0002/0003 改成 cancelled）
DO $$
DECLARE
  v_op UUID;
BEGIN
  SELECT created_by INTO v_op FROM picking_waves WHERE id = 12;
  IF v_op IS NOT NULL THEN
    PERFORM rpc_mark_orders_shipping_for_wave(12, v_op);
  END IF;
END $$;

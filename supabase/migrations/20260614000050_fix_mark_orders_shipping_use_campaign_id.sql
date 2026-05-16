-- ============================================================
-- 2026-06-14: 修 rpc_mark_orders_shipping_for_wave —
--   舊版用 `DATE(campaign.end_at @ Taipei) = wave.wave_date` 當 join
--   條件，但 wave_date 是排撿貨的日期、不一定等於 campaign 結單日。
--   結果：campaign.end_at = 2026-05-17 但 wave.wave_date = 2026-05-16
--   → join 不上 → 訂單留在 'pending'。
--
--   後續 rpc_receive_transfer 邏輯 C 只推 status='shipping' 的訂單到
--   'ready'，所以這些訂單永遠卡 pending → 顧客取不到貨、退貨流程
--   也找不到（modal 過濾 returnable 不含 pending）。
--
--   新邏輯：picking_wave_items.campaign_id 已經是真實對應，直接用
--   它對 customer_orders.campaign_id + store_id 即可，不需經 wave_date。
--
--   Backfill：
--     1. 對所有 wave (status IN shipped/received) 重跑 mark_shipping
--     2. 對所有 status='shipping' 且 strict is_order_pickup_ready=true
--        的訂單，再推到 'ready'（補 rpc_receive_transfer 漏跑的部分）
-- ============================================================

DROP FUNCTION IF EXISTS rpc_mark_orders_shipping_for_wave(BIGINT, UUID);

CREATE OR REPLACE FUNCTION rpc_mark_orders_shipping_for_wave(
  p_wave_id  BIGINT,
  p_operator UUID
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id UUID;
  v_updated   INTEGER;
BEGIN
  SELECT tenant_id INTO v_tenant_id FROM picking_waves WHERE id = p_wave_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;

  WITH affected AS (
    UPDATE customer_orders co
       SET status     = 'shipping',
           updated_at = NOW(),
           updated_by = p_operator
     WHERE co.tenant_id = v_tenant_id
       AND co.status IN ('pending','confirmed','reserved')
       AND EXISTS (
         SELECT 1 FROM picking_wave_items pwi
          WHERE pwi.wave_id    = p_wave_id
            AND pwi.picked_qty > 0
            AND pwi.campaign_id  = co.campaign_id
            AND pwi.store_id     = co.pickup_store_id
       )
    RETURNING co.id
  )
  SELECT COUNT(*) INTO v_updated FROM affected;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_mark_orders_shipping_for_wave(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_mark_orders_shipping_for_wave IS
  '把 wave 涉及的訂單（同 campaign + 同 store）從 pending/confirmed/reserved 推到 shipping。改用 picking_wave_items.campaign_id 直接對齊，不再依賴 wave_date = end_at 日。';

-- ----------------------------------------------------------------
-- Backfill A：對 status IN ('picked','shipped','received') 的 wave 重跑 mark_shipping
-- ----------------------------------------------------------------
DO $$
DECLARE
  r RECORD;
  v_uid UUID;
  v_total INTEGER := 0;
  v_one   INTEGER;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  FOR r IN
    SELECT id FROM picking_waves
     WHERE status IN ('picked','shipped','received')
     ORDER BY id
  LOOP
    v_one := rpc_mark_orders_shipping_for_wave(r.id, v_uid);
    v_total := v_total + COALESCE(v_one, 0);
  END LOOP;

  RAISE NOTICE 'Backfill A: pushed % orders from pending/confirmed/reserved → shipping', v_total;
END $$;

-- ----------------------------------------------------------------
-- Backfill B：status='shipping' 且 strict pickup_ready=true → 推到 'ready'
--   （補 rpc_receive_transfer 漏跑的 status='shipping' → 'ready' 那段）
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_uid   UUID;
  v_fixed INTEGER;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  WITH bad AS (
    SELECT co.id
      FROM customer_orders co
     WHERE co.status = 'shipping'
       AND public.is_order_pickup_ready(co.id)
  ),
  upd AS (
    UPDATE customer_orders co
       SET status     = 'ready',
           ready_at   = NOW(),
           updated_by = v_uid,
           updated_at = NOW()
     WHERE co.id IN (SELECT id FROM bad)
    RETURNING co.id
  )
  SELECT COUNT(*) INTO v_fixed FROM upd;

  RAISE NOTICE 'Backfill B: pushed % orders from shipping → ready (strict pickup_ready=true)', v_fixed;
END $$;

-- ============================================================================
-- 給 picking_waves / picking_wave_items / transfers / transfer_items / goods_receipts / goods_receipt_items
-- 加 authenticated SELECT policy（admin UI 用）
-- 既有 hq/store policy 保留
-- ============================================================================

CREATE POLICY auth_read_picking_waves ON picking_waves
  FOR SELECT TO authenticated USING (true);

CREATE POLICY auth_read_picking_wave_items ON picking_wave_items
  FOR SELECT TO authenticated USING (true);

CREATE POLICY auth_read_transfers ON transfers
  FOR SELECT TO authenticated USING (true);

CREATE POLICY auth_read_transfer_items ON transfer_items
  FOR SELECT TO authenticated USING (true);

CREATE POLICY auth_read_goods_receipts ON goods_receipts
  FOR SELECT TO authenticated USING (true);

CREATE POLICY auth_read_goods_receipt_items ON goods_receipt_items
  FOR SELECT TO authenticated USING (true);

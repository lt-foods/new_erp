-- 收貨待辦（/wms/inbound）的「總倉多給」標籤要比對 picking_wave_items 的
-- qty(應發) vs picked_qty(實撿)，查詢條件是 generated_transfer_id IN (...)。
--
-- picking_wave_items 原本只有 (wave_id) 與 (tenant_id, store_id, wave_id) 兩支索引
-- （見 20260423120002_picking_waves.sql），用 generated_transfer_id 查會走 seq scan；
-- 這張表隨每次派貨累積，而收貨頁是店家每天開最多次的頁面 → 補一支部分索引。
--
-- 部分索引：generated_transfer_id 只有「已產生調撥單」的列才有值，NULL 的不必進索引。
--
-- rollback: DROP INDEX IF EXISTS idx_wave_items_generated_transfer;

CREATE INDEX IF NOT EXISTS idx_wave_items_generated_transfer
  ON picking_wave_items (generated_transfer_id)
  WHERE generated_transfer_id IS NOT NULL;

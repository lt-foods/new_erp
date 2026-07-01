-- ============================================================================
-- stock_movements.movement_type 加入 'transfer_cancel'
--
-- Bug：rpc_cancel_aid_order（撤回派貨，shipping 狀態）在把在途貨反向退回原
-- 調出店時，呼叫 rpc_inbound(..., p_movement_type => 'transfer_cancel')，但
-- 'transfer_cancel' 不在 stock_movements_movement_type_check 允許清單裡
-- （20260512000007 只補了 'transfer_reject'）。→ 空中轉/一般轉單在途被撤回時
-- 會撞 CHECK、整筆 transaction abort，貨根本退不回原店。
-- 註：此 latent bug 自 rpc_cancel_aid_order 初版（20260510000006）就存在，
--    最新版（20260606000040 wallet_refund）沿用同一 branch，故一直沒被修到。
--
-- 修正：把 'transfer_cancel' 加入允許清單。語義對齊 'transfer_reject'（對方
-- 拒收 / 撤回後回流源點），保留獨立 type 利於審計區分「撤回」與「拒收」。
--
-- 基底：20260512000007_stock_movements_allow_transfer_reject.sql 的清單（含
--      transfer_reject），本次僅「新增」transfer_cancel，其餘值原封不動。
-- Rollback：DROP 本 constraint、CREATE OR REPLACE 回 20260512000007 的清單
--          （移除 transfer_cancel）。注意：回滾前需確認沒有已寫入的
--          transfer_cancel movement，否則 constraint 會加不回去。
-- ============================================================================

ALTER TABLE public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_movement_type_check;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_movement_type_check CHECK (
    movement_type = ANY (ARRAY[
      'purchase_receipt',
      'return_to_supplier',
      'sale',
      'customer_return',
      'transfer_out',
      'transfer_in',
      'transfer_reject',
      'transfer_cancel',
      'stocktake_gain',
      'stocktake_loss',
      'damage',
      'manual_adjust',
      'reversal'
    ])
  );

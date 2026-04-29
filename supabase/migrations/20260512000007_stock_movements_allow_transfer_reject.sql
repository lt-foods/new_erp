-- ============================================================================
-- stock_movements.movement_type 加入 'transfer_reject'
--
-- rpc_reject_transfer (20260510000007) 在反向回送庫存時會以
-- movement_type='transfer_reject' 寫 stock_movements，但
-- stock_movements_movement_type_check 沒列入該值，導致：
--   "stock_movements_movement_type_check" 違反 → reject 整個炸掉
--
-- 修正：把 transfer_reject 加入允許清單。語義對齊既有 'transfer_out' / 'transfer_in'，
-- 但 transfer_reject 是「對方拒收後回流源點」的特殊事件，保留獨立 type 利於審計。
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
      'stocktake_gain',
      'stocktake_loss',
      'damage',
      'manual_adjust',
      'reversal'
    ])
  );

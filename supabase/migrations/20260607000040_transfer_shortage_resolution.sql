-- ============================================================
-- 收貨短少處理 schema
--
-- 場景:transfer 收貨後 qty_received < qty_shipped(短收)
-- HQ / 客服需要決定怎麼處理:補出貨 / 取消客戶訂單 / 供應商求償 / 接受認賠
--
-- 1. ALTER transfer_items 加 shortage_resolution 4 欄
-- 2. 建 RPC rpc_resolve_transfer_item_shortage 讓 HQ 標記處理
--
-- TEST:
--   - transfer_items 短收 → /wms/exceptions 列出
--   - 點擊開 modal → 選 resolution → 標記 → 該 row 從 exceptions 移除
--
-- Rollback: ALTER TABLE DROP COLUMN + DROP FUNCTION
-- ============================================================

-- ----------------------------------------------------------------
-- 1. transfer_items 加 shortage_resolution
-- ----------------------------------------------------------------
ALTER TABLE transfer_items
  ADD COLUMN IF NOT EXISTS shortage_resolution TEXT
    CHECK (shortage_resolution IS NULL OR shortage_resolution IN
      ('replenish','cancel_orders','vendor_claim','accept')),
  ADD COLUMN IF NOT EXISTS shortage_resolution_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS shortage_resolution_by UUID,
  ADD COLUMN IF NOT EXISTS shortage_resolution_notes TEXT;

COMMENT ON COLUMN transfer_items.shortage_resolution IS
  '短收處理方式:replenish=補出貨/cancel_orders=取消客戶訂單/vendor_claim=供應商求償/accept=接受認賠';

CREATE INDEX IF NOT EXISTS idx_transfer_items_unresolved_shortage
  ON transfer_items (transfer_id)
  WHERE qty_received < qty_shipped AND shortage_resolution IS NULL;

-- ----------------------------------------------------------------
-- 2. rpc_resolve_transfer_item_shortage
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_resolve_transfer_item_shortage(
  p_transfer_item_id BIGINT,
  p_resolution       TEXT,
  p_notes            TEXT,
  p_operator         UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot resolve shortage', v_role;
  END IF;
  IF p_resolution NOT IN ('replenish','cancel_orders','vendor_claim','accept') THEN
    RAISE EXCEPTION 'invalid resolution: %', p_resolution;
  END IF;

  UPDATE transfer_items
     SET shortage_resolution       = p_resolution,
         shortage_resolution_at    = NOW(),
         shortage_resolution_by    = p_operator,
         shortage_resolution_notes = NULLIF(TRIM(p_notes), ''),
         updated_by                = p_operator
   WHERE id = p_transfer_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_item % not found', p_transfer_item_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_resolve_transfer_item_shortage(BIGINT, TEXT, TEXT, UUID)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_resolve_transfer_item_shortage(BIGINT, TEXT, TEXT, UUID) IS
  'HQ 處理收貨短少:標記 resolution(replenish/cancel_orders/vendor_claim/accept)+ 備註。實際補出貨/取消訂單由其他流程做。';

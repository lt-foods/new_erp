-- ============================================================
-- Phase 5c step 4 — 互助板分批扣量 RPC
--
-- 取代「partial transfer 後 client UPDATE qty_available」的做法（被 RLS 擋）
-- 統一走 SECURITY DEFINER RPC：
--   - 扣 qty_available + qty_remaining by p_qty
--   - 若 reach 0 → status='exhausted'
--   - 若 > 0 → 保持 active（可繼續被分批認領 / 提供）
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_consume_aid_board(
  p_board_id BIGINT,
  p_qty      NUMERIC,
  p_operator UUID
) RETURNS TEXT  -- 'exhausted' | 'partial'
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_qty_remaining NUMERIC;
  v_status        TEXT;
  v_new_remaining NUMERIC;
  v_new_status    TEXT;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'p_qty must be > 0';
  END IF;

  SELECT qty_remaining, status
    INTO v_qty_remaining, v_status
    FROM mutual_aid_board
   WHERE id = p_board_id
   FOR UPDATE;
  IF v_qty_remaining IS NULL THEN
    RAISE EXCEPTION 'board % not found', p_board_id;
  END IF;
  IF v_status != 'active' THEN
    RAISE EXCEPTION 'board % status=%, only active can be consumed', p_board_id, v_status;
  END IF;
  IF v_qty_remaining < p_qty THEN
    RAISE EXCEPTION 'board % insufficient qty: remaining=%, requested=%',
                    p_board_id, v_qty_remaining, p_qty;
  END IF;

  v_new_remaining := v_qty_remaining - p_qty;
  v_new_status := CASE WHEN v_new_remaining = 0 THEN 'exhausted' ELSE 'active' END;

  UPDATE mutual_aid_board
     SET qty_remaining = v_new_remaining,
         status        = v_new_status,
         updated_by    = p_operator
   WHERE id = p_board_id;

  RETURN v_new_status;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_consume_aid_board(BIGINT, NUMERIC, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_consume_aid_board IS
  'Phase 5c step 4：互助板認領 / 提供時扣 qty；reach 0 自動 exhausted、否則保持 active 可分批';

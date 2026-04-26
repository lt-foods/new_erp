-- rpc_pr_reopen：PR 退回草稿
--
-- 使用情境：PR 送審通過但發現有未指派供應商等問題，需重新編輯。
-- 守衛：只允許 status='submitted'；已拆 PO（partially/fully_ordered）禁止退回。

CREATE OR REPLACE FUNCTION rpc_pr_reopen(
  p_pr_id   BIGINT,
  p_operator UUID
) RETURNS VOID AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status INTO v_status
    FROM purchase_requests
   WHERE id = p_pr_id
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'purchase_request % not found', p_pr_id;
  END IF;

  IF v_status = 'draft' THEN
    RAISE EXCEPTION 'PR % already in draft', p_pr_id;
  END IF;

  IF v_status IN ('partially_ordered', 'fully_ordered') THEN
    RAISE EXCEPTION 'PR % already split to PO (status=%); cannot reopen', p_pr_id, v_status;
  END IF;

  IF v_status = 'cancelled' THEN
    RAISE EXCEPTION 'PR % is cancelled; cannot reopen', p_pr_id;
  END IF;

  IF v_status <> 'submitted' THEN
    RAISE EXCEPTION 'PR % cannot be reopened from status %', p_pr_id, v_status;
  END IF;

  UPDATE purchase_requests
     SET status       = 'draft',
         submitted_at = NULL,
         updated_at   = NOW(),
         updated_by   = p_operator
   WHERE id = p_pr_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION rpc_pr_reopen(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_pr_reopen(BIGINT, UUID) IS
  'PR 退回草稿：status=submitted 時可退回 draft；已拆 PO 不可退回。';

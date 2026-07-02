-- ============================================================================
-- 2026-07-02: rpc_submit_pr — 送審加品項守衛（禁空單、禁未指派供應商）
-- ----------------------------------------------------------------------------
-- 背景（PR2607020421 / pr_id=63 實案）：
--   編輯頁的「✕ 移除品項」只從前端 state 過濾、從未刪 DB 列（本次一併修前端），
--   使用者移除唯一品項後畫面看起來乾淨，前端送審驗證掃的是 state → 全過，
--   rpc_submit_pr 又無任何品項驗證，total=0 低於 threshold → 自動 approved。
--   結果：DB 裡殘留一列 suggested_supplier_id IS NULL 的品項，
--   rpc_split_pr_to_pos 的 unassigned 守衛把拆 PO 擋死，而 submitted 狀態下
--   品項已不可編輯 → 使用者「沒辦法建立採購單」，只能靠退回草稿自救。
--
-- 修法：送審時在 DB 端直接驗（不再只信前端 state）：
--   1. PR 至少要有 1 個品項
--   2. 所有品項都要已指派供應商（suggested_supplier_id NOT NULL）
--   兩者正是 rpc_split_pr_to_pos 的拆單前置條件，在送審關口就擋下，
--   避免核准後才發現拆不了單。
--
-- 基底版本：20260428120000_campaign_to_purchase.sql 的 rpc_submit_pr
--   （唯一動過此 function 的 migration；已比對線上定義一致）。
-- Rollback：重跑 20260428120000 內的 rpc_submit_pr 定義即可。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_submit_pr(
  p_pr_id    BIGINT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant       UUID;
  v_status       TEXT;
  v_review       TEXT;
  v_item_count   INTEGER;
  v_unassigned   INTEGER;
  v_total        NUMERIC(18,4);
  v_threshold    NUMERIC(18,4);
  v_new_review   TEXT;
BEGIN
  SELECT tenant_id, status, review_status INTO v_tenant, v_status, v_review
    FROM purchase_requests
   WHERE id = p_pr_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PR % not found', p_pr_id;
  END IF;

  IF v_status <> 'draft' THEN
    RAISE EXCEPTION 'PR % already submitted (status: %)', p_pr_id, v_status;
  END IF;

  -- 品項守衛：DB 實際列為準（前端 state 可能與 DB 不同步）
  SELECT COUNT(*),
         COUNT(*) FILTER (WHERE suggested_supplier_id IS NULL)
    INTO v_item_count, v_unassigned
    FROM purchase_request_items
   WHERE pr_id = p_pr_id;

  IF v_item_count = 0 THEN
    RAISE EXCEPTION '請購單沒有任何品項，無法送審；若整張不需要了請直接刪除請購單';
  END IF;

  IF v_unassigned > 0 THEN
    RAISE EXCEPTION '有 % 個品項未指派供應商，無法送審；請先指派供應商（若畫面上看不到該品項，請重新整理頁面）', v_unassigned;
  END IF;

  -- 重算 total（考慮使用者已編輯 unit_cost / qty）
  SELECT COALESCE(SUM(line_subtotal), 0) INTO v_total
    FROM purchase_request_items WHERE pr_id = p_pr_id;

  -- 套 global threshold（簡化：先支援 global scope）
  SELECT MIN(threshold_amount) INTO v_threshold
    FROM purchase_approval_thresholds
   WHERE tenant_id = v_tenant
     AND active = TRUE
     AND scope = 'global'
     AND scope_id IS NULL;

  IF v_threshold IS NOT NULL AND v_total >= v_threshold THEN
    v_new_review := 'pending_review';
  ELSE
    v_new_review := 'approved';
  END IF;

  UPDATE purchase_requests
     SET status = 'submitted',
         submitted_at = NOW(),
         total_amount = v_total,
         review_status = v_new_review,
         review_threshold_amount = v_threshold,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_pr_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_submit_pr TO authenticated;

COMMENT ON FUNCTION public.rpc_submit_pr IS
  'PR 送審：驗品項（非空、供應商已指派）→ 重算 total → 比 threshold → 設 review_status (approved / pending_review)';

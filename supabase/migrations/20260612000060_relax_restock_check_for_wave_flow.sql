-- ============================================================
-- 放寬 restock_requests_check:approved_transfer 不再強制 linked_transfer_id
--
-- 背景:
-- 原本 constraint 規定 status='approved_transfer' 必須掛 linked_transfer_id,
-- 因為舊流程「派貨」會立即建 transfer。現在改成派貨工作台 gate 模式,
-- approval 只是 status bump、transfer 由 wave 流產出,
-- linked_transfer_id 在 approval 當下是 NULL。
--
-- 改動:
-- - 移除 (status='approved_transfer' ⇒ linked_transfer_id NOT NULL) 條款
-- - approved_pr ⇒ linked_pr_id NOT NULL  仍保留
-- - rejected ⇒ rejected_reason NOT NULL  仍保留
-- ============================================================

ALTER TABLE public.restock_requests
  DROP CONSTRAINT IF EXISTS restock_requests_check;

ALTER TABLE public.restock_requests
  ADD CONSTRAINT restock_requests_check CHECK (
    (status <> 'approved_pr' OR linked_pr_id IS NOT NULL) AND
    (status <> 'rejected'    OR rejected_reason IS NOT NULL)
  );

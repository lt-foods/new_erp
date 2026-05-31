-- 會員列表 admin view：暴露 members 全欄位 + 已配單未取貨單數（PENDING_STATUSES 一致）。
-- 用途：admin 會員列表頁顯示 / 排序「已配單未取貨」欄。
--
-- 設計：
--   1. left join 聚合 customer_orders，狀態 pending/confirmed/shipping/ready
--      （與前端 PENDING_STATUSES 完全一致；未取貨金額也用這口徑）
--   2. security_invoker = true：RLS 套用 caller（admin JWT 已可讀 members + customer_orders）
--   3. 用 (member_id, status) idx_corders_member index → sort by unpicked 可走 index
--
-- 基底：首建（無歷史版本）。Rollback：DROP VIEW v_admin_member_list。

CREATE OR REPLACE VIEW public.v_admin_member_list
WITH (security_invoker = true) AS
SELECT
  m.*,
  COALESCE(uo.unpicked_order_count, 0)::int AS unpicked_order_count
FROM public.members m
LEFT JOIN (
  SELECT member_id, COUNT(*) AS unpicked_order_count
  FROM public.customer_orders
  WHERE status IN ('pending','confirmed','shipping','ready')
  GROUP BY member_id
) uo ON uo.member_id = m.id;

GRANT SELECT ON public.v_admin_member_list TO authenticated, anon;

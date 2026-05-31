-- 會員列表 admin view：暴露 members 全欄位 + 已到貨未取貨單數。
-- 用途：admin 會員列表頁顯示 / 排序「已到貨未取貨」欄。
--
-- 「已到貨未取貨」定義：
--   訂單貨已抵達取貨店、客人還沒（全部）取走。具體 status:
--     - 'ready'                — 已到貨可取
--     - 'partially_completed'  — 部分取走、剩餘品項仍在店待取
--   （與 is_order_pickup_ready() 同口徑；流程上 partially_completed 必經 ready，
--    且只有「還有未取」才會停在這個 status，全取完轉 completed）
--
-- 不算的：
--     - pending / confirmed → 貨還沒派到店（不算到貨）
--     - shipping            → 派貨中（在途）
--     - completed / cancelled / expired / transferred_out → 已結案
--
-- 設計：
--   1. security_invoker = true：RLS 套用 caller（admin JWT 已可讀 members + customer_orders）
--   2. 用 (member_id, status) idx_corders_member index → sort by unpicked 可走 index
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
  WHERE status IN ('ready','partially_completed')
  GROUP BY member_id
) uo ON uo.member_id = m.id;

GRANT SELECT ON public.v_admin_member_list TO authenticated, anon;

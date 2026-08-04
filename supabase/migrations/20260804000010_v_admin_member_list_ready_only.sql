-- v_admin_member_list.unpicked_order_count 口徑：只算「已配單未取貨」＝ ready / partially_completed。
--
-- 背景：線上 view 早就被手動改成 ready/partially_completed，但 repo 的
-- 20260701020000_v_admin_member_list.sql 仍寫著 pending/confirmed/shipping/ready
-- （4 個狀態），repo 與 prod 不同步。任何人照 repo 重跑 migration 都會把線上
-- 口徑改回去，造成「已配單未取貨」把還沒到貨的單也算進來。
-- 這支把線上的真實定義寫回 repo，並與 admin 會員列表「未取貨金額」欄同口徑
-- （apps/admin/src/app/(protected)/members/page.tsx 的 UNPICKED_STATUSES）。
--
-- 口徑說明：
--   ready               = 貨到店、等客人來取           → 算
--   partially_completed = 取了一部分、店裡還有剩       → 算
--   pending / confirmed = 還沒到貨，店裡沒有東西       → 不算
--   shipping            = 派貨中，尚未確認到店         → 不算
--
-- 基底：線上實際 view 定義（= 20260701020000 的 4 狀態版本被手改後的樣子）。
-- Rollback：把 WHERE 的狀態陣列改回
--   ARRAY['pending','confirmed','shipping','ready']（即 20260701020000 的版本）。

DROP VIEW IF EXISTS public.v_admin_member_list;

CREATE VIEW public.v_admin_member_list
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

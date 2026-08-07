-- ============================================================
-- v_admin_orders_list — /orders 列表查詢用檢視（v_admin_orders + 可排序欄位）
--
-- 動機：/orders 表格要「全部欄位都能排序」。開團名 / 會員名 / 取貨店名 /
--   項數 / 總數量 / 總金額 / 來源 都不在 customer_orders 上（前端是拿到當頁
--   50 筆後才另外抓明細彙總），所以只能排到「當頁」；要跨頁排序就必須讓
--   PostgREST 的 order 直接吃得到這些欄位 → 在伺服端 join / 彙總出來。
--
-- 為什麼開新 view、不在 v_admin_orders 尾端加欄位：
--   rpc_order_overview（tab 數量 + 月趨勢，見 20260805000130 / 20260806000020）
--   也查 v_admin_orders。品項彙總是 LATERAL 子查詢，planner 沒辦法像「可證唯一
--   的 LEFT JOIN」那樣把沒用到的 join 剪掉 —— 加在 v_admin_orders 上會讓
--   overview 的每一次全表聚合都多跑 per-row 品項彙總，把當初改 RPC 省下的
--   效能又吐回去。所以疊一層：本 view = v_admin_orders.* + join 欄位，
--   event_at 定義維持單一來源（v_admin_orders），列表與 tab 數量不會漂移。
--
-- 彙總語意對齊前端 itemSummary（orders/page.tsx）：不濾品項 status、
--   金額 = Σ qty×unit_price；source_summary 對齊 summarizeOrderSource
--   （0 種→NULL、1 種→該 source、>1 種→'mixed'）。
--   member_name = COALESCE(members.name, nickname_snapshot)，對齊列表
--   「會員 / 暱稱」欄的顯示邏輯（有會員顯示會員名，否則顯示暱稱）。
--
-- security_invoker = true：RLS 套用 caller；v_admin_orders 本身同慣例。
--
-- base：v_admin_orders @ 20260805000120（未改動該 view）
-- rollback：DROP VIEW v_admin_orders_list;
--   並把 orders/page.tsx 的 .from("v_admin_orders_list") 改回 "v_admin_orders"
--   （排序 UI 需一併退回，否則日期以外的排序鍵會 400）。
-- ============================================================

CREATE VIEW v_admin_orders_list
WITH (security_invoker = true) AS
SELECT
  o.*,
  c.name AS campaign_name,
  COALESCE(m.name, o.nickname_snapshot) AS member_name,
  s.name AS store_name,
  agg.line_count,
  agg.total_qty,
  agg.total_amount,
  agg.source_summary
FROM v_admin_orders o
LEFT JOIN group_buy_campaigns c ON c.id = o.campaign_id
LEFT JOIN members m ON m.id = o.member_id
LEFT JOIN stores s ON s.id = o.pickup_store_id
LEFT JOIN LATERAL (
  SELECT
    count(*)::int                          AS line_count,
    COALESCE(sum(i.qty), 0)                AS total_qty,
    COALESCE(sum(i.qty * i.unit_price), 0) AS total_amount,
    CASE WHEN count(DISTINCT i.source) > 1 THEN 'mixed'
         ELSE min(i.source) END            AS source_summary
  FROM customer_order_items i
  WHERE i.order_id = o.id
) agg ON true;

COMMENT ON VIEW v_admin_orders_list IS
  '/orders 列表查詢用：v_admin_orders + 可排序欄位（campaign_name / member_name / '
  'store_name / line_count / total_qty / total_amount / source_summary）。'
  '只給列表 + 選取全部用；tab 數量與趨勢的 rpc_order_overview 維持查 v_admin_orders，'
  '避免整表聚合時多揹 per-row 品項彙總。';

GRANT SELECT ON v_admin_orders_list TO authenticated;

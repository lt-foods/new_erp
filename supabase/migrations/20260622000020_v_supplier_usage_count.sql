-- ============================================================
-- v_supplier_usage_count — 廠商被指派為 PR 採購建議供應商的次數
--
-- 用途：admin /purchase/requests/edit 的廠商下拉，要把「常用」廠商
-- 排在前面、其餘按拼音。次數來源為 purchase_request_items 的
-- suggested_supplier_id 出現次數（每一個 PR item 算一次）。
--
-- RLS：view 自然套用 purchase_request_items 的 tenant 過濾政策，
-- 所以每個租戶看到自己 tenant 的計數，安全。
-- ============================================================

CREATE OR REPLACE VIEW v_supplier_usage_count AS
SELECT
  suggested_supplier_id AS supplier_id,
  COUNT(*) AS usage_count
FROM purchase_request_items
WHERE suggested_supplier_id IS NOT NULL
GROUP BY suggested_supplier_id;

GRANT SELECT ON v_supplier_usage_count TO authenticated;

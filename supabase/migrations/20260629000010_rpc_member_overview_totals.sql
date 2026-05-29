-- ============================================================
-- rpc_member_overview_totals — 會員首頁「未結金額 / 進行中筆數」聚合 (AUDIT #27)
--
-- @money-critical: 計算會員的未結金額 (receivable_amount) 與進行中訂單數。
--   顯示於 /overview 與 /me 的「未結單金額」卡片。
--   修改前請閱讀 docs/STANDARD-資料分頁與筆數限制.md §4。
--
-- 修復 AUDIT 清單 #27 (re-audit 新發現):
--   原 liff-api/index.ts:getOverview() 用
--     .from("v_customer_order_summary").select("payable_amount")...(無 limit)
--   然後後端 .reduce() 加總 → 會員 unpaid 訂單 >1000 筆時被 PostgREST
--   max_rows 靜默截斷,未結金額偏低。違反 STANDARD §4.1 (金額禁止前端/裸聚合)。
--
-- 設計: RETURNS jsonb 單列,SQL 端 SUM + COUNT,免疫 max_rows。
--   口徑對齊原 getOverview:
--     receivable: payment_status='unpaid' AND status NOT IN (cancelled,expired)
--     active:     status NOT IN (completed,cancelled,expired)
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_member_overview_totals(
  p_tenant     UUID,
  p_member_id  BIGINT
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'receivable_amount', COALESCE((
      SELECT SUM(s.payable_amount)
      FROM v_customer_order_summary s
      WHERE s.tenant_id = p_tenant
        AND s.member_id = p_member_id
        AND s.payment_status = 'unpaid'
        AND s.status NOT IN ('cancelled', 'expired')
    ), 0),
    'active_orders_count', COALESCE((
      SELECT COUNT(*)
      FROM v_customer_order_summary s
      WHERE s.tenant_id = p_tenant
        AND s.member_id = p_member_id
        AND s.status NOT IN ('completed', 'cancelled', 'expired')
    ), 0)
  );
$$;

COMMENT ON FUNCTION public.rpc_member_overview_totals(UUID, BIGINT) IS
  '@money-critical 會員未結金額/進行中筆數聚合,JSONB 單列避免 max_rows 截斷。詳見 docs/STANDARD-資料分頁與筆數限制.md';

GRANT EXECUTE ON FUNCTION public.rpc_member_overview_totals(UUID, BIGINT)
  TO anon, authenticated, service_role;

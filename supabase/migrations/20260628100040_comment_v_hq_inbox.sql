-- ============================================================
-- v_hq_inbox COMMENT (AUDIT #16)
--
-- v_hq_inbox 是 4 來源 UNION view,本身無 LIMIT。如果前端直接
-- sb.from("v_hq_inbox").select(...) 會被 PostgREST max_rows=1000 截斷。
-- 應透過 rpc_hq_inbox_keys (內建分頁) 呼叫。
--
-- 此 migration 只加 COMMENT,提醒 reviewer 與後續開發者。
-- 不修改 view 本身結構。
-- ============================================================

COMMENT ON VIEW public.v_hq_inbox IS
  '⚠️ 請勿直接透過 PostgREST 查詢此 view (會被 max_rows=1000 截斷)。改用 rpc_hq_inbox_keys() (內建分頁)。詳見 docs/STANDARD-資料分頁與筆數限制.md';

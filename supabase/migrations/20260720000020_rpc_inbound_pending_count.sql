-- ============================================================
-- 2026-07-20: 分店收貨待辦數 rpc_inbound_pending_count
--
-- 需求：分店登入時，若有已派出(shipped)還沒收的調撥單，側欄「收貨」
--   選單要掛小數字當通知（同「月結算」badge 的做法，見
--   20260715000130_rpc_settlement_action_count.sql）。
--
-- 口徑（對齊前端 /wms/inbound 的「待收」查詢與 layout isBranchUser）：
--   - 分店帳號（app_metadata.stores 非空且不含「總倉」）：
--     自己店（_jwt_store_location_ids()）為 dest_location、status='shipped'
--     的 transfers 筆數。
--   - HQ / 總倉 / 未綁店帳號 → 0（收貨 badge 只服務分店，總倉有自己的
--     收件匣與進貨待辦）。
--
-- 新函式，無歷史版本（已 grep supabase/migrations/ 確認）。
-- Rollback：DROP FUNCTION public.rpc_inbound_pending_count();
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_inbound_pending_count()
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT ARRAY(
      SELECT jsonb_array_elements_text(
        COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb))
    ) AS store_names
  )
  SELECT CASE
    -- 分店帳號 = stores 非空且不含「總倉」，對齊前端 isBranchUser()
    WHEN (SELECT cardinality(store_names) > 0
             AND NOT ('總倉' = ANY (store_names))
            FROM me) THEN (
      SELECT COUNT(*)::int
        FROM transfers t
       WHERE t.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND t.status = 'shipped'
         AND t.dest_location = ANY (public._jwt_store_location_ids())
    )
    ELSE 0
  END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_inbound_pending_count() TO authenticated;

COMMENT ON FUNCTION public.rpc_inbound_pending_count IS
  '側欄「收貨」badge 用：分店帳號回自己店 status=shipped 的待收調撥筆數；'
  'HQ/總倉/未綁店回 0。';

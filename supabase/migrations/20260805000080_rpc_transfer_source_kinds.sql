-- ============================================================
-- rpc_get_transfer_source_kinds：每張派貨單的來源類型
--   → { "<transfer_id>": "campaign" | "restock" | "free" }
--
-- 動機：收貨頁點數量看訂單時，補貨單會回「查不到對應的訂單」，店家以為是系統
--   壞了（2026-08-05 湖口店 WAVE-875-S49 的回報）。那張單的 5 條
--   picking_wave_items 的 campaign_id 全是 NULL —— 它是補貨申請產生的，
--   背後本來就沒有顧客訂單，對到的只有 order_kind='restock' 的 RR-xxx 與
--   __INTERNAL_RESTOCK__ 內部單（rpc_get_orders_for_transfer 已正確排除）。
--
-- 線上 8815 張 shipped/received 裡：8433 張有開團、191 張補貨、191 張沒有波次
--   （自由轉貨 / 互助），約 4% 會落在「查不到訂單」，值得在畫面上講清楚是哪一種。
--
--   campaign  有波次且至少一條帶 campaign_id → 開團派貨，背後有顧客訂單
--   restock   有波次但 campaign_id 全 NULL   → 補貨，本來就沒有顧客訂單
--   free      沒有任何波次行                  → 自由轉貨 / 互助 / 直送
--
-- 基底版本：新函式，無前版。
-- rollback: DROP FUNCTION IF EXISTS public.rpc_get_transfer_source_kinds(BIGINT[]);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_get_transfer_source_kinds(
  p_transfer_ids BIGINT[]
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH k AS (
    SELECT t.id AS tid,
           CASE
             WHEN COUNT(pwi.id) = 0                       THEN 'free'
             WHEN COUNT(pwi.campaign_id) = 0              THEN 'restock'
             ELSE 'campaign'
           END AS kind
      FROM transfers t
      LEFT JOIN picking_wave_items pwi ON pwi.generated_transfer_id = t.id
     WHERE t.id = ANY(p_transfer_ids)
     GROUP BY t.id
  )
  SELECT COALESCE(jsonb_object_agg(k.tid::text, k.kind), '{}'::jsonb) FROM k;
$$;

REVOKE ALL ON FUNCTION public.rpc_get_transfer_source_kinds(BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_transfer_source_kinds(BIGINT[]) TO authenticated;

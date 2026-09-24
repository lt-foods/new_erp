-- ============================================================================
-- rpc_list_supplementable_close_dates：_pr_campaign_sku_remaining_rows 改成一次批次呼叫
--
-- 背景（2026-09-24 事故調查）：DB 一週 OOM 重開 6 次，這支是當天 pg_stat_statements
-- 依總時間排第 4 的查詢（每次 ~2.5s，請購單頁每開一次打一次）。
--
-- 原因：`CROSS JOIN LATERAL _pr_campaign_sku_remaining_rows(ARRAY[ec.id])` ——
-- 一支刻意設計成吃陣列、單趟算完的批次函式，被包成 per-row LATERAL，60 天內
-- 1,737 個已結單的團就呼叫 1,737 次，每次各自掃一遍 customer_orders / PR 表
-- （CLAUDE.md「吃陣列的批次函式，不要包一層 per-row LATERAL」那條）。
--
-- 改法：只改 delta CTE —— 先 `ARRAY(SELECT id FROM eligible_campaigns)` 一次呼叫，
-- 再用 campaign_id join 回 eligible_campaigns 拿 close_date。eligible_campaigns 的
-- id 唯一（來自 group_buy_campaigns 主鍵），join 不會放大列數。
-- 其餘 CTE、輸出欄位、排序一字不動。
--
-- 實測（線上，2 個結單日）：2,277ms → 259ms；新舊逐列 to_jsonb 對拍 diff = 0。
--
-- 基底版本：20260921001000_pr_campaign_sku_delta.sql（第 969 行起）
-- Rollback：重跑該檔的 CREATE OR REPLACE FUNCTION public.rpc_list_supplementable_close_dates 段落
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_list_supplementable_close_dates()
 RETURNS TABLE(close_date date, campaign_count integer, remaining_skus integer, remaining_qty numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH t AS (
    SELECT public._current_tenant_id() AS tid
  ),
  recent_campaigns AS (
    SELECT
      gbc.id,
      DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') AS close_date
    FROM public.group_buy_campaigns gbc
    CROSS JOIN t
    WHERE gbc.tenant_id = t.tid
      AND gbc.status IN ('closed','locked')
      AND gbc.end_at >= NOW() - INTERVAL '60 days'
  ),
  eligible_campaigns AS (
    SELECT rc.id, rc.close_date
      FROM recent_campaigns rc
      CROSS JOIN t
     WHERE EXISTS (
       SELECT 1
         FROM public.purchase_requests pr
        WHERE pr.tenant_id = t.tid
          AND pr.source_type = 'close_date'
          AND pr.source_close_date = rc.close_date
          AND pr.status <> 'cancelled'
     )
     OR EXISTS (
       SELECT 1
         FROM public.purchase_requests pr
         JOIN public.purchase_request_items pri
           ON pri.pr_id = pr.id
        WHERE pr.tenant_id = t.tid
          AND pr.status <> 'cancelled'
          AND pri.source_campaign_id = rc.id
     )
     OR EXISTS (
       SELECT 1
         FROM public.purchase_requests pr
         JOIN public.purchase_request_items pri
           ON pri.pr_id = pr.id
         JOIN public.purchase_request_item_campaigns pric
           ON pric.pr_item_id = pri.id
        WHERE pr.tenant_id = t.tid
          AND pric.tenant_id = t.tid
          AND pr.status <> 'cancelled'
          AND pric.campaign_id = rc.id
     )
  ),
  -- 批次函式只呼叫一次（吃整個 eligible 陣列），再 join 回去拿 close_date；
  -- 不要改回 per-row LATERAL（1,737 次 × 全表掃描 ≈ 2.3s）。
  delta AS (
    SELECT
      ec.close_date,
      d.campaign_id,
      d.sku_id,
      d.delta_qty
    FROM public._pr_campaign_sku_remaining_rows(ARRAY(SELECT ec0.id FROM eligible_campaigns ec0)) d
    JOIN eligible_campaigns ec ON ec.id = d.campaign_id
    WHERE d.delta_qty > 0
  )
  SELECT
    del.close_date,
    (SELECT COUNT(*)::INTEGER
       FROM recent_campaigns rc
      WHERE rc.close_date = del.close_date) AS campaign_count,
    COUNT(DISTINCT del.sku_id)::INTEGER AS remaining_skus,
    COALESCE(SUM(del.delta_qty), 0) AS remaining_qty
  FROM delta del
  GROUP BY del.close_date
  ORDER BY del.close_date DESC;
$function$;

REVOKE ALL ON FUNCTION public.rpc_list_supplementable_close_dates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_list_supplementable_close_dates() TO authenticated;

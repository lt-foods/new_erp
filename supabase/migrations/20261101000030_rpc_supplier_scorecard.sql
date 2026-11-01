-- ============================================================================
-- 20261101000030_rpc_supplier_scorecard.sql
--
-- 廠商評分（docs/PLAN-選品系統-外部來源與向量媒合.md §四）。
-- 老闆要測的是「這個廠商的商品是不是都很慢到總倉 → 配貨給分店一直延後 → 客人抱怨」。
--
-- 2026-11-01 實查（近 150 天 1,590 張已收採購單）：採購送出到總倉首次收貨中位 7.3 天、
-- 三分之一超過 14 天；到總倉 29 天以上的單，連動訂單取消率 6.2%，7 天內 2～2.5%。
-- 差異在廠商不在類別：米嵐 28.5 天 / 95% 超過 14 天 / 斷貨 22% / 取消 13%；
-- 晨一 11.5 天 / 取消 1.2%。
--
-- 定義：
--   送出時間   = COALESCE(purchase_orders.sent_at, created_at)
--   到總倉時間 = 該採購單第一張非取消 goods_receipts 的 COALESCE(confirmed_at, receive_date)
--   天數       = 兩者差（只算已收過的單；斷貨單沒收貨，天數 NULL，只進斷貨率）
--   母體       = 期間內 created_at 的採購單，status IN (partially_received, fully_received, closed)
--                或 stockout_at IS NOT NULL（斷貨單）；draft / sent / cancelled 不算
--   連動訂單   = purchase_request_items.source_campaign_id → purchase_order_items.po_item_id → 該單
--                的團 → customer_orders（排除 store_internal、transferred_out）
--   取消率     = 連動訂單 status IN (cancelled, expired) 的比例
--
-- 兩支都是 LANGUAGE sql STABLE、**不是** SECURITY DEFINER：租戶隔離靠各表既有 RLS
--（同 20260809000050 的分析 RPC）。分店帳號看得到的訂單母體較小，這頁本來就是總部看的。
--
-- rollback：DROP FUNCTION public.rpc_supplier_scorecard(INT), public.rpc_supplier_scorecard_detail(BIGINT, INT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_supplier_scorecard(p_days INT DEFAULT 150)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_days, 150), 30), 365) AS days
  ),
  po AS (
    SELECT po.id, po.supplier_id, po.stockout_at,
           date_trunc('month', po.created_at AT TIME ZONE 'Asia/Taipei')::date AS mon,
           COALESCE(po.sent_at, po.created_at) AS sent,
           (SELECT min(COALESCE(gr.confirmed_at, gr.receive_date::timestamptz))
              FROM goods_receipts gr
             WHERE gr.po_id = po.id AND gr.status <> 'cancelled') AS first_rcpt
      FROM purchase_orders po
      CROSS JOIN params p
     WHERE po.created_at >= now() - (p.days * INTERVAL '1 day')
       AND (po.status IN ('partially_received', 'fully_received', 'closed') OR po.stockout_at IS NOT NULL)
  ),
  x AS (
    SELECT po.*, EXTRACT(EPOCH FROM (first_rcpt - sent)) / 86400 AS d FROM po
  ),
  pc AS (
    SELECT DISTINCT poi.po_id, pri.source_campaign_id AS campaign_id
      FROM purchase_request_items pri
      JOIN purchase_order_items poi ON poi.id = pri.po_item_id
     WHERE pri.source_campaign_id IS NOT NULL
       AND poi.po_id IN (SELECT id FROM po)
  ),
  oc AS (
    SELECT pc.po_id,
           count(*) AS orders,
           count(*) FILTER (WHERE co.status IN ('cancelled', 'expired')) AS cancelled
      FROM pc
      JOIN customer_orders co ON co.campaign_id = pc.campaign_id
      JOIN members m ON m.id = co.member_id AND m.member_type <> 'store_internal'
     WHERE co.status <> 'transferred_out'
     GROUP BY 1
  ),
  xo AS (
    SELECT x.*, COALESCE(oc.orders, 0) AS orders, COALESCE(oc.cancelled, 0) AS cancelled
      FROM x LEFT JOIN oc ON oc.po_id = x.id
  ),
  sup AS (
    SELECT s.id, s.name,
           count(*) AS pos,
           count(*) FILTER (WHERE d IS NOT NULL) AS received,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY d) FILTER (WHERE d IS NOT NULL) AS med_days,
           percentile_cont(0.9) WITHIN GROUP (ORDER BY d) FILTER (WHERE d IS NOT NULL) AS p90_days,
           count(*) FILTER (WHERE d > 14) AS over14,
           count(*) FILTER (WHERE stockout_at IS NOT NULL) AS stockouts,
           sum(orders) AS orders,
           sum(cancelled) AS cancelled,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY d)
             FILTER (WHERE d IS NOT NULL AND sent >= now() - INTERVAL '30 days') AS med_days_30d
      FROM xo JOIN suppliers s ON s.id = xo.supplier_id
     GROUP BY 1, 2
  )
  SELECT jsonb_build_object(
    'days', (SELECT days FROM params),
    'summary', (
      SELECT jsonb_build_object(
        'pos', count(*),
        'received', count(*) FILTER (WHERE d IS NOT NULL),
        'p25', round(percentile_cont(0.25) WITHIN GROUP (ORDER BY d) FILTER (WHERE d IS NOT NULL)::numeric, 1),
        'med_days', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY d) FILTER (WHERE d IS NOT NULL)::numeric, 1),
        'p75', round(percentile_cont(0.75) WITHIN GROUP (ORDER BY d) FILTER (WHERE d IS NOT NULL)::numeric, 1),
        'p90', round(percentile_cont(0.9) WITHIN GROUP (ORDER BY d) FILTER (WHERE d IS NOT NULL)::numeric, 1),
        'over14', count(*) FILTER (WHERE d > 14),
        'stockouts', count(*) FILTER (WHERE stockout_at IS NOT NULL),
        'orders', sum(orders),
        'cancelled', sum(cancelled)
      ) FROM xo),
    'buckets', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('bucket', b, 'pos', pos, 'orders', orders, 'cancelled', cancelled) ORDER BY o)
        FROM (
          SELECT CASE WHEN d <= 3 THEN '0-3 天' WHEN d <= 7 THEN '4-7 天' WHEN d <= 14 THEN '8-14 天'
                      WHEN d <= 28 THEN '15-28 天' ELSE '29 天+' END AS b,
                 CASE WHEN d <= 3 THEN 1 WHEN d <= 7 THEN 2 WHEN d <= 14 THEN 3 WHEN d <= 28 THEN 4 ELSE 5 END AS o,
                 count(*) AS pos, sum(orders) AS orders, sum(cancelled) AS cancelled
            FROM xo WHERE d IS NOT NULL GROUP BY 1, 2
        ) q), '[]'::jsonb),
    'months', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('mon', mon, 'pos', pos, 'med_days', med_days, 'over14', over14) ORDER BY mon)
        FROM (
          SELECT mon, count(*) AS pos,
                 round(percentile_cont(0.5) WITHIN GROUP (ORDER BY d)::numeric, 1) AS med_days,
                 count(*) FILTER (WHERE d > 14) AS over14
            FROM xo WHERE d IS NOT NULL GROUP BY 1
        ) q), '[]'::jsonb),
    'suppliers', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', id, 'name', name, 'pos', pos, 'received', received,
               'med_days', round(med_days::numeric, 1), 'p90_days', round(p90_days::numeric, 1),
               'over14', over14, 'stockouts', stockouts, 'orders', orders, 'cancelled', cancelled,
               'med_days_30d', round(med_days_30d::numeric, 1)
             ) ORDER BY orders DESC NULLS LAST)
        FROM sup), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_supplier_scorecard(INT) IS
  '廠商評分：採購送出→總倉首次收貨天數（中位 / P90 / >14 天）、斷貨率、連動訂單取消率、逐月趨勢。'
  '母體是期間內已收或斷貨的採購單；天數只算已收過的。';
GRANT EXECUTE ON FUNCTION public.rpc_supplier_scorecard(INT) TO authenticated;

-- 單一廠商的採購單明細
CREATE OR REPLACE FUNCTION public.rpc_supplier_scorecard_detail(p_supplier_id BIGINT, p_days INT DEFAULT 150)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_days, 150), 30), 365) AS days
  ),
  po AS (
    SELECT po.id, po.po_no, po.status, po.stockout_at,
           COALESCE(po.sent_at, po.created_at) AS sent,
           (SELECT min(COALESCE(gr.confirmed_at, gr.receive_date::timestamptz))
              FROM goods_receipts gr
             WHERE gr.po_id = po.id AND gr.status <> 'cancelled') AS first_rcpt
      FROM purchase_orders po
      CROSS JOIN params p
     WHERE po.supplier_id = p_supplier_id
       AND po.created_at >= now() - (p.days * INTERVAL '1 day')
       AND (po.status IN ('partially_received', 'fully_received', 'closed') OR po.stockout_at IS NOT NULL)
  ),
  pc AS (
    SELECT DISTINCT poi.po_id, pri.source_campaign_id AS campaign_id
      FROM purchase_request_items pri
      JOIN purchase_order_items poi ON poi.id = pri.po_item_id
     WHERE pri.source_campaign_id IS NOT NULL
       AND poi.po_id IN (SELECT id FROM po)
  ),
  oc AS (
    SELECT pc.po_id,
           count(*) AS orders,
           count(*) FILTER (WHERE co.status IN ('cancelled', 'expired')) AS cancelled,
           string_agg(DISTINCT g.name, '、') AS campaigns
      FROM pc
      JOIN group_buy_campaigns g ON g.id = pc.campaign_id
      JOIN customer_orders co ON co.campaign_id = pc.campaign_id
      JOIN members m ON m.id = co.member_id AND m.member_type <> 'store_internal'
     WHERE co.status <> 'transferred_out'
     GROUP BY 1
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', po.id, 'po_no', po.po_no, 'status', po.status,
           'sent', po.sent, 'first_rcpt', po.first_rcpt,
           'days', round((EXTRACT(EPOCH FROM (po.first_rcpt - po.sent)) / 86400)::numeric, 1),
           'stockout', po.stockout_at IS NOT NULL,
           'orders', COALESCE(oc.orders, 0), 'cancelled', COALESCE(oc.cancelled, 0),
           'campaigns', LEFT(oc.campaigns, 120)
         ) ORDER BY po.sent DESC), '[]'::jsonb)
    FROM po LEFT JOIN oc ON oc.po_id = po.id;
$function$;

COMMENT ON FUNCTION public.rpc_supplier_scorecard_detail(BIGINT, INT) IS '廠商評分 → 單一廠商的採購單明細（送出 / 到總倉 / 天數 / 斷貨 / 連動訂單）';
GRANT EXECUTE ON FUNCTION public.rpc_supplier_scorecard_detail(BIGINT, INT) TO authenticated;

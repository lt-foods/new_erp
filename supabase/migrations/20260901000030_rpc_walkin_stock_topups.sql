-- ============================================================================
-- 現場銷售：補庫存稽核報表 rpc_walkin_stock_topups
-- ============================================================================
-- 為什麼一定要有這一支：
--   rpc_create_walkin_sale 的 add_stock_qty 是全站少數「憑空生庫存」的入口
--   （同一交易內寫 manual_adjust(+N) 再賣掉）。它解掉了店員的真實困境
--   —— 架上有貨、帳上沒有、客人正站在櫃台前 —— 但沒有人看得到「補了多少」
--   的話，它就會從權宜之計變成日常，帳與實體越差越遠而沒有任何訊號。
--   CLAUDE.md 記過的幽靈庫存災情（忠順池子 ×10、松山 on_hand=0 還能取貨）
--   都是「有人默默生了貨、沒有人在看」的變體。
--
-- 查法：movement_type='manual_adjust' AND reason LIKE '現場銷售即時入帳%'。
--   單號嵌在 reason 裡（'現場銷售即時入帳 WS-1-0007（…）'），所以對得回是哪一單。
--   ⚠ 改 rpc_create_walkin_sale 的 reason 字串就會弄斷這支，兩邊要一起改。
--
-- 回傳兩塊：
--   summary[]  依 日期 × 分店 聚合（筆數 / 件數 / 幾個 SKU / 幾位操作人）
--              —— 這是「要不要排盤點」的訊號面板。
--   rows[]     明細（最多 500 列，新到舊）：時間 / 分店 / 商品 / 數量 /
--              當下在庫 / 單號 / 操作人。
--
-- 日界與參數比照 rpc_daily_pickup_settlement（20260826010000）：
--   Asia/Taipei 切日、預設今天、區間上限 92 天（超過自動夾住，避免全表掃描）。
--
-- 權限：LANGUAGE sql STABLE、**不是** SECURITY DEFINER —— 以呼叫者身分跑，
--   tenant 隔離交給 RLS（同 rpc_daily_pickup_settlement）。
--
-- 基底版本：無（新函式）。
-- Rollback：DROP FUNCTION public.rpc_walkin_stock_topups(bigint, date, date);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_walkin_stock_topups(
  p_store_id  BIGINT DEFAULT NULL,
  p_date_from DATE   DEFAULT NULL,
  p_date_to   DATE   DEFAULT NULL
) RETURNS JSONB
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH params AS (
    SELECT
      COALESCE(p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date) AS d_from,
      LEAST(
        COALESCE(p_date_to, p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date),
        COALESCE(p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date) + 92
      ) AS d_to
  ),
  bounds AS (
    SELECT (p.d_from::timestamp AT TIME ZONE 'Asia/Taipei')     AS ts_from,
           ((p.d_to + 1)::timestamp AT TIME ZONE 'Asia/Taipei') AS ts_to
      FROM params p
  ),
  topups AS (
    SELECT
      sm.id,
      sm.created_at,
      (sm.created_at AT TIME ZONE 'Asia/Taipei')::date AS ymd,
      st.id   AS store_id,
      st.name AS store_name,
      sm.sku_id,
      sm.quantity AS qty,
      sm.unit_cost,
      sm.operator_id,
      -- 單號嵌在 reason 裡（見檔頭）；抓不到就留 NULL，不要讓整列消失
      substring(sm.reason FROM 'WS-[0-9]+-[0-9]+') AS order_no,
      sk.sku_code,
      sk.product_name,
      sk.variant_name
    FROM stock_movements sm
    CROSS JOIN bounds b
    JOIN stores st ON st.location_id = sm.location_id AND st.tenant_id = sm.tenant_id
    LEFT JOIN skus sk ON sk.id = sm.sku_id
   WHERE sm.movement_type = 'manual_adjust'
     AND sm.reason LIKE '現場銷售即時入帳%'
     AND sm.created_at >= b.ts_from
     AND sm.created_at <  b.ts_to
     AND (p_store_id IS NULL OR st.id = p_store_id)
  )
  SELECT jsonb_build_object(
    'date_from', (SELECT d_from FROM params),
    'date_to',   (SELECT d_to   FROM params),
    'summary', COALESCE((
      SELECT jsonb_agg(x ORDER BY x ->> 'ymd' DESC, x ->> 'store_name')
        FROM (
          SELECT jsonb_build_object(
                   'ymd',        t.ymd,
                   'store_id',   t.store_id,
                   'store_name', t.store_name,
                   'movements',  count(*),
                   'qty',        sum(t.qty),
                   'skus',       count(DISTINCT t.sku_id),
                   'operators',  count(DISTINCT t.operator_id),
                   'orders',     count(DISTINCT t.order_no)
                 ) AS x
            FROM topups t
           GROUP BY t.ymd, t.store_id, t.store_name
        ) g
    ), '[]'::jsonb),
    'rows', COALESCE((
      SELECT jsonb_agg(y ORDER BY y ->> 'created_at' DESC)
        FROM (
          SELECT jsonb_build_object(
                   'movement_id', t.id,
                   'created_at',  t.created_at,
                   'ymd',         t.ymd,
                   'store_id',    t.store_id,
                   'store_name',  t.store_name,
                   'sku_id',      t.sku_id,
                   'sku_code',    t.sku_code,
                   'product_name', t.product_name,
                   'variant_name', t.variant_name,
                   'qty',         t.qty,
                   'unit_cost',   t.unit_cost,
                   'order_no',    t.order_no,
                   'operator_id', t.operator_id
                 ) AS y
            FROM topups t
           ORDER BY t.created_at DESC
           LIMIT 500
        ) d
    ), '[]'::jsonb),
    'rows_total', (SELECT count(*) FROM topups),
    'qty_total',  COALESCE((SELECT sum(qty) FROM topups), 0)
  );
$$;

COMMENT ON FUNCTION public.rpc_walkin_stock_topups(BIGINT, DATE, DATE) IS
  '現場銷售「結帳時補庫存」稽核報表：manual_adjust + reason 以「現場銷售即時入帳」'
  '開頭的異動，依 日期 × 分店 聚合＋明細（含單號）。常態性補帳＝帳跟實體長期'
  '脫節，該排盤點。20260901000030。';

REVOKE ALL ON FUNCTION public.rpc_walkin_stock_topups(BIGINT, DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_walkin_stock_topups(BIGINT, DATE, DATE) TO authenticated;

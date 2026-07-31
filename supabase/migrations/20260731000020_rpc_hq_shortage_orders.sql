-- ============================================================
-- rpc_hq_shortage_orders — 總倉收件匣「訂單短少」來源 server-side 分頁
--
-- 背景:
--   /hq/inbox 的 shortage 來源(fetchShortageRows)原本前端
--   `.from("v_order_shortage").limit(20000)` 把 (order × sku) 全撈,
--   client 聚合到 order 維度再切頁 — 是「假分頁」:換頁/換 stage 都
--   重新下載整包。訂單短少爆量時(修正前 8,733 張單)行動網路上
--   要載幾十秒,體感就是「這頁沒分頁」。
--
-- 解法:聚合 + stage/日期篩選 + 分頁全部搬進 DB,一次回傳
--   { total, rows(當前頁, ShortageRaw 形狀) },前端只收 20 筆。
--
-- 對齊前端(hq/inbox/page.tsx):
--   - rows 欄位 = ShortageRaw:order_id / order_no / member_id /
--     store_name / order_status / shortage_resolution /
--     shortage_notified_at / short_items[] / total_unfulfillable /
--     order_updated_at
--   - p_stage 篩選 = SHORTAGE_RESOLUTION_BY_STAGE:
--       pending    → shortage_resolution IS NULL
--       in_transit → IN ('notified','waiting_next_po')
--       done       → IN ('cancelled','reallocated')
--       其他值     → 空(standby / rejected 前端本來就直接回空)
--   - 排序 = order_updated_at DESC(同原查詢)
--   - sku_label 組法與 v_hq_exceptions customer_shortage 分支一致
--
-- 慣例對齊:SECURITY DEFINER + GRANT EXECUTE TO authenticated
--   (同 rpc_hq_exceptions,20260704000020)。
--
-- 基於:v_order_shortage v3(20260731000010)。本 RPC 為新建,無前身。
-- Rollback:DROP FUNCTION public.rpc_hq_shortage_orders(text,int,int,timestamptz,timestamptz);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_hq_shortage_orders(
  p_stage     text        DEFAULT NULL,
  p_page      int         DEFAULT 1,
  p_page_size int         DEFAULT 20,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to   timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH agg AS MATERIALIZED (
    SELECT
      vos.order_id,
      MAX(vos.order_no)             AS order_no,
      MAX(vos.member_id)            AS member_id,
      MAX(vos.store_name)           AS store_name,
      MAX(vos.order_status)         AS order_status,
      MAX(vos.shortage_resolution)  AS shortage_resolution,
      MAX(vos.shortage_notified_at) AS shortage_notified_at,
      MAX(vos.order_updated_at)     AS order_updated_at,
      SUM(vos.demand_unfulfillable) AS total_unfulfillable,
      jsonb_agg(
        jsonb_build_object(
          'sku_id', vos.sku_id,
          'sku_label',
            CASE
              WHEN vos.sku_code IS NOT NULL AND vos.sku_code <> ''
                THEN vos.sku_code || ' ' || COALESCE(NULLIF(TRIM(COALESCE(vos.product_name,'') || COALESCE(' / ' || NULLIF(vos.variant_name,''), '')), ''), '品項#' || vos.sku_id::text)
              ELSE COALESCE(NULLIF(TRIM(COALESCE(vos.product_name,'') || COALESCE(' / ' || NULLIF(vos.variant_name,''), '')), ''), '品項#' || vos.sku_id::text)
            END,
          'order_qty', vos.order_qty,
          'demand_unfulfillable', vos.demand_unfulfillable
        )
        ORDER BY vos.sku_id
      )                             AS short_items
    FROM public.v_order_shortage vos
    GROUP BY vos.order_id
  ),
  filtered AS (
    SELECT * FROM agg
    WHERE CASE
            WHEN p_stage IS NULL            THEN TRUE
            WHEN p_stage = 'pending'        THEN shortage_resolution IS NULL
            WHEN p_stage = 'in_transit'     THEN shortage_resolution IN ('notified','waiting_next_po')
            WHEN p_stage = 'done'           THEN shortage_resolution IN ('cancelled','reallocated')
            ELSE FALSE
          END
      AND (p_date_from IS NULL OR order_updated_at >= p_date_from)
      AND (p_date_to   IS NULL OR order_updated_at <= p_date_to)
  ),
  page AS (
    SELECT * FROM filtered
    ORDER BY order_updated_at DESC NULLS LAST, order_id
    LIMIT  GREATEST(1, p_page_size)
    OFFSET GREATEST(0, (p_page - 1) * p_page_size)
  )
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM filtered),
    'rows', (
      SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY order_updated_at DESC NULLS LAST, order_id), '[]'::jsonb)
      FROM page
    )
  );
$$;

COMMENT ON FUNCTION public.rpc_hq_shortage_orders(text, int, int, timestamptz, timestamptz) IS
  '總倉收件匣「訂單短少」server-side 分頁:v_order_shortage 聚合到 order 維度,'
  '依 stage(shortage_resolution)/ 日期篩選後分頁,回傳 { total, rows }。';

GRANT EXECUTE ON FUNCTION public.rpc_hq_shortage_orders(text, int, int, timestamptz, timestamptz) TO authenticated;

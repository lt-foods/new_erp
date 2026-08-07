-- ============================================================
-- 總倉收件匣:每個來源都可搜尋「商品 / 品項」(server-side)
--
-- 背景:收件匣搜尋框原本是 client-side、只過濾當前頁 20 筆,
--   且大多來源搜不到品項(items_summary 只有前 4 個 SKU)。
--   異常 tab(ExceptionsContent)則完全沒有搜尋。
--
-- 解法:
--   1. rpc_hq_inbox_search — 給 restock / transfer / aid / air /
--      picking / shortage 六來源用的 server-side 搜尋。
--      套用與前端 fetcher 完全相同的 stage / 日期 / 種類篩選,
--      比對「單號 / 店名 / 備註 + 品項(sku_code / 品名 / 品相 /
--      自由轉貨 description)」,回傳 { total, ids }(當頁、新→舊)。
--      前端拿 ids 走既有 fetch*RowsByIds 補完整欄位。
--   2. rpc_hq_exceptions 追加 p_search — 比對 doc_no / sku_code /
--      sku_label / warehouse_name,搜尋套在 counts 之前,
--      各 tab 計數同步反映搜尋結果。
--
-- 基於:
--   - rpc_hq_exceptions 前身 = 20260704000020(唯一定義);
--     v_hq_exceptions 用 20260807000050 版(含 doc_id / warehouse_name)。
--   - stage 語意對齊 v_hq_inbox(20260722000020)與前端
--     hq/inbox/page.tsx 的 *_STATUS_BY_STAGE 常數。
-- Rollback:
--   DROP FUNCTION public.rpc_hq_inbox_search(text,text,text,timestamptz,timestamptz,text,text,int,int);
--   DROP FUNCTION public.rpc_hq_exceptions(text,int,int,text);
--   再重建 20260704000020 的 rpc_hq_exceptions(text,int,int)。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_hq_inbox_search — 各來源 server-side 搜尋(回當頁 ids + total)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_hq_inbox_search(
  p_source        text,
  p_q             text,
  p_stage         text DEFAULT NULL,
  p_date_from     timestamptz DEFAULT NULL,
  p_date_to       timestamptz DEFAULT NULL,
  p_transfer_kind text DEFAULT NULL,
  p_aid_status    text DEFAULT NULL,
  p_page          int DEFAULT 1,
  p_page_size     int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pat    text := '%' || COALESCE(NULLIF(TRIM(p_q), ''), '') || '%';
  v_limit  int  := GREATEST(1, p_page_size);
  v_offset int  := GREATEST(0, (p_page - 1) * p_page_size);
  v_total  int  := 0;
  v_ids    bigint[] := '{}';
BEGIN
  IF p_source = 'restock' THEN
    WITH hits AS (
      SELECT r.id, r.requested_at AS ts
      FROM restock_requests r
      LEFT JOIN stores st ON st.id = r.requesting_store_id
      WHERE (p_stage IS NULL
             OR (p_stage = 'pending'    AND r.status = 'pending' AND r.standby_at IS NULL)
             OR (p_stage = 'standby'    AND r.status = 'pending' AND r.standby_at IS NOT NULL)
             OR (p_stage = 'in_transit' AND r.status IN ('approved_transfer','approved_pr','shipped'))
             OR (p_stage = 'done'       AND r.status = 'received')
             OR (p_stage = 'rejected'   AND r.status IN ('rejected','cancelled')))
        AND (p_date_from IS NULL OR r.requested_at >= p_date_from)
        AND (p_date_to   IS NULL OR r.requested_at <= p_date_to)
        AND (
          st.name ILIKE v_pat
          OR r.notes ILIKE v_pat
          OR ('RESTOCK#' || r.id::text) ILIKE v_pat
          OR EXISTS (
            SELECT 1 FROM restock_request_lines l
            JOIN skus s ON s.id = l.sku_id
            LEFT JOIN products p ON p.id = s.product_id
            WHERE l.request_id = r.id
              AND (s.sku_code ILIKE v_pat OR s.variant_name ILIKE v_pat OR p.name ILIKE v_pat)
          )
        )
    )
    SELECT COUNT(*)::int,
           COALESCE((SELECT array_agg(id) FROM (
             SELECT id FROM hits ORDER BY ts DESC, id DESC LIMIT v_limit OFFSET v_offset
           ) pg), '{}')
    INTO v_total, v_ids
    FROM hits;

  ELSIF p_source = 'transfer' THEN
    WITH hits AS (
      SELECT t.id
      FROM transfers t
      WHERE (p_stage IS NULL
             OR (p_stage = 'pending'    AND (t.status IN ('draft','confirmed')
                                             OR (t.status = 'shipped' AND t.transfer_type = 'return_to_hq')))
             OR (p_stage = 'in_transit' AND t.status = 'shipped' AND t.transfer_type <> 'return_to_hq')
             OR (p_stage = 'done'       AND t.status = 'received')
             OR (p_stage = 'rejected'   AND t.status = 'cancelled'))
        AND (p_transfer_kind IS NULL OR p_transfer_kind = 'all' OR t.transfer_type = p_transfer_kind)
        AND (p_date_from IS NULL OR t.created_at >= p_date_from)
        AND (p_date_to   IS NULL OR t.created_at <= p_date_to)
        AND (
          t.transfer_no ILIKE v_pat
          OR t.hq_notes ILIKE v_pat
          OR t.notes ILIKE v_pat
          OR EXISTS (SELECT 1 FROM locations l
                     WHERE l.id IN (t.source_location, t.dest_location) AND l.name ILIKE v_pat)
          OR EXISTS (
            SELECT 1 FROM transfer_items ti
            LEFT JOIN skus s ON s.id = ti.sku_id
            LEFT JOIN products p ON p.id = s.product_id
            WHERE ti.transfer_id = t.id
              AND (ti.description ILIKE v_pat
                   OR s.sku_code ILIKE v_pat OR s.variant_name ILIKE v_pat OR p.name ILIKE v_pat)
          )
        )
    )
    SELECT COUNT(*)::int,
           COALESCE((SELECT array_agg(id) FROM (
             SELECT id FROM hits ORDER BY id DESC LIMIT v_limit OFFSET v_offset
           ) pg), '{}')
    INTO v_total, v_ids
    FROM hits;

  ELSIF p_source IN ('aid', 'air') THEN
    WITH hits AS (
      SELECT co.id, co.updated_at AS ts
      FROM customer_orders co
      LEFT JOIN stores st ON st.id = co.pickup_store_id
      LEFT JOIN group_buy_campaigns c ON c.id = co.campaign_id
      WHERE EXISTS (SELECT 1 FROM customer_order_items coi
                    WHERE coi.order_id = co.id AND coi.source = 'aid_transfer')
        AND (CASE WHEN p_source = 'air' THEN co.is_air_transfer IS TRUE
                  ELSE COALESCE(co.is_air_transfer, false) = false END)
        AND (p_stage IS NULL
             OR (p_stage = 'pending'    AND co.status IN ('pending','confirmed'))
             OR (p_stage = 'in_transit' AND co.status = 'shipping')
             OR (p_stage = 'done'       AND co.status IN ('ready','completed','partially_completed'))
             OR (p_stage = 'rejected'   AND co.status = 'cancelled'))
        AND (NULLIF(p_aid_status, '') IS NULL OR co.status = p_aid_status)
        AND (p_date_from IS NULL OR co.updated_at >= p_date_from)
        AND (p_date_to   IS NULL OR co.updated_at <= p_date_to)
        AND (
          co.order_no ILIKE v_pat
          OR st.name ILIKE v_pat
          OR c.campaign_no ILIKE v_pat
          OR EXISTS (
            SELECT 1 FROM customer_order_items coi
            JOIN skus s ON s.id = coi.sku_id
            LEFT JOIN products p ON p.id = s.product_id
            WHERE coi.order_id = co.id
              AND (s.sku_code ILIKE v_pat OR s.variant_name ILIKE v_pat OR p.name ILIKE v_pat)
          )
        )
    )
    SELECT COUNT(*)::int,
           COALESCE((SELECT array_agg(id) FROM (
             SELECT id FROM hits ORDER BY ts DESC, id DESC LIMIT v_limit OFFSET v_offset
           ) pg), '{}')
    INTO v_total, v_ids
    FROM hits;

  ELSIF p_source = 'picking' THEN
    WITH hits AS (
      SELECT w.id, w.created_at AS ts
      FROM picking_waves w
      LEFT JOIN purchase_orders po ON po.id = w.source_po_id
      WHERE (p_stage IS NULL
             OR (p_stage = 'pending'  AND w.status IN ('draft','picking','picked'))
             OR (p_stage = 'done'     AND w.status = 'shipped')
             OR (p_stage = 'rejected' AND w.status = 'cancelled'))
        AND (p_date_from IS NULL OR w.created_at >= p_date_from)
        AND (p_date_to   IS NULL OR w.created_at <= p_date_to)
        AND (
          w.wave_code ILIKE v_pat
          OR w.note ILIKE v_pat
          OR po.po_no ILIKE v_pat
          OR EXISTS (
            SELECT 1 FROM picking_wave_items pwi
            JOIN skus s ON s.id = pwi.sku_id
            LEFT JOIN products p ON p.id = s.product_id
            WHERE pwi.wave_id = w.id
              AND (s.sku_code ILIKE v_pat OR s.variant_name ILIKE v_pat OR p.name ILIKE v_pat)
          )
        )
    )
    SELECT COUNT(*)::int,
           COALESCE((SELECT array_agg(id) FROM (
             SELECT id FROM hits ORDER BY ts DESC, id DESC LIMIT v_limit OFFSET v_offset
           ) pg), '{}')
    INTO v_total, v_ids
    FROM hits;

  ELSIF p_source = 'shortage' THEN
    WITH agg AS (
      SELECT vos.order_id,
             MAX(vos.order_updated_at)    AS ts,
             MAX(vos.shortage_resolution) AS resolution,
             bool_or(
               vos.order_no ILIKE v_pat
               OR vos.store_name ILIKE v_pat
               OR vos.sku_code ILIKE v_pat
               OR vos.product_name ILIKE v_pat
               OR vos.variant_name ILIKE v_pat
             ) AS matched
      FROM v_order_shortage vos
      GROUP BY vos.order_id
    ), hits AS (
      SELECT order_id AS id, ts FROM agg
      WHERE matched
        AND (p_stage IS NULL
             OR (p_stage = 'pending'    AND resolution IS NULL)
             OR (p_stage = 'in_transit' AND resolution IN ('notified','waiting_next_po'))
             OR (p_stage = 'done'       AND resolution IN ('cancelled','reallocated')))
        AND (p_date_from IS NULL OR ts >= p_date_from)
        AND (p_date_to   IS NULL OR ts <= p_date_to)
    )
    SELECT COUNT(*)::int,
           COALESCE((SELECT array_agg(id) FROM (
             SELECT id FROM hits ORDER BY ts DESC, id DESC LIMIT v_limit OFFSET v_offset
           ) pg), '{}')
    INTO v_total, v_ids
    FROM hits;

  ELSE
    RAISE EXCEPTION 'rpc_hq_inbox_search: unknown p_source %', p_source;
  END IF;

  RETURN jsonb_build_object('total', v_total, 'ids', to_jsonb(v_ids));
END;
$$;

COMMENT ON FUNCTION public.rpc_hq_inbox_search(text, text, text, timestamptz, timestamptz, text, text, int, int) IS
  'HQ 收件匣 server-side 搜尋:比對單號/店名/備註 + 品項(sku_code/品名/品相/自由轉貨描述),'
  '套用與前端相同的 stage/日期/種類篩選後分頁,回傳 { total, ids }(前端再 by-id 補詳情)。';

GRANT EXECUTE ON FUNCTION public.rpc_hq_inbox_search(text, text, text, timestamptz, timestamptz, text, text, int, int) TO authenticated;

-- ----------------------------------------------------------------
-- 2. rpc_hq_exceptions — 追加 p_search(搜尋套在 counts 之前,
--    tab 計數同步反映;舊 3 參數呼叫靠 DEFAULT 相容)
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_hq_exceptions(text, int, int);

CREATE OR REPLACE FUNCTION public.rpc_hq_exceptions(
  p_type      text DEFAULT NULL,
  p_page      int  DEFAULT 1,
  p_page_size int  DEFAULT 20,
  p_search    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ex AS MATERIALIZED (
    SELECT * FROM public.v_hq_exceptions
    WHERE (NULLIF(TRIM(p_search), '') IS NULL
           OR doc_no ILIKE '%' || TRIM(p_search) || '%'
           OR sku_code ILIKE '%' || TRIM(p_search) || '%'
           OR sku_label ILIKE '%' || TRIM(p_search) || '%'
           OR warehouse_name ILIKE '%' || TRIM(p_search) || '%')
  ),
  filtered AS (
    SELECT * FROM ex
    WHERE (p_type IS NULL OR p_type = 'all' OR ex.type = p_type)
  ),
  page AS (
    SELECT * FROM filtered
    ORDER BY ts DESC NULLS LAST, row_key
    LIMIT  GREATEST(1, p_page_size)
    OFFSET GREATEST(0, (p_page - 1) * p_page_size)
  )
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM filtered),
    'counts', (
      SELECT jsonb_build_object(
        'all',               COUNT(*),
        'po_shortage',       COUNT(*) FILTER (WHERE type = 'po_shortage'),
        'po_damage',         COUNT(*) FILTER (WHERE type = 'po_damage'),
        'po_over',           COUNT(*) FILTER (WHERE type = 'po_over'),
        'transfer_short',    COUNT(*) FILTER (WHERE type = 'transfer_short'),
        'customer_shortage', COUNT(*) FILTER (WHERE type = 'customer_shortage')
      )
      FROM ex
    ),
    'rows', (
      SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY ts DESC NULLS LAST, row_key), '[]'::jsonb)
      FROM page
    )
  );
$$;

COMMENT ON FUNCTION public.rpc_hq_exceptions(text, int, int, text) IS
  '總倉收件匣異常 server-side 分頁:回傳 { total, counts(各 tab), rows(當前頁) }。'
  '20260807000060 起支援 p_search(doc_no / sku_code / sku_label / warehouse_name,counts 同步反映)。';

GRANT EXECUTE ON FUNCTION public.rpc_hq_exceptions(text, int, int, text) TO authenticated;

-- 讓 PostgREST 立即重載 schema(新函式簽名才不會吃到快取 404)
NOTIFY pgrst, 'reload schema';

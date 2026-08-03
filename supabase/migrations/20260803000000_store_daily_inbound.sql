-- ============================================================
-- 2026-08-03: 分店端「每日進貨對帳」（不用等月結才看得到金額）
--
-- 需求（楊小胖 / 1688 群組）：
--   店家當天問「今日進貨總金額多少？」——紙本出貨單只有品名數量沒有金額，
--   系統裡也只有月結對帳單送出後才看得到分店價。要讓分店隨時查
--   「當日所有品項的分店價 + 當日總金額」。
--
-- 設計：
--   - 不新增表、不改月結生成器。金額口徑跟 rpc_generate_hq_to_store_settlement
--     v4（20260801000000）逐項對齊：hq_inbound / air_in（+）、air_out /
--     return_out（−）走 _branch_price_at 分店價；free_in（+）/ free_out（−）
--     走 estimated_amount。所以每日金額加總 = 該月月結的 branch_amount
--     （不含人工調整 adjustment_amount）。
--   - 日界用 Asia/Taipei（店家認知的「今天」；對齊 repo 既有
--     DATE(x AT TIME ZONE 'Asia/Taipei') 慣例）。月結生成器的月界是 DB
--     session tz（UTC），所以跨月那天凌晨 00:00–08:00(台北) 收的貨，
--     日曆歸屬會跟月結差一天 —— 現網全量 7439 筆只有 2 筆落在此窗，
--     暫不動月結生成器（要動是另一支 migration 的事）。
--   - 權限：SECURITY DEFINER + in-RPC gate，沿用 20260715000120 的
--     _settlement_caller_is_hq() / _settlement_caller_in_store()
--     —— 分店只能查自己店，HQ 可查任一店。
--   - helper _store_inbound_lines 不對外開放（REVOKE PUBLIC），
--     只給兩支 RPC 內部用。
--
-- 基底版本：無（全新函式，不覆寫任何既有物件）
-- Rollback：
--   DROP FUNCTION public.rpc_store_inbound_day_items(BIGINT, DATE);
--   DROP FUNCTION public.rpc_store_inbound_daily_summary(BIGINT, DATE);
--   DROP FUNCTION public._store_inbound_lines(BIGINT, TIMESTAMPTZ, TIMESTAMPTZ);
-- ============================================================

-- ------------------------------------------------------------
-- 1. helper：某店在 [p_from, p_to) 之間的分店價分錄（逐行）
--    正負號與 store_monthly_settlement_items.branch_amount 一致。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._store_inbound_lines(
  p_store_id BIGINT,
  p_from     TIMESTAMPTZ,
  p_to       TIMESTAMPTZ
) RETURNS TABLE (
  transfer_id       BIGINT,
  transfer_item_id  BIGINT,
  sku_id            BIGINT,
  qty               NUMERIC,
  unit_branch_price NUMERIC,
  amount            NUMERIC,
  entry_type        TEXT,
  description       TEXT,
  received_at       TIMESTAMPTZ,
  biz_date          DATE
)
LANGUAGE sql STABLE
AS $$
  WITH st AS (
    SELECT s.id, s.tenant_id, s.location_id
      FROM public.stores s
     WHERE s.id = p_store_id
       AND s.location_id IS NOT NULL
  )
  -- A) hq_inbound：總倉進貨（+）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         bp.p, ti.qty_received * bp.p,
         'hq_inbound'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
    CROSS JOIN LATERAL (
      SELECT COALESCE(public._branch_price_at(st.tenant_id, ti.sku_id, t.received_at), 0) AS p
    ) bp
   WHERE t.transfer_type = 'hq_to_store'
     AND t.status IN ('received','closed')
     AND t.dest_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0

  UNION ALL
  -- B) air_in：空中轉入（+）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         bp.p, ti.qty_received * bp.p,
         'air_in'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
    CROSS JOIN LATERAL (
      SELECT COALESCE(public._branch_price_at(st.tenant_id, ti.sku_id, t.received_at), 0) AS p
    ) bp
   WHERE t.transfer_type = 'store_to_store'
     AND t.customer_order_id IS NOT NULL
     AND t.status IN ('received','closed')
     AND t.dest_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0

  UNION ALL
  -- C) air_out：空中轉出（−）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         bp.p, -1 * ti.qty_received * bp.p,
         'air_out'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
    CROSS JOIN LATERAL (
      SELECT COALESCE(public._branch_price_at(st.tenant_id, ti.sku_id, t.received_at), 0) AS p
    ) bp
   WHERE t.transfer_type = 'store_to_store'
     AND t.customer_order_id IS NOT NULL
     AND t.status IN ('received','closed')
     AND t.source_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0

  UNION ALL
  -- D) free_in：自由轉入（+，估價）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         0, COALESCE(ti.estimated_amount, 0),
         'free_in'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
   WHERE t.transfer_type = 'store_to_store'
     AND t.customer_order_id IS NULL
     AND t.status IN ('received','closed')
     AND t.dest_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0

  UNION ALL
  -- E) free_out：自由轉出（−，估價）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         0, -1 * COALESCE(ti.estimated_amount, 0),
         'free_out'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
   WHERE t.transfer_type = 'store_to_store'
     AND t.customer_order_id IS NULL
     AND t.status IN ('received','closed')
     AND t.source_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0

  UNION ALL
  -- F) return_out：退貨回總倉（−）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         bp.p, -1 * ti.qty_received * bp.p,
         'return_out'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
    CROSS JOIN LATERAL (
      SELECT COALESCE(public._branch_price_at(st.tenant_id, ti.sku_id, t.received_at), 0) AS p
    ) bp
   WHERE t.transfer_type = 'return_to_hq'
     AND t.status IN ('received','closed')
     AND t.source_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0
$$;

COMMENT ON FUNCTION public._store_inbound_lines(BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) IS
  '某分店在指定期間的分店價分錄逐行（口徑同月結 branch_amount，正負號一致）。'
  '內部 helper：不開放直接呼叫，只給 rpc_store_inbound_* 用。';

REVOKE ALL ON FUNCTION public._store_inbound_lines(BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;

-- ------------------------------------------------------------
-- 2. RPC：某店某月的「每日金額」彙總（日曆列表用）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_inbound_daily_summary(
  p_store_id BIGINT,
  p_month    DATE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_store       public.stores%ROWTYPE;
  v_month_start DATE := DATE_TRUNC('month', p_month)::DATE;
  v_from        TIMESTAMPTZ;
  v_to          TIMESTAMPTZ;
  v_days        JSONB;
  v_amount      NUMERIC(18,4);
  v_lines       INTEGER;
BEGIN
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;
  IF NOT (public._settlement_caller_is_hq() OR public._settlement_caller_in_store(p_store_id)) THEN
    RAISE EXCEPTION '無權查看此分店的進貨明細（store_id=%）', p_store_id;
  END IF;
  IF v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 未設定倉別（location_id），無法計算進貨金額', v_store.name;
  END IF;

  -- 台北時區的月首/次月首（helper 依 received_at timestamptz 比對）
  v_from := (v_month_start)::TIMESTAMP AT TIME ZONE 'Asia/Taipei';
  v_to   := (v_month_start + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'Asia/Taipei';

  WITH d AS (
    SELECT l.biz_date,
           COUNT(*)::INT       AS line_count,
           SUM(l.amount)       AS amount
      FROM public._store_inbound_lines(p_store_id, v_from, v_to) l
     GROUP BY l.biz_date
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'date',       d.biz_date,
      'line_count', d.line_count,
      'amount',     d.amount
    ) ORDER BY d.biz_date DESC), '[]'::jsonb),
    COALESCE(SUM(d.amount), 0),
    COALESCE(SUM(d.line_count), 0)
    INTO v_days, v_amount, v_lines
    FROM d;

  RETURN jsonb_build_object(
    'store_id',     p_store_id,
    'store_name',   v_store.name,
    'month',        to_char(v_month_start, 'YYYY-MM'),
    'days',         v_days,
    'month_amount', v_amount,
    'month_lines',  v_lines
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_store_inbound_daily_summary(BIGINT, DATE) IS
  '分店某月「每日進貨金額」彙總（分店價口徑，日界 Asia/Taipei）。'
  '月合計 = 該月月結 branch_amount（不含人工調整）。分店只能查自己店、HQ 可查全部。';

GRANT EXECUTE ON FUNCTION public.rpc_store_inbound_daily_summary(BIGINT, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 3. RPC：某店某日的進貨明細（品項 + 分店價 + 小計 + 當日總額）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_inbound_day_items(
  p_store_id BIGINT,
  p_date     DATE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_store  public.stores%ROWTYPE;
  v_from   TIMESTAMPTZ;
  v_to     TIMESTAMPTZ;
  v_items  JSONB;
  v_total  NUMERIC(18,4);
BEGIN
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;
  IF NOT (public._settlement_caller_is_hq() OR public._settlement_caller_in_store(p_store_id)) THEN
    RAISE EXCEPTION '無權查看此分店的進貨明細（store_id=%）', p_store_id;
  END IF;
  IF v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 未設定倉別（location_id），無法計算進貨金額', v_store.name;
  END IF;

  v_from := (p_date)::TIMESTAMP AT TIME ZONE 'Asia/Taipei';
  v_to   := (p_date + 1)::TIMESTAMP AT TIME ZONE 'Asia/Taipei';

  WITH l AS (
    SELECT * FROM public._store_inbound_lines(p_store_id, v_from, v_to)
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'transfer_id',       l.transfer_id,
      'transfer_no',       t.transfer_no,
      'transfer_item_id',  l.transfer_item_id,
      'sku_id',            l.sku_id,
      'sku_code',          sk.sku_code,
      'product_name',      COALESCE(sk.product_name, l.description),
      'variant_name',      sk.variant_name,
      'qty',               l.qty,
      'unit_branch_price', l.unit_branch_price,
      'amount',            l.amount,
      'entry_type',        l.entry_type,
      'description',       l.description,
      -- 分店價沒設到（貨款行卻 0 元）→ 前端標示，提醒回報總部補價
      'missing_price',     (l.entry_type IN ('hq_inbound','air_in','air_out','return_out')
                            AND l.unit_branch_price = 0),
      'received_at',       l.received_at
    ) ORDER BY l.entry_type, l.received_at, l.transfer_item_id), '[]'::jsonb),
    COALESCE(SUM(l.amount), 0)
    INTO v_items, v_total
    FROM l
    LEFT JOIN public.transfers t ON t.id = l.transfer_id
    LEFT JOIN public.skus sk     ON sk.id = l.sku_id;

  RETURN jsonb_build_object(
    'store_id',   p_store_id,
    'store_name', v_store.name,
    'date',       to_char(p_date, 'YYYY-MM-DD'),
    'items',      v_items,
    'total',      v_total
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_store_inbound_day_items(BIGINT, DATE) IS
  '分店某日進貨明細（品項/數量/分店價/小計）＋當日總金額，日界 Asia/Taipei。'
  '口徑同月結對帳單（分店價），分店只能查自己店、HQ 可查全部。';

GRANT EXECUTE ON FUNCTION public.rpc_store_inbound_day_items(BIGINT, DATE) TO authenticated;

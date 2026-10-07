-- ============================================================
-- 2026-10-07: 每日進貨對帳加「售價」與「毛利」（售價 − 分店價）
--
-- 分店（Peggy 2026-10-07 反映）：毛利只有月結對帳單看得到，一次看整個月眼睛很花，
-- 希望每日進貨那頁就能看到。口徑沿用 20260916000000 老闆定義的「分店毛利」：
--   售價（零售價，收貨／派車當下生效）− 分店價；售價取 _retail_price_at。
-- ⛔ 一樣不碰 unit_cost / line_amount：總倉成本不給分店看。
--
-- 改動：
--   1. rpc_store_inbound_daily_summary：每一天多回 retail_amount（售價小計）、
--      priced_amount（有售價那些行的分店價小計）、profit（= retail − priced）；
--      月合計同樣多回 month_retail_amount / month_profit。
--      分店價口徑的 amount / month_amount 一個字都不動（仍 = 月結貨款）。
--   2. rpc_store_inbound_day_items：每一行多回 unit_retail_price / retail_amount
--      （沒有售價、自由轉貨虛擬 SKU → NULL），尾端多回 retail_total / profit_total。
--
-- 售價行的母體比照 rpc_settlement_retail_lines：description IS NULL 的行才取售價
--（自由轉貨虛擬 SKU 行、估價行沒有售價）；正負號跟分店價小計同向
--（air_out / return_out / free_out 取負）。毛利只算「有售價的行」兩邊的差，
-- 沒售價的行分店價也不計入 priced_amount，不然缺價會被算成負毛利。
--
-- 基底版本：
--   rpc_store_inbound_daily_summary ← 20260803000000（唯一本體版本；20260901000000 只改 COMMENT）
--   rpc_store_inbound_day_items     ← 20260805000160（20260901000000 只改 COMMENT）
-- Rollback：重跑上面兩支基底裡的定義，再把 20260901000000 的兩段 COMMENT 貼回去。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 每日彙總：加售價小計 / 毛利
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
  v_retail      NUMERIC(18,4);
  v_profit      NUMERIC(18,4);
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

  WITH l AS (
    SELECT x.*,
           -- 售價小計：有售價才算，正負號同分店價小計
           CASE WHEN r.price IS NULL THEN NULL
                ELSE (CASE WHEN x.entry_type IN ('air_out','return_out','free_out') THEN -1 ELSE 1 END)
                     * x.qty * r.price
           END AS retail_amount
      FROM public._store_inbound_lines(p_store_id, v_from, v_to) x
      LEFT JOIN LATERAL (
        SELECT public._retail_price_at(v_store.tenant_id, x.sku_id, x.received_at) AS price
         WHERE x.description IS NULL
      ) r ON TRUE
  ), d AS (
    SELECT l.biz_date,
           COUNT(*)::INT                                              AS line_count,
           SUM(l.amount)                                              AS amount,
           SUM(l.retail_amount)                                       AS retail_amount,
           SUM(l.amount) FILTER (WHERE l.retail_amount IS NOT NULL)   AS priced_amount
      FROM l
     GROUP BY l.biz_date
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'date',          d.biz_date,
      'line_count',    d.line_count,
      'amount',        d.amount,
      'retail_amount', COALESCE(d.retail_amount, 0),
      'priced_amount', COALESCE(d.priced_amount, 0),
      'profit',        COALESCE(d.retail_amount, 0) - COALESCE(d.priced_amount, 0)
    ) ORDER BY d.biz_date DESC), '[]'::jsonb),
    COALESCE(SUM(d.amount), 0),
    COALESCE(SUM(d.line_count), 0),
    COALESCE(SUM(d.retail_amount), 0),
    COALESCE(SUM(d.retail_amount), 0) - COALESCE(SUM(d.priced_amount), 0)
    INTO v_days, v_amount, v_lines, v_retail, v_profit
    FROM d;

  RETURN jsonb_build_object(
    'store_id',            p_store_id,
    'store_name',          v_store.name,
    'month',               to_char(v_month_start, 'YYYY-MM'),
    'days',                v_days,
    'month_amount',        v_amount,
    'month_lines',         v_lines,
    'month_retail_amount', v_retail,
    'month_profit',        v_profit
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_store_inbound_daily_summary(BIGINT, DATE) IS
  '分店某月「每日進貨金額」彙總（分店價口徑，日界 Asia/Taipei）。'
  '月合計 = 該月月結 branch_amount（不含人工調整）。分店只能查自己店、HQ 可查全部。'
  '2026-09-01 起：總倉→分店那一段的日期＝總倉派車日（不是店家收貨日），'
  '數量＝MAX(派出量, 實收量)；店↔店訂單相關轉貨＝轉出店出貨日（2026-08-25 起）。'
  '2026-10-07 起：每日／月合計另回售價小計與毛利（售價 − 分店價，只算有售價的行）。';

-- ------------------------------------------------------------
-- 2. 單日明細：每行加售價單價 / 售價小計，尾端加售價合計 / 毛利合計
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
  v_retail NUMERIC(18,4);
  v_profit NUMERIC(18,4);
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
    SELECT x.*,
           r.price AS unit_retail_price,
           CASE WHEN r.price IS NULL THEN NULL
                ELSE (CASE WHEN x.entry_type IN ('air_out','return_out','free_out') THEN -1 ELSE 1 END)
                     * x.qty * r.price
           END AS retail_amount
      FROM public._store_inbound_lines(p_store_id, v_from, v_to) x
      LEFT JOIN LATERAL (
        SELECT public._retail_price_at(v_store.tenant_id, x.sku_id, x.received_at) AS price
         WHERE x.description IS NULL
      ) r ON TRUE
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'transfer_id',       l.transfer_id,
      'transfer_no',       t.transfer_no,
      'transfer_item_id',  l.transfer_item_id,
      'sku_id',            l.sku_id,
      -- 虛擬 SKU（自由轉貨佔位）不回編號/規格，品名改用 description
      'sku_code',          CASE WHEN COALESCE(pr.is_virtual, FALSE) THEN NULL ELSE sk.sku_code END,
      'product_name',      CASE WHEN COALESCE(pr.is_virtual, FALSE)
                                THEN COALESCE(NULLIF(btrim(l.description), ''), '自由轉貨品項')
                                ELSE COALESCE(sk.product_name, NULLIF(btrim(l.description), '')) END,
      'variant_name',      CASE WHEN COALESCE(pr.is_virtual, FALSE) THEN NULL ELSE sk.variant_name END,
      'qty',               l.qty,
      'unit_branch_price', l.unit_branch_price,
      'amount',            l.amount,
      -- 售價（零售價）與售價小計；沒設售價 / 自由轉貨 → NULL，前端畫「—」
      'unit_retail_price', l.unit_retail_price,
      'retail_amount',     l.retail_amount,
      'entry_type',        l.entry_type,
      'description',       l.description,
      -- 分店價沒設到（貨款行卻 0 元）→ 前端標示，提醒回報總部補價
      'missing_price',     (l.entry_type IN ('hq_inbound','air_in','air_out','return_out')
                            AND l.unit_branch_price = 0),
      'received_at',       l.received_at
    ) ORDER BY l.entry_type, l.received_at, l.transfer_item_id), '[]'::jsonb),
    COALESCE(SUM(l.amount), 0),
    COALESCE(SUM(l.retail_amount), 0),
    COALESCE(SUM(l.retail_amount), 0) - COALESCE(SUM(l.amount) FILTER (WHERE l.retail_amount IS NOT NULL), 0)
    INTO v_items, v_total, v_retail, v_profit
    FROM l
    LEFT JOIN public.transfers t ON t.id = l.transfer_id
    LEFT JOIN public.skus sk     ON sk.id = l.sku_id
    LEFT JOIN public.products pr ON pr.id = sk.product_id;

  RETURN jsonb_build_object(
    'store_id',     p_store_id,
    'store_name',   v_store.name,
    'date',         to_char(p_date, 'YYYY-MM-DD'),
    'items',        v_items,
    'total',        v_total,
    'retail_total', v_retail,
    'profit_total', v_profit
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_store_inbound_day_items(BIGINT, DATE) IS
  '分店某日進貨明細（品項/數量/分店價/小計/售價/售價小計）＋當日總金額、售價合計、毛利合計，日界 Asia/Taipei。'
  '口徑同月結對帳單（分店價），分店只能查自己店、HQ 可查全部。'
  '自由轉貨的虛擬 SKU 以 transfer_items.description 當品名，不回佔位 SKU 的編號/規格。'
  '2026-09-01 起：總倉→分店那一段的日期＝總倉派車日、數量＝MAX(派出量, 實收量)；'
  '回傳欄位 received_at 存的是「這筆帳成立的時間」，不一定是收貨時間。'
  '2026-10-07 起：售價＝_retail_price_at 於 received_at 生效的零售價；毛利＝售價 − 分店價（只算有售價的行）。';

GRANT EXECUTE ON FUNCTION public.rpc_store_inbound_daily_summary(BIGINT, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_store_inbound_day_items(BIGINT, DATE) TO authenticated;

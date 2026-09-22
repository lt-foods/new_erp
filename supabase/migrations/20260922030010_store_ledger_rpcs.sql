-- ============================================================================
-- 門市記帳本（現金帳）2/2：讀寫 RPC
-- ============================================================================
-- 搭配 20260922030000（表／RLS／權限 helper／預設科目）。
--
-- 讀：
--   rpc_store_ledger_day        單日全貌（取貨收現 ＋ 逐筆帳 ＋ 現金結算 ＋ 關帳狀態）
--   rpc_store_ledger_period     區間報表（每日一列 ＋ 分類彙總 ＋ 合計）
--   rpc_store_ledger_entry_list 逐筆明細（分頁／篩選／匯出用）
--   rpc_store_ledger_categories 科目清單（含停用，給科目管理用）
-- 寫：
--   rpc_store_ledger_save_entry / _void_entry
--   rpc_store_ledger_close_day  / _reopen_day
--   rpc_store_ledger_save_category / _delete_category
--
-- 全部 SECURITY DEFINER，第一件事都是 _store_ledger_guard(p_store_id)：
--   * tenant 由 _current_tenant_id() 決定（試用到期也擋在這裡）
--   * 店長只能碰 app_metadata.stores 對應的自己店；store_staff 全擋
--   * SECURITY DEFINER 會繞過 RLS，所以每一句 SQL 都自己帶 tenant_id 條件
--
-- ⚠ 取貨收現的口徑：**直接呼叫 rpc_daily_pickup_settlement**（不是自己再抄一份
--   picked_up 的母體）。日結報表跟記帳本在同一頁上下並排，數字只要有一點不同
--   店長就不會信任何一邊；共用同一支函式才不會因為日後改口徑而分岔。
--   只有「非現金那一小塊」（customer_orders.payment_method 目前只有現場銷售會寫，
--   線上 104/97,120 筆）是本檔自己算的 —— 現金 = 總額 − 非現金，
--   所以就算那支 slice 的母體日後漂移，**總額永遠等於日結報表**，
--   最多是現金／非現金分錯，不會出現同一頁上下兩個總數對不起來。
--
-- 錯誤訊息前綴（前端 lib/rpcError.ts 會脫掉前綴直接顯示中文）：
--   ledger_perm: / ledger_closed: / ledger_input: / ledger_not_found:
--
-- 基底版本：無（新函式）。
-- Rollback：DROP FUNCTION 本檔所有 rpc_store_ledger_* 與 _store_ledger_guard /
--   _store_ledger_sales / _store_ledger_assert_open。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 守衛：tenant ＋ 門市存在 ＋ 這個人看不看得到這家店
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._store_ledger_guard(p_store_id BIGINT)
RETURNS public.stores
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_store  public.stores%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'ledger_input: 請先選擇門市。';
  END IF;

  SELECT * INTO v_store FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger_not_found: 找不到門市 #%。', p_store_id;
  END IF;

  IF NOT public._store_ledger_can_view(p_store_id) THEN
    RAISE EXCEPTION 'ledger_perm: 記帳本只有該店店長看得到，你的帳號沒有「%」的權限。', v_store.name;
  END IF;

  RETURN v_store;
END;
$$;

REVOKE ALL ON FUNCTION public._store_ledger_guard(BIGINT) FROM PUBLIC, anon, authenticated;

-- 關帳的那一天不能再動帳（新增 / 修改 / 作廢都擋）
CREATE OR REPLACE FUNCTION public._store_ledger_assert_open(
  p_tenant   UUID,
  p_store_id BIGINT,
  p_date     DATE
)
RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM store_daily_closings
     WHERE tenant_id = p_tenant AND store_id = p_store_id
       AND closing_date = p_date AND status = 'closed'
  ) THEN
    RAISE EXCEPTION 'ledger_closed: % 已經關帳，要改帳請先在那一天按「重新開帳」。',
      to_char(p_date, 'YYYY-MM-DD');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._store_ledger_assert_open(UUID, BIGINT, DATE) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. 取貨收現：總額走 rpc_daily_pickup_settlement，非現金自己算
--    ⚠ 呼叫端必須**先**過 _store_ledger_guard —— 這支是 SECURITY DEFINER，
--      RLS 對它無效，傳什麼 store 就吐什麼 store 的營業額。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._store_ledger_sales(
  p_store_id BIGINT,
  p_from     DATE,
  p_to       DATE
)
RETURNS TABLE (
  ymd            TEXT,
  total          NUMERIC,
  noncash        NUMERIC,
  cash           NUMERIC,
  orders         INT,
  qty            NUMERIC,
  store_campaign NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH report AS (
    SELECT public.rpc_daily_pickup_settlement(p_store_id, p_from, p_to) AS j
  ),
  days AS (
    SELECT d.value ->> 'ymd'                                           AS ymd,
           COALESCE((d.value ->> 'amount')::numeric, 0)                 AS total,
           COALESCE((d.value ->> 'orders')::int, 0)                     AS orders,
           COALESCE((d.value ->> 'qty')::numeric, 0)                    AS qty,
           COALESCE((d.value ->> 'store_campaign_amount')::numeric, 0)  AS store_campaign
      FROM report r,
           LATERAL jsonb_array_elements(COALESCE(r.j -> 'days', '[]'::jsonb)) d
  ),
  noncash AS (
    SELECT to_char((i.updated_at AT TIME ZONE 'Asia/Taipei')::date, 'YYYY-MM-DD') AS ymd,
           SUM(i.qty * i.unit_price)::numeric AS amt
      FROM customer_order_items i
      JOIN customer_orders co ON co.id = i.order_id
      LEFT JOIN members m ON m.id = co.member_id
     WHERE i.status = 'picked_up'
       AND i.updated_at >= (p_from::timestamp AT TIME ZONE 'Asia/Taipei')
       AND i.updated_at <  ((p_to + 1)::timestamp AT TIME ZONE 'Asia/Taipei')
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND COALESCE(m.member_type, '') <> 'store_internal'
       AND co.pickup_store_id = p_store_id
       AND COALESCE(co.payment_method, 'cash') <> 'cash'
     GROUP BY 1
  )
  SELECT d.ymd,
         d.total,
         LEAST(COALESCE(n.amt, 0), d.total)        AS noncash,
         GREATEST(d.total - COALESCE(n.amt, 0), 0) AS cash,
         d.orders,
         d.qty,
         d.store_campaign
    FROM days d
    LEFT JOIN noncash n ON n.ymd = d.ymd;
$$;

REVOKE ALL ON FUNCTION public._store_ledger_sales(BIGINT, DATE, DATE) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._store_ledger_sales(BIGINT, DATE, DATE) IS
  '門市記帳本：某店某區間的每日取貨收現。總額直接取 rpc_daily_pickup_settlement，'
  '非現金（customer_orders.payment_method 非 cash）自己算，現金 = 總額 − 非現金。'
  '⚠ SECURITY DEFINER 無 RLS，呼叫端要先過 _store_ledger_guard。';

-- ----------------------------------------------------------------------------
-- 3. 單日全貌
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_ledger_day(
  p_store_id BIGINT,
  p_date     DATE DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store     public.stores%ROWTYPE := public._store_ledger_guard(p_store_id);
  v_tenant    UUID := v_store.tenant_id;
  v_today     DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_date      DATE := COALESCE(p_date, v_today);
  v_s_total   NUMERIC; v_s_cash NUMERIC; v_s_noncash NUMERIC;
  v_s_orders  INT;     v_s_qty  NUMERIC; v_s_self    NUMERIC;
  v_tot       RECORD;
  v_closing   public.store_daily_closings%ROWTYPE;
  v_prev      public.store_daily_closings%ROWTYPE;
  v_open      NUMERIC := 0;
  v_suggest   NUMERIC := 0;
  v_entries   jsonb;
  v_cats      jsonb;
BEGIN
  SELECT s.total, s.cash, s.noncash, s.orders, s.qty, s.store_campaign
    INTO v_s_total, v_s_cash, v_s_noncash, v_s_orders, v_s_qty, v_s_self
    FROM public._store_ledger_sales(p_store_id, v_date, v_date) s
   LIMIT 1;

  v_s_total   := COALESCE(v_s_total, 0);
  v_s_cash    := COALESCE(v_s_cash, 0);
  v_s_noncash := COALESCE(v_s_noncash, 0);
  v_s_orders  := COALESCE(v_s_orders, 0);
  v_s_qty     := COALESCE(v_s_qty, 0);
  v_s_self    := COALESCE(v_s_self, 0);

  SELECT
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'income'  AND e.payment_method =  'cash'), 0) AS income_cash,
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'income'  AND e.payment_method <> 'cash'), 0) AS income_noncash,
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'expense' AND e.payment_method =  'cash'), 0) AS expense_cash,
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'expense' AND e.payment_method <> 'cash'), 0) AS expense_noncash,
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'income'  AND COALESCE(c.affects_profit, TRUE)), 0) AS income_profit,
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'expense' AND COALESCE(c.affects_profit, TRUE)), 0) AS expense_profit,
    COUNT(*) AS cnt
    INTO v_tot
    FROM store_ledger_entries e
    LEFT JOIN store_ledger_categories c ON c.id = e.category_id
   WHERE e.tenant_id = v_tenant
     AND e.store_id = p_store_id
     AND e.entry_date = v_date
     AND e.voided_at IS NULL;

  SELECT * INTO v_closing
    FROM store_daily_closings
   WHERE tenant_id = v_tenant AND store_id = p_store_id AND closing_date = v_date;

  SELECT * INTO v_prev
    FROM store_daily_closings
   WHERE tenant_id = v_tenant AND store_id = p_store_id
     AND closing_date < v_date AND status = 'closed'
   ORDER BY closing_date DESC
   LIMIT 1;

  v_suggest := COALESCE(v_prev.counted_cash, 0);
  v_open    := CASE WHEN v_closing.id IS NOT NULL THEN v_closing.opening_cash ELSE v_suggest END;

  SELECT COALESCE(jsonb_agg(t.x ORDER BY t.ord), '[]'::jsonb)
    INTO v_entries
    FROM (
      SELECT e.created_at AS ord,
             jsonb_build_object(
               'id',             e.id,
               'entry_date',     to_char(e.entry_date, 'YYYY-MM-DD'),
               'direction',      e.direction,
               'category_id',    e.category_id,
               'category_name',  COALESCE(c.name, '（未分類）'),
               'affects_profit', COALESCE(c.affects_profit, TRUE),
               'amount',         e.amount,
               'payment_method', e.payment_method,
               'counterparty',   e.counterparty,
               'note',           e.note,
               'receipt_no',     e.receipt_no,
               'created_at',     e.created_at,
               'created_by',     u.email,
               'voided_at',      e.voided_at,
               'void_reason',    e.void_reason,
               'voided_by',      vu.email
             ) AS x
        FROM store_ledger_entries e
        LEFT JOIN store_ledger_categories c ON c.id = e.category_id
        LEFT JOIN auth.users u  ON u.id  = e.created_by
        LEFT JOIN auth.users vu ON vu.id = e.voided_by
       WHERE e.tenant_id = v_tenant
         AND e.store_id = p_store_id
         AND e.entry_date = v_date
    ) t;

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.kind, c.sort_order, c.name), '[]'::jsonb)
    INTO v_cats
    FROM (
      SELECT id, store_id, kind, name, affects_profit, is_system, sort_order
        FROM store_ledger_categories
       WHERE tenant_id = v_tenant
         AND is_active
         AND (store_id IS NULL OR store_id = p_store_id)
    ) c;

  RETURN jsonb_build_object(
    'store', jsonb_build_object('id', v_store.id, 'code', v_store.code, 'name', v_store.name),
    'date',  to_char(v_date, 'YYYY-MM-DD'),
    'today', to_char(v_today, 'YYYY-MM-DD'),
    'is_hq', public._store_ledger_is_hq(),
    'sales', jsonb_build_object(
      'total',          v_s_total,
      'cash',           v_s_cash,
      'noncash',        v_s_noncash,
      'orders',         v_s_orders,
      'qty',            v_s_qty,
      'store_campaign', v_s_self
    ),
    'totals', jsonb_build_object(
      'entries',         v_tot.cnt,
      'income_cash',     v_tot.income_cash,
      'income_noncash',  v_tot.income_noncash,
      'expense_cash',    v_tot.expense_cash,
      'expense_noncash', v_tot.expense_noncash,
      'income_profit',   v_tot.income_profit,
      'expense_profit',  v_tot.expense_profit
    ),
    'opening_cash',           v_open,
    'suggested_opening_cash', v_suggest,
    'expected_cash',          v_open + v_s_cash + v_tot.income_cash - v_tot.expense_cash,
    'profit',                 v_s_total + v_tot.income_profit - v_tot.expense_profit,
    'prev_closing', CASE WHEN v_prev.id IS NULL THEN NULL ELSE jsonb_build_object(
        'closing_date', to_char(v_prev.closing_date, 'YYYY-MM-DD'),
        'counted_cash', v_prev.counted_cash
      ) END,
    'closing',    CASE WHEN v_closing.id IS NULL THEN NULL ELSE to_jsonb(v_closing) END,
    'entries',    v_entries,
    'categories', v_cats
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_day(BIGINT, DATE) TO authenticated;
COMMENT ON FUNCTION public.rpc_store_ledger_day(BIGINT, DATE) IS
  '門市記帳本單日：取貨收現（同日結口徑）＋逐筆帳＋現金結算＋關帳狀態＋可用科目。';

-- ----------------------------------------------------------------------------
-- 4. 區間報表
--    區間上限 92 天：rpc_daily_pickup_settlement 自己就夾在 d_from + 92，
--    放寬只會讓後面幾天的營業額默默變 0。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_ledger_period(
  p_store_id  BIGINT,
  p_date_from DATE DEFAULT NULL,
  p_date_to   DATE DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store  public.stores%ROWTYPE := public._store_ledger_guard(p_store_id);
  v_tenant UUID := v_store.tenant_id;
  v_today  DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_from   DATE := COALESCE(p_date_from, date_trunc('month', v_today)::date);
  v_to     DATE;
  v_out    jsonb;
BEGIN
  v_to := LEAST(COALESCE(p_date_to, v_today), v_from + 92);
  IF v_to < v_from THEN
    v_to := v_from;
  END IF;

  WITH cal AS (
    SELECT g::date AS d, to_char(g::date, 'YYYY-MM-DD') AS ymd
      FROM generate_series(v_from, v_to, INTERVAL '1 day') g
  ),
  sales AS (
    SELECT * FROM public._store_ledger_sales(p_store_id, v_from, v_to)
  ),
  led AS (
    SELECT e.entry_date,
           COUNT(*)                                                                                  AS entries,
           COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'income'), 0)                           AS income_all,
           COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'income'  AND e.payment_method = 'cash'), 0) AS income_cash,
           COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'income'  AND COALESCE(c.affects_profit, TRUE)), 0) AS income_profit,
           COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'expense'), 0)                          AS expense_all,
           COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'expense' AND e.payment_method = 'cash'), 0) AS expense_cash,
           COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'expense' AND COALESCE(c.affects_profit, TRUE)), 0) AS expense_profit
      FROM store_ledger_entries e
      LEFT JOIN store_ledger_categories c ON c.id = e.category_id
     WHERE e.tenant_id = v_tenant AND e.store_id = p_store_id
       AND e.entry_date BETWEEN v_from AND v_to
       AND e.voided_at IS NULL
     GROUP BY e.entry_date
  ),
  base AS (
    SELECT cal.ymd,
           COALESCE(s.total, 0)          AS sales_total,
           COALESCE(s.cash, 0)           AS sales_cash,
           COALESCE(s.noncash, 0)        AS sales_noncash,
           COALESCE(l.income_all, 0)     AS income_all,
           COALESCE(l.income_cash, 0)    AS income_cash,
           COALESCE(l.income_profit, 0)  AS income_profit,
           COALESCE(l.expense_all, 0)    AS expense_all,
           COALESCE(l.expense_cash, 0)   AS expense_cash,
           COALESCE(l.expense_profit, 0) AS expense_profit,
           COALESCE(l.entries, 0)::int   AS entries,
           COALESCE(cl.status = 'closed', FALSE) AS closed,
           -- 重新開帳過（status='reopened'）的那天，關帳快照已經是舊的：
           -- 這裡一律當成「還沒關帳」不回數字，否則 diff_cash 合計會把一筆
           -- 作廢掉的盤點差異一直算進去。
           CASE WHEN cl.status = 'closed' THEN cl.counted_cash  END AS counted_cash,
           CASE WHEN cl.status = 'closed' THEN cl.expected_cash END AS expected_cash,
           CASE WHEN cl.status = 'closed' THEN cl.diff_cash     END AS diff_cash
      FROM cal
      LEFT JOIN sales s ON s.ymd = cal.ymd
      LEFT JOIN led   l ON l.entry_date = cal.d
      LEFT JOIN store_daily_closings cl
             ON cl.tenant_id = v_tenant AND cl.store_id = p_store_id AND cl.closing_date = cal.d
  ),
  cats AS (
    SELECT e.direction AS kind,
           e.category_id,
           COALESCE(c.name, '（未分類）')      AS name,
           COALESCE(c.affects_profit, TRUE)    AS affects_profit,
           SUM(e.amount)                       AS amount,
           COALESCE(SUM(e.amount) FILTER (WHERE e.payment_method = 'cash'), 0) AS cash,
           COUNT(*)::int                       AS cnt
      FROM store_ledger_entries e
      LEFT JOIN store_ledger_categories c ON c.id = e.category_id
     WHERE e.tenant_id = v_tenant AND e.store_id = p_store_id
       AND e.entry_date BETWEEN v_from AND v_to
       AND e.voided_at IS NULL
     GROUP BY e.direction, e.category_id, c.name, c.affects_profit
  )
  SELECT jsonb_build_object(
    'store',     jsonb_build_object('id', v_store.id, 'code', v_store.code, 'name', v_store.name),
    'date_from', to_char(v_from, 'YYYY-MM-DD'),
    'date_to',   to_char(v_to, 'YYYY-MM-DD'),
    'days',      COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.ymd DESC) FROM base b), '[]'::jsonb),
    'by_category', COALESCE(
      (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.kind, x.amount DESC) FROM cats x), '[]'::jsonb),
    'totals', (
      SELECT jsonb_build_object(
        'sales_total',    COALESCE(SUM(b.sales_total), 0),
        'sales_cash',     COALESCE(SUM(b.sales_cash), 0),
        'sales_noncash',  COALESCE(SUM(b.sales_noncash), 0),
        'income_all',     COALESCE(SUM(b.income_all), 0),
        'income_cash',    COALESCE(SUM(b.income_cash), 0),
        'income_profit',  COALESCE(SUM(b.income_profit), 0),
        'expense_all',    COALESCE(SUM(b.expense_all), 0),
        'expense_cash',   COALESCE(SUM(b.expense_cash), 0),
        'expense_profit', COALESCE(SUM(b.expense_profit), 0),
        'entries',        COALESCE(SUM(b.entries), 0),
        'closed_days',    COALESCE(SUM(CASE WHEN b.closed THEN 1 ELSE 0 END), 0),
        'diff_cash',      COALESCE(SUM(COALESCE(b.diff_cash, 0)), 0),
        'profit',         COALESCE(SUM(b.sales_total + b.income_profit - b.expense_profit), 0)
      ) FROM base b
    )
  ) INTO v_out;

  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_period(BIGINT, DATE, DATE) TO authenticated;
COMMENT ON FUNCTION public.rpc_store_ledger_period(BIGINT, DATE, DATE) IS
  '門市記帳本區間報表：每日一列（營業額／收支／損益／關帳）＋分類彙總＋合計。區間上限 92 天。';

-- ----------------------------------------------------------------------------
-- 5. 逐筆明細（分頁 / 篩選 / 匯出）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_ledger_entry_list(
  p_store_id       BIGINT,
  p_date_from      DATE    DEFAULT NULL,
  p_date_to        DATE    DEFAULT NULL,
  p_direction      TEXT    DEFAULT NULL,
  p_category_id    BIGINT  DEFAULT NULL,
  p_include_voided BOOLEAN DEFAULT FALSE,
  p_limit          INT     DEFAULT 50,
  p_offset         INT     DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store  public.stores%ROWTYPE := public._store_ledger_guard(p_store_id);
  v_tenant UUID := v_store.tenant_id;
  v_today  DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_from   DATE := COALESCE(p_date_from, date_trunc('month', v_today)::date);
  v_to     DATE := COALESCE(p_date_to, v_today);
  v_limit  INT  := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500);
  v_offset INT  := GREATEST(COALESCE(p_offset, 0), 0);
  v_total  INT;
  v_rows   jsonb;
BEGIN
  SELECT COUNT(*) INTO v_total
    FROM store_ledger_entries e
   WHERE e.tenant_id = v_tenant AND e.store_id = p_store_id
     AND e.entry_date BETWEEN v_from AND v_to
     AND (p_direction IS NULL OR e.direction = p_direction)
     AND (p_category_id IS NULL OR e.category_id = p_category_id)
     AND (p_include_voided OR e.voided_at IS NULL);

  SELECT COALESCE(jsonb_agg(t.x ORDER BY t.d DESC, t.id DESC), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT e.entry_date AS d,
             e.id         AS id,
             jsonb_build_object(
               'id',             e.id,
               'entry_date',     to_char(e.entry_date, 'YYYY-MM-DD'),
               'direction',      e.direction,
               'category_id',    e.category_id,
               'category_name',  COALESCE(c.name, '（未分類）'),
               'affects_profit', COALESCE(c.affects_profit, TRUE),
               'amount',         e.amount,
               'payment_method', e.payment_method,
               'counterparty',   e.counterparty,
               'note',           e.note,
               'receipt_no',     e.receipt_no,
               'created_at',     e.created_at,
               'created_by',     u.email,
               'voided_at',      e.voided_at,
               'void_reason',    e.void_reason
             ) AS x
        FROM store_ledger_entries e
        LEFT JOIN store_ledger_categories c ON c.id = e.category_id
        LEFT JOIN auth.users u ON u.id = e.created_by
       WHERE e.tenant_id = v_tenant AND e.store_id = p_store_id
         AND e.entry_date BETWEEN v_from AND v_to
         AND (p_direction IS NULL OR e.direction = p_direction)
         AND (p_category_id IS NULL OR e.category_id = p_category_id)
         AND (p_include_voided OR e.voided_at IS NULL)
       ORDER BY e.entry_date DESC, e.id DESC
       LIMIT v_limit OFFSET v_offset
    ) t;

  RETURN jsonb_build_object(
    'date_from', to_char(v_from, 'YYYY-MM-DD'),
    'date_to',   to_char(v_to, 'YYYY-MM-DD'),
    'total',     v_total,
    'rows',      v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_entry_list(BIGINT, DATE, DATE, TEXT, BIGINT, BOOLEAN, INT, INT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. 科目清單（含停用 ＋ 已用筆數）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_ledger_categories(
  p_store_id         BIGINT,
  p_include_inactive BOOLEAN DEFAULT TRUE
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store  public.stores%ROWTYPE := public._store_ledger_guard(p_store_id);
  v_tenant UUID := v_store.tenant_id;
  v_rows   jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.kind, c.sort_order, c.name), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT x.id, x.store_id, x.kind, x.name, x.affects_profit, x.is_system, x.is_active, x.sort_order,
             (SELECT COUNT(*) FROM store_ledger_entries e
               WHERE e.category_id = x.id AND e.voided_at IS NULL)::int AS used_count
        FROM store_ledger_categories x
       WHERE x.tenant_id = v_tenant
         AND (x.store_id IS NULL OR x.store_id = p_store_id)
         AND (p_include_inactive OR x.is_active)
    ) c;

  RETURN jsonb_build_object('store_id', p_store_id, 'is_hq', public._store_ledger_is_hq(), 'rows', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_categories(BIGINT, BOOLEAN) TO authenticated;

-- ----------------------------------------------------------------------------
-- 7. 寫入：新增 / 修改一筆帳
--    p_id IS NULL → 新增；有值 → 修改（同一家店、未作廢、當天未關帳）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_ledger_save_entry(
  p_store_id       BIGINT,
  p_entry_date     DATE,
  p_direction      TEXT,
  p_category_id    BIGINT,
  p_amount         NUMERIC,
  p_payment_method TEXT   DEFAULT 'cash',
  p_counterparty   TEXT   DEFAULT NULL,
  p_note           TEXT   DEFAULT NULL,
  p_receipt_no     TEXT   DEFAULT NULL,
  p_id             BIGINT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store  public.stores%ROWTYPE := public._store_ledger_guard(p_store_id);
  v_tenant UUID := v_store.tenant_id;
  v_today  DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_date   DATE := COALESCE(p_entry_date, v_today);
  v_amount NUMERIC := ROUND(COALESCE(p_amount, 0), 2);
  v_pm     TEXT := COALESCE(NULLIF(TRIM(p_payment_method), ''), 'cash');
  v_cat    public.store_ledger_categories%ROWTYPE;
  v_old    public.store_ledger_entries%ROWTYPE;
  v_id     BIGINT;
BEGIN
  IF p_direction IS NULL OR p_direction NOT IN ('income','expense') THEN
    RAISE EXCEPTION 'ledger_input: 請選擇「收入」或「支出」。';
  END IF;
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'ledger_input: 金額必須大於 0。';
  END IF;
  IF v_amount > 99999999 THEN
    RAISE EXCEPTION 'ledger_input: 金額超過上限（99,999,999），請確認是不是多打了幾個 0。';
  END IF;
  IF v_pm NOT IN ('cash','transfer','credit_card','line_pay','other') THEN
    RAISE EXCEPTION 'ledger_input: 付款方式「%」不合法。', v_pm;
  END IF;
  IF v_date > v_today THEN
    RAISE EXCEPTION 'ledger_input: 不能記未來日期的帳（%）。', to_char(v_date, 'YYYY-MM-DD');
  END IF;

  SELECT * INTO v_cat
    FROM store_ledger_categories
   WHERE id = p_category_id AND tenant_id = v_tenant
     AND (store_id IS NULL OR store_id = p_store_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger_input: 請選擇科目（找不到 #% 或不屬於這家店）。', p_category_id;
  END IF;
  IF v_cat.kind <> p_direction THEN
    RAISE EXCEPTION 'ledger_input: 科目「%」是%科目，跟這筆的收支別不符。',
      v_cat.name, CASE WHEN v_cat.kind = 'income' THEN '收入' ELSE '支出' END;
  END IF;

  PERFORM public._store_ledger_assert_open(v_tenant, p_store_id, v_date);

  IF p_id IS NULL THEN
    INSERT INTO store_ledger_entries (
      tenant_id, store_id, entry_date, direction, category_id, amount, payment_method,
      counterparty, note, receipt_no, created_by, updated_by
    ) VALUES (
      v_tenant, p_store_id, v_date, p_direction, v_cat.id, v_amount, v_pm,
      NULLIF(TRIM(COALESCE(p_counterparty, '')), ''),
      NULLIF(TRIM(COALESCE(p_note, '')), ''),
      NULLIF(TRIM(COALESCE(p_receipt_no, '')), ''),
      auth.uid(), auth.uid()
    )
    RETURNING id INTO v_id;
  ELSE
    SELECT * INTO v_old
      FROM store_ledger_entries
     WHERE id = p_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ledger_not_found: 找不到這筆帳（可能已被刪除）。';
    END IF;
    IF v_old.store_id <> p_store_id THEN
      RAISE EXCEPTION 'ledger_perm: 這筆帳不屬於「%」。', v_store.name;
    END IF;
    IF v_old.voided_at IS NOT NULL THEN
      RAISE EXCEPTION 'ledger_input: 這筆帳已作廢，不能再修改。請重新新增一筆。';
    END IF;
    -- 舊日期也要檢查：帳不能從已關帳的那天搬出來
    PERFORM public._store_ledger_assert_open(v_tenant, p_store_id, v_old.entry_date);

    UPDATE store_ledger_entries
       SET entry_date     = v_date,
           direction      = p_direction,
           category_id    = v_cat.id,
           amount         = v_amount,
           payment_method = v_pm,
           counterparty   = NULLIF(TRIM(COALESCE(p_counterparty, '')), ''),
           note           = NULLIF(TRIM(COALESCE(p_note, '')), ''),
           receipt_no     = NULLIF(TRIM(COALESCE(p_receipt_no, '')), ''),
           updated_by     = auth.uid()
     WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('id', v_id, 'entry_date', to_char(v_date, 'YYYY-MM-DD'));
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_save_entry(BIGINT, DATE, TEXT, BIGINT, NUMERIC, TEXT, TEXT, TEXT, TEXT, BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 8. 作廢一筆帳（不刪列）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_ledger_void_entry(
  p_id     BIGINT,
  p_reason TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_old    public.store_ledger_entries%ROWTYPE;
BEGIN
  SELECT * INTO v_old FROM store_ledger_entries WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger_not_found: 找不到這筆帳。';
  END IF;

  PERFORM public._store_ledger_guard(v_old.store_id);

  IF v_old.voided_at IS NOT NULL THEN
    RAISE EXCEPTION 'ledger_input: 這筆帳已經作廢過了。';
  END IF;

  PERFORM public._store_ledger_assert_open(v_tenant, v_old.store_id, v_old.entry_date);

  UPDATE store_ledger_entries
     SET voided_at   = NOW(),
         voided_by   = auth.uid(),
         void_reason = NULLIF(TRIM(COALESCE(p_reason, '')), ''),
         updated_by  = auth.uid()
   WHERE id = p_id;

  RETURN jsonb_build_object('id', p_id, 'voided', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_void_entry(BIGINT, TEXT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 9. 關帳 / 重開
--    關帳＝把當下的數字存成快照。之後取貨被撤銷／補記都不會動到已關的那天，
--    要更新就「重新開帳 → 再關一次」，而那會留下 reopened_by / reopen_reason。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_ledger_close_day(
  p_store_id     BIGINT,
  p_date         DATE,
  p_counted_cash NUMERIC,
  p_opening_cash NUMERIC DEFAULT NULL,
  p_note         TEXT    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store     public.stores%ROWTYPE := public._store_ledger_guard(p_store_id);
  v_tenant    UUID := v_store.tenant_id;
  v_today     DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_date      DATE := COALESCE(p_date, v_today);
  v_s_total   NUMERIC; v_s_cash NUMERIC; v_s_noncash NUMERIC;
  v_tot       RECORD;
  v_open      NUMERIC;
  v_counted   NUMERIC := ROUND(COALESCE(p_counted_cash, 0), 2);
  v_expect    NUMERIC;
  v_row       public.store_daily_closings%ROWTYPE;
BEGIN
  IF v_date > v_today THEN
    RAISE EXCEPTION 'ledger_input: 還沒到的日期不能關帳（%）。', to_char(v_date, 'YYYY-MM-DD');
  END IF;
  IF v_counted < 0 THEN
    RAISE EXCEPTION 'ledger_input: 實點現金不能是負數。';
  END IF;
  PERFORM public._store_ledger_assert_open(v_tenant, p_store_id, v_date);

  SELECT s.total, s.cash, s.noncash
    INTO v_s_total, v_s_cash, v_s_noncash
    FROM public._store_ledger_sales(p_store_id, v_date, v_date) s LIMIT 1;
  v_s_total   := COALESCE(v_s_total, 0);
  v_s_cash    := COALESCE(v_s_cash, 0);
  v_s_noncash := COALESCE(v_s_noncash, 0);

  SELECT
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'income'  AND e.payment_method =  'cash'), 0) AS income_cash,
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'income'  AND e.payment_method <> 'cash'), 0) AS income_noncash,
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'expense' AND e.payment_method =  'cash'), 0) AS expense_cash,
    COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'expense' AND e.payment_method <> 'cash'), 0) AS expense_noncash
    INTO v_tot
    FROM store_ledger_entries e
   WHERE e.tenant_id = v_tenant AND e.store_id = p_store_id
     AND e.entry_date = v_date AND e.voided_at IS NULL;

  IF p_opening_cash IS NOT NULL THEN
    v_open := ROUND(p_opening_cash, 2);
  ELSE
    SELECT COALESCE(counted_cash, 0) INTO v_open
      FROM store_daily_closings
     WHERE tenant_id = v_tenant AND store_id = p_store_id
       AND closing_date < v_date AND status = 'closed'
     ORDER BY closing_date DESC LIMIT 1;
    v_open := COALESCE(v_open, 0);
  END IF;

  v_expect := v_open + v_s_cash + v_tot.income_cash - v_tot.expense_cash;

  INSERT INTO store_daily_closings (
    tenant_id, store_id, closing_date, status,
    opening_cash, sales_total, sales_cash, sales_noncash,
    income_cash, income_noncash, expense_cash, expense_noncash,
    expected_cash, counted_cash, diff_cash, note, closed_by, closed_at
  ) VALUES (
    v_tenant, p_store_id, v_date, 'closed',
    v_open, v_s_total, v_s_cash, v_s_noncash,
    v_tot.income_cash, v_tot.income_noncash, v_tot.expense_cash, v_tot.expense_noncash,
    v_expect, v_counted, v_counted - v_expect,
    NULLIF(TRIM(COALESCE(p_note, '')), ''), auth.uid(), NOW()
  )
  ON CONFLICT (tenant_id, store_id, closing_date) DO UPDATE
     SET status          = 'closed',
         opening_cash    = EXCLUDED.opening_cash,
         sales_total     = EXCLUDED.sales_total,
         sales_cash      = EXCLUDED.sales_cash,
         sales_noncash   = EXCLUDED.sales_noncash,
         income_cash     = EXCLUDED.income_cash,
         income_noncash  = EXCLUDED.income_noncash,
         expense_cash    = EXCLUDED.expense_cash,
         expense_noncash = EXCLUDED.expense_noncash,
         expected_cash   = EXCLUDED.expected_cash,
         counted_cash    = EXCLUDED.counted_cash,
         diff_cash       = EXCLUDED.diff_cash,
         note            = EXCLUDED.note,
         closed_by       = EXCLUDED.closed_by,
         closed_at       = NOW()
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_close_day(BIGINT, DATE, NUMERIC, NUMERIC, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_store_ledger_reopen_day(
  p_store_id BIGINT,
  p_date     DATE,
  p_reason   TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store  public.stores%ROWTYPE := public._store_ledger_guard(p_store_id);
  v_tenant UUID := v_store.tenant_id;
  v_row    public.store_daily_closings%ROWTYPE;
BEGIN
  SELECT * INTO v_row
    FROM store_daily_closings
   WHERE tenant_id = v_tenant AND store_id = p_store_id AND closing_date = p_date;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger_not_found: 這一天還沒關帳。';
  END IF;
  IF v_row.status <> 'closed' THEN
    RAISE EXCEPTION 'ledger_input: 這一天目前不是已關帳狀態。';
  END IF;

  UPDATE store_daily_closings
     SET status        = 'reopened',
         reopened_by   = auth.uid(),
         reopened_at   = NOW(),
         reopen_reason = NULLIF(TRIM(COALESCE(p_reason, '')), '')
   WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_reopen_day(BIGINT, DATE, TEXT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 10. 科目維護
--     共用科目（store_id IS NULL，含系統預設）只有總部能動；
--     店長只能加／改／停用**自己店**的自訂科目。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_ledger_save_category(
  p_store_id       BIGINT,
  p_kind           TEXT,
  p_name           TEXT,
  p_affects_profit BOOLEAN DEFAULT TRUE,
  p_sort_order     INT     DEFAULT 500,
  p_is_active      BOOLEAN DEFAULT TRUE,
  p_id             BIGINT  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID;
  v_name   TEXT := NULLIF(TRIM(COALESCE(p_name, '')), '');
  v_old    public.store_ledger_categories%ROWTYPE;
  v_guard  public.stores%ROWTYPE;
  v_id     BIGINT;
BEGIN
  IF p_id IS NOT NULL THEN
    v_tenant := public._current_tenant_id();
    SELECT * INTO v_old FROM store_ledger_categories WHERE id = p_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ledger_not_found: 找不到這個科目。';
    END IF;
    IF v_old.store_id IS NULL THEN
      IF NOT public._store_ledger_is_hq() THEN
        RAISE EXCEPTION 'ledger_perm: 「%」是全門市共用科目，只有總部可以修改。分店要自己的科目請按「＋ 新增科目」。', v_old.name;
      END IF;
    ELSE
      PERFORM public._store_ledger_guard(v_old.store_id);
    END IF;

    IF v_old.is_system AND (v_name IS DISTINCT FROM v_old.name OR p_kind IS DISTINCT FROM v_old.kind) THEN
      RAISE EXCEPTION 'ledger_input: 系統預設科目「%」不能改名稱或收支別，只能調整排序／停用。', v_old.name;
    END IF;

    UPDATE store_ledger_categories
       SET name           = COALESCE(v_name, name),
           kind           = COALESCE(NULLIF(p_kind, ''), kind),
           affects_profit = COALESCE(p_affects_profit, affects_profit),
           sort_order     = COALESCE(p_sort_order, sort_order),
           is_active      = COALESCE(p_is_active, is_active),
           updated_by     = auth.uid()
     WHERE id = p_id
    RETURNING id INTO v_id;
  ELSE
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'ledger_input: 請輸入科目名稱。';
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('income','expense') THEN
      RAISE EXCEPTION 'ledger_input: 科目必須是「收入」或「支出」。';
    END IF;

    IF p_store_id IS NULL THEN
      v_tenant := public._current_tenant_id();
      IF NOT public._store_ledger_is_hq() THEN
        RAISE EXCEPTION 'ledger_perm: 只有總部可以新增全門市共用科目。';
      END IF;
    ELSE
      v_guard  := public._store_ledger_guard(p_store_id);
      v_tenant := v_guard.tenant_id;
    END IF;

    INSERT INTO store_ledger_categories (
      tenant_id, store_id, kind, name, affects_profit, is_system, is_active, sort_order, created_by, updated_by
    ) VALUES (
      v_tenant, p_store_id, p_kind, v_name, COALESCE(p_affects_profit, TRUE), FALSE,
      COALESCE(p_is_active, TRUE), COALESCE(p_sort_order, 500), auth.uid(), auth.uid()
    )
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('id', v_id);
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'ledger_input: 已經有一個同名的科目了（%）。', COALESCE(v_name, p_name);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_save_category(BIGINT, TEXT, TEXT, BOOLEAN, INT, BOOLEAN, BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_store_ledger_delete_category(p_id BIGINT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_old    public.store_ledger_categories%ROWTYPE;
  v_used   INT;
BEGIN
  SELECT * INTO v_old FROM store_ledger_categories WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger_not_found: 找不到這個科目。';
  END IF;
  IF v_old.store_id IS NULL THEN
    IF NOT public._store_ledger_is_hq() THEN
      RAISE EXCEPTION 'ledger_perm: 「%」是全門市共用科目，只有總部可以刪除。', v_old.name;
    END IF;
  ELSE
    PERFORM public._store_ledger_guard(v_old.store_id);
  END IF;
  IF v_old.is_system THEN
    RAISE EXCEPTION 'ledger_input: 系統預設科目不能刪除。用不到請改成「停用」。';
  END IF;

  SELECT COUNT(*) INTO v_used FROM store_ledger_entries WHERE category_id = p_id;
  IF v_used > 0 THEN
    RAISE EXCEPTION 'ledger_input: 這個科目已經記過 % 筆帳，不能刪除。請改成「停用」，舊帳才留得住。', v_used;
  END IF;

  DELETE FROM store_ledger_categories WHERE id = p_id;
  RETURN jsonb_build_object('id', p_id, 'deleted', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_ledger_delete_category(BIGINT) TO authenticated;

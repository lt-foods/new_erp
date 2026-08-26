-- ============================================================
-- 2026-08-26: 日結報表 rpc_daily_pickup_settlement（新函式）
--
-- 需求（Alex）：要有日結報表，統計「已完成」與「部分取貨」訂單當天
--   實際取走的金額 —— 門市每天關帳時要知道今天交了多少貨、收了多少錢。
--
-- 口徑（對齊 rpc_order_overview 的 pickup 聚合，20260803000020）：
--   * 取貨明細 = customer_order_items.status='picked_up'。
--     rpc_record_pickup 整行取直接標 picked_up、部分取則拆出一行 picked_up
--     （qty=本次取貨量），逐行加總不重複也不漏；rpc_undo_pickup 改回
--     pending，撤銷的取貨自動不計。
--   * 金額 = qty * unit_price（不扣折扣），與 /orders KPI「今日取貨金額」
--     同一公式，兩邊數字才對得起來。
--   * 取貨時間 = customer_order_items.updated_at，日界以 Asia/Taipei 切。
--     2026-08-26 重驗：picked_up 全量 57,938 筆與 pickup_movement_id →
--     stock_movements.created_at 完全相等（max drift 0 秒、無 NULL），
--     20260803000020 檔頭的「若日後有 RPC 會改 picked_up 行要改 join
--     stock_movements」警語仍未觸發。
--   * 排除 cancelled / expired / transferred_out 訂單（同 overview）。
--   * 排除內部容器單（members.member_type='store_internal'：RR- /
--     【內部】xx 店 / AB- 載體）—— 那是現貨池帳本搬運，不是對客人收的錢。
--     線上實測這類單身上掛著 437 筆 picked_up / 約 NT$13.8 萬，不排除
--     日結會多算。⚠ 判準是 member_type，不是 order_kind / 單號前綴：
--     29 張 RR- 單已換到真會員名下（picked_up $10,496），那些是真的收錢。
--   * 已完成 / 部分取貨的拆分依單頭「目前」status：completed /
--     partially_completed；其他 status（理論上不會有，防禦用）歸 other，
--     金額照列不丟。
--
-- 回傳 jsonb：
--   date_from / date_to      實際套用的日期（Asia/Taipei，含頭尾）
--   days[]                   依 日期 × 分店 聚合（orders / qty / amount /
--                            completed_* / partial_* / other_amount）
--   orders[]                 依 訂單 × 日期 的明細列（最多 800 列，
--                            picked_at DESC），orders_total / orders_truncated
--                            告知有沒有被截斷
--
-- 參數：p_store_id NULL=全部分店；日期預設今天（台北）；區間上限 92 天
--   （超過自動夾住，避免全站掃描 timeout）。
--
-- 權限：LANGUAGE sql STABLE、無 SECURITY DEFINER → 以呼叫者身分跑，
--   tenant 隔離交給 RLS（與 rpc_order_overview 同一套）。
--
-- 附帶：customer_order_items 新增 partial index
--   idx_coi_picked_up_updated_at (tenant_id, updated_at) WHERE status='picked_up'
--   —— 本函式與 rpc_order_overview 的 pickup 聚合都是「picked_up + 時間區間」
--   的掃法，之前只能全表掃 picked_up。
--
-- 基底版本：無（新函式、新 index）。
-- rollback：DROP FUNCTION rpc_daily_pickup_settlement(bigint, date, date);
--           DROP INDEX idx_coi_picked_up_updated_at;
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_coi_picked_up_updated_at
  ON customer_order_items (tenant_id, updated_at)
  WHERE status = 'picked_up';

CREATE OR REPLACE FUNCTION rpc_daily_pickup_settlement(
  p_store_id  bigint DEFAULT NULL,
  p_date_from date   DEFAULT NULL,
  p_date_to   date   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE
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
    SELECT
      (p.d_from::timestamp AT TIME ZONE 'Asia/Taipei')       AS ts_from,
      ((p.d_to + 1)::timestamp AT TIME ZONE 'Asia/Taipei')   AS ts_to
    FROM params p
  ),
  picked AS (
    SELECT
      to_char((i.updated_at AT TIME ZONE 'Asia/Taipei')::date, 'YYYY-MM-DD') AS ymd,
      co.pickup_store_id                            AS store_id,
      COALESCE(s.name, '#' || co.pickup_store_id)   AS store_name,
      co.id                                         AS order_id,
      co.order_no,
      co.status,
      CASE
        WHEN co.status = 'completed'           THEN 'completed'
        WHEN co.status = 'partially_completed' THEN 'partial'
        ELSE 'other'
      END                                           AS grp,
      COALESCE(m.name, co.nickname_snapshot)        AS member_name,
      i.qty::numeric                                AS qty,
      (i.qty * i.unit_price)::numeric               AS amount,
      i.updated_at                                  AS picked_at
    FROM customer_order_items i
    JOIN customer_orders co ON co.id = i.order_id
    JOIN bounds b ON TRUE
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN stores  s ON s.id = co.pickup_store_id
    WHERE i.status = 'picked_up'
      AND i.updated_at >= b.ts_from
      AND i.updated_at <  b.ts_to
      AND co.status NOT IN ('cancelled','expired','transferred_out')
      AND COALESCE(m.member_type, '') <> 'store_internal'
      AND (p_store_id IS NULL OR co.pickup_store_id = p_store_id)
  ),
  day_agg AS (
    SELECT
      p.ymd,
      p.store_id,
      p.store_name,
      count(DISTINCT p.order_id)                                          AS orders,
      SUM(p.qty)::numeric                                                 AS qty,
      SUM(p.amount)::numeric                                              AS amount,
      count(DISTINCT p.order_id) FILTER (WHERE p.grp = 'completed')       AS completed_orders,
      COALESCE(SUM(p.amount) FILTER (WHERE p.grp = 'completed'), 0)::numeric AS completed_amount,
      count(DISTINCT p.order_id) FILTER (WHERE p.grp = 'partial')         AS partial_orders,
      COALESCE(SUM(p.amount) FILTER (WHERE p.grp = 'partial'), 0)::numeric   AS partial_amount,
      COALESCE(SUM(p.amount) FILTER (WHERE p.grp = 'other'), 0)::numeric     AS other_amount
    FROM picked p
    GROUP BY p.ymd, p.store_id, p.store_name
  ),
  order_day AS (
    SELECT
      p.ymd,
      p.store_id,
      p.store_name,
      p.order_id,
      p.order_no,
      p.status,
      p.member_name,
      count(*)               AS item_count,
      SUM(p.qty)::numeric    AS qty,
      SUM(p.amount)::numeric AS amount,
      max(p.picked_at)       AS picked_at
    FROM picked p
    GROUP BY p.ymd, p.store_id, p.store_name, p.order_id, p.order_no, p.status, p.member_name
  ),
  order_rows AS (
    SELECT * FROM order_day ORDER BY picked_at DESC LIMIT 800
  )
  SELECT jsonb_build_object(
    'date_from', (SELECT to_char(d_from, 'YYYY-MM-DD') FROM params),
    'date_to',   (SELECT to_char(d_to,   'YYYY-MM-DD') FROM params),
    'days', COALESCE(
      (SELECT jsonb_agg(to_jsonb(d.*) ORDER BY d.ymd DESC, d.store_name)
       FROM day_agg d),
      '[]'::jsonb
    ),
    'orders', COALESCE(
      (SELECT jsonb_agg(to_jsonb(o.*) ORDER BY o.picked_at DESC)
       FROM order_rows o),
      '[]'::jsonb
    ),
    'orders_total',     (SELECT count(*) FROM order_day),
    'orders_truncated', (SELECT count(*) > 800 FROM order_day)
  );
$$;

COMMENT ON FUNCTION rpc_daily_pickup_settlement(bigint, date, date) IS
  '日結報表：依日期×分店聚合「已取走品項」金額（picked_up 逐行、qty*unit_price、'
  'Asia/Taipei 日界、updated_at 當取貨時間），拆已完成 / 部分取貨，附訂單明細列'
  '（上限 800）。排除 cancelled/expired/transferred_out 訂單與內部容器單'
  '（member_type=store_internal）。口徑同 rpc_order_overview 的 pickup 聚合，'
  '不扣折扣。';

GRANT EXECUTE ON FUNCTION rpc_daily_pickup_settlement(bigint, date, date) TO authenticated;

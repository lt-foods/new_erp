-- ============================================================================
-- 店家自開團 (5/5)：日結報表多一個「店家自己的團」區塊
-- ============================================================================
-- 需求（Alex 2026-08-31）：「月結算也不記入」「日結算多一個區塊是店家自己團的結算」。
--
-- 月結算：**不用改**。store_monthly_settlement_items 整張表以 transfer_id /
--   transfer_item_id 為鍵，母體全是 transfers；自開團全程不產生任何 transfer，
--   所以結構性地一列都不會進去。在月結那邊另外加排除條件反而是多餘的分歧
--   （日後有人改了母體卻忘了同步那個條件，就是靜默錯帳）。
--
-- 日結算：要拆開看。日結是「門市今天交了多少貨、收了多少錢」，自開團的錢是
--   店家自己的（貨自己買、不跟總倉結算），跟總倉團的錢混在同一個數字裡，
--   門市關帳時分不出哪些要跟總倉對帳。所以：
--     * days[] 每一列多四個欄位：store_campaign_orders / _qty / _amount 與 hq_amount
--       （hq_amount = amount − store_campaign_amount，兩者相加＝原本的 amount，
--        既有欄位一個都沒動，前端沒改也不會壞）
--     * 多一個 top-level `store_campaigns`：依 日期 × 分店 × 團 聚合，
--       這就是「店家自己團的結算」區塊的資料來源
--     * 明細 rpc_daily_pickup_orders 每列多一個 is_store_campaign / campaign_no /
--       campaign_name，讓明細也分得出來
--
-- ⚠ 兩支函式的 picked 母體（WHERE 那五個條件）必須逐字一致 ——
--   基底檔頭已經寫過這條，這次加 join 也一樣兩支同步加。
--
-- 判準：group_buy_campaigns.owner_store_id IS NOT NULL（20260831000000）。
--   不要改用「單號前綴」或 order_kind —— 那些都不是這個功能的標記。
--
-- 基底版本：20260828010000_rpc_daily_pickup_orders_paged.sql（線上現行版，
--   settlement 只回彙總、明細走 rpc_daily_pickup_orders 分頁）。
-- Rollback：兩支 CREATE OR REPLACE 回 20260828010000。
-- ============================================================================

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
      CASE
        WHEN co.status = 'completed'           THEN 'completed'
        WHEN co.status = 'partially_completed' THEN 'partial'
        ELSE 'other'
      END                                           AS grp,
      -- 20260831：店家自開團（owner_store_id 非 NULL）
      (gc.owner_store_id IS NOT NULL)               AS is_store_campaign,
      co.campaign_id,
      gc.campaign_no,
      gc.name                                       AS campaign_name,
      i.qty::numeric                                AS qty,
      (i.qty * i.unit_price)::numeric               AS amount
    FROM customer_order_items i
    JOIN customer_orders co ON co.id = i.order_id
    JOIN bounds b ON TRUE
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN stores  s ON s.id = co.pickup_store_id
    LEFT JOIN group_buy_campaigns gc ON gc.id = co.campaign_id
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
      COALESCE(SUM(p.amount) FILTER (WHERE p.grp = 'other'), 0)::numeric     AS other_amount,
      -- 20260831：店家自己的團（不跟總倉結算）vs 其餘（要跟總倉對帳）
      count(DISTINCT p.order_id) FILTER (WHERE p.is_store_campaign)          AS store_campaign_orders,
      COALESCE(SUM(p.qty)    FILTER (WHERE p.is_store_campaign), 0)::numeric AS store_campaign_qty,
      COALESCE(SUM(p.amount) FILTER (WHERE p.is_store_campaign), 0)::numeric AS store_campaign_amount,
      COALESCE(SUM(p.amount) FILTER (WHERE NOT p.is_store_campaign), 0)::numeric AS hq_amount
    FROM picked p
    GROUP BY p.ymd, p.store_id, p.store_name
  ),
  store_campaign_agg AS (
    SELECT
      p.ymd,
      p.store_id,
      p.store_name,
      p.campaign_id,
      p.campaign_no,
      p.campaign_name,
      count(DISTINCT p.order_id) AS orders,
      SUM(p.qty)::numeric        AS qty,
      SUM(p.amount)::numeric     AS amount
    FROM picked p
    WHERE p.is_store_campaign
    GROUP BY p.ymd, p.store_id, p.store_name, p.campaign_id, p.campaign_no, p.campaign_name
  )
  SELECT jsonb_build_object(
    'date_from', (SELECT to_char(d_from, 'YYYY-MM-DD') FROM params),
    'date_to',   (SELECT to_char(d_to,   'YYYY-MM-DD') FROM params),
    'days', COALESCE(
      (SELECT jsonb_agg(to_jsonb(d.*) ORDER BY d.ymd DESC, d.store_name)
       FROM day_agg d),
      '[]'::jsonb
    ),
    'store_campaigns', COALESCE(
      (SELECT jsonb_agg(to_jsonb(c.*) ORDER BY c.ymd DESC, c.store_name, c.campaign_no)
       FROM store_campaign_agg c),
      '[]'::jsonb
    )
  );
$$;

COMMENT ON FUNCTION rpc_daily_pickup_settlement(bigint, date, date) IS
  '日結報表彙總：依日期×分店聚合「已取走品項」金額（picked_up 逐行、qty*unit_price、'
  'Asia/Taipei 日界、updated_at 當取貨時間），拆已完成 / 部分取貨。排除 cancelled/'
  'expired/transferred_out 訂單與內部容器單（member_type=store_internal）。'
  '20260831 起每列另拆 store_campaign_*（店家自開團，店家自己的錢、不跟總倉結算）'
  '與 hq_amount，並多回一個 store_campaigns[]（日期×分店×團）供日結的自開團區塊。'
  '訂單明細走 rpc_daily_pickup_orders（分頁），兩支的 picked 母體必須一致。';

GRANT EXECUTE ON FUNCTION rpc_daily_pickup_settlement(bigint, date, date) TO authenticated;

-- ------------------------------------------------------------
-- 訂單明細（點了才載、分頁）。picked 母體與上面那支逐字相同。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_daily_pickup_orders(
  p_store_id  bigint  DEFAULT NULL,
  p_date_from date    DEFAULT NULL,
  p_date_to   date    DEFAULT NULL,
  p_limit     integer DEFAULT 20,
  p_offset    integer DEFAULT 0
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
      COALESCE(m.name, co.nickname_snapshot)        AS member_name,
      (gc.owner_store_id IS NOT NULL)               AS is_store_campaign,
      gc.campaign_no,
      gc.name                                       AS campaign_name,
      i.qty::numeric                                AS qty,
      (i.qty * i.unit_price)::numeric               AS amount,
      i.updated_at                                  AS picked_at
    FROM customer_order_items i
    JOIN customer_orders co ON co.id = i.order_id
    JOIN bounds b ON TRUE
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN stores  s ON s.id = co.pickup_store_id
    LEFT JOIN group_buy_campaigns gc ON gc.id = co.campaign_id
    WHERE i.status = 'picked_up'
      AND i.updated_at >= b.ts_from
      AND i.updated_at <  b.ts_to
      AND co.status NOT IN ('cancelled','expired','transferred_out')
      AND COALESCE(m.member_type, '') <> 'store_internal'
      AND (p_store_id IS NULL OR co.pickup_store_id = p_store_id)
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
      p.is_store_campaign,
      p.campaign_no,
      p.campaign_name,
      count(*)               AS item_count,
      SUM(p.qty)::numeric    AS qty,
      SUM(p.amount)::numeric AS amount,
      max(p.picked_at)       AS picked_at
    FROM picked p
    GROUP BY p.ymd, p.store_id, p.store_name, p.order_id, p.order_no, p.status,
             p.member_name, p.is_store_campaign, p.campaign_no, p.campaign_name
  ),
  page AS (
    SELECT *
    FROM order_day
    ORDER BY picked_at DESC, order_id DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM order_day),
    'rows', COALESCE(
      (SELECT jsonb_agg(to_jsonb(o.*) ORDER BY o.picked_at DESC, o.order_id DESC)
       FROM page o),
      '[]'::jsonb
    )
  );
$$;

COMMENT ON FUNCTION rpc_daily_pickup_orders(bigint, date, date, integer, integer) IS
  '日結報表的訂單明細（分頁，picked_at DESC）。picked 母體與 rpc_daily_pickup_settlement 逐字相同。'
  '20260831 起每列多回 is_store_campaign / campaign_no / campaign_name，'
  '讓明細也分得出「店家自己的團」與總倉團。';

GRANT EXECUTE ON FUNCTION rpc_daily_pickup_orders(bigint, date, date, integer, integer) TO authenticated;

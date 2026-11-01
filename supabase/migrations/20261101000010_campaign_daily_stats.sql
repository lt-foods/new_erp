-- ============================================================================
-- 20261101000010_campaign_daily_stats.sql
--
-- 開團每日快照（docs/PLAN-選品系統-外部來源與向量媒合.md Phase A）。
--
-- 為什麼要這張表：customer_orders 看得到「現在累積多少」，看不到「第 1 天賣多少、
-- 第 3 天賣多少」；campaign_views 是每 (團,會員) 一列累加、沒有每日明細。
-- 選品分數要「開團 24 小時 / 7 天的結果」回寫類別勝率、每週回測也要它。
--
-- 資料形狀：每 (團, 台北日期) 一列，只在那天有任何動靜（下單 / 取消 / 留言 / 新瀏覽者）
-- 才有列。所有欄位由 _campaign_daily_stats_rollup(from, to) 從來源表**重算**（upsert），
-- 所以重跑同一天不會加倍，事後取消的單重跑也會反映在 cancelled。
--
--   orders / buyers / qty / amount：當天建立的訂單（排除 store_internal 容器單、transferred_out）
--     qty / amount 看品項當下的 qty × unit_price，**不**濾品項 status —— 這是「那天客人想買多少」，
--     之後斷貨 / 取消反映在 cancelled，不回頭改這裡。
--   cancelled：cancelled_at 落在當天的訂單數（不論哪天建立）
--   comments：line_note_comments.commented_at 落在當天（經 line_note_posts 對到團）
--   new_viewers：campaign_views.first_viewed_at 落在當天的會員數（可回填）
--   views_cum：跑 rollup 那一刻 SUM(view_count)，只對「跑的當下」有意義 ——
--     回填的歷史列是 NULL，夜間排程跑昨天時填進去的值 ≈ 昨天結束時的累積。
--
-- 排程：pg_cron 'campaign-daily-stats'，台北 00:20（UTC 16:20）重算最近 4 天
-- （昨天 + 往前 3 天，吸收晚到的取消 / 留言同步）。
--
-- 本檔回填 2026-05-18（第一張訂單）起到昨天。
--
-- rollback：
--   SELECT cron.unschedule('campaign-daily-stats');
--   DROP FUNCTION public._campaign_daily_stats_tick();
--   DROP FUNCTION public._campaign_daily_stats_rollup(date, date);
--   DROP TABLE public.campaign_daily_stats;
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.campaign_daily_stats (
  tenant_id    UUID        NOT NULL,
  campaign_id  BIGINT      NOT NULL REFERENCES public.group_buy_campaigns(id) ON DELETE CASCADE,
  stat_date    DATE        NOT NULL,
  orders       INT         NOT NULL DEFAULT 0,
  buyers       INT         NOT NULL DEFAULT 0,
  qty          INT         NOT NULL DEFAULT 0,
  amount       NUMERIC(14,2) NOT NULL DEFAULT 0,
  cancelled    INT         NOT NULL DEFAULT 0,
  comments     INT         NOT NULL DEFAULT 0,
  new_viewers  INT         NOT NULL DEFAULT 0,
  views_cum    INT,
  computed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (campaign_id, stat_date)
);

CREATE INDEX IF NOT EXISTS idx_campaign_daily_stats_tenant_date
  ON public.campaign_daily_stats (tenant_id, stat_date DESC);

COMMENT ON TABLE public.campaign_daily_stats IS
  '開團每日快照（台北日期）。只由 _campaign_daily_stats_rollup 重算寫入；重跑同一天不加倍。'
  'views_cum 只在夜間排程跑的那一刻有意義，回填列為 NULL。';

ALTER TABLE public.campaign_daily_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS auth_read_campaign_daily_stats ON public.campaign_daily_stats;
CREATE POLICY auth_read_campaign_daily_stats ON public.campaign_daily_stats
  FOR SELECT TO authenticated
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
REVOKE INSERT, UPDATE, DELETE ON public.campaign_daily_stats FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.campaign_daily_stats TO authenticated;

-- ----------------------------------------------------------------------------
-- 重算 [p_from, p_to] 這段日期（台北），set-based，一句 upsert。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._campaign_daily_stats_rollup(p_from DATE, p_to DATE)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n INT;
  v_from_ts TIMESTAMPTZ := (p_from::timestamp) AT TIME ZONE 'Asia/Taipei';
  v_to_ts   TIMESTAMPTZ := ((p_to + 1)::timestamp) AT TIME ZONE 'Asia/Taipei';
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RETURN 0;
  END IF;

  WITH o AS (
    SELECT co.tenant_id, co.campaign_id,
           (co.created_at AT TIME ZONE 'Asia/Taipei')::date AS d,
           count(*)                       AS orders,
           count(DISTINCT co.member_id)   AS buyers,
           COALESCE(sum(i.qty), 0)        AS qty,
           COALESCE(sum(i.amount), 0)     AS amount
      FROM customer_orders co
      JOIN members m ON m.id = co.member_id AND m.member_type <> 'store_internal'
      LEFT JOIN LATERAL (
        SELECT sum(qty) AS qty, sum(qty * unit_price) AS amount
          FROM customer_order_items ci WHERE ci.order_id = co.id
      ) i ON TRUE
     WHERE co.created_at >= v_from_ts AND co.created_at < v_to_ts
       AND co.status <> 'transferred_out'
       AND co.campaign_id IS NOT NULL
     GROUP BY 1, 2, 3
  ),
  c AS (
    SELECT co.tenant_id, co.campaign_id,
           (co.cancelled_at AT TIME ZONE 'Asia/Taipei')::date AS d,
           count(*) AS cancelled
      FROM customer_orders co
      JOIN members m ON m.id = co.member_id AND m.member_type <> 'store_internal'
     WHERE co.cancelled_at >= v_from_ts AND co.cancelled_at < v_to_ts
       AND co.campaign_id IS NOT NULL
     GROUP BY 1, 2, 3
  ),
  cm AS (
    SELECT p.tenant_id, p.campaign_id,
           (lc.commented_at AT TIME ZONE 'Asia/Taipei')::date AS d,
           count(*) AS comments
      FROM line_note_comments lc
      JOIN line_note_posts p ON p.id = lc.post_id
     WHERE lc.commented_at >= v_from_ts AND lc.commented_at < v_to_ts
     GROUP BY 1, 2, 3
  ),
  v AS (
    SELECT cv.tenant_id, cv.campaign_id,
           (cv.first_viewed_at AT TIME ZONE 'Asia/Taipei')::date AS d,
           count(*) AS new_viewers
      FROM campaign_views cv
     WHERE cv.first_viewed_at >= v_from_ts AND cv.first_viewed_at < v_to_ts
     GROUP BY 1, 2, 3
  ),
  keys AS (
    SELECT tenant_id, campaign_id, d FROM o
    UNION SELECT tenant_id, campaign_id, d FROM c
    UNION SELECT tenant_id, campaign_id, d FROM cm
    UNION SELECT tenant_id, campaign_id, d FROM v
  ),
  merged AS (
    SELECT k.tenant_id, k.campaign_id, k.d,
           COALESCE(o.orders, 0)       AS orders,
           COALESCE(o.buyers, 0)       AS buyers,
           COALESCE(o.qty, 0)::int     AS qty,
           COALESCE(o.amount, 0)       AS amount,
           COALESCE(c.cancelled, 0)    AS cancelled,
           COALESCE(cm.comments, 0)    AS comments,
           COALESCE(v.new_viewers, 0)  AS new_viewers
      FROM keys k
      LEFT JOIN o  ON o.campaign_id = k.campaign_id AND o.d = k.d
      LEFT JOIN c  ON c.campaign_id = k.campaign_id AND c.d = k.d
      LEFT JOIN cm ON cm.campaign_id = k.campaign_id AND cm.d = k.d
      LEFT JOIN v  ON v.campaign_id = k.campaign_id AND v.d = k.d
      -- 團被刪掉的孤兒列不寫（FK 會擋）
      WHERE EXISTS (SELECT 1 FROM group_buy_campaigns g WHERE g.id = k.campaign_id)
  ),
  up AS (
    INSERT INTO campaign_daily_stats AS s
      (tenant_id, campaign_id, stat_date, orders, buyers, qty, amount, cancelled, comments, new_viewers, computed_at)
    SELECT tenant_id, campaign_id, d, orders, buyers, qty, amount, cancelled, comments, new_viewers, now()
      FROM merged
    ON CONFLICT (campaign_id, stat_date) DO UPDATE
      SET orders = EXCLUDED.orders, buyers = EXCLUDED.buyers, qty = EXCLUDED.qty,
          amount = EXCLUDED.amount, cancelled = EXCLUDED.cancelled, comments = EXCLUDED.comments,
          new_viewers = EXCLUDED.new_viewers, computed_at = now()
    RETURNING 1
  )
  SELECT count(*) INTO v_n FROM up;

  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._campaign_daily_stats_rollup(DATE, DATE) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 夜間 tick：重算最近 4 天，並把「昨天」的 views_cum 填成此刻的累積瀏覽數。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._campaign_daily_stats_tick()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
BEGIN
  PERFORM public._campaign_daily_stats_rollup(v_today - 4, v_today - 1);

  -- 昨天那一列的累積瀏覽（沒列的團就算了：昨天沒動靜的團不需要快照）
  UPDATE campaign_daily_stats s
     SET views_cum = x.views
    FROM (SELECT campaign_id, sum(view_count)::int AS views FROM campaign_views GROUP BY 1) x
   WHERE s.campaign_id = x.campaign_id AND s.stat_date = v_today - 1;
END;
$$;
REVOKE ALL ON FUNCTION public._campaign_daily_stats_tick() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule('campaign-daily-stats')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'campaign-daily-stats');
SELECT cron.schedule('campaign-daily-stats', '20 16 * * *', $cron$ SELECT public._campaign_daily_stats_tick(); $cron$);

-- ----------------------------------------------------------------------------
-- 回填：第一張訂單 2026-05-18 起到昨天（台北）
-- ----------------------------------------------------------------------------
SELECT public._campaign_daily_stats_rollup(DATE '2026-05-18', (now() AT TIME ZONE 'Asia/Taipei')::date - 1);

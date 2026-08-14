-- ============================================================
-- 2026-08-14：收貨頁的「訂單合計 / 總倉多給」要把同店轉單的衍生單算進去
--
-- 災情（三峽店 WV260813001460 / transfer 10797，G01659 蛋黃酥）：
--   彈窗標「派出 54 件 · 訂單 49 件 · 總倉多給 5 件（沒有訂單對應）」。
--   實際上那 5 件全有主：同店轉單（換客人 / 拆單）生出的衍生單
--   （GRP-...-TF0184/0185/0202/0204/0205，transferred_from_order_id 指向同店原單）。
--   撿貨波次建立時（20260807000000 起）需求端已改成「保留同店衍生單」——
--   這張 wave 的計畫量 55 = 目前算得到的 49 + 衍生單 6，總倉就是按這個數派的；
--   但收貨頁的兩支顯示用 RPC 還停在一刀 `transferred_from_order_id IS NULL`，
--   原單 transferred_out 排除＋衍生單也排除 → 需求憑空消失，被標成總倉多給。
--   同單第二個 SKU 同病：派 22 · 訂單 17 · 「多給 5」，實際需求 21，真多給只有
--   1 件（撿貨多撿：計畫 21、實撿 22）。
--
-- 影響範圍（線上實測，近 30 天帶開團波次的收貨線 9,082 條）：
--   73 條的訂單合計會變；「總倉多給」從 194 條 / 368 件降到 130 條 / 267 件，
--   消失的 64 條 / 101 件全是這種假多給。沒有任何一條的需求變小（只加不減）。
--
-- 修法：wave 需求 join 對齊 20260807000000 的守衛 ——
--   「排除跨店衍生單、保留同店衍生單」：
--     (co.transferred_from_order_id IS NULL OR EXISTS (
--        SELECT 1 FROM customer_orders src
--         WHERE src.id = co.transferred_from_order_id
--           AND src.pickup_store_id = co.pickup_store_id))
--   同店衍生單不會重複計數：部分轉出時原單品項已遞減 / 整列 cancelled，
--   整單轉出時原單 status='transferred_out' 本來就被排除。
--   跨店轉入單維持排除：它的貨不是這張 wave 派的（本例 TF0206/0207 從別店
--   轉來，就該繼續不列，列了反而變成「訂單比派出量多」的假警報）。
--
--   兩個刻意不動的地方：
--   - from_restock 維持一刀 `transferred_from_order_id IS NULL`：RR 母單這條
--     刻意連 cancelled 品項一起算（= 已轉出的量也算在母單頭上，見 20260805000090
--     檔頭），衍生子單再列出來就是重複計數。
--   - from_store（store_sku 退路）套守衛時多一個「來源單是一般單」條件：
--     這條 join 不綁 campaign，RR 母單的衍生單（order_kind 預設 'normal'、
--     campaign NULL）會被它撈到，而母單已在 from_restock 以含 cancelled 的
--     全量計數 —— 不擋 src.order_kind 的話補貨波次會重複計數。
--     from_wave 不需要這個條件：RR 母單 campaign_id 是 NULL，衍生單繼承後
--     對不上 pwi.campaign_id，天然進不來。
--
-- 基底版本：
--   rpc_get_orders_for_transfer        ← 20260805000090（v2，含 restock 路線）
--   rpc_get_ship_vs_demand_for_transfers ← 20260811000060（prior 批次版）
-- rollback: 重跑 20260805000090 與 20260811000060。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_get_orders_for_transfer v3：wave / store_sku 路線納入同店衍生單
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_orders_for_transfer(
  p_transfer_id BIGINT,
  p_sku_id      BIGINT DEFAULT NULL
) RETURNS TABLE (
  sku_id       BIGINT,
  order_id     BIGINT,
  order_no     TEXT,
  customer     TEXT,
  order_status TEXT,
  order_qty    NUMERIC,
  campaign_id  BIGINT,
  match_kind   TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH t AS (
    SELECT tr.id, tr.tenant_id, tr.dest_location, tr.customer_order_id
      FROM transfers tr
     WHERE tr.id = p_transfer_id
  ),
  want AS (
    SELECT DISTINCT ti.sku_id AS want_sku_id
      FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id
       AND (p_sku_id IS NULL OR ti.sku_id = p_sku_id)
  ),
  store AS (
    SELECT s.id AS store_id
      FROM t JOIN stores s
        ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
  ),
  from_wave AS (
    SELECT pwi.sku_id            AS r_sku_id,
           co.id                 AS r_order_id,
           co.order_no           AS r_order_no,
           COALESCE(m.name, co.nickname_snapshot) AS r_customer,
           co.status             AS r_status,
           SUM(coi.qty)          AS r_qty,
           co.campaign_id        AS r_campaign_id,
           'wave'::text          AS r_match_kind
      FROM t
      JOIN picking_wave_items pwi
        ON pwi.generated_transfer_id = t.id
       AND pwi.campaign_id IS NOT NULL
      JOIN want w ON w.want_sku_id = pwi.sku_id
      JOIN customer_orders co
        ON co.tenant_id        = pwi.tenant_id
       AND co.campaign_id      = pwi.campaign_id
       AND co.pickup_store_id  = pwi.store_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       -- 同 20260807000000：排除跨店衍生單、保留同店衍生單（貨走同一張 wave）
       AND (co.transferred_from_order_id IS NULL OR EXISTS (
              SELECT 1 FROM customer_orders src
               WHERE src.id = co.transferred_from_order_id
                 AND src.pickup_store_id = co.pickup_store_id))
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.sku_id   = pwi.sku_id
       AND coi.status NOT IN ('cancelled', 'expired')
      LEFT JOIN members m ON m.id = co.member_id
     GROUP BY pwi.sku_id, co.id, co.order_no, m.name, co.nickname_snapshot,
              co.status, co.campaign_id
  ),
  from_aid AS (
    SELECT coi.sku_id      AS r_sku_id,
           co.id           AS r_order_id,
           co.order_no     AS r_order_no,
           COALESCE(m.name, co.nickname_snapshot) AS r_customer,
           co.status       AS r_status,
           SUM(coi.qty)    AS r_qty,
           co.campaign_id  AS r_campaign_id,
           'aid'::text     AS r_match_kind
      FROM t
      JOIN customer_orders co ON co.id = t.customer_order_id
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.status NOT IN ('cancelled', 'expired')
      JOIN want w ON w.want_sku_id = coi.sku_id
      LEFT JOIN members m ON m.id = co.member_id
     GROUP BY coi.sku_id, co.id, co.order_no, m.name, co.nickname_snapshot,
              co.status, co.campaign_id
  ),
  from_restock AS (
    -- 補貨申請（RR-xxx，order_kind='restock'）：同店 + 同品項。
    -- 這條刻意不排除 coi.status = 'cancelled'，也刻意維持一刀排除衍生單 ——
    -- 母單已含轉出量，衍生子單再列就是重複計數（見檔頭）。
    SELECT coi.sku_id      AS r_sku_id,
           co.id           AS r_order_id,
           co.order_no     AS r_order_no,
           COALESCE(m.name, co.nickname_snapshot, '補貨申請') AS r_customer,
           co.status       AS r_status,
           SUM(coi.qty)    AS r_qty,
           co.campaign_id  AS r_campaign_id,
           'restock'::text AS r_match_kind
      FROM t
      JOIN store st ON TRUE
      JOIN customer_orders co
        ON co.pickup_store_id = st.store_id
       AND co.tenant_id       = t.tenant_id
       AND co.order_kind      = 'restock'
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND co.transferred_from_order_id IS NULL
      JOIN customer_order_items coi ON coi.order_id = co.id
      JOIN want w ON w.want_sku_id = coi.sku_id
      LEFT JOIN members m ON m.id = co.member_id
     GROUP BY coi.sku_id, co.id, co.order_no, m.name, co.nickname_snapshot,
              co.status, co.campaign_id
  ),
  from_store AS (
    -- 一般顧客訂單的退路：沒有波次 / 波次沒帶開團時，只用「取貨店 + 品項」比對
    SELECT coi.sku_id       AS r_sku_id,
           co.id            AS r_order_id,
           co.order_no      AS r_order_no,
           COALESCE(m.name, co.nickname_snapshot) AS r_customer,
           co.status        AS r_status,
           SUM(coi.qty)     AS r_qty,
           co.campaign_id   AS r_campaign_id,
           'store_sku'::text AS r_match_kind
      FROM t
      JOIN store st ON TRUE
      JOIN customer_orders co
        ON co.pickup_store_id = st.store_id
       AND co.tenant_id       = t.tenant_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       -- 同店衍生單保留，但來源必須是一般單：RR 母單的衍生單要擋掉，
       -- 母單已在 from_restock 以含 cancelled 的全量計數（見檔頭）
       AND (co.transferred_from_order_id IS NULL OR EXISTS (
              SELECT 1 FROM customer_orders src
               WHERE src.id = co.transferred_from_order_id
                 AND src.pickup_store_id = co.pickup_store_id
                 AND (src.order_kind = 'normal' OR src.order_kind IS NULL)))
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.status NOT IN ('cancelled', 'expired')
      JOIN want w ON w.want_sku_id = coi.sku_id
      LEFT JOIN members m ON m.id = co.member_id
     WHERE NOT EXISTS (SELECT 1 FROM from_wave fw WHERE fw.r_sku_id = coi.sku_id)
       AND NOT EXISTS (SELECT 1 FROM from_aid  fa WHERE fa.r_sku_id = coi.sku_id)
     GROUP BY coi.sku_id, co.id, co.order_no, m.name, co.nickname_snapshot,
              co.status, co.campaign_id
  ),
  unioned AS (
    SELECT * FROM from_wave
    UNION ALL SELECT * FROM from_aid
    UNION ALL SELECT * FROM from_restock
    UNION ALL SELECT * FROM from_store
  )
  SELECT DISTINCT ON (u.r_sku_id, u.r_order_id)
         u.r_sku_id, u.r_order_id, u.r_order_no, u.r_customer,
         u.r_status, u.r_qty, u.r_campaign_id, u.r_match_kind
    FROM unioned u
   ORDER BY u.r_sku_id, u.r_order_id,
            CASE u.r_match_kind
              WHEN 'wave' THEN 1 WHEN 'aid' THEN 2 WHEN 'restock' THEN 3 ELSE 4
            END;
$$;

REVOKE ALL ON FUNCTION public.rpc_get_orders_for_transfer(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_orders_for_transfer(BIGINT, BIGINT) TO authenticated;

-- ----------------------------------------------------------------
-- 2. rpc_get_ship_vs_demand_for_transfers：demand / backorder 同步套守衛
--    （「標籤上的件數 = 彈窗裡『派出 − 訂單合計』」的約定，兩邊要一起動）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_ship_vs_demand_for_transfers(
  p_transfer_ids BIGINT[]
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH pw AS (
    SELECT pwi.generated_transfer_id      AS tid,
           pwi.tenant_id,
           pwi.campaign_id,
           pwi.store_id,
           pwi.sku_id,
           COALESCE(pwi.picked_qty, pwi.qty) AS shipped
      FROM picking_wave_items pwi
     WHERE pwi.generated_transfer_id = ANY(p_transfer_ids)
       AND pwi.campaign_id IS NOT NULL
  ),
  dem AS (
    SELECT pw.tid, pw.shipped, d.demand, cov.covered, pri.prior, bo.backorder
      FROM pw
      CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(coi.qty), 0) AS demand
          FROM customer_orders co
          JOIN customer_order_items coi
            ON coi.order_id = co.id
           AND coi.sku_id   = pw.sku_id
           AND coi.status NOT IN ('cancelled', 'expired')
         WHERE co.tenant_id       = pw.tenant_id
           AND co.campaign_id     = pw.campaign_id
           AND co.pickup_store_id = pw.store_id
           AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
           -- 同 20260807000000：排除跨店衍生單、保留同店衍生單
           AND (co.transferred_from_order_id IS NULL OR EXISTS (
                  SELECT 1 FROM customer_orders src
                   WHERE src.id = co.transferred_from_order_id
                     AND src.pickup_store_id = co.pickup_store_id))
           AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      ) d
      CROSS JOIN LATERAL (
        -- coverage = 庫存減抵單（已用店內現貨交貨）+ 抵減單（開團時宣告用店內現貨）
        SELECT COALESCE((
                 SELECT SUM(n.qty) FROM inventory_deduction_notes n
                  WHERE n.tenant_id   = pw.tenant_id
                    AND n.campaign_id = pw.campaign_id
                    AND n.store_id    = pw.store_id
                    AND n.sku_id      = pw.sku_id
                    AND n.cancelled_at IS NULL
               ), 0)
             + COALESCE((
                 SELECT SUM(-oi.qty)
                   FROM customer_orders oo
                   JOIN customer_order_items oi
                     ON oi.order_id = oo.id
                    AND oi.sku_id   = pw.sku_id
                    AND oi.qty < 0
                    AND oi.status NOT IN ('cancelled', 'expired')
                  WHERE oo.tenant_id       = pw.tenant_id
                    AND oo.campaign_id     = pw.campaign_id
                    AND oo.pickup_store_id = pw.store_id
                    AND oo.order_kind      = 'offset'
                    AND oo.status NOT IN ('cancelled', 'expired', 'transferred_out')
               ), 0) AS covered
      ) cov
      CROSS JOIN LATERAL (
        -- 20260811(7)：這組還掛著幾件待補貨（backorder_at 未解）。
        -- 修掉假短少之後，「短少」歸零的組別連帶會失去收貨頁的「⚖️ 配貨」入口
        --（顯示條件是 short > 0 || covered > 0），而那是唯一能人工解除
        -- backorder_at 的地方。所以另外回一個 backorder，讓還有人在等的組別
        -- 一定看得到入口，也讓店家知道「這組還有 N 件沒配到」。
        SELECT COALESCE(SUM(coi.qty), 0) AS backorder
          FROM customer_orders co
          JOIN customer_order_items coi
            ON coi.order_id = co.id
           AND coi.sku_id   = pw.sku_id
           AND coi.status IN ('pending', 'reserved', 'ready')
           AND coi.backorder_at IS NOT NULL
         WHERE co.tenant_id       = pw.tenant_id
           AND co.campaign_id     = pw.campaign_id
           AND co.pickup_store_id = pw.store_id
           AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
           AND (co.transferred_from_order_id IS NULL OR EXISTS (
                  SELECT 1 FROM customer_orders src
                   WHERE src.id = co.transferred_from_order_id
                     AND src.pickup_store_id = co.pickup_store_id))
           AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      ) bo
      CROSS JOIN LATERAL (
        -- 20260811(7)：同一 (團,店,SKU) 的「其他」已收批次實收量。
        -- 沒有這一項，第二批到貨會被當成「這團只到了這麼多」，
        -- 第一批早就收進來的量憑空消失 → 假短少。
        -- 條件比照 rpc_get_allocation_candidates 的 supplied。
        SELECT COALESCE(SUM(ti.qty_received), 0) AS prior
          FROM picking_wave_items p2
          JOIN transfers t       ON t.id = p2.generated_transfer_id
                                AND t.status IN ('received', 'closed')
          JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = pw.sku_id
         WHERE p2.tenant_id            = pw.tenant_id
           AND p2.campaign_id          = pw.campaign_id
           AND p2.store_id             = pw.store_id
           AND p2.sku_id               = pw.sku_id
           AND p2.generated_transfer_id IS DISTINCT FROM pw.tid
      ) pri
  ),
  per_line AS (
    SELECT dem.tid,
           -- over 維持單批語意，不加 prior（見 20260811000060 檔頭）
           GREATEST(dem.shipped - dem.demand, 0)                                  AS over_qty,
           GREATEST(dem.demand - dem.prior - dem.shipped - dem.covered, 0)        AS short_qty,
           LEAST(dem.covered, GREATEST(dem.demand - dem.prior - dem.shipped, 0))  AS covered_qty,
           -- 沒在補缺口的減抵量 = 這批到貨其實是補回店家先墊的貨
           LEAST(
             GREATEST(dem.covered
                      - LEAST(dem.covered, GREATEST(dem.demand - dem.prior - dem.shipped, 0)), 0),
             dem.shipped
           ) AS prefilled_qty,
           dem.backorder                                                          AS backorder_qty
      FROM dem
  ),
  per_transfer AS (
    SELECT per_line.tid,
           SUM(per_line.over_qty)      AS over_qty,
           SUM(per_line.short_qty)     AS short_qty,
           SUM(per_line.covered_qty)   AS covered_qty,
           SUM(per_line.prefilled_qty) AS prefilled_qty,
           SUM(per_line.backorder_qty) AS backorder_qty
      FROM per_line
     GROUP BY per_line.tid
    HAVING SUM(per_line.over_qty) > 0
        OR SUM(per_line.short_qty) > 0
        OR SUM(per_line.covered_qty) > 0
        OR SUM(per_line.prefilled_qty) > 0
        OR SUM(per_line.backorder_qty) > 0
  )
  SELECT COALESCE(
           jsonb_object_agg(
             per_transfer.tid::text,
             jsonb_build_object('over', per_transfer.over_qty,
                                'short', per_transfer.short_qty,
                                'covered', per_transfer.covered_qty,
                                'prefilled', per_transfer.prefilled_qty,
                                'backorder', per_transfer.backorder_qty)
           ),
           '{}'::jsonb)
    FROM per_transfer;
$$;

COMMENT ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) IS
  '收貨頁的派出量 vs 訂單需求：over（這一批多給）/ short（還缺幾件）/ '
  'covered（缺口已由店內現貨吸收）/ prefilled（這批是補回店家先墊的貨）/ '
  'backorder（這組還掛著幾件待補貨未解）。'
  'short/covered/prefilled 的供給側含同組其他已收批次的實收量（prior），'
  '多批到貨才不會被算成假短少；over 維持單批語意。'
  '需求側含同店轉單的衍生單、不含跨店轉入單（同 20260807000000 的波次需求守衛）。';

REVOKE ALL ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) TO authenticated;

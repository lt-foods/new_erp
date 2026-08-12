-- ============================================================
-- 2026-08-11 (7)：收貨頁的「短少」要把先前批次已收的量算進去
--
-- 災情（承 20260811000050 那張松山單）：總倉補派第二批 1 瓶到松山，
--   店家收貨頁會標「⚠️ 短少 10」。因為這支是拿
--     這一張 transfer 的派出量(shipped=1)   ← 單批
--   去比
--     該團該店該 SKU 的全期需求(demand=11)  ← 含已領走的 10 件
--   兩邊的時間尺度根本不同一套。第一批的 10 件明明已經收進來、也發給客人了，
--   在這個算式裡完全不存在。
--
--   後果不只是數字難看：那個 short 就是收貨頁「⚖️ 配貨」按鈕的顯示條件
--   （wms/inbound/page.tsx：summary.shortQty > 0 || coveredQty > 0），
--   而少發配貨正是唯一能解除 backorder_at 的人工入口。店員看到補 1 瓶卻寫
--   「短少 10」，第一反應是「總倉又出錯了」而不是進去配貨。
--
-- 影響範圍（線上實測，349 個 (團,店,SKU) 已經是多批到貨）：
--   目前 283 張 transfer 標著短少，其中 178 張（合計 1,002 件）在修完之後
--   歸零 —— 全是先前批次早就補齊、只是這支看不到的假短少。
--   沒有任何一張的 short 變大（實測 short_worse = 0）。
--
-- 修法：需求側不動（維持含已取貨，見 20260805000220 的說明），只把供給側
--   補上 prior —— 同一 (團,店,SKU) 的**其他**已收 transfer 的實收量：
--     short     = GREATEST(demand − prior − shipped − covered, 0)
--     covered   = LEAST(covered, GREATEST(demand − prior − shipped, 0))
--     prefilled = LEAST(GREATEST(covered − covered_qty, 0), shipped)   ← 仍夾在本批派出量內
--   prior 的算法逐字比照 rpc_get_allocation_candidates 的 supplied
--   （t.status IN ('received','closed')），彈窗與外面的徽章才會對得起來。
--
--   **over 刻意不動**（維持 GREATEST(shipped − demand, 0)）：它是「這一批派出量
--   超過訂單需求」的單批警示，語意跟 short 不同。把 prior 加進 over 會讓 438 張
--   歷史 transfer 突然亮起「多給」，那是另一個題目，不順手夾帶。
--
--   另外新增回傳欄位 backorder = 這組還掛著幾件待補貨未解。修掉假短少之後，
--   short 歸零的組別會連帶失去「⚖️ 配貨」入口（顯示條件是 short>0 || covered>0），
--   而那是唯一能人工解除 backorder_at 的地方 —— 20260811000050 的自動解除
--   有實體庫存守衛，帳上有、架上沒有時不會放行，那種情況更需要人進去看。
--   所以還有人在等的組別一律保留入口，並在收貨頁標「⏳ 待補貨 N 件」。
--
-- 基底版本：20260805000220_ship_vs_demand_prefilled 的
--   rpc_get_ship_vs_demand_for_transfers（最新版；20260805000190 只動 candidates）
-- rollback: 重跑 20260805000220 的 rpc_get_ship_vs_demand_for_transfers。
-- ============================================================

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
           AND co.transferred_from_order_id IS NULL
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
           AND co.transferred_from_order_id IS NULL
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
           -- over 維持單批語意，不加 prior（見檔頭）
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
  '多批到貨才不會被算成假短少；over 維持單批語意。';

REVOKE ALL ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) TO authenticated;

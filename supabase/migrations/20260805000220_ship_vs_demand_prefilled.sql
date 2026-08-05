-- ============================================================
-- 收貨頁標示「這批有幾件是補回店家先墊的現貨」
--
-- 動機：店家用店內現貨先把客人的貨交掉（庫存減抵單 / 加單頁現貨直售）之後，
--   總倉那批貨還是會來 —— 因為派貨分貨的需求量把「已取貨」的品項也算進去
--   （只排除 cancelled/expired，見 v_picking_demand / arrive_auto_allocations）。
--   那批到貨實質上是「把店家先墊的貨補回架上」，但收貨頁看起來就是一張普通的單：
--   缺口已經是 0（demand = shipped），covered 被 GREATEST(demand−shipped,0) 夾成 0，
--   標籤不會亮。店家會困惑「這件我明明已經賣掉了，怎麼又來？」
--
-- 做法：多回一個 prefilled —— 該組減抵單裡「沒有在補缺口、而是由本批到貨補回」的量。
--   prefilled = LEAST(減抵總量 − 本線已算進 covered 的量, 本線派出量)
--   covered / short / over 的算法完全不動 → 既有標籤行為零改變。
--
-- 例：訂單 1、店家現貨先交 1（減抵單 1）、總倉照樣派 1
--     demand=1, shipped=1 → short=0, over=0, covered=0, prefilled=1
-- 例（20260805000060 的少發情境）：訂單 8、到貨 6、減抵 2
--     covered=2（在補缺口）, prefilled=LEAST(2−2, 6)=0 → 不會重複標
--
-- 基底版本：20260805000180_offset_orders_count_as_coverage 的
--   rpc_get_ship_vs_demand_for_transfers（唯一版本；20260805000190 只動 candidates）
-- rollback: 重跑 20260805000180 的 rpc_get_ship_vs_demand_for_transfers。
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
    SELECT pw.tid, pw.shipped, d.demand, cov.covered
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
  ),
  per_line AS (
    SELECT dem.tid,
           GREATEST(dem.shipped - dem.demand, 0)               AS over_qty,
           GREATEST(dem.demand - dem.shipped - dem.covered, 0) AS short_qty,
           LEAST(dem.covered, GREATEST(dem.demand - dem.shipped, 0)) AS covered_qty,
           -- 沒在補缺口的減抵量 = 這批到貨其實是補回店家先墊的貨
           LEAST(
             GREATEST(dem.covered - LEAST(dem.covered, GREATEST(dem.demand - dem.shipped, 0)), 0),
             dem.shipped
           ) AS prefilled_qty
      FROM dem
  ),
  per_transfer AS (
    SELECT per_line.tid,
           SUM(per_line.over_qty)      AS over_qty,
           SUM(per_line.short_qty)     AS short_qty,
           SUM(per_line.covered_qty)   AS covered_qty,
           SUM(per_line.prefilled_qty) AS prefilled_qty
      FROM per_line
     GROUP BY per_line.tid
    HAVING SUM(per_line.over_qty) > 0
        OR SUM(per_line.short_qty) > 0
        OR SUM(per_line.covered_qty) > 0
        OR SUM(per_line.prefilled_qty) > 0
  )
  SELECT COALESCE(
           jsonb_object_agg(
             per_transfer.tid::text,
             jsonb_build_object('over', per_transfer.over_qty,
                                'short', per_transfer.short_qty,
                                'covered', per_transfer.covered_qty,
                                'prefilled', per_transfer.prefilled_qty)
           ),
           '{}'::jsonb)
    FROM per_transfer;
$$;

COMMENT ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) IS
  '每張派貨單的派出量 vs 訂單需求量：over（多給）/ short（不夠分，已淨掉 coverage）/ '
  'covered（缺口由店內現貨吸收）/ prefilled（本批是補回店家先墊的現貨）。'
  'coverage = 庫存減抵單 + 抵減單（負數訂單）。';

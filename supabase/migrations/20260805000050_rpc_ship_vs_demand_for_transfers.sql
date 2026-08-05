-- ============================================================
-- rpc_get_ship_vs_demand_for_transfers：每張派貨單的「派出量 vs 訂單需求量」差額
--   → { "<transfer_id>": { "over": <多給件數>, "short": <不夠分的件數> } }
--   兩邊都是 0 的單不回傳。
--
-- 取代 20260805000040 的 rpc_get_over_ship_for_transfers（只算多給的那一半）。
--
-- 為什麼要補 short：2026-08-05 松山店 / 永和店的阿猴鮮奶（G01476-01）各派 10 瓶、
--   訂單 11 瓶。店端收貨沒有短收（派 10 收 10），缺口是排波次時就少排了
--   （全團訂單 107、波次只排 105，而採購實收 120，總倉根本有貨）。
--   店家在收貨當下完全看不出這批不夠分，等到最後一位客人上門才發現沒貨。
--   這個差額是文件層的事實（訂單 vs 派出），不依賴會漂移的店內庫存餘額。
--
-- 為什麼不用「店內庫存 < 未取訂單量」當警示：線上實測光松山＋永和兩家店就有
--   15 個以上品項符合，還有 on_hand 是負數的（-4）。店內餘額不可靠，拿來當
--   警示只會變成天天在叫的狼來了。
--
-- 需求量的 join 與 rpc_get_orders_for_transfer 的 wave 路線一致，
--   標籤上的件數 = 彈窗裡「派出 − 訂單合計」。
-- campaign_id IS NULL 的線（補貨直送）沒有顧客訂單，兩邊都不算。
--
-- 基底版本：20260805000040_rpc_get_over_ship_for_transfers（本檔一併 DROP 舊函式）
-- rollback: DROP FUNCTION IF EXISTS public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]);
--           並重跑 20260805000040。
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_get_over_ship_for_transfers(BIGINT[]);

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
    SELECT pw.tid, pw.shipped, d.demand
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
  ),
  per_transfer AS (
    SELECT dem.tid,
           SUM(GREATEST(dem.shipped - dem.demand, 0)) AS over_qty,
           SUM(GREATEST(dem.demand - dem.shipped, 0)) AS short_qty
      FROM dem
     GROUP BY dem.tid
    HAVING SUM(GREATEST(dem.shipped - dem.demand, 0)) > 0
        OR SUM(GREATEST(dem.demand - dem.shipped, 0)) > 0
  )
  SELECT COALESCE(
           jsonb_object_agg(
             per_transfer.tid::text,
             jsonb_build_object('over', per_transfer.over_qty,
                                'short', per_transfer.short_qty)
           ),
           '{}'::jsonb)
    FROM per_transfer;
$$;

-- Postgres 預設把新函式的 EXECUTE 給 PUBLIC；這支是 SECURITY DEFINER，
-- 雖然只吐數字，仍不該讓 anon 拿來探測各店各團的出貨與訂單量。
REVOKE ALL ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) TO authenticated;

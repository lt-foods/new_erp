-- ============================================================
-- rpc_get_over_ship_for_transfers：批次算出每張派貨單「沒有訂單對應」的件數
--   → { "<transfer_id>": <多給件數>, ... }，只回多給 > 0 的單。
--
-- 為什麼不是比 picking_wave_items.picked_qty > qty：
--   線上實測 picking_wave_items 17429 列裡 over_pick = 0（撿貨端不會撿超過應發，
--   短撿才有 2 筆）。用那個定義做出來的「總倉多給」標籤永遠不會亮。
--   店家講的多給是「派來的量比店裡的訂單還多」——派出量 vs 該店該團的訂單需求量，
--   同一批待收實測 1619 條線裡有 22 條、合計 88 件是這種情況。
--
-- 需求量的 join 與 rpc_get_orders_for_transfer 的 wave 路線完全一致
--   （picking_wave_items 的 campaign_id + store_id + sku_id → customer_orders），
--   所以標籤上的件數 = 彈窗裡「派出 − 訂單合計」，兩邊不會對不起來。
--
-- campaign_id IS NULL 的線（補貨直送，線上 585 列）本來就沒有顧客訂單，
--   不納入計算，否則整批補貨都會被誤標成多給。
--
-- 基底版本：新函式，無前版。
-- rollback: DROP FUNCTION IF EXISTS public.rpc_get_over_ship_for_transfers(BIGINT[]);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_get_over_ship_for_transfers(
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
    SELECT dem.tid, SUM(dem.shipped - dem.demand) AS extra
      FROM dem
     WHERE dem.shipped > dem.demand
     GROUP BY dem.tid
  )
  SELECT COALESCE(jsonb_object_agg(per_transfer.tid::text, per_transfer.extra), '{}'::jsonb)
    FROM per_transfer;
$$;

-- Postgres 預設把新函式的 EXECUTE 給 PUBLIC；這支是 SECURITY DEFINER 且會吐出
-- 顧客姓名 / 電話（nickname_snapshot 內含手機），不 REVOKE 的話拿 anon key 就查得到。
REVOKE ALL ON FUNCTION public.rpc_get_over_ship_for_transfers(BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_over_ship_for_transfers(BIGINT[]) TO authenticated;

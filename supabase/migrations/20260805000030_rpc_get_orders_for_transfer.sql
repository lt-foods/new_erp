-- ============================================================
-- rpc_get_orders_for_transfer：一張派貨單（可再指定單一品項）背後的顧客訂單明細
--
-- 動機：/wms/inbound 收貨待辦要能點開數量看「這幾件是誰的訂單」。總倉多撿給的
--   量本來就沒有訂單對應，把訂單一筆筆列出來、跟派出量相減，多給多少一眼可見。
--
-- 為什麼要這樣 join：transfer_items 上沒有任何 campaign / order / wave 欄位，
--   訂單與派貨單之間也沒有分配表。唯一的硬連結是
--   picking_wave_items.generated_transfer_id → transfers.id，
--   再靠 picking_wave_items 的 (campaign_id, store_id, sku_id) 對回訂單。
--   這個 join 形狀直接沿用 is_order_item_pickup_ready 的 Path B
--   （20260704000000_item_level_pickup_gate.sql:87-99），保持與取貨閘門同一套判定。
--
-- 三條來源，同一張單同一個品項的同一筆訂單只留優先度最高的一條：
--   wave      撿貨波次（最準，campaign 被 picking_wave_items 綁死）
--   aid       互助 / 轉單，transfers.customer_order_id 直接指到訂單
--   store_sku 沒有波次或波次沒帶 campaign（補貨直送、彙總請購）時的退路，
--             只用「取貨店 + 品項」比對 → 會多抓到別團的訂單，前端要標示為約略值
--
-- (co.order_kind = 'normal' OR co.order_kind IS NULL) 而不是 COALESCE(...)：
--   COALESCE 不可 sarg，planner 會把 join order 帶歪（見 20260720000040 的實測）。
--
-- 基底版本：新函式，無前版。
-- rollback: DROP FUNCTION IF EXISTS public.rpc_get_orders_for_transfer(BIGINT, BIGINT);
-- ============================================================

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
       AND co.transferred_from_order_id IS NULL
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
  from_store AS (
    -- 只補「wave 路線完全對不到」的品項，避免蓋掉精準結果
    SELECT coi.sku_id       AS r_sku_id,
           co.id            AS r_order_id,
           co.order_no      AS r_order_no,
           COALESCE(m.name, co.nickname_snapshot) AS r_customer,
           co.status        AS r_status,
           SUM(coi.qty)     AS r_qty,
           co.campaign_id   AS r_campaign_id,
           'store_sku'::text AS r_match_kind
      FROM t
      JOIN stores s
        ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
      JOIN customer_orders co
        ON co.pickup_store_id = s.id
       AND co.tenant_id       = t.tenant_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND co.transferred_from_order_id IS NULL
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.status NOT IN ('cancelled', 'expired')
      JOIN want w ON w.want_sku_id = coi.sku_id
      LEFT JOIN members m ON m.id = co.member_id
     WHERE NOT EXISTS (
             SELECT 1 FROM from_wave fw WHERE fw.r_sku_id = coi.sku_id
           )
       AND NOT EXISTS (
             SELECT 1 FROM from_aid fa WHERE fa.r_sku_id = coi.sku_id
           )
     GROUP BY coi.sku_id, co.id, co.order_no, m.name, co.nickname_snapshot,
              co.status, co.campaign_id
  ),
  unioned AS (
    SELECT * FROM from_wave
    UNION ALL SELECT * FROM from_aid
    UNION ALL SELECT * FROM from_store
  )
  SELECT DISTINCT ON (u.r_sku_id, u.r_order_id)
         u.r_sku_id, u.r_order_id, u.r_order_no, u.r_customer,
         u.r_status, u.r_qty, u.r_campaign_id, u.r_match_kind
    FROM unioned u
   ORDER BY u.r_sku_id, u.r_order_id,
            CASE u.r_match_kind WHEN 'wave' THEN 1 WHEN 'aid' THEN 2 ELSE 3 END;
$$;

-- Postgres 預設把新函式的 EXECUTE 給 PUBLIC；這支是 SECURITY DEFINER 且會吐出
-- 顧客姓名 / 電話（nickname_snapshot 內含手機），不 REVOKE 的話拿 anon key 就查得到。
REVOKE ALL ON FUNCTION public.rpc_get_orders_for_transfer(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_orders_for_transfer(BIGINT, BIGINT) TO authenticated;

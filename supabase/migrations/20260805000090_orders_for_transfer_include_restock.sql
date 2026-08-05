-- ============================================================
-- rpc_get_orders_for_transfer v2：補貨單也要看得到它的補貨申請
--
-- 動機：湖口店 WAVE-875-S49（transfer 8624）點數量看訂單是空的，我上一版把它
--   標成「補貨（無顧客訂單）」——講錯了。它背後有單：RR-247，一張
--   order_kind='restock' 的 customer_orders（id 65983、湖口店、8/3 03:26 建立，
--   波次 03:31 建立），5 個品項與這張派貨單的 5 個 SKU 一對一（申請 1/2/2/1/1、
--   派出 1/2/2/1/2）。v1 的 (co.order_kind='normal' OR IS NULL) 把它濾掉了。
--
-- 補貨這條路的資料形狀跟開團不一樣，要另外處理：
--   1. picking_wave_items.campaign_id 是 NULL（不是開團派的），wave 路線對不到。
--   2. RR 單的品項在轉出後會被設成 cancelled，並長出
--      __INTERNAL_RESTOCK__-TFxxxx 子單（transferred_from_order_id 指回 RR）。
--      那是內部帳的搬運，不是「這張補貨申請不算數」——所以 restock 這條
--      刻意不套 coi.status 的排除條件，否則畫面又會變成空的。
--   子單本身仍被 transferred_from_order_id IS NULL 擋掉，不會跟母單重複列出。
--
-- 來源優先序：wave > aid > restock > store_sku。
--
-- 基底版本：20260805000030_rpc_get_orders_for_transfer（v1）
-- rollback: 重跑 20260805000030。
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
  from_restock AS (
    -- 補貨申請（RR-xxx，order_kind='restock'）：同店 + 同品項。
    -- 這條刻意不排除 coi.status = 'cancelled' —— 見檔頭說明。
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
       AND co.transferred_from_order_id IS NULL
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

-- ============================================================
-- v_order_shortage v5：前瞻模型（v4）＋「這一輪團的採購已定案」閘門
--
-- 事故案例（本次修法動機）：
--   2026-08-11 /wms/exceptions「訂單短少」266 列，抽查後 260 列是誤報：
--
--   A. 還在收單的團就先爆警報（177 列 / 172 單 / 307 件，最大宗）
--      GRP-20260806-009 厚實鮭魚菲力、GRP-20260807-001 土雞蛋、
--      GRP-20260807-002 小卷炊粉、GRP-20260806-005 海鮮煎餅、
--      GRP-20260806-008 牛三寶 —— 全部 status='open'、end_at=2026-08-11
--      （當天才結單），這幾支 SKU 八月的 PO 一張都沒有（本來就還沒到
--      下採購單的時候）。但線上 v3 的「採購已定案」閘門是**SKU 層級**的
--      （該 SKU 存在 sent/partial/fully/closed 的 PO 就判），這幾支 SKU
--      六月/七月的舊團各有一張 fully_received 的舊 PO → 閘門成立，
--      供給欄只認得到舊團的累計收貨（G00075-02 只有 27 件、
--      G00199-01 125 件…），新團一開賣就整團掛短缺。
--      ＝「同一支 SKU 只要開過一次團，之後每一輪都會在結單前先被判短缺」。
--
--   B. 貨已經到店的單還算在需求裡（41 列 / 34 單 / 208 件）
--      RR-373/376/377/381/392、__INTERNAL_RESTOCK__-TF0381/TF0393 這些
--      補貨/現貨池單 status 已是 ready（貨真的在店裡），v3 的需求集合是
--      「非終態訂單」，ready 也算 → G01203-01 智利鮭魚頭需求 253 件裡
--      241 件是 ready，累計收貨 223 → 假短缺 30。
--      （＝ 20260801000000_v_order_shortage_v4 檔頭寫的「破洞 2」。）
--
-- 修法：v4 前瞻模型補回線上，並把閘門從 SKU 層級改成 campaign×sku 層級。
--
--   需求 = 還沒拿到貨的品項：
--     coi.status='pending' AND co.status IN ('pending','confirmed','shipping')
--     （ready/completed = 貨已到店，離開需求池 → B 消失）
--     抵減單（order_kind='offset'，負數量）不論 pending/confirmed/ready
--     都保留在需求裡（會計性抵減、不是待送達的貨；線上 13 列 -26 件掛在
--     ready 單上，若隨 ready 一起被排除會虛增需求）。
--   供給 = 經總倉現貨 on_hand（含盤點/調帳來的貨，不限 PO/GR 管道）
--        + PO 在途（sent/partially_received 未收餘量，且 stockout_at IS NULL）
--        + 調撥在途（transfers.status='shipped' 的 qty_shipped）。
--     累計 GR 不再進判定（total_gr 保留為純資訊欄）。
--   閘門 = **這張訂單所屬的 campaign×sku 有一張定案 PO** 才判短缺。
--     po_item ↔ campaign 的對應沿用 v_picking_demand_by_po 的 po_campaigns
--     寫法（purchase_request_campaigns UNION purchase_request_items
--     .source_campaign_id），不要另外自己定義。→ A 消失。
--   短缺 = GREATEST(0, 需求 − 供給)，用線上現行的 LIFO 拆行分攤
--     （見下方「線上 drift」）。
--
-- 模型自癒：採購開單 → 閘門成立、在途進供給；盤點加貨 → on_hand 上升；
--   波次出貨 → 轉調撥在途；店端收貨 → 訂單 ready 離開需求。
--
-- 線上 drift（本檔一併收編，別再被沖掉）：
--   1. repo 的 20260801000000_v_order_shortage_v4_forward_looking.sql
--      從來沒部署過；20260807000000_same_store_transfer_before_arrival.sql
--      以「線上現行定義」為基底重寫時收錄的是 po_item_stockout 的 v3 分支，
--      等於把 v4 蓋掉。本檔＝v4 的模型 + 20260807000000 的同店衍生單規則。
--   2. 線上現行版本另有一段 **repo 從來沒有的 LIFO 拆行 hotfix**：
--        newer_qty = 同 SKU 內比自己新的單的數量累計（created_at DESC, coi.id DESC）
--        demand_unfulfillable = LEAST(order_qty, CEIL(shortage) − newer_qty)
--      ＝ 短缺一律扣在**最新**下單的人身上（先到先得），不是 v4 的比例分攤。
--      這是業務規則，本檔原樣保留。
--
-- 2026-08-11 線上 dry-run（現行 266 列 → 本檔 366 列）：
--   保留 6 列（GRP-20260709-013 迷你桌面吸塵器，7/9 卡 confirmed、GR 0 → 真短缺）
--   消失 260 列（上述 A + B 全部）
--   新增 360 列 / 152 SKU：全部是 5/25–7/28 建立、卡在 shipping/confirmed
--     的存量殭屍單，其中 326 列的取貨店現貨為 0、總倉現貨 0、無在途
--     —— 沒有任何東西會再把貨送過去，正是 v3 用累計 GR 掩蓋掉的真異常
--     （v4 檔頭的「破洞 3」）。另 40 列貨其實在店裡、只是單頭狀態沒推進，
--     屬 20260811000020 修的那一類，下批到貨會自然收斂。
--   ⚠️ 這 360 列都是 shortage_resolution IS NULL 的未處理單，套用後
--      收件匣「訂單短少」會從 266 跳到 366，需要 HQ 實際去收。
--
-- 欄位：與線上完全同名同序同型別，下游 v_hq_exceptions、v_hq_inbox、
--   rpc_hq_shortage_orders、rpc_hq_inbox_search、前端
--   hq/inbox/page.tsx 的 .from("v_order_shortage") 全部免改。
--
-- 已知邊界（有意取捨）：
--   - 全域 pooling 沿用 v2~v4：店 A 的在途/現貨帳面可蓋店 B 的需求。
--   - 分店貨架庫存不算供給（那是 ready 單與零售的貨，算入會雙重計）。
--   - draft PO 不算供給、也不算定案：採購擬單期間不判短缺。
--   - 補貨單（RR- /【內部】xx 店，campaign 806 __INTERNAL_RESTOCK__）
--     永遠對不到 po_campaigns（補貨 PR 不帶 source_campaign_id、也不進
--     purchase_request_campaigns）→ 一律不判短缺。它們的供給來源是總倉
--     現貨/調撥而不是採購批次，缺口在 /wms/restock 與「收貨短少」已有
--     專屬流程，放進這裡只會製造重複帳（B 就是這樣來的）。
--   - 跨店衍生單維持排除、同店衍生單保留（20260807000000 的規則）。
--
-- 基於：線上 pg_get_viewdef 逐字取回的現行定義（v3 + stockout 閘 +
--   同店衍生單 + LIFO 拆行 hotfix），模型部分換成
--   20260801000000_v_order_shortage_v4_forward_looking.sql 的前瞻算法。
-- Rollback：CREATE OR REPLACE VIEW 回
--   20260807000000_same_store_transfer_before_arrival.sql 的第 5 節，
--   再手動補回上述 LIFO 拆行 hotfix（該檔內文是比例分攤版，直接回退會
--   連 LIFO 一起掉）。
-- ============================================================

CREATE OR REPLACE VIEW public.v_order_shortage AS
WITH
-- 1. po_item ↔ campaign 對應（與 v_picking_demand_by_po.po_campaigns 同一套）
po_campaigns AS (
  SELECT DISTINCT u.po_item_id, u.campaign_id
  FROM (
    SELECT poi.id AS po_item_id, prc.campaign_id
      FROM purchase_order_items poi
      JOIN purchase_request_items pri      ON pri.po_item_id = poi.id
      JOIN purchase_requests pr            ON pr.id = pri.pr_id
      JOIN purchase_request_campaigns prc  ON prc.pr_id = pr.id
    UNION
    SELECT poi.id AS po_item_id, pri.source_campaign_id AS campaign_id
      FROM purchase_order_items poi
      JOIN purchase_request_items pri ON pri.po_item_id = poi.id
     WHERE pri.source_campaign_id IS NOT NULL
  ) u
),
-- 2. 閘門：這一輪團的這支 SKU 採購已定案（沒有列 = 不判短缺，等採購開單）
settled_campaign_sku AS (
  SELECT DISTINCT pc.campaign_id, poi.sku_id
    FROM po_campaigns pc
    JOIN purchase_order_items poi ON poi.id = pc.po_item_id
    JOIN purchase_orders po       ON po.id = poi.po_id
   WHERE po.status IN ('sent', 'partially_received', 'fully_received', 'closed')
),
-- 3. PO 供給：sent/partial 未收餘量（斷貨品項不算，20260801000000）；
--    total_gr 為歷史累計，純資訊欄，不進判定
settled_po_supply AS (
  SELECT poi.sku_id,
         SUM(COALESCE(g.gr_qty, 0)) AS total_gr,
         SUM(CASE WHEN po.status IN ('sent', 'partially_received')
                   AND poi.stockout_at IS NULL
                  THEN GREATEST(0, poi.qty_ordered - COALESCE(g.gr_qty, 0))
                  ELSE 0
             END) AS po_in_transit
    FROM purchase_orders po
    JOIN purchase_order_items poi ON poi.po_id = po.id
    LEFT JOIN (
      SELECT gri.po_item_id, SUM(gri.qty_received) AS gr_qty
        FROM goods_receipt_items gri
        JOIN goods_receipts gr ON gr.id = gri.gr_id
       WHERE gr.status = 'confirmed'
       GROUP BY gri.po_item_id
    ) g ON g.po_item_id = poi.id
   WHERE po.status IN ('sent', 'partially_received', 'fully_received', 'closed')
   GROUP BY poi.sku_id
),
-- 4. 經總倉現貨：含盤點調整/手動調帳進來的貨（不限 PO/GR 管道）
hq_on_hand AS (
  SELECT sb.sku_id, SUM(sb.on_hand) AS hq_on_hand
    FROM stock_balances sb
    JOIN locations l ON l.id = sb.location_id
   WHERE l.type = 'central_warehouse' AND l.is_active = TRUE
   GROUP BY sb.sku_id
),
-- 5. 調撥在途：已出貨未收貨（shipping 單的貨在車上）
xfer_in_transit AS (
  SELECT ti.sku_id, SUM(ti.qty_shipped) AS xfer_in_transit
    FROM transfer_items ti
    JOIN transfers t ON t.id = ti.transfer_id
   WHERE t.status = 'shipped'
   GROUP BY ti.sku_id
),
-- 6. 已撿+已派（純資訊欄位，不影響短缺判定）
allocated_per_sku_store AS (
  SELECT sku_id, store_id,
         SUM(wave_qty)    AS total_wave,
         SUM(shipped_qty) AS total_shipped
    FROM v_picking_demand_by_po
   WHERE store_id IS NOT NULL
   GROUP BY sku_id, store_id
),
allocated_per_sku AS (
  SELECT sku_id, SUM(total_wave) AS total_wave, SUM(total_shipped) AS total_shipped
    FROM allocated_per_sku_store
   GROUP BY sku_id
),
-- 7. 未到貨需求（過閘門）：pending 品項 × pending/confirmed/shipping 訂單；
--    抵減單（負數量）非終態全算；同店衍生單保留、跨店衍生單排除
demand_rows AS (
  SELECT co.id  AS order_id,
         coi.id AS order_item_id,
         coi.sku_id,
         coi.qty,
         co.created_at AS order_created_at
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN settled_campaign_sku scs
      ON scs.campaign_id = co.campaign_id AND scs.sku_id = coi.sku_id
   WHERE co.pickup_store_id IS NOT NULL
     AND coi.status NOT IN ('cancelled', 'expired')
     AND (co.transferred_from_order_id IS NULL
          OR EXISTS (SELECT 1 FROM customer_orders src
                      WHERE src.id = co.transferred_from_order_id
                        AND src.pickup_store_id = co.pickup_store_id))
     AND (
       (COALESCE(co.order_kind, 'normal') <> 'offset'
         AND co.status IN ('pending', 'confirmed', 'shipping')
         AND coi.status = 'pending')
       OR
       (co.order_kind = 'offset'
         AND co.status NOT IN ('cancelled', 'expired', 'transferred_out'))
     )
),
demand_per_sku AS (
  SELECT sku_id, SUM(qty) AS total_demand FROM demand_rows GROUP BY sku_id
),
-- 8. SKU 層級短缺判定
sku_shortage AS (
  SELECT d.sku_id,
         d.total_demand,
         COALESCE(s.total_gr, 0) AS total_gr,
         COALESCE(s.po_in_transit, 0) + COALESCE(x.xfer_in_transit, 0) AS total_in_transit,
         COALESCE(a.total_wave, 0)    AS total_wave,
         COALESCE(a.total_shipped, 0) AS total_shipped,
         GREATEST(0, d.total_demand
                     - COALESCE(h.hq_on_hand, 0)
                     - COALESCE(s.po_in_transit, 0)
                     - COALESCE(x.xfer_in_transit, 0)) AS sku_shortage_qty
    FROM demand_per_sku d
    LEFT JOIN settled_po_supply s ON s.sku_id = d.sku_id
    LEFT JOIN hq_on_hand h        ON h.sku_id = d.sku_id
    LEFT JOIN xfer_in_transit x   ON x.sku_id = d.sku_id
    LEFT JOIN allocated_per_sku a ON a.sku_id = d.sku_id
   WHERE d.total_demand > COALESCE(h.hq_on_hand, 0)
                        + COALESCE(s.po_in_transit, 0)
                        + COALESCE(x.xfer_in_transit, 0)
),
-- 9. 展開到 order_item：LIFO — 短缺扣在最新下單的人身上（線上 hotfix，保留）
expanded AS (
  SELECT dr.order_id, dr.order_item_id, dr.sku_id,
         dr.qty AS order_qty, dr.order_created_at,
         ss.total_demand, ss.total_gr, ss.total_in_transit,
         ss.total_wave, ss.total_shipped, ss.sku_shortage_qty,
         SUM(dr.qty) OVER (PARTITION BY dr.sku_id
                           ORDER BY dr.order_created_at DESC, dr.order_item_id DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) - dr.qty AS newer_qty
    FROM demand_rows dr
    JOIN sku_shortage ss ON ss.sku_id = dr.sku_id
   WHERE dr.qty > 0
     AND ss.sku_shortage_qty > 0
)
SELECT co.tenant_id,
       e.order_id,
       co.order_no,
       co.member_id,
       co.pickup_store_id AS store_id,
       st.name            AS store_name,
       co.status          AS order_status,
       co.shortage_notified_at,
       co.shortage_resolution,
       co.shortage_resolution_at,
       e.order_item_id,
       e.sku_id,
       s.sku_code,
       s.product_name,
       s.variant_name,
       e.order_qty,
       e.total_demand,
       e.total_gr,
       e.total_in_transit,
       e.total_wave,
       e.total_shipped,
       e.sku_shortage_qty AS total_supplier_shortage,
       LEAST(e.order_qty::NUMERIC, CEIL(e.sku_shortage_qty) - e.newer_qty) AS demand_unfulfillable,
       e.order_created_at,
       co.updated_at      AS order_updated_at
  FROM expanded e
  JOIN customer_orders co ON co.id = e.order_id
  LEFT JOIN skus s    ON s.id = e.sku_id
  LEFT JOIN stores st ON st.id = co.pickup_store_id
 WHERE (CEIL(e.sku_shortage_qty) - e.newer_qty) > 0;

GRANT SELECT ON public.v_order_shortage TO authenticated;

COMMENT ON VIEW public.v_order_shortage IS
  '短缺訂單看板 v5：未到貨需求（pending 品項 × pending/confirmed/shipping 訂單）'
  ' vs 現在拿得出的貨（經總倉現貨 + PO 在途 + 調撥在途）。'
  '閘門改為 campaign×sku 層級（這一輪團有定案 PO 才判；SKU 層級會讓還在收單的新團一開賣就爆警報）。'
  'ready/completed 單＝貨已到店、離開需求池；抵減單（offset，負量）非終態全算需求。'
  '累計 GR 不再進判定（total_gr 為純資訊欄）。分攤為 LIFO：短缺扣在最新下單者身上。'
  '補貨單（__INTERNAL_RESTOCK__）對不到 campaign PO，一律不判短缺 — 走 /wms/restock 與收貨短少。';

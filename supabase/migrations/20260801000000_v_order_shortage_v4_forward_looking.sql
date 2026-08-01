-- ============================================================
-- v_order_shortage v4：前瞻模型 —「未到貨需求 vs 現在拿得出的貨」
--
-- 事故案例（本次修法動機）：
--   環球店補貨申請 #173（普渡，G00291-02 玉米罐 ×120）7/31 已全數到店
--   （WAVE-762-S52 / transfer 6933、店倉現貨 121），內部訂單 RR-173 卻
--   出現在收件匣「訂單短少」，掛 72.45 件短缺。查證是 v3 累計帳模型的
--   結構性破洞，RR-173 只是症狀之一：
--     1. 非 PO 入庫看不見：這批貨是總倉盤點調整 +240（ST2607300015、
--        movement_type='stocktake_gain'）入帳，不走 PO/GR → v3 供給=63
--        （六月唯一一張 PO），需求 159 → 假短缺 96。
--     2. 終態停在 ready 的單永遠算需求：補貨 ride-along 內部單收貨後
--        即停在 ready（20260717000000 設計如此，不會有會員取貨推進到
--        completed）。線上有 169 張 / 4,700 件這種「已送達的補貨」
--        永遠掛在需求池；會員未取的 ready 單同理。
--     3. 反向也錯 — 累計 GR 掩蓋真短缺：貨早已發給過去的訂單，
--        total_gr 帳上還在，讓現在卡住的單看起來「有貨」。實測
--        G00234-02 / G00651-03 有五、六月起卡在 shipping、HQ 現貨 0、
--        無在途的殭屍單，v3 完全列不出來（正是店家拒收/短收事故
--        後遺症該被看到的單）。
--
-- 修法：整個換成前瞻模型（不再是累計帳）——
--   需求 = 還沒拿到貨的品項：
--     coi.status='pending' AND co.status IN ('pending','confirmed','shipping')
--     （ready/completed = 貨已到店，離開需求池 → 破洞 2 消失）
--     抵減單（order_kind='offset'，負數量）不論 pending/confirmed/ready
--     都保留在需求裡（它是會計性抵減、不是待送達的貨，
--     若因 ready 被排除會虛增需求）。
--   供給 = 經總倉現貨 on_hand（含盤點/調帳來的貨 → 破洞 1 消失）
--        + PO 在途（sent/partially_received 未收餘量，同 v3 算法）
--        + 調撥在途（transfers.status='shipped' 的 qty_shipped，
--          蓋住 shipping 單「貨在車上」的量；方向不限 — 退回總倉的
--          在途貨終會落回 HQ，全網 pooling 一致）。
--     累計 GR 不再進判定 → 破洞 3 消失。
--   閘門 = 保留 v3「採購已定案」INNER JOIN（存在 sent/partial/fully/
--     closed PO 的 SKU 才判）→ 新檔期還沒開 PO 不會爆量。
--   短缺 = GREATEST(0, 需求 − 供給)，按比例展開到 order_item
--     （只展開非 offset 的 pending 品項 — ready 單不再出現在清單）。
--
-- 模型自癒：盤點加貨 → on_hand 上升自動消警報；波次出貨 → 轉調撥
--   在途；店端收貨 → 訂單 ready 離開需求。不需再對入庫管道打補丁。
--
-- 2026-08-01 線上 dry-run：
--   v3：11 SKU / 313 列（含 RR-173、G01095-01 兩類假警報）
--   v4：66 SKU / ~625 列 — RR-173、G01095-01 正確消失；
--     G00192-02（真短缺 33）正確保留；新增的 ~57 顆 SKU 抽驗為
--     存量殭屍單（卡 shipping、無貨無在途），是 v3 漏抓的真異常。
--
-- 欄位：與 v3 完全同名同序同型別，下游 v_hq_exceptions（異常頁）、
--   rpc_hq_shortage_orders（收件匣訂單短少分頁）、v_hq_inbox counts、
--   前端 fetchShortageRowsByIds 全部免改。語意微調：
--     total_in_transit = PO 在途 + 調撥在途（v3 僅 PO 在途）；
--     total_gr 保留為歷史 GR 累計（純資訊欄，不進判定）。
--
-- 已知邊界（有意取捨）：
--   - 全域 pooling 沿用 v2/v3：店 A 的在途/現貨帳面可蓋店 B 的需求。
--   - 分店貨架庫存不算供給（那是 ready 單與零售的貨，算入會雙重計）。
--   - draft PO 不算供給：採購擬單期間仍列警報 —「已定案」語意一致。
--   - 互助單（transferred_from_order_id 非空）維持排除。
--
-- 基於：20260731000010_v_order_shortage_settled_po_gate.sql（v3，最新版）。
-- Rollback：CREATE OR REPLACE VIEW 回 20260731000010 版本。
-- TEST: docs/TEST-order-shortage-v4.md
-- ============================================================

CREATE OR REPLACE VIEW public.v_order_shortage AS
WITH
-- 1.「採購已定案」閘門 + PO 供給：sent/partial 算在途餘量；closed/fully
--    只當閘門與 total_gr 資訊欄。沒有列 = 該 SKU 不判短缺（等採購開單）。
settled_po_supply AS (
  SELECT
    poi.sku_id,
    SUM(COALESCE(g.gr_qty, 0)) AS total_gr,
    SUM(
      CASE WHEN po.status IN ('sent', 'partially_received')
           THEN GREATEST(0, poi.qty_ordered - COALESCE(g.gr_qty, 0))
           ELSE 0
      END
    ) AS po_in_transit
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
-- 2. 經總倉現貨：v4 新供給來源 — 含盤點調整/手動調帳進來的貨
hq_on_hand AS (
  SELECT sb.sku_id, SUM(sb.on_hand) AS hq_on_hand
  FROM stock_balances sb
  JOIN locations l ON l.id = sb.location_id
  WHERE l.type = 'central_warehouse' AND l.is_active = TRUE
  GROUP BY sb.sku_id
),
-- 3. 調撥在途：已出貨未收貨的量（shipping 單的貨在車上）
xfer_in_transit AS (
  SELECT ti.sku_id, SUM(ti.qty_shipped) AS xfer_in_transit
  FROM transfer_items ti
  JOIN transfers t ON t.id = ti.transfer_id
  WHERE t.status = 'shipped'
  GROUP BY ti.sku_id
),
-- 已撿+已派（沿用 v3：純資訊欄位，不影響短缺判定）
allocated_per_sku AS (
  SELECT sku_id,
    SUM(wave_qty)    AS total_wave,
    SUM(shipped_qty) AS total_shipped
  FROM v_picking_demand_by_po
  WHERE store_id IS NOT NULL
  GROUP BY sku_id
),
-- 4. 未到貨需求：pending 品項 × pending/confirmed/shipping 訂單；
--    抵減單（負數量）非 cancelled 全算
unfulfilled_demand AS (
  SELECT coi.sku_id, SUM(coi.qty) AS total_demand
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  WHERE co.transferred_from_order_id IS NULL
    AND co.pickup_store_id IS NOT NULL
    AND coi.status NOT IN ('cancelled', 'expired')
    AND (
      (co.order_kind <> 'offset'
        AND co.status IN ('pending', 'confirmed', 'shipping')
        AND coi.status = 'pending')
      OR
      (co.order_kind = 'offset'
        AND co.status NOT IN ('cancelled', 'expired', 'transferred_out'))
    )
  GROUP BY coi.sku_id
),
-- 5. SKU 層級短缺判定：INNER JOIN settled_po_supply = 採購定案閘門
sku_shortage AS (
  SELECT
    d.sku_id,
    d.total_demand,
    COALESCE(s.total_gr, 0) AS total_gr,
    COALESCE(s.po_in_transit, 0) + COALESCE(x.xfer_in_transit, 0) AS total_in_transit,
    COALESCE(a.total_wave, 0)    AS total_wave,
    COALESCE(a.total_shipped, 0) AS total_shipped,
    GREATEST(0,
      d.total_demand
        - COALESCE(h.hq_on_hand, 0)
        - COALESCE(s.po_in_transit, 0)
        - COALESCE(x.xfer_in_transit, 0)
    ) AS sku_shortage_qty
  FROM unfulfilled_demand d
  JOIN settled_po_supply s ON s.sku_id = d.sku_id
  LEFT JOIN hq_on_hand h      ON h.sku_id = d.sku_id
  LEFT JOIN xfer_in_transit x ON x.sku_id = d.sku_id
  LEFT JOIN allocated_per_sku a ON a.sku_id = d.sku_id
  WHERE d.total_demand >
        COALESCE(h.hq_on_hand, 0)
      + COALESCE(s.po_in_transit, 0)
      + COALESCE(x.xfer_in_transit, 0)
)
-- 6. 展開到 order_item：只展開「還沒拿到貨」的品項，按需求比例分攤
SELECT
  co.tenant_id,
  co.id              AS order_id,
  co.order_no,
  co.member_id,
  co.pickup_store_id AS store_id,
  st.name            AS store_name,
  co.status          AS order_status,
  co.shortage_notified_at,
  co.shortage_resolution,
  co.shortage_resolution_at,
  coi.id             AS order_item_id,
  coi.sku_id,
  s.sku_code,
  s.product_name,
  s.variant_name,
  coi.qty            AS order_qty,
  ss.total_demand,
  ss.total_gr,
  ss.total_in_transit,
  ss.total_wave,
  ss.total_shipped,
  ss.sku_shortage_qty AS total_supplier_shortage,
  ROUND(coi.qty::NUMERIC * ss.sku_shortage_qty / NULLIF(ss.total_demand, 0), 2) AS demand_unfulfillable,
  co.created_at      AS order_created_at,
  co.updated_at      AS order_updated_at
FROM customer_orders co
JOIN customer_order_items coi ON coi.order_id = co.id
JOIN sku_shortage ss ON ss.sku_id = coi.sku_id
LEFT JOIN skus s ON s.id = coi.sku_id
LEFT JOIN stores st ON st.id = co.pickup_store_id
WHERE co.transferred_from_order_id IS NULL
  AND co.pickup_store_id IS NOT NULL
  AND co.order_kind <> 'offset'
  AND co.status IN ('pending', 'confirmed', 'shipping')
  AND coi.status = 'pending'
  AND ss.sku_shortage_qty > 0;

GRANT SELECT ON public.v_order_shortage TO authenticated;

COMMENT ON VIEW public.v_order_shortage IS
  '短缺訂單看板 v4（前瞻模型）：未到貨需求（pending 品項 × pending/confirmed/shipping 訂單）'
  ' vs 現在拿得出的貨（經總倉現貨 + PO 在途 + 調撥在途）。'
  '保留 v3 採購定案閘門（存在 sent/partial/fully/closed PO 才判）。'
  'ready/completed 單＝貨已到店、離開需求池；抵減單（offset，負量）非 cancelled 全算需求。'
  '累計 GR 不再進判定（total_gr 為純資訊欄）。展開到 order_item 按比例分攤，欄位與 v3 相容。';

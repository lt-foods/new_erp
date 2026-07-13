-- ============================================================
-- 派貨工作台：已派量納入補貨直派 transfer + 新增 has_demand_left（需求派完就下架）
--
-- 使用者回報（截圖 PO2607070725 / PO2607070726）：
--   補貨申請（RR-51 / RR-53，各 SKU 申請 1 件）已經派貨、門市也收貨了，
--   但派貨工作台矩陣「一直顯示」這些品項，「需 1」也一直掛著。
--   使用者因此對同一筆 1 件的補貨重複建單 — 線上實際查到龍潭店被派了
--   7 張 1 件的 wave ＋ 1 張補貨直派 transfer（TR2607130189），同一需求出了 9 次貨。
--
-- 根因（兩個）：
--   1) 補貨直派沒被算進「已派」：
--      rpc_ship_restock_pr_received 走 restock_requests.linked_transfer_id 直接建
--      hq_to_store transfer，不經 picking_waves。view 的 per-store wave_qty 有算
--      這條路（20260611000020 加的 UNION 分支），但 per (po,sku) 的
--      po_sku_already_wave 與 rpc_create_wave_from_po 的守衛都只算
--      picking_wave_items → 「可分配」比總倉真實庫存多（例：G00100-01 view 說
--      可分配 4、總倉 on_hand 只有 3），有超派風險。
--   2) 矩陣的顯示條件是純庫存驅動（has_stock_left = gr > 已撿）：
--      補貨帶囤貨的 PO（訂 51 件、補貨需求只有 1 件，其餘囤總倉）永遠
--      gr > 已撿 → 列永遠不消失；且格子的「需 N」顯示原始 demand_qty、
--      不扣已派量 → 邀請使用者重複派貨。
--
-- 修法：
--   A) po_sku_already_wave 加 UNION ALL 分支：補貨直派 transfer
--      （rr.linked_transfer_id → transfer_items.qty_requested，歸屬到
--      linked_pr → po_item 的 PO），與 per-store wave_qty 的第二分支完全同構。
--      has_stock_left 隨之變成 gr > (wave + 直派)。
--   B) view 尾端新增布林欄 has_demand_left：per (po,sku) 是否還有任一分店
--      「需求 > 已派」（demand_qty − wave_qty per store，floor 0 後加總 > 0）。
--      前端矩陣視角改抓 has_stock_left AND has_demand_left → 需求派完
--      （含門市已收貨）的列自動下架，總倉囤貨不再永遠掛在工作台。
--   C) rpc_create_wave_from_po 第 4 步守衛的 already_wave 同步加上直派量，
--      與 view 對齊（對齊原則見 docs/TEST-picking-already-wave-fix.md —
--      view 與 RPC 守衛不同步就會出現「UI 說可以、送出被擋」）。
--
-- CREATE OR REPLACE VIEW 限制：既有欄位順序/型別不可動，新欄位只能加在尾端；
-- has_demand_left 放在 has_stock_left 之後（最後一欄）。
--
-- 基於：
--   view — 20260709000000_v_picking_demand_has_stock_left.sql（最新版）
--   rpc_create_wave_from_po — 20260702000000_wave_from_po_campaign_scoped.sql（最新版）
-- Rollback：
--   view — CREATE OR REPLACE 回 20260709000000 版本（新欄位無法 drop，改回
--          恆為 gr>wave 的舊語意即可；或 DROP VIEW 後用 20260709000000 重建）
--   rpc  — CREATE OR REPLACE 回 20260702000000 版本
-- TEST: docs/TEST-picking-dispatched-demand-left.md
-- ============================================================

CREATE OR REPLACE VIEW public.v_picking_demand_by_po AS
WITH po_skus AS (
  SELECT
    po.id            AS po_id,
    po.tenant_id,
    po.po_no,
    po.status        AS po_status,
    po.supplier_id,
    poi.id           AS po_item_id,
    poi.sku_id,
    poi.qty_ordered,
    EXISTS (
      SELECT 1
        FROM purchase_request_items pri2
        JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
       WHERE pri2.po_item_id = poi.id
    ) AS is_restock_sourced
  FROM purchase_orders po
  JOIN purchase_order_items poi ON poi.po_id = po.id
  WHERE po.status IN ('sent', 'partially_received', 'fully_received')
),
gr_qty AS (
  SELECT
    gri.po_item_id,
    SUM(gri.qty_received) AS gr_qty
  FROM goods_receipt_items gri
  JOIN goods_receipts gr ON gr.id = gri.gr_id
  WHERE gr.status = 'confirmed'
  GROUP BY gri.po_item_id
),
po_campaigns AS (
  SELECT DISTINCT po_item_id, campaign_id FROM (
    SELECT poi.id AS po_item_id, prc.campaign_id
      FROM purchase_order_items poi
      JOIN purchase_request_items pri ON pri.po_item_id = poi.id
      JOIN purchase_requests pr ON pr.id = pri.pr_id
      JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
    UNION
    SELECT poi.id AS po_item_id, pri.source_campaign_id AS campaign_id
      FROM purchase_order_items poi
      JOIN purchase_request_items pri ON pri.po_item_id = poi.id
     WHERE pri.source_campaign_id IS NOT NULL
  ) u
),
campaign_demand AS (
  SELECT
    pc.po_item_id,
    co.pickup_store_id AS store_id,
    SUM(coi.qty) AS demand_qty
  FROM po_campaigns pc
  JOIN customer_orders co ON co.campaign_id = pc.campaign_id
                         AND co.status NOT IN ('cancelled','expired','transferred_out')
                         AND co.transferred_from_order_id IS NULL
  JOIN customer_order_items coi ON coi.order_id = co.id
                               AND coi.status NOT IN ('cancelled','expired')
  JOIN purchase_order_items poi ON poi.id = pc.po_item_id
                               AND poi.sku_id = coi.sku_id
  GROUP BY pc.po_item_id, co.pickup_store_id
),
restock_demand AS (
  SELECT
    poi.id AS po_item_id,
    rr.requesting_store_id AS store_id,
    SUM(rrl.qty) AS demand_qty
  FROM purchase_order_items poi
  JOIN purchase_request_items pri ON pri.po_item_id = poi.id
  JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                          AND rr.status NOT IN ('cancelled','rejected')
  JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                AND rrl.sku_id = poi.sku_id
  GROUP BY poi.id, rr.requesting_store_id
),
store_demand AS (
  SELECT po_item_id, store_id, SUM(demand_qty) AS demand_qty
  FROM (
    SELECT po_item_id, store_id, demand_qty FROM campaign_demand
    UNION ALL
    SELECT po_item_id, store_id, demand_qty FROM restock_demand
  ) u
  GROUP BY po_item_id, store_id
),
wave_qty AS (
  SELECT source_po_id, sku_id, store_id, SUM(qty) AS wave_qty
  FROM (
    SELECT pw.source_po_id, pwi.sku_id, pwi.store_id, pwi.qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
    WHERE pw.status <> 'cancelled'
      AND pw.source_po_id IS NOT NULL
    UNION ALL
    SELECT
      poi.po_id AS source_po_id,
      ti.sku_id,
      rr.requesting_store_id AS store_id,
      ti.qty_requested
    FROM restock_requests rr
    JOIN transfers t ON t.id = rr.linked_transfer_id
    JOIN transfer_items ti ON ti.transfer_id = t.id
    JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
    WHERE t.transfer_type = 'hq_to_store'
      AND t.status <> 'cancelled'
  ) u
  GROUP BY source_po_id, sku_id, store_id
),
-- per (po_id, sku_id) 跨 store 的「已派」真值，與 RPC 守衛對齊。
-- 本次修改：加第二分支 = 補貨直派 transfer（不經 wave 的
-- rpc_ship_restock_pr_received 路徑），與上面 wave_qty 的第二分支同構。
po_sku_already_wave AS (
  SELECT po_id, sku_id, SUM(qty) AS already_wave
  FROM (
    SELECT pw.source_po_id AS po_id, pwi.sku_id, pwi.qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
    WHERE pw.status <> 'cancelled'
      AND pw.source_po_id IS NOT NULL
    UNION ALL
    SELECT poi.po_id, ti.sku_id, ti.qty_requested AS qty
    FROM restock_requests rr
    JOIN transfers t ON t.id = rr.linked_transfer_id
    JOIN transfer_items ti ON ti.transfer_id = t.id
    JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
    WHERE t.transfer_type = 'hq_to_store'
      AND t.status <> 'cancelled'
  ) u
  GROUP BY po_id, sku_id
),
-- 新增：per (po_id, sku_id) 還有任一分店「需求 > 已派」嗎？
-- 已派用 per-store wave_qty（含 wave 與補貨直派），逐店 floor 0 再加總，
-- 避免某店超派的量去抵銷別店未滿足的需求。
po_sku_demand_left AS (
  SELECT
    ps.po_id,
    ps.sku_id,
    SUM(GREATEST(0, COALESCE(sd.demand_qty, 0) - COALESCE(wq.wave_qty, 0))) AS demand_left
  FROM po_skus ps
  JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
  LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id
                       AND wq.sku_id = ps.sku_id
                       AND wq.store_id = sd.store_id
  GROUP BY ps.po_id, ps.sku_id
),
shipped_qty AS (
  SELECT source_po_id, sku_id, store_id, SUM(qty_received) AS shipped_qty
  FROM (
    SELECT
      pw.source_po_id,
      ti.sku_id,
      (substring(t.transfer_no FROM 'WAVE-\d+-S(\d+)'))::BIGINT AS store_id,
      ti.qty_received
    FROM transfers t
    JOIN transfer_items ti ON ti.transfer_id = t.id
    JOIN picking_waves pw ON t.transfer_no LIKE 'WAVE-' || pw.id || '-S%'
    WHERE t.transfer_type = 'hq_to_store'
      AND t.status IN ('received', 'closed')
      AND pw.source_po_id IS NOT NULL
    UNION ALL
    SELECT
      poi.po_id AS source_po_id,
      ti.sku_id,
      rr.requesting_store_id AS store_id,
      ti.qty_received
    FROM restock_requests rr
    JOIN transfers t ON t.id = rr.linked_transfer_id
    JOIN transfer_items ti ON ti.transfer_id = t.id
    JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
    WHERE t.transfer_type = 'hq_to_store'
      AND t.status IN ('received', 'closed')
  ) u
  GROUP BY source_po_id, sku_id, store_id
)
SELECT
  ps.tenant_id,
  ps.po_id,
  ps.po_no,
  ps.po_status,
  ps.supplier_id,
  ps.po_item_id,
  ps.sku_id,
  s.sku_code,
  COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
  ps.qty_ordered,
  COALESCE(g.gr_qty, 0)::NUMERIC AS gr_qty,
  CASE
    WHEN ps.po_status <> 'fully_received'
      THEN GREATEST(0, ps.qty_ordered - COALESCE(g.gr_qty, 0))
    ELSE 0
  END::NUMERIC AS qty_in_transit,
  CASE
    WHEN ps.po_status = 'fully_received' AND COALESCE(g.gr_qty, 0) < ps.qty_ordered
      THEN ps.qty_ordered - COALESCE(g.gr_qty, 0)
    ELSE 0
  END::NUMERIC AS qty_shortage,
  sd.store_id,
  st.code AS store_code,
  st.name AS store_name,
  COALESCE(sd.demand_qty, 0)::NUMERIC AS demand_qty,
  COALESCE(wq.wave_qty, 0)::NUMERIC AS wave_qty,
  COALESCE(sq.shipped_qty, 0)::NUMERIC AS shipped_qty,
  ps.is_restock_sourced,
  -- per (po, sku) 已派（wave ＋ 補貨直派），與 RPC 守衛對齊
  COALESCE(psaw.already_wave, 0)::NUMERIC AS po_sku_already_wave,
  -- per (po, sku) 是否尚有可分配庫存（gr > 已派）。
  (COALESCE(g.gr_qty, 0) > COALESCE(psaw.already_wave, 0)) AS has_stock_left,
  -- 新欄位：per (po, sku) 是否還有任一分店需求未派完。
  -- 前端矩陣視角 .eq("has_stock_left", true).eq("has_demand_left", true)：
  -- 需求全部派完（含補貨直派）的列自動下架，總倉囤貨不再永遠掛在工作台。
  (COALESCE(dl.demand_left, 0) > 0) AS has_demand_left
FROM po_skus ps
JOIN skus s ON s.id = ps.sku_id
LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
LEFT JOIN stores st ON st.id = sd.store_id
LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
LEFT JOIN po_sku_already_wave psaw ON psaw.po_id = ps.po_id AND psaw.sku_id = ps.sku_id
LEFT JOIN po_sku_demand_left dl ON dl.po_id = ps.po_id AND dl.sku_id = ps.sku_id
WHERE
  COALESCE(sq.shipped_qty, 0) < GREATEST(COALESCE(g.gr_qty, 0), 1)
  AND (COALESCE(g.gr_qty, 0) > 0 OR COALESCE(sd.demand_qty, 0) > 0);

GRANT SELECT ON public.v_picking_demand_by_po TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖：PO × SKU × store 矩陣。'
  'po_sku_already_wave (per po+sku) = 已派真值（picking_wave_items ＋ 補貨直派 transfer），與 RPC 守衛對齊；'
  'wave_qty (per po+sku+store) 依 store_demand JOIN，含 wave 與補貨直派，供 by_store 視角與需求淨額計算；'
  'has_stock_left (per po+sku) = gr_qty > po_sku_already_wave；'
  'has_demand_left (per po+sku) = 尚有分店需求未派完（逐店 GREATEST(0, demand−wave) 加總 > 0），'
  '前端矩陣視角同時過濾兩者，需求派完的列自動下架。';

-- ============================================================
-- rpc_create_wave_from_po：第 4 步守衛的 already_wave 同步納入補貨直派 transfer
-- （其餘邏輯與 20260702000000 完全相同）
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_wave_from_po(
  p_po_id        BIGINT,
  p_wave_date    DATE,
  p_allocations  JSONB,
  p_operator     UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_po                purchase_orders%ROWTYPE;
  v_tenant            UUID;
  v_wave_id           BIGINT;
  v_wave_code         TEXT;
  v_alloc             JSONB;
  v_sku_id            BIGINT;
  v_store_id          BIGINT;
  v_qty               NUMERIC(18,3);
  v_line_campaign_id  BIGINT;
  v_total_qty         NUMERIC(18,3) := 0;
  v_item_count        INTEGER := 0;
  v_store_count       INTEGER := 0;
  v_over              RECORD;
BEGIN
  -- 1. PO 守衛
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;
  IF v_po.status NOT IN ('sent','partially_received','fully_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可建撿貨單（需為「已發送」/「部分進貨」/「全部進貨」）', v_po.po_no, v_po.status;
  END IF;
  v_tenant := v_po.tenant_id;

  -- 2. allocations 守衛
  IF p_allocations IS NULL OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION '請先填寫各分店分配量、不可全為空';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('wave:po:' || p_po_id::text));

  -- 3. 守衛：每個分配 qty > 0
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_qty := (v_alloc->>'qty')::NUMERIC;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '分配數量必須 > 0';
    END IF;
  END LOOP;

  -- 4. 守衛：每 sku 的總分配量 ≤ (GR 量 − 已派量)
  --    已派量 = picking_wave_items ＋ 補貨直派 transfer（linked_transfer_id 路徑），
  --    與 v_picking_demand_by_po.po_sku_already_wave 對齊。
  WITH alloc_agg AS (
    SELECT
      (a->>'sku_id')::BIGINT  AS sku_id,
      SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  po_sku_state AS (
    SELECT
      poi.sku_id,
      COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status = 'confirmed'), 0) AS gr_qty,
      COALESCE((
        SELECT SUM(pwi.qty)
          FROM picking_wave_items pwi
          JOIN picking_waves pw ON pw.id = pwi.wave_id
         WHERE pw.source_po_id = p_po_id
           AND pwi.sku_id = poi.sku_id
           AND pw.status <> 'cancelled'
      ), 0)
      + COALESCE((
        SELECT SUM(ti.qty_requested)
          FROM restock_requests rr
          JOIN transfers t ON t.id = rr.linked_transfer_id
          JOIN transfer_items ti ON ti.transfer_id = t.id
          JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
          JOIN purchase_order_items poi2 ON poi2.id = pri.po_item_id AND poi2.sku_id = ti.sku_id
         WHERE poi2.po_id = p_po_id
           AND poi2.sku_id = poi.sku_id
           AND t.transfer_type = 'hq_to_store'
           AND t.status <> 'cancelled'
      ), 0) AS already_wave
    FROM purchase_order_items poi
    LEFT JOIN goods_receipt_items gri ON gri.po_item_id = poi.id
    LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id
    WHERE poi.po_id = p_po_id
    GROUP BY poi.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
    aa.total_alloc, ps.gr_qty, ps.already_wave,
    (ps.gr_qty - ps.already_wave) AS available
  INTO v_over
  FROM alloc_agg aa
  JOIN po_sku_state ps ON ps.sku_id = aa.sku_id
  JOIN skus s ON s.id = aa.sku_id
  WHERE aa.total_alloc > (ps.gr_qty - ps.already_wave)
  LIMIT 1;

  IF v_over.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」分配 % 超過可分配量 %（進貨 %、已派 %，含撿貨單與補貨直派）',
      v_over.sku_code, v_over.sku_label,
      v_over.total_alloc, v_over.available, v_over.gr_qty, v_over.already_wave;
  END IF;

  -- 5. wave header — 用 sequence 產 code,避免同秒撞單
  v_wave_code := 'WV'
              || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYMMDD')
              || LPAD(nextval('public.picking_wave_code_seq')::TEXT, 6, '0');

  INSERT INTO picking_waves (
    tenant_id, wave_code, wave_date, status, source_po_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_wave_code, p_wave_date, 'draft', p_po_id,
    p_operator, p_operator
  ) RETURNING id INTO v_wave_id;

  -- 6 + 7. 逐 (sku, store) 解析「實際有需求的那一團」當 campaign_id，並擋跨團誤撿
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_sku_id   := (v_alloc->>'sku_id')::BIGINT;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    v_qty      := (v_alloc->>'qty')::NUMERIC;

    -- 在「此 PO 對應的開團」裡，挑對該 (store, sku) 確實有訂單需求的一團。
    -- 涵蓋兩條 PO→campaign 路徑（purchase_request_campaigns 與 source_campaign_id），
    -- 與 v_picking_demand_by_po 的 po_campaigns 對齊。
    SELECT cand.campaign_id
      INTO v_line_campaign_id
      FROM (
        SELECT prc.campaign_id
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
         WHERE poi.po_id = p_po_id
        UNION
        SELECT pri.source_campaign_id AS campaign_id
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
         WHERE poi.po_id = p_po_id
           AND pri.source_campaign_id IS NOT NULL
      ) cand
     WHERE EXISTS (
       SELECT 1
         FROM customer_orders co
         JOIN customer_order_items coi ON coi.order_id = co.id
        WHERE co.campaign_id = cand.campaign_id
          AND co.pickup_store_id = v_store_id
          AND co.status NOT IN ('cancelled','expired','transferred_out')
          AND co.transferred_from_order_id IS NULL
          AND coi.sku_id = v_sku_id
          AND coi.status NOT IN ('cancelled','expired')
     )
     ORDER BY cand.campaign_id
     LIMIT 1;

    IF v_line_campaign_id IS NULL THEN
      -- 此 (store, sku) 在這張 PO 的開團都沒有需求。
      -- 只有「補貨 (restock) 來源」才允許（campaign_id 掛 NULL，沿用既有行為）。
      IF NOT EXISTS (
        SELECT 1
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                  AND rr.requesting_store_id = v_store_id
                                  AND rr.status NOT IN ('cancelled','rejected')
          JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                        AND rrl.sku_id = v_sku_id
         WHERE poi.po_id = p_po_id
           AND poi.sku_id = v_sku_id
      ) THEN
        RAISE EXCEPTION
          '分店「%」在採購單「%」對應的開團沒有 SKU「%」的訂單需求，不能撿到這批貨（這批屬於別團，請改用該店所屬開團的採購單撿貨）',
          COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
          v_po.po_no,
          COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id);
      END IF;
    END IF;

    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, campaign_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_wave_id, v_sku_id, v_store_id, v_qty, v_line_campaign_id,
      p_operator, p_operator
    )
    ON CONFLICT (wave_id, sku_id, store_id) DO UPDATE
      SET qty = picking_wave_items.qty + EXCLUDED.qty,
          updated_by = p_operator,
          updated_at = NOW();
  END LOOP;

  -- 8. 統計 wave header
  SELECT COUNT(*), COUNT(DISTINCT store_id), COALESCE(SUM(qty), 0)
    INTO v_item_count, v_store_count, v_total_qty
    FROM picking_wave_items WHERE wave_id = v_wave_id;

  UPDATE picking_waves
     SET item_count = v_item_count,
         store_count = v_store_count,
         total_qty = v_total_qty,
         updated_at = NOW()
   WHERE id = v_wave_id;

  RETURN jsonb_build_object(
    'wave_id', v_wave_id,
    'wave_code', v_wave_code,
    'item_count', v_item_count,
    'store_count', v_store_count,
    'total_qty', v_total_qty
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_wave_from_po IS
  '按 PO 建撿貨單；wave item 的 campaign_id 逐 (sku,store) 取「此 PO 對應開團裡確實有該店該 SKU 需求」的那一團；'
  '若無開團需求且非補貨來源則 RAISE（擋跨團誤撿）。可分配守衛 = GR − (wave ＋ 補貨直派 transfer)，'
  '與 v_picking_demand_by_po.po_sku_already_wave 對齊。wave_code 用 sequence 避免同秒撞單。';

-- ============================================================
-- rpc_create_wave_from_po：撿貨單尊重「開團邊界」，不准把別團需求撿到別團的 PO
--
-- 背景／真實案例 (GRP-20260531-002-0005 / 訂單 #17768)：
--   同一家賣場「包子媽生鮮小舖」連兩週各開一團、品項相同：
--     956 GRP-20260523-002 (05/23) → PR#4 → PO#1
--     2205 GRP-20260531-002 (05/31) → PR#9 → PO#5
--   PR/PO 其實已按開團分開。但撿貨工作站 (wms/picking) 把需求「按 sku 跨 PO
--   合併」、提交時用 FIFO 依 po_id 由小到大吃 PO 容量。於是 2205/忠順店(51) 的
--   1029/1030 需求被倒進「最舊的」PO#1（956）→ 產生 wave 9/10 → WAVE-9-S51。
--   接著本函式舊版第 6 步只取「該 PO 最小 campaign_id」當代表蓋到所有 wave item
--   → wave item 掛 956 → 2205 訂單被孤立：歷程查不到那張 transfer、status 也沒人
--   推 → 卡 pending、不能取貨。
--
-- 根因：撿貨是 campaign-blind，但團購訂單的「收貨→可取貨／歷程」是 campaign-scoped。
--   兩個同時進行、共用 SKU 的開團一出現就互相污染。
--
-- 修法（伺服器端強制分開，UI 繞不過去）：
--   1) 移除第 6 步「單一代表 campaign」。
--   2) 第 7 步逐 (sku, store) 解析 campaign_id：
--      在「此 PO 對應的開團」裡，找對該 (store, sku) 確實有訂單需求的那一團來蓋。
--   3) 若該 (store, sku) 在此 PO 的開團「都沒有需求」：
--      - 有補貨 (restock) 需求 → 允許，campaign_id 掛 NULL（沿用既有 restock 行為）。
--      - 兩者皆無 → 直接 RAISE，擋掉跨團誤撿（貨屬別團，請改用該店所屬開團的 PO）。
--
-- 前端 (wms/picking) 同批改成 FIFO 只倒給「該 (po,sku,store) 確實有需求」的 PO，
--   讓 UI 不會再產生本函式會擋掉的分配。
--
-- 基於：20260609000001_picking_wave_code_seq.sql（最新／線上版本，wave_code 用 seq）。
-- Rollback：CREATE OR REPLACE 回 20260609000001 版本（恢復第 6 步單一代表 campaign、
--           移除逐行 campaign 解析與守衛）。
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

  -- 4. 守衛：每 sku 的總分配量 ≤ (GR 量 − 已 wave 量)
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
    RAISE EXCEPTION 'SKU「% %」分配 % 超過可分配量 %（進貨 %、已撿 %）',
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
  '若無開團需求且非補貨來源則 RAISE（擋跨團誤撿）。wave_code 用 sequence 避免同秒撞單。';

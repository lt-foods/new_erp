-- ============================================================
-- 跨團借調（20260816000050）部署乾跑 / 部署後驗證
--
-- 用法（Management API，單一 query 送出）：
--   部署前乾跑： BEGIN; + <migration 全文> + <本檔 DO 區塊> + ROLLBACK;
--   部署後驗證： 直接跑本檔 DO 區塊（不要 BEGIN/ROLLBACK 也可以 —— 它只借 1 件
--               又立刻期望守衛擋下超額，但保險起見還是包在 BEGIN...ROLLBACK 裡跑）。
--
-- 六道斷言：
--   0) 歷史 wave 的 campaign tag 全部落在來源 PO 的團裡 → wave_qty 借調歸屬
--      分支對既有資料零變動（2026-08-16 乾跑實測 = 0 筆例外）
--   1) 線上找得到「某店短單有未派需求 + 有人等貨 + 別張 PO 有餘量」的真實案例
--   2) 借 1 件成功（rpc_create_wave_from_po 走借調分支）
--   3) wave item 的 tag 非 NULL、不屬於來源 PO 的團、該團在該店確實有人等貨
--   4) v_picking_wave_campaign_mismatch 不把合法借調列成誤撿
--   5) 短單那排的未派需求 −1（需求歸屬跟著 tag 走）
--   6) 超額借調被守衛擋下（own_unmet>0 踩步驟 4.5；=0 踩步驟 4）
-- ============================================================
DO $dry$
DECLARE
  v_sku BIGINT; v_store BIGINT; v_short_po BIGINT; v_src_po BIGINT;
  v_avail NUMERIC; v_own_unmet NUMERIC;
  v_op UUID; v_res JSONB; v_wave BIGINT;
  v_before NUMERIC; v_after NUMERIC;
  v_tag BIGINT; v_n INT; v_msg TEXT; v_try NUMERIC;
BEGIN
  -- 0. 歷史 wave 的 tag 應全部落在來源 PO 的團裡 → 借調歸屬分支對既有資料 = 空集合
  --    （= 新版 view 對歷史輸出零變動）
  SELECT count(*) INTO v_n
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
   WHERE pw.status <> 'cancelled' AND pw.source_po_id IS NOT NULL AND pwi.campaign_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM (
         SELECT prc.campaign_id FROM purchase_order_items poi
           JOIN purchase_request_items pri ON pri.po_item_id = poi.id
           JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
          WHERE poi.po_id = pw.source_po_id
         UNION
         SELECT pri.source_campaign_id FROM purchase_order_items poi
           JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          WHERE poi.po_id = pw.source_po_id AND pri.source_campaign_id IS NOT NULL
       ) c WHERE c.campaign_id = pwi.campaign_id);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'ASSERT0 FAIL: 既有 wave 有 % 筆 tag 不在來源 PO 的團（歷史歸屬會變動）', v_n;
  END IF;

  -- 1. 找真實借調案例：某店在短單有未派需求、且該店有「等貨中」的非內部訂單、
  --    同 SKU 另張 PO 有餘量、且該店在那張 PO 上沒有需求列（真借調）
  WITH v AS (
    SELECT po_id, sku_id, store_id, demand_qty, wave_qty, gr_qty, po_sku_already_wave
      FROM v_picking_demand_by_po WHERE store_id IS NOT NULL
  ),
  po_sku AS (
    SELECT po_id, sku_id, MAX(gr_qty) AS gr, MAX(po_sku_already_wave) AS aw,
           SUM(GREATEST(0, demand_qty - wave_qty)) AS own_unmet
      FROM v GROUP BY po_id, sku_id
  ),
  short_side AS (
    SELECT v.po_id, v.sku_id, v.store_id
      FROM v JOIN po_sku p USING (po_id, sku_id)
     WHERE v.demand_qty - v.wave_qty > 0
       AND GREATEST(0, p.gr - p.aw) = 0
       AND EXISTS (
         SELECT 1 FROM customer_orders co
         JOIN customer_order_items coi ON coi.order_id = co.id
         LEFT JOIN members m ON m.id = co.member_id
        WHERE co.pickup_store_id = v.store_id AND co.campaign_id IS NOT NULL
          AND co.status NOT IN ('cancelled','expired','transferred_out')
          AND coi.sku_id = v.sku_id AND coi.status IN ('pending','reserved','ready')
          AND COALESCE(m.member_type,'') <> 'store_internal')
  ),
  surplus_side AS (
    SELECT po_id, sku_id, GREATEST(0, gr - aw) AS avail, own_unmet,
           GREATEST(0, gr - aw) - own_unmet AS surplus
      FROM po_sku WHERE GREATEST(0, gr - aw) - own_unmet > 0
  )
  SELECT s.sku_id, s.store_id, s.po_id, x.po_id, x.avail, x.own_unmet
    INTO v_sku, v_store, v_short_po, v_src_po, v_avail, v_own_unmet
  FROM short_side s
  JOIN LATERAL (
    SELECT sp.po_id, sp.avail, sp.own_unmet
      FROM surplus_side sp
     WHERE sp.sku_id = s.sku_id AND sp.po_id <> s.po_id
       AND NOT EXISTS (SELECT 1 FROM v_picking_demand_by_po v2
                        WHERE v2.po_id = sp.po_id AND v2.sku_id = s.sku_id AND v2.store_id = s.store_id)
     ORDER BY (sp.own_unmet > 0) DESC, sp.surplus DESC LIMIT 1
  ) x ON TRUE
  LIMIT 1;
  IF v_sku IS NULL THEN RAISE EXCEPTION 'ASSERT1 FAIL: 線上找不到可測的借調案例'; END IF;

  SELECT id INTO v_op FROM auth.users LIMIT 1;

  SELECT COALESCE(SUM(GREATEST(0, demand_qty - wave_qty)), 0) INTO v_before
    FROM v_picking_demand_by_po
   WHERE po_id = v_short_po AND sku_id = v_sku AND store_id = v_store;

  -- 2. 借 1 件（應成功）
  v_res := rpc_create_wave_from_po(
    v_src_po, CURRENT_DATE + 1,
    jsonb_build_array(jsonb_build_object('sku_id', v_sku, 'store_id', v_store, 'qty', 1)),
    v_op);
  v_wave := (v_res->>'wave_id')::BIGINT;

  -- 3. tag 檢查：非 NULL、不屬於來源 PO 的團、該團在該店確實有人等貨
  SELECT campaign_id INTO v_tag FROM picking_wave_items WHERE wave_id = v_wave;
  IF v_tag IS NULL THEN RAISE EXCEPTION 'ASSERT3a FAIL: 借調 wave item 的 campaign_id 是 NULL'; END IF;
  IF EXISTS (
    SELECT 1 FROM (
      SELECT prc.campaign_id FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
       WHERE poi.po_id = v_src_po
      UNION
      SELECT pri.source_campaign_id FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
       WHERE poi.po_id = v_src_po AND pri.source_campaign_id IS NOT NULL
    ) c WHERE c.campaign_id = v_tag
  ) THEN RAISE EXCEPTION 'ASSERT3b FAIL: tag % 落在來源 PO 自己的團，不是借調解析', v_tag; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
   WHERE co.campaign_id = v_tag AND co.pickup_store_id = v_store
     AND co.status NOT IN ('cancelled','expired','transferred_out')
     AND coi.sku_id = v_sku AND coi.status IN ('pending','reserved','ready')
  ) THEN RAISE EXCEPTION 'ASSERT3c FAIL: tag % 的團在該店沒有等貨中的訂單', v_tag; END IF;

  -- 4. mismatch 視圖不得把合法借調列成誤撿
  SELECT count(*) INTO v_n FROM v_picking_wave_campaign_mismatch WHERE wave_id = v_wave;
  IF v_n <> 0 THEN RAISE EXCEPTION 'ASSERT4 FAIL: 借調被 mismatch 視圖誤列（% 筆）', v_n; END IF;

  -- 5. 需求歸屬：短單那排的未派需求要 −1（wave_qty 借調歸屬分支生效）
  SELECT COALESCE(SUM(GREATEST(0, demand_qty - wave_qty)), 0) INTO v_after
    FROM v_picking_demand_by_po
   WHERE po_id = v_short_po AND sku_id = v_sku AND store_id = v_store;
  IF v_after <> v_before - 1 THEN
    RAISE EXCEPTION 'ASSERT5 FAIL: 借調後短單未派需求 % → %（預期 −1）', v_before, v_after;
  END IF;

  -- 6. 守衛：超額借調要被擋。own_unmet>0 → 借滿 avail 會踩 4.5；own_unmet=0 → avail+1 踩步驟 4
  v_try := CASE WHEN v_own_unmet > 0 THEN v_avail ELSE v_avail + 1 END;
  BEGIN
    PERFORM rpc_create_wave_from_po(
      v_src_po, CURRENT_DATE + 1,
      jsonb_build_array(jsonb_build_object('sku_id', v_sku, 'store_id', v_store, 'qty', v_try)),
      v_op);
    RAISE EXCEPTION 'ASSERT6 FAIL: 超額借調（qty=%）沒有被任何守衛擋下', v_try;
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    IF v_msg LIKE 'ASSERT6 FAIL%' THEN RAISE; END IF;
    IF v_own_unmet > 0 AND position('跨團借調' in v_msg) = 0 THEN
      RAISE EXCEPTION 'ASSERT6b FAIL: 預期步驟 4.5 借調守衛，實得: %', v_msg;
    END IF;
    IF v_own_unmet = 0 AND position('超過可分配量' in v_msg) = 0 THEN
      RAISE EXCEPTION 'ASSERT6c FAIL: 預期步驟 4 總量守衛，實得: %', v_msg;
    END IF;
  END;
END $dry$;

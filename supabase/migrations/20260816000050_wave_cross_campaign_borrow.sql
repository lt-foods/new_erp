-- ============================================================
-- 跨團借調：第一團短少時，把同 SKU 別張 PO 的「餘量」派給還在等的客人
--
-- 背景（老闆實務）：同一賣場每週重開團。第一團短少 / 未到，第二團的貨到了，
--   實務上店家本來就會拿第二團的貨先給第一團的客人 —— 系統原本在
--   rpc_create_wave_from_po 硬擋（跨團守衛），結果是客人缺貨、或店家改走
--   轉單繞路生出重複單。
-- 線上盤點（2026-08-16，唯讀）：46 組 (PO,店,SKU) 借得到 —— 生煎包三張短單
--   缺 253 件、同 SKU 兩張 PO 餘 128；土雞蛋缺 150、餘 9。合計缺 403、可借 347。
--
-- 設計原則：
--   1. 只借「餘量」：(GR − 已派) − 該 PO 自己的未派需求。兩團都不夠的真稀缺
--      不自動借（誰先拿是人的決定，走既有的少發配貨 / 斷貨通知）。
--   2. wave item 的 campaign_id 一律標「實際被服務的那一團」（不是貨來源的團）。
--      rpc_mark_orders_shipping_for_wave 要 pwi.campaign_id = co.campaign_id 才推
--      得動單頭；標錯 = 貨到店、單卡 confirmed（忠順 2026-08-11 的 105 張翻版）。
--   3. 需求歸屬跟著 campaign 標記走、容量歸屬跟著來源 PO 走：
--      v_picking_demand_by_po.wave_qty 新增借調歸屬分支（被服務的 (po,sku,store)
--      需求會歸零、has_demand_left 會下架），po_sku_already_wave 維持算在來源 PO
--      （可分配量正確遞減）。缺了前者，工作台會永遠邀請對同一批需求重複派貨。
--   4. 補貨 (restock) 路徑優先且完全不變：有補貨需求的 (store,sku) 照走
--      campaign NULL + 補貨 cap，借調只在「開團與補貨都沒需求」時啟動。
--
-- 基底（皆經 grep 全歷史確認為最新版）：
--   - rpc_create_wave_from_po      ← 20260807000000（線上版，含補貨 cap hotfix）
--       新增：步驟 4.5 借調總量守衛、步驟 6 借調 campaign 解析分支。
--   - v_picking_demand_by_po       ← 20260807000000
--       只動 wave_qty CTE（借調歸屬分支）＋ 新增 po_campaign_po CTE；
--       輸出欄位、順序、型別完全不變（CREATE OR REPLACE VIEW 相容）。
--   - v_picking_wave_campaign_mismatch ← 20260702000010
--       新增排除 (c)：標記團自身在該店該 SKU 有活訂單需求 = 合法借調，不列。
-- Rollback：三個物件 CREATE OR REPLACE 回上述基底版本。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. v_picking_demand_by_po：wave_qty 新增「依 campaign 標記歸屬」的借調分支
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_picking_demand_by_po AS
 WITH po_skus AS (
         SELECT po.id AS po_id,
            po.tenant_id,
            po.po_no,
            po.status AS po_status,
            po.supplier_id,
            poi.id AS po_item_id,
            poi.sku_id,
            poi.qty_ordered,
            (EXISTS ( SELECT 1
                   FROM purchase_request_items pri2
                     JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
                  WHERE pri2.po_item_id = poi.id)) AS is_restock_sourced
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text])
        ), gr_qty AS (
         SELECT gri.po_item_id,
            sum(gri.qty_received) AS gr_qty
           FROM goods_receipt_items gri
             JOIN goods_receipts gr ON gr.id = gri.gr_id
          WHERE gr.status = 'confirmed'::text
          GROUP BY gri.po_item_id
        ), po_campaigns AS (
         SELECT DISTINCT u.po_item_id,
            u.campaign_id
           FROM ( SELECT poi.id AS po_item_id,
                    prc.campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                     JOIN purchase_requests pr ON pr.id = pri.pr_id
                     JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
                UNION
                 SELECT poi.id AS po_item_id,
                    pri.source_campaign_id AS campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                  WHERE pri.source_campaign_id IS NOT NULL) u
        ), po_campaign_po AS (
         -- PO 層級的開團對應（po_campaigns 是 po_item 粒度），給 wave_qty 的借調歸屬分支用
         SELECT DISTINCT poi.po_id,
            pc0.campaign_id
           FROM po_campaigns pc0
             JOIN purchase_order_items poi ON poi.id = pc0.po_item_id
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR EXISTS ( SELECT 1
                    FROM customer_orders src
                   WHERE src.id = co.transferred_from_order_id
                     AND src.pickup_store_id = co.pickup_store_id))
             JOIN customer_order_items coi ON coi.order_id = co.id AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
             JOIN purchase_order_items poi ON poi.id = pc.po_item_id AND poi.sku_id = coi.sku_id
          GROUP BY pc.po_item_id, co.pickup_store_id
        ), restock_demand AS (
         SELECT poi.id AS po_item_id,
            rr.requesting_store_id AS store_id,
            sum(rrl.qty) AS demand_qty
           FROM purchase_order_items poi
             JOIN purchase_request_items pri ON pri.po_item_id = poi.id
             JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id AND (rr.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text]))
             JOIN restock_request_lines rrl ON rrl.request_id = rr.id AND rrl.sku_id = poi.sku_id
          GROUP BY poi.id, rr.requesting_store_id
        ), store_demand AS (
         SELECT u.po_item_id,
            u.store_id,
            sum(u.demand_qty) AS demand_qty
           FROM ( SELECT campaign_demand.po_item_id,
                    campaign_demand.store_id,
                    campaign_demand.demand_qty
                   FROM campaign_demand
                UNION ALL
                 SELECT restock_demand.po_item_id,
                    restock_demand.store_id,
                    restock_demand.demand_qty
                   FROM restock_demand) u
          GROUP BY u.po_item_id, u.store_id
        ), wave_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty) AS wave_qty
           FROM ( SELECT pw.source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_requested
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text
                UNION ALL
                 -- 跨團借調（20260816000050）：wave item 掛在來源 PO（貨從哪來）、
                 -- campaign_id 標「實際被服務的團」。需求歸屬要跟著 campaign 標記走，
                 -- 否則被借調服務的 (po, sku, store) 需求永遠顯示未派，工作台會邀請重複派貨。
                 -- 只認「標記團不屬於來源 PO」的列（真借調）；一般列走上面第一支，不會重複計。
                 -- 容量歸屬（po_sku_already_wave）維持跟著來源 PO，兩邊各記各的。
                 SELECT pcp.po_id AS source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                     JOIN po_campaign_po pcp ON pcp.campaign_id = pwi.campaign_id
                  WHERE pw.status <> 'cancelled'::text
                    AND pw.source_po_id IS NOT NULL
                    AND pwi.campaign_id IS NOT NULL
                    AND pcp.po_id <> pw.source_po_id
                    AND NOT EXISTS ( SELECT 1
                           FROM po_campaign_po own
                          WHERE own.po_id = pw.source_po_id
                            AND own.campaign_id = pwi.campaign_id)) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        ), po_sku_already_wave AS (
         SELECT u.po_id,
            u.sku_id,
            sum(u.qty) AS already_wave
           FROM ( SELECT pw.source_po_id AS po_id,
                    pwi.sku_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id,
                    ti.sku_id,
                    ti.qty_requested AS qty
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text) u
          GROUP BY u.po_id, u.sku_id
        ), po_sku_demand_left AS (
         SELECT ps_1.po_id,
            ps_1.sku_id,
            sum(GREATEST(0::numeric, COALESCE(sd_1.demand_qty, 0::numeric) - COALESCE(wq_1.wave_qty, 0::numeric))) AS demand_left
           FROM po_skus ps_1
             JOIN store_demand sd_1 ON sd_1.po_item_id = ps_1.po_item_id
             LEFT JOIN wave_qty wq_1 ON wq_1.source_po_id = ps_1.po_id AND wq_1.sku_id = ps_1.sku_id AND wq_1.store_id = sd_1.store_id
          GROUP BY ps_1.po_id, ps_1.sku_id
        ), shipped_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty_received) AS shipped_qty
           FROM ( SELECT pw.source_po_id,
                    ti.sku_id,
                    "substring"(t.transfer_no, 'WAVE-\d+-S(\d+)'::text)::bigint AS store_id,
                    ti.qty_received
                   FROM transfers t
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN picking_waves pw ON t.transfer_no ~~ (('WAVE-'::text || pw.id) || '-S%'::text)
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text])) AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_received
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text]))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        )
 SELECT ps.tenant_id,
    ps.po_id,
    ps.po_no,
    ps.po_status,
    ps.supplier_id,
    ps.po_item_id,
    ps.sku_id,
    s.sku_code,
    COALESCE(s.product_name, ''::text) || COALESCE(' '::text || NULLIF(s.variant_name, ''::text), ''::text) AS sku_label,
    ps.qty_ordered,
    COALESCE(g.gr_qty, 0::numeric) AS gr_qty,
        CASE
            WHEN ps.po_status <> 'fully_received'::text THEN GREATEST(0::numeric, ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric))
            ELSE 0::numeric
        END AS qty_in_transit,
        CASE
            WHEN ps.po_status = 'fully_received'::text AND COALESCE(g.gr_qty, 0::numeric) < ps.qty_ordered THEN ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric)
            ELSE 0::numeric
        END AS qty_shortage,
    sd.store_id,
    st.code AS store_code,
    st.name AS store_name,
    COALESCE(sd.demand_qty, 0::numeric) AS demand_qty,
    COALESCE(wq.wave_qty, 0::numeric) AS wave_qty,
    COALESCE(sq.shipped_qty, 0::numeric) AS shipped_qty,
    ps.is_restock_sourced,
    COALESCE(psaw.already_wave, 0::numeric) AS po_sku_already_wave,
    COALESCE(g.gr_qty, 0::numeric) > COALESCE(psaw.already_wave, 0::numeric) AS has_stock_left,
    COALESCE(dl.demand_left, 0::numeric) > 0::numeric AS has_demand_left
   FROM po_skus ps
     JOIN skus s ON s.id = ps.sku_id
     LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
     LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
     LEFT JOIN stores st ON st.id = sd.store_id
     LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
     LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
     LEFT JOIN po_sku_already_wave psaw ON psaw.po_id = ps.po_id AND psaw.sku_id = ps.sku_id
     LEFT JOIN po_sku_demand_left dl ON dl.po_id = ps.po_id AND dl.sku_id = ps.sku_id
  WHERE COALESCE(sq.shipped_qty, 0::numeric) < GREATEST(COALESCE(g.gr_qty, 0::numeric), 1::numeric) AND (COALESCE(g.gr_qty, 0::numeric) > 0::numeric OR COALESCE(sd.demand_qty, 0::numeric) > 0::numeric);

GRANT SELECT ON public.v_picking_demand_by_po TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖：PO × SKU × store 矩陣。campaign_demand 排除「跨店」衍生單、保留「同店」衍生單。'
  'wave_qty 含跨團借調歸屬分支（campaign 標記不屬於來源 PO 的 wave item，需求歸屬跟著標記走）；'
  'po_sku_already_wave/has_stock_left 維持跟著來源 PO。其餘語意同 20260807000000。';

-- ----------------------------------------------------------------
-- 2. rpc_create_wave_from_po：步驟 4.5 借調總量守衛 + 步驟 6 借調 campaign 解析
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_wave_from_po(p_po_id bigint, p_wave_date date, p_allocations jsonb, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
  v_restock_demand    NUMERIC;
  v_restock_dispatched NUMERIC;
  v_restock_left      NUMERIC;
  v_borrow            RECORD;
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

  -- 4.5 借調守衛（20260816000050）：分配到「本單開團 / 補貨都沒需求」的 (store, sku)
  --     ＝ 跨團借調。借調總量（per SKU）不可超過本單餘量
  --       餘量 = (GR − 已派) − 本單自己的未派需求
  --     否則會吃掉本單自己團的客人還沒拿到的貨。「未派需求」對齊
  --     v_picking_demand_by_po 的 demand_left 口徑（Σ GREATEST(0, demand − wave)；
  --     wave_qty 的借調歸屬分支已含在內）。此守衛在建 wave 之前跑，view 不含本次分配。
  WITH alloc_rows AS (
    SELECT
      (a->>'sku_id')::BIGINT  AS sku_id,
      (a->>'store_id')::BIGINT AS store_id,
      SUM((a->>'qty')::NUMERIC) AS qty
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT, (a->>'store_id')::BIGINT
  ),
  borrow_alloc AS (
    SELECT ar.sku_id, SUM(ar.qty) AS borrow_qty
      FROM alloc_rows ar
     WHERE NOT EXISTS (               -- 本單開團對該 (store, sku) 沒有訂單需求（鏡射步驟 6 的解析條件）
             SELECT 1
               FROM ( SELECT prc.campaign_id
                        FROM purchase_order_items poi
                        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                        JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
                       WHERE poi.po_id = p_po_id
                      UNION
                      SELECT pri.source_campaign_id AS campaign_id
                        FROM purchase_order_items poi
                        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                       WHERE poi.po_id = p_po_id
                         AND pri.source_campaign_id IS NOT NULL) cand
              WHERE EXISTS (
                SELECT 1
                  FROM customer_orders co
                  JOIN customer_order_items coi ON coi.order_id = co.id
                 WHERE co.campaign_id = cand.campaign_id
                   AND co.pickup_store_id = ar.store_id
                   AND co.status NOT IN ('cancelled','expired','transferred_out')
                   AND (co.transferred_from_order_id IS NULL OR EXISTS (
                         SELECT 1 FROM customer_orders src
                          WHERE src.id = co.transferred_from_order_id
                            AND src.pickup_store_id = co.pickup_store_id))
                   AND coi.sku_id = ar.sku_id
                   AND coi.status NOT IN ('cancelled','expired')))
       AND NOT EXISTS (               -- 也不是補貨來源（鏡射步驟 6）
             SELECT 1
               FROM purchase_order_items poi
               JOIN purchase_request_items pri ON pri.po_item_id = poi.id
               JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                       AND rr.requesting_store_id = ar.store_id
                                       AND rr.status NOT IN ('cancelled','rejected')
               JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                             AND rrl.sku_id = ar.sku_id
              WHERE poi.po_id = p_po_id
                AND poi.sku_id = ar.sku_id)
     GROUP BY ar.sku_id
  ),
  own_unmet AS (
    SELECT v.sku_id, SUM(GREATEST(0, v.demand_qty - v.wave_qty)) AS unmet
      FROM public.v_picking_demand_by_po v
     WHERE v.po_id = p_po_id AND v.store_id IS NOT NULL
     GROUP BY v.sku_id
  ),
  po_sku_state2 AS (
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
    b.borrow_qty,
    COALESCE(u.unmet, 0) AS own_unmet,
    GREATEST(0, GREATEST(0, ps.gr_qty - ps.already_wave) - COALESCE(u.unmet, 0)) AS surplus
  INTO v_borrow
  FROM borrow_alloc b
  JOIN po_sku_state2 ps ON ps.sku_id = b.sku_id
  LEFT JOIN own_unmet u ON u.sku_id = b.sku_id
  JOIN skus s ON s.id = b.sku_id
  WHERE b.borrow_qty > GREATEST(0, GREATEST(0, ps.gr_qty - ps.already_wave) - COALESCE(u.unmet, 0))
  LIMIT 1;

  IF v_borrow.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」跨團借調 % 件超過本單餘量 %（本單自己的團還缺 % 件未派，借調只能動「蓋掉自己需求後剩下的量」）',
      v_borrow.sku_code, v_borrow.sku_label,
      v_borrow.borrow_qty, v_borrow.surplus, v_borrow.own_unmet;
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
          AND (co.transferred_from_order_id IS NULL OR EXISTS (
                SELECT 1 FROM customer_orders src
                 WHERE src.id = co.transferred_from_order_id
                   AND src.pickup_store_id = co.pickup_store_id))
          AND coi.sku_id = v_sku_id
          AND coi.status NOT IN ('cancelled','expired')
     )
     ORDER BY cand.campaign_id
     LIMIT 1;

    IF v_line_campaign_id IS NULL THEN
      -- 此 (store, sku) 在這張 PO 的開團都沒有需求。兩條出路：
      --   a) 補貨 (restock) 來源 → campaign_id 掛 NULL ＋ 補貨 cap（沿用既有行為，優先）。
      --   b) 跨團借調（20260816000050）→ 別的團在該店有客人在等 → 標「被服務的那一團」。
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
        -- 跨團借調：wave item 的 campaign_id 一律標「實際被服務的那一團」，
        -- 出貨時 rpc_mark_orders_shipping_for_wave（pwi.campaign_id = co.campaign_id）
        -- 才推得動該團的單頭。標成貨來源的團 = 貨到店、單卡 confirmed
        -- （忠順 2026-08-11 全卡 105 張的翻版），絕對不要。
        -- 解析規則：該店該 SKU「還在等貨」（pending/reserved/ready）的活訂單裡，
        -- 挑最早開始等的那一團；內部現貨池（store_internal）不是借調對象。
        -- 借調總量已由步驟 4.5 擋在本單餘量內。
        SELECT co.campaign_id
          INTO v_line_campaign_id
          FROM customer_orders co
          JOIN customer_order_items coi ON coi.order_id = co.id
          LEFT JOIN members m ON m.id = co.member_id
         WHERE co.pickup_store_id = v_store_id
           AND co.campaign_id IS NOT NULL
           AND co.status NOT IN ('cancelled','expired','transferred_out')
           AND (co.transferred_from_order_id IS NULL OR EXISTS (
                 SELECT 1 FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id
                    AND src.pickup_store_id = co.pickup_store_id))
           AND coi.sku_id = v_sku_id
           AND coi.status IN ('pending','reserved','ready')
           AND COALESCE(m.member_type, '') <> 'store_internal'
         GROUP BY co.campaign_id
         ORDER BY MIN(co.created_at)
         LIMIT 1;

        IF v_line_campaign_id IS NULL THEN
          RAISE EXCEPTION
            '分店「%」在採購單「%」對應的開團沒有 SKU「%」的訂單需求，也沒有別團的客人在該店等這個商品，不能撿到這批貨（若要額外補庫存給分店，請走內部調撥）',
            COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
            v_po.po_no,
            COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id);
        END IF;
      ELSE

      -- 20260715 新增：補貨分配不可超過「剩餘補貨需求」= 申請量 − 已派量。
      -- 申請量：此 PO 對應補貨申請對該 (store, sku) 的 lines 加總。
      SELECT COALESCE(SUM(rrl.qty), 0) INTO v_restock_demand
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                AND rr.requesting_store_id = v_store_id
                                AND rr.status NOT IN ('cancelled','rejected')
        JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                      AND rrl.sku_id = v_sku_id
       WHERE poi.po_id = p_po_id
         AND poi.sku_id = v_sku_id;

      -- 已派量：此 PO 的 campaign NULL wave items（含本 wave 前面 loop 已插入的列，
      -- 同批重複 (sku,store) 會累計）＋ 補貨直派 transfer。
      SELECT
        COALESCE((
          SELECT SUM(pwi.qty)
            FROM picking_wave_items pwi
            JOIN picking_waves pw ON pw.id = pwi.wave_id
           WHERE pw.source_po_id = p_po_id
             AND pw.status <> 'cancelled'
             AND pwi.sku_id = v_sku_id
             AND pwi.store_id = v_store_id
             AND pwi.campaign_id IS NULL
        ), 0)
        + COALESCE((
          SELECT SUM(ti.qty_requested)
            FROM restock_requests rr
            JOIN transfers t ON t.id = rr.linked_transfer_id
            JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = v_sku_id
            JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
            JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = v_sku_id
           WHERE poi.po_id = p_po_id
             AND rr.requesting_store_id = v_store_id
             AND t.transfer_type = 'hq_to_store'
             AND t.status <> 'cancelled'
        ), 0)
      INTO v_restock_dispatched;

      v_restock_left := GREATEST(0, v_restock_demand - v_restock_dispatched);
      IF v_qty > v_restock_left THEN
        RAISE EXCEPTION
          '分店「%」SKU「%」的補貨需求只剩 % 件未派（申請 %、已派 %，含撿貨單與直派），本次分配 % 超過。若要額外補庫存給分店，請走內部調撥。',
          COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
          COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id),
          v_restock_left, v_restock_demand, v_restock_dispatched, v_qty;
      END IF;
      END IF;  -- a) restock / b) 借調 分流
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
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_create_wave_from_po(BIGINT, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_wave_from_po(BIGINT, DATE, JSONB, UUID) IS
  '由派貨工作台建撿貨單。跨團守衛：本單開團有需求 → 標該團；補貨來源 → NULL + 補貨 cap；'
  '都沒有 → 跨團借調（標「實際被服務的團」，總量 ≤ 本單餘量 = 可分配 − 自己未派需求，'
  '步驟 4.5 守衛）。基底 20260807000000。';

-- ----------------------------------------------------------------
-- 3. v_picking_wave_campaign_mismatch：合法借調不列 mismatch
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_picking_wave_campaign_mismatch AS
SELECT
  p.tenant_id,
  p.wave_id,
  pw.wave_code,
  pw.status        AS wave_status,
  pw.source_po_id  AS po_id,
  po.po_no,
  p.store_id,
  st.name          AS store_name,
  p.sku_id,
  s.sku_code,
  COALESCE(s.product_name,'') || COALESCE(' ' || NULLIF(s.variant_name,''),'') AS sku_label,
  p.qty,
  p.campaign_id    AS tagged_campaign_id,
  ( SELECT string_agg(DISTINCT c2.campaign_no, ', ' ORDER BY c2.campaign_no)
      FROM customer_orders co2
      JOIN customer_order_items coi2 ON coi2.order_id = co2.id
      JOIN group_buy_campaigns c2 ON c2.id = co2.campaign_id
     WHERE co2.pickup_store_id = p.store_id
       AND coi2.sku_id = p.sku_id
       AND co2.status NOT IN ('cancelled','expired','transferred_out')
       AND co2.transferred_from_order_id IS NULL
       AND coi2.status NOT IN ('cancelled','expired')
  ) AS demand_actually_in
FROM picking_wave_items p
JOIN picking_waves pw ON pw.id = p.wave_id
JOIN purchase_orders po ON po.id = pw.source_po_id
JOIN skus s ON s.id = p.sku_id
LEFT JOIN stores st ON st.id = p.store_id
WHERE pw.status <> 'cancelled'
  AND pw.source_po_id IS NOT NULL
  -- (a) 此 PO 的開團都沒有該 (store, sku) 的活訂單需求
  AND NOT EXISTS (
    SELECT 1
    FROM (
      SELECT prc.campaign_id
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
       WHERE poi.po_id = pw.source_po_id
      UNION
      SELECT pri.source_campaign_id
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
       WHERE poi.po_id = pw.source_po_id
         AND pri.source_campaign_id IS NOT NULL
    ) cand
    JOIN customer_orders co ON co.campaign_id = cand.campaign_id
                           AND co.pickup_store_id = p.store_id
                           AND co.status NOT IN ('cancelled','expired','transferred_out')
                           AND co.transferred_from_order_id IS NULL
    JOIN customer_order_items coi ON coi.order_id = co.id
                                 AND coi.sku_id = p.sku_id
                                 AND coi.status NOT IN ('cancelled','expired')
  )
  -- (b) 也不是補貨來源
  AND NOT EXISTS (
    SELECT 1
      FROM purchase_order_items poi
      JOIN purchase_request_items pri ON pri.po_item_id = poi.id
      JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                              AND rr.requesting_store_id = p.store_id
                              AND rr.status NOT IN ('cancelled','rejected')
      JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                    AND rrl.sku_id = p.sku_id
     WHERE poi.po_id = pw.source_po_id
       AND poi.sku_id = p.sku_id
  )
  -- (c) 也不是合法的跨團借調（20260816000050）：wave item 的 campaign_id 標的是
  --     「實際被服務的那一團」，只要那一團在該店該 SKU 確實有活訂單需求，
  --     tag 就是誠實的（訂單推進不會卡）→ 不列 mismatch。
  --     誤標（標了沒需求的團）與 campaign_id NULL 的超撿照舊列出。
  AND NOT (
    p.campaign_id IS NOT NULL
    AND EXISTS (
      SELECT 1
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id
                                     AND coi.sku_id = p.sku_id
                                     AND coi.status NOT IN ('cancelled','expired')
       WHERE co.campaign_id = p.campaign_id
         AND co.pickup_store_id = p.store_id
         AND co.status NOT IN ('cancelled','expired','transferred_out')
         AND co.transferred_from_order_id IS NULL
    )
  );

GRANT SELECT ON public.v_picking_wave_campaign_mismatch TO authenticated;

COMMENT ON VIEW public.v_picking_wave_campaign_mismatch IS
  '撿貨單跨開團誤撿 / 無需求超撿偵測（唯讀）。排除合法跨團借調（campaign_id 標記的團'
  '在該店該 SKU 有活訂單需求）；誤標與 NULL 超撿照舊列出。與 rpc_create_wave_from_po'
  '的守衛同一不變式。基底 20260702000010。';

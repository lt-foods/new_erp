-- ============================================================================
-- ⚠️ 會改正式庫：還原 20261016000000（派車照採購單數量：叫貨後才取消的件數照派原店）
-- ----------------------------------------------------------------------------
-- 什麼時候用
--   貼完 supabase/migrations/20261016000000_picking_post_po_cancel_to_store.sql 之後，
--   確認查詢有 ❌、或派貨工作台／建撿貨單／分店追加因為這次改動出問題，就貼這一份。
--   只是想「先停用新規則」的話，用 kill_switch_20261016000000.sql 就好（只改一個時間，不用還原）。
--
-- 做了什麼（照順序）
--   1. 派貨表 v_picking_demand_by_po 回到 20260818000030 那一版（逐字；說明回到 20260816000050 那一句）
--   2. 建撿貨單 rpc_create_wave_from_po 回到「20260816000050 ＋ 20260923110000 總倉封頂」那一版（逐字）
--   3. 分店追加寫入 rpc_add_po_store_demands 回到 20261002000000 那一版（逐字）
--   4. 拿掉本檔新增的：rpc_order_cancel_po_notice、rpc_preview_po_store_addition_extra、
--      v_picking_post_po_cancelled、v_picking_po_rule_items、_picking_po_rule_cutover
--   ⛔ 紀錄表新加的欄位 po_delta_qty **留著**（可空、舊程式不會讀它；拿掉會丟掉已經寫進去的紀錄）。
--   不加 CASCADE：萬一有別的東西建在新 view 上，會直接報錯停下，不會連帶拿掉別人的東西。
--
-- 還原之後會怎樣
--   * 派貨工作台回到「只照客人現在還有效的訂單」帶數字：叫貨後才取消的件數又會留在總倉。
--     已經照派原店建好的撿貨單、派貨單不會被改（還原只改程式，不改任何一筆資料）。
--   * 前端已經合併的話：取消前的提醒查詢不在了 ⇒ 每次取消都會跳「無法確認是否已叫貨」（不擋取消）；
--     派貨工作台讀不到叫貨後取消那張表 ⇒ 上方一行紅字，其他功能照常。
--   * 要恢復就重貼一次 migration。
--
-- 執行方式
--   整份貼進 Supabase SQL Editor、按一次 Run。
--   第 0 段前置檢查放最前面：三支要還原的東西如果不是「本檔新版」也不是「改前那一版」，
--   或新東西的同名物件不是 20261016000000 建的，直接停下，一行都不會改。
--   整份可以重貼（已經還原過再貼，也只是把同樣的東西再寫一次）。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 前置檢查（只讀；只建暫存 view 比對、用完就丟）
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  l_bad       TEXT[] := ARRAY[]::TEXT[];
  l_rec       RECORD;
  l_oid       REGCLASS;
  l_kind      "char";
  l_note      TEXT;
  l_live      TEXT;
  l_def_0818  TEXT;
  l_def_new   TEXT;
  l_sig       TEXT;
BEGIN
  l_sig := (SELECT string_agg(md5(replace(p.prosrc, chr(13), '')), ',' ORDER BY p.oid)
              FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public' AND p.proname = 'rpc_create_wave_from_po');
  IF l_sig IS NULL OR l_sig NOT IN ('ea371af8434804c43a043334602f4205', 'cb6be9654963d06a9a4e06ca12ca471a') THEN
    l_bad := l_bad || ('建撿貨單 rpc_create_wave_from_po 不是本檔新版、也不是改前那一版：' || COALESCE(l_sig, '找不到'));
  END IF;

  l_sig := (SELECT string_agg(md5(replace(p.prosrc, chr(13), '')), ',' ORDER BY p.oid)
              FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public' AND p.proname = 'rpc_add_po_store_demands');
  IF l_sig IS NULL OR l_sig NOT IN ('220befc9d94d5e1c0aab37f41b627612', '87dfda93e5c1a54dc5ae8c8fd05dca44') THEN
    l_bad := l_bad || ('分店追加 rpc_add_po_store_demands 不是本檔新版、也不是改前那一版：' || COALESCE(l_sig, '找不到'));
  END IF;

  l_live := pg_get_viewdef(to_regclass('public.v_picking_demand_by_po'), true);
  EXECUTE $ppc0818$CREATE TEMP VIEW ppc_chk_demand_0818 AS
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
         SELECT DISTINCT poi.po_id,
            pc0.campaign_id
           FROM po_campaigns pc0
             JOIN purchase_order_items poi ON poi.id = pc0.po_item_id
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR (EXISTS ( SELECT 1
                   FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id AND src.pickup_store_id = co.pickup_store_id)))
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
                 SELECT pcp.po_id AS source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                     JOIN po_campaign_po pcp ON pcp.campaign_id = pwi.campaign_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL AND pwi.campaign_id IS NOT NULL AND pcp.po_id <> pw.source_po_id AND NOT (EXISTS ( SELECT 1
                           FROM po_campaign_po own
                          WHERE own.po_id = pw.source_po_id AND own.campaign_id = pwi.campaign_id))) u
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
                     JOIN picking_waves pw ON pw.id = ("substring"(t.transfer_no, '^WAVE-(\d+)-S'::text))::bigint
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
  WHERE COALESCE(sq.shipped_qty, 0::numeric) < GREATEST(COALESCE(g.gr_qty, 0::numeric), 1::numeric) AND (COALESCE(g.gr_qty, 0::numeric) > 0::numeric OR COALESCE(sd.demand_qty, 0::numeric) > 0::numeric)$ppc0818$;
  l_def_0818 := pg_get_viewdef(to_regclass('pg_temp.ppc_chk_demand_0818'), true);
  EXECUTE 'DROP VIEW pg_temp.ppc_chk_demand_0818';
  l_def_new := NULL;
  IF to_regclass('public.v_picking_post_po_cancelled') IS NOT NULL THEN
    EXECUTE $ppcnew$CREATE TEMP VIEW ppc_chk_demand_new AS
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
         SELECT DISTINCT poi.po_id,
            pc0.campaign_id
           FROM po_campaigns pc0
             JOIN purchase_order_items poi ON poi.id = pc0.po_item_id
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR (EXISTS ( SELECT 1
                   FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id AND src.pickup_store_id = co.pickup_store_id)))
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
                   FROM restock_demand
                UNION ALL
                 SELECT ppc.po_item_id,
                    ppc.store_id,
                    ppc.qty AS demand_qty
                   FROM v_picking_post_po_cancelled ppc
                  WHERE ppc.store_active) u
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
                 SELECT pcp.po_id AS source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                     JOIN po_campaign_po pcp ON pcp.campaign_id = pwi.campaign_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL AND pwi.campaign_id IS NOT NULL AND pcp.po_id <> pw.source_po_id AND NOT (EXISTS ( SELECT 1
                           FROM po_campaign_po own
                          WHERE own.po_id = pw.source_po_id AND own.campaign_id = pwi.campaign_id))) u
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
                     JOIN picking_waves pw ON pw.id = ("substring"(t.transfer_no, '^WAVE-(\d+)-S'::text))::bigint
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
  WHERE COALESCE(sq.shipped_qty, 0::numeric) < GREATEST(COALESCE(g.gr_qty, 0::numeric), 1::numeric) AND (COALESCE(g.gr_qty, 0::numeric) > 0::numeric OR COALESCE(sd.demand_qty, 0::numeric) > 0::numeric)$ppcnew$;
    l_def_new := pg_get_viewdef(to_regclass('pg_temp.ppc_chk_demand_new'), true);
    EXECUTE 'DROP VIEW pg_temp.ppc_chk_demand_new';
  END IF;
  IF l_live IS NULL THEN
    l_bad := l_bad || '找不到派貨表 v_picking_demand_by_po'::TEXT;
  ELSIF l_live IS DISTINCT FROM l_def_0818 AND l_live IS DISTINCT FROM l_def_new THEN
    l_bad := l_bad || ('派貨表 v_picking_demand_by_po 不是本檔新版、也不是 8/18 版（md5 去空白 '
                       || md5(regexp_replace(l_live, '\s+', '', 'g')) || '）')::TEXT;
  END IF;

  FOR l_rec IN
    SELECT * FROM (VALUES ('v_picking_po_rule_items'), ('v_picking_post_po_cancelled')) AS x(n)
  LOOP
    l_oid := to_regclass('public.' || l_rec.n);
    IF l_oid IS NOT NULL THEN
      l_kind := (SELECT c.relkind FROM pg_class c WHERE c.oid = l_oid);
      l_note := obj_description(l_oid, 'pg_class');
      IF l_kind <> 'v' OR position('post_po_cancel_to_store:20261016000000' IN COALESCE(l_note, '')) = 0 THEN
        l_bad := l_bad || ('public.' || l_rec.n || ' 不是 20261016000000 建的（說明裡沒有記號），不能拿掉');
      END IF;
    END IF;
  END LOOP;

  FOR l_rec IN
    SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
           position('post_po_cancel_to_store:20261016000000' IN p.prosrc) > 0 AS ours
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public'
       AND p.proname IN ('_picking_po_rule_cutover', 'rpc_preview_po_store_addition_extra',
                         'rpc_order_cancel_po_notice')
  LOOP
    IF NOT l_rec.ours THEN
      l_bad := l_bad || ('public.' || l_rec.proname || '(' || l_rec.args || ') 不是 20261016000000 建的，不能拿掉');
    END IF;
  END LOOP;

  IF array_length(l_bad, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。請先找工程師確認：\n%', array_to_string(l_bad, E'\n');
  END IF;
END
$precheck$;

-- ----------------------------------------------------------------------------
-- 1. 派貨表回到 20260818000030:61-267（逐字）。先做這一步，才不會再依賴 v_picking_post_po_cancelled。
-- ----------------------------------------------------------------------------
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
         SELECT DISTINCT poi.po_id,
            pc0.campaign_id
           FROM po_campaigns pc0
             JOIN purchase_order_items poi ON poi.id = pc0.po_item_id
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR (EXISTS ( SELECT 1
                   FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id AND src.pickup_store_id = co.pickup_store_id)))
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
                 SELECT pcp.po_id AS source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                     JOIN po_campaign_po pcp ON pcp.campaign_id = pwi.campaign_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL AND pwi.campaign_id IS NOT NULL AND pcp.po_id <> pw.source_po_id AND NOT (EXISTS ( SELECT 1
                           FROM po_campaign_po own
                          WHERE own.po_id = pw.source_po_id AND own.campaign_id = pwi.campaign_id))) u
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
                     JOIN picking_waves pw ON pw.id = ("substring"(t.transfer_no, '^WAVE-(\d+)-S'::text))::bigint
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

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖：PO × SKU × store 矩陣。campaign_demand 排除「跨店」衍生單、保留「同店」衍生單。'
  'wave_qty 含跨團借調歸屬分支（campaign 標記不屬於來源 PO 的 wave item，需求歸屬跟著標記走）；'
  'po_sku_already_wave/has_stock_left 維持跟著來源 PO。其餘語意同 20260807000000。';

-- ----------------------------------------------------------------------------
-- 2. 建撿貨單回到「20260816000050:268 ＋ 20260923110000 總倉封頂」（內文逐字，指紋 ea371af8434804c43a043334602f4205）
-- ----------------------------------------------------------------------------
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
  v_hq_location_id  BIGINT;
  v_stock_over      RECORD;
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
  -- 4.2 守衛：跨 PO / 舊 PO 殘留時，總分配不可超過總倉真正可派量。
  --     open wave 只算 draft / picking / picked；shipped 已經由出倉流程扣 on_hand，
  --     若再算一次會把同一批貨重複保留。
  SELECT id INTO v_hq_location_id
    FROM public.locations
   WHERE tenant_id = v_tenant
     AND type = 'central_warehouse'
     AND is_active = TRUE
   ORDER BY id
   LIMIT 1;

  IF v_hq_location_id IS NULL THEN
    RAISE EXCEPTION '找不到總倉 location(type=central_warehouse)';
  END IF;

  -- 與退回貨 reserved / 其他派貨建單共用同一 balance 鎖；SKU 升冪避免死鎖。
  FOR v_sku_id IN
    SELECT DISTINCT (a->>'sku_id')::BIGINT
      FROM jsonb_array_elements(p_allocations) a
     ORDER BY 1
  LOOP
    PERFORM 1
      FROM public.stock_balances
     WHERE tenant_id = v_tenant
       AND location_id = v_hq_location_id
       AND sku_id = v_sku_id
     FOR UPDATE;
  END LOOP;

  WITH alloc_agg AS (
    SELECT
      (a->>'sku_id')::BIGINT AS sku_id,
      SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  open_wave_reserved AS (
    SELECT pwi.sku_id, SUM(pwi.qty) AS qty
      FROM public.picking_wave_items pwi
      JOIN public.picking_waves pw ON pw.id = pwi.wave_id
     WHERE pw.tenant_id = v_tenant
       AND pw.status IN ('draft','picking','picked')
       AND pwi.sku_id IN (SELECT sku_id FROM alloc_agg)
     GROUP BY pwi.sku_id
  ),
  hq_state AS (
    SELECT
      aa.sku_id,
      aa.total_alloc,
      GREATEST(COALESCE(sb.on_hand, 0) - COALESCE(sb.reserved, 0), 0) AS hq_available_qty,
      COALESCE(ow.qty, 0) AS open_wave_qty
    FROM alloc_agg aa
    LEFT JOIN public.stock_balances sb
      ON sb.tenant_id = v_tenant
     AND sb.location_id = v_hq_location_id
     AND sb.sku_id = aa.sku_id
    LEFT JOIN open_wave_reserved ow ON ow.sku_id = aa.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
    hs.total_alloc,
    hs.hq_available_qty,
    hs.open_wave_qty,
    GREATEST(hs.hq_available_qty - hs.open_wave_qty, 0) AS hq_left
  INTO v_stock_over
  FROM hq_state hs
  JOIN public.skus s ON s.id = hs.sku_id AND s.tenant_id = v_tenant
  WHERE hs.total_alloc > GREATEST(hs.hq_available_qty - hs.open_wave_qty, 0)
  LIMIT 1;

  IF v_stock_over.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」分配 % 超過總倉可派量 %（帳上可派 %、未出倉撿貨單已保留 %）',
      v_stock_over.sku_code, v_stock_over.sku_label,
      v_stock_over.total_alloc, v_stock_over.hq_left,
      v_stock_over.hq_available_qty, v_stock_over.open_wave_qty;
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

COMMENT ON FUNCTION public.rpc_create_wave_from_po(BIGINT, DATE, JSONB, UUID) IS
  '由派貨工作台建撿貨單。跨團守衛：本單開團有需求 → 標該團；補貨來源 → NULL + 補貨 cap；'
  '都沒有 → 跨團借調（標「實際被服務的團」，總量 ≤ 本單餘量 = 可分配 − 自己未派需求，'
  '步驟 4.5 守衛）。新增總倉庫存封頂：本次分配 + 未出倉 wave 保留量 ≤ on_hand - reserved。';

-- ----------------------------------------------------------------------------
-- 3. 分店追加寫入回到 20261002000000:794-1280（逐字，指紋 220befc9d94d5e1c0aab37f41b627612）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_add_po_store_demands(
  p_po_id        BIGINT,
  p_po_item_id   BIGINT,
  p_campaign_id  BIGINT,
  p_additions    JSONB,
  p_operator     UUID,
  p_request_key  UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- po_store_additions:20261002000000
DECLARE
  v_tenant            UUID;
  v_reason            TEXT;
  v_existing          RECORD;
  v_existing_po_item  BIGINT;
  v_po_qty_now        NUMERIC;
  v_po                RECORD;
  v_poi               RECORD;
  v_pr                RECORD;
  v_campaign          RECORD;
  v_ci                RECORD;
  v_res               RECORD;
  v_bad_count         INTEGER := 0;
  v_missing_store_ids TEXT;
  v_store_count       INTEGER := 0;
  v_store_added_qty   NUMERIC := 0;
  v_order_count       INTEGER := 0;
  v_delta             NUMERIC;
  v_demand            NUMERIC;
  v_already           NUMERIC;
  v_x                 NUMERIC := 0;
  v_pr_qty_after      NUMERIC;
  v_po_qty_after      NUMERIC;
  v_stores            JSONB;
  v_same_payload      BOOLEAN;
  r                   RECORD;
BEGIN
  PERFORM public._pr_qty_sync_assert_perm();

  v_tenant := public._current_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;

  IF p_operator IS NULL THEN
    RAISE EXCEPTION 'operator is required';
  END IF;

  IF auth.uid() IS NOT NULL AND p_operator <> auth.uid() THEN
    RAISE EXCEPTION 'operator must match current user';
  END IF;

  IF p_request_key IS NULL THEN
    RAISE EXCEPTION 'request key is required';
  END IF;

  -- ── 防重送（比照 #995）────────────────────────────────────────────────────
  -- 跟 #995 用**同一個前綴**的鎖：兩支共用 purchase_request_store_additions 與它的
  -- (tenant_id, request_key, store_id) 唯一索引，同一把 key 不管從哪一支進來都會排隊。
  PERFORM pg_advisory_xact_lock(hashtext('pr_store_add:' || p_request_key::TEXT));

  SELECT COUNT(*)                                     AS store_count,
         COUNT(DISTINCT a.pr_item_id)                 AS item_cnt,
         COUNT(DISTINCT a.campaign_id)                AS camp_cnt,
         MIN(a.pr_id)                                 AS pr_id,
         MIN(a.pr_item_id)                            AS pr_item_id,
         MIN(a.campaign_id)                           AS campaign_id,
         bool_and(a.created_by IS NOT DISTINCT FROM p_operator) AS same_operator,
         COALESCE(SUM(a.qty_added), 0)                AS store_added_qty,
         COALESCE(MAX(a.pr_delta_qty), 0)             AS pr_delta_qty,
         MAX(a.pr_qty_after)                          AS pr_qty_after,
         jsonb_agg(jsonb_build_object(
           'store_id', a.store_id,
           'qty', a.qty_added,
           'order_id', a.order_id,
           'order_item_id', a.order_item_id
         ) ORDER BY a.store_id)                       AS stores
    INTO v_existing
    FROM public.purchase_request_store_additions a
   WHERE a.tenant_id = v_tenant
     AND a.request_key = p_request_key;

  IF v_existing.store_count > 0 THEN
    SELECT pri.po_item_id
      INTO v_existing_po_item
      FROM public.purchase_request_items pri
     WHERE pri.id = v_existing.pr_item_id;

    SELECT poi.qty_ordered
      INTO v_po_qty_now
      FROM public.purchase_order_items poi
     WHERE poi.id = p_po_item_id
       AND poi.po_id = p_po_id;

    IF v_existing.item_cnt <> 1
       OR v_existing.camp_cnt <> 1
       OR NOT v_existing.same_operator
       OR v_existing_po_item IS DISTINCT FROM p_po_item_id
       OR v_po_qty_now IS NULL THEN
      RAISE EXCEPTION 'request key already used by another store-addition request';
    END IF;

    -- 同一個視窗重送：團、各店數量都要跟第一次**完全一樣**才回上次結果。
    -- 不一樣＝第一次可能其實已經寫進去（例：網路斷了沒收到回應），使用者又改了內容再送；
    -- 照舊回「上次結果」會讓畫面以為改過的內容生效了 → 擋下，請他重新整理看實際狀況。
    -- 各店數量的算法跟第一次寫紀錄時一樣（同一家店加總、取到小數三位，見下面 _po_store_add_input），
    -- 比對的是紀錄表上每列的 store_id／qty_added（表不加欄位）。
    IF v_existing.campaign_id <> p_campaign_id
       OR p_additions IS NULL
       OR jsonb_typeof(p_additions) <> 'array' THEN
      v_same_payload := FALSE;
    ELSE
      WITH sent_now AS (
        SELECT x.store_id::BIGINT AS store_id, SUM(x.qty)::NUMERIC(18,3) AS qty
          FROM jsonb_to_recordset(p_additions) AS x(store_id BIGINT, qty NUMERIC)
         GROUP BY x.store_id
      ),
      sent_before AS (
        SELECT a.store_id, a.qty_added AS qty
          FROM public.purchase_request_store_additions a
         WHERE a.tenant_id = v_tenant
           AND a.request_key = p_request_key
      )
      SELECT NOT EXISTS (SELECT store_id, qty FROM sent_now EXCEPT SELECT store_id, qty FROM sent_before)
         AND NOT EXISTS (SELECT store_id, qty FROM sent_before EXCEPT SELECT store_id, qty FROM sent_now)
        INTO v_same_payload;
    END IF;

    IF NOT v_same_payload THEN
      RAISE EXCEPTION '這個視窗之前已經送出過不同的團或數量（可能已經寫進去了），請關掉視窗、重新整理頁面確認後再操作；這次什麼都沒有改';
    END IF;

    -- 上次已經做完：照紀錄回傳，不重做。
    -- ⚠️ 採購單「改之前是多少」紀錄表沒有存（表不加欄位），所以 po_qty_before 回 NULL、
    --    po_qty_after 回**現值**（之後若有人再改過，就不是當時的數字）。
    RETURN jsonb_build_object(
      'po_id', p_po_id,
      'po_item_id', p_po_item_id,
      'campaign_id', p_campaign_id,
      'request_key', p_request_key,
      'pr_id', v_existing.pr_id,
      'pr_item_id', v_existing.pr_item_id,
      'stores', v_existing.stores,
      'store_count', v_existing.store_count,
      'store_added_qty', v_existing.store_added_qty,
      'po_added_qty', v_existing.pr_delta_qty,
      'po_qty_before', NULL,
      'po_qty_after', v_po_qty_now,
      'pr_qty_after', v_existing.pr_qty_after,
      'idempotent', TRUE
    );
  END IF;

  -- ── 先檢查一次（還沒上鎖；不行就早點停，不必去搶鎖）──────────────────────
  v_reason := public._po_item_store_add_block_reason(p_po_item_id, p_campaign_id);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION '%', v_reason;
  END IF;

  -- ── 輸入（解析與分店檢查照抄 #995；數量檢查比 #995 嚴，見下）──────────────────
  IF p_additions IS NULL OR jsonb_typeof(p_additions) <> 'array' OR jsonb_array_length(p_additions) = 0 THEN
    RAISE EXCEPTION '請至少選一間分店或批發與數量';
  END IF;

  DROP TABLE IF EXISTS pg_temp._po_store_add_raw;
  CREATE TEMP TABLE _po_store_add_raw ON COMMIT DROP AS
  SELECT
    x.store_id::BIGINT AS store_id,
    x.qty::NUMERIC AS qty
  FROM jsonb_to_recordset(p_additions) AS x(store_id BIGINT, qty NUMERIC);

  -- 數量檢查（審查第三輪 P1）：每一列原始輸入、同一家店加總後，各查一次。
  --   ・NaN／Infinity：直接打 RPC 傳字串 "NaN"、"Infinity" 會被轉成 numeric 的特殊值；
  --     NaN 在 Postgres 裡比任何數字都大，光寫 `qty <= 0` 擋不住，會一路寫進採購單、請購單的數量與金額。
  --   ・寫入欄位只到小數三位（NUMERIC(18,3)）：0.0004 這種取到三位後變 0 的值，
  --     要在這裡用白話擋下，不要拖到資料表 CHECK 才報技術錯誤。
  --   ⇒ 最終條件：不是 NaN／±Infinity，而且取到小數三位後 > 0。
  --   （#995 rpc_add_pr_store_demands 有同樣的缺口，本檔沒動它。）
  SELECT COUNT(*)
    INTO v_bad_count
    FROM pg_temp._po_store_add_raw
   WHERE store_id IS NULL
      OR qty IS NULL
      OR qty::TEXT IN ('NaN', 'Infinity', '-Infinity')
      OR round(qty, 3) <= 0;

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION '分店／批發追加數量必須是大於 0 的數字（最多三位小數）';
  END IF;

  DROP TABLE IF EXISTS pg_temp._po_store_add_input;
  CREATE TEMP TABLE _po_store_add_input ON COMMIT DROP AS
  SELECT store_id, SUM(qty)::NUMERIC(18,3) AS qty
    FROM pg_temp._po_store_add_raw
   GROUP BY store_id;

  -- 同一家店拆成好幾列時，加總（取到小數三位）後再查一次同一個條件
  SELECT COUNT(*)
    INTO v_bad_count
    FROM pg_temp._po_store_add_input
   WHERE qty IS NULL
      OR qty::TEXT IN ('NaN', 'Infinity', '-Infinity')
      OR qty <= 0;

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION '分店／批發追加數量必須是大於 0 的數字（最多三位小數）';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(qty), 0)
    INTO v_store_count, v_store_added_qty
    FROM pg_temp._po_store_add_input;

  SELECT string_agg(i.store_id::TEXT, ',')
    INTO v_missing_store_ids
    FROM pg_temp._po_store_add_input i
    LEFT JOIN public.stores s
      ON s.id = i.store_id
     AND s.tenant_id = v_tenant
     AND s.is_active = TRUE
     AND s.deleted_at IS NULL
     AND COALESCE(s.store_kind, 'branch') IN ('branch', 'wholesale')
   WHERE s.id IS NULL;

  IF v_missing_store_ids IS NOT NULL THEN
    RAISE EXCEPTION '有分店／批發不存在、停用或已刪除：%', v_missing_store_ids;
  END IF;

  -- ── 上鎖＋寫入（包在內層區塊裡：被判死結／拿不到品項鎖時整筆不寫、改回白話訊息）────
  -- 上鎖順序：採購單（排隊等）→ 採購單品項（NOWAIT）→ 請購單與品項 → 團 → (團, 商品)。
  -- 為什麼這樣排、品項為什麼 NOWAIT：見檔頭「上鎖順序」。
  BEGIN
    SELECT po.id, po.po_no, po.status
      INTO v_po
      FROM public.purchase_orders po
     WHERE po.id = p_po_id
       AND po.tenant_id = v_tenant
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION '找不到這張採購單';
    END IF;

    SELECT poi.id, poi.sku_id, poi.qty_ordered
      INTO v_poi
      FROM public.purchase_order_items poi
     WHERE poi.id = p_po_item_id
       AND poi.po_id = p_po_id
     FOR UPDATE NOWAIT;

    IF NOT FOUND THEN
      RAISE EXCEPTION '這個商品不在這張採購單上';
    END IF;

    PERFORM 1
       FROM public.purchase_request_items pri
       JOIN public.purchase_requests pr
         ON pr.id = pri.pr_id
      WHERE pri.po_item_id = p_po_item_id
        AND pri.sku_id = v_poi.sku_id
        AND pr.tenant_id = v_tenant
      ORDER BY pri.id
      FOR UPDATE OF pr, pri;

    SELECT gbc.id, gbc.campaign_no, gbc.name, gbc.status
      INTO v_campaign
      FROM public.group_buy_campaigns gbc
     WHERE gbc.id = p_campaign_id
       AND gbc.tenant_id = v_tenant
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION '找不到這個團 %', p_campaign_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(p_campaign_id::TEXT), hashtext(v_poi.sku_id::TEXT));

    -- >>> RECHECK BEGIN（鎖完再跑一次同一套檢查 —— 不可拿掉）
    -- 第一次檢查到上鎖之間，可能有人開了進貨單、撿貨單、按了斷貨或改了團的狀態。
    -- 那些動作都會碰到我們剛鎖的列（UPDATE 或外鍵），所以這時候再查一次一定看得到。
    v_reason := public._po_item_store_add_block_reason(p_po_item_id, p_campaign_id);
    IF v_reason IS NOT NULL THEN
      RAISE EXCEPTION '%', v_reason;
    END IF;
    -- <<< RECHECK END

    -- 要改的那一列請購品項（檢查已保證：剛好一列、總數 = 各團明細加總）
    SELECT pr.id AS pr_id, pr.pr_no, pri.id AS pr_item_id, pri.qty_requested
      INTO v_pr
      FROM public.purchase_request_items pri
      JOIN public.purchase_requests pr
        ON pr.id = pri.pr_id
      JOIN public.purchase_request_item_campaigns pric
        ON pric.pr_item_id = pri.id
       AND pric.campaign_id = p_campaign_id
       AND pric.tenant_id = v_tenant
     WHERE pri.po_item_id = p_po_item_id
       AND pri.sku_id = v_poi.sku_id
       AND pr.tenant_id = v_tenant
       AND pr.status <> 'cancelled';

    IF NOT FOUND THEN
      RAISE EXCEPTION '內部錯誤：找不到要改的請購品項（po_item_id=%）', p_po_item_id;
    END IF;

    SELECT ci.id, ci.unit_price
      INTO v_ci
      FROM public.campaign_items ci
     WHERE ci.tenant_id = v_tenant
       AND ci.campaign_id = p_campaign_id
       AND ci.sku_id = v_poi.sku_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION '此品項不屬於指定原團';
    END IF;

    DROP TABLE IF EXISTS pg_temp._po_store_add_done;
    CREATE TEMP TABLE _po_store_add_done (
      store_id      BIGINT,
      qty           NUMERIC,
      order_id      BIGINT,
      order_item_id BIGINT,
      order_created BOOLEAN
    ) ON COMMIT DROP;

    -- >>> STEP1 BEGIN（第 1 步：每家店建店家內部單 +N）
    FOR r IN SELECT store_id, qty FROM pg_temp._po_store_add_input ORDER BY store_id
    LOOP
      SELECT o.o_order_id, o.o_order_item_id, o.o_order_created
        INTO v_res
        FROM public._store_add_internal_order_item(
               v_tenant, p_campaign_id, v_campaign.campaign_no, v_ci.id, v_poi.sku_id,
               v_ci.unit_price, r.store_id, r.qty, p_operator,
               format('【採購單分店／批發追加】%s', v_po.po_no),
               format('採購單 %s 分店／批發追加', v_po.po_no)
             ) o;

      INSERT INTO pg_temp._po_store_add_done (store_id, qty, order_id, order_item_id, order_created)
      VALUES (r.store_id, r.qty, v_res.o_order_id, v_res.o_order_item_id, v_res.o_order_created);

      IF v_res.o_order_created THEN
        v_order_count := v_order_count + 1;
      END IF;
    END LOOP;
    -- <<< STEP1 END

    -- 第 2 步：差額（加完店家單之後）。X = max(差額, 0)
    SELECT d.delta_qty, d.demand_qty, d.already_qty
      INTO v_delta, v_demand, v_already
      FROM public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id]) d
     WHERE d.campaign_id = p_campaign_id
       AND d.sku_id = v_poi.sku_id;

    v_x := GREATEST(COALESCE(v_delta, 0), 0);

    -- >>> STEP3 BEGIN（第 3 步：請購單 +X，先各團明細、後總數 —— 順序反了 #982 守衛會擋）
    IF v_x > 0 THEN
      UPDATE public.purchase_request_item_campaigns
         SET qty_requested = qty_requested + v_x
       WHERE pr_item_id = v_pr.pr_item_id
         AND campaign_id = p_campaign_id
         AND tenant_id = v_tenant;

      IF NOT FOUND THEN
        RAISE EXCEPTION '內部錯誤：請購品項的這一團明細在途中消失了（pr_item_id=%）', v_pr.pr_item_id;
      END IF;

      UPDATE public.purchase_request_items
         SET qty_requested = qty_requested + v_x,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = v_pr.pr_item_id;

      -- 請購單總金額：跟 #995（20260924010000:372-380）同一個算法；line_subtotal 是 generated column
      UPDATE public.purchase_requests pr
         SET total_amount = COALESCE((
               SELECT SUM(pri.line_subtotal)
                 FROM public.purchase_request_items pri
                WHERE pri.pr_id = v_pr.pr_id
             ), 0),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE pr.id = v_pr.pr_id;
    END IF;
    -- <<< STEP3 END

    SELECT pri.qty_requested
      INTO v_pr_qty_after
      FROM public.purchase_request_items pri
     WHERE pri.id = v_pr.pr_item_id;

    -- 第 4 步：採購單 +X，再重算表頭（算法見檔頭：subtotal = SUM(qty_ordered * unit_cost)、
    --          total = subtotal、tax 不動 —— 跟 rpc_split_pr_to_pos 20260428120000:396-405 相同）
    IF v_x > 0 THEN
      UPDATE public.purchase_order_items
         SET qty_ordered = qty_ordered + v_x,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = p_po_item_id;

      UPDATE public.purchase_orders po
         SET subtotal   = COALESCE((SELECT SUM(qty_ordered * unit_cost)
                                      FROM public.purchase_order_items WHERE po_id = po.id), 0),
             total      = COALESCE((SELECT SUM(qty_ordered * unit_cost)
                                      FROM public.purchase_order_items WHERE po_id = po.id), 0),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE po.id = p_po_id;
    END IF;

    SELECT poi.qty_ordered
      INTO v_po_qty_after
      FROM public.purchase_order_items poi
     WHERE poi.id = p_po_item_id;

    -- 第 5 步：每家店一列追加紀錄（表不加欄位；採購單從 pr_item_id → po_item_id 查得到）
    INSERT INTO public.purchase_request_store_additions (
      tenant_id, pr_id, pr_item_id, campaign_id, store_id,
      order_id, order_item_id, sku_id, qty_added, request_key, created_by,
      pr_delta_qty, pr_qty_after
    )
    SELECT v_tenant, v_pr.pr_id, v_pr.pr_item_id, p_campaign_id, d.store_id,
           d.order_id, d.order_item_id, v_poi.sku_id, d.qty, p_request_key, p_operator,
           v_x, v_pr_qty_after
      FROM pg_temp._po_store_add_done d
     ORDER BY d.store_id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'store_id', d.store_id,
             'qty', d.qty,
             'order_id', d.order_id,
             'order_item_id', d.order_item_id,
             'order_created', d.order_created
           ) ORDER BY d.store_id), '[]'::JSONB)
      INTO v_stores
      FROM pg_temp._po_store_add_done d;

    RETURN jsonb_build_object(
      'po_id', p_po_id,
      'po_no', v_po.po_no,
      'po_item_id', p_po_item_id,
      'campaign_id', p_campaign_id,
      'campaign_no', v_campaign.campaign_no,
      'request_key', p_request_key,
      'pr_id', v_pr.pr_id,
      'pr_no', v_pr.pr_no,
      'pr_item_id', v_pr.pr_item_id,
      'stores', v_stores,
      'store_count', v_store_count,
      'store_added_qty', v_store_added_qty,
      'po_added_qty', v_x,
      'po_qty_before', v_poi.qty_ordered,
      'po_qty_after', v_po_qty_after,
      'pr_qty_before', v_pr.qty_requested,
      'pr_qty_after', v_pr_qty_after,
      'demand_qty', v_demand,
      'already_qty_before_sync', v_already,
      'delta_qty', v_delta,
      'created_order_count', v_order_count,
      'idempotent', FALSE
    );
  EXCEPTION
    -- >>> LOCKMSG BEGIN
    WHEN lock_not_available THEN
      -- 採購單品項被別人鎖著（例：同時有人按斷貨、調整已收量 —— 它們先鎖品項再鎖採購單）。
      -- 不等：等的話會跟對方互等（死結），Postgres 可能挑對方當犧牲者。
      RAISE EXCEPTION '有人同時在操作這張採購單的這個商品（例如按斷貨、調整已收量），請稍後再按一次；這次什麼都沒有改'
        USING DETAIL = 'lock_not_available: ' || SQLERRM;
    WHEN deadlock_detected THEN
      RAISE EXCEPTION '有人同時在操作這張採購單，請稍後再按一次；這次什麼都沒有改'
        USING DETAIL = 'deadlock_detected: ' || SQLERRM;
    -- <<< LOCKMSG END
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) IS
  '採購單頁「分店／批發追加」：替分店／批發在原團加店家內部單（+N），再用 _pr_campaign_sku_remaining_rows 算出 X = max(差額, 0)，請購單（先各團明細後總數）與採購單各 +X。不重開團、不通知廠商。同一 request_key 重送：團與各店數量都一樣才回上次結果，不一樣就擋。採購單品項被別人鎖著或被判死結時整筆不寫、回白話訊息。';

-- ----------------------------------------------------------------------------
-- 4. 拿掉本檔新增的（函式先、view 後、分界時間最後：view 依賴它）
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_order_cancel_po_notice(BIGINT, BIGINT);
DROP FUNCTION IF EXISTS public.rpc_preview_po_store_addition_extra(BIGINT);
DROP VIEW IF EXISTS public.v_picking_post_po_cancelled;
DROP VIEW IF EXISTS public.v_picking_po_rule_items;
DROP FUNCTION IF EXISTS public._picking_po_rule_cutover();

NOTIFY pgrst, 'reload schema';

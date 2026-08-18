-- ============================================================================
-- 2026-08-18: 撿貨波次 ↔ 轉移單改用「解析出來的 wave id」等值 join，不要用單號 LIKE
--
-- 症狀：/wms 派貨工作台的來源查詢（v_picking_demand_by_po，篩
--   has_stock_left = true AND has_demand_left = true）線上 mean 4.4s / max 5.0s，
--   帶 RLS 實測 **7.0 秒** —— PostgREST 的上限是 8 秒，已經在 timeout 邊緣。
--
-- 原因：transfers 沒有 wave_id 欄位，跟 picking_waves 的唯一關聯是單號字串
--   `WAVE-<wave_id>-S<store_id>`，於是 view 裡寫成
--
--     JOIN picking_waves pw ON t.transfer_no LIKE 'WAVE-' || pw.id || '-S%'
--
--   LIKE 的右手邊帶著另一張表的欄位 → 既不能走索引也不能 hash join，planner
--   只能做巢狀迴圈把兩邊乘開。線上 10,737 張 hq_to_store 轉移單 × 1,160 個有
--   source_po_id 的波次：
--
--     Nested Loop (actual time=0.077..5629.448 rows=10395)
--       Join Filter: (t_1.transfer_no ~~ (('WAVE-' || pw_1.id) || '-S%'))
--       Rows Removed by Join Filter: 12,444,525     ← 1,244 萬次字串串接 + LIKE
--
--   單這一個節點就 5.6 秒，佔整支 7 秒的 80%。
--
-- 修法：把 wave id 從單號解析出來做**等值** join，planner 就能改用 hash join：
--
--     JOIN picking_waves pw ON pw.id = substring(t.transfer_no, '^WAVE-(\d+)-S')::bigint
--
--   同一個 CTE 裡取 store_id 本來就是這樣寫的（`substring(t.transfer_no,
--   'WAVE-\d+-S(\d+)')::bigint`），只是 join 這一側沒跟上。
--
--   語意相同：substring 對非 WAVE- 開頭的單號回 NULL，`pw.id = NULL` 永遠不成立，
--   跟 LIKE 一樣把它們排除；而 'WAVE-1-S%' 也不會誤中 'WAVE-12-S3'（LIKE 要求
--   'WAVE-1' 後面緊接 '-S'）。線上 11,765 張轉移單裡 11,488 張是 WAVE- 開頭，
--   全部嚴格符合 `^WAVE-\d+-S\d+$`，0 個例外。
--
-- 驗證（transaction 內建新 view、對拍後 ROLLBACK；一定要開
--   `ISOLATION LEVEL REPEATABLE READ`，否則正式庫同時間的寫入會被算成假差異，
--   理由見同批的 20260818000020 檔頭）：
--   v_picking_demand_by_po：兩側各 24,600 列，EXCEPT ALL 雙向都是 **0 筆**差異。
--     速度 4,188ms → 1,204ms（3.5 倍；上面那個 7 秒是帶 RLS 的數字，
--     搭配同批的 20260818000020 會再降）。
--   v_pr_progress：兩側 EXCEPT ALL 雙向 0 筆差異。
--     它今天還不慢（purchase_requests 只有 298 列，而且 LATERAL 內先用
--     `pw.source_po_id = poi.po_id` 收斂過），純粹是把同一顆未爆彈一起拆掉。
--
-- 基底版本：兩支 view 都是從**線上 pg_get_viewdef() 現況**取出、只替換那一行
--   join 條件，其餘逐字保留（v_picking_demand_by_po 最近一次是
--   20260709000000_v_picking_demand_has_stock_left.sql，但不要信這行 —— 依
--   CLAUDE.md，改之前請重新 grep 一次）。
--
-- Rollback：把 `pw.id = substring(...)::bigint` 改回
--   `t.transfer_no LIKE 'WAVE-' || pw.id || '-S%'`（會慢回去，但語意一樣）。
--
-- 沒有對應的前端改動。
--
-- ⚠ 後續：同樣的字串 join 在 migration 歷史裡還有十幾處（RPC / 函式內），
--   grep `WAVE-' ||` 找得到。那些多半是單一 wave id 的等值比對（`t.transfer_no =
--   'WAVE-' || pwi.wave_id || '-S' || co.pickup_store_id`），常數對常數不會乘開，
--   所以不在這次範圍。真正的根治是給 transfers 加一個 wave_id 欄位。
-- ============================================================================

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

CREATE OR REPLACE VIEW public.v_pr_progress AS
SELECT pr.id AS pr_id,
    pr.tenant_id,
    pr.source_close_date,
    COALESCE(po_agg.po_total, 0::bigint) AS po_total,
    COALESCE(po_agg.po_sent, 0::bigint) AS po_sent,
    COALESCE(po_agg.po_received_fully, 0::bigint) AS po_received_fully,
    COALESCE(xfer_agg.transfer_total, 0::bigint) AS transfer_total,
    COALESCE(xfer_agg.transfer_shipped, 0::bigint) AS transfer_shipped,
    COALESCE(xfer_agg.transfer_delivered, 0::bigint) AS transfer_delivered,
    COALESCE(item_agg.item_count, 0::bigint) AS item_count,
    COALESCE(item_agg.unassigned_supplier_count, 0::bigint) AS unassigned_supplier_count,
        CASE
            WHEN pr.source_close_date IS NULL THEN false
            WHEN cmp.total_campaigns = 0 THEN false
            ELSE cmp.completed_campaigns = cmp.total_campaigns
        END AS all_campaigns_finalized
   FROM purchase_requests pr
     LEFT JOIN LATERAL ( SELECT count(DISTINCT po.id) AS po_total,
            count(DISTINCT po.id) FILTER (WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text, 'closed'::text])) AS po_sent,
            count(DISTINCT po.id) FILTER (WHERE po.status = ANY (ARRAY['fully_received'::text, 'closed'::text])) AS po_received_fully
           FROM purchase_request_items pri
             JOIN purchase_order_items poi ON poi.id = pri.po_item_id
             JOIN purchase_orders po ON po.id = poi.po_id
          WHERE pri.pr_id = pr.id) po_agg ON true
     LEFT JOIN LATERAL ( SELECT count(DISTINCT t.id) AS transfer_total,
            count(DISTINCT t.id) FILTER (WHERE t.status = ANY (ARRAY['shipped'::text, 'received'::text, 'closed'::text])) AS transfer_shipped,
            count(DISTINCT t.id) FILTER (WHERE t.status = ANY (ARRAY['received'::text, 'closed'::text])) AS transfer_delivered
           FROM purchase_request_items pri
             JOIN purchase_order_items poi ON poi.id = pri.po_item_id
             JOIN picking_waves pw ON pw.source_po_id = poi.po_id
             JOIN transfers t ON t.tenant_id = pr.tenant_id AND t.transfer_type = 'hq_to_store'::text AND pw.id = ("substring"(t.transfer_no, '^WAVE-(\d+)-S'::text))::bigint
          WHERE pri.pr_id = pr.id AND pri.po_item_id IS NOT NULL) xfer_agg ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS item_count,
            count(*) FILTER (WHERE pri.suggested_supplier_id IS NULL) AS unassigned_supplier_count
           FROM purchase_request_items pri
          WHERE pri.pr_id = pr.id) item_agg ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS total_campaigns,
            count(*) FILTER (WHERE gbc.status = 'completed'::text) AS completed_campaigns
           FROM group_buy_campaigns gbc
          WHERE gbc.tenant_id = pr.tenant_id AND pr.source_close_date IS NOT NULL AND date((gbc.end_at AT TIME ZONE 'Asia/Taipei'::text)) = pr.source_close_date AND gbc.status <> 'cancelled'::text) cmp ON true;

-- ============================================================
-- 收貨短少：標「補出貨」不等於補到了 —— 貨真的補到之前，異常不消失
--
-- 事故案例（cktalex 2026-08-07 回報）：
--   訂單 GRP-20260714-013-0003（id=50856，平鎮店）(D)芋頭生乳捲 G01109-04
--   卡在「待取」永遠取不到，但總倉哪裡都看不到這件事。追下去：
--     8/3 02:41  WAVE-857-S1（transfer 8597）出貨 4 個品項到平鎮店
--     8/3 06:16  店家收貨，單頭寫「少收1  (D)芋頭生乳捲沒有來」，
--                transfer_item 16571：qty_shipped=1 / qty_received=0
--                → 異常頁「收貨短少」正確列出
--     8/4 09:36  總倉在異常頁把它標成 shortage_resolution='replenish'
--                （補出貨）→ 該列從異常頁消失
--     ……但從來沒有任何一張補貨的 transfer 建出來（線上查證：8/3 之後
--       sku 3168 沒有任何新的 transfer，經總倉現貨也是 0）。
--   結果：店家看得到一行永遠待取的品項，總倉看不到任何異常。
--
-- 錯在哪：
--   rpc_resolve_transfer_item_shortage 只是「標記」——
--   它自己的註解就寫「實際補出貨/取消訂單由其他流程做」。
--   其他三個選項（accept 認賠 / cancel_orders 取消訂單 / vendor_claim 求償）
--   標記完事情就真的結束了，唯獨 replenish 是一個「之後要補」的承諾；
--   把它跟其他三個一樣當成結案，等於承諾一寫下就沒人再追。
--   線上目前 replenish 只有這 1 筆 —— 正是出事的這筆。
--
--   另外「訂單短少」也接不住這種單：v_order_shortage 是 SKU 累計帳
--   （需求 vs 該 SKU 歷來 GR），sku 3168 訂 9 收 9、剩餘需求 5，
--   帳上不缺貨 —— 貨確實進了總倉、也發出去了，只是有 1 件在送到
--   平鎮店的路上不見了。這種「總量夠、個別店沒收到」本來就只能靠
--   收貨短少這條線看，所以這條線不能被一個標記關掉。
--
-- 修法（只動 v_hq_exceptions 的 transfer_short 分支）：
--   1. 標 replenish 的短少列繼續顯示，直到該店該 SKU 在標記之後
--      真的又收到貨、累計實收補滿缺口為止（自癒：補貨 transfer 一收貨
--      就自動消失，不用再回來按一次）。
--      其餘三種 resolution（accept / cancel_orders / vendor_claim）
--      維持標記即結案，行為不變。
--   2. extra 補上「已標補出貨,尚未補到」，跟還沒處理的短少一眼分得出來。
--   3. reason 帶出店家收貨當下寫的備註（transfers.notes）——
--      「少收1 (D)芋頭生乳捲沒有來」這種第一手描述本來就寫在系統裡，
--      只是異常頁沒顯示（reason 一直是 NULL）。
--
-- 2026-08-07 線上 dry-run：
--   before：transfer_short 154 筆
--   after ：transfer_short 155 筆（+1 = transfer_item 16571，
--           extra 顯示「分店少收或運送中遺失 · 已標補出貨,尚未補到」，
--           reason 顯示店家備註）。其餘 154 筆完全不動。
--
-- 基底版本（依 CLAUDE.md 規則，以 2026-08-07 線上 pg_get_viewdef 逐字取回）：
--   v_hq_exceptions 線上版比 repo 最後一版（20260704000020）多了三處
--   從未進 repo 的線上 hotfix，本檔一併收錄，避免下次再被蓋掉：
--     - po_shortage / po_over 合併成同一個掃描分支（CASE 分型別）
--     - 新增 doc_id 欄（各型別對應的主檔 id）
--     - 新增 warehouse_name 欄（rpc_hq_exceptions 的 p_search 會搜它）
--   rpc_hq_exceptions 不動（欄位與型別皆未變）。
-- TEST：docs/TEST-transfer-shortage-replenish-followup.md
-- Rollback：CREATE OR REPLACE VIEW 回本檔內文，transfer_short 分支的
--   WHERE 還原為 `ti.shortage_resolution IS NULL`，reason 還原為 NULL::text，
--   extra 移除 replenish 後綴。
-- ============================================================

CREATE OR REPLACE VIEW public.v_hq_exceptions AS
-- 1+3. 進貨短少 / 過量進貨（同一次掃描，用 CASE 分型別）
 SELECT
        CASE
            WHEN pd.qty_shortage > 0::numeric THEN 'po_shortage'::text
            ELSE 'po_over'::text
        END AS type,
    ((
        CASE
            WHEN pd.qty_shortage > 0::numeric THEN 'po-short-'::text
            ELSE 'po-over-'::text
        END || pd.po_id::text) || ':'::text) || pd.sku_id::text AS row_key,
    po.created_at AS ts,
    pd.po_no AS doc_no,
    pd.sku_code,
    pd.sku_label,
    pd.qty_ordered::numeric AS expected,
    pd.gr_qty AS actual,
        CASE
            WHEN pd.qty_shortage > 0::numeric THEN pd.qty_shortage
            ELSE pd.gr_qty - pd.qty_ordered
        END AS diff,
    NULL::text AS reason,
        CASE
            WHEN pd.qty_shortage > 0::numeric THEN 'PO 已關單,差額不會到'::text
            ELSE '供應商多送或重複入庫'::text
        END AS extra,
    NULL::bigint AS transfer_item_id,
    NULL::bigint AS transfer_id,
    NULL::text AS transfer_no,
    pd.sku_id,
    NULL::numeric AS qty_shipped,
    NULL::numeric AS qty_received,
    NULL::numeric AS shortage_qty,
    NULL::bigint AS dest_location,
    NULL::bigint AS dest_store_id,
    NULL::text AS dest_store_name,
    NULL::bigint AS customer_order_id,
    NULL::text AS shortage_resolution,
    pd.po_id AS doc_id,
    ( SELECT l.name
           FROM locations l
          WHERE l.id = po.dest_location_id) AS warehouse_name
   FROM ( SELECT DISTINCT v_picking_demand_by_po.po_id,
            v_picking_demand_by_po.sku_id,
            v_picking_demand_by_po.po_no,
            v_picking_demand_by_po.sku_code,
            v_picking_demand_by_po.sku_label,
            v_picking_demand_by_po.qty_ordered,
            v_picking_demand_by_po.gr_qty,
            v_picking_demand_by_po.qty_shortage
           FROM v_picking_demand_by_po
          WHERE v_picking_demand_by_po.qty_shortage > 0::numeric OR v_picking_demand_by_po.gr_qty > v_picking_demand_by_po.qty_ordered) pd
     LEFT JOIN purchase_orders po ON po.id = pd.po_id
UNION ALL
-- 2. 進貨破損
 SELECT 'po_damage'::text AS type,
    'po-dmg-'::text || gri.id::text AS row_key,
    gr.created_at AS ts,
    gr.gr_no AS doc_no,
    s.sku_code,
    COALESCE(NULLIF(TRIM(BOTH FROM COALESCE(s.product_name, ''::text) || COALESCE(' / '::text || NULLIF(s.variant_name, ''::text), ''::text)), ''::text), '品項#'::text || gri.sku_id::text) AS sku_label,
    gri.qty_received::numeric AS expected,
    gri.qty_received - gri.qty_damaged AS actual,
    gri.qty_damaged::numeric AS diff,
    gri.variance_reason AS reason,
    (('已收 '::text || gri.qty_received::text) || ' 含瑕疵 '::text) || gri.qty_damaged::text AS extra,
    NULL::bigint AS transfer_item_id,
    NULL::bigint AS transfer_id,
    NULL::text AS transfer_no,
    gri.sku_id,
    NULL::numeric AS qty_shipped,
    NULL::numeric AS qty_received,
    NULL::numeric AS shortage_qty,
    NULL::bigint AS dest_location,
    NULL::bigint AS dest_store_id,
    NULL::text AS dest_store_name,
    NULL::bigint AS customer_order_id,
    NULL::text AS shortage_resolution,
    gr.po_id AS doc_id,
    ( SELECT l.name
           FROM locations l
          WHERE l.id = gr.dest_location_id) AS warehouse_name
   FROM goods_receipt_items gri
     JOIN goods_receipts gr ON gr.id = gri.gr_id
     LEFT JOIN skus s ON s.id = gri.sku_id
  WHERE gri.qty_damaged > 0::numeric AND gr.status = 'confirmed'::text
UNION ALL
-- 4. 收貨短少（分店實收 < 出貨）
--    2026-08-07：標 replenish（補出貨）只是承諾，貨補到之前不算結案。
 SELECT 'transfer_short'::text AS type,
    'tshort-'::text || ti.id::text AS row_key,
    COALESCE(t.received_at, t.created_at) AS ts,
    t.transfer_no AS doc_no,
    s.sku_code,
    COALESCE(NULLIF(TRIM(BOTH FROM COALESCE(s.product_name, ''::text) || COALESCE(' / '::text || NULLIF(s.variant_name, ''::text), ''::text)), ''::text), '品項#'::text || ti.sku_id::text) AS sku_label,
    ti.qty_shipped::numeric AS expected,
    ti.qty_received::numeric AS actual,
    ti.qty_shipped - ti.qty_received AS diff,
    -- 店家收貨當下寫的備註（第一手描述，例：「少收1 (D)芋頭生乳捲沒有來」）
    CASE WHEN NULLIF(TRIM(BOTH FROM COALESCE(t.notes, ''::text)), ''::text) IS NOT NULL
         THEN '店家收貨備註：'::text || TRIM(BOTH FROM t.notes)
         ELSE NULL::text
    END AS reason,
        CASE
            WHEN COALESCE(ti.damage_qty, 0::numeric) > 0::numeric THEN '含破損 '::text || ti.damage_qty::text
            ELSE '分店少收或運送中遺失'::text
        END
        || CASE WHEN ti.shortage_resolution = 'replenish'::text
                THEN ' · 已標補出貨,尚未補到'::text
                ELSE ''::text
           END AS extra,
    ti.id AS transfer_item_id,
    ti.transfer_id,
    t.transfer_no,
    ti.sku_id,
    ti.qty_shipped::numeric AS qty_shipped,
    ti.qty_received::numeric AS qty_received,
    ti.qty_shipped - ti.qty_received AS shortage_qty,
    t.dest_location,
    ( SELECT ds.id
           FROM stores ds
          WHERE ds.location_id = t.dest_location
          ORDER BY ds.id
         LIMIT 1) AS dest_store_id,
    COALESCE(( SELECT ds.name
           FROM stores ds
          WHERE ds.location_id = t.dest_location
          ORDER BY ds.id
         LIMIT 1), ( SELECT l.name
           FROM locations l
          WHERE l.id = t.dest_location), '位置 #'::text || COALESCE(t.dest_location::text, '?'::text)) AS dest_store_name,
    NULL::bigint AS customer_order_id,
    NULL::text AS shortage_resolution,
    ti.transfer_id AS doc_id,
    COALESCE(( SELECT ds.name
           FROM stores ds
          WHERE ds.location_id = t.dest_location
          ORDER BY ds.id
         LIMIT 1), ( SELECT l.name
           FROM locations l
          WHERE l.id = t.dest_location), '位置 #'::text || COALESCE(t.dest_location::text, '?'::text)) AS warehouse_name
   FROM transfer_items ti
     JOIN transfers t ON t.id = ti.transfer_id
     LEFT JOIN skus s ON s.id = ti.sku_id
  WHERE t.status = 'received'::text
    AND ti.qty_received < ti.qty_shipped
    AND (
      ti.shortage_resolution IS NULL
      -- 標了「補出貨」但補的貨還沒到（標記之後該店該 SKU 累計實收 < 缺口）→ 繼續掛著
      OR (
        ti.shortage_resolution = 'replenish'::text
        AND COALESCE((
          SELECT SUM(ti2.qty_received)
            FROM transfers t2
            JOIN transfer_items ti2 ON ti2.transfer_id = t2.id
           WHERE t2.dest_location = t.dest_location
             AND t2.tenant_id     = t.tenant_id
             AND ti2.sku_id       = ti.sku_id
             AND t2.status IN ('received'::text, 'closed'::text)
             AND COALESCE(t2.received_at, t2.updated_at) > ti.shortage_resolution_at
        ), 0::numeric) < (ti.qty_shipped - ti.qty_received)
      )
    )
UNION ALL
-- 5. 訂單短少（v_order_shortage 聚合到 order 維度）
 SELECT 'customer_shortage'::text AS type,
    'custshort-'::text || agg.order_id::text AS row_key,
    agg.ts,
    agg.order_no AS doc_no,
    NULL::text AS sku_code,
    agg.sku_label,
    agg.expected,
    GREATEST(0::numeric, agg.expected - agg.total_unfulfillable) AS actual,
    agg.total_unfulfillable AS diff,
        CASE agg.shortage_resolution
            WHEN 'notified'::text THEN '✓ 已通知客戶'::text
            WHEN 'cancelled'::text THEN '✓ 已取消退款'::text
            WHEN 'reallocated'::text THEN '✓ 已改派'::text
            WHEN 'waiting_next_po'::text THEN '⏳ 等下批 PO'::text
            ELSE NULL::text
        END AS reason,
    ((((COALESCE(agg.store_name, '—'::text) || ' · 會員 #'::text) || COALESCE(agg.member_id::text, '—'::text)) || ' · '::text) || agg.short_item_count::text) || ' 樣品項短少'::text AS extra,
    NULL::bigint AS transfer_item_id,
    NULL::bigint AS transfer_id,
    NULL::text AS transfer_no,
    NULL::bigint AS sku_id,
    NULL::numeric AS qty_shipped,
    NULL::numeric AS qty_received,
    NULL::numeric AS shortage_qty,
    NULL::bigint AS dest_location,
    NULL::bigint AS dest_store_id,
    NULL::text AS dest_store_name,
    agg.order_id AS customer_order_id,
    agg.shortage_resolution,
    agg.order_id AS doc_id,
    agg.store_name AS warehouse_name
   FROM ( SELECT vos.order_id,
            max(vos.order_no) AS order_no,
            max(vos.member_id) AS member_id,
            max(vos.store_name) AS store_name,
            max(vos.shortage_resolution) AS shortage_resolution,
            max(vos.order_updated_at) AS ts,
            sum(vos.order_qty) AS expected,
            sum(vos.demand_unfulfillable) AS total_unfulfillable,
            count(*) AS short_item_count,
            string_agg(
                CASE
                    WHEN vos.sku_code IS NOT NULL AND vos.sku_code <> ''::text THEN (vos.sku_code || ' '::text) || COALESCE(NULLIF(TRIM(BOTH FROM COALESCE(vos.product_name, ''::text) || COALESCE(' / '::text || NULLIF(vos.variant_name, ''::text), ''::text)), ''::text), '品項#'::text || vos.sku_id::text)
                    ELSE COALESCE(NULLIF(TRIM(BOTH FROM COALESCE(vos.product_name, ''::text) || COALESCE(' / '::text || NULLIF(vos.variant_name, ''::text), ''::text)), ''::text), '品項#'::text || vos.sku_id::text)
                END, '、'::text ORDER BY vos.sku_id) AS sku_label
           FROM v_order_shortage vos
          GROUP BY vos.order_id) agg;

GRANT SELECT ON public.v_hq_exceptions TO authenticated;

COMMENT ON VIEW public.v_hq_exceptions IS
  '總倉收件匣異常統一 view：union 進貨短少/破損/過量/收貨短少/訂單短少 5 來源為扁平列，'
  '供 rpc_hq_exceptions 做 server-side 分頁與計數。'
  '收貨短少：標 replenish（補出貨）只是承諾，該店該 SKU 在標記之後累計實收補滿缺口前不下架；'
  'accept / cancel_orders / vendor_claim 維持標記即結案。';

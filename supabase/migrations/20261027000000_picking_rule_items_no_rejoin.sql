-- ============================================================================
-- 20261027000000_picking_rule_items_no_rejoin.sql
--
-- 派貨工作台讀不出來（一直「載入中…」）：v_picking_demand_by_po 在正式庫 8 秒逾時。
--
-- 根因：v_picking_po_rule_items（20261016000000 A3）最後一步
--   `JOIN purchase_order_items poi ON poi.id = l.po_item_id WHERE poi.created_at >= 分界時間`
--   回頭撈採購單品項的建立時間。purchase_order_items.created_at 的統計停在 10/12
--   （早於分界 10/16），planner 估「分界後的採購單品項 = 1 列」→ 把整段
--   po_campaigns＋window（~30 萬列、約 1 秒）放在 nested loop 內側，
--   分界後每多一個採購單品項就整段重算一次。10/27 有 323 個 → 單跑這支 66 秒，
--   v_picking_post_po_cancelled 兩段各用一次 → 2 分鐘，派貨表直接逾時。
--   10/22 資料庫重啟把 autovacuum 的異動計數歸零，統計一直沒被重算。
--   （分界後的品項只會越來越多 —— 不修的話就算重算統計，下一次統計過期又會回來。
--    所以本檔不做 ANALYZE：新寫法不靠統計，統計過期也不會再走進這個坑。）
--
-- 修法：po_skus 直接帶出 poi.created_at，window 算完在同一層用它過濾，不再回頭 JOIN。
--   結果逐列不變（同一個 poi.id → 同一個 created_at；n_po_items 仍是對全部有效採購單品項算，
--   分界條件仍在 window 之後才套）。輸出欄位、順序、型別不變 → CREATE OR REPLACE，
--   依賴它的 v_picking_post_po_cancelled → v_picking_demand_by_po → v_hq_exceptions、
--   rpc_create_wave_from_po、rpc_preview_po_store_addition_extra、rpc_order_cancel_po_notice、
--   rpc_picking_post_po_cancelled_by_sku 都不用動。
--
-- 實測（正式庫，temp view 對拍）：v_picking_post_po_cancelled 2 分鐘 → 2.3 秒，
--   派貨工作台那句（has_stock_left/has_demand_left + 排序）逾時 → 4.6 秒。
--
-- 基底：20261016000000 A3（已核對與正式庫 pg_get_viewdef 一致），只改三行。
-- rollback：重貼 20261016000000 A3 那段 CREATE OR REPLACE VIEW（結果相同，只是慢）。
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.v_picking_po_rule_items AS
WITH po_skus AS (
         SELECT po.id AS po_id,
            po.tenant_id,
            po.po_no,
            po.status AS po_status,
            po.supplier_id,
            poi.id AS po_item_id,
            poi.sku_id,
            poi.qty_ordered,
            poi.created_at AS po_item_created_at,
            (EXISTS ( SELECT 1
                   FROM purchase_request_items pri2
                     JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
                  WHERE pri2.po_item_id = poi.id)) AS is_restock_sourced
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text])
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
        ), linked AS (
         SELECT ps.tenant_id,
            ps.po_id,
            ps.po_item_id,
            ps.sku_id,
            pc.campaign_id,
            ps.po_item_created_at,
            count(*) OVER (PARTITION BY pc.campaign_id, ps.sku_id) AS n_po_items
           FROM po_campaigns pc
             JOIN po_skus ps ON ps.po_item_id = pc.po_item_id
        )
 SELECT l.tenant_id,
    l.po_id,
    l.po_item_id,
    l.sku_id,
    l.campaign_id,
    l.po_item_created_at AS ordered_at
   FROM linked l
  WHERE l.n_po_items = 1 AND l.po_item_created_at >= _picking_po_rule_cutover();

COMMENT ON VIEW public.v_picking_po_rule_items IS
  '派車照採購單數量（post_po_cancel_to_store:20261016000000；20261027000000 改成不回頭 JOIN 採購單品項）：一列＝套新規則的（採購單品項, 團, 商品）。條件：這一團這樣商品剛好只連到 1 個有效採購單品項（連法同 v_picking_demand_by_po），而且那個採購單品項在分界時間 _picking_po_rule_cutover() 之後成立。ordered_at＝採購單品項建立時間（叫貨那一刻）。只讀；不給前端角色直接讀。';

REVOKE ALL ON public.v_picking_po_rule_items FROM PUBLIC, anon, authenticated;

COMMIT;

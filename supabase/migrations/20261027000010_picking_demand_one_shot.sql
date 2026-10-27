-- ============================================================================
-- 20261027000010_picking_demand_one_shot.sql
--
-- 派貨工作台打開要等 20 多秒（20261027000000 修好逾時之後）：
--   1. v_picking_demand_by_po 每次都把所有未結案採購單（~1,700 張、4.5 萬列）從頭算一遍，
--      再挑出要派的 ~3,300 列，一次 ~5 秒。
--   2. 前端一次只能拿 1,000 列（PostgREST max_rows），fetchAllRows 分 4 頁接著拿，
--      每一頁都整張 view 重算一次 → 4 × 5 秒。
--   3. v_picking_post_po_cancelled 兩段（整張取消／刪品項）各算一次 v_picking_po_rule_items（~1 秒／次）。
--
-- 這支：
--   A. v_picking_post_po_cancelled：v_picking_po_rule_items 包成 MATERIALIZED CTE，兩段共用、只算一次。
--      基底 20261016000000 A4（已核對與正式庫 pg_get_viewdef 一致），兩段內文一字不動，
--      只把 `FROM v_picking_po_rule_items r` 換成 `FROM r`。輸出欄位不變 → CREATE OR REPLACE，
--      v_picking_demand_by_po 與四支讀它的 RPC 都不用動。
--      （rpc_picking_post_po_cancelled_by_sku 原本靠 sku 條件推進去也是 ~1 秒，包起來後實測一樣 ~1 秒。）
--   B. 新增 rpc_picking_dispatchable_demand()：工作台「全清單矩陣」那句
--      （has_stock_left AND has_demand_left、po_item_id, store_id NULLS LAST 排序）一次整包回 jsonb，
--      不受 1,000 列上限 → 整張 view 只算一次。SECURITY INVOKER：權限跟前端直接讀 view 一模一樣。
--
-- 實測（正式庫，temp view 對拍）：v_picking_post_po_cancelled / v_picking_demand_by_po
--   新舊 EXCEPT ALL 兩邊都 0；派貨表那句 4.7 秒 → 3.8 秒；工作台載入 4 次 → 1 次。
--
-- rollback：
--   A. 重貼 20261016000000 A4 那段 CREATE OR REPLACE VIEW（結果相同，只是慢）。
--   B. DROP FUNCTION public.rpc_picking_dispatchable_demand();
--      （前端讀不到這支會自動退回舊的分頁讀法。）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A. 叫貨後才取消的訂單品項：v_picking_po_rule_items 只算一次
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE VIEW public.v_picking_post_po_cancelled AS
WITH r AS MATERIALIZED (
  SELECT * FROM v_picking_po_rule_items
)
-- (1) 整張取消：訂單取消時間晚於叫貨、品項本身沒有取消／過期
 SELECT r.tenant_id,
    r.po_id,
    r.po_item_id,
    r.sku_id,
    r.campaign_id,
    co.pickup_store_id AS store_id,
    co.id AS order_id,
    coi.id AS order_item_id,
    coi.qty,
    co.cancelled_at,
    COALESCE(st.is_active AND st.deleted_at IS NULL, false) AS store_active
   FROM r
     JOIN customer_orders co ON co.tenant_id = r.tenant_id
                             AND co.campaign_id = r.campaign_id
                             AND co.status = 'cancelled'::text
                             AND co.cancelled_at > r.ordered_at
                             AND co.transferred_from_order_id IS NULL
                             AND co.stockout_at IS NULL
     JOIN customer_order_items coi ON coi.order_id = co.id
                                  AND coi.sku_id = r.sku_id
                                  AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
                                  AND coi.stockout_at IS NULL
                                  AND coi.created_at <= r.ordered_at
     LEFT JOIN stores st ON st.id = co.pickup_store_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM customer_order_audit_log ra
          WHERE ra.order_id = co.id
            AND ra.entity_type = 'order'::text
            AND ra.entity_id = co.id
            AND ra.field = 'status'::text
            AND ra.before_value = to_jsonb('cancelled'::text)
            AND ra.after_value <> to_jsonb('cancelled'::text)
            AND ra.created_at > r.ordered_at))
UNION ALL
-- (2) 刪單一品項：品項取消、編輯歷史有一筆「狀態→取消」晚於叫貨、訂單不是轉出
 SELECT r.tenant_id,
    r.po_id,
    r.po_item_id,
    r.sku_id,
    r.campaign_id,
    co.pickup_store_id AS store_id,
    co.id AS order_id,
    coi.id AS order_item_id,
    coi.qty,
    ia.cancelled_at,
    COALESCE(st.is_active AND st.deleted_at IS NULL, false) AS store_active
   FROM r
     JOIN customer_order_items coi ON coi.tenant_id = r.tenant_id
                                  AND coi.sku_id = r.sku_id
                                  AND coi.status = 'cancelled'::text
                                  AND coi.stockout_at IS NULL
                                  AND coi.created_at <= r.ordered_at
     JOIN customer_orders co ON co.id = coi.order_id
                             AND co.campaign_id = r.campaign_id
                             AND co.status <> 'transferred_out'::text
                             AND co.transferred_from_order_id IS NULL
                             AND co.stockout_at IS NULL
     JOIN LATERAL ( SELECT min(l.created_at) AS cancelled_at
           FROM customer_order_audit_log l
          WHERE l.order_id = co.id
            AND l.entity_type = 'item'::text
            AND l.entity_id = coi.id
            AND l.field = 'status'::text
            AND l.after_value = to_jsonb('cancelled'::text)
            AND l.created_at > r.ordered_at) ia ON ia.cancelled_at IS NOT NULL
     LEFT JOIN stores st ON st.id = co.pickup_store_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM customer_order_audit_log ra
          WHERE ra.order_id = co.id
            AND ra.entity_type = 'order'::text
            AND ra.entity_id = co.id
            AND ra.field = 'status'::text
            AND ra.before_value = to_jsonb('cancelled'::text)
            AND ra.after_value <> to_jsonb('cancelled'::text)
            AND ra.created_at > r.ordered_at));

COMMENT ON VIEW public.v_picking_post_po_cancelled IS
  '派車照採購單數量（post_po_cancel_to_store:20261016000000；20261027000010 v_picking_po_rule_items 兩段共用只算一次）：一列＝一個叫貨後才取消的訂單品項（只看 v_picking_po_rule_items 的採購單品項；叫貨前就有、不是轉入單、沒有斷貨標記；整張取消晚於叫貨或刪品項歷史晚於叫貨；叫貨後沒有復原取消過）。store_active＝門市啟用且沒刪除；派貨表只帶 store_active 的列，停用店留給總倉決定。只讀；不給前端角色直接讀（前端用 rpc_picking_post_po_cancelled_by_sku）。';

REVOKE ALL ON public.v_picking_post_po_cancelled FROM PUBLIC, anon, authenticated;

COMMIT;

-- ----------------------------------------------------------------------------
-- B. 派貨工作台「全清單矩陣」一次整包讀
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_picking_dispatchable_demand()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(
           jsonb_agg(to_jsonb(v) ORDER BY v.po_item_id, v.store_id NULLS LAST),
           '[]'::jsonb)
    FROM public.v_picking_demand_by_po v
   WHERE v.has_stock_left
     AND v.has_demand_left;
$$;

COMMENT ON FUNCTION public.rpc_picking_dispatchable_demand() IS
  '派貨工作台全清單矩陣（20261027000010）：v_picking_demand_by_po 中 has_stock_left AND has_demand_left 的列，依 po_item_id, store_id NULLS LAST 排序，一次整包回 jsonb 陣列（不受 PostgREST 1000 列上限、view 只算一次）。SECURITY INVOKER，權限同直接讀 view。';

REVOKE ALL ON FUNCTION public.rpc_picking_dispatchable_demand() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_picking_dispatchable_demand() TO authenticated, service_role;

COMMIT;

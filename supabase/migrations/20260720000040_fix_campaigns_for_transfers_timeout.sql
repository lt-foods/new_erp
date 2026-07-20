-- ============================================================
-- 修 rpc_get_campaigns_for_transfers / rpc_get_campaigns_for_transfer 慢查詢 timeout
--
-- 動機：postgres logs 7/13 出現 14 次 statement timeout（57014），全部來自
--   PostgREST 呼叫 rpc_get_campaigns_for_transfers（/wms/inbound 收貨待辦頁）。
--   pg_stat_statements：1809 次呼叫、平均 1976ms、最大 7995ms —— 剛好頂到
--   authenticated role 的 statement_timeout=8s，尖峰時就炸。
--
-- 根因（EXPLAIN ANALYZE 實測，永和店 336 張 shipped transfers）：
--   1. `COALESCE(co.order_kind, 'normal') = 'normal'` 不可 sarg，planner 估 245
--      列、實際 49017 列（全表幾乎都是 normal），join order 被帶歪成
--      nested loop 掃全部 customer_orders × customer_order_items（6 萬+ 列）
--      → 1927ms。改成 `(order_kind = 'normal' OR order_kind IS NULL)` 後
--      估算正確、planner 改走 hash join → 141ms（同語意，13.7x）。
--   2. transfer_items 完全沒有 transfer_id 索引（只有 pkey 與 shortage 部分
--      索引），`WHERE transfer_id = ANY(...)` 全是 seq scan。pg_stat_user_tables:
--      seq_scan 231 萬次、seq_tup_read 147 億。補 (transfer_id, sku_id)。
--
-- 語意完全不變：`COALESCE(x,'normal')='normal'` ≡ `(x='normal' OR x IS NULL)`。
--
-- 基底版本：
--   rpc_get_campaigns_for_transfers = 20260708000030（唯一版本）
--   rpc_get_campaigns_for_transfer  = 20260516000007（v2，最新版本）
-- rollback：重跑上列兩支 migration 的 CREATE OR REPLACE，
--   並 DROP INDEX IF EXISTS idx_transfer_items_transfer;
-- ============================================================

-- 1) 批次版（/wms/inbound 實際在用的）
CREATE OR REPLACE FUNCTION rpc_get_campaigns_for_transfers(
  p_transfer_ids BIGINT[]
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH t AS (
    SELECT id, customer_order_id, dest_location, tenant_id
      FROM transfers
     WHERE id = ANY(p_transfer_ids)
  ),
  ti AS (
    SELECT DISTINCT transfer_id, sku_id
      FROM transfer_items
     WHERE transfer_id = ANY(p_transfer_ids)
  ),
  from_co_match AS (
    -- 從 dest store + 該 transfer 的 sku 對到的 customer_orders.campaign_id
    SELECT DISTINCT t.id AS transfer_id, co.campaign_id
      FROM t
      JOIN stores s
        ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
      JOIN customer_orders co
        ON co.pickup_store_id = s.id
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      JOIN customer_order_items coi ON coi.order_id = co.id
      JOIN ti ON ti.transfer_id = t.id AND ti.sku_id = coi.sku_id
     WHERE co.campaign_id IS NOT NULL
  ),
  from_aid AS (
    -- aid transfer 直接帶 customer_order_id
    SELECT DISTINCT t.id AS transfer_id, co.campaign_id
      FROM t
      JOIN customer_orders co ON co.id = t.customer_order_id
     WHERE co.campaign_id IS NOT NULL
  ),
  unioned AS (
    SELECT transfer_id, campaign_id FROM from_co_match
    UNION
    SELECT transfer_id, campaign_id FROM from_aid
  ),
  per_transfer AS (
    SELECT transfer_id, jsonb_agg(DISTINCT campaign_id) AS cids
      FROM unioned
     GROUP BY transfer_id
  )
  SELECT COALESCE(jsonb_object_agg(transfer_id::text, cids), '{}'::jsonb)
    FROM per_transfer;
$$;

-- 2) 單筆版（前端已改用批次版，但函式仍部署著、可被呼叫，同病同修）
CREATE OR REPLACE FUNCTION rpc_get_campaigns_for_transfer(
  p_transfer_id BIGINT
) RETURNS TABLE(campaign_id BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH t AS (
    SELECT id, transfer_no, customer_order_id, dest_location, tenant_id
      FROM transfers WHERE id = p_transfer_id
  ),
  store AS (
    SELECT s.id AS store_id
      FROM t
      JOIN stores s ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
  ),
  skus AS (
    SELECT DISTINCT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id
  ),
  from_co_match AS (
    -- 從 dest store + sku 對到的 customer_orders.campaign_id
    SELECT DISTINCT co.campaign_id
      FROM customer_orders co
      JOIN store s ON s.store_id = co.pickup_store_id
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE coi.sku_id IN (SELECT sku_id FROM skus)
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
  ),
  from_aid AS (
    -- aid transfer 直接帶 customer_order_id
    SELECT DISTINCT co.campaign_id
      FROM customer_orders co
      JOIN t ON t.customer_order_id = co.id
  )
  SELECT campaign_id FROM from_co_match WHERE campaign_id IS NOT NULL
  UNION
  SELECT campaign_id FROM from_aid WHERE campaign_id IS NOT NULL
$$;

-- 3) transfer_items 缺 transfer_id 索引：收貨/揀貨所有「查某張 transfer 的明細」
--    全在 seq scan（10.7k 列、每日成長）。(transfer_id, sku_id) 同時涵蓋
--    本函式 ti CTE 的 DISTINCT 與一般明細查詢。
CREATE INDEX IF NOT EXISTS idx_transfer_items_transfer
  ON transfer_items (transfer_id, sku_id);

-- ============================================================
-- fixture: with-stock
-- 在每個 location（總倉 + 5 店）幫每支 SKU 灌一筆初始庫存
-- 量級：總倉 100 個、店家 20 個。avg_cost 取 supplier_skus.default_unit_cost 折 0.95
--
-- 改版：走 stock_movements (type='manual_adjust') 鏈，由 trigger 自動更新
--      stock_balances + 保留審計歷史。為了讓 reverse 情境可以走 stock_movements
--      鏈（如 R6 transfer / R7 damage 找得到對應 source movement），開帳行
--      也用 stock_movements 寫入。
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

-- 開帳行：每個 (location × sku) 一筆 manual_adjust 正向 movement
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO stock_movements (
  tenant_id, location_id, sku_id, quantity, unit_cost,
  movement_type, source_doc_type, reason, operator_id
)
SELECT :'tenant_id'::uuid,
       l.id,
       s.id,
       (CASE WHEN l.type = 'central_warehouse' THEN 100 ELSE 20 END)::numeric,
       ROUND(COALESCE(ss.default_unit_cost, 50) * 0.95, 4),
       'manual_adjust',
       'opening_balance',
       'E2E 開帳行 (with-stock fixture)',
       (SELECT id FROM any_user)
FROM locations l
CROSS JOIN skus s
LEFT JOIN supplier_skus ss
       ON ss.tenant_id = s.tenant_id
      AND ss.sku_id    = s.id
      AND ss.is_preferred = TRUE
WHERE l.tenant_id = :'tenant_id'::uuid
  AND s.tenant_id = :'tenant_id'::uuid;

-- trigger apply_movement_to_balance 已自動把 stock_balances 拉起來
-- 這裡確認一下沒漏（保險：可能某些 SKU 的 supplier_skus 全部 is_preferred=FALSE）

COMMIT;

\echo 'fixture with-stock seeded (stock_movements + auto stock_balances).'

-- ============================================================
-- Phase 5c step 7 — customer_orders UNIQUE 改 partial（active 才 unique）
--
-- 問題：UNIQUE (tenant, campaign, channel, member) 完整、不分 status
--   - rpc_transfer_order_partial 的 upsert SELECT 排除 ('expired','cancelled','transferred_out')
--   - trio 若已有 closed-status row（例：5b-1 測試遺留 transferred_out 訂單）
--     → SELECT 找不到、INSERT 撞 UNIQUE → 「duplicate key value violates ...」
--
-- 修法：原 UNIQUE 改 partial WHERE status NOT IN (3 closed states)
--   - 同 trio active 仍只允許 1 筆（Q6: 同團同頻道同會員合併）
--   - 同 trio 可有 1+ closed + 1 active（場景：被 transferred_out 後再收新轉入）
-- ============================================================

ALTER TABLE customer_orders
  DROP CONSTRAINT customer_orders_tenant_id_campaign_id_channel_id_member_id_key;

CREATE UNIQUE INDEX customer_orders_trio_active_uniq
  ON customer_orders (tenant_id, campaign_id, channel_id, member_id)
  WHERE status NOT IN ('transferred_out', 'expired', 'cancelled');

COMMENT ON INDEX customer_orders_trio_active_uniq IS
  'Phase 5c step 7：同團同頻道同會員只允許一筆 active 訂單；closed (transferred_out/expired/cancelled) 不佔 slot';

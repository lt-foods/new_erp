---
title: TEST — is_order_pickup_ready 對 close_date aggregated PR 過嚴 (Bug A)
module: Pickup / Order
status: passed
ran_at: 2026-05-15
verified_by: alex.chen + claude (week simulator)
---

# Bug A: is_order_pickup_ready 對 close_date aggregated PR 過嚴

## 症狀

同日結多個 campaigns → `rpc_close_campaign` 走 close_date 路徑 → `rpc_create_pr_from_close_date` 聚合多 camps 成 1 PR → 1 wave、`picking_wave_items.campaign_id` 只能掛單一值（fn 用 `MIN(gbc.id)`）。

導致 wave_items.campaign_id != order.campaign_id 對於非「MIN id」的 camps、`is_order_pickup_ready` 路徑 B 找不到對應 wave_items、回 false、orders 永遠不能 pickup 即使 transfer 已 received。

## 影響

Production 同日結多 camps 業務流程 — HQ 同日結 N 團、只第一個 camp 的 orders 能取貨、其他 N-1 個 camp 全卡。

跑 week simulator 觀察到 19,665 orders 卡 not ready（後端鏈 chain 都完整、就是 ready check fail）。

## 修法

[20260615000010_fix_pickup_ready_aggregated_pr.sql](../supabase/migrations/20260615000010_fix_pickup_ready_aggregated_pr.sql)

加 Path C：「order 所有 active items 的 (sku, pickup_store) 都有對應 received/closed transfer」即算 ready。不檢 campaign_id 嚴格相等。

```sql
-- Path C (NEW)
NOT EXISTS (
  SELECT 1 FROM customer_order_items coi
   WHERE coi.order_id = co.id
     AND coi.status NOT IN ('picked_up', 'cancelled', 'expired')
     AND NOT EXISTS (
       SELECT 1
         FROM picking_wave_items pwi
         JOIN transfers t
           ON t.tenant_id = pwi.tenant_id
          AND t.transfer_type = 'hq_to_store'
          AND t.transfer_no = 'WAVE-' || pwi.wave_id || '-S' || co.pickup_store_id
          AND t.status IN ('received','closed')
        WHERE pwi.tenant_id = co.tenant_id
          AND pwi.store_id = co.pickup_store_id
          AND pwi.sku_id = coi.sku_id
     )
)
```

Path A (互助訂單) + Path B (per-camp PR 嚴格) 保留、Path C 新加做 fallback。

## 驗證

| 測項 | 修前 | 修後 |
|---|---|---|
| Week sim stuck orders (close_date PR) | 19,665 not ready | 4,120 → ready (含 fix 前已 chain 完的) |
| Pickup chain end-to-end | 卡死 | 跑得通 |
| Path B regression (per-camp PR) | ✓ 仍 work | ✓ 沒影響 |

## SQL

```sql
SELECT COUNT(*)
  FROM customer_orders co
 WHERE co.status NOT IN ('completed','cancelled','expired','transferred_out')
   AND is_order_pickup_ready(co.id) = true;
-- expect: matching transfers received 的 orders 數
```

## 之後該補

整合進 `TEST-E2E-T7-inbox.md` 或 `TEST-E2E-master.md` 的 § 7 取貨段：
- 加一個情境「同日多 camp 結單 → close_date PR aggregate → orders 全部 ready」
- 沒這 path C 會卡

# E2E Full Chain — 建商品到取貨完整鏈路測試

跑「建商品 → 開團 → 顧客下單 → 關團 → 採購 → 收貨 → 派貨 → 分店收貨 → 顧客取貨」整條鏈路、確認資料層一致 + invariants 全綠。

完整 spec + bug 故事：[docs/TEST-E2E-full-chain.md](../../../docs/TEST-E2E-full-chain.md)

## 一鍵跑

```bash
node scripts/e2e/full_chain/run_all.cjs
```

## 個別跑

```bash
node scripts/e2e/full_chain/01_setup.cjs       # product/SKU/prices/supplier_skus/campaign
node scripts/e2e/full_chain/03_orders.cjs      # 3 customer orders
node scripts/e2e/full_chain/04_close.cjs       # close campaign → auto PR
node scripts/e2e/full_chain/05_pr_po_gr.cjs    # PR → PO → GR
node scripts/e2e/full_chain/07_wave.cjs        # wave → 3 transfers
node scripts/e2e/full_chain/08_receive.cjs     # 3 stores receive
node scripts/e2e/full_chain/09_pickup.cjs      # SQL fallback pickup (orders 31/32)
node scripts/e2e/full_chain/10_invariants.cjs  # final invariants
```

## 設定

- Marker：`E2E-CHAIN-260514`（在 `01_setup.cjs` 開頭）
- DB：anfyoeviuhmzzrhilwtm dev pooler（連線寫在 `_db.cjs`）
- Admin：`cktalex@gmail.com` (uid `39fd694d-3af6-4978-beab-6e826dff7246`)

## Idempotent / 重跑限制

| Step | 重跑 |
|---|---|
| 01 setup | ✅ idempotent — reuse existing product/SKU/campaign |
| 03 orders | ✅ skip if orders already exist for (campaign, channel, member) |
| 04 close | ⚠️ 已 closed 後重跑會試 create_pr_from_campaign、若 PR 已有就 RAISE |
| 05-08 | ⚠️ 已 advance 的 status 重跑會卡 |
| 09 pickup | ⚠️ 已 picked_up 的 items 不會再做 |
| 10 invariants | ✅ 永遠可獨立跑 |

**整條鏈路只設計「首次跑」一次 + 「事後驗 invariant」。要重新測完整鏈路：**

A. 換 marker（修改 `MARKER`、用 `E2E-CHAIN-NEW-XXX`）然後重跑 → 建一批全新資料
B. Reset 整個 dev DB（`bash scripts/e2e/reset.sh full-demo`）然後改 marker 重跑

## 預期結果（2026-05-14 首次跑）

| Step | Result |
|---|---|
| 01 | product 16 / sku 16 / campaign 18 |
| 03 | 3 orders (id 30/31/32) qty 15/10/5 = 30 |
| 04 | PR 13 自動建 + `purchase_request_campaigns` trigger 自動同步 |
| 05 | PR submit (auto-approved by amount threshold) → PO 17 sent → GR 23 confirmed → stock +30 @ HQ |
| 07 | Wave 13 picked → 3 transfers (TF 29/30/31) shipped |
| 08 | 3 stores received → stock 各店 +5/+10/+15 |
| 09 | 3 orders completed (1 UI wallet + 1 SQL wallet + 1 SQL cash) |
| 10 | 4/4 invariants ✓ + stock 全 0 |

## 沿途發現的 bug + 修復

| Bug | Migration |
|---|---|
| PR↔Campaigns 不同步 | [20260614000010](../../../supabase/migrations/20260614000010_fix_pr_campaigns_sync.sql) + [20260614000020](../../../supabase/migrations/20260614000020_pr_campaigns_invariant_trigger.sql) |
| 取貨不扣分店 stock | [20260614000030](../../../supabase/migrations/20260614000030_fix_pickup_stock_movement.sql) |

## Troubleshooting

| 症狀 | 原因 | 解法 |
|---|---|---|
| `JWT missing tenant_id claim` | RPC 需要 JWT、pg client 沒帶 | `_db.cjs` 的 `setJwt()` 在 transaction 內注入 |
| `分店 X 未設定倉庫位置` | store.location_id NULL | INSERT location + UPDATE store.location_id |
| `PR X already submitted` | 重跑 | 預期；用 fresh marker 重跑 |
| `分配 X 超過可分配量 0` | wave 已建過 | 用 fresh marker 重跑 |
| `member status=merged cannot be charged` | M-TEST-003 是 merged | Step 09 fallback 自動用 cash |

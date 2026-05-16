# E2E Week Simulation — 一週混亂大規模模擬

跑 7 天「每日開新團 + 隨機混亂時序」的真實壓測。
完整 spec：[docs/TEST-E2E-week-simulation.md](../../../docs/TEST-E2E-week-simulation.md)

## 一鍵跑

```bash
# 1. (一次性) 補齊 stores 的 location_id + store_short_code
node scripts/e2e/week_simulation/00_backfill_stores.cjs

# 2. 跑模擬 (default = B+ 約 1 小時 / 10K orders)
DAYS=7 CAMPAIGNS_PER_DAY=10 STORES_MAX=10 ORDERS_MAX=25 \
  node scripts/e2e/week_simulation/run.cjs

# 3. 驗證 invariants + chain trace
node scripts/e2e/week_simulation/verify.cjs
```

## 規模選項（env vars）

| Scale | DAYS | CAMP/DAY | STORES_MAX | ORDERS_MAX | 訂單數 | 時間 |
|---|---|---|---|---|---|---|
| **default (B+)** | 7 | 10 | 10 | 25 | ~10K | ~1 hr |
| **smoke** | 2 | 3 | 3 | 5 | ~50 | ~1 min |
| **full A** | 7 | 20 | 15 | 50 | ~42K | ~3-4 hr |
| **custom** | env override 任一參數 | | | | | |

其他 env:
- `SEED` (default `'week-260514'`) — 同 seed 重跑結果一致
- `QTY_MIN` / `QTY_MAX` (default 1/5) — 每 item 件數範圍
- `SKUS_MIN` / `SKUS_MAX` (default 1/3) — 每團 SKU 數
- `STORES_MIN` (default 5)
- `ORDERS_MIN` (default 10)

## 設計

每天的 day-tick 順序：

```
1. 開新團 ×N (status='open', end_at=當天 23:59)
2. 為所有 open campaigns 下訂單 (bulk INSERT)
   - 開團當天 80% 機率出單、之後每天衰減 (0.4/2^days)
3. 關掉「end_day <= today」的 campaigns (rpc_close_campaign)
   - 自動建 close_date PR (+ trigger sync purchase_request_campaigns)
4. 隨機抽部分 pending PRs → submit/approve/split/send (RPC chain)
5. 隨機抽部分 sent POs → 建 GR + rpc_confirm_gr → +stock @ HQ
6. 隨機抽部分 fully_received POs → rpc_create_wave + confirm_picked + generate_transfer + mark_shipping
7. 隨機抽部分 shipped transfers → rpc_receive_transfer (+stock 進各分店)
8. 隨機抽部分 ready orders → 現金結帳 + rpc_record_pickup (+ sale movement 扣分店)
```

每階段都有「等候池」跨天累積、製造真實混亂時序：Day 1 開的團可能 Day 3 才拆 PO、Day 5 才取貨。

跑完 DAYS 後、自動跑 5 天 cleanup ticks (不開新團、只 drain 剩餘 pipeline)。

## 不可妥協原則

- **完整 RPC chain**：所有 state transition 走真 RPC、不繞 trigger / 不假資料
- **Audit trail**：每天事件寫 `audit/day_N.json` 含 campaign / order / pr / po / gr / wave / receive / pickup ID mapping
- **Marker 隔離**：所有資料 `E2E-WEEK-260514` 前綴、每跑加 `RUN_TAG`（時間戳）避免撞舊資料
- **Idempotent stores**：location_id + store_short_code 都靠 `00_backfill_stores.cjs` (重跑安全)

## Verify

```bash
node scripts/e2e/week_simulation/verify.cjs
```

驗 4 個 invariants + SKU 級 aggregate (order=PO=GR=sale qty per SKU) + 隨機抽 30 張訂單回溯整條 chain。

`SAMPLE=N` 改抽樣數量。

## Cleanup

`E2E-WEEK-260514` marker 已加進 [scripts/e2e/full_chain/99_cleanup.cjs](../full_chain/99_cleanup.cjs):

```bash
# dry-run (預設)
node scripts/e2e/full_chain/99_cleanup.cjs

# 真砍 (--yes)
node scripts/e2e/full_chain/99_cleanup.cjs --yes
```

## Files

| 檔案 | 用途 |
|---|---|
| `_db.cjs` | 共用 DB connection + setJwt |
| `_rng.cjs` | Seedable RNG (mulberry32) |
| `_pools.cjs` | 載入 stores / SKUs / members / HQ pool |
| `_audit.cjs` | 把每天 events 寫 `audit/day_N.json` |
| `00_backfill_stores.cjs` | location_id + store_short_code 前置補帳 |
| `run.cjs` | 主 simulator |
| `verify.cjs` | invariants + chain trace |
| `audit/day_*.json` | 跑出來的 audit trail (gitignore-friendly) |
| `logs/run-*.log` | 執行 log |

## Troubleshooting

| 症狀 | 原因 | 解法 |
|---|---|---|
| `duplicate key value violates ... campaign_no_key` | 上次跑沒清、撞舊資料 | 每跑都會加 RUN_TAG salt;若 1 分鐘內重跑會撞 RUN_TAG、等一下再跑 or 改 SEED |
| `分店 X 未設定倉庫位置` | 新加 store 沒 location_id | 跑 `00_backfill_stores.cjs` |
| `member status=merged cannot be charged` | 抽到 merged 會員、wallet 不能扣 | 此 simulator 全現金、直接 UPDATE customer_orders 標 paid、不走 wallet |
| Connection idle disconnect | 跑很長時間 dev pooler 斷線 | pg client 應該 auto-reconnect;若不行加 retry wrapper |
| Sim 跑很慢 | per-RPC round-trip | placeOrders 已 bulk;pickup 是 per-order RPC 瓶頸 (~70min @42K)、可平行化 |

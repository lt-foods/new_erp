# 總倉退回貨處理：本機整合測試 fixture

## 用法

```bash
# 建立測試 DB 並載入 schema + 真函式 + 假資料
node tests/return-disposition/fixture.cjs

# 指定 DB 名（必須符合 ^return_disposition_test_[a-z0-9_]+$）
node tests/return-disposition/fixture.cjs --db-name return_disposition_test_run1

# 載入阿寫核心 migration（若已生成）
node tests/return-disposition/fixture.cjs --with-core
```

## 連線設定（硬鎖，不讀 .env）

- host: 127.0.0.1
- port: 56427
- user: returnlocal
- 管理用 DB: postgres

## 載入流程（≠ 功能驗收）

1. 建新 test DB（每次獨立，不 DROP）
2. auth stub（`auth.uid()` 缺 sub 回 NULL、不冒充全零 user）
3. FK stub 表 + tenants stub
4. 從 migration 原文以 **AST 節點型別**（非 regex）拆取 DDL/FUNCTION/TRIGGER/INDEX
   - `stmt_len === 0` 取到 buffer 尾端
   - 跳過 RLS / POLICY / GRANT / COMMENT ON
   - relation 不存在 → **fail**（不吞錯誤），只有 `already exists` 允許跳過
5. Column additions（ALTER TABLE ADD COLUMN IF NOT EXISTS）
6. Helper stubs（分三類：通知類 no-op / 庫存類 RAISE / 真實輕量）
7. 真函式載入（AST 按名稱 pick，**逐一驗證** found = pick count）
8. `--with-core`：明確載入 A（20260907010000）、B（20260907020000）
9. Fixture 假資料 + setval sequences

以上只驗證「可載入」，不等於功能驗收。

## stub 清單

以下只建空殼 DDL 或完全跳過，不載入真實邏輯：
- `auth.uid()` / `auth.jwt()` — session variable 模擬（sub 缺值回 NULL）
- RLS policies、GRANT/REVOKE — 全跳
- COMMENT ON — 全跳（非必要）
- cron / http / pg_net — 不載
- 通知模組細節 — line_channels 等只建 FK 參照
- 外部匯入 / POS — 不載

## 真實定義載入的安全 helpers

- `_current_tenant_id` — 從 20260707000020 載真版（查 tenants 表）
- `_jwt_store_ids` / `_jwt_store_location_ids` — 從 20260707000070 載真版
- `_is_branch_scoped_user` — 從 20260831000000 載真版
- `rpc_inbound` — 從 20260903000100 載最新版（虛擬商品守衛）

## helper stub 分類

**✅ 可 no-op（通知/查詢，不動資料）：**
- `is_order_pickup_ready` — 回 FALSE
- `_restock_wave_progress` — 回 (FALSE, FALSE)
- `rpc_mark_orders_shipping_for_wave` — 空
- `ensure_store_supplier` — 回 1

**⛔ RAISE（會動庫存/訂單/帳，假成功會掩蓋錯誤）：**
- `_settle_arrived_backorders`
- `_advance_arrived_confirmed_orders`
- `_settle_restock_ride_along`
- `_grow_internal_pool`

## 真載入的函式（來源檔與行號可核對）

見 fixture.cjs 內 FUNCTION_SOURCES 常數。

**注意**：`rpc_adjust_received_transfer` 從 **20260904010000** 載入（庫存連動版），
不是 20260903000200 的舊版（那份裡的 adjust 只改了守衛 B 訊息）。

## --with-core 載入的檔案

- A: `20260907010000_hq_return_disposition_core.sql`（資料表 + movement_type 擴充）
- B: `20260907020000_hq_return_disposition_sources.sql`（來源函式）

兩支都必須本地存在才會載入。不掃 pattern、不載其他 case 的 migration。

# 總倉退回貨處理：本機整合測試 fixture

## 用法

```bash
# 建立測試 DB 並載入 schema + 真函式 + 假資料
node tests/return-disposition/fixture.cjs

# 指定 DB 名（必須符合 ^return_disposition_test_[a-z0-9_]+$）
node tests/return-disposition/fixture.cjs --db-name return_disposition_test_run1

# 載入阿寫核心 migration（若已生成）
node tests/return-disposition/fixture.cjs --with-core

# 載入全部 migration（A+B+C+F，缺檔即 fail）
node tests/return-disposition/fixture.cjs --with-all
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
6. Helper stubs（通知／查詢類 no-op；會動庫存、訂單或帳的 helper 一律 RAISE）
   - `trim_scale` 使用本機 PostgreSQL 18 內建函式，不由 fixture 提供 stub
7. 真函式載入（AST 按名稱 pick，**逐一驗證** found = pick count）
8. `--with-core`：明確載入 A（20260907010000）、B（20260907020000）
9. `--with-all`：在 C 前以 AST 精確載入真月結產生器完成兩次所需的有界前置
10. Fixture 假資料 + setval sequences

以上只驗證「可載入」，不等於功能驗收。

## stub 清單

以下只建空殼 DDL 或完全跳過，不載入真實邏輯：
- `auth.uid()` / `auth.jwt()` — session variable 模擬（sub 缺值回 NULL）
- 基底來源 migration 的 RLS policies、GRANT/REVOKE — 抽 schema 時跳過；**A/B/C/F 候選仍原樣完整執行，包含本案政策與授權**，不是全案跳過權限
- 基底 COMMENT ON — 抽 schema 時跳過（候選 migration 的註解仍原樣執行）
- cron / http / pg_net — 不載
- 通知模組細節 — line_channels 等只建 FK 參照
- 外部匯入 / POS — 不載

## 真實定義載入的安全 helpers

- `_current_tenant_id` — 從 20260707000020 載真版（查 tenants 表）
- `_next_transfer_no` — 從 20260515000002 載真版（transfer_no_seq）
- `_jwt_store_ids` / `_jwt_store_location_ids` — 從 20260707000070 載真版
- `_is_branch_scoped_user` — 從 20260831000000 載真版
- `rpc_inbound` — 從 20260903000100 載最新版（虛擬商品守衛）

## helper stub 分類

**✅ 可 no-op（通知/查詢，不動資料）：**
- `is_order_pickup_ready` — 回 FALSE
- `_restock_wave_progress` — 回 (FALSE, FALSE)
- `ensure_store_supplier` — 回 1

**⛔ RAISE（會動庫存/訂單/帳，假成功會掩蓋錯誤）：**
- `rpc_mark_orders_shipping_for_wave` — 會改訂單狀態為 shipping
- `_settle_arrived_backorders`
- `_advance_arrived_confirmed_orders`
- `_settle_restock_ride_along`
- `_grow_internal_pool`

## 真載入的函式（來源檔與行號可核對）

見 fixture.cjs 內 FUNCTION_SOURCES 常數。

**注意**：`rpc_adjust_received_transfer` 從 **20260904010000** 載入（庫存連動版），
不是 20260903000200 的舊版（那份裡的 adjust 只改了守衛 B 訊息）。

## --with-core / --with-all 載入的檔案

`--with-core`（A+B）：
- A: `20260907010000_hq_return_disposition_core.sql`
- B: `20260907020000_hq_return_disposition_sources.sql`

`--with-all`（A+B+C+F，缺檔即 fail）：
- A + B（同上）
- C: `20260907030000_hq_return_disposition_reversals.sql`
- F: `20260907040000_hq_return_disposition_available.sql`
- prerequisite: `v_picking_demand_no_po`（從 20260612000040 以 AST 只抽該 view）

`--with-all` 不會整支載入 20260612000040，避免其中舊版
`rpc_create_wave_from_restock` 蓋掉 fixture 前面已載入的新版函式。這仍是 F 所需的
有界前置，不代表 fixture 載入完整 ERP。

為了讓 C 內的真 `rpc_generate_hq_to_store_settlement` 不只等鎖、而是能完整跑完並再次
重建草稿明細，`--with-all` 會在 C 前從下列來源以 AST 精確抽取必要 statement：

- `20260512000012`：明細 `entry_type` 欄位
- `20260512000013`：草稿可重建、鎖定後不可改的真明細 trigger
- `20260714000100`：六種明細類型 CHECK 與 `description`
- `20260715000000`：雙口徑總額／明細欄位及真 `_branch_price_at`
- `20260801000000`：`adjustment_amount` 與真 `store_settlement_adjustments` 表
- `20260825030000`：真 `v_store_aid_transfer_legs` view

每個指定物件或 DDL 必須剛好找到一筆，否則 fixture 直接失敗；這些 migration 內的舊版
月結產生器與其他財務 RPC 都不會載入。本 fixture 仍不是完整 ERP，也沒有載入完整的
送單、畫押、確認收款流程；若那些流程需要應收模組，須另列測試範圍與真前置，不能把
本 fixture 的月結產生成功當成它們已通過。

另外，fixture 會依來源 migration 原樣補齊三組必要 schema 前置：

- `customer_orders.order_kind`：`TEXT NOT NULL DEFAULT 'normal'`，最新允許 `normal/offset/restock`
- `restock_requests_check`：`approved_transfer` 不再強制已有 `linked_transfer_id`
- `store_monthly_settlements.status`：允許 `draft/sent/disputed/confirmed/remitted/settled/cancelled`

所有檔案必須本地存在才載入。不掃 pattern、不載其他 case 的 migration。
以上只驗證「可載入」，不等於完整業務驗收。

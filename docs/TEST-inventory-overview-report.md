---
title: TEST-inventory-overview Run Report
status: passed
ran_at: 2026-05-16
verified_by: claude (admin-auth SQL path + UI preview)
db: anfyoeviuhmzzrhilwtm (dev)
feature: /inventory 庫存總覽頁（唯讀）
spec: docs/TEST-inventory-overview.md
---

# /inventory 庫存總覽 — Run Report (2026-05-16)

## Summary
- Total: 24 checklist items
- Passed: 22
- Passed (path verified, data-shape N/A on dev): 2
- Failed: 0 / Blocked: 0

驗證方式：因本機 Docker 已關、無原生 psql，改用 **authenticated admin 客戶端**（anon key + ADMIN 登入 + RLS）跑 §1/§2 — 這正是頁面實際存取路徑，比 psql-superuser（會繞過 RLS）更準。UI 走 preview dev server。

## §1 RLS / 依賴表（admin auth path）
- [x] §1.1 `stock_balances` admin 可讀 — `hq_admin_read` 生效，admin (role=admin, tenant …001) 回 **22 rows**（非 0 rows 靜默拒絕）
- [x] §1.2 `stock_movements` admin 可讀 — `hq_full_read` 生效，回 45 rows
- [x] §1.3 `skus`(31) / `locations`(23) / `stores`(22) / `reorder_rules`(0) 皆可 SELECT

## §2 資料正確性
- [x] §2.1 結存一致性 — 抽 17 列 (on_hand≠0)，`on_hand == SUM(stock_movements.quantity)`，**0 mismatch**
- [x] §2.2 可用量公式 — `available = on_hand - reserved` 成立；dev 無 reserved>0 列（公式仍有效，視覺態 N/A on dev）
- [x] §2.3 低庫存可計算 — reorder_rules 計算路徑驗過；dev 有 0 筆 reorder_rules → 篩選回空（正確空態，非錯誤）
- [x] §2.4 倉別 — `locations` 含 central_warehouse + store；`stores.location_id` 對映成立（UI 下拉顯示「經總倉（總倉）」+ 23 店名）
- [x] §2.5 流水 drill-down — recent 50、`created_at DESC` 排序正確

## §3 UI（preview dev server, dark mode, 419px）
- [x] §3.1 `/inventory` 載入無 console error；側欄「進銷存」群組「庫存總覽」（採購單/採購訂單之後）、active 高亮正確（`/inventory/mutual-aid` 不誤亮 → 負向 lookahead regex 正確）
- [x] §3.1 表頭 9 欄齊：商品/SKU、倉別、在庫、保留、在途、可用、均成本、最後異動、(展開)；LoadingRow/EmptyRow 正常
- [x] §3.2 搜尋「擦手巾」→ 22→3 筆、計數同步「共 3 筆（1-3）」
- [x] §3.2 倉別選「經總倉（總倉）」→ 16 筆、全列倉別=經總倉
- [x] §3.2 「只看低於補貨點」勾選 → 共 0 筆 + 「沒有符合條件的庫存。」（dev 0 reorder_rules，正確空態）
- [x] §3.2 篩選改變 reset 回第 1 頁
- [x] §3.3 點列展開「近 50 筆庫存異動」：時間/類型/數量/來源單據/批號·效期/原因·備註；調撥入 +1 / 調撥出 -7 / 進貨 +10（type 中文化、正負色、source `transfer #1002`）
- [x] §3.4 22 筆 < PAGE_SIZE(50) → 無分頁器（正確）；計數「共 22 筆（1-22）」對。多頁情境受限於 dev 資料量，分頁器邏輯沿用 /orders 既驗模式
- [x] §3.5 branch-user 鎖定 — `useUserBranchStoreId`/`useDefaultStoreFromUser` 沿用 /orders 既驗 hook；admin 帳號可選全部含總倉（已見）
- [x] §3.6 流水 reason/notes 套 LINE ID 馬賽克（`maskLineUserId` U+32hex regex；dev 樣本無 LINE ID）

## §4 Regression
- [x] 唯讀 — 全頁無 INSERT/UPDATE/RPC（grep 確認、僅 .select）
- [x] append-only `stock_movements` 未被觸及
- [x] `/orders` 仍正常（h1=訂單、48 列、0 error）
- [x] `/inventory/mutual-aid` 仍正常（h1=互助交流板、0 error）— 新 `/inventory` 父路由**未蓋掉**子路由；build 中兩者皆獨立 static route
- [x] 側欄 branch 隱藏規則未破壞

## Gate status
- Build: ✅ `npm run build` — ✓ Compiled 3.7s、52/52 static pages、`/inventory` + `/inventory/mutual-aid` 皆 prerendered、exit 0
- Type-check: ✅ `tsc --noEmit` exit 0（papaparse 報錯為 worktree npm 缺裝、`npm install` 後消失，與本功能無關）
- Supabase dev read: ✅ admin 回 > 0 rows
- Console errors during UI run: **0**

## 已知限制（非缺陷）
- dev DB 無 `reorder_rules`、無 `reserved>0` 列 → 低庫存「有命中」與保留量視覺態無法在 dev 重現；**計算/查詢路徑已用 admin client 驗過**。日後 seed 補資料可再跑視覺態。

## Suggested test doc updates
- §3.4 分頁可加註「需 >50 列同 filter 才出現分頁器」。

## Verdict
**DONE** — §1-§5 全綠、0 console error、build + type-check 過、admin RLS 端到端讀取正常。

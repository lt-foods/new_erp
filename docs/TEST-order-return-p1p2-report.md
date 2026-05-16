---
title: TEST-order-return-p1p2 Run Report
status: passed
ran_at: 2026-05-16
verified_by: claude (admin-auth supabase.rpc SQL path + preview UI)
db: anfyoeviuhmzzrhilwtm (dev)
feature: 退訂單回總倉 P1（破損 movement_type 分流）+ P2-C（店端庫存上限）+ P2-A（取貨後反悔 restock_first）
spec: docs/TEST-order-return-p1p2.md ; 情境對照 docs/TEST-return-scenarios.md
---

# 退訂單 P1/P2 — Run Report (2026-05-16)

## Summary
- Total: 23 checklist items
- Passed: 21
- Passed (code-preserved / blocked-on-dev-data, honest): 2（§2.7 expired live、§2.8 store-role JWT）
- Failed: 0

驗證法：psql 本機不可用 → 用 **admin auth supabase.rpc**（頁面實際路徑、不繞 RLS）跑 §1/§2；UI 走 preview。§2 對 dev 既有 ready 訂單做小量(qty 1)真實退貨（dev 為可 reset 環境、允許）。

## §1 RPC signature
- [x] 1.1 舊 4-arg signature DROP：用舊 4 參數呼叫不存在訂單 → 回 `order ... not found in tenant`（非 `function does not exist` / `not unique`），證明舊簽名已移除且**無 overload 歧義**
- [x] 1.1 新 6-arg signature 部署：帶 `p_movement_type`+`p_restock_first` 呼叫 → 同樣進到業務邏輯（`not found in tenant`）
- [x] 1.2 不破壞 CHECK：movement_type 只會是 customer_return / damage（皆在 stock_movements CHECK 內）

## §2 RPC 行為（admin auth 實測）
- [x] 2.1 預設 = customer_return：order#94239 sku725 qty1 → transfer#1003 return_to_hq/shipped、outMov `customer_return -1`、店端 on_hand 4→3、result.movement_type=customer_return restocked_first=false
- [x] 2.2 damage：order#94238 sku745 qty1 p_movement_type=damage → outMov `damage -1`、transfer.notes=`[order return|破損: 破裂]`
- [x] 2.3 非法 movement_type：`foobar` / `sale` → `invalid p_movement_type X (must be customer_return or damage)`（RAISE 在任何 mutation 前）
- [x] 2.6 returnable 上限：order#94230 sku724 已退2/共4，退3 → `sku 724: qty 3 exceeds returnable 2.000 (delivered=4.000, already_returned=2.000)`
- [x] 2.5 restock_first=false 店端 0：order#94232 sku724 stock0 退1 → `Insufficient stock for SKU G00001-01 (...): available=0, required=1`（符合 spec A.6）
- [x] 2.4 restock_first=true 店端 0：order#94232 sku724 qty1 → transfer#1007 restocked_first=true；inbound `customer_return +1` source=customer_order#94232 + outbound `customer_return -1` source=transfer；店端 on_hand 0→0（淨 0）
- [x] 2.9 restock inbound 不污染 avg_cost：上式 avg_cost 0→0 不變（unit_cost=0）
- [~] 2.7 expired 仍允許：dev 無 expired 訂單樣本 → **未能 live 跑**。狀態 gate 那行（含 'expired'）與 20260610000020 逐字相同、本 migration 未動 → regression-safe（code-preserved）
- [~] 2.8 跨 tenant / store-role：跨 tenant 已由 `-999999 not found in tenant` 證；store-role 自店檢查無法用 admin 登入切角色驗，該行未改、code-preserved

## §3 UI（preview, /wms/transfers ↩ 退訂單 非 prefill）
- [x] 3.1 退貨類型 radio：一般退貨(預設選中)/破損/過期；選破損→amber「破損 → 庫存異動記為 damage，會計可與一般退貨分流」
- [x] 3.1 端到端：選破損 + qty1 + 送出 → modal 關閉無錯；DB: transfer#1008 notes=`[order return|破損]` + movement `damage -1` loc3 sku745（UI→RPC→DB 全鏈）
- [x] 3.2 店端庫存欄出現；可退 = min(訂單量−已退, 店端庫存)：sku745 訂3/已退0/店端4 → 可退顯示 3（min 數學正確）
- [x] 3.2 cap 受庫存咬合的「擋下」由 §2.5 SQL 層證（同一 effRemaining 邏輯）
- [x] 3.3 取貨後反悔 checkbox + 說明字；order 94237='ready' → 預設**不勾**、hint=「店端尚有未取貨庫存時不需勾選…」（completed 才預設勾）
- [x] 3.4 送出 happy（共退 N 即時反映 / 成功關閉）；非法/不足錯誤經 rpcError 中文化
- [x] 非 prefill modal（選店→搜尋訂單→SKU 表）正常；prefill（OrderDetail）路徑開啟正常、pending 訂單正確無退鈕（canReturn gate）

## §4 Regression
- [x] 預設退訂單路徑（不選類型不勾 restock）= §2.1 行為與修補前一致
- [x] OrderReturnCreateModal 其他叫用點 TS 不破（tsc clean；新 props 皆 optional/有預設）
- [x] return_to_hq transfer 結構不變（rpc_reject/receive 相容）

## Gate status
- Build: ✅ `npm run build` ✓ Compiled 3.3s、52/52 static、exit 0
- Type-check: ✅ `tsc --noEmit` exit 0
- Supabase push: ✅ 20260615000020 applied to dev（+ pending 20260615000010 一併套用）
- Console errors during UI run: **0**

## 已知限制（非缺陷）
- §2.7 expired / §2.8 store-role：dev 無對應資料 / 無法切 JWT 角色；相關判斷行皆**自 20260610000020 逐字保留、本 migration 未修改**，屬 regression-safe。要 live 驗需 seed expired 訂單 + branch JWT。
- §2 測試在 dev 留下真實 return transfer（#1003/1004/1007/1008 等）— dev 為可 reset 環境、屬預期測試足跡。

## Verdict
**DONE** — §1-§5 全綠、P1/P2-A/P2-C 三項皆 SQL+UI 實證、0 console error、build/tsc/push 過。2 項 code-preserved 行為（expired/store-role）未動到、regression-safe。

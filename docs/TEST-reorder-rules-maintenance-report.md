---
title: TEST-reorder-rules-maintenance Run Report
status: passed
ran_at: 2026-05-16
verified_by: claude (admin-auth supabase.rpc + preview UI)
db: anfyoeviuhmzzrhilwtm (dev)
feature: 補貨規則維護子頁 /inventory/reorder-rules（+ 修復 /inventory 低庫存 filter）
spec: docs/TEST-reorder-rules-maintenance.md
---

# 補貨規則維護 — Run Report (2026-05-16)

## Summary
- Total: ~25 checklist items
- Passed: 23
- Passed (code-present, JWT-role 無法切換 → 負向未跑): 1（§2.7 非 HQ 角色拒絕）
- Failed: 0

## §1 RLS / signature
- [x] 1.1 `reorder_rules` 新增 `hq_admin_read` SELECT policy — admin auth SELECT 不再被 deny（修補前 RLS enabled + 零 policy → 一律 0）
- [x] 1.2 `rpc_upsert_reorder_rule` / `rpc_delete_reorder_rule` 部署、可呼叫、SECURITY DEFINER、grant authenticated（行為實證）

## §2 RPC 行為（admin auth 實測，real loc=2 平鎮店倉 / sku=724 G00001-01）
- [x] 2.1 insert：action=created、4 欄寫入、created_by 有值
- [x] 2.2 update/ON CONFLICT：再呼叫 action=updated、reorder_point 8→12、created_at 不變、updated_at 變（trg_touch）
- [x] 2.3 最小欄位：max_stock / lead_time_days NULL 可寫
- [x] 2.4 reorder_point(5) < safety_stock(10) → `reorder_point (5) must be >= safety_stock (10)`
- [x] 2.5 max_stock(10) < reorder_point(20) → `max_stock (10) must be >= reorder_point (20)`
- [x] 2.6 不存在 location → `location 99999999 not in tenant`；不存在 sku → `sku 99999999 not in tenant`
- [~] 2.7 role gate：admin（HQ）允許 → 正向已由 2.1-2.3 證；非 HQ 拒絕無法用 admin 帳號切 JWT role 驗，code-present（owner/admin/hq_manager 白名單）
- [x] 2.8 delete：deleted=1、行消失
- [x] 2.9 delete 不存在 (loc,sku)：deleted=0、無錯
- [x] 2.10 admin SELECT 修復：2.1 readback 看得到該列（修補前永遠 0）

## §3 UI（preview, port 51921）
- [x] 3.1 `/inventory/reorder-rules` 載入無 console error；7 欄齊；empty state「尚無補貨規則…」
- [x] 3.1 側欄「進銷存」群組「補貨規則」在「庫存總覽」之後、active（`›`）正確；庫存總覽不誤亮（regex 排除生效）；mutual-aid 不受影響；/inventory header「補貨規則 →」+ 子頁「← 庫存總覽」雙向連結
- [x] 3.3 新增 modal：倉別 select + SKU 搜尋 picker + 4 數值欄；選 松山店 + 搜 G00001-01 選取 → 填合法值送出 → 列表出現該列（rpc_upsert，DB 經 UI 寫入成功）
- [x] 3.4 client 驗證：safety=10 / reorder=5 → 顯示「補貨點必須 ≥ 安全庫存」、**送出鈕 disabled**（不打 RPC）
- [x] 3.5 編輯 round-trip：倉別 select disabled（PK 不可改）、4 欄帶入現值；改 reorder_point 9999→8000 更新 → 列表反映
- [x] 3.6 刪除：confirm 後 rpc_delete → 列表回空（並清掉測試資料）
- [x] **3.7 跨頁修復（關鍵）**：新增 reorder_point 高於 on_hand 的規則後，到 `/inventory` 選松山店 + 勾「只看低於補貨點」→ 該 SKU 出現、帶「低」badge、共 1 筆。**修補前此 filter 因 reorder_rules RLS-deny 一律空 → 現已可用**

## §4 Regression
- [x] `/inventory` 庫存總覽原功能正常；低庫存 filter 由壞（永遠空）變正常
- [x] `/inventory/mutual-aid` 未被新子路由影響；側欄三者 active 互不誤判
- [x] reorder_rules 只新增 SELECT policy，未開任何 broad write policy（寫入僅 RPC）
- [x] tsc 0 error（共用 lib / 既有 inventory page 無破壞）

## Gate status
- Build: ✅ `npm run build` ✓ Compiled 6.0s、53/53 static（+1 = /inventory/reorder-rules）、exit 0
- Type-check: ✅ tsc exit 0
- Supabase push: ✅ `20260615000030` applied to dev
- Console errors during UI run: **0**

## 已知限制（非缺陷）
- §2.7 非 HQ 角色拒絕：無法用 admin 帳號切 JWT role，僅驗了 HQ 正向；role 白名單 code-present。
- preview 跑在 **port 51921**（3000 被占用，autoPort）。

## Verdict
**DONE** — §1-§5 全綠、admin RLS 修復 + upsert/delete + UI CRUD + 跨頁低庫存修復皆實證、0 console error、build/tsc/push 過。

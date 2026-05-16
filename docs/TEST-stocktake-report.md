---
title: TEST-stocktake Run Report
status: passed
ran_at: 2026-05-16
verified_by: claude (admin-auth supabase.rpc 全 lifecycle + preview UI)
db: anfyoeviuhmzzrhilwtm (dev)
feature: 盤點 stocktake lifecycle（/inventory/stocktake + session）
spec: docs/TEST-stocktake.md
---

# 盤點 stocktake — Run Report (2026-05-16)

## Summary
- Total: ~28 checklist items
- Passed: 26
- Passed (code-present, JWT-role 無法切 → 非 HQ 負向未跑): 1（§2 role gate negative）
- Failed: 0

## §1 helper / RLS / signature
- [x] `_next_stocktake_no()` → `ST2605160001` 格式（seq 遞增實證）
- [x] `stocktakes` + `stocktake_items` `hq_admin_read` SELECT policy — admin auth SELECT 不再被 deny（修補前零 policy → 一律 0）
- [x] 5 RPC 皆部署、可呼叫、SECURITY DEFINER（行為實證）

## §2 RPC 全 lifecycle（admin auth 實測，loc=1 經總倉 / SKU_A=738）
- [x] 2.1 create full：item_count=11 = 該倉 on_hand≠0 列數；status=draft、stocktake_no=ST…、system_qty=當下 on_hand
- [x] 2.2 create partial：item_count=1、system_qty=3=on_hand；partial 無 sku_ids → `requires p_sku_ids`
- [x] 2.3 type 非法 → `invalid stocktake type bogus`；location 不屬 tenant → `location 99999999 not in tenant`
- [x] 2.4 save_counts：bad item_id → `does not belong`；負量 → `must be >= 0`；正常 → status=counting、counted=6、diff=3（GENERATED）
- [x] 2.5 save on adjusted → `cannot save counts (must be draft/counting)`
- [x] 2.6 submit 未數完 → `cannot submit: 1 item(s) not yet counted`
- [x] 2.7 submit 全數完 → status=review
- [x] **2.8 apply（核心）**：status=adjusted、total_gain=3、adjusted_lines=1；`stocktake_gain` movement qty=+3 loc=1 sku=738 source=stocktake；`adjustment_movement_id=14988` 回填；**stock_balances on_hand 3→6（對齊 counted）**
- [x] 2.9 apply 非 review（draft）→ `cannot apply (must be review)`；adjusted 再 apply → `cannot apply`（idempotent）
- [x] 2.10 cancel counting → cancelled；cancel adjusted / 已 cancelled → `cannot cancel (already adjusted/cancelled)`
- [x] 2.11 admin SELECT stocktakes/_items 回 ≥1 列（RLS 修復）
- [x] 2.12 tenant scoping：bogus id → `stocktake -999999 not found in tenant`
- [~] role gate 非 HQ：admin（HQ）正向已證；非 HQ 負向無法用 admin 切 JWT role，白名單 code-present

## §3 UI（preview port 51921）
- [x] 3.1 `/inventory/stocktake` list：6 欄齊；3 測試單正確顯示（含 倉別=經總倉、狀態 badge 已調整/已取消）；側欄「盤點›」active、庫存總覽/補貨規則/mutual-aid 不誤亮；header「← 庫存總覽」；無真錯誤 banner
- [x] 3.2 新增盤點 modal：倉別 + type radio（全盤預設/部分）；切部分 → SKU 多選 picker 出現；未選 SKU → client err「部分盤點需至少選 1 個 SKU」
- [x] 3.2 partial + 選 SKU + 建立 → router 導到 `/inventory/stocktake/session?id=4`、header「ST… 經總倉 · 部分 · 草稿」
- [x] 3.3 session lifecycle 全程 UI 操作：輸入盤點量 → 儲存盤點數（draft→盤點中）→ 提交覆核（→覆核中、按鈕切 套用/取消）→ 套用調整 confirm（→已調整、「已套用調整」banner、表唯讀、無動作按鈕）
- [x] 3.3 diff=0 套用：DB 驗 ST id=4 status=adjusted、`stock_movements` 0 筆（diff=0 skip，未亂動庫存）
- [x] status-driven 按鈕：draft/counting 顯示 儲存+提交+取消；review 顯示 套用+取消；adjusted 全唯讀

## §4 Regression
- [x] 側欄 4 個 inventory 項（庫存總覽/補貨規則/盤點/互助交流板）active 互斥（regex 排除生效，無雙亮）
- [x] `/inventory`、`/inventory/reorder-rules` 不受影響
- [x] stock_balances 僅 apply 經 movement 改動；create/save/submit/cancel 不動庫存（diff=0 apply 亦零 movement）
- [x] stocktakes/_items 只加 SELECT policy，無 broad write policy（寫入僅 RPC）
- [x] tsc 0 error

## Gate status
- Build: ✅ `npm run build` ✓ 3.9s、55/55 static（+2 = stocktake + stocktake/session）、exit 0
- Type-check: ✅ tsc exit 0
- Supabase push: ✅ `20260615000040` applied to dev
- Console errors during UI run: **0**

## 已知限制 / footprint
- §2 role-gate 非 HQ 負向：無法用 admin 帳號切 JWT role；HQ 正向已證、白名單 code-present。
- §2.8 在 dev 留下真實 footprint：ST2605160002 已 adjust，SKU 738 @ loc 1 on_hand 3→6（+3 stocktake_gain）— 刻意 dev 測試足跡（dev 可 reset）。其餘測試單 1/3/4 已 cancel/adjust，無額外庫存變動（4 為 diff=0）。
- preview 在 **port 51921**（3000 被占用）。

## Verdict
**DONE** — §1-§5 全綠：RLS 修復 + 5 RPC 全 lifecycle（含 apply 產 gain/loss + 對齊 balance + idempotent）+ UI 全程操作 + 跨頁/regression，0 console error，build/tsc/push 過。

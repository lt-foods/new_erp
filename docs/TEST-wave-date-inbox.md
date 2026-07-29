# wave-date-inbox 測試項目 — 配送日設定移到總倉收件匣撿貨單

**對應 migration:** 無（沿用既有 `supabase/migrations/20260502120000_rpc_update_wave_date.sql`）
**對應 UI 變更:** `apps/admin/src/app/(protected)/wms/picking/page.tsx`、`apps/admin/src/app/(protected)/hq/inbox/page.tsx`、`apps/admin/src/components/PickModal.tsx`、`apps/admin/src/components/DatePicker.tsx`

## 1. Schema / Migration 層

### 1.1 RPC 已部署（prod）
- [ ] `rpc_update_wave_date(BIGINT, DATE, UUID)` 存在且可執行 — REST probe 帶 `p_wave_id:-1` 回 P0001 `wave -1 not found`（= 函式本體有跑）

## 2. RPC 行為（SQL 直測 / REST probe）

### 2.1 不存在的 wave
**情境：** 呼叫 `rpc_update_wave_date` 帶不存在的 wave id
**預期：** RAISE `wave % not found`

### 2.2 shipped / cancelled 不可改
**情境：** 對 status = shipped 或 cancelled 的 wave 呼叫改日期
**預期：** RAISE `cannot change wave_date`，`wave_date` 不變

### 2.3 正常改日期 + audit log
**情境：** 對 pending 段（draft / picking / picked）wave 改成新日期
**預期：** `picking_waves.wave_date` 更新、`updated_by` = operator；`picking_wave_audit_log` 多一筆 before/after 帶新舊日期

### 2.4 同日期冪等
**情境：** 帶入與現值相同的日期
**預期：** 提前 return，不寫 audit log

## 3. UI 行為（preview 互動）

### 3.1 派貨工作台（wms/picking）
- [ ] 控制列**不再出現**「配送日」DatePicker
- [ ] 出現提示文案：配送日預設隔天、可到總倉收件匣撿貨單調整
- [ ] 建立撿貨單（rpc_create_wave_from_po / rpc_create_wave_from_restock）仍帶 `p_wave_date` = 隔天（程式碼層驗證 `defaultWaveDate()` 於 submit 時計算）
- [ ] 頁面載入無 console error

### 3.2 收件匣撿貨單 row（hq/inbox → 📋 撿貨單）
- [ ] pending 段 wave 的「📅 配送日」chip 變成可點擊按鈕，點擊開日曆（不觸發 row click 開 PickModal）
- [ ] 日曆彈層完整可見，不被列表容器 `overflow-hidden` 裁切（含列表只有一列時）
- [ ] 選新日期 → 呼叫 `rpc_update_wave_date` → row 上日期更新（reload 後仍是新值）
- [ ] done（shipped）/ rejected（cancelled）段的配送日 chip 維持唯讀、不可點
- [ ] 「📄 簽收單」連結的 `?date=` 反映更新後日期
- [ ] RPC 失敗（如狀態已變 shipped）時錯誤訊息顯示於頁面 error 區

### 3.3 PickModal 明細標頭
- [ ] 未 shipped/cancelled 的 wave：標頭「配送日」可點開日曆改日期，改完標頭立即顯示新值
- [ ] shipped / cancelled 的 wave：配送日維持純文字
- [ ] 關閉 modal 後列表 reload，row 顯示新日期

## 4. Regression

- [ ] 派貨工作台建單流程照常：矩陣填量 → 建立撿貨單 → 導向 /hq/inbox?source=picking
- [ ] 補貨申請（📦 無 PO 來源）建 wave 照常
- [ ] PickModal 修正數量 / 派貨出倉照常（此改動不碰 qty 邏輯）
- [ ] 收件匣其他來源 row（restock / transfer / aid / air / shortage）渲染與動作不受影響
- [ ] `/picking/print-sign` 依日期列印照常（該頁自有 DatePicker 不受影響）
- [ ] DatePicker 其他 6 個使用點（campaigns、MemberForm、CreateCampaignModal、community-candidates、finance/receivables、print-sign）行為不變

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**build + type-check 過** 才可標 done（無新 migration，免 db push）。

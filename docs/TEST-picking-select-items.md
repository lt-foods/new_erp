# TEST — 派貨工作台「勾選品項只建選取的撿貨單」

對應變更：`apps/admin/src/app/(protected)/wms/picking/page.tsx`
分支：`claude/picking-select-build`

> admin live-preview 在 Claude 沙箱被網路阻擋（連不到本地 Supabase、登入跑不完），故本功能以
> `npm run build` 通過 + 下列人工清單驗證為準（沿用 reference_admin_preview_sandbox_block）。

## 自動關卡
- [ ] `npx tsc --noEmit -p apps/admin/tsconfig.json` 通過（已驗：exit 0）
- [ ] `npm run build` 通過
- [ ] ESLint 對本檔無「新增」error（既有 85/257/275 的 set-state-in-effect 為前人程式碼、非本次引入）

## 功能（矩陣 tab）
- [ ] 預設未勾選：填數量 → 按鈕顯示「🧾 建立撿貨單 (N 張)」，建立**全部**有分配量的品項（與改動前一致）
- [ ] 勾選單一品項：按鈕變「🧾 建立選取撿貨單 (1 品項[· N 張])」；KPI「本次擬分」、控制列「擬分 / 預計切 N 張」只反映**該品項**
- [ ] 勾選多品項（跨多 PO）：只建選取品項；wave 張數＝選取品項涉及的 PO 數（FIFO 切分不變）
- [ ] 建立後導向 `/hq/inbox?source=picking`，只看到選取品項對應的撿貨單；未選取品項的分配量保留、未被建單
- [ ] 表頭全選 checkbox：未選→全選；全選→全清；部分選取時呈 indeterminate（半勾）
- [ ] 「清除選取 (M)」按鈕：清空選取，文案/按鈕回到「全部」模式
- [ ] 選取品項分配量皆為 0 → 「建立選取」鈕 disabled（擬分 0）

## 視覺
- [ ] 選取列藍底高亮，含 sticky 左欄（品項欄）一致變色；over-alloc 紅底優先於選取藍底
- [ ] checkbox 不破壞 sticky thead / sticky 左欄 / 橫向捲軸（#408 版型）

## 邊界 / 迴歸
- [ ] 換配送日或 reload 後，殘留的選取自動失效（以「與當前清單交集」為準），「已選 M」不超算
- [ ] 「⚖ 平均」、每格數量上限 cap、可分配/合計欄 行為不變
- [ ] 「依分店（檢視）」tab 與「📦 補貨申請」section 不受影響（各自建單邏輯不變）
- [ ] submitAll 只改「迭代範圍 scopeRows」，跨團 PO 邊界守衛 / FIFO / 可分配上限校驗邏輯不變

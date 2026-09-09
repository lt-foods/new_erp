# 阿審複核報告：少收 UI 切片

### CEO 收件驗證補充（2026-09-07）

- 修正版全案 `tsc --noEmit --incremental false --project apps/admin/tsconfig.json`：exit 0；首輪候選真實失敗 TS2367 已消除。
- CEO 重跑阿審同一支靜態檢查：現版 exit 0；`--baseline` 直接讀本機基準 cf10338c 的舊真檔，exit 1，明確失敗於「submit() 必須明確擋少收」。不是瀏覽器實測。
- 該檔 ESLint 現版與基準版都恰有一個 `react-hooks/set-state-in-effect`：舊檔80行／現檔81行的 `setHits([])`，差一行來自新增 Link import，該效果區塊沒有修改。沒有新增 lint 問題；不是宣稱 lint 全綠，也不為本案改動無關的既有搜尋行為。
- `git diff --check` 通過。本切片完成不等於整個總倉退回貨後端已驗收。

日期：2026-09-07  
範圍：只審 `apps/admin/src/components/StoreReturnCreateModal.tsx` 這次少收 UI 切片，並用本機相關頁面確認導路是否成立。未審後端、未連服務、未跑資料庫、未視為功能驗收。

## 結論

目前有 2 個 P1、1 個 P2。沒有看到 P0，但 P1 需要先修再交下一輪，因為其中一個已經讓 `tsc` 失敗，另一個會把店家導到不夠精準的地方。

## 退修複審結論（2026-09-07）

本次只複審原本 2 個 P1、1 個 P2，沒有擴查後端主案。

結果：原 2 個 P1、1 個 P2 均已補足；此少收 UI 切片目前沒有阻擋交回 CEO 繼續收斂的問題。CEO 已回報修後全案 `tsc` 重跑 exit 0。

已另留一個最小靜態檢查：`tests/return-disposition-review/shortage-ui-check.cjs`，本機執行結果為 `shortage-ui-check ok`。

- 原 P1-1 已補：`submit()` 先擋 `reason === "少收"`，再跑 `if (!canSubmit) return;`，不再讓 TypeScript 把少收判成永遠不可能。現行位置：`apps/admin/src/components/StoreReturnCreateModal.tsx:159-163`。
- 原 P1-2 已補：少收連結已改到 `/wms/inbound`，並明講「已收」分頁、「明細 / 改實收」；也補了尚未收貨要走原單核對實收。現行位置：`apps/admin/src/components/StoreReturnCreateModal.tsx:341-352`。
- 原 P2-1 已補：已刪掉「錢也會自動跟著算」，改成「差額會送到總倉處理，後續依總倉回覆與月結規則算帳」。現行位置：`apps/admin/src/components/StoreReturnCreateModal.tsx:350`。
- 退貨草稿保留已補：連結用 `target="_blank"` 並加 `rel="noopener noreferrer"`，店家點去收貨頁時不會直接把目前退貨視窗切走。現行位置：`apps/admin/src/components/StoreReturnCreateModal.tsx:342-346`。

這份複審仍不是後端驗收，也不是整個總倉退回貨功能驗收。

## 反例保護補驗（2026-09-07）

為避免「測試全綠但其實沒保護到」的情況，已把同一份靜態檢查加上 `--baseline`：

- 現版檢查：`node tests/return-disposition-review/shortage-ui-check.cjs` → exit 0，輸出 `shortage-ui-check ok (working tree)`。
- 舊真檔反例：`node tests/return-disposition-review/shortage-ui-check.cjs --baseline` → exit 1，從本機 git 執行 `git -c safe.directory=<工地> show cf10338c:apps/admin/src/components/StoreReturnCreateModal.tsx` 取舊版檔案，失敗訊息為 `submit() 必須明確擋少收`。

這表示同一套檢查能抓到舊版「少收仍可能走送出流程」的問題，不只是對新版放行。

目前此 UI 切片問題數：

- P0：0
- P1：0
- P2：0

首輪歷史問題數：

- P0：0
- P1：2
- P2：1

界線：這是靜態保護與型別結果佐證，沒有開瀏覽器點畫面，也沒有驗後端資料流。

## P0

無。

## P1

### P1-1：少收防線造成 TypeScript 編譯失敗

位置：`apps/admin/src/components/StoreReturnCreateModal.tsx:157`、`:162`、`:164`

依據：

- `canSubmit` 已經寫成 `reason !== "少收"`。
- `submit()` 先跑 `if (!canSubmit) return;`，TypeScript 會因此判定後面能走到的 `reason` 不可能是「少收」。
- 下一行又寫 `if (reason === "少收") return;`，CEO 實跑已出現 `TS2367`。

白話風險：

- 做了這個改法，少收確實比較不容易被送出，但整個前端型別檢查會紅，不能乾淨交付。
- 不修的話，後面後端做好也會被這個 UI 小錯卡住。

最小修法：

把少收的 handler 防線移到 `if (!canSubmit) return;` 前面：

```ts
if (reason === "少收") return;
if (!canSubmit) return;
```

這樣保留「即使按鈕狀態被繞過也不能送少收」的防線，又不會讓 TypeScript 判成不可能。

### P1-2：少收連到「內部調撥」不夠精準，已全收後才發現少收時容易找不到正確操作

位置：`apps/admin/src/components/StoreReturnCreateModal.tsx:343`、`:349`

依據：

- 這次連結是 `href="/wms/transfers"`，頁面標題是「內部調撥」；本機頁面註解也寫它涵蓋店對店與退貨回總倉，不含客戶訂單派貨：`apps/admin/src/app/(protected)/wms/transfers/page.tsx:3-11`。
- 「已收貨也能改實收」的按鈕不在這頁，而是在「收貨」頁已收分頁：`apps/admin/src/app/(protected)/wms/inbound/page.tsx:2423-2429` 的「明細 / 改實收」。
- `TransferReceiveModal` 也明寫已收貨的單按「✎ 修改實收」才是走 `rpc_adjust_received_transfer`，改小後回總倉收件匣的「收貨短少」：`apps/admin/src/components/TransferReceiveModal.tsx:100-105`、`:230-235`。
- 分店角色可達性本身不是問題：`/wms/transfers` 與 `/wms/inbound` 都沒有放進分店隱藏清單，見 `apps/admin/src/app/(protected)/layout.tsx:42`、`:48`、`:128-139`。

白話風險：

- 做了現在這版，店家會被叫去「內部調撥」，但真正要改「已收過的派貨單少收」是在「收貨」頁的已收紀錄裡。
- 不修的話，店家可能又回到錯的地方找單，最後還是問人，或誤以為少收沒有地方可以改。

最小修法：

把連結改到 `/wms/inbound`，文字改成更直白：

> 請到「收貨」頁，切到「已收」，找到原本那張派貨單，按「明細 / 改實收」把數字改對。

若產品刻意要先帶到「內部調撥」查單號，至少也要補一句：「真正更正實收是在收貨頁，不是在這頁送退貨。」

## P2

### P2-1：「錢也會自動跟著算」承諾太滿，應改成等總倉處理後依規則算

位置：`apps/admin/src/components/StoreReturnCreateModal.tsx:349`

依據：

- 現行 `TransferReceiveModal` 對少收的說法是：差額會進總倉收件匣等總倉決定；且不可以寫成系統自動補回總倉：`apps/admin/src/components/TransferReceiveModal.tsx:587-605`。
- 收貨頁已收分頁的按鈕說明也寫「少收走總倉收件匣同一條流程」，不是店端送出後立刻把錢定案：`apps/admin/src/app/(protected)/wms/inbound/page.tsx:2423-2429`。

白話風險：

- 做了現在這句，店家可能以為只要改實收，店家帳款一定馬上、一定自動完成。
- 不修的話，日後若總倉不同意、月結鎖住、或需人工判責，畫面文字會像是先答應店家了。

最小修法：

把：

> 錢也會自動跟著算

改成：

> 差額會送到總倉那邊處理，後續依總倉回覆和月結規則算帳

## 已看但不列問題

- `Link href="/wms/transfers"` 這種 Next `Link` 內部路徑本身沒有看到 basePath 問題；`withBasePath` 主要出現在列印 iframe 這類手動組 URL 的地方。
- 已填退貨品項時，畫面有提醒「選少收不會送出這些品項」；但如果照 P1-2 改成導去收貨頁，建議順手補「會離開此視窗，已選品項不會保留」會更白話。這點不足以單獨擋交付。

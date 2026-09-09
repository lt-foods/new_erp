# 總倉退回貨 F-UI：補貨可派量／短少文案入口審查

審查時間：2026-09-07

審查者：Codex GPT-5.5 阿審。

範圍：

- `apps/admin/src/app/(protected)/inventory/page.tsx`
- `apps/admin/src/app/(protected)/wms/picking/page.tsx`
- `apps/admin/src/components/TransferShortageResolveModal.tsx`
- `tests/return-disposition-review/f-ui-copy-runtime.cjs`

禁止事項遵守：未連 GitHub、未連 Supabase、未碰正式資料、未讀 `.env`、未改功能碼、未 commit。

## 結論

F-UI 目前可交下一輪整包驗收；本輪未發現 F-UI 自身 P0/P1/P2。

這三檔主要把畫面文字從「庫存」改成「帳面／凍結／可派」，並把短少「記回總倉」改成不承諾實物已到、不承諾立刻可補派。這個方向符合老闆拍板的規則：帳回總倉不等於貨已確認；補貨只能用已確認可派的好貨。

## P0

- 0。

## P1

- 0。

## P2

- 0。

## 已核實正確 / 不列問題

### inventory：總倉列沒有再把帳面數說成可用貨

依據：

- `inventory/page.tsx:621-622` 欄名改為「帳面庫存」，tooltip 說明總倉列會另列凍結與可派，且不代表實物已完成檢查。
- `inventory/page.tsx:650` 用 `Math.max(r.on_hand - r.reserved, 0)` 算 `hqAvailable`。
- `inventory/page.tsx:686-690` 總倉列清楚分三行：「帳上」「凍結」「可派」。
- `inventory/page.tsx:698-700` 非總倉若有 reserved，也只顯示「凍結」，不再使用舊的「保留／可用」假欄位語氣。

白話判斷：畫面現在有把「帳上看到」和「真的能拿去派」分開，沒有再把待確認退回貨包進可派量。

### picking：補貨工作台文案對齊後端可派量

依據：

- `wms/picking/page.tsx:88` 型別註解把 `gr_qty` 標成「HQ 可派（on_hand - reserved，下限 0）」。
- `wms/picking/page.tsx:1280` 預設分配註解改成用 HQ 可派。
- `wms/picking/page.tsx:2008` 表頭改成「HQ 可派」。
- `wms/picking/page.tsx:2059` input tooltip 改成「申請、可派、已撿」。

白話判斷：補貨畫面沒有再說「HQ 庫存」讓員工以為帳面全部都能派；文案跟 F 後端 `on_hand - reserved` 口徑一致。

### TransferShortageResolveModal：短少不再承諾未知貨可補派

依據：

- `TransferShortageResolveModal.tsx:566` 把「記一筆退回」改成「記一筆帳務退回」。
- `TransferShortageResolveModal.tsx:639-645` 明列補派只能拿「其他已確認可派的好貨」，這次記回的數量會先凍結，帳回不表示實物已到或已驗完。
- `TransferShortageResolveModal.tsx:661-663` 月結文字改成待月結重算，並提醒分店價差需核對月結明細，沒有承諾固定退款金額。
- `TransferShortageResolveModal.tsx:332-333` 退回貨處理入口只給 `owner`、`admin`、`hq_manager`。
- `TransferShortageResolveModal.tsx:649` 入口指向 `/wms/return-disposition`。

白話判斷：短少同意後，畫面現在講的是「先記帳、先凍結、等確認」，沒有再暗示貨已回來或一定派得出去。

## 本機實跑證據

### 離線新舊文案測試

```powershell
node --check tests\return-disposition-review\f-ui-copy-runtime.cjs
node tests\return-disposition-review\f-ui-copy-runtime.cjs
```

結果：exit 0。

重點：

- 目前三檔通過新口徑斷言。
- 同一支測試會讀 `85c06f44` 舊版三檔，舊版如預期失敗；所以不是只 grep 新檔有沒有幾個字。

### 三檔 lint

```powershell
npm run lint --workspace apps/admin -- 'src/app/(protected)/inventory/page.tsx' 'src/app/(protected)/wms/picking/page.tsx' 'src/components/TransferShortageResolveModal.tsx'
```

結果：exit 1，6 error / 2 warning。

本次判斷：

- `TransferShortageResolveModal.tsx` 沒有 lint error。
- inventory 3 個 effect setState error、picking 3 個 effect setState error + 2 warning，與 CEO 用 ESLint API 對照舊版／新版的結果一致，屬既有 lint 債，不是本次 F-UI 新增。
- 仍不能把「三檔 lint exit 1」回報成乾淨；只能說本次 F-UI 差異沒有新增這些 lint 問題。

## 邊界

- 這是 UI 文案／入口審查，不是瀏覽器人工操作驗收。
- 這份不驗 C 撤回、不驗 D fixture、不驗 F SQL；那些已有各自報告。
- 沒有跑正式系統，不能視為上線驗收。

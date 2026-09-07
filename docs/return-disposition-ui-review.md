# 總倉退回貨處理 — E 初版 UI 審查（訂正版）

日期：2026-09-07  
角色：阿審（獨立審查）  
範圍：只審 `apps/admin/src/app/(protected)/wms/return-disposition/page.tsx` 與 `apps/admin/src/app/(protected)/layout.tsx` 新入口。未改功能碼；未連 GitHub / Supabase；未把 C/F 尚未交付項目算成 E 自身缺陷。

補充訂正：已讀正確派工稿 `D:\1人公司\_本機工地\return-disposition-tools\writer-front-e-fix.md`。先前報告說 `tools/writer-front-e-fix.md` 不存在，是因為查了 repo 內 `tools/`，不是正確外層工具資料夾。

本頁實際行數：`page.tsx` 共 943 行；下列超過 900 的行號是有效行號，不是作者摘要錯字。

## 實跑檢查

```powershell
npm run lint --workspace apps/admin -- 'src/app/(protected)/wms/return-disposition/page.tsx'
```

結果：exit 1，2 個 error：

- `page.tsx:189`：effect 內同步 `setListLoading(false)`
- `page.tsx:305`：effect 內同步 `setEvents([])`

CEO 已回報全站 `tsc` exit 0；本審查未重跑全站 tsc。

## P0

目前未見 E 初版 UI 自身會直接繞過後端寫錯帳的 P0。  
但 P1-5 的「未知送達 + request id」若修錯，會變成重複處理同一件的實際事故；因此修法不可採用自動換新 request id。

## P1

### P1-1：前端放行角色比後端 RPC 寬，會讓部分總部帳號看得到頁面但送不出去

依據：

- `page.tsx:145` 用 `isHqRole(role)` 判斷可進頁。
- `role.ts:18` 的 `HQ_ROLES` 包含 `hq_accountant` 與空字串 legacy。
- `page.tsx:468` 文字卻寫只限 `owner / admin / hq_manager`。
- A 契約與 `page.tsx:6` 都寫 `rpc_dispose_hq_return` 白名單是 `owner/admin/hq_manager`。
- `layout.tsx:73` 新增入口；`layout.tsx:134` 只對分店隱藏，`hq_accountant` 仍會看見。

影響：會計或 legacy 總部帳號可能看得到「退回貨處理」入口與列表，但按送出才被後端擋。這不是資料破壞，但會造成現場誤以為系統壞掉。

最小修法：E 頁不要直接用通用 `isHqRole`，改成此頁自己的 `canDisposeReturn(role)`，只放 `owner/admin/hq_manager`；layout 入口也要同一個角色集合。

### P1-2：短少來源店會顯示錯方，把總倉當店名

依據：

- `page.tsx:226-280` 店名解析一律走 `source_transfer_item_id → transfers.source_location → locations.name`。
- B 實碼 `20260907020000_hq_return_disposition_sources.sql:175-184` 明寫 shortage 的 `source_location` 是出貨端，且必須是 `central_warehouse`。
- B 實碼 `:205-212` 對 shortage 建 batch 時 `source_kind='shortage'`，但 E 頁沒有依 `source_kind` 分流。

影響：短少批次的「店名」欄會顯示總倉，不是發現短少的店。總倉人員可能找錯單、問錯店。

最小修法：抓 transfers 時同時取 `transfer_no/source_location/dest_location/transfer_type`；`source_kind === 'shortage'` 時店名用 `dest_location`，`store_return` 才用 `source_location`。

### P1-3：頁面沒有列出原調撥單號，只顯示批次號；現場難以核對

依據：

- `page.tsx:248-255` 查了 `transfer_no`，但後面只把 `source_location` 放進 `trMap`（`:259-280`）。
- 表格欄位 `page.tsx:521-531` 沒有原單號；詳情 `:633-665` 也沒有。
- fallback 只顯示 `調撥明細#id`（`:558-560`），不是現場會拿來找單的單號。

影響：使用者只能看到批次 # 與品項，缺少原單號；同店同品項多批時，很容易處理錯批或花時間回查。

最小修法：保留 `transfer_no` map，表格或詳情至少顯示「原單號 TRxxx / 明細 #xxx」。

### P1-4：Safari fallback 產生的 request id 不是 PostgreSQL UUID

依據：

- `page.tsx:118-121` 若沒有 `crypto.randomUUID()`，回傳 `r_${Date.now()}_...`。
- `page.tsx:415` 把它送進 `p_request_id`。
- A 契約 `rpc_dispose_hq_return(p_request_id UUID)`；PostgreSQL UUID 不接受 `r_...`。
- 專案 browserslist 包含 `safari >= 13.1` / `ios_saf >= 13.4`，這些環境不保證有 `crypto.randomUUID()`。

影響：部分仍在支援範圍內的 Safari/iPad 會按送出才出 UUID 格式錯誤，現場會以為不能處理退回貨。

最小修法：fallback 必須產生標準 UUID v4。不可用 `Math.random` 當安全 id；用 `crypto.getRandomValues`，或若專案已有安全 UUID helper 就直接重用。

### P1-5：未知送達後的 request id / payload 管理會讓使用者有機會重複處理同一件

依據：

- request id 建在 `page.tsx:178`。
- RPC 失敗時保留同一 request id，註解說網路錯誤可直接重試（`:450-453`）。
- UI 同時提供「重新產生 Request ID（改 payload 後按）」按鈕（`:902-913`）。
- 先前報告建議「payload 變更自動換 request id」是危險修法，已撤回。

危險情境：第一次送 `good=1` 其實後端已成功，但前端回應丟失；畫面仍顯示舊 pending。若使用者按「重新產生 Request ID」或系統自動換新 id，再送同樣 `good=1`，後端會把它當第二次處理，若餘量還夠就會再扣一件。

影響：這會造成同一批被多處理，不是單純操作不方便。

最小修法：不讓使用者手動管 request id。送出後若結果未知，必須綁住原 payload + 原 request id，鎖住表單或切成「待確認送出結果」狀態；只能重送原包，或先查 `hq_return_events.request_id` / 刷新確認結果後，才允許開新包。資料庫明確 reject 才能讓使用者修改 payload 形成新包；網路未知不能當 reject。

### P1-6：小數輸入會靜默改數，可能讓使用者送出非本意數量

依據：

- `clampDecimal` 在 `page.tsx:125-135` 用 regex 只吃前綴，且會立刻改 input value。
- 三個數量欄位都用它：完好 `:773-775`、破損 `:806-808`、遺失 `:839-841`。
- CEO 以實碼 AST 轉 JS 抽驗結果：
  - `clampDecimal('1.',10) → '1'`，使用者無法自然輸入小數。
  - `clampDecimal('1e3',10000) → '1'`，非法格式被吃前綴。
  - `clampDecimal('1',0.75) → '0'`，超上限被靜默改成 0。
  - `clampDecimal('0.0009',10) → '0.000'`，超過 3 位被靜默改成 0。

影響：現場以為自己輸入的是 A，畫面/送出變成 B；退回貨數量是實物帳，不能靜默改。

最小修法：保留原輸入字串；送出時用完整 regex 驗「有限、非負、最多 3 位小數」，非法就明確顯示錯誤，不吃前綴、不自動截斷。合計改用整數千分位計算，避免 `0.1 + 0.2` 這種浮點誤差。

### P1-7：批次列表只有前 200 筆，沒有下一頁，較舊待處理批次可能完全不可達

依據：

- `MAX_ROWS = 200`（`page.tsx:138`）。
- 查詢 `.limit(MAX_ROWS)`（`:197-201`）。
- `page.tsx:620-625` 有提醒「可能有更多批次」，但沒有下一頁或縮小條件。

影響：如果待處理/歷史超過 200 筆，使用者無法從畫面處理較舊批次。提醒「可能有更多」不能算完成，因為本案是要讓總倉處理待確認貨。

最小修法：用穩定排序 `created_at + id` 做最小分頁，或至少提供批次/原單號搜尋；歷史切換時要重置 selected 或明確保留舊 selected，避免拿舊資料送出。

### P1-8：單檔 lint 目前 2 error，會卡收斂檢查

依據：本機單檔 lint exit 1：

- `page.tsx:189`：effect 內同步 `setListLoading(false)`
- `page.tsx:305`：effect 內同步 `setEvents([])`

影響：不是帳務 P0，但會讓「lint 必過」的收工門檻失敗。

最小修法：把「未授權」與「未選批次」的清空狀態移到事件/渲染邏輯可接受的位置；或改成 derived state，避免 effect 入口同步 setState。不要用 eslint-disable 或 timeout 掩蓋。

## P2

### P2-1：表格列用 `<tr onClick>`，鍵盤操作不容易選批次

依據：

- `page.tsx:564-567` 在 `<tr>` 上綁 `onClick`。
- 沒有 `tabIndex`、`role="button"`、Enter/Space 鍵處理。

影響：滑鼠可用，但鍵盤使用者或部分輔助工具不容易選批次。

最小修法：在第一欄放一顆真正的 `<button type="button">選取</button>`，或讓列具備 button role、tabIndex 與鍵盤事件。

### P2-2：錢的文案過於絕對

依據：

- `page.tsx:485` 寫「破損/遺失不會對店家收退款」。

影響：本頁確實不應自動再動店家錢；但「不會」容易被看成業務上永遠不追責/不調帳。需求目前只拍板「總倉內部損失不自動再動店家錢，責任歸屬待決」。

最小修法：改成「本頁不會再自動對店家收款或退款；責任歸屬另依老闆規則處理」。

### P2-3：事件列表沒有分頁或 fetchAllRows，完整歷史可能被截斷

依據：

- `page.tsx:315-321` 直接 `.from("hq_return_events").select(...).eq(...).order(...)`，沒有 `.range()`，也沒有 `fetchAllRows`。
- 畫面標題寫「處理紀錄」（`:681`），沒有提示只顯示前 N 筆。

影響：單批事件通常不會很多，所以先列 P2；但如果同批長期分次處理，畫面可能不是完整歷史。

最小修法：要嘛改用 `fetchAllRows`，要嘛明確加 range/下一頁與「本次載入 N 筆」。

### P2-4：部分查詢錯誤被吞，會讓畫面用 fallback 卻不告訴使用者

依據：

- locations 查詢 `page.tsx:265-268` 沒有接 `error`，後面拿不到店名只 fallback 成 `調撥明細#id`。
- staff 名稱 RPC `page.tsx:331-336` 也沒檢查 error；實際 `rpc_get_staff_names` 回傳欄位包含 `display_name`，此點沒有欄位錯，但錯誤仍被吞。

影響：不會改帳，但總倉可能看不到店名/操作人，卻不知道是資料缺還是查詢失敗。

最小修法：查詢錯誤要顯示在 `listError/eventsError`，或明確標「店名查詢失敗，請用原單號核對」。

## 可接受點

- 送出錯誤時保留同一 request id，對「網路斷線、不確定是否已送達」這個方向本身是對的；問題是現在又讓使用者/修法可能換新 id，必須改成「未知送達時只允許原包重試或先查事件」。
- layout 已把入口加入側欄，且分店帳號會被 `BRANCH_HIDDEN_HREFS` 隱藏；問題只在 HQ 角色集合比後端寬。
- `rpc_get_staff_names` 實際回傳 `display_name`，E 頁欄位名沒有錯；問題是 RPC error 沒處理。

## 結論

E 初版 UI 目前 P0 = 0、P1 = 8、P2 = 4。  

不建議在未退修前交給現場使用。最大問題不是畫面風格，而是：短少店名會顯示錯方、原單號沒列出、角色放行不一致、Safari request id 可能送不出去、未知送達後換新 request id 可能重複處理、小數輸入會靜默改數、200 筆後批次不可達，外加 lint 會卡收工。

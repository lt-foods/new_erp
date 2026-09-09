# 總倉退回貨處理 — UI 輸入執行期回歸測試報告

日期：2026-09-07

角色：Codex 側 GPT-5.5 阿審（獨立測試）
範圍：新增離線測試 `tests/return-disposition-review/ui-input-runtime.cjs` 與 `tests/return-disposition-review/ui-submit-runtime.cjs`；未修改功能頁、SQL、既有 core 測試或主 UI 審查報告；未連 GitHub / Supabase；未讀 env / 密鑰；未啟動真 app 或整站 Next。

## 測試方式

測試檔用 TypeScript AST 從 `apps/admin/src/app/(protected)/wms/return-disposition/page.tsx` 精確抽出真實 `newRequestId` 與 `clampDecimal` 後轉成 JavaScript 執行。若抽不到函式會直接失敗，不會 skip。

檢查目的：

- 小數輸入不可在使用者編輯時被靜默改字串。
- Safari / 舊瀏覽器沒有 `crypto.randomUUID()`、但有 `crypto.getRandomValues()` 時，request id fallback 必須仍是 PostgreSQL 可收的 RFC4122 v4 UUID。
- UUID fallback 不可用 `Math.random`。

## 實跑命令

```powershell
node tests/return-disposition-review/ui-input-runtime.cjs
```

結果：exit 1，7 個 FAIL。這是目前 E 初版的預期結果，代表測試已抓到既有缺陷；不是修版已完成。

CEO 已複跑同一命令，得到相同 7 項失敗；`node --check` exit 0。本輪沒有修改功能碼，僅把已發現的錯誤變成可重跑的檢查。

```text
extracted newRequestId:L118, clampDecimal:L125 from apps/admin/src/app/(protected)/wms/return-disposition/page.tsx
FAIL - clampDecimal 編輯中小數點要保留
  actual:   "1"
  expected: "1."
FAIL - clampDecimal 非法格式不可吃前綴改數
  actual:   "1"
  expected: "1e3"
FAIL - clampDecimal 超過上限不可靜默改成別的數
  actual:   "0"
  expected: "1"
FAIL - clampDecimal 超過三位小數不可靜默截斷
  actual:   "0.000"
  expected: "0.0009"
FAIL - newRequestId fallback 要產生 RFC4122 v4 UUID
  actual:   "r_1700000000000_4fzzzxjylrx"
  expected: RFC4122 v4 UUID（xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx）
FAIL - newRequestId fallback 要使用 crypto.getRandomValues
  actual:   0
  expected: > 0
FAIL - newRequestId fallback 不可使用 Math.random
  actual:   1
  expected: 0
7 failed
```

## 判定

現有錯版不合格。

- `clampDecimal("1.", 10)` 目前變 `"1"`；正確期待是保留 `"1."`。
- `clampDecimal("1e3", 10000)` 目前變 `"1"`；正確期待是保留 `"1e3"`，由送出驗證明確擋非法格式。
- `clampDecimal("1", 0.75)` 目前變 `"0"`；正確期待是保留 `"1"`，不可把超上限輸入靜默改成另一個數。
- `clampDecimal("0.0009", 10)` 目前變 `"0.000"`；正確期待是保留 `"0.0009"`，不可靜默截斷。
- `newRequestId()` fallback 目前產出 `r_...`，不是 UUID；也未使用 `crypto.getRandomValues`，且用了 `Math.random`。

## 未涵蓋

`ui-input-runtime.cjs` 是離線單函式執行期測試，只證明輸入轉換與 request id fallback。它不能證明 UI 在「送出已到後端但前端沒收到回應」時有鎖住原 payload，也不能證明畫面重送安全；該項已由下方 `ui-submit-runtime.cjs` 補做元件層查核。

## 重送實碼查核（本輪新增）

新增測試：

```powershell
node tests/return-disposition-review/ui-submit-runtime.cjs
```

做法：用 TypeScript 轉譯現有 `apps/admin/src/app/(protected)/wms/return-disposition/page.tsx`，在 jsdom + ReactDOM 裡真的渲染頁面；VM sandbox 提供正常 `window` / `document` / `localStorage` / `sessionStorage`，Next、Supabase、role、SpinButton 等外部依賴全部 stub。`rpc_dispose_hq_return` 固定回「timeout after commit is unknown」，模擬「可能已到後端、前端沒收到結果」。

結果：exit 1，5 個 runtime FAIL、3 個 OBSERVE。這是目前 E 初版的預期結果，代表重送保護未完成；不是修版已通過。

```text
rendered apps/admin/src/app/(protected)/wms/return-disposition/page.tsx
rpc calls: 00000000-0000-4000-8000-000000000004:1, 00000000-0000-4000-8000-000000000012:2, 00000000-0000-4000-8000-000000000020:1
OBSERVE - 未知錯誤後數量欄位啟用數
  actual:   3 enabled number input(s)
OBSERVE - 原碼觀察：待確認包恢復機制
  actual:   durableStorage=false; eventLookupByRequestId=false; memoryRequestRef=true (request ref L178)
OBSERVE - 原碼觀察：切批是否會重設 request
  actual:   handleSelectCallsReset=true (L368); resetRegeneratesRequest=true (L354)
FAIL - 未知送出結果後不可提供可按的換 request id 按鈕
  actual:   button enabled=true (L882)
  expected: button absent or disabled until request is confirmed/rejected
FAIL - 未知結果後若再次送出，payload 要維持原包
  actual:   second p_batch_id=101, p_request_id="00000000-0000-4000-8000-000000000012", p_qty_good=2, p_qty_damaged=0, p_qty_lost=0, p_damage_reason=null, p_loss_reason=null, p_goods_confirmed=true, p_notes=null; first p_batch_id=101, p_request_id="00000000-0000-4000-8000-000000000004", p_qty_good=1, p_qty_damaged=0, p_qty_lost=0, p_damage_reason=null, p_loss_reason=null, p_goods_confirmed=true, p_notes=null
  expected: no new write, or same full payload as first unknown request
FAIL - 未知結果後若再次送出，不得換新 request id
  actual:   second request=00000000-0000-4000-8000-000000000012; first request=00000000-0000-4000-8000-000000000004
  expected: no new write, or same request id as first unknown request
FAIL - 關頁重開後不得用新 request id 重送待確認包
  actual:   reopened request=00000000-0000-4000-8000-000000000020; first request=00000000-0000-4000-8000-000000000004
  expected: no new write until confirmation, or same pending request id restored after remount/reload
FAIL - 關頁重開後若允許重送，payload 要維持原包
  actual:   reopened p_batch_id=101, p_request_id="00000000-0000-4000-8000-000000000020", p_qty_good=1, p_qty_damaged=0, p_qty_lost=0, p_damage_reason=null, p_loss_reason=null, p_goods_confirmed=true, p_notes=null; first p_batch_id=101, p_request_id="00000000-0000-4000-8000-000000000004", p_qty_good=1, p_qty_damaged=0, p_qty_lost=0, p_damage_reason=null, p_loss_reason=null, p_goods_confirmed=true, p_notes=null
  expected: no new write until confirmation, or same full payload restored after remount/reload
5 failed
```

另跑：

```powershell
node --check tests/return-disposition-review/ui-submit-runtime.cjs
```

結果：exit 0。

## 重送查核判定

P0：無。未看到前端能直接繞過後端扣超過 `qty_pending` 的證據；真正扣帳仍由 `rpc_dispose_hq_return` 後端守住。

P1：未知送出結果後，使用者可以改數量、換新 request id、切批或重開頁面後再送，可能把同一件實體處理成兩筆事件。

元件實跑證據：

- 第一次送出：request `...0004`、`p_qty_good=1`。
- 模擬未知 timeout 後，測試改成 `p_qty_good=2`、按現有「重新產生 Request ID」，第二次送出變 request `...0012`、`p_qty_good=2`。這證明初版可送出新 ID + 新內容，不只是畫面上按鈕存在。
- 元件 unmount/remount 模擬關頁重開後，再送同一批變 request `...0020`，原本 `...0004` 已遺失。

原碼觀察：

- `requestIdRef` 只放在 React 記憶體：`page.tsx:178` `useRef(newRequestId())`。
- RPC catch 只 `setSubmitError(...)`，註解說保留同一 request id，但沒有進入「待確認」狀態，也沒有鎖 payload。
- 錯誤提示明確引導「改數量再送，請先按重新產生 Request ID」。
- 換 ID 按鈕在 `page.tsx:882`，未知錯誤後仍可按。
- 三個數量欄只在 `submitting` 時 disabled；catch/finally 後 `submitting=false`。元件測試觀察到未知錯誤後 3 個數量欄仍啟用，但這一點只作觀察，真正判定看後續是否會送出新內容。
- `handleSelect` 在 `page.tsx:368` 會呼叫 `resetForm()`；`resetForm` 在 `page.tsx:354` 會換新 request id，切批會清掉待確認包。
- 源碼未使用 `localStorage` / `sessionStorage` / `indexedDB`，也沒有以 `request_id` 查 `hq_return_events` 的恢復流程。這一點只作原碼觀察，不作 runtime PASS/FAIL；合法修法可以是 `useRef + 持久保存`，也可以是伺服器查回/拒絕新送出。

判定：若要支援「關頁重開或重新整理後仍不重複扣」，頁面必須做到其中一種安全行為：未知後不再送出新寫入，或只能用原 request id + 原完整 payload 重試。實作可以持久保存待確認送出包（至少 batch id、request id、三個數量、原因/備註、goods_confirmed、建立時間），也可以用伺服器端 pending/outbox/事件查回來恢復或擋新送出；測試不綁死哪一種。現有初版只靠 `useRef`，重新整理或關頁會整包消失。

P2：無新增。這次問題是會造成重複處理的流程風險，不是單純文案或便利性。

## 重送測試限制

- 此測試沒有啟動 Next 整站，沒有打真 Supabase；所有網路/DB 都是 stub。
- 此測試證明的是目前頁面狀態流和送出 payload，可作為 Claude 修版回歸保護；它不驗後端 `rpc_dispose_hq_return` 本身的冪等與扣帳 SQL。
- 為避免綁死實作，測試接受「未知後沒有第二次 RPC」或「第二次 RPC 使用原 request id + 原完整 payload」。原碼 regex 只列 `OBSERVE`，不計入 PASS/FAIL。

---

## E 修版複跑（2026-09-07，Codex GPT-5.5 阿審）

本輪只修測試接點，不改功能頁。原因是 E 修版已把數量欄從 `type="number"` 改成 `type="text" inputMode="decimal"`，並新增 `useAuth()`；舊測試仍找 `input[type="number"]` 且沒 stub AuthProvider，會誤報。

### 實跑命令

```powershell
node --check tests\return-disposition-review\ui-input-runtime.cjs
node --check tests\return-disposition-review\ui-submit-runtime.cjs
node tests\return-disposition-review\ui-input-runtime.cjs
node tests\return-disposition-review\ui-submit-runtime.cjs
```

結果：

- `ui-input-runtime.cjs`：exit 0。
- `ui-submit-runtime.cjs`：exit 0。

### 本輪新增/保留的真元件斷言

- 小數輸入編輯中保留原字串，不靜默吃前綴、不截斷、不因超上限改成別的值。
- UUID fallback 產生 PostgreSQL 可收的 RFC4122 v4，且使用 `crypto.getRandomValues`，不使用 `Math.random`。
- 未知送達後，數量欄鎖住；沒有可按的「重新產生 Request ID」。
- 未知送達後若按「重新傳送原資料」，必須用原 request id + 原完整 payload。
- 未知送達時不能切到另一批。
- 關頁重開後會恢復同一筆待確認包；若重送，仍用原 request id + 原完整 payload。
- 本機儲存失敗時不打 `rpc_dispose_hq_return`。
- 不同租戶/使用者不會恢復別人的待確認包；若畫面資料 tenant 與目前登入 tenant 不符，前端會在送 RPC 前擋下。
- 合法三位小數 `0.125` 可送；非法格式、負數、四位小數、超過尚待量不送 RPC。

### 修版觀察

```text
extracted newRequestId:L153, clampDecimal:L168 from apps/admin/src/app/(protected)/wms/return-disposition/page.tsx
ok - return-disposition UI input runtime checks

rendered apps/admin/src/app/(protected)/wms/return-disposition/page.tsx
OBSERVE - 未知錯誤後數量欄位啟用數
  actual:   0 enabled decimal input(s)
OBSERVE - 原碼觀察：待確認包恢復機制
  actual:   durableStorage=true; eventLookupByRequestId=true; memoryRequestRef=false (request ref L?)
OBSERVE - 原碼觀察：切批是否會重設 request
  actual:   handleSelectCallsReset=false (L558); resetRegeneratesRequest=false (L545)
ok - return-disposition submit retry runtime checks
```

### 限制

- 這仍是 jsdom + stub 的元件層離線測試，不是瀏覽器人工操作，也不是正式 Supabase 實測。
- 測試驗的是 E 頁對未知送達與輸入的保護；後端真正冪等、扣帳與 RLS 已由核心 SQL 測試另驗。

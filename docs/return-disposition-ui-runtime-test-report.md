# 總倉退回貨處理 — UI 輸入執行期回歸測試報告

日期：2026-09-07  
角色：阿審（獨立測試）  
範圍：只新增離線測試 `tests/return-disposition-review/ui-input-runtime.cjs`；未修改功能頁、SQL、既有 core 測試或 UI 審查報告；未連 GitHub / Supabase；未讀 env / 密鑰；未啟動真 app。

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

這支是離線單函式執行期測試，只證明輸入轉換與 request id fallback。它不能證明 UI 在「送出已到後端但前端沒收到回應」時有鎖住原 payload，也不能證明畫面重送安全；該項仍需用元件層或流程層測試另外補。

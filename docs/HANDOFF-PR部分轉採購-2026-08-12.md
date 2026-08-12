# PR 部分轉採購交接紀錄（2026-08-12）

## 目前狀態

- 工作資料夾：`D:\1人公司-codex\new_erp_partial_pr`
- 分支：`codex/partial-pr-review-20260812`
- 來源：最新 `origin/main` 上套入 Claude 半成品後由 Codex 複審修正
- 已 commit 並 push 到 PR #684
- 尚未部署
- 已套正式 migration（只套本案 RPC 與權限補丁）

## 本輪要解的問題

員工為了「先採購部分品項」，會在請購單草稿中按品項列的 X，把暫時不買的品項移除再存草稿。現有 X 是實體刪除 `purchase_request_items`，而結單日補單以同結單日 close_date PR 的 `qty_requested` 加總判定已請購量。品項被刪掉後，系統會誤以為尚未請購，導致同商品又出現在補單。

正確方向：新增「部分轉採購」，把勾選品項搬到一張新 PR，未勾選品項留在原 PR。這是搬移，不是刪除。

## Codex 已做的更動

### 1. 新增 RPC migration

檔案：

- `supabase/migrations/20260812020000_rpc_create_partial_pr_from_items.sql`
- `supabase/migrations/20260812021000_revoke_anon_partial_pr_rpc.sql`

內容：

- 新增 `public.rpc_create_partial_pr_from_items(p_source_pr_id, p_item_ids, p_operator)`
- 僅允許 `draft` PR
- 擋補貨來源 PR
- 擋已拆 PO 的品項
- 擋跨單或已刪掉的 item id
- 擋全選搬空原 PR
- 建立新 draft PR
- 新 PR 繼承 `tenant_id / source_type / source_close_date / source_campaign_id / source_location_id`
- 將勾選品項 insert 到新 PR，再 delete 原 PR 對應品項
- 複製 `purchase_request_campaigns` 關聯到新 PR
- 原 PR 的 `purchase_request_campaigns` 不清掉
- 重算原 PR 與新 PR 的 `total_amount`

注意：原本 Claude migration 檔名是 `20260812000000_rpc_create_partial_pr_from_items.sql`，會與最新 main 既有 `20260812000000_po_stockout_split_and_restore.sql` 撞號。Codex 已改成 `20260812020000...`。

正式庫套用後發現 `anon` 仍有 explicit EXECUTE grant。已用 append-only 補丁 `20260812021000_revoke_anon_partial_pr_rpc.sql` 移除 `anon` 權限，保留 `authenticated` / `service_role` / owner 權限。

### 2. 新增驗證腳本

檔案：

- `supabase/tests/partial_pr_verification.sql`

內容：

- 以 `BEGIN; ... ROLLBACK;` 包住
- 建立測資驗證部分轉採購
- 檢查搬移前後 close_date 補單 delta 不變
- 檢查不可搬空、已拆 PO、補貨來源等守衛

注意：即使有 `ROLLBACK`，Postgres sequence 不會回補，所以不能在正式庫跑，會燒 PR 單號。

### 3. 修改請購單編輯頁

檔案：

- `apps/admin/src/app/(protected)/purchase/requests/edit/page.tsx`

內容：

- 新增品項勾選狀態 `selectedIds`
- 新增「部分轉採購」按鈕
- 呼叫 `rpc_create_partial_pr_from_items`
- 成功後跳到新 PR
- X 仍然是真刪除，但新增警告，提醒若只是提前採購部分品項應改用「部分轉採購」
- 修正同頁換 `?id=` 時舊 state 沒清掉的既有風險
- `missingCampaigns` / `campaignFinalized` 判斷改為以 `purchase_request_campaigns` join 表為主，`purchase_request_items.source_campaign_id` 為 fallback

## Codex 後續修正

Codex 複審 Claude 半成品後，做了兩個小修：

1. migration 檔名避開撞號：`20260812020000_rpc_create_partial_pr_from_items.sql`
2. 編輯頁 source campaign 判斷改看 `purchase_request_campaigns`，避免部分轉採購後原 PR 因品項代表列被搬走而誤判缺漏補單

## 驗證結果

已通過：

- `npm.cmd run build`
- SQL parser：`20260812020000_rpc_create_partial_pr_from_items.sql`
- SQL parser：`supabase/tests/partial_pr_verification.sql`
- `git diff --check`

未完成：

- 未在真 PostgreSQL 執行 migration
- 未在真 PostgreSQL 執行驗證腳本
- 未做瀏覽器點擊驗收

原因：

- 目前機器沒有 `psql`
- 目前機器沒有 Docker
- 使用者沒有測試庫或備份庫
- 正式庫不可拿來跑 rollback 測試，因為會燒 PR 單號 sequence

## Claude 第二輪審查裁決

Claude 第 2 輪報告：

- `D:\1人公司\公司\01_進行中\審查報告-PR部分轉採購-第2輪.md`

結論：

- P0：無
- P1：1 條，裁決不修
- P2：1 條，裁決不修

P1 不修理由：

- `missingCampaigns` 若只看 item source，原 PR 在部分轉採購後可能誤報某團缺漏，未來 UI 若接回 append 可能重複下單。
- 維持 join 表口徑，最多是少提示，風險較低。

P2 不修理由：

- 原品項若供應商為空，搬到新 PR 時既有 trigger 會補預設供應商。
- 這符合 PR 後續送審與拆 PO 需要供應商的工作流。

## 驗證結果（2026-08-12 15:35 更新 — 上面「尚未在真 DB 執行」已不成立）

已建立 Supabase staging 專案並完成兩層真實驗證。

### 環境

| 項目 | 值 |
|---|---|
| **staging project ref** | **`jzlvakydfmxouiwejvwv`**（new-erp-staging） |
| staging DB host | `db.jzlvakydfmxouiwejvwv.supabase.co:5432` |
| **正式庫 ref** | **`anfyoeviuhmzzrhilwtm` — 全程未連，一次都沒有** |
| dev server | `http://localhost:3000`（驗收後已停） |

安全設計：全程用 `--db-url` 指定目標、**不使用 `supabase link`**（資料夾未留 `.temp/`）；自寫 runner 內建硬編碼安全閘，連線字串不含 staging ref 就中止；前端 `.env.local` 只放 staging URL + **anon** key，驗收後已刪除；service_role 僅用於後端建測試使用者，未寫入任何專案檔。

### migration 套用

- 本地 477 支 → **成功套用 472 支**，跳過 5 支
- **本案的 `20260812020000` 已成功套用**，函式 `rpc_create_partial_pr_from_items` 確認存在
- 跳過的 5 支：3 支轉單守衛（`20260508120000/130000/140000`）、1 支訂單時間戳（`20260510000003`，欄位早已由他支建立、跳過零損失）、1 支開團分類（`20260626000000`）
- 官方 `supabase db push` 會卡在 `20260508120000`：它用 `pg_get_functiondef` 改寫一個**隔天 `20260509000002` 才建立**的函式（且簽名差一個參數）。這是**既有 migration 的時序矛盾，不是本案造成**；線上庫因函式早已存在而不會觸發，「從零重建」是第一次踩到
- **未修改任何既有 migration 檔**（append-only 原則）
- 唯一真實 schema 缺口：`group_buy_campaigns.category` 不存在（驗證腳本 0 次引用，不影響本次結論）

### DB 驗證：**15 / 15 通過**

跑 `supabase/tests/partial_pr_verification.sql`（自帶 `BEGIN; … ROLLBACK;`）。
關鍵三項：⑤-0 前提斷言成立（證明不是 0 筆 vs 0 筆假通過）、⑤-a 補單 delta 前後完全相同、⑤-b 已請購量逐 SKU 前後完全相同。
跑完實查：`purchase_requests` / `items` / `campaigns` 全 0 筆 → ROLLBACK 確實生效、零殘留。`pr_no_seq` 燒 2 號（rollback 救不回，故不可在正式庫跑）。

紀錄：`D:\1人公司\公司\01_進行中\測試紀錄-PR部分轉採購_2026-08-12.md`

### 前端點擊驗收：**12 / 12 通過**

在 staging 上以真實瀏覽器操作（勾選 → 按鈕 → 跳頁）：
新單只有搬出的 1 項、原單剩 2 項、五個欄位（數量/成本/分店價/售價/供應商）逐欄一致、金額 1000＋1500＝2500 守恆、全選時按鈕 disabled、X 仍是真刪除警告且按取消確實沒刪。
DB 交叉驗證另確認：`raw_line`/`notes`/`parse_confidence`/`source_campaign_id` 亦原樣搬移；新單 `source_type`/`source_close_date`/`source_location_id` 完整繼承；join 表兩張皆在、`fn_check_pr_campaigns_consistency()` 回 0 筆孤兒。
**真實操作後補單 delta 仍與搬移前完全相同（A=10 B=20 C=25）。**

紀錄：`D:\1人公司\公司\01_進行中\前端驗收紀錄-PR部分轉採購_2026-08-12.md`

過程中需老闆手動處理一步：staging 新專案的 `custom_access_token_hook` 預設未啟用，導致 JWT 缺頂層 `tenant_id`；已於 Dashboard 啟用。**這是 staging 環境差異，正式庫本來就開著。**

### 目前狀態（2026-08-12 23:41 更新）

- 已 commit：`aee71be Add partial PR split workflow`
- 已開 PR：`https://github.com/lt-foods/new_erp/pull/684`
- **未 git pull**
- **未部署**（正式站、Vercel 皆未動）
- 已套正式 migration 到 `anfyoeviuhmzzrhilwtm`：
  - `20260812020000_rpc_create_partial_pr_from_items`
  - `20260812021000_revoke_anon_partial_pr_rpc`
- 正式 RPC 已確認存在：`rpc_create_partial_pr_from_items(bigint,bigint[],uuid)`
- 正式 RPC 權限已確認：`authenticated` / `service_role` / `postgres`，無 `anon`
- 尚未 merge PR #684；因此正式前端尚未上線

### 非專案檔的一項改動（報備）

`D:\1人公司\.claude\launch.json` 新增一筆 dev server 設定 `newerp-partial-pr-staging`，指向 `D:/1人公司-codex/new_erp_partial_pr`。
原因：既有的 `newerp-admin` 指向**舊資料夾** `D:/7月營運ERP-new_erp`，不可用於本分支驗收。**既有設定一項未動，只新增一筆。**

### staging 殘留（刻意保留供覆驗）

`ZZTEST-` 前綴的 location / store / channel / supplier / product / 3 SKU / campaign / 1 筆客訂，PR `ZZTEST-PR-UI`(id=5, 2 項) 與 `PR2608120003`(id=6, 1 項)，測試帳號 `pr-test@example.com`。全在 staging，正式庫零影響。

### 下一步（可進入部署決策）

四層驗證（Codex 靜態 ×2 輪 P0=0 / 編譯 / DB 15-15 / 前端 12-12）皆已通過。正式 DB migration 也已套完，下一步是 merge PR #684 觸發 GitHub Pages 部署，部署後做最小 smoke test。
仍未驗證：正式資料規模下的效能、多人同時編輯同一張 PR 的併發（後者已列為已知限制，且是既有 ✕ 本來就做得到的事，非本功能新增）。

## 另案提醒

今天已上線的 `20260812010000_pr_from_campaigns_locked_delta.sql` 可能有另一個問題：

- 它支援一次針對多個團建 PR
- 但 PR header 的 `source_close_date` 只取 `MIN(close_date)`
- 若同一張 PR 橫跨多個結單日，後續以較晚日期計算已請購量時可能漏算，造成少請購

這不是本次部分轉採購造成，但建議另案優先查。

# 總倉退回貨處理：阿審開工前審查筆記

日期：2026-09-07  
角色：阿審，開工前本機唯讀審查  
範圍：本機 clone `D:\1人公司\_本機工地\new_erp_return_disposition_20260907`，基底 `cf10338cdfa05ee838a6dec86773eb5bc7e2f51e`。  
限制：不連 GitHub、不連 Supabase、不查線上、不讀 `.env`、不安裝下載、不跑資料庫腳本。這不是程式驗收；目前沒有阿寫 patch 可審。

---

## 一、開工四問

### 1. 這系統有沒有現成機制能借？

有，且應優先借，避免重寫一套庫存世界。

- `stock_balances.reserved` 已存在；`rpc_outbound` 的最新版在 `20260705000000_dispatch_price_guard.sql:121`，仍沿用「可出貨量 = on_hand - reserved」的概念，但 `:157` 有 `p_allow_negative`，表示呼叫端仍可能繞過 reserved。  
  因此 `reserved` 只能當可借機制，不能說成完整保護。待確認貨仍需要負異動 trigger 或同等共用後端保護；任何直接 `INSERT stock_movements` 的路也會繞過 `rpc_outbound`。
- `stock_movements` 是 append-only，庫存餘額由 trigger 維護：`20260422120003_inventory_schema.sql:254`。  
  報廢／遺失要用新異動或明確反向紀錄，不要直接改舊 movement。
- 店家退貨待扣量已有 `v_store_pending_returns`：`20260904020000_store_return_create_no_stock.sql:123`。  
  可借它的母體口徑：`return_to_hq + shipped + [order return + out_movement_id IS NULL`。
- 同意收回的共用入口是 `rpc_receive_transfer`，人工同意和自動同意都會走到這裡：`20260904020010_accept_store_return_deducts_stock.sql:101`、`20260903010020_return_to_hq_auto_accept.sql:174`。  
  所以待處理紀錄不能只做在前端按鈕，否則 48 小時自動同意會漏。
- 收貨短少已有 `rpc_resolve_transfer_item_shortage`，含 `restock_hq` / `redispatch` / `reject_return`：`20260903000200_shortage_resolution_undo.sql:111`、`:142`。  
  「少收」要接這套原單差額，不要做成一般自由退貨。
- 撤銷短少已有 `rpc_undo_transfer_item_shortage`：`20260903000200_shortage_resolution_undo.sql:429`。  
  後續若總倉待處理也要撤銷，應抄「單筆撤銷、保留軌跡」的精神，不要整張退回重來。
- `rpc_adjust_received_transfer` 與 `rpc_unreceive_transfer` 是已收單的兩個逃逸口：`20260904010000_adjust_received_syncs_stock.sql:194`、`20260903000010_unreceive_reverse_inbound_regardless_of_qty.sql:26`。  
  新待確認批次若不擋這兩個，員工可從已收清單改掉數字或退回收貨配單，讓待處理紀錄和庫存保留量脫鉤。

### 2. 最新真正 CREATE 定義是哪幾支？

本輪用 `git grep -nE "CREATE (OR REPLACE )?FUNCTION/VIEW ..."` 在本機 HEAD 查，不用檔名猜。

- `rpc_receive_transfer`：`20260904020010_accept_store_return_deducts_stock.sql:101`
- `rpc_reject_transfer`：`20260904020020_reject_store_return_no_phantom_stock.sql:88`
- `rpc_create_store_return`：`20260904020000_store_return_create_no_stock.sql:157`
- `rpc_auto_accept_overdue_returns`：`20260903010020_return_to_hq_auto_accept.sql:120`
- `rpc_resolve_transfer_item_shortage`：`20260903000200_shortage_resolution_undo.sql:111`
- `rpc_undo_transfer_item_shortage`：`20260903000200_shortage_resolution_undo.sql:429`
- `rpc_adjust_received_transfer`：`20260904010000_adjust_received_syncs_stock.sql:194`
- `rpc_unreceive_transfer`：`20260903000010_unreceive_reverse_inbound_regardless_of_qty.sql:26`
- `rpc_transfer_arrive_at_hq_batch`：`20260508000000_transfer_hq_dispatch.sql:44`
- `rpc_create_wave_from_restock`：`20260715000020_restock_dispatch_dedup_guards.sql:485`
- `v_store_pending_returns`：`20260904020000_store_return_create_no_stock.sql:123`
- `v_picking_demand_no_po`：`20260612000040_approve_restock_via_picking_workstation.sql:53`
- `v_hq_exceptions`：`20260903010000_hq_po_exception_resolution.sql:296`
- `v_hq_inbox`：`20260818000040_hq_inbox_exclude_same_store_transfers.sql:96`

### 3. 誰在呼叫？

前端呼叫點：

- 店家送退貨：`apps/admin/src/components/StoreReturnCreateModal.tsx:176` → `rpc_create_store_return`
- 總倉收件匣不同意：`apps/admin/src/app/(protected)/hq/inbox/page.tsx:1628` → `rpc_reject_transfer`
- 收貨頁收貨：`apps/admin/src/app/(protected)/wms/inbound/page.tsx:1222`、`apps/admin/src/components/TransferReceiveModal.tsx:335` → `rpc_receive_transfer`
- 收貨頁退回收貨配單：`apps/admin/src/app/(protected)/wms/inbound/page.tsx:1335` → `rpc_unreceive_transfer`
- 明細修改實收：`apps/admin/src/components/TransferReceiveModal.tsx:248` → `rpc_adjust_received_transfer`
- 異常短少處理：`apps/admin/src/components/TransferShortageResolveModal.tsx:455` → `rpc_resolve_transfer_item_shortage`
- 異常已處理撤銷：`apps/admin/src/components/ExceptionsContent.tsx:453` → `rpc_undo_transfer_item_shortage`
- 補貨工作台建單：`apps/admin/src/app/(protected)/wms/picking/page.tsx:1786` → `rpc_create_wave_from_restock`

後端串接點：

- 總倉批次到倉函式內部呼叫 `rpc_receive_transfer`：`20260508000000_transfer_hq_dispatch.sql:82`
- 48 小時自動同意內部呼叫 `rpc_receive_transfer`：`20260903010020_return_to_hq_auto_accept.sql:174`
- 短少 `restock_hq` / `redispatch` 會用 `transfer_cancel` 把短收量記回出貨端，且 `redispatch` 會開重派撿貨單：`20260903000200_shortage_resolution_undo.sql:217`、`:242`、`:265`
- 短少沖帳會產 `return_to_hq` 純記帳單，且註解明寫「本單不動庫存」：`20260903000200_shortage_resolution_undo.sql:340`、`:379`

### 4. 本機 PR 905-915 快照有誰碰同檔？

只讀本機 bare 鏡像 `D:\1人公司\_備份_GitHub_20260831\new_erp.git` 的 `refs/pull/*/head`。這是過期快照，不代表現在 GitHub 狀態。

- #905-#910 都碰到：`hq/inbox/page.tsx`、`wms/inbound/page.tsx`、`wms/picking/page.tsx`、`ExceptionsContent.tsx`、`StoreReturnCreateModal.tsx`、`TransferReceiveModal.tsx`、`TransferShortageResolveModal.tsx`，以及 9/03-9/04 一批 migration。
- #911-#913 都碰到：`wms/inbound/page.tsx`、`StoreReturnCreateModal.tsx`、`TransferReceiveModal.tsx`、三支店家退貨 migration。
- #914 只在快照中看到 `wms/inbound/page.tsx`。
- #915 另需列入目標檔：本機 `cf10338c...refs/pull/915/head` 實查只差 `apps/admin/src/app/(protected)/wms/returns/page.tsx`。

結論：這段只能當本機 refs 的過期線索。若前述清單是用 `main..head` 反向 diff 得到，不能據此斷言它就是該 PR 的實際變更清單，也不能判斷線上作者、狀態或權限。未來要送出等簽收前，仍需在允許連線時重新查證。

---

## 二、阿寫最小切點建議

### 最小落地方案 A：待確認明細表 + 同步 reserved

這是目前看起來最少改、又能卡住共用出庫的路。

1. 新增一張總倉退回貨待處理明細表，記原 transfer / transfer_item、sku、原因、原數量、待確認量、已放行量、破損量、遺失量、處理人與時間。
2. `rpc_receive_transfer` 收到「店家退貨回總倉」時，同步建立待處理明細，並把同 sku 的 HQ `stock_balances.reserved` 加上待確認量。
3. 總倉後續處理時：
   - 完好：扣掉 reserved，變可派。
   - 破損／遺失：先扣 reserved，再寫庫存扣減異動，保留成本依據。
   - 寫錯：必須連回原單處理，不給自由加減。
4. 取消或退回收貨配單時，要同步撤回待處理明細與 reserved，否則會留下卡死的保留量。

做了會怎樣：一般走 `rpc_outbound` 且未開 `p_allow_negative` 的出庫會先被 `on_hand - reserved` 擋住；但這不是完整防線，仍需補負異動 trigger 或同等共用後端保護，並檢查直接寫 `stock_movements` 的路。  
不做會怎樣：只做待辦清單的話，畫面提醒歸提醒，出庫守衛仍可能把未確認貨派出去。

### 為什麼不是只改畫面？

人工同意與 48 小時自動同意都會進 `rpc_receive_transfer`。只改總倉收件匣或某個按鈕，自動同意那條會漏。

### 為什麼不能只改 `v_picking_demand_no_po`？

補貨工作台畫面和 `rpc_create_wave_from_restock` 都直接看 HQ `stock_balances.on_hand`：`20260612000040:75`、`20260715000020:579`、`:591`。  
只改畫面會擋不住送出；只改送出會讓畫面說有貨、送出才失敗。兩邊要同口徑，或用 `reserved` 讓共用守衛先兜住。

---

## 三、容易漏的出口

### P0 待驗風險：未確認貨不能派出去，必須有後端共用保護

檢查點：

- `rpc_receive_transfer` 手動／自動同意都要建立待處理與保留量。
- `rpc_outbound` 一般路徑會吃 `reserved`，但 `p_allow_negative`、直接 `INSERT stock_movements`、補貨工作台 `v_picking_demand_no_po` 與 `rpc_create_wave_from_restock` 直接吃 `on_hand` 的路，都要改成扣掉 reserved 或用同等共用後端保護。
- `wms/picking/page.tsx` 的 `totalAvailable`、KPI、送出前校驗，必須和後端一致。

### P0 待驗風險：同一批不能被重複處理或併發扣兩次

檢查點：

- 待處理明細需要唯一約束，例如同一 `transfer_item_id` 只能有一筆主處理紀錄，或用狀態/序號嚴格控管。
- 部分處理要保證：完好 + 破損 + 遺失 + 寫錯/撤銷 + 未處理 = 原回帳量。
- 同一批兩個總倉人同時處理，要鎖同一批明細與 `stock_balances`，鎖序要跟既有庫存家族一致。

### P0 待驗風險：短收沖帳單不能被當成退貨實物待驗

檢查點：

- 一般店家退貨母體應該是 `[order return%`，不要把 `[短收沖帳]` 的 `return_to_hq` 純記帳單抓進來。
- `restock_hq` / `redispatch` 已會產生 `transfer_cancel` 入庫與沖帳單；短少的 `transfer_cancel` 若是真正回到總倉或出貨端的貨帳，也必須建立一次待處理實物紀錄，但它產生的 `[短收沖帳]` 純記帳單不能再進總倉實物待驗。本案不能對同一短少重複加總倉或重複退款。

### P1 待驗風險：修改實收與退回收貨配單會逃逸

檢查點：

- `rpc_adjust_received_transfer` 現在可改已收單數量；若 `return_to_hq` 退貨單已有待處理，改實收必須同步調整待處理/保留量，或直接擋。
- `rpc_unreceive_transfer` 可把已收退回待收；它也必須同步撤回待處理/保留量，不然總倉保留量會卡住。
- `TransferReceiveModal` 與 `wms/inbound/page.tsx` 目前都看得到修改／退回入口，不能只靠隱藏按鈕，後端要守。

### P1 待驗風險：角色與租戶

檢查點：

- 新處理 RPC 至少要和短少處理同級：`owner/admin/hq_manager` 可處理，店端不可任意處理總倉內部報廢／遺失。
- 所有查詢要吃 tenant；空 role 的 legacy 行為不能放大成任意店可動總倉處理。
- 自動同意的全零操作者要保留標示，不要拿來當真人。

### P1 待驗風險：錢和成本只留依據，不自動再動店家錢

檢查點：

- 店家退貨沖回和總倉內部報廢／遺失是兩件事。總倉後續處理不可再自動產生店家退款或再向店家收款。
- 破損／遺失扣總倉庫存時要保留成本依據：原 out movement / in movement 單價、處理數量、原因、操作者、時間。
- 月結已鎖月份不要被自由更正繞過。若有錢的影響，要和現有鎖月守衛一致。

### P2 待驗風險：畫面文字不要說謊

檢查點：

- 「可派貨」只能顯示扣掉待確認後的數字。
- 「待確認」要明確是這一批，不是整個商品都不能派。
- 自動同意要標示系統自動、時間、原單。
- 未查清時只能留待確認，不能逼員工填破損／遺失／完好。

---

## 四、施工完成後阿審要驗的測試清單

最少要有這些情境；可以是本機型別檢查、單元測試、SQL 靜態檢查或可重跑的本機驗證腳本，但不能連正式庫。

1. 手動同意退貨：建立待處理明細，HQ `reserved` 增加，未確認量不可派。
2. 48 小時自動同意：同樣建立待處理明細，標明自動與時間。
3. 同商品已有好貨 20、待確認 3：可派應為 20，不是 23，也不是 0。
4. 同批 10 件拆成 7 完好、2 破損、1 遺失：最後待確認 0，可派只增加 7，破損/遺失扣帳有紀錄。
5. 部分處理：10 件先放行 4，待確認剩 6，不能整批結案。
6. 同一批重按處理：不能重複扣 reserved、不能重複扣庫存。
7. 兩個人同時處理同一批：其中一邊要等或失敗，合計不能超過原數量。
8. 補貨工作台畫面與送出守衛同口徑：畫面可派多少，送出就只能用多少。
9. `restock_hq` / `redispatch` 的 `transfer_cancel` 真回帳必須建立一次待處理實物紀錄；同時，它們產生的 `[短收沖帳]` 純記帳單不進總倉實物待處理。
10. `rpc_adjust_received_transfer` 對已有待處理退貨單不能讓數字和保留量脫鉤。
11. `rpc_unreceive_transfer` 對已有待處理退貨單不能留下幽靈 reserved。
12. 店端帳單沖回已發生後，總倉內部報廢／遺失不再自動收店家或退店家一次。
13. 舊庫存不自動回補、不批次清理，只影響新流程。

---

## 五、目前狀態

阿寫 Claude CLI 被自動安全審查拒絕，原因是會把私人程式碼送外部 Claude 模型，需要老闆額外明確同意；不應重試或繞過。  
因此目前沒有程式 patch 可審。本輪是外部 Claude 傳送授權阻擋，不能繞過。

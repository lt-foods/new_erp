# 總倉退回貨 C：原單更正／撤回契約

## 範圍

C 不重建 `rpc_adjust_received_transfer`、`rpc_unreceive_transfer`、`rpc_undo_transfer_item_shortage`。三支既有流程都會先寫一筆完整 `stock_movements.reversal`，再清除或替換 `transfer_items` 的來源欄位；C 在這兩個共同接點與 `return_to_hq` 單頭加守門。

## 真撤回

- 只有 `NEW.reverses` 指向 `hq_return_batches.source_movement_id`，且 reversal 與原 movement 的 tenant、location、SKU、成本、數量、transfer、item、operator 全部一致，才算真撤回。
- 原 item 必須仍指向該 movement。門市退貨另核對 `qty_received`；短收另核對 `qty_shipped - qty_received`。
- 鎖序沿用 A：先 `stock_balances`、再 `hq_return_batches`。釋放前確認 `reserved` 足以涵蓋同 tenant/location/SKU 的全部 pending。
- 只有完全未處理的 pending 批次可撤回：good/damaged/lost/revoked 全為 0，且沒有處理事件。partial、completed 或已有事件會 raise，外層 RPC 的新 movement、單據、庫存及財務變更一起 rollback。
- 成功時 `reserved -= total_qty`，批次寫成 `qty_revoked=total_qty,status='revoked'` 並保存 operator、時間與原因；reversal row 落表後，AFTER hook 立即把 append-only movement id 的 FK 補回批次。任一 hook 失敗都會讓整筆 INSERT 與外層 RPC rollback。

## item／header 守門

- `in_movement_id` 或 `shortage_restock_movement_id` 被清除／替換前，舊 batch 必須已由對應原 movement 的真 reversal 完整撤回。
- item 仍指著來源 movement 時，門市退貨的 `qty_received`、短收的 `qty_shipped - qty_received` 必須等於 batch 總量。這是 deferred final-state 檢查：合法整張 unreceive 可在同一交易內先把實收歸零、再撤 shortage；若交易結束時仍掛來源 movement，直接改 `qty_shipped` 或 `qty_received` 會讓整筆失敗。
- received/closed 的 `return_to_hq` item 新增、刪除、改量或移到別張單，也會檢查原單與新單月份；因此沒有 batch 的純短收 credit 子單不能靠直接改 item 繞過月鎖。
- 有 batch 的 item 不可刪除或改寫 item/transfer/SKU 歷史歸屬；有 batch 的 transfer 不可刪除或改 tenant/type/location。
- `return_to_hq` 尚有 pending/partial batch 時，不可直接離開 received/closed，也不可清空 `received_at`。合法 unreceive 會先逐項 reversal，最後才更新單頭，因此可通過。

## 月份鎖

- 月份一律用 `received_at AT TIME ZONE 'Asia/Taipei'`，店家一律取 return transfer 的 `source_location`，並同時帶 tenant。
- 真門市退貨 reversal 先檢查原 return transfer；短收 reversal 先檢查 `shortage_return_transfer_id` 指向的純記帳 credit 子單。檢查在釋放 batch/reserved 之前，直接寫 reversal 也無法繞過。
- return header 改 `received_at`、來源店、tenant、type、status 或刪除時，OLD 與 NEW 涉及月份都會依固定順序檢查。
- C 本案新增 tenant＋month advisory transaction lock，並讓真正最新版月結生成器共用；這不是原生成器既有機制。C 使用 `pg_try_advisory_xact_lock`，月份忙碌就立即讓外層整筆 rollback，避免舊撤收已持有 balance 時等待月份鎖形成死鎖；生成器用同 key 的 blocking lock，C 持鎖時必須等待。取得月份鎖後再 `FOR UPDATE` 鎖該店該月 `store_monthly_settlements` row；`confirmed`、`settled`、`remitted` 一律拒絕。純 `[短收沖帳]` 子單沒有 batch，仍由 `shortage_return_transfer_id` 關係保護。

## 不在 C 內重寫的邊界

- C 原樣重建真正最新版 `rpc_generate_hq_to_store_settlement(date,uuid)`，唯一行為差異是在鎖定判斷與金額讀取前取得同 tenant／month lock；公開 signature、權限、計價、月界、狀態條件與回傳不變。C 不改短收 credit 子單、退款或庫存會計規則，也不做歷史 backfill。
- A 處理破損／遺失產生的 `source_doc_type='hq_return_batch'` 負 movement 目前沒有完整 event reversal 財務流程，禁止直接反向；需人工盤點與對帳。
- 其他沒有 `hq_return_batches` 的歷史 stock movement 仍沿用舊 reversal 規則。
- 真撤回一律要求 `auth.uid()`，movement operator 必須相同，tenant 經 `_current_tenant_id()` 核對；缺 JWT 不會被當成 service 特權。自動接貨是正向 movement，不會進撤回分支，因此既有 autoaccept 不受影響。沒有使用可偽造的 session flag。

# TEST-E2E-T7 — HQ 收件匣

**範圍：** /hq/inbox unified inbox / restock 整合 / 撿貨整合 / counts RPC / 4 個 tab（pending / in_transit / done / 全部）/ 真分頁
**對應 master §：** §8
**對應 fixture seed：** 整體 seed（campaign close / PR / wave / aid post / restock 都會在 inbox 出現）
**反向情境：** 主要為「不應在 inbox 出現」的反向驗證

---

## 既有 docs

| 文件 | 範圍 | 三色 | 動作 |
|---|---|---|---|
| TEST-store-self-service.md | 加盟店自助 / restock | 🟡 | 跑（部分 cover）|

> T7 既有 doc 少，本軌主要是 **inline checklist**。

---

## Inline checklist

### G7.1 RPCs 存在
- [ ] `rpc_hq_inbox_keys` 存在、SECDEF
- [ ] `rpc_inbox_counts` 存在、回傳 4 tab 計數
  ```sql
  SELECT proname, prosecdef, pg_get_function_arguments(oid)
    FROM pg_proc WHERE proname IN ('rpc_hq_inbox_keys','rpc_inbox_counts');
  ```

### G7.2 Inbox 來源整合（per recent commits）
> commit `b80835f`: 採購頁 KPI 重設計 + 撿貨整合進收件匣 + 軟取消 wave
> commit `be0091f`: counts 改一支 RPC + 「全部」視圖真分頁

- [ ] **驗證：** /hq/inbox 涵蓋以下來源（每個都該有 row）：
  - campaign close 通知（CAMP-004/005 status='closed'）
  - PR auto-create / 待審（PR-0002 status='fully_ordered' / PR-0004 status='submitted'）
  - PR cancelled (PR-0003 應在 done tab 或不顯示)
  - PO partially_received / pending (PO-0005)
  - GR confirmed 待後續處理
  - restock requests
  - mutual aid 求助/出讓 (active 7 筆 + cancelled 4 筆)
  - shortage events (ORD-0007)
  - picking wave 撿貨任務 (WAVE-0001 picked / WAVE-0002 cancelled)
  - transfer 收貨待處理 (TF-0002 shipped 等待 dest 收)

### G7.3 Counts RPC 一致性
- [ ] **SQL:** rpc_inbox_counts() 回傳 4 個數字：pending + in_transit + done + 全部
  ```sql
  SELECT * FROM rpc_inbox_counts();
  -- expect: 4 rows or 1 row 4 cols
  ```
- [ ] **驗證：** counts.pending = inbox-keys WHERE status='pending' 的 distinct row 數
- [ ] **驗證：** counts.全部 = pending + in_transit + done

### G7.4 真分頁（per commit be0091f）
- [ ] **UI:** /hq/inbox 「全部」視圖切到 page 2 → 應走 server-side 分頁、不在 client 分
- [ ] **驗證：** 後端 RPC 接 page / page_size 參數、回傳對應 slice

### G7.5 撿貨整合（per commit b80835f）
- [ ] **UI:** /hq/inbox 看到 picking wave 任務（pending tab 應有 WAVE-0001）
- [ ] **UI:** 點 wave row → 跳到 /wms/picking/[wave_id] 正確

### G7.6 軟取消 wave（per commit b80835f）
- [ ] **驗證：** WAVE-0002 cancelled → 不在 pending tab、可在 done tab 找到
- [ ] **UI:** done tab 顯示「已取消」標籤

### G7.7 Restock 整合
- [ ] **驗證：** 加盟店發 restock request → HQ inbox 應有 row（pending tab）
- [ ] **rpc_approve_restock_to_pr / rpc_approve_restock_to_transfer / rpc_reject_restock**: 三種處理方式
- [ ] **驗證：** approve_to_pr → restock 移到 done、新 PR 建在 in_transit
- [ ] **驗證：** approve_to_transfer → restock 移到 done、新 transfer 建在 in_transit

### G7.8 6 頁列表 unified table 樣式（per commit 7f11418）
- [ ] **UI:** /hq/inbox 列表樣式 + /restock + /transfers + /orders + ... 應對齊（同樣 column / hover / pagination）

---

## 反向情境（負面驗證）

### Cancelled / closed 不應在 pending tab
- [ ] PR-0003 (cancelled) 不在 pending
- [ ] PO-0003 (cancelled) 不在 pending
- [ ] PO-0004 (cancelled) 不在 pending
- [ ] WAVE-0002 (cancelled) 不在 pending
- [ ] AID-OFR-002/3/4 (cancelled offer) 不在 pending
- [ ] CAMP-010 (completed) 不在 pending

### Done 不應重複出現在 pending
- [ ] GR-0001 (confirmed) 出現在 done tab、不在 pending tab
- [ ] VP-0001 (paid) 不出現在 pending tab

### 跨 tenant
- [ ] anon 連 inbox → 0 rows
- [ ] branch user 連 inbox → 應只看自己 store 相關（hq_to_store 給該 store 的、自己 store 發出的 restock）

---

## 驗收門檻

- [ ] G7.1 ~ G7.8 全勾
- [ ] 反向「不應出現」全驗
- [ ] 既有 1 doc 跑完
- [ ] 結 `TEST-E2E-T7-inbox-report.md` status: passed

---
title: TEST — 互助交流板 UI（offer + request 兩種 post）(Phase 5c)
module: Inventory / UI
status: draft
owner: alex.chen
created: 2026-04-26
---

# 測試清單 — 互助交流板（純通訊版 + 訂單聯動）

兩種 post type：
- **offer (我有庫存可提供)** = 從既有 customer_order 釋出；認領 → 走 5b-1 `rpc_transfer_order_to_store` 把該訂單變成接收店的
- **request (我要求助)** = 純需求（無 source order）；提供 → 從提供店 pending 訂單挑一張轉給求助店

廢掉原 `rpc_claim_aid` 自動扣 qty / 自動建 transfer 的設計。

**對應 migration:**
- `20260509000000_mutual_aid_replies.sql` (step 1：replies + 3 RPC)
- `20260509000001_mutual_aid_offer_request.sql` (step 2：post_type + source_order)
- `20260509000002_transfer_order_partial.sql` (step 3：依 qty 拆單轉)
- `20260509000003_consume_aid_board.sql` (step 4：分批扣 qty + 自動 exhausted)
**對應 UI:** `apps/admin/src/app/(protected)/inventory/mutual-aid/page.tsx` (新)、`apps/admin/src/app/(protected)/layout.tsx` (Sidebar 加項)
**依賴:** 5b-1 [PR #135](https://github.com/lt-foods/new_erp/pull/135) `rpc_transfer_order_to_store`

## 1. Schema / Migration

### 1.1 mutual_aid_replies (新表)
- [ ] 欄位：`id`、`tenant_id`、`board_id FK→mutual_aid_board(id) ON DELETE CASCADE`、`author_id UUID`、`author_label TEXT`、`body TEXT CHECK 1..1000`、`created_at`
- [ ] index `idx_aid_replies_board (board_id, created_at)`
- [ ] append-only trigger `trg_no_mut_aid_replies` (BEFORE UPDATE OR DELETE)
- [ ] RLS: `replies_read_all` (SELECT 同 tenant)、`replies_authenticated_insert` (INSERT 限 author_id = auth.uid())

### 1.2 mutual_aid_board 加欄位 (step 2)
- [ ] `post_type TEXT NOT NULL DEFAULT 'offer' CHECK IN ('offer','request')`
- [ ] `source_customer_order_id BIGINT REFERENCES customer_orders(id)` (nullable)
- [ ] `aid_board_source_consistency` CHECK：offer → source NOT NULL、request → source IS NULL
- [ ] index `idx_aid_active_by_type (tenant_id, post_type, status, expires_at)` partial WHERE status='active'
- [ ] index `idx_aid_source_order (source_customer_order_id)` partial WHERE NOT NULL

### 1.3 RPC signatures
- [ ] `rpc_post_aid_board(p_offering_store_id, p_sku_id, p_qty_available, p_expires_at, p_note, p_operator, p_post_type, p_source_customer_order_id)` — 8 args、舊 6-arg DROP
- [ ] `rpc_post_aid_reply(p_board_id, p_body, p_operator) RETURNS BIGINT`
- [ ] `rpc_close_aid_board(p_board_id, p_status IN ('cancelled','exhausted'), p_operator)`

## 2. RPC 行為

### 2.1 rpc_post_aid_board offer happy
**情境：** offering_store=2 + sku=11 + qty=1 + expires=+7d + post_type='offer' + source_order_id=53 (該店 pending 訂單)
**預期：** 回新 board id、status='active'、qty_remaining=1、source_customer_order_id=53、tenant_id 從 store 取

### 2.2 rpc_post_aid_board offer 邊界
- [ ] post_type='offer' + source_order_id=NULL → RAISE 'offer post requires p_source_customer_order_id'
- [ ] source_order 不存在 → RAISE 'customer_order N not found'
- [ ] source_order.pickup_store_id ≠ p_offering_store_id → RAISE 'pickup_store_id ... does not match'
- [ ] cross-tenant order → RAISE 'cross-tenant order'

### 2.3 rpc_post_aid_board request happy
**情境：** post_type='request' + source_order_id=NULL + 其他正常
**預期：** 回新 board id、status='active'、source_customer_order_id IS NULL

### 2.4 rpc_post_aid_board request 邊界
- [ ] request + source_order_id 非 NULL → RAISE 'request post must not have source_customer_order_id'

### 2.5 共通邊界
- [ ] qty_available <= 0 → RAISE
- [ ] expires_at <= NOW() → RAISE
- [ ] sku 不存在 → RAISE
- [ ] store 不存在 → RAISE
- [ ] post_type 非 offer/request → RAISE

### 2.6 rpc_post_aid_reply
- [ ] board_id 不存在 → RAISE
- [ ] body 空 → RAISE
- [ ] body > 1000 → RAISE
- [ ] author_label 自動取 raw_user_meta_data.display_name 或 email 前綴
- [ ] tenant_id 從 board 帶
- [ ] 即使 board status=cancelled/expired 仍允許留言（純通訊）

### 2.7 rpc_close_aid_board
- [ ] active → 'cancelled' / 'exhausted' 各成功
- [ ] p_status 非 cancelled/exhausted → RAISE
- [ ] board_id 不存在 → RAISE
- [ ] 已關閉重關 → idempotent 不錯

## 3. UI 行為

### 3.1 載入 /inventory/mutual-aid
- [ ] page 無 console error
- [ ] 看到「📢 我要求助」+「📦 我有庫存可提供」二個按鈕
- [ ] filter tabs：全部 / 需求中 / 釋出中
- [ ] 空態提示

### 3.2 我要求助 modal (RequestModal)
- [ ] 點開 modal、4 必填 (求助店 + SKU + qty + expires) + 1 選填 (note)
- [ ] 任一必填空 → inline 錯誤、modal 不關
- [ ] qty <= 0 → 錯誤
- [ ] 全填 + submit → modal 關 + list 新增 request 貼

### 3.3 我有庫存可提供 modal (OfferModal)
- [ ] 選釋出店後、自動載入該店 pending/confirmed/reserved 訂單列表
- [ ] 選一張訂單 → 自動帶 qty (= 該訂單第一個 item 的 qty)
- [ ] 訂單有多 item → 顯示每個 item 的 SKU pill、可切換 (pickedItemIdx)
- [ ] 沒可釋出訂單 → 顯示「該店目前沒有可釋出的訂單」
- [ ] 必填驗證、submit → modal 關 + list 新增 offer 貼 (含「源訂單」資訊)

### 3.4 List rendering
- [ ] 每 row 顯示：post_type badge (釋出 pink / 需求 blue) + status badge + 釋出/求助店名 + SKU + 數量 + 到期 + (offer 才有) 源訂單號 + 留言數 + note
- [ ] tab 切換 → 列表只顯示對應 type
- [ ] 預設 status=active

### 3.5 Thread modal
- [ ] 點 row 開 modal、顯示 post header + 所有 replies + 留言輸入框
- [ ] reply 輸入 + Ctrl+Enter / 送出留言 → 留言出現
- [ ] reply 寫入後 list 該 post 留言數 +1
- [ ] active post 才能留言 / 認領 / 結束、closed post 顯示「無法再留言」

### 3.6 認領 offer (ClaimOfferDialog) — 支援分批
- [ ] thread modal 對 offer post 顯示「✋ 我要認領」按鈕（紅）
- [ ] 點開二級 dialog：接收店 select (排除釋出店) + 認領數量 input (預設 = post.qty_available) + 原因
- [ ] 數量超過 qty_available → inline 錯誤
- [ ] 不選店 → inline 錯誤
- [ ] 確認後：
  - [ ] call `rpc_transfer_order_partial(post.source_customer_order_id, 接收店, NULL, NULL, ..., p_items=[{sku_id, qty}])` → 拆出指定 qty 開新單；source 該 SKU item qty 減 N（== 則 cancelled）；source 還有其他 active item → 保持 pending、否則 transferred_out
  - [ ] call `rpc_consume_aid_board(post.id, qty, ...)` → board.qty_remaining 減 N；reach 0 → status='exhausted'，否則 active 可繼續被分批認領
- [ ] 分批：A 認 3 → board qty 5→2 active；B 再認 2 → board exhausted

### 3.7 提供 request (FulfillRequestDialog) — 支援分批
- [ ] thread modal 對 request post 顯示「🤝 我可以提供」按鈕（藍）
- [ ] 點開二級 dialog：提供店 select (排除求助店) + 載入該店符合 SKU 的 pending 訂單 + 挑一張 + 提供數量 input (預設 = post.qty_available) + 原因
- [ ] 數量超過 qty_available → inline 錯誤
- [ ] 沒符合訂單 → 顯示「該店沒有含此 SKU 的可轉移訂單」
- [ ] 確認後：partial transfer 該 sku qty 給求助店 + consume board
- [ ] 分批：A 提供 1 → 需求 5→4 active；B 再提供 4 → exhausted

### 3.8 結束此貼 (close)
- [ ] active post 對所有人顯示「結束此貼」按鈕
- [ ] confirm dialog → 確認後 status='cancelled'、modal 關 + list 重載

### 3.9 Sidebar nav
- [ ] 「進銷存」群組下新增「互助交流板」、active 狀態高亮

## 4. Regression
- [ ] 既有 `/inventory/*` (transfers) 頁面不影響
- [ ] `mutual_aid_claims` + legacy `rpc_claim_aid` 仍可呼叫（schema 沒動）
- [ ] `mutual_aid_board` 既有資料（pre-migration）— 沒辦法保證符合新 constraint（offer 沒 source_order）→ migration 加 DELETE 清掉測試資料
- [ ] `npm run build` + TS 過
- [ ] supabase dev push 成功

## 5. 驗收門檻

全部 §1-§4 勾完、preview 無 console error、Supabase dev push 成功、build + type-check 過 才標 done。

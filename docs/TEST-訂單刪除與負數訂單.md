---
title: TEST — 訂單軟刪除 + 負數訂單 + member 登入流程優化 + 訂單列表 cosmetics
module: Orders / Member-app
status: draft
owner: alex.chen
created: 2026-05-03
---

# 測試清單 — 訂單軟刪除 + 負數訂單 + member 登入優化

**對應 plan:** `C:\Users\Alex\.claude\plans\buzzing-singing-stream.md`
**對應 migration:**
- `supabase/migrations/20260516000000_allow_negative_order_qty.sql`（新）
- `supabase/migrations/20260516000001_rpc_create_offset_order.sql`（新）

**對應 UI 變更：**
- `apps/member/src/app/page.tsx`（A1 / A2）
- `apps/member/src/app/auth/success/page.tsx`（A3）
- `apps/admin/src/app/(protected)/orders/page.tsx`（B1 / B1b）
- `apps/admin/src/components/OrderDetail.tsx`（B2）
- `apps/admin/src/app/(protected)/campaigns/order-entry/page.tsx`（C5）

**復用 RPC：** `rpc_cancel_aid_order`、`rpc_get_or_create_store_member`、`list_stores` LIFF API

---

## 1. Schema / Migration 層

### 1.1 customer_order_items.qty 約束放寬
- [ ] 舊 CHECK `qty > 0` 已 drop
- [ ] 新 CHECK `qty <> 0` 存在
- [ ] 嘗試 INSERT qty=0 → 拒絕；qty=-1 → 接受；qty=1 → 接受
  ```sql
  SELECT check_clause FROM information_schema.check_constraints
  WHERE constraint_name = 'customer_order_items_qty_check';
  ```

### 1.2 customer_orders.order_kind 欄位
- [ ] 欄位存在、TEXT NOT NULL DEFAULT 'normal'
- [ ] CHECK constraint 限制 IN ('normal', 'offset')
- [ ] COMMENT 說明已寫入
- [ ] 既有 row 全部填入 'normal'（DEFAULT 生效）
  ```sql
  SELECT COUNT(*), order_kind FROM customer_orders GROUP BY order_kind;
  -- 應全為 normal
  ```

### 1.3 Indexes
- [ ] `idx_customer_orders_kind` on `(tenant_id, campaign_id, order_kind)`
  ```sql
  SELECT indexname, indexdef FROM pg_indexes WHERE indexname = 'idx_customer_orders_kind';
  ```

### 1.4 RPC signature
- [ ] `rpc_create_offset_order(BIGINT, BIGINT, JSONB, TEXT, UUID) RETURNS BIGINT` 存在
- [ ] `rpc_cancel_offset_order(BIGINT, TEXT, UUID) RETURNS VOID` 存在
- [ ] 兩個 RPC 都 SECURITY DEFINER
- [ ] GRANT EXECUTE TO authenticated（與專案慣例一致）
  ```sql
  SELECT proname, prosecdef, pg_get_function_arguments(oid)
  FROM pg_proc WHERE proname IN ('rpc_create_offset_order', 'rpc_cancel_offset_order');
  ```

---

## 2. RPC 行為（SQL 直測）

### 2.1 rpc_create_offset_order — happy path
**情境：** campaign A 已 open；store S 已存在；items=`[{campaign_item_id:5, qty:-3}]`、reason='店內現有 3 個'
**預期：**
- 回傳新 order_id
- `customer_orders.order_kind='offset'`、`status='confirmed'`、`notes` 開頭 `[庫存抵減單]`
- `member_id` 對應 store_internal member（rpc_get_or_create_store_member 結果）
- `customer_order_items.qty = -3`
- `created_by = updated_by = p_operator`

### 2.2 rpc_create_offset_order — qty 正數被拒
**情境：** items 內含 `qty: 2`
**預期：** RAISE EXCEPTION '負數訂單所有品項 qty 必須 < 0'，無 row 寫入

### 2.3 rpc_create_offset_order — qty=0 被拒
**情境：** items=`[{campaign_item_id:5, qty:0}]`
**預期：** 同樣 RAISE（>= 0 被擋）

### 2.4 rpc_create_offset_order — store_internal member 復用
**情境：** 同一 store 連續呼叫兩次
**預期：** 兩次 order 的 member_id 一致；members 表只多一筆（第一次建、第二次重用）

### 2.5 rpc_cancel_offset_order — happy path
**情境：** 上一條建立的 offset order
**預期：** `status='cancelled'`、`cancelled_at` 有值、`updated_by` 為 operator

### 2.6 rpc_cancel_offset_order — non-offset 拒絕
**情境：** 對 `order_kind='normal'` 的訂單呼叫
**預期：** RAISE EXCEPTION（提示用 rpc_cancel_aid_order）

### 2.7 rpc_cancel_aid_order 對 offset 訂單
**情境：** 對 `order_kind='offset'` 訂單呼叫 rpc_cancel_aid_order
**預期：** 不會誤觸發 transfer chain 邏輯（offset 單沒有 transfer 關聯，但仍應走基本 cancel path 或被拒；實作時擇一明確）

### 2.8 picking_demand_view 抵減驗證
**情境：** campaign A，3 筆 normal 訂單共 qty=10、1 筆 offset 訂單 qty=-3
**預期：** demand_view 的 `demand_qty` SUM = 7（不是 10）
  ```sql
  SELECT campaign_item_id, demand_qty FROM picking_demand_view
  WHERE campaign_id = <A>;
  ```

### 2.9 Cross-tenant 拒絕
**情境：** store_id 屬於 tenant B、campaign 屬於 tenant A、operator 屬於 A
**預期：** RAISE 或 0 row（不應跨 tenant 寫入）

---

## 3. UI 行為（preview 互動）

### 3.1 A1 — 中文店名顯示
- [ ] `apps/member` 開啟、URL 帶 `?store=S002`
- [ ] 載入完成後顯示「您目前位於 **<中文店名>** 門市」
- [ ] list_stores 失敗（拔網路 / mock 500）→ fallback 顯示 `S002`
- [ ] 切換不同 store code → 名稱跟著變

### 3.2 A2 — 非 PWA 模式隱藏驗證碼區
- [ ] 桌機瀏覽器（非 standalone）：看不到「或者」分隔線、看不到 6 位數驗證碼 form
- [ ] 仍看得到「更換其他門市」連結
- [ ] 模擬 standalone（DevTools application → Service Worker → Add to home / Chrome installed PWA）：驗證碼區出現
- [ ] 已 sync 過的 6 位驗證碼仍能在 PWA 模式下提交

### 3.3 A3 — 驗證成功頁
- [ ] OAuth 走完跳到 `/auth/success`，看到 LINE 頭貼（圓形）+ 名稱（h1）
- [ ] 沒有「進入會員中心」按鈕
- [ ] 有「前往安裝步驟」綠色按鈕，點擊跳到 `/install`
- [ ] PWA 配對流程（paired=1）：顯示「請關閉此視窗、回到 PWA App」原文案
- [ ] 6 位數驗證碼區塊：`code && !paired` 時顯示
- [ ] LINE 個資抓不到（fragment 缺 line_picture/line_name）→ fallback 綠勾 + 「LINE 驗證成功」標題
- [ ] console 無 error

### 3.4 B1 — 訂單列表「取消」按鈕
- [ ] status=pending/confirmed/reserved/shipping/ready/partially_ready：看到紅色「取消」按鈕
- [ ] status=completed/cancelled/expired/transferred_out：看不到「取消」按鈕
- [ ] 點「取消」→ confirm dialog → 確認 → 列表自動 reload、該 row status 變 cancelled
- [ ] 取消失敗（例如 RPC error）→ alert 顯示翻譯後錯誤訊息
- [ ] 取消 shipping 中訂單 → 走全鏈路逆轉、相關 transfer 也變 cancelled（`rpc_cancel_aid_order` 既有行為）

### 3.5 B1b — 訂單列表 cosmetics
- [ ] 「開團」column 顯示 campaign cover_image_url 圖片（h-10 w-10 rounded）+ campaign_no + name
- [ ] cover_image_url 為 null → 顯示 placeholder（首字 / svg / 灰底）
- [ ] 「會員」column 顯示 avatar_url（h-8 w-8 rounded-full）+ 暱稱/姓名
- [ ] avatar_url 為 null → 顯示 fallback 首字圓圈
- [ ] 圖片載入失敗（壞 URL）→ 不破版（`onError` 替成 fallback）

### 3.6 B2 — 訂單詳情頁「取消」按鈕
- [ ] OrderDetail modal 上 action bar 看到紅色「取消訂單」按鈕（與「轉出」「取貨」並列）
- [ ] 點擊跳出原因輸入 → 送出 → modal 顯示成功訊息 → 列表自動 reload
- [ ] 已 cancelled 訂單再開詳情：取消按鈕隱藏

### 3.7 C5 — 訂單新增頁 [負數模式] toggle
- [ ] Mode 切換器看到三顆按鈕：客戶 / 店內 / 庫存抵減單（紅/橘色）
- [ ] 切到 offset → 顧客選擇區隱藏、自動帶 store_internal
- [ ] 「抵減原因」必填欄位顯示、空白送出 → 阻擋
- [ ] qty 欄位 placeholder 改提示「正數會自動轉為負」
- [ ] 送出時 qty = -|input|；DB 寫入確實為負
- [ ] 送出成功 → 跳回列表、該 order 顯示「抵」徽章
- [ ] 既有 customer / internal mode 不受影響（regression）

### 3.8 訂單列表 — offset 徽章
- [ ] order_kind=offset 的 row 顯示「抵」灰色徽章
- [ ] 點開詳情：可看到 notes 開頭 `[庫存抵減單]`
- [ ] 顧客視角（apps/member /me）：看不到 offset 訂單（member_id 不同）

---

## 4. Regression

### 4.1 既有 OAuth 流程
- [ ] 從 LINE 內 webview 開啟 → LIFF 自動登入 → /me 不破
- [ ] 從桌機瀏覽器開啟 → 走 OAuth → success page → 點「前往安裝步驟」 → /install 顯示正確 UA 分支
- [ ] PWA standalone 點登入 → 開瀏覽器 OAuth → 6 位數碼仍能 sync 回 PWA

### 4.2 既有訂單流程
- [ ] 一般訂單建立（rpc_create_customer_orders）不受 qty 約束放寬影響
- [ ] 一般訂單取消（pending/confirmed）走 `rpc_cancel_aid_order` 直接 cancel 路徑正常
- [ ] 訂單轉手 (rpc_transfer_order) 對 offset 單應拒絕（加 guard）
- [ ] 取貨流程 / picking wave 流程不受 offset 訂單影響（offset 不進 picking）

### 4.3 採購聚合
- [ ] picking_demand_view、PR 計算包含 offset 抵減後的數字
- [ ] 結算金額（settlement）行為與 plan 開放問題 #2 一致（依實作後實際行為記錄）
- [ ] 既有 v_customer_order_summary、v_customer_order_summary_items_detail 不破

### 4.4 訂單列表查詢效能
- [ ] 加入 cover_image_url、avatar_url 後列表載入時間無顯著退化
- [ ] 大量 row（>1000）下 JOIN/IN query 仍可接受

---

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功**（記憶提醒：URL 要帶 `sslmode=require`）、**apps/admin + apps/member build + type-check 通過** 才可標 done。

完成後依使用者記憶規則：
1. GitHub Issues 開新 issue + merge 後關閉
2. Wiki 更新訂單模組頁、Home、Sidebar
3. PRD `docs/PRD-訂單取貨模組-v0.2-addendum.md` 補負數訂單一節

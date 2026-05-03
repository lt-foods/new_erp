# TEST — apps/member 訂單卡三 tab + 通知中心 + bar 重組

**對應 commit:** `645d538 feat(member): 訂單卡三 tab 分組 + 通知中心 + bar 重組`
**對應 migration:** `supabase/migrations/20260604000000_notifications.sql`
**對應 edge function:** `supabase/functions/liff-api/index.ts` + `supabase/functions/admin-notify/index.ts`
**對應 UI 變更:**
- `apps/member/src/app/orders/page.tsx`
- `apps/member/src/components/OrderCard.tsx`
- `apps/member/src/components/MemberTabBar.tsx`
- `apps/member/src/app/notifications/page.tsx` (新)
- `apps/member/src/components/NotificationCard.tsx` (新)
- `apps/member/src/lib/useUnreadNotifications.ts` (新)
- `apps/admin/src/app/(protected)/orders/page.tsx` (Td title prop 修)

## 目標
驗證三件事到端對端可用：
1. 訂單卡片去除內部編號（`order_no` / `sku_code` / `settlement_no`）+ 三 tab 分組（未到貨 / 已到貨 / 訂單紀錄）
2. Bar 拿掉「結單」、加「通知」並支援未讀 badge
3. `notifications` 模組（schema + 3 個 liff-api action + admin-notify in-app 寫入整合）

## 前置條件
- migration `20260604000000_notifications.sql` 已 push
- edge function `liff-api` + `admin-notify` 已 redeploy
- 測試 member A：有未到貨 ≥1 / 已到貨 ≥1 / 已完成 ≥1 訂單；至少 1 個 push subscription
- 測試 member B：與 A 同 tenant 但不同 member_id，用於跨 member 隔離測
- 至少 1 筆訂單的 `store_name` 非空（驗 header 第二行取貨欄位）

---

## T1 — Schema / Migration

| # | 步驟 | 預期 |
|---|------|------|
| T1-1 | `\d notifications` | 欄位齊備：`id BIGSERIAL`, `tenant_id UUID NOT NULL`, `member_id BIGINT NOT NULL`, `category TEXT NOT NULL DEFAULT 'general'`, `title TEXT NOT NULL`, `body TEXT`, `url TEXT`, `read_at TIMESTAMPTZ`, `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` |
| T1-2 | `\d+ notifications` | 看到 FK `member_id REFERENCES members(id) ON DELETE CASCADE` |
| T1-3 | `\di notifications*` | `idx_notifications_member_recent` (tenant_id, member_id, created_at DESC) + `idx_notifications_member_unread` partial WHERE `read_at IS NULL` 兩個都在 |
| T1-4 | `SELECT relrowsecurity FROM pg_class WHERE relname='notifications'` | `t`（RLS 啟用） |
| T1-5 | `SELECT polname FROM pg_policy WHERE polrelid='notifications'::regclass` | 含 `notifications_self_all` + `notifications_hq_all` 兩條 |
| T1-6 | `INSERT INTO notifications (tenant_id, member_id, title) VALUES ('<t>','<m>','測試')` (service role) | 成功；`category='general'`、`read_at IS NULL`、`created_at` 自動帶 |
| T1-7 | 同 T1-6 但 `member_id` 給不存在 ID | FK 違反 reject |
| T1-8 | `DELETE FROM members WHERE id = <m>` | `notifications` 對應 row 一起被 CASCADE 刪除 |

## T2 — Edge Function: liff-api 通知 actions

| # | 步驟 | 預期 |
|---|------|------|
| T2-1 | `POST /liff-api { action: "list_my_notifications" }` 用 member A token | 200，`{notifications: [...]}` 全部 `member_id = A` |
| T2-2 | T2-1 排序 | `created_at` desc，第一筆是最新 |
| T2-3 | T2-1 limit | 最多 100 筆 |
| T2-4 | A 的 token 取 B 的訊息（不存在的 action 參數） | 結果不含 B 的訊息（service role + WHERE 過濾） |
| T2-5 | `POST /liff-api { action: "get_my_unread_notification_count" }` | 200，`{count: N}`，N = `read_at IS NULL` 的數量 |
| T2-6 | A 有 3 筆未讀；標 1 筆已讀後再呼叫 T2-5 | count = 2 |
| T2-7 | `POST { action: "mark_notification_read", id: <自己的> }` | 200 ok；該筆 `read_at` 變成 now() |
| T2-8 | `POST { action: "mark_notification_read", id: <別人的> }` | 200 ok 但 row 沒被改（WHERE member_id 過濾保護） |
| T2-9 | `POST { action: "mark_notification_read" }` 無 id 也無 mark_all | 400 `id required when mark_all is not set` |
| T2-10 | `POST { action: "mark_notification_read", mark_all: true }` | 200 ok；A 所有未讀全變已讀；T2-5 再呼叫 = 0 |
| T2-11 | 不帶 Authorization 呼叫任一 action | 401 missing authorization |

## T3 — Edge Function: admin-notify 雙寫 push + in-app

| # | 步驟 | 預期 |
|---|------|------|
| T3-1 | `POST /admin-notify { member_id: A, title: "T", message: "B", url: "/orders" }` 帶 admin JWT | 200；`notifications` 多 1 筆 `(category='general', title='T', body='B', url='/orders')`；A 的手機收到 push |
| T3-2 | `POST /admin-notify { member_id: A, title: "T2", category: "order_arrived", url: "/orders" }` | 200；多 1 筆 `category='order_arrived'` |
| T3-3 | 對沒 push subscription 的會員 C 呼叫 admin-notify | 200 `{ok:true, sent:0, message:"Notification recorded; no active PWA subscriptions to push"}`；C 的 `notifications` 仍多 1 筆 |
| T3-4 | 不帶 Authorization | 401 |
| T3-5 | 不帶 `member_id` | 400 `member_id is required` |
| T3-6 | 同 T3-1 但 push subscription 全部失效（401 from web push service） | `notifications` 仍寫入；response 回 `failed: N` 但 `sent: 0`；不會 throw 500 |

## T4 — UI: /orders 三 tab + 卡片精簡

| # | 步驟 | 預期 |
|---|------|------|
| T4-1 | 進 `/orders`（已登入） | 三個 tab 標籤：`未到貨 (n1)` / `已到貨 (n2)` / `訂單紀錄 (n3)`，n 數字與後端 active+history 結果對得上 |
| T4-2 | 切 tab 觀察 devtools network | 不再觸發新的 `list_my_orders` 請求（純 client filter） |
| T4-3 | 點「未到貨」 tab | 列出的訂單 `arrived=false` 全部 |
| T4-4 | 點「已到貨」 tab | 列出的訂單 `arrived=true` 全部 |
| T4-5 | 點「訂單紀錄」 tab | 列出狀態 = completed 的訂單 |
| T4-6 | 觀察任一卡片 | 不出現 `O-` / `S-` / `SKU-` 開頭的編號文字；不出現「結單編號」字樣 |
| T4-7 | 觀察卡片右上 / 商品列下方 | 沒有「已到貨 / 未到貨」chip（已被 tab 取代） |
| T4-8 | 卡片 header 第二行 | 顯示 `YYYY/MM/DD · 取貨：<店名>` 格式 |
| T4-9 | `store_name` 為 null 的訂單 | 第二行只顯示日期（不出現 `· 取貨：`） |
| T4-10 | 商品列 item 區塊 | 顯示「商品名稱 / 規格」+「單價 × 數量」+「小計」；無 sku_code mono 字串 |
| T4-11 | 任一 tab 為 0 筆 | 顯示空狀態：`📦 / 目前沒有<未到貨\|已到貨\|已完成>訂單` |
| T4-12 | 整頁初次載入 console | 無 error / warn |

## T5 — UI: bar + /notifications

| # | 步驟 | 預期 |
|---|------|------|
| T5-1 | 開啟 PWA standalone（非 LINE webview）任一頁 | 底部 4 個 tab：`商品` / `訂單` / `通知` / `我`，第三格無「結單」字樣 |
| T5-2 | 直接訪問 `/settlements` | 頁面正常進入（保留路由，僅 bar 不再列） |
| T5-3 | 手動 INSERT 1 筆 notifications row（read_at IS NULL）給當前 member | 切到任一頁面後，「通知」icon 右上出現紅圓 badge 顯示 `1` |
| T5-4 | 手動 INSERT 100 筆未讀 | badge 顯示 `99+` |
| T5-5 | 進 `/notifications` | 列表依 created_at desc 顯示；未讀者左側藍點；右上相對時間（剛剛 / N 分鐘前 / N 小時前 / N 天前 / 日期） |
| T5-6 | T5-5 進入後，切到其他 tab 再回來 | bar badge 歸零（auto mark_all_read on entry） |
| T5-7 | 點有 `url` 的卡片 | 跳轉到該 url 路徑 |
| T5-8 | 點沒 `url` 的卡片 | 不會跳轉、無 console error |
| T5-9 | 通知為 0 筆時進入 | 顯示空狀態 `📬 還沒有任何通知` |
| T5-10 | iPhone Safari LIFF webview（非 standalone）開頁 | bar 整個隱藏（既有邏輯不被破壞） |
| T5-11 | `/shop/c/<id>` 商品詳細頁 | bar 隱藏（既有邏輯不被破壞） |

## T6 — Regression

| # | 步驟 | 預期 |
|---|------|------|
| T6-1 | 既有的「未完成 / 訂單紀錄」深連結（若有） | 改用 `/orders` 後仍可開頁，不報錯（tab default 為 `pending`） |
| T6-2 | admin `TransferReceiveModal` 收貨後推播 | 顧客手機收 push **且** /notifications 出現對應紀錄（之前只有 push） |
| T6-3 | admin `MemberDetail` 測試推播 | 同 T6-2 |
| T6-4 | `apps/admin` build | `next build` 綠燈，原本 `(protected)/orders/page.tsx:351` 的 `Property 'title' does not exist` TS error 解掉 |
| T6-5 | `apps/member` build | `next build` 綠燈，含新 `/notifications` route |
| T6-6 | `list_my_orders` 既有呼叫端（tab=active / tab=history）行為 | 後端不變，回傳結構相同 |

## §7 驗收門檻

全 §1-§6 勾完、**無 console error**、**Supabase dev push 成功**、**admin + member build + type-check 通過** 才可標 done。

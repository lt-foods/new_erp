# 測試項目 — 取貨只能按照店家（分店帳號鎖店）

**範圍:** 取貨頁（`/pickup`）+ `rpc_record_pickup` 後端守衛。原本搜會員會列出該會員**所有分店**的未取單，A 店店員按得到 B 店訂單的「取貨」—— 庫存扣的是 B 店（stock_movement 跟著 `pickup_store_id` 的 location 走）、訂單被標成已取，但客人人在 B 店根本沒拿到貨。改成：分店帳號只顯示、只能操作自己店的訂單；後端 RPC 加同款守衛當最後防線（orders 頁批次取貨 / PickupDialog 走同一支 RPC，一併被蓋住）。

**分店身分判定（前後端一致，對齊 `useUserBranchStoreId` / 20260808000020）:**
`app_metadata.role ∈ (store_manager, store_staff)` 且 `app_metadata.stores`（店名陣列）非空、不含「總倉」→ 鎖店。HQ 層級（owner / admin / hq_manager / hq_accountant / ''）、stores 未設定的 legacy 分店帳號、含「總倉」的帳號行為不變。

**對應變更:**
- `supabase/migrations/20260813000000_pickup_store_guard.sql` — `rpc_record_pickup` 開頭加店家守衛（基底 20260801000000，rollback 重跑該段落）：訂單 `pickup_store_id` 的店名必須在呼叫者 `app_metadata.stores` 裡，否則 `RAISE EXCEPTION 'wrong_store: 此訂單的取貨店是「X」…'`。
- `apps/admin/src/app/(protected)/pickup/page.tsx`：
  - `branchLocked` 時，會員卡片訂單清單（未取/已取兩個模式）只列自己店的單；一次全取、合併補印、確認視窗、快速取貨都走過濾後清單。
  - 其他店的單收成一行摘要：「🔒 另有 N 張未取訂單在其他分店（三峽店 ×2、板橋店 ×1）— 請顧客至該店取貨」（已取模式改說「補印收據請由該店操作」），讓櫃台答得出客人在別店還有幾張。
  - 頁首加「🔒 分店帳號：僅顯示、僅能操作 X 店的訂單」提示；空清單文案改「本店無未取訂單。」。
  - 貨齡面板 `PickupAgingPanel` 傳入 `storeId`（分店帳號只看本店統計；多店帳號沿用 `useUserBranchStoreId` 慣例取第一個 match）。
- `apps/admin/src/lib/rpcError.ts`：`wrong_store:` 前綴剝掉、直接顯示中文訊息。

**驗證方式:** `tsc --noEmit` + eslint（不新增問題）+ Playwright fixture（`apps/admin/.claude/skills/verify`，攔 `rest/v1` 假資料模擬分店/HQ 帳號，不碰線上 DB）+ 線上 DB 灌 claims 打 RPC（`p_item_ids=ARRAY[0]` 選不到任何品項，守衛通過會停在 `no items picked`，零副作用）。migration 已於 2026-08-13 套用到線上。

---

## 1. 分店帳號（store_staff，stores=['林口店']，Playwright fixture 已實測）

- [x] 頁首顯示「🔒 分店帳號：僅顯示、僅能操作 林口店 的訂單」
- [x] 搜跨店會員 → 只列林口店的未取單；三峽店的 2 張不出現在清單
- [x] 卡片底部顯示「🔒 另有 2 張未取訂單在其他分店（三峽店 ×2）— 請顧客至該店取貨」
- [x] 「📦 一次全取（N 張）」張數只算林口店的單（fixture：3 張只算 1 張）
- [ ] 全部單都在別店 → 顯示「本店無未取訂單。」+ 其他分店摘要
- [ ] 「✅ 已取貨（補印）」模式同樣只列本店已取單，摘要改說「補印收據請由該店操作」
- [x] 貨齡面板只顯示本店張數（實測 rpc_pickup_aging 收到 `{"p_store_id":1}`）
- [x] 直接打 RPC（或 orders 頁批次取貨勾別店的單）→ 後端回「此訂單的取貨店是「X」，分店帳號只能替自己店的訂單取貨，請由該店操作或先轉單」（頁面上 wrong_store 前綴已剝掉）

## 2. HQ 帳號（owner / admin / hq_manager / hq_accountant / ''）

- [x] 行為完全不變：所有分店的單都列出、都可取貨；無鎖店提示；貨齡面板 `p_store_id:null`（fixture 以 role='' 實測；admin 於後端實測）
- [x] store_manager/store_staff 但 stores 含「總倉」→ 不鎖（後端已實測；前端同一個 branchLocked 條件）
- [x] store_staff 但 stores 未設定（legacy）→ 不鎖（避免部署當天把舊帳號全鎖死；後端已實測）

## 3. 後端守衛邊界（線上 DB 灌 claims 已實測，order 74848 取貨店=湖口店）

```sql
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"<uuid>","app_metadata":{"tenant_id":"<uuid>","role":"store_staff","stores":["平鎮店"]}}', true);
SELECT rpc_record_pickup(74848, ARRAY[0]::bigint[], '<uuid>');
-- → wrong_store: 此訂單的取貨店是「湖口店」…（換成 stores=["湖口店"] → no items picked = 守衛通過）
```

- [x] 分店帳號取自己店的單 → 通過守衛（停在 no items picked，dummy item id 零副作用）
- [x] 分店帳號取別店的單 → wrong_store，訊息含對方店名「湖口店」
- [ ] 訂單 pickup_store_id 為 NULL / 查無店 → 分店帳號被擋（訊息顯示「未設定」）
- [x] HQ（role=admin）→ 通過守衛不受影響；service_role / 無 JWT（role 為空）同一條 bypass 路徑

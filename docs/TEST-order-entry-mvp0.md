# order-entry-mvp0 測試項目 — 小幫手代客 key 訂單

**對應 migration:** `supabase/migrations/<新增>_order_entry_rpcs.sql`（待新增）
**對應 UI 變更:** `apps/admin/src/app/(protected)/campaigns/order-entry/page.tsx`（路由用 `?id=X` query string，不走 `[id]/`，因為 admin 是 static export）
**對應 PRD:** `docs/PRD-訂單取貨模組.md` §7.3、`docs/PRD-訂單取貨模組-v0.2-addendum.md`
**現有 schema:** `supabase/migrations/20260423120000_stores_order_schema.sql`（tables 已建好，本次只加 RPC）

---

## 1. Schema / Migration 層

### 1.1 RPC: `rpc_search_members(p_term TEXT, p_limit INT DEFAULT 20)`
- [ ] 函式存在、回傳 `TABLE(id BIGINT, member_no TEXT, name TEXT, phone TEXT, avatar_url TEXT)`
- [ ] `SECURITY DEFINER`、`GRANT EXECUTE TO authenticated`
  ```sql
  SELECT pg_get_functiondef('rpc_search_members'::regproc);
  ```

### 1.2 RPC: `rpc_search_skus_for_campaign(p_campaign_id BIGINT, p_term TEXT, p_limit INT DEFAULT 20)`
- [ ] 回傳該活動 `campaign_items` 內的 SKU + unit_price + cap_qty
- [ ] term 為空時回前 N 筆（預設排序）
- [ ] 比對 sku.code / sku.name / product.name 模糊搜尋

### 1.3 RPC: `rpc_search_aliases(p_channel_id BIGINT, p_term TEXT, p_limit INT DEFAULT 20)`
- [ ] 從 `customer_line_aliases` 搜 nickname、JOIN members 回傳 (alias_id, nickname, member_id, member_name, phone)

### 1.4 RPC: `rpc_bind_line_alias(p_channel_id, p_nickname, p_member_id)`
- [ ] 已存在相同 (channel_id, nickname) → 改 member_id 並更新 updated_by
- [ ] 不存在 → INSERT
- [ ] member_id 跨 tenant → RAISE

### 1.5 RPC: `rpc_create_customer_orders(p_campaign_id, p_channel_id, p_rows JSONB)`
參數 `p_rows`：`[{member_id, nickname, pickup_store_id, items:[{campaign_item_id, qty}]}, ...]`
- [ ] 函式 `SECURITY DEFINER` + tenant 驗證
- [ ] 同 (campaign_id, channel_id, member_id) 已存在訂單 → 走 UPSERT 合併 items（呼應 schema UNIQUE 194）
- [ ] 自動產 `order_no`（規則：`{campaign_no}-{seq}`）
- [ ] items.unit_price 從 campaign_items 取，**不接受前端傳 price**
- [ ] 回傳 `TABLE(order_id BIGINT, order_no TEXT, item_count INT)`

### 1.6 Grants / RLS
- [ ] 4 個 RPC 全部 `GRANT EXECUTE TO authenticated`
- [ ] 以 `hq_manager` JWT 呼叫 → 通；以 store JWT 呼叫 search_members / create_orders → 仍允許（小幫手未必是 HQ role，需確認 JWT role 範圍）

---

## 2. RPC 行為（SQL 直測）

### 2.1 `rpc_search_members` — 模糊搜
**情境：** 預先建 3 筆 members（name=陳小美 / phone=0912345678 / member_no=M0001）
**預期：**
- term=`小美` → 回 1 筆
- term=`5678` → 回 1 筆（phone 後 4 碼）
- term=`M0001` → 回 1 筆
- term=`` → 回前 N 筆（依 created_at DESC）

### 2.2 `rpc_search_skus_for_campaign` — 限縮在活動內
**情境：** Campaign A 有 SKU x/y；DB 還有 SKU z 不在活動
**預期：** 搜 z 的 code → 0 筆；搜 x → 1 筆且帶 unit_price

### 2.3 `rpc_create_customer_orders` — 新建 + 合併
**情境：** 同 campaign+channel+member 先呼叫一次（含 SKU x qty=2），再呼叫一次（含 SKU x qty=1, SKU y qty=3）
**預期：**
- customer_orders 只 1 筆（UNIQUE 觸發合併）
- customer_order_items：SKU x 變 qty=3（或新增第二筆，視合併策略 — 文件決議）、SKU y qty=3
- 第二次呼叫 updated_by 有更新

### 2.4 `rpc_create_customer_orders` — 跨 tenant FK 拒絕
**情境：** 傳入別 tenant 的 member_id
**預期：** RAISE EXCEPTION（tenant mismatch）

### 2.5 `rpc_create_customer_orders` — qty=0 拒絕
**情境：** items 內帶 qty=0
**預期：** CHECK (qty > 0) 觸發 → RAISE

### 2.6 `rpc_create_customer_orders` — campaign 已 closed
**情境：** campaign.status='closed'
**預期：** RAISE EXCEPTION（決議 A：只有 `open` 階段允許 key 單；`closed` 起一律拒絕）

### 2.7 `rpc_bind_line_alias` — 改綁
**情境：** 既有 alias (channel=1, nickname='小美')→memberA；改呼叫綁到 memberB
**預期：** 同一筆 row 的 member_id 更新為 B、updated_at 變更

### 2.8 `rpc_bind_line_alias` — 跨頻道同暱稱
**情境：** channel=1 與 channel=2 都綁 nickname='小美' 但對到不同 member
**預期：** 兩筆並存（schema UNIQUE 是 tenant+channel+nickname）

---

## 3. UI 行為（preview 互動）

### 3.1 Mount
- [ ] 走訪 `/campaigns/order-entry?id={id}` 載入無 console error
- [ ] 頂部顯示活動卡（campaign_no / name / status / pickup_deadline）

### 3.2 顧客搜尋區
- [ ] 輸入 2 字元觸發 autocomplete（debounce 200ms）
- [ ] 同時搜 alias + member（分區顯示）
- [ ] 點 alias 結果 → 帶入 member 並鎖 channel
- [ ] 點 member 結果 → 顯示「此頻道未綁定，是否新增暱稱別名？」inline action
- [ ] Ctrl+N 開「新增顧客」抽屜（建 member + 同步建 alias）

### 3.3 明細表（Excel 式）
- [ ] 每列：SKU autocomplete / 數量 / 單價(readonly) / 小計 / 刪除
- [ ] Tab 跳下一欄；最後一欄 Tab 自動加新列
- [ ] Enter 在數量欄 → 加新列並 focus 到 SKU
- [ ] SKU autocomplete 只顯示活動內 SKU
- [ ] 數量輸入非數字 / 0 / 負數 → 紅框 + 不可送出
- [ ] 刪除列 → 即時更新右側統計

### 3.4 右側統計面板
- [ ] 顯示總筆數、總金額
- [ ] 各 SKU 累計 qty
- [ ] 顧客切換時不會殘留前一筆統計

### 3.5 Draft 自動存（localStorage）
- [ ] 30s tick 寫入 `draft:order-entry:{campaign_id}`
- [ ] 重新整理頁面 → 顯示「發現未送出的草稿，要載回嗎？」
- [ ] 成功送出 → 清空對應 draft key

### 3.6 送出
- [ ] Ctrl+S 觸發送出（非 form submit）
- [ ] 成功 → toast「已建立 N 筆訂單」+ 清空表單 + 清 draft
- [ ] 失敗（RPC RAISE）→ toast 顯示錯誤訊息、表單保留
- [ ] DB 驗證：customer_orders + customer_order_items 實際寫入

### 3.7 顧客→訂單合併
- [ ] 同顧客連 key 兩次 → 第二次提示「此顧客已有訂單，將合併」並可預覽

---

## 4. Regression
- [ ] `/campaigns` 列表頁正常（campaign 狀態、items count 正確）
- [ ] `/campaigns/[id]` 既有明細頁不受影響
- [ ] `/orders` 列表能看到新 key 的訂單（含 nickname_snapshot）
- [ ] `/members` 列表頁正常（新 alias 不應改動 member 主檔以外欄位）
- [ ] 既有 RLS：以 store role 進站，看不到別店 pickup 的訂單

---

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功**、**build + type-check 過** 才可標 done。

# 粉絲團設定頁 `/fb-pages`

**對應頁面：** `apps/admin/src/app/(protected)/fb-pages/page.tsx`（新增）
**對應 RPC：** `rpc_upsert_fb_page`、`rpc_delete_fb_page`（新增於本次 migration）
**對應 schema：** `fb_pages` (`supabase/migrations/20260620000030_fb_pages_and_campaign_fb_posts.sql:9`)

**動機：** `FbPublishModal` 仰賴 `fb_pages` 表，但目前後台**完全沒有 CRUD UI**（modal 顯示 hint：「目前沒有啟用中的粉絲團設定。請先在資料庫的 fb_pages 表新增資料。」）。每次要加新粉絲團都得直接打 SQL，違反「管理操作走 UI」的習慣，且 access_token 是長字串敏感資料，貼 SQL 容易出錯。

---

## 0. 範圍

**v1（本次）**
- 列表：name / page_id / sort_order / 狀態
- 搜尋：name + page_id ilike
- 過濾：是否啟用
- inline 編輯：name / page_id / access_token（留空＝沿用） / sort_order / is_active
- 新增
- 「停用」用 is_active toggle（不做硬刪——已被 campaign_fb_posts FK 引用）

**v1 不做**
- 「已發團數」欄位（PostgREST nested-filter 寫起來囉嗦，下版補）
- 「測試 token 有效性」按鈕（call FB Graph /me 驗 token）— 後續再補
- access_token 加密儲存（目前 plaintext，RLS 守門已足夠 v1）
- 多 tenant 切換（沿用 user JWT tenant_id）

---

## 1. 列表行為

### 1.1 預設載入
- [ ] `/fb-pages` 載入無 console error
- [ ] 預設只顯示 `is_active = TRUE`
- [ ] 排序：sort_order asc, then updated_at desc
- [ ] 列表 select **不含 access_token**（敏感欄位，client 端不取）

### 1.2 搜尋
- [ ] 搜「樂樂」→ name 含「樂樂」hit
- [ ] 搜 page_id（一串純數字）→ exact-ish ilike hit
- [ ] 250ms debounce

### 1.3 篩選
- [ ] 「全部 / 僅啟用」切換正常

---

## 2. 編輯行為

### 2.1 新增
- [ ] 點「新增粉絲團」→ 出現 inline 表單
- [ ] name、page_id、access_token 必填
- [ ] access_token 用 `type="password"`，且 placeholder 提示「Page Access Token」
- [ ] sort_order 預設 0
- [ ] is_active 預設 true
- [ ] 儲存呼叫 `rpc_upsert_fb_page(p_id=NULL,...)` 成功
- [ ] 儲存後列表新增該筆、access_token 不出現在 UI 任何地方

### 2.2 編輯
- [ ] 點「編輯」→ inline 表單帶入 name / page_id / sort_order / is_active（**access_token 欄位為空**）
- [ ] access_token 留空 → 儲存後 DB 內 token 不變
- [ ] access_token 重新填 → 儲存後 DB 內 token 更新
- [ ] 取消不寫入

### 2.3 停用
- [ ] 編輯時取消「啟用」checkbox → 儲存 → `is_active=false`
- [ ] 篩「僅啟用」時不顯示
- [ ] `FbPublishModal` 開啟時不會出現停用的粉絲團（沿用 `.eq("is_active", true)`）

### 2.4 錯誤處理
- [ ] page_id 重複（同 tenant_id）→ 紅字提示 unique violation
- [ ] 沒輸入必填 → HTML required 擋下
- [ ] 新增時 access_token 空 → 守門（HTML required + RPC raise）

---

## 3. 權限 / 安全

- [ ] 只 owner / admin / hq_manager 能進頁面（沿用 fb_pages RLS）
- [ ] 一般 store_manager 帳號開頁 → 列表為空 + 操作觸發 RLS 拒絕
- [ ] sidebar 「粉絲團」連結放「設定」group（已是 admin-only）
- [ ] 分店帳號（branch user）看不到 sidebar 連結（加進 `BRANCH_HIDDEN_HREFS`）
- [ ] access_token 不出現在 select 列表 / 不出現在 console / 不出現在 network 回傳
- [ ] RPC `rpc_upsert_fb_page` 是 SECURITY DEFINER，內部守門 role IN ('owner','admin','hq_manager') + tenant_id 從 JWT 拿（非 client 傳）

---

## 4. Regression

- [ ] `/campaigns` 列表「發 FB」按鈕仍正常開 `FbPublishModal`
- [ ] `FbPublishModal` 內粉絲團 chip 仍能載入（用本頁新增的粉絲團）
- [ ] `campaign-publish-facebook` Edge Function 仍能正常 select access_token + 發文
- [ ] 既有的 `campaign_fb_posts` 紀錄沒受影響

---

## 5. 驗收門檻
全勾 + `apps/admin` tsc 過 + build 過 + migration apply 後 RPC 可叫成功 + dev server 啟動列表能載 + 新增/編輯/停用 各一筆能存。

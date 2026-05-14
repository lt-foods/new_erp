# 門市設定頁 `/stores`

**對應頁面：** `apps/admin/src/app/(protected)/stores/page.tsx`（新增）
**對應 RPC：** `rpc_upsert_store` (`supabase/migrations/20260425120000_core_crud_rpcs.sql:273`)
**對應 schema：** `stores` (`supabase/migrations/20260423120000_stores_order_schema.sql:13`)

**動機：** 樂樂 CSV 匯入會自動建 `LELE-{標籤}` store，加上原有手動建的 store，目前管理介面沒有列表頁
能瀏覽 / 編輯 / 停用，需要一個簡易設定頁。

---

## 0. 範圍

**v1（本次）**
- 列表：code / 名稱 / location 對應 / 取貨窗 / 付款方式 / 狀態
- 搜尋：code + name ilike
- 過濾：是否啟用、是否樂樂自動建 (`code LIKE 'LELE-%'`)
- inline 編輯：code、name、location_id、pickup_window_days、allowed_payment_methods、is_active、notes
- 新增

**v1 不做**
- LINE OA 設定（線下另行處理；`line_oa_*` 欄位有加密 BYTEA）
- 公休日 `off_days`（JSON 編輯器需要另設 UI）
- `notification_mode`（屬通知模組）
- supplier_id（AP 模組自動填）
- 刪除（用「停用」代替）

---

## 1. 列表行為

### 1.1 預設載入
- [ ] `/stores` 載入無 console error
- [ ] 預設只顯示 `is_active = TRUE`
- [ ] 排序：updated_at desc

### 1.2 搜尋
- [ ] 搜「松山」→ name 含松山 hit
- [ ] 搜「LELE-永和」→ code hit
- [ ] 250ms debounce

### 1.3 篩選
- [ ] 「全部 / 僅啟用」切換正常
- [ ] 「全部 / 僅樂樂自動建 / 排除樂樂自動建」三段切換

### 1.4 樂樂 chip
- [ ] `code LIKE 'LELE-%'` 顯示「樂樂自動建」amber chip
- [ ] 一般 store 不顯示 chip

### 1.5 分頁
- [ ] 多於 20 筆出現 pager
- [ ] 切頁切換正常

---

## 2. 編輯行為

### 2.1 新增
- [ ] 點「新增門市」→ 出現 inline 表單
- [ ] code、name 必填
- [ ] location 為 select（從 `locations WHERE type='store' AND is_active`）；可留空
- [ ] pickup_window_days 預設 5、min 1
- [ ] allowed_payment_methods 預設 `['cash']`，可 checkbox 勾 cash/credit_card/transfer/line_pay/wallet
- [ ] 儲存呼叫 `rpc_upsert_store(p_id=NULL,...)` 成功

### 2.2 編輯
- [ ] 點「編輯」→ inline 表單帶入既有值
- [ ] 修改 name、儲存後列表立即更新
- [ ] 取消不寫入

### 2.3 停用
- [ ] 編輯時取消「啟用」checkbox → 儲存 → `is_active=false`
- [ ] 篩「僅啟用」時不顯示

### 2.4 錯誤處理
- [ ] code 重複 → 紅字「已存在」（unique violation）
- [ ] 沒輸入必填 → HTML required 擋下

---

## 3. 權限

- [ ] 只 owner / admin / hq_manager 看得到（沿用 stores 表 RLS）
- [ ] sidebar 該連結放「設定」group（已是 admin-only）
- [ ] 分店帳號（branch user）看不到 sidebar 連結（加進 `BRANCH_HIDDEN_HREFS`）

---

## 4. Regression

- [ ] `/members` 列表的「取貨店」select 不受影響（用同 stores 表）
- [ ] `/campaigns/order-entry` 的店家 dropdown 不變
- [ ] 樂樂 CSV `/members/import` 仍能自動建 store
- [ ] HQ Inbox 載入 stores 不變

---

## 5. 驗收門檻
全勾 + dev server 啟動 + preview 列表能載 + 編輯一筆能存 + 新增一筆能存。

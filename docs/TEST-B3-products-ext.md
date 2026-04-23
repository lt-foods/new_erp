# B3 測試項目 — 擴 products schema（樂樂對齊）

**對應 migration:** `supabase/migrations/20260424140000_products_ext.sql`
**對應 UI 變更:** `apps/admin/src/components/ProductForm.tsx`, `apps/admin/src/app/(protected)/products/edit/page.tsx`

## 1. Schema / Migration 層

### 1.1 enum type 建立
- [ ] `product_storage_type` enum 有 4 值：`room_temp` / `refrigerated` / `frozen` / `meal_train`
- [ ] `product_sale_mode` enum 有 3 值：`preorder` / `in_stock_only` / `limited`

**驗證 SQL：**
```sql
SELECT t.typname, e.enumlabel
  FROM pg_type t JOIN pg_enum e ON t.oid = e.enumtypid
 WHERE t.typname IN ('product_storage_type','product_sale_mode')
 ORDER BY t.typname, e.enumsortorder;
```

### 1.2 products 新欄位
- [ ] 11 個新欄位都存在（`\d products` 能看到）
- [ ] `stop_shipping` DEFAULT FALSE、NOT NULL
- [ ] `is_for_shop` DEFAULT TRUE、NOT NULL
- [ ] `sale_mode` DEFAULT 'preorder'、NOT NULL
- [ ] `vip_level_min` DEFAULT 0、NOT NULL、CHECK 0-10
- [ ] `default_supplier_id` FK → suppliers(id)
- [ ] `customized_text` CHECK ≤ 7 字
- [ ] `count_for_start_sale` CHECK ≥ 0

**驗證 SQL：**
```sql
SELECT column_name, data_type, is_nullable, column_default
  FROM information_schema.columns
 WHERE table_name = 'products'
   AND column_name IN ('storage_type','customized_id','customized_text','storage_location',
                       'default_supplier_id','count_for_start_sale','limit_time','user_note',
                       'user_note_public','stop_shipping','is_for_shop','sale_mode','vip_level_min');
```

### 1.3 Indexes
- [ ] `idx_products_default_supplier` 存在（partial, WHERE default_supplier_id IS NOT NULL）
- [ ] `idx_products_limit_time` 存在（partial, WHERE limit_time IS NOT NULL）

### 1.4 RPC signature
- [ ] 舊 10-arg `rpc_upsert_product` 已被 drop
- [ ] 新 23-arg `rpc_upsert_product` 存在、authenticated 可 EXECUTE

## 2. RPC 行為（SQL 直測）

### 2.1 INSERT — 全欄位填滿
**情境：** 建立一個 preorder 團購品，有成團數 + 收單時間 + 預設供應商

**驗證：** 插入後 SELECT，所有 13 個新欄位值正確儲存；audit log 有 `create` 記錄。

### 2.2 INSERT — 只填必填（defaults 生效）
**情境：** 只傳 code/name，其他 NULL。

**預期：**
- `stop_shipping = FALSE`
- `is_for_shop = TRUE`
- `sale_mode = 'preorder'`
- `vip_level_min = 0`
- 其他可為 NULL 的欄位 = NULL

### 2.3 UPDATE — 改數個欄位
**情境：** 把成團數從 10 改 20，收單時間延後 1 天。

**驗證：** 欄位更新 + audit log 有 `update` + before/after diff。

### 2.4 Cross-tenant supplier 拒絕
**情境：** `p_default_supplier_id` 指向別 tenant 的 supplier。

**預期：** RAISE EXCEPTION `supplier % not in tenant`。

### 2.5 customized_text 超過 7 字被擋
**情境：** 傳入 8 字中文。

**預期：** CHECK constraint 擋下（或 UI 先擋）。

### 2.6 vip_level_min 超過範圍被擋
**情境：** 傳 -1 或 11。

**預期：** CHECK constraint 擋下。

### 2.7 storage_type 傳錯字被擋
**情境：** 傳 `"cold"` 不是 enum 值。

**預期：** enum cast 失敗。

## 3. UI 行為（preview 互動）

### 3.1 新增商品頁載入
- [ ] `/products/new` 能開、無 console error
- [ ] 主要區看得到：商品編號、狀態、名稱、簡稱、品牌、分類、**儲存溫層**、**銷售模式**、**預設供應商**、**成團數**、**收單時間**、**上架個人賣場 / 暫停出貨** checkbox、描述、圖片
- [ ] 「進階設定」折疊段預設收合
- [ ] 展開進階可見：客製編號、客製文字、存放位置、VIP 等級、內部備註、公開備註
- [ ] Supplier dropdown 能載入 options（is_active = true 的 suppliers）

### 3.2 新增送出 — 最簡
- [ ] 填 code/name/status，其他空白，按「建立」
- [ ] 成功跳轉 `/products/edit?id=X&saved=1`
- [ ] 資料庫該筆 `sale_mode = 'preorder'`、`is_for_shop = TRUE`、`stop_shipping = FALSE`

### 3.3 新增送出 — 團購品
- [ ] 填 `storage_type = 冷藏`、`sale_mode = 預購`、成團數 = 20、收單時間 = 明天
- [ ] 成功儲存、值正確

### 3.4 編輯頁載入
- [ ] `/products/edit?id=X` 能載回所有新欄位（特別是 `limit_time` datetime-local format 正確）
- [ ] 進階欄位若有值 → 進階段會保留收合但資料在裡面

### 3.5 客製文字 > 7 字 UI 擋
- [ ] 輸入框 maxLength=7 擋住
- [ ] 若被 bypass（paste 超過），送出時 setError「客製文字最多 7 字」

### 3.6 VIP 等級 clamp
- [ ] 輸入 15 會被 clamp 成 10
- [ ] 輸入 -5 會被 clamp 成 0

### 3.7 checkbox 互動
- [ ] 勾 / 取消勾「暫停出貨」、「上架個人賣場」後送出，DB 值一致

## 4. Regression

### 4.1 既有商品（無新欄位值）
- [ ] 在 migration apply 後，既有 product 讀回 UI 不會 crash（新欄位以 default / null 呈現）

### 4.2 列表頁不受影響
- [ ] `/products` 列表仍可載入 / 篩選 / 排序 / 分頁（本次沒改列表 SELECT，不應受影響）

### 4.3 SKU section 不受影響
- [ ] 編輯頁底的 `ProductSkuSection` 仍能列 / 編 SKU

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功**、**build + type-check 過** 才可標 done。

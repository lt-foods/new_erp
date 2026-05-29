# DEPLOY — 資料截斷修復線上 SQL 部署清單

> **用途**：列出本分支（`claude/data-api-rate-limits-Yq8Io` / PR #354）所有需要在 production / 其他環境**手動執行**的 SQL（trigger、function、RPC、view、migration），方便手動跑。
> **建立日期**：2026-05-23
> **適用範圍**：本次資料截斷修復涉及的所有 SQL 變更。新增其他修復後請補進來。
>
> ⚠️ **dev 環境（erp-dev）已透過 Management API 全部套用過了，這份是給 production / 其他 DB 用的。**

---

## 0. 部署順序（重要）

**請依下方 §1 → §2 順序執行**。兩個 RPC 互相獨立，但 §1 是會員端團詳情頁、§2 是商店首頁，跑反順序也不會壞，只是某個頁面 LIFF 部署後會先看到錯誤。

跑完 SQL 後再 deploy Edge Function（`supabase functions deploy liff-api`）。

---

## 1. RPC: `rpc_member_campaign_detail`（修 #11 #12）

**檔案**：`supabase/migrations/20260628100010_rpc_member_campaign_detail.sql`

**修了什麼**：會員端團詳情頁的 `ordered_qty`（已售出數量）原本透過 PostgREST 撈 `customer_order_items` 再前端 sum，大團 >1000 訂單行時靜默截斷，**會員可能下到超賣的單**。改成 SQL 端聚合、JSONB 單列回傳，繞過 PostgREST max_rows=1000。

**SQL（直接複製貼到 Supabase Studio → SQL Editor 跑）**：

```sql
CREATE OR REPLACE FUNCTION public.rpc_member_campaign_detail(
  p_tenant      UUID,
  p_campaign_id BIGINT
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH
  c AS (
    SELECT
      gbc.id,
      gbc.campaign_no,
      gbc.name,
      gbc.description,
      gbc.cover_image_url,
      gbc.status,
      gbc.end_at,
      gbc.pickup_deadline
    FROM group_buy_campaigns gbc
    WHERE gbc.tenant_id = p_tenant
      AND gbc.id = p_campaign_id
  ),
  items AS (
    SELECT
      ci.id,
      ci.unit_price,
      ci.cap_qty,
      ci.sort_order,
      sku.id           AS sku_id,
      sku.sku_code     AS sku_code,
      sku.product_name AS sku_product_name,
      sku.variant_name AS sku_variant_name,
      p.name           AS product_name,
      p.images         AS product_images
    FROM campaign_items ci
    JOIN skus sku ON sku.id = ci.sku_id
    LEFT JOIN products p ON p.id = sku.product_id
    WHERE ci.tenant_id = p_tenant
      AND ci.campaign_id = p_campaign_id
  ),
  order_count AS (
    SELECT COUNT(*)::bigint AS n
    FROM customer_orders co
    WHERE co.tenant_id = p_tenant
      AND co.campaign_id = p_campaign_id
      AND co.status NOT IN ('cancelled', 'expired')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
  ),
  ordered_qty_per_item AS (
    SELECT
      coi.campaign_item_id,
      SUM(coi.qty)::numeric AS total_qty
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    WHERE coi.tenant_id = p_tenant
      AND co.campaign_id = p_campaign_id
      AND co.status NOT IN ('cancelled', 'expired')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
    GROUP BY coi.campaign_item_id
  )
  SELECT jsonb_build_object(
    'campaign', (
      SELECT to_jsonb(c) || jsonb_build_object(
        'order_count', (SELECT n FROM order_count)
      )
      FROM c
    ),
    'items', COALESCE((
      SELECT jsonb_agg(
        to_jsonb(items) || jsonb_build_object(
          'ordered_qty', COALESCE(oq.total_qty, 0)
        )
        ORDER BY items.sort_order ASC, items.id ASC
      )
      FROM items
      LEFT JOIN ordered_qty_per_item oq ON oq.campaign_item_id = items.id
    ), '[]'::jsonb)
  )
  FROM c;
$$;

COMMENT ON FUNCTION public.rpc_member_campaign_detail(UUID, BIGINT) IS
  '@money-critical 會員端團詳情聚合 RPC,JSONB 單列回傳避免 PostgREST 1000 列截斷。修改前請閱讀 docs/STANDARD-資料分頁與筆數限制.md';

GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_detail(UUID, BIGINT)
  TO anon, authenticated, service_role;
```

**驗證（跑完後執行確認）**：

```sql
-- 應該回傳一列,proname = rpc_member_campaign_detail,result type = jsonb
SELECT proname, pg_get_function_result(oid)
FROM pg_proc
WHERE proname = 'rpc_member_campaign_detail';
```

預期：
```
proname                       | pg_get_function_result
------------------------------+-----------------------
rpc_member_campaign_detail    | jsonb
```

---

## 2. RPC: `rpc_member_campaign_aggregates`（修 #13 #14）

**檔案**：`supabase/migrations/20260628100020_rpc_member_campaign_aggregates.sql`

**修了什麼**：會員端商店首頁的 `ordered_qty`（「已售出 N 份」徽章）與「最熱銷」排序，原本透過 `customer_orders` + 前端 reduce 計算，>1000 訂單時被截斷，**也是超賣風險來源**。同一個 RPC 取代了舊的 `rpc_member_campaign_order_counts`（那個是 RETURNS TABLE，會被 1000 列截斷）。

**SQL**：

```sql
CREATE OR REPLACE FUNCTION public.rpc_member_campaign_aggregates(
  p_tenant      UUID,
  p_recent_days INT DEFAULT 7
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH
  filtered_orders AS (
    SELECT co.id, co.campaign_id, co.created_at
    FROM customer_orders co
    WHERE co.tenant_id = p_tenant
      AND co.status NOT IN ('cancelled', 'expired')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
  ),
  counts AS (
    SELECT
      fo.campaign_id,
      COUNT(*)::bigint AS order_count,
      COUNT(*) FILTER (
        WHERE fo.created_at >= now() - make_interval(days => GREATEST(p_recent_days, 0))
      )::bigint AS recent_order_count
    FROM filtered_orders fo
    GROUP BY fo.campaign_id
  ),
  qtys AS (
    SELECT
      fo.campaign_id,
      SUM(coi.qty)::numeric AS ordered_qty
    FROM filtered_orders fo
    JOIN customer_order_items coi ON coi.order_id = fo.id
    GROUP BY fo.campaign_id
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'campaign_id',         c.campaign_id,
        'order_count',         c.order_count,
        'recent_order_count',  c.recent_order_count,
        'ordered_qty',         COALESCE(q.ordered_qty, 0)
      )
    ),
    '[]'::jsonb
  )
  FROM counts c
  LEFT JOIN qtys q ON q.campaign_id = c.campaign_id;
$$;

COMMENT ON FUNCTION public.rpc_member_campaign_aggregates(UUID, INT) IS
  '@money-critical 會員端商店首頁聚合 RPC,JSONB 單列回傳避免 PostgREST 1000 列截斷。修改前請閱讀 docs/STANDARD-資料分頁與筆數限制.md';

GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_aggregates(UUID, INT)
  TO anon, authenticated, service_role;
```

**驗證**：

```sql
SELECT proname, pg_get_function_result(oid)
FROM pg_proc
WHERE proname = 'rpc_member_campaign_aggregates';
```

預期：
```
rpc_member_campaign_aggregates | jsonb
```

也可以實際呼叫看看（替換 `<tenant_uuid>` 為一個現有 tenant）：

```sql
SELECT rpc_member_campaign_aggregates('<tenant_uuid>'::uuid, 7);
```

應該回 JSONB array，每個 campaign 一個 object。

---

## 3. RPC: `rpc_list_staff`（修 #15）

**檔案**：`supabase/migrations/20260628100030_rpc_list_staff_jsonb.sql`

**修了什麼**：原 `rpc_list_staff` 是 `RETURNS TABLE`，受 PostgREST 1000 列上限，員工數 >1000 時管理頁顯示不完整。改成 `RETURNS jsonb` 單列回 `jsonb_agg array`。
前端 `apps/admin/src/app/(protected)/staff/page.tsx` 已更新讀 array。

**SQL**：

```sql
DROP FUNCTION IF EXISTS public.rpc_list_staff();

CREATE OR REPLACE FUNCTION public.rpc_list_staff()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_result jsonb;
BEGIN
  IF NOT public._caller_can_manage_staff() THEN
    RAISE EXCEPTION 'permission denied: requires owner/admin role';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'user_id',         u.id,
      'email',           u.email::text,
      'display_name',    COALESCE(u.raw_user_meta_data ->> 'display_name', u.raw_user_meta_data ->> 'name'),
      'role',            COALESCE(u.raw_app_meta_data ->> 'role', ''),
      'stores',          COALESCE(u.raw_app_meta_data -> 'stores', '[]'::jsonb),
      'disabled',        (COALESCE(u.raw_app_meta_data ->> 'role', '') = 'disabled'),
      'created_at',      u.created_at,
      'last_sign_in_at', u.last_sign_in_at
    )
    ORDER BY
      CASE COALESCE(u.raw_app_meta_data ->> 'role', '')
        WHEN 'owner' THEN 1
        WHEN 'admin' THEN 2
        WHEN 'hq_manager' THEN 3
        WHEN 'hq_accountant' THEN 4
        WHEN 'purchaser' THEN 5
        WHEN 'assistant' THEN 6
        WHEN 'store_manager' THEN 7
        WHEN 'store_staff' THEN 8
        WHEN 'disabled' THEN 99
        ELSE 50
      END,
      u.email
  ), '[]'::jsonb)
  INTO v_result
  FROM auth.users u
  WHERE (u.raw_app_meta_data ->> 'tenant_id')::uuid = v_tenant;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_staff() TO authenticated;

COMMENT ON FUNCTION public.rpc_list_staff() IS
  'RETURNS jsonb 單列,避免 PostgREST max_rows=1000 截斷。詳見 docs/STANDARD-資料分頁與筆數限制.md';
```

**驗證**：

```sql
SELECT proname, pg_get_function_result(oid)
FROM pg_proc
WHERE proname = 'rpc_list_staff';
-- 預期: rpc_list_staff | jsonb
```

---

## 4. VIEW COMMENT: `v_hq_inbox`（修 #16）

**檔案**：`supabase/migrations/20260628100040_comment_v_hq_inbox.sql`

**修了什麼**：給 view 加上警示 COMMENT，避免未來開發者直接從前端 `sb.from("v_hq_inbox")` 查詢被 1000 列截斷。目前已 grep 確認無 caller 直接從此 view 查詢；正確路徑是 `rpc_hq_inbox_keys`（內建分頁）。

**SQL**：

```sql
COMMENT ON VIEW public.v_hq_inbox IS
  '⚠️ 請勿直接透過 PostgREST 查詢此 view (會被 max_rows=1000 截斷)。改用 rpc_hq_inbox_keys() (內建分頁)。詳見 docs/STANDARD-資料分頁與筆數限制.md';
```

**驗證**：

```sql
SELECT obj_description('public.v_hq_inbox'::regclass);
-- 預期: 顯示上述 COMMENT
```

---

## 4b. RPC: `rpc_member_overview_totals`（修 #27，re-audit 新增）

**檔案**：`supabase/migrations/20260629000010_rpc_member_overview_totals.sql`

**修了什麼**：會員首頁「未結金額」原本後端裸查 `v_customer_order_summary` + `.reduce()` 加總,>1000 筆 unpaid 訂單會截斷偏低。改 JSONB 單列 SQL 聚合。`getOverview` 已改呼叫此 RPC。

**SQL**：

```sql
CREATE OR REPLACE FUNCTION public.rpc_member_overview_totals(
  p_tenant     UUID,
  p_member_id  BIGINT
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'receivable_amount', COALESCE((
      SELECT SUM(s.payable_amount)
      FROM v_customer_order_summary s
      WHERE s.tenant_id = p_tenant
        AND s.member_id = p_member_id
        AND s.payment_status = 'unpaid'
        AND s.status NOT IN ('cancelled', 'expired')
    ), 0),
    'active_orders_count', COALESCE((
      SELECT COUNT(*)
      FROM v_customer_order_summary s
      WHERE s.tenant_id = p_tenant
        AND s.member_id = p_member_id
        AND s.status NOT IN ('completed', 'cancelled', 'expired')
    ), 0)
  );
$$;

COMMENT ON FUNCTION public.rpc_member_overview_totals(UUID, BIGINT) IS
  '@money-critical 會員未結金額/進行中筆數聚合,JSONB 單列避免 max_rows 截斷。詳見 docs/STANDARD-資料分頁與筆數限制.md';

GRANT EXECUTE ON FUNCTION public.rpc_member_overview_totals(UUID, BIGINT)
  TO anon, authenticated, service_role;
```

**驗證**：

```sql
SELECT proname, pg_get_function_result(oid) FROM pg_proc WHERE proname = 'rpc_member_overview_totals';
-- 預期: rpc_member_overview_totals | jsonb
```

---

## 4c. RPC: `rpc_get_members_to_notify_for_transfer`（修 #28，re-audit 新增）

**檔案**：`supabase/migrations/20260629000020_rpc_members_for_transfer_jsonb.sql`

**修了什麼**：調撥收貨推播 fan-out 原 `RETURNS TABLE`,大調撥覆蓋 >1000 訂單列時截斷漏發通知。改 `RETURNS jsonb`（DROP+CREATE）。前端 TransferReceiveModal 零改動。

**SQL**：

```sql
DROP FUNCTION IF EXISTS rpc_get_members_to_notify_for_transfer(BIGINT);

CREATE OR REPLACE FUNCTION rpc_get_members_to_notify_for_transfer(
  p_transfer_id BIGINT
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH dest AS (
    SELECT t.dest_location, t.tenant_id, s.id AS store_id
      FROM transfers t
      LEFT JOIN stores s ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
     WHERE t.id = p_transfer_id
  ),
  skus AS (
    SELECT DISTINCT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id
  ),
  rows AS (
    SELECT DISTINCT co.member_id, co.id AS order_id, co.order_no
      FROM customer_orders co
      JOIN dest d
        ON d.store_id = co.pickup_store_id
       AND d.tenant_id = co.tenant_id
      JOIN customer_order_items coi
        ON coi.order_id = co.id
     WHERE coi.sku_id IN (SELECT sku_id FROM skus)
       AND co.member_id IS NOT NULL
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out', 'completed')
       AND COALESCE(co.order_kind, 'normal') = 'normal'
  )
  SELECT COALESCE(
    jsonb_agg(jsonb_build_object(
      'member_id', r.member_id,
      'order_id',  r.order_id,
      'order_no',  r.order_no
    )),
    '[]'::jsonb
  )
  FROM rows r;
$$;

GRANT EXECUTE ON FUNCTION rpc_get_members_to_notify_for_transfer(BIGINT) TO authenticated;
```

**驗證**：

```sql
SELECT proname, pg_get_function_result(oid) FROM pg_proc WHERE proname = 'rpc_get_members_to_notify_for_transfer';
-- 預期: rpc_get_members_to_notify_for_transfer | jsonb
```

---

## 5. 不需要動 SQL 的修復項目

下列風險的修復完全在 Edge Function / 前端側（用 `fetchAllPaginated` helper 或 cursor 分頁），**不需要任何 SQL 變更**：

| AUDIT # | 內容 |
|---|---|
| #1 | OrderAuditDrawer cursor 翻頁 |
| #2 #3 | HQ Inbox / Exception 缺貨彙整 fetchAllPaginated |
| #4 | picking_waves 計數 fetchAllPaginated |
| #5 #6 #24 | WMS 揀貨 / 列印 / picking demand views fetchAllPaginated |
| #7 | reorder_rules 補貨規則 fetchAllPaginated |
| #8 #9 #10 | 會員端訂單 / 結算 / 通知 cursor 分頁 |
| #14 主查詢 | listActiveCampaigns server-side range loop |
| #17 | 庫存移動史 fetchAllPaginated |
| #18 #19 | 會員 points / wallet ledger fetchAllPaginated |
| #20 #21 #22 #23 | 各種無 limit `.in()` 查詢 fetchAllPaginated |

等 LIFF / admin app deploy 完就會生效。

---

## 6. 部署 checklist

線上跑 SQL（依序執行）：
- [ ] §1 `rpc_member_campaign_detail` 已跑、驗證查詢回 `jsonb`
- [ ] §2 `rpc_member_campaign_aggregates` 已跑、驗證查詢回 `jsonb`
- [ ] §3 `rpc_list_staff` 已跑、驗證查詢回 `jsonb`
- [ ] §4 `v_hq_inbox` COMMENT 已加
- [ ] §4b `rpc_member_overview_totals` 已跑、驗證查詢回 `jsonb`（re-audit #27）
- [ ] §4c `rpc_get_members_to_notify_for_transfer` 已跑、驗證查詢回 `jsonb`（re-audit #28）

部署 Edge Function：
- [ ] `supabase functions deploy liff-api --project-ref <production_ref>`

部署前端（admin + 會員端 LIFF）：
- [ ] vercel / 你們的部署流程觸發

LIFF 實機驗證：
- [ ] 商店首頁：「已售出 N 份」徽章正常
- [ ] 團詳情：商品列表完整、`ordered_qty` 與後台一致
- [ ] 我的訂單 → 訂單紀錄：超過 30 筆出現「載入更多」並能載入舊單
- [ ] 我的結單 → 已寄出：同上
- [ ] 通知：超過 30 則出現「載入更多」

Admin 實機驗證：
- [ ] 員工管理頁：員工列表完整顯示（即使 >1000 名）
- [ ] HQ inbox：缺貨/補貨/調撥計數正確
- [ ] WMS 揀貨頁：派工內容完整（不漏 SKU）
- [ ] 揀貨單列印：完整列出所有 PO/SKU
- [ ] 庫存頁面：低庫存掃描不限於 2000 SKU
- [ ] 會員 detail：點數/儲值流水完整顯示
- [ ] 訂單頁搜尋：搜尋會員名稱命中 >300 也能查到訂單

---

## 7. 舊的 RPC 處理

`rpc_member_campaign_order_counts`（migration `20260616000010_*.sql`）**還留在 DB**，但 Edge Function 已經不再呼叫。

- **不必刪除**：刪除是破壞性動作，留著沒成本（只是不再被用）。
- **未來清理建議**：確認 90 天內沒有其他 caller 後再 `DROP FUNCTION`。
- **絕對不要**把舊 RPC 改寫成跟新的一樣 — 這會踩到 STANDARD §3 B5 的雷（caller 預期 SETOF）。

---

## 8. 回滾

如果 LIFF 部署後發現問題：

1. **前端與 Edge Function** 直接回滾到上一個 commit（PR 合併前的 main）。
2. **SQL 不必回滾** — 新 RPC 沒人呼叫就只是個無害的函數定義躺在那。
3. 真要清，跑：
   ```sql
   DROP FUNCTION IF EXISTS public.rpc_member_campaign_detail(UUID, BIGINT);
   DROP FUNCTION IF EXISTS public.rpc_member_campaign_aggregates(UUID, INT);
   ```
4. 若需回滾 `rpc_list_staff`，重新跑舊版 SQL（檔案 `supabase/migrations/20260613000150_staff_permissions.sql` §2）即可。
5. `v_hq_inbox` 的 COMMENT 純註解，無回滾必要；要清空可：
   ```sql
   COMMENT ON VIEW public.v_hq_inbox IS NULL;
   ```

---

## 9. 未來新增「線上要跑的 SQL」時的規矩

每次再有需要手動跑的 trigger / function / RPC / view，請在本檔末尾新增一節（依編號或日期），格式：

```
## N. <類型>: <名稱>（修 <AUDIT 編號>）
**檔案**：<migration 路徑>
**修了什麼**：一段話
**SQL**：```sql ... ```
**驗證**：```sql ... ```
```

確保任何接手的人（或未來的自己）都能單看這份文件 + commit 連結就完成部署。

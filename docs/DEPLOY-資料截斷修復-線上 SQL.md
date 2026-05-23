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

## 3. 不需要動 SQL 的 #8 / #9

#8 / #9（訂單/結算歷史 cursor 分頁）**只動 Edge Function 與前端**，沒有 SQL 變更。等 LIFF deploy 完就會生效。

---

## 4. 部署 checklist

線上跑 SQL：
- [ ] §1 `rpc_member_campaign_detail` 已跑、驗證查詢回 `jsonb`
- [ ] §2 `rpc_member_campaign_aggregates` 已跑、驗證查詢回 `jsonb`

部署 Edge Function（任一機器有 supabase CLI + 對應 access token）：
- [ ] `supabase functions deploy liff-api --project-ref <production_ref>`

部署前端（會員端 LIFF）：
- [ ] vercel / 你們的部署流程觸發

最後在 LIFF 實機驗證：
- [ ] 開團列表（商店首頁）：「已售出 N 份」徽章正常顯示
- [ ] 點進某團：商品列表完整、`ordered_qty` 顯示與後台一致
- [ ] 我的訂單 → 訂單紀錄：超過 30 筆會出現「載入更多」按鈕，按下去能載入舊單
- [ ] 我的結單 → 已寄出：同上「載入更多」生效

---

## 5. 舊的 RPC 處理

`rpc_member_campaign_order_counts`（migration `20260616000010_*.sql`）**還留在 DB**，但 Edge Function 已經不再呼叫。

- **不必刪除**：刪除是破壞性動作，留著沒成本（只是不再被用）。
- **未來清理建議**：確認 90 天內沒有其他 caller 後再 `DROP FUNCTION`。
- **絕對不要**把舊 RPC 改寫成跟新的一樣 — 這會踩到 STANDARD §3 B5 的雷（caller 預期 SETOF）。

---

## 6. 回滾

如果 LIFF 部署後發現問題：

1. **前端與 Edge Function** 直接回滾到上一個 commit（PR 合併前的 main）。
2. **SQL 不必回滾** — 新 RPC 沒人呼叫就只是個無害的函數定義躺在那。
3. 真要清，跑：
   ```sql
   DROP FUNCTION IF EXISTS public.rpc_member_campaign_detail(UUID, BIGINT);
   DROP FUNCTION IF EXISTS public.rpc_member_campaign_aggregates(UUID, INT);
   ```

---

## 7. 未來新增「線上要跑的 SQL」時的規矩

每次再有需要手動跑的 trigger / function / RPC / view，請在本檔末尾新增一節（依編號或日期），格式：

```
## N. <類型>: <名稱>（修 <AUDIT 編號>）
**檔案**：<migration 路徑>
**修了什麼**：一段話
**SQL**：```sql ... ```
**驗證**：```sql ... ```
```

確保任何接手的人（或未來的自己）都能單看這份文件 + commit 連結就完成部署。

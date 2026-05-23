# STANDARD — 資料分頁與筆數限制（防止靜默截斷）

> **文件性質**：強制規範。所有新增或修改資料讀取邏輯前必讀。
> **適用範圍**：admin app、member app（LIFF）、`supabase/functions/**`、所有 SQL view / RPC。
> **建立日期**：2026-05-23
> **負責人**：每次 PR Reviewer 都需確認本規範被遵守。

---

## 0. TL;DR — 三條鐵則

1. **任何回傳「列表」的 API/RPC，如果使用者預期會看到全部，必須採用以下其中一種模式**：
   - `cursor 分頁 + load more`（如 `list_wallet_ledger`）
   - `JSONB 單列包裝`（如 `rpc_orders_pivot` v3）
   - `server-side .range() 迴圈`（僅限後端聚合 / 匯出）
2. **訂單數量、金額、庫存數量、點數金額、錢包餘額、結算金額** 這六類欄位的聚合：
   - **絕對禁止**直接在前端從 `.select()` 結果 reduce／sum／count。
   - **必須**在 SQL 端完成聚合並以 **JSONB 單列**或**已驗證的分頁協議**回傳。
3. **新建 view 或 RPC**：明確標註是否會被 PostgREST 直連，若會，必須在 SQL 註解寫明「呼叫端必須分頁」或內建分頁參數。

---

## 1. 為什麼這份文件存在

### 1.1 根因：PostgREST `max_rows = 1000`

本專案 `supabase/config.toml:18` 設定 `max_rows = 1000`。

這代表：
- 任何透過 `supabase-js` 的 `.from(...).select(...)` 查詢、view 查詢、`.rpc(...)` 回傳 `SETOF` / `RETURNS TABLE` 的 RPC，**只要沒有顯式 `.range()` 或 `.limit()` 限制**，**回傳上限就是 1000 筆**。
- **不會報錯**、**不會 warning**。資料就是少了。
- `data.length` 可能剛好等於 1000，看起來像「正常結果」，但其實第 1001~N 筆已被吃掉。

### 1.2 已知踩雷史（節錄，完整清單見 `AUDIT-資料截斷風險清單-*.md`）

- LIFF 商品列表 `list_active_campaigns` 曾用 `.limit(50)`，導致開團數 >50 時最晚結單的整批團在顧客端消失。
- `rpc_orders_pivot` v2 使用 `SETOF`，回傳行數超過 1000 時前端統計表整列遺失，後改為 v3（JSONB 單列）。
- 多處 `v_picking_demand_*` view 沒有分頁，前端列印揀貨單時 >1000 行靜默漏項，倉儲漏揀貨。

### 1.3 為什麼「訂單數量、金額」格外嚴格

- 一筆漏算 = 帳對不上 = 對使用者的承諾失準。
- 截斷在生產初期看不出來（資料量小），等業務成長後才爆，**爆炸時很難回溯哪幾天少算了什麼**。
- 這類欄位通常會被印報表、發給門市、做業績核算，錯一個數字就是信任崩壞。

---

## 2. 「列表」的三種正確寫法

依使用情境選一種。**不可混用、不可發明第四種，除非經 review 同意並補進本文件。**

### 2.1 模式 A：Cursor 分頁 + Load More（互動式列表的標準寫法）

**適用**：使用者會「往下捲動繼續看」的列表，例如：訂單歷史、通知、錢包流水、稽核日誌、庫存移動紀錄。

**範本（後端 / Edge Function）**：

```ts
// supabase/functions/liff-api/index.ts — listWalletLedger 為標準範本
const limit = Math.min(Math.max(Number(body.limit ?? 30), 1), 100);
const beforeId = body.before_id ? Number(body.before_id) : null;
let q = sb.from("wallet_ledger")
  .select("...")
  .eq("tenant_id", tenantId)
  .eq("member_id", memberId)
  .order("id", { ascending: false })
  .limit(limit);
if (beforeId) q = q.lt("id", beforeId);
const { data, error } = await q;
return json({
  ledger: data ?? [],
  has_more: (data?.length ?? 0) === limit,  // ← 必須回 has_more
  next_cursor: data?.length ? data[data.length - 1].id : null,
});
```

**範本（前端 React）**：

```tsx
// apps/member/src/app/wallet/page.tsx 為標準範本
const [items, setItems] = useState([]);
const [cursor, setCursor] = useState<number | null>(null);
const [hasMore, setHasMore] = useState(true);

async function loadMore() {
  const res = await api.listWalletLedger({ before_id: cursor, limit: 30 });
  setItems(prev => [...prev, ...res.ledger]);
  setCursor(res.next_cursor);
  setHasMore(res.has_more);
}
```

**關鍵不變式**：
- 必須 `ORDER BY` 一個**唯一遞減**欄位（通常是 PK `id` 或 `created_at` + tiebreaker）。
- `has_more` 由「本次回傳筆數是否等於 limit」決定，**不可**用 count query 估算（不一致風險）。
- 前端**必須有**「載入更多」UI 或 infinite scroll，**不可**只 fetch 第一頁就 render「全部」。

### 2.2 模式 B：JSONB 單列包裝（聚合、報表、需要一次拿完的場景）

**適用**：需要一次拿到全部資料做計算或 render，分頁無意義的場景。例如：
- 團詳情頁需要顯示每個 SKU 的 `已訂數量` → 必須聚合所有 customer_order_items。
- 訂單樞紐表（cross-tab）。
- 後台儀表板的 KPI 卡片。

**範本（SQL）**：

```sql
-- 仿 rpc_orders_pivot v3 的寫法
CREATE OR REPLACE FUNCTION rpc_campaign_detail_with_counts(
  p_tenant uuid,
  p_campaign_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'campaign', (SELECT row_to_json(c) FROM campaigns c WHERE c.id = p_campaign_id),
    'items', (
      SELECT jsonb_agg(row_to_json(ci) ORDER BY ci.sort_order)
      FROM campaign_items ci
      WHERE ci.campaign_id = p_campaign_id AND ci.tenant_id = p_tenant
    ),
    'ordered_qty_by_item', (
      SELECT jsonb_object_agg(coi.campaign_item_id::text, SUM(coi.qty))
      FROM customer_order_items coi
      INNER JOIN customer_orders co ON co.id = coi.order_id
      WHERE co.campaign_id = p_campaign_id
        AND co.tenant_id = p_tenant
        AND co.status NOT IN ('cancelled', 'expired')
        AND (co.order_kind IS NULL OR co.order_kind = 'normal')
      GROUP BY coi.campaign_item_id
    )
  ) INTO v_result;
  RETURN v_result;
END;
$$;
```

**為什麼這樣寫**：
- `RETURNS jsonb` → PostgREST 看到的是 **1 列**，永遠不會被 `max_rows=1000` 截斷。
- 所有聚合在 SQL 完成，前端不用 reduce／sum，沒有「漏算」風險。
- 巨量資料（>10MB 回傳）才會撞 PostgREST body 上限，這是另一個層級的問題（屆時用 streaming 或拆 RPC）。

### 2.3 模式 C：Server-side `.range()` 迴圈（純後端聚合、匯出）

**適用**：
- Edge Function 內部需要全表掃描做聚合（不會回給前端原始資料）。
- 後端產生 CSV / Excel 匯出。
- Cron job、batch 計算。

**範本**：

```ts
async function fetchAll<T>(builderFn: (from: number, to: number) => any) {
  const PAGE = 1000;
  const all: T[] = [];
  let from = 0;
  while (true) {
    const { data, error } = await builderFn(from, from + PAGE - 1);
    if (error) throw error;
    if (!data?.length) break;
    all.push(...(data as T[]));
    if (data.length < PAGE) break;
    from += PAGE;
  }
  return all;
}

// 使用
const allShortages = await fetchAll<ShortageRow>(
  (from, to) => sb.from("v_order_shortage")
    .select("*")
    .eq("tenant_id", tenantId)
    .order("id", { ascending: true })
    .range(from, to)
);
```

**關鍵不變式**：
- 必須 `ORDER BY` **穩定欄位**，否則跨頁有重複或遺漏風險。
- **絕對不可在前端使用此模式**（會狂打網路、阻塞 UI、易掛）。
- 迴圈上限要有 safety（例如 100 頁 = 10 萬筆），超過要 log + alert。

---

## 3. 黑名單寫法（PR 直接拒絕）

| # | 寫法 | 為什麼錯 |
|---|---|---|
| B1 | `sb.from(table).select(...)` 無 `.range()` 也無 `.limit()` | 1000 列靜默截斷 |
| B2 | `sb.from(view).select(...)` 無分頁，且 view 可能 >1000 列 | 同上，且 view 通常更隱蔽 |
| B3 | `.limit(N)` 用於「給使用者看的列表」但前端沒有 load-more UI | 使用者看不到第 N+1 筆，且不知道有截斷 |
| B4 | 前端對 paginated 結果用 `.reduce` / `.length` 算總數、總額 | 算到的是「第一頁的合計」，不是真正的總額 |
| B5 | RPC `RETURNS TABLE` / `SETOF` 沒有分頁參數，又被前端直接 `.rpc()` 呼叫 | 同 B1 |
| B6 | 用 `count: 'exact'` 取總數，但拿同一查詢的 `data` 當完整列表 | count 是準的，但 data 仍可能被截 |
| B7 | `Promise.all([fetchOrders(), fetchItems()])` 然後在前端 join | 兩邊各自截斷 1000，join 後資料不一致 |

---

## 4. 訂單／數量／金額類 API 的強制要求

凡是回傳或計算以下任一欄位的 API、RPC、view，**必須遵守本節**：

> `qty`, `quantity`, `total_qty`, `ordered_qty`, `pick_qty`, `received_qty`, `shortage_qty`,
> `amount`, `total_amount`, `subtotal`, `unit_price`, `paid_amount`, `refund_amount`,
> `wallet_balance`, `points_balance`, `settlement_amount`, `invoice_amount`

### 4.1 強制條款

1. **聚合必須在 SQL 完成**。禁止「拉資料到前端再 sum」。
2. **必須用 模式 B（JSONB 單列）或 模式 C（後端 range 迴圈）**。模式 A 只能用於展示原始流水，**不可**用於計算總額。
3. **必須有截斷偵測**：若內部使用 `.range()` 或 `.limit(N)`，要 assert `回傳筆數 < limit`，否則 raise error / log warning。
4. **必須在 SQL 註解標註**：
   ```sql
   -- @money-critical: 本函數涉及金額計算，修改前請閱讀 docs/STANDARD-資料分頁與筆數限制.md §4
   ```
5. **必須在對應的 e2e 測試或 seed script 中**塞入 >1000 筆測試資料，驗證金額正確。

### 4.2 舉例（DO）

```sql
-- ✅ 結算金額：SQL 內聚合，回 JSONB 單列
CREATE FUNCTION rpc_member_settlement_summary(p_tenant uuid, p_member_id bigint)
RETURNS jsonb
AS $$
  SELECT jsonb_build_object(
    'total_amount', COALESCE(SUM(amount), 0),
    'order_count', COUNT(*),
    'last_settled_at', MAX(settled_at)
  )
  FROM settlements
  WHERE tenant_id = p_tenant AND member_id = p_member_id;
$$ LANGUAGE sql STABLE;
```

### 4.3 反例（DON'T）

```ts
// ❌ 前端從分頁列表 reduce 計算總額
const { data } = await sb.from("settlements")
  .select("amount")
  .eq("member_id", memberId);  // 1000 列截斷
const total = data.reduce((a, b) => a + b.amount, 0);  // 算出來的是前 1000 筆的合計

// ❌ 用 .limit(100) + 前端加總
.from("customer_orders").select("total_amount").limit(100);
// 超過 100 筆就漏算
```

---

## 5. 新建 view / RPC 的 checklist

提交 SQL migration 前，逐項確認：

- [ ] 這個 view / RPC **預期回傳幾列**？最壞情況呢？
- [ ] 如果最壞情況 >1000：是否設計成模式 B（JSONB）或內建分頁參數？
- [ ] 若是 view，是否在 `COMMENT ON VIEW` 寫明「呼叫端必須分頁」？
- [ ] 若涉及金額/數量，是否標註 `-- @money-critical`？
- [ ] 是否在 `scripts/audit-pagination/` 新增種子腳本驗證 >1000 筆情境？
- [ ] PR 描述是否說明這個 view/RPC 預期被誰、用哪種模式呼叫？

---

## 6. 前端讀取資料的 checklist

提交前端 PR 前，逐項確認：

- [ ] 我的 `.from(...).select(...)` 有沒有 `.range()` 或 `.limit()`？
- [ ] 如果有 `.limit(N)`，UI 上有沒有「載入更多」？沒有的話 N 是否真的足夠？
- [ ] 我有沒有把回傳結果當「全部資料」用 `.reduce` / `.length` / `Set` 計算？
- [ ] 我有沒有「截斷哨兵」：當 `data.length === limit` 時 log warning 或 UI 提示？
- [ ] 如果是金額/數量類，我有沒有改走 RPC 讓 SQL 端聚合？
- [ ] 對應的 `liff-api` 或 admin API 是不是已經回了 `has_more`？我有用嗎？

---

## 7. Code Review checklist（Reviewer 必看）

打開 PR 後，搜尋以下關鍵字並逐個檢視：

```
.from(           # 每個都看 — 有沒有 .range() / .limit()？
.select(         # 同上
.rpc(            # 對應的 SQL 函數是分頁的還是 JSONB 的？
.limit(          # 數字是寫死的嗎？UI 有沒有 load more？
.range(          # 有沒有迴圈？是否會撞天花板？
RETURN QUERY     # SQL 端：有沒有 LIMIT？呼叫端怎麼分頁？
RETURNS TABLE    # 同上
RETURNS SETOF    # 同上
```

對訂單/金額類 PR，**額外**詢問：「如果這個查詢有 5000 筆，會怎樣？」如果 PR 作者答不出來，**直接 request changes**。

---

## 8. 工具與輔助

### 8.1 截斷偵測 helper（建議新增）

```ts
// apps/admin/src/lib/supabase/assertNotTruncated.ts
export function assertNotTruncated<T>(
  data: T[] | null,
  context: string,
  maxRows = 1000
): T[] {
  const rows = data ?? [];
  if (rows.length >= maxRows) {
    console.error(`[PAGINATION-RISK] ${context} returned ${rows.length} rows, may be truncated`);
    if (typeof window !== 'undefined') {
      // 可選：在 dev 環境彈警告
    }
  }
  return rows;
}
```

### 8.2 種子腳本目錄

所有大量資料驗證腳本放在 `scripts/audit-pagination/`，命名為 `test-<風險編號>-<簡述>.{mjs,sh}`。每個腳本須：

1. 在測試 tenant 塞入 ≥1100 筆對應資料。
2. 呼叫實際 API / RPC。
3. assert 結果筆數正確、金額正確。
4. 結束前清理測試資料 **並 verify 真的清乾淨**（見下方陷阱）。

#### ⚠️ Cleanup 陷阱（已踩過）

部分 table 有禁止 DELETE 的 trigger（如 `skus` 的 `forbid_sku_delete()`，業務規則：只能設 `status=discontinued`）。當你用 Management API 一次送多段 DELETE，**任一段失敗就整個 transaction rollback**，看起來像清完了，其實 fixture 全部留下。

**正確寫法**（適用 Management API / postgres role）：

```sql
BEGIN;
SET LOCAL session_replication_role = 'replica';  -- 在此 transaction 內禁用 trigger
DELETE FROM customer_order_items WHERE ...;
DELETE FROM customer_orders WHERE ...;
DELETE FROM skus WHERE ...;                       -- 不會觸發 forbid_sku_delete
DELETE FROM products WHERE ...;
COMMIT;
```

**且 cleanup 後必須 verify**：

```bash
remain=$(run_sql "SELECT (SELECT COUNT(*) FROM customer_orders WHERE ...) + (...) AS n;")
if [ "$remain" != "0" ]; then
  echo "❌ cleanup 沒清乾淨,剩 ${remain} 筆"  # silent rollback 偵測
fi
```

範例：`scripts/audit-pagination/test-11-12-via-mgmt-api.sh` 的 cleanup() 函式。

---

## 9. 例外與豁免

凡需要「不依本規範」的設計，必須：

1. 在 SQL / TS 程式碼中明確註解理由。
2. 在 `AUDIT-資料截斷風險清單-*.md` 新增條目，狀態標記為「已豁免」並附理由。
3. PR 描述中 @ 一位資深 reviewer 確認豁免。

**有效豁免理由的範例**：
- 該 view 物理上不可能 >100 列（例如 enum 表）。
- 該欄位非業務關鍵，使用者只看最近 N 筆（並有清楚 UI 提示）。

**無效豁免理由**：
- 「現在資料還很少」← 半年後就爆。
- 「使用者應該不會看那麼多」← 系統不能依賴使用者行為。

---

## 10. 相關文件

- `AUDIT-資料截斷風險清單-2026-05-23.md` — 現況稽核全表。
- `FIX-LOG-資料截斷修復.md` — 修復進度紀錄。
- `supabase/config.toml` — PostgREST `max_rows` 設定位置。
- `supabase/functions/liff-api/index.ts` — `listWalletLedger` 是模式 A 的標準範本。
- `supabase/migrations/20260621000030_rpc_orders_pivot_jsonb.sql` — 模式 B 的標準範本。

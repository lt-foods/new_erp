---
title: TEST — UI fix: PostgREST 1000-row cap on /orders KPI + /campaigns list (Bug B)
module: UI / Orders / Campaigns
status: passed
ran_at: 2026-05-15
verified_by: alex.chen + claude (preview)
---

# Bug B: UI 受 PostgREST max-rows 1000 cap、大規模 query 算錯

## 症狀

| 頁面 | 修前 | 修後 |
|---|---|---|
| `/orders` KPI 本月營業額 | $128,564 | $1,921,040 |
| `/orders` KPI 本月訂單數 | 124 | 2,509 |
| `/campaigns` 列表特定 camp 件數 | 0 | 393 / 261 / 395 ... 真實值 |

DB 實際 ~15,000+ orders、~$8M 金額。UI 顯示 8-60 倍小、completely wrong。

## 根因

Supabase JS 預設用 PostgREST、`max-rows` 設定 1000 (Supabase Cloud default)。
任何 `.select()` 一次最多回 1000 rows、超出靜默截斷。

兩處 query 超過 1000：
1. `/orders` KPI fetch 用 `.limit(20000)` — 一樣被 server cap 1000
2. `/campaigns` list fetch `customer_orders.in('campaign_id', ids)` — 50 camps × 平均 200 orders = 10K、被 cap

## 修法

[apps/admin/src/app/(protected)/orders/page.tsx](../apps/admin/src/app/(protected)/orders/page.tsx) — KPI fetch 改 range pagination loop:

```ts
const orders = [];
const PAGE = 1000;
const MAX_PAGES = 50;
for (let p = 0; p < MAX_PAGES; p++) {
  const pq = sb.from("customer_orders").select(...).neq(...).gte(...)
    .order("id", { ascending: true })
    .range(p * PAGE, (p + 1) * PAGE - 1);
  // ... filter conditions ...
  const { data: rows } = await pq;
  orders.push(...rows);
  if (rows.length < PAGE) break;
}
```

[apps/admin/src/app/(protected)/campaigns/page.tsx](../apps/admin/src/app/(protected)/campaigns/page.tsx) — 加共用 helper:

```ts
async function fetchAll<T>(builder: () => any, pageSize = 1000, maxPages = 50): Promise<T[]> {
  const all: T[] = [];
  for (let p = 0; p < maxPages; p++) {
    const { data, error } = await builder().range(p * pageSize, (p + 1) * pageSize - 1);
    if (error) throw error;
    const rows = (data ?? []) as T[];
    all.push(...rows);
    if (rows.length < pageSize) break;
  }
  return all;
}
```

兩處 (list view + calendar view) 都套用。

## 驗證

| 測項 | 結果 |
|---|---|
| `/orders` 共 15,170 筆 顯示 (was 398) | ✓ |
| KPI 本月營業額 $1.92M (was $128K) | ✓ 對齊 DB 真實 |
| KPI 本月訂單數 2,509 (was 124) | ✓ |
| `/campaigns` 列表件數 (e.g. GB-WEEK-R5141920-5-20 = 393) | ✓ 對齊 DB |
| Console error | 零 |

## 邊界

- `MAX_PAGES=50` × 1000 = 50K rows 上限。再大規模需 server-side aggregate via RPC
- `fetchAll` factory pattern 因為 supabase builder `.range()` 後不能 reuse
- 每 page 額外 1 RTT、50 page = 50 round-trips、可能慢、但比錯資料好

## 後續 follow-up

考慮加 server-side aggregate RPC `rpc_orders_kpi(p_filter)` 一次回 total / amount / unique_members 等、UI 直接拿、不用 chunked fetch。

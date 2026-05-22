# TEST — 加單下拉排除「已軟刪 SKU / 下架商品」

## 背景

`rpc_search_skus_for_campaign` 兩個 CTE：

| CTE | 用途 | 既有狀態 filter |
| --- | --- | --- |
| `in_campaign` | 已加進 campaign_items 的 SKU | ❌ 都沒 filter |
| `siblings`    | 同商品但未加進 campaign 的 SKU | ✅ `s.status='active' AND p.status='active'` |

實例：開團 `GB20260522-C000315` 內含 SKU `G00127-01`（已 `rpc_delete_sku` → `status='discontinued'`），仍在 admin 加單 picker 顯示為 `$0` 選項。

## 修法

`in_campaign` 也加上 `s.status='active' AND p.status='active'` 條件。

## 測試清單

### Schema / RPC 層

- [ ] **T1**：開團含一個 `status='discontinued'` 的 SKU（campaign_items 仍存在）→ `rpc_search_skus_for_campaign(campaign, '', 50)` 結果**不含**該 SKU。
- [ ] **T2**：開團含一個 `s.status='active'` 但 `p.status='inactive'` 的 SKU → 結果**不含**該 SKU。
- [ ] **T3**：開團含一個 active SKU + 一個 discontinued SKU（同 product）→ 結果只回 active 那筆。
- [ ] **T4**：開團含一個 SKU 但同 product 另有兄弟 SKU 為 discontinued → siblings 不出兄弟 discontinued（既有行為，不應 regress）。
- [ ] **T5**：跨 tenant 不外洩（既有行為，不應 regress）。
- [ ] **T6**：return shape 不變（campaign_item_id / sku_id / sku_code / product_name / variant_name / unit_price / cap_qty）。

### UI 層（admin /campaigns/order-entry?id=...）

- [ ] **T7**：用上述 GB20260522-C000315 進 picker，搜尋空字串 → dropdown 沒有 G00127-01。
- [ ] **T8**：「+ 加商品」select option 也沒有 G00127-01。
- [ ] **T9**：搜尋字串包含 G00127-01 sku_code → 仍不出現。

### 回溯影響

- [ ] **T10**：既有訂單 `customer_order_items` 已參照 discontinued SKU 的 campaign_item → 訂單詳情頁仍可正常顯示 `sku_label`（picker 不影響顯示）。
- [ ] **T11**：「為分店叫貨 / 庫存抵減單」mode 同一個 RPC → 也排除 discontinued。
- [ ] **T12**：order-entry 進入時 `useEffect` 一次性撈 SKUs 那段（line 161）→ 不會把 discontinued 帶進 `campaignSkus`，dropdown 即時可用。

## 驗證手段

- T1–T6：prod Studio 跑 SQL：
  ```sql
  SELECT * FROM rpc_search_skus_for_campaign(
    (SELECT id FROM group_buy_campaigns WHERE campaign_no='GB20260522-C000315'),
    '', 50
  );
  ```
  確認回傳列中沒有 G00127-01。
- T7–T9, T11–T12：使用者於 admin 加單頁自審截圖。
- T10：訂單列表→詳情頁觀察。

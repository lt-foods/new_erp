---
title: PRD - 召回模組（總倉派貨錯誤召回）
module: WMS / Orders
status: v1
owner: alex.chen
created: 2026-08-08
related: [PRD-WMS-倉儲管理工作台, PRD-訂單取貨模組, PRD-庫存模組, SOP-收貨後退貨]
tags: [PRD, ERP, WMS, Recall, 召回, 派貨錯誤]
---

# PRD — 召回模組

> 場景：總倉派貨派錯了（派錯品項 / 派錯數量 / 派錯店 / 品質或效期問題），
> 但貨**已經出倉**。此時同一張撿貨單（wave）派出去的貨散落在各種狀態：
> 還在車上、店家收了沒動、店家收了客人取走了一部分、有訂單只有一半要召回…
> 這些散落的單必須能從**總倉收件匣 → 撿貨單 → 已完成**那一列一鍵發起，
> 並且要有一個畫面能**比對確認召回數量是否正確**。

---

## 1. 為什麼要獨立一個模組（既有東西為什麼不夠）

系統已經有「退貨回總倉」：`rpc_create_order_return` → `transfers(transfer_type='return_to_hq')`
（[[SOP-收貨後退貨]]）。但它是**分店端、單張訂單**的工具：

| 既有退貨 | 召回需要的 |
|---|---|
| 分店發起 | 總倉發起 |
| 一次一張顧客訂單 | 一張撿貨單 × N 家店 × M 個品項 × 一堆訂單 |
| 貨一定已經在店裡 | 可能還在車上（transfer 還沒 received） |
| 沒有「目標量 vs 回收量」的概念 | 核心就是這個對帳 |
| 沒有跨店進度 | 要看「這批召回總共要回收 500，現在回來 320，還差 180 卡在哪幾家」 |

所以召回 = **一張總倉開的追蹤單**，底下**復用**既有的 transfer / 退貨 / 庫存原語，
自己只負責「目標量、狀態分桶、進度對帳、訂單連動」。

---

## 2. 名詞與資料流

```
撿貨單 wave ──generate_transfer_from_wave──▶ transfers(hq_to_store, 每店一張)
                                               │
                            ┌──────────────────┼──────────────────┐
                     status=shipped      status=received     （店端收貨）
                       貨在車上            貨在店裡
                                               │
                                     customer_order_items
                                    ┌──────────┴──────────┐
                            active(未取)              picked_up(客人取走)
```

召回開單時，每一格 **(店 × 品項)** 都會被拆成三個桶：

| 桶 | 條件 | 回收路徑 | 誰執行 |
|---|---|---|---|
| **A 在途** | 派貨單還是 `shipped`（店家沒收貨） | 整張攔截 → 貨帳退回總倉 | 總倉 |
| **B 在店未取** | 已 `received`、顧客訂單品項還沒取貨 | 拆單取消品項 → 店端出庫 → `return_to_hq` → 總倉收貨 | 分店 → 總倉 |
| **C 客人已取** | `customer_order_items.status='picked_up'` | 聯繫客人拿回 → 既有「取貨後退回」退貨 → 總倉收貨 | 分店 → 總倉 |

三個桶加起來 = 該格的召回目標量。**A/B/C 的量在開單當下就快照下來**
（`snap_in_transit / snap_unpicked / snap_picked_up`），之後現場怎麼變都不影響
「當初要召回多少」這個基準 —— 這就是對帳畫面的左半邊。

---

## 3. 資料模型

### 3.1 新表

**`product_recalls`（召回單主檔）**

| 欄位 | 說明 |
|---|---|
| `recall_no` | `RC{YYMMDD}{seq4}` |
| `source_wave_id` | 從哪張撿貨單發起（NULL 保留給未來其他入口） |
| `reason_code` | `wrong_sku / wrong_qty / wrong_store / quality / expiry / supplier_recall / other` |
| `status` | `draft`（可改可刪）→ `issued`（已發布、開始回收）→ `completed` / `cancelled` |

**`product_recall_lines`（店 × 品項，一格一行）**

| 欄位 | 說明 |
|---|---|
| `qty_dispatched` | 該 wave 派給該店該品項的量（快照） |
| `qty_target` | **這次要召回多少**（操作員填，≤ 可召回量） |
| `snap_in_transit / snap_unpicked / snap_picked_up` | 開單當下三桶的快照 |
| `qty_written_off` | 追不回、人工沖銷的量（含原因） |
| `settled_at` | 這一格結案時間 |

唯一鍵 `(recall_id, store_id, sku_id)` — 同一張召回單同一格不會重複。

**`product_recall_events`（append-only 稽核）**
每一次攔截 / 拆單 / 出貨 / 收貨 / 沖銷都留一筆，帶 `ref_type + ref_id`
（transfer / customer_order / customer_order_item），出事時可逐筆回溯。

### 3.2 既有表加欄位

| 表 | 欄位 | 用途 |
|---|---|---|
| `transfers` | `recall_id` | 這張 transfer 是為哪張召回單而生（含攔截掉的派貨單） |
| `customer_order_items` | `recall_id` / `recalled_at` | 因召回被取消的品項 |
| `customer_orders` | `recalled_at` | 整單因召回而結束 |

> **為什麼不新增 `status='recalled'`？**
> 與斷貨（`20260702020000`）同一個決策：`customer_order_items.status` 被十幾支
> view / RPC 用 `status NOT IN ('cancelled','expired')` 過濾，新增值會讓被召回的
> 品項繼續算進撿貨需求、繼續跟客人收錢。所以沿用 `status='cancelled'`，
> 另以 `recalled_at` 區分「召回」與「一般取消 / 斷貨」，顯示時優先顯示召回。
> 這也自動讓 CLAUDE.md 記載的四個金額加總點（`v_customer_order_summary`、
> `rpc_wallet_pay_order`、`v_admin_orders_list`、前端）正確排除召回品項。

### 3.3 進度一律「推導」不落地

`qty_returned` / `qty_intercepted` **不存欄位**，改由 view 即時算：

```
qty_intercepted  ← product_recall_events(event_type='intercepted') 的 qty 加總
qty_returned     ← transfers(recall_id=X, status IN ('received','closed')) 的 qty_received
qty_in_return    ← transfers(recall_id=X, status='shipped') 的 qty_shipped（在途回程）
qty_order_cancelled ← customer_order_items(recall_id=X, status='cancelled') 的 qty
```

理由：`rpc_receive_transfer` 已經被改過八次（見 migration 史），再往裡面塞
「回沖召回單」的副作用是下一個事故源。推導式沒有同步問題，總倉照既有流程
在 `/wms/inbound` 收貨，召回單的數字自己會動。

---

## 4. 流程

### 4.1 開單（總倉）

入口：`/hq/inbox?source=picking` → stage **已完成** → 該列 **🚨 召回**。

1. `rpc_recall_scan_wave(wave_id)` 掃描該 wave，回每一格：
   派出量 / 派貨單狀態 / 已收量 / 未取量 / 已取量 / 已退量 / 店端現有庫存 / **可召回量**
   以及每格背後的顧客訂單明細（誰、幾件、取了沒）。
2. 操作員逐格填「要召回多少」，或用 **全部召回 / 只召回未取** 快捷。
3. `rpc_create_recall(...)` 建 `draft`。此時**不動任何貨帳**，可反覆修改、刪除。

### 4.2 發布（總倉）

`rpc_issue_recall(recall_id)`：

- **B 桶**：對每一格，依 `建立時間 DESC, 訂單編號 DESC`（後下單先召回，保護早下單的客人）
  挑未取的 `customer_order_items` 取消，量不足整行時 **拆行**：
  新增一行 `qty=召回量, status='cancelled', recalled_at, recall_id`，原行 `qty` 扣掉。
  → 這就是「有訂單一部分是召回、有些正常，需要拆單」。
  操作員也可以在畫面上**指定要動哪幾筆訂單**（`p_item_overrides`），
  跟少發配貨（`ShortageAllocateModal`）同一套互動。
- 訂單收尾：全部品項都取消 → 整單 `cancelled`；還有取過貨 →
  `_close_orders_all_items_settled`（CLAUDE.md 的規則，不可略）。
- **C 桶**：不動訂單（客人已取、貨在客人手上），只登記待追回量。
- **A 桶**：不自動動，需總倉在對帳頁按「攔截」（見 4.3）。
- 狀態 → `issued`，之後不可改目標量（要改就沖銷或另開一張）。

### 4.3 回收

| 桶 | 動作 | RPC |
|---|---|---|
| A | 總倉「攔截整張派貨單」（**僅當該張派貨單所有品項數量都在召回範圍內**才允許） | `rpc_recall_intercept_transfer` |
| B | 分店在召回明細頁按「出貨退回總倉」→ 建 `return_to_hq` transfer（帶 `recall_id`） | `rpc_recall_store_ship` |
| C | 客人拿回來後，分店用既有退貨（勾「客戶已取貨後退回」）；掛到召回單 | `rpc_recall_customer_return` |

總倉端一律走既有 `/wms/inbound` 收貨（`rpc_receive_transfer`），不需要新流程。

**A 桶的限制是刻意的**：派貨單是整張 transfer，部分攔截等於改已發生的庫存異動。
只有整張都要召回時才允許攔截；部分召回請店家照常收貨，收完走 B 桶。
（另有守衛：`rpc_reject_transfer` 本來就禁止分店拒收波次派貨單，會讓訂單卡在
`shipping`、庫存虛回總倉 —— 召回攔截自己處理訂單連動，不走那條路。）

### 4.4 對帳（本需求的核心畫面）

`/recalls/detail?id=…`，每一格一列：

```
店       品項      派出  目標 │ 攔截  店退  客退 │ 已回收  在途  沖銷 │ 差額  狀態
松山店   G00123-05  120   120 │   0    80    12 │    92     20     0 │   -8  回收中
永和店   G00123-05   60    60 │  60     0     0 │    60      0     0 │    0  ✓ 已結
```

- **差額 = 已回收 + 沖銷 − 目標**，`0` 才是綠燈；負數紅字表示還沒回夠。
- 頂部 KPI：目標總量 / 已回收 / 在途 / 待客人歸還 / 沖銷 / 差額，以及
  「還有幾家店沒回完」。
- 每格可展開：影響到哪幾張訂單、哪幾張 transfer、逐筆事件時間軸。
- 追不回的量按 **沖銷**（填原因）→ 該格 `settled`。
- 全部格子 `settled`（差額 = 0）才能 `rpc_close_recall` 結案。

### 4.5 金額 / 月結

- 召回品項變成 `status='cancelled'` → 四個加總點自動不跟客人收錢（CLAUDE.md）。
- `return_to_hq` 的貨在總倉收貨後，月結生成器已有 `return_out` 分錄沖回分店應付
  （`20260714000100`），召回**不需要額外記帳**。
- 攔截掉的派貨單 `status='cancelled'`，月結的 `hq_inbound` 只認已收貨的 transfer，
  也自動不計。
- **會有的例外**：客人已用儲值金付過款、品項被召回 → `wallet_paid_amount` 可能
  超過新的應收。對帳頁把這種訂單標紅列出「需退款」，**不自動退**（退款是人的決定）。

---

## 5. 權限

| 動作 | 角色 |
|---|---|
| 掃描 / 開單 / 發布 / 攔截 / 沖銷 / 結案 | `owner` `admin` `hq_manager` `''` |
| 檢視自家店的召回明細、執行「出貨退回總倉」 | 上述 + `store_manager` `store_staff` `clerk`（限自家店） |

店端可視範圍由 `_jwt_store_ids()` 判定（本系統 JWT **沒有** `store_id` claim，
只有 `app_metadata.stores` 店名陣列 —— 這個坑踩過兩次，見 CLAUDE.md）。
SQL 讀角色一律走 `auth.jwt() -> 'app_metadata' ->> 'role'`。

---

## 6. 非目標（v1 不做）

- ❌ 自動推播通知客人「你的商品被召回」（先做名單匯出，通知走既有 LINE 模組）
- ❌ 自動退款 / 自動退儲值金（只標記「需退款」）
- ❌ 召回後自動重派正確商品（請另開一張撿貨單；召回單留 `notes` 互指）
- ❌ 批號 / 效期維度的召回（系統還沒有批號，見 WMS PRD v2）
- ❌ 供應商端召回（廠退走既有 `purchase_returns`）

---

## 7. 檔案清單

| 層 | 檔案 |
|---|---|
| Schema | `supabase/migrations/20260808000100_recall_schema.sql` |
| RPC | `supabase/migrations/20260808000110_recall_rpcs.sql` |
| 開單 | `apps/admin/src/components/RecallCreateModal.tsx` |
| 列表 | `apps/admin/src/app/(protected)/recalls/page.tsx` |
| 對帳 | `apps/admin/src/app/(protected)/recalls/detail/page.tsx` |
| 入口 | `apps/admin/src/app/(protected)/hq/inbox/page.tsx`（已完成撿貨單列加「🚨 召回」） |
| 標示 | `apps/admin/src/lib/orderStatus.ts` + `OrderDetail.tsx` + `orders/page.tsx` + member `OrderCard.tsx` |
| 測試 | `docs/TEST-warehouse-recall.md` |

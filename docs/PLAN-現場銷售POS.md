# PLAN — 現場銷售（門市 POS：沒有訂單的現場客，當場結帳當場扣庫存）

> 狀態：**P0 已施工完成，尚未部署正式庫**（2026-09-01）。分支 `claude/point-of-sale-feature-plan-ezpz4x`。
> 需求人：Alex。決議見 §11、施工結果見 §9。
> 需求原文：「有店家想要賣現場客，但是沒有訂單，然後又想要維護庫存，
> 可以做一個現場銷售的功能，像是一般超商那樣，可以依照人名跟商品庫存來產生一筆訂單，
> 並且扣掉庫存，然後銷售當下有可能很多商品沒有庫存，可以在同一個地方假如沒庫存就自動增加一筆記錄到庫存」。

---

## 0. 一句話

現場銷售 = 把「開單」和「取貨」壓進**同一個交易**、支援**多品項購物車**、
客人可以只有**一個名字**（不必是會員）；缺貨的品項可以在同一個畫面上**先補庫存再賣**。
帳走既有的 `customer_orders` + `picked_up` + `stock_movements('sale')`，
**不新開一套銷售表**。

---

## 1. 現況：這件事已經有人在做，只是很難用

線上已經有 `rpc_create_spot_sale`（現貨直配，2026-08-16 上線，單號 `SP-`）：
店員在庫存總覽選一個商品、選一位客人、送出 → 開一張「待取」單，客人來取貨時才扣庫存。

線上實測（2026-09-01）：

| 指標 | 數字 | 解讀 |
|---|---|---|
| `SP-` 訂單數 | 111（全部在近 30 天） | 功能有人用 |
| 平均品項數 | **1.00** | 一次只能賣一項 —— 買三樣要開三張單 |
| 開單後 6 小時內就取貨 | 41 / 111（37%） | **店員已經在拿它當現場銷售用**，只是要按兩次（配單 → 取貨頁再結一次） |

所以本案不是從零長一個新模組，而是把現貨直配補成「一次買多樣、當場結掉」的版本。
凡是現貨直配已經踩過的坑（可配量口徑、池子扣帳、店家守衛、零售價預填），**照抄**，不要重新發明。

其他相關現況：

- **零售價已經備好**：5,497 個 SKU 有 5,471 個掛著有效零售價 → 掃到/選到商品可以自動帶價。
- **條碼幾乎沒有**：`barcodes` 表線上只有 10 筆 → 掃碼**不能當 P0**，P0 靠名稱搜尋。
- **會員庫已經很髒**：25,715 位會員裡有 21,538 位沒有電話 → **不要**替每個現場客開一筆會員（見 §3.2）。

---

## 2. 為什麼不開一張新的 `pos_sales` 表

因為下游全部掛在 `customer_orders` / `customer_order_items` 上，另開一張表要把它們**全部再實作一次**，而且漏掉的那幾支不會報錯、只會靜靜地少算：

| 下游 | 靠什麼認 | 新表的話 |
|---|---|---|
| 日結報表 `rpc_daily_pickup_settlement` | `coi.status='picked_up'` | 現場銷售當天收的錢**不會出現在日結** |
| `/orders` 列表、營收 / 商品分析 | `customer_orders` + `order_kind='normal'` | 現場銷售不進任何報表 |
| 退貨 `rpc_create_order_return` | 訂單 + 品項 | 現場客退貨無路可走 |
| 撤銷 `rpc_undo_pickup` | `order_pickup_events` + `pickup_movement_id` | 按錯無法還原 |
| 成本 / 均成本 | `stock_movements('sale')` | 毛利算不出來 |

**結論：現場銷售就是一張顧客訂單，只是它出生的時候就已經取完貨了。**

### ⚠ 不要用 day-1 留下來的 `pos_sales`

線上**真的有**一組 `pos_sales` / `pos_sale_items` 表，還有一支 `rpc_complete_pos_sale`
（`20260422120005_sales_schema.sql`，通用 ERP 骨架）。看起來像正主，但它是死的：

| 檢查 | 結果 |
|---|---|
| `pos_sales` 資料 | **0 筆** |
| `pos_sale_items` 資料 | **0 筆** |
| 前端引用 | **完全沒有**（`grep -rn "pos_sale" apps/` 沒有命中） |
| `pos_sales.customer_id` 指向 | `customers` 表 —— 也是 **0 筆**，全站其實用 `members` |

它跟現在這套系統（會員、團購、取貨、日結）沒有任何接點。用它等於重蓋一套平行帳。

---

## 3. 資料模型

### 3.1 單頭 / 品項 / 庫存

| 東西 | 值 | 為什麼 |
|---|---|---|
| `order_no` | **`WS-<store_id>-0001`**（walk-in sale） | 線上已驗：`WS-` / `POS-` 兩個前綴**都沒人用**（現有前綴只有 GRP- 69,314 / RR- 552 / SP- 111 / OV- 23 / AB- 10）。序號一律 **MAX-based**，不要 `COUNT(*)+1`（20260813000010 湖口 RR-435 事故） |
| `status` | `completed` | 當場付清、當場交貨，沒有待取這一段 |
| `order_kind` | **`normal`** | ⛔ 不要新增 kind：全站 100 支檔案、188 處用 `order_kind='normal' OR IS NULL` 當口徑，新 kind 會被整批排除（營收、未結金額、商品分析…） |
| `campaign_id / channel_id / campaign_item_id` | 既有 sentinel trio（`_restock_sentinel_*`） | `customer_order_items.campaign_item_id` 是 **NOT NULL**，沒有團就只能掛 sentinel。現貨直配已經這樣做 |
| `nickname_snapshot` | **店員輸入的人名** | 這就是需求說的「依照人名產生訂單」 |
| `payment_method` | `cash` / `transfer` / …（來源 `stores.allowed_payment_methods`） | 目前全站沒有任何路徑寫這一欄，可以安心用 |
| `payment_status` | **維持 `unpaid`，不要寫 `paid`** | 見 §3.3 |
| 品項 | 建立時**直接** `status='picked_up'` + `pickup_movement_id` | 日結、營收、退貨全部靠這個狀態認 |
| 庫存 | 每列一筆 `stock_movements(-qty, 'sale', source_doc_type='customer_order', source_doc_id=訂單, source_doc_line_id=品項)` | 與 `rpc_record_pickup` **逐欄相同**，所以撤銷 / 退貨 / 月結 / 成本全部通用 |
| 取貨事件 | 一筆 `order_pickup_events(event_type='picked_up')` | ⚠ **不寫就不能撤銷**：`rpc_undo_pickup` 第一件事就是找最後一筆取貨事件，找不到直接 `RAISE` |

### 3.2 客人：兩種都要，預設不開新會員

1. **有會員** → 用既有 `rpc_search_members` 選（跟 `SpotSaleModal` 同一套），訂單掛在他名下，會員中心 / LINE 通知照常。
2. **純現場客** → 掛在**每店一筆**的「現場客」假會員（`member_type='guest'`、`member_no` 例如 `WALKIN-<store_id>`），**人名存 `nickname_snapshot`**。
3. **現場客要留下來** → 結帳畫面上一顆「☐ 建立為會員」，勾了就用輸入的名字（＋選填手機）開一筆正式會員，訂單直接掛他名下。
   **預設不勾**（Alex 決議）。手機有填就會走 `rpc_upsert_member` 的撞號路徑 —— 那支 20260831000050 之後會把死號讓出來、活人吐出點得出名字的錯誤，不要自己另外寫一套。

為什麼不替每個現場客開一筆會員：

- 線上已有 21,538 位沒電話的 active 會員，一天幾十筆現場客會把會員庫沖爛（搜尋、合併、標籤全部跟著爛）。
- 手機唯一索引那組雷（20260831000050：merged 殘骸佔號、林口店 83 筆）會被新路徑再踩一次。

為什麼是 `guest` 不是 `store_internal`：

- `store_internal` 被**日結報表明文排除**（`rpc_daily_pickup_settlement` 排掉容器單），掛上去 = 現場銷售收的錢在日結看不到 —— 正好把最重要的那件事弄壞。
- `store_internal` 還被 `_sku_commitment` 的池子口徑、零元守衛特判，語意完全不同。
- `member_type='guest'` 在 CHECK 裡合法（20260429120000）、後台 `MemberDetail` 已經會顯示「訪客」標籤，而線上**一筆都沒有** → 乾淨的新語意，不會污染既有查詢。

⚠ 連帶要處理：`customer_orders_trio_kind_active_uniq` 是「同 (tenant, campaign, channel, member, order_kind) 只能有一張 active 單」，
predicate 目前排除 `order_kind='restock'` 與 `order_no LIKE 'SP-%'`，
**但 `completed` 沒有被排除** → 同一家店第二筆現場銷售會直接撞唯一索引。
migration 必須把 predicate 加上 `AND order_no !~~ 'WS-%'`（照 SP- 那次的做法）。

### 3.3 付款：`payment_status` 一律維持 `unpaid`

CLAUDE.md 已經記過：`payment_status` 全站永遠是 `unpaid`，`WHERE payment_status='unpaid'` 等於沒有 WHERE。
現在有 3 支前端**反過來**把 `'paid'` 當「這張單不用再處理」在用：

- `apps/member/src/components/SettlementCard.tsx` — 會員端未結金額
- `apps/admin/src/app/(protected)/pickup/page.tsx:220` — `payment_status==='paid'` 直接歸零跳過
- `apps/admin/src/components/OrderDetail.tsx:1451` / `PickupDialog.tsx:192` — 儲值金付款判斷

現場銷售如果開始寫 `'paid'`，這些地方的行為會突然改變（而且是靜默的）。
「收到錢了」用既有語意表達就好：**品項 `picked_up`** → `v_customer_order_summary.outstanding_amount` 自動是 0。
**付款方式做成可選、預設現金**（Alex 決議）：選項來源 `stores.allowed_payment_methods`（預設 `["cash"]`），寫進 `payment_method` 欄位（目前全站沒人寫），日結報表多一個 group by。

---

## 4. 核心：`rpc_create_walkin_sale`（一支 RPC、一個交易）

```
rpc_create_walkin_sale(
  p_store_id  BIGINT,
  p_lines     JSONB,    -- [{sku_id, qty, unit_price, add_stock_qty}]
  p_member_id BIGINT,   -- NULL = 用該店的現場客假會員
  p_name      TEXT,     -- 現場客人名（存 nickname_snapshot）
  p_payment_method TEXT,
  p_discount_amount NUMERIC,
  p_operator  UUID,
  p_notes     TEXT
) RETURNS JSONB
```

執行順序（**順序本身就是設計**）：

1. **店家守衛** —— 逐字沿用 `rpc_create_spot_sale` / `rpc_add_stock_by_product` 的那一段：
   `app_metadata.role ∈ (store_manager, store_staff)` 且 `app_metadata.stores` 非空、不含「總倉」→ 目標店必須在清單裡。
   ⚠ 一律用 `app_metadata.stores`（**店名陣列**），不可以用 `store_id`（線上 33 個分店帳號沒有任何一個有 store_id）。
   角色一律讀 `auth.jwt() -> 'app_metadata' ->> 'role'`，不要用頂層 `role`（那永遠是 `authenticated`）。
2. 每個 (店, SKU) 各取一次 `pg_advisory_xact_lock`（同現貨直配），併發結帳序列化。
3. **可賣量閘門**：上限是 **`_sku_free_qty_with_pool(store, sku)`**，不是 `on_hand`。
   別的客人在等的貨（待客取 / 等貨中 / 在途池子）不可以被現場客買走 —— 那正是取貨閘門實體庫存守衛（20260818000010）在擋的事，
   而現場銷售**直接寫 sale、不經過取貨閘門**，所以這裡是唯一防線。
4. **缺貨補帳**（見 §5）：`add_stock_qty > 0` 的列先寫 `manual_adjust(+N)`，再回到步驟 3 重算。
5. 開單頭（`WS-` 序號、`completed`）→ 開品項（直接 `picked_up`）→ 每列寫 `sale` movement 並回填 `pickup_movement_id`。
6. **扣內部現貨池**：成交量超出純自由量的部分，呼叫既有的 `_consume_internal_pool(store, sku, qty, operator, now, '[已現場售出 WS-x-xxxx]')`
   —— 不呼叫的話同一批貨會掛兩份承諾，下一位客人的取貨閘門會被擋掉。
   **不要再抄一份拆行邏輯**（CLAUDE.md 明文）。
7. 寫 `order_pickup_events`（`picked_up`）。
8. 回傳 `{order_id, order_no, total, lines[], stock_added[]}` 給前端印小票。

明確**不做**的事：

- 不呼叫 `rpc_record_pickup`（它會跑取貨閘門，而現場銷售的貨不必「到過店」）。
- 不寫 `backorder_at`（那是少發配貨的語意，寫下去會多一道人工解除的關卡）。
- 不動 `payment_status`。

---

## 5. 「沒庫存就自動補一筆」—— 這是本案唯一的高風險設計

需求要的是：結帳當下發現帳上沒貨，可以在同一個畫面補一筆庫存再賣掉。
這等於在系統裡開一個**憑空生貨**的入口，而 CLAUDE.md 有一整節在講幽靈庫存造成的災情。所以要配套：

**做法**：同一個交易內先寫 `stock_movements(+N, 'manual_adjust')`，`reason` 固定格式
`現場銷售即時入帳 WS-<store>-<seq>`，再寫 `sale(-N)`。要嘛全成、要嘛整筆 rollback。

**五個必要的配套**：

1. **成本要帶**：`manual_adjust` 不帶成本時，若該倉 `avg_cost` 是 0，後面那筆 `sale` 的 COGS 就是 0、毛利虛高。
   補帳時帶 `_current_cost_price(tenant, sku)` 當 fallback（同 `_air_ship_order_items` 的做法）。
2. **權限（Alex 決議：店長）**：只有 `store_manager` 以上可以用；`store_staff` 看得到缺貨提示但按不下去（前端擋 + RPC 再擋一次，
   「按鈕拿掉但 EXECUTE 還通等於沒停」—— 自由轉貨那次的教訓）。
3. **單頭留痕**：notes 寫「本單有 N 件是現場補帳（未經收貨）」，`/orders` 明細看得到。
4. **報表**：新增一張「現場銷售補庫存」清單（依店 / 日期 / 操作人 / SKU / 數量），
   查法就是 `movement_type='manual_adjust' AND reason LIKE '現場銷售即時入帳%'`。
   帳一直要補 = 實體與帳面長期脫節，那是**盤點**要解的問題，報表要能一鍵導到盤點頁。
5. **不要用減抵單（DN）繞過**：`rpc_create_inventory_deduction` 自己就強制 `on_hand - reserved >= qty`，
   而 Path D 的無條件豁免正是 2026-08-18 松山「庫存 0 還能一直取貨」的元凶。現場銷售**不碰 DN**。

**明確不做**：不做負庫存直售（`p_allow_negative`）。負庫存只有在「貨確實離開了店」時才是誠實的記錄
（空中轉出庫那種），現場銷售是店員當下數得出來的東西，數得出來就補得出正確的數字。

---

## 6. 前端

新頁 `/pos`（暫名「現場銷售」），入口放在 `/inventory` 旁與側欄；分店角色一律鎖自己店。

```
┌──────────────────────────┬─────────────────────────┐
│ 商品搜尋（名稱 / SKU code）  │ 客人：[🔍 搜會員] 或 [打名字]  │
│  ─ 商品 A  可賣 5  $109    │ ─────────────────────── │
│  ─ 商品 B  可賣 0  $85 ⚠   │ 商品 A  ×2  $109   $218  │
│  ─ 商品 C  可賣 12 $60     │ 商品 B  ×1  $85    $85   │
│                          │   ⚠ 可賣 0（在庫 3、待客取 3）│
│                          │   ☑ 先補 1 件庫存再賣        │
│                          │ ─────────────────────── │
│                          │ 整單折扣 [   ]   合計 $303  │
│                          │ 付款：◉ 現金 ○ 轉帳         │
│                          │      〔 結帳 〕            │
└──────────────────────────┴─────────────────────────┘
```

要點：

- 可賣量、建議售價一次撈：擴充既有 `rpc_get_stock_commitment_bulk`（它已經回 `free_with_pool`），
  **不要**每列各打一次 `rpc_get_spot_availability`（那是 `ARRAY[單一變數]` 那個坑，一頁 50 列就是掃 50 遍，
  文山店實測 3.8 秒 → 收斂後 60ms）。
- 售價預填**零售價**（`suggest_price = COALESCE(retail, branch, 0)`，20260827020000 已定案），可改；
  分店價只給 `canSeeBranch` 的角色看。
- 單價 0 要擋（零元守衛的同一個理由：$0 = 把貨白送出去）。
- 缺貨列一律顯示拆解「在庫 X、待客取 Y、等貨中 Z」，不要只寫「可賣 0」——
  那正是 8/24「調整庫存完不能把庫存再轉出去」那次店員繞不出來的原因。
- **結帳完直接出小票（Alex 決議：要）** —— 列為 P0，不是 P1。版型重用 `/pickup/print`，走 `/pos/receipt?order=<id>`：店名、單號、日期、人名、逐列品項 / 數量 / 單價 / 小計、折扣、合計、付款方式、操作人。

---

## 7. 退貨 / 按錯 / 作廢

| 情境 | 走哪一支 | 要驗什麼 |
|---|---|---|
| 品項打錯、金額打錯（當天） | `rpc_undo_pickup` → 還原庫存 → 再開一張 | 它需要 `order_pickup_events`，所以 §4 步驟 7 不能省；權限已含 `store_manager`（20260807000010） |
| 客人事後退貨 | 既有 `rpc_create_order_return` | 對 `completed` 的 `WS-` 單能不能跑，要實測 |
| 整單作廢 | 撤銷取貨後 `cancelled` | 撤銷後記得接 `_close_orders_all_items_settled` 的既有收尾 |

---

## 8. 報表：什麼會自動對、什麼要改

**自動就會對**（選 `guest` 而不是 `store_internal` 的關鍵理由）：

- 日結 `rpc_daily_pickup_settlement`：口徑是「`picked_up` 品項 + 排除 `store_internal`」→ 現場銷售當天自動入帳。
- `/orders` 列表、營收 / 商品分析：`order_kind='normal'` → 自動涵蓋。
- 月結算：`store_monthly_settlement_items` 以 `transfers` 為母體，現場銷售一列都不產生 → **結構性地不入月結**（正確，這批貨本來就在店裡）。

**要改**：

- 日結多一個「現場銷售」分項 + 付款方式（現金 / 轉帳）小計。
- 新增「現場銷售補庫存」報表（§5.4）。

---

## 9. 施工順序

| # | 內容 | 檔案 | 狀態 |
|---|---|---|---|
| 1 | 唯一索引 predicate 加 `order_no NOT LIKE 'WS-%'`、`source` CHECK 加 `walk_in`、`_walkin_member(tenant, store)` | `20260901000000_walkin_sale_schema.sql` | ✅ |
| 2 | `rpc_create_walkin_sale`（店家守衛、free_with_pool 閘門、缺貨補帳、扣池、pickup event） | `20260901000010_rpc_create_walkin_sale.sql` | ✅ |
| 3 | `rpc_pos_search_products`（結帳頁商品搜尋，一次撈可賣量＋售價） | `20260901000020_rpc_pos_search_products.sql` | ✅ |
| 4 | 補庫存稽核報表 `rpc_walkin_stock_topups` | `20260901000030_rpc_walkin_stock_topups.sql` | ✅ |
| 5 | 結帳頁 + 側欄入口 | `app/(protected)/pos/page.tsx`、`layout.tsx` | ✅ |
| 6 | 小票（80mm，決議 4） | `app/(protected)/pos/receipt/page.tsx` | ✅ |
| 7 | 補庫存紀錄頁（§5 配套 4） | `app/(protected)/pos/topups/page.tsx` | ✅ |
| 8 | 訂單頁：`internalOrderSource()` 加 `WS-`、`walk_in` badge、`/orders` 快篩 | `lib/orderTitle.ts`、`lib/orderSource.ts`、`orders/page.tsx` | ✅ |
| 9 | 日結報表依付款方式分項 | `rpc_daily_pickup_settlement` | ⏳ **還沒做**，見下 |

### ⏳ 還沒做：日結依付款方式分項

現場銷售**已經**會進日結（§10 情境 6 實測過），只是還沒有「現金 / 轉帳」的拆分。
沒有一起做的原因：`rpc_daily_pickup_settlement` 最新版是 `20260831000040`（245 行、
兩支函式，而且兩支的 `picked` 母體必須逐字一致），為了加一個分項欄位去整支重寫
是這個 PR 裡風險最高、價值最低的一段。等現場銷售真的跑起來、確定要拆的維度之後
再單獨做一支 migration 比較安全。

要做的時候：基底是 `20260831000040`，`days[]` 比照 `store_campaign_*` 那組的做法
多回 `cash_amount` / `other_amount_by_method`，**既有欄位一個都不要動**
（前端沒改也不會壞，那是該檔自己立的規矩）。

每支 migration 送出前：

```bash
node scripts/check-sql-syntax.cjs supabase/migrations/<檔名>.sql   # 每個檔案開新 wasm instance
git fetch origin main -q && git ls-tree --name-only origin/main supabase/migrations/ | tail -5   # 檢查撞號
```

套上正式庫走 Management API（不要戳 pooler），而且**當天就要把 migration 合進 main**。

---

## 10. 驗收情境（✅ = 已對正式庫實測，執行後 ROLLBACK）


| # | 情境 | 實測結果 |
|---|---|---|
| 1 | 買 3 樣、其中 1 樣缺 2 件勾補庫存 | ✅ `WS-1-0001`、3 列 `picked_up`、3 筆 `sale` + 1 筆 `manual_adjust(+2, cost 2.2)` |
| 2 | 同店連開多張 | ✅ `WS-1-0001` / `0002` / `0003`，沒撞唯一索引 |
| 3 | 超過可賣量 | ✅ 擋下，訊息帶「在庫 3 / 待客取 0 / 等貨中 0」＋下一步 |
| 4 | 池子有貨（on_hand 6、free 1、cap 5）賣 4 件 | ✅ `from_pool=3`，池子 4→1（OV- 單留一列刪除線 `[已現場售出 WS-1-0001]`），on_hand 6→2 |
| 5 | 分店帳號打別店 | ✅ `wrong_store` |
| 6 | 賣完當天開日結 | ✅ 平鎮店 746 → 996（+250），`/orders` 列表 `source_summary='walk_in'` |
| 7 | 按錯 → `rpc_undo_pickup` | ✅ 兩筆 `reversal`、品項回 `pending`、`on_hand` 完全復原 |
| 8 | 補庫存報表 | ✅ 對得回 `WS-1-0001`，summary/明細都出得來 |
| 9 | `store_staff` 勾補庫存 | ✅ `permission denied`（不勾則正常結帳） |
| 10 | 單價 0 / 空購物車 / 賣給【內部】店帳號 | ✅ 三個都擋下 |

前端（Playwright + fixture，`apps/admin:verify`）：結帳頁缺貨列出現補庫存勾選、
勾了才給結帳、付款方式吃 `stores.allowed_payment_methods`、小票金額與折扣正確
且不印出 `WALKIN-` 帳號、`/orders` 快篩按下去 keyword 變 `WS-`、側欄出現「現場銷售」。

---

## 11. 決議（Alex 2026-09-01）

| # | 問題 | 決議 |
|---|---|---|
| 1 | 現場客要不要留成會員？ | **預設不留，但畫面上要能選擇留**（勾「建立為會員」）→ §3.2 第 3 點 |
| 2 | 缺貨補庫存誰能按？ | **店長（`store_manager` 以上）** → §5.2 |
| 3 | 付款方式要分嗎？ | **做成選項、預設現金** → §3.3 |
| 4 | 要印小票嗎？ | **要**，列入 P0 → §6 |
| 5 | （追加）訂單頁 | 現場銷售**要產生訂單**，但**不跟著任何團** → 見 §12 |

---

## 12. 訂單頁的調整（Alex 追加）

現場銷售會產生一張真的顧客訂單，但它不屬於任何團。系統裡**已經有這條路**：
現貨直配 / 補貨 / 轉單的單一律掛在共用假團 `__INTERNAL_RESTOCK__`「【內部】補貨申請」底下，
而訂單列表與明細早就會把那個名字換掉、改標「實際來源」（2026-08-16 回報後做的）。
現場銷售**接上同一套**就好，不要另外發明。

### 12.1 已經現成、只要接上去的

| 位置 | 現成機制 | 要做的事 |
|---|---|---|
| `/orders` 列表的「開團」欄 | `CampaignOrSource`：`campaign_no` 以 `__` 開頭 → 改印 `internalOrderSource(order_no)` | 在 `internalOrderSource()` 加 `WS-` → **「🛒 現場銷售」**／hint「門市現場結帳，當場扣庫存收款」 |
| 訂單明細的「開團」欄 | `OrderDetail` 同一段判斷 | 同上，一改兩處都生效 |
| 會員 App 的訂單卡標題 | `orderCardTitle()`：內部團改印品項名 | 自動生效（`WS-` 掛 sentinel 團）。⚠ `lib/orderTitle.ts` 在 admin 與 member **各有一份副本**，改一定要兩邊一起改 |
| 手機卡片的品項名 | `itemLabel()`：開團名 ≠ 商品名時補上商品名 | 自動生效 |

### 12.2 要新增的

1. **品項來源新增 `walk_in`**（`customer_order_items.source`）。
   照 `lib/orderSource.ts` 檔頭寫好的三步驟做：
   (a) 加進 `ORDER_ITEM_SOURCES` + `ORDER_SOURCE_META`（label「現場銷售」/ short「現場」/ icon 🛒）；
   (b) migration 改 CHECK constraint（現行 `20260808000020_order_item_source_pwa.sql`）；
   (c) **不要**加進 `SOURCE_TREND_SERIES` —— 那張折線圖只畫「人是怎麼下這張單的」三個通路（App / 商城 / 小幫手），
   現場銷售不是線上通路，混進去會讓通路消長的圖說謊。
2. **`/orders` 加一個「現場銷售」快篩**（單號前綴 `WS-`），店長對帳時要能一眼把今天的現場單撈出來。
3. **訂單明細對 `WS-` 單要收掉不適用的動作**：轉單給別人、標到貨、少發配貨、催取貨通知 ——
   單頭出生就是 `completed`，多數按鈕本來就不會出現，但要逐一確認（尤其「轉單給客人」，
   貨已經交出去了還能轉會生出幽靈品項，那正是 20260810010000 修過的那類 bug）。
   留著的只有：撤銷取貨、退貨、改備註。
4. **明細上要標「本單有 N 件是現場補帳」**（§5.3），並列出那幾筆 `manual_adjust`。

### 12.3 明確不做

- **不新開 sentinel 團給現場銷售用。** 共用 `__INTERNAL_RESTOCK__` 是刻意的：全站 10+ 處濾網
  （`campaigns`、`purchase/requests`、`ProductCampaignsPanel`、`/shop`…）都寫死排除它，
  另開一個新 sentinel 只要漏掉一處，現場銷售的假團就會外顯給客人看到。
- **不新增 `order_kind`。** 理由同 §3.1。
- **不改 `v_admin_orders_list` 的口徑。** 現場銷售是 `order_kind='normal'` 的正常單，
  本來就該進訂單數 / 金額 / 營收；要區分靠來源 badge 與快篩，不是靠把它從母體挖掉。

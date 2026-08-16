# PLAN — 現貨直配（不掛團配庫存給客人）與庫存承諾收斂

> 狀態：**已施工、已部署正式庫**（2026-08-16）。分支：`claude/usage-guide-2lf0wx`。
> **待辦：migration 尚未進 main，見 §4.3。**
> 需求人：Alex。「直接選商品配庫存給客人，不跟著開團」。

---

## 0. 一句話

店員在庫存總覽選一個商品、選一位客人、送出 → 產生一張正常的顧客訂單（待取，
取貨時才扣庫存、收款），**全程不需要先開團**；同時把全站散落十幾份的
「庫存承諾量」算法收斂成一支 canonical 函式，讓這條新路徑（和以後所有路徑）
不再各自抄公式。

---

## 1. 心智模型：兩本帳、一個交會點

系統裡其實有兩本互相獨立的帳，過去的災情多半是把它們混為一談：

| | 實物帳（庫存池） | 認領帳（訂單） |
|---|---|---|
| 本體 | `stock_balances` + `stock_movements` | `customer_orders` + items |
| 回答的問題 | 這個店這個 SKU 現在有幾件 | 這幾件是誰的、可不可以領 |
| 入口 | 收貨（調撥入）、新增庫存（manual_adjust）、盤盈 | 團購下單、代客加單、內部叫貨（-INT）、補貨申請（RR-）、收貨多給（OV-）、轉單（-TF）、現貨配單（加單頁）、**★本案新增：現貨直配** |
| 出口 | 取貨（sale）、調撥出、盤虧 | 取貨結案、取消、斷貨、轉出 |

兩本帳**沒有外鍵綁定**，唯一同時動兩本的動作是**取貨**
（`rpc_record_pickup`：認領銷帳＋寫 `sale` 異動出池）。

名詞約定（避免混淆）：

- **調整** = `manual_adjust`，只動實物帳的數量。
- **配單／直配** = 把池裡的自由量綁給一個人，只動認領帳；實物在取貨時才動。
- **自由量** = `on_hand − 已承諾未取(promised) − confirmed 等貨需求(waiting) − 內部店池子(pool)`
  —— 沒有任何認領掛著的貨。2026-08-16 實測松山店：on_hand 1,031、自由量 203 件（47 SKU）。

訂單模型的核心不變量**不動**：`customer_orders.campaign_id NOT NULL`、
`customer_order_items.campaign_item_id NOT NULL`。「不掛團」是對使用者而言；
資料層用 sentinel 假團補位（既有手法，見 §2.2）。

---

## 2. 階段一：現貨直配 `rpc_create_spot_sale`

### 2.1 UX 與操作流程

畫面規劃：**`docs/mockups/spot-sale.html`**（狀態 A–E，含 disabled / 擋下 / 完成 / append 文案）。

- 入口：**庫存總覽**（`/inventory`）列展開面板（現在放「近 50 筆庫存異動」那格）
  頂部加動作列：左側顯示**自由量拆解**（在庫 − 承諾 − 等貨 − 池子 ＝ 自由量，
  hover 看明細），右側「🤝 配給客人」按鈕，自由量 ≤ 0 時 disabled ＋ tooltip 說明去向。
- Modal：商品唯讀卡（含自由量）→ 客人搜尋（沿用加單頁會員搜尋元件）→
  數量（上限＝自由量）＋ 單價（預填分店價→現售價，可改、必須 > 0）→
  紫色說明框「送出＝待取，取貨時才扣庫存收款」→ confirm() → 送出。
  分店帳號鎖自己店（同減抵單頁 `useUserBranchStoreId` 慣例）。
- 完成 alert 顯示訂單號＋「待取」；append 進既有單時明講「併入 ×××（現共 N 件）」。
- 後續全走既有頁面：取貨頁交貨、會員端看單、配錯在訂單頁取消品項——不新做任何頁。
- 不做購物車：一次一個 SKU（庫存總覽是「看著這列貨想賣掉它」的場景；
  多品項需求走加單頁既有模式）。

操作流程（店員視角）：

```
客人在櫃檯指著架上的貨
  → 庫存總覽搜商品 → 點開該列
  → 自由量 > 0？
      ├ 是 → 配給客人 → 選人 → 數量/單價 → 送出（單=待取）
      │        → 客人到取貨頁走正常取貨（此刻扣庫存、收款）
      └ 否 → 按鈕 disabled，tooltip 指路：
             架上實際有貨 → 先「+ 新增庫存」入帳再回來
             貨是池子(RR-/OV-)的 → 走訂單頁「轉單給客人」
             貨是別人的承諾 → 不能賣（這正是閘門存在的理由）
```

### 2.2 資料流（全部沿用既有零件）

1. **sentinel trio**：`_restock_sentinel_campaign(tenant)`（`__INTERNAL_RESTOCK__` 團）
   ＋ `_restock_sentinel_channel(tenant, store)` ＋ **真實客人** member。
   campaign_item 用 `_restock_sentinel_campaign_item(...)` 按需自動建。
   共用補貨 sentinel 而不另開新團：全站 10+ 處 `.neq('__INTERNAL_RESTOCK__')`
   濾網現成；另開新 sentinel 要逐處補條件，漏一處就靜默出錯（CLAUDE.md 同型教訓）。
2. **單價**：預填 `prices` branch → retail；**必須 > 0**（20260815000000 零元守衛
   會在取貨時擋 $0 品項——這張是真客人的單，不在 store_internal 豁免範圍）。
   sentinel `campaign_item.unit_price` 可能是 0，**訂單品項單價以表單值為準**
   （同 `rpc_transfer_order_partial` 轉單改鎖現售價的既例）。
3. **可配量閘門**：上限用**自由量**（§1 定義，由階段二 `_sku_commitment` 計算），
   不是 `on_hand − reserved`。用後者會把「別的客人正在等的貨」「池子登記的貨」
   賣掉——就是忠順 8 位團友撲空那型災情。池子（RR-/OV-）的貨要賣走既有
   「轉單給客人」，直配不碰。
4. **建單**：reuse-first——trio partial UNIQUE 保證同客人同店只有一張 active 單，
   有就 append、`completed` 就 `_reopen_order_if_completed`（20260805000140），
   沒有就 `rpc_create_customer_orders` 新建。
5. **取貨閘門**：開一張 DN 減抵單當 coverage → `is_order_item_pickup_ready`
   Path D 放行（與 `rpc_create_offset_sale` 20260805000230 完全同法，
   含「不呼叫 rpc_record_pickup、配單＝待取」的語意）。單頭推 `ready`。
6. **不觸發採購**：sentinel 團被請購頁排除、無 PR 連結 → 不會進採購聚合；
   DN coverage 讓收貨頁口徑也對。

### 2.3 單號與顯示

- 訂單沿用 trio 建單的號（`__INTERNAL_RESTOCK__-…`）。
  **顯示層**要接：`apps/admin/src/lib/orderTitle.ts`、`apps/member/src/lib/orderTitle.ts`
  已有「sentinel 團的單改顯示品項名」的例外（RR-/TF- 型），確認新單型也吃得到，
  吃不到就補。`skuLabel.ts` 檔頭註解同步。
- 訂單列表／會員端不用改：這是真客人＋`order_kind='normal'` 的正常單，
  金額報表、未結金額、商品分析**本來就該算它**——它就是一筆真實銷售。

### 2.4 列表也要顯示承諾拆解（2026-08-16 回報後追加）

回報：「已承諾未取要在清單上就出現了，清單上的可分配庫存要區分開來」。

病灶：列表的「可用」＝ `on_hand − reserved`，而 **`reserved` 全站沒在維護**
（實測 7,712 筆有庫存的列，`reserved <> 0` 的是 **0 筆**）→「可用」恆等於「在庫」。
截圖那筆松山店 G01150-01：列表寫「可用 3」、配單視窗寫「自由量 0」（promised 3）
—— 同一頁的兩個數字互相打臉，比沒有數字更糟。

改法（`20260816000020` ＋ 前端）：

- 列表欄位「保留 / 可用」→ 換成 **「已承諾 / 池子 / 可分配」**。
  `reserved` 不給整欄，改成非 0 時才在「在庫」旁邊冒一個標記，
  哪天真的開始用不會被靜靜吃掉。
- `rpc_get_stock_commitment_bulk(p_pairs jsonb)`：一頁 50 列一次算完。
  **free 在伺服端算完才回**，前端只顯示 —— 若讓前端自己 `on_hand − …`，
  等於把公式又抄一份到第五個地方。
- 「已承諾」欄在有等貨需求時附掛 `+N待`；「可分配」> 0 才給綠色。

### 2.4.1 「只看可配給客人」篩選（2026-08-16 追加）

庫存總覽多一個 checkbox：只列出**可分配 > 0** 的品項 —— 店員想知道
「現在有哪些貨可以直接配給客人」。可與「只看低於補貨點」並用（取交集）。

- `rpc_list_allocatable_pairs(倉別, SKU集合, limit)` 回候選 (倉別, SKU)。
  前端拿它當候選集合，再照既有「只看低於補貨點」的作法撈 `stock_balances`、自己分頁。
  全站實測 **507 組 / 15 個倉別 / 6,647 件**，集合很小，這個作法夠用。
- 「全部倉別」時伺服端要走過每間店的訂單一次（實測 ~3s），單店 143ms。

#### 順帶修掉自己種下的效能地雷

做這個篩選時量測才發現，`20260816000020` 那版 `rpc_get_stock_commitment_bulk`
對 `p_pairs` 的**每一列**各呼叫一次 `_sku_commitment` —— 一頁 50 列就把該店訂單
掃 50 遍。文山店（1,704 張單）實測 **3.8 秒**，逼近 PostgREST 的 8 秒上限；
想拿它掃全站直接 `statement timeout`（>120s）。

這正是 CLAUDE.md 記過、`_advance_arrived_confirmed_orders` 在 20260813(3)
才修掉的同一個坑，而 `_sku_commitment` 本來就設計成「傳 SKU 陣列、單趟 GROUP BY」
—— 卻用 `ARRAY[單一 sku]` 呼叫，把那個設計浪費掉。

`20260816000030` 改成**一間店只呼叫一次**（把 pairs 依倉別分組後傳整個 SKU 陣列）：
**3.8s → 60ms（63×）**，數值逐筆不變。
教訓：`_sku_commitment` 這種「吃陣列、單趟算完」的函式，
包一層 per-row LATERAL 就等於退化回原本要避免的寫法。

### 2.5 明確不做

- 不讓訂單脫離 campaign（動核心不變量，全站 join 假設崩）。
- 不做多品項購物車、不做折扣（改單價欄位即是）。
- 池子貨不走直配（走轉單，池子帳才會跟著動）。
- 通知：第一版不發「可取貨」通知（客人就在櫃檯是主場景）；要發再加。

---

## 3. 階段二：承諾量收斂 `_sku_commitment`

### 3.1 為什麼先做這個

階段一的可配量閘門需要「自由量」，而自由量的三個分項（promised / waiting / pool）
目前 inline 抄在至少四支函式裡，口徑各有微妙差異。過去一個月至少四起事故
同根因（忠順池子 ×10、未結金額多算 482 萬、松山 backorder 卡 6 天、
盤壞帳 395→79→26 組兩次誤判）。先收斂，階段一直接呼叫，不再新增第五份複本。

### 3.2 設計（施工後修正）

實作時逐字比對四支現行版本，發現**差異比規劃時假設的多，而且是刻意的**，
不能硬統一。最終簽名：

```sql
CREATE FUNCTION public._sku_commitment(p_store_id BIGINT, p_sku_ids BIGINT[] DEFAULT NULL)
RETURNS TABLE (
  sku_id          BIGINT,
  promised        NUMERIC,  -- 客人單 ready/partially_completed/shipping 未取量
  promised_active NUMERIC,  -- 同上但排除待補貨列（_settle 用）
  waiting         NUMERIC,  -- confirmed 一般單還在等貨的需求
  pool_claimed    NUMERIC,  -- 內部店容器未取量（含在途 RR-，_grow 用）
  pool_arrived    NUMERIC   -- 內部店容器未取量（只算已到貨，_trim 用）
) LANGUAGE sql STABLE;
```

三個規劃時沒預料到的點：

- **`promised` 有兩種**：`_settle_arrived_backorders` 多一個
  `backorder_at IS NULL`。待補貨列本來就是「還沒配到貨」，算進已承諾等於
  自己擋自己，整支永遠解不開任何一列（20260811000050 檔頭）。
- **`pool` 有兩種**：`_grow` 含在途 RR-（避免對還沒到的貨重複掛帳）、
  `_trim` 只吃 ready/partially_completed（拿在途的貨沖銷已交付量是錯的，
  20260811000040）。**兩者都對**，不是其中一個有 bug。
- **必須是 set-returning 單趟 GROUP BY**，不能只做 per-SKU 純量。
  `_advance_arrived_confirmed_orders` 在 20260813(3) 特地把 per-SKU LATERAL
  改成一次 GROUP BY（文山 1,704 張單 × ~5ms ≈ 8.5s，PostgREST 8s timeout）。
  純量版會把那個效能 regression 種回去。另出純量包裝
  `_sku_free_qty(店, SKU)` 給 `_grow` 與現貨直配用。

回分項、不回單一數字的理由不變：各呼叫端的組合本來就不同，
收斂的是「分項的定義」，組合留給呼叫端。

### 3.3 ★ 順帶抓到一個 latent bug（已修）

`_grow_internal_pool` 的 pool 條件沒有排除 `order_kind='offset'`、也沒有
`qty > 0`。而抵減單（-OFF）掛在 store_internal 假會員名下、單頭 `confirmed`、
品項 qty 是**負數** —— 正好全部落在它的狀態範圍內。結果 pool 被灌成負的
→ 自由量虛增 → 收貨多給時把不存在的貨掛進 OV- 池子（幽靈庫存）。

線上實測 2026-08-16：**35 組 (店,SKU)、合計虛增 112 件**（最大一筆：
中和店 sku 4729 灌水 30 件）。`_sku_commitment` 一律 `qty > 0` ＋ pool 排除
offset，`_grow` 換用後少掛那 112 件 —— 這是修正，不是 regression。

已驗證全站唯一的非正數品項就是抵減單（offset ＋ store_internal，49 列），
所以 `qty > 0` 對 promised / waiting 是 no-op，那兩者的口徑不受影響。

### 3.4 呼叫點改造：本次只換 `_grow`，其餘三支延後

| 函式 | 最新版本（實測） | 本次 | 理由 |
|---|---|---|---|
| `_grow_internal_pool` | 20260814010000 | ✅ 已換 | 行為有變（修 bug），本來就要動 |
| `_trim_internal_pool` | 20260811000040 | ⏸ 延後 | 零行為變更的純去重 |
| `_advance_arrived_confirmed_orders` | **20260813020000** | ⏸ 延後 | 同上；查詢計畫是調過的，要連 MATERIALIZED 那段一起驗 |
| `_settle_arrived_backorders` | 20260811000050 | ⏸ 延後 | 零行為變更的純去重 |

> ⚠ 規劃時把 `_advance_arrived_confirmed_orders` 的基底寫成 20260811000020 是錯的
> —— 它被改過 4 次，最新是 `20260813020000`。改這支前務必重跑
> `grep -rln "FUNCTION public._advance_arrived_confirmed_orders" supabase/migrations/`。

分開上線的理由：**「行為有變」和「行為沒變」要各自可回溯、可 rollback**。
把 bug 修正跟三支大函式的整段改寫混在同一支 migration，出事時分不出是哪一半造成的。
後三支的等價性驗證 SQL 已寫在 `20260816000000` 檔尾 §4。

### 3.5 附帶收穫

上線當天拿 `_sku_commitment` 全站掃一輪
`pool_arrived > on_hand − promised`（判準含單頭 status，見 CLAUDE.md「到店了沒」教訓），
把現存壞帳清單交給 Alex 人工收尾。

---

## 4. 施工順序與部署

| # | 項目 | 狀態 |
|---|---|---|
| 1 | **Migration A** `20260816000000`：`_sku_commitment` / `_sku_free_qty` ＋ `_grow` 換用＋修 bug＋等價驗證 SQL | ✅ 已寫、語法過 |
| 2 | **Migration B** `20260816000010`：`rpc_create_spot_sale` ＋ `rpc_get_spot_availability` | ✅ 已寫、語法過 |
| 3 | **前端**：`/inventory` 展開列動作＋`SpotSaleModal` | ✅ 已寫，tsc 乾淨 / 新檔 lint 0 / Playwright 驗過 |
| 4 | **部署到線上** | ✅ 已套＋等價性驗證通過（§4.2） |
| 5 | **Migration C** `20260816000020`：`rpc_get_stock_commitment_bulk` ＋ 列表欄位改版 | ✅ 已套（§2.4） |
| 6 | **migration 進 main** | ⛔ **未做** — 見 §4.3 |
| 6.5 | **Migration D** `20260816000030`：bulk 改一間店一趟（3.8s→60ms）＋ `rpc_list_allocatable_pairs` | ✅ 已套 |
| 7 | **TEST 文件** `docs/TEST-spot-sale.md` | ⏸ 待店家實際跑一輪後補 |

### 4.1 離線驗證工具（本次新增）

- `scripts/check-sql-syntax.cjs`：用 repo 既有的 `pg-query-emscripten`
  離線檢查 migration 語法**含 PL/pgSQL 函式內文**（`parsePlpgsql`）。
  不連 DB 就能擋掉語法錯，免得 `CREATE OR REPLACE` 套一半留下壞掉的函式。
  ⚠ 每個檔案要開新的 wasm instance —— 同一個 instance 連續解析多檔會在
  模組內部爆掉（`Ma[...] is not a function`），那是 emscripten 的狀態問題、
  不是 SQL 有錯（誤判過一次）。
- `scripts/apply-migration.sh`：走 Management API 套 migration（CLAUDE.md：
  不戳 pooler TCP）。

### 4.2 ✅ 部署完成（2026-08-16）

兩支都已套上正式庫（走 `scripts/apply-migration.sh` → Management API）：

| Migration | 結果 |
|---|---|
| `20260816000000_sku_commitment_canonical.sql` | ✅ 已套 |
| `20260816000010_rpc_create_spot_sale.sql` | ✅ 已套 |

**等價性驗證通過**（`scripts/apply-migration.sh scripts/verify-sku-commitment-equivalence.sql`）：

```
a_mismatches: 0     ← promised / promised_active / waiting / pool_arrived 逐筆相等（零行為變更）
b_unexpected: 0     ← pool_claimed 的差異只出現在有負數 offset 的組，且差額相符
bugfix_pairs: 35    ← 與部署前實測一致
bugfix_units: 112
```

冒煙測試：4 支函式都在；松山店自由量 **203 件 / 47 SKU**，與部署前手算一致；
`rpc_get_spot_availability` 拆解正確（例：棉柔洗臉巾 on_hand 40 − pool 10 = free 30）。

> ⚠ 第一次跑驗證回了 1,117 筆假 mismatch —— 原因是驗證查詢在 `_sku_commitment`
> 那一側濾了 `st.is_active`、legacy 側沒濾，而**已停用的 5 家分店身上還掛著
> 1,327 組 (店,SKU) 的未取品項**。函式本身沒問題。這類「收斂前後對拍」的查詢，
> 兩側的 store 集合必須完全一樣，否則會把自己嚇一跳、甚至去「修」一個不存在的 bug。

### 4.3 ⛔ 還沒做：migration 進 main

依 CLAUDE.md：**凡直接套上正式庫的 SQL，對應 migration 當天必須真的進 main**，
否則 repo 與正式庫脫鉤，後續開發都會基於錯誤認知往下做。

目前兩支只在 `claude/usage-guide-2lf0wx` 分支上。收工判準（唯一算數的）：

```bash
git log origin/main -- supabase/migrations/20260816000000_sku_commitment_canonical.sql
git log origin/main -- supabase/migrations/20260816000010_rpc_create_spot_sale.sql
git log origin/main -- supabase/migrations/20260816000020_stock_commitment_bulk.sql
git log origin/main -- supabase/migrations/20260816000030_commitment_one_pass_and_allocatable_filter.sql
```

⚠ 開 PR 時注意 base 一定要選 **main**（前例 #629 base 選成 feature 分支，
GitHub 顯示 Merged 但從沒進 main，repo 與正式庫脫鉤一週）。

## 5. 驗收情境

1. 自由量 3 件 → 直配 2 件成功；訂單待取、庫存**未扣**；取貨後扣 2、單結案。
2. 自由量 3 件 → 直配 4 件被擋，錯誤訊息含可用量與入帳指引。
3. on_hand 5 但 promised 4 → 只能直配 1（不能賣別人在等的貨）。
4. 同客人二次直配 → append 進同一張單，不開新單；結案後再配 → 單重開。
5. 單價 0 送出被擋（前端＋伺服端）。
6. 池子（RR- ready）掛著的 SKU → 直配上限已扣除池子量。
7. 減抵單頁、收貨頁 covered 口徑不受影響（sentinel 團不與真團相撞）。
8. 會員端：客人看得到待取單、品項名正常顯示（非 sentinel 團名）。

## 6. 階段三（記錄存在、明確延後）

真正的 reservation 一等公民表（`stock_reservations`）可讓 grow/trim 收斂
邏輯退役，但要接上所有寫路徑的生命週期，風險大於收益。等階段二口徑
穩定運行一段時間後再評估。

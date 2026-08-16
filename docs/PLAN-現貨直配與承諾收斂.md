# PLAN — 現貨直配（不掛團配庫存給客人）與庫存承諾收斂

> 狀態：**規劃中**（2026-08-16）。分支：`claude/usage-guide-2lf0wx`。
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

### 2.1 UX

- 入口：**庫存總覽**（`/inventory`）每列加「配給客人」動作 → modal：
  客人搜尋（沿用加單頁的會員搜尋元件）、數量、單價（預填、可改）。
  分店帳號鎖自己店（同減抵單頁 `useUserBranchStoreId` 慣例）。
- 送出後顯示訂單號；客人取貨頁／會員中心立即看得到「待取」。
- 不做購物車：一次一個 SKU（庫存總覽是「看著這列貨想賣掉它」的場景；
  多品項需求走加單頁既有模式）。

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

### 2.4 明確不做

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

### 3.2 設計

```sql
CREATE FUNCTION public._sku_commitment(p_store_id BIGINT, p_sku_id BIGINT)
RETURNS TABLE (
  promised NUMERIC,  -- 客人單 ready/partially_completed/shipping 的未取量
                     --   （排除 store_internal、offset；品項 pending/reserved/ready）
  waiting  NUMERIC,  -- confirmed 一般單還在等貨的需求（同上排除）
  pool     NUMERIC   -- store_internal 容器單未取量（單頭未結案）
) LANGUAGE sql STABLE;
```

**回分項、不回單一數字**——各呼叫端的組合本來就不同（grow 要扣 waiting、
trim 不扣；settle 要另排除 backorder 列），統一成一個數字反而製造新 bug。
收斂的是「分項的定義」，組合留給呼叫端。

### 3.3 改造呼叫點（各基於時間最新版本改寫，CLAUDE.md 規則）

| 函式 | 最新版本 | 用到的分項 |
|---|---|---|
| `_grow_internal_pool` | 20260814010000 | promised + waiting + pool |
| `_trim_internal_pool` | 20260811000040 | promised + pool |
| `_advance_arrived_confirmed_orders` | 20260811000020 | promised |
| `_settle_arrived_backorders` | 20260811000050 | promised（另有 backorder 排除，保留在呼叫端） |

行為必須**逐字等價**（純收斂、零行為變更）。比對方式：改造前後對全站
(店, SKU) 各跑一輪分項值 dump，diff 必須為空。若某呼叫端口徑差異太大
無法無損套用，第一版**跳過該處**並在函式註解記錄差異，不硬改。

### 3.4 附帶收穫

上線當天拿 `_sku_commitment` 全站掃一輪
`pool > on_hand − promised`（判準含單頭 status，見 CLAUDE.md「到店了沒」教訓），
把現存壞帳清單交給 Alex 人工收尾。

---

## 4. 施工順序與部署

1. **Migration A**（階段二）：`_sku_commitment` ＋ 四個呼叫點改造＋等價驗證 SQL。
2. **Migration B**（階段一）：`rpc_create_spot_sale`（advisory lock 同
   `offsale:` 慣例、grants 收 `authenticated`、REVOKE anon）。
3. **前端**：`/inventory` 列動作＋ modal；orderTitle 例外確認；
   `apps/admin:verify` skill 走 UI 驗證。
4. **部署**：SQL 走 Management API（CLAUDE.md：不戳 pooler）；
   **當天 merge 進 main**（`git log origin/main -- <migration>` 查得到才算收工）。
5. **TEST 文件**：`docs/TEST-spot-sale.md`——驗收情境見 §5。

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

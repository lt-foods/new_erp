# TEST — 總倉派貨錯誤召回

> 對應：[[PRD-召回模組]]
> Migration：`20260808000100_recall_schema.sql` / `20260808000110_recall_rpcs.sql` / `20260808000120_order_summary_recall_flag.sql`
> 入口：`/hq/inbox?source=picking` → **已完成** → 該列 **🚨 召回**

---

## 0. 測前準備（本地 scratch DB）

不需要碰線上。開一個本機 Postgres，套完整 migration 鏈後灌測資：

```bash
initdb -D /var/tmp/pgtest/data -U postgres -A trust
pg_ctl -D /var/tmp/pgtest/data -o '-p 5433 -k /var/tmp/pgtest' start
# bootstrap：建 anon/authenticated/service_role 三個 role + auth schema（auth.uid / auth.jwt / auth.users）
# 再依檔名順序套 supabase/migrations/*.sql
```

以 admin 身分執行（不用真的登入，灌 claims 就好，見 CLAUDE.md）：

```sql
SELECT set_config('request.jwt.claims',
  '{"sub":"<uuid>","tenant_id":"<tenant>","app_metadata":{"tenant_id":"<tenant>","role":"admin"}}', false);
```

**測資形狀**（一張撿貨單 WAVE-R1，同一個 SKU 派三家店）：

| 店 | 派出 | 派貨單狀態 | 訂單 |
|---|---|---|---|
| 松山 S1 | 10 | 已收貨 | A 訂 4（未取）、B 訂 3（未取）、C 訂 3（**已取走**） |
| 永和 S2 | 6 | 已收貨 | D 訂 6（未取） |
| 湖口 S3 | 4 | **運送中**（沒收貨） | E 訂 4（未取） |

---

## A. 掃描（開單前）

`SELECT rpc_recall_scan_wave(<wave_id>);`

| 檢查 | 期望 |
|---|---|
| A.1 | 三格都回來，`qty_shipped` = 10 / 6 / 4 |
| A.2 | S1：`qty_unpicked=7`、`qty_picked_up=3`、`store_on_hand=7` |
| A.3 | S3：`qty_in_transit=4`、`qty_received=0`、`transfer_status='shipped'` |
| A.4 | `qty_recallable` = 派出 − 已退 − 其他召回單占用 − 拒收作廢 |
| A.5 | 同一 (店,品項) 有多列 pwi 指向同一張 transfer 時**不會重複計算**（DISTINCT） |
| A.6 | 撿貨單沒帶 campaign 的格子 `order_match='store_sku'`，UI 標「約略」 |
| A.7 | 店長帳號呼叫 → `權限不足：store_manager 不可操作召回單` |

---

## B. 開單 + 三桶快照

`rpc_create_recall(wave, 'wrong_sku', '派錯商品', [{S1,sku,10},{S2,sku,6},{S3,sku,4}])`

| 檢查 | 期望 |
|---|---|
| B.1 | 回 `recall_no` 形如 `RC2608080001`，`line_count=3`，status=`draft` |
| B.2 | S1 快照 = 在途 0 / 店裡 7 / 客人 3 |
| B.3 | S3 快照 = 在途 4 / 店裡 0 / 客人 0 |
| B.4 | 目標量 > `qty_recallable` → 擋下，訊息帶店名 + SKU |
| B.5 | draft 階段**不動**任何庫存 / 訂單（`stock_movements` 沒有新增） |
| B.6 | 派出量 > 訂單需求（總倉多撿）時，多的量落在「店裡未取」桶 |

---

## C. 發布（拆單 — 本需求的重點）

`rpc_issue_recall(<recall_id>)`

### C.1 全格召回

| 檢查 | 期望 |
|---|---|
| C.1.1 | S1 的 A(4)、B(3) 品項 → `status='cancelled'`、`recalled_at` 有值、`recall_id` 指到該單 |
| C.1.2 | C 的 `picked_up` 行**完全不動** |
| C.1.3 | 全品項都取消且沒收過錢的訂單 → `status='cancelled'` + `recalled_at` |
| C.1.4 | S3（A 桶）的訂單此時**還沒動**（貨還沒到店，等攔截） |
| C.1.5 | 已發布的單再呼叫一次 → 擋下（只有 draft 可發布） |

### C.2 部分召回 → 拆單

S1 只召回 5（訂單 A 訂 4、B 訂 3，後下單先召回）：

| 檢查 | 期望 |
|---|---|
| C.2.1 | B 整行 3 件 → cancelled + recalled_at |
| C.2.2 | A 拆成兩行：2 件 `cancelled`+`recalled_at`、2 件維持 `ready` |
| C.2.3 | ORD-A 訂單狀態維持 `ready`（客人還拿得到剩下 2 件） |
| C.2.4 | ORD-A 應收 = 2 × 單價（**不是** 4 × 單價）—— 被召回的行不收錢 |
| C.2.5 | 折扣按比例分到兩行，兩行加總 = 原折扣 |
| C.2.6 | `p_item_overrides={"<line_id>":[coi_id,…]}` 可指定只動某幾筆訂單 |

### C.3 訂單收尾

| 檢查 | 期望 |
|---|---|
| C.3.1 | 有 `picked_up` 品項、剩餘全被召回 → 訂單 `completed`（`_close_orders_all_items_settled`） |
| C.3.2 | 付過款 / 用過儲值金的訂單**不自動取消**，留在對帳頁「需退款」清單 |

---

## D. 回收三條路

### D.1 A 桶 — 攔截在途派貨單

`rpc_recall_intercept_transfer(recall, <TR-S3>)`

| 檢查 | 期望 |
|---|---|
| D.1.1 | 派貨單 → `cancelled`，notes 追加 `[召回攔截 RC…]`，`recall_id` 寫入 |
| D.1.2 | 總倉庫存 +4（`transfer_reject` inbound） |
| D.1.3 | ORD-E 的品項被取消、訂單 `cancelled` + `recalled_at` |
| D.1.4 | 對帳 `qty_intercepted=4`、差額歸 0 |
| D.1.5 | 對**已收貨**的派貨單攔截 → 擋下（「已收貨請走店端退回」） |
| D.1.6 | 只召回一部分時整張攔截 → 擋下（訊息說明請店家照常收貨） |
| D.1.7 | 不屬於本召回單撿貨單的 transfer → 擋下 |

### D.2 B 桶 — 店端出貨退回總倉

`rpc_recall_store_ship(recall, S1, [{sku, 7}])`

| 檢查 | 期望 |
|---|---|
| D.2.1 | 建出 `return_to_hq` transfer，`recall_id` 已寫入、狀態 `shipped` |
| D.2.2 | 店端庫存 −7；不夠時由 `rpc_outbound` 擋 `Insufficient stock` |
| D.2.3 | 對帳 `qty_in_return=7`、`qty_returned=0`（總倉還沒收） |
| D.2.4 | 總倉走既有 `/wms/inbound`（`rpc_receive_transfer`）收貨後 → `qty_returned=7`、在途歸 0 |
| D.2.5 | 超退（超過「目標 − 已回收 − 沖銷 − 在途」）→ 擋下，訊息列出四個數字 |
| D.2.6 | 店長只能退自家店；退別家 → `分店帳號只能處理自己店的召回` |

### D.3 C 桶 — 客人歸還

`rpc_recall_customer_return(recall, <ORD-C>, [{sku,3}])`

| 檢查 | 期望 |
|---|---|
| D.3.1 | 內部走既有 `rpc_create_order_return(restock_first=true)`：先入庫店端再出庫回總倉 |
| D.3.2 | 產生的 transfer `recall_id` 已補寫，總倉收貨後計入 `qty_returned` |
| D.3.3 | 超過客人已取量 → 由既有退貨 RPC 擋下 |

---

## E. 對帳與結案

| 檢查 | 期望 |
|---|---|
| E.1 | `v_recall_line_progress.qty_diff` = 攔截 + 已回總倉 + 沖銷 − 目標 |
| E.2 | 還有格子 `qty_diff < 0` → `rpc_close_recall` 擋下，訊息帶格數 |
| E.3 | 還有 `qty_in_return > 0`（總倉沒收完）→ 也擋下 |
| E.4 | `rpc_recall_write_off(line, qty, 原因)`：原因空白 → 擋下；量 > 目標−已回收 → 擋下 |
| E.5 | 沖銷後該格 `settled_at` 有值、差額歸 0，可結案 |
| E.6 | 結案後 `rpc_recall_store_ship` / 攔截 → 擋下（狀態不是 issued） |
| E.7 | **全流程結束後庫存歸位**：總倉回到原本數量、參與召回的店端該 SKU 歸 0 |
| E.8 | `issued` 的召回單不可作廢（`rpc_cancel_recall` 擋下，要沖銷後結案） |

---

## F. 顯示端

| 檢查 | 期望 |
|---|---|
| F.1 | admin 訂單明細：被召回的品項行紅標「**召回**」（優先於「斷貨」） |
| F.2 | admin 訂單明細單頭：整單召回顯示 `🚨 召回` |
| F.3 | 會員端 OrderCard：召回的品項刪除線 + 「召回」chip，不算進件數 |
| F.4 | 會員端 `v_customer_order_summary.items_total` 不含召回品項（金額對得起來） |
| F.5 | `/recalls` 列表：回收中 / 草稿 / 已結案 分頁；未回收 > 0 顯示紅字 |
| F.6 | `/recalls/detail`：六個 KPI + 對帳表 + 受影響訂單（「需退款」標黃底）+ 處理紀錄 |
| F.7 | 分店帳號開同一張召回單 → 只看得到自己店那幾格（`is_store=true`） |

---

## G. 權限

| 角色 | 掃描/開單/發布/攔截/沖銷/結案 | 檢視 | 店端退回 |
|---|---|---|---|
| owner / admin / hq_manager / `''` | ✅ | ✅ 全部 | ✅ |
| hq_accountant / assistant | ❌ | ✅ 全部 | ❌ |
| store_manager / store_staff / clerk | ❌ | ✅ **僅自家店** | ✅ 僅自家店 |

> 店端「自己店」由 `app_metadata.stores` 店名經 `_jwt_store_ids()` 推導 ——
> 本系統 JWT **沒有** `store_id` claim，這個坑踩過兩次（CLAUDE.md）。

---

## H. 月結 / 金額（回歸）

| 檢查 | 期望 |
|---|---|
| H.1 | 召回退回總倉的貨，月結生成器記 `return_out`（負）沖回分店應付（既有 `20260714000100`） |
| H.2 | 被攔截的派貨單 `cancelled` → 月結 `hq_inbound` 不計 |
| H.3 | 召回本身**不新增**任何月結分錄（沒有雙重記帳） |
| H.4 | `v_admin_orders_list` 的項數 / 件數 / 總金額不含召回品項 |

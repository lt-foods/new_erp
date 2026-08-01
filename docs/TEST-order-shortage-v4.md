# TEST — v_order_shortage v4 前瞻模型（訂單短少判定重寫）

> Migration：`20260801000000_v_order_shortage_v4_forward_looking.sql`
> 基底：`20260731000010`（v3 settled-po-gate）
> 動機事故：RR-173（環球店普渡補貨，貨已到店卻掛「訂單短少」72.45 件）

## 模型摘要

```
需求 = coi.status='pending' × co.status IN (pending/confirmed/shipping)、非 offset
     + offset 抵減單（負量）非 cancelled 全算
供給 = 經總倉現貨 on_hand + PO 在途(sent/partial 未收餘量) + 調撥在途(shipped qty_shipped)
閘門 = 保留 v3「採購已定案」（存在 sent/partial/fully/closed PO 的 SKU 才判）
短缺 = GREATEST(0, 需求 − 供給)，展開到非 offset 的 pending 品項
```

v3 三個結構性破洞 → v4 對應驗證項目：
1. 非 PO 入庫（盤點/調帳）不算供給 → **A 組**
2. 終態 ready 的單（補貨內部單、未取會員單）永遠算需求 → **B 組**
3. 累計 GR 掩蓋真短缺（殭屍 shipping 單隱形）→ **C 組**

## 驗證項目

### A. 供給側：非 PO 入庫要消警報
- [x] **A.1** RR-173 場景：貨走 `stocktake_gain` 入總倉、再派到店 → 該 SKU 不再列短缺
      （prod 驗證 2026-08-01：`G00291-02` 從清單消失）
- [x] **A.2** 同類假警報一併消失（prod：`G01095-01` 消失）
- [ ] **A.3** 手動調帳 `manual_adjust` +N 入總倉 → 供給即時反映、警報消失

### B. 需求側：貨已到店 = 離開需求池
- [x] **B.1** 補貨內部單（order_kind='restock'）收貨後停在 ready → 不算需求
      （prod 驗證：view 內 restock×ready 列數 = 0；v3 時代 169 張/4,700 件掛在池裡）
- [x] **B.2** view 只展開 pending/confirmed/shipping 的單（prod：ready/completed 列數 = 0）
- [ ] **B.3** 抵減單（offset、qty<0）在 confirmed 或 ready 都仍計入需求（負量不可因 ready 被丟）
- [ ] **B.4** 會員取貨（completed）後該品項需求消失

### C. 真短缺不能漏
- [x] **C.1** 現貨 0、無在途、有 pending 訂單的 SKU 要列出
      （prod 驗證：`G00192-02` 起士米餅，短缺 33、28 列保留）
- [x] **C.2** 殭屍 shipping 單（transfer 已收/取消、訂單卡 shipping、無貨無在途）要浮出
      （prod 抽驗：`G00234-02`、`G00651-03` 五、六月卡單，v3 隱形 → v4 列出）
- [ ] **C.3** shipping 單若貨真的在車上（transfer status='shipped'）→ 調撥在途蓋住、不列短缺

### D. 閘門與邊界
- [ ] **D.1** 新檔期收單、尚無任何 PO 的 SKU → 不列（不重演 8,733 筆爆量）
- [ ] **D.2** 只剩 cancelled PO 的 SKU → 不列（斷貨連動處理，不重複）
- [ ] **D.3** draft PO 不算供給：擬單期間仍列警報（「已定案」語意）

### E. 下游相容（欄位同名同序同型別）
- [x] **E.1** `rpc_hq_shortage_orders`（收件匣訂單短少分頁）免改可跑
      （prod 驗證：total=466、rows 正常、~240ms）
- [x] **E.2** `v_hq_exceptions` customer_shortage 分支免改（prod：466 筆）
- [x] **E.3** view 掃描效能與 v3 同量級（prod：~190ms）
- [ ] **E.4** 收件匣「訂單短少」badge 數 = 異常頁 customer_shortage tab 數

## Prod 驗證紀錄（2026-08-01 部署當日）

| 指標 | v3（部署前） | v4（部署後） |
|---|---|---|
| 列數 / 訂單 / SKU | 313 / 306 / 11 | 565 / 466 / 64 |
| RR-173（假警報） | 列出 | ✅ 消失 |
| G01095-01（假警報） | 列出 | ✅ 消失 |
| G00192-02（真短缺 33） | 列出 | ✅ 保留（28 列） |
| ready/restock-ready 污染列 | 有 | ✅ 0 |

列數 313→565 是**揭露 v3 漏抓的存量殭屍單**（多為五、六月卡 shipping 的舊單，
抽驗屬實），非誤報增加。營運後續需用收件匣「通知客戶／等下批／改派／取消」清理。

## Rollback

```sql
-- CREATE OR REPLACE VIEW 回 20260731000010（v3）版本即可，無資料變更。
```

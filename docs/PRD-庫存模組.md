---
title: PRD - 庫存模組
module: Inventory
status: draft-v0.1
owner: www161616
created: 2026-04-20
tags: [PRD, ERP, 庫存, Inventory]
---

# PRD — 庫存模組（Inventory Module）

> 零售連鎖 ERP，總倉 1 + 門市 100 + SKU 15,000。
> 本文件為 **v0.1 checklist 版**，勾選用於追蹤完成度；細節待後續 v0.2 展開。
>
> **v0.2 增補**：見 [[PRD-庫存模組-v0.2-addendum]]（transfer_type enum / 需求表 / 欠品 roll-over / 互助交流 / 88 折出清 / 店轉店月結算）。

---

## 1. 模組定位
- [ ] 本模組負責「庫存數字的唯一真相來源（Single Source of Truth）」
- [ ] 所有會動到庫存的行為（採購收貨、配貨、銷售、退貨、盤點、損耗）都必須透過本模組的異動 API
- [ ] 其他模組（採購、銷售、配貨）**不得**直接 UPDATE 庫存表

---

## 2. 核心概念 / 名詞定義
- [ ] **倉別（Location）**：1 個總倉 + 100 個門市倉（每店 1 倉，必要時可擴充為多倉）
- [ ] **庫存單位（Stock Item）**：`tenant_id + location_id + sku_id`（+ 未來可擴充 batch_id / expiry）
- [ ] **可用庫存（Available）** = 實際庫存 − 已配未出 − 已預留
- [ ] **在途庫存（In-transit）**：配貨單已出但門市未收
- [ ] **庫存異動（Stock Movement）**：所有進出庫的原子紀錄（append-only）

---

## 3. Goals
- [ ] G1 — 庫存準確率 ≥ 98%（每月盤點差異率 < 2%）
- [ ] G2 — 總部可即時查詢 100 店 × 15,000 SKU 的當下庫存，查詢延遲 ≤ 3 秒
- [ ] G3 — 任何庫存異動皆可追溯來源單據（可回答「為什麼這個商品少了 3 個？」）
- [ ] G4 — 支援並發：同一 SKU 多門市同時扣庫存不會發生超賣或負庫存（除非設定允許）

---

## 4. Non-Goals（v1 不做）
- [ ] ❌ 批號管理（P1，視業態開啟）
- [ ] ❌ 效期管理（P1）
- [ ] ❌ 序號管理（3C / 高單價商品才需要，P2）
- [ ] ❌ 多儲位（同一門市內細分貨架，P2）
- [ ] ❌ 寄售 / 寄賣庫存（P2）

---

## 5. User Stories

### 總倉倉管
- [ ] 作為總倉倉管，我要能看到總倉每個 SKU 的即時庫存與在途數
- [ ] 作為總倉倉管，我要能執行「收貨入庫」將採購單的商品增加到總倉
- [ ] 作為總倉倉管，我要能執行「配貨出庫」將商品減少並產生在途紀錄

### 店長
- [ ] 作為店長，我要能查看本店所有 SKU 當下庫存（不能看其他店）
- [ ] 作為店長，我要能確認收貨，系統把在途轉為本店庫存
- [ ] 作為店長，我要能發起盤點、輸入實盤數、產生差異調整單

### 店員
- [ ] 作為店員，我在 POS 結帳時系統自動扣本店庫存
- [ ] 作為店員，我要能查詢「本店目前還有幾個某商品」（不能跨店查）

### 採購 / 總部老闆
- [ ] 作為採購，我要看到全集團每個 SKU 的總庫存與分店分佈
- [ ] 作為總部老闆，我要看到「庫存金額」「滯銷」「缺貨」「即將缺貨」四個儀表板

---

## 6. Functional Requirements

### 6.1 庫存查詢
- [ ] **單店單 SKU**：輸入 store + sku，回傳 available / on-hand / in-transit / reserved
- [ ] **全集團單 SKU**：輸入 sku，回傳 100 店 + 總倉的分佈
- [ ] **單店全品**：列出本店所有庫存 > 0 的 SKU（可篩選、可匯出）
- [ ] **低於安全庫存清單**：各店 / 全集團視角
- [ ] **滯銷清單**：N 天無異動且庫存 > 0 的 SKU（N 可設定）
- [ ] **庫存金額彙總**：依成本法計算（先進先出 or 移動平均，**需確認**）

### 6.2 入庫（Inbound）
- [ ] 來源：採購收貨、門市退貨回總倉、盤盈、其他調整（+）
- [ ] 每筆入庫產生一筆 `stock_movement`，類型標明
- [ ] 必填：sku、location、quantity、source_doc_id、operator、timestamp
- [ ] 成本寫入（移動平均法 / FIFO — 待決策）

### 6.3 出庫（Outbound）
- [ ] 來源：POS 銷售、配貨出總倉、報廢、損耗、盤虧、退供應商
- [ ] 出庫前檢查可用庫存，若不足：
  - [ ] 預設：阻擋
  - [ ] 特殊權限：允許負庫存（需 log 原因）
- [ ] 每筆出庫產生 `stock_movement`

### 6.4 調撥（Transfer）
- [ ] 支援 **總倉 → 門市**（主要）
- [ ] 支援 **門市 → 門市**（需總部審核開關）
- [ ] 支援 **門市 → 總倉**（退回、調回）
- [ ] 狀態流：`draft → confirmed → shipped（來源扣、在途+） → received（在途−、目的地+）`
- [ ] 差異處理：收貨數 ≠ 出貨數時自動產生差異調整單等待審核

### 6.5 盤點（Stocktake）
- [ ] **類型**：全盤 / 抽盤 / 循環盤點
- [ ] **流程**：建立盤點單 → 凍結（可設定是否允許交易）→ 輸入實盤 → 差異確認 → 產生調整異動
- [ ] 支援手持 PDA / 條碼掃描輸入（P1 具體，API 先預留）
- [ ] 盤點結果 → 自動產生 **盤盈入庫** 或 **盤虧出庫** 異動

### 6.6 安全庫存 / 補貨建議
- [ ] 每個 `store × sku` 可設定：安全庫存、補貨點、最大庫存
- [ ] 支援批次設定（依類別、依店型套用）
- [ ] **P1**：依動銷率自動計算建議值

### 6.7 庫存異動明細（Movement Log）
- [ ] 所有異動 append-only，不可修改、不可刪除
- [ ] 錯誤更正 → 產生**反向異動**，不改原紀錄
- [ ] 每筆異動可穿透到來源單據（採購單 / 配貨單 / 銷售單 / 盤點單）
- [ ] 提供「某 SKU 某期間所有異動」的 timeline 查詢

---

## 7. 非功能需求（NFR）
- [ ] **資料一致性**：所有異動使用 DB transaction；跨表以 outbox pattern 或 2PC 保證（視技術選型）
- [ ] **併發**：同一 `store × sku` 的扣庫存採 row-level lock 或樂觀鎖（版本號），避免超賣
- [ ] **效能**：
  - [ ] 單 SKU 查詢 P95 < 200ms
  - [ ] 100 店 × 15k SKU 全表查詢匯出 < 30s
  - [ ] POS 扣庫存 API P95 < 300ms
- [ ] **稽核**：所有異動留下 `operator_id`、`ip`、`user_agent`、`timestamp`
- [ ] **備份**：庫存表每日全量備份 + CDC 紀錄
- [ ] **多租戶**：所有表 + 查詢必帶 `tenant_id`（v1 只有 1 tenant 但架構預留）

---

## 8. 權限（RBAC 對應本模組）

| 權限 | 總部老闆 | 採購 | 總倉倉管 | 店長 | 店員 |
|---|:-:|:-:|:-:|:-:|:-:|
| 查全集團庫存 | ✅ | ✅ | ✅ | ❌ | ❌ |
| 查本店庫存 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 總倉入庫 | ❌ | ✅ | ✅ | ❌ | ❌ |
| 發起配貨 | ✅ | ✅ | ✅ | ❌ | ❌ |
| 收貨確認 | ❌ | ❌ | ❌ | ✅ | ❌ |
| 盤點 | ✅ | ❌ | ✅ | ✅ | ❌ |
| 手動調整庫存 | ✅ | ❌ | ✅（需事由）| ❌ | ❌ |
| 允許負庫存 | ✅ | ❌ | ❌ | ❌ | ❌ |

- [ ] 上表權限納入 `permissions` 設定檔
- [ ] 所有「手動調整」必填事由，寫入 movement 備註

---

## 9. 資料模型草稿（待 Review）

- [ ] `locations` — 倉別（總倉 / 門市）
- [ ] `skus` — 商品主檔（引用，非本模組）
- [ ] `stock_balances` — `(tenant_id, location_id, sku_id) → on_hand, reserved, in_transit, avg_cost, version`
- [ ] `stock_movements` — append-only：`id, tenant_id, location_id, sku_id, qty(+/-), type, source_doc_type, source_doc_id, cost, operator, created_at`
- [ ] `transfers` — 調撥單頭 + 明細
- [ ] `stocktakes` — 盤點單頭 + 明細（系統數 / 實盤數 / 差異）
- [ ] `reorder_rules` — `(location_id, sku_id) → safety_stock, reorder_point, max_stock`

---

## 10. 與其他模組的整合點

- [ ] **採購模組** → 呼叫入庫 API（收貨時）
- [ ] **銷售 / POS 模組** → 呼叫出庫 API（結帳時）、退貨時呼叫入庫
- [ ] **配貨 / 調撥模組** → 本模組提供核心流程
- [ ] **報表模組** → 讀 `stock_balances` + `stock_movements`
- [ ] **主檔模組** → 讀取 SKU / Location

---

## 11. 驗收準則（Acceptance Criteria）
- [ ] 在採購收貨完成後，總倉該 SKU 的 `on_hand` 正確增加
- [ ] 發起配貨單「確認出貨」後：總倉 `on_hand` 扣減、`in_transit` 增加
- [ ] 門市「收貨確認」後：`in_transit` 扣減、門市 `on_hand` 增加
- [ ] POS 賣出 1 件 → 本店 `on_hand` 扣 1、產生一筆 type=sale 的 movement
- [ ] 盤點差異 +3 → 產生 type=stocktake_gain 的 movement，`on_hand` +3
- [ ] 同一 SKU 被兩支手機同時結帳（只剩 1 件）→ 僅一筆成功、另一筆回應「庫存不足」
- [ ] 店員打 API 想查別店庫存 → 403 Forbidden
- [ ] 任意異動均可在「異動明細」頁找到並穿透到來源單據

---

## 12. Open Questions（請回答以推進 v0.2）

- [x] **Q1 成本法**：→ **移動平均（Moving Average）**。業態團購店無批次追溯需求；schema 已完整支援（`stock_balances.avg_cost` + trigger）。若未來需 FIFO，新增 `stock_batch_balances` 批次表升級（P2）。（2026-04-21）

  **trade-off 已接受**：進貨價差大的月份毛利會被平滑化、無法精算單一促銷活動成本；團購店看月毛利率足夠。
- [x] **Q2 效期 / 批號**：→ **追效期、不追批號召回（FEFO 批次層級）**。（2026-04-21）

  **業態事實**：80% 商品有效期、含過期會出問題的商品（乳製品 / 熟食）、有即期品促銷需求。

  **決定範圍**：
  - ✅ 每批入庫記 `expiry_date`（`stock_movements.expiry_date` 現有欄位）
  - ✅ 新增 `stock_lots` 批次層級餘額表（v0.2 schema 變動）
  - ✅ FEFO（先到期先出）出貨邏輯
  - ✅ 即期品自動促銷（到期前 X 天自動套 `prices.promo`）
  - ✅ 近期到期報表（30 / 7 天警示）
  - ✅ 到期推播（通知模組）
  - ❌ 不做批次客戶追蹤 / 召回
  - ❌ 不做批號印發票

  **過期寬鬆度（B）+ 分類設定**：
  - `categories` 新增 `expiry_grace_days`（NOT NULL DEFAULT 0）
  - 每個分類可獨立設定過期後寬限天數
  - POS 出貨邏輯：
    ```
    if today > expiry_date + category.expiry_grace_days: 擋下
    elif today > expiry_date: 警告彈窗 + 店員輸入原因 + audit log
    else: 正常
    ```
  - 預設值（店家可改）：短效食品 0 天 / 長效食品 3 天 / 日用品 7 天 / 罐頭 30 天

  **20% 無效期商品**：`expiry_date = NULL`，FEFO 時視為無到期限制（最後才扣）。

  **v0.2 schema 變動清單**：
  1. 新增 `stock_lots` 表（批次餘額）
  2. `categories` 新增 `expiry_grace_days INTEGER NOT NULL DEFAULT 0`
  3. 改 `rpc_inbound`：建 lot 而非加總
  4. 改 `rpc_outbound`：FEFO 扣 lots
  5. 新增 `rpc_mark_expired`（每日 job）
  6. 新增 `rpc_near_expiry_report`
- [x] **Q3 POS 來源 + 扣庫存時機**：→ **自建 POS（Web-based，整合 LIFF / 會員 / 儲值金 / 點數）**；扣庫存於 **結帳完成當下即時扣**。（2026-04-21）

  **業態事實**：目前無既有 POS 系統。團購店 POS 本質是「取貨結算點」，比傳統零售 POS 簡單。

  **技術方向**：
  - 前端：Next.js / React + Supabase（同 ERP 後台架構）
  - 流程：掃 LIFF QR（會員）→ 掃商品條碼或取貨單 → 選付款方式 → `rpc_complete_pos_sale` 一次扣庫存 + 賺點 + 開發票
  - 併發：現有 `rpc_outbound` 已用 `SELECT FOR UPDATE` 防超賣
  - 離線：依 Q15 「只讀不寫」

  **硬體**（待採購）：USB 掃描槍、熱感發票機（ESC-POS）、平板/筆電、錢箱。不需整套 POS 機。

  **v1 決策**（2026-04-21）：
  - **發票 v1 不開**（P1 再加）— ⚠️ 需注意法規：台灣營業稅法 **營業額 > 20 萬/月 必須開統一發票**。100 門市同一 `tenant_id`（= 同一公司）幾乎鐵定超過此門檻。v1 若不開需確保有合法因應（例：分開稅籍、代收代付模式、或只做內部試營運）。建議與會計師確認後再上線。
  - **付款 v1 只收現金**，不整合信用卡 / LINE Pay / 街口 / 儲值金 / 點數扣抵（P1 再加）。會員模組 `rpc_wallet_spend` / `rpc_spend_points` 仍保留 schema 與 RPC，僅 POS UI 暫不串接。
  - 這兩個決策大幅簡化 POS v1 開發範圍。
- [x] **Q4 負庫存**：→ **預設擋、店長以上權限可解鎖（必填原因）**。（2026-04-21）

  **實作**：
  - DB 層 `stock_balances.on_hand` **不加** `>= 0` CHECK，允許負數（補單 / 跨期 / 盤點差異才能運作）
  - `rpc_outbound` 預設 `p_allow_negative = FALSE`（擋下）
  - POS UI：若扣到負，回錯誤 `'Insufficient stock'` + 店員看到紅色提示
  - **解鎖按鈕**：店長以上角色看到「允許負庫存」按鈕，點擊 → 彈窗輸入原因 → 呼叫 `rpc_outbound(..., p_allow_negative => TRUE, notes => p_reason)`
  - `stock_movements.notes` 記錄解鎖原因，`operator_id` 是誰
  - 稽核查詢：每月報表列出「本月所有負庫存解鎖紀錄」
- [x] **Q5 門市互調**：→ **完全開放、事後通知總部**。（2026-04-21）

  **業態理由**：團購店下訂後備貨、客人等貨時間敏感；店長互調最快解決缺貨。

  **實作**：
  - `transfers` 表已支援任意兩倉互調（不限總倉出發）
  - B 店店長可直接建 transfer：`source_location = C 店`, `dest_location = B 店`
  - 流程縮短為 `draft → shipped → received`（**跳過** `confirmed` 審核步驟）
  - **透明追蹤不可少**：
    - 所有互調進 `transfers` + `stock_movements`，完整 audit trail
    - 總部 dashboard 即時顯示「進行中的門市互調」
    - 推播通知總部（通知模組）
    - 每月稽核報表：列出所有互調明細、異常大量者人工檢視
  - 若未來發現亂用可隨時收緊為 Q5-B（需審核），schema 不變
- [x] **Q6 凍結期間交易**：→ **依盤點類型預設、可手動覆寫**。（2026-04-21）

  | `stocktakes.type` | 預設 `freeze_trx` | 交易行為 |
  |---|---|---|
  | `full`（全盤）| `TRUE` | POS / 收貨 / 調撥全凍結（利用夜間或公休日）|
  | `partial`（抽盤）| `FALSE` | POS 正常；收貨 / 調撥 / 手動調整凍結 |
  | `cycle`（循環）| `FALSE` | 全部正常（每天掃少量 SKU，不影響營業）|

  **實作**：
  - `stocktakes.freeze_trx` schema 已存在
  - 建盤點單 UI：依選定 `type` 自動帶入預設值，店長可覆寫
  - `rpc_outbound` / `rpc_inbound` 前置檢查：若該 location 存在 `stocktakes.status IN ('counting') AND freeze_trx = TRUE`，擋下（但 cycle 類例外，因預設 FALSE）
  - 盤點後差異計算：`system_qty` 快照於盤點開始時記錄（現有 `stocktake_items.system_qty` 設計）；即使未凍結，差異仍精確（快照 + 期間 POS 賣出 = 推算實盤）
- [x] **Q7 預留庫存（reserved）**：→ **做、下單當下即 reserve**。（2026-04-21）

  **業態理由**：團購店典型流程「開團收單 → 到貨 → 取貨」。顧客下單先鎖最公平；reserved > on_hand 於預購期是常態、無害。

  **實作**：
  - `stock_balances.reserved` schema 已存在
  - `available = on_hand - reserved`（可為負數，代表「待進貨量」）
  - **訂單建立時**（訂單 / 銷售模組）：呼叫新 RPC `rpc_reserve(location, sku, qty)` → `reserved += qty`
  - **取消訂單 / 退單時**：`rpc_release(location, sku, qty)` → `reserved -= qty`
  - **取貨（出貨完成）時**：`rpc_outbound` 扣 `on_hand` + `rpc_release` 釋放 `reserved`
  - **到貨後若 `reserved > on_hand`**：列出「履約不足清單」，店長人工處理（退款 / 換貨 / 延後）

  **v0.2 schema 變動**：
  1. 新增 `rpc_reserve` / `rpc_release` RPC
  2. 團單層級「收單上限」留給**訂單 / 取貨模組**（尚未建立），不在庫存模組處理
  3. 與 Q2 `stock_lots`（FEFO）整合：reserved 目前以 SKU 層級、不細分批次（預留不綁特定批）
- [x] **Q8 舊系統資料搬遷**：→ **全盤後開帳 + 單店 pilot + 漸進推廣**。（2026-04-21）

  **現況事實**：
  - 資料來源混合（舊 ERP + Excel）
  - 舊庫存數字**不準**，不能直接搬
  - Cut-over 策略：pilot 單店 → 確認穩定 → 漸進推廣

  **搬遷計劃**：

  **Phase 0 — 準備（T-4 週）**
  - 新系統 dev 環境部署完成（5 份 schema + seed 資料）
  - 主檔匯入：SKU / 分類 / 品牌 / 已知條碼（爬蟲 + CSV + 邊用邊建策略，見商品模組 Q13）
  - 選定 pilot 門市（建議管理最完善的一間，降低風險）

  **Phase 1 — Pilot（T-2 ~ T-0）**
  - Pilot 門市 + 總倉 **實體全盤**（停業 1 天 / 夜間作業）
  - 盤點結果轉「開帳異動」：每個 `(location, sku)` 寫一筆 `stock_movements`（type=`manual_adjust`, reason=`opening_balance`）
  - Trigger 自動建 `stock_balances`
  - Pilot 門市上線運行 **2~4 週**、觀察：
    - POS 扣庫存正確性
    - 收貨 / 調撥流程
    - 盤點差異率
    - 店員 UX 回饋

  **Phase 2 — 漸進推廣（T+4 ~ T+16）**
  - 依 pilot 經驗調整後，每週上線 5~10 間門市（避免一次切換風險）
  - 每店上線前獨立全盤
  - 100 店估 **10~12 週** rollout
  - 總倉已於 Phase 1 上線，新門市上線即可接入

  **Phase 3 — 舊系統退役（T+16+）**
  - 舊 ERP 轉**唯讀**保留 3~6 個月（查歷史用）
  - 舊 Excel 停止維護
  - 資料完整遷入新系統後可 archive

  **關鍵原則**：
  - ❌ 不搬舊 `stock_movements`（舊資料不準，帶進新系統會污染）
  - ✅ 舊系統歷史保留唯讀，新系統「舊系統參考連結」欄位可跳轉
  - ✅ 每店上線**強制全盤**，不圖方便省略
  - ✅ Pilot 期間允許 bug / 流程調整（正式推廣前修穩）

---

## 13. 下一步
- [ ] 回答 Q1~Q8 → 進入 v0.2（展開每支 API、欄位、UI wireframe）
- [ ] 依 v0.2 拆 Sprint / Ticket
- [ ] 先做 Spike：多租戶 + 併發扣庫存 的資料模型 POC

---

## 相關連結
- [[專案總覽]]
- [[docs/architecture]]
- 舊系統參考：`lt-erp/Inventory.html`, `InventoryLog.html`, `InventoryView.html`, `Stocktake.html`

---
title: PRD - WMS 倉儲管理工作台
module: WMS
status: draft-v0.1
owner: alex.chen
created: 2026-05-08
related: [PRD-採購模組, PRD-庫存模組, PRD-訂單取貨模組]
tags: [PRD, ERP, WMS, 倉儲, Receiving, Picking, Wave, Outbound]
---

# PRD — WMS 倉儲管理工作台

> 業界稱 Warehouse Management System(WMS),本系統屬「Hub-and-Spoke 配送中心型」
> (Distribution Center / DC):總倉 1 + 100 加盟店,15k 品項,無自有倉儲深架。
>
> 本 PRD 不取代既有 [[PRD-採購模組]] / [[PRD-庫存模組]] / [[PRD-訂單取貨模組]],
> 而是把橫跨它們的「倉儲日常作業層」(Receiving / Picking / Outbound)抽出來,
> 讓總倉操作人員有「全局可見、單一入口」的工作台。

---

## 1. 文件背景

### 觸發來源
2026-05-08 與 Alex 討論期間的反饋:
- 「批次撿貨工作站可以針對所有清單分派商品,不要用 PO 來當 group」
- 「但是我要知道訂購多少東西已經到貨可以出貨了」
- 「我在進貨的時候每一張 PO 來的數量不一定正確」
- 「也會分批來」
- 「我想要一個比較完整的 WMS」

### 為什麼要拉出這份 PRD
既有三份 PRD(採購 / 庫存 / 訂單取貨)各自完整,但**現場日常作業跨三本**:
- 倉管:今天進貨多少?哪幾筆短少?哪幾筆還沒到?
- HQ:哪些客戶訂單會因短少拿不到貨?
- 派貨員:同一張 PO 分批進、跨 PO 同品項要合併出 — 怎麼操作?

→ 缺一個「橫切面工作台」,把上述三模組的相關狀態整合在一處。

---

## 2. 名詞定義

| 詞 | 業界對應 | 說明 |
|---|---|---|
| 進貨 GR | Goods Receipt | 供應商貨到、實際收下並登記數量 |
| 撿貨單 Wave | Pick Wave / Pick List | 一批要從總倉拿出去的單,含 N 個品項 × M 個目的店 |
| 派貨工作台 | Wave Planning Workbench | 規劃今天要建哪些 Wave、分多少給哪家店 |
| 出貨 / Transfer | Outbound / Internal Transfer | Wave 撿完後產生的「總倉 → 分店」轉貨單 |
| 短少 | Shortage | PO 已 fully_received 但實到 < 訂購,差額永遠不會到 |
| 在途 | In-transit | PO 還沒 fully_received,訂購量 − 已到貨,還會繼續來 |
| Hub-and-Spoke | DC 配送模式 | 總倉只做拆分配送、不做長期儲存(cross-dock 為主) |
| Put-to-Store | 零售業專用詞 | 進貨時直接拆給各分店,不入儲位(等同 cross-dock) |
| FEFO | First Expired First Out | 先到期先出貨(批號/效期 v2 才做) |

---

## 3. 範圍 (Scope)

### 3.1 本 PRD 包含
- 進貨待辦(Receiving Workbench) — 新頁
- PO 到貨進度(PO Receipt Tracking) — 新功能
- 撿貨工作站 v3(Picking Workstation Upgrade) — 既有頁強化
- 短少訂單看板(Order Shortage Dashboard) — 新 view + 入口
- 出貨集貨(Outbound Dock) — 既有 `/transfers/dispatch` 改名 + 整理
- 異常處理(Exception Panel) — 新頁,集中短少 / 損耗 / 過量
- Sidebar 重組 — 把上述頁納入「倉儲」分組
- 統一收件匣 `/hq/inbox` 整合短少訂單來源

### 3.2 本 PRD 不包含
- 批號管理(batch_no / lot)— v2
- 效期管理 / FEFO — v2
- 多儲位(zone / aisle / bin / pick path optimization)— v2
- 條碼撿貨 / RF gun / Voice picking — v2,需硬體
- 退貨處理(RMA / vendor return)— 既有 PRD 涵蓋
- 盤點(cycle count / physical count)— [[PRD-庫存模組]] 已涵蓋
- 補貨流程(restock_request)— 已單獨在 [[PRD-訂單取貨模組-v0.2-addendum]],與本 WMS **平行不重疊**

---

## 4. Goals / Non-Goals

### Goals
- **G1** — 倉管人員從「今天進什麼貨」到「派完出去」**單一頁面內完成**,無需切換多頁。
- **G2** — 任何時刻、任何品項,可以在 5 秒內看到「訂多少 / 到多少 / 撿多少 / 派多少 / 還缺多少」。
- **G3** — 短少進貨自動連鎖反應到客戶端 — HQ 看得到「哪些訂單拿不到貨」、可直接通知/取消。
- **G4** — 撿貨工作站不再要求每張 PO 各別建 wave,**一次操作可一張或多張 wave**(已實作 Phase 1)。
- **G5** — 排除「補貨流程的 PO」混進撿貨工作站(只專注客戶訂單驅動的派貨)。

### Non-Goals (v1 不做)
- ❌ 條碼掃描撿貨(需 RF/PDA 硬體)
- ❌ 批號 / 效期追蹤
- ❌ Pick path 最佳化(總倉沒分區)
- ❌ ABC 分類儲位
- ❌ 自動化 wave generator(系統自動排程,不靠人按按鈕)

---

## 5. User Stories

### 倉管(總倉)
- [ ] 早上一進公司,我打開「**進貨待辦**」就能看到今天/這週會到的所有 PO,跟昨天到一半的 PO。
- [ ] 收貨時,我要能輸入「實際到貨量」並標記破損;系統記錄差異原因,**不需要剛好等於訂購量**。
- [ ] 同一張 PO 可分批收 — 第一次到 60 件、明天再到 40 件,系統自動疊加並更新狀態。
- [ ] 收完所有貨後,我打開「**派貨工作台**」一張矩陣表看到所有未派完品項,直接填數字派貨。

### 派貨員 / HQ 主管
- [ ] 我要能在派貨工作台上,**一眼看出**「這品項還會再來貨」(在途)還是「這品項不會再來了」(短少)。
- [ ] 我要能看到 KPI 儀表:今日進貨總量 / 今日派貨總量 / 待派需求 / 短少訂單數。
- [ ] 對於短少的品項,我要能點下去看「具體哪幾家分店哪幾位顧客拿不到貨」,直接通知客戶。
- [ ] 派完貨後,我要能批次列印出貨單,**按司機路線分組**(如果有設路線)。

### HQ 客服
- [ ] 我要能在 [/hq/inbox](apps/admin/src/app/(protected)/hq/inbox/page.tsx) 看到「短少訂單」這個來源,點進去看明細,逐筆處理(通知 / 取消 / 改派)。
- [ ] 通知後系統要記錄「已通知」狀態,不要重複通知客戶。

---

## 6. Functional Requirements

### 6.1 進貨待辦頁 — `/wms/receiving`(新)

**目的**:今天/這幾天會到的貨,什麼狀態。

**頁面結構**
```
┌─ KPI bar ─────────────────────────────────────┐
│  本週應到 12 PO · 已收 8 · 部分收 3 · 未收 1   │
└────────────────────────────────────────────────┘

┌─ Filter ──────────────────────────────────────┐
│  日期 [____~____]  供應商▼  狀態▼  品溫▼     │
└────────────────────────────────────────────────┘

┌─ PO list ─────────────────────────────────────┐
│ PO 編號         供應商    應到   品項 訂購 已到 差   狀態      [動作]│
│ PO2605080044   弘盛       05/08  3   1500 1500  0   ✓全收    [明細]│
│ PO2605080043   宜禾       05/08  2   720  720   0   ✓全收    [明細]│
│ PO2605080042   宏全       05/08  1   1000 500  500  ⏳部分收  [收貨]│
│ PO2605070038   森永       05/07  5   4500 0   4500  🔴未收    [收貨]│
└────────────────────────────────────────────────┘
```

**欄位 / Action**
- [ ] 列點擊 → 展開該 PO 完成度 timeline(見 6.2)
- [ ] 「收貨」按鈕 → 跳到既有 [purchase/orders/receive](apps/admin/src/app/(protected)/purchase/orders/receive/page.tsx)
- [ ] 「明細」按鈕 → 看該 PO 已收/未收 line 明細
- [ ] 列上 hover 顯示「品溫(冷凍/冷藏/常溫)」、「總金額」

**資料來源**
- 既有 `purchase_orders` + `goods_receipts` + `goods_receipt_items` JOIN 出彙總
- 視 v 表複雜度決定是否新建 `v_po_receipt_progress` view

### 6.2 PO 到貨進度(timeline)— PO 列展開或單獨頁

**目的**:看這張 PO 的所有 GR 歷程,搞清楚「分批進貨」狀態。

```
PO2605080044 — 訂 100 件
├─ 05/08 13:30  GR-001  收 60 件   操作員:王小明  ✓
├─ 05/12 09:15  GR-002  收 30 件   操作員:王小明  ✓
└─ 05/13 已關單  總計 90 件,差 5 件 → 標記短少
                                   [補建 PR / 通知客戶]
```

**欄位**
- [ ] PO 訂購量 / 累積到貨 / 累積差異
- [ ] 每筆 GR 顯示:時間 / 數量 / 損耗 / 操作員 / variance_reason
- [ ] PO status 變化:sent → partially_received → fully_received

### 6.3 撿貨工作站 v3 — `/picking/workstation`(既有頁強化)

**已完成 (Phase 1)**:全清單合併矩陣 + FIFO 切多 PO + 訂購欄。

**本 PRD 補強**:
- [x] 加 4 欄:訂購 / 已到 / **在途** / **短少** / 已撿 / 可分配 / 合計(已實作,等 view migration)
- [ ] 短少品項 **紅色警示** + 點擊看「影響的訂單清單」彈窗
- [ ] 在途品項 **黃色提示**,hover 顯示「還會來幾件、預計到貨日」
- [ ] 頁頂加 **KPI bar**:今日進貨總量 / 待派需求 / 已建 wave 數 / 缺貨警示數
- [ ] 排除 restock-sourced POs(view 層,已寫 migration 待 push)

### 6.4 短少訂單看板 — 新 view + `/hq/inbox` 新來源

**Schema 變更(新 migration)**
```sql
CREATE OR REPLACE VIEW v_order_shortage AS
SELECT
  co.id AS order_id, co.order_no, co.member_id, co.pickup_store_id,
  coi.sku_id, coi.qty AS demand_qty,
  coalesce(allocated.qty, 0) AS allocated_qty,
  coi.qty - coalesce(allocated.qty, 0) AS shortage_qty,
  ...
WHERE shortage_qty > 0
  AND co.status NOT IN ('cancelled', 'completed', 'transferred_out')
```

**UI**
- [ ] 在 `/hq/inbox` 加一個來源 chip:「⚠️ 短少訂單」
- [ ] 列出短少訂單,可逐筆執行:
  - [ ] 通知客戶(LINE 推播 / SMS)
  - [ ] 取消訂單 + 退款 / 退儲值金
  - [ ] 改派(從其他店有的庫存轉)
  - [ ] 等下批 PO 補貨
- [ ] 通知狀態追蹤(避免重複通知)

### 6.5 出貨集貨 — `/transfers/dispatch`(既有頁強化 / 改名為 `/wms/outbound`)

**改進**:
- [ ] 頁標改成「出貨集貨 (Outbound Dock)」
- [ ] 按司機 / 路線分組顯示(可選)
- [ ] 批次列印出貨單(已有,擴大 UX)
- [ ] 不要重複顯示同張 transfer(去重 — 同一張 transfer 在 wave-generated / restock-派貨 / aid-轉貨 三來源)

### 6.6 異常處理 — `/wms/exceptions`(新頁)

**目的**:把散在各處的異常集中。

**內容**
- [ ] 進貨短少:GR `qty_received < qty_ordered` 的 PO line
- [ ] 進貨破損:GR `qty_damaged > 0`
- [ ] 過量進貨:GR `qty_received > qty_ordered`(若允許)
- [ ] 收貨短少:Transfer `qty_received < qty_shipped`(分店收貨少)
- [ ] 撿貨破損:wave 內 picked_qty < qty 且有破損標記
- [ ] 客訴對應品(關聯到上述任一)

每筆顯示:類型 / 單號 / 品項 / 預期 / 實際 / 狀態 / 處理人 / 動作。

---

## 7. Sidebar 重組(已決議全改 `/wms/*`)

### 新分組
```
🏠 儀表板
📨 總倉收件匣 (/hq/inbox)

🏢 核心業務
   開團 / 商品 / 供應商

🛒 分店業務
   訂單 / 取貨 / 會員 / 互助交流板

📦 進銷存
   請購單 / 採購單 / 補貨申請 / 補貨申請(HQ)

🏬 倉儲(WMS)
   📥 進貨待辦       /wms/receiving       (新)
   🚦 派貨工作台     /wms/picking         (← /picking/workstation)
   📋 撿貨歷史       /wms/picking/history (← /picking/history)
   📤 出貨集貨       /wms/outbound        (← /transfers/dispatch)
   📦 收貨待辦       /wms/inbound         (← /transfers/inbox)
   🔄 內部調撥       /wms/transfers       (新匯總,含自由轉貨 / 退貨回總倉)
   🤝 互助轉移       /transfers/aid       (維持獨立路徑,但顯示在 WMS 群)
   ⚠️  異常處理      /wms/exceptions      (新)

💰 財務
   HQ 應收 / 月結算

📊 社群選品
```

### 路徑遷移計劃

| 舊路徑 | 新路徑 | 動作 |
|---|---|---|
| `/picking/workstation` | `/wms/picking` | 移檔 + 301 redirect |
| `/picking/history` | `/wms/picking/history` | 移檔 + 301 redirect |
| `/transfers/dispatch` | `/wms/outbound` | 移檔 + 301 redirect |
| `/transfers/inbox` | `/wms/inbound` | 移檔 + 301 redirect |
| `/transfers/free` | `/wms/transfers/free`(可選) | v1 暫不動,v2 整併 |
| `/transfers/aid` | (不變) | 顯示在 sidebar WMS 群但路徑保留 |
| `/transfers/settlement` | (不變) | 屬於財務,不屬 WMS |
| 新 | `/wms/receiving` | 新建 |
| 新 | `/wms/transfers` | 新建(內部調撥匯總頁) |
| 新 | `/wms/exceptions` | 新建 |

> 改路徑用 `next.config.ts` redirects() 設 301 永久轉向。1 週後檢查無 404 流量再考慮移除 redirect。

---

## 8. Data Model 變更摘要

| 變更 | 性質 | 預估 migration |
|---|---|---|
| `v_picking_demand_by_po` 加 `po_status` / `qty_in_transit` / `qty_shortage`,排除 restock-sourced | View | 1 (已寫) |
| `v_po_receipt_progress` 新 view(進貨待辦 + timeline 用) | View | 1 |
| `v_order_shortage` 新 view(短少訂單) | View | 1 |
| `customer_orders` 加 `shortage_notified_at` 欄(避免重複通知) | Column | 1 |
| `customer_orders` 加 `shortage_resolution`(cancelled/notified/reallocated/etc.) | Column | 1 |
| 新 RPC:`rpc_handle_shortage_order(order_id, action, ...)` | RPC | 1 |
| 排除 restock POs 的撿貨需求 | 已含於上 view | - |

**預估 5 張 migration、~600 行 SQL**。

---

## 9. Phases 切割 / 優先順序

| Phase | 範圍 | 預估工時 | 依賴 |
|---|---|---|---|
| **P1** ✅ 已做 | SpinButton + 撿貨工作站合併矩陣 + FIFO 切多 PO + 訂購欄 + SKU→品項 + /hq/inbox MVP + 補貨「下訂單」+ 每次新 PR | done | - |
| **P2** | view migration(訂/到/在途/短少)+ 撿貨頁 4 欄 + 警示色 | 半天 | view migration push |
| **P3** | 進貨待辦頁 + PO 完成度 timeline | 1 天 | P2 |
| **P4** | 短少訂單看板 + /hq/inbox 新來源 + 通知客戶 RPC | 1.5 天 | P3 |
| **P5** | 異常處理頁 + Sidebar 重組 + 路徑改名(若決定要改) | 1 天 | P3-P4 |
| **P6** | KPI bar / 路線分組列印 / 出貨集貨整理 | 0.5 天 | P3-P5 |
| **v2(未來)** | 批號 + 效期 + FEFO + 多儲位 + 條碼撿貨 | 大改 | 硬體 + schema 大調 |

---

## 10. Open Questions — 已決議

| # | 問題 | **決議** | 備註 |
|---|---|---|---|
| Q1 | 短少訂單通知客戶管道 | **PWA 推播** | 利用既有 PWA push 訂閱,不走 LINE OA(每店訊息費負擔) |
| Q2 | 過量進貨處理 | **警示但允許 + 強制 variance_reason** | UI 紅底提示、必填理由欄 |
| Q3 | 路徑要改 `/wms/*` 嗎? | **全改** + 舊路徑 301 redirect | 列入 Phase 2 |
| Q4 | 出貨集貨分組 | **v1 按目的店分組** | routes 表 v2 |
| Q5 | 短少訂單處理方式 | **手動處理** | HQ 客服逐筆「通知 / 取消退款 / 改派 / 等下批」 |
| Q6 | 多種 transfer 場景 | **WMS 工作台統籌全部** | 見 §13 |
| Q7 | 命名統一 | **「派貨工作台」** | 對齊業界 Wave Planning;內部 schema 仍用 wave |

---

## 13. Transfer 類型全景(Q6 補充)

實際業務有**多種 transfer 流**,WMS 工作台都要 cover:

```
A. 客戶訂單派貨   HQ → Store    via Wave    (撿貨工作站建)
B. 補貨派貨       HQ → Store    direct      (HQ Inbox 派貨 / 📦 PO 到貨建轉貨單)
C. 自由轉貨       Store ↔ Store free        (/transfers/free)
D. 互助訂單       會員間衍生    aid_xfer    (customer_orders 衍生)
E. 退貨回總倉     Store → HQ    return      (待設計:可能透過 free 模式或專屬 type)
```

### Transfer type 分類

| 業務類型 | `transfers.transfer_type` | 來源 | 目的 | 觸發點 |
|---|---|---|---|---|
| A | `hq_to_store` | HQ | 分店 | wave 完成 |
| B | `hq_to_store` | HQ | 分店 | rpc_approve_restock_to_transfer / rpc_ship_restock_pr_received |
| C | `store_to_store` | 任意 | 任意 | rpc_create_free_transfer |
| D | `aid_transfer`(視 schema 而定) | 來源店 | 目的店 | rpc_ship_aid_order 衍生 |
| E | 待設計(`store_to_hq` 或復用 `store_to_store`) | 分店 | HQ | 新 RPC |

### WMS 工作台對應頁

| 階段 | 對應頁 | 涵蓋類型 |
|---|---|---|
| **進貨**(Inbound from supplier)| `/wms/receiving` | (跟 transfer 無關,GR-only) |
| **派貨**(Outbound from HQ via wave)| `/wms/picking` | A |
| **出貨集貨**(集中所有要出 HQ 的 transfer)| `/wms/outbound` | A + B |
| **轉貨待辦**(各端點要收的 transfer)| `/wms/inbound` | A + B + C + E(分店端 / HQ 端) |
| **內部調撥**(Store ↔ Store / Store → HQ 退貨)| `/wms/transfers` (新匯總頁) | C + E |
| **互助訂單**(會員間)| `/transfers/aid` (維持獨立或併入 inbox)| D |

### 各種 transfer 流的差異點(影響 UI 設計)

- **A vs B**:都是 HQ 出貨給分店,A 走 wave(批次撿)、B 直接出。出貨集貨頁要把兩種一起列,但 source 標籤要清楚(「客戶訂單派貨」vs「補貨派貨」)。
- **C 自由轉貨**:source / dest 是任意 location,可能是「店 1 借給店 2」的非正式調撥。沒有 wave / 沒有 GR,直接建 transfer。
- **D 互助訂單**:會員間轉,衍生 customer_orders,實際走的是 customer_orders 流程不是 transfers。WMS 看不到,在 `/hq/inbox` + `/transfers/aid` 處理。
- **E 退貨回總倉**:目前 schema 沒專屬 type,需設計。場景:店 1 過期/破損商品退回 HQ;或店 1 多餘庫存還回 HQ。觸發點可能是 PWA banner。

### v1 範圍決定

- **含 A、B、C、E**:都是 transfer 流,工作台統籌
- **D 維持獨立**:走 customer_orders,在 `/hq/inbox` 看到、在 `/transfers/aid` 操作
- **E 退貨**:本 v1 暫先用 free transfer 形式(source=store, dest=HQ),v2 視需求拉出專屬 type

---

## 11. 風險

| 風險 | 緩解 |
|---|---|
| 撿貨工作站排除 restock POs 後,使用者搞錯路線(以為要從這派) | 進貨待辦頁明確標示來源類型(客戶訂單 / 補貨申請),補貨用 HQ Inbox |
| 短少訂單一次通知大量客戶,誤觸發 | 通知前要 confirm 對話框、批次預覽、有「取消通知」狀態欄 |
| View 性能(JOIN 變多) | 加 index、必要時改成 materialized view |
| Sidebar 重組造成使用者迷失 | 改前先發布 release note + 提供舊路徑 redirect 1 週 |

---

## 12. Out of scope (本文件不負責)

- 庫存準確性、移動平均成本、盤點 — 見 [[PRD-庫存模組]]
- 請購單 / 採購單(PR/PO)的撰寫流程 — 見 [[PRD-採購模組]]
- 客戶取貨流程(LIFF / 分店端取貨)— 見 [[PRD-訂單取貨模組]]
- 補貨申請(restock_requests)流程 — 見 [[PRD-訂單取貨模組-v0.2-addendum]]
- 互助訂單(aid_transfer)— 見 [[PRD-訂單取貨模組-v0.2-addendum]]

---

## 附錄 A — 業界對照系統

| 系統 | 對照模組 | 可參考處 |
|---|---|---|
| Odoo Inventory | Batch Transfer / Cluster Picking | github.com/odoo/odoo `addons/stock_picking_batch` |
| ERPNext | Pick List / Stock Entry | erpnext.com docs |
| SAP EWM | Wave Monitor / Inbound Workbench | help.sap.com 公開 |
| Manhattan Active WM | Outbound Wave / Receiving | Manhattan 官方部落格 |

---

## 變更歷史

- 2026-05-08:初稿,根據對話需求建立。Phase 1 已實作完成,本 PRD 涵蓋 Phase 2-6。

---
title: PRD - 採購模組
module: Purchase
status: draft-v0.1
owner: www161616
created: 2026-04-20
tags: [PRD, ERP, 採購, Purchase]
---

# PRD — 採購模組（Purchase Module）

> 零售連鎖 ERP，總倉 1 + 門市 100 + SKU 15,000。
> 本文件為 **v0.1 checklist 版**。
>
> **v0.2 增補**：見 [[PRD-採購模組-v0.2-addendum]]（PR 內部審核 / 陸貨到貨追蹤 / 漂漂館 sub-brand / 1688 拼多多 import hook）。
> **相關新模組**：[[PRD-供應商整合-v0.2]]（xiaolan Google Sheets sync + marketplace Apps Script）、[[PRD-應付帳款零用金-v0.2]]（GR → vendor_bill 流程）。

---

## 1. 模組定位
- [ ] 負責「從需求產生 → 供應商下單 → 收貨入庫 → 對帳」的完整採購生命週期
- [ ] 是**庫存模組**的主要入庫來源之一（另一個來源是門市退貨、盤盈）
- [ ] 本模組**不**處理付款本身（交給財務 / 應付帳款模組），但產生應付憑據

---

## 2. 核心流程（含上游 LINE 入單）

```
[門市/相關人員]
    │ 寫叫貨需求
    ▼
[LINE 記事本]  ← 非結構化文字
    │
    │ 小幫手讀 → 系統 key 單（支援貼上解析）
    ▼
[請購單 PR] ──合併/拆分──► [採購單 PO]
                                  │
                                  │ 送供應商
                                  ▼
                          [供應商出貨]
                                  │
                                  ▼
                          [總倉收貨入庫] ──► (呼叫庫存模組入庫 API)
                                  │
                                  ▼
                          [採購對帳 / 結案]
```

---

## 3. 名詞定義
- [ ] **請購單（PR, Purchase Request）**：小幫手從 LINE 記事本 key 進來的草稿單，**尚未發給供應商**
- [ ] **採購單（PO, Purchase Order）**：正式發給供應商的單據，一張 PO = 一個供應商
- [ ] **收貨單（GR, Goods Receipt）**：總倉實際收到貨後的紀錄，會觸發庫存異動
- [ ] **退供單**：向供應商退貨，會觸發反向庫存異動

---

## 4. Goals
- [ ] G1 — 小幫手 key 單速度 ↑ 50%（透過「貼上 LINE 文字自動解析」）
- [ ] G2 — 所有採購需求 100% 進系統，不再有只存在 LINE / Excel 的叫貨紀錄
- [ ] G3 — 採購員可清楚看到每張 PO 的狀態（已下 / 未到 / 部分到 / 完成）
- [ ] G4 — 收貨與採購單數量自動比對，差異即時警示
- [ ] G5 — 採購對帳時間 ↓ 50%（對帳單自動生成）

---

## 5. Non-Goals（v1 不做）
- [ ] ❌ **詢價 / 比價 / 招標流程**（RFQ）— 實務上已固定供應商，P2
- [ ] ❌ **付款與出金** — 屬財務 / 應付模組
- [ ] ❌ **自動從 LINE Bot 直接收單寫入系統** — 先保留小幫手人工 key 單環節；P2 考慮
- [ ] ❌ **供應商自助 Portal（供應商登入系統）** — P2
- [ ] ❌ **進口 / 多幣別 / 報關** — 目前台灣內採購，不需要

---

## 6. User Roles 與 Stories

### 6.1 小幫手（行政助理）— 上游 key 單
- [ ] 作為小幫手，我要能**貼上 LINE 記事本的整段文字**，系統自動解析出品項、數量、供應商（若有寫），我再微調
- [ ] 作為小幫手，我要能**批次建立請購單**（一次處理多店多品）
- [ ] 作為小幫手，我要能在商品找不到時**快速新增商品主檔**（或標記 pending 讓採購處理）
- [ ] 作為小幫手，我要能標註這張請購單來自哪家門市 / 哪個來源（哪段 LINE 對話）
- [ ] 作為小幫手，我要能看到今日 key 過的單，避免重複輸入

### 6.2 採購
- [ ] 作為採購，我要看到**所有未處理的請購單**，按供應商自動分組
- [ ] 作為採購，我要能把多張請購單**合併成一張 PO**（同一供應商）
- [ ] 作為採購，我要能調整 PO 數量、單價、備註後送出
- [ ] 作為採購，我要能選擇把 PO **發 Email / 匯出 PDF / 列印**給供應商（**通道待確認**）
- [ ] 作為採購，我要能看**未到貨清單**（PO 已發 X 天仍未全收）
- [ ] 作為採購，我要能對帳：把供應商月結單 vs 系統收貨紀錄比對

### 6.3 總倉倉管
- [ ] 作為倉管，我要能依 PO 收貨，系統預帶應收品項與數量
- [ ] 作為倉管，實收與應收數量不符時可直接標記差異（短收 / 破損）
- [ ] 作為倉管，收貨確認後自動觸發庫存入庫

### 6.4 總部老闆
- [ ] 作為老闆，我要看月採購金額、Top 10 供應商、採購異常清單

---

## 7. Functional Requirements

### 7.1 LINE 文字解析（本模組亮點）
- [ ] 輸入：小幫手貼上的 LINE 原始文字（多行、自由格式，常混雜語助詞與門市代號）
- [ ] 輸出：結構化品項清單 `[{sku_candidate, qty, unit, store, raw_line, confidence}]`
- [ ] 解析策略（由易到難）：
  - [ ] 先用規則：行拆分 → 數量抽取（數字 + 單位）→ 商品名關鍵字比對主檔
  - [ ] 補 LLM：規則信心度低的行交 LLM 解析，回傳候選 SKU 清單
  - [ ] 模糊比對：商品名別名 / 錯字容錯（門市常用簡稱）
- [ ] UI：原始文字在左、解析結果在右，可逐行修正
- [ ] 無法識別的行標紅，讓小幫手手動對應或新增別名（**別名會回寫商品主檔**，下次就認得）

### 7.2 請購單（PR）
- [ ] CRUD：建立、編輯、刪除（僅草稿狀態可刪）
- [ ] 狀態：`draft → submitted → merged_to_po / rejected`
- [ ] 必填欄位：來源門市、品項明細、小幫手操作人、原始 LINE 文字（備查）
- [ ] 支援「整批同店」與「單品跨店」兩種輸入姿勢

### 7.3 採購單（PO）
- [ ] 由請購單合併產生 or 採購員直接手動建立
- [ ] 一張 PO = 一個供應商
- [ ] 狀態：`draft → sent → partially_received → fully_received → closed`
- [ ] 欄位：PO 編號、供應商、預計到貨日、付款條件、明細、總金額、備註
- [ ] PO 發送後禁止修改數量（需走「修改單」流程）

### 7.4 供應商主檔
- [ ] 基本資料：名稱、統編、聯絡人、電話、Email、地址、付款條件
- [ ] 商品對應：哪些 SKU 由哪個供應商供應（可一對多）
- [ ] 預設報價：`(supplier, sku) → 預設單價`

### 7.5 收貨（GR）
- [ ] 從 PO 開始收貨（必須掛單，不允許無單收貨）
- [ ] 同一張 PO 可分多次收貨
- [ ] 差異處理：
  - [ ] **短收**：產生差異，PO 保持未結
  - [ ] **超收**：阻擋，除非採購開權限
  - [ ] **破損**：計入收貨但同步產生報廢異動
- [ ] 收貨確認 → 呼叫 **庫存模組入庫 API**（Inventory module §6.2）

### 7.6 退供應商
- [ ] 來源：收貨當下發現不良、收貨後發現問題
- [ ] 產生「退供單」→ 呼叫 **庫存模組出庫 API**
- [ ] 影響應付金額（寫入應付沖帳資料）

### 7.7 對帳
- [ ] 月結對帳：列出某供應商當月所有 GR + 退供，比對供應商送來的月結單
- [ ] 差異清單：金額 / 數量對不上的項目

---

## 8. 非功能需求
- [ ] LLM 解析 API 超時 fallback 到純規則 + 手動
- [ ] PR → PO 合併、GR 入庫皆需 DB transaction
- [ ] 所有操作留稽核紀錄
- [ ] 權限：店員 / 店長**無採購模組權限**（除非採購授權）

---

## 9. 權限對照

| 權限 | 總部老闆 | 採購 | 小幫手 | 倉管 | 店長 |
|---|:-:|:-:|:-:|:-:|:-:|
| 建立 PR | ✅ | ✅ | ✅ | ❌ | 🔸(申請) |
| 合併/修改 PR | ✅ | ✅ | ✅ | ❌ | ❌ |
| 建立 / 送出 PO | ✅ | ✅ | ❌ | ❌ | ❌ |
| 收貨 | ✅ | ❌ | ❌ | ✅ | ❌ |
| 退供應商 | ✅ | ✅ | ❌ | ✅ | ❌ |
| 對帳 / 報表 | ✅ | ✅ | ❌ | ❌ | ❌ |
| 管理供應商主檔 | ✅ | ✅ | ❌ | ❌ | ❌ |

---

## 10. 資料模型草稿

- [ ] `purchase_requests` — PR 單頭（含 `raw_line_text` 原始 LINE 文字備查、`source_store_id`、`created_by`）
- [ ] `purchase_request_items` — PR 明細
- [ ] `purchase_orders` — PO 單頭
- [ ] `purchase_order_items` — PO 明細（含已收數量）
- [ ] `goods_receipts` — 收貨單頭
- [ ] `goods_receipt_items` — 收貨明細（含差異原因）
- [ ] `purchase_returns` — 退供單
- [ ] `suppliers` — 供應商主檔
- [ ] `supplier_skus` — 供應商商品對應（+ 預設單價）
- [ ] `sku_aliases` — 商品別名（LINE 解析用，**關鍵表**）

---

## 11. 與其他模組整合
- [ ] **庫存模組** → 收貨 / 退供時呼叫入庫 / 出庫 API
- [ ] **主檔模組** → 商品、供應商
- [ ] **報表模組** → 採購分析、供應商分析
- [ ] **財務 / 應付模組** → 產生應付憑據（v1 先以匯出方式對接外部會計軟體）
- [ ] **LLM 服務** → 文字解析

---

## 12. 驗收準則
- [ ] 貼上一段 LINE 記事本文字 → 系統解析出 ≥ 80% 品項正確（其餘手動對應）
- [ ] 小幫手無法送出含未識別商品的 PR（必須先對應或新增主檔）
- [ ] 合併 3 張同供應商 PR → 產生 1 張 PO，總金額 = 三張 PR 金額加總
- [ ] PO 送出後嘗試修改數量 → 被阻擋，顯示「需走修改單」
- [ ] PO 數量 100、收貨 60 → 狀態 `partially_received`，剩 40 仍在「未到清單」
- [ ] 收貨確認後 3 秒內，該 SKU 總倉庫存已增加對應數量
- [ ] 無權限角色（店員）打採購 API → 403

---

## 13. Open Questions

### 流程 / 策略
- [x] **Q1 LINE 文字解析**：→ **不在採購模組**。（2026-04-21）

  **釐清**：原 PRD 誤假設「店員透過 LINE 叫貨、小幫手解析文字成 PR」。實際流程是「**顧客在 LINE 頻道 +N 下單** → 結單統計 → 產生採購需求」。

  **重新歸屬**：
  - **訂單 / 取貨模組**（新建）：解析**顧客 LINE 留言**（多品 + 改單語法），建議用 **LLM**（複雜語法純規則難覆蓋）
  - **採購模組**：PR 來源改為「訂單模組結單統計」+「門市緊急叫貨」兩條路徑，不解析 LINE 文字
- [x] **Q2 小幫手併發**：→ **5 人同時處理、結單日塞車；必要系統級併發控制**。（2026-04-21）

  **Level 1（必要）**：
  - PR / PO 單號 **DB sequence 自動產生**（格式 `PR` / `PO` + yyMMdd + 流水），不給手 key
  - Schema v0.2 新增 `version BIGINT`（樂觀鎖）到 `purchase_requests` / `purchase_orders`
  - UPDATE 必帶 version、不符拒絕

  **Level 2（強烈建議）**：
  - 「本單正在編輯中」鎖顯示（`locked_by / locked_at` 欄位，10 分鐘超時自動釋放）
  - 批次操作：「從訂單模組結單 → 一鍵生成多張 PO（依供應商分組）」
  - 草稿自動存檔（30 秒 / 次）

  **Level 3（P1）**：
  - Supabase Realtime 即時協作
  - 背景佇列（寄 PO email、生 PDF）
  - 結單日效能壓測（目標 50 張 PO / 分鐘）

  **v0.2 schema 變動**：
  ```sql
  ALTER TABLE purchase_requests
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN locked_by UUID,
    ADD COLUMN locked_at TIMESTAMPTZ;
  -- 同 purchase_orders
  CREATE SEQUENCE pr_no_seq; CREATE SEQUENCE po_no_seq;
  ```
- [x] **Q3 請購單 / 訂單來源保留**：→ **分階段導入，v1 純人工登打 + 預留自動化 schema**。（2026-04-21）

  **釐清**：這題原始情境（「LINE 原文備查」）其實屬**訂單模組**範疇。採購 PR 不需要保留 LINE 原文。

  **訂單模組分階段計劃**：

  | 階段 | 做法 | 月成本 | 優缺點 |
  |---|---|---|---|
  | **v1（優先）** | **小幫手人工登打**（看 LINE 手動輸入每筆顧客訂單）| NT$ 0 | UI 要做很順、快速鍵、顧客 autocomplete、draft 自動存 |
  | **P1（升級）** | 上傳 LINE 截圖 → **Claude Haiku vision** 多模態解析 → 草稿審核 | ~NT$ 40~135 | 省 80% 人工時間 |
  | **P2（備援）** | 純 OCR（Tesseract / Google Vision）+ 文字規則解析 | NT$ 50 | 本機運作，對個資敏感情境可用 |

  **v1 schema 預留欄位（訂單模組 PRD 待建）**：
  - `customer_orders.source_screenshots TEXT[]`（v1 NULL、P1 填入截圖 URL）
  - `customer_orders.source_parsed_json JSONB`（v1 NULL、P1 填入 LLM 輸出）
  - `customer_orders.source_raw_text TEXT`（v1 NULL、P2 填入 OCR 文字）
  - 保留 2 年（客訴防線）

  **v1 UX 設計優先項**（因為純手工、5 人同時、結單日塞車）：
  - 顧客 autocomplete（打 LINE ID 前幾字自動帶）
  - 商品從團購清單下拉選（Q5/Q3 共識：商品不用打）
  - 快速鍵（Tab 跳欄、Enter 新增列、上下鍵切換）
  - 每 30 秒自動存 draft
  - 結單日看板：各頻道完成度進度條
- [x] **Q4 PO 通道**：→ **混合（LINE / Email / 電話），依供應商偏好，現況以 LINE 為主**。（2026-04-21）

  **v0.2 schema 變動**：
  ```sql
  ALTER TABLE suppliers
    ADD COLUMN preferred_po_channel TEXT CHECK (preferred_po_channel IN
      ('line','email','phone','fax','manual')) DEFAULT 'line',
    ADD COLUMN line_contact TEXT;
  -- purchase_orders.sent_channel 已存在
  ```

  **UI 流程**：按「發送」→ 依 `preferred_po_channel` 顯示對應操作：
  - **LINE**：格式化 PO 文字 + 「複製」按鈕 + 供應商 LINE ID（小幫手自行切到 LINE 貼上）
  - **Email**：下載 PDF / Excel + `mailto:` 草稿（人工寄送）
  - **電話**：顯示號碼 + 通話紀錄填寫欄
  - 發送後自動記 `sent_at / sent_by / sent_channel`，PO 狀態 `draft → sent`

  **v1 不自動化**：不串 LINE API、不自動發 email；人工操作 + 系統輔助格式化即可。

  **P1 擴充**：Edge Function 串 Resend / SendGrid 自動發 email；LINE Notify / 官方帳號 API（視供應商合作度）。
- [x] **Q5 多供應商同品**：→ **沿用商品模組 Q12 決定：預設帶 `sku_suppliers.is_preferred` 供應商、UI 列出全部可切換**。（2026-04-21）

  採購模組無特殊考量，共用同一機制：`sku_suppliers` 有 `is_preferred` 唯一索引（每 SKU 僅一個偏好）。
- [x] **Q6 緊急叫貨**：→ **店長可直接建 PO、跳過 PR；必填原因 + 金額上限 + 事後稽核**。（2026-04-21）

  **實作**：
  - 店長角色開放「建立 PO」權限（平常僅小幫手 / 採購員有）
  - 緊急 PO 必填 `emergency_reason TEXT`（v0.2 新增欄位）
  - 單次金額閾值（可設定，預設 NT$ 10,000）：
    - ≤ 閾值：自動通過、立即發出
    - > 閾值：進入「待總部批」佇列、總部 15 分鐘內處理
  - 事後稽核：每月報表列出所有 `emergency_reason` 非空的 PO、總部檢視
  - 與 Q8 商品模組「店長自由改售價」權限一致：**寬鬆 + 事後稽核**哲學

  **v0.2 schema 變動**：
  ```sql
  ALTER TABLE purchase_orders
    ADD COLUMN emergency_reason TEXT,
    ADD COLUMN requires_hq_approval BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN hq_approved_at TIMESTAMPTZ,
    ADD COLUMN hq_approved_by UUID;
  ```
- [x] **Q7 付款條件**：→ **支援所有常見類型（現金現貨 / T+N / 月結 N / COD / 預付款 / 混合）**；供應商層級預設 + PO 級可覆寫。（2026-04-21）

  **v0.2 schema 變動**：
  ```sql
  -- suppliers：結構化付款條件
  ALTER TABLE suppliers
    ADD COLUMN payment_type TEXT CHECK (payment_type IN
      ('cash_on_delivery','t_plus_days','monthly_close','cod','prepaid','mixed'))
      DEFAULT 'monthly_close',
    ADD COLUMN payment_days INTEGER,         -- T+7=7, 月結 30=30
    ADD COLUMN monthly_close_day SMALLINT,   -- 月結幾號結（預設月底 = 31）
    ADD COLUMN prepaid_percent NUMERIC(5,4); -- 預付款比例（0.30 = 30%）
  -- purchase_orders：PO 級可覆寫（應付日期計算）
  ALTER TABLE purchase_orders
    ADD COLUMN payment_type_override TEXT,
    ADD COLUMN payment_days_override INTEGER,
    ADD COLUMN due_date DATE;  -- 系統依條款自動算出的應付日
  ```

  **due_date 自動計算規則**（RPC）：
  - `cash_on_delivery` / `cod` → due_date = 收貨日
  - `t_plus_days` → due_date = 收貨日 + payment_days
  - `monthly_close` → due_date = 次月 `monthly_close_day`（例月結 30 → 次月 30 日）
  - `prepaid` → PO 確認時先產生應付 `prepaid_percent × total`，到貨後產生剩餘
  - `mixed` → 建 PO 時手動指定 override

  **應付帳款**：
  - 採購模組**不**處理付款本身（Non-Goals 明確排除）
  - PO / GR 確認後產生「應付憑據」給財務 / 應付模組（**尚未建立 PRD**，未來另開）
  - v1 可先簡化：`accounts_payable` 表記錄未付單、手動勾選「已付」
- [x] **Q8 議價 / 促銷價**：→ **A + B 組合（不做 C 季節活動表）**。（2026-04-21）

  **實作**：
  - **A（永久降價）**：採購員可改 `sku_suppliers.default_unit_cost`；影響之後所有新 PO，不動歷史
  - **B（PO 臨時價）**：建 PO 時 `purchase_order_items.unit_cost` 可自由覆寫，只影響這筆
  - **不做 C**：季節性活動 / 量大議價用 B 臨時覆寫處理；若未來需求增強再加 `supplier_price_events` 表（P2）

  **schema 無變動**（現有欄位已支援）。UI 要做：
  - 供應商主檔編輯頁 → 顯示 `sku_suppliers` 列表 + 「改預設成本」按鈕
  - 建 PO 頁 → 每一 line item 的 unit_cost 可直接編輯、顯示「原預設 $25 → 本次 $20」差異提示

### 與現況銜接
- [x] **Q9 現行 LINE 通路現況**：→ **20 個 LINE 社群（OpenChat）頻道，各 300~2000 顧客，格式統一；系統半自動輔助、不自動發文**。（2026-04-21）

  **重大架構限制發現**：LINE 社群（OpenChat）**官方無開放 API** → 不能自動發文、不能自動讀留言、顧客只有社群暱稱（非真實 user_id）。

  **v1 實作方式**：
  - 系統提供 **post 範本管理**（可編輯、變數代入商品資訊）
  - 小幫手按「生成 post」→ 複製 → 手動貼到 LINE 社群（20 次）
  - 顧客身份綁定走 **A + B 混合**（訂單模組實作）：
    - A. 小幫手登打時手動綁定 `社群暱稱 ↔ member_id`，系統記下來下次自動帶
    - B. LIFF / OA 讓顧客自己綁（訂單模組 / 會員模組細節）
  - 顧客身份對應表 `customer_line_aliases (channel_id, nickname, member_id)` 由訂單模組管理

  **v1 架構**：
  ```
  LINE 社群（顧客下單，手動 post + 截圖）
     ↓ 小幫手截圖 → 登打
  系統 ERP
     ↓ 推播
  LINE 官方帳號 OA（取貨通知）→ LIFF（會員查詢）
  ```

  **顧客需「雙加」**（社群看團購 + OA 收通知）— 承擔此體驗損失。

  **v0.2 schema 新增**：
  ```sql
  CREATE TABLE post_templates (
    id, tenant_id, name, template TEXT, variables JSONB, ...
  );
  CREATE TABLE customer_line_aliases (
    tenant_id, channel_id, nickname, member_id, created_by, created_at,
    UNIQUE (tenant_id, channel_id, nickname)
  );
  ```
- [x] **Q10 舊系統採購資料遷移**：→ **直接切換、不搬舊 PO**。（2026-04-21）

  **策略**：
  - Cut-over 當日起，新 PO 全走新系統
  - 舊系統**唯讀保留**，舊 PO 繼續在舊系統追到結案（估 1-2 個月自然清空）
  - 供應商通知：Cut-over 後到貨走新系統 GR
  - 與庫存模組 Q8 搬遷策略一致（舊系統唯讀、新系統從 cut-over 開始）

  **免掉的工作**：
  - 不用雙系統對帳
  - 不用資料清洗
  - 不用擔心漏單 / 重複

---

## 14. 下一步
- [ ] 回答 Q1~Q10 → v0.2 展開欄位 / API / UI wireframe
- [ ] Spike：丟 10 段真實 LINE 文字給 LLM + 規則混合，測解析準確度
- [ ] 與小幫手實際訪談 30 分鐘，看真實操作姿勢

---

## 相關連結
- [[PRD-庫存模組]]
- [[專案總覽]]
- 舊系統參考：`lt-erp/PurchaseOrder.html`, `SearchPurchase.html`, `SupplierList.html`, `SupplierManager.html`

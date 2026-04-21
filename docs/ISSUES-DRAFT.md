# GitHub Issues Draft — new_erp

> 本文件列出從 v0.1 設計階段產出的所有待辦項目，供批次建立 GitHub Issues 使用。
>
> 使用方式：
> - 設定完 Labels + Milestones 後
> - 選擇批次建立方法（gh CLI / GitHub API / 手動 copy-paste）
> - 每個 `###` 區塊對應一個 issue

---

## 📌 Labels 體系設計

### 模組標籤
```
module:product       商品模組
module:member        會員模組
module:inventory     庫存模組
module:purchase      採購模組
module:sales         銷售模組
module:order         訂單 / 取貨模組（待建）
module:notification  通知模組（待建）
module:ap            應付帳款 / 財務模組（待建）
module:liff          LIFF 前端（另案）
module:cross         跨模組
```

### 類型標籤
```
type:feature         新功能
type:schema          Schema 變動 / migration
type:rpc             RPC / stored procedure
type:spike           技術驗證 / POC
type:docs            文件 / PRD
type:migration       資料遷移
type:infra           基礎建設 / DevOps
type:decision        待決策 / 討論
type:bug             Bug
```

### 優先級標籤
```
priority:p0          MVP 必要（v1 上線前）
priority:p1          建議 v1 後做
priority:p2          未來版本 / nice-to-have
```

### 狀態標籤
```
status:blocked       被其他 issue 卡住
status:ready         可以開始
status:in-progress   進行中
status:review        待 review
```

---

## 📅 Milestones 設計

| Milestone | 目標日期 | 內容 |
|---|---|---|
| **v0.1 設計完成** | 已完成 90% | PRD + Open Questions |
| **v0.2 Schema Finalize** | TBD | schema 變動、RPC 實作完成 |
| **Phase 1: Pilot 準備** | TBD | Supabase deploy、API scaffold、pilot 門市選定 |
| **Phase 1: Pilot 上線** | TBD | 1 店 pilot + 總倉、2~4 週真實跑 |
| **Phase 2: 漸進推廣** | TBD | 每週 5~10 店上線、10~12 週全部 |
| **Phase 3: 訂單流程完整** | TBD | 訂單 / 通知 / LIFF 整合 |

---

## 📝 Issues 清單

共計 **約 55 個 issues**，分 7 大類。

---

## 1️⃣ Schema 變動（v0.2）

### [schema/inventory] 新增 stock_lots 批次層級餘額表
- **Labels**: `module:inventory` `type:schema` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - 新增 `stock_lots` 表：每批入庫獨立一列，記 `expiry_date`、`on_hand`、`initial_qty`、`source_gr_id`、`unit_cost`、`status`
  - 支援 FEFO（先到期先出）
  - 搭配 20% 無效期商品 `expiry_date = NULL`
- **PRD 參考**: [docs/PRD-庫存模組.md Q2](docs/PRD-庫存模組.md)

### [schema/inventory] categories 加 expiry_grace_days 欄位
- **Labels**: `module:inventory` `module:product` `type:schema` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - `ALTER TABLE categories ADD COLUMN expiry_grace_days INTEGER NOT NULL DEFAULT 0`
  - 每分類獨立設定過期寬限天數
  - POS 出貨 when > expiry + grace → 擋；within grace → 警告 + 填原因

### [rpc/inventory] 改寫 rpc_inbound 支援 stock_lots
- **Labels**: `module:inventory` `type:rpc` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**: 每次入庫建立新 `stock_lots` 列，而非只加總 stock_balances

### [rpc/inventory] 改寫 rpc_outbound 支援 FEFO
- **Labels**: `module:inventory` `type:rpc` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**: 出貨依 lots expiry ASC 扣除；擋過期邏輯：`today > expiry + category.expiry_grace_days`

### [rpc/inventory] 新增 rpc_mark_expired（排程 job）
- **Labels**: `module:inventory` `type:rpc` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**: 每日凌晨掃過期 lots，設 status='expired'；觸發通知模組推播店長

### [rpc/inventory] 新增 rpc_near_expiry_report
- **Labels**: `module:inventory` `type:rpc` `priority:p1`
- **Milestone**: Phase 1: Pilot 準備
- **Description**: 列出 N 天內到期的 lots；用於近期到期報表頁面

### [rpc/inventory] 新增 rpc_reserve / rpc_release
- **Labels**: `module:inventory` `module:order` `type:rpc` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - `rpc_reserve(location, sku, qty)` → `reserved += qty`
  - `rpc_release(location, sku, qty)` → `reserved -= qty`
  - 支援預購期 `reserved > on_hand`（available 可為負）

### [schema/purchase] suppliers 結構化付款條件
- **Labels**: `module:purchase` `type:schema` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - `payment_type`（cash_on_delivery / t_plus_days / monthly_close / COD / prepaid / mixed）
  - `payment_days`, `monthly_close_day`, `prepaid_percent`
  - `preferred_po_channel`（line/email/phone/fax/manual）+ `line_contact`

### [schema/purchase] purchase_orders / requests 加 version + lock 欄位
- **Labels**: `module:purchase` `type:schema` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - `version BIGINT` 樂觀鎖
  - `locked_by UUID`, `locked_at TIMESTAMPTZ`（編輯鎖顯示）
  - `emergency_reason`, `requires_hq_approval`, `hq_approved_at`, `hq_approved_by`
  - `payment_type_override`, `payment_days_override`, `due_date`

### [schema/purchase] 建立 PR/PO 單號 DB sequence
- **Labels**: `module:purchase` `type:schema` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**: `CREATE SEQUENCE pr_no_seq; po_no_seq;` + RPC `rpc_next_pr_no` / `rpc_next_po_no`

### [schema/member] points_ledger 加 expires_at + 年度到期 job
- **Labels**: `module:member` `type:schema` `type:rpc` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - `points_ledger.expires_at DATE`（每 earn 自動填次年 12/31）
  - 年度到期 job（12/31 夜）：計算本年度未扣點 → 產 expire 流水
  - FIFO 扣點邏輯（先到期先扣）

### [schema/product] prices 支援促銷門市覆寫
- **Labels**: `module:product` `type:schema` `priority:p1`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - Q7 商品：promo scope 支援「總部基準 + 門市覆寫」
  - 新增 `prices.store_override_id` 或類似欄位
  - 改 `rpc_current_price`：四層取最低不疊加（Q9）、同 promo 下有門市版優先

### [rpc/product] 改 rpc_current_price 四層取最低
- **Labels**: `module:product` `type:rpc` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - 讀 tier.benefits.discount_rate 套 retail 算 member_tier 層
  - 四層全查後 `MIN()`，不依序取第一個
  - 搭配 Q10 會員等級折扣

### [schema/order] 新增 customer_line_aliases 對應表
- **Labels**: `module:order` `type:schema` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - `(tenant_id, channel_id, nickname, member_id)` UNIQUE
  - 支援首次下單時手動綁 / LIFF 自助綁
  - 社群暱稱可能改、多對一對應

### [schema/order] 新增 post_templates 與 customer_orders 骨架
- **Labels**: `module:order` `type:schema` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - `post_templates (id, name, template TEXT, variables JSONB)`
  - `customer_orders (含 source_screenshots[], source_parsed_json, source_raw_text)`
  - 其他細節待 PRD-訂單模組.md 確認

---

## 2️⃣ 待建模組 PRD

### [docs] 建立訂單 / 取貨模組 PRD
- **Labels**: `module:order` `type:docs` `priority:p0`
- **Milestone**: v0.1 設計完成
- **Description**:
  - 核心業務模組（團購店的主流程）
  - 涵蓋：發布團購 post / 截圖下單登打 / 結單 / 產生採購需求 / 取貨流程
  - 關鍵功能：v1 人工登打、P1 Claude vision 解析、顧客身份對應
  - 需參考既有 PRD 風格（frontmatter / checklist / 權限 / Open Questions）

### [docs] 建立通知模組 PRD
- **Labels**: `module:notification` `type:docs` `priority:p0`
- **Milestone**: v0.1 設計完成
- **Description**:
  - 統一處理 LINE OA push / SMS / Email 推送
  - 事件來源：會員（等級變更 / 生日 / 點數到期）、訂單（到貨 / 取貨逾期）、庫存（效期警示）
  - 串 LINE Messaging API（註：LINE 社群 OpenChat 無 API，不在本模組範圍）

### [docs] 建立應付帳款 / 財務模組 PRD
- **Labels**: `module:ap` `type:docs` `priority:p1`
- **Milestone**: Phase 2: 漸進推廣
- **Description**:
  - 採購模組產生應付憑據 → 本模組管理
  - 月結對帳、付款確認、應付明細帳
  - v1 可簡化：單一 `accounts_payable` 表 + 手動勾選「已付」

### [docs] 建立 LIFF 前端規格 PRD（另案）
- **Labels**: `module:liff` `type:docs` `priority:p1`
- **Milestone**: Phase 3: 訂單流程完整
- **Description**:
  - 顧客端 LIFF 網頁：會員 QR、點數 / 儲值金查詢、訂單查詢、取貨確認
  - 消費 ERP API（Supabase client）
  - LINE OA 綁定流程

### [docs] 完成銷售模組 Open Questions
- **Labels**: `module:sales` `type:docs` `type:decision` `priority:p0`
- **Milestone**: v0.1 設計完成
- **Description**: 與使用者 Q&A 討論 PRD-銷售模組.md 內所有 Open Questions

---

## 3️⃣ Spike / POC

### [spike] 條碼 lookup P95 < 50ms 效能驗證
- **Labels**: `module:product` `type:spike` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 灌 50k 條碼 + 15k SKU seed
  - 用 Supabase RPC 測 1000 次 `rpc_barcode_lookup`
  - 驗 P95 < 50ms、P99 < 200ms

### [spike] LIFF QR HMAC 產生 / 驗證 + 自動刷新
- **Labels**: `module:member` `module:liff` `type:spike` `priority:p1`
- **Milestone**: Phase 3: 訂單流程完整
- **Description**:
  - LIFF 網頁每 60s 呼叫 API 拿新 payload
  - HMAC secret 存 Supabase Vault
  - 驗簽失敗計數告警

### [spike] 併發扣儲值金 100 QPS 測試
- **Labels**: `module:member` `type:spike` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 100 支手機同時打 rpc_wallet_spend 同一會員
  - 驗證 `SELECT FOR UPDATE` 排隊、無超扣、`balance >= 0`

### [spike] 併發扣庫存 / POS 超賣防護
- **Labels**: `module:inventory` `type:spike` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 多支 POS 同時扣同一 SKU（剩 1 件）
  - 驗證僅一筆成功、其餘回「庫存不足」

### [spike] Claude Haiku vision 解析 LINE 截圖 POC
- **Labels**: `module:order` `type:spike` `priority:p1`
- **Milestone**: Phase 3: 訂單流程完整
- **Description**:
  - 給 10 張真實 LINE 社群截圖 + 商品清單
  - 測 Claude Haiku 結構化輸出準確率
  - 評估每月成本、UI 審核流程

### [spike] 移動平均成本 trigger 正確性
- **Labels**: `module:inventory` `type:spike` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - 多批進貨 + 出貨、驗證 avg_cost 計算
  - 含 qty=0 / unit_cost NULL 邊界

### [spike] 價格排程生效 + 歷史回溯
- **Labels**: `module:product` `type:spike` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - 排程明天 00:00 變價 → 今天查 = 原價、明天查 = 新價
  - 2 週前時間點查當時售價

### [spike] FEFO 扣貨順序驗證
- **Labels**: `module:inventory` `type:spike` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - 3 批不同效期 → 扣貨時嚴格按 expiry ASC
  - 包含 expiry=NULL 批（最後才扣）

### [spike] BarTender 匯入格式 / 條碼列印流程
- **Labels**: `module:product` `type:spike` `priority:p1`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 確認舊版 BarTender 模板 + 系統產出 CSV 格式對齊
  - 批次列印 50 個 SKU 測試

---

## 4️⃣ Infrastructure / DevOps

### [infra] 技術棧定案文件
- **Labels**: `type:decision` `type:infra` `priority:p0`
- **Milestone**: v0.1 設計完成
- **Description**:
  - 確認 Supabase auto-gen + RPC + RLS 為主架構
  - Edge Functions 處理 LINE API / 金流 webhook / 發票
  - 前端框架（後台 Next.js？LIFF 另案）

### [infra] Supabase dev 專案建立
- **Labels**: `type:infra` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 申請 Supabase 專案（免費或 Pro 方案評估）
  - 設定 Auth / Storage / Realtime
  - 導入 5 份 SQL schema

### [infra] Supabase staging + prod 環境
- **Labels**: `type:infra` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 三環境：dev / staging / prod
  - schema migration 工具（supabase CLI）
  - CI/CD pipeline（GitHub Actions）

### [infra] Seed 資料腳本
- **Labels**: `type:infra` `priority:p0`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - 1 tenant + 2 locations + 10 products + 20 SKUs + 30 conditions + 50 prices + 10 members + 5 sample orders
  - 用於開發測試

### [infra] GitHub Actions CI（schema 驗證）
- **Labels**: `type:infra` `priority:p1`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - PR 觸發時：lint SQL、execute on throwaway Postgres、run pgTAP
  - 防止 schema 破壞性變更

### [infra] 錯誤監控 / 日誌
- **Labels**: `type:infra` `priority:p1`
- **Milestone**: Phase 1: Pilot 上線
- **Description**:
  - Sentry / Logtail 整合
  - Supabase logs dashboard

---

## 5️⃣ 資料遷移 / Pilot 準備

### [migration] 主檔爬蟲 + CSV loader 開發
- **Labels**: `module:product` `type:migration` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 爬蟲：從供應商 / 通路網頁抓商品資訊
  - CSV loader：批次匯入 SKU / 分類 / 品牌 / 條碼（部分）/ 供應商關聯
  - 去重與清理 pipeline

### [migration] Pilot 門市選定
- **Labels**: `type:decision` `type:migration` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 選一間管理最完善的門市
  - 確認店長配合意願
  - 盤點團隊準備

### [migration] Pilot 門市全盤計劃
- **Labels**: `module:inventory` `type:migration` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 停業一天（或夜間）進行全盤
  - 盤點結果 → 開帳 `stock_movements (type=manual_adjust, reason=opening_balance)`
  - Trigger 自動建 `stock_balances`

### [migration] 總倉全盤計劃
- **Labels**: `module:inventory` `type:migration` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**: 同上、針對總倉 15,000 SKU

### [migration] 供應商主檔建立
- **Labels**: `module:purchase` `type:migration` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 盤點現有供應商清單
  - 填 payment_type / preferred_po_channel / 聯絡資訊
  - 建立 `sku_suppliers` 關聯（每 SKU 至少一個 is_preferred）

### [migration] 會員資料遷移
- **Labels**: `module:member` `type:migration` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 從舊系統 / Excel 匯入會員
  - PII 加密（pgcrypto）
  - 計算 phone_hash
  - 開帳：points / wallet 若有初始餘額

### [migration] 舊系統唯讀保留計劃
- **Labels**: `type:migration` `priority:p1`
- **Milestone**: Phase 1: Pilot 上線
- **Description**:
  - 舊 ERP 轉唯讀 3~6 個月
  - 舊 PO 自然追到結案、不搬
  - 新系統放「舊系統參考連結」欄位

### [decision] Pilot 期間硬體採購
- **Labels**: `type:decision` `type:infra` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - USB 掃描槍（型號待定）
  - 熱感發票機（ESC-POS）
  - 平板 / 筆電 / 桌機
  - 錢箱、標籤列印機

---

## 6️⃣ 待決策 / 業務對齊

### [decision] 電子發票管道選擇
- **Labels**: `module:sales` `type:decision` `priority:p0`
- **Milestone**: Phase 1: Pilot 上線
- **Description**:
  - 綠界 ezPay / 藍新 / 財政部大平台直接
  - v1 暫訂不開發票 → 需與會計師確認 20 萬 / 月法遵
  - P1 上線前必須確認

### [decision] 付款方式清單確認（v1+）
- **Labels**: `module:sales` `type:decision` `priority:p1`
- **Milestone**: Phase 1: Pilot 上線
- **Description**:
  - v1 只收現金
  - P1：信用卡 / LINE Pay / 街口 / 儲值金 / 點數折抵
  - 串接金流供應商（綠界 / 藍新）

### [decision] LINE OA 申請（若沒有）
- **Labels**: `module:member` `module:notification` `type:decision` `priority:p0`
- **Milestone**: Phase 3: 訂單流程完整
- **Description**:
  - 確認現況是否已有 LINE 官方帳號
  - 若無 → 申請流程
  - 用於取貨通知 + LIFF 入口

### [decision] 20 個 LINE 社群帳號盤點
- **Labels**: `module:order` `type:decision` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - 列出 20 個社群頻道 + 對應門市
  - 社群 channel_id 記錄（用於訂單來源標記）
  - 統一發文範本盤點

### [decision] Pilot 門市的 LINE 頻道選擇
- **Labels**: `module:order` `type:decision` `priority:p0`
- **Milestone**: Phase 1: Pilot 準備
- **Description**:
  - Pilot 門市對應的 LINE 社群先上線
  - 其他 19 個頻道漸進推廣

### [decision] 團單「收單上限 campaign_cap」規則
- **Labels**: `module:order` `type:decision` `priority:p0`
- **Milestone**: Phase 3: 訂單流程完整
- **Description**:
  - 每團上限設定（商品層級 / 頻道層級）
  - 到上限自動關團（或繼續收、等候補）
  - 與庫存 reserved 邏輯整合

---

## 7️⃣ 文件 / Review

### [docs] 建立 TEST-PLAN.md
- **Labels**: `type:docs` `priority:p1`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - 所有 Open Questions 決定對應的測試需求
  - pgTAP unit test 清單
  - 整合測試 / E2E 清單
  - 使用者已同意：待所有模組 Open Questions 答完再建

### [docs] 完善 RBAC 權限矩陣
- **Labels**: `module:cross` `type:docs` `priority:p1`
- **Milestone**: v0.2 Schema Finalize
- **Description**:
  - 合併各 PRD 的權限表
  - 建立 `docs/RBAC.md` 統一維護
  - 對應 Supabase RLS policy 實作

### [docs] 法遵 / 合規檢查清單
- **Labels**: `type:docs` `type:decision` `priority:p1`
- **Milestone**: Phase 1: Pilot 上線
- **Description**:
  - 台灣營業稅法（20 萬 / 月發票）
  - 個資法 / GDPR（PII 加密、刪除、保留 7 年）
  - 消保法（預付型商品揭露：儲值金不退現）
  - 預計諮詢會計師 + 律師

### [docs] 資料備份策略
- **Labels**: `type:infra` `type:docs` `priority:p1`
- **Milestone**: Phase 1: Pilot 上線
- **Description**:
  - Supabase daily backup
  - PII 加密下的備份處理
  - Point-in-time recovery 可行性

### [decision] 通知模組基礎架構
- **Labels**: `module:notification` `type:decision` `priority:p0`
- **Milestone**: v0.1 設計完成
- **Description**:
  - 事件驅動架構（Supabase Realtime / Edge Function 觸發）
  - 訂閱-發布模型：會員 / 庫存 / 訂單模組發事件、通知模組消費
  - 通道：LINE OA Messaging API / SMS / Email
  - 失敗重試與訊息去重

---

## 🎯 快速統計

- **Schema / RPC**：~15 個
- **待建 PRD**：5 個
- **Spike / POC**：9 個
- **Infrastructure**：6 個
- **Migration**：8 個
- **Decision**：6 個
- **Documentation**：6 個

**總計：約 55 個 issues**

---

## 🚀 下一步建議

1. 用 [GitHub Labels API](https://docs.github.com/en/rest/issues/labels) 或手動建立 13 個 Labels
2. 建立 6 個 Milestones
3. 選擇 issue 批次建立方法：
   - **A**. 手動 copy-paste 到 web UI
   - **B**. `gh CLI` 批次 script
   - **C**. GitHub API + PAT 批次呼叫
4. 建完後啟用 **GitHub Projects**（Kanban / Table 視圖）組織所有 issues
5. 銷售模組 Open Questions 答完後補進此清單

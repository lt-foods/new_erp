---
title: PRD - 商品模組
module: Product
status: draft-v0.1
owner: www161616
created: 2026-04-20
updated: 2026-04-23
tags: [PRD, ERP, 商品, Product, Pricing, Barcode, 樂樂通路]
---

# PRD — 商品模組（Product Module）

> 零售連鎖 ERP，總倉 1 + 門市 100 + SKU 15,000。
> 本模組是所有模組的**主檔根基**：庫存、採購、銷售、配貨的 `sku_id` 皆指向這裡。
> v0.1 checklist 版。

---

## 0. 🚨 加盟店模式兩層價格（2026-04-21 review）

加盟店模式下、商品有**兩層價格**概念：

| 層級 | 欄位 / 來源 | 誰決定 | 誰看得到 |
|---|---|---|---|
| **總部成本價**（加盟主進貨價）| `stock_balances.avg_cost`（移動平均、入庫時累計）| 總部採購 | 加盟主 + 總部 |
| **門市銷售價**（顧客買價）| `prices.scope='store', scope_id=<store_id>` | 加盟主自訂 | 加盟主 + 顧客 |

**加盟主毛利** = `門市銷售價 - stock_balances.avg_cost`

- 技術上**不需**新 schema（現有欄位足以表達）
- 報表 / UI 層要明確區分「成本價」、「建議售價」、「門市售價」
- **目前預設全加盟主同一成本**、不做差別定價
- P2+ 若需「總部給不同加盟主不同進貨價」→ 新增 `store_cost_prices` 表

**相關 issue**: [#85](https://github.com/www161616/new_erp/issues/85)

---

## 1. 模組定位
- [ ] 本模組是**商品主檔 Single Source of Truth**，定義「一個 SKU 到底是什麼」
- [ ] 涵蓋三大子領域：**商品主檔** + **多單位 / 多條碼** + **價格策略**
- [ ] 其他模組（庫存、採購、銷售）只讀本模組、不得 UPDATE 本模組表
- [ ] 條碼識別、標籤列印、多單位換算在本模組內完成

---

## 2. 核心概念 / 名詞定義
- [ ] **商品（Product）**：業務概念上的一個販售品項；1 個 Product = 1 或多個 SKU
- [ ] **SKU（Stock Keeping Unit）**：最小庫存管理單位；同一 Product 的不同口味 / 顏色 / 容量 = 不同 SKU
- [ ] **單位（UOM, Unit of Measure）**：個 / 盒 / 箱 / kg / 組等；每 SKU 有 1 個 **base_unit**
- [ ] **包裝換算（Pack）**：`1 箱 = 12 盒 = 144 個`，以 base_unit 為 1
- [ ] **條碼（Barcode）**：`barcode_value → sku_id + unit`（不同單位可掛不同條碼）
- [ ] **品類（Category）**：大類 / 中類 / 小類的樹狀分類
- [ ] **品牌（Brand）**：商品的品牌歸屬（1 對多 SKU）
- [ ] **供應商關聯（Supplier Link）**：某 SKU 可由哪些供應商提供（僅放關聯，實際供應商主檔屬採購模組）
- [ ] **售價（Retail Price）**：建議售價 / 現行售價 / 會員價 / 促銷價
- [ ] **成本（Cost）**：標準成本（採購基準）— 實際成本（移動平均）由庫存模組維護

---

## 3. Goals
- [ ] G1 — 新增 SKU 從填表到上架（可售、可掃、可配）≤ 3 分鐘
- [ ] G2 — 任一 SKU 查詢（包含條碼、單位、現行售價）P95 < 100ms
- [ ] G3 — 同一 Product 支援至少 5 個 SKU 變體（如不同容量）且 UI 不混淆
- [ ] G4 — 條碼識別率 ≥ 99%；同一 SKU 可綁多條碼（原廠 + 內部 + 替換）
- [ ] G5 — 價格變更可**排程生效**（未來 00:00 自動切換），且可回溯歷史售價
- [ ] G6 — 大量匯入 15,000 SKU + 條碼 + 售價 ≤ 10 分鐘（初始化 / 資料搬遷情境）

---

## 4. Non-Goals（v1 不做）
- [ ] ❌ **商品組合 / 套裝（Bundle / Kit）** — P1（買 A+B 組合優惠）
- [ ] ❌ **多語系商品名稱** — P2
- [ ] ❌ **商品圖片 CDN 自動優化** — v1 只存 URL，由雲儲存處理
- [ ] ❌ **自建條碼列印機驅動** — 沿用 BarTender（同條碼模組決策）
- [ ] ❌ **動態定價 / AI 推薦價** — P2
- [ ] ❌ **RFID / NFC**、**OCR 辨識**、**序號管理（3C）** — P2
- [ ] ❌ **商品評論 / 問答** — 非 ERP 範疇

---

## 5. User Stories

### 主檔管理員
- [ ] 作為主檔管理員，我要能新增商品、填入品名 / 分類 / 品牌 / 單位 / 成本 / 售價 一次完成
- [ ] 作為主檔管理員，我要能為同一 Product 建立多個 SKU 變體（例如「茶飲-300ml、500ml」）
- [ ] 作為主檔管理員，我要能為 SKU 追加「替換條碼 / 別名條碼」
- [ ] 作為主檔管理員，我收到無原廠條碼的商品時，要能**一鍵產生內部條碼 + 列印標籤**
- [ ] 作為主檔管理員，我要能批次匯入 / 匯出 SKU + 條碼 + 售價（CSV）
- [ ] 作為主檔管理員，我要能**下架** SKU（不刪除，但各端點不再銷售 / 採購）

### 採購
- [ ] 作為採購，我要看到某 SKU 的**可用供應商**、各家報價與 lead time
- [ ] 作為採購，我要能維護 SKU 的**標準成本**（用於採購預算）

### 店長 / 店員
- [ ] 作為店員，我 POS 掃條碼 → 立即帶出 SKU、現行售價、本店庫存
- [ ] 作為店長，我要能**本店調整售價**（若總部授權）；否則只讀
- [ ] 作為店員，我掃到未知條碼 → 可呼叫主檔管理員當場綁定（若無權限則進待處理佇列）

### 總部老闆
- [ ] 作為總部老闆，我要能**一次調整全集團售價**並排程生效
- [ ] 作為總部老闆，我要看到售價 / 成本 / 毛利率分析（v1 提 API，UI 可先陽春）

---

## 6. Functional Requirements

### 6.1 商品主檔（Product / SKU）
- [ ] **層級**：`Product (1) ── (N) SKU`
- [ ] Product 欄位：`product_code, name, brand_id, category_id, description, images[], status(draft/active/inactive/discontinued)`
- [ ] SKU 欄位：`sku_code, product_id, variant_name (例: 500ml), spec (JSONB), base_unit, weight, status, tax_rate`
- [ ] 自動生成 `sku_code`：規則可設定（預設 `P` + yyMMdd + 4 碼流水）
- [ ] **軟刪除**：`status = discontinued`；禁止物理刪除（因有歷史單據引用）
- [ ] 圖片：存 URL（Supabase Storage 或外部 CDN），主圖 + 最多 5 張

### 6.2 分類與品牌
- [ ] `categories` 為樹狀（大類 → 中類 → 小類，建議 3 層上限）
- [ ] 一個 SKU 只歸一個葉節點分類
- [ ] `brands` 獨立表，一個 SKU 一個品牌
- [ ] 分類 / 品牌皆為 tenant 範圍內可自訂

### 6.3 多單位與包裝換算（UOM / Pack）
- [ ] 每 SKU 指定一個 `base_unit`（如「個」）；所有庫存以 base_unit 計量
- [ ] `sku_packs` 表記錄「替代單位 → 換算值」：
  - [ ] 例：箱 = 144 個、盒 = 12 個
  - [ ] 可設定該單位是否可「銷售」/「採購」/「配貨」
  - [ ] 可設定該單位的**專屬條碼**（掃「箱條碼」= 帶出 144 個 base_unit）
- [ ] **換算規則**：永遠用整數換算（避免浮點），不允許非整數倍 pack（如「0.5 箱」）
- [ ] POS 掃到箱條碼時：明細顯示「1 箱 = 144 個」並正確扣庫存 144

### 6.4 條碼（Barcode）— 併入本模組
- [ ] **條碼類型**：EAN-13 / EAN-8 / UPC-A / UPC-E / CODE-128 / 內部碼
- [ ] 同一 SKU 可綁**多條碼**；每個條碼綁定一個**單位**（個 / 盒 / 箱）
- [ ] 每 SKU 指定一個 `primary_barcode`（預設列印用）
- [ ] **未知條碼**：掃到未註冊條碼 → 回「未知」+ 引導綁定（有權限者）或進待處理佇列
- [ ] **退役條碼**：`status = retired`，仍可識別但 UI 提示「請改貼新條碼」
- [ ] **內部條碼產生規則**：`LT` + `yyMMdd` + 5 碼流水 + 1 碼 check digit（CODE-128，共 14 碼）
- [ ] 序號不重複：走集中流水號池（`internal_barcode_sequence`）
- [ ] **多租戶唯一範圍**：`(tenant_id, barcode_value)` unique

### 6.5 條碼識別 API（熱路徑）
- [ ] `GET /products/lookup?barcode=xxx&context=pos|gr|transfer|stocktake`
  → 回 `sku_id, product_name, unit, pack_qty, current_price, tax_rate, is_active`
- [ ] 目標 P95 < 50ms（含 DB hit）
- [ ] 走熱資料快取（Redis / Postgres shared_buffers 友善索引）
- [ ] Context-aware：POS 回銷售價；GR（收貨）回採購單位與標準成本

### 6.6 標籤列印
- [ ] 列印場景：價格標、貨架標、箱標（P1）、效期標（P1）
- [ ] 整合方式：
  - [ ] v1：輸出 CSV / PDF，餵給 BarTender（使用者既有工具）
  - [ ] P1：直接呼叫標籤機 API（需確認機型）
- [ ] 批次列印：選 SKU 清單 → 指定份數 + 模板 → 產出

### 6.7 價格策略（Pricing）
- [ ] **三層價格模型**：
  - [ ] **Retail Price（建議售價）**：總部標牌價
  - [ ] **Store Price（門市現行價）**：各店可覆寫（若總部授權），否則繼承
  - [ ] **Member Price / Promo Price**：會員等級價 / 促銷活動價（時限）
- [ ] 價格 **不** 直接改 SKU 欄位，而是存在 `prices` 版本表（append-only）：
  - [ ] `(tenant_id, sku_id, scope, scope_id, price, effective_from, effective_to, created_by)`
  - [ ] scope：`retail` / `store:<location_id>` / `member_tier:<tier_id>` / `promo:<promo_id>`
- [ ] **查詢當前有效價**：`effective_from <= NOW() < effective_to`（NULL = 無上限）
- [ ] **排程變價**：填 `effective_from` 未來時間即可
- [ ] **歷史可回溯**：任一時間點的售價都可查（用於退貨原價還原、對帳）
- [ ] **價格變更審計**：改價必填「變更原因」（總部老闆可免）

### 6.8 促銷活動（Promotion）
- [ ] v0.1：**僅支援基本時限促銷價**（單品打折）
- [ ] `promotions` 表：`code, name, type(fixed|percent), discount, start_at, end_at, applicable_sku_ids[], applicable_store_ids[]`
- [ ] 促銷優先序：`promo > member > store > retail`（同時存在取最低；可切換）
- [ ] **買 A 送 B / 滿額折**、**點數折抵** 屬 P1（涉及銷售模組）

### 6.9 供應商關聯
- [ ] `sku_suppliers`：`(sku_id, supplier_id, supplier_sku_code, lead_time_days, min_order_qty, last_cost, is_preferred)`
- [ ] 一個 SKU 可有多供應商；標記 1 個偏好供應商（採購建議用）
- [ ] 供應商主檔 `suppliers` 由**採購模組**擁有，本模組只引用 `supplier_id`

### 6.10 匯入 / 匯出
- [ ] CSV 匯入：商品 + SKU + 條碼 + 售價 + 供應商關聯
- [ ] 匯入模式：`create_only` / `update_only` / `upsert`
- [ ] 匯入前驗證：必填、格式、條碼重複、分類存在；錯誤行列出、可部分匯入
- [ ] 匯出：任一篩選條件下的 SKU 清單（含條碼、售價）

### 6.11 商品狀態流
- [ ] `draft`（草稿）→ `active`（上架可售可採）→ `inactive`（暫時下架，可重啟）
- [ ] `active` → `discontinued`（停產；歷史單據仍可引用，不能再採購/銷售）
- [ ] 狀態變更留稽核（who / when / why）

---

## 7. 非功能需求（NFR）
- [ ] **資料一致性**：Product / SKU / Barcode / Price 屬強一致；促銷可 eventual
- [ ] **效能**：
  - [ ] 條碼 lookup P95 < 50ms、P99 < 200ms
  - [ ] SKU 主檔查詢 P95 < 100ms
  - [ ] 15,000 SKU 列表分頁載入 < 1s
- [ ] **併發**：同一 SKU 同時改售價（總部 + 門市）→ row-level lock，後寫覆蓋前寫但必須有 audit
- [ ] **稽核**：主檔變更 / 價格變更 / 條碼綁定退役皆留紀錄（operator, ip, before/after）
- [ ] **多租戶**：所有表 + 查詢必帶 `tenant_id`；條碼唯一範圍限 tenant 內
- [ ] **離線容錯**（POS 關鍵）：
  - [ ] POS 本地快取「常用 SKU × 條碼 × 當前售價」每日同步
  - [ ] 斷網 4 小時內仍可掃碼結帳

---

## 8. 權限（RBAC 對應本模組）

| 權限 | 總部老闆 | 主檔管理 | 採購 | 店長 | 店員 |
|---|:-:|:-:|:-:|:-:|:-:|
| 查 SKU 主檔 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 新增 / 編輯 SKU | ✅ | ✅ | ❌ | ❌ | ❌ |
| 下架 / 停產 SKU | ✅ | ✅ | ❌ | ❌ | ❌ |
| 綁定條碼到既有 SKU | ✅ | ✅ | ✅ | ❌ | ❌ |
| 產生內部條碼 | ✅ | ✅ | ❌ | ❌ | ❌ |
| 退役條碼 | ✅ | ✅ | ❌ | ❌ | ❌ |
| 列印標籤 | ✅ | ✅ | ✅ | ✅ | ❌ |
| 調整全集團售價 | ✅ | ✅ | ❌ | ❌ | ❌ |
| 調整本店售價 | ✅ | ✅ | ❌ | ✅（授權開關）| ❌ |
| 設定促銷活動 | ✅ | ✅ | ❌ | ❌ | ❌ |
| 維護供應商關聯 | ✅ | ✅ | ✅ | ❌ | ❌ |
| 批次匯入 / 匯出 | ✅ | ✅ | ❌ | ❌ | ❌ |

- [ ] 店長可否改本店售價 → `tenants` 層級開關控制
- [ ] 所有寫入操作必留 audit（operator_id、ip、before_value、after_value）

---

## 9. 資料模型草稿（待 Review）

- [ ] `categories` — 分類樹（parent_id 遞迴）
- [ ] `brands` — 品牌主檔
- [ ] `products` — 商品主檔（業務層級）
- [ ] `skus` — SKU 主檔（庫存 / 單據引用目標）
- [ ] `sku_packs` — 多單位換算（1 箱 = 12 盒 = 144 個）
- [ ] `barcodes` — 條碼對應（sku + unit）
- [ ] `internal_barcode_sequence` — 內部條碼流水號池
- [ ] `pending_barcodes` — 未知條碼待處理佇列
- [ ] `prices` — 價格版本表（append-only，帶 effective 時間）
- [ ] `promotions` — 促銷活動主檔
- [ ] `promotion_skus` — 促銷適用 SKU 明細
- [ ] `sku_suppliers` — SKU × 供應商關聯（成本 / lead time）
- [ ] `product_audit_log` — 主檔變更稽核

---

## 10. 與其他模組的整合點

- [ ] **庫存模組** → 讀 `skus` / `sku_packs`；建立 `stock_balances` 的 key
- [ ] **採購模組** → 讀 `sku_suppliers` / 標準成本；收貨時將實際成本回寫入庫（但寫入 movement，不改主檔）
- [ ] **銷售 / POS 模組** → 熱路徑呼叫條碼 lookup API + 當前有效價查詢
- [ ] **條碼識別 / 標籤** → 已併入本模組（原 `PRD-條碼模組` 作為深入補充）
- [ ] **會員模組** → 讀會員等級 → 查 `prices.scope = member_tier:X` 取會員價
- [ ] **報表模組** → 讀 `prices` + `stock_movements.unit_cost` 計毛利

---

## 11. 驗收準則（Acceptance Criteria）
- [ ] 新增一個 Product + 1 SKU + 1 base_unit + 1 售價，3 分鐘內完成、可被 POS 掃到
- [ ] 同一 SKU 綁 3 個條碼（個 / 盒 / 箱），分別掃到時帶出正確單位與換算
- [ ] 未知條碼掃 → 顯示「未知」+ 綁定 / 新增 / 忽略三選項；有權限者綁定後 10 秒內他機可識別
- [ ] 排定「明天 00:00 全部 SKU 售價 +5%」→ 今天查 = 原價、明天 00:00:01 查 = 新價
- [ ] 查 2 週前「某 SKU 當時售價」→ 取得正確歷史價
- [ ] 總部促銷「A 商品 8 折，2026/04/25 ~ 2026/04/30」→ 期間內 POS 抓到 8 折價、期外回原價
- [ ] 店員改本店售價 → 若 tenant 未授權 → 403
- [ ] CSV 匯入 1,000 SKU（含條碼 + 售價）→ ≤ 1 分鐘；錯誤行可下載修正後重匯
- [ ] 停產 SKU 後：新採購單 / POS 無法選；歷史單據仍可開啟

---

## 12. Open Questions（請回答以推進 v0.2）

### 商品主檔
- [x] **Q1 Product vs SKU 模型**：~~15,000 SKU 是否真有多變體需求？~~ → **決定：兩層（Product 1 → SKU N）**。理由：業態確有變體需求（容量 / 口味 / 尺寸等），兩層在改品名、報表分組、促銷系列、商品圖共用上都更清爽。（2026-04-20）
- [x] **Q2 分類深度**：~~3 層（大/中/小）是否夠？~~ → **決定：3 層**。業態為團購店，品項雜但 3 層足以分類。（2026-04-20）
- [x] **Q3 稅率**：~~台灣 5% 外加 / 內含？是否有免稅商品？~~ → **決定：統一 5% 含稅價、無免稅品**。標價即售價，POS 不再加稅；`skus.tax_rate` 預設 0.0500 用於報表拆解銷售額 / 稅額。（2026-04-20）

### 多單位 / 條碼
- [x] **Q4 箱/盒 採購 vs 個 銷售**：~~是否為通案？~~ → **決定：通案**。多數 SKU 都會有箱 / 盒 / 個多單位設定；`sku_packs` 是核心常用表，POS 與採購 UI 需原生支援單位切換，箱條碼列印為必要功能（非 P1）。（2026-04-20）
- [x] **Q5 箱條碼來源**：~~供應商給？還是自印？~~ → **決定：混合**。有供應商給就用（需支援 SSCC / ITF-14 解析），沒有就自印內部箱條碼；系統兩種都要支援，收貨流程先嘗試識別原廠箱條碼、失敗退回自印流程。（2026-04-20）
- [x] **Q6 舊系統條碼遷移**：~~現有 15,000 SKU 條碼完整度？~~ → **決定：舊系統無條碼資料，全部重建**。內部碼規則自由決定（維持 `LT` + yyMMdd + 5 碼流水 + check digit，14 碼 CODE-128）。(2026-04-20)

  **重大影響**：
  - 15k SKU × 平均 2 單位（個 + 箱，Q4 通案）= 約 30k 條碼需建檔，是 v1 最大工作量之一
  - 建議策略（待 v0.2 確認）：
    - 原廠條碼（EAN-13 等）：安排倉管 / 主檔管理員以手機或掃描槍批次建檔
    - 未掃過的 SKU：採「**邊用邊建**」策略 — POS / 收貨掃到未知條碼 → 當場綁定流程（主檔管理員或有權限者）
    - 無原廠碼的自有商品 / 裸裝商品 → 直接用 `rpc_generate_internal_barcode` 產內部條碼 + 列印貼標
  - 資料遷移時：v0.1 只要求主檔、售價、庫存先就位；條碼可**陸續補建**，不需一次到位

### 價格
- [x] **Q7 定價模型最終決定**：→ **維持四層 scope（retail / store / member_tier / promo），但 promo 支援「總部基準 + 門市覆寫」**。
  - 總部建「團購專案」走 `promo` scope（`applicable_store_ids = []` 代表全店通用）
  - 門市若要調整 → 建同 promo_id 的門市版 prices 紀錄（額外帶 store_id 匹配條件），或另建 `applicable_store_ids = [該店]` 的 promo
  - `rpc_current_price` 需修：promo 比價時若有「本店專屬版」以其為準，否則取通用版；不再單純 `ORDER BY price ASC`（避免門市想調高時反被較低的總部版蓋掉）
  - schema 微調：v0.2 新增 `prices.store_override_id` 或類似欄位支援「促銷的門市覆寫」（待 v0.2 細節）
  （2026-04-20）
- [x] **Q8 店長改本店價**：→ **完全開放、不審核、不限幅度**。店長可自由覆寫本店售價（store scope 或 promo 門市覆寫版），馬上生效；但**所有變更留稽核**（`product_audit_log`：誰 / 何時 / before→after / 事由）供事後稽核或異常分析。預設 RBAC 已支援（店長「調整本店售價」勾選；無 `tenants` 開關需要）。（2026-04-20）
- [x] **Q9 促銷優先序**：→ **只取四層中最低價、不疊加**。`rpc_current_price` 邏輯簡化為「查詢四個 scope 的當前有效價，回傳最低那個」；不做會員折 × 促銷折之類疊加計算。（2026-04-20）

  **影響 `rpc_current_price` 實作**：原版本是依優先序「第一個命中就回傳」，需改為「蒐集四層所有命中值、回傳 `MIN()`」。Q7 門市覆寫 promo 的邏輯仍在 promo 層內處理（取門市專屬版優先於通用版），再與其他三 scope 比最低。
- [x] **Q10 會員等級價**：→ **保留 B + C 兩種機制並存**。（2026-04-20）

  - **B（點數倍率）**：`member_tiers.benefits.points_multiplier`（例：金卡 1.5x）。只影響回饋點數，不影響結帳金額；走會員模組 `rpc_earn_points` 計算。
  - **C（等級折扣）**：`member_tiers.benefits.discount_rate`（例：金卡 0.90 = 9 折）。結帳時會員等級價 = `retail_price × discount_rate`，再與其他 scope 比最低（依 Q9 規則）。
  - **不用 A（per-SKU 會員價）**：`prices.scope = member_tier` 不再必要；schema 保留但 v1 不主動寫入（留給未來特殊情境用）。
  - **rpc_current_price 調整**：`member_tier` 那一層改為「讀 `tier.benefits.discount_rate` × retail_price」取代原本的 `prices.scope = member_tier` 查詢。

### 供應商
- [x] **Q11 供應商主檔歸屬**：→ **採購模組**（業界主流：SAP MM / Oracle Procurement / NetSuite / Odoo / Dynamics 皆同）。商品模組僅存 `sku_suppliers` 關聯表（`sku_id × supplier_id`），`supplier_id` 指向採購模組的 `suppliers` 主檔。（2026-04-20）
- [x] **Q12 一品多商**：→ **混合：預設帶 `is_preferred` 供應商，但 UI 列出所有可用供應商供採購切換**。不強制自動選擇，保留採購彈性（貨源不穩、活動價時可改選）。（2026-04-20）

### 資料遷移
- [x] **Q13 舊系統主檔搬遷**：→ **混合來源：爬蟲 + CSV + 邊用邊建（D）**。（2026-04-20）

  **搬遷策略**：
  - **爬蟲來源**：從供應商 / 通路網頁抓取商品資訊（品名、規格、圖、原廠條碼）；需有**去重與清理 pipeline**（同商品多來源、規格解析、圖片下載）
  - **CSV 匯入**：PRD §6.10 已涵蓋；供人工整理的清單批次上架
  - **邊用邊建（D）**：v1 上線時不要求 15k SKU 全部就位；採購收貨 / POS 掃到新商品時可**現場建立**（最少欄位：品名 + 條碼 + 售價 + 成本 + 分類），其他欄位可後補
  - 與 Q6 條碼策略呼應：條碼也可陸續補
  - **需要的工具**（v0.2 展開）：
    1. Crawler 輸出 → `products / skus / barcodes` 的正規化 loader
    2. CSV 驗證 + upsert（已有 §6.10）
    3. POS / 收貨「快速建檔」UI（最小欄位、權限給主檔管理員或授權店員）

### 外部通路上架（樂樂 / 未來其他通路）
- [ ] **Q14 樂樂建品項 XLS 格式支援**（2026-04-23 開題）：樂樂通路批量上架商品的範本為 **24 欄 XLS**（實檔 `batch_file_20240412.xls`，Big5 編碼、xlrd 讀），結構如下：

  | 樂樂欄位 | new_erp schema 對應 | 備註 |
  |---|---|---|
  | 自訂編號 | `products.code` | 必填、unique |
  | 商品名稱 | `products.name` | 必填 |
  | 主要款式 / 款式一 / 款式二 | SKU variants | 樂樂三層款式 → new_erp SKU 變體（對應規則待釐清）|
  | 售價 / VIP價 | `current_price`（retail / member_tier） | 走 `rpc_current_price` 計算 |
  | 成本 | `sku_suppliers.is_preferred` 的 cost | |
  | 庫存 | `skus.on_hand_qty` | snapshot 時點 |
  | 允許VIP購 / 增加個人份 / 僅供現貨 / 訊息類 / 可用人次 | **無對應 schema** | 樂樂平台專屬旗標，建議新增 `products.lele_meta JSONB` 避免污染主檔 |
  | 商品分類 | `products.category_id` | 需做 ID → 樂樂分類名稱 lookup 表 |
  | 收單時間 | `campaigns.close_at` | 若該商品在樂樂綁某 campaign 上架 |
  | 自訂訂類 / 攤位位置 | **無對應** | 樂樂 UI 欄位，放 `lele_meta` |
  | 預設供貨商 | `sku_suppliers.is_preferred` 的 name | |
  | 商品描述 / 商品備註 / 退款備註 | 需新增 `products.description` / `notes` / `refund_notes` | 或統一放 `lele_meta` |

  **待決議 sub-questions**：
  1. **new_erp 要不要生出這個 XLS？**（一鍵匯出 v.s. 使用者自己維護兩邊）
  2. **誰經營樂樂通路？**（總部統一 / 各加盟店自有樂樂帳號 / 混合）— 依 [[decisions/2026-04-23-系統立場-混合型]] 可能是「加盟店自主」
  3. **樂樂三層款式 vs new_erp SKU**：是否需要正式 mapping 表，還是 ad-hoc 規則
  4. **`lele_meta JSONB`**：是否該加進 v0.2 schema（預留通路旗標欄位）

  **artifact 位置**：使用者 Downloads 內 `batch_file_20240412.xls`（24 欄範本 + 1 筆範例）；對照 [[PRD-訂單取貨模組-v0.2-addendum]] §8 Q1（樂樂訂單 CSV 23 欄）為 import 方向、本 Q14 為 export 方向。

---

## 13. 下一步
- [ ] 回答 Q1~Q13 → 進入 v0.2（展開 API 合約、UI wireframe、匯入模板）
- [ ] Spike：條碼 lookup + 當前有效價 查詢效能（P95 < 50ms）
- [ ] Spike：多單位 POS 掃碼 end-to-end（掃箱條碼 → 扣 144 個 base_unit）
- [ ] Spike：價格排程生效 + 歷史回溯查詢
- [ ] 先做資料模型 POC：Product / SKU / Pack / Barcode / Price 五表的增改查

---

## 相關連結
- [[PRD-庫存模組]]
- [[PRD-採購模組]]
- [[PRD-銷售模組]]
- [[PRD-條碼模組]] — v0.1 已併入本模組；原文保留為掃碼 / 列印深入補充
- [[PRD-會員模組]] — 會員等級價的來源
- [[專案總覽]]
- 舊系統參考：`lt-erp/ProductList.html`, `ProductForm.html`, `Pricing.html`

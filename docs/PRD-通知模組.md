---
title: PRD - 通知模組
module: Notification
status: draft-v0.2
owner: www161616
created: 2026-04-21
updated: 2026-04-21
tags: [PRD, ERP, 通知, Notification, LINE, OA, Franchise]
---

# PRD — 通知模組（Notification Module）

> 零售連鎖 ERP，總倉 1 + 門市 100（**加盟店模式**）+ SKU 15,000。
> 本模組負責「何時、對誰、透過什麼管道、發什麼訊息」，以及「送達 / 失敗 / 重試」的稽核。
> **核心設計：每加盟店獨立申請並維護自己的 LINE OA，自行決定通知啟用範圍與成本。**
> v0.2 checklist 版（Q1~Q12 全數決策）。

---

## 1. 模組定位
- [x] **事件驅動**：其他模組（訂單 / 庫存 / 採購）發事件，本模組消費
- [x] **每加盟店獨立 LINE OA**：系統管理每店 OA 憑證、訊息額度與計費由店東自負
- [x] **每店三種通知模式可選**：完整 / 精簡 / 零推播（§6.9）
- [x] 統一 **訊息範本 / 變數代入**（總部預設、店長可微調）
- [x] **失敗不擋業務主流程**：送不到只記錄、不 rollback 上游（例如訂單仍算成立）
- [x] **不承擔會員生命週期通知**（生日 / 升等 / 點數到期 / 儲值金餘額）— v1 明確排除
- [x] 其他模組 **不得直接呼叫 LINE API**，一律透過本模組 RPC（`rpc_enqueue_notification`）
- [x] **總部不承擔 OA 費用**：系統層面僅提供功能，實際 LINE 訊息成本由各加盟店自付

---

## 2. 核心概念 / 名詞定義
- [x] **通知事件（Event）**：由上游模組產生的訊號，如「訂單到貨」「快過期」
- [x] **通知類型（Notification Type）**：對應的通知種類 code，如 `pickup_ready` / `pickup_reminder`
- [x] **通知模式（Notification Mode）**：每店可設 `full / simple / none` 三擇一（§6.9）
- [x] **範本（Template）**：特定通知類型的訊息格式（含變數 placeholder），總部出預設、店長可覆寫
- [x] **通知記錄（Notification Log）**：每一則實際發出的通知，狀態 = `queued / queued_deferred / sent / failed / blocked`
- [x] **收件人（Recipient）**：顧客（`line_user_id` **per store**）或店長群組（`line_group_id`）
- [x] **店家 OA 憑證（Store OA Credentials）**：每店的 LINE Channel Access Token + Channel Secret
- [x] **時段規則（Quiet Hours）**：僅允許發送的時間窗（顧客 09:00–21:00；店長全天）
- [x] **失敗清單（Failure List）**：`status = failed / blocked` 的後台清單，供店長人工跟進
- [x] **公休日（Off Day）**：每店自行設定的休息日，影響取貨期限計算

---

## 3. Goals
- [x] G1 — 訂單到貨、觸發顧客通知 ≤ 10 秒內排入佇列
- [x] G2 — 佇列中的通知 95% 以上 ≤ 60 秒內送達 LINE API
- [x] G3 — 失敗清單可在後台即時查看，店長可一鍵「標記已電聯」
- [x] G4 — 每月統計報表一鍵產出（總發送數、失敗數、各類型分布 — 每店獨立 + 總部匯總）
- [x] G5 — 時段外產生的顧客通知自動延至隔天 09:00 發送
- [x] G6 — 加盟店可在**後台 10 分鐘內完成**自己的 LINE OA 設定並上線發送

---

## 4. Non-Goals（v1 不做）
- [x] ❌ 下單成功確認通知（顧客在 LINE 社群對話中已確認）
- [x] ❌ 會員相關通知（生日 / 點數到期 / 會員升等 / 儲值金餘額低）
- [x] ❌ 庫存過低警示（採購端另案處理）
- [x] ❌ 簡訊 / Email 備援（LINE 送不到 → 店長打電話跟進）
- [x] ❌ 顧客端細分類 opt-out（顧客要全關只能封鎖 OA）
- [x] ❌ 即時 dashboard（v1 只做每月報表，P1 再升級）
- [x] ❌ EDM / 行銷推播 / A/B test
- [x] ❌ P2P 客服對話（非通知範圍）
- [x] ❌ **店長群「新訂單通知」**（Q7 決定：店員直接看後台訂單列表）
- [x] ❌ **總部統一 LINE OA**（Q12 決定：加盟店各自管，總部不承擔）
- [x] ❌ 跨店顧客統一 OA 入口（顧客要收哪店通知就加哪店 OA）

---

## 5. User Stories

### 顧客
- [x] 作為顧客，我要在 LINE 社群看到「加入本店官方帳號」QR code，自主選擇是否加入
- [x] 作為顧客，我在 A 店加了 OA → 只會收到 A 店的通知；在 B 店也要加 → 得加 B 店的 OA
- [x] 作為顧客，我要在商品到店當天收到 LINE 通知（若該店啟用）
- [x] （若該店模式為「完整」）作為顧客，我要在取貨期限前 1 天收到提醒
- [x] （若該店模式為「完整」）作為顧客，我要在逾期後收到通知

### 店東 / 店長（加盟主）
- [x] 作為店東，我要能在後台設定自己的 LINE OA 憑證（貼上 Channel Access Token）
- [x] 作為店東，我要能選擇本店的通知模式（完整 / 精簡 / 零推播）
- [x] 作為店長，我要收到「商品快過期」警示（若模式 ≠ 零推播）
- [x] 作為店長，我要收到「顧客逾期未取」通知（若模式 ≠ 零推播）
- [x] 作為店長，我要能在後台看「送不到的失敗清單」（限本店），勾選「已電聯」
- [x] 作為店長，我要能微調本店範本（例如加開店時間、地址）
- [x] 作為店長，我要能看本店每月發送統計與成本
- [x] 作為店長，我要能**隨時切換模式**（感覺貴了就降級為精簡 / 零推播）

### 總部
- [x] 作為總部，我要維護全系統預設範本（所有加盟店繼承，可覆寫）
- [x] 作為總部，我要看到**每店選了哪種模式**的全局視圖
- [x] 作為總部，我要看到每月各店的發送量 / 失敗率（但不看個別訊息內容，隱私分權）

---

## 6. Functional Requirements

### 6.1 通知類型清單（v1）

> ⚠️ Q7 決策：移除 `store_new_order`（店員看後台）
> ⚠️ 是否啟用由「店家通知模式」決定（§6.9）

| 代碼 | 對象 | 觸發事件 | 時機 | 時段限制 | 模式 full | 模式 simple | 模式 none |
|---|---|---|---|---|---|---|---|
| `pickup_ready` | 顧客 | 訂單到店 | 立即 | 09:00–21:00 | ✅ | ✅ | ❌ |
| `pickup_reminder` | 顧客 | 每日 09:00 批次 | 批次 | 09:00–21:00 | ✅ | ❌ | ❌ |
| `pickup_overdue` | 顧客 | 每日 09:00 批次 | 批次 | 隨時 | ✅ | ❌ | ❌ |
| `store_expiry_alert` | 店長 | 每日 08:00 彙整 | 批次 | 全天 | ✅ | ✅ | ❌ |
| `store_pickup_overdue` | 店長 | 每日 09:00 批次 | 批次 | 全天 | ✅ | ✅ | ❌ |

### 6.2 取貨期限（含公休日順延）
- [x] 預設 **5 天**（可由各店 `stores.pickup_window_days` 覆寫）
- [x] **錨點**：從**實際發送 `pickup_ready` 通知當天**起算（Q10-1 B）
  - 若到貨時間在 21:00 後 → 通知延到隔天 09:00 發 → 5 天從隔天起算
  - 若模式為 `simple` → 取錨點 = 到貨當天 09:00（沒有 reminder/overdue）
  - 若模式為 `none` → 無「通知錨點」概念，直接用到貨當天
- [x] **公休日順延**（Q10-3）：若 5 天期限終點落在該店公休日 → 自動順延到下個營業日
- [x] **每店公休日自訂**（Q10-2 E）：`stores.off_days` JSONB 欄位
- [x] `pickup_reminder` 發送日：`通知錨點 + 4 天`
- [x] `pickup_overdue` 發送日：`通知錨點 + 6 天`

### 6.3 範本管理（Q1 語氣決策）
- [x] **語氣風格**：統一採**友善親切**（因顧客以婆婆媽媽為主）
  - 範例：「嗨～您訂的東西到囉 😊 訂單 #{{order_no}}，5 天內來拿唷！地址：{{store_address}}」
- [x] `notification_templates` 兩層：
  - `scope = tenant`：總部層級預設
  - `scope = store, scope_id = store_id`：店長覆寫
- [x] 優先序：店長覆寫 > 總部預設
- [x] 標準變數：`{{customer_name}}` / `{{order_no}}` / `{{pickup_deadline}}` / `{{store_name}}` / `{{store_address}}` / `{{store_phone}}` / `{{order_items}}`
- [x] **隱私遮罩規則（Q6）**：店長群組通知中 `{{customer_name}}` / `{{customer_phone}}` **一律遮罩**
  - 姓名：`王**`、手機：`0912-***-678`
  - 完整資料需店長登入後台查看
- [x] 範本修改走版本化（`notification_templates_history`），可回溯

### 6.4 時段與批次發送規則
- [x] 顧客端 `quiet_hours = {start: 21:00, end: 09:00}`，對 `pickup_ready` / `pickup_reminder` 生效
- [x] 超出時段 → `status = queued_deferred`，`scheduled_at` 設隔天 09:00
- [x] `pickup_overdue`（顧客）+ 所有店長通知 → 不受時段限制
- [x] **定時 job 排程**（以台北時間為準）：
  - 每日 **08:00**：`store_expiry_alert` 彙整發送
  - 每日 **09:00**：`pickup_reminder` / `pickup_overdue` / `store_pickup_overdue` 批次發送

### 6.5 發送流程
- [x] 上游呼叫 `rpc_enqueue_notification(p_store_id, ...)` → 寫入 `notification_logs`
- [x] **若該店 `notification_mode = none`** → 直接略過、不寫 log、不扣費
- [x] **若該店 `notification_mode = simple`** 且類型為 `pickup_reminder` / `pickup_overdue` → 直接略過
- [x] Worker 輪詢 queue → **讀該店 OA 憑證** → 打 LINE API
- [x] 成功 → `status = sent`，記 `sent_at`、`line_message_id`
- [x] 失敗（API 錯誤）→ `status = failed`，記 `error_code`、`error_detail`
- [x] 顧客封鎖該店 OA → `status = blocked`

### 6.6 失敗處理與重試
- [x] **系統不自動重試**（避免疲勞轟炸）
- [x] **顧客無 `line_user_id` 特例**（Q3 B）：系統每日自動重試一次，等顧客補加**對應店的** OA 後自動補發
  - 若超過 `pickup_overdue` 觸發日仍未綁 → 自動停止重試、轉入失敗清單
- [x] 失敗自動進「失敗清單」頁面
- [x] 店長手動動作：`標記已電聯 / 新增備註 / 重發`
- [x] **重發限制（Q9 D）**：同一則最多重發 **3 次**，兩次重發間隔至少 **10 分鐘**
- [x] **失敗清單保留（Q11 B）**：90 天後自動 archive

### 6.7 統計報表與計費
- [x] 每月自動產生：`notification_monthly_reports` 物化表
- [x] 欄位：`yyyymm, type, store_id, total_sent, total_failed, total_blocked, estimated_cost`
- [x] 報表頁面每店獨立；總部可匯總檢視
- [x] `estimated_cost`：根據該店 LINE OA 方案（`stores.line_oa_plan`）估算（輕用量 / 進階 / 專業）
- [x] 店長後台首頁顯示「本月已發 X 則 / 方案上限 Y 則」— **超量提醒店長升級或改模式**

### 6.8 顧客綁定 LINE OA 策略（Q2 C）
- [x] **雙管齊下**（**per store**）：
  - 該店的 LINE 社群置頂貼文放「請加入 XX 店 LINE 官方帳號」QR code
  - 店員看到 +1 留言 → 確認顧客是否已加**本店 OA** → 未加 → 私訊補推
- [x] 綁定流程：顧客加某店 OA → 系統收該店 webhook → 透過手機號 / LIFF 綁定對應會員 → 寫入 `member_line_bindings (member_id, store_id, line_user_id)`
- [x] **同一會員在不同店有不同 `line_user_id`**（LINE OA 機制限制，不可避免）
- [x] 無該店 `line_user_id` 的顧客：走 §6.6 每日重試流程

### 6.9 加盟店通知模式（Q12 核心新增）

**三種模式由店東在後台選擇：**

| 模式 | 顧客通知 | 店長通知 | 適用情境 | 預估月費（LINE OA）|
|---|---|---|---|---|
| **`full`（完整）** | ready + reminder + overdue | expiry + overdue | 生意好、想極致顧客體驗 | $1,800 專業方案起 |
| **`simple`（精簡）** | 僅 ready | expiry + overdue | **預設推薦**，兼顧效果與成本 | $800 進階方案夠用 |
| **`none`（零推播）** | ❌ | ❌ | 捨不得花錢、店長親力親為 | $0（但需買 LINE OA 帳號）|

**模式切換規則：**
- [x] 店東登入後台 → 「通知設定」頁 → 下拉選擇模式 → 存檔即時生效
- [x] 切換是**即時**的：新訂單立刻按新模式處理；既有 queued 通知保持原模式規則
- [x] 總部無權改店家模式（店東自主）
- [x] 新加盟店預設 `simple` 模式（平衡選項）
- [x] 若店家**未設 LINE OA 憑證** → 強制 `none` 模式（系統 enforce）
- [x] 後台顯示「切到此模式後，每月預估省 / 多花 X 元」輔助決策

### 6.10 LINE OA 憑證管理（Q12 新增）
- [x] 店東在後台「LINE 設定」頁填入：
  - Channel ID
  - Channel Secret
  - Channel Access Token（長期 token）
  - LINE OA Basic ID / Premium ID（顯示 QR 連結用）
- [x] 系統驗證：上傳後呼叫 LINE API `getBotInfo` → 驗證憑證有效 → 顯示「綁定成功」
- [x] 憑證加密儲存（pgcrypto + Supabase Vault P1）
- [x] **Webhook URL** 由系統提供（每店獨立路徑：`/webhook/line/:store_id`）→ 店東複製貼到 LINE Developer 後台
- [x] 憑證失效（LINE API 401）→ 系統標記該店 OA 異常 → 通知店東重設 + 自動降級為 `none`

---

## 7. Data Model (High Level)

```
stores                                    -- 擴充既有主檔
  ..., 
  notification_mode (enum: full/simple/none) DEFAULT 'simple',
  line_oa_channel_id TEXT,
  line_oa_channel_secret_enc BYTEA,
  line_oa_access_token_enc BYTEA,
  line_oa_basic_id TEXT,
  line_oa_plan (enum: free/advanced/pro) DEFAULT 'free',
  line_oa_quota_monthly INT,
  line_oa_verified BOOLEAN DEFAULT false,
  line_oa_verified_at TIMESTAMPTZ,
  line_group_id TEXT,                     -- 店長群（Q5）
  pickup_window_days INT DEFAULT 5,
  off_days JSONB DEFAULT '{}'             -- Q10 公休
  
notification_templates
  id (PK), tenant_id, scope (tenant/store), scope_id,
  type (code), body, version, active,
  created_by, updated_by, created_at, updated_at

notification_templates_history
  id, template_id (FK), version, body, changed_by, changed_at

notification_logs                         ← append-only
  id (PK), tenant_id, store_id,
  type (code),
  recipient_type (customer/store_group), recipient_id,
  variables JSONB, rendered_text,
  status (queued/queued_deferred/sent/failed/blocked/skipped_mode/archived),
  scheduled_at, sent_at, line_message_id,
  error_code, error_detail,
  source_module, source_ref_id,           -- 冪等 key
  resend_count INT DEFAULT 0,
  parent_log_id UUID,
  created_at

notification_failure_followups
  id (PK), notification_log_id (FK),
  action (called/noted/resent), note,
  operator_id, created_at

notification_monthly_reports              ← 物化
  id, tenant_id, store_id, yyyymm, type,
  total_sent, total_failed, total_blocked,
  estimated_cost NUMERIC(10,2),
  last_calculated_at

member_line_bindings                      -- 每會員 × 每店 = 一筆 binding
  id (PK), tenant_id, member_id, store_id,
  line_user_id TEXT NOT NULL,
  bound_at, unbound_at,
  UNIQUE (store_id, line_user_id),
  UNIQUE (member_id, store_id)
```

---

## 8. RPC / API

| RPC | 用途 |
|---|---|
| `rpc_enqueue_notification(p_store_id, p_type, p_recipient_type, p_recipient_id, p_variables, p_source_module, p_source_ref_id)` | 上游模組排入通知 |
| `rpc_mark_followup(p_log_id, p_action, p_note, p_operator)` | 店長標記失敗已處理 |
| `rpc_resend_notification(p_log_id, p_operator)` | 店長重發（含冷卻 + 上限） |
| `rpc_upsert_template(p_scope, p_scope_id, p_type, p_body, p_operator)` | 新增 / 更新範本 |
| `rpc_compile_template(p_type, p_scope_id, p_variables) → text` | 純函數，前台預覽用 |
| `rpc_monthly_report(p_yyyymm, p_store_id?) → json` | 報表查詢 |
| `rpc_compute_pickup_deadline(p_received_at, p_store_id) → date` | 計算取貨期限（含公休順延） |
| `rpc_set_notification_mode(p_store_id, p_mode, p_operator)` | 店東切換通知模式 |
| `rpc_upsert_oa_credentials(p_store_id, p_channel_id, p_secret, p_token, p_operator)` | 店東設定 OA 憑證 |
| `rpc_verify_oa_credentials(p_store_id) → boolean` | 驗證 OA 憑證有效 |

---

## 9. 權限（RBAC 摘要）

| 動作 | 店員 | 店長 | 店東 | 行銷 | 總部老闆 |
|---|---|---|---|---|---|
| 看失敗清單（本店）| ❌ | ✅ | ✅ | ❌ | ✅ |
| 看失敗清單（全店）| ❌ | ❌ | ❌ | ❌ | ✅ |
| 標記已電聯 / 備註 | ❌ | ✅ | ✅ | ❌ | ✅ |
| 重發通知 | ❌ | ✅ | ✅ | ❌ | ✅ |
| 編輯本店範本 | ❌ | ✅ | ✅ | ❌ | ✅ |
| 編輯總部預設範本 | ❌ | ❌ | ❌ | ❌ | ✅ |
| 看每月報表（本店）| ❌ | ✅ | ✅ | ✅ | ✅ |
| 看每月報表（全店）| ❌ | ❌ | ❌ | ✅ | ✅ |
| 手動觸發 job | ❌ | ❌ | ❌ | ❌ | ✅ |
| **切換通知模式** | ❌ | ❌ | ✅ | ❌ | ❌（店東自主） |
| **設定 LINE OA 憑證** | ❌ | ❌ | ✅ | ❌ | ❌（店東自主） |
| **設定 `line_group_id`** | ❌ | ❌ | ✅ | ❌ | ❌（店東自主） |

> 加盟店自主權：店東角色對通知設定有最終決策權，總部僅提供工具。

---

## 10. 整合點

- **訂單 / 取貨模組**（上游，待建）：觸發 `pickup_ready` / `pickup_overdue`
- **採購 / 收貨模組**（上游）：`goods_receipts.received_at` → 起算取貨期限
- **庫存模組**（上游）：`stock_lots.expiry_date` 臨近 → 觸發 `store_expiry_alert`
- **會員模組**（被讀）：從 `member_line_bindings(member_id, store_id)` 解顧客 `line_user_id`
- **主檔 / 門市**（被讀 & 被寫）：`stores.notification_mode` / `stores.line_oa_*` / `stores.off_days` / `stores.line_group_id`
- **LIFF 前端**（另案）：若未來開 opt-out 頁面會來呼叫本模組 API
- **LINE OA / Messaging API**（外部，**per store**）：實際送達管道

---

## 11. 非功能需求

- [x] **延遲**：事件 → 排入 queue ≤ 10s；queue → 送達 95% ≤ 60s
- [x] **可用性**：LINE API 中斷時 queue 累積、不丟訊息
- [x] **冪等**：同一 `source_module + source_ref_id + type` 在 24h 內只能成功送出一次
- [x] **稽核**：`notification_logs` append-only
- [x] **法遵**：範本需包含「取消訂閱」指引；店長群組資料遮罩避免個資外洩
- [x] **監控**：單店失敗率 > 5% / 小時 → 告警**該店店東**（非總部）
- [x] **資料隔離**：跨店資料讀取 RLS 嚴格限制（加盟店不可看其他店 OA 憑證 / 會員明細）

---

## 12. Open Questions — 全部已決策 ✅

### ✅ Q1 訊息語氣 — **友善親切**（婆婆媽媽客群）（2026-04-21）

### ✅ Q2 顧客 `line_user_id` 綁定策略 — **雙管齊下**（社群置頂 + 店員補私訊）（2026-04-21）

### ✅ Q3 無 `line_user_id` 的顧客 — **系統每日自動重試**（2026-04-21）

### ✅ Q4 `pickup_reminder` 掃描 — **固定每日 09:00 批次發**（2026-04-21）

### ✅ Q5 店長群組 — **一店一群 + 店長交接直接加入原群**（2026-04-21）

### ✅ Q6 範本變數隱私 — **店長群組全遮罩**（姓名末碼 + 手機末 3 碼）（2026-04-21）

### ✅ Q7 `store_new_order` 合流策略 — **不發**，店員看後台（2026-04-21）

### ✅ Q8 `store_expiry_alert` 合流 — **每日 08:00 彙整一則**（2026-04-21）

### ✅ Q9 重發限制 — **10 分鐘冷卻 + 最多 3 次**（2026-04-21）

### ✅ Q10 跨時段延遲 + 公休日 — **通知錨點起算 + 每店 `off_days` + 遇公休順延**（2026-04-21）

### ✅ Q11 失敗清單保留 — **90 天後 archive**（2026-04-21）

### ✅ Q12 LINE OA 成本方案 — **加盟店模式 + 每店三模式自選**（2026-04-21）

**最終決策（取代原 A/C 二選一）：**
- 100 間門市為**加盟店**，各店東自行申請並維護自己的 LINE OA
- 總部**不承擔** OA 訂閱費用
- 每店東可在後台自選通知模式：`full` / `simple` / `none`（§6.9）
  - **預設 `simple`**（僅到貨通知 + 店長警示，平衡選項）
  - 捨得花錢可升 `full`、想省到底可降 `none`
- 顧客跨店購買 → 需各自加對應店 OA（選項 A）
- 未設 OA 憑證的店 → 系統強制為 `none`
- 系統提供「本月估算成本」輔助店東決策

**實作影響：**
- 資料模型增加：`stores.notification_mode` / `stores.line_oa_*` / `member_line_bindings` 多對多
- 新增 RPC：`rpc_set_notification_mode` / `rpc_upsert_oa_credentials` / `rpc_verify_oa_credentials`
- 後台頁面新增：「LINE 設定」頁 + 「通知模式切換」頁
- Worker 需 per-request 讀取對應店 OA 憑證（而非全系統共用）
- 預計增加 **3~5 天**開發工時

---

## 13. 下一步
- [x] Q1~Q12 全數決策完成，PRD 進入 v0.2
- [ ] 確認「訂單 / 取貨模組」PRD 後補事件來源對齊（本模組消費）
- [ ] Spike：LINE Messaging API 節流（單店 100 則 / 分鐘）
- [ ] Spike：`line_user_id` 跨店綁定流程（含 LIFF 首綁）
- [ ] Spike：LINE OA 憑證驗證流程 + 失效降級邏輯
- [ ] UI 原型：店東「LINE 設定」+「通知模式」頁面
- [ ] 文件：加盟店 OA 申請與綁定 SOP（提供給店東參考）

---

## 相關連結
- [[PRD-會員模組]] — `line_user_id` 來源（now per store）
- [[PRD-訂單取貨模組]] — 主要事件來源（待建）
- [[PRD-庫存模組]] — `stock_lots` 臨期事件來源
- [[PRD-採購模組]] — `goods_receipts` 收貨事件來源
- [[專案總覽]]

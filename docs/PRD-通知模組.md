---
title: PRD - 通知模組
module: Notification
status: draft-v0.1
owner: www161616
created: 2026-04-21
tags: [PRD, ERP, 通知, Notification, LINE, OA]
---

# PRD — 通知模組（Notification Module）

> 零售連鎖 ERP，總倉 1 + 門市 100 + SKU 15,000。
> 本模組負責「何時、對誰、透過什麼管道、發什麼訊息」，以及「送達 / 失敗 / 重試」的稽核。
> v0.1 checklist 版。

---

## 1. 模組定位
- [x] **事件驅動**：其他模組（訂單 / 庫存 / 採購）發事件，本模組消費
- [x] 統一 **訊息發送管道**：v1 只接 LINE（顧客走 OA、店長走群組）；簡訊 / Email 未來再開
- [x] 統一 **訊息範本 / 變數代入**（總部預設、店長可微調）
- [x] **失敗不擋業務主流程**：送不到只記錄、不 rollback 上游（例如訂單仍算成立）
- [x] **不承擔會員生命週期通知**（生日 / 升等 / 點數到期 / 儲值金餘額）— v1 明確排除
- [x] 其他模組 **不得直接呼叫 LINE API**，一律透過本模組 RPC（`rpc_enqueue_notification`）

---

## 2. 核心概念 / 名詞定義
- [x] **通知事件（Event）**：由上游模組產生的訊號，如「訂單到貨」「快過期」
- [x] **通知類型（Notification Type）**：對應的通知種類 code，如 `pickup_ready` / `pickup_reminder` / `pickup_overdue`
- [x] **範本（Template）**：特定通知類型的訊息格式（含變數 placeholder），總部出預設、店長可覆寫
- [x] **通知記錄（Notification Log）**：每一則實際發出的通知，狀態 = `queued / queued_deferred / sent / failed / blocked`
- [x] **收件人（Recipient）**：顧客（`line_user_id`）或店長群組（`line_group_id`）
- [x] **時段規則（Quiet Hours）**：僅允許發送的時間窗（顧客 09:00–21:00；店長全天）
- [x] **失敗清單（Failure List）**：`status = failed / blocked` 的後台清單，供店長人工跟進

---

## 3. Goals
- [x] G1 — 訂單到貨、觸發顧客通知 ≤ 10 秒內排入佇列
- [x] G2 — 佇列中的通知 95% 以上 ≤ 60 秒內送達 LINE API
- [x] G3 — 失敗清單可在後台即時查看，店長可一鍵「標記已電聯」
- [x] G4 — 每月統計報表一鍵產出（總發送數、失敗數、各類型分布）
- [x] G5 — 時段外產生的顧客通知自動延至隔天 09:00 發送

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

---

## 5. User Stories

### 顧客
- [x] 作為顧客，我要在商品到店當天收到 LINE 通知，告知訂單編號與取貨期限
- [x] 作為顧客，我要在取貨期限前 1 天收到提醒，避免忘記取
- [x] 作為顧客，我要在逾期後收到通知，知道商品如何處理

### 店長
- [x] 作為店長，我要在店長群組即時收到「新團購訂單」通知，可立即備貨
- [x] 作為店長，我要收到「商品快過期」警示，優先安排出貨或促銷
- [x] 作為店長，我要收到「顧客逾期未取」通知，安排電話跟進
- [x] 作為店長，我要能在後台看「送不到的失敗清單」（限本店），勾選「已電聯」
- [x] 作為店長，我要能微調本店範本（例如加開店時間、地址）
- [x] 作為店長，我要能看本店每月發送統計

### 總部
- [x] 作為總部，我要維護全系統預設範本
- [x] 作為總部，我要看到全系統每月發送報表（總量、失敗率、各類型分布）
- [x] 作為總部，我要看全部門市的失敗清單

---

## 6. Functional Requirements

### 6.1 通知類型清單（v1）

| 代碼 | 對象 | 觸發事件 | 時機 | 時段限制 |
|---|---|---|---|---|
| `pickup_ready` | 顧客 | 訂單到店（`goods_receipt` 綁定 `customer_order`）| 立即 | 09:00–21:00 |
| `pickup_reminder` | 顧客 | 定時掃描（到期前 1 天）| 每日 job | 09:00–21:00 |
| `pickup_overdue` | 顧客 | 定時掃描（超過取貨期限）| 每日 job | **隨時** |
| `store_new_order` | 店長 | `customer_order.status = confirmed` | 立即 | 全天 |
| `store_expiry_alert` | 店長 | 定時掃描（`stock_lots` 臨過期）| 每日晨 | 全天 |
| `store_pickup_overdue` | 店長 | 同 `pickup_overdue` 觸發點 | 每日 job | 全天 |

### 6.2 取貨期限
- [x] 預設 **5 天**（可由總部 `tenant_config` 覆寫）
- [x] 起算：`goods_receipt.received_at`
- [x] `pickup_reminder` 發送日：`received_at + 4 天`
- [x] `pickup_overdue` 發送日：`received_at + 6 天`

### 6.3 範本管理
- [x] `notification_templates` 兩層：
  - `scope = tenant`：總部層級預設
  - `scope = store, scope_id = store_id`：店長覆寫
- [x] 優先序：店長覆寫 > 總部預設
- [x] 變數代入（標準變數）：`{{customer_name}}` / `{{order_no}}` / `{{pickup_deadline}}` / `{{store_name}}` / `{{store_address}}` / `{{store_phone}}` / `{{order_items}}`
- [x] 範本修改走版本化（`notification_templates_history`），可回溯

### 6.4 時段規則
- [x] 顧客端 `quiet_hours = {start: 21:00, end: 09:00}`，對 `pickup_ready` / `pickup_reminder` 生效
- [x] 超出時段 → `status = queued_deferred`，`scheduled_at` 設隔天 09:00，由 job 批次放行
- [x] `pickup_overdue`（顧客）+ 所有店長通知 → 不受時段限制

### 6.5 發送流程
- [x] 上游呼叫 `rpc_enqueue_notification(...)` → 寫入 `notification_logs`（`status = queued` 或 `queued_deferred`）
- [x] Worker（Supabase Edge Function / Cron）輪詢 queue → 渲染範本 → 打 LINE API
- [x] 成功 → `status = sent`，記 `sent_at`、`line_message_id`
- [x] 失敗（API 錯誤）→ `status = failed`，記 `error_code`、`error_detail`
- [x] 顧客封鎖 OA 特例 → `status = blocked`（與一般 failed 區分，失敗清單呈現不同提示）

### 6.6 失敗處理
- [x] **不自動重試**（避免對封鎖用戶的疲勞轟炸）；v1 一次性失敗 = 放棄
- [x] 失敗自動進「失敗清單」頁面
- [x] 店長手動動作：`標記已電聯 / 新增備註 / 重發`
- [x] 重發走新 `notification_logs` 列（不改原失敗列，保留稽核）

### 6.7 統計報表
- [x] 每月自動產生：`notification_monthly_reports` 物化表（每月 1 號 02:00 job）
- [x] 欄位：`yyyymm, type, store_id, total_sent, total_failed, total_blocked`
- [x] 後台頁面：類型 × 門市 × 月份 三維查詢；店長只能看本店；行銷 / 總部看全部

---

## 7. Data Model (High Level)

```
notification_templates
  id (PK), tenant_id, scope (enum: tenant / store), scope_id,
  type (code), body (含 {{vars}}), version, active,
  created_by, updated_by, created_at, updated_at

notification_templates_history
  id, template_id (FK), version, body, changed_by, changed_at

notification_logs                 ← append-only
  id (PK), tenant_id, type (code),
  recipient_type (customer / store_group), recipient_id,
  variables JSONB, rendered_text,
  status (queued / queued_deferred / sent / failed / blocked),
  scheduled_at, sent_at, line_message_id,
  error_code, error_detail,
  source_module, source_ref_id,      -- 上游事件來源（冪等 key）
  created_at

notification_failure_followups
  id (PK), notification_log_id (FK),
  action (called / noted / resent), note,
  operator_id, created_at

notification_monthly_reports       ← 物化
  id, tenant_id, yyyymm, type, store_id,
  total_sent, total_failed, total_blocked,
  last_calculated_at
```

---

## 8. RPC / API

| RPC | 用途 |
|---|---|
| `rpc_enqueue_notification(p_type, p_recipient_type, p_recipient_id, p_variables, p_source_module, p_source_ref_id)` | 上游模組排入通知 |
| `rpc_mark_followup(p_log_id, p_action, p_note, p_operator)` | 店長標記失敗已處理 |
| `rpc_resend_notification(p_log_id, p_operator)` | 店長重發 |
| `rpc_upsert_template(p_scope, p_scope_id, p_type, p_body, p_operator)` | 新增 / 更新範本 |
| `rpc_compile_template(p_type, p_scope_id, p_variables) → text` | 純函數，前台預覽用 |
| `rpc_monthly_report(p_yyyymm, p_store_id?) → json` | 報表查詢 |

---

## 9. 權限（RBAC 摘要）

| 動作 | 店員 | 店長 | 行銷 | 總部老闆 |
|---|---|---|---|---|
| 看失敗清單（本店）| ❌ | ✅ | ❌ | ✅ |
| 看失敗清單（全店）| ❌ | ❌ | ❌ | ✅ |
| 標記已電聯 / 備註 | ❌ | ✅ | ❌ | ✅ |
| 重發通知 | ❌ | ✅ | ❌ | ✅ |
| 編輯本店範本 | ❌ | ✅ | ❌ | ✅ |
| 編輯總部預設範本 | ❌ | ❌ | ❌ | ✅ |
| 看每月報表（本店）| ❌ | ✅ | ✅ | ✅ |
| 看每月報表（全店）| ❌ | ❌ | ✅ | ✅ |
| 手動觸發 job | ❌ | ❌ | ❌ | ✅ |

---

## 10. 整合點

- **訂單 / 取貨模組**（上游，待建）：觸發 `pickup_ready` / `pickup_overdue` / `store_new_order`
- **採購 / 收貨模組**（上游）：`goods_receipts.received_at` → 起算取貨期限
- **庫存模組**（上游）：`stock_lots.expiry_date` 臨近 → 觸發 `store_expiry_alert`
- **會員模組**（被讀）：解出顧客 `line_user_id`（`member_cards.line_user_id` 或 LIFF 綁定表）
- **LIFF 前端**（另案）：若未來開 opt-out 頁面會來呼叫本模組 API
- **LINE OA / Messaging API**（外部）：實際送達管道

---

## 11. 非功能需求

- [x] **延遲**：事件 → 排入 queue ≤ 10s；queue → 送達 95% ≤ 60s
- [x] **可用性**：LINE API 中斷時 queue 累積、不丟訊息、人為恢復後重試（P1）；v1 失敗即止
- [x] **冪等**：同一 `source_module + source_ref_id + type` 在 24h 內只能成功送出一次（避免重發）
- [x] **稽核**：`notification_logs` append-only；所有狀態轉換都有時間戳
- [x] **法遵**：範本需包含「取消訂閱」指引（說明封鎖 OA 即停止通知）
- [x] **監控**：失敗率 > 5% / 小時 → 告警總部

---

## 12. Open Questions

> 需使用者確認後才進 v0.2。

- [ ] **Q1 訊息語氣 / 情感風格**：友善 / 商務 / 俏皮？影響所有預設範本撰寫

- [ ] **Q2 顧客 `line_user_id` 綁定策略**：
  - A. 首次下單掃 LINE OA QR → 自動綁 `member_id`（需 LIFF）
  - B. 人工登打訂單時一併輸入（實務困難，店員看不到顧客 LINE ID）
  - C. 先靠手機號查會員、找不到就不發
  - → v1 採哪個？

- [ ] **Q3 無 `line_user_id` 的顧客怎麼辦**：
  - A. 系統跳過、直接列入失敗清單
  - B. Worker 每日重試一次（等顧客綁 LINE OA）
  - C. 通知店長改發簡訊（但 5-1 已決不做備援）
  - → 建議 A

- [ ] **Q4 `pickup_reminder` 的「到期前 1 天」掃描策略**：
  - A. 固定每日 09:00 掃一次，合格的全部發
  - B. 精準在 24h 前（到貨 04/21 15:00 → 提醒 04/25 15:00）
  - → A 簡單、B 使用者體驗好；建議 A

- [ ] **Q5 店長群組 `line_group_id` 管理**：
  - 一店一群 vs 一店多群？
  - 總部 LINE OA bot 加入群組取得 `group_id` 的 SOP 待定
  - 店長離職 → 群組帳號要交接 or 重綁

- [ ] **Q6 範本變數隱私**：
  - 顧客姓名 / 訂單編號 / 商品明細代入前要不要遮罩？
  - 群組通知若含顧客手機 → 隱私問題，建議強制遮罩

- [ ] **Q7 `store_new_order` 合流策略**：
  - 每筆訂單即時發 vs 每 N 分鐘彙整一條「新訂單 X 筆」？
  - pilot 一天 200 單可能刷屏 → 建議彙整或加節流

- [ ] **Q8 `store_expiry_alert` 合流策略**：
  - 每日 08:00 彙整一條（列全店臨期 SKU）vs 每個 lot 一則？
  - 建議前者

- [ ] **Q9 重發限制**：
  - 店長重發無上限？或最多 N 次？
  - 同一則冷卻時間（10 分鐘內不能重複重發）

- [ ] **Q10 跨時段延遲的精確行為**：
  - 晚 21:05 產生的顧客通知 → 延到隔天 09:00
  - 若隔天是假日且門市休 → 繼續延？還是發？
  - 延遲期間取貨期限如何計算（`received_at` 錨點不變？）

- [ ] **Q11 失敗清單保留期限**：
  - 店長沒處理的失敗列保留多久？建議 90 天後 archive（ledger 保留、UI 不再顯示）

- [ ] **Q12 LINE OA 月推播額度與成本**：
  - LINE OA 免費方案每月 500 則；超量需升級付費
  - 100 店 × 每店 300 單 / 月 × 平均 3 通知 ≈ 9 萬則 → 需升級方案成本預估
  - 建議：先取得 LINE OA 現況、評估月成本

---

## 13. 下一步
- [ ] 回答 Q1~Q12 → 進入 v0.2（展開 Edge Function、LINE API wrapper、排程 job 規劃）
- [ ] 確認「訂單 / 取貨模組」PRD 後補事件來源對齊（本模組消費）
- [ ] Spike：LINE Messaging API 發送節流（100 則 / 分鐘）
- [ ] Spike：`line_user_id` 綁定流程（含 LIFF 首綁）
- [ ] LINE OA 月推播量估算 + 方案選擇

---

## 相關連結
- [[PRD-會員模組]] — `line_user_id` 來源
- [[PRD-訂單取貨模組]] — 主要事件來源（待建）
- [[PRD-庫存模組]] — `stock_lots` 臨期事件來源
- [[PRD-採購模組]] — `goods_receipts` 收貨事件來源
- [[專案總覽]]

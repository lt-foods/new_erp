---
title: PRD - 會員模組
module: Member
status: draft-v0.1
owner: www161616
created: 2026-04-20
updated: 2026-04-23
tags: [PRD, ERP, 會員, Member, Points, Wallet, QRCode, c混合型]
---

# PRD — 會員模組（Member Module）

> 零售連鎖 ERP，總倉 1 + 門市 100 + SKU 15,000。
> 本模組負責「會員是誰、有什麼等級、累積多少點 / 儲值金、怎麼被識別」。
> v0.1 checklist 版。
> **決策基準**：[[decisions/2026-04-23-系統立場-混合型]] C 混合型 — 本模組 §0 加盟店模式 review（per-store 會員池 / `member_line_bindings` 多對多）即此立場。

---

## 0. 🚨 加盟店模式 Review（2026-04-21）

本 PRD 原設計基於「單一 tenant」會員池假設。經加盟店模式 review 後必須調整：

- **會員分店獨立**：`members` 加 `store_id NOT NULL`；UNIQUE 範圍從 `(tenant, phone_hash)` 改 `(tenant, store, phone_hash)`。同一支手機在 A / B 店各自辦會員 = 兩筆獨立紀錄。
- **點數 / 儲值金分店**：`points_ledger.member_id` 天然繼承 store scope、不跨店累積。
- **line_user_id 移出 members**：改為新表 `member_line_bindings (member_id, store_id, line_user_id)`（LINE OA 機制同會員不同店不同 user_id）。
- **GDPR 刪除**：僅影響該店 member 記錄、不動他店同手機會員。
- **Q1 手機識別**：在 store 範圍內唯一。
- **Q2 手機重辦阻擋**：從 tenant 降為 **store 內阻擋**（跨店可重辦）。
- **Q16 跨 tenant**：不跨（原本決定）；進一步**連 tenant 內跨 store 也不共享**。

**對應 schema issue**：[#83](https://github.com/www161616/new_erp/issues/83)（新增）

---

## 1. 模組定位
- [ ] 會員主檔 **Single Source of Truth**；銷售 / 促銷 / 行銷只讀
- [ ] 提供三類識別管道：**手機號** / **實體會員卡（條碼）** / **虛擬會員卡（LIFF 動態 QR code）**
- [ ] 前端載體採 **LINE 官方帳號 + LIFF**（LINE Front-end Framework）— 取代原生 APP：會員掃 OA QR 加入 → LIFF 網頁顯示動態會員 QR、查訂單、查點數、收取貨通知推播
- [ ] 點數（Points）與儲值金（Wallet）採 **append-only ledger** 架構（同庫存 `stock_movements` 思路）：每筆異動是不可變流水、餘額為物化視圖
- [ ] 其他模組（銷售、促銷）**不得**直接 UPDATE 會員 / 點數 / 儲值金表，必須透過本模組 RPC

---

## 2. 核心概念 / 名詞定義
- [ ] **會員（Member）**：`tenant_id + member_no`，一個人一筆資料
- [ ] **會員等級（Tier）**：銅 / 銀 / 金 / 鑽（可自訂），影響會員價與回饋率
- [ ] **會員卡（Member Card）**：實體卡或虛擬卡（APP QR）；一會員可多卡，有啟用 / 退役狀態
- [ ] **QR payload**：`{type:"member", tenant, card_id, nonce, sig}`，server 簽章防偽、可設定 TTL
- [ ] **點數（Points）**：累積 / 消費 / 調整的流水（`points_ledger`）＋ 餘額（`member_points_balance`）
- [ ] **儲值金（Wallet）**：預付金流水（`wallet_ledger`）＋ 餘額（`wallet_balances`）；不可退現（v1）
- [ ] **歸屬門市（Home Store）**：會員主要消費門市，行銷 / 業績歸屬
- [ ] **會員標籤（Tag）**：行銷分群用（如「常客」「沉睡」），可人工 / 規則自動打標

---

## 3. Goals
- [ ] G1 — 會員掃 QR 到 POS 顯示「會員 + 等級 + 點數 + 儲值金」≤ 500ms（含驗簽）
- [ ] G2 — 會員點數結帳後 1 秒內更新餘額，異動可追溯來源銷售單
- [ ] G3 — 儲值金扣款高併發安全（同一會員多店同時結帳不超扣）
- [ ] G4 — 生日當月名單 / 沉睡會員名單 可一指令查出並匯出
- [ ] G5 — 會員資料支援 GDPR / 個資法「查詢 / 更正 / 刪除」請求

---

## 4. Non-Goals（v1 不做）
- [ ] ⏸ **原生 APP 開發（iOS / Android）** — **v1 不做、P2+ 規劃**（2026-04-21 更新）。v1 採 LINE OA + LIFF；未來 APP 同時支援推播 + 顧客下單功能（與 LINE 社群下單並存）
- [ ] ❌ **外部點數平台整合**（悠遊付、LINE Points）— P1
- [ ] ❌ **多層級推薦 / 直銷** — 非 ERP 範疇
- [ ] ❌ **複雜行銷自動化（EDM / 排程引擎）** — 僅提供名單 API，外部工具處理；**但取貨通知 / 基本交易推播由「通知模組」負責**（新增模組，見整合點）
- [ ] ❌ **家庭群組 / 公司戶會員** — P1
- [ ] ❌ **點數 ↔ 儲值金互換** — P1
- [ ] ❌ **信用卡 / 金流串接** — 由銷售 / 金流模組處理

---

## 5. User Stories

### 店員（POS 熱路徑）
- [ ] 作為店員，我要能**掃會員 QR** 帶入結帳畫面，立即顯示等級 + 點數 + 儲值金
- [ ] 作為店員，我要能輸入**手機號**查會員（掃不到時的備援）
- [ ] 作為店員，我要能**用儲值金結帳**（扣儲值金）
- [ ] 作為店員，我要能**用點數折抵**（1 點 = 1 元，可設定）
- [ ] 作為店員，我要能**當場申辦新會員**（手機 + 姓氏 + 生日 即可，其他可後補）

### 會員 / 顧客
- [ ] 作為會員，我要能在 LINE 內（LIFF 網頁）看到我的會員卡 QR（每 30 秒刷新避免截圖盜用）
- [ ] 作為會員，我要能在 LINE 收到取貨通知（訂單到貨 / 可取貨期限 / 超時提醒）
- [ ] 作為會員，我要能查詢點數 / 儲值金流水與餘額
- [ ] 作為會員，我要能**在門市加值儲值金**（現金、信用卡；串接由銷售模組處理）

### 店長
- [ ] 作為店長，我要看到本店會員數、活躍度、平均客單
- [ ] 作為店長，我要能**人工調整點數 / 儲值金**（退貨、客訴補償）；必填事由、留稽核

### 行銷 / 總部
- [ ] 作為行銷，我要能建立 **會員分群**（規則：近 90 天消費 > X、生日月、等級）
- [ ] 作為行銷，我要能匯出分群名單（給 EDM / SMS 工具用）
- [ ] 作為行銷，我要能設定 **等級升降級規則**（消費滿 X 升等、一年未消費降等）

### 總部老闆
- [ ] 作為總部老闆，我要看到集團整體會員 LTV / 客單 / 回購率儀表板

---

## 6. Functional Requirements

### 6.1 會員主檔
- [ ] 欄位：`member_no, phone(unique), email, name, birthday, gender, home_store_id, tier_id, status, joined_at, notes`
- [ ] **手機號** 在 tenant 內唯一（去重 + 合併機制見 Open Questions）
- [ ] `member_no` 自動產生（規則可設定，預設 `M` + yyMMdd + 4 碼流水）
- [ ] 狀態：`active / inactive / blocked / deleted(soft)`
- [ ] 個資欄位 **column-level encryption**（`phone` / `email` / `birthday`）或至少 RLS 嚴格（看 Q）

### 6.2 會員等級
- [ ] `member_tiers`：`code, name, sort_order, benefits(JSONB)`
- [ ] benefits 範例：`{points_multiplier: 1.5, member_price_eligible: true}`
- [ ] 會員等級對應 `prices.scope = member_tier, scope_id = tier_id`，查會員價走商品模組既有 `rpc_current_price`
- [ ] 升降級：規則引擎（排程 job，每日掃描）或手動

### 6.3 會員卡（含 QR code）
- [ ] `member_cards`：`card_no(unique), member_id, type(physical|virtual), status(active|retired|lost), issued_at, expires_at`
- [ ] 實體卡：`card_no` 印在卡上（EAN-13 或 CODE-128）
- [ ] 虛擬卡（LIFF 動態 QR）：**動態 QR** — `payload = {type:"member", tenant, card_id, nonce, exp_ts, sig:HMAC}`
  - [ ] `sig = HMAC_SHA256(secret, f"{tenant}|{card_id}|{nonce}|{exp_ts}")`
  - [ ] TTL 60 秒，LIFF 網頁前端定期刷新（Q3 決定）
  - [ ] 盜刷防護：驗簽 + 時效檢查 + nonce 可入短期黑名單
- [ ] 一會員可多卡；退役卡仍可識別但提示「已退役」
- [ ] 拾獲 / 遺失：`status = lost`，掃到提示

### 6.4 識別 API（熱路徑）
- [ ] `POST /members/resolve` — body 支援三種來源：
  - [ ] `{qr: "<payload>"}`
  - [ ] `{card_no: "..."}`
  - [ ] `{phone: "..."}`
- [ ] 回傳：`member_id, member_no, name(masked), tier_id, tier_name, points_balance, wallet_balance, status`
- [ ] 姓名 masked（王** / 陳*明）—— POS 顯示用；完整資訊需權限
- [ ] 目標 P95 < 300ms（含 QR 驗簽）

### 6.5 點數（Points）
- [ ] **流水表**：`points_ledger (id, tenant_id, member_id, change, balance_after, source_type, source_id, reason, operator_id, created_at)`
- [ ] **餘額表**：`member_points_balance (tenant_id, member_id, balance, version, last_movement_at)`
- [ ] **賺取**：
  - [ ] 銷售消費：`change = floor(amount * tier.points_multiplier * base_rate)`
  - [ ] 活動贈點：由行銷發起
- [ ] **消費**：
  - [ ] 結帳折抵：`rpc_spend_points(...)`，1 點 = 1 元（可設定匯率）
  - [ ] 檢查餘額 → 不足阻擋（或允許 0，不允許負）
- [ ] **調整**：客訴 / 補償 → 必填事由、限權限角色
- [ ] **退貨**：原銷售若賺過點 → 反向扣回（用 `reverses` 鏈）
- [ ] **過期**（v0.1 預設不過期 → Open Question）：若要過期，排程 job 每日掃分批打出 `expire` 類型流水

### 6.6 儲值金（Wallet）
- [ ] **流水表**：`wallet_ledger (id, tenant_id, member_id, change, balance_after, type(topup|spend|refund|adjust), source_type, source_id, payment_method, reason, operator_id, created_at)`
- [ ] **餘額表**：`wallet_balances (tenant_id, member_id, balance, version, last_movement_at)`
- [ ] **加值（Top-up）**：
  - [ ] 管道：現金、信用卡、行動支付（金流串接由銷售模組）
  - [ ] 成功 → 寫 `topup` 流水、餘額 +
  - [ ] **加值回饋**（選用，v1 先關）：加 1000 送 50，可設定
- [ ] **消費**：
  - [ ] POS 結帳呼叫 `rpc_wallet_spend(...)`，含 `SELECT FOR UPDATE` 防超扣
- [ ] **退款**：退貨若以儲值金付 → 退回儲值金（`type=refund`）
- [ ] **不可退現**（v1）：要退現金需財務走例外流程（手動開支票 + 記 `adjust` 沖正）
- [ ] **到期**（v0.1 預設永久有效 → Open Question）

### 6.7 會員分群 / 標籤
- [ ] `member_tags`：`(member_id, tag_code, source(manual|rule), created_by, created_at)`
- [ ] 系統內建規則（排程 job 每日更新）：
  - [ ] `vip`：近 365 天消費 > X
  - [ ] `dormant`：近 180 天未消費
  - [ ] `new`：加入 30 天內
  - [ ] `birthday_month`：生日當月
- [ ] 自訂規則（v0.1 簡易版 → P1 完整規則引擎）

### 6.8 名單匯出
- [ ] `GET /members/export?tags=...&status=...&joined_from=...`
- [ ] 輸出 CSV：`member_no, phone, email, name, tier, points_balance, wallet_balance, last_visit_at`
- [ ] 個資遮罩選項（匯出給外部工具時）

### 6.9 個資合規（GDPR / 個資法）
- [ ] 會員可申請 **查詢自身資料**：`GET /members/{id}/gdpr-export`
- [ ] 會員可申請 **更正**（手機 / Email）
- [ ] 會員可申請 **刪除**：
  - [ ] 主檔 `status = deleted`、PII 欄位清空 → `[DELETED_<hash>]`
  - [ ] 歷史流水（銷售、點數、儲值金）**不刪**，FK 仍成立
- [ ] 所有個資讀寫留稽核

### 6.10 會員合併
- [ ] 場景：同一人有兩個手機號建了兩筆 → 合併
- [ ] 操作：選「主」「被合併」→ 點數 / 儲值金 / 標籤 / 卡片 遷移至主
- [ ] 被合併方 `status = merged`，記 `merged_into_member_id`
- [ ] 限權限角色、必填事由

### 6.11 離線容錯（POS）
- [ ] POS 斷網時：
  - [ ] 可掃 QR → 本地驗簽（簽章 secret 需同步到端末，注意安全）
  - [ ] 可做消費扣點 / 扣儲值金 → 存本地 pending 佇列
  - [ ] 網路恢復 → 依序上拋寫入 ledger
  - [ ] **風險**：離線期間同一會員多店消費可能總和超過餘額 → 需規則（如限額）

---

## 7. 非功能需求（NFR）
- [ ] **資料一致性**：點數 / 儲值金流水 append-only，trigger 維護餘額
- [ ] **併發**：`rpc_spend_points` / `rpc_wallet_spend` 走 `SELECT FOR UPDATE` 鎖 balance 列
- [ ] **效能**：
  - [ ] 會員識別（QR / card / phone）P95 < 300ms
  - [ ] 餘額查詢 P95 < 100ms
  - [ ] 集團會員總數 ~50 萬筆情境下分頁查詢 < 1s
- [ ] **稽核**：主檔變更 / 點數調整 / 儲值金加扣 / 合併 / 刪除 皆留紀錄
- [ ] **多租戶**：所有表帶 `tenant_id`；RLS 限制只能看本 tenant 會員
- [ ] **權限**：店員只看本店會員（view），總部看全集團
- [ ] **個資**：PII 欄位 at-rest 加密（pgcrypto 或 KMS）；顯示層 masked
- [ ] **安全**：QR HMAC secret 定期輪替；簽章失敗計數告警

---

## 8. 權限（RBAC 對應本模組）

| 權限 | 總部老闆 | 行銷 | 店長 | 店員 |
|---|:-:|:-:|:-:|:-:|
| 查全集團會員 | ✅ | ✅ | ❌ | ❌ |
| 查本店會員 | ✅ | ✅ | ✅ | ✅（masked）|
| 新增會員 | ✅ | ✅ | ✅ | ✅ |
| 編輯會員資料 | ✅ | ✅ | ✅（本店）| ❌ |
| 人工調整點數 | ✅ | ✅ | ✅（上限）| ❌ |
| 人工調整儲值金 | ✅ | ❌ | ✅（上限 + 審核）| ❌ |
| 查詢點數 / 儲值金餘額 | ✅ | ✅ | ✅ | ✅ |
| 結帳扣點 / 扣儲值金 | ✅ | ❌ | ✅ | ✅ |
| 儲值金加值 | ✅ | ❌ | ✅ | ✅ |
| 會員合併 | ✅ | ✅ | ❌ | ❌ |
| 刪除會員（GDPR）| ✅ | ✅ | ❌ | ❌ |
| 建 / 改會員等級 | ✅ | ✅ | ❌ | ❌ |
| 匯出名單 | ✅ | ✅ | ❌ | ❌ |

- [ ] 店長調整點數 / 儲值金**每日上限**可設定（預設 500 點 / 1000 元）
- [ ] 超過上限走「待總部審核」佇列

---

## 9. 資料模型草稿（待 Review）

- [ ] `member_tiers` — 等級主檔
- [ ] `members` — 會員主檔（PII 加密 / masked 欄位）
- [ ] `member_cards` — 會員卡（實體 / 虛擬，含 QR secret 關聯）
- [ ] `points_ledger` — 點數流水（append-only）
- [ ] `member_points_balance` — 點數餘額（物化）
- [ ] `wallet_ledger` — 儲值金流水（append-only）
- [ ] `wallet_balances` — 儲值金餘額（物化）
- [ ] `member_tags` — 標籤
- [ ] `member_audit_log` — 稽核
- [ ] `member_merges` — 合併歷史

---

## 10. 與其他模組的整合點

- [ ] **商品模組**：
  - [ ] `member_tiers.id` → `prices.scope_id` where `scope = member_tier`
  - [ ] 會員價查詢走商品模組既有 `rpc_current_price(p_member_tier => tier_id)`
- [ ] **銷售 / POS 模組**：
  - [ ] 結帳前呼叫 `rpc_resolve_member(...)`
  - [ ] 結帳後呼叫 `rpc_earn_points(sale_id, amount, ...)`
  - [ ] 點數折抵 `rpc_spend_points(...)`
  - [ ] 儲值金扣款 `rpc_wallet_spend(...)`
  - [ ] 儲值金加值 `rpc_wallet_topup(...)`
- [ ] **促銷模組**（屬商品）：
  - [ ] 會員等級門檻（「金卡限定」）讀 `members.tier_id`
- [ ] **報表模組**：
  - [ ] 會員 LTV / 回購 / 活躍 — 讀 `members` + 銷售模組訂單
- [ ] **通知模組**（新增）：
  - [ ] 會員模組發出「會員事件」（新註冊、等級升降、點數到期提醒、生日祝賀）
  - [ ] 銷售 / 訂單模組發出「訂單事件」（到貨可取、取貨期限、超時）
  - [ ] 通知模組統一處理 LINE / SMS / Email 推送
- [ ] **LIFF 前端**（另案）：
  - [ ] 消費本模組 API：`rpc_resolve_member` / 餘額查詢 / 流水查詢
  - [ ] 動態 QR 顯示（每 60s 刷新，Q3 決定）
  - [ ] 新會員註冊 OAuth 流程（LINE user_id 綁定 `members.line_user_id`，v0.2 新增欄位）
- [ ] **外部（v1 不做）**：悠遊付、LINE Points 等第三方點數平台

---

## 11. 驗收準則（Acceptance Criteria）
- [ ] 新會員申辦（手機 + 姓氏）→ 30 秒內產生 `member_no` + 可立即掃 QR 結帳
- [ ] 掃會員 QR → POS 顯示 masked 姓名 + 等級 + 餘額，全程 < 500ms
- [ ] 同一會員在兩店同時結帳（只剩 100 元儲值金，各扣 80）→ 一筆成功一筆回「餘額不足」
- [ ] 銷售 1000 元 + 金卡倍率 1.5 → 自動入點 1500
- [ ] 該筆銷售退貨 → 自動反向扣點 1500（`reverses` 鏈成立）
- [ ] 會員生日當月自動帶 `birthday_month` 標籤、次月自動移除
- [ ] 合併兩筆會員（A → B）：A 的點數 / 儲值金 / 標籤 / 卡片 全搬到 B、A `status = merged`
- [ ] GDPR 刪除：`status = deleted`、PII 清空 → `[DELETED_xxx]`；歷史單據仍可查但會員資訊顯示「已註銷」
- [ ] 盜刷測試：用過期 QR payload（TTL 超時）→ 401
- [ ] 盜刷測試：竄改 payload 再送 → 簽章驗證失敗 401
- [ ] 店員查詢他店會員 → 403 或只回 masked 最小資訊（依 Q）

---

## 12. Open Questions（請回答以推進 v0.2）

### 會員識別
- [x] **Q1 主要識別方式**：→ **手機號 + LIFF 動態 QR 雙主**（原生 APP 改採 **LINE 官方帳號 + LIFF**）。實體會員卡僅作為 fallback。（2026-04-20）

  **影響**：
  - POS UI 預設兩個主按鈕：「掃 QR」「輸入手機」；實體卡入口折疊在次選單
  - **前端載體定為 LINE OA + LIFF**（非原生 APP）：顧客加 LINE 官方帳號 → 在 LIFF 網頁看 QR、查訂單、收推播
  - LIFF 前端另案開發（消費本模組 API），但本模組需提供 QR 簽章 API、LINE user_id 綁定欄位（`members.line_user_id`，v0.2 新增）
  - **催生新模組：通知模組**（統一處理 LINE / SMS / Email 推送）— 取貨通知、訂單通知、會員事件推送
  - 新會員申辦：預設走「手機號 + 姓氏 + 生日」最小資料；若從 LINE OA 進入，同時綁 `line_user_id`
  - 資源投入：`member_cards.type = virtual` 多數、`physical` 少數例外
- [x] **Q2 手機號去重**：→ **阻擋**。同手機號重複申辦時，系統回應「此手機已註冊」並顯示原會員資料供店員直接調出；不自動合併、不建重複筆。（DB 已用 `UNIQUE (tenant_id, phone_hash)` 強制執行）（2026-04-20）
- [x] **Q3 QR TTL**：→ **60 秒**。團購店實體面對面結帳場景盜用風險低，60s 兼顧網路不穩時的可用性與安全性。（原 PRD 預設 30s 上調至 60s）（2026-04-20）

### 點數 / 儲值金
- [x] **Q4 點數過期**：→ **次年底過期**。2026 年賺的點，2027/12/31 23:59:59 全部到期；每年底排程 job 產出 `expire` 流水。（2026-04-20）

  **實作要點**：
  - `points_ledger.expires_at` 新增欄位（v0.2 schema 調整）：每筆 `change > 0` 寫入時 `= date_trunc('year', created_at) + interval '1 year 1 day' - interval '1 second'`
  - **扣點 FIFO**：扣點時優先消耗最早到期的 earn entries（避免新賺的先被扣、舊的先到期）。v0.1 用簡化模型（年度彙總）、v0.2 評估是否升級為「points_lots」完整 FIFO
  - **年度到期 job**：每年 12/31 23:00 跑 — 對每會員計算「本年度之前未扣完的點 + 前年度未到期結餘」產出 `expire` 流水沖至 0
  - **提醒推播**（透過通知模組）：12/1 發「您有 X 點將在月底到期」提醒顧客使用
  - UI：會員在 LIFF 查點數時顯示「明細 / 即將到期」區塊
- [x] **Q5 點數回饋率 + 等級倍率**：→ **預設值如下（之後可調）**。（2026-04-20）

  **基準回饋率**：1%（每 100 元 1 點），存 `tenant_settings.points_base_rate` 或 config

  **4 個等級**：
  | 等級 | code | points_multiplier | discount_rate | 升等門檻（年累計消費）|
  |---|---|---|---|---|
  | 銅 | bronze   | 1.0 | 1.00 | 新會員即是 |
  | 銀 | silver   | 1.2 | 0.98 | 5,000 |
  | 金 | gold     | 1.5 | 0.95 | 20,000 |
  | 鑽 | diamond  | 2.0 | 0.90 | 50,000 |

  **計算規則**：`points = floor(amount × base_rate × multiplier)`（無條件捨去）
  - 例：金卡消費 150 元 = floor(150 × 0.01 × 1.5) = 2 點

  **存法**：`member_tiers.benefits` JSONB 範例 `{"points_multiplier": 1.5, "discount_rate": 0.95, "upgrade_threshold": 20000, "member_price_eligible": true}`

  **調整方式**：只改 `member_tiers.benefits` 與 config，不用動 schema 或程式碼
- [x] **Q6 點數 1 元對價**：→ **1 點 = 1 元（暫定）**；**v1 單筆無上限**（可抵到 0 元）。（2026-04-20）

  存 `tenant_settings.points_redeem_rate = 1.0`，之後可調。

  **P1 再議**：若發現客人大量累積後一次用光影響現金流，再加「單筆最多抵 50%」或「單日最高 X 點」限制。屆時加 `tenant_settings.points_redeem_limit_*` 設定，不需改 schema。
- [x] **Q7 儲值金退現**：→ **完全禁止**。加值後只能消費、不能退現；若遇特殊情況（客訴、歇業等）需退，由財務走**人工例外流程**（手動記 `adjust` 沖正沖帳，必填事由、留稽核）。（2026-04-20）

  **UI 提示**：加值頁面明確顯示「加值金僅可消費、不退現」同意條款（符合消保法預付型商品揭露要求）。
- [x] **Q8 儲值金加值回饋**：→ **v1 不做**（加值即 1:1 無回饋）。P1 再開，屆時新增 `topup_bonus_rules` 表並擴充 `rpc_wallet_topup` 計算。（2026-04-20）

### 等級與規則
- [x] **Q9 等級數量與門檻**：→ **依 Q5 預設走**：4 級（銅/銀/金/鑽），門檻 0 / 5,000 / 20,000 / 50,000。（2026-04-20）
- [x] **Q10 升降級判定**：→ **滾動 12 個月 + 一次降一級**。（2026-04-20）

  **規則**：
  - **判定期間**：往前看滾動 12 個月的已付款消費總額（退貨金額扣除）
  - **升等**：消費額跨過上一級門檻 → 立即升等
  - **降等**：消費額跌破本級門檻 → 一次只降一級（例：金卡掉下去變銀卡，不會直接降到銅卡）；給 **30 天緩衝期**，期間仍享本級權益，期滿前若補消費越過門檻則取消降等
  - **排程 job**：每日凌晨掃描所有會員、更新 `tier_id`；升降級寫 `member_audit_log` + 觸發通知模組推播
  - **欄位支援**：`members` 已有 `tier_id`；需新增 `tier_review_at`（下次判定時間）或 `downgrade_pending_at`（緩衝期結束日期）— v0.2 schema 調整

### 個資與合規
- [x] **Q11 PII 加密強度**：→ **v1：欄位層 pgcrypto + 環境變數 key；P1：改 Supabase Vault**。（2026-04-20）

  **v1 實作**：
  - `phone_enc` / `email_enc` / `birthday_enc` 用 `pgp_sym_encrypt(plain, key)`
  - key 存環境變數 `MEMBER_PII_ENCRYPTION_KEY`（`.env` / Supabase secret）
  - 查詢靠 hash 欄位（`phone_hash = sha256(normalized)`），加密欄位只在需要時解密

  **P1 升級**：改用 Supabase Vault（內建 KMS） — 支援 key rotation、稽核、存取控制
- [x] **Q12 姓名顯示策略**：→ **依角色**。（2026-04-20）

  | 角色 | 姓名顯示 | 手機顯示 | Email 顯示 |
  |---|---|---|---|
  | 店員（clerk） | masked（王**） | 末 3 碼 | 隱藏 |
  | 店長（store_manager） | masked（王**） | 完整 | masked（a***@xx.com） |
  | 主檔管理 | 完整 | 完整 | 完整 |
  | 行銷（marketer） | 完整 | 完整 | 完整 |
  | 總部老闆（owner） | 完整 | 完整 | 完整 |

  POS 走 `rpc_resolve_member` 時 server 端依 JWT role 決定回傳遮罩程度，不讓前端自行決定。
- [x] **Q13 刪除 vs 封存**：→ **軟刪除 + PII 清空、歷史流水保留**。（2026-04-20）

  **實作 RPC**：`rpc_member_gdpr_delete(p_member_id, p_reason, p_operator)`

  ```
  members:
    name          = NULL
    phone_enc     = NULL
    phone_hash    = 'DELETED_' || id    -- 保 unique，釋放原手機號可被新人重辦
    email_enc     = NULL, email_hash = NULL
    birthday_enc  = NULL, birth_md = NULL
    status        = 'deleted'
    notes         = '[GDPR deleted at {date} by {operator}]'

  member_cards:  all → status = 'retired'
  member_tags:   all → deleted

  points_ledger / wallet_ledger / sales: 不動（稅務留存）

  member_audit_log: 記一筆 action = 'gdpr_delete'
  ```

  **權限**：僅總部老闆 / 行銷可操作；UI 需二次確認（不可逆）
  **法規覆蓋**：台灣個資法「請求刪除權」✅、稅捐稽徵法 7 年留存 ✅、GDPR §17 法律義務例外 ✅
- [x] **Q14 法遵留存**：→ **至少 7 年**。配合稅捐稽徵法 21 條（帳簿憑證保存 7 年）。會員主檔 + 銷售 + 點數 / 儲值金流水，7 年內不可物理刪；Q13 的 GDPR 刪除僅清 PII，歷史流水繼續保留。（2026-04-20）

### POS 整合
- [x] **Q15 離線模式**：→ **只讀不寫**。（2026-04-20）

  | 功能 | 離線行為 |
  |---|---|
  | 掃 QR / 查會員 | ✅ 讀本地快取 |
  | 查點數 / 儲值金餘額 | ✅ 讀本地快取（僅供參考，實際扣款需連線）|
  | 扣點 / 扣儲值金 | ❌ 禁止；UI 提示「網路斷線、請改用現金 / 信用卡」|
  | 銷售賺點 | ⚠️ 銷售允許離線，點數等網路恢復再補結算 |
  | 儲值金加值 | ❌ 禁止（金流本就需連線）|

  **理由**：同一會員多店同時離線消費 → 本地各自通過驗證、上拋時第二筆失敗 → 已收貨難追回。寧可斷網時顧客改用現金，也不冒超扣風險。
- [x] **Q16 跨 tenant 會員共通**：→ **v1 不跨**。（2026-04-20）

  **定義釐清**：
  - **Tenant（租戶）** = 獨立公司 / 帳號體系
  - **Store / Location（門市）** = 同 tenant 內的分店或取貨點
  - 你的 100 個門市皆屬同一 tenant，**會員天然共通**（v1 已支援）

  **未來加盟情境**（P1+）：若開放不同加盟主（= 不同 tenant），會員是否跨 tenant 共用？需業務模式定型後再設計（涉及分潤 / 對帳 / GDPR 跨域），本 v1 明確不做。

---

## 13. 下一步
- [ ] 回答 Q1~Q16 → 進入 v0.2（展開 API、驗簽細節、升降級規則引擎）
- [ ] Spike：QR HMAC 產生 / 驗證流程 + APP 端動態刷新
- [ ] Spike：併發扣儲值金（100 QPS 同一會員）— 驗證 row-level lock 正確性
- [ ] Spike：離線 POS 上拋順序（兩店離線同時消費）的處理策略
- [ ] 先做資料模型 POC：members + cards + ledger + balance 四表的 RPC

---

## 相關連結
- [[PRD-商品模組]] — 會員價透過 `prices.scope = member_tier`
- [[PRD-銷售模組]] — POS 結帳主要消費者
- [[PRD-庫存模組]] — ledger 模式設計參考對象
- [[專案總覽]]
- 舊系統參考：`lt-erp/MemberList.html`, `MemberCard.html`, `Points.html`

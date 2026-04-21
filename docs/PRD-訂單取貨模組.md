---
title: PRD - 訂單 / 取貨模組
module: Order
status: draft-v0.1
owner: alex.chen
created: 2026-04-21
tags: [PRD, ERP, 訂單, 取貨, Order, Pickup, LINE社群, LIFF]
---

# PRD — 訂單 / 取貨模組（Order / Pickup Module）

> **團購店業務核心模組**。從「總倉發布商品」→「顧客 LINE 社群下單」→「結單採購」→「到貨配送」→「推播取貨」→「門市結算」完整流程的中樞。
>
> 零售連鎖 ERP，總倉 1 + 門市 100 + SKU 15,000、20 個 LINE 社群頻道。
> 本文件為 **v0.1 checklist 版**。

---

## 1. 模組定位
- [ ] 是**團購流程的樞紐**：連結商品（本次團購清單）、會員（顧客身份）、庫存（reserve）、採購（結單需求）、銷售（取貨結算）、通知（推播）
- [ ] 處理「顧客下訂 → 取貨」的完整生命週期
- [ ] 顧客下訂**來源：LINE 社群（OpenChat）** — 無 API，靠人工 / 截圖 LLM 解析
- [ ] **不處理**的事：
  - LINE 社群自動發文（無 API、只能半自動：系統範本 + 複製貼上）
  - 金流 / 發票（銷售模組 / 通知模組各自負責）
  - 採購 PO 開立本身（採購模組負責、本模組僅產生需求數字）

---

## 2. 核心業務流程

```
┌───────────────────────────────────────────────────────┐
│ Phase A: 發布團購                                      │
├───────────────────────────────────────────────────────┤
│ 1. 總倉小幫手建立 group_buy_campaign（團購活動）        │
│    - 選定本次商品清單（多 SKU + 售價 + 收單上限）       │
│    - 設結單日、預計到貨日、取貨期限                    │
│    - 選要發布的 LINE 頻道（20 個 subset）              │
│ 2. 系統產生 post 文案（依 post_template + 變數代入）   │
│ 3. 小幫手「複製」→ 手動貼到各 LINE 頻道記事本           │
│                                                        │
├───────────────────────────────────────────────────────┤
│ Phase B: 顧客下單（LINE 社群端）                       │
├───────────────────────────────────────────────────────┤
│ 4. 顧客在自己門市頻道留言 `+N`（可多品、改單、取消）    │
│    - 「+3」= 主商品 3 份                               │
│    - 「+3 另 A 品 2 個」= 多品                         │
│    - 「取消 +2」/「改成 +5」                           │
│                                                        │
├───────────────────────────────────────────────────────┤
│ Phase C: 訂單登打                                      │
├───────────────────────────────────────────────────────┤
│ 5. 小幫手進系統「訂單登打」介面                         │
│    - v1: 看 LINE 手動逐筆 key                          │
│    - P1: 上傳截圖 → Claude Haiku vision → 草稿表格     │
│    - P2: OCR + 規則（法規敏感時備援）                  │
│ 6. 登打時綁定社群暱稱 ↔ 會員（首次手動、之後 auto）    │
│ 7. 每筆顧客訂單：建 customer_orders + items             │
│    - 每 item 呼叫 rpc_reserve 鎖庫存（預購期可 negative）│
│                                                        │
├───────────────────────────────────────────────────────┤
│ Phase D: 結單 + 採購                                   │
├───────────────────────────────────────────────────────┤
│ 8. 結單（到期 OR 達 campaign_cap）→ campaign status 轉  │
│ 9. 系統彙總：each SKU 各門市總需求                     │
│ 10. 推向採購模組建 PR / PO                             │
│                                                        │
├───────────────────────────────────────────────────────┤
│ Phase E: 到貨 + 配送                                   │
├───────────────────────────────────────────────────────┤
│ 11. 供應商到貨總倉 → GR 入庫（採購模組）               │
│ 12. 總倉依各門市需求建 transfer 配送（庫存模組）       │
│ 13. 門市收到貨 → receive → in_transit → on_hand        │
│                                                        │
├───────────────────────────────────────────────────────┤
│ Phase F: 通知 + 取貨                                   │
├───────────────────────────────────────────────────────┤
│ 14. 本模組觸發「到貨通知」事件                          │
│ 15. 通知模組推播顧客 LINE OA（非社群、需雙加）         │
│ 16. 顧客到門市取貨                                      │
│ 17. POS 掃 QR / 輸手機 → 調出訂單 → 確認取貨           │
│ 18. POS 結帳 → rpc_outbound 扣庫存 + rpc_release reserve│
│ 19. order status → completed                            │
│                                                        │
└───────────────────────────────────────────────────────┘
```

---

## 3. 名詞定義

- [ ] **團購活動（Campaign）**：一次團購商品發布 = 一個 `group_buy_campaigns` 記錄，涵蓋商品清單 + 期間 + 頻道
- [ ] **團購商品（Campaign Item）**：活動內某一品項（SKU + 此次售價 + 收單上限）
- [ ] **收單上限（Campaign Cap）**：單品 / 整團的訂購總量上限；到上限自動關團或該品項轉為「候補」
- [ ] **LINE 頻道（Channel）**：一個 LINE 社群（OpenChat），對應一個 home_location 門市或多門市共用
- [ ] **社群暱稱（Nickname）**：顧客在 LINE 社群中的顯示名，**非唯一**可改
- [ ] **身份對應（Alias）**：`nickname ↔ member_id` 的人工綁定紀錄，之後自動帶入
- [ ] **顧客訂單（Customer Order）**：一位顧客一次下訂 = 一筆 `customer_orders`，可含多品項
- [ ] **結單（Campaign Close）**：停止收單，觸發後續採購 / 配送流程
- [ ] **取貨（Pickup）**：顧客到門市領取已到貨商品，觸發 POS 結算

---

## 4. Goals
- [ ] G1 — 小幫手登打速度：v1 每筆 < 30 秒、P1 Claude vision 輔助下 < 5 秒
- [ ] G2 — 結單 → 採購 PR 自動產生 < 3 分鐘
- [ ] G3 — 到貨 → 推播通知 < 10 分鐘
- [ ] G4 — 取貨流程：顧客到門市 → 確認取貨 < 60 秒
- [ ] G5 — 訂單追溯：每筆可找到 LINE 截圖 / LLM 解析原文（2 年保留）
- [ ] G6 — 誤訂率 < 1%（v1 人工登打）、< 3%（P1 LLM 解析）
- [ ] G7 — 取貨率 ≥ 95%（未取貨 → 逾期處理）

---

## 5. Non-Goals（v1 不做）
- [ ] ❌ **LINE 社群自動發文**（API 不支援、半自動複製貼上）
- [ ] ❌ **LINE 社群自動讀訊息**（API 不支援）
- [ ] ❌ **金流串接**（v1 取貨時現金結清，銷售模組 POS 處理）
- [ ] ❌ **宅配 / 物流**（P1，v1 只做「到店取貨」）
- [ ] ❌ **顧客自助下單頁**（v1 純靠 LINE 社群 +N；P1 可考慮 LIFF 下單）
- [ ] ❌ **訂單拆單 / 合單**（v1 一筆顧客訂單對應一筆取貨）
- [ ] ❌ **預付定金**（v1 取貨才付款）
- [ ] ❌ **LINE Pay 等行動支付**（銷售 Q9 已排除 v1）

---

## 6. User Stories

### 總倉小幫手（發布 + 登打）
- [ ] 作為小幫手，我要建立新團購活動：選 SKU 清單、填售價、設結單日、選頻道
- [ ] 作為小幫手，我要一鍵產生 LINE 發文文字、複製貼到 20 個頻道
- [ ] 作為小幫手，我要用系統介面**逐筆登打顧客 +N 留言**（v1 主要工作）
- [ ] 作為小幫手，我 P1 要**上傳截圖**、系統自動解析訂單、我只審核修改
- [ ] 作為小幫手，**首次遇到陌生暱稱**時，系統提示我綁定到會員；下次自動帶入
- [ ] 作為小幫手，我要結單、看到該團各門市各 SKU 總量
- [ ] 作為小幫手，我要把結單統計**一鍵餵給採購模組**（產生 PR）

### 顧客
- [ ] 作為顧客，我在 LINE 社群看到團購文、留言 `+3`、店家收單
- [ ] 作為顧客，我要能**改單**（留言「改成 +5」）— 小幫手能識別
- [ ] 作為顧客，我可以**取消**（留言「取消」）— 小幫手能識別
- [ ] 作為顧客，我**加 LINE OA** 後可在 LIFF 查我所有團購訂單
- [ ] 作為顧客，我收到到貨通知（LINE OA 推播）「您訂的 X 商品已到 A 店，請於 5/10 前取貨」
- [ ] 作為顧客，我到門市報手機 / 掃 LIFF QR → 店員調出我的訂單 → 確認取貨

### 店長 / 店員
- [ ] 作為店員，顧客來取貨時我要能快速調出該顧客的訂單（可能多筆團購）
- [ ] 作為店員，**部分取貨**（顧客只想拿部分、其他下次）系統要能支援
- [ ] 作為店長，我要看本店的所有進行中團購、預計到貨日、顧客分佈
- [ ] 作為店長，我要看**逾期未取**清單、聯絡顧客

### 總部老闆
- [ ] 作為老闆，我要看**團購營運儀表板**：本月團數、總下單數、取貨率、熱銷 SKU
- [ ] 作為老闆，我要看**每團損益**：售價 × 取貨數 − 採購成本 = 毛利

---

## 7. Functional Requirements

### 7.1 團購活動（Campaign）管理

- [ ] 建立新活動：
  - 名稱、描述、主圖
  - 商品清單：多選 SKU，每 SKU 填「本次售價」+「收單上限」（可空表示無上限）
  - 收單期間：start_at / end_at（自動或手動結單）
  - 預計到貨日、取貨期限
  - 套用 post 範本
  - 發布頻道：選 20 個之中要發的 subset
- [ ] 活動狀態流：
  - `draft`（草稿）
  - `open`（收單中）
  - `closed`（結單停止收單）
  - `ordered`（已開 PO 給供應商）
  - `receiving`（到貨中）
  - `ready`（可取貨）
  - `completed`（取貨期限到）
  - `cancelled`
- [ ] 編輯限制：`open` 後只能改非關鍵欄位（描述、圖片）；售價 / SKU 清單 / 收單上限鎖定
- [ ] 關聯：`campaign ← post_templates`（發文模板）、`campaign → campaign_items`（SKU）、`campaign → campaign_channels`（頻道）

### 7.2 發文範本（Post Template）

- [ ] CRUD：總部可管理多套範本
- [ ] 變數佔位符：`{product_name}`, `{price}`, `{spec}`, `{close_date}`, `{delivery_date}`, `{shop_name}` 等
- [ ] 套到活動後產生可複製文字（多 SKU 時自動迭代）
- [ ] UI：活動頁有「產生發文」按鈕 → 彈出視窗顯示文字 + 「複製」按鈕
- [ ] 複製後提示：「請自行貼到 LINE 社群 X / Y / Z 頻道」

### 7.3 訂單登打（Order Entry）— v1 核心

- [ ] **v1 路徑（純人工）**：
  - 進入「活動 → 登打」介面
  - 介面分區：
    - 頂部：活動資訊 + 本次商品清單（可拖放加入訂單）
    - 左側：顧客搜尋（輸入 LINE 暱稱 / 手機 autocomplete）
    - 中間：訂單明細表（可多筆顧客並列、類似 Excel）
    - 右側：本活動總結單數 / 各 SKU 累計
  - 快速鍵：
    - `Tab` 跳欄
    - `Enter` 新增明細列
    - `Ctrl+N` 新顧客
    - `Ctrl+S` 存檔
  - Autocomplete：
    - 打 LINE 暱稱 → 顯示既有 aliases + 會員資料
    - 新暱稱 → 提示「新綁定」→ 輸入手機 → 系統建 member + alias
  - Draft 自動存檔（30s）
- [ ] **P1 路徑（截圖解析）**：
  - 上傳 1 或多張 LINE 頻道截圖
  - 系統呼叫 Claude Haiku vision（附上本活動 SKU 清單 + prompt）
  - 回傳 JSON：`[{nickname, orders: [{sku_id, qty, action}]}]`
  - 填入上述登打表格草稿
  - 小幫手審核 / 修改 / 送出
  - 儲存截圖 + LLM 原始輸出（`source_screenshots[]`, `source_parsed_json`）
- [ ] 登打完成：批次建 `customer_orders` + `customer_order_items` + 呼叫 `rpc_reserve`

### 7.4 顧客身份對應（Customer Line Aliases）

- [ ] `customer_line_aliases (tenant_id, channel_id, nickname, member_id)` UNIQUE
- [ ] 同一 nickname 在不同 channel 可對應不同 member（極少但理論上可能）
- [ ] 首次綁定流程：
  - 小幫手輸入 nickname → 找不到 alias
  - 系統跳窗「綁定到既有會員 / 建新會員」
  - 輸入手機 → 走會員模組 `rpc_resolve_member` / 申辦新會員
  - 建立 alias
- [ ] 二次之後：直接帶出
- [ ] **LIFF 自助綁定（P1）**：
  - 顧客加 OA 後 → LIFF 請填 nickname
  - 系統自動建 alias（`created_by = self`）

### 7.5 結單（Close Campaign）

- [ ] 手動：小幫手按「結單」按鈕
- [ ] 自動：達到 `end_at` 時間
- [ ] 結單觸發：
  - 活動狀態 `open → closed`
  - 計算各 SKU 各門市總量（`GROUP BY location, sku`）
  - 呼叫採購模組 `rpc_create_pr_from_campaign(campaign_id)`
    - 自動產生一張 PR（或多張依供應商拆分）
    - PR 來源類型 `source_type = 'campaign'`
    - 可追溯：PR ← items ← orders ← customers
  - 觸發通知：小幫手 / 採購員「Campaign #X 已結單、PR 已產生」

### 7.6 收單上限 / Campaign Cap

- [ ] **商品層級**：`campaign_items.cap_qty`（例：保鮮袋限量 500 份）
- [ ] **頻道層級**：`campaign_channels.cap_qty`（例：A 頻道限 200 份）
- [ ] **整團層級**：`campaigns.total_cap_qty`（例：整團 2000 份）
- [ ] 下單時檢查（登打 / LLM 解析完要送出前）：
  - 若超過 cap → 彈窗警告「超過上限、是否候補 / 截斷」
  - 小幫手決定：接受 / 候補 / 拒絕
  - 候補單 status = `waitlist`、不 reserve 庫存
  - 若補貨補到 → 依候補順序轉 `confirmed`
- [ ] UI：登打頁即時顯示剩餘名額

### 7.7 取貨（Pickup）

- [ ] **取貨識別**：
  - 店員掃顧客 LIFF QR → 會員模組 `rpc_resolve_member` → 會員 ID
  - OR 輸入手機查會員
  - OR 輸入訂單號碼（小幫手事先給）
- [ ] **調出訂單**：
  - 顯示該會員在本店所有 `ready` / `partially_ready` 訂單
  - 每訂單顯示：活動名稱、品項、數量、付款金額
- [ ] **確認取貨**：
  - 全額取貨：標記 order 全部 items 為 `picked_up`、`order.status = completed`
  - 部分取貨：選要取的 items、status `partially_completed`
- [ ] **觸發 POS 結算**：
  - 呼叫銷售模組建立 `pos_sale` + `pos_sale_items`
  - POS 觸發 `rpc_outbound` 扣庫存 + `rpc_release` 釋放 reserved
  - POS 觸發 `rpc_earn_points` 會員點數
  - 顧客付款（v1 只收現金）
- [ ] **逾期未取**：
  - 超過取貨期限未取 → `order.status = expired`
  - 釋放 reserved 庫存
  - 通知小幫手處理（退款 / 放回庫存銷售 / 報廢）

### 7.8 通知觸發

- [ ] 活動到貨 → 本模組發事件 `order.ready_for_pickup`（包含 member_id, store, pickup_deadline, items）→ 通知模組推播
- [ ] 取貨期限前 2 天 → `order.pickup_reminder`
- [ ] 取貨期限到未取 → `order.pickup_expired`
- [ ] 結單通知小幫手 → `campaign.closed`

### 7.9 報表 / Dashboard

- [ ] 本月團購總覽：活動數 / 總訂單 / 總金額 / 取貨率
- [ ] 每團損益：售價合計 − 採購成本 = 毛利率
- [ ] 熱銷 SKU（近 30 天）
- [ ] 各頻道活躍度：下單數 / 取貨率
- [ ] 顧客忠誠度：重複下單次數
- [ ] 逾期未取清單

---

## 8. 非功能需求（NFR）
- [ ] **資料一致性**：`customer_orders` + `customer_order_items` + `rpc_reserve` 必須原子（transaction）
- [ ] **併發**：登打時 5 人同時 → 同 campaign、同 member 不能被兩位小幫手同時綁定 alias（`UNIQUE` 索引保護）
- [ ] **效能**：
  - 活動清單載入 < 1s
  - 登打 autocomplete P95 < 200ms
  - LLM 截圖解析 P95 < 5s（P1）
  - 結單彙總（15k SKU × 100 store）< 10s
- [ ] **稽核**：所有訂單 CRUD 留 `created_by/updated_by` + 變更 log
- [ ] **離線**：登打 UI 不支援離線（必需 server-side reserve）
- [ ] **資料保留**：截圖 + LLM 解析 **2 年**（客訴防線）；訂單主檔 7 年（同稅務要求）
- [ ] **多租戶**：所有表帶 `tenant_id`、RLS 隔離

---

## 9. 權限（RBAC）

| 權限 | 老闆 | 小幫手 | 店長 | 店員 |
|---|:-:|:-:|:-:|:-:|
| 建 / 編輯團購活動 | ✅ | ✅ | ❌ | ❌ |
| 產生發文文字 | ✅ | ✅ | ❌ | ❌ |
| 登打訂單 | ✅ | ✅ | ❌ | ❌ |
| 上傳截圖 + LLM 解析（P1）| ✅ | ✅ | ❌ | ❌ |
| 綁定 / 修改 alias | ✅ | ✅ | ✅（本店）| ❌ |
| 結單 | ✅ | ✅ | ❌ | ❌ |
| 查全集團訂單 | ✅ | ✅ | ❌ | ❌ |
| 查本店訂單 | ✅ | ✅ | ✅ | ✅ |
| 確認取貨（POS） | ✅ | ✅ | ✅ | ✅ |
| 處理逾期訂單 | ✅ | ✅ | ✅（本店）| ❌ |
| 看報表 | ✅ | ✅ | ✅（本店）| ❌ |

---

## 10. 資料模型草稿（待 Review）

- [ ] `line_channels` — 20 個 LINE 社群頻道主檔
- [ ] `post_templates` — 發文範本
- [ ] `group_buy_campaigns` — 團購活動單頭
- [ ] `campaign_items` — 活動商品明細（SKU + 售價 + cap）
- [ ] `campaign_channels` — 活動 × 頻道關聯（哪些頻道要發）
- [ ] `customer_line_aliases` — 社群暱稱 ↔ 會員對應
- [ ] `customer_orders` — 顧客訂單（單頭）
- [ ] `customer_order_items` — 訂單明細
- [ ] `customer_order_source` — 截圖 + LLM 解析存檔（或直接欄位）
- [ ] `order_pickup_events` — 取貨紀錄 log
- [ ] `order_waitlist` — 候補清單（超過 cap 的訂單）
- [ ] `order_audit_log` — 稽核

---

## 11. 與其他模組的整合點

- [ ] **商品模組** ← 讀 SKU / price / category；campaign_items.sku_id
- [ ] **會員模組** ← `rpc_resolve_member`、alias 綁定；`rpc_earn_points`
- [ ] **庫存模組** → `rpc_reserve` / `rpc_release` 鎖釋庫存；取貨時 `rpc_outbound`
- [ ] **採購模組** → `rpc_create_pr_from_campaign`（新 RPC，v0.2）
- [ ] **銷售模組** → 取貨時建立 `pos_sales`
- [ ] **通知模組** → 到貨 / 取貨期限 / 逾期事件推播
- [ ] **LIFF 前端（另案）** → 顧客查訂單、取貨確認、補綁 alias

---

## 12. 驗收準則（Acceptance Criteria）

- [ ] 建團購活動 → 產生發文文字 → 複製貼到 LINE → 活動狀態 `open`
- [ ] 登打顧客「+3」→ 建 order + items + reserve 3 份 → 剩餘名額 -3
- [ ] 首次登打新 nickname → 綁定會員流程完成 → 下次自動帶入
- [ ] 顧客改單「+3 → +5」→ 找既有 order → 更新 qty + 補 reserve 2 份
- [ ] 結單 → PR 自動產生 → 各門市各 SKU 總量正確
- [ ] 到貨配送完成 → order status `ready` → 通知模組推播 LINE OA
- [ ] 顧客到店掃 QR → 店員看到該顧客所有 ready 訂單 → 確認取貨 → POS 結算 + 扣庫存 + 賺點 + 釋放 reserved
- [ ] 逾期未取 → status `expired` → 釋放 reserved → 通知小幫手
- [ ] 登打中查過去某顧客某期團購 → 截圖 + LLM 解析 原文可查

---

## 13. Open Questions（待確認）

### 活動設計
- [x] **Q1 收單上限層級**：→ **三層都要（A）**，但全部 nullable。（2026-04-21）

  **業態事實**：有單一門市爆單情況 → 頻道層 cap 必要。

  **實作**：
  | 層級 | 欄位 | 用途 | 必填 |
  |---|---|---|---|
  | 商品 | `campaign_items.cap_qty` | 某 SKU 整團上限（供應商可給的總量）| 選填 |
  | 頻道 | `campaign_channels.cap_qty` | 某頻道可訂總量（防單店爆單）| 選填 |
  | 整團 | `group_buy_campaigns.total_cap_qty` | 整團訂單總量（活動規模限制）| 選填 |

  NULL = 無上限。下單時**三層都檢查**、任一超過即觸發 Q2 處理。

  UI：
  - 建活動時預設 cap 都 blank（無上限）
  - 有經驗的小幫手才設限
  - 登打介面即時顯示三層各自剩餘名額
- [x] **Q2 超過 cap 處理**：→ **混合（D）：預設候補、小幫手可切拒絕 / 關團**。（2026-04-21）

  **邏輯**：
  - 登打時系統偵測超 cap → 彈窗
  - 預設動作：**候補（waitlist）**
  - 小幫手可改選：
    - **候補**：進 `order_waitlist`，不 reserve 庫存
    - **拒絕此單**：不建訂單、小幫手自己回覆顧客抱歉
    - **自動關團**：把活動狀態改 `closed`、之後都拒收
  - **候補轉正**：別人取消 / 到貨超預期時、依 waitlist 順序補上
  - 候補顧客要另外推播通知（「您在保鮮袋團購候補、順位 3」/「已補到您、請確認」）

  **schema**：
  ```sql
  CREATE TABLE order_waitlist (
    id BIGSERIAL PRIMARY KEY,
    tenant_id UUID NOT NULL,
    campaign_id BIGINT NOT NULL REFERENCES group_buy_campaigns(id),
    sku_id BIGINT NOT NULL,
    member_id BIGINT REFERENCES members(id),
    nickname TEXT,
    qty NUMERIC(18,3) NOT NULL,
    position INTEGER,                    -- 候補順位
    status TEXT DEFAULT 'waiting' CHECK (status IN ('waiting','promoted','cancelled','expired')),
    promoted_order_id BIGINT REFERENCES customer_orders(id),
    created_by UUID, updated_by UUID,
    created_at TIMESTAMPTZ DEFAULT NOW(), updated_at TIMESTAMPTZ DEFAULT NOW()
  );
  ```
- [x] **Q3 一團多頻道**：→ **各頻道獨立、不合併（A）**。（2026-04-21）

  **原則**：頻道對應門市、取貨地點由頻道決定。
  - 同會員在 X 頻道 +3 → 訂單 A（X 店取貨）
  - 同會員在 Y 頻道 +2 → 訂單 B（Y 店取貨）
  - 兩筆獨立、各自 reserve、各自結帳、各自取貨
  - `customer_orders.channel_id` 決定 `pickup_location_id`（不由顧客選）

  **schema 影響**：`customer_orders` 要有 `channel_id` NOT NULL，且 `pickup_location_id` 從 `line_channels.home_location_id` 取。

  **偶發跨頻道情境**：視為正常 — 顧客就是在兩家店都要取貨、分兩筆沒問題。
- [x] **Q4 活動編輯限制**：→ **全部可改、留稽核（C）**。（2026-04-21）

  **延續寬鬆哲學**（同 Q8 店長改售價、Q1 B2B 額度、Q4 POS 折扣）：信任操作者、事後稽核。

  **實作**：
  - 活動 `open` 狀態後任何欄位都可改（售價、SKU、cap、結單日…）
  - **每次變更必填 `edit_reason`**（一句話原因）
  - 所有變更寫 `campaign_audit_log`：
    - `campaign_id, field, before_value, after_value, edit_reason, operator_id, created_at`
  - **已下單顧客的保護**：
    - 售價改了 → 既有訂單保留**下單當時的 unit_price**（不追溯）
    - SKU 移除 → 既有訂單該 item 不受影響，新訂單無法再加
    - Cap 改小 → 若已超現況、系統跳警告（不強制處理）
  - 影響較大的變更（售價 / SKU 移除 / 結單日提前）→ 推播通知小幫手團隊

  **schema 新增**：
  ```sql
  CREATE TABLE campaign_audit_log (
    id BIGSERIAL PRIMARY KEY,
    tenant_id UUID NOT NULL,
    campaign_id BIGINT NOT NULL REFERENCES group_buy_campaigns(id),
    entity_type TEXT NOT NULL,      -- 'campaign' / 'item' / 'channel'
    entity_id BIGINT,
    field TEXT NOT NULL,
    before_value JSONB,
    after_value JSONB,
    edit_reason TEXT NOT NULL,
    operator_id UUID NOT NULL,
    operator_ip INET,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  ```

  **顧客訂單保護欄位**：
  - `customer_order_items.unit_price` 已記錄下單時價（不追溯後續修改）

### 訂單與登打
- [x] **Q5 改單 / 取消時限**：→ **結單前隨時可改（A）**。（2026-04-21）

  **原則**：活動狀態 `open` 期間，顧客 / 小幫手可自由改單、取消。
  - 結單（`open → closed`）瞬間凍結、之後不可改
  - 小幫手處理改單 / 取消時同樣更新庫存 reserve（加 / 減）
  - 沒有「結單前 X 小時凍結」的緩衝期 — 延續寬鬆哲學

  **trade-off 已接受**：
  - 結單前一分鐘取消 → 採購數字可能浮動
  - 但小幫手本來就要在結單**後**才彙總跑 PR，不影響採購流程
  - 實務上結單瞬間 snapshot 即為採購依據
- [x] **Q6 一顧客一團多筆訂單**：→ **合併現有訂單（A）**。（2026-04-21）

  **UNIQUE constraint**：`(tenant_id, campaign_id, channel_id, member_id)` — 同團同頻道同會員只有一筆 order。

  **邏輯**：
  - 登打時 lookup 是否已有 → 有則 UPDATE / 新增 items；無則 CREATE
  - 數量變動 → 對應 `rpc_reserve` / `rpc_release`（加或減）
  - 取貨時一次結算所有 items（取貨地點相同）
  - `customer_order_items` 可一筆 order 內多個 SKU（本來就支援）

  **追溯來源**：
  - `customer_order_items.source_line_raw TEXT[]` 可存多次留言原文（每次加訂留一條）
  - LLM 解析時若偵測為加訂 → append 到既有 items 的 source_raw
  - 保留「早上 +3 / 下午 +2」時序紀錄以利客訴
- [x] **Q7 最低訂購量 MOQ**：→ **不做（A）**。（2026-04-21）

  系統不追蹤 / 不警告 MOQ；結單照實收到的數量 → 採購模組 / 小幫手自己決定要不要補單或跟供應商商量。

  **不影響 schema** — 無需額外欄位。未來若真需要、再加 `campaign_items.moq` 欄位（P2）。
- [x] **Q8 匿名 / 訪客下單**：→ **自動建 guest 會員（C）**。（2026-04-21）

  **流程**：
  - 小幫手登打遇到無法綁定的 nickname → 系統自動建「訪客會員」（`member_type = 'guest'`）
  - 訂單正常建立、關聯到 guest member
  - 顧客日後加 OA / 填手機 → 觸發合併流程（會員模組 `member_merges` 表已規劃）
  - 合併後：訂單 / 點數 / 儲值金 / alias 全部搬到 real member

  **v0.2 schema 變動（會員模組）**：
  ```sql
  ALTER TABLE members
    ADD COLUMN member_type TEXT NOT NULL DEFAULT 'full'
      CHECK (member_type IN ('full','guest'));

  -- Guest 的 phone_hash 用 placeholder 滿足 UNIQUE：'GUEST_' || id
  -- phone_enc NULL 允許（已允許）
  -- 新增部分 UNIQUE index，避免 GUEST_* 互相衝突：
  -- UNIQUE (tenant_id, phone_hash) 現已存在，placeholder 'GUEST_<id>' 天然 unique
  ```

  **guest 會員特性**：
  - 無手機、無 PII、無法識別個別身份
  - 取貨時識別：看 nickname + 訂單號碼（或 guest 升級成 full 後憑手機）
  - 點數 / 儲值金仍可累（合併時搬移）
  - GDPR 刪除：同 full member 邏輯

  **RPC 新增**：
  - `rpc_create_guest_member(tenant_id, channel_id, nickname)` → 回 member_id
  - `rpc_merge_member(guest_id, real_id)` → 搬移所有關聯資料到 real、guest 標 `status='merged'`

  **取貨識別**（更新自 §7.7）：
  - Guest 取貨：靠 nickname + 訂單號
  - Full member 取貨：手機 / LIFF QR
  - 小幫手可在取貨當下升級 guest → full（填手機）

### 取貨
- [x] **Q9 取貨期限**：→ **依 SKU 儲存類型預設，可覆寫**。（2026-04-21）

  **設計**：
  - 商品新增 `storage_type` 屬性：`frozen`（冷凍）/ `refrigerated`（冷藏）/ `room_temp`（常溫）
  - 全 tenant 共用預設值（可調）：
    | storage_type | 預設取貨天數 |
    |---|---|
    | 冷凍 frozen | 7 天 |
    | 冷藏 refrigerated | **2 天** |
    | 常溫 room_temp | 7 天 |
    | **美食列車 meal_train** | **0 天（當天取）** |
  - 建活動時，系統自動依 SKU 的 storage_type 計算**最嚴格的取貨期限**（取 MIN）
    - 例：活動含冷凍 + 冷藏商品 → 2 天（取最短）
    - 例：活動含美食列車 → 當天 0 天（最嚴）
  - **美食列車特殊規則**：
    - 若活動含 `meal_train` 商品 → 到貨即當日結案
    - 未取貨顧客在當日營業結束後自動 `expired`
    - 推播通知時機需提早（例：到貨前 2 小時就先推播）
  - 小幫手可在活動層級**手動覆寫**（`group_buy_campaigns.pickup_days` 欄位）

  **v0.2 schema 變動（商品模組）**：
  ```sql
  ALTER TABLE products
    ADD COLUMN storage_type TEXT
      CHECK (storage_type IN ('frozen','refrigerated','room_temp','meal_train'))
      DEFAULT 'room_temp';
  ```

  **v0.2 schema 變動（tenant_settings）**：
  ```sql
  -- tenant_settings.pickup_days_by_storage JSONB
  -- DEFAULT '{"frozen": 7, "refrigerated": 2, "room_temp": 7, "meal_train": 0}'
  ```

  **v0.2 schema 變動（本模組）**：
  ```sql
  ALTER TABLE group_buy_campaigns
    ADD COLUMN pickup_days INTEGER,  -- NULL = 自動依 SKU storage_type 計算最小值
    ADD COLUMN pickup_deadline_at TIMESTAMPTZ;  -- 到貨日 + pickup_days 計算
  ```

  **與庫存 Q2 呼應**：`categories.expiry_grace_days`（效期寬限）是關於**商品本身過期**；本題 `storage_type + pickup_days` 是關於**顧客取貨時限**。兩者獨立但邏輯類似（依商品特性分層設定）。
- [x] **Q10 逾期未取處理**：→ **依 storage_type 複合規則**。（2026-04-21）

  | storage_type | 處理方式 | 說明 |
  |---|---|---|
  | `meal_train`（美食列車）| **報廢** | 當天取貨、過期必須扔掉（食安）|
  | `refrigerated`（冷藏）| **報廢** | 短效、風險大 |
  | `frozen`（冷凍）| **放回一般庫存** | 仍可冷凍保存銷售 |
  | `room_temp`（常溫）| **放回一般庫存** | 保存期長 |

  **流程**（排程 job 每日凌晨跑）：
  - 掃 `customer_orders` where `pickup_deadline_at < NOW()` AND `status IN ('ready','partially_ready')`
  - 逐筆處理：
    1. 訂單 status → `expired`
    2. 釋放 reserved：`rpc_release`
    3. 依每個 item 的 SKU storage_type 決定：
       - 報廢 → `rpc_outbound(movement_type='damage', reason='pickup_expired')`
       - 放回庫存 → 什麼都不做（reserved 已釋放、on_hand 就回一般庫存了）
    4. 產生 `order_expiry_events` 紀錄（含處理方式）
    5. 通知店長 / 小幫手
  - 顧客：透過通知模組發「您的訂單已逾期」告知（若有賺過點則照 points_ledger 反向扣回、v1 尚未付款故無退款）

  **schema 新增**：
  ```sql
  CREATE TABLE order_expiry_events (
    id BIGSERIAL PRIMARY KEY,
    tenant_id UUID NOT NULL,
    order_id BIGINT NOT NULL REFERENCES customer_orders(id),
    order_item_id BIGINT,
    action TEXT NOT NULL CHECK (action IN ('damaged','returned_to_stock','refunded')),
    storage_type TEXT,
    qty NUMERIC(18,3) NOT NULL,
    movement_id BIGINT REFERENCES stock_movements(id),
    operator_id UUID,    -- NULL = 系統自動
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  ```
- [x] **Q11 部分取貨後剩餘**：→ **原期限繼續（A）**。（2026-04-21）

  **邏輯**：
  - 訂單原本 pickup_deadline_at = X
  - 顧客部分取貨後，剩餘 items 仍使用同一個 deadline X
  - 不延長期限、顧客需在原期限內回來取完
  - 到期未取 → 套 Q10 處理（依 storage_type）

  **schema**：
  - `customer_orders.status` 增加 `partially_picked_up` 狀態（部分已取、仍 open）
  - `customer_order_items.picked_qty / remaining_qty` 追蹤
  - 取貨時逐 item 記 `order_pickup_events`（已有規劃）

### 技術 / 整合
- [x] **Q12 LLM 解析階段策略**：→ **沿用採購 Q3：v1 純人工 / P1 Claude vision / P2 OCR**。（2026-04-21）

  v1 實作重點：`customer_orders.source_raw_text`, `source_screenshots[]`, `source_parsed_json` 三欄位 NULL 即可（留給 P1 / P2 填）。
  UI：登打介面設計成「順手人工登打」為主、不依賴截圖功能。

- [x] **Q13 campaign_cap 計算時機**：→ **Real-time 即時扣**。（2026-04-21）

  **實作**：
  - 登打送出訂單 → Transaction 內：
    1. `SELECT ... FOR UPDATE` 鎖 `campaign_items` / `campaign_channels` / `group_buy_campaigns` 相關列
    2. 檢查三層 cap 剩餘（`qty_cap - qty_ordered >= requested_qty`）
    3. 通過 → 建 `customer_order_items` + 更新 `qty_ordered` 計數 + `rpc_reserve`
    4. 超過 → 依 Q2 流程（彈窗、候補 / 拒絕 / 關團）
  - `version` 樂觀鎖配合
  - 登打 UI 實時顯示「剩餘 XX 份」（每次送出後 refresh，或用 Supabase Realtime 推播）

- [x] **Q14 訂單號碼格式**：→ **`ORD-yyMMdd-NNNN`**（例：`ORD-260421-0001`）。（2026-04-21）

  - DB sequence `order_no_seq` 每日 reset（cron 或 trigger 處理）
  - `customer_orders.order_no TEXT UNIQUE`
  - RPC `rpc_next_order_no(tenant_id)` 產號

### 報表 / 分析
- [x] **Q15 逾期閾值警示**：→ **絕對數 ≥ 10 筆、通知門市店長**（非老闆）。（2026-04-21）

  **邏輯**：
  - 逾期處理 job（Q10）跑完後、每活動 × 每門市彙總
  - 若某門市在該活動的逾期數 **≥ 10 筆** → 透過通知模組推播該店店長
  - 推播訊息：「活動 #X 在您的門市有 Y 筆逾期未取（已依規則報廢 / 放回庫存）、請 review 原因」
  - 老闆可在 dashboard 看全集團彙總、不另外推播

  **why 店長而非老闆**：
  - 店長最能直接處理該店問題（配送延誤、通知沒發到、顧客反應差）
  - 老闆只看 dashboard 彙總即可
  - 閾值絕對數（非比例）避免小團誤報（例：只 8 筆訂單全部逾期 = 100% 但實際不嚴重）
- [x] **Q16 庫存短缺分配**：→ **FIFO 先下單先得（A）**。（2026-04-21）

  **情境**：到貨 < 訂單總量時的分配機制。

  **邏輯**（排程 job / 手動觸發）：
  - 依 `customer_orders.created_at ASC` 排序所有該 campaign 的訂單
  - 依序分配：每筆訂單若 requested_qty ≤ remaining_stock → 全額滿足
  - 最後一筆可能部分滿足（剩餘不夠）→ `partially_fulfilled`
  - 之後的訂單全部 `shortage_unfulfilled`
  - 分配完成：
    - 滿足的訂單 → status 照正常流程（ready → 推播取貨）
    - 部分滿足 → 只滿足可給的份數、剩餘轉 `waitlist` 等補貨或退單
    - 未滿足 → 推播通知顧客「抱歉、本次缺貨、下次優先」+ 記 `shortage_events`（供下次優先處理）

  **schema 新增**：
  ```sql
  CREATE TABLE order_shortage_events (
    id BIGSERIAL PRIMARY KEY,
    tenant_id UUID NOT NULL,
    campaign_id BIGINT NOT NULL,
    order_id BIGINT NOT NULL REFERENCES customer_orders(id),
    sku_id BIGINT NOT NULL,
    requested_qty NUMERIC(18,3),
    fulfilled_qty NUMERIC(18,3),
    shortage_qty NUMERIC(18,3) GENERATED ALWAYS AS (requested_qty - fulfilled_qty) STORED,
    reason TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
  );
  ```

  **考量**：
  - 透明公平、顧客能理解「先到先得」
  - 系統實作簡單（只需 ORDER BY created_at）
  - 不會產生等級 / 隨機類的客訴
  - 未來若要改（例如 VIP 優先）可擴充成 score-based（`score = f(tier, time)`），但 v1 純 FIFO

---

## 14. 下一步
- [ ] 回答 Q1~Q16 → 進入 v0.2（展開 DB schema + RPC）
- [ ] 建 `docs/DB-訂單取貨模組.md`
- [ ] 建 `docs/sql/order_schema.sql`
- [ ] Spike：Claude Haiku vision 解析準確率（POC）
- [ ] Spike：campaign_cap 併發扣除正確性（5 人同時登打）
- [ ] 與會員模組整合：alias 綁定流程 UX

---

## 相關連結
- [[PRD-商品模組]] — 團購商品來源（SKU / price）
- [[PRD-會員模組]] — 顧客身份、LIFF、OA 推播入口
- [[PRD-庫存模組]] — reserve / release / outbound
- [[PRD-採購模組]] — 結單後的 PR / PO
- [[PRD-銷售模組]] — 取貨時的 POS 結算
- [[通知模組]] — 推播事件消費者（尚未建立 PRD）
- [[LIFF前端]] — 顧客端網頁（另案）
- [專案總覽](Home)

---

## 本 PRD 已吸收的既有決策（跨模組）

- **業態**：團購店、20 LINE 社群頻道 × 300~2000 顧客 / 頻道
- **LINE 社群無 API**：半自動發文 / 截圖解析
- **雙加架構**：顧客加社群 + OA，訂單模組負責 alias 綁定
- **預留庫存**：下單即 reserve（庫存 Q7）
- **解析分階段**：v1 人工 / P1 Claude vision / P2 OCR（採購 Q3）
- **POS 結算**：v1 只收現金（銷售 Q6）
- **會員等級**：4 級 + 點數 1% + 等級倍率（會員 Q5）
- **稽核**：所有表帶四欄位 created_by / updated_by / created_at / updated_at

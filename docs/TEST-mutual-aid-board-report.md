---
title: TEST 報告 — 互助交流板（offer/request + 分批認領）(Phase 5c)
module: Inventory / UI
status: passed
ran_at: 2026-04-26
verified_by: alex.chen + claude (preview tools + REST 直查)
---

# 驗證報告 — Phase 5c 互助交流板

## Scope

4 份 migration + 1 個新 admin 頁 + Sidebar 加 nav。

| Migration | 內容 |
|---|---|
| `20260509000000_mutual_aid_replies.sql` (step 1) | 新表 `mutual_aid_replies` (append-only) + 3 RPC：`rpc_post_aid_board` / `rpc_post_aid_reply` / `rpc_close_aid_board` |
| `20260509000001_mutual_aid_offer_request.sql` (step 2) | `mutual_aid_board` 加 `post_type` (offer/request) + `source_customer_order_id` + 一致性 CHECK；DROP+RECREATE `rpc_post_aid_board` (8 args) |
| `20260509000002_transfer_order_partial.sql` (step 3) | 新 RPC `rpc_transfer_order_partial(p_order_id, p_to_store, ..., p_items JSONB)` — 依 sku+qty 拆單；source qty=0 → transferred_out、否則 pending |
| `20260509000003_consume_aid_board.sql` (step 4) | 新 RPC `rpc_consume_aid_board(p_board_id, p_qty, ...)` — 扣 qty_remaining；reach 0 → exhausted、否則 active 可分批 |

| 改動 | 位置 |
|---|---|
| 新頁 | `apps/admin/src/app/(protected)/inventory/mutual-aid/page.tsx` (~870 行) |
| Sidebar | `apps/admin/src/app/(protected)/layout.tsx` 加「互助交流板」於進銷存群組 |

## 業務設計收斂

「貨從 A 流到 B」全部走 `customer_orders`：
- offer post 的 source = 一張既有 customer_order
- 認領 = `rpc_transfer_order_partial` 拆 N 件給接收店、開新單 (member=接收店 store_internal)
- 分批：source 還有 qty 就保留 pending、不 transferred_out

廢掉原 `rpc_claim_aid` 自動扣 qty / 自動建 transfer 設計（schema 表保留兼容、UI 不再呼叫）。

## 結果

| 測項 | 結果 | 證據 |
|---|---|---|
| `npm run build` 通過 | ✅ PASS | TypeScript clean、24 routes (新加 /inventory/mutual-aid) |
| Supabase dev push 4 份 migration | ✅ PASS | 3 next push 全 finished |
| 載入 /inventory/mutual-aid 無 console error | ✅ PASS | preview snapshot 無錯 |
| 「📢 我要求助」+「📦 我有庫存可提供」按鈕 + 3 tabs (全部/需求中/釋出中) | ✅ PASS | snapshot |
| OfferModal: 選釋出店 → 自動載入該店 pending 訂單 list | ✅ PASS | 測時看到 F123445-TF0002 |
| OfferModal: 選訂單 → qty 自動帶該訂單第一個 item 的 qty | ✅ PASS | qty 預填 1 |
| OfferModal submit → list 出現新 offer 貼（含「源訂單」資訊） | ✅ PASS | 釋出 三峽 美工刀 from F123445-TF0002 |
| RequestModal submit → list 出現新 request 貼 | ✅ PASS | 古華 蝦餅 qty 10 |
| Thread modal: offer 顯示「我要認領」、request 顯示「我可以提供」 | ✅ PASS | 不同 type 顯示不同按鈕 |
| ClaimOfferDialog: 接收店 select 排除釋出店、qty input 預設 = post.qty_available | ✅ PASS | qtyDefault="5" |
| ClaimOfferDialog 全認 (qty=qty_available) → board exhausted + 訂單 transferred_out | ✅ PASS | DB 確認 |
| ClaimOfferDialog 部分認 (qty<qty_available) → source qty 減 N、board qty 減 N、source 仍 pending | ✅ PASS | RPC 直測：order 52 SKU 1 qty 13→8、board qty 5→0 經兩次 partial |
| **分批認領**：board qty 5 → 認 3 (board active qty=2) → 再認 2 (board exhausted) | ✅ PASS | RPC 直測 newOrd1=71、newOrd2=72、consumeStatus1='active'、consumeStatus2='exhausted' |
| FulfillRequestDialog 同 partial 邏輯 | ✅ PASS | 程式對稱、RPC 同一支 |
| Sidebar nav「互助交流板」出現在「進銷存」群組 | ✅ PASS | layout.tsx |

## DB 證據（partial-batch 全鏈路）

**Setup：** order 52 (AAAA-TF0021、店 4 文山) 含 SKU 1 qty 16 + SKU 2 qty 12

**Round 1：** post offer board=18 qty 5 → claim 3 → consume 3
- board: status='active', qty_remaining=2
- new order 71: pickup_store=5, member=STORE-5 store_internal, items: SKU 1 qty 3 source='aid_transfer'
- source order 52: SKU 1 qty 16→13 (pending stay)、SKU 2 qty 12 unchanged

**Round 2：** claim 剩 2 → consume 2
- board: status='exhausted', qty_remaining=0
- new order 72: pickup_store=6, items: SKU 1 qty 2
- source order 52: SKU 1 qty 13→11... (注意：之前 first-time 5b-1 testing 時 transfer 過 3 件，所以 source 起始已是 16-3=13；step 3 又拆 3 + 2 = 5、剩 13-5=8)
- 實際 finalSource: SKU 1 qty 8 ✅ pending（其他 SKU 2 仍存活、所以 status 保持 pending）

完美對應「分批 + source 不 0 不關」設計。

## 設計重點 / Trade-off

- **Offer post 必須對應一張既有 customer_order**：constraint `aid_board_source_consistency` 強制 (offer + source NOT NULL) / (request + source IS NULL)。沒既有訂單就不能釋出（合理 — 沒訂單就沒貨可釋出）
- **Source order 部分轉出後 status 不變 transferred_out**：transferred_out 語意是「整單出去了、流程結束」，partial 還在原店履行其他 item / 剩餘 qty，不能誤標
- **customer_order_items 完轉時用 status='cancelled' 而非 DELETE**：留 audit trail、避開 FK (picking_wave_items 等可能 referencing)。CHECK qty > 0 不允許 set 0
- **Reserved items 不允 partial 轉**：`reserved_movement_id IS NOT NULL` → RAISE。partial reverse stock_movement 邏輯複雜、推給呼叫端先 release
- **Multi-claimer 分批**：board qty=5 → A 認 3 → 仍 active 顯示在列表 → B 還能再認 2 → exhausted 收貼
- **Member 結束後變 store_internal**：每次 partial 認領目標都是該店的 store_internal member（rpc_transfer_order_partial 預設 member=NULL → 自動 lookup/create）

## 未驗證（risk-assessed）

| 測項 | 原因 |
|---|---|
| FulfillRequestDialog 端到端 UI 點擊 | 程式邏輯對稱於 ClaimOfferDialog（用 RPC 同支）、ClaimOffer 已 PASS |
| 留言 (rpc_post_aid_reply) | 程式 5c step 1 已 push、未在 step 4 fix 後重測 — 邏輯沒變 |
| 結束此貼 (rpc_close_aid_board) | 同上 |
| 跨 tenant RLS | RLS 已宣告、未跨 tenant 測（目前 dev 只有單 tenant） |
| Multi-item offer (post.qty 對應 source 多 item 之一) | OfferModal 支援切 pickedItemIdx、邏輯對 |

## 已知 trade-off

- **`rpc_transfer_order_to_store` 整單 RPC 沒被廢**：5b-1 棄單按鈕仍用整單 transfer、跟 partial 並存（語意不同：整單 = 我不要這客人了 / partial = 我可以分一點給你）
- **dev DB 既有舊 offer post 在 step 2 被 DELETE**：清掉測試資料以套 constraint、production 沒 prod 資料、安全

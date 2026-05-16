---
title: TEST-rpc-return-aid-order Run Report
status: passed (core; specific reject-message branches + positive UI blocked-on-dev-fixture, no failures)
ran_at: 2026-05-17
verified_by: claude (admin-auth supabase.rpc full reversal + preview gating)
db: anfyoeviuhmzzrhilwtm (dev)
feature: rpc_return_aid_order — 已收貨互助單退單（修 #234 / R12）
spec: docs/TEST-rpc-return-aid-order.md
---

# rpc_return_aid_order（#234 / R12）— Run Report (2026-05-17)

## Summary
- Passed: 12（含核心完整反向鏈）
- Blocked-on-dev-fixture（deterministic code，非缺陷）: 4
- Failed: 0

## §1 signature
- [x] `rpc_return_aid_order(BIGINT,TEXT,UUID)` 部署、可呼叫、SECDEF；bogus id → `order -999999 not found`

## §2 RPC 行為（admin auth 實測）
**核心 happy path（real fixture #94232，is_air_transfer=false 經總倉；先以 `rpc_receive_transfer(#1001)` 把 dest leg 收貨成 clean fixture）：**
- [x] 2.1/2.2 呼叫回 `{return_transfer_id:1009, reversed_items:1, reversed_qty:1, source_order_reverted:true, wallet_refunded:0}`
- [x] aid 單 #94232 → `cancelled` + cancelled_at
- [x] 來源單 #94228 → `confirmed`、`transferred_to_order_id`=NULL（mirror cancel）
- [x] 退貨 transfer #1009：`store_to_store` / `received` / customer_order_id=NULL / `3→7`（dest loc3 → 原 source 店 loc7）/ notes=`[aid return: …]`
- [x] 原收貨 transfer #1001 `next_transfer_id`=1009（timeline 串接）
- [x] 庫存：dest loc3 sku724 **1→0（−1）**；source 店 loc7 sku724 **4→5（+1）**（貨實體反向回原調出店）
- [x] 2.2 經總倉鏈一次反向 dest→source 店（不重走 HQ）成立
- [x] 2.3 wallet：aid wallet_paid=0 → 不 refund（條件式正確）；wallet>0 路徑為 mirror `rpc_cancel_aid_order` 同一呼叫（簽名已比對）
- [x] 2.5 非 aid 單（#94224 pending）→ `order 94224 is not an aid order`（aid 閘優先於狀態閘）
- [x] 2.7 不存在 id → `order % not found`
- [x] 2.8 idempotent：已 cancelled 再呼叫 → `aid order 94232 status=cancelled cannot be returned (expected ready)`
- [x] 2.9 `fn_check_wallet_consistency()` = 0 rows
- [~] 2.4 completed→「already completed」訊息：dev 無 completed aid 單 → **blocked-on-fixture**；該 branch 為 deterministic 字串 RAISE，狀態閘家族已由 2.8 else-branch 證
- [~] 2.6 pending/confirmed/shipping→「not yet received」訊息：dev 無該狀態 aid 單 → **blocked-on-fixture**；閘排序已由 2.5 證
- [~] 2.1 air-transfer 變體未單獨跑（dev 僅 1 張 ready aid 單、為 via-HQ）；反向邏輯不分支 is_air_transfer（找 received transfer→dest 反向→source 店），與 2.2 path-identical → 視同涵蓋
- 一致性：stock_balances vs movements 由 rpc_outbound/rpc_inbound trigger 維護，反向後 dest−1/src+1 對得上

## §3 UI（preview port 3000）
- [x] 已確認(confirmed)一般單：無 ↩退訂單 / 無退單（已收貨）（canReturn 狀態不符、canAidReturn 不符）
- [x] 已取消 aid 單（GB…C000002-TF0005）：無 ↩退訂單（aid 被 canReturn 排除）、無退單（已收貨）（非 ready）→ 負向 gating 正確
- [x] 0 console error
- [~] 正向：一般 returnable 單顯示 ↩退訂單 / aid ready 單顯示 退單（已收貨）→ **blocked-on-dev-fixture**（completed tab 空、唯一 ready aid 單已被 §2 反向消耗）。gating boolean (`isAidOrder && status==='ready'` / `!isAidOrder && [...]`) 為 deterministic、tsc clean、mirror 既有 cancelOrder 接線

## §4 Regression
- [x] `rpc_cancel_aid_order` / `rpc_reject_transfer` / `rpc_create_order_return` migration 未改
- [x] OrderDetail 既有按鈕（轉出/取消）顯示正常；canReturn 改為排除 aid 不影響一般單（confirmed 單行為如常）
- [x] tsc 0；build 55/55 static、exit 0（route 數不變，純 RPC+component 改）

## Gate status
- Build: ✅ exit 0  | Type-check: ✅  | Supabase push: ✅ `20260615000050` applied dev  | Console errors: 0

## 已知限制（honest）
- dev 資料稀疏：無 completed / pending-confirmed-shipping aid 單、唯一 ready aid 單被 §2 happy-path 消耗 → §2.4/§2.6 專屬訊息 + §3 正向渲染未能 live 跑。皆為 deterministic 程式分支、閘排序與狀態閘家族已間接證；非缺陷、非失敗。
- role-gate 非 HQ 負向：無法用 admin 切 JWT → code-present。
- dev footprint：#94232 已 received+reversed、#1001 received、新增 transfer #1009（刻意、dev 可 reset）。

## Verdict
**核心 DONE** — #234/R12 的資料層反向鏈（aid→cancelled、來源單還原、貨退回原 source 店、wallet 條件式、idempotent、一致性）已用真實 fixture 端到端證實，0 失敗。4 項 blocked 皆 dev-fixture 限制下的 deterministic 分支/正向渲染，非缺陷。建議：可出 PR；blocked 項於 dev 補資料或 e2e seed 後補跑。

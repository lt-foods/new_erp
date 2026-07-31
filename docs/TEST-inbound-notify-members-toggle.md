---
title: TEST — 收貨待辦「收貨後通知會員」開關
module: WMS / Inbound
status: draft
owner: alex.chen
created: 2026-07-31
---

# 測試清單 — 收貨待辦「收貨後通知會員」開關

店家在 `/wms/inbound` 收貨時，可用開關決定要不要**整批**推播「您的商品到貨」給受影響會員。
開關套用到全部三條收貨路徑：單筆「收貨」、「✓ 批次收貨」、「✎ 調整」modal。

## Scope

- 前端：
  - `apps/admin/src/app/(protected)/wms/inbound/page.tsx` — 開關 UI（批次工具列）、`quickReceive` / `batchReceive` 接推播
  - `apps/admin/src/components/TransferReceiveModal.tsx` — 移除本地 fanout，改吃 `notifyMembers` prop
  - `apps/admin/src/lib/pickupNotify.ts`（新）— 共用 `fanoutPickupNotifications(transferIds: number[])`
- 後端：**無 schema / RPC 變更**。沿用既有 `rpc_get_members_to_notify_for_transfer`（已過濾
  `no_notify_pickup` 黑名單）、`rpc_mark_pickup_notified`、edge function `admin-notify`。
- 偏好儲存：`localStorage["inbound-notify-members"]`（`"1"` 開 / `"0"` 關，預設開）。

## 行為定義

| 路徑 | 開關 ON（預設） | 開關 OFF |
|---|---|---|
| 單筆「收貨」 | 收貨成功後推播該張 transfer 的受影響會員；推 >0 時 alert 顯示人數 | 只收貨，不推播 |
| 「✓ 批次收貨」 | 只對**成功**收貨的單 fan-out；跨單合併名單、**同會員只推一次**；alert 附「📩 已推播 N 位顧客」 | 只收貨，不推播 |
| 「✎ 調整」modal | 同舊行為：收貨完成後推播（原本是無條件推） | 不推播 |
| confirm 對話框 | 附註「📩 收貨後會推播…」 | 附註「🔕 已關閉會員通知…」 |

不受開關影響的既有行為：
- `rpc_get_members_to_notify_for_transfer` 內建的黑名單過濾（`members.no_notify_pickup`）。
- 推播與否不影響收貨本身；fan-out 任何失敗只 `console.warn`。
- 有推播時，所有受影響訂單（跨單去重）照舊標 `last_notify_pickup_at`（`rpc_mark_pickup_notified`）。
- 「↩ 退回收貨」不撤銷已發通知（`last_notify_pickup_at` 是 audit，維持不清除）。

## 測試項目

### A. 開關本身

- [ ] 未收分頁、有待收單時，批次工具列出現「📩 收貨後通知會員」checkbox，預設勾選
- [ ] 取消勾選 → 文案變「🔕 收貨後不通知會員」；重新整理頁面後仍是關閉（localStorage 記住）
- [ ] 分店帳號（非 HQ）也看得到、可操作此開關

### B. 單筆「收貨」

- [ ] ON：confirm 內含「📩 收貨後會推播…」；確認後該店受影響會員收到推播＋`notifications` 各新增一筆 `order_arrived`；訂單 `last_notify_pickup_at` 更新
- [ ] ON 且推播人數 > 0：alert「📩 已推播 N 位顧客」
- [ ] ON 但該 transfer 無對應會員訂單（如 return_to_hq / 純補貨）：不推播、無 alert、收貨正常
- [ ] OFF：confirm 內含「🔕 …」；收貨成功、完全無推播、`last_notify_pickup_at` 不變

### C. 「✓ 批次收貨」

- [ ] ON：勾 N 筆批次收貨 → alert「✅ 批次收貨完成:N 筆 📩 已推播 M 位顧客」
- [ ] 同一會員的訂單分散在多張選中的 transfer → 只收到 **1** 則推播；其所有受影響訂單都有標 `last_notify_pickup_at`
- [ ] 部分失敗：只對成功的單 fan-out（失敗單的會員不收到推播）；alert 的「部分成功」訊息含推播數
- [ ] OFF：批次收貨成功、無任何推播

### D. 「✎ 調整」modal

- [ ] ON：調整數量後確認收貨 → 推播照舊、alert 含「📩 已推播 N 位顧客」（與改版前行為一致）
- [ ] OFF：確認收貨 → 不推播、alert 無推播行
- [ ] 已收單開「看明細」（readOnly）→ 無收貨動作、無推播（不受開關影響）

### E. 黑名單與去重（回歸）

- [ ] `members.no_notify_pickup = true` 的會員：開關 ON 也不會收到推播（RPC 端過濾，非前端）
- [ ] 同會員多張訂單在同一張 transfer：仍只推 1 次（原有去重不變）

### F. 失敗容錯（回歸）

- [ ] `admin-notify` 回非 2xx / 網路失敗：收貨結果不受影響，只少了該會員的推播
- [ ] `rpc_get_members_to_notify_for_transfer` 失敗：收貨照常完成、alert 無推播行

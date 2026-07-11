# TEST — 補貨申請詳情：進度時間軸

功能：`RestockDetailModal` 加入「申請 → 核可 → 出貨 → 收貨」進度時間軸，
並在轉貨單／請購單連結旁顯示各自目前狀態。

資料來源（皆為既有欄位，無 schema 變動）：
- `restock_requests.requested_at / approved_at / rejected_at / status`
- `restock_requests.linked_transfer_id / linked_pr_id`
- `transfers.status / shipped_at / received_at`（出貨、收貨時間的唯一可靠來源）
- `purchase_requests.status`

## 進度階段判定（reachedLevel = max(restock, transfer)）

| 來源 | 對應 level |
|---|---|
| restock `pending` | 0 |
| restock `approved_transfer` / `approved_pr` | 1 |
| restock `shipped` | 2 |
| restock `received` | 3 |
| transfer `confirmed` | 1 |
| transfer `shipped` | 2 |
| transfer `received` / `closed` | 3 |

階段狀態：`level <= reached` → done；`level == reached+1` → current；其餘 → todo。

## 測試項目

### 顯示層
- [ ] T1 一般（pending）：只有「申請」為 done、時間 = requested_at；「核可」為 current；出貨/收貨為 todo（灰空心點）。
- [ ] T2 approved_transfer（尚未出貨）：申請/核可 done、核可時間 = approved_at；出貨 current；收貨 todo。核可副標顯示「派庫存」。
- [ ] T3 approved_pr：同 T2，但核可副標顯示「採購」。
- [ ] T4 同時掛 TR + PR（即 RESTOCK#18 型）：核可副標顯示「派庫存 + 採購」。
- [ ] T5 shipped：申請/核可/出貨 done；出貨時間 = transfer.shipped_at；收貨 current。
- [ ] T6 received：四階段全 done；出貨 = shipped_at、收貨 = received_at。
- [ ] T7 rejected：申請 done → 終端紅點「已拒絕」＋ rejected_at ＋ 原因；不顯示出貨/收貨。
- [ ] T8 cancelled：申請 done → 終端灰點「已取消」；不顯示出貨/收貨。
- [ ] T9 shipped 但 linked_transfer_id 為 null：出貨仍判 done（靠 restock.status），但時間顯示 —（不炸）。

### 狀態徽章
- [ ] T10 轉貨單連結旁顯示 transferStatusLabel（例：已出貨），未知 status fallback 原字串。
- [ ] T11 請購單連結旁顯示 prStatusLabel（例：全部轉單）。
- [ ] T12 無 linked_transfer_id / linked_pr_id 時該列整段不顯示（沿用既有條件）。

### 迴歸
- [ ] T13 明細表（SKU / 品名+規格 / 數量 / 單價 / 小計 / 合計）維持不變。
- [ ] T14 已刪除 line 的 line-through 與「已刪除」標記維持；合計仍排除 cancelled line。
- [ ] T15 換單（restockId 改變）/ 關閉再開，timeline 依新單資料重算，不殘留上一單。
- [ ] T16 載入態不出現新的「載入中」文字（沿用既有；spinner 規範）。

### 型別 / 建置
- [ ] T17 `next build`（admin）通過、無型別錯誤。

> 實機驗證（登入 admin、開 RESTOCK#18 等各狀態單）因沙箱連不到 Supabase 由使用者於 GH Pages preview 自審；
> agent 側以 build/typecheck + 邏輯逐項核對為主。

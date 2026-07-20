# TEST — 補貨 ride-along 單 items 一律鎖現售價

Migration：`20260720000010_restock_ride_along_items_retail_price.sql`
使用者定案（2026-07-20，取代 20260714000090 的「內部單存分店價」舊定案）：
「魚子燒賣分店價180 零售265，訂單上面的單價是呈現零售價格才對」——
補貨 ride-along 單即使掛【內部】xx店，items 單價也一律鎖建單當下現售價。

## 測試項目

### 建單（rpc_create_restock_request）
- [ ] T1 不指定會員（掛【內部】xx店）→ order items 單價 = 當下 prices scope='retail' 最新生效價（RR-126 案例：魚子燒賣分店 180 / 零售 265 → 單價 265、應收 = 265×qty）。
- [ ] T2 指定真會員 → 同樣鎖現售價（原 090 行為不變）。
- [ ] T3 該 SKU 無現售價或現售價 ≤ 0（未設定的髒資料）→ fallback 分店價（不炸、不寫 0）。
- [ ] T4 restock_request_lines 照舊存分店價（總倉↔分店對帳不受影響）；訂單明細頁「分店價」欄（另查 prices scope='branch'）與單價欄並存顯示（265 / 180）。
- [ ] T5 既有行為迴歸：sentinel campaign/channel/item、虛擬 SKU 拒絕、qty 守衛、_jwt_store_ids 自店檢查、內部/指定會員 notes 前綴全保留（基底 20260714000090）。

### 下游不受影響
- [ ] T6 轉手（partial / to_store）：內部單 → 真會員仍在轉手當下重鎖最新現售價；內部 → 內部維持來源價（現在來源已是現售價）。
- [ ] T7 店端對內部單直接取貨 / 儲值金結帳 → 收零售價。

### Backfill
- [ ] T8 存量未完成（pending/confirmed/shipping/ready）ride-along 單 items 全數改為當下現售價；套用當下 prod 掃描約 150 item / 80 張單（RR-126 180→265、RR-100 180→265 等），套用後 mismatch = 0。
- [ ] T9 已完成/部分完成的單不回溯改價。
- [ ] T10 現售價 0 的測試 SKU（RR-70 G00519-22）不被改為 0（price>0 守衛）。

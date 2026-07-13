# TEST — 月結雙價格口徑（成本價＋分店價分開計算）

Migration：
- `20260715000000_settlement_dual_price_basis.sql`（雙口徑欄位與計算）
- `20260715000100_settlement_payable_use_branch_price.sql`（應收改以分店價計）

需求：月結算每筆分錄同時帶「成本價」與「分店價」兩個口徑分開計算；
龍潭為總倉、出給分店的貨跟分店收**分店價**。
公式：
- `cost_amount`（成本口徑）＝ movement.unit_cost 計（自由轉貨以估價計）— 總倉毛利參考
- `branch_amount`（分店價口徑）＝ 同六種分錄、以 `prices scope='branch'` 收貨當下生效價計（自由轉貨仍以估價計）
- `payable_amount` ＝ `branch_amount`（20260715000100 起；confirm 入 store_receivables 的請款金額 = 分店價口徑）

## 測試項目

### 分錄產生（rpc_generate_hq_to_store_settlement）
- [x] T1 hq_inbound：每行 `unit_branch_price` = 收貨當下生效分店價、`branch_amount` = qty × 分店價；`unit_cost`/`line_amount`（成本口徑）與舊版完全一致（迴歸）。
- [x] T2 air_in / air_out：雙口徑鏡像同額（收方正、出方負），總倉淨額兩口徑皆 0。
- [x] T3 free_in / free_out：無真 SKU 可查價 → 兩口徑同用估價（`unit_branch_price`=0、`branch_amount`=±estimated_amount）。
- [x] T4 return_out：兩口徑皆負值沖回；分店價口徑 = −qty × 收貨當下分店價。
- [x] T5 header `cost_amount` = Σ items.line_amount、`branch_amount` = Σ items.branch_amount、`payable_amount` = `branch_amount`（2026-07 線上 14 店全數一致）。
- [ ] T6 分店價改價後收貨 → 取「收貨當下生效」版本，非現行價（prices effective_from/effective_to 落點）。
- [ ] T7 收貨早於首次設分店價的舊資料 → fallback 現行分店價；完全無分店價 → 0（真 SKU 行 `unit_branch_price`=0 可辨識缺價）。
- [x] T8 「無活動 skip」擴成兩口徑皆 0 才 skip；confirmed/settled 不重算（沿用既有行為）。

### 既有資料
- [x] T9 header `cost_amount` 回填 = 舊 `payable_amount`；items 為 append-only 不回填，draft 重跑生成器即補齊。
- [x] T10 回傳 JSON 加 `total_cost_amount` / `total_branch_amount`；`total_amount` 保留（= 成本口徑，向下相容）。

### UI（transfers/settlement）
- [ ] T11 列表：「應付總倉（分店價）」與「成本價口徑（參考）」兩欄並列、footer 各自合計。
- [ ] T12 明細 modal：成本單價/成本小計/分店單價/分店小計四欄；統計卡多「成本價口徑（參考）」「口徑差額（總倉毛利）」；請款以分店小計為準（合計列 rose 強調）。
- [ ] T13 產生結果訊息顯示兩口徑總額。

### UI（finance/receivables/print 對帳單）
- [ ] T14 明細表雙口徑欄位、合計列兩個總額；表頭顯示分店價（應付）＋成本口徑（參考）。
- [ ] T15 補 #524 缺口：free_in/free_out/return_out 類型標籤與自由轉貨行描述正常顯示（先前只認三種 entry_type）。

## 線上驗證（2026-07-13）

`rpc_generate_hq_to_store_settlement('2026-07-01')` 重跑後：

| entry_type | 行數 | 成本口徑 | 分店價口徑 |
|---|---|---|---|
| hq_inbound | 3393 | 1,413,460.53 | 1,617,410.38 |
| air_in / air_out | 1 / 1 | +1,150 / −1,150 | +1,250 / −1,250 |
| free_in / free_out | 17 / 19 | +940 / −940 | +940 / −940 |
| return_out | 7 | −700 | −773 |

14 家店 header 與 items 加總全數一致；真 SKU 行無缺分店價（`unit_branch_price`=0）者。

### 應收切分店價後（20260715000100 套用、2026-05〜07 draft 全數重算）

| 月份 | 店數 | payable（=分店價口徑） | 成本口徑（參考） |
|---|---|---|---|
| 2026-05 | 1 | 0 | 400 |
| 2026-06 | 13 | 1,208,677.50 | 1,047,326.88 |
| 2026-07 | 15 | 1,660,149.68 | 1,450,512.53 |

- 三個月份全數 `payable_amount` = `branch_amount`、header = Σ items（兩口徑）。
- 2026-05 該筆為「測試商品」G00283（從未設分店價）→ 分店價口徑 0、
  payable 0（confirm 擋 ≤ 0，無法誤請款）；屬測試資料非缺陷。
- 切換當下線上無任何 confirmed/settled 月結，無歷史請款受影響。

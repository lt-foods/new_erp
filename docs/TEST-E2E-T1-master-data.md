# TEST-E2E-T1 — 主檔（商品 / SKU / 加盟店 / 會員 / 員工）

**範圍：** products / skus / sku_packs / categories / brands / suppliers / supplier_skus / stores / line_channels / post_templates / members / member_cards / member_line_bindings / audit 4 欄位 / 自動編號規則
**對應 master §：** §1
**對應 fixture seed：** 01-master.sql / 02-base-fixtures.sql
**反向情境：** 主檔本身少（軟刪 status 變更為主）

---

## 既有 docs

| 文件 | 範圍 | 三色 | 動作 |
|---|---|---|---|
| TEST-B3-products-ext.md | 商品擴充欄位 | 🟢 | relink |
| TEST-core-modules.md | 核心 CRUD（products/skus/stores/suppliers）| 🟢 | relink |
| TEST-member-merge-ux.md | 會員合併 UX | 🟡 | 跑 |
| TEST-member-tabs-notifications.md | 會員分頁 + 通知 | 🟡 | 跑 |
| TEST-member-type-guest.md | guest 訪客 member | 🟡 | 跑 |

---

## Gap addendum

### G1.1 categories 3 層樹完整
- [ ] **SQL:** 17 categories: 3 level1 + 9 level2 + 5 level3
- [ ] **SQL:** parent_id 鏈正確
  ```sql
  SELECT level, code, name, (SELECT code FROM categories p WHERE p.id = c.parent_id) AS parent_code
    FROM categories c ORDER BY level, sort_order;
  ```
- [ ] **UI:** 商品建立頁面 category dropdown 應顯示樹狀

### G1.2 sku_packs 多單位
- [ ] **SQL:** P004（香米）/ P008（雞蛋）/ P010（餅乾）有 base + 額外 pack
- [ ] **驗證 is_default_sale 唯一：**
  ```sql
  SELECT sku_id, COUNT(*) FILTER (WHERE is_default_sale) AS default_count
    FROM sku_packs GROUP BY sku_id HAVING COUNT(*) FILTER (WHERE is_default_sale) <> 1;
  -- expect 0 rows (every sku 恰一個 default)
  ```
- [ ] **UI:** /products/SKU-004 顯示「個 / 箱(10)」兩單位

### G1.3 多供應商分配
- [ ] **SQL:** SUP-JP 對 SKU-001/3/6/10 為 is_preferred；SUP-XL 對 SKU-008
- [ ] **UI:** /products 列表能顯示主要供應商欄
- [ ] **UI:** /suppliers/SUP-JP 顯示供應 4 個 SKU

### G1.4 Audit 4 欄位
（詳見 T10 §4，T1 在此 spot-check 主要 8 表）
- [ ] products / skus / stores / members / suppliers / categories / sku_packs / line_channels 4 欄位齊
- [ ] 修改 row 後 updated_at / updated_by 自動更新（trigger touch_updated_at 仍掛）

### G1.5 Member tier + LINE 綁定
- [ ] **SQL:** 4 會員（M-001/2/3/INT-001）tier 對應正確（normal/gold/silver/normal）
- [ ] **SQL:** 3 會員有 member_line_bindings（M-INT-001 沒有，因為 store_internal）
- [ ] **SQL:** customer_line_aliases 4 筆（含 LC-VIP 1 筆）
- [ ] **UI:** /members/M-TEST-002 wallet tab 顯示 4500 + ledger 流水

### G1.6 Multi-channel + post_templates
- [ ] **SQL:** 3 channels (LC-MAIN/VIP/DAILY)、3 templates (DEFAULT/PROMO/CLOSING)
- [ ] **UI:** 開團頁面 channel dropdown 有 3 選項、template dropdown 有 3 選項

### G1.7 Purchase approval thresholds 多級
- [ ] **SQL:** 5 thresholds: 1 global + 2 store + 2 supplier
  ```sql
  SELECT scope, scope_id, threshold_amount, approver_role
    FROM purchase_approval_thresholds ORDER BY scope, scope_id;
  ```
- [ ] **驗證解析邏輯：** PR 走 supplier scope 優先還是 global？（UI/RPC 應有規則）

---

## 反向情境（主檔特性少、僅軟刪 + 狀態變更）

### Soft-delete 會員（GDPR）
- [ ] **RPC:** `rpc_member_gdpr_delete` 應把 status='deleted' + 清 PII
- [ ] **Trigger:** `forbid_member_delete` 攔 hard DELETE
- [ ] **驗證 ripple：**
  - members.status='deleted'
  - phone_enc / email_enc / birthday_enc 清空
  - phone_hash 仍保留（avoid duplicate registration）
  - wallet_balances 不動（保留 audit）

---

## 驗收門檻

- [ ] G1.1 ~ G1.7 全勾
- [ ] 既有 5 docs 各跑完 inline report
- [ ] 結 `TEST-E2E-T1-master-data-report.md` status: passed
- [ ] [TEST-INDEX.md](TEST-INDEX.md) 此軌標 🟢

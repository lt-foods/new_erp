# TEST-E2E-T2 — 候選 → 開團

**範圍：** 候選週曆同步開團 / candidate → draft → finalize / campaign_no 規則 / campaign_audit_log / auto-PR 觸發 / close 自動建新 PR
**對應 master §：** §2 / §4（auto-PR 鏈接）
**對應 fixture seed：** with-campaign.sql（10 campaigns 多狀態）
**反向情境：** campaign cancelled（draft 階段）

---

## 既有 docs

| 文件 | 範圍 | 三色 | 動作 |
|---|---|---|---|
| TEST-candidate-to-draft-and-pricing.md | 候選 → 草稿 + 定價 | 🟡 | 跑 |
| TEST-campaign-finalize.md | finalize 流程 | 🟡 | 跑 |
| TEST-campaign-to-purchase.md | finalize 觸發 PR | 🟡 | 跑 |
| TEST-close-campaign-auto-new-pr.md | close 自動建新 PR | 🟡 | 跑 |

---

## Gap addendum

### G2.1 campaign_no 規則
- [ ] **SQL:** 新建 campaign 的 campaign_no 應符合 `GB{YYYYMMDD}-C{padded6}` 格式
  ```sql
  SELECT campaign_no FROM group_buy_campaigns
   WHERE campaign_no ~ '^GB[0-9]{8}-C[0-9]{6}$';
  ```
- [ ] **memory ref:** `reference_candidate_campaign_linkage.md` substring FROM 13 FOR 6 取 candidate id

### G2.2 跨 channel campaign_channels
- [ ] **SQL:** 既有 10 campaigns 全掛 LC-MAIN
- [ ] **新測：** 開新 campaign 掛 LC-VIP + LC-MAIN（multi-channel）
- [ ] **驗證 cap_qty：** 每 channel 各自的 cap_qty 不互相干擾

### G2.3 候選週曆 → 同步開團（memory project_business_context）
- [ ] **UI:** `/community-candidates/calendar` 推 candidate 到指定週、指定 channel
- [ ] **UI:** finalize 後返回 calendar → 該 slot 應顯示成 'campaign'
- [ ] **SQL:** group_buy_campaigns.matrix_row_order 對齊

### G2.4 Auto-PR 觸發鏈（finalize 觸發）
- [ ] **RPC:** `rpc_finalize_campaign` 應自動 call rpc_create_pr_from_campaigns
- [ ] **SQL:** 新 campaign finalize 後 → 對應 PR 出現 status='draft'
- [ ] **SQL:** PR 內 items 對齊 campaign_items 的 SKU + qty 累計

### G2.5 close 觸發新 PR (TEST-close-campaign-auto-new-pr 對應)
- [ ] **驗證：** campaign close 後若仍有 backorder → auto rollover 到下一個 open campaign

### G2.6 campaign_audit_log
- [ ] **SQL:** 任何 campaign 編輯（item / channel）都應在 campaign_audit_log 留 row
  ```sql
  SELECT entity_type, action, edit_reason FROM campaign_audit_log
   WHERE campaign_id = ? ORDER BY created_at DESC LIMIT 5;
  ```

---

## 反向情境

### Campaign cancel（draft 階段）
- [ ] **SQL:** UPDATE group_buy_campaigns SET status='cancelled' WHERE status='draft'
- [ ] **不可 cancel：** 已有 customer_orders / PR 的 campaign（應 RPC 拒絕、留 status 不動）
- [ ] **驗證：** `rpc_finalize_campaign` 對 cancelled status 應 RAISE

### Campaign expired（自動）
- [ ] **RPC:** `rpc_auto_close_expired_campaigns` 應掃 end_at < NOW + status='open'
- [ ] **驗證：** seed 有 CAMP-006/7/8 狀態為 ordered/receiving/ready，不應被誤標 expired

---

## 驗收門檻

- [ ] G2.1 ~ G2.6 全勾
- [ ] 4 既有 docs 各跑完
- [ ] 結 `TEST-E2E-T2-campaign-report.md` status: passed

---
title: TEST — PR ↔ Campaigns 一致性 invariant
module: Purchase / Schema
status: passed
ran_at: 2026-05-14
verified_by: alex.chen + claude (pg client)
---

# PR ↔ Campaigns 雙向一致性 invariant

## 背景

撿貨工作站 `v_picking_demand_by_po` 用 `purchase_request_campaigns` join 表抓
「PR ↔ campaign」對應、決定要派貨給哪家店。

但歷史上兩支 RPC 都漏寫 join 表、只寫 `purchase_request_items.source_campaign_id`：
- `rpc_create_pr_from_close_date`
- `rpc_append_campaign_to_pr`

導致 `PO2605130062` 收貨 43 件後撿貨工作站完全看不到，需求被分到 3 家店但
demand_qty = 0 / store_id = NULL。

## 修法（已 ship）

| Migration | 動作 |
|---|---|
| `20260614000010` | View 加 fallback 從 `pri.source_campaign_id` / 補 2 支 RPC 寫 join 表 / backfill 歷史 PR |
| `20260614000020` | 加 trigger `trg_pri_sync_campaigns` 自動 sync + `fn_check_pr_campaigns_consistency()` 檢查孤兒 + migration 末尾 self-check |

## Invariant

**任何 `purchase_request_items` row with `source_campaign_id IS NOT NULL`、且 PR 非 cancelled、必須在 `purchase_request_campaigns` 有對應 (pr_id, campaign_id) row。**

## 自動防護機制（雙層）

### 1. DB trigger（被動同步）
`AFTER INSERT OR UPDATE OF source_campaign_id, pr_id ON purchase_request_items`
→ 自動 upsert `purchase_request_campaigns (pr_id, campaign_id, tenant_id)` ON CONFLICT DO NOTHING

任何寫入 `pri` 的 RPC / SQL（含未來新增的）都會自動 sync、無需呼叫端記得。

### 2. View fallback（讀取容錯）
`v_picking_demand_by_po` 的 `po_campaigns` CTE 同時讀兩條路：
- Path A: `purchase_request_campaigns` join 表
- Path B: `purchase_request_items.source_campaign_id`

即使 trigger 因某種原因沒觸發（直接 SQL bulk insert 沒 RETURNING、或外部腳本繞過），view 還是看得到 demand。

## 驗證 SQL

### A. 一致性檢查（核心）

```sql
SELECT COUNT(*) AS orphans FROM fn_check_pr_campaigns_consistency();
-- expect: 0
```

如果 > 0、可以列出細節：

```sql
SELECT * FROM fn_check_pr_campaigns_consistency();
-- 欄位: issue / pr_id / pr_no / pr_status / sku_id / campaign_id / campaign_no
```

### B. Trigger 存在驗證

```sql
SELECT tgname, tgenabled
  FROM pg_trigger
 WHERE tgrelid = 'public.purchase_request_items'::regclass
   AND tgname = 'trg_pri_sync_campaigns';
-- expect: 1 row, tgenabled='O' (Origin/Enabled)
```

### C. Trigger 真的會觸發（模擬）

```sql
BEGIN;
-- 故意刪掉一筆 join row、然後改 pri、看 trigger 補回
DELETE FROM purchase_request_campaigns WHERE pr_id = <某 PR> AND campaign_id = <某 campaign>;
UPDATE purchase_request_items
   SET source_campaign_id = source_campaign_id  -- no-op、只觸發 trigger
 WHERE pr_id = <某 PR> AND source_campaign_id = <某 campaign>;
SELECT * FROM purchase_request_campaigns WHERE pr_id = <某 PR> AND campaign_id = <某 campaign>;
-- expect: trigger 已補回 1 row
ROLLBACK;
```

### D. View 端對 PO2605130062 的 demand 對得上

```sql
SELECT store_name, demand_qty, gr_qty
  FROM v_picking_demand_by_po
 WHERE po_no = 'PO2605130062'
 ORDER BY store_name;
-- expect: 3 rows
-- 松山店 26 / 萬華店 10 / 四號店 7、合計 = qty_ordered (43)
```

## 已驗證（2026-05-14）

| 測項 | 結果 | 證據 |
|---|---|---|
| A. fn_check 回 0 orphans | ✅ PASS | `SELECT COUNT(*) FROM fn_check_pr_campaigns_consistency() = 0` |
| B. Trigger 存在 + enabled | ✅ PASS | `tgname=trg_pri_sync_campaigns, tgenabled=O` |
| C. DELETE join + UPDATE pri → trigger 補回 | ✅ PASS | After test, join row 恢復 `(11, 3)` |
| D. View PO16 demand 對齊 qty_ordered | ✅ PASS | 松山 26 + 萬華 10 + 四號 7 = 43 ✓ |
| E. Migration self-check | ✅ PASS | Migration 末尾 DO block 跑 `fn_check` = 0 才 apply |

## 整合進 E2E

在 E2E master 黃金路徑跑完後加一句檢查：

```sql
SELECT COUNT(*) FROM fn_check_pr_campaigns_consistency();
-- expect: 0
```

如果 > 0、表示有 RPC 或外部腳本沒走 trigger 路徑、需要 review。

建議加進 [TEST-E2E-T4-purchase.md](TEST-E2E-T4-purchase.md) 的 schema integrity 段、
或 [TEST-E2E-T10-security-rls.md](TEST-E2E-T10-security-rls.md) 的 B 系列 schema sweep。

## 未來新 RPC 須知

寫新 RPC 涉及 `purchase_request_items` INSERT 時：
- ✅ **不用** 自己 INSERT `purchase_request_campaigns`、trigger 會做
- ✅ 但 RPC 內如果用 bulk INSERT / COPY、確認 BEFORE/AFTER ROW trigger 會跑（PG 預設都跑、除非 `ALTER TABLE DISABLE TRIGGER`）
- ❌ 別在 RPC 內 `ALTER TABLE ... DISABLE TRIGGER ALL`（會繞過保護）

## 仍待 follow-up（optional）

- UI: 撿貨工作站對 `store_id=NULL` 但 `gr_qty > 0` 的 row 顯示警告 banner（last-line-of-defense、預期不會再發生但 0 成本加防線）
- E2E master report: 把 `fn_check_pr_campaigns_consistency` 加進 B 系列 schema integrity

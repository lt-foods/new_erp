# Deploy Runbook — 訂單流程改造(PR #334 / #335 / #336)

四個 Stage 已全部 merged 進 main,本 runbook 是**資料庫 migration 部署順序**與驗證步驟。

對應 PRs:
- **#334**(merged):Stage 1 PR/PO 正名 + Stage 2 開團 `locked` 狀態
- **#335**(merged):Stage 3 店家可改待確認訂單 qty
- **#336**(merged):Stage 4 PR 建立時自動鎖團 + auto-confirm

---

## ⚠️ 部署順序(必須一次套完,不能中斷)

| # | Migration | 來源 PR | 必要前置 |
|---|-----------|---------|-----------|
| 1 | `20260623000000_campaign_status_locked.sql` | #334 | — |
| 2 | `20260624000000_order_item_qty_edit.sql` | #335 | #1 |
| 3 | `20260625000000_pr_create_lock_campaign_and_orders.sql` | #336 | #1, #2 |

**核心約束**:`20260624` 的 `rpc_update_order_item_qty` 會寫 `customer_order_audit_log.field='qty'`,但 CHECK constraint 是 `20260625` 才擴充 — 中間若有空窗,店家改 qty 會撞 violation。

---

## Pre-deploy 檢查

1. **資料庫狀態**:確認最後一支 migration 是 `20260622000030_search_skus_exclude_discontinued_in_campaign.sql`(或更新 — 但不包含本批的 `20260623+`)
   ```sql
   SELECT version FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 5;
   ```
2. **既有資料健檢**:
   ```sql
   -- 應為 0(沒有 locked campaign 才合理)
   SELECT COUNT(*) FROM group_buy_campaigns WHERE status = 'locked';

   -- 應全為合法值(無遺漏的 status)
   SELECT DISTINCT status FROM group_buy_campaigns;

   -- 既有 audit log field 種類(部署後 + qty / status)
   SELECT DISTINCT field FROM customer_order_audit_log;
   ```
3. **無人在用**:挑離峰時段;CHECK 重建 + RLS policy 重建會有極短的 ACCESS EXCLUSIVE lock。

---

## 部署(一次跑完三支)

```bash
# 確認在正確環境 / branch
git checkout main && git pull
git log --oneline supabase/migrations/2026062*.sql

# 推 migrations
supabase db push
# 或:
# psql $DATABASE_URL -f supabase/migrations/20260623000000_campaign_status_locked.sql
# psql $DATABASE_URL -f supabase/migrations/20260624000000_order_item_qty_edit.sql
# psql $DATABASE_URL -f supabase/migrations/20260625000000_pr_create_lock_campaign_and_orders.sql
```

---

## 部署後驗證

### 1. Migration 都進去了
```sql
SELECT version FROM supabase_migrations.schema_migrations
 WHERE version IN ('20260623000000','20260624000000','20260625000000')
 ORDER BY version;
-- 應為 3 筆
```

### 2. CHECK constraints 已擴充
```sql
-- group_buy_campaigns 含 'locked'
SELECT pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conname = 'group_buy_campaigns_status_check';
-- 預期含 'locked'

-- customer_order_audit_log 含 'qty' 與 'status'
SELECT pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conname = 'customer_order_audit_log_field_check';
-- 預期含 'qty', 'status'
```

### 3. RLS policy 含 locked
```sql
SELECT pg_get_expr(pp.polqual, pp.polrelid)
  FROM pg_policy pp
  JOIN pg_class pc ON pc.oid = pp.polrelid
 WHERE pc.relname = 'group_buy_campaigns'
   AND pp.polname = 'gbc_store_read';
-- 預期 USING 含 'locked'
```

### 4. 新 RPC 存在
```sql
SELECT proname FROM pg_proc
 WHERE proname IN ('rpc_update_order_item_qty','_lock_orders_after_pr_aggregation')
 ORDER BY proname;
-- 應 2 筆
```

### 5. 既有 closed campaigns 不受影響
```sql
-- 部署前後比對:同 campaign id 的 status 不應變動(只有未來新 PR 才會鎖)
SELECT COUNT(*) FROM group_buy_campaigns WHERE status = 'closed';
-- 應與部署前一樣
```

---

## Smoke test(建議在 staging 跑一次)

對應 `docs/TEST-campaign-locked-status.md` 情境 A:

1. 建一個 open campaign,放 2 筆顧客訂單(各 1 個 SKU,qty=3)
2. `rpc_close_campaign(id, op)` → campaign 變 closed,訂單仍 pending
3. **店家改一筆 qty 3 → 5**(用店家 JWT 呼叫 `rpc_update_order_item_qty`)
   - 預期成功,`customer_order_audit_log` 多一筆 `field='qty', before=3, after=5`
4. `rpc_create_pr_from_close_date(close_date, op)`
   - 預期 campaign 變 `locked`、兩筆訂單變 `confirmed`、`confirmed_at` 都有時間戳
   - audit log 各多一筆 `field='status', edit_reason='auto-confirmed by PR #N'`
   - PR items qty 反映改後 = 5 + 3 = 8(或對應 SKU 加總)
5. **再嘗試改 qty**:應跳「訂單狀態為「已確認」,僅「待確認」訂單可改數量。」
6. **嘗試對該 campaign 加單**:應跳「此團狀態為「已鎖定」,僅「開團中」或「已收單」可以加單。」

---

## Rollback

若部署出問題需要回滾(僅在 production 出嚴重 bug 才做),按**逆序**還原:

```sql
-- 1. 退 20260625(復原 lock 邏輯)
--    手動還原:CREATE OR REPLACE FUNCTION 把 rpc_create_pr_from_close_date /
--    rpc_append_campaign_to_pr 還原成 20260614000010 版本(從 git 撈舊版)
--    DROP FUNCTION _lock_orders_after_pr_aggregation(BIGINT[], UUID, BIGINT);
--    退 CHECK:不要,留著 'qty' / 'status' 不會造成損害

-- 2. 退 20260624(復原 qty 編輯)
--    DROP FUNCTION rpc_update_order_item_qty(BIGINT, BIGINT, NUMERIC, UUID, TEXT);
--    rpc_create_customer_orders 還原成 20260426120000 版本(status='open' only)

-- 3. 退 20260623(復原 locked 狀態)
--    UPDATE group_buy_campaigns SET status='closed' WHERE status='locked';
--    -- (若已有 locked 資料,需先決定他們該回到哪個狀態)
--    ALTER TABLE group_buy_campaigns DROP CONSTRAINT group_buy_campaigns_status_check;
--    ALTER TABLE group_buy_campaigns ADD CONSTRAINT group_buy_campaigns_status_check
--      CHECK (status IN ('draft','open','closed','ordered','receiving','ready','completed','cancelled'));
--    -- 還原 RLS / view / RPC 到 Stage 2 前的版本
```

**注意**:回滾後若已有訂單被 auto-confirmed,**不要**自動把它們改回 pending(會破壞稽核連續性);若需要復原狀態,個案手動處理。

---

## 已知限制 / 後續工作

- PR 取消/退回沒有自動解鎖(`rpc_unlock_campaign` 未實作)— 留到下次
- ordered/receiving/ready 狀態目前無 RPC 自動推進 — 留到下次
- `shipping_at` / `ready_at` / `completed_at` 仍未設值(只修了 `confirmed_at`)— 留到下次
- 既有 confirmed orders 的 `confirmed_at` 維持 NULL(沒回填)

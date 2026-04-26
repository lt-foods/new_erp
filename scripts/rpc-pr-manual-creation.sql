-- ============================================================
-- PR 手動建立 — A+B 驗證 SQL
-- 對應 migration: 20260505000000_pr_manual_creation.sql
-- 對應 TEST: docs/TEST-pr-manual-creation.md
--
-- 用法：在 Supabase SQL editor 跑（會建立資料），逐段執行。
--   p_operator 換成自己的 auth.users.id
--   p_campaign_id 換成 closed campaign id
-- ============================================================

-- 1. Schema 驗證：source_type CHECK 應含 'campaign'
SELECT conname, pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'purchase_requests'::regclass
   AND conname = 'purchase_requests_source_type_check';
-- 預期：CHECK (source_type = ANY (ARRAY['manual','close_date','campaign']))

-- 2. Schema 驗證：chk_pr_source_consistency
SELECT pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'purchase_requests'::regclass
   AND conname = 'chk_pr_source_consistency';
-- 預期：含三條 OR：close_date / campaign / manual

-- 3. Schema 驗證：source_campaign_id 欄 + index
\d+ purchase_requests
SELECT indexname FROM pg_indexes
 WHERE tablename = 'purchase_requests' AND indexname = 'idx_pr_campaign';

-- 4. RPC: rpc_create_pr_blank
DO $$
DECLARE v_pr_id BIGINT;
BEGIN
  v_pr_id := public.rpc_create_pr_blank(
    p_operator := '00000000-0000-0000-0000-000000000000'::uuid  -- 換成你的 user id
  );
  RAISE NOTICE 'blank PR id = %', v_pr_id;
END $$;

SELECT id, pr_no, source_type, source_close_date, source_campaign_id, status, total_amount
  FROM purchase_requests
 WHERE source_type = 'manual'
 ORDER BY id DESC LIMIT 3;
-- 預期：source_close_date / source_campaign_id 都 NULL；status='draft'；total_amount=0

SELECT COUNT(*) FROM purchase_request_items
 WHERE pr_id = (SELECT MAX(id) FROM purchase_requests WHERE source_type='manual');
-- 預期：0

-- 5. RPC: rpc_create_pr_from_campaign happy path
-- 換 p_campaign_id 成自己的 closed campaign id
DO $$
DECLARE v_pr_id BIGINT;
BEGIN
  v_pr_id := public.rpc_create_pr_from_campaign(
    p_campaign_id := 1,  -- ← 換成 closed campaign id
    p_operator    := '00000000-0000-0000-0000-000000000000'::uuid
  );
  RAISE NOTICE 'campaign PR id = %', v_pr_id;
END $$;

SELECT id, pr_no, source_type, source_campaign_id, source_close_date, status, total_amount
  FROM purchase_requests
 WHERE source_type = 'campaign'
 ORDER BY id DESC LIMIT 3;
-- 預期：source_type='campaign'、source_campaign_id 已填、source_close_date 從 campaign.end_at 抓

SELECT pri.sku_id, pri.qty_requested, pri.unit_cost, pri.line_subtotal,
       pri.suggested_supplier_id, pri.source_campaign_id,
       pri.retail_price, pri.franchise_price
  FROM purchase_request_items pri
 WHERE pri.pr_id = (SELECT MAX(id) FROM purchase_requests WHERE source_type='campaign');
-- 預期：每行 source_campaign_id = 該 campaign id；line_subtotal = qty * unit_cost

-- 6. 守衛：同 campaign 重複建
DO $$
BEGIN
  PERFORM public.rpc_create_pr_from_campaign(
    p_campaign_id := 1,  -- ← 同上
    p_operator    := '00000000-0000-0000-0000-000000000000'::uuid
  );
  RAISE EXCEPTION 'should have raised: campaign already has PR';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'expected error: %', SQLERRM;
END $$;

-- 7. 守衛：open campaign（先把上一張 cancel 才能重建）
-- UPDATE purchase_requests SET status='cancelled' WHERE id=(...);
-- UPDATE group_buy_campaigns SET status='open' WHERE id=1;
-- 然後跑：
-- DO $$ BEGIN PERFORM public.rpc_create_pr_from_campaign(1, '...'); END $$;
-- 預期：RAISE 'campaign 1 not in closed status (current: open)'

-- 8. 共存性驗證：4/28 已有 close_date PR + 4/28 某 campaign PR
SELECT id, pr_no, source_type, source_close_date, source_campaign_id, status
  FROM purchase_requests
 WHERE source_close_date = '2026-04-28'
   AND status <> 'cancelled'
 ORDER BY source_type;
-- 預期：可同時看到 close_date / campaign 兩種行

-- 9. 列表頁來源欄位
SELECT source_type, COUNT(*) FROM purchase_requests
 WHERE status <> 'cancelled' GROUP BY source_type;
-- 預期：close_date / campaign / manual 三種值都可能出現

-- 10. v_pr_progress 對 campaign / manual PR 不報錯
SELECT pr_id, po_total, po_sent, transfer_total, all_campaigns_finalized
  FROM v_pr_progress
 WHERE pr_id IN (
   SELECT id FROM purchase_requests
    WHERE source_type IN ('campaign','manual') AND status<>'cancelled'
 );
-- 預期：每行都正常返回，campaign_finalized 對 manual=NULL 或 false

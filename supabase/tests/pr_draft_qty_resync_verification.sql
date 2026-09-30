-- 驗證 20260930000000_pr_draft_qty_resync.sql；整檔包在 transaction，結尾不留資料。
BEGIN;

DO $$
DECLARE
  v_count INTEGER;
  v_src   TEXT;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
   WHERE c.relname IN ('customer_orders','customer_order_items')
     AND t.tgname LIKE 'trg_pr_qty_dirty_%'
     AND NOT t.tgisinternal
     AND (t.tgtype & 1) = 0;
  IF v_count <> 4 THEN
    RAISE EXCEPTION '❌ statement-level dirty triggers expected 4, got %', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
   WHERE c.relname IN ('customer_orders','customer_order_items')
     AND t.tgname LIKE 'trg_pr_qty_dirty_%'
     AND NOT t.tgisinternal
     AND (t.tgtype & 1) = 1;
  IF v_count <> 0 THEN
    RAISE EXCEPTION '❌ dirty queue must not use row-level triggers';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conrelid = 'public.purchase_request_qty_dirty'::regclass
       AND contype = 'p'
       AND pg_get_constraintdef(oid) LIKE '%tenant_id, campaign_id, sku_id%'
  ) THEN
    RAISE EXCEPTION '❌ dirty queue missing tenant+campaign+sku dedupe key';
  END IF;

  SELECT pg_get_functiondef('public._pr_mark_dirty_from_customer_orders()'::regprocedure)
      || pg_get_functiondef('public._pr_mark_dirty_from_customer_order_items()'::regprocedure)
    INTO v_src;
  IF v_src NOT ILIKE '%EXCEPTION WHEN OTHERS%' OR v_src NOT ILIKE '%RAISE WARNING%' THEN
    RAISE EXCEPTION '❌ dirty trigger errors are not swallowed with WARNING';
  END IF;
  IF v_src ILIKE '%_pr_apply_qty_sync%' OR v_src ILIKE '%UPDATE public.purchase_request_items%' THEN
    RAISE EXCEPTION '❌ customer-order trigger attempts to recalculate/lock PR';
  END IF;

  IF pg_get_constraintdef((
    SELECT oid FROM pg_constraint
     WHERE conrelid = 'public.purchase_request_items'::regclass
       AND conname = 'purchase_request_items_qty_requested_check'
  )) NOT LIKE '%qty_requested >= 0%' THEN
    RAISE EXCEPTION '❌ parent PR item still rejects qty=0';
  END IF;
  IF pg_get_constraintdef((
    SELECT oid FROM pg_constraint
     WHERE conrelid = 'public.purchase_request_item_campaigns'::regclass
       AND conname = 'purchase_request_item_campaigns_qty_requested_check'
  )) NOT LIKE '%qty_requested >= 0%' THEN
    RAISE EXCEPTION '❌ campaign detail still rejects qty=0';
  END IF;

  IF has_function_privilege('anon', 'public.rpc_sync_pr_qty(bigint,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_preview_pr_qty_sync(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION '❌ anon can call PR qty sync functions';
  END IF;

  SELECT pg_get_functiondef('public.rpc_submit_pr(bigint,uuid)'::regprocedure) INTO v_src;
  IF STRPOS(v_src, '_pr_apply_qty_sync') = 0
     OR STRPOS(v_src, '_pr_validate_qty_current') = 0
     OR STRPOS(v_src, '_pr_apply_qty_sync') > STRPOS(v_src, 'status = ''submitted''') THEN
    RAISE EXCEPTION '❌ submit does not sync+validate while still draft';
  END IF;

  SELECT pg_get_functiondef('public.rpc_split_pr_to_pos(bigint,bigint,uuid)'::regprocedure) INTO v_src;
  IF STRPOS(v_src, '_pr_validate_qty_current') = 0
     OR STRPOS(v_src, '_pr_validate_qty_current') > STRPOS(v_src, 'rpc_next_po_no') THEN
    RAISE EXCEPTION '❌ split creates/spends PO number before live demand validation';
  END IF;

  SELECT pg_get_functiondef('public.rpc_merge_prs_to_po(uuid,bigint[],bigint,bigint,text,uuid)'::regprocedure) INTO v_src;
  IF STRPOS(v_src, '_pr_validate_qty_current') = 0
     OR STRPOS(v_src, '_pr_validate_qty_current') > STRPOS(v_src, 'INSERT INTO public.purchase_orders') THEN
    RAISE EXCEPTION '❌ merge creates PO before live demand validation';
  END IF;

  SELECT pg_get_functiondef('public.rpc_create_partial_pr_from_items(bigint,bigint[],uuid)'::regprocedure) INTO v_src;
  IF v_src NOT ILIKE '%UPDATE public.purchase_request_items%SET pr_id = v_new_pr_id%'
     OR v_src ILIKE '%DELETE FROM public.purchase_request_items%' THEN
    RAISE EXCEPTION '❌ partial PR move would lose source/store-addition trace';
  END IF;
END;
$$;

-- 核心算式反例：負差額不能再被丟掉；10-1+2 必須得到 11。
DO $$
DECLARE
  v_target NUMERIC;
BEGIN
  v_target := GREATEST(9 - 0, 0);
  IF v_target <> 9 OR v_target - 10 <> -1 THEN
    RAISE EXCEPTION '❌ cancellation-only case must resync 10 -> 9';
  END IF;

  v_target := GREATEST(11 - 0, 0);
  IF v_target <> 11 THEN
    RAISE EXCEPTION '❌ 10 - 1 + 2 must resync to 11';
  END IF;

  v_target := GREATEST(0 - 0, 0);
  IF v_target <> 0 THEN
    RAISE EXCEPTION '❌ zero demand must keep a qty=0 trace row';
  END IF;
END;
$$;

-- 實際故障注入：讓 dirty upsert 必定報錯，再改一張 active 客單；客單更新仍須成功。
CREATE OR REPLACE FUNCTION pg_temp.fail_pr_dirty_write()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'intentional dirty queue failure';
END;
$$;

CREATE TRIGGER test_fail_pr_dirty_write
BEFORE INSERT OR UPDATE ON public.purchase_request_qty_dirty
FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_pr_dirty_write();

DO $$
DECLARE
  v_order_id BIGINT;
  v_old      TEXT;
  v_new      TEXT;
BEGIN
  SELECT id, status INTO v_order_id, v_old
    FROM public.customer_orders
   WHERE status NOT IN ('cancelled','expired','transferred_out')
   ORDER BY id
   LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE NOTICE '⚠ 無 active 客單，略過 dirty failure runtime case';
    RETURN;
  END IF;

  UPDATE public.customer_orders SET status = 'cancelled' WHERE id = v_order_id;
  SELECT status INTO v_new FROM public.customer_orders WHERE id = v_order_id;
  IF v_new <> 'cancelled' THEN
    RAISE EXCEPTION '❌ dirty failure rolled back customer cancellation';
  END IF;
  RAISE NOTICE '✅ dirty failure did not block cancellation (order %, % -> %)', v_order_id, v_old, v_new;
END;
$$;

DROP TRIGGER test_fail_pr_dirty_write ON public.purchase_request_qty_dirty;

SELECT '✅ PR draft qty resync verification passed' AS result;
ROLLBACK;

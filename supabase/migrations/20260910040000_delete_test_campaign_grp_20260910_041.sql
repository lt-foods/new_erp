-- ============================================================================
-- 一次性資料清理：刪掉測試團 GRP-20260910-041「…350克+-10%test」
-- ============================================================================
-- 需求（Alex 2026-09-10）：接續 20260910030000 —— 那支把這個誤開的測試團底下
-- 唯一一張客人訂單（美慧-中和／2 件 (B) 職人三杯雞腿丁）搬去正式團
-- GRP-20260910-021 之後，這團已經空了，「然後把第一張圖的團刪掉」。
--
-- 刪除當下的狀態（id 5050，總倉團 owner_store_id IS NULL、status='cancelled'）：
--   customer_orders 0、campaign_items 2（SKU 7120 / 7141，各 $99）、
--   campaign_views 1、其餘 15 張會參照 group_buy_campaigns 的表全部 0 筆
--   —— 沒有撿貨波次、採購單、候補名單、庫存異動、減抵單、社群貼文。
--
-- 走 rpc_delete_campaign（＝後台「刪除」鈕的同一支），不自己抄一份 DELETE：
-- 它知道哪些表要手動清（campaign_audit_log / customer_order_sources 是
-- append-only，得先暫停 BEFORE DELETE 保護；order_waitlist 沒有 CASCADE），
-- 抄一份等於哪天那支加了新表這裡就漏。它自己的兩道守衛（open 不給刪、
-- 有訂單不給刪）本來就擋得住誤刪。
--
-- 它讀 auth.jwt() 判角色（總倉團要 owner/admin/hq_manager/assistant/''），
-- migration 沒有登入身分，所以用 CLAUDE.md 記的那招灌 claims 進去；
-- set_config 第三個參數 true = 只在本交易有效，做完立刻還原，不外洩。
--
-- 守衛：先自己驗一次「這團真的是那一支、真的空了」才呼叫，任一不成立就
--   RAISE 中止 —— 光靠 campaign_no 比對不夠（號碼是手選的，會撞號）。
-- 冪等：團已經不在就直接跳過（NOTICE）。
--
-- Rollback：沒有。實體刪除、不可回復（測試資料，刪掉即為目的）。
--   真要重建：campaign_no 'GRP-20260910-041'、name '中華一番・中式職人料理
--   350克+-10%test'、product_id 3746、status 'cancelled'、is_for_shop true、
--   sales_channel 'main'、start_at 2026-09-10T09:50:13.157685Z、
--   end_at 2026-09-13T15:59:00Z、created_by 39fd694d-…，商品兩列
--   SKU 7120 / 7141 各 $99（sort_order 1 / 2）。id 與 campaign_items.id 不會一樣。
-- ============================================================================

DO $$
DECLARE
  v_tenant CONSTANT UUID := '00000000-0000-0000-0000-000000000001';
  v_no     CONSTANT TEXT := 'GRP-20260910-041';
  v_name   CONSTANT TEXT := '中華一番・中式職人料理 350克+-10%test';
  v_camp   BIGINT;
  v_status TEXT;
  v_oper   UUID;
  v_owner  BIGINT;
  v_cnt    INT;
  v_prev   TEXT;
BEGIN
  SELECT id, status, created_by, owner_store_id
    INTO v_camp, v_status, v_oper, v_owner
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant AND campaign_no = v_no AND name = v_name
   FOR UPDATE;

  IF v_camp IS NULL THEN
    RAISE NOTICE '[skip] 測試團 % 不存在（已刪除，或不是這一支）', v_no;
    RETURN;
  END IF;

  IF v_status = 'open' THEN
    RAISE EXCEPTION '團 % 現在是 open，不刪（rpc 也會擋）', v_no;
  END IF;

  -- 訂單：20260910030000 應該已經全部搬走。還有殘留就是有人又下了單，停手。
  SELECT COUNT(*) INTO v_cnt FROM customer_orders WHERE tenant_id = v_tenant AND campaign_id = v_camp;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 還有 % 張訂單，先搬走再刪', v_no, v_cnt;
  END IF;

  -- 沒有 CASCADE 的參照：真的沾到就不是純測試團，讓 rpc 的 FK 例外之前先講清楚
  SELECT (SELECT COUNT(*) FROM picking_wave_items        WHERE campaign_id = v_camp)
       + (SELECT COUNT(*) FROM purchase_request_campaigns WHERE campaign_id = v_camp)
       + (SELECT COUNT(*) FROM purchase_request_items     WHERE source_campaign_id = v_camp)
       + (SELECT COUNT(*) FROM purchase_requests          WHERE source_campaign_id = v_camp)
       + (SELECT COUNT(*) FROM backorders                 WHERE rollover_to_campaign_id = v_camp)
    INTO v_cnt;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 還被 % 筆撿貨／採購／待補貨紀錄參照，不刪', v_no, v_cnt;
  END IF;

  -- 沾到實體貨或錢就停手（測試團不該有）
  SELECT COUNT(*) INTO v_cnt
    FROM stock_movements WHERE source_doc_type = 'campaign' AND source_doc_id = v_camp;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 有 % 筆庫存異動，刪掉會留下無主庫存，不刪', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM inventory_deduction_notes WHERE campaign_id = v_camp AND cancelled_at IS NULL;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 有 % 張未取消的庫存減抵單，不刪', v_no, v_cnt;
  END IF;

  IF v_owner IS NOT NULL THEN
    RAISE EXCEPTION '團 % 是店家自開團（owner_store_id=%），請走 rpc_delete_store_campaign', v_no, v_owner;
  END IF;

  -- 灌 claims → 呼叫後台那顆「刪除」鈕的同一支 rpc → 還原 claims
  v_prev := current_setting('request.jwt.claims', true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'tenant_id', v_tenant,
      'app_metadata', jsonb_build_object('tenant_id', v_tenant, 'role', 'admin')
    )::TEXT, true);

  PERFORM public.rpc_delete_campaign(v_camp, v_oper);

  PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);

  IF EXISTS (SELECT 1 FROM group_buy_campaigns WHERE id = v_camp) THEN
    RAISE EXCEPTION '團 % 呼叫 rpc_delete_campaign 後仍然存在，中止', v_no;
  END IF;

  RAISE NOTICE '已刪除測試團 %（id %）', v_no, v_camp;
END $$;

-- ============================================================================
-- 驗證腳本：請購草稿「同步最新開團數量」（精簡版）
-- 對應 migration：supabase/migrations/20261001000000_pr_qty_sync_minimal.sql
-- ----------------------------------------------------------------------------
-- ⛔ 只在本機 / 測試庫執行。整份包在交易裡，跑完 ROLLBACK 不留測資。
--
-- 覆蓋（對應實作計畫 §6 九條）：
--   1. 原本 10、取消 1、沒再加單 → 同步後草稿變 9。
--   2. 原本 10、取消 1、再加 2 → 11。
--      ⚠️ 精簡版計畫 §6-2 寫「12（不是 11）」是把極性寫反了。
--      權威來源 `需求暨實作計畫_NEWERP取消訂單同步請購草稿數量_2026-09-30.md`
--      :56「需求是 11，已請購是 10，正差額只有 1，最後變成 11」
--      :203「重算後是 11，不能變 12，也不能重複加」
--      ⇒ 11 才是對的。本測試斷言 11，並額外斷言「不會變成 12」。
--   3. 需求整個歸零 → ⚠️ 不自動改，列為「需人工確認」。
--      ⚠️ 計畫 §4-7／§6-3 寫「該列變 0、列還在」在資料庫層做不到：
--      purchase_request_items.qty_requested（20260422120004:135）與
--      purchase_request_item_campaigns.qty_requested（20260921001000:34）
--      兩欄都有 CHECK (qty_requested > 0)，且從未被任何 migration 拿掉。
--      改成 0 會被 CHECK 擋、刪列會讓 9/23 分店加單紀錄追不回來
--      ⇒ 本版選擇「不動它、標成需人工確認」。
--   4. 同一列合併多個團 → 只動有變化的那個團，父層總數仍等於各團加總。
--   5. 已送審 → rpc 直接擋；已有 PO 的品項 → 跳過並回報需人工確認。
--   6. 同團同 SKU 落在多張可改草稿 → 不猜，兩張都列為需人工確認。
--   7. #982 三個守衛仍然抓得到故意製造的不一致。
--   8. 權限：store_manager 被擋；空角色可用。
--   9. 對照組：故意做壞「只處理正差額」「父層不重算」「寫入順序顛倒」三種版本，
--      測試必須紅（pass 的條件是「壞版本真的被抓出來」）。
-- ============================================================================

BEGIN;

SET LOCAL request.jwt.claim  = '{"tenant_id":"feed0000-0000-4000-8000-000000000031","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}';
SET LOCAL request.jwt.claims = '{"tenant_id":"feed0000-0000-4000-8000-000000000031","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}';

CREATE TEMP TABLE _t_env ON COMMIT DROP AS
SELECT
  'feed0000-0000-4000-8000-000000000031'::UUID AS tenant,
  'feed0000-0000-4000-8000-0000000000fe'::UUID AS operator,
  (CURRENT_DATE - 1)::DATE AS close_date;

CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_result(seq INT, item TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;


-- ----------------------------------------------------------------------------
-- 夾具：一個商品、七個團、五張請購單
--   camp1 需求 9（原本 10 取消 1）      · pr1 草稿 pric=10
--   camp2 需求 11（10 取消 1 再加 2）   · pr2 草稿 pric=10
--   camp3 需求 0（全取消）              · pr3 草稿 pric=5
--   camp4 需求 8（10 取消 2）＋
--   camp5 需求 20（沒變）               · pr4 草稿 一列兩個團 pric 10/20、pri=30
--   camp6 需求 9（10 取消 1）           · pr5 已送審 pric=10
--   camp7 需求 9（10 取消 1）           · pr6/pr7 兩張草稿各 pric=5（共 10）
-- ----------------------------------------------------------------------------
DO $fixture$
DECLARE
  v_tenant   UUID := (SELECT tenant FROM _t_env);
  v_op       UUID := (SELECT operator FROM _t_env);
  v_date     DATE := (SELECT close_date FROM _t_env);
  v_loc      BIGINT;
  v_store    BIGINT;
  v_channel  BIGINT;
  v_supplier BIGINT;
  v_product  BIGINT;
  v_sku      BIGINT;
  v_camp     BIGINT;
  v_ci       BIGINT;
  v_order    BIGINT;
  v_pr       BIGINT;
  v_item     BIGINT;
  v_po       BIGINT;
  v_po_item  BIGINT;
  v_camps    BIGINT[] := ARRAY[]::BIGINT[];
  i          INTEGER;

  -- 每個團的「有效需求」與「取消掉的量」（第 8 個團給「已轉 PO」那張單用）
  v_active   NUMERIC[] := ARRAY[9, 11, 0, 8, 20, 9, 9, 9];
  v_cancel   NUMERIC[] := ARRAY[1,  1, 7, 2,  0, 1, 1, 1];
BEGIN
  INSERT INTO locations (tenant_id, code, name, type)
  VALUES (v_tenant, 'ZZQSYNC-LOC', '【測試】數量同步總倉', 'central_warehouse')
  RETURNING id INTO v_loc;

  INSERT INTO stores (tenant_id, code, name, location_id)
  VALUES (v_tenant, 'ZZQSYNC-STORE', '【測試】數量同步門市', v_loc)
  RETURNING id INTO v_store;

  INSERT INTO line_channels (tenant_id, code, name, home_store_id)
  VALUES (v_tenant, 'ZZQSYNC-CH', '【測試】數量同步頻道', v_store)
  RETURNING id INTO v_channel;

  INSERT INTO suppliers (tenant_id, code, name)
  VALUES (v_tenant, 'ZZQSYNC-SUP', '【測試】數量同步供應商')
  RETURNING id INTO v_supplier;

  INSERT INTO products (tenant_id, product_code, name, status)
  VALUES (v_tenant, 'ZZQSYNC-P', '【測試】栗子地瓜', 'active')
  RETURNING id INTO v_product;

  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
  VALUES (v_tenant, v_product, 'ZZQSYNC-SKU', '1000g', 'active', '【測試】栗子地瓜')
  RETURNING id INTO v_sku;

  INSERT INTO _t_ctx(k, v) VALUES ('sku', v_sku), ('loc', v_loc), ('supplier', v_supplier);

  -- 八個團：每個團一張「活的」訂單 + 一張「已取消」訂單
  FOR i IN 1..8 LOOP
    INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, end_at)
    VALUES (
      v_tenant, 'ZZQSYNC-CAMP-' || i::TEXT, '【測試】同步團 ' || i::TEXT, 'locked',
      ((v_date + TIME '12:00') AT TIME ZONE 'Asia/Taipei')
    )
    RETURNING id INTO v_camp;

    v_camps := v_camps || v_camp;
    INSERT INTO _t_ctx(k, v) VALUES ('camp' || i::TEXT, v_camp);

    INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
    VALUES (v_tenant, v_camp, v_sku, 180)
    RETURNING id INTO v_ci;

    -- 活的需求
    IF v_active[i] > 0 THEN
      INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status)
      VALUES (v_tenant, 'ZZQSYNC-ORD-A' || i::TEXT, v_camp, v_channel, v_store, 'confirmed')
      RETURNING id INTO v_order;

      INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
      VALUES (v_tenant, v_order, v_ci, v_sku, v_active[i], 180, 'pending');
    END IF;

    -- 被取消掉的需求（這一段就是「客人取消訂單」）
    IF v_cancel[i] > 0 THEN
      INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status)
      VALUES (v_tenant, 'ZZQSYNC-ORD-X' || i::TEXT, v_camp, v_channel, v_store, 'cancelled')
      RETURNING id INTO v_order;

      INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
      VALUES (v_tenant, v_order, v_ci, v_sku, v_cancel[i], 180, 'cancelled');
    END IF;
  END LOOP;

  -- ---- pr1 / pr2 / pr3：單團草稿，pric 分別 10 / 10 / 5 ----
  FOR i IN 1..3 LOOP
    INSERT INTO purchase_requests (
      tenant_id, pr_no, source_type, source_close_date, source_location_id,
      status, total_amount, created_by, updated_by
    ) VALUES (
      v_tenant, 'ZZQSYNC-PR-' || i::TEXT, 'close_date', v_date, v_loc,
      'draft', 0, v_op, v_op
    ) RETURNING id INTO v_pr;

    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
    ) VALUES (v_pr, v_sku, CASE WHEN i = 3 THEN 5 ELSE 10 END, v_supplier, 100, v_op, v_op)
    RETURNING id INTO v_item;

    INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
    VALUES (v_item, v_camps[i], v_tenant, CASE WHEN i = 3 THEN 5 ELSE 10 END);

    INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
    VALUES (v_pr, v_camps[i], v_tenant);

    UPDATE purchase_requests pr
       SET total_amount = COALESCE((SELECT SUM(pri.line_subtotal) FROM purchase_request_items pri WHERE pri.pr_id = v_pr), 0)
     WHERE pr.id = v_pr;

    INSERT INTO _t_ctx(k, v) VALUES ('pr' || i::TEXT, v_pr), ('item' || i::TEXT, v_item);
  END LOOP;

  -- ---- pr4：一列合併 camp4 + camp5（10 + 20 = 30）----
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-4', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
  ) VALUES (v_pr, v_sku, 30, v_supplier, 100, v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
  VALUES (v_item, v_camps[4], v_tenant, 10), (v_item, v_camps[5], v_tenant, 20);

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr, v_camps[4], v_tenant), (v_pr, v_camps[5], v_tenant);

  UPDATE purchase_requests pr
     SET total_amount = COALESCE((SELECT SUM(pri.line_subtotal) FROM purchase_request_items pri WHERE pri.pr_id = v_pr), 0)
   WHERE pr.id = v_pr;

  INSERT INTO _t_ctx(k, v) VALUES ('pr4', v_pr), ('item4', v_item);

  -- ---- pr5：已送審（camp6）----
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-5', 'close_date', v_date, v_loc, 'submitted', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
  ) VALUES (v_pr, v_sku, 10, v_supplier, 100, v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
  VALUES (v_item, v_camps[6], v_tenant, 10);

  INSERT INTO _t_ctx(k, v) VALUES ('pr5', v_pr), ('item5', v_item);

  -- ---- pr6 / pr7：同團同 SKU 落在兩張草稿（camp7，各 5，共 10）----
  FOR i IN 6..7 LOOP
    INSERT INTO purchase_requests (
      tenant_id, pr_no, source_type, source_close_date, source_location_id,
      status, total_amount, created_by, updated_by
    ) VALUES (v_tenant, 'ZZQSYNC-PR-' || i::TEXT, 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
    RETURNING id INTO v_pr;

    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
    ) VALUES (v_pr, v_sku, 5, v_supplier, 100, v_op, v_op)
    RETURNING id INTO v_item;

    INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
    VALUES (v_item, v_camps[7], v_tenant, 5);

    INSERT INTO _t_ctx(k, v) VALUES ('pr' || i::TEXT, v_pr), ('item' || i::TEXT, v_item);
  END LOOP;

  -- ---- pr8：草稿，但品項已建立採購單（po_item_id 非空），用 camp1 ----
  INSERT INTO purchase_orders (
    tenant_id, po_no, supplier_id, dest_location_id, status, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PO-1', v_supplier, v_loc, 'sent', v_op, v_op)
  RETURNING id INTO v_po;

  INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by)
  VALUES (v_po, v_sku, 3, 100, v_op, v_op)
  RETURNING id INTO v_po_item;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-8', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  -- 這一列掛 camp8（獨立的團，不干擾其他測試）：
  -- camp8 需求 9、這張單已請購 3 ⇒ 差額 +6 有東西要同步，
  -- 但品項已轉 PO ⇒ 必須被跳過並回報需人工確認。
  -- 用 source_campaign_id（沒有明細列）＝ 順便蓋到舊資料那條 legacy 路徑。
  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, po_item_id,
    source_campaign_id, created_by, updated_by
  ) VALUES (v_pr, v_sku, 3, v_supplier, 100, v_po_item,
            (SELECT v FROM _t_ctx WHERE k = 'camp8'), v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO _t_ctx(k, v) VALUES ('pr8', v_pr), ('item8', v_item), ('po_item', v_po_item);
END
$fixture$;


-- ============================================================================
-- 測 1：原本 10、取消 1、沒有再加單 → 同步後草稿變 9
-- ============================================================================
DO $t1$
DECLARE
  v_pr     BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr1');
  v_item   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item1');
  v_op     UUID   := (SELECT operator FROM _t_env);
  v_res    JSONB;
  v_pric   NUMERIC;
  v_pri    NUMERIC;
  v_total  NUMERIC;
BEGIN
  v_res := public.rpc_sync_pr_qty(v_pr, v_op, gen_random_uuid());

  SELECT qty_requested INTO v_pric
    FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  SELECT qty_requested INTO v_pri
    FROM purchase_request_items WHERE id = v_item;
  SELECT total_amount INTO v_total FROM purchase_requests WHERE id = v_pr;

  INSERT INTO _t_result VALUES (
    1, '取消 1、沒再加單 → 草稿 10 變 9（父層與明細一致、總金額 900）',
    (v_pric = 9 AND v_pri = 9 AND v_total = 900
     AND (v_res ->> 'synced_count')::INT = 1
     AND (v_res ->> 'blocked_count')::INT = 0),
    format('pric=%s, pri=%s, total=%s, res=%s', v_pric, v_pri, v_total, v_res)
  );
END
$t1$;


-- ============================================================================
-- 測 2：原本 10、取消 1、再加 2 → 11（⛔ 不是 12，也不可重複加）
-- ============================================================================
DO $t2$
DECLARE
  v_pr   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr2');
  v_item BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item2');
  v_op   UUID   := (SELECT operator FROM _t_env);
  v_res  JSONB;
  v_pric NUMERIC;
  v_pri  NUMERIC;
  v_again JSONB;
  v_pric2 NUMERIC;
BEGIN
  v_res := public.rpc_sync_pr_qty(v_pr, v_op, gen_random_uuid());

  SELECT qty_requested INTO v_pric FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  SELECT qty_requested INTO v_pri  FROM purchase_request_items WHERE id = v_item;

  -- 連按第二次不可以再加（冪等）
  v_again := public.rpc_sync_pr_qty(v_pr, v_op, gen_random_uuid());
  SELECT qty_requested INTO v_pric2 FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;

  INSERT INTO _t_result VALUES (
    2, '取消 1 再加 2 → 11（不是 12）；再按一次不會重複加',
    (v_pric = 11 AND v_pri = 11 AND v_pric <> 12
     AND v_pric2 = 11
     AND (v_again ->> 'synced_count')::INT = 0),
    format('pric=%s, pri=%s, 再按後 pric=%s, res=%s, again=%s', v_pric, v_pri, v_pric2, v_res, v_again)
  );
END
$t2$;


-- ============================================================================
-- 測 3：需求整個歸零
--   ⚠️ 計畫寫「變 0、列還在」——CHECK (qty_requested > 0) 做不到。
--   本版行為：不動它，列為需人工確認，原因要講清楚。
-- ============================================================================
DO $t3$
DECLARE
  v_pr    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr3');
  v_item  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item3');
  v_op    UUID   := (SELECT operator FROM _t_env);
  v_res   JSONB;
  v_pric  NUMERIC;
  v_pri   NUMERIC;
  v_total NUMERIC;
  v_reason TEXT;
  v_rows  INTEGER;
BEGIN
  SELECT block_reason INTO v_reason
    FROM public._pr_qty_sync_preview(v_pr)
   WHERE pr_item_id = v_item;

  v_res := public.rpc_sync_pr_qty(v_pr, v_op, gen_random_uuid());

  SELECT qty_requested INTO v_pric FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  SELECT qty_requested INTO v_pri  FROM purchase_request_items WHERE id = v_item;
  SELECT total_amount  INTO v_total FROM purchase_requests WHERE id = v_pr;
  SELECT COUNT(*) INTO v_rows FROM purchase_request_items WHERE id = v_item;

  INSERT INTO _t_result VALUES (
    3, '需求歸零 → 不偷改、列還在、標成需人工確認且原因提到不能是 0',
    (v_rows = 1                      -- 列沒有被刪
     AND v_pric = 5 AND v_pri = 5    -- 數字沒被偷改
     AND v_total = 500
     AND (v_res ->> 'synced_count')::INT = 0
     AND (v_res ->> 'blocked_count')::INT = 1
     AND v_reason IS NOT NULL
     AND v_reason LIKE '%0 或負數%'),
    format('pric=%s, pri=%s, total=%s, reason=%s, res=%s', v_pric, v_pri, v_total, v_reason, v_res)
  );
END
$t3$;


-- ============================================================================
-- 測 4：一列合併多個團 → 只動有變化的團，父層總數 = 各團加總
-- ============================================================================
DO $t4$
DECLARE
  v_pr     BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr4');
  v_item   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item4');
  v_camp4  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp4');
  v_camp5  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp5');
  v_op     UUID   := (SELECT operator FROM _t_env);
  v_res    JSONB;
  v_q4     NUMERIC;
  v_q5     NUMERIC;
  v_pri    NUMERIC;
  v_sum    NUMERIC;
  v_total  NUMERIC;
BEGIN
  v_res := public.rpc_sync_pr_qty(v_pr, v_op, gen_random_uuid());

  SELECT qty_requested INTO v_q4
    FROM purchase_request_item_campaigns WHERE pr_item_id = v_item AND campaign_id = v_camp4;
  SELECT qty_requested INTO v_q5
    FROM purchase_request_item_campaigns WHERE pr_item_id = v_item AND campaign_id = v_camp5;
  SELECT qty_requested INTO v_pri FROM purchase_request_items WHERE id = v_item;
  SELECT SUM(qty_requested) INTO v_sum
    FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  SELECT total_amount INTO v_total FROM purchase_requests WHERE id = v_pr;

  INSERT INTO _t_result VALUES (
    4, '合併團：camp4 10→8、camp5 維持 20、父層 28 = 明細加總、總金額 2800',
    (v_q4 = 8 AND v_q5 = 20 AND v_pri = 28 AND v_sum = 28 AND v_pri = v_sum AND v_total = 2800
     AND (v_res ->> 'synced_count')::INT = 1),
    format('camp4=%s, camp5=%s, pri=%s, sum=%s, total=%s, res=%s', v_q4, v_q5, v_pri, v_sum, v_total, v_res)
  );
END
$t4$;


-- ============================================================================
-- 測 5：已送審 → rpc 直接擋；已有 PO 的品項 → 跳過並回報需人工確認
-- ============================================================================
DO $t5$
DECLARE
  v_pr5   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr5');
  v_item5 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item5');
  v_pr8   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr8');
  v_item8 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item8');
  v_op    UUID   := (SELECT operator FROM _t_env);
  v_raised BOOLEAN := FALSE;
  v_q5    NUMERIC;
  v_res8  JSONB;
  v_q8    NUMERIC;
  v_reason8 TEXT;
BEGIN
  -- (a) 已送審的整張單：rpc 要擋，而且一個字都不能改
  BEGIN
    PERFORM public.rpc_sync_pr_qty(v_pr5, v_op, gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    v_raised := TRUE;
  END;
  SELECT qty_requested INTO v_q5
    FROM purchase_request_item_campaigns WHERE pr_item_id = v_item5;

  -- (b) 草稿單但品項已轉 PO：跳過、回報原因、不偷改
  SELECT block_reason INTO v_reason8
    FROM public._pr_qty_sync_preview(v_pr8) WHERE pr_item_id = v_item8;
  v_res8 := public.rpc_sync_pr_qty(v_pr8, v_op, gen_random_uuid());
  SELECT qty_requested INTO v_q8 FROM purchase_request_items WHERE id = v_item8;

  INSERT INTO _t_result VALUES (
    5, '已送審 → rpc 擋且不改；已轉 PO 的品項 → 跳過並回報需人工確認',
    (v_raised AND v_q5 = 10
     AND v_q8 = 3
     AND (v_res8 ->> 'synced_count')::INT = 0
     AND v_reason8 IS NOT NULL
     AND v_reason8 LIKE '%已建立採購單%'),
    format('raised=%s, pr5_pric=%s, pr8_pri=%s, reason8=%s, res8=%s',
           v_raised, v_q5, v_q8, v_reason8, v_res8)
  );
END
$t5$;


-- ============================================================================
-- 測 6：同團同 SKU 落在多張可改草稿 → 不猜，兩張都列為需人工確認
-- ============================================================================
DO $t6$
DECLARE
  v_pr6   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr6');
  v_pr7   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr7');
  v_item6 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item6');
  v_item7 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item7');
  v_op    UUID   := (SELECT operator FROM _t_env);
  v_r6    TEXT;
  v_r7    TEXT;
  v_res6  JSONB;
  v_q6    NUMERIC;
  v_q7    NUMERIC;
BEGIN
  SELECT block_reason INTO v_r6 FROM public._pr_qty_sync_preview(v_pr6) WHERE pr_item_id = v_item6;
  SELECT block_reason INTO v_r7 FROM public._pr_qty_sync_preview(v_pr7) WHERE pr_item_id = v_item7;

  v_res6 := public.rpc_sync_pr_qty(v_pr6, v_op, gen_random_uuid());

  SELECT qty_requested INTO v_q6 FROM purchase_request_item_campaigns WHERE pr_item_id = v_item6;
  SELECT qty_requested INTO v_q7 FROM purchase_request_item_campaigns WHERE pr_item_id = v_item7;

  INSERT INTO _t_result VALUES (
    6, '同團同 SKU 在兩張草稿 → 兩張都標需人工確認，按同步也不動任何一張',
    (v_r6 IS NOT NULL AND v_r6 LIKE '%多張草稿%'
     AND v_r7 IS NOT NULL AND v_r7 LIKE '%多張草稿%'
     AND v_q6 = 5 AND v_q7 = 5
     AND (v_res6 ->> 'synced_count')::INT = 0
     AND (v_res6 ->> 'blocked_count')::INT = 1),
    format('r6=%s, r7=%s, q6=%s, q7=%s, res6=%s', v_r6, v_r7, v_q6, v_q7, v_res6)
  );
END
$t6$;


-- ============================================================================
-- 測 7：#982 三個守衛還在，故意製造的不一致要被抓到
-- ============================================================================
DO $t7$
DECLARE
  v_item1 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item1');
  v_item4 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item4');
  v_camp1 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp1');
  v_g1 BOOLEAN := FALSE;   -- 父層總數 <> 明細加總
  v_g2 BOOLEAN := FALSE;   -- 明細超過目前需求
  v_g3 BOOLEAN := FALSE;   -- 合併列父層亂改
BEGIN
  BEGIN
    UPDATE purchase_request_items SET qty_requested = 99 WHERE id = v_item1;
  EXCEPTION WHEN OTHERS THEN v_g1 := TRUE;
  END;

  BEGIN
    UPDATE purchase_request_item_campaigns
       SET qty_requested = 999
     WHERE pr_item_id = v_item1 AND campaign_id = v_camp1;
  EXCEPTION WHEN OTHERS THEN v_g2 := TRUE;
  END;

  BEGIN
    UPDATE purchase_request_items SET qty_requested = 1 WHERE id = v_item4;
  EXCEPTION WHEN OTHERS THEN v_g3 := TRUE;
  END;

  INSERT INTO _t_result VALUES (
    7, '#982 守衛：父層 <> 明細被擋、明細超過需求被擋、合併列亂改被擋',
    (v_g1 AND v_g2 AND v_g3),
    format('父層不符=%s, 超過需求=%s, 合併列=%s', v_g1, v_g2, v_g3)
  );
END
$t7$;


-- ============================================================================
-- 測 8：權限 —— store_manager 被擋、空角色可用
-- ============================================================================
DO $t8$
DECLARE
  v_pr1   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr1');
  v_blocked BOOLEAN := FALSE;
  v_empty_ok BOOLEAN := FALSE;
  v_staff_blocked BOOLEAN := FALSE;
  v_n INTEGER;
BEGIN
  -- store_manager 要被擋
  PERFORM set_config('request.jwt.claims',
    '{"tenant_id":"feed0000-0000-4000-8000-000000000031","app_metadata":{"role":"store_manager"},"sub":"feed0000-0000-4000-8000-0000000000fe"}',
    TRUE);
  BEGIN
    PERFORM COUNT(*) FROM public.rpc_preview_pr_qty_sync(v_pr1);
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE;
  END;

  -- store_staff 也要被擋
  PERFORM set_config('request.jwt.claims',
    '{"tenant_id":"feed0000-0000-4000-8000-000000000031","app_metadata":{"role":"store_staff"},"sub":"feed0000-0000-4000-8000-0000000000fe"}',
    TRUE);
  BEGIN
    PERFORM COUNT(*) FROM public.rpc_preview_pr_qty_sync(v_pr1);
  EXCEPTION WHEN OTHERS THEN v_staff_blocked := TRUE;
  END;

  -- 空角色（JWT 沒帶 app_metadata.role）要放行
  PERFORM set_config('request.jwt.claims',
    '{"tenant_id":"feed0000-0000-4000-8000-000000000031","app_metadata":{},"sub":"feed0000-0000-4000-8000-0000000000fe"}',
    TRUE);
  BEGIN
    SELECT COUNT(*) INTO v_n FROM public.rpc_preview_pr_qty_sync(v_pr1);
    v_empty_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN v_empty_ok := FALSE;
  END;

  -- 還原成 owner，後面的測試才跑得動
  PERFORM set_config('request.jwt.claims',
    '{"tenant_id":"feed0000-0000-4000-8000-000000000031","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}',
    TRUE);

  INSERT INTO _t_result VALUES (
    8, '權限：store_manager / store_staff 被擋，空角色可用',
    (v_blocked AND v_staff_blocked AND v_empty_ok),
    format('manager擋=%s, staff擋=%s, 空角色可用=%s', v_blocked, v_staff_blocked, v_empty_ok)
  );
END
$t8$;


-- ============================================================================
-- 測 9：對照組 —— 故意做壞三種版本，測試必須紅
--   pass 的條件是「壞版本真的被抓出來」。抓不到就是測試太弱。
-- ============================================================================


-- ---- 9-B：父層不重算 ----
-- 只改明細不改父層，資料就對不起來，而且下一次碰父層一定會被守衛擋。
DO $t9b$
DECLARE
  v_item  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item2');
  v_camp2 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp2');
  v_pri   NUMERIC;
  v_sum   NUMERIC;
  v_inconsistent BOOLEAN;
  v_guard_caught BOOLEAN := FALSE;
BEGIN
  -- 故意只動明細（模擬「父層不重算」的壞版本）：11 → 10
  UPDATE purchase_request_item_campaigns
     SET qty_requested = 10
   WHERE pr_item_id = v_item AND campaign_id = v_camp2;

  SELECT qty_requested INTO v_pri FROM purchase_request_items WHERE id = v_item;
  SELECT SUM(qty_requested) INTO v_sum
    FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  v_inconsistent := (v_pri <> v_sum);

  -- 這種不一致一定要被守衛抓到（就是老闆看到的那句紅字）
  BEGIN
    UPDATE purchase_request_items SET qty_requested = v_pri WHERE id = v_item;
  EXCEPTION WHEN OTHERS THEN v_guard_caught := TRUE;
  END;

  -- 收乾淨，別影響後面
  UPDATE purchase_request_item_campaigns
     SET qty_requested = 11
   WHERE pr_item_id = v_item AND campaign_id = v_camp2;

  INSERT INTO _t_result VALUES (
    902, '對照組 B：只改明細不重算父層 → 資料對不起來，而且守衛一定抓到',
    (v_inconsistent AND v_guard_caught),
    format('pri=%s, 明細加總=%s, 不一致=%s, 守衛抓到=%s', v_pri, v_sum, v_inconsistent, v_guard_caught)
  );
END
$t9b$;

-- ---- 9-C：寫入順序顛倒 ----
-- 先改父層再改明細，會在第一步就被守衛擋掉 ⇒ 證明順序不是可選的。
DO $t9c$
DECLARE
  v_item  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item4');
  v_camp4 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp4');
  v_reversed_failed BOOLEAN := FALSE;
  v_correct_ok BOOLEAN := FALSE;
  v_pri NUMERIC;
BEGIN
  -- 顛倒：先父層（28 → 27）
  BEGIN
    UPDATE purchase_request_items SET qty_requested = 27 WHERE id = v_item;
    UPDATE purchase_request_item_campaigns SET qty_requested = 7
     WHERE pr_item_id = v_item AND campaign_id = v_camp4;
  EXCEPTION WHEN OTHERS THEN v_reversed_failed := TRUE;
  END;

  -- 正確順序：先明細（8 → 7）再父層（28 → 27）
  BEGIN
    UPDATE purchase_request_item_campaigns SET qty_requested = 7
     WHERE pr_item_id = v_item AND campaign_id = v_camp4;
    UPDATE purchase_request_items SET qty_requested = 27 WHERE id = v_item;
    v_correct_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN v_correct_ok := FALSE;
  END;

  SELECT qty_requested INTO v_pri FROM purchase_request_items WHERE id = v_item;

  INSERT INTO _t_result VALUES (
    903, '對照組 C：先父層後明細 → 被守衛擋；先明細後父層 → 通過',
    (v_reversed_failed AND v_correct_ok AND v_pri = 27),
    format('顛倒被擋=%s, 正確順序通過=%s, pri=%s', v_reversed_failed, v_correct_ok, v_pri)
  );
END
$t9c$;


-- ============================================================================
-- 測 10（額外）：§2.1 換掉的 helper，既有呼叫端行為不變
--   負值列必須存在（新能力），但帶 delta_qty > 0 的呼叫端看不到它。
-- ============================================================================
DO $t10$
DECLARE
  v_camp3 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp3');
  v_all  INTEGER;
  v_pos  INTEGER;
  v_demand NUMERIC;
  v_already NUMERIC;
  v_delta  NUMERIC;
BEGIN
  SELECT COUNT(*) INTO v_all
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[v_camp3]);
  SELECT COUNT(*) INTO v_pos
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[v_camp3]) WHERE delta_qty > 0;
  SELECT demand_qty, already_qty, delta_qty INTO v_demand, v_already, v_delta
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[v_camp3]);

  INSERT INTO _t_result VALUES (
    10, 'helper 相容性：需求 0／已請購 5 會回一列 -5，但 delta_qty > 0 的呼叫端看不到',
    (v_all = 1 AND v_pos = 0 AND v_demand = 0 AND v_already = 5 AND v_delta = -5),
    format('列數=%s, 正差額列數=%s, demand=%s, already=%s, delta=%s',
           v_all, v_pos, v_demand, v_already, v_delta)
  );
END
$t10$;


-- ============================================================================
-- 測 9-A（對照組，刻意放最後）：只處理正差額
--   真的把 helper 換回舊版（LEFT JOIN、母體只有需求），跑同一份斷言 → 必須紅。
--   ⚠️ 放最後是刻意的：這樣就**不需要把正確版本再抄一份回來**。
--      抄回來那份會跟 migration 慢慢對不上，變成「假綠」。
--   整份包在 ROLLBACK 裡，壞版本不會留在資料庫。
-- ============================================================================
CREATE OR REPLACE FUNCTION public._pr_campaign_sku_remaining_rows(
  p_campaign_ids BIGINT[]
) RETURNS TABLE(
  campaign_id BIGINT, sku_id BIGINT,
  demand_qty NUMERIC, already_qty NUMERIC, delta_qty NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $broken_a$
  WITH t AS (SELECT public._current_tenant_id() AS tid),
  sel AS (SELECT DISTINCT unnest(p_campaign_ids) AS campaign_id),
  demand AS (
    SELECT co.campaign_id, coi.sku_id, SUM(coi.qty) AS qty
      FROM sel
      JOIN public.customer_orders co ON co.campaign_id = sel.campaign_id
      JOIN public.customer_order_items coi ON coi.order_id = co.id
      CROSS JOIN t
     WHERE co.tenant_id = t.tid
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY co.campaign_id, coi.sku_id
  ),
  already AS (
    SELECT pric.campaign_id, pri.sku_id, SUM(pric.qty_requested) AS qty
      FROM public.purchase_request_item_campaigns pric
      JOIN public.purchase_request_items pri ON pri.id = pric.pr_item_id
      JOIN public.purchase_requests pr ON pr.id = pri.pr_id
      JOIN sel ON sel.campaign_id = pric.campaign_id
      CROSS JOIN t
     WHERE pr.tenant_id = t.tid AND pric.tenant_id = t.tid AND pr.status <> 'cancelled'
     GROUP BY pric.campaign_id, pri.sku_id
  )
  -- ⬇⬇ 這就是被修掉的 bug：LEFT JOIN ⇒ 需求歸零時整列消失
  SELECT d.campaign_id, d.sku_id, d.qty, COALESCE(a.qty, 0),
         d.qty - COALESCE(a.qty, 0)
    FROM demand d
    LEFT JOIN already a ON a.campaign_id = d.campaign_id AND a.sku_id = d.sku_id;
$broken_a$;

DO $t9a$
DECLARE
  v_camp3 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp3');
  v_pr3   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr3');
  v_rows_broken  INTEGER;
  v_needs_broken INTEGER;
BEGIN
  -- camp3：需求 0（全取消）、已請購 5。正確版本回一列 delta = -5。
  SELECT COUNT(*) INTO v_rows_broken
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[v_camp3]);

  SELECT COUNT(*) INTO v_needs_broken
    FROM public._pr_qty_sync_preview(v_pr3) WHERE needs_sync;

  INSERT INTO _t_result VALUES (
    901,
    '對照組 A：裝回「只處理正差額」的舊 helper → 需求歸零的團整列消失、不會被標成待同步（確認測試真的會紅）',
    (v_rows_broken = 0 AND v_needs_broken = 0),
    format('壞版本回傳列數=%s（應為 0，正確版本是 1），待同步筆數=%s（應為 0，正確版本是 1）',
           v_rows_broken, v_needs_broken)
  );
END
$t9a$;


TABLE _t_result ORDER BY seq;

DO $$
DECLARE
  v_bad TEXT;
BEGIN
  SELECT string_agg(seq || ' ' || item || ' :: ' || detail, E'\n')
    INTO v_bad
    FROM _t_result
   WHERE NOT pass OR pass IS NULL;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'pr_qty_sync_minimal_verification failed:%', E'\n' || v_bad;
  END IF;
END $$;

ROLLBACK;

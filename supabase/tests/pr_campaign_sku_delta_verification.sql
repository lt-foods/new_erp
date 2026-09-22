-- ============================================================================
-- 驗證腳本：請購防重第二刀
-- 對應 migration：supabase/migrations/20260921001000_pr_campaign_sku_delta.sql
-- ----------------------------------------------------------------------------
-- 只在本機 / 測試庫執行。整份包在交易裡，跑完 ROLLBACK 不留測資。
--
-- 覆蓋：
--   1. 舊 PR 116，同團最新 153：補單列表只列 +37，不列 153。
--   2. 想再塞同團全量 153，guard 會擋。
--   3. 舊 PR 仍是草稿時，結單日補單直接把舊品項 116 更新成 153。
--   4. 舊 PR 已送出不可改時，針對團購建單才另開差額 PR；
--      多團同 SKU 時，PR item 維持一列 190，
--      但明細保留 B 團 +37、C 團 +153，後續不會再重複列出。
--   5. 多團同 SKU 合併列若仍是草稿，後續追加會更新原草稿列，
--      不會再開第二張差額草稿。
--   6. 已有來源團明細的 PR item，不可手動改成總數與明細不一致。
-- ============================================================================

BEGIN;

SET LOCAL request.jwt.claim  = '{"tenant_id":"feed0000-0000-4000-8000-000000000021","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000ff"}';
SET LOCAL request.jwt.claims = '{"tenant_id":"feed0000-0000-4000-8000-000000000021","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000ff"}';

CREATE TEMP TABLE _t_env ON COMMIT DROP AS
SELECT
  'feed0000-0000-4000-8000-000000000021'::UUID AS tenant,
  'feed0000-0000-4000-8000-0000000000ff'::UUID AS operator,
  (CURRENT_DATE - 4)::DATE AS old_date,
  (CURRENT_DATE - 3)::DATE AS date_a,
  (CURRENT_DATE - 2)::DATE AS date_b,
  (CURRENT_DATE - 1)::DATE AS date_c;

CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_result(seq INT, item TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;

DO $$
DECLARE
  v_tenant   UUID := (SELECT tenant FROM _t_env);
  v_op       UUID := (SELECT operator FROM _t_env);
  v_old_date DATE := (SELECT old_date FROM _t_env);
  v_date_a   DATE := (SELECT date_a FROM _t_env);
  v_date_b   DATE := (SELECT date_b FROM _t_env);
  v_date_c   DATE := (SELECT date_c FROM _t_env);
  v_loc      BIGINT;
  v_store    BIGINT;
  v_channel  BIGINT;
  v_supplier BIGINT;
  v_product  BIGINT;
  v_sku      BIGINT;
  v_camp_a   BIGINT;
  v_camp_b   BIGINT;
  v_camp_c   BIGINT;
  v_campaign BIGINT;
  v_ci       BIGINT;
  v_order    BIGINT;
  v_pr       BIGINT;
  v_pr_a     BIGINT;
  v_pr_b     BIGINT;
BEGIN
  INSERT INTO locations (tenant_id, code, name, type)
  VALUES (v_tenant, 'ZZDELTA-LOC', '【測試】請購防重總倉', 'central_warehouse')
  RETURNING id INTO v_loc;

  INSERT INTO stores (tenant_id, code, name, location_id)
  VALUES (v_tenant, 'ZZDELTA-STORE', '【測試】請購防重門市', v_loc)
  RETURNING id INTO v_store;

  INSERT INTO line_channels (tenant_id, code, name, home_store_id)
  VALUES (v_tenant, 'ZZDELTA-CH', '【測試】請購防重頻道', v_store)
  RETURNING id INTO v_channel;

  INSERT INTO suppliers (tenant_id, code, name)
  VALUES (v_tenant, 'ZZDELTA-SUP', '【測試】請購防重供應商')
  RETURNING id INTO v_supplier;

  INSERT INTO products (tenant_id, product_code, name, status)
  VALUES (v_tenant, 'ZZDELTA-P', '【測試】栗子地瓜', 'active')
  RETURNING id INTO v_product;

  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
  VALUES (v_tenant, v_product, 'ZZDELTA-SKU', '1000g', 'active', '【測試】栗子地瓜')
  RETURNING id INTO v_sku;

  INSERT INTO supplier_skus (tenant_id, supplier_id, sku_id, supplier_sku_code, is_preferred, default_unit_cost)
  VALUES (v_tenant, v_supplier, v_sku, 'ZZDELTA-SUP-SKU', TRUE, 125);

  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, end_at)
  VALUES (v_tenant, 'ZZDELTA-CAMP-A', '【測試】補單團 A', 'locked', ((v_date_a + TIME '12:00') AT TIME ZONE 'Asia/Taipei'))
  RETURNING id INTO v_camp_a;

  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, end_at)
  VALUES (v_tenant, 'ZZDELTA-CAMP-B', '【測試】建單團 B', 'locked', ((v_date_b + TIME '12:00') AT TIME ZONE 'Asia/Taipei'))
  RETURNING id INTO v_camp_b;

  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, end_at)
  VALUES (v_tenant, 'ZZDELTA-CAMP-C', '【測試】不同團 C', 'locked', ((v_date_c + TIME '12:00') AT TIME ZONE 'Asia/Taipei'))
  RETURNING id INTO v_camp_c;

  FOREACH v_campaign IN ARRAY ARRAY[v_camp_a, v_camp_b, v_camp_c]
  LOOP
    INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
    VALUES (v_tenant, v_campaign, v_sku, 180)
    RETURNING id INTO v_ci;

    INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status)
    VALUES (
      v_tenant,
      'ZZDELTA-ORD-' || v_campaign::TEXT,
      v_campaign,
      v_channel,
      v_store,
      CASE WHEN v_campaign = v_camp_a THEN 'pending' ELSE 'confirmed' END
    )
    RETURNING id INTO v_order;

    INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
    VALUES (v_tenant, v_order, v_ci, v_sku, 153, 180, 'pending');
  END LOOP;

  -- A、B 各有舊 PR 116；C 沒有舊 PR，用來驗同 SKU 不同團不互扣。
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZDELTA-PR-A-116', 'close_date', v_old_date, v_loc,
    'draft', 0, v_op, v_op
  ) RETURNING id INTO v_pr;
  v_pr_a := v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
    source_campaign_id, created_by, updated_by
  ) VALUES (v_pr, v_sku, 116, v_supplier, 125, v_camp_a, v_op, v_op);

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZDELTA-PR-B-116', 'close_date', v_old_date, v_loc,
    'submitted', 0, v_op, v_op
  ) RETURNING id INTO v_pr;
  v_pr_b := v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
    source_campaign_id, created_by, updated_by
  ) VALUES (v_pr, v_sku, 116, v_supplier, 125, v_camp_b, v_op, v_op);

  INSERT INTO _t_ctx(k, v) VALUES
    ('loc', v_loc),
    ('store', v_store),
    ('channel', v_channel),
    ('supplier', v_supplier),
    ('sku', v_sku),
    ('pr_a', v_pr_a),
    ('pr_b', v_pr_b),
    ('camp_a', v_camp_a),
    ('camp_b', v_camp_b),
    ('camp_c', v_camp_c);
END $$;

-- 1. 補單列表：A 目前 153、舊 direct PR 116，只能列 +37，不可列 153。
INSERT INTO _t_result(seq, item, pass, detail)
SELECT
  10,
  '補單列表同團改日期只列 +37，不列 153 全量',
  EXISTS (
    SELECT 1 FROM public.rpc_list_supplementable_close_dates() x
     WHERE x.close_date = (SELECT date_a FROM _t_env)
       AND x.remaining_qty = 37
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.rpc_list_supplementable_close_dates() x
     WHERE x.close_date = (SELECT date_a FROM _t_env)
       AND x.remaining_qty = 153
  ),
  COALESCE((
    SELECT 'remaining_qty=' || x.remaining_qty::TEXT
      FROM public.rpc_list_supplementable_close_dates() x
     WHERE x.close_date = (SELECT date_a FROM _t_env)
     LIMIT 1
  ), 'no row');

-- 2. Guard：同團已請 116，再塞全量 153 會變 269 > 153，必須擋。
DO $$
DECLARE
  v_tenant  UUID := (SELECT tenant FROM _t_env);
  v_op      UUID := (SELECT operator FROM _t_env);
  v_pr      BIGINT;
  v_blocked BOOLEAN := FALSE;
  v_detail  TEXT := 'not blocked';
BEGIN
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZDELTA-PR-A-FULL-153', 'close_date', (SELECT date_a FROM _t_env),
    (SELECT v FROM _t_ctx WHERE k = 'loc'), 'draft', 0, v_op, v_op
  ) RETURNING id INTO v_pr;

  BEGIN
    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
      source_campaign_id, created_by, updated_by
    ) VALUES (
      v_pr,
      (SELECT v FROM _t_ctx WHERE k = 'sku'),
      153,
      (SELECT v FROM _t_ctx WHERE k = 'supplier'),
      125,
      (SELECT v FROM _t_ctx WHERE k = 'camp_a'),
      v_op,
      v_op
    );
  EXCEPTION WHEN OTHERS THEN
    v_detail := SQLERRM;
    v_blocked := v_detail LIKE '同一團同商品請購量超過目前需求%';
  END;

  INSERT INTO _t_result(seq, item, pass, detail)
  VALUES (20, 'guard 擋掉同團全量重複請購', v_blocked, v_detail);
END $$;

-- 3. 補單：舊 PR 還是草稿時，不另開 37，直接把舊品項 116 更新成 153。
WITH called AS (
  SELECT public.rpc_create_supplementary_pr_from_close_date(
    (SELECT date_a FROM _t_env),
    (SELECT operator FROM _t_env)
  ) AS pr_id
)
INSERT INTO _t_result(seq, item, pass, detail)
SELECT
  30,
  '結單日補單優先更新舊草稿 116 → 153',
  called.pr_id = (SELECT v FROM _t_ctx WHERE k = 'pr_a')
  AND EXISTS (
    SELECT 1
      FROM purchase_request_items pri
      JOIN purchase_request_item_campaigns pric
        ON pric.pr_item_id = pri.id
     WHERE pri.pr_id = called.pr_id
       AND pri.sku_id = (SELECT v FROM _t_ctx WHERE k = 'sku')
       AND pri.source_campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_a')
       AND pri.qty_requested = 153
       AND pric.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_a')
       AND pric.qty_requested = 153
  )
  AND NOT EXISTS (
    SELECT 1
      FROM purchase_request_items
     WHERE pr_id <> called.pr_id
       AND source_campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_a')
       AND qty_requested = 37
  )
  AND NOT EXISTS (
    SELECT 1
      FROM public._pr_campaign_sku_remaining_rows(ARRAY[
        (SELECT v FROM _t_ctx WHERE k = 'camp_a')
      ]) r
     WHERE r.delta_qty > 0
  ),
  'touched_pr=' || called.pr_id::TEXT
FROM called;

INSERT INTO _t_result(seq, item, pass, detail)
SELECT
  35,
  '已鎖團後追加且只更新舊草稿時也要確認 pending 客單',
  EXISTS (
    SELECT 1
      FROM group_buy_campaigns
     WHERE id = (SELECT v FROM _t_ctx WHERE k = 'camp_a')
       AND status = 'locked'
  )
  AND EXISTS (
    SELECT 1
      FROM customer_orders
     WHERE campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_a')
       AND status = 'confirmed'
  ),
  'campaign_status=' || COALESCE((
    SELECT status
      FROM group_buy_campaigns
     WHERE id = (SELECT v FROM _t_ctx WHERE k = 'camp_a')
  ), '<missing>')
  || ', order_status=' || COALESCE((
    SELECT status
      FROM customer_orders
     WHERE campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_a')
     LIMIT 1
  ), '<missing>');

-- 4. 針對團購建單：B 舊 PR 已送出不可改，所以 B 差額 37 + C 全量 153
--    另開新 PR；同 SKU 合成一列 190；
--    attribution 仍保留各團數量，後續 helper 不會再列出 B/C。
WITH called AS (
  SELECT public.rpc_create_pr_from_campaigns(
    ARRAY[
      (SELECT v FROM _t_ctx WHERE k = 'camp_b'),
      (SELECT v FROM _t_ctx WHERE k = 'camp_c')
    ],
    (SELECT operator FROM _t_env)
  ) AS pr_id
)
INSERT INTO _t_result(seq, item, pass, detail)
SELECT
  40,
  '針對團購建單多團同 SKU 合一列，但來源團明細不丟',
  EXISTS (
    SELECT 1
      FROM purchase_request_items pri
     WHERE pri.pr_id = called.pr_id
       AND pri.sku_id = (SELECT v FROM _t_ctx WHERE k = 'sku')
       AND pri.qty_requested = 190
       AND pri.source_campaign_id IS NULL
  )
  AND EXISTS (
    SELECT 1
      FROM purchase_request_items pri
      JOIN purchase_request_item_campaigns pric
        ON pric.pr_item_id = pri.id
     WHERE pri.pr_id = called.pr_id
       AND pric.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_b')
       AND pric.qty_requested = 37
  )
  AND EXISTS (
    SELECT 1
      FROM purchase_request_items pri
      JOIN purchase_request_item_campaigns pric
        ON pric.pr_item_id = pri.id
     WHERE pri.pr_id = called.pr_id
       AND pric.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_c')
       AND pric.qty_requested = 153
  )
  AND NOT EXISTS (
    SELECT 1
      FROM public._pr_campaign_sku_remaining_rows(ARRAY[
        (SELECT v FROM _t_ctx WHERE k = 'camp_b'),
        (SELECT v FROM _t_ctx WHERE k = 'camp_c')
      ]) r
     WHERE r.delta_qty > 0
  ),
  'new_pr=' || called.pr_id::TEXT
FROM called;

-- 5. 已有來源團明細的合併列，不可直接手改總數造成歸屬失真。
DO $$
DECLARE
  v_item_id BIGINT;
  v_blocked BOOLEAN := FALSE;
BEGIN
  SELECT pri.id
    INTO v_item_id
    FROM purchase_request_items pri
    JOIN purchase_request_item_campaigns pric_b
      ON pric_b.pr_item_id = pri.id
     AND pric_b.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_b')
    JOIN purchase_request_item_campaigns pric_c
      ON pric_c.pr_item_id = pri.id
     AND pric_c.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_c')
   WHERE pri.sku_id = (SELECT v FROM _t_ctx WHERE k = 'sku')
     AND pri.qty_requested = 190
   LIMIT 1;

  BEGIN
    UPDATE purchase_request_items
       SET qty_requested = 250
     WHERE id = v_item_id;
  EXCEPTION WHEN OTHERS THEN
    v_blocked := TRUE;
  END;

  INSERT INTO _t_result(seq, item, pass, detail)
  SELECT
    45,
    '有來源團明細的 PR item 不可手改到總數與明細不同',
    v_blocked
    AND EXISTS (
      SELECT 1
        FROM purchase_request_items
       WHERE id = v_item_id
         AND qty_requested = 190
    ),
    'item=' || COALESCE(v_item_id::TEXT, '<null>') || ', blocked=' || v_blocked::TEXT;
END $$;

-- 6. B/C 同 SKU 已合併成 source_campaign_id=NULL 的草稿列；
--    B 再追加 10 時，仍要更新這張草稿 190 → 200，不可另開 10。
WITH multi_pr AS (
  SELECT pri.pr_id, pri.id AS pr_item_id
    FROM purchase_request_items pri
    JOIN purchase_request_item_campaigns pric_b
      ON pric_b.pr_item_id = pri.id
     AND pric_b.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_b')
    JOIN purchase_request_item_campaigns pric_c
      ON pric_c.pr_item_id = pri.id
     AND pric_c.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_c')
   WHERE pri.sku_id = (SELECT v FROM _t_ctx WHERE k = 'sku')
     AND pri.qty_requested = 190
     AND pri.source_campaign_id IS NULL
   ORDER BY pri.id DESC
   LIMIT 1
),
new_order AS (
  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status
  )
  VALUES (
    (SELECT tenant FROM _t_env),
    'ZZDELTA-ORD-B-EXTRA',
    (SELECT v FROM _t_ctx WHERE k = 'camp_b'),
    (SELECT v FROM _t_ctx WHERE k = 'channel'),
    (SELECT v FROM _t_ctx WHERE k = 'store'),
    'confirmed'
  )
  RETURNING id
),
new_item AS (
  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status
  )
  SELECT
    (SELECT tenant FROM _t_env),
    new_order.id,
    ci.id,
    (SELECT v FROM _t_ctx WHERE k = 'sku'),
    10,
    180,
    'pending'
  FROM new_order
  JOIN campaign_items ci
    ON ci.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_b')
   AND ci.sku_id = (SELECT v FROM _t_ctx WHERE k = 'sku')
  RETURNING id
),
called AS (
  SELECT public.rpc_create_pr_from_campaigns(
    ARRAY[(SELECT v FROM _t_ctx WHERE k = 'camp_b')],
    (SELECT operator FROM _t_env)
  ) AS pr_id
)
INSERT INTO _t_result(seq, item, pass, detail)
SELECT
  50,
  '多團同 SKU 合併草稿後續追加仍更新原草稿列',
  called.pr_id = multi_pr.pr_id
  AND EXISTS (
    SELECT 1
      FROM purchase_request_items pri
     WHERE pri.id = multi_pr.pr_item_id
       AND pri.qty_requested = 200
       AND pri.source_campaign_id IS NULL
  )
  AND EXISTS (
    SELECT 1
      FROM purchase_request_item_campaigns pric
     WHERE pric.pr_item_id = multi_pr.pr_item_id
       AND pric.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_b')
       AND pric.qty_requested = 47
  )
  AND EXISTS (
    SELECT 1
      FROM purchase_request_item_campaigns pric
     WHERE pric.pr_item_id = multi_pr.pr_item_id
       AND pric.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp_c')
       AND pric.qty_requested = 153
  )
  AND NOT EXISTS (
    SELECT 1
      FROM public._pr_campaign_sku_remaining_rows(ARRAY[
        (SELECT v FROM _t_ctx WHERE k = 'camp_b'),
        (SELECT v FROM _t_ctx WHERE k = 'camp_c')
      ]) r
     WHERE r.delta_qty > 0
  ),
  'called_pr=' || called.pr_id::TEXT || ', multi_pr=' || multi_pr.pr_id::TEXT
FROM called, multi_pr;

TABLE _t_result ORDER BY seq;

DO $$
DECLARE
  v_bad TEXT;
BEGIN
  SELECT string_agg(seq || ' ' || item || ' :: ' || detail, E'\n')
    INTO v_bad
    FROM _t_result
   WHERE NOT pass;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'pr_campaign_sku_delta_verification failed:%', E'\n' || v_bad;
  END IF;
END $$;

ROLLBACK;

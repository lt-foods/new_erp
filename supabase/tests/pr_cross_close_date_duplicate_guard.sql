-- ============================================================================
-- Verification: cross-close-date duplicate PR guard
-- Migration: supabase/migrations/20260921000000_pr_cross_close_date_duplicate_guard.sql
-- ----------------------------------------------------------------------------
-- Run only on a local/test database. This file writes synthetic rows inside a
-- transaction and rolls everything back. Do not run it against production.
--
-- Checks:
--   1. Same campaign + same SKU + different close_date PR is blocked.
--   2. Same campaign + same SKU + same close_date PR is still allowed.
--   3. Header-level campaign linkage alone does not block without SKU proof.
--   4. Header link + SKU orders before the link time is blocked.
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _guard_result(
  seq    INT,
  item   TEXT,
  pass   BOOLEAN,
  detail TEXT
) ON COMMIT DROP;

DO $$
DECLARE
  v_tenant UUID := '99999999-0000-4000-8000-000000000001';
  v_user   UUID := '99999999-0000-4000-8000-0000000000ff';
  v_camp   BIGINT;
  v_old_pr BIGINT;
  v_same_pr BIGINT;
  v_new_pr BIGINT;
  v_header_only_old_pr BIGINT;
  v_header_only_new_pr BIGINT;
  v_product BIGINT;
  v_sku_append BIGINT;
  v_store BIGINT;
  v_channel BIGINT;
  v_campaign_item BIGINT;
  v_order BIGINT;
  v_append_old_pr BIGINT;
  v_append_new_pr BIGINT;
  v_msg    TEXT;
BEGIN
  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, status, end_at, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-CAMP', 'ZZTEST PR duplicate guard campaign',
    'closed', TIMESTAMPTZ '2026-09-18 12:00:00+08', v_user, v_user
  ) RETURNING id INTO v_camp;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, status,
    total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-OLD', 'close_date', DATE '2026-09-17',
    'draft', 0, 'old close date PR', v_user, v_user
  ) RETURNING id INTO v_old_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, source_campaign_id, created_by, updated_by
  ) VALUES (
    v_old_pr, 9001001, 116, v_camp, v_user, v_user
  );

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_old_pr, v_camp, v_tenant)
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, status,
    total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-SAME-DATE', 'close_date', DATE '2026-09-17',
    'draft', 0, 'same close date supplement remains allowed', v_user, v_user
  ) RETURNING id INTO v_same_pr;

  BEGIN
    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, source_campaign_id, created_by, updated_by
    ) VALUES (
      v_same_pr, 9001001, 37, v_camp, v_user, v_user
    );

    INSERT INTO _guard_result
    VALUES (1, 'same close_date supplement is allowed', TRUE, 'insert succeeded');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _guard_result
    VALUES (1, 'same close_date supplement is allowed', FALSE, SQLERRM);
  END;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, status,
    total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-NEW', 'close_date', DATE '2026-09-18',
    'draft', 0, 'new close date full PR should be blocked', v_user, v_user
  ) RETURNING id INTO v_new_pr;

  BEGIN
    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, source_campaign_id, created_by, updated_by
    ) VALUES (
      v_new_pr, 9001001, 153, v_camp, v_user, v_user
    );

    INSERT INTO _guard_result
    VALUES (2, 'different close_date duplicate is blocked', FALSE, 'insert unexpectedly succeeded');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _guard_result
    VALUES (
      2,
      'different close_date duplicate is blocked',
      v_msg LIKE '%同一團同商品已在其他結單日請購過%'
        AND v_msg LIKE '%為避免重複請購已停止%'
        AND v_msg LIKE '%請人工確認舊 PR%',
      v_msg
    );
  END;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, status,
    total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-HEADER-OLD', 'close_date', DATE '2026-09-17',
    'draft', 0, 'old PR with header-only campaign link', v_user, v_user
  ) RETURNING id INTO v_header_only_old_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, created_by, updated_by
  ) VALUES (
    v_header_only_old_pr, 9002002, 5, v_user, v_user
  );

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_header_only_old_pr, v_camp, v_tenant)
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, status,
    total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-HEADER-NEW', 'close_date', DATE '2026-09-18',
    'draft', 0, 'new PR should not be blocked by header link only', v_user, v_user
  ) RETURNING id INTO v_header_only_new_pr;

  BEGIN
    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, source_campaign_id, created_by, updated_by
    ) VALUES (
      v_header_only_new_pr, 9002002, 3, v_camp, v_user, v_user
    );

    INSERT INTO _guard_result
    VALUES (3, 'header-only old linkage without SKU proof is allowed', TRUE, 'insert succeeded');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _guard_result
    VALUES (3, 'header-only old linkage without SKU proof is allowed', FALSE, SQLERRM);
  END;

  INSERT INTO products (
    tenant_id, product_code, name, status, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-PROD', 'ZZTEST PR guard product',
    'active', v_user, v_user
  ) RETURNING id INTO v_product;

  INSERT INTO skus (
    tenant_id, product_id, sku_code, variant_name, status,
    product_name, created_by, updated_by
  ) VALUES (
    v_tenant, v_product, 'ZZTEST-PR-GUARD-SKU', 'append path',
    'active', 'ZZTEST PR guard product', v_user, v_user
  ) RETURNING id INTO v_sku_append;

  INSERT INTO stores (
    tenant_id, code, name, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-STORE', 'ZZTEST PR guard store',
    v_user, v_user
  ) RETURNING id INTO v_store;

  INSERT INTO line_channels (
    tenant_id, code, name, home_store_id, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-CH', 'ZZTEST PR guard channel',
    v_store, v_user, v_user
  ) RETURNING id INTO v_channel;

  INSERT INTO campaign_items (
    tenant_id, campaign_id, sku_id, unit_price, created_by, updated_by
  ) VALUES (
    v_tenant, v_camp, v_sku_append, 1, v_user, v_user
  ) RETURNING id INTO v_campaign_item;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, status,
    total_amount, notes, created_by, updated_by, created_at
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-APPEND-OLD', 'close_date', DATE '2026-09-17',
    'draft', 0, 'old PR header existed before append', v_user, v_user,
    TIMESTAMPTZ '2026-09-17 08:00:00+08'
  ) RETURNING id INTO v_append_old_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, created_by, updated_by
  ) VALUES (
    v_append_old_pr, v_sku_append, 7, v_user, v_user
  );

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, pickup_store_id,
    status, created_by, updated_by, created_at
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-ORDER', v_camp, v_channel, v_store,
    'pending', v_user, v_user, TIMESTAMPTZ '2026-09-17 09:00:00+08'
  ) RETURNING id INTO v_order;

  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, created_by, updated_by, created_at
  ) VALUES (
    v_tenant, v_order, v_campaign_item, v_sku_append, 7, 1,
    'pending', v_user, v_user, TIMESTAMPTZ '2026-09-17 09:00:00+08'
  );

  INSERT INTO purchase_request_campaigns (
    pr_id, campaign_id, tenant_id, created_at
  ) VALUES (
    v_append_old_pr, v_camp, v_tenant,
    TIMESTAMPTZ '2026-09-17 10:00:00+08'
  )
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, status,
    total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-GUARD-APPEND-NEW', 'close_date', DATE '2026-09-18',
    'draft', 0, 'new PR should be blocked by appended old PR link', v_user, v_user
  ) RETURNING id INTO v_append_new_pr;

  BEGIN
    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, source_campaign_id, created_by, updated_by
    ) VALUES (
      v_append_new_pr, v_sku_append, 9, v_camp, v_user, v_user
    );

    INSERT INTO _guard_result
    VALUES (4, 'append existing-SKU header link with SKU proof is blocked', FALSE, 'insert unexpectedly succeeded');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _guard_result
    VALUES (
      4,
      'append existing-SKU header link with SKU proof is blocked',
      v_msg LIKE '%同一團同商品已在其他結單日請購過%'
        AND v_msg LIKE '%為避免重複請購已停止%'
        AND v_msg LIKE '%請人工確認舊 PR%',
      v_msg
    );
  END;
END;
$$;

SELECT
  seq,
  CASE WHEN pass THEN 'PASS' ELSE 'FAIL' END AS result,
  item,
  detail
FROM _guard_result
ORDER BY seq;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM _guard_result WHERE NOT pass) THEN
    RAISE EXCEPTION 'pr_cross_close_date_duplicate_guard verification failed';
  END IF;
END;
$$;

ROLLBACK;

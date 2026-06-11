-- ============================================================
-- TEST: pr-delete（docs/TEST-pr-delete.md §2）
-- 前置（由 runner 先跑）：auth stub + _current_tenant_id stub + 精簡 schema
--   （精確複製關鍵約束：items/campaigns join 的 ON DELETE CASCADE、
--    group_buy_campaigns.status CHECK 含 locked/closed、restock linked_pr_id 無 CASCADE）
--   + 灌 20260706000000_rpc_delete_pr.sql
-- 本檔：BEGIN → fixtures → 各案 → 輸出 → ROLLBACK（不留資料）。
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- admin + tenant 身份（rpc_delete_pr 讀 auth.jwt() app_metadata）
SELECT set_config('request.jwt.claims',
  '{"app_metadata":{"role":"admin","tenant_id":"a0000000-0000-4000-8000-0000000000aa"}}', true);

CREATE TEMP TABLE _r (seq SERIAL, test TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;

DO $$
DECLARE
  c_tenant CONSTANT UUID := 'a0000000-0000-4000-8000-0000000000aa';
  c_op     CONSTANT UUID := 'b0000000-0000-4000-8000-0000000000bb';
  v_camp1 BIGINT; v_camp2 BIGINT; v_camp_other BIGINT;
  v_pr BIGINT; v_pr2 BIGINT; v_po BIGINT; v_poi BIGINT;
  v_exists INT; v_st TEXT; v_orders INT;
BEGIN
  -- ============ 2.1 draft 可刪 + items CASCADE ============
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T1', 'draft', 'manual', c_op) RETURNING id INTO v_pr;
  INSERT INTO purchase_request_items (pr_id, sku_id, qty_requested, created_by)
  VALUES (v_pr, 1, 5, c_op), (v_pr, 2, 3, c_op);

  PERFORM rpc_delete_pr(v_pr, c_op);
  SELECT COUNT(*) INTO v_exists FROM purchase_requests WHERE id = v_pr;
  SELECT COUNT(*) INTO v_orders FROM purchase_request_items WHERE pr_id = v_pr;
  INSERT INTO _r(test,pass,detail) VALUES
    ('2.1 draft 刪除成功 + items CASCADE', v_exists = 0 AND v_orders = 0,
     'pr_left=' || v_exists || ' items_left=' || v_orders);

  -- ============ 2.2 submitted 可刪 ============
  INSERT INTO purchase_requests (tenant_id, pr_no, status, review_status, source_type, created_by)
  VALUES (c_tenant, 'PR-T2', 'submitted', 'pending_review', 'manual', c_op) RETURNING id INTO v_pr;
  PERFORM rpc_delete_pr(v_pr, c_op);
  SELECT COUNT(*) INTO v_exists FROM purchase_requests WHERE id = v_pr;
  INSERT INTO _r(test,pass,detail) VALUES ('2.2 submitted 可刪', v_exists = 0, 'left=' || v_exists);

  -- ============ 2.3 cancelled 可刪 ============
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T3', 'cancelled', 'manual', c_op) RETURNING id INTO v_pr;
  PERFORM rpc_delete_pr(v_pr, c_op);
  SELECT COUNT(*) INTO v_exists FROM purchase_requests WHERE id = v_pr;
  INSERT INTO _r(test,pass,detail) VALUES ('2.3 cancelled 可刪', v_exists = 0, 'left=' || v_exists);

  -- ============ 2.4 已拆 PO（status 守門）擋 ============
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T4', 'partially_ordered', 'manual', c_op) RETURNING id INTO v_pr;
  BEGIN
    PERFORM rpc_delete_pr(v_pr, c_op);
    INSERT INTO _r(test,pass,detail) VALUES ('2.4 partially_ordered 擋', FALSE, '未擋');
  EXCEPTION WHEN OTHERS THEN
    SELECT COUNT(*) INTO v_exists FROM purchase_requests WHERE id = v_pr;
    INSERT INTO _r(test,pass,detail) VALUES
      ('2.4 partially_ordered 擋 + PR 留存', SQLERRM LIKE '%已拆採購單%' AND v_exists = 1, SQLERRM);
  END;

  -- ============ 2.5 po_item_id 雙重保險（draft 但 item 連到 PO item）============
  INSERT INTO purchase_orders (tenant_id) VALUES (c_tenant) RETURNING id INTO v_po;
  INSERT INTO purchase_order_items (po_id) VALUES (v_po) RETURNING id INTO v_poi;
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T5', 'draft', 'manual', c_op) RETURNING id INTO v_pr;
  INSERT INTO purchase_request_items (pr_id, sku_id, qty_requested, po_item_id, created_by)
  VALUES (v_pr, 1, 5, v_poi, c_op);
  BEGIN
    PERFORM rpc_delete_pr(v_pr, c_op);
    INSERT INTO _r(test,pass,detail) VALUES ('2.5 po_item_id 雙重保險擋', FALSE, '未擋');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _r(test,pass,detail) VALUES
      ('2.5 po_item_id 雙重保險擋', SQLERRM LIKE '%已有品項拆成採購單%', SQLERRM);
  END;

  -- ============ 2.6 解鎖團 locked→closed + 訂單不動 ============
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, status, updated_by)
  VALUES (c_tenant, 'GB-L1', 'locked', c_op) RETURNING id INTO v_camp1;
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, status, updated_by)
  VALUES (c_tenant, 'GB-L2', 'locked', c_op) RETURNING id INTO v_camp2;
  INSERT INTO customer_orders (tenant_id, campaign_id, status) VALUES
    (c_tenant, v_camp1, 'confirmed'), (c_tenant, v_camp2, 'confirmed');
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, source_close_date, created_by)
  VALUES (c_tenant, 'PR-T6', 'draft', 'close_date', DATE '2026-07-01', c_op) RETURNING id INTO v_pr;
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id) VALUES
    (v_pr, v_camp1, c_tenant), (v_pr, v_camp2, c_tenant);

  PERFORM rpc_delete_pr(v_pr, c_op);
  SELECT COUNT(*) INTO v_exists FROM group_buy_campaigns
    WHERE id IN (v_camp1, v_camp2) AND status = 'closed';
  SELECT COUNT(*) INTO v_orders FROM customer_orders
    WHERE campaign_id IN (v_camp1, v_camp2) AND status = 'confirmed';
  INSERT INTO _r(test,pass,detail) VALUES
    ('2.6 兩團解鎖 closed + 訂單維持 confirmed', v_exists = 2 AND v_orders = 2,
     'closed=' || v_exists || ' confirmed_orders=' || v_orders);

  -- ============ 2.7 只動 locked、不誤傷其他狀態 ============
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, status, updated_by)
  VALUES (c_tenant, 'GB-L3', 'locked', c_op) RETURNING id INTO v_camp1;
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, status, updated_by)
  VALUES (c_tenant, 'GB-R1', 'receiving', c_op) RETURNING id INTO v_camp_other;
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T7', 'draft', 'campaign', c_op) RETURNING id INTO v_pr;
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id) VALUES
    (v_pr, v_camp1, c_tenant), (v_pr, v_camp_other, c_tenant);
  PERFORM rpc_delete_pr(v_pr, c_op);
  SELECT status INTO v_st FROM group_buy_campaigns WHERE id = v_camp_other;
  SELECT status INTO v_st FROM group_buy_campaigns WHERE id = v_camp1;
  INSERT INTO _r(test,pass,detail) VALUES
    ('2.7 locked→closed、receiving 不動',
     (SELECT status FROM group_buy_campaigns WHERE id=v_camp1)='closed'
       AND (SELECT status FROM group_buy_campaigns WHERE id=v_camp_other)='receiving',
     'L3=' || (SELECT status FROM group_buy_campaigns WHERE id=v_camp1)
       || ' R1=' || (SELECT status FROM group_buy_campaigns WHERE id=v_camp_other));

  -- ============ 2.8 manual/blank（無關聯）直接刪 ============
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T8', 'draft', 'manual', c_op) RETURNING id INTO v_pr;
  PERFORM rpc_delete_pr(v_pr, c_op);
  INSERT INTO _r(test,pass,detail) VALUES
    ('2.8 manual 無關聯直接刪', (SELECT COUNT(*) FROM purchase_requests WHERE id=v_pr)=0, 'ok');

  -- ============ 2.9 source_campaign_id（非 join 表）也解鎖 ============
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, status, updated_by)
  VALUES (c_tenant, 'GB-SC', 'locked', c_op) RETURNING id INTO v_camp1;
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, source_campaign_id, created_by)
  VALUES (c_tenant, 'PR-T9', 'draft', 'campaign', v_camp1, c_op) RETURNING id INTO v_pr;
  -- 故意不寫 join 表，只靠 source_campaign_id
  PERFORM rpc_delete_pr(v_pr, c_op);
  INSERT INTO _r(test,pass,detail) VALUES
    ('2.9 source_campaign_id 解鎖', (SELECT status FROM group_buy_campaigns WHERE id=v_camp1)='closed',
     'status=' || (SELECT status FROM group_buy_campaigns WHERE id=v_camp1));

  -- ============ 2.10 restock 來源 PR 擋 ============
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T10', 'submitted', 'manual', c_op) RETURNING id INTO v_pr;
  INSERT INTO restock_requests (tenant_id, linked_pr_id) VALUES (c_tenant, v_pr);
  BEGIN
    PERFORM rpc_delete_pr(v_pr, c_op);
    INSERT INTO _r(test,pass,detail) VALUES ('2.10 restock 來源擋', FALSE, '未擋');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _r(test,pass,detail) VALUES
      ('2.10 restock 來源擋', SQLERRM LIKE '%補貨%' AND (SELECT COUNT(*) FROM purchase_requests WHERE id=v_pr)=1, SQLERRM);
  END;

  -- ============ 2.11 not found ============
  BEGIN
    PERFORM rpc_delete_pr(999999, c_op);
    INSERT INTO _r(test,pass,detail) VALUES ('2.11 not found 擋', FALSE, '未擋');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _r(test,pass,detail) VALUES ('2.11 not found 擋', SQLERRM LIKE '%找不到請購單%', SQLERRM);
  END;

  -- ============ 2.13 殘留無 CASCADE 參照 → 可讀訊息 ============
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T13', 'draft', 'manual', c_op) RETURNING id INTO v_pr;
  INSERT INTO dummy_ref (pr_id) VALUES (v_pr);  -- 無 ON DELETE CASCADE 的殘參照
  BEGIN
    PERFORM rpc_delete_pr(v_pr, c_op);
    INSERT INTO _r(test,pass,detail) VALUES ('2.13 殘參照可讀訊息', FALSE, '未擋');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _r(test,pass,detail) VALUES
      ('2.13 殘參照→可讀中文訊息', SQLERRM LIKE '%仍被其他紀錄參照%', SQLERRM);
  END;
END $$;

-- ============ 2.12 role 守門（切 store_staff 身份）============
SELECT set_config('request.jwt.claims',
  '{"app_metadata":{"role":"store_staff","tenant_id":"a0000000-0000-4000-8000-0000000000aa"}}', true);
DO $$
DECLARE c_tenant CONSTANT UUID := 'a0000000-0000-4000-8000-0000000000aa';
        c_op CONSTANT UUID := 'b0000000-0000-4000-8000-0000000000bb'; v_pr BIGINT;
BEGIN
  INSERT INTO purchase_requests (tenant_id, pr_no, status, source_type, created_by)
  VALUES (c_tenant, 'PR-T12', 'draft', 'manual', c_op) RETURNING id INTO v_pr;
  BEGIN
    PERFORM rpc_delete_pr(v_pr, c_op);
    INSERT INTO _r(test,pass,detail) VALUES ('2.12 role 守門擋 store_staff', FALSE, '未擋');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _r(test,pass,detail) VALUES
      ('2.12 role 守門擋 store_staff', SQLERRM LIKE '%權限不足%' AND (SELECT COUNT(*) FROM purchase_requests WHERE id=v_pr)=1, SQLERRM);
  END;
END $$;

SELECT CASE WHEN pass THEN 'PASS' ELSE '*** FAIL ***' END AS result, test, LEFT(detail,150) AS detail
  FROM _r ORDER BY seq;
SELECT COUNT(*) FILTER (WHERE pass) || ' / ' || COUNT(*) AS passed FROM _r;

ROLLBACK;

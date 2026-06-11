-- ============================================================
-- TEST: dispatch-price-guard（docs/TEST-dispatch-price-guard.md §1/§2）
-- 用法：docker exec -i supabase_db_xxx psql -U postgres -d postgres -f - < this
-- 自帶 fixture、全程單一交易、結尾 ROLLBACK — 不留任何資料。
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE _t (seq SERIAL, test TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;

-- §1.2 rpc_outbound 只剩一個 10 參數版
INSERT INTO _t (test, pass, detail)
SELECT '1.2 rpc_outbound 單一 overload、10 參數',
       COUNT(*) = 1 AND MAX(pronargs) = 10,
       string_agg(pronargs::TEXT, ',')
  FROM pg_proc WHERE proname = 'rpc_outbound';

-- §1.3 三支出倉 RPC 都含守衛
INSERT INTO _t (test, pass, detail)
SELECT '1.3 三支出倉 RPC prosrc 含 _missing_dispatch_prices',
       COUNT(*) = 3, string_agg(proname, ',')
  FROM pg_proc
 WHERE proname IN ('generate_transfer_from_wave','rpc_ship_restock_pr_received','rpc_transfer_distribute_batch')
   AND prosrc LIKE '%_missing_dispatch_prices%';

DO $$
DECLARE
  c_tenant   CONSTANT UUID := 'a0000000-0000-4000-8000-00000000aaaa';
  c_op       CONSTANT UUID := 'b0000000-0000-4000-8000-00000000bbbb';
  v_hq_loc   BIGINT; v_s1_loc BIGINT; v_s2_loc BIGINT;
  v_st1      BIGINT; v_st2 BIGINT;
  v_prod     BIGINT; v_prod_v BIGINT;
  v_sku_np   BIGINT;  -- 無任何價
  v_sku_co   BIGINT;  -- 只有成本價
  v_sku_z    BIGINT;  -- 兩價都存在但 price=0
  v_sku_ok   BIGINT;  -- 兩價齊全、HQ avg_cost=0（fallback 案例）
  v_sku_avg  BIGINT;  -- 兩價齊全、HQ avg_cost=7
  v_sku_v    BIGINT;  -- 虛擬
  v_wave     BIGINT;
  v_msg      TEXT;
  v_res      JSONB;
  v_xa BIGINT; v_xb BIGINT; v_xc BIGINT;
  v_cost_np NUMERIC; v_cost_ok NUMERIC; v_cost_avg NUMERIC;
  v_status TEXT; v_cnt INT;
BEGIN
  -- ---------- fixtures ----------
  INSERT INTO locations (tenant_id, code, name, type) VALUES
    (c_tenant, 'TG-WH',  '守衛測試總倉', 'central_warehouse') RETURNING id INTO v_hq_loc;
  INSERT INTO locations (tenant_id, code, name, type) VALUES
    (c_tenant, 'TG-S1', '守衛測試店一', 'store') RETURNING id INTO v_s1_loc;
  INSERT INTO locations (tenant_id, code, name, type) VALUES
    (c_tenant, 'TG-S2', '守衛測試店二', 'store') RETURNING id INTO v_s2_loc;

  INSERT INTO stores (tenant_id, code, name, location_id)
  VALUES (c_tenant, 'TG-ST1', '守衛測試店一', v_s1_loc) RETURNING id INTO v_st1;
  INSERT INTO stores (tenant_id, code, name, location_id)
  VALUES (c_tenant, 'TG-ST2', '守衛測試店二', v_s2_loc) RETURNING id INTO v_st2;

  INSERT INTO products (tenant_id, product_code, name, status)
  VALUES (c_tenant, 'TG-P1', '守衛測試商品', 'active') RETURNING id INTO v_prod;
  INSERT INTO products (tenant_id, product_code, name, status, is_virtual)
  VALUES (c_tenant, 'TG-PV', '守衛測試虛擬商品', 'active', TRUE) RETURNING id INTO v_prod_v;

  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name) VALUES
    (c_tenant, v_prod,   'TG-NP',  '無價',   'active', '守衛測試商品') RETURNING id INTO v_sku_np;
  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name) VALUES
    (c_tenant, v_prod,   'TG-CO',  '只有成本', 'active', '守衛測試商品') RETURNING id INTO v_sku_co;
  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name) VALUES
    (c_tenant, v_prod,   'TG-Z',   '零元價', 'active', '守衛測試商品') RETURNING id INTO v_sku_z;
  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name) VALUES
    (c_tenant, v_prod,   'TG-OK',  '齊全0avg', 'active', '守衛測試商品') RETURNING id INTO v_sku_ok;
  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name) VALUES
    (c_tenant, v_prod,   'TG-AVG', '齊全有avg', 'active', '守衛測試商品') RETURNING id INTO v_sku_avg;
  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name) VALUES
    (c_tenant, v_prod_v, 'TG-V',   '虛擬',   'active', '守衛測試虛擬商品') RETURNING id INTO v_sku_v;

  -- 價格：CO 只有 cost；Z 兩種都 0；OK/AVG 齊全
  INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price, created_by) VALUES
    (c_tenant, v_sku_co,  'cost',   NULL, 50, c_op),
    (c_tenant, v_sku_z,   'cost',   NULL,  0, c_op),
    (c_tenant, v_sku_z,   'branch', NULL,  0, c_op),
    (c_tenant, v_sku_ok,  'cost',   NULL, 50, c_op),
    (c_tenant, v_sku_ok,  'branch', NULL, 60, c_op),
    (c_tenant, v_sku_avg, 'cost',   NULL, 50, c_op),
    (c_tenant, v_sku_avg, 'branch', NULL, 60, c_op);

  -- HQ 庫存：NP/OK avg_cost=0（0 成本入庫情境）、AVG avg_cost=7；S1 給 CO 庫存（店間轉貨用）
  INSERT INTO stock_balances (tenant_id, location_id, sku_id, on_hand, avg_cost) VALUES
    (c_tenant, v_hq_loc, v_sku_np,  100, 0),
    (c_tenant, v_hq_loc, v_sku_co,  100, 0),
    (c_tenant, v_hq_loc, v_sku_ok,  100, 0),
    (c_tenant, v_hq_loc, v_sku_avg, 100, 7),
    (c_tenant, v_s1_loc, v_sku_co,   10, 0);

  -- ---------- §2 helper 單元 ----------
  v_msg := public._missing_dispatch_prices(c_tenant, ARRAY[v_sku_np]);
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.1h 無價 SKU → 缺兩種', v_msg LIKE '%缺成本價%' AND v_msg LIKE '%缺分店價%' AND v_msg LIKE '%TG-NP%', v_msg);

  v_msg := public._missing_dispatch_prices(c_tenant, ARRAY[v_sku_co]);
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.2h 只有成本 → 只缺分店價', v_msg LIKE '%缺分店價%' AND v_msg NOT LIKE '%缺成本價%', v_msg);

  v_msg := public._missing_dispatch_prices(c_tenant, ARRAY[v_sku_z]);
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.3h 價格=0 視同缺', v_msg LIKE '%缺成本價%' AND v_msg LIKE '%缺分店價%', v_msg);

  v_msg := public._missing_dispatch_prices(c_tenant, ARRAY[v_sku_ok, v_sku_avg]);
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.4h 兩價齊全 → NULL', v_msg IS NULL, COALESCE(v_msg, '(null)'));

  v_msg := public._missing_dispatch_prices(c_tenant, ARRAY[v_sku_v]);
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.9h 虛擬 SKU 跳過 → NULL', v_msg IS NULL, COALESCE(v_msg, '(null)'));

  v_msg := public._missing_dispatch_prices(c_tenant, ARRAY[v_sku_np, v_sku_co, v_sku_ok]);
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.11h 一次列出全部缺價 SKU', v_msg LIKE '%TG-NP%' AND v_msg LIKE '%TG-CO%' AND v_msg NOT LIKE '%TG-OK%', v_msg);

  -- ---------- §2 wave 派貨守衛 ----------
  INSERT INTO picking_waves (tenant_id, wave_code, wave_date, status, created_by)
  VALUES (c_tenant, 'TG-W1', CURRENT_DATE, 'picked', c_op) RETURNING id INTO v_wave;
  INSERT INTO picking_wave_items (tenant_id, wave_id, sku_id, store_id, qty, picked_qty, created_by) VALUES
    (c_tenant, v_wave, v_sku_np,  v_st1, 3, 3, c_op),
    (c_tenant, v_wave, v_sku_ok,  v_st1, 2, 2, c_op),
    (c_tenant, v_wave, v_sku_avg, v_st1, 1, 1, c_op);

  BEGIN
    PERFORM generate_transfer_from_wave(v_wave, v_hq_loc, c_op);
    INSERT INTO _t (test, pass, detail) VALUES ('2.1 wave 缺價擋下', FALSE, '未擋（不該成功）');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _t (test, pass, detail) VALUES
      ('2.1 wave 缺價擋下＋中文訊息', SQLERRM LIKE '無法派貨%' AND SQLERRM LIKE '%TG-NP%' AND SQLERRM NOT LIKE '%TG-OK%', SQLERRM);
  END;

  SELECT status INTO v_status FROM picking_waves WHERE id = v_wave;
  SELECT COUNT(*) INTO v_cnt FROM transfers WHERE tenant_id = c_tenant;
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.1b 擋下後 wave 仍 picked、無 transfer', v_status = 'picked' AND v_cnt = 0, v_status || ' / transfers=' || v_cnt);

  -- 補價後重試 → 成功
  INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price, created_by) VALUES
    (c_tenant, v_sku_np, 'cost',   NULL, 45, c_op),
    (c_tenant, v_sku_np, 'branch', NULL, 55, c_op);

  v_res := generate_transfer_from_wave(v_wave, v_hq_loc, c_op);
  SELECT status INTO v_status FROM picking_waves WHERE id = v_wave;
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.4 補價後派貨成功、wave shipped', (v_res ->> 'store_count')::INT = 1 AND v_status = 'shipped', v_res::TEXT);

  -- 出庫成本：avg=0 → 用現行成本價（NP=45, OK=50）；avg=7 → 維持 avg（AVG=7）
  SELECT sm.unit_cost INTO v_cost_np
    FROM transfer_items ti JOIN stock_movements sm ON sm.id = ti.out_movement_id
   WHERE ti.sku_id = v_sku_np AND sm.tenant_id = c_tenant;
  SELECT sm.unit_cost INTO v_cost_ok
    FROM transfer_items ti JOIN stock_movements sm ON sm.id = ti.out_movement_id
   WHERE ti.sku_id = v_sku_ok AND sm.tenant_id = c_tenant;
  SELECT sm.unit_cost INTO v_cost_avg
    FROM transfer_items ti JOIN stock_movements sm ON sm.id = ti.out_movement_id
   WHERE ti.sku_id = v_sku_avg AND sm.tenant_id = c_tenant;
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.5 avg=0 出庫用現行成本價', v_cost_np = 45 AND v_cost_ok = 50, 'np=' || v_cost_np || ' ok=' || v_cost_ok);
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.5b avg>0 出庫仍用 avg_cost', v_cost_avg = 7, 'avg=' || v_cost_avg);

  -- ---------- §2.8 / §2.9 distribute_batch ----------
  -- A: hq_to_store 缺分店價 → failed；B: 店↔店同 SKU → 不檢查照常 shipped；C: hq_to_store 虛擬 → shipped
  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location, status, transfer_type, created_by)
  VALUES (c_tenant, 'TG-XA', v_hq_loc, v_s2_loc, 'draft', 'hq_to_store', c_op) RETURNING id INTO v_xa;
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by)
  VALUES (v_xa, v_sku_co, 1, c_op);

  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location, status, transfer_type, created_by)
  VALUES (c_tenant, 'TG-XB', v_s1_loc, v_s2_loc, 'draft', 'store_to_store', c_op) RETURNING id INTO v_xb;
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by)
  VALUES (v_xb, v_sku_co, 1, c_op);

  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location, status, transfer_type, created_by)
  VALUES (c_tenant, 'TG-XC', v_hq_loc, v_s2_loc, 'draft', 'hq_to_store', c_op) RETURNING id INTO v_xc;
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by)
  VALUES (v_xc, v_sku_v, 1, c_op);

  v_res := rpc_transfer_distribute_batch(ARRAY[v_xa, v_xb, v_xc], v_hq_loc, c_op);

  INSERT INTO _t (test, pass, detail) VALUES
    ('2.8 batch：hq_to_store 缺價進 failed、訊息中文',
     (SELECT COUNT(*) FROM jsonb_array_elements(v_res -> 'failed') f
       WHERE (f ->> 'id')::BIGINT = v_xa AND f ->> 'reason' LIKE '無法派貨%缺分店價%') = 1,
     v_res::TEXT);
  SELECT status INTO v_status FROM transfers WHERE id = v_xa;
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.8b 被擋的 transfer 維持 draft、庫存未動', v_status = 'draft'
       AND (SELECT on_hand FROM stock_balances WHERE tenant_id = c_tenant AND location_id = v_hq_loc AND sku_id = v_sku_co) = 100,
     v_status);
  SELECT status INTO v_status FROM transfers WHERE id = v_xb;
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.8c 店↔店缺價不檢查、照常 shipped', v_status = 'shipped'
       AND v_res -> 'succeeded' @> to_jsonb(v_xb), v_status);
  SELECT status INTO v_status FROM transfers WHERE id = v_xc;
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.9 hq_to_store 虛擬 SKU 不擋、跳過庫存', v_status = 'shipped'
       AND (SELECT out_movement_id FROM transfer_items WHERE transfer_id = v_xc) IS NULL, v_status);

  -- ---------- §2.10 既有 9 參數呼叫端回歸（具名參數、不傳 fallback）----------
  PERFORM rpc_outbound(
    p_tenant_id       => c_tenant,
    p_location_id     => v_hq_loc,
    p_sku_id          => v_sku_avg,
    p_quantity        => 1::NUMERIC,
    p_movement_type   => 'sale',
    p_source_doc_type => 'test',
    p_source_doc_id   => 0,
    p_operator        => c_op,
    p_allow_negative  => FALSE
  );
  INSERT INTO _t (test, pass, detail) VALUES
    ('2.10 9 參數具名呼叫照常 resolve', TRUE, 'no function-is-not-unique');
END $$;

SELECT CASE WHEN pass THEN 'PASS' ELSE '*** FAIL ***' END AS result, test, LEFT(detail, 160) AS detail
  FROM _t ORDER BY seq;
SELECT COUNT(*) FILTER (WHERE pass) || ' / ' || COUNT(*) AS passed FROM _t;

ROLLBACK;

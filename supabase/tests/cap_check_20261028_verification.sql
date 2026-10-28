-- ============================================================================
-- cap_check_20261028_verification.sql —— 20261028000000 限量上限的本機實跑驗證
-- ⛔ 只在本機臨時庫跑（先跑 cap_check_20261028_local_fixture.sql，見那支檔頭）。會寫入資料。
-- ============================================================================
-- 本機臨時庫實跑：限量上限（每段 DO 失敗就 RAISE，成功印 ✅）
\set ON_ERROR_STOP 1
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"00000000-0000-0000-0000-000000000001","app_metadata":{"tenant_id":"00000000-0000-0000-0000-000000000001","role":"admin"}}', false);

INSERT INTO tenants VALUES ('00000000-0000-0000-0000-000000000001','active');
INSERT INTO stores (id, tenant_id) VALUES (1,'00000000-0000-0000-0000-000000000001');
INSERT INTO line_channels (id, tenant_id, home_store_id) VALUES (1,'00000000-0000-0000-0000-000000000001',1);
INSERT INTO members (id, tenant_id, member_no, name, home_store_id)
SELECT g, '00000000-0000-0000-0000-000000000001', 'M' || g, '會員' || g, 1 FROM generate_series(1,20) g;
INSERT INTO skus (id, product_name, variant_name) VALUES (1,'蔓越莓',NULL),(2,'鼠尾草','大包'),(3,'雜貨',NULL);
INSERT INTO line_note_communities (id, store_id) VALUES (1, 1);

-- 團 10：整團 5、品項 101 上限 3、品項 102 不限
INSERT INTO group_buy_campaigns (id, tenant_id, campaign_no, status, total_cap_qty) VALUES (10,'00000000-0000-0000-0000-000000000001','GRP-10','open',5);
INSERT INTO campaign_items (id, tenant_id, campaign_id, sku_id, unit_price, cap_qty, sort_order) VALUES
 (101,'00000000-0000-0000-0000-000000000001',10,1,100,3,1),
 (102,'00000000-0000-0000-0000-000000000001',10,2,50,NULL,2);
-- 團 20：沒設上限
INSERT INTO group_buy_campaigns (id, tenant_id, campaign_no, status, total_cap_qty) VALUES (20,'00000000-0000-0000-0000-000000000001','GRP-20','open',NULL);
INSERT INTO campaign_items (id, tenant_id, campaign_id, sku_id, unit_price, cap_qty, sort_order) VALUES
 (201,'00000000-0000-0000-0000-000000000001',20,3,10,0,1);

CREATE FUNCTION pg_temp.rows(p_member bigint, p_items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('member_id', p_member, 'pickup_store_id', 1, 'nickname', 'n', 'items', p_items)) $$;
CREATE FUNCTION pg_temp.sold(p_campaign bigint) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(SUM(coi.qty),0) FROM customer_order_items coi JOIN customer_orders co ON co.id = coi.order_id
   WHERE co.campaign_id = p_campaign AND co.status NOT IN ('cancelled','expired','transferred_out')
     AND coi.status NOT IN ('cancelled','expired') AND co.order_kind = 'normal' $$;

-- 1. 未滿：成功
DO $t$ BEGIN
  PERFORM * FROM rpc_create_customer_orders_capped(10, 1, pg_temp.rows(1, '[{"campaign_item_id":101,"qty":2}]'));
  IF pg_temp.sold(10) <> 2 THEN RAISE EXCEPTION '1 失敗 sold=%', pg_temp.sold(10); END IF;
  RAISE NOTICE '✅ 1 未滿上限：加 2 件成功（已售 2）';
END $t$;

-- 2. 品項滿了被擋（101 上限 3、已售 2、要加 2）
DO $t$ DECLARE v_msg text; BEGIN
  BEGIN
    PERFORM * FROM rpc_create_customer_orders_capped(10, 1, pg_temp.rows(2, '[{"campaign_item_id":101,"qty":2}]'));
    RAISE EXCEPTION '2 失敗：沒被擋';
  EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM; END;
  IF v_msg NOT LIKE '已達限量上限：「蔓越莓」還剩 1 件，這次要加 2 件' THEN RAISE EXCEPTION '2 訊息不對：%', v_msg; END IF;
  IF pg_temp.sold(10) <> 2 THEN RAISE EXCEPTION '2 被擋卻寫入了'; END IF;
  RAISE NOTICE '✅ 2 品項上限擋下：%', v_msg;
END $t$;

-- 3. 多位客人加總超過整團（整團 5、已售 2、兩人各 2 = 4 > 3）→ 整批不送
DO $t$ DECLARE v_msg text; BEGIN
  BEGIN
    PERFORM * FROM rpc_create_customer_orders_capped(10, 1,
      pg_temp.rows(3, '[{"campaign_item_id":102,"qty":2}]') || pg_temp.rows(4, '[{"campaign_item_id":102,"qty":2}]'));
    RAISE EXCEPTION '3 失敗：沒被擋';
  EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM; END;
  IF v_msg <> '已達限量上限：整團還剩 3 件，這次要加 4 件' THEN RAISE EXCEPTION '3 訊息不對：%', v_msg; END IF;
  IF pg_temp.sold(10) <> 2 OR EXISTS (SELECT 1 FROM customer_orders WHERE member_id IN (3,4)) THEN RAISE EXCEPTION '3 整批不送卻寫入了'; END IF;
  RAISE NOTICE '✅ 3 多人加總超過整批不送：%', v_msg;
END $t$;

-- 4. 剛好加滿：成功；再加 1 → 擋（還剩 0）
DO $t$ DECLARE v_msg text; BEGIN
  PERFORM * FROM rpc_create_customer_orders_capped(10, 1,
    pg_temp.rows(3, '[{"campaign_item_id":102,"qty":2}]') || pg_temp.rows(4, '[{"campaign_item_id":101,"qty":1}]'));
  IF pg_temp.sold(10) <> 5 THEN RAISE EXCEPTION '4 加滿失敗 sold=%', pg_temp.sold(10); END IF;
  BEGIN
    PERFORM * FROM rpc_create_customer_orders_capped(10, 1, pg_temp.rows(5, '[{"campaign_item_id":102,"qty":1}]'));
    RAISE EXCEPTION '4 失敗：滿了沒被擋';
  EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM; END;
  IF v_msg <> '已達限量上限：整團還剩 0 件，這次要加 1 件' THEN RAISE EXCEPTION '4 訊息不對：%', v_msg; END IF;
  RAISE NOTICE '✅ 4 剛好加滿成功；滿了再加被擋：%', v_msg;
END $t$;

-- 5. 已售算法：取消／過期／轉出的單、取消／過期的品項、非 normal 單不算 → 釋出的量可再加
INSERT INTO customer_orders (id, tenant_id, order_no, campaign_id, channel_id, member_id, pickup_store_id, status, order_kind)
VALUES (900,'00000000-0000-0000-0000-000000000001','X1',10,1,6,1,'cancelled','normal'),
       (901,'00000000-0000-0000-0000-000000000001','X2',10,1,7,1,'transferred_out','normal'),
       (902,'00000000-0000-0000-0000-000000000001','X3',10,1,8,1,'pending','restock'),
       (903,'00000000-0000-0000-0000-000000000001','X4',10,1,9,1,'pending','normal');
INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, qty, status) VALUES
 ('00000000-0000-0000-0000-000000000001',900,102,9,'pending'),
 ('00000000-0000-0000-0000-000000000001',901,102,9,'pending'),
 ('00000000-0000-0000-0000-000000000001',902,102,9,'pending'),
 ('00000000-0000-0000-0000-000000000001',903,102,9,'cancelled'),
 ('00000000-0000-0000-0000-000000000001',903,102,9,'expired');
DO $t$ DECLARE r record; BEGIN
  SELECT * INTO r FROM _campaign_cap_remaining(10) WHERE campaign_item_id = 101;
  IF r.item_cap <> 3 OR r.item_sold <> 3 OR r.item_remaining <> 0 OR r.total_cap <> 5 OR r.total_sold <> 5 OR r.total_remaining <> 0 THEN
    RAISE EXCEPTION '5 失敗 %', row_to_json(r); END IF;
  SELECT * INTO r FROM _campaign_cap_remaining(10) WHERE campaign_item_id = 102;
  IF r.item_cap IS NOT NULL OR r.item_remaining IS NOT NULL OR r.item_sold <> 2 THEN RAISE EXCEPTION '5 失敗 102 %', row_to_json(r); END IF;
  RAISE NOTICE '✅ 5 已售排除取消／轉出／非 normal 單、取消／過期品項；沒設品項上限＝NULL';
END $t$;

-- 6. 跟商城那支算出一樣的邊界：同一團改成整團 7（剩 2），商城 2 件過、3 件 sold out；新函式同樣
UPDATE group_buy_campaigns SET total_cap_qty = 7 WHERE id = 10;
DO $t$ DECLARE v_ok_mall boolean; v_ok_capped boolean; BEGIN
  -- 商城：3 件應被擋
  BEGIN PERFORM * FROM rpc_place_member_order_guarded('00000000-0000-0000-0000-000000000001',10,1,11,1,'[{"campaign_item_id":102,"qty":3}]');
        v_ok_mall := true; EXCEPTION WHEN raise_exception THEN v_ok_mall := false; END;
  BEGIN PERFORM * FROM rpc_create_customer_orders_capped(10,1,pg_temp.rows(12,'[{"campaign_item_id":102,"qty":3}]'));
        v_ok_capped := true; EXCEPTION WHEN raise_exception THEN v_ok_capped := false; END;
  IF v_ok_mall OR v_ok_capped THEN RAISE EXCEPTION '6 失敗：3 件 mall=% capped=%', v_ok_mall, v_ok_capped; END IF;
  -- 2 件：兩邊都過（各自在子交易裡做完就回滾，不互相影響）
  BEGIN PERFORM * FROM rpc_place_member_order_guarded('00000000-0000-0000-0000-000000000001',10,1,11,1,'[{"campaign_item_id":102,"qty":2}]');
        v_ok_mall := true; RAISE EXCEPTION 'rollback_me'; EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_me' THEN v_ok_mall := false; END IF; END;
  BEGIN PERFORM * FROM rpc_create_customer_orders_capped(10,1,pg_temp.rows(12,'[{"campaign_item_id":102,"qty":2}]'));
        v_ok_capped := true; RAISE EXCEPTION 'rollback_me'; EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_me' THEN v_ok_capped := false; END IF; END;
  IF NOT v_ok_mall OR NOT v_ok_capped THEN RAISE EXCEPTION '6 失敗：2 件 mall=% capped=%', v_ok_mall, v_ok_capped; END IF;
  -- 品項上限：101 滿（3/3），商城 1 件 item sold out、新函式也擋
  BEGIN PERFORM * FROM rpc_place_member_order_guarded('00000000-0000-0000-0000-000000000001',10,1,11,1,'[{"campaign_item_id":101,"qty":1}]');
        v_ok_mall := true; EXCEPTION WHEN raise_exception THEN v_ok_mall := false; END;
  BEGIN PERFORM * FROM rpc_create_customer_orders_capped(10,1,pg_temp.rows(12,'[{"campaign_item_id":101,"qty":1}]'));
        v_ok_capped := true; EXCEPTION WHEN raise_exception THEN v_ok_capped := false; END;
  IF v_ok_mall OR v_ok_capped THEN RAISE EXCEPTION '6 失敗：品項 mall=% capped=%', v_ok_mall, v_ok_capped; END IF;
  RAISE NOTICE '✅ 6 跟商城下單同一個邊界（整團剩 2：2 件過、3 件擋；品項滿：1 件擋）';
END $t$;
UPDATE group_buy_campaigns SET total_cap_qty = 5 WHERE id = 10;

-- 7. 沒設上限的團：結果跟原本那支一樣
DO $t$ DECLARE a record; b record; BEGIN
  SELECT * INTO a FROM rpc_create_customer_orders_capped(20, 1, pg_temp.rows(1, '[{"campaign_item_id":201,"qty":999}]'));
  SELECT * INTO b FROM rpc_create_customer_orders(20, 1, pg_temp.rows(1, '[{"campaign_item_id":201,"qty":1}]'));
  IF a.out_order_id <> b.out_order_id OR (SELECT qty FROM customer_order_items WHERE order_id = a.out_order_id) <> 1000 THEN
    RAISE EXCEPTION '7 失敗'; END IF;
  RAISE NOTICE '✅ 7 沒設上限（含 cap_qty=0）：999 件照加，跟原本那支併同一張單（%）', a.out_order_no;
END $t$;

-- 8. 原本那支的錯誤照原樣丟出（找不到團、qty<=0）
DO $t$ DECLARE v_msg text; BEGIN
  BEGIN PERFORM * FROM rpc_create_customer_orders_capped(999, 1, pg_temp.rows(1, '[{"campaign_item_id":201,"qty":1}]'));
  EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM; END;
  IF v_msg <> 'campaign 999 not in tenant' THEN RAISE EXCEPTION '8 失敗 %', v_msg; END IF;
  BEGIN PERFORM * FROM rpc_create_customer_orders_capped(20, 1, pg_temp.rows(1, '[{"campaign_item_id":201,"qty":0}]'));
  EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM; END;
  IF v_msg <> 'qty must be > 0' THEN RAISE EXCEPTION '8 失敗 %', v_msg; END IF;
  RAISE NOTICE '✅ 8 其他錯誤沿用原本那支的訊息';
END $t$;

-- 9～12 LINE 記事本留言
-- 團 30：整團 4、一個品項（不寫代碼）；團 40：兩個品項 A（上限 2）B 不限，整團 3；團 50 不限
INSERT INTO group_buy_campaigns (id, tenant_id, campaign_no, status, total_cap_qty) VALUES
 (30,'00000000-0000-0000-0000-000000000001','GRP-30','open',4),
 (40,'00000000-0000-0000-0000-000000000001','GRP-40','open',3),
 (50,'00000000-0000-0000-0000-000000000001','GRP-50','open',NULL);
INSERT INTO campaign_items (id, tenant_id, campaign_id, sku_id, unit_price, cap_qty, sort_order) VALUES
 (301,'00000000-0000-0000-0000-000000000001',30,1,100,NULL,1),
 (401,'00000000-0000-0000-0000-000000000001',40,1,100,2,1),
 (402,'00000000-0000-0000-0000-000000000001',40,2,100,NULL,2),
 (501,'00000000-0000-0000-0000-000000000001',50,3,100,NULL,1);
INSERT INTO line_note_posts (id, campaign_id, community_id) VALUES (30,30,1),(40,40,1),(50,50,1);
SELECT * FROM rpc_create_customer_orders_capped(30, 1, pg_temp.rows(1, '[{"campaign_item_id":301,"qty":3}]'));
INSERT INTO line_note_comments (id, tenant_id, post_id, parsed, member_no_hint, commenter_name, text) VALUES
 (1,'00000000-0000-0000-0000-000000000001',30,'[{"qty":3}]','M2','客2','M2 +3'),
 (2,'00000000-0000-0000-0000-000000000001',30,'[{"qty":2}]','M3','客3','M3 +2'),
 (3,'00000000-0000-0000-0000-000000000001',40,'[{"code":"A","qty":3},{"code":"B","qty":2}]','M4','客4','M4 A3 B2'),
 (4,'00000000-0000-0000-0000-000000000001',50,'[{"qty":7}]','M5','客5','M5 +7');

DO $t$ DECLARE r record; c record; BEGIN
  SELECT * INTO r FROM rpc_line_note_apply_comment(1);
  SELECT * INTO c FROM line_note_comments WHERE id = 1;
  IF r.out_status <> 'ordered' OR (SELECT qty FROM customer_order_items WHERE order_id = r.out_order_id) <> 1
     OR c.resolution_note <> '限量已滿，只加部分：A 要 3 件只加 1 件'
     OR (SELECT source FROM customer_order_items WHERE order_id = r.out_order_id) <> 'line_bot' THEN
    RAISE EXCEPTION '9 失敗 % %', row_to_json(r), row_to_json(c); END IF;
  RAISE NOTICE '✅ 9 留言 +3 只剩 1：加 1 件、status=ordered、resolution_note=%', c.resolution_note;
END $t$;

DO $t$ DECLARE r record; c record; BEGIN
  SELECT * INTO r FROM rpc_line_note_apply_comment(2);
  SELECT * INTO c FROM line_note_comments WHERE id = 2;
  IF r.out_status <> 'error' OR c.status <> 'error' OR c.error <> '已達限量上限，未加單（A 要 2 件只加 0 件）'
     OR c.member_id <> 3 OR EXISTS (SELECT 1 FROM customer_orders WHERE member_id = 3 AND campaign_id = 30) THEN
    RAISE EXCEPTION '10 失敗 %', row_to_json(c); END IF;
  RAISE NOTICE '✅ 10 剩 0：整則不加、status=error（進待處理）、error=%', c.error;
END $t$;

DO $t$ DECLARE r record; c record; BEGIN
  SELECT * INTO r FROM rpc_line_note_apply_comment(3);
  SELECT * INTO c FROM line_note_comments WHERE id = 3;
  -- A 上限 2 → 加 2；整團 3 被 A 用掉 2 → B 只剩 1
  IF r.out_status <> 'ordered'
     OR (SELECT qty FROM customer_order_items WHERE order_id = r.out_order_id AND campaign_item_id = 401) <> 2
     OR (SELECT qty FROM customer_order_items WHERE order_id = r.out_order_id AND campaign_item_id = 402) <> 1
     OR c.resolution_note <> '限量已滿，只加部分：A 要 3 件只加 2 件、B 要 2 件只加 1 件' THEN
    RAISE EXCEPTION '11 失敗 %', row_to_json(c); END IF;
  RAISE NOTICE '✅ 11 品項上限＋整團上限依品項順序分配：%', c.resolution_note;
END $t$;

DO $t$ DECLARE r record; c record; BEGIN
  SELECT * INTO r FROM rpc_line_note_apply_comment(4);
  SELECT * INTO c FROM line_note_comments WHERE id = 4;
  IF r.out_status <> 'ordered' OR c.resolution_note IS NOT NULL
     OR (SELECT qty FROM customer_order_items WHERE order_id = r.out_order_id) <> 7 THEN
    RAISE EXCEPTION '12 失敗 %', row_to_json(c); END IF;
  RAISE NOTICE '✅ 12 沒設上限的團：照原量加 7 件、resolution_note 不動';
END $t$;

-- 13. 去重＋截量併在同一欄（已有 A 的會員再留 A+1 B+5，團 40 已滿）
INSERT INTO line_note_comments (id, tenant_id, post_id, parsed, member_no_hint, commenter_name, text) VALUES
 (5,'00000000-0000-0000-0000-000000000001',40,'[{"code":"A","qty":1},{"code":"B","qty":5}]','M4','客4','M4 A1 B5');
DO $t$ DECLARE r record; c record; BEGIN
  SELECT * INTO r FROM rpc_line_note_apply_comment(5);
  SELECT * INTO c FROM line_note_comments WHERE id = 5;
  -- A 是重複（已有）、B 已經有了也算重複 → 全部重複 → duplicate，跟原本一樣
  IF r.out_status <> 'duplicate' THEN RAISE EXCEPTION '13 失敗 %', row_to_json(c); END IF;
  RAISE NOTICE '✅ 13 全部重複照舊走 duplicate（截量在去重之後才做）：%', c.error;
END $t$;
UPDATE group_buy_campaigns SET total_cap_qty = 10 WHERE id = 40;
INSERT INTO line_note_comments (id, tenant_id, post_id, parsed, member_no_hint, commenter_name, text) VALUES
 (7,'00000000-0000-0000-0000-000000000001',40,'[{"code":"A","qty":1},{"code":"B","qty":9}]','M1','客1','M1 A1 B9');
SELECT * FROM rpc_create_customer_orders_capped(40, 1, pg_temp.rows(1, '[{"campaign_item_id":402,"qty":1}]'));
DO $t$ DECLARE r record; c record; BEGIN
  -- 團 40 整團 10、已售 4（A2 B1 + 會員1 B1）→ 剩 6；A 已滿（2/2）→ 0；會員1 已有 B → 重複
  SELECT * INTO r FROM rpc_line_note_apply_comment(7);
  SELECT * INTO c FROM line_note_comments WHERE id = 7;
  IF r.out_status <> 'error' OR c.error <> '已達限量上限，未加單（A 要 1 件只加 0 件）' THEN RAISE EXCEPTION '14 失敗 %', row_to_json(c); END IF;
  RAISE NOTICE '✅ 14 一項重複、另一項限量已滿 → error：%', c.error;
END $t$;

-- 15. 一項重複＋一項只加部分 → ordered，resolution_note 限量那句放最前面（待處理判斷看開頭）
INSERT INTO group_buy_campaigns (id, tenant_id, campaign_no, status, total_cap_qty) VALUES (80,'00000000-0000-0000-0000-000000000001','GRP-80','open',3);
INSERT INTO campaign_items (id, tenant_id, campaign_id, sku_id, unit_price, cap_qty, sort_order) VALUES
 (801,'00000000-0000-0000-0000-000000000001',80,1,100,NULL,1),
 (802,'00000000-0000-0000-0000-000000000001',80,2,100,NULL,2);
INSERT INTO line_note_posts (id, campaign_id, community_id) VALUES (80,80,1);
SELECT * FROM rpc_create_customer_orders_capped(80, 1, pg_temp.rows(1, '[{"campaign_item_id":801,"qty":1}]'));
INSERT INTO line_note_comments (id, tenant_id, post_id, parsed, member_no_hint, commenter_name, text) VALUES
 (8,'00000000-0000-0000-0000-000000000001',80,'[{"code":"A","qty":1},{"code":"B","qty":5}]','M1','客1','M1 A1 B5');
DO $t$ DECLARE r record; c record; BEGIN
  SELECT * INTO r FROM rpc_line_note_apply_comment(8);
  SELECT * INTO c FROM line_note_comments WHERE id = 8;
  IF r.out_status <> 'ordered' OR c.resolution_note <> '限量已滿，只加部分：B 要 5 件只加 2 件；已略過重複：A'
     OR (SELECT qty FROM customer_order_items WHERE order_id = r.out_order_id AND campaign_item_id = 802) <> 2 THEN
    RAISE EXCEPTION '15 失敗 %', row_to_json(c); END IF;
  RAISE NOTICE '✅ 15 重複＋部分：resolution_note=%', c.resolution_note;
END $t$;

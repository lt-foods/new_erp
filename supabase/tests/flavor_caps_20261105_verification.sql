-- ============================================================================
-- flavor_caps_20261105_verification.sql —— 20261105000000 每口味限量的本機實跑驗證
-- ⛔ 只在本機臨時庫跑（先照 flavor_caps_20261105_local_fixture.sql 檔頭）。會寫入資料。
-- ============================================================================
\set ON_ERROR_STOP 1
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"00000000-0000-0000-0000-000000000001","app_metadata":{"tenant_id":"00000000-0000-0000-0000-000000000001","role":"admin"}}', false);

CREATE FUNCTION pg_temp.mk(p_name text, p_product bigint, p_close text, p_channel text, p_total numeric, p_caps jsonb) RETURNS bigint LANGUAGE sql AS $$
  SELECT rpc_create_campaign_from_product(
    p_name => p_name, p_end_at => now() + interval '3 day', p_pickup_deadline => NULL, p_product_id => p_product,
    p_close_type => p_close, p_sales_channel => p_channel, p_total_cap_qty => p_total, p_item_caps => p_caps) $$;

-- 會被擋：訊息要對，而且一列都不留
CREATE FUNCTION pg_temp.must_fail(p_label text, p_product bigint, p_close text, p_channel text, p_total numeric, p_caps jsonb, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_msg text; v_before bigint; v_before_items bigint;
BEGIN
  SELECT count(*) INTO v_before FROM group_buy_campaigns;
  SELECT count(*) INTO v_before_items FROM campaign_items;
  BEGIN
    PERFORM pg_temp.mk(p_label, p_product, p_close, p_channel, p_total, p_caps);
    RAISE EXCEPTION USING message = p_label || ' 失敗：沒被擋', errcode = 'ZZ001';
  EXCEPTION WHEN sqlstate 'ZZ001' THEN RAISE;
  WHEN OTHERS THEN v_msg := SQLERRM; END;
  IF v_msg NOT LIKE p_msg THEN RAISE EXCEPTION '% 訊息不對：%', p_label, v_msg; END IF;
  IF (SELECT count(*) FROM group_buy_campaigns) <> v_before OR (SELECT count(*) FROM campaign_items) <> v_before_items THEN
    RAISE EXCEPTION '% 被擋卻留下資料', p_label; END IF;
  RAISE NOTICE '✅ % → %', p_label, v_msg;
END $$;

CREATE FUNCTION pg_temp.sold(p_item bigint) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(SUM(coi.qty),0) FROM customer_order_items coi JOIN customer_orders co ON co.id = coi.order_id
   WHERE coi.campaign_item_id = p_item AND co.status NOT IN ('cancelled','expired','transferred_out')
     AND coi.status NOT IN ('cancelled','expired') AND co.order_kind = 'normal' $$;
CREATE FUNCTION pg_temp.item(p_campaign bigint, p_sku bigint) RETURNS bigint LANGUAGE sql AS $$
  SELECT id FROM campaign_items WHERE campaign_id = p_campaign AND sku_id = p_sku $$;
CREATE FUNCTION pg_temp.mall(p_campaign bigint, p_item bigint, p_member bigint, p_qty numeric) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM * FROM rpc_place_member_order_guarded('00000000-0000-0000-0000-000000000001', p_campaign, 1, p_member, 1,
    jsonb_build_array(jsonb_build_object('campaign_item_id', p_item, 'qty', p_qty)));
  RETURN 'ok';
EXCEPTION WHEN raise_exception THEN RETURN SQLERRM; END $$;
CREATE FUNCTION pg_temp.admin(p_campaign bigint, p_item bigint, p_member bigint, p_qty numeric) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM * FROM rpc_create_customer_orders_capped(p_campaign, 1,
    jsonb_build_array(jsonb_build_object('member_id', p_member, 'pickup_store_id', 1, 'nickname', 'n',
      'items', jsonb_build_array(jsonb_build_object('campaign_item_id', p_item, 'qty', p_qty)))));
  RETURN 'ok';
EXCEPTION WHEN raise_exception THEN RETURN SQLERRM; END $$;

-- ── 建團 ──
-- 1. 全填
DO $t$ DECLARE v_id bigint; g record; BEGIN
  v_id := pg_temp.mk('全填', 1, 'limited', 'main', NULL,
    '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]');
  SELECT * INTO g FROM group_buy_campaigns WHERE id = v_id;
  IF g.total_cap_qty IS NOT NULL OR g.close_type <> 'limited' OR g.sales_channel <> 'main' OR g.status <> 'open' THEN
    RAISE EXCEPTION '1 失敗 %', row_to_json(g); END IF;
  IF (SELECT array_agg(cap_qty ORDER BY sku_id) FROM campaign_items WHERE campaign_id = v_id) <> ARRAY[3,5,1]::numeric[]
     OR (SELECT array_agg(unit_price ORDER BY sku_id) FROM campaign_items WHERE campaign_id = v_id) <> ARRAY[100,110,120]::numeric[]
     OR (SELECT array_agg(sort_order ORDER BY sku_id) FROM campaign_items WHERE campaign_id = v_id) <> ARRAY[1,2,3] THEN
    RAISE EXCEPTION '1 品項不對'; END IF;
  RAISE NOTICE '✅ 1 全填：一個團、三行上限 3／5／1、總量空、停用口味沒進團';
END $t$;

-- 2. 全空
SELECT pg_temp.must_fail('2a 全空（NULL）', 1, 'limited', 'main', NULL, NULL, '限量團要填總量上限，或每個規格都填上限');
SELECT pg_temp.must_fail('2b 全空（[]）', 1, 'limited', 'main', NULL, '[]', '限量團要填總量上限，或每個規格都填上限');
DO $t$ DECLARE v_id bigint; BEGIN
  v_id := pg_temp.mk('總量', 1, 'limited', 'main', 9, NULL);
  IF (SELECT total_cap_qty FROM group_buy_campaigns WHERE id = v_id) <> 9
     OR EXISTS (SELECT 1 FROM campaign_items WHERE campaign_id = v_id AND cap_qty IS NOT NULL)
     OR (SELECT count(*) FROM campaign_items WHERE campaign_id = v_id) <> 3 THEN RAISE EXCEPTION '2c 失敗'; END IF;
  RAISE NOTICE '✅ 2c 只填總量：照舊、三口味共用';
END $t$;

-- 3. 填一部分；4. 兩者都填
SELECT pg_temp.must_fail('3 填一部分', 1, 'limited', 'main', NULL, '[{"sku_id":11,"cap_qty":3}]', '每個規格都要填上限，還沒填：T-C (巧克力)、T-P (花生)');
SELECT pg_temp.must_fail('4 兩者都填', 1, 'limited', 'main', 9,
  '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '總量上限和每個規格的上限只能填一種');

-- 5. 數字不合法
SELECT pg_temp.must_fail('5a 上限 0', 1, 'limited', 'main', NULL, '[{"sku_id":11,"cap_qty":0},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '每個規格的上限要填大於 0 的整數');
SELECT pg_temp.must_fail('5b 負數', 1, 'limited', 'main', NULL, '[{"sku_id":11,"cap_qty":-1},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '每個規格的上限要填大於 0 的整數');
SELECT pg_temp.must_fail('5c 小數', 1, 'limited', 'main', NULL, '[{"sku_id":11,"cap_qty":1.5},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '每個規格的上限要填大於 0 的整數');
SELECT pg_temp.must_fail('5d 字串', 1, 'limited', 'main', NULL, '[{"sku_id":11,"cap_qty":"3"},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '每個規格的上限格式不正確');
SELECT pg_temp.must_fail('5e 缺上限', 1, 'limited', 'main', NULL, '[{"sku_id":11},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '每個規格的上限格式不正確');
SELECT pg_temp.must_fail('5f JSON null 上限', 1, 'limited', 'main', NULL, '[{"sku_id":11,"cap_qty":null},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '每個規格的上限格式不正確');
SELECT pg_temp.must_fail('5g 不是陣列', 1, 'limited', 'main', NULL, '{"sku_id":11,"cap_qty":3}', '每個規格的上限格式不正確');
SELECT pg_temp.must_fail('5h JSON null', 1, 'limited', 'main', NULL, 'null', '每個規格的上限格式不正確');
SELECT pg_temp.must_fail('5i 元素不是物件', 1, 'limited', 'main', NULL, '[3]', '每個規格的上限格式不正確');
SELECT pg_temp.must_fail('5j 上限大到存不下', 1, 'limited', 'main', NULL, '[{"sku_id":11,"cap_qty":1e30},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '%numeric%');

-- 6. 規格不合法
SELECT pg_temp.must_fail('6a 別的商品的規格', 1, 'limited', 'main', NULL, '[{"sku_id":21,"cap_qty":3},{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '這些規格不屬於這個商品或已停用：21');
SELECT pg_temp.must_fail('6b 停用規格', 1, 'limited', 'main', NULL, '[{"sku_id":14,"cap_qty":3},{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '這些規格不屬於這個商品或已停用：14');
SELECT pg_temp.must_fail('6c 重複規格', 1, 'limited', 'main', NULL, '[{"sku_id":11,"cap_qty":3},{"sku_id":11,"cap_qty":4},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '同一個規格不能重複填上限：11');
SELECT pg_temp.must_fail('6d 不存在的規格', 1, 'limited', 'main', NULL, '[{"sku_id":99999,"cap_qty":3},{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '這些規格不屬於這個商品或已停用：99999');
SELECT pg_temp.must_fail('6e 規格編號小數', 1, 'limited', 'main', NULL, '[{"sku_id":11.5,"cap_qty":3}]', '每個規格的上限格式不正確');
SELECT pg_temp.must_fail('6f 規格編號超大', 1, 'limited', 'main', NULL, '[{"sku_id":1e30,"cap_qty":3}]', '每個規格的上限格式不正確');

-- 7. 非限量傳 p_item_caps
SELECT pg_temp.must_fail('7a 常規', 1, 'regular', 'main', NULL, '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '只有限量團可以填每個規格的上限');
SELECT pg_temp.must_fail('7b 快團', 1, 'fast', 'main', NULL, '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '只有限量團可以填每個規格的上限');
SELECT pg_temp.must_fail('7c 美食列車', 1, 'food_train', 'main', NULL, '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '只有限量團可以填每個規格的上限');
SELECT pg_temp.must_fail('7d 漂漂館', 1, 'regular', 'piaopiao', NULL, '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '只有限量團可以填每個規格的上限');
SELECT pg_temp.must_fail('7e 限量＋漂漂館', 1, 'limited', 'piaopiao', NULL, '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '只有限量團可以填每個規格的上限');
SELECT pg_temp.must_fail('7f 不傳類別', 1, NULL, 'main', NULL, '[{"sku_id":11,"cap_qty":3}]', '只有限量團可以填每個規格的上限');
DO $t$ DECLARE v_id bigint; BEGIN
  v_id := pg_temp.mk('常規空陣列', 1, 'regular', 'main', NULL, '[]');
  IF EXISTS (SELECT 1 FROM campaign_items WHERE campaign_id = v_id AND cap_qty IS NOT NULL) THEN RAISE EXCEPTION '7g 失敗'; END IF;
  RAISE NOTICE '✅ 7g 常規傳空陣列＝沒給，照常建團';
END $t$;

-- 8. 舊呼叫（只傳 5 個參數）
DO $t$ DECLARE v_id bigint; g record; BEGIN
  v_id := rpc_create_campaign_from_product(p_name => '舊呼叫', p_end_at => now() + interval '3 day',
    p_pickup_deadline => NULL, p_product_id => 1, p_description => NULL);
  SELECT * INTO g FROM group_buy_campaigns WHERE id = v_id;
  IF g.close_type <> 'regular' OR g.total_cap_qty IS NOT NULL OR g.description <> '吐司文案'
     OR (SELECT count(*) FROM campaign_items WHERE campaign_id = v_id AND cap_qty IS NULL) <> 3 THEN RAISE EXCEPTION '8 失敗'; END IF;
  RAISE NOTICE '✅ 8 舊呼叫 5 參數：常規、文案帶入、三規格無上限';
END $t$;

-- 9. 單規格走 p_item_caps 也可以；沒售價照舊擋
DO $t$ DECLARE v_id bigint; BEGIN
  v_id := pg_temp.mk('單規格', 3, 'limited', 'main', NULL, '[{"sku_id":31,"cap_qty":2}]');
  IF (SELECT cap_qty FROM campaign_items WHERE campaign_id = v_id) <> 2 THEN RAISE EXCEPTION '9 失敗'; END IF;
  RAISE NOTICE '✅ 9 單規格傳 p_item_caps 也寫得進去（畫面上單規格仍走總量）';
END $t$;
SELECT pg_temp.must_fail('9b 沒售價', 4, 'limited', 'main', NULL, '[{"sku_id":41,"cap_qty":2}]', '無法開團：以下規格尚未設定零售價%');

-- 10. 權限與簽名
DO $t$ DECLARE v_sig text := 'public.rpc_create_campaign_from_product(text, timestamptz, date, bigint, text, timestamptz, timestamptz, boolean, boolean, text, text, numeric, jsonb)'; BEGIN
  IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN RAISE EXCEPTION '10 anon 不該能執行'; END IF;
  IF NOT has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN RAISE EXCEPTION '10 authenticated 要能執行'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_sig::regprocedure AND a.grantee = 0) THEN RAISE EXCEPTION '10 PUBLIC 還有權限'; END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'rpc_create_campaign_from_product') <> 1 THEN RAISE EXCEPTION '10 同名有兩版'; END IF;
  IF obj_description(v_sig::regprocedure) NOT LIKE '%p_item_caps%' THEN RAISE EXCEPTION '10 COMMENT 沒跟新簽名'; END IF;
  RAISE NOTICE '✅ 10 權限：anon／PUBLIC 不行、authenticated 可以；同名只有一版；COMMENT 正確';
END $t$;

-- 11. 檢查之後規格才異動：整個團退回。用測試觸發器在「檢查之後、寫品項之前」動規格。
CREATE FUNCTION pg_temp.add_sku_trg() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
  INSERT INTO skus (id, tenant_id, product_id, sku_code, product_name, variant_name, status)
  VALUES (15,'00000000-0000-0000-0000-000000000001',1,'T-N','吐司','新口味','active');
  INSERT INTO prices (tenant_id, sku_id, scope, price, effective_from, effective_to)
  VALUES ('00000000-0000-0000-0000-000000000001',15,'retail',130,now(),NULL);
  RETURN NEW; END $$;
CREATE TRIGGER t_add BEFORE INSERT ON group_buy_campaigns FOR EACH ROW EXECUTE FUNCTION pg_temp.add_sku_trg();
SELECT pg_temp.must_fail('11a 檢查後才新增口味', 1, 'limited', 'main', NULL,
  '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '規格剛有異動，請重新開團：sku 15');
DROP TRIGGER t_add ON group_buy_campaigns;
DO $t$ BEGIN IF EXISTS (SELECT 1 FROM skus WHERE id = 15) THEN RAISE EXCEPTION '11a 交易沒退回'; END IF; END $t$;

CREATE FUNCTION pg_temp.off_sku_trg() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
  UPDATE skus SET status = 'discontinued' WHERE id = 13; RETURN NEW; END $$;
CREATE TRIGGER t_off BEFORE INSERT ON group_buy_campaigns FOR EACH ROW EXECUTE FUNCTION pg_temp.off_sku_trg();
SELECT pg_temp.must_fail('11b 檢查後才停用口味', 1, 'limited', 'main', NULL,
  '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]', '規格剛有異動，請重新開團');
DROP TRIGGER t_off ON group_buy_campaigns;
DO $t$ BEGIN IF (SELECT status FROM skus WHERE id = 13) <> 'active' THEN RAISE EXCEPTION '11b 交易沒退回'; END IF; END $t$;

-- ── 下單 ──
CREATE TEMP TABLE c AS SELECT pg_temp.mk('吐司下單', 1, 'limited', 'main', NULL,
  '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]') AS id;
CREATE FUNCTION pg_temp.cid() RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM c $$;

-- 12. 商城：三個草莓後第 4 個被擋，其他口味不受影響
DO $t$ DECLARE s bigint := pg_temp.item(pg_temp.cid(), 11); ch bigint := pg_temp.item(pg_temp.cid(), 12); p bigint := pg_temp.item(pg_temp.cid(), 13); v text; BEGIN
  v := pg_temp.mall(pg_temp.cid(), s, 1, 3); IF v <> 'ok' THEN RAISE EXCEPTION '12 買 3 個草莓：%', v; END IF;
  v := pg_temp.mall(pg_temp.cid(), s, 2, 1); IF v <> 'item sold out' THEN RAISE EXCEPTION '12 第 4 個沒擋：%', v; END IF;
  v := pg_temp.mall(pg_temp.cid(), ch, 2, 5); IF v <> 'ok' THEN RAISE EXCEPTION '12 巧克力受影響：%', v; END IF;
  v := pg_temp.mall(pg_temp.cid(), ch, 3, 1); IF v <> 'item sold out' THEN RAISE EXCEPTION '12 巧克力第 6 個沒擋：%', v; END IF;
  IF pg_temp.sold(s) <> 3 OR pg_temp.sold(ch) <> 5 OR pg_temp.sold(p) <> 0 THEN RAISE EXCEPTION '12 已售不對'; END IF;
  RAISE NOTICE '✅ 12 商城：草莓第 4 個售完、巧克力第 6 個售完、花生沒動';
END $t$;

-- 13. 後台加單也照口味擋
DO $t$ DECLARE s bigint := pg_temp.item(pg_temp.cid(), 11); p bigint := pg_temp.item(pg_temp.cid(), 13); v text; BEGIN
  v := pg_temp.admin(pg_temp.cid(), s, 4, 1);
  IF v NOT LIKE '已達限量上限：%還剩 0 件，這次要加 1 件' THEN RAISE EXCEPTION '13 草莓沒擋：%', v; END IF;
  v := pg_temp.admin(pg_temp.cid(), p, 4, 2);
  IF v NOT LIKE '已達限量上限：%還剩 1 件，這次要加 2 件' THEN RAISE EXCEPTION '13 花生沒擋：%', v; END IF;
  IF pg_temp.sold(p) <> 0 THEN RAISE EXCEPTION '13 被擋卻寫入'; END IF;
  RAISE NOTICE '✅ 13 後台加單：%', v;
END $t$;

-- 14. 取消後名額回來（這裡直接把訂單與品項改成 cancelled，沒有跑取消函式）
DO $t$ DECLARE s bigint := pg_temp.item(pg_temp.cid(), 11); v text; v_order bigint; BEGIN
  SELECT co.id INTO v_order FROM customer_orders co WHERE co.campaign_id = pg_temp.cid() AND co.member_id = 1;
  UPDATE customer_order_items SET status = 'cancelled' WHERE order_id = v_order;
  UPDATE customer_orders SET status = 'cancelled' WHERE id = v_order;
  IF pg_temp.sold(s) <> 0 THEN RAISE EXCEPTION '14 已售沒歸零'; END IF;
  v := pg_temp.mall(pg_temp.cid(), s, 5, 3); IF v <> 'ok' THEN RAISE EXCEPTION '14 名額沒回來：%', v; END IF;
  v := pg_temp.mall(pg_temp.cid(), s, 6, 1); IF v <> 'item sold out' THEN RAISE EXCEPTION '14 又超賣：%', v; END IF;
  RAISE NOTICE '✅ 14 取消後草莓 3 個名額回來，再買 3 個成功、第 4 個又被擋';
END $t$;

-- 15. 記事本留言：多口味 A+1 照各口味上限；只寫 +1 不加單
INSERT INTO line_note_posts (id, campaign_id, community_id) SELECT 900, id, 1 FROM c;
INSERT INTO line_note_comments (id, tenant_id, post_id, parsed, member_no_hint, commenter_name, text) VALUES
 (901,'00000000-0000-0000-0000-000000000001',900,'[{"code":"C","qty":1}]','M7','客7','M7 C+1'),
 (902,'00000000-0000-0000-0000-000000000001',900,'[{"code":"C","qty":1}]','M8','客8','M8 C+1'),
 (903,'00000000-0000-0000-0000-000000000001',900,'[{"qty":1}]','M9','客9','M9 +1');
DO $t$ DECLARE r record; c1 record; BEGIN
  SELECT * INTO r FROM rpc_line_note_apply_comment(901);
  IF r.out_status <> 'ordered' OR pg_temp.sold(pg_temp.item(pg_temp.cid(), 13)) <> 1 THEN RAISE EXCEPTION '15a 失敗 %', row_to_json(r); END IF;
  SELECT * INTO r FROM rpc_line_note_apply_comment(902);
  SELECT * INTO c1 FROM line_note_comments WHERE id = 902;
  IF r.out_status <> 'error' OR c1.error NOT LIKE '已達限量上限%' OR pg_temp.sold(pg_temp.item(pg_temp.cid(), 13)) <> 1 THEN
    RAISE EXCEPTION '15b 失敗 %', row_to_json(c1); END IF;
  SELECT * INTO r FROM rpc_line_note_apply_comment(903);
  SELECT * INTO c1 FROM line_note_comments WHERE id = 903;
  IF r.out_status = 'ordered' OR EXISTS (SELECT 1 FROM customer_orders WHERE member_id = 9 AND campaign_id = pg_temp.cid()) THEN
    RAISE EXCEPTION '15c 失敗 %', row_to_json(c1); END IF;
  RAISE NOTICE '✅ 15 留言 C+1 第二個被擋；只寫 +1 不加單（status=%, error=%）', c1.status, c1.error;
END $t$;

-- 16. 編輯視窗走的 rpc_upsert_campaign_item：帶回原值只動上限，新上限馬上生效
DO $t$ DECLARE i record; a record; v text; BEGIN
  UPDATE campaign_items SET notes = '備註', unit_price = 123, sort_order = 7 WHERE id = pg_temp.item(pg_temp.cid(), 13);
  SELECT * INTO i FROM campaign_items WHERE id = pg_temp.item(pg_temp.cid(), 13);
  PERFORM rpc_upsert_campaign_item(i.id, i.campaign_id, i.sku_id, i.unit_price, 2, i.sort_order, i.notes);
  SELECT * INTO a FROM campaign_items WHERE id = i.id;
  IF a.cap_qty <> 2 OR a.notes <> '備註' OR a.unit_price <> 123 OR a.sort_order <> 7 THEN RAISE EXCEPTION '16 失敗 %', row_to_json(a); END IF;
  v := pg_temp.mall(pg_temp.cid(), i.id, 10, 1); IF v <> 'ok' THEN RAISE EXCEPTION '16 新上限沒生效：%', v; END IF;
  v := pg_temp.mall(pg_temp.cid(), i.id, 11, 1); IF v <> 'item sold out' THEN RAISE EXCEPTION '16 新上限沒擋：%', v; END IF;
  RAISE NOTICE '✅ 16 改上限 1→2：單價、排序、備註不變，第 2 個買得到、第 3 個被擋';
END $t$;

SELECT '全部通過' AS flavor_caps_verification;

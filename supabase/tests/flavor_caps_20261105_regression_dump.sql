-- ============================================================================
-- flavor_caps_20261105_regression_dump.sql —— 舊呼叫改前改後比對（本機臨時庫，用法見 local_fixture 檔頭）
-- 全包在交易裡、最後 ROLLBACK。只傳舊的 12 個參數；輸出不含 id 與時間，改前改後可以直接 diff。
-- 預期差異只有一行：限量且沒填總量的錯誤訊息。
-- ============================================================================
\set QUIET 1
\pset tuples_only on
\pset format unaligned
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"00000000-0000-0000-0000-000000000001","app_metadata":{"tenant_id":"00000000-0000-0000-0000-000000000001","role":"admin"}}', false) AS _cfg \gset

CREATE TEMP TABLE out_rows (seq serial, line text);
CREATE FUNCTION pg_temp.dump(p_label text, p_id bigint) RETURNS void LANGUAGE sql AS $$
  INSERT INTO out_rows (line)
  SELECT p_label || ' | ' || concat_ws(' | ', g.name, g.status, g.close_type, g.sales_channel, g.total_cap_qty, g.description, g.pickup_deadline, g.auto_open, g.line_note_enabled, g.product_id)
    FROM group_buy_campaigns g WHERE g.id = p_id;
  INSERT INTO out_rows (line)
  SELECT p_label || ' item | ' || concat_ws(' | ', c.sku_id, c.unit_price, COALESCE(c.cap_qty::text, 'NULL'), c.sort_order, COALESCE(c.notes, 'NULL'))
    FROM campaign_items c WHERE c.campaign_id = p_id ORDER BY c.sort_order;
$$;

-- campaigns/import 頁的舊呼叫：只有 5 個參數
SELECT pg_temp.dump('import', rpc_create_campaign_from_product(
  p_name => '匯入團', p_end_at => now() + interval '3 day', p_pickup_deadline => DATE '2030-01-01',
  p_product_id => 1, p_description => NULL));

-- 商品頁舊畫面會送的 12 個參數
DO $$
DECLARE
  r record;
  v_id bigint;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('常規','regular','main',NULL::numeric,1::bigint),
    ('常規單規格','regular','main',NULL,3),
    ('快團不填','fast','main',NULL,1),
    ('快團有填','fast','main',9,1),
    ('限量總量','limited','main',9,1),
    ('限量單規格','limited','main',9,3),
    ('美食列車','food_train','main',NULL,1),
    ('漂漂館','regular','piaopiao',NULL,1),
    ('限量漂漂館','limited','piaopiao',NULL,1),
    ('常規多填總量','regular','main',9,1),
    ('錯：限量沒填總量','limited','main',NULL,1),
    ('錯：限量總量0','limited','main',0,1),
    ('錯：沒售價','regular','main',NULL,4),
    ('錯：通路','regular','xx',NULL,1),
    ('錯：類別','xx','main',NULL,1),
    ('錯：不存在商品','regular','main',NULL,999)
  ) AS t(label, close_type, channel, total, product_id)
  LOOP
    BEGIN
      v_id := rpc_create_campaign_from_product(
        p_name => r.label, p_end_at => now() + interval '3 day', p_pickup_deadline => DATE '2030-01-01',
        p_product_id => r.product_id, p_description => 'd', p_customer_end_at => now() + interval '2 day',
        p_start_at => now(), p_auto_open => true, p_line_note => true,
        p_close_type => r.close_type, p_sales_channel => r.channel, p_total_cap_qty => r.total);
      PERFORM pg_temp.dump(r.label, v_id);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO out_rows (line) VALUES (r.label || ' ERROR | ' || SQLERRM);
    END;
  END LOOP;
END $$;

SELECT line FROM out_rows ORDER BY seq;
ROLLBACK;

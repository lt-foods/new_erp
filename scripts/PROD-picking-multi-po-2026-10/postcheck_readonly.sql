-- ============================================================================
-- 只查不改：20261015000000（撿貨用檢查表：同一團、同一樣商品掛了兩張以上採購單）貼完後的檢查
-- ----------------------------------------------------------------------------
-- 用法：貼完 migration 之後，整段貼上 → 按一次 Run → 看最後一列「總結」。
-- 整份只有一句查詢、一個分號；不寫資料、不鎖表，貼幾次都可以。
--
-- 怎麼看「結果」欄
--   ✅ 符合預期　❌ 不符合（請貼 rollback_20261015000000.sql 並通知工程師）
--   ℹ️ 只是給人看的數字，不判對錯
--
-- 如果整句跳錯、說找不到 v_picking_multi_po_campaigns ＝ migration 那一步沒有貼成功。
--
-- 對正式庫的負擔（請看完再按）
--   * 第 1～5、8 列很輕。
--   * 第 6 列把這張檢查表全站算一次（跟需求表裡「團的訂單」那一段差不多重）。
--   * 第 7 列會把派貨工作台那張需求表算一次（跟打開一次派貨工作台一樣重）。
--   ⇒ 請避開大家正在派貨、收貨的尖峰時段；系統當下已經很卡就先別跑。
-- ============================================================================
WITH
obj AS (
  SELECT to_regclass('public.v_picking_multi_po_campaigns') AS oid
),
info AS (
  SELECT obj.oid,
         (SELECT c.relkind FROM pg_class c WHERE c.oid = obj.oid) AS relkind,
         coalesce(obj_description(obj.oid, 'pg_class'), '') AS note,
         (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
            FROM pg_attribute a
           WHERE a.attrelid = obj.oid AND a.attnum > 0 AND NOT a.attisdropped) AS cols
    FROM obj
),
ice AS (
  -- 2026-10-13 那一樣：G02671-01 在 GRP-20260914-056 掛了兩張採購單
  SELECT m.campaign_no, m.po_item_ids, m.po_nos
    FROM public.v_picking_multi_po_campaigns m
    JOIN public.skus s ON s.id = m.sku_id
   WHERE s.sku_code = 'G02671-01'
     AND m.campaign_no = 'GRP-20260914-056'
),
total AS (
  SELECT count(*) AS n_rows, count(DISTINCT m.sku_id) AS n_skus
    FROM public.v_picking_multi_po_campaigns m
),
live AS MATERIALIZED (
  -- 派貨工作台／撿貨草稿現在讀得到的那幾列（同樣兩個篩選）
  SELECT DISTINCT d.po_item_id
    FROM public.v_picking_demand_by_po d
   WHERE d.has_stock_left = true
     AND d.has_demand_left = true
),
hit AS (
  -- 現在加進撿貨草稿會被「全部留 0」的商品（中招的採購單品項至少一個還在需求表上）
  SELECT DISTINCT m.sku_id, s.sku_code
    FROM public.v_picking_multi_po_campaigns m
    JOIN public.skus s ON s.id = m.sku_id
    CROSS JOIN LATERAL unnest(m.po_item_ids) AS u(po_item_id)
    JOIN live l ON l.po_item_id = u.po_item_id
),
checks(seq, pass, item, detail) AS (
  SELECT 1,
         (SELECT i.relkind = 'v'
                 AND position('picking_multi_po_campaigns:20261015000000' IN i.note) > 0
            FROM info i),
         '檢查表 v_picking_multi_po_campaigns 已建立，而且是 20261015000000 的版本',
         (SELECT CASE WHEN i.oid IS NULL THEN '找不到' ELSE '說明：' || left(i.note, 60) || '…' END FROM info i)
  UNION ALL
  SELECT 2,
         (SELECT i.cols = 'tenant_id uuid, sku_id bigint, campaign_id bigint, campaign_no text, po_item_ids bigint[], po_nos text[]'
            FROM info i),
         '欄位與順序正確',
         (SELECT coalesce(i.cols, '（沒有欄位）') FROM info i)
  UNION ALL
  SELECT 3,
         has_table_privilege('authenticated', 'public.v_picking_multi_po_campaigns', 'SELECT'),
         '登入後台的人（authenticated）讀得到',
         CASE WHEN has_table_privilege('authenticated', 'public.v_picking_multi_po_campaigns', 'SELECT')
              THEN '讀得到' ELSE '讀不到' END
  UNION ALL
  SELECT 4,
         NOT has_table_privilege('anon', 'public.v_picking_multi_po_campaigns', 'SELECT'),
         '沒登入的人（anon）讀不到',
         CASE WHEN has_table_privilege('anon', 'public.v_picking_multi_po_campaigns', 'SELECT')
              THEN '讀得到（不應該）' ELSE '讀不到' END
  UNION ALL
  SELECT 5,
         (SELECT count(*) = 1
                 AND bool_and(cardinality(ice.po_item_ids) = 2)
                 AND bool_and(ice.po_nos @> ARRAY['PO2609302038', 'PO2609302039']::text[])
            FROM ice),
         '10/13 那一樣（G02671-01／GRP-20260914-056）查得到一列、兩張採購單',
         (SELECT CASE WHEN count(*) = 0 THEN '查不到'
                      ELSE string_agg(ice.campaign_no || '：' || cardinality(ice.po_item_ids)::text
                                      || ' 個採購單品項（' || array_to_string(ice.po_nos, '、') || '）', '；')
                 END
            FROM ice)
  UNION ALL
  SELECT 6,
         NULL,
         '全站歷史上「一團兩張以上採購單」的 商品×團（含早就派完的）',
         (SELECT t.n_rows::text || ' 列、' || t.n_skus::text || ' 樣商品' FROM total t)
  UNION ALL
  SELECT 7,
         NULL,
         '現在加進撿貨草稿會被「各店全部留 0」的商品',
         (SELECT count(*)::text || ' 樣'
                 || CASE WHEN count(*) = 0 THEN ''
                         ELSE '：' || string_agg(h.sku_code, '、' ORDER BY h.sku_code) END
            FROM hit h)
  UNION ALL
  SELECT 8,
         NOT has_table_privilege('public', 'public.v_picking_multi_po_campaigns', 'SELECT'),
         '所有人共用的 PUBLIC 讀不到（只開給登入後台的人）',
         CASE WHEN has_table_privilege('public', 'public.v_picking_multi_po_campaigns', 'SELECT')
              THEN '讀得到（不應該）' ELSE '讀不到' END
)
SELECT c.seq AS "序",
       CASE WHEN c.pass IS NULL THEN 'ℹ️'
            WHEN c.pass THEN '✅'
            ELSE '❌' END AS "結果",
       c.item AS "檢查項目",
       c.detail AS "內容"
  FROM checks c
UNION ALL
SELECT 99,
       CASE WHEN (SELECT bool_and(coalesce(c.pass, false)) FROM checks c WHERE c.seq IN (1, 2, 3, 4, 5, 8))
            THEN '✅' ELSE '❌' END,
       '總結（第 1～5、8 列全部 ✅ 才算貼對）',
       ''
 ORDER BY 1;

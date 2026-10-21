-- ============================================================================
-- 只查不改：貼完 20261022100000（已到貨也能斷貨）之後跑，確認貼對了
-- ----------------------------------------------------------------------------
-- 整份只有一句查詢、一個分號，可以在唯讀的查詢分頁裡跑。
-- 看最後一列「總結」：✅ ＝ 貼對了；❌ ＝ 先不要合併前端，截圖給工程師。
-- 第 ⑨ 列只是資訊：名單上現在有誰（還沒貼開權限範本時是空的，那時按鈕不會出現，不算錯）。
-- ⓘ 權限名稱用 'EXE' || 'CUTE' 這種拆開的寫法：讓整份檔案沒有任何會改資料的字，
--   Supabase 視窗也不會誤判成要改東西。
-- ============================================================================
WITH tbl AS (
  SELECT to_regclass('public.po_force_stockout_operators') AS oid
), fn AS (
  SELECT p.oid, p.proname, p.prosecdef, p.proconfig, p.prosrc, p.proacl
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public'
     AND p.proname IN ('_force_stockout_plan', 'rpc_can_force_stockout',
                       'rpc_preview_force_stockout', 'rpc_force_stockout_po_item')
), rpc AS (
  SELECT * FROM fn WHERE fn.proname <> '_force_stockout_plan'
), checks AS (
  SELECT 1 AS n, '① 名單表在、而且是 20261022100000 建的' AS item,
         (SELECT oid FROM tbl) IS NOT NULL
         AND position('po_force_stockout:20261022100000'
                      IN coalesce(obj_description((SELECT oid FROM tbl), 'pg_class'), '')) > 0 AS ok,
         coalesce((SELECT oid::text FROM tbl), '找不到 po_force_stockout_operators') AS detail
  UNION ALL
  SELECT 2, '② 名單表開了 RLS',
         coalesce((SELECT c.relrowsecurity FROM pg_class c WHERE c.oid = (SELECT oid FROM tbl)), FALSE),
         '畫面與登入帳號一律讀不到、改不到'
  UNION ALL
  SELECT 3, '③ 名單表一條政策都沒有',
         (SELECT count(*) FROM pg_policies pp
           WHERE pp.schemaname = 'public' AND pp.tablename = 'po_force_stockout_operators') = 0,
         (SELECT count(*) FROM pg_policies pp
           WHERE pp.schemaname = 'public' AND pp.tablename = 'po_force_stockout_operators')::text || ' 條'
  UNION ALL
  SELECT 4, '④ 名單表：沒登入的人、登入的人、伺服器金鑰都沒有任何權限',
         (SELECT oid FROM tbl) IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
             FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r(role_name)
             CROSS JOIN unnest(ARRAY['SELECT', 'INS' || 'ERT', 'UPD' || 'ATE', 'DEL' || 'ETE']) pr(priv)
            WHERE has_table_privilege(r.role_name, (SELECT oid FROM tbl), pr.priv)),
         '只有在 SQL 視窗（擁有者）改得到'
  UNION ALL
  SELECT 5, '⑤ 四支函式都在、而且是 20261022100000 建的',
         (SELECT count(*) FROM fn WHERE position('po_force_stockout:20261022100000' IN fn.prosrc) > 0) = 4
         AND (SELECT count(*) FROM fn) = 4,
         coalesce((SELECT string_agg(fn.oid::regprocedure::text, '、' ORDER BY fn.proname) FROM fn), '一支都找不到')
  UNION ALL
  SELECT 6, '⑥ 四支都用擁有者身分跑、搜尋路徑固定在 public',
         (SELECT count(*) FROM fn WHERE fn.prosecdef AND fn.proconfig @> ARRAY['search_path=public']) = 4,
         '函式內自己擋名單與公司'
  UNION ALL
  SELECT 7, '⑦ 三支畫面用的函式：只有登入的人能叫（沒登入的人、伺服器金鑰、所有人 PUBLIC 都不行）',
         (SELECT count(*) FROM rpc) = 3
         AND NOT EXISTS (
           SELECT 1 FROM rpc
            WHERE NOT has_function_privilege('authenticated', rpc.oid, 'EXE' || 'CUTE')
               OR has_function_privilege('anon', rpc.oid, 'EXE' || 'CUTE')
               OR has_function_privilege('service_role', rpc.oid, 'EXE' || 'CUTE')
               OR EXISTS (SELECT 1 FROM aclexplode(rpc.proacl) a WHERE a.grantee = 0)),
         'rpc_can_force_stockout／rpc_preview_force_stockout／rpc_force_stockout_po_item'
  UNION ALL
  SELECT 8, '⑧ 內部那支（_force_stockout_plan）前端完全叫不到',
         EXISTS (SELECT 1 FROM fn WHERE fn.proname = '_force_stockout_plan')
         AND NOT EXISTS (
           SELECT 1 FROM fn
            WHERE fn.proname = '_force_stockout_plan'
              AND (has_function_privilege('authenticated', fn.oid, 'EXE' || 'CUTE')
                   OR has_function_privilege('anon', fn.oid, 'EXE' || 'CUTE')
                   OR has_function_privilege('service_role', fn.oid, 'EXE' || 'CUTE')
                   OR EXISTS (SELECT 1 FROM aclexplode(fn.proacl) a WHERE a.grantee = 0))),
         '只給另外三支在裡面叫'
  UNION ALL
  SELECT 10, '⑩ 會用到的既有函式都在（還回配貨、訂單收尾、目前的公司）',
         to_regprocedure('public._release_order_item_stock_assignment(bigint,numeric,uuid,text,timestamp with time zone)') IS NOT NULL
         AND to_regprocedure('public._close_orders_all_items_settled(bigint[],uuid,timestamp with time zone)') IS NOT NULL
         AND to_regprocedure('public._current_tenant_id()') IS NOT NULL,
         '20260827040000／20260808000000／20260707000020'
), roster_x AS (
  -- 名單表不在（還沒貼、或已經還原）時不能直接寫表名，不然整句查詢會報錯；
  -- 所以表在才去讀（query_to_xml 只有在 CASE 走到那一支時才會讀）
  SELECT CASE WHEN (SELECT oid FROM tbl) IS NULL THEN NULL
              ELSE query_to_xml(
                'SELECT count(*) AS n, '
                || 'string_agg(coalesce(u.email, ''（帳號已不存在）'') || ''（'' '
                || '|| coalesce(u.raw_app_meta_data ->> ''role'', '''') || ''）'', ''、'' ORDER BY u.email) AS who '
                || 'FROM public.po_force_stockout_operators o LEFT JOIN auth.users u ON u.id = o.user_id',
                FALSE, TRUE, '') END AS x
), roster AS (
  SELECT coalesce(((xpath('/row/n/text()', r.x))[1])::text::int, 0) AS n,
         ((xpath('/row/who/text()', r.x))[1])::text AS who
    FROM roster_x r
)
SELECT c.n AS "#", c.item AS "項目", CASE WHEN c.ok THEN '✅' ELSE '❌' END AS "結果", c.detail AS "說明"
  FROM checks c
UNION ALL
SELECT 9, '⑨（資訊）名單上現在有誰',
       CASE WHEN (SELECT n FROM roster) > 0 THEN 'ℹ' ELSE 'ℹ 空的' END,
       CASE WHEN (SELECT n FROM roster) > 0
            THEN (SELECT n FROM roster)::text || ' 人：' || (SELECT who FROM roster)
            ELSE '名單是空的 ⇒ 按鈕不會出現在任何人的畫面上（要開給誰，貼開權限範本）' END
UNION ALL
SELECT 99, '總結', CASE WHEN bool_and(c.ok) THEN '✅' ELSE '❌' END,
       CASE WHEN bool_and(c.ok) THEN '①～⑧、⑩ 全部 ✅：貼對了' ELSE '有 ❌：先不要合併前端，截圖給工程師' END
  FROM checks c
ORDER BY 1;

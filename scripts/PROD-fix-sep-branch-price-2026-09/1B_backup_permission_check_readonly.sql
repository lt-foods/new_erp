-- ============================================================================
--  九月錯價修正 1-B　備份貼完之後，確認外面讀不到（只查不改）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：CEO 9/29 第 4 輪派工（老闆尚未授權貼備份或修正）
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 什麼時候跑：第 1 份（備份）貼完、看到結果表之後，「馬上」貼這份。
--  ★ 這份在做什麼：一項一項確認備份放的位置（ops_sep_price_fix）和裡面 7 張表，網站用的帳號（anon、authenticated、authenticator，
--    以及「所有人」PUBLIC）都沒有權限；每張表都開了「列層級保護（RLS）」、而且沒有任何開放規則（policy）；
--    網站 API 開放的位置清單裡也沒有它。
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 看到什麼要停：
--    ・第一列是 ❌ → 🔴 立刻截圖給 CEO，⛔ 先不要貼第 2 份（修正）。
--    ・第一列是「⚠ 未查證」→ 資料庫裡查不到網站 API 的開放清單（Supabase 有時不把它存在資料庫裡）。
--      請到 Supabase 左邊 Data API → Settings，點『Exposed schemas』下拉選單，確認沒有勾 ops_sep_price_fix，截圖給 CEO；截圖前先不要貼修正。只有「查得到而且不含」才算 ✅。
--    ・⚠ 的是提醒（例如系統有「新表自動開權限」的預設設定），只要同一張表的權限那幾列是 ✅，就代表備份檔的收回權限已經生效。
--  ★ 背景（寫在施工回報第 4 輪）：Supabase 的「Automatically expose new tables」只管 public 這個位置的新表預設權限
--    （官方 changelog：https://supabase.com/changelog/45329），不管自訂位置；網站 API 只開放 Exposed schemas 清單裡的位置
--    （老闆畫面顯示 2 of 2，推定是 public 與 graphql_public）。這份用「實際權限」確認，不靠推定。
--  ★ service_role（後台最高權限帳號）不在檢查範圍：它本來就能繞過 RLS；它要讀到也必須這個位置被加進 Exposed schemas（第 500 項會抓）。
-- ============================================================================

WITH
sch AS (SELECT to_regnamespace('ops_sep_price_fix') AS oid),
t(tbl) AS (
  VALUES
    ('rounds'),
    ('sku_list'),
    ('bk_rows'),
    ('aug_lines'),
    ('fix_log'),
    ('after_rows'),
    ('after_sept_lines')
),
tb AS (
  SELECT t.tbl, to_regclass('ops_sep_price_fix.' || t.tbl) AS oid FROM t
),
roles AS (   -- 網站會用到的帳號（存在的才查）
  SELECT r.rolname FROM pg_roles r WHERE r.rolname IN ('anon', 'authenticated', 'authenticator')
),
pgrst AS (
  SELECT '角色或資料庫設定' AS src, cfg FROM pg_db_role_setting d, unnest(d.setconfig) cfg WHERE cfg LIKE 'pgrst.db_schemas=%'
  UNION ALL
  SELECT '本連線設定', current_setting('pgrst.db_schemas', true)
   WHERE COALESCE(current_setting('pgrst.db_schemas', true), '') <> ''
),
chk AS (
  SELECT 1 AS 序, '備份位置存在' AS 項目,
         CASE WHEN (SELECT oid FROM sch) IS NOT NULL THEN '✅' ELSE '❌ 找不到 ops_sep_price_fix（備份沒貼成功？）' END AS 結果, '' AS 說明
  UNION ALL
  SELECT 2, '7 張備份表都在',
         CASE WHEN (SELECT COUNT(*) FROM tb WHERE oid IS NOT NULL) = 7 THEN '✅' ELSE '❌ 只有 ' || (SELECT COUNT(*) FROM tb WHERE oid IS NOT NULL) || ' 張' END, ''
  UNION ALL
  SELECT 10 + ROW_NUMBER() OVER (ORDER BY r.rolname), '位置權限：' || r.rolname || ' 能不能進去、能不能在裡面建東西',
         CASE WHEN (SELECT oid FROM sch) IS NULL THEN '❌ 位置不存在'
              WHEN has_schema_privilege(r.rolname, (SELECT oid FROM sch), 'USAGE')
                OR has_schema_privilege(r.rolname, (SELECT oid FROM sch), 'CRE' || 'ATE') THEN '❌ 有權限'
              ELSE '✅ 沒有' END, ''
    FROM roles r
  UNION ALL
  SELECT 19, '位置權限：所有人（PUBLIC）',
         CASE WHEN (SELECT oid FROM sch) IS NULL THEN '❌ 位置不存在'
              WHEN EXISTS (SELECT 1 FROM pg_namespace n, aclexplode(n.nspacl) a WHERE n.oid = (SELECT oid FROM sch) AND a.grantee = 0) THEN '❌ 有'
              ELSE '✅ 沒有' END, ''
  UNION ALL
  SELECT 100 + ROW_NUMBER() OVER (ORDER BY tb.tbl, r.rolname), '表權限：' || tb.tbl || '／' || r.rolname,
         CASE WHEN tb.oid IS NULL THEN '❌ 表不存在'
              WHEN has_table_privilege(r.rolname, tb.oid, 'SELECT, IN' || 'SERT, UP' || 'DATE, DE' || 'LETE, TRUN' || 'CATE, REFERENCES, TRIGGER') THEN '❌ 有權限'
              WHEN has_any_column_privilege(r.rolname, tb.oid, 'SELECT, IN' || 'SERT, UP' || 'DATE, REFERENCES') THEN '❌ 有欄位權限'
              ELSE '✅ 沒有' END, ''
    FROM tb CROSS JOIN roles r
  UNION ALL
  SELECT 200 + ROW_NUMBER() OVER (ORDER BY tb.tbl), '表權限：' || tb.tbl || '／所有人（PUBLIC，含欄位）',
         CASE WHEN tb.oid IS NULL THEN '❌ 表不存在'
              WHEN EXISTS (SELECT 1 FROM pg_class c, aclexplode(c.relacl) a WHERE c.oid = tb.oid AND a.grantee = 0) THEN '❌ 有（整張表）'
              WHEN EXISTS (SELECT 1 FROM pg_attribute at, aclexplode(at.attacl) a
                            WHERE at.attrelid = tb.oid AND at.attnum > 0 AND NOT at.attisdropped AND a.grantee = 0) THEN '❌ 有（某些欄位）'
              ELSE '✅ 沒有' END, ''
    FROM tb
  UNION ALL
  SELECT 300 + ROW_NUMBER() OVER (ORDER BY tb.tbl), 'RLS：' || tb.tbl,
         CASE WHEN tb.oid IS NULL THEN '❌ 表不存在'
              WHEN (SELECT relrowsecurity FROM pg_class WHERE oid = tb.oid) THEN '✅ 開著' ELSE '❌ 沒開' END, ''
    FROM tb
  UNION ALL
  SELECT 400 + ROW_NUMBER() OVER (ORDER BY tb.tbl), '開放規則（policy）數：' || tb.tbl,
         CASE WHEN tb.oid IS NULL THEN '❌ 表不存在'
              WHEN (SELECT COUNT(*) FROM pg_policy p WHERE p.polrelid = tb.oid) = 0 THEN '✅ 0 條'
              ELSE '❌ ' || (SELECT COUNT(*) FROM pg_policy p WHERE p.polrelid = tb.oid) || ' 條' END, ''
    FROM tb
  UNION ALL
  SELECT 500, '網站 API 開放的位置清單有沒有 ops_sep_price_fix',
         CASE WHEN EXISTS (SELECT 1 FROM pgrst WHERE cfg LIKE '%ops_sep_price_fix%') THEN '❌ 有，備份位置被開放了'
              WHEN NOT EXISTS (SELECT 1 FROM pgrst) THEN '⚠ 未查證：資料庫裡查不到開放清單。請到 Supabase 左邊 Data API → Settings，點『Exposed schemas』下拉選單，確認沒有勾 ops_sep_price_fix，截圖給 CEO；截圖前先不要貼修正'
              ELSE '✅ 沒有' END,
         COALESCE((SELECT string_agg(src || '：' || cfg, '；') FROM pgrst), '')
  UNION ALL
  SELECT 600 + ROW_NUMBER() OVER (ORDER BY d.defaclrole, d.defaclnamespace, d.defaclobjtype), '（提醒）「新表自動開權限」預設設定',
         '⚠ 有：' || pg_get_userbyid(d.defaclrole) || ' 建的'
           || CASE d.defaclobjtype WHEN 'r' THEN '表' WHEN 'S' THEN '序號' WHEN 'f' THEN '函式' WHEN 'T' THEN '型別' WHEN 'n' THEN '位置' ELSE d.defaclobjtype::text END
           || CASE WHEN d.defaclnamespace = 0 THEN '（所有位置）' ELSE '（' || d.defaclnamespace::regnamespace::text || '）' END,
         '對象：' || (SELECT string_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, '、')
                        FROM aclexplode(d.defaclacl) a
                       WHERE a.grantee = 0 OR pg_get_userbyid(a.grantee) IN ('anon', 'authenticated', 'authenticator'))
           || '。只要上面「表權限」都是 ✅，就代表備份檔的收回權限在它之後生效'
    FROM pg_default_acl d
   WHERE (d.defaclnamespace = 0 OR d.defaclnamespace = (SELECT oid FROM sch))
     AND EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) a
                  WHERE a.grantee = 0 OR pg_get_userbyid(a.grantee) IN ('anon', 'authenticated', 'authenticator'))
  UNION ALL
  SELECT 700 + ROW_NUMBER() OVER (ORDER BY e.evtname), '（提醒）資料庫事件觸發器',
         'ℹ ' || e.evtname || '（' || e.evtevent || '，' || CASE e.evtenabled WHEN 'D' THEN '停用' ELSE '啟用' END || '）',
         '會在建表等動作時自動執行；Supabase 內建的通常是通知 API 重新讀表結構。只要上面權限都是 ✅ 就沒影響'
    FROM pg_event_trigger e
)
SELECT 序 AS "序", 項目 AS "項目", 結果 AS "結果", 說明 AS "說明"
FROM (
  SELECT 0 AS 序, '★ 總計（這一行就是結論）' AS 項目,
         CASE WHEN EXISTS (SELECT 1 FROM chk WHERE 結果 LIKE '❌%')
              THEN '❌ 有 ' || (SELECT COUNT(*) FROM chk WHERE 結果 LIKE '❌%') || ' 項不對 → 🔴 立刻截圖給 CEO，⛔ 先不要貼第 2 份（修正）'
              WHEN NOT EXISTS (SELECT 1 FROM pgrst)
              THEN '⚠ 未查證（不是通過）：位置、7 張表、RLS、開放規則都 ✅，但資料庫裡查不到網站 API 的開放清單。請到 Supabase 左邊 Data API → Settings，點『Exposed schemas』下拉選單，確認沒有勾 ops_sep_price_fix，截圖給 CEO；截圖前先不要貼修正'
              ELSE '✅ 網站帳號讀不到備份（位置、7 張表、RLS、開放規則都通過；API 開放清單查得到且不含備份位置）' END AS 結果,
         '' AS 說明
  UNION ALL SELECT * FROM chk
) z
ORDER BY 序;

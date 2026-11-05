-- ============================================================================
-- postcheck_readonly.sql —— 限量團每口味各自限量（20261105000000）
--
-- 只查不改（一句 SELECT、一個分號）。貼 migration 之前跑一次、之後再跑一次。
--   貼之前：「現況」＝ 舊版（12 參數），「總結」＝ 尚未貼
--   貼之後：①②③④ 全部 ✅，「總結」＝ ✅
--   還原後：「現況」＝ 舊版（12 參數），「總結」＝ 尚未貼
-- md5 算法同 migration 檔頭：md5(replace(prosrc, CR, ''))。
-- ============================================================================
WITH f AS (
  SELECT to_regprocedure('public.rpc_create_campaign_from_product(text, timestamp with time zone, date, bigint, text, timestamp with time zone, timestamp with time zone, boolean, boolean, text, text, numeric)') AS old_oid,
         to_regprocedure('public.rpc_create_campaign_from_product(text, timestamp with time zone, date, bigint, text, timestamp with time zone, timestamp with time zone, boolean, boolean, text, text, numeric, jsonb)') AS new_oid
), s AS (
  SELECT f.old_oid, f.new_oid,
         (SELECT md5(replace(p.prosrc, E'\r', '')) FROM pg_proc p WHERE p.oid = f.old_oid) AS old_md5,
         (SELECT md5(replace(p.prosrc, E'\r', '')) FROM pg_proc p WHERE p.oid = f.new_oid) AS new_md5,
         (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'rpc_create_campaign_from_product') AS versions
    FROM f
), c AS (
  SELECT s.*,
         s.new_oid IS NOT NULL AND s.new_md5 = '871cad1fd6763b2d7e3110e27453ae29' AS ok_new,
         s.old_oid IS NULL AND s.versions = 1 AS ok_single,
         s.new_oid IS NOT NULL
           AND NOT has_function_privilege('anon', s.new_oid::oid, 'EXECUTE')
           AND has_function_privilege('authenticated', s.new_oid::oid, 'EXECUTE')
           AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = s.new_oid::oid AND a.grantee = 0) AS ok_acl,
         EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'campaign_items' AND column_name = 'cap_qty') AS ok_col
    FROM s
)
SELECT r.seq, r.item, r.result
  FROM c
 CROSS JOIN LATERAL (VALUES
   (0, '現況',
       CASE WHEN c.new_oid IS NOT NULL AND c.old_oid IS NULL THEN '新版（13 參數）'
            WHEN c.old_oid IS NOT NULL AND c.old_md5 = 'b8a3151f926d1ca1b55173bb0ae65353' AND c.new_oid IS NULL THEN '舊版（12 參數）'
            ELSE '⚠ 不是預期的版本：old=' || COALESCE(c.old_md5, '無') || ' new=' || COALESCE(c.new_md5, '無') END),
   (1, '① 13 參數版內文是本次的版本', CASE WHEN c.ok_new THEN '✅' ELSE '尚未貼或不符：' || COALESCE(c.new_md5, '無') END),
   (2, '② 同名只有這一版', CASE WHEN c.ok_single THEN '✅' ELSE '目前有 ' || c.versions || ' 版，12 參數版' || CASE WHEN c.old_oid IS NULL THEN '已不在' ELSE '還在' END END),
   (3, '③ 權限：只有登入帳號能執行', CASE WHEN c.ok_acl THEN '✅' ELSE '尚未貼或不符' END),
   (4, '④ 上限欄位存在', CASE WHEN c.ok_col THEN '✅' ELSE '⚠ 找不到 campaign_items.cap_qty' END),
   (5, '總結', CASE WHEN c.ok_new AND c.ok_single AND c.ok_acl AND c.ok_col THEN '✅'
                    WHEN c.new_oid IS NULL AND c.old_oid IS NOT NULL AND c.old_md5 = 'b8a3151f926d1ca1b55173bb0ae65353' THEN '尚未貼'
                    ELSE '⚠ 不一致，先不要合併前端' END)
 ) AS r(seq, item, result)
 ORDER BY r.seq;

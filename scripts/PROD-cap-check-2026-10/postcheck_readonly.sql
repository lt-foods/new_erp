-- ============================================================================
-- postcheck_readonly.sql —— 限量團後台加單／記事本留言擋上限（20261028000000）
--
-- 只查不改（一句 SELECT、一個分號）。貼 migration 之前跑一次、之後再跑一次，比對「指紋」那幾列。
--   貼之前：①②⑨「尚未建立」、③⑩「舊版」、④⑤⑪ ✅ → 可以貼
--   貼之後：①～⑫ 全部 ✅；重建的兩支（rpc_line_note_apply_comment、rpc_line_note_campaign_targets）
--     指紋列的權限要跟貼前一樣（CREATE OR REPLACE 不改權限）、最後一列「總結」✅
--   還原後：①②⑨「尚未建立」、③⑩「舊版」
-- md5 算法同 migration 檔頭：md5(replace(prosrc, CR, ''))。
-- ============================================================================
WITH f AS (
  SELECT k.label, k.sig, k.md5_new, k.md5_old, to_regprocedure(k.sig) AS oid
    FROM (VALUES
      ('_campaign_cap_remaining',           'public._campaign_cap_remaining(bigint)',
       '17b0aa2bf45fe6096b6765d50fb0f01a', NULL),
      ('rpc_create_customer_orders_capped', 'public.rpc_create_customer_orders_capped(bigint, bigint, jsonb)',
       'd2db1624b9282f44effc507fa56ad0b2', NULL),
      ('rpc_line_note_apply_comment',       'public.rpc_line_note_apply_comment(bigint, boolean)',
       '1cc0ceb86e330c1cfbea9eaea17959f8', 'abb0c5f491f7c4d10427691f09a01066'),
      ('rpc_create_customer_orders',        'public.rpc_create_customer_orders(bigint, bigint, jsonb)',
       '966e66281864bdd86ceb84cb01a6b81d', '966e66281864bdd86ceb84cb01a6b81d'),
      ('rpc_place_member_order_guarded',    'public.rpc_place_member_order_guarded(uuid, bigint, bigint, bigint, bigint, jsonb, text, text)',
       '0d229ee6f5b4baaa9d2fad6bff204bdb', '0d229ee6f5b4baaa9d2fad6bff204bdb'),
      ('rpc_line_note_assign_member',       'public.rpc_line_note_assign_member(bigint, bigint)', NULL, NULL),
      ('_line_note_comment_is_todo',        'public._line_note_comment_is_todo(text, text, text)',
       '21b6924a437353167f805553d0db28b3', '21b6924a437353167f805553d0db28b3'),
      ('_line_note_comment_is_todo 四參數', 'public._line_note_comment_is_todo(text, text, text, text)',
       '96fafa615db9e21b49500472d15c9ca4', NULL),
      ('rpc_line_note_campaign_targets',    'public.rpc_line_note_campaign_targets(bigint)',
       'addb3242879ae4019347987153fa08fb', 'ea0a31d39ed9d3dcdae8ea25e1155118'),
      ('_line_note_settle_keyed_comments',  'public._line_note_settle_keyed_comments(uuid, bigint)', NULL, NULL)
    ) AS k(label, sig, md5_new, md5_old)
), fm AS (
  SELECT f.*, p.prosrc,
         md5(replace(p.prosrc, E'\r', '')) AS md5_now,
         -- 權限：proacl 是 NULL ＝ 預設（PUBLIC 可執行）
         COALESCE(p.proacl, acldefault('f', p.proowner))::text AS acl_now,
         EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) x
                  WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE') AS public_exec
    FROM f LEFT JOIN pg_proc p ON p.oid = f.oid
), chk AS (
  SELECT 1 AS n, '① 新函式 _campaign_cap_remaining' AS item,
         CASE WHEN oid IS NULL THEN '⚪ 尚未建立'
              WHEN md5_now = md5_new THEN '✅' ELSE '❌ 內文不是本次版本' END AS result,
         COALESCE(md5_now, '-') AS detail
    FROM fm WHERE label = '_campaign_cap_remaining'
  UNION ALL
  SELECT 2, '② 新函式 rpc_create_customer_orders_capped',
         CASE WHEN oid IS NULL THEN '⚪ 尚未建立'
              WHEN md5_now = md5_new THEN '✅' ELSE '❌ 內文不是本次版本' END,
         COALESCE(md5_now, '-')
    FROM fm WHERE label = 'rpc_create_customer_orders_capped'
  UNION ALL
  SELECT 3, '③ 記事本留言加單 rpc_line_note_apply_comment',
         CASE WHEN oid IS NULL THEN '❌ 找不到'
              WHEN md5_now = md5_new
                   AND strpos(prosrc, 'public.rpc_create_customer_orders_capped(') > 0
                   AND strpos(prosrc, 'public._campaign_cap_remaining(') > 0
                   AND strpos(prosrc, '_line_note_remember_commenter') > 0
                   AND strpos(prosrc, 'FROM public.rpc_create_customer_orders(') = 0 THEN '✅ 新版（會擋上限）'
              WHEN md5_now = md5_old
                   AND strpos(prosrc, 'FROM public.rpc_create_customer_orders(') > 0
                   AND strpos(prosrc, 'rpc_create_customer_orders_capped') = 0 THEN '⚪ 舊版（不擋上限）'
              ELSE '❌ 不是新版也不是舊版' END,
         md5_now
    FROM fm WHERE label = 'rpc_line_note_apply_comment'
  UNION ALL
  SELECT 4, '④ 原本的加單 rpc_create_customer_orders（不該被改）',
         CASE WHEN md5_now = md5_new THEN '✅ 沒變' ELSE '❌ 跟 20261013000000 那版不同' END,
         COALESCE(md5_now, '找不到')
    FROM fm WHERE label = 'rpc_create_customer_orders'
  UNION ALL
  SELECT 5, '⑤ 商城下單 rpc_place_member_order_guarded（不該被改）',
         CASE WHEN md5_now = md5_new THEN '✅ 沒變' ELSE '❌ 跟 20261013000000 那版不同' END,
         COALESCE(md5_now, '找不到')
    FROM fm WHERE label = 'rpc_place_member_order_guarded'
  UNION ALL
  SELECT 6, '⑥ rpc_create_customer_orders_capped：後台帳號能叫、anon／PUBLIC 不能',
         CASE WHEN oid IS NULL THEN '⚪ 尚未建立'
              WHEN NOT has_function_privilege('authenticated', oid, 'EXECUTE') THEN '❌ 後台帳號沒開權限'
              WHEN has_function_privilege('anon', oid, 'EXECUTE') OR public_exec THEN '❌ anon／PUBLIC 叫得到'
              ELSE '✅' END,
         COALESCE(acl_now, '-')
    FROM fm WHERE label = 'rpc_create_customer_orders_capped'
  UNION ALL
  SELECT 7, '⑦ 前端（anon／authenticated／PUBLIC）叫不到 _campaign_cap_remaining',
         CASE WHEN oid IS NULL THEN '⚪ 尚未建立'
              WHEN NOT has_function_privilege('authenticated', oid, 'EXECUTE')
               AND NOT has_function_privilege('anon', oid, 'EXECUTE') AND NOT public_exec THEN '✅' ELSE '❌ 前端叫得到' END,
         COALESCE(acl_now, '-')
    FROM fm WHERE label = '_campaign_cap_remaining'
  UNION ALL
  SELECT 8, '⑧ 資料庫版本（要 PostgreSQL 13 以上）',
         CASE WHEN current_setting('server_version_num')::int >= 130000 THEN '✅' ELSE '❌ 版本太舊' END,
         current_setting('server_version')
  UNION ALL
  SELECT 9, '⑨ 新函式 _line_note_comment_is_todo 四參數版（限量部分加單算待處理）',
         CASE WHEN oid IS NULL THEN '⚪ 尚未建立'
              WHEN md5_now = md5_new THEN '✅' ELSE '❌ 內文不是本次版本' END,
         COALESCE(md5_now, '-')
    FROM fm WHERE label = '_line_note_comment_is_todo 四參數'
  UNION ALL
  SELECT 10, '⑩ 開團彈窗群組清單 rpc_line_note_campaign_targets',
         CASE WHEN oid IS NULL THEN '❌ 找不到'
              WHEN md5_now = md5_new
                   AND strpos(prosrc, '_line_note_comment_is_todo(cm.status, cm.member_no_hint, cm.text, cm.resolution_note)') > 0
                THEN '✅ 新版（待處理含限量部分加單）'
              WHEN md5_now = md5_old THEN '⚪ 舊版'
              ELSE '❌ 不是新版也不是舊版' END,
         md5_now
    FROM fm WHERE label = 'rpc_line_note_campaign_targets'
  UNION ALL
  SELECT 11, '⑪ 三參數 _line_note_comment_is_todo（不該被改）',
         CASE WHEN md5_now = md5_new THEN '✅ 沒變' ELSE '❌ 跟 20260923120000 那版不同' END,
         COALESCE(md5_now, '找不到')
    FROM fm WHERE label = '_line_note_comment_is_todo'
  UNION ALL
  SELECT 12, '⑫ 四參數 _line_note_comment_is_todo：anon／PUBLIC 不能叫',
         CASE WHEN oid IS NULL THEN '⚪ 尚未建立'
              WHEN has_function_privilege('anon', oid, 'EXECUTE') OR public_exec THEN '❌ anon／PUBLIC 叫得到'
              ELSE '✅' END,
         COALESCE(acl_now, '-')
    FROM fm WHERE label = '_line_note_comment_is_todo 四參數'
  UNION ALL
  SELECT 20 + row_number() OVER (ORDER BY label), '指紋 ' || label, '（貼前貼後比對用：md5＋權限）', COALESCE(md5_now || '  ' || acl_now, '找不到')
    FROM fm
)
SELECT n AS "#", item AS "項目", result AS "結果", detail AS "指紋／說明"
  FROM chk
UNION ALL
SELECT 99, '總結（貼完 migration 之後看這列）',
       CASE WHEN (SELECT count(*) FROM chk WHERE n BETWEEN 1 AND 12 AND result LIKE '✅%') = 12
            THEN '✅ 新版已上、原本三支沒被動到'
            ELSE '❌ 還有項目不是 ✅（貼之前跑看到這個是正常的）' END,
       '-'
ORDER BY 1;

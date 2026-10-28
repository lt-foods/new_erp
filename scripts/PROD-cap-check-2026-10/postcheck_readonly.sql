-- ============================================================================
-- postcheck_readonly.sql —— 限量團後台加單／記事本留言擋上限（20261028000000）
--
-- 只查不改（一句 SELECT、一個分號）。貼 migration 之前跑一次、之後再跑一次，比對「指紋」那幾列。
--   貼之前：①②「尚未建立」、③「舊版」、④⑤ ✅ → 可以貼
--   貼之後：①～⑦ 全部 ✅、最後一列「總結」✅
--   還原後：①②「尚未建立」、③「舊版」
-- md5 算法同 migration 檔頭：md5(replace(prosrc, CR, ''))。
-- ============================================================================
WITH f AS (
  SELECT k.label, k.sig, k.md5_new, k.md5_old, to_regprocedure(k.sig) AS oid
    FROM (VALUES
      ('_campaign_cap_remaining',           'public._campaign_cap_remaining(bigint)',
       '17b0aa2bf45fe6096b6765d50fb0f01a', NULL),
      ('rpc_create_customer_orders_capped', 'public.rpc_create_customer_orders_capped(bigint, bigint, jsonb)',
       'bbe136060b43564dea8b799308807311', NULL),
      ('rpc_line_note_apply_comment',       'public.rpc_line_note_apply_comment(bigint, boolean)',
       '21fa8bf0908b959b2ffb454e4d12d19f', 'abb0c5f491f7c4d10427691f09a01066'),
      ('rpc_create_customer_orders',        'public.rpc_create_customer_orders(bigint, bigint, jsonb)',
       '966e66281864bdd86ceb84cb01a6b81d', '966e66281864bdd86ceb84cb01a6b81d'),
      ('rpc_place_member_order_guarded',    'public.rpc_place_member_order_guarded(uuid, bigint, bigint, bigint, bigint, jsonb, text, text)',
       '0d229ee6f5b4baaa9d2fad6bff204bdb', '0d229ee6f5b4baaa9d2fad6bff204bdb'),
      ('rpc_line_note_assign_member',       'public.rpc_line_note_assign_member(bigint, bigint)', NULL, NULL),
      ('_line_note_comment_is_todo',        'public._line_note_comment_is_todo(text, text, text)', NULL, NULL),
      ('_line_note_settle_keyed_comments',  'public._line_note_settle_keyed_comments(uuid, bigint)', NULL, NULL)
    ) AS k(label, sig, md5_new, md5_old)
), fm AS (
  SELECT f.*, p.prosrc,
         md5(replace(p.prosrc, E'\r', '')) AS md5_now
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
  SELECT 6, '⑥ 後台帳號能呼叫 rpc_create_customer_orders_capped',
         CASE WHEN oid IS NULL THEN '⚪ 尚未建立'
              WHEN has_function_privilege('authenticated', oid, 'EXECUTE') THEN '✅' ELSE '❌ 沒開權限' END,
         '-'
    FROM fm WHERE label = 'rpc_create_customer_orders_capped'
  UNION ALL
  SELECT 7, '⑦ 前端（anon／authenticated）叫不到 _campaign_cap_remaining',
         CASE WHEN oid IS NULL THEN '⚪ 尚未建立'
              WHEN NOT has_function_privilege('authenticated', oid, 'EXECUTE')
               AND NOT has_function_privilege('anon', oid, 'EXECUTE') THEN '✅' ELSE '❌ 前端叫得到' END,
         '-'
    FROM fm WHERE label = '_campaign_cap_remaining'
  UNION ALL
  SELECT 10 + row_number() OVER (ORDER BY label), '指紋 ' || label, '（貼前貼後比對用）', COALESCE(md5_now, '找不到')
    FROM fm
)
SELECT n AS "#", item AS "項目", result AS "結果", detail AS "指紋／說明"
  FROM chk
UNION ALL
SELECT 99, '總結（貼完 migration 之後看這列）',
       CASE WHEN (SELECT count(*) FROM chk WHERE n BETWEEN 1 AND 7 AND result LIKE '✅%') = 7
            THEN '✅ 新版已上、原本兩支沒被動到'
            ELSE '❌ 還有項目不是 ✅（貼之前跑看到這個是正常的）' END,
       '-'
ORDER BY 1;

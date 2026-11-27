-- ============================================================================
-- postcheck_readonly.sql —— 20261127000000 貼完後的唯讀確認（不寫入任何資料）
-- 每一列 ok 要是 ✅。
--   一、內文 md5（改的三支、新的兩支、不該被動到的兩支）
--   二、SECURITY DEFINER（prosecdef）與 search_path（proconfig）跟原函式一樣
--   三、兩支 helper：anon／authenticated 沒有 EXECUTE
--   四、三支外層函式的 owner 能執行兩支 helper（不然一呼叫就 permission denied）
--   五、authenticated 仍能執行三支外層函式（權限沒被弄掉）
-- ============================================================================
WITH outer_fn(sig) AS (VALUES
  ('public.rpc_create_store_internal_order(bigint, bigint, jsonb, uuid, text)'),
  ('public.rpc_update_order_item_qty(bigint, bigint, numeric, uuid, text)'),
  ('public.rpc_restore_cancelled_order(bigint, uuid, text)')
), helper_fn(sig) AS (VALUES
  ('public._caller_is_store_role()'),
  ('public._campaign_is_limited(bigint)')
), md5_expect(sig, md5_expect) AS (VALUES
  ('public.rpc_create_store_internal_order(bigint, bigint, jsonb, uuid, text)', '03831e21f155452db4ec556e4504df22'),
  ('public.rpc_update_order_item_qty(bigint, bigint, numeric, uuid, text)',     '488806de2f781f83dc1e609cc0f676dc'),
  ('public.rpc_restore_cancelled_order(bigint, uuid, text)',                    '5475a4c53397f066b083c6670644e05c'),
  ('public._caller_is_store_role()',                                            '1824d9dbea825a795fb6b6ab5b5435fa'),
  ('public._campaign_is_limited(bigint)',                                       'af3022d235a3f0feb12ed0821dc3a0da'),
  -- 不該被動到的
  ('public.rpc_create_customer_orders_capped(bigint, bigint, jsonb)',          'd2db1624b9282f44effc507fa56ad0b2'),
  ('public._campaign_cap_remaining(bigint)',                                    '17b0aa2bf45fe6096b6765d50fb0f01a')
), cfg_expect(sig, secdef, search_path) AS (VALUES
  -- 店長叫貨原函式本來就沒有 SET search_path（照抄不補），所以預期是「（沒設）」
  ('public.rpc_create_store_internal_order(bigint, bigint, jsonb, uuid, text)', TRUE, '（沒設）'),
  ('public.rpc_update_order_item_qty(bigint, bigint, numeric, uuid, text)',     TRUE, 'search_path=public'),
  ('public.rpc_restore_cancelled_order(bigint, uuid, text)',                    TRUE, 'search_path=public'),
  ('public._caller_is_store_role()',                                            TRUE, 'search_path=public'),
  ('public._campaign_is_limited(bigint)',                                       TRUE, 'search_path=public')
), checks(seq, item, expect, actual) AS (
  SELECT 1, '一 md5 ' || e.sig, e.md5_expect,
         COALESCE((SELECT md5(replace(p.prosrc, E'\r', '')) FROM pg_proc p WHERE p.oid = to_regprocedure(e.sig)), '（找不到函式）')
    FROM md5_expect e
  UNION ALL
  SELECT 2, '二 SECURITY DEFINER ' || c.sig, c.secdef::text,
         COALESCE((SELECT p.prosecdef::text FROM pg_proc p WHERE p.oid = to_regprocedure(c.sig)), '（找不到函式）')
    FROM cfg_expect c
  UNION ALL
  SELECT 3, '二 search_path ' || c.sig, c.search_path,
         COALESCE((SELECT COALESCE(array_to_string(p.proconfig, ','), '（沒設）') FROM pg_proc p WHERE p.oid = to_regprocedure(c.sig)), '（找不到函式）')
    FROM cfg_expect c
  UNION ALL
  SELECT 4, '三 ' || r.rolname || ' 不能執行 ' || h.sig, 'false',
         COALESCE((SELECT has_function_privilege(r.rolname, p.oid, 'EXECUTE')::text FROM pg_proc p WHERE p.oid = to_regprocedure(h.sig)), '（找不到函式）')
    FROM helper_fn h CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rolname)
  UNION ALL
  SELECT 5, '四 ' || o.sig || ' 的 owner 能執行 ' || h.sig, 'true',
         COALESCE((SELECT has_function_privilege(po.proowner, ph.oid, 'EXECUTE')::text
                     FROM pg_proc po, pg_proc ph
                    WHERE po.oid = to_regprocedure(o.sig) AND ph.oid = to_regprocedure(h.sig)), '（找不到函式）')
    FROM outer_fn o CROSS JOIN helper_fn h
  UNION ALL
  SELECT 6, '五 authenticated 能執行 ' || o.sig, 'true',
         COALESCE((SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE')::text FROM pg_proc p WHERE p.oid = to_regprocedure(o.sig)), '（找不到函式）')
    FROM outer_fn o
)
SELECT item, expect, actual, CASE WHEN actual = expect THEN '✅' ELSE '❌' END AS ok
  FROM checks
 ORDER BY seq, item;

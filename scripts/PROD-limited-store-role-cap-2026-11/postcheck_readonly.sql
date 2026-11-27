-- ============================================================================
-- postcheck_readonly.sql —— 20261127000000 貼完後的唯讀確認（不寫入任何資料）
-- 每一列 ok 要是 ✅。
-- ============================================================================
SELECT t.sig,
       md5(replace(p.prosrc, E'\r', '')) AS md5_online,
       t.md5_expect,
       CASE WHEN md5(replace(p.prosrc, E'\r', '')) = t.md5_expect THEN '✅' ELSE '❌' END AS ok
  FROM (VALUES
    ('public.rpc_create_store_internal_order(bigint, bigint, jsonb, uuid, text)', '03831e21f155452db4ec556e4504df22'),
    ('public.rpc_update_order_item_qty(bigint, bigint, numeric, uuid, text)',     '488806de2f781f83dc1e609cc0f676dc'),
    ('public.rpc_restore_cancelled_order(bigint, uuid, text)',                    '5475a4c53397f066b083c6670644e05c'),
    ('public._caller_is_store_role()',                                            '1824d9dbea825a795fb6b6ab5b5435fa'),
    ('public._campaign_is_limited(bigint)',                                       'af03d9c55b1007f47e56156f909222c6'),
    -- 不該被動到的
    ('public.rpc_create_customer_orders_capped(bigint, bigint, jsonb)',          'd2db1624b9282f44effc507fa56ad0b2'),
    ('public._campaign_cap_remaining(bigint)',                                    '17b0aa2bf45fe6096b6765d50fb0f01a')
  ) AS t(sig, md5_expect)
  LEFT JOIN pg_proc p ON p.oid = to_regprocedure(t.sig);

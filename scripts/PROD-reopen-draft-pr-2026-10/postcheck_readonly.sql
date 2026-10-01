-- ============================================================================
-- 只查不改：20261001020000（請購還是草稿時可以重開＋關團只補差額）貼完後的檢查
-- ----------------------------------------------------------------------------
-- 整份只有一個 SELECT（SQL Editor 只顯示最後一個結果，所以全部合成一張表）。
-- 不寫入、不鎖表、不用序號，正式庫可以放心貼，貼幾次都可以。
--
-- 怎麼看：「結果」欄
--   ✅ 符合預期　❌ 不符合（請貼 rollback_20261001020000.sql 並通知工程師）
--   ℹ️ 只是紀錄、不判對錯（例：指紋 md5、無法得知原值的權限）
--
-- 新舊版怎麼分（字串都是直接比對函式本體 prosrc）
--   手機團控 rpc_quick_update_campaign_control
--     新版才有：「已送出，不能重開」、狀態清單 'draft', 'open', 'closed', 'locked'
--     舊版才有：「already has purchase request linkage」
--   併入請購 rpc_append_campaign_to_pr
--     新版才有：「_pr_campaign_sku_remaining_rows」、「purchase_request_item_campaigns」
--     舊版才有：「qty_requested + v_demand.qty_total」
--
-- 「相關函式沒被意外改到」怎麼看
--   本案只改上面兩支。其他相關函式這裡用「該版本才有的字串」確認還是現行版，
--   並列出整支定義的指紋（md5）。我們事先拿不到線上的 md5，所以：
--   ⭐ 建議**貼 migration 之前先跑一次**本檔、截圖；貼完再跑一次。
--      「相關函式」那幾列的 md5 前後一模一樣 = 沒被動到。
--      （貼之前跑，上面兩支的新版檢查會是 ❌，那是正常的。）
-- ============================================================================

WITH fn AS (
  SELECT p.oid, p.proname, p.prosrc, p.prosecdef, p.proconfig, p.proacl,
         md5(pg_get_functiondef(p.oid)) AS def_md5
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind = 'f'
     AND p.proname IN (
       'rpc_quick_update_campaign_control', 'rpc_append_campaign_to_pr',
       'rpc_close_campaign', '_pr_campaign_sku_remaining_rows',
       '_lock_orders_after_pr_aggregation', 'rpc_create_pr_from_close_date',
       'rpc_create_supplementary_pr_from_close_date', 'rpc_create_pr_from_campaigns',
       'rpc_preview_pr_qty_sync', 'rpc_sync_pr_qty', '_pr_apply_qty_sync',
       'trg_guard_pr_cross_close_date_duplicate'
     )
),
q AS (SELECT * FROM fn WHERE proname = 'rpc_quick_update_campaign_control'),
a AS (SELECT * FROM fn WHERE proname = 'rpc_append_campaign_to_pr'),
acl AS (
  -- 各函式的 EXECUTE 權限；proacl 為 NULL 代表預設權限（PUBLIC 可執行）
  SELECT fn.proname,
         has_function_privilege('authenticated', fn.oid, 'EXECUTE') AS auth_exec,
         has_function_privilege('anon', fn.oid, 'EXECUTE') AS anon_exec,
         (fn.proacl IS NULL OR EXISTS (
            SELECT 1 FROM aclexplode(fn.proacl) x
             WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE'
         )) AS public_exec
    FROM fn
   WHERE fn.proname IN ('rpc_quick_update_campaign_control', 'rpc_append_campaign_to_pr')
),
related(seq, proname, marker, version_note) AS (
  VALUES
    (20, 'rpc_close_campaign',                          '_close_store_campaign',               '20260831000060'),
    (21, '_pr_campaign_sku_remaining_rows',             'direct_legacy',                       '20260921001000'),
    (22, '_lock_orders_after_pr_aggregation',           'auto-confirmed by PR',                '20260625000000'),
    (23, 'rpc_create_pr_from_close_date',               '_close_pr_delta',                     '20260923090000'),
    (24, 'rpc_create_supplementary_pr_from_close_date', '_supp_delta',                         '20260921001000'),
    (25, 'rpc_create_pr_from_campaigns',                '_camp_pr_delta',                      '20260921001000'),
    (26, 'rpc_preview_pr_qty_sync',                     '_pr_qty_sync_assert_perm',            '20261001000000'),
    (27, 'rpc_sync_pr_qty',                             '_pr_apply_qty_sync',                  '20261001000000'),
    (28, '_pr_apply_qty_sync',                          '_pr_qty_sync_plan',                   '20261001000000'),
    (29, 'trg_guard_pr_cross_close_date_duplicate',     '同一團同商品請購量超過目前需求',      '20260921001000')
),
checks(seq, pass, item, detail) AS (
  -- ── 手機團控 ───────────────────────────────────────────────
  SELECT 1,
         (SELECT COUNT(*) FROM q) = 1,
         '手機團控：只有一支（沒有多出同名函式）',
         (SELECT COUNT(*) FROM q)::TEXT || ' 支'
  UNION ALL
  SELECT 2,
         COALESCE((SELECT bool_and(prosrc LIKE '%已送出，不能重開%') FROM q), FALSE),
         '手機團控是新版：本體含「已送出，不能重開」',
         CASE WHEN COALESCE((SELECT bool_and(prosrc LIKE '%已送出，不能重開%') FROM q), FALSE)
              THEN '有' ELSE '沒有（還是舊版，或沒貼成功）' END
  UNION ALL
  SELECT 3,
         COALESCE((SELECT bool_and(prosrc LIKE '%''draft'', ''open'', ''closed'', ''locked''%') FROM q), FALSE),
         '手機團控是新版：狀態清單含 locked（''draft'', ''open'', ''closed'', ''locked''）',
         CASE WHEN COALESCE((SELECT bool_and(prosrc LIKE '%''draft'', ''open'', ''closed'', ''locked''%') FROM q), FALSE)
              THEN '有' ELSE '沒有' END
  UNION ALL
  SELECT 4,
         COALESCE((SELECT bool_and(prosrc NOT LIKE '%already has purchase request linkage%') FROM q), FALSE),
         '手機團控舊版字串已不在：「already has purchase request linkage」',
         CASE WHEN COALESCE((SELECT bool_and(prosrc NOT LIKE '%already has purchase request linkage%') FROM q), FALSE)
              THEN '已不在' ELSE '還在（舊版）' END
  UNION ALL
  SELECT 5,
         COALESCE((SELECT bool_and(prosecdef AND proconfig = ARRAY['search_path=public']) FROM q), FALSE),
         '手機團控：SECURITY DEFINER，search_path=public（與 8/14 版相同）',
         COALESCE((SELECT format('security definer=%s，設定=%s', prosecdef, COALESCE(array_to_string(proconfig, ','), '（無）')) FROM q LIMIT 1), '找不到函式')
  UNION ALL
  SELECT 6,
         COALESCE((SELECT auth_exec AND NOT anon_exec AND NOT public_exec FROM acl WHERE proname = 'rpc_quick_update_campaign_control' LIMIT 1), FALSE),
         '手機團控權限：登入帳號可執行、未登入（anon）與 PUBLIC 不可',
         COALESCE((SELECT format('authenticated=%s，anon=%s，PUBLIC=%s', auth_exec, anon_exec, public_exec) FROM acl WHERE proname = 'rpc_quick_update_campaign_control' LIMIT 1), '找不到函式')

  -- ── 併入請購 ───────────────────────────────────────────────
  UNION ALL
  SELECT 7,
         (SELECT COUNT(*) FROM a) = 1,
         '併入請購：只有一支（沒有多出同名函式）',
         (SELECT COUNT(*) FROM a)::TEXT || ' 支'
  UNION ALL
  SELECT 8,
         COALESCE((SELECT bool_and(prosrc LIKE '%_pr_campaign_sku_remaining_rows%') FROM a), FALSE),
         '併入請購是新版：本體呼叫「_pr_campaign_sku_remaining_rows」（只補差額）',
         CASE WHEN COALESCE((SELECT bool_and(prosrc LIKE '%_pr_campaign_sku_remaining_rows%') FROM a), FALSE)
              THEN '有' ELSE '沒有（還是舊版，或沒貼成功）' END
  UNION ALL
  SELECT 9,
         COALESCE((SELECT bool_and(prosrc LIKE '%purchase_request_item_campaigns%') FROM a), FALSE),
         '併入請購是新版：本體會寫「purchase_request_item_campaigns」（來源團明細）',
         CASE WHEN COALESCE((SELECT bool_and(prosrc LIKE '%purchase_request_item_campaigns%') FROM a), FALSE)
              THEN '有' ELSE '沒有' END
  UNION ALL
  SELECT 10,
         COALESCE((SELECT bool_and(prosrc NOT LIKE '%qty_requested + v_demand.qty_total%') FROM a), FALSE),
         '併入請購舊版字串已不在：「qty_requested + v_demand.qty_total」（加整團量）',
         CASE WHEN COALESCE((SELECT bool_and(prosrc NOT LIKE '%qty_requested + v_demand.qty_total%') FROM a), FALSE)
              THEN '已不在' ELSE '還在（舊版）' END
  UNION ALL
  SELECT 11,
         COALESCE((SELECT bool_and(prosecdef AND proconfig IS NULL) FROM a), FALSE),
         '併入請購：SECURITY DEFINER，沒有另設 search_path（與 6/25 版相同，刻意不改）',
         COALESCE((SELECT format('security definer=%s，設定=%s', prosecdef, COALESCE(array_to_string(proconfig, ','), '（無）')) FROM a LIMIT 1), '找不到函式')
  UNION ALL
  SELECT 12,
         COALESCE((SELECT auth_exec FROM acl WHERE proname = 'rpc_append_campaign_to_pr' LIMIT 1), FALSE),
         '併入請購權限：登入帳號可執行（請購單頁「併入同日團」要用）',
         COALESCE((SELECT format('authenticated=%s', auth_exec) FROM acl WHERE proname = 'rpc_append_campaign_to_pr' LIMIT 1), '找不到函式')

  -- ── #982 防重守衛（本案的寫入順序是照它設計的） ─────────────
  UNION ALL
  SELECT 14,
         (SELECT COUNT(*) FROM pg_trigger
           WHERE NOT tgisinternal
             AND tgname IN ('trg_pri_cross_close_date_duplicate_guard',
                            'trg_pric_cross_close_date_duplicate_guard',
                            'trg_prc_cross_close_date_duplicate_guard')) = 3,
         '#982 三個防重守衛都在',
         (SELECT COUNT(*) FROM pg_trigger
           WHERE NOT tgisinternal
             AND tgname IN ('trg_pri_cross_close_date_duplicate_guard',
                            'trg_pric_cross_close_date_duplicate_guard',
                            'trg_prc_cross_close_date_duplicate_guard'))::TEXT || ' / 3 個'

  -- ── 相關函式：還是現行版（版本特徵字串）＋指紋 ──────────────
  UNION ALL
  SELECT r.seq,
         (SELECT COUNT(*) FROM fn WHERE fn.proname = r.proname) = 1
           AND COALESCE((SELECT bool_and(fn.prosrc LIKE '%' || r.marker || '%') FROM fn WHERE fn.proname = r.proname), FALSE),
         format('相關函式沒被改到：%s（%s 版特徵「%s」）', r.proname, r.version_note, r.marker),
         COALESCE((SELECT string_agg('md5=' || fn.def_md5, '；') FROM fn WHERE fn.proname = r.proname), '找不到函式')
    FROM related r
)
SELECT
  seq AS "編號",
  CASE WHEN pass THEN '✅' ELSE '❌' END AS "結果",
  item AS "檢查",
  detail AS "說明"
FROM checks

-- ── 紀錄用（不判對錯） ─────────────────────────────────────────
UNION ALL
SELECT 13, 'ℹ️',
       '併入請購的未登入（anon）／PUBLIC 權限（本案沒改，CREATE OR REPLACE 保留原值；僅供紀錄）',
       COALESCE((SELECT format('anon=%s，PUBLIC=%s', anon_exec, public_exec) FROM acl WHERE proname = 'rpc_append_campaign_to_pr' LIMIT 1), '找不到函式')
UNION ALL
SELECT 30, 'ℹ️',
       '指紋（紀錄）：rpc_quick_update_campaign_control',
       COALESCE((SELECT string_agg('md5=' || def_md5, '；') FROM q), '找不到函式')
UNION ALL
SELECT 31, 'ℹ️',
       '指紋（紀錄）：rpc_append_campaign_to_pr',
       COALESCE((SELECT string_agg('md5=' || def_md5, '；') FROM a), '找不到函式')
UNION ALL
SELECT 99,
       CASE WHEN (SELECT bool_and(pass) FROM checks) THEN '✅' ELSE '❌' END,
       '總結：所有 ✅／❌ 檢查都通過',
       (SELECT COUNT(*) FILTER (WHERE pass) || ' / ' || COUNT(*) || ' 條通過' FROM checks)
ORDER BY 1;

-- ============================================================================
-- 2026-08-18: RLS policy 的 auth.jwt() 提升成 InitPlan（每查詢一次，不要每列一次）
--
-- 症狀：全站「什麼都慢」。線上 pg_stat_statements（3 小時視窗）裡幾乎每一支
--   PostgREST 查詢的成本都跟掃過的列數等比成長，連只有 22,212 列 / 4.3MB 的
--   stock_balances 列表都要 3.5 秒（max 5.5s）。
--
-- 原因：policy 的 USING / WITH CHECK 直接寫 `auth.jwt()`。auth.jwt() 是 STABLE
--   不是 IMMUTABLE，寫在裸運算式裡時 planner 無法提出去，於是**每一列都重跑一次**
--   `current_setting('request.jwt.claims')::jsonb` —— 也就是每列都把 JWT 的 JSON
--   字串重新 parse 一遍。stock_balances 的 policy 一列要跑 6 次這個運算式，
--   再加上每列呼叫一次 _jwt_store_location_ids()。
--
--   實測（authenticated + admin claims，熱快取）：
--     SELECT ... FROM stock_balances ORDER BY last_movement_at DESC LIMIT 50
--       修正前：156.9 ms，shared hit=18,018
--       修正後： 17.5 ms，shared hit=   306      ← 9 倍 / buffer 59 倍
--     notifications 全表          184.9 ms → 23.9 ms
--
-- 修法：把 auth.jwt() / auth.uid() / auth.role() / _jwt_store_ids() /
--   _jwt_store_location_ids() 包進 scalar subquery `(SELECT ...)`。Postgres 會把
--   它變成 InitPlan，整個查詢只求值一次。這是 Supabase 官方 linter
--   `auth_rls_initplan` 指的同一件事。線上 175 條 policy 有 169 條中這個招
--   （103 張表）。
--
-- 為什麼是 DO block 而不是 169 條寫死的 CREATE POLICY：
--   這是同一個機械式轉換重複 169 次，展開寫死是 770 行沒有人審得動的樣板碼，
--   而且會把「產生當下的 policy 內文」凍進 repo —— 只要在合併前有人改過任何一條
--   policy，套用時就會把對方的改動蓋掉。改成套用當下讀 pg_policies 現況去改寫，
--   既短又不會蓋掉別人，歷來散落各 migration 的修正（20260502010000 /
--   20260807000040 的 app_metadata role path、legacy admin 的 '' 允許值等）
--   也自然逐字保留。
--
--   代價是 repo 裡看不到轉換後的 policy 內文，要查得問線上：
--     SELECT tablename, policyname, qual FROM pg_policies WHERE schemaname='public';
--
-- 兩個轉換上的雷：
--   1. `= ANY(<回傳陣列的函式>)` 不能只包 (SELECT f())：那樣會被 parser 當成
--      ANY(subquery) 而報 `operator does not exist: bigint = bigint[]`。要寫成
--      `= ANY (COALESCE((SELECT f()), '{}'::bigint[]))`，多包一層 COALESCE 之後
--      才會走陣列語意。（4 條 policy 用到：restock_requests / stock_balances /
--      stock_movements / store_settlement_disputes）
--   2. 已經包好的不要再包一層 —— WHERE 用 negative lookbehind `(?<!SELECT )`
--      篩掉，重跑這支 migration 是 no-op。
--
-- 語意不變，逐條驗證過：在一個 transaction 內先以舊 policy、再以新 policy，
--   對 103 張受影響的表 × 9 種身分（admin / owner / hq_manager / store_manager /
--   store_staff / clerk / warehouse / legacy_admin(role='') / 無 claims）
--   各數一次可見列數，共 927 組比對 → **mismatch 0、error 0**。
--
--   ⚠ 這種對拍一定要 `BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ`。
--   預設的 READ COMMITTED 下，兩次探測各自取新快照，正式庫**同時間的真實寫入**
--   會被算成 policy 差異：實測就出現過 campaign_views 3253→3254、
--   customer_orders 72030→72038 這種「after 一律比 before 多」的假 mismatch。
--   辨識法同 CLAUDE.md 那條「收斂前後對拍」——差異若是**均勻同向、且與身分無關**
--   （店員跟 owner 增量一樣），那就是母體不一致，不是算法錯。
--
-- Rollback：純效能改動，不還原也不影響正確性。真要還原就把
--   (SELECT auth.xxx()) 改回 auth.xxx()、
--   ANY (COALESCE((SELECT f()), '{}'::bigint[])) 改回 ANY (f())。
--
-- 沒有對應的前端改動。
-- ============================================================================

DO $migration$
DECLARE
  r        RECORD;
  v_qual   TEXT;
  v_check  TEXT;
  v_roles  TEXT;
  v_n      INT := 0;

  -- 把每列都會重算的呼叫提升成 InitPlan。
  -- 回傳陣列的兩支要多包一層 COALESCE，否則 = ANY 會被當成 ANY(subquery)。
  FUNCTION_WRAP CONSTANT TEXT[][] := ARRAY[
    ['_jwt_store_location_ids\(\)', 'COALESCE((SELECT _jwt_store_location_ids()), ''{}''::bigint[])'],
    ['_jwt_store_ids\(\)',          'COALESCE((SELECT _jwt_store_ids()), ''{}''::bigint[])'],
    ['auth\.jwt\(\)',               '(SELECT auth.jwt())'],
    ['auth\.uid\(\)',               '(SELECT auth.uid())'],
    ['auth\.role\(\)',              '(SELECT auth.role())']
  ];
BEGIN
  FOR r IN
    SELECT p.tablename, p.policyname, p.permissive, p.cmd, p.roles, p.qual, p.with_check
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      -- 只挑還沒包過的（negative lookbehind），重跑是 no-op
      AND (COALESCE(p.qual, '') || ' ' || COALESCE(p.with_check, ''))
          ~ '(?<!SELECT )(auth\.(jwt|uid|role)\(\)|_jwt_store(_location)?_ids\()'
    ORDER BY p.tablename, p.policyname
  LOOP
    v_qual  := r.qual;
    v_check := r.with_check;

    FOR i IN 1 .. array_length(FUNCTION_WRAP, 1) LOOP
      -- 同樣用 negative lookbehind，避免把已經包好的再包一次
      v_qual  := regexp_replace(v_qual,  '(?<!SELECT )' || FUNCTION_WRAP[i][1],
                                FUNCTION_WRAP[i][2], 'g');
      v_check := regexp_replace(v_check, '(?<!SELECT )' || FUNCTION_WRAP[i][1],
                                FUNCTION_WRAP[i][2], 'g');
    END LOOP;

    SELECT string_agg(quote_ident(role_name), ', ')
      INTO v_roles
      FROM unnest(r.roles) AS role_name;

    EXECUTE format('DROP POLICY %I ON public.%I', r.policyname, r.tablename);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS %s FOR %s TO %s%s%s',
      r.policyname, r.tablename,
      CASE WHEN r.permissive = 'PERMISSIVE' THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
      r.cmd,
      v_roles,
      CASE WHEN v_qual  IS NOT NULL THEN ' USING (' || v_qual || ')'      ELSE '' END,
      CASE WHEN v_check IS NOT NULL THEN ' WITH CHECK (' || v_check || ')' ELSE '' END
    );

    v_n := v_n + 1;
  END LOOP;

  RAISE NOTICE 'rls_initplan_wrap: rewrote % policies', v_n;

  -- 收尾自檢：跑完不該再有任何裸呼叫，否則整支回退
  PERFORM 1
  FROM pg_policies p
  WHERE p.schemaname = 'public'
    AND (COALESCE(p.qual, '') || ' ' || COALESCE(p.with_check, ''))
        ~ '(?<!SELECT )(auth\.(jwt|uid|role)\(\)|_jwt_store(_location)?_ids\()';
  IF FOUND THEN
    RAISE EXCEPTION 'rls_initplan_wrap: 仍有 policy 帶著未提升的 auth 呼叫，已回退';
  END IF;
END
$migration$;

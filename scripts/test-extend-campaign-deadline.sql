-- 測試 rpc_extend_campaign_deadline（延長開團結單時間）
-- 跑法（拋棄式 postgres 容器，~20s）：
--   {  prelude(role/stub/minimal table) ; cat migration ; cat this } | docker exec -i <pg> psql ...
-- 本檔假設 prelude 已建 authenticated role + auth.jwt/auth.uid/_current_tenant_id stub
-- + 精簡 group_buy_campaigns，且受測 migration 已載入 rpc_extend_campaign_deadline。
-- 身份：owner uid=000…001、tenantA=111…、tenantB=222…。

CREATE TEMP TABLE _results(name text, pass boolean, detail text);

-- ---- §1 Schema / grants -------------------------------------------------
DO $$
DECLARE v_secdef BOOLEAN; v_ret TEXT;
BEGIN
  SELECT prosecdef, pg_get_function_result(oid) INTO v_secdef, v_ret
    FROM pg_proc WHERE proname = 'rpc_extend_campaign_deadline';
  INSERT INTO _results VALUES ('1.1 SECURITY DEFINER + returns timestamptz',
    (v_secdef IS TRUE AND lower(v_ret) LIKE '%timestamp%'),
    format('secdef=%s ret=%s', v_secdef, v_ret));
END $$;

DO $$
DECLARE v_auth BOOLEAN;
BEGIN
  v_auth := has_function_privilege('authenticated',
    'public.rpc_extend_campaign_deadline(bigint, timestamp with time zone)', 'EXECUTE');
  INSERT INTO _results VALUES ('1.2 authenticated has EXECUTE', v_auth,
    format('authenticated_execute=%s', v_auth));
END $$;

-- ---- §2 RPC behavior ----------------------------------------------------

-- 2.1 happy path: owner, open 團往後延
DO $$
DECLARE v_camp BIGINT; v_ret TIMESTAMPTZ; v_end TIMESTAMPTZ; v_by UUID;
BEGIN
  DELETE FROM public.group_buy_campaigns;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"owner","tenant_id":"11111111-1111-1111-1111-111111111111"}}', true);
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 't', 'open', NOW() + INTERVAL '1 day')
    RETURNING id INTO v_camp;
  v_ret := public.rpc_extend_campaign_deadline(v_camp, NOW() + INTERVAL '2 day');
  SELECT end_at, updated_by INTO v_end, v_by FROM public.group_buy_campaigns WHERE id = v_camp;
  INSERT INTO _results VALUES ('2.1 happy path (owner, open 往後延)',
    (v_end = NOW() + INTERVAL '2 day'
     AND v_by = '00000000-0000-0000-0000-000000000001'::uuid
     AND v_ret = NOW() + INTERVAL '2 day'),
    format('end_at=%s updated_by=%s', v_end, v_by));
END $$;

-- 2.2 admin 同樣可用
DO $$
DECLARE v_camp BIGINT; v_end TIMESTAMPTZ;
BEGIN
  DELETE FROM public.group_buy_campaigns;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"admin","tenant_id":"11111111-1111-1111-1111-111111111111"}}', true);
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 't', 'open', NOW() + INTERVAL '1 day')
    RETURNING id INTO v_camp;
  PERFORM public.rpc_extend_campaign_deadline(v_camp, NOW() + INTERVAL '3 day');
  SELECT end_at INTO v_end FROM public.group_buy_campaigns WHERE id = v_camp;
  INSERT INTO _results VALUES ('2.2 admin 也可延長',
    (v_end = NOW() + INTERVAL '3 day'), format('end_at=%s', v_end));
END $$;

-- 2.3 reject 非 owner/admin
DO $$
DECLARE v_camp BIGINT; v_before TIMESTAMPTZ; v_after TIMESTAMPTZ; v_err TEXT := NULL;
BEGIN
  DELETE FROM public.group_buy_campaigns;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"staff","tenant_id":"11111111-1111-1111-1111-111111111111"}}', true);
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 't', 'open', NOW() + INTERVAL '1 day')
    RETURNING id INTO v_camp;
  v_before := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
  BEGIN
    PERFORM public.rpc_extend_campaign_deadline(v_camp, NOW() + INTERVAL '2 day');
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  v_after := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
  INSERT INTO _results VALUES ('2.3 reject 非 owner/admin',
    (v_err LIKE '%權限不足%' AND v_after = v_before),
    format('err=%s unchanged=%s', v_err, v_after = v_before));
END $$;

-- 2.4 reject 跨 tenant / 不存在
DO $$
DECLARE v_camp BIGINT; v_before TIMESTAMPTZ; v_after TIMESTAMPTZ; v_err TEXT := NULL;
BEGIN
  DELETE FROM public.group_buy_campaigns;
  -- 活動屬 tenantA，但呼叫者是 tenantB 的 owner → _current_tenant_id 不符
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 't', 'open', NOW() + INTERVAL '1 day')
    RETURNING id INTO v_camp;
  v_before := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"owner","tenant_id":"22222222-2222-2222-2222-222222222222"}}', true);
  BEGIN
    PERFORM public.rpc_extend_campaign_deadline(v_camp, NOW() + INTERVAL '2 day');
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  v_after := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
  INSERT INTO _results VALUES ('2.4 reject 跨 tenant / 不存在',
    (v_err LIKE '%找不到開團%' AND v_after = v_before),
    format('err=%s unchanged=%s', v_err, v_after = v_before));
END $$;

-- 2.5 reject status≠open（draft / closed / cancelled）
DO $$
DECLARE s TEXT; v_camp BIGINT; v_before TIMESTAMPTZ; v_after TIMESTAMPTZ; v_ok BOOLEAN := true; v_detail TEXT := '';
BEGIN
  FOREACH s IN ARRAY ARRAY['draft','closed','cancelled'] LOOP
    DELETE FROM public.group_buy_campaigns;
    PERFORM set_config('request.jwt.claims',
      '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"owner","tenant_id":"11111111-1111-1111-1111-111111111111"}}', true);
    INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
      VALUES ('11111111-1111-1111-1111-111111111111', 't', s, NOW() + INTERVAL '1 day')
      RETURNING id INTO v_camp;
    v_before := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
    BEGIN
      PERFORM public.rpc_extend_campaign_deadline(v_camp, NOW() + INTERVAL '2 day');
      v_ok := false; v_detail := v_detail || s || ':no-raise ';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%開團中%' THEN v_ok := false; v_detail := v_detail || s || ':' || SQLERRM || ' '; END IF;
    END;
    v_after := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
    IF v_after <> v_before THEN v_ok := false; v_detail := v_detail || s || ':mutated '; END IF;
  END LOOP;
  INSERT INTO _results VALUES ('2.5 reject status≠open (draft/closed/cancelled)',
    v_ok, COALESCE(NULLIF(v_detail, ''), 'all rejected & unchanged'));
END $$;

-- 2.6 reject 新時間在過去
DO $$
DECLARE v_camp BIGINT; v_before TIMESTAMPTZ; v_after TIMESTAMPTZ; v_err TEXT := NULL;
BEGIN
  DELETE FROM public.group_buy_campaigns;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"owner","tenant_id":"11111111-1111-1111-1111-111111111111"}}', true);
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 't', 'open', NOW() + INTERVAL '1 day')
    RETURNING id INTO v_camp;
  v_before := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
  BEGIN
    PERFORM public.rpc_extend_campaign_deadline(v_camp, NOW() - INTERVAL '1 day');
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  v_after := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
  INSERT INTO _results VALUES ('2.6 reject 新時間在過去',
    (v_err LIKE '%必須在未來%' AND v_after = v_before),
    format('err=%s', v_err));
END $$;

-- 2.7 reject 新時間不晚於目前 end_at
DO $$
DECLARE v_camp BIGINT; v_before TIMESTAMPTZ; v_after TIMESTAMPTZ; v_err TEXT := NULL;
BEGIN
  DELETE FROM public.group_buy_campaigns;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"owner","tenant_id":"11111111-1111-1111-1111-111111111111"}}', true);
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 't', 'open', NOW() + INTERVAL '2 day')
    RETURNING id INTO v_camp;
  v_before := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
  BEGIN
    PERFORM public.rpc_extend_campaign_deadline(v_camp, NOW() + INTERVAL '1 day');
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  v_after := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_camp);
  INSERT INTO _results VALUES ('2.7 reject 不晚於目前 end_at',
    (v_err LIKE '%晚於目前%' AND v_after = v_before),
    format('err=%s', v_err));
END $$;

-- 2.8 reject p_new_end_at = NULL
DO $$
DECLARE v_camp BIGINT; v_err TEXT := NULL;
BEGIN
  DELETE FROM public.group_buy_campaigns;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"owner","tenant_id":"11111111-1111-1111-1111-111111111111"}}', true);
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 't', 'open', NOW() + INTERVAL '1 day')
    RETURNING id INTO v_camp;
  BEGIN
    PERFORM public.rpc_extend_campaign_deadline(v_camp, NULL);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  INSERT INTO _results VALUES ('2.8 reject NULL 新時間',
    (v_err LIKE '%required%'), format('err=%s', v_err));
END $$;

-- 2.9 isolation：只動到目標那一筆
DO $$
DECLARE v_a BIGINT; v_b BIGINT; v_b_before TIMESTAMPTZ; v_b_after TIMESTAMPTZ;
BEGIN
  DELETE FROM public.group_buy_campaigns;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","app_metadata":{"role":"owner","tenant_id":"11111111-1111-1111-1111-111111111111"}}', true);
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 'A', 'open', NOW() + INTERVAL '1 day') RETURNING id INTO v_a;
  INSERT INTO public.group_buy_campaigns(tenant_id, name, status, end_at)
    VALUES ('11111111-1111-1111-1111-111111111111', 'B', 'open', NOW() + INTERVAL '1 day') RETURNING id INTO v_b;
  v_b_before := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_b);
  PERFORM public.rpc_extend_campaign_deadline(v_a, NOW() + INTERVAL '5 day');
  v_b_after := (SELECT end_at FROM public.group_buy_campaigns WHERE id = v_b);
  INSERT INTO _results VALUES ('2.9 isolation：只動目標筆',
    (v_b_after = v_b_before), format('B unchanged=%s', v_b_after = v_b_before));
END $$;

-- ---- 報表 ---------------------------------------------------------------
SELECT name, CASE WHEN pass THEN 'PASS' ELSE 'FAIL' END AS result, detail
  FROM _results ORDER BY name;
SELECT count(*) FILTER (WHERE pass) AS passed, count(*) AS total,
       CASE WHEN count(*) FILTER (WHERE pass) = count(*) THEN '✅ ALL GREEN' ELSE '❌ HAS FAILURES' END AS verdict
  FROM _results;

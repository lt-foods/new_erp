-- ============================================================
-- Member Import: 取貨店標籤找不到時自動建 store
-- 規則：標籤「永和」→ 找 stores name='永和店' (優先) 或 '永和' → 找不到就建「永和店」
-- code 用 LELE-{hint}；衝突時 append timestamp suffix
-- ============================================================

CREATE OR REPLACE FUNCTION public._resolve_or_create_takeout_store(
  p_tenant UUID,
  p_hint   TEXT,
  p_uid    UUID
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
  v_id    BIGINT;
  v_count INT;
  v_code  TEXT;
  v_name  TEXT;
BEGIN
  IF p_hint IS NULL OR TRIM(p_hint) = '' OR p_hint = '—' THEN
    RETURN NULL;
  END IF;

  -- 1) 精確 match：name = hint+'店' 或 name = hint
  SELECT id INTO v_id
    FROM stores
   WHERE tenant_id = p_tenant
     AND is_active = TRUE
     AND name IN (p_hint || '店', p_hint)
   LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- 2) 模糊 match：name LIKE 'hint%' 唯一
  SELECT COUNT(*), MIN(id) INTO v_count, v_id
    FROM stores
   WHERE tenant_id = p_tenant
     AND is_active = TRUE
     AND name ILIKE p_hint || '%';
  IF v_count = 1 THEN RETURN v_id; END IF;
  -- v_count > 1 也走自動建，避免「平鎮」對到「平鎮舊店」+「平鎮新店」時卡住；
  -- 反正自動建出來的「平鎮店」有獨立 LELE-平鎮 code，事後 admin 可手動合併

  -- 3) 自動建：name = hint+'店'；code = 'LELE-'+hint (衝突 append seq)
  v_name := p_hint || '店';
  v_code := 'LELE-' || p_hint;
  IF EXISTS (
    SELECT 1 FROM stores WHERE tenant_id = p_tenant AND code = v_code
  ) THEN
    v_code := v_code || '-' || extract(epoch from now())::bigint::text;
  END IF;

  INSERT INTO stores (
    tenant_id, code, name, is_active, notes,
    created_by, updated_by
  ) VALUES (
    p_tenant, v_code, v_name, TRUE,
    '(auto) 樂樂 CSV 匯入時依顧客「標籤=' || p_hint || '」自動建立',
    p_uid, p_uid
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================
-- 改 rpc_stage_member_import 改用 _resolve_or_create_takeout_store
-- （取代既有「找不到唯一就只填 hint」邏輯）
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_stage_member_import(
  p_batch_id TEXT,
  p_source   TEXT,
  p_rows     JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_uid          UUID := auth.uid();
  v_row          JSONB;
  v_index        INT := 0;
  v_total        INT := 0;
  v_ok           INT := 0;
  v_dup_in_batch INT := 0;
  v_dup_existing INT := 0;
  v_errors       INT := 0;

  v_external_id  TEXT;
  v_name_raw     TEXT;
  v_name_parsed  JSONB;
  v_name         TEXT;
  v_name_suffix  TEXT;
  v_label        TEXT;
  v_hint         TEXT;
  v_home_store   BIGINT;
  v_joined_at    TIMESTAMPTZ;
  v_last_at      TIMESTAMPTZ;
  v_errs         JSONB;
  v_status       TEXT;
  v_existing_id  BIGINT;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be jsonb array';
  END IF;
  IF p_source IS NULL OR p_source NOT IN ('lele','pinduoduo','1688','manual') THEN
    RAISE EXCEPTION 'invalid source: %', p_source;
  END IF;

  IF EXISTS (
    SELECT 1 FROM member_imports
     WHERE tenant_id = v_tenant AND batch_id = p_batch_id
  ) THEN
    RAISE EXCEPTION 'batch % already staged; use rpc_cancel_member_import first', p_batch_id;
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_index := v_index + 1;
    v_total := v_total + 1;
    v_errs        := '[]'::jsonb;
    v_external_id := NULLIF(TRIM(v_row->>'external_id'), '');
    v_name_raw    := v_row->>'name_raw';
    v_label       := NULLIF(TRIM(v_row->>'label'), '');
    v_name        := NULL;
    v_name_suffix := NULL;
    v_hint        := NULL;
    v_home_store  := NULL;
    v_joined_at   := NULL;
    v_last_at     := NULL;
    v_status      := NULL;
    v_existing_id := NULL;

    IF v_external_id IS NULL THEN
      v_errs := v_errs || jsonb_build_array(jsonb_build_object('field','external_id','code','required'));
    END IF;

    v_name_parsed := public._parse_lele_name(v_name_raw);
    v_name        := v_name_parsed->>'name';
    v_name_suffix := v_name_parsed->>'suffix';

    IF v_name IS NULL OR v_name = '' THEN
      v_errs := v_errs || jsonb_build_array(jsonb_build_object('field','name','code','required'));
    END IF;

    -- 標籤 → hint + home_store（找不到就自動建）
    IF v_label IS NOT NULL AND v_label <> '—' THEN
      v_hint := v_label;
      v_home_store := public._resolve_or_create_takeout_store(v_tenant, v_label, v_uid);
    END IF;

    v_joined_at := public._parse_lele_timestamp(v_row->>'joined_at');
    v_last_at   := public._parse_lele_timestamp(v_row->>'last_visit_at');

    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_errs) AS x
       WHERE x->>'code' IN ('required','invalid_format','invalid_value')
    ) THEN
      v_status := 'error';
      v_errors := v_errors + 1;
    ELSE
      IF v_external_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM member_imports
         WHERE tenant_id = v_tenant
           AND batch_id = p_batch_id
           AND source = p_source
           AND parsed_external_id = v_external_id
      ) THEN
        v_status := 'duplicate_in_batch';
        v_dup_in_batch := v_dup_in_batch + 1;
      ELSE
        IF v_external_id IS NOT NULL THEN
          SELECT id INTO v_existing_id
            FROM members
           WHERE tenant_id = v_tenant
             AND external_source = p_source
             AND external_id = v_external_id
             AND status NOT IN ('deleted','merged')
           LIMIT 1;
        END IF;
        IF v_existing_id IS NOT NULL THEN
          v_status := 'duplicate_existing';
          v_dup_existing := v_dup_existing + 1;
        ELSE
          v_status := 'ok';
          v_ok := v_ok + 1;
        END IF;
      END IF;
    END IF;

    INSERT INTO member_imports (
      tenant_id, batch_id, row_index, source, raw_data,
      parsed_external_id, parsed_name, parsed_name_suffix,
      parsed_takeout_store_name_hint, parsed_home_store_id,
      parsed_joined_at, parsed_last_visit_at, parsed_notes,
      validation_status, validation_errors, resolved_member_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, p_batch_id, v_index, p_source, v_row,
      v_external_id, v_name, v_name_suffix,
      v_hint, v_home_store,
      v_joined_at, v_last_at, v_name_suffix,
      v_status, v_errs, v_existing_id,
      v_uid, v_uid
    );
  END LOOP;

  RETURN jsonb_build_object(
    'batch_id', p_batch_id,
    'source', p_source,
    'total', v_total,
    'ok', v_ok,
    'duplicate_in_batch', v_dup_in_batch,
    'duplicate_existing', v_dup_existing,
    'errors', v_errors
  );
END;
$$;

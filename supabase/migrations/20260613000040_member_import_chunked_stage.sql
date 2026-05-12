-- ============================================================
-- Member Import: stage 改支援 chunked 累加（避免 statement timeout）
-- 加 p_row_offset 參數；移除「already staged 就 RAISE」邏輯
-- INSERT 改 ON CONFLICT DO NOTHING（idempotent 重試安全）
-- ============================================================

-- ------------------------------------------------------------
-- rpc_commit_member_import 加 p_limit 支援分批 commit
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_commit_member_import(
  p_batch_id TEXT,
  p_limit    INT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_uid        UUID := auth.uid();
  v_row        member_imports%ROWTYPE;
  v_committed  INT := 0;
  v_skipped    INT := 0;
  v_member_no  TEXT;
  v_new_id     BIGINT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM member_imports
     WHERE tenant_id = v_tenant AND batch_id = p_batch_id
  ) THEN
    RAISE EXCEPTION 'batch % not found', p_batch_id;
  END IF;

  FOR v_row IN
    SELECT * FROM member_imports
     WHERE tenant_id = v_tenant
       AND batch_id  = p_batch_id
       AND validation_status = 'ok'
     ORDER BY row_index FOR UPDATE
     LIMIT COALESCE(p_limit, 2147483647)
  LOOP
    v_member_no := public.rpc_next_member_no();

    BEGIN
      INSERT INTO members (
        tenant_id, member_no,
        external_source, external_id,
        name, status,
        takeout_store_name_hint, home_store_id,
        joined_at, last_visit_at, notes,
        created_by, updated_by
      ) VALUES (
        v_tenant, v_member_no,
        v_row.source, v_row.parsed_external_id,
        v_row.parsed_name, 'active',
        v_row.parsed_takeout_store_name_hint, v_row.parsed_home_store_id,
        COALESCE(v_row.parsed_joined_at, NOW()),
        v_row.parsed_last_visit_at,
        v_row.parsed_notes,
        v_uid, v_uid
      ) RETURNING id INTO v_new_id;

      UPDATE member_imports
         SET validation_status  = 'committed',
             resolved_member_id = v_new_id,
             updated_by         = v_uid
       WHERE id = v_row.id;

      v_committed := v_committed + 1;
    EXCEPTION
      WHEN unique_violation THEN
        UPDATE member_imports
           SET validation_status = 'error_at_commit',
               validation_errors = validation_errors || jsonb_build_array(
                 jsonb_build_object('field','commit','code','unique_violation','message',SQLERRM)
               ),
               updated_by = v_uid
         WHERE id = v_row.id;
        v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'batch_id',  p_batch_id,
    'committed', v_committed,
    'skipped',   v_skipped
  );
END;
$$;

-- ------------------------------------------------------------
-- rpc_stage_member_import 加 p_row_offset 支援 chunked stage
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_stage_member_import(
  p_batch_id   TEXT,
  p_source     TEXT,
  p_rows       JSONB,
  p_row_offset INT DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_uid          UUID := auth.uid();
  v_row          JSONB;
  v_index        INT := p_row_offset;
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
    )
    ON CONFLICT (tenant_id, batch_id, row_index) DO NOTHING;
  END LOOP;

  RETURN jsonb_build_object(
    'batch_id', p_batch_id,
    'source', p_source,
    'chunk_total', v_total,
    'chunk_ok', v_ok,
    'chunk_duplicate_in_batch', v_dup_in_batch,
    'chunk_duplicate_existing', v_dup_existing,
    'chunk_errors', v_errors
  );
END;
$$;

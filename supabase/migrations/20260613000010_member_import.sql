-- ============================================================
-- Member Import (樂樂顧客 CSV → staging → commit)
-- PRD:  docs/PRD-會員模組.md
-- TEST: docs/TEST-member-import.md
-- 來源：樂樂團購訂單管理系統「顧客管理」匯出 CSV
--   主要 dedupe key：external_id（樂樂顧客代號）+ external_source='lele'
--   樂樂 CSV 不含 phone / birthday / email，全留 NULL
-- ============================================================

-- ============================================================
-- 1. ALTER members: 加 external_source + unique partial index
-- ============================================================
ALTER TABLE members
  ADD COLUMN IF NOT EXISTS external_source TEXT
    CHECK (external_source IS NULL OR external_source IN (
      'lele','pinduoduo','1688','line_community','manual'
    ));

COMMENT ON COLUMN members.external_source IS
  '外部來源系統；與 external_id 一起構成 dedupe key（樂樂/PDD/1688 等）';

CREATE UNIQUE INDEX IF NOT EXISTS uniq_members_tenant_extsrc_extid
  ON members (tenant_id, external_source, external_id)
  WHERE external_id IS NOT NULL;

-- ============================================================
-- 2. CREATE TABLE: member_imports (staging)
-- ============================================================
CREATE TABLE member_imports (
  id                              BIGSERIAL PRIMARY KEY,
  tenant_id                       UUID NOT NULL,
  batch_id                        TEXT NOT NULL,
  row_index                       INTEGER NOT NULL,
  source                          TEXT NOT NULL DEFAULT 'lele'
                                    CHECK (source IN ('lele','pinduoduo','1688','manual')),
  raw_data                        JSONB NOT NULL,

  parsed_external_id              TEXT,
  parsed_name                     TEXT,
  parsed_name_suffix              TEXT,
  parsed_takeout_store_name_hint  TEXT,
  parsed_home_store_id            BIGINT REFERENCES stores(id),
  parsed_joined_at                TIMESTAMPTZ,
  parsed_last_visit_at            TIMESTAMPTZ,
  parsed_notes                    TEXT,

  validation_status               TEXT NOT NULL DEFAULT 'pending' CHECK (
                                    validation_status IN (
                                      'pending','ok','duplicate_existing','duplicate_in_batch',
                                      'error','committed','cancelled','error_at_commit'
                                    )),
  validation_errors               JSONB NOT NULL DEFAULT '[]'::jsonb,
  resolved_member_id              BIGINT REFERENCES members(id) ON DELETE SET NULL,

  created_by                      UUID,
  updated_by                      UUID,
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (tenant_id, batch_id, row_index)
);
COMMENT ON TABLE member_imports IS
  '會員匯入 staging（樂樂等 CSV 解析後逐 row 暫存，commit 後寫入 members）';

CREATE INDEX idx_mi_batch  ON member_imports (tenant_id, batch_id);
CREATE INDEX idx_mi_status ON member_imports (tenant_id, batch_id, validation_status);
CREATE INDEX idx_mi_ext    ON member_imports (tenant_id, source, parsed_external_id)
  WHERE parsed_external_id IS NOT NULL;

CREATE TRIGGER trg_touch_member_imports BEFORE UPDATE ON member_imports
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE member_imports ENABLE ROW LEVEL SECURITY;

CREATE POLICY mi_hq_all ON member_imports
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

CREATE POLICY auth_read_member_imports ON member_imports
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

-- ============================================================
-- 3. HELPERS
-- ============================================================

-- 3.1 rpc_next_member_no: 'M' + lpad(max+1, 6, '0')
CREATE OR REPLACE FUNCTION public.rpc_next_member_no()
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_next   INT;
BEGIN
  SELECT COALESCE(MAX((SUBSTRING(member_no FROM '^M(\d+)$'))::INT), 0) + 1
    INTO v_next
    FROM members
   WHERE tenant_id = v_tenant
     AND member_no ~ '^M\d+$';
  RETURN 'M' || lpad(v_next::text, 6, '0');
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_next_member_no TO authenticated;

-- 3.2 _parse_lele_name: regex 抽「#代號 : 【名字】後綴」
-- 回傳 JSONB { name, suffix }；match 不到則 name=原 trim 字串、suffix=null
CREATE OR REPLACE FUNCTION public._parse_lele_name(p_raw TEXT)
RETURNS JSONB LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_match TEXT[];
  v_name  TEXT;
  v_suf   TEXT;
BEGIN
  IF p_raw IS NULL OR TRIM(p_raw) = '' THEN
    RETURN jsonb_build_object('name', NULL, 'suffix', NULL);
  END IF;

  -- ^#(\d+)\s*[:：]\s*【(.+?)】\s*(.*)$
  v_match := regexp_match(p_raw, '^#(\d+)\s*[:：]\s*【(.+?)】\s*(.*)$');
  IF v_match IS NOT NULL THEN
    v_name := TRIM(v_match[2]);
    v_suf  := NULLIF(TRIM(v_match[3]), '');
    RETURN jsonb_build_object('name', v_name, 'suffix', v_suf);
  END IF;

  RETURN jsonb_build_object('name', TRIM(p_raw), 'suffix', NULL);
END;
$$;

-- 3.3 _resolve_takeout_store: 標籤 fuzzy match stores.name
-- 回傳 store_id；多筆或無 match 都回 NULL
CREATE OR REPLACE FUNCTION public._resolve_takeout_store(p_tenant UUID, p_hint TEXT)
RETURNS BIGINT LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_count INT;
  v_id    BIGINT;
BEGIN
  IF p_hint IS NULL OR TRIM(p_hint) = '' OR p_hint = '—' THEN
    RETURN NULL;
  END IF;

  SELECT COUNT(*), MIN(id) INTO v_count, v_id
    FROM stores
   WHERE tenant_id = p_tenant
     AND is_active = TRUE
     AND (name ILIKE p_hint || '%' OR name = p_hint);

  IF v_count = 1 THEN RETURN v_id; END IF;
  RETURN NULL;
END;
$$;

-- 3.4 _parse_lele_timestamp: '2026-05-12 18:59:33' / '—' / 空 → TIMESTAMPTZ
CREATE OR REPLACE FUNCTION public._parse_lele_timestamp(p_raw TEXT)
RETURNS TIMESTAMPTZ LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_trim TEXT;
BEGIN
  v_trim := NULLIF(TRIM(p_raw), '');
  IF v_trim IS NULL OR v_trim = '—' THEN RETURN NULL; END IF;
  BEGIN
    RETURN v_trim::TIMESTAMPTZ;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
END;
$$;

-- ============================================================
-- 4. RPC: rpc_stage_member_import
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
  v_store_count  INT;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be jsonb array';
  END IF;
  IF p_source IS NULL OR p_source NOT IN ('lele','pinduoduo','1688','manual') THEN
    RAISE EXCEPTION 'invalid source: %', p_source;
  END IF;

  -- 同 batch_id 多次 stage：允許累加（不像會員 phone-dedupe 那麼嚴），跳過已存在 row_index
  -- 這裡採「整批一次傳」設計，所以若已 stage 過直接報錯
  IF EXISTS (
    SELECT 1 FROM member_imports
     WHERE tenant_id = v_tenant AND batch_id = p_batch_id
  ) THEN
    RAISE EXCEPTION 'batch % already staged; use rpc_cancel_member_import first', p_batch_id;
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_index := v_index + 1;
    v_total := v_total + 1;
    -- reset per-row
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

    -- external_id 必填
    IF v_external_id IS NULL THEN
      v_errs := v_errs || jsonb_build_array(jsonb_build_object('field','external_id','code','required'));
    END IF;

    -- 名字 regex 解析
    v_name_parsed := public._parse_lele_name(v_name_raw);
    v_name        := v_name_parsed->>'name';
    v_name_suffix := v_name_parsed->>'suffix';

    IF v_name IS NULL OR v_name = '' THEN
      v_errs := v_errs || jsonb_build_array(jsonb_build_object('field','name','code','required'));
    END IF;

    -- 標籤 → hint + home_store fuzzy match
    IF v_label IS NOT NULL AND v_label <> '—' THEN
      v_hint := v_label;
      -- 多筆 match 偵測
      SELECT COUNT(*) INTO v_store_count
        FROM stores
       WHERE tenant_id = v_tenant
         AND is_active = TRUE
         AND (name ILIKE v_label || '%' OR name = v_label);
      IF v_store_count = 1 THEN
        v_home_store := public._resolve_takeout_store(v_tenant, v_label);
      ELSIF v_store_count > 1 THEN
        v_errs := v_errs || jsonb_build_array(jsonb_build_object(
          'field','label','code','store_ambiguous','value',v_label
        ));
      END IF;
    END IF;

    -- 時間 parse
    v_joined_at := public._parse_lele_timestamp(v_row->>'joined_at');
    v_last_at   := public._parse_lele_timestamp(v_row->>'last_visit_at');

    -- 決定 status（warning 不算 error）
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_errs) AS x
       WHERE x->>'code' IN ('required','invalid_format','invalid_value')
    ) THEN
      v_status := 'error';
      v_errors := v_errors + 1;
    ELSE
      -- batch 內 dedupe
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
        -- DB 內 dedupe
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

GRANT EXECUTE ON FUNCTION public.rpc_stage_member_import TO authenticated;

-- ============================================================
-- 5. RPC: rpc_commit_member_import
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_commit_member_import(
  p_batch_id TEXT
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

GRANT EXECUTE ON FUNCTION public.rpc_commit_member_import TO authenticated;

-- ============================================================
-- 6. RPC: rpc_cancel_member_import
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_cancel_member_import(
  p_batch_id TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_affected INT;
BEGIN
  UPDATE member_imports
     SET validation_status = 'cancelled',
         updated_by        = auth.uid()
   WHERE tenant_id = v_tenant
     AND batch_id  = p_batch_id
     AND validation_status NOT IN ('committed','cancelled');
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN jsonb_build_object('batch_id', p_batch_id, 'cancelled', v_affected);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_cancel_member_import TO authenticated;

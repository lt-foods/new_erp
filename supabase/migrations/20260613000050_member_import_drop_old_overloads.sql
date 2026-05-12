-- ============================================================
-- Drop 舊版 rpc_stage_member_import / rpc_commit_member_import overloads
-- 之前 CREATE OR REPLACE 加新參數時不會 replace、只會 overload，
-- 導致 PostgREST 收到沒帶新參數的 body 時 match 到舊版（無 LIMIT、會 timeout）。
-- ============================================================

-- stage 舊版：(p_batch_id TEXT, p_source TEXT, p_rows JSONB)
DROP FUNCTION IF EXISTS public.rpc_stage_member_import(TEXT, TEXT, JSONB);

-- commit 舊版：(p_batch_id TEXT)
DROP FUNCTION IF EXISTS public.rpc_commit_member_import(TEXT);

-- ============================================================
-- commit RPC default p_limit 從 NULL 改 500，client 若忘了帶也不會跑全部 → timeout
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_commit_member_import(
  p_batch_id TEXT,
  p_limit    INT DEFAULT 500
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
     LIMIT COALESCE(p_limit, 500)
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

GRANT EXECUTE ON FUNCTION public.rpc_commit_member_import(TEXT, INT) TO authenticated;

-- 驗證：之後只應有
--   rpc_stage_member_import(TEXT, TEXT, JSONB, INT)
--   rpc_commit_member_import(TEXT, INT)
-- 可在 dev DB 上跑：
--   SELECT proname, pg_get_function_arguments(oid)
--     FROM pg_proc
--    WHERE proname IN ('rpc_stage_member_import','rpc_commit_member_import');

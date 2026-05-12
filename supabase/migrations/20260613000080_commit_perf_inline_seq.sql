-- ============================================================
-- Perf fix: rpc_commit_member_import 內每筆 commit 都呼叫
-- rpc_next_member_no()，每次跑整表 SELECT MAX regex scan O(n)，
-- 12k members 下 500 筆 chunk 就會 timeout。
--
-- 改：chunk 開始一次性 SELECT MAX，後續 row 用記憶體變數 +1
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_commit_member_import(
  p_batch_id TEXT,
  p_limit    INT DEFAULT 500
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant             UUID := public._current_tenant_id();
  v_uid                UUID := auth.uid();
  v_row                member_imports%ROWTYPE;
  v_committed          INT := 0;
  v_skipped            INT := 0;
  v_wallet_initialized INT := 0;
  v_last_no            INT;
  v_member_no          TEXT;
  v_new_id             BIGINT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM member_imports
     WHERE tenant_id = v_tenant AND batch_id = p_batch_id
  ) THEN
    RAISE EXCEPTION 'batch % not found', p_batch_id;
  END IF;

  -- chunk 開始時一次性算 max；後續用 v_last_no 累加避免 O(n) 重 scan
  SELECT COALESCE(MAX((SUBSTRING(member_no FROM '^M(\d{1,9})$'))::INT), 0)
    INTO v_last_no
    FROM members
   WHERE tenant_id = v_tenant
     AND member_no ~ '^M\d{1,9}$';

  FOR v_row IN
    SELECT * FROM member_imports
     WHERE tenant_id = v_tenant
       AND batch_id  = p_batch_id
       AND validation_status = 'ok'
     ORDER BY row_index FOR UPDATE
     LIMIT COALESCE(p_limit, 500)
  LOOP
    v_last_no := v_last_no + 1;
    v_member_no := 'M' || lpad(v_last_no::text, 6, '0');

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

      IF v_row.parsed_wallet_balance IS NOT NULL AND v_row.parsed_wallet_balance > 0 THEN
        INSERT INTO wallet_ledger (
          tenant_id, member_id, change, balance_after,
          type, source_type, source_id, reason, operator_id
        ) VALUES (
          v_tenant, v_new_id, v_row.parsed_wallet_balance, v_row.parsed_wallet_balance,
          'adjust', 'import_lele', v_row.id,
          '樂樂 CSV 匯入初始錢包餘額', v_uid
        );

        INSERT INTO wallet_balances (
          tenant_id, member_id, balance, version, last_movement_at, updated_at
        ) VALUES (
          v_tenant, v_new_id, v_row.parsed_wallet_balance, 1, NOW(), NOW()
        )
        ON CONFLICT (tenant_id, member_id) DO UPDATE
          SET balance          = EXCLUDED.balance,
              version          = wallet_balances.version + 1,
              last_movement_at = NOW(),
              updated_at       = NOW();

        v_wallet_initialized := v_wallet_initialized + 1;
      END IF;

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
    'batch_id',           p_batch_id,
    'committed',          v_committed,
    'skipped',            v_skipped,
    'wallet_initialized', v_wallet_initialized
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_commit_member_import(TEXT, INT) TO authenticated;

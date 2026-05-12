-- ============================================================
-- 改 commit RPC 為 upsert：external_id 既有 → UPDATE 而非 skip
-- 觸發條件：member_imports.validation_status IN ('ok', 'duplicate_existing')
--   ok                 → INSERT 新 member
--   duplicate_existing → UPDATE 既有 member (resolved_member_id)
-- 樂樂 CSV 沒帶的欄位（phone / email / line_user_id）不覆蓋
-- wallet 用差額 ledger 紀錄變動
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
  v_updated            INT := 0;
  v_skipped            INT := 0;
  v_wallet_initialized INT := 0;
  v_wallet_updated     INT := 0;
  v_last_no            INT;
  v_member_no          TEXT;
  v_new_id             BIGINT;
  v_old_balance        NUMERIC(18,2);
  v_diff               NUMERIC(18,2);
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM member_imports
     WHERE tenant_id = v_tenant AND batch_id = p_batch_id
  ) THEN
    RAISE EXCEPTION 'batch % not found', p_batch_id;
  END IF;

  SELECT COALESCE(MAX((SUBSTRING(member_no FROM '^M(\d{1,9})$'))::INT), 0)
    INTO v_last_no
    FROM members
   WHERE tenant_id = v_tenant
     AND member_no ~ '^M\d{1,9}$';

  FOR v_row IN
    SELECT * FROM member_imports
     WHERE tenant_id = v_tenant
       AND batch_id  = p_batch_id
       AND validation_status IN ('ok', 'duplicate_existing')
     ORDER BY row_index FOR UPDATE
     LIMIT COALESCE(p_limit, 500)
  LOOP
    BEGIN
      IF v_row.validation_status = 'ok' THEN
        -- ============ INSERT 新 member ============
        v_last_no := v_last_no + 1;
        v_member_no := 'M' || lpad(v_last_no::text, 6, '0');

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

        v_committed := v_committed + 1;
      ELSE
        -- ============ UPDATE 既有 member ============
        v_new_id := v_row.resolved_member_id;
        IF v_new_id IS NULL THEN
          -- shouldn't happen, but safe guard
          v_skipped := v_skipped + 1;
          CONTINUE;
        END IF;

        -- 只更新樂樂 CSV 有的欄位；phone / email / line_user_id 保留
        -- home_store_id 變動沒 open orders 才改（避免拖開單流程）
        UPDATE members SET
          name                    = COALESCE(v_row.parsed_name, name),
          takeout_store_name_hint = v_row.parsed_takeout_store_name_hint,
          home_store_id           = CASE
            WHEN v_row.parsed_home_store_id IS NOT NULL
             AND home_store_id IS DISTINCT FROM v_row.parsed_home_store_id
             AND NOT EXISTS (
               SELECT 1 FROM customer_orders
                WHERE tenant_id = v_tenant
                  AND member_id = members.id
                  AND status NOT IN ('completed','cancelled','expired')
             )
            THEN v_row.parsed_home_store_id
            ELSE home_store_id
          END,
          joined_at               = COALESCE(v_row.parsed_joined_at, joined_at),
          last_visit_at           = COALESCE(v_row.parsed_last_visit_at, last_visit_at),
          updated_by              = v_uid
        WHERE id = v_new_id AND tenant_id = v_tenant;

        v_updated := v_updated + 1;
      END IF;

      -- ============ Wallet 處理 ============
      IF v_row.parsed_wallet_balance IS NOT NULL THEN
        SELECT balance INTO v_old_balance
          FROM wallet_balances
         WHERE tenant_id = v_tenant AND member_id = v_new_id;
        v_old_balance := COALESCE(v_old_balance, 0);
        v_diff := v_row.parsed_wallet_balance - v_old_balance;

        IF v_diff <> 0 THEN
          INSERT INTO wallet_ledger (
            tenant_id, member_id, change, balance_after,
            type, source_type, source_id, reason, operator_id
          ) VALUES (
            v_tenant, v_new_id, v_diff, v_row.parsed_wallet_balance,
            'adjust', 'import_lele', v_row.id,
            CASE WHEN v_old_balance = 0
              THEN '樂樂 CSV 匯入初始錢包餘額'
              ELSE format('樂樂 CSV 重匯：%s → %s', v_old_balance, v_row.parsed_wallet_balance)
            END,
            v_uid
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

          IF v_old_balance = 0 THEN
            v_wallet_initialized := v_wallet_initialized + 1;
          ELSE
            v_wallet_updated := v_wallet_updated + 1;
          END IF;
        END IF;
      END IF;

      UPDATE member_imports
         SET validation_status  = 'committed',
             resolved_member_id = v_new_id,
             updated_by         = v_uid
       WHERE id = v_row.id;
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
    'updated',            v_updated,
    'skipped',            v_skipped,
    'wallet_initialized', v_wallet_initialized,
    'wallet_updated',     v_wallet_updated
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_commit_member_import(TEXT, INT) TO authenticated;

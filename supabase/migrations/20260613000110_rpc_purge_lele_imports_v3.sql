-- ============================================================
-- v3: 用 EXECUTE 'ALTER TABLE DISABLE TRIGGER' 繞 forbid_append_only_mutation
-- session_replication_role 是 superuser-only，普通 DEFINER role 用 ALTER TABLE
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_admin_purge_lele_imports()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_member_ids BIGINT[];
  v_n_members  INT := 0;
  v_n_stores   INT := 0;
  v_n_imports  INT := 0;
  v_n_wallet_l INT := 0;
  v_n_wallet_b INT := 0;
  v_n_push     INT := 0;
BEGIN
  SELECT array_agg(id) INTO v_member_ids
    FROM members
   WHERE tenant_id = v_tenant
     AND external_source = 'lele';

  IF v_member_ids IS NOT NULL AND array_length(v_member_ids, 1) > 0 THEN
    -- 暫關 append-only / no-delete trigger
    EXECUTE 'ALTER TABLE wallet_ledger DISABLE TRIGGER trg_no_delete_wallet';
    EXECUTE 'ALTER TABLE points_ledger DISABLE TRIGGER USER';
    EXECUTE 'ALTER TABLE members       DISABLE TRIGGER trg_no_delete_member';

    DELETE FROM wallet_ledger          WHERE member_id = ANY(v_member_ids);
    GET DIAGNOSTICS v_n_wallet_l = ROW_COUNT;

    DELETE FROM wallet_balances        WHERE member_id = ANY(v_member_ids);
    GET DIAGNOSTICS v_n_wallet_b = ROW_COUNT;

    DELETE FROM points_ledger          WHERE member_id = ANY(v_member_ids);
    DELETE FROM member_points_balance  WHERE member_id = ANY(v_member_ids);
    DELETE FROM member_cards           WHERE member_id = ANY(v_member_ids);
    DELETE FROM customer_line_aliases  WHERE member_id = ANY(v_member_ids);

    DELETE FROM push_subscriptions     WHERE member_id = ANY(v_member_ids);
    GET DIAGNOSTICS v_n_push = ROW_COUNT;

    DELETE FROM members                WHERE id = ANY(v_member_ids);
    v_n_members := array_length(v_member_ids, 1);

    -- 恢復
    EXECUTE 'ALTER TABLE wallet_ledger ENABLE TRIGGER trg_no_delete_wallet';
    EXECUTE 'ALTER TABLE points_ledger ENABLE TRIGGER USER';
    EXECUTE 'ALTER TABLE members       ENABLE TRIGGER trg_no_delete_member';
  END IF;

  DELETE FROM member_imports WHERE tenant_id = v_tenant;
  GET DIAGNOSTICS v_n_imports = ROW_COUNT;

  DELETE FROM stores
   WHERE tenant_id = v_tenant
     AND code LIKE 'LELE-%';
  GET DIAGNOSTICS v_n_stores = ROW_COUNT;

  RETURN jsonb_build_object(
    'members_deleted',         v_n_members,
    'wallet_ledger_deleted',   v_n_wallet_l,
    'wallet_balances_deleted', v_n_wallet_b,
    'push_subs_deleted',       v_n_push,
    'imports_deleted',         v_n_imports,
    'stores_deleted',          v_n_stores
  );
END;
$$;

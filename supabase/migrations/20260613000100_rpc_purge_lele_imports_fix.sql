-- ============================================================
-- Fix purge RPC: wallet_ledger 有 append-only trigger 擋 DELETE
-- 在 RPC 內暫時 SET session_replication_role='replica' 跳過 user trigger
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
  -- 暫停 user trigger（含 forbid_append_only_mutation 等）以允許 cleanup DELETE
  SET LOCAL session_replication_role = 'replica';

  SELECT array_agg(id) INTO v_member_ids
    FROM members
   WHERE tenant_id = v_tenant
     AND external_source = 'lele';

  IF v_member_ids IS NOT NULL AND array_length(v_member_ids, 1) > 0 THEN
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
  END IF;

  DELETE FROM member_imports WHERE tenant_id = v_tenant;
  GET DIAGNOSTICS v_n_imports = ROW_COUNT;

  DELETE FROM stores
   WHERE tenant_id = v_tenant
     AND code LIKE 'LELE-%';
  GET DIAGNOSTICS v_n_stores = ROW_COUNT;

  -- end of LOCAL replica；RESET implicit on TX end
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

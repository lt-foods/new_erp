-- ============================================================
-- v5: chunked purge，每 call 刪 p_limit 個 members
-- client 端 while loop 直到 members_deleted = 0
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_admin_purge_lele_imports(
  p_limit INT DEFAULT 500
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
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
    FROM (
      SELECT id FROM members
       WHERE tenant_id = v_tenant AND external_source = 'lele'
       LIMIT p_limit
    ) sub;

  IF v_member_ids IS NOT NULL AND array_length(v_member_ids, 1) > 0 THEN
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

    EXECUTE 'ALTER TABLE wallet_ledger ENABLE TRIGGER trg_no_delete_wallet';
    EXECUTE 'ALTER TABLE points_ledger ENABLE TRIGGER USER';
    EXECUTE 'ALTER TABLE members       ENABLE TRIGGER trg_no_delete_member';
  END IF;

  -- 只在 chunk 0 members 時清 staging + stores（避免每 chunk 重跑）
  IF v_n_members = 0 THEN
    DELETE FROM member_imports WHERE tenant_id = v_tenant;
    GET DIAGNOSTICS v_n_imports = ROW_COUNT;

    DELETE FROM stores
     WHERE tenant_id = v_tenant
       AND code LIKE 'LELE-%';
    GET DIAGNOSTICS v_n_stores = ROW_COUNT;
  END IF;

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

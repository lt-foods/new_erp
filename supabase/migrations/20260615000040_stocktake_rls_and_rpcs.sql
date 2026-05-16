-- ============================================================
-- 盤點 stocktake：RLS + lifecycle RPCs
--
-- schema（stocktakes / stocktake_items）自 20260422120003 即存在，
-- 但從未加 RPC、也從未加 RLS policy（同 reorder_rules 缺口：
-- RLS ENABLED + 零 policy → admin 連讀都被靜默拒）。
--
-- 流程：draft →save_counts→ counting →submit→ review →apply→ adjusted
--       任一非 adjusted → cancel → cancelled
-- 套用：每筆 diff≠0 寫 stocktake_gain/stocktake_loss movement，
--       trigger apply_movement_to_balance 把 stock_balances 對齊 counted。
--
-- 寫入只走 SECURITY DEFINER RPC，不開 broad write policy。
-- TEST: docs/TEST-stocktake.md
-- ============================================================

-- ----------------------------------------------------------------
-- 0. doc no helper（mirror _next_transfer_no）
-- ----------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS stocktake_no_seq;

CREATE OR REPLACE FUNCTION public._next_stocktake_no()
RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
  RETURN 'ST' || to_char(NOW(),'YYMMDD') || lpad(nextval('stocktake_no_seq')::TEXT, 4, '0');
END;
$$;

-- ----------------------------------------------------------------
-- 1. RLS — admin/HQ read（stocktakes + stocktake_items）
-- ----------------------------------------------------------------
CREATE POLICY hq_admin_read ON stocktakes
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '')
        IN ('owner','admin','hq_manager','warehouse','purchaser','reporter')
  );

CREATE POLICY hq_admin_read ON stocktake_items
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM stocktakes s
       WHERE s.id = stocktake_items.stocktake_id
         AND s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    )
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '')
        IN ('owner','admin','hq_manager','warehouse','purchaser','reporter')
  );

COMMENT ON POLICY hq_admin_read ON stocktakes IS
  'HQ/倉管讀本 tenant 盤點單。寫入走 SECURITY DEFINER RPC。';
COMMENT ON POLICY hq_admin_read ON stocktake_items IS
  '經 stocktakes 連動 tenant；HQ/倉管讀。寫入走 RPC。';

-- ----------------------------------------------------------------
-- helper：取盤點單 + tenant 驗證 + 角色閘
-- ----------------------------------------------------------------
-- (inline 於各 RPC；不另抽函式以保持 SECURITY DEFINER 邊界清楚)

-- ----------------------------------------------------------------
-- 2. rpc_create_stocktake
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_stocktake(
  p_location_id BIGINT,
  p_type        TEXT,
  p_sku_ids     BIGINT[] DEFAULT NULL,
  p_notes       TEXT     DEFAULT NULL,
  p_operator    UUID     DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := COALESCE(p_operator, auth.uid());
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
  v_id     BIGINT;
  v_no     TEXT;
  v_cnt    INT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create stocktake', v_role;
  END IF;
  IF p_type NOT IN ('full','partial','cycle') THEN
    RAISE EXCEPTION 'invalid stocktake type % (full/partial/cycle)', p_type;
  END IF;
  PERFORM 1 FROM locations WHERE id = p_location_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'location % not in tenant', p_location_id;
  END IF;
  IF p_type IN ('partial','cycle') AND (p_sku_ids IS NULL OR array_length(p_sku_ids,1) IS NULL) THEN
    RAISE EXCEPTION 'partial/cycle stocktake requires p_sku_ids';
  END IF;

  v_no := public._next_stocktake_no();
  INSERT INTO stocktakes (
    tenant_id, stocktake_no, location_id, type, status,
    started_at, created_by, updated_by, notes
  ) VALUES (
    v_tenant, v_no, p_location_id, p_type, 'draft',
    NOW(), v_user, v_user, p_notes
  ) RETURNING id INTO v_id;

  IF p_type = 'full' THEN
    INSERT INTO stocktake_items (stocktake_id, sku_id, system_qty, created_by, updated_by)
    SELECT v_id, sb.sku_id, sb.on_hand, v_user, v_user
      FROM stock_balances sb
     WHERE sb.tenant_id = v_tenant
       AND sb.location_id = p_location_id
       AND sb.on_hand <> 0;
  ELSE
    INSERT INTO stocktake_items (stocktake_id, sku_id, system_qty, created_by, updated_by)
    SELECT v_id, s.id,
           COALESCE((SELECT sb.on_hand FROM stock_balances sb
                      WHERE sb.tenant_id = v_tenant AND sb.location_id = p_location_id
                        AND sb.sku_id = s.id), 0),
           v_user, v_user
      FROM skus s
     WHERE s.id = ANY(p_sku_ids) AND s.tenant_id = v_tenant;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM stocktake_items WHERE stocktake_id = v_id;

  RETURN jsonb_build_object('id', v_id, 'stocktake_no', v_no, 'item_count', v_cnt);
END;
$$;

-- ----------------------------------------------------------------
-- 3. rpc_save_stocktake_counts
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_save_stocktake_counts(
  p_stocktake_id BIGINT,
  p_counts       JSONB,   -- [{ item_id, counted_qty }]
  p_operator     UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := COALESCE(p_operator, auth.uid());
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
  v_st     stocktakes%ROWTYPE;
  v_line   JSONB;
  v_item   BIGINT;
  v_qty    NUMERIC;
  v_n      INT := 0;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse') THEN
    RAISE EXCEPTION 'permission denied: role %', v_role;
  END IF;
  SELECT * INTO v_st FROM stocktakes WHERE id = p_stocktake_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'stocktake % not found in tenant', p_stocktake_id;
  END IF;
  IF v_st.status NOT IN ('draft','counting') THEN
    RAISE EXCEPTION 'stocktake % status=% cannot save counts (must be draft/counting)', p_stocktake_id, v_st.status;
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(COALESCE(p_counts,'[]'::jsonb))
  LOOP
    v_item := (v_line ->> 'item_id')::BIGINT;
    v_qty  := (v_line ->> 'counted_qty')::NUMERIC;
    IF v_qty IS NULL OR v_qty < 0 THEN
      RAISE EXCEPTION 'invalid counted_qty for item % (must be >= 0)', v_item;
    END IF;
    UPDATE stocktake_items
       SET counted_qty = v_qty, counted_by = v_user, counted_at = NOW(), updated_by = v_user
     WHERE id = v_item AND stocktake_id = p_stocktake_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'item % does not belong to stocktake %', v_item, p_stocktake_id;
    END IF;
    v_n := v_n + 1;
  END LOOP;

  IF v_st.status = 'draft' THEN
    UPDATE stocktakes SET status = 'counting',
           started_at = COALESCE(started_at, NOW()), updated_by = v_user
     WHERE id = p_stocktake_id;
  ELSE
    UPDATE stocktakes SET updated_by = v_user WHERE id = p_stocktake_id;
  END IF;

  RETURN jsonb_build_object('saved', v_n, 'status', 'counting');
END;
$$;

-- ----------------------------------------------------------------
-- 4. rpc_submit_stocktake（counting → review）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_submit_stocktake(
  p_stocktake_id BIGINT,
  p_operator     UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := COALESCE(p_operator, auth.uid());
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
  v_st     stocktakes%ROWTYPE;
  v_un     INT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse') THEN
    RAISE EXCEPTION 'permission denied: role %', v_role;
  END IF;
  SELECT * INTO v_st FROM stocktakes WHERE id = p_stocktake_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'stocktake % not found in tenant', p_stocktake_id;
  END IF;
  IF v_st.status <> 'counting' THEN
    RAISE EXCEPTION 'stocktake % status=% cannot submit (must be counting)', p_stocktake_id, v_st.status;
  END IF;

  SELECT COUNT(*) INTO v_un FROM stocktake_items
   WHERE stocktake_id = p_stocktake_id AND counted_qty IS NULL;
  IF v_un > 0 THEN
    RAISE EXCEPTION 'cannot submit: % item(s) not yet counted', v_un;
  END IF;

  UPDATE stocktakes SET status = 'review', updated_by = v_user WHERE id = p_stocktake_id;
  RETURN jsonb_build_object('status', 'review');
END;
$$;

-- ----------------------------------------------------------------
-- 5. rpc_apply_stocktake（review → adjusted；產調整 movement）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_apply_stocktake(
  p_stocktake_id BIGINT,
  p_operator     UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := COALESCE(p_operator, auth.uid());
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
  v_st     stocktakes%ROWTYPE;
  v_it     RECORD;
  v_mov    BIGINT;
  v_lines  INT := 0;
  v_gain   NUMERIC := 0;
  v_loss   NUMERIC := 0;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse') THEN
    RAISE EXCEPTION 'permission denied: role %', v_role;
  END IF;
  SELECT * INTO v_st FROM stocktakes WHERE id = p_stocktake_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'stocktake % not found in tenant', p_stocktake_id;
  END IF;
  IF v_st.status <> 'review' THEN
    RAISE EXCEPTION 'stocktake % status=% cannot apply (must be review)', p_stocktake_id, v_st.status;
  END IF;

  FOR v_it IN
    SELECT id, sku_id, diff_qty
      FROM stocktake_items
     WHERE stocktake_id = p_stocktake_id
       AND counted_qty IS NOT NULL
       AND diff_qty <> 0
     ORDER BY id
     FOR UPDATE
  LOOP
    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
      source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
    ) VALUES (
      v_tenant, v_st.location_id, v_it.sku_id, v_it.diff_qty, NULL,
      CASE WHEN v_it.diff_qty > 0 THEN 'stocktake_gain' ELSE 'stocktake_loss' END,
      'stocktake', p_stocktake_id, v_it.id,
      format('盤點調整 stocktake=%s', v_st.stocktake_no),
      v_user
    ) RETURNING id INTO v_mov;

    UPDATE stocktake_items SET adjustment_movement_id = v_mov, updated_by = v_user
     WHERE id = v_it.id;

    v_lines := v_lines + 1;
    IF v_it.diff_qty > 0 THEN v_gain := v_gain + v_it.diff_qty;
    ELSE v_loss := v_loss + (-v_it.diff_qty); END IF;
  END LOOP;

  UPDATE stocktakes
     SET status = 'adjusted', completed_at = NOW(), updated_by = v_user
   WHERE id = p_stocktake_id;

  RETURN jsonb_build_object(
    'status', 'adjusted',
    'adjusted_lines', v_lines,
    'total_gain', v_gain,
    'total_loss', v_loss
  );
END;
$$;

-- ----------------------------------------------------------------
-- 6. rpc_cancel_stocktake
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_cancel_stocktake(
  p_stocktake_id BIGINT,
  p_reason       TEXT DEFAULT NULL,
  p_operator     UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := COALESCE(p_operator, auth.uid());
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
  v_st     stocktakes%ROWTYPE;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse') THEN
    RAISE EXCEPTION 'permission denied: role %', v_role;
  END IF;
  SELECT * INTO v_st FROM stocktakes WHERE id = p_stocktake_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'stocktake % not found in tenant', p_stocktake_id;
  END IF;
  IF v_st.status NOT IN ('draft','counting','review') THEN
    RAISE EXCEPTION 'stocktake % status=% cannot cancel (already adjusted/cancelled)', p_stocktake_id, v_st.status;
  END IF;

  UPDATE stocktakes
     SET status = 'cancelled',
         notes = COALESCE(NULLIF(TRIM(notes),''),'') ||
                 CASE WHEN p_reason IS NOT NULL THEN ' [cancel: ' || TRIM(p_reason) || ']' ELSE ' [cancelled]' END,
         updated_by = v_user
   WHERE id = p_stocktake_id;
  RETURN jsonb_build_object('status', 'cancelled');
END;
$$;

-- ----------------------------------------------------------------
-- grants + comments
-- ----------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.rpc_create_stocktake(BIGINT,TEXT,BIGINT[],TEXT,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_save_stocktake_counts(BIGINT,JSONB,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_submit_stocktake(BIGINT,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_apply_stocktake(BIGINT,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_stocktake(BIGINT,TEXT,UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_stocktake  IS '建盤點單(draft)+快照 stocktake_items（full=該倉 on_hand≠0 全收；partial/cycle=指定 sku）。HQ/倉管。';
COMMENT ON FUNCTION public.rpc_save_stocktake_counts IS '寫盤點數量（draft/counting）；首次存數 → status=counting。';
COMMENT ON FUNCTION public.rpc_submit_stocktake  IS 'counting→review；尚有未盤點品項則 RAISE。';
COMMENT ON FUNCTION public.rpc_apply_stocktake   IS 'review→adjusted；每筆 diff≠0 產 stocktake_gain/loss movement，trigger 對齊 stock_balances。';
COMMENT ON FUNCTION public.rpc_cancel_stocktake  IS '取消盤點（draft/counting/review）；adjusted 不可取消。';

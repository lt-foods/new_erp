-- ============================================================
-- 盤點開放店長：store_manager 可對「自己店」全流程盤點
--
-- 需求（Alex 2026-08-26）：「每間店的店長都有盤點功能權限」。
--
-- 現況：盤點的 RLS 讀取與 5 支 lifecycle RPC（20260615000040）角色閘都只收
--   ('owner','admin','hq_manager','warehouse')，store_manager 開頁面是空清單、
--   按「+ 新增盤點」直接 permission denied。前端選單/頁面對分店本來就開著
--   （/inventory/stocktake 不在 BRANCH_HIDDEN_HREFS，列表也做好了分店鎖），
--   只差 server 側。
--
-- 修法：
--   1. RLS：stocktakes / stocktake_items 各加一條 store_read_own —— store_manager
--      只讀自己店 location 的盤點單（_jwt_store_location_ids()，20260707000070）。
--      store_staff 不開（需求只給店長）。
--   2. 5 支 RPC 角色閘加 'store_manager'，並插入店家守衛（逐字比照
--      20260816000050 rpc_add_stock_by_product 的規則）：分店角色 stores 非空、
--      不含「總倉」→ 目標倉別的店名必須在自己 stores 裡，否則 wrong_store。
--      守衛抽成 _assert_stocktake_store_scope(location_id) 給 5 支共用。
--      沒有 stores 的 legacy 分店帳號不鎖（同既有守衛，不製造新卡關）。
--   3. 順手修既有角色閘的已知坑（CLAUDE.md「app_metadata 不要用頂層 role」）：
--      原本 COALESCE(app_metadata.role, jwt.role, '') 對「沒有顯式 role 的
--      legacy/dev admin」會落到頂層 role='authenticated' 而被擋。改成
--      COALESCE(app_metadata.role, '') 且允許清單補 ''（管理員層級 =
--      ('owner','admin','')，對齊 apps/admin/src/lib/role.ts）。
--      hq_admin_read 兩條 policy 同步改。
--
-- 基底版本（每支都重 grep 過，migrations 只有這一版；線上 prosrc 也逐字
--   比對過 = 20260615000040，無未回寫的 hotfix）：
--   rpc_create_stocktake / rpc_save_stocktake_counts / rpc_submit_stocktake /
--   rpc_apply_stocktake / rpc_cancel_stocktake、hq_admin_read ×2 = 20260615000040
--
-- rollback:
--   DROP POLICY store_read_own ON stocktakes;
--   DROP POLICY store_read_own ON stocktake_items;
--   DROP FUNCTION public._assert_stocktake_store_scope(BIGINT);
--   重跑 20260615000040 的 hq_admin_read ×2（先 DROP）與 5 支 RPC。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 店家守衛 helper（給 5 支 RPC 共用）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._assert_stocktake_store_scope(p_location_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_role       TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores  JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_store_name TEXT;
  v_loc_name   TEXT;
BEGIN
  -- 分店角色只能盤自己店的倉別。規則對齊 20260816000050（rpc_add_stock_by_product）：
  -- stores 為空的 legacy 帳號、含「總倉」者、HQ 角色不鎖。
  -- 分店身分一律看 app_metadata.stores 店名陣列（線上分店帳號沒有 store_id，
  -- 見 20260808000020）。分店指到總倉倉別（沒有對應 stores 列）一律擋。
  IF v_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉') THEN
    SELECT s.name INTO v_store_name
      FROM stores s
     WHERE s.location_id = p_location_id
       AND s.tenant_id   = (auth.jwt() ->> 'tenant_id')::uuid;
    IF v_store_name IS NULL OR NOT (v_my_stores ? v_store_name) THEN
      SELECT l.name INTO v_loc_name FROM locations l WHERE l.id = p_location_id;
      RAISE EXCEPTION 'wrong_store: 這個倉別（%）不是你的店，分店帳號只能盤點自己店的庫存',
        COALESCE(v_store_name, v_loc_name, p_location_id::TEXT);
    END IF;
  END IF;
END;
$$;

COMMENT ON FUNCTION public._assert_stocktake_store_scope(BIGINT) IS
  '盤點 RPC 店家守衛：分店角色(store_manager/store_staff)只能動自己店 location 的盤點，'
  '否則 raise wrong_store。HQ / legacy 無 stores 帳號不受影響。';

REVOKE ALL ON FUNCTION public._assert_stocktake_store_scope(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._assert_stocktake_store_scope(BIGINT) TO authenticated;

-- ------------------------------------------------------------
-- 2. RLS：store_manager 讀自己店的盤點單
-- ------------------------------------------------------------
CREATE POLICY store_read_own ON stocktakes
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'store_manager'
    AND location_id = ANY (public._jwt_store_location_ids())
  );

CREATE POLICY store_read_own ON stocktake_items
  FOR SELECT TO authenticated USING (
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'store_manager'
    AND EXISTS (
      SELECT 1 FROM stocktakes s
       WHERE s.id = stocktake_items.stocktake_id
         AND s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND s.location_id = ANY (public._jwt_store_location_ids())
    )
  );

COMMENT ON POLICY store_read_own ON stocktakes IS
  '店長讀自己店 location 的盤點單（app_metadata.stores 店名經 _jwt_store_location_ids() 推導）。';
COMMENT ON POLICY store_read_own ON stocktake_items IS
  '經 stocktakes 連動 location；店長讀自己店的盤點品項。';

-- 既有 HQ 讀取政策：改用 app_metadata role（頂層 role 永遠是 authenticated，
-- 舊寫法把「沒有顯式 role 的 legacy/dev admin」擋在外面）＋允許清單補 ''。
DROP POLICY IF EXISTS hq_admin_read ON stocktakes;
CREATE POLICY hq_admin_read ON stocktakes
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('owner','admin','hq_manager','warehouse','purchaser','reporter','')
  );

DROP POLICY IF EXISTS hq_admin_read ON stocktake_items;
CREATE POLICY hq_admin_read ON stocktake_items
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM stocktakes s
       WHERE s.id = stocktake_items.stocktake_id
         AND s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    )
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('owner','admin','hq_manager','warehouse','purchaser','reporter','')
  );

COMMENT ON POLICY hq_admin_read ON stocktakes IS
  'HQ/倉管讀本 tenant 盤點單。寫入走 SECURITY DEFINER RPC。20260826010000 改讀 app_metadata.role＋補 legacy ''''。';
COMMENT ON POLICY hq_admin_read ON stocktake_items IS
  '經 stocktakes 連動 tenant；HQ/倉管讀。寫入走 RPC。';

-- ------------------------------------------------------------
-- 3. rpc_create_stocktake（基底 20260615000040 逐字保留，
--    只改 v_role 讀法、允許清單、插入店家守衛）
-- ------------------------------------------------------------
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
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_id     BIGINT;
  v_no     TEXT;
  v_cnt    INT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create stocktake', v_role;
  END IF;
  IF p_type NOT IN ('full','partial','cycle') THEN
    RAISE EXCEPTION 'invalid stocktake type % (full/partial/cycle)', p_type;
  END IF;
  PERFORM 1 FROM locations WHERE id = p_location_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'location % not in tenant', p_location_id;
  END IF;
  PERFORM public._assert_stocktake_store_scope(p_location_id);
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

-- ------------------------------------------------------------
-- 4. rpc_save_stocktake_counts
-- ------------------------------------------------------------
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
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_st     stocktakes%ROWTYPE;
  v_line   JSONB;
  v_item   BIGINT;
  v_qty    NUMERIC;
  v_n      INT := 0;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: role %', v_role;
  END IF;
  SELECT * INTO v_st FROM stocktakes WHERE id = p_stocktake_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'stocktake % not found in tenant', p_stocktake_id;
  END IF;
  PERFORM public._assert_stocktake_store_scope(v_st.location_id);
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

-- ------------------------------------------------------------
-- 5. rpc_submit_stocktake（counting → review）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_submit_stocktake(
  p_stocktake_id BIGINT,
  p_operator     UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := COALESCE(p_operator, auth.uid());
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_st     stocktakes%ROWTYPE;
  v_un     INT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: role %', v_role;
  END IF;
  SELECT * INTO v_st FROM stocktakes WHERE id = p_stocktake_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'stocktake % not found in tenant', p_stocktake_id;
  END IF;
  PERFORM public._assert_stocktake_store_scope(v_st.location_id);
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

-- ------------------------------------------------------------
-- 6. rpc_apply_stocktake（review → adjusted；產調整 movement）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_apply_stocktake(
  p_stocktake_id BIGINT,
  p_operator     UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := COALESCE(p_operator, auth.uid());
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_st     stocktakes%ROWTYPE;
  v_it     RECORD;
  v_mov    BIGINT;
  v_lines  INT := 0;
  v_gain   NUMERIC := 0;
  v_loss   NUMERIC := 0;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: role %', v_role;
  END IF;
  SELECT * INTO v_st FROM stocktakes WHERE id = p_stocktake_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'stocktake % not found in tenant', p_stocktake_id;
  END IF;
  PERFORM public._assert_stocktake_store_scope(v_st.location_id);
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

-- ------------------------------------------------------------
-- 7. rpc_cancel_stocktake
-- ------------------------------------------------------------
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
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_st     stocktakes%ROWTYPE;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','warehouse','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: role %', v_role;
  END IF;
  SELECT * INTO v_st FROM stocktakes WHERE id = p_stocktake_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'stocktake % not found in tenant', p_stocktake_id;
  END IF;
  PERFORM public._assert_stocktake_store_scope(v_st.location_id);
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

-- ------------------------------------------------------------
-- comments（grants 不動：CREATE OR REPLACE 保留 20260615000040 的 GRANT）
-- ------------------------------------------------------------
COMMENT ON FUNCTION public.rpc_create_stocktake  IS '建盤點單(draft)+快照 stocktake_items（full=該倉 on_hand≠0 全收；partial/cycle=指定 sku）。HQ/倉管/店長(限自己店)。';
COMMENT ON FUNCTION public.rpc_save_stocktake_counts IS '寫盤點數量（draft/counting）；首次存數 → status=counting。店長限自己店。';
COMMENT ON FUNCTION public.rpc_submit_stocktake  IS 'counting→review；尚有未盤點品項則 RAISE。店長限自己店。';
COMMENT ON FUNCTION public.rpc_apply_stocktake   IS 'review→adjusted；每筆 diff≠0 產 stocktake_gain/loss movement，trigger 對齊 stock_balances。店長限自己店。';
COMMENT ON FUNCTION public.rpc_cancel_stocktake  IS '取消盤點（draft/counting/review）；adjusted 不可取消。店長限自己店。';

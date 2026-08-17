-- ============================================================
-- rpc_merge_stores：兩店合併（來源店 → 目標店）
--
-- 把 2026-08-17 四號店 → 中和店的手工遷移（20260817000020 訂單/會員、
-- 20260817000030 庫存）收斂成一支可重複使用的 RPC，之後收店直接在
-- 後台門市頁按「合併」。
--
-- 搬移內容（與該次遷移同一套語意）：
--   1. LINE 綁定 member_line_bindings：改掛目標店；同一人兩店都綁過
--      （line_user_id 或 member_id 撞 (tenant,store) 唯一鍵）→ 刪來源側、
--      保留目標店既有綁定。
--   2. 會員 members.home_store_id → 目標店。**排除 member_type='store_internal'**：
--      【內部】xx 店是店的固定裝置、目標店有自己的一個，搬過去會出現兩個。
--      它名下的單照搬（見 3），現貨池帳本跟著貨走（池子口徑看
--      pickup_store_id + member_type，不看內部會員的 home_store）。
--   3. 訂單 customer_orders.pickup_store_id → 目標店（全部，含歷史單與
--      RR-/AB- 容器單；trio 唯一索引不含 pickup_store_id、restock 又被
--      predicate 排除，不會撞）。
--   4. 庫存：來源店倉 on_hand > 0 的 SKU 開一張正式店對店調撥單
--      MG-S<src>-S<dst>-<時間戳>，逐 SKU rpc_outbound(transfer_out) 後走
--      rpc_receive_transfer 標準收貨 —— 邏輯 A0–E 照跑（解待補貨、推進
--      confirmed 單、自動配單、內部池收斂），月結走 free_in/free_out
--      （estimated_amount = qty × 分店價，缺價退出庫成本；CHECK 要求與
--      description 成對，填 SKU 碼＋品名）。負庫存留在來源店倉、
--      回報 negative_balances_left 交給盤點，不硬搬。
--   5. p_deactivate_source（預設 TRUE）：搬完停用來源店。
--
-- 守衛：
--   - owner / admin / ''（legacy dev admin）限定，路徑走 app_metadata
--     （頂層 role 永遠是 'authenticated'，見 20260502010000 / 20260807000040）。
--   - 目標店必須啟用中且未刪除；來源店未刪除（停用中可合併——收店常態）。
--   - 來源店有「在途入庫」（draft/confirmed/shipped 且 dest = 來源店倉的
--     transfers）或進行中補貨申請 → 擋下。先收完或取消，否則那批貨會
--     派到一間死店。
--
-- 刻意不搬（歷史事實 / 另有正主，呼叫端要知道）：
--   - 歷史財務：expenses / petty_cash / store_monthly_settlements /
--     store_receivables → 留在來源店，月結歸檔本來就按店別。
--   - 歷史物流：picking_wave_items / restock_requests / order_pickup_events。
--   - 店務設定：LINE OA（store_line_oa_credentials / line_channels）、
--     promotions.applicable_store_ids、互助板進行中釋出（回報
--     aid_listings_open 讓人工收尾）。
--   - 員工指派 app_metadata.stores 存的是**店名**（見 role.ts useMyStores），
--     在 auth 端要人工改 → 回報 staff_assignments_pending。
--
-- rollback：資料搬移不可逆轉自動回復；反向再呼叫一次（target→source）可把
-- 訂單/會員/庫存搬回去，但被去重刪掉的綁定與已觸發的訂單推進不會還原。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_merge_stores(
  p_source_store_id   BIGINT,
  p_target_store_id   BIGINT,
  p_operator          UUID DEFAULT NULL,
  p_deactivate_source BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_operator UUID := COALESCE(p_operator, auth.uid());
  v_src      stores;
  v_dst      stores;
  v_inflight        INT;
  v_open_restocks   INT;
  v_bind_deduped    INT := 0;
  v_bind_moved      INT := 0;
  v_members_moved   INT := 0;
  v_orders_moved    INT := 0;
  v_transfer_id     BIGINT;
  v_transfer_no     TEXT;
  v_mov_id          BIGINT;
  v_est             NUMERIC;
  v_desc            TEXT;
  v_stock_lines     INT := 0;
  v_stock_qty       NUMERIC := 0;
  v_neg_left        INT := 0;
  v_aid_open        INT := 0;
  v_staff_pending   INT := 0;
  r                 RECORD;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION 'permission denied: only owner/admin can merge stores';
  END IF;
  IF p_source_store_id = p_target_store_id THEN
    RAISE EXCEPTION '來源店與目標店不能是同一間';
  END IF;

  -- 固定依 id 順序鎖兩間店，避免同時兩筆反向合併互相死鎖
  FOR r IN
    SELECT * FROM stores
     WHERE tenant_id = v_tenant AND id IN (p_source_store_id, p_target_store_id)
     ORDER BY id
       FOR UPDATE
  LOOP
    IF r.id = p_source_store_id THEN v_src := r; ELSE v_dst := r; END IF;
  END LOOP;

  IF v_src.id IS NULL THEN
    RAISE EXCEPTION 'source store % not found', p_source_store_id;
  END IF;
  IF v_dst.id IS NULL THEN
    RAISE EXCEPTION 'target store % not found', p_target_store_id;
  END IF;
  IF v_src.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION '來源店 %（%）已被刪除，先還原再合併', v_src.name, v_src.code;
  END IF;
  IF v_dst.deleted_at IS NOT NULL OR NOT v_dst.is_active THEN
    RAISE EXCEPTION '目標店 %（%）必須是啟用中的門市', v_dst.name, v_dst.code;
  END IF;

  -- 在途入庫：這批貨正派往來源店，先收完或取消再合併
  IF v_src.location_id IS NOT NULL THEN
    SELECT count(*) INTO v_inflight
      FROM transfers t
     WHERE t.tenant_id = v_tenant
       AND t.dest_location = v_src.location_id
       AND t.status IN ('draft','confirmed','shipped');
    IF v_inflight > 0 THEN
      RAISE EXCEPTION '來源店 % 還有 % 張在途/待出貨的入庫調撥單，先收貨或取消再合併',
        v_src.code, v_inflight;
    END IF;
  END IF;

  SELECT count(*) INTO v_open_restocks
    FROM restock_requests
   WHERE tenant_id = v_tenant
     AND requesting_store_id = p_source_store_id
     AND status NOT IN ('cancelled','received','rejected');
  IF v_open_restocks > 0 THEN
    RAISE EXCEPTION '來源店 % 還有 % 筆進行中補貨申請，先結掉再合併',
      v_src.code, v_open_restocks;
  END IF;

  -- 1a. 兩店都綁過的人：刪來源側綁定，保留目標店既有的
  DELETE FROM member_line_bindings b
   WHERE b.tenant_id = v_tenant
     AND b.store_id = p_source_store_id
     AND EXISTS (
       SELECT 1 FROM member_line_bindings b2
        WHERE b2.tenant_id = b.tenant_id
          AND b2.store_id = p_target_store_id
          AND (b2.line_user_id = b.line_user_id OR b2.member_id = b.member_id)
     );
  GET DIAGNOSTICS v_bind_deduped = ROW_COUNT;

  -- 1b. 其餘綁定改掛目標店
  UPDATE member_line_bindings
     SET store_id = p_target_store_id
   WHERE tenant_id = v_tenant AND store_id = p_source_store_id;
  GET DIAGNOSTICS v_bind_moved = ROW_COUNT;

  -- 2. 會員改隸目標店（內部池容器會員留在來源店，見檔頭）
  UPDATE members
     SET home_store_id = p_target_store_id
   WHERE tenant_id = v_tenant
     AND home_store_id = p_source_store_id
     AND member_type IS DISTINCT FROM 'store_internal';
  GET DIAGNOSTICS v_members_moved = ROW_COUNT;

  -- 3. 訂單取貨店改為目標店（全部，含歷史單與容器單）
  UPDATE customer_orders
     SET pickup_store_id = p_target_store_id
   WHERE tenant_id = v_tenant AND pickup_store_id = p_source_store_id;
  GET DIAGNOSTICS v_orders_moved = ROW_COUNT;

  -- 4. 庫存：正式調撥單 + 標準收貨（比照 20260817000030）
  IF v_src.location_id IS NOT NULL AND v_dst.location_id IS NOT NULL
     AND v_src.location_id <> v_dst.location_id THEN

    v_transfer_no := 'MG-S' || p_source_store_id || '-S' || p_target_store_id
                  || '-' || to_char(NOW() AT TIME ZONE 'utc', 'YYYYMMDDHH24MISS');

    INSERT INTO transfers (
      tenant_id, transfer_no, source_location, dest_location,
      status, transfer_type, is_air_transfer,
      notes, shipped_by, shipped_at, created_by, updated_by
    ) VALUES (
      v_tenant, v_transfer_no, v_src.location_id, v_dst.location_id,
      'shipped', 'store_to_store', FALSE,
      format('兩店合併：%s（%s）庫存整批移轉 %s（%s）', v_src.name, v_src.code, v_dst.name, v_dst.code),
      v_operator, NOW(), v_operator, v_operator
    ) RETURNING id INTO v_transfer_id;

    FOR r IN
      SELECT sb.sku_id, sb.on_hand
        FROM stock_balances sb
       WHERE sb.tenant_id = v_tenant
         AND sb.location_id = v_src.location_id
         AND sb.on_hand > 0
       ORDER BY sb.sku_id
    LOOP
      v_mov_id := rpc_outbound(
        p_tenant_id          => v_tenant,
        p_location_id        => v_src.location_id,
        p_sku_id             => r.sku_id,
        p_quantity           => r.on_hand,
        p_movement_type      => 'transfer_out',
        p_source_doc_type    => 'transfer',
        p_source_doc_id      => v_transfer_id,
        p_operator           => v_operator,
        p_allow_negative     => TRUE,
        p_fallback_unit_cost => public._current_cost_price(v_tenant, r.sku_id)
      );

      SELECT r.on_hand * COALESCE(
               NULLIF(public._branch_price_at(v_tenant, r.sku_id, NOW()), 0),
               sm.unit_cost, 0)
        INTO v_est
        FROM stock_movements sm
       WHERE sm.id = v_mov_id;

      SELECT trim(k.sku_code || ' ' || COALESCE(k.product_name, '')
               || COALESCE(' ' || NULLIF(k.variant_name, ''), ''))
        INTO v_desc
        FROM skus k
       WHERE k.id = r.sku_id;

      INSERT INTO transfer_items (
        transfer_id, sku_id, qty_requested, qty_shipped,
        out_movement_id, estimated_amount, description, created_by, updated_by
      ) VALUES (
        v_transfer_id, r.sku_id, r.on_hand, r.on_hand,
        v_mov_id, v_est, v_desc, v_operator, v_operator
      );

      v_stock_lines := v_stock_lines + 1;
      v_stock_qty   := v_stock_qty + r.on_hand;
    END LOOP;

    IF v_stock_lines = 0 THEN
      DELETE FROM transfers WHERE id = v_transfer_id;
      v_transfer_id := NULL;
      v_transfer_no := NULL;
    ELSE
      PERFORM rpc_receive_transfer(
        v_transfer_id, NULL, v_operator,
        format('兩店合併收貨：%s → %s', v_src.code, v_dst.code), TRUE
      );
    END IF;

    SELECT count(*) INTO v_neg_left
      FROM stock_balances
     WHERE tenant_id = v_tenant
       AND location_id = v_src.location_id
       AND on_hand < 0;
  END IF;

  -- 5. 停用來源店
  IF p_deactivate_source THEN
    UPDATE stores
       SET is_active = FALSE, updated_by = v_operator, updated_at = NOW()
     WHERE id = p_source_store_id AND tenant_id = v_tenant;
  END IF;

  -- 人工收尾項（只回報、不動手）
  SELECT count(*) INTO v_aid_open
    FROM mutual_aid_board
   WHERE tenant_id = v_tenant
     AND offering_store_id = p_source_store_id
     AND status = 'active';

  SELECT count(*) INTO v_staff_pending
    FROM auth.users u
   WHERE u.raw_app_meta_data -> 'stores' ? v_src.name;

  RETURN jsonb_build_object(
    'source_store',            v_src.code,
    'target_store',            v_dst.code,
    'bindings_moved',          v_bind_moved,
    'bindings_deduped',        v_bind_deduped,
    'members_moved',           v_members_moved,
    'orders_moved',            v_orders_moved,
    'stock_transfer_no',       v_transfer_no,
    'stock_lines',             v_stock_lines,
    'stock_qty',               v_stock_qty,
    'negative_balances_left',  v_neg_left,
    'source_deactivated',      p_deactivate_source,
    'aid_listings_open',       v_aid_open,
    'staff_assignments_pending', v_staff_pending
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_merge_stores(BIGINT, BIGINT, UUID, BOOLEAN) IS
  '兩店合併：來源店的 LINE 綁定（去重）/ 會員（排除內部池容器）/ 全部訂單改掛目標店，'
  '店倉庫存開 MG- 調撥單走標準收貨，預設停用來源店。owner/admin 限定。'
  '在途入庫或進行中補貨申請未結會擋下。回傳各項搬移數量與人工收尾項。';

REVOKE ALL ON FUNCTION public.rpc_merge_stores(BIGINT, BIGINT, UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_merge_stores(BIGINT, BIGINT, UUID, BOOLEAN) TO authenticated;

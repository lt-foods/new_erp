-- ============================================================
-- 追加品項到「已取貨完成」的訂單 → 把訂單重開，別讓品項變幽靈
--
-- 回報案例（2026-08-05）：
--   湖口店 RR-247（order 65983）收貨後，店端把 G00763-01 ×1 / G01020-03 ×2 /
--   G01020-05 ×2 轉出給會員「*琡芳*205528-湖口」(member 67091)。轉出沒報錯，
--   但 205528 身上完全看不到這幾件。
--
-- 成因：
--   rpc_transfer_order_partial 找「既有可追加的訂單」時，條件是
--     status NOT IN ('expired','cancelled','transferred_out')
--   —— 'completed' 不在排除清單裡。205528 在補貨 sentinel 開團
--   （campaign 806 '__INTERNAL_RESTOCK__'）名下早就有一張
--   __INTERNAL_RESTOCK__-TF0092（order 53781），2026-07-21 就已取貨 completed。
--   所有補貨轉出都落在同一個 sentinel campaign + 同一個 channel + 同一個會員，
--   於是 8/3 這批直接被 append 進那張 7 月就結案的單裡：
--     - 待取清單只看 active 狀態 → 看不到
--     - is_order_item_pickup_ready 的第一個條件就是
--       co.status NOT IN ('completed',...) → 就算找到也不給取
--   等於貨進了店、帳掛在會員身上，但兩邊都摸不到。
--
-- 為什麼不是「開一張新單」：
--   customer_orders_trio_kind_active_uniq 是 (tenant, campaign, channel, member,
--   order_kind) 的 partial UNIQUE，predicate 只排除
--   ('transferred_out','expired','cancelled') —— completed 仍佔著 slot。
--   要新開單就得放寬那支索引，等於動到所有開團訂單「一會員一活動一張單」的
--   核心不變量（rpc_create_customer_orders 也靠它），連帶 rpc_undo_pickup
--   撤銷取貨時可能撞唯一鍵。改成「重開既有單」不動索引、不動不變量，
--   而且語意正確：這張單確實又有沒取的東西了。
--
-- 修法：
--   1. 新增 _reopen_order_if_completed(order_id, operator, why)
--      —— 只在 status='completed' 時動手：
--        有 picked_up 品項 → 'partially_completed'（UI 對這狀態本就開放續取）
--        否則 is_order_pickup_ready() → 'ready'，再否則 'shipping'
--        （與 rpc_undo_pickup 的狀態重算規則一致）
--      清 completed_at、寫 notes、寫 customer_order_audit_log。
--   2. rpc_transfer_order_partial：走 append 分支時（v_appended）在最後呼叫它。
--   3. rpc_create_customer_orders：代客加單追加到既有單時同樣呼叫
--      —— 同一類無聲吞資料的坑（目前線上還沒踩到，掃描見下）。
--
-- 線上實際受害範圍（掃 items.created_at > orders.completed_at）：只有 3 張，
-- 全是「追加轉入」，全在湖口店 — 53781 / 53750 / 51747。資料修復在
-- 20260805000150_backfill_reopen_ghost_appended_orders.sql。
--
-- 基底版本（一律取時間最新、已 dump 線上比對逐字一致）：
--   rpc_transfer_order_partial   = 20260714000090（內部單→真會員鎖現售價版）
--   rpc_create_customer_orders   = 20260630000000（skip cancelled + 黑名單版）
-- Rollback：
--   CREATE OR REPLACE 回上述兩個基底版本；DROP FUNCTION _reopen_order_if_completed。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _reopen_order_if_completed — completed 單被追加品項時重開
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reopen_order_if_completed(
  p_order_id BIGINT,
  p_operator UUID,
  p_why      TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_order      customer_orders%ROWTYPE;
  v_has_picked BOOLEAN;
  v_new_status TEXT;
  v_operator   UUID := COALESCE(p_operator, '00000000-0000-0000-0000-000000000000'::uuid);
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL OR v_order.status <> 'completed' THEN
    RETURN NULL;   -- 沒這張單 / 本來就不是結案單 → 不動
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM customer_order_items
     WHERE order_id = p_order_id AND status = 'picked_up'
  ) INTO v_has_picked;

  -- 與 rpc_undo_pickup（20260704000010）的狀態重算同規則
  v_new_status := CASE
    WHEN v_has_picked                      THEN 'partially_completed'
    WHEN is_order_pickup_ready(p_order_id) THEN 'ready'
    ELSE 'shipping'
  END;

  UPDATE customer_orders
     SET status       = v_new_status,
         completed_at = NULL,
         notes        = COALESCE(notes, '') ||
                        E'\n[重開單 completed → ' || v_new_status || '：' ||
                        COALESCE(p_why, '結案後又被追加品項') || '] ' ||
                        to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
         updated_by   = v_operator,
         updated_at   = v_now
   WHERE id = p_order_id;

  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_order.tenant_id, p_order_id, 'order', p_order_id, 'status',
    to_jsonb('completed'::TEXT), to_jsonb(v_new_status),
    '已取貨完成的訂單被追加品項，重開讓新品項看得到／取得到：' ||
      COALESCE(p_why, ''),
    v_operator
  );

  RETURN v_new_status;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public._reopen_order_if_completed(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public._reopen_order_if_completed(BIGINT, UUID, TEXT) IS
  '結案(completed)訂單被追加品項時重開：有已取品項→partially_completed，'
  '否則依 is_order_pickup_ready 給 ready/shipping；清 completed_at + 寫 audit。'
  '非 completed 一律不動並回 NULL。';

-- ----------------------------------------------------------------
-- 2. rpc_transfer_order_partial — append 分支加重開（基底 20260714000090）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_transfer_order_partial(
  p_order_id              BIGINT,
  p_to_pickup_store_id    BIGINT,
  p_to_member_id          BIGINT,
  p_to_channel_id         BIGINT,
  p_operator              UUID,
  p_reason                TEXT,
  p_items                 JSONB,
  p_is_air_transfer       BOOLEAN DEFAULT FALSE
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_orig             customer_orders%ROWTYPE;
  v_tenant_id        UUID;
  v_to_member_id     BIGINT;
  v_to_channel_id    BIGINT;
  v_new_order_id     BIGINT;
  v_new_order_no     TEXT;
  v_seq              INT;
  v_campaign_no      TEXT;
  v_p_item           JSONB;
  v_p_sku_id         BIGINT;
  v_p_qty            NUMERIC;
  v_src_item_id      BIGINT;
  v_src_item_qty     NUMERIC;
  v_src_item_ci      BIGINT;
  v_src_item_price   NUMERIC;
  v_src_item_reserved BIGINT;
  v_remaining_count  INT;
  v_now              TIMESTAMPTZ := NOW();
  v_existing_order   BIGINT;
  v_appended         BOOLEAN := FALSE;
  v_new_status       TEXT;
  v_src_is_internal  BOOLEAN := FALSE;
  v_dst_is_internal  BOOLEAN := FALSE;
  v_retail_price     NUMERIC;
  v_item_price       NUMERIC;
  v_reopened         TEXT;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  -- 貨還沒到分店不能轉單：source 必須 status='ready'
  IF v_orig.status <> 'ready' THEN
    RAISE EXCEPTION '貨還沒到分店、訂單 % 不可轉單 (status=%)',
                    p_order_id, v_orig.status;
  END IF;

  IF v_orig.transferred_to_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'order % already transferred to order %',
                    p_order_id, v_orig.transferred_to_order_id;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_to_pickup_store_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_store % not in tenant', p_to_pickup_store_id;
  END IF;

  v_to_member_id := COALESCE(
    p_to_member_id,
    rpc_get_or_create_store_member(p_to_pickup_store_id, p_operator)
  );

  PERFORM 1 FROM members WHERE id = v_to_member_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not in tenant', v_to_member_id;
  END IF;

  -- 內部單（【內部】xx店）轉給真會員 = 門市現貨銷售 → 轉出價改鎖現售價。
  -- 店↔店互助（目標也是 store_internal）維持原價不變。
  SELECT (m.member_type = 'store_internal') INTO v_src_is_internal
    FROM members m WHERE m.id = v_orig.member_id;
  v_src_is_internal := COALESCE(v_src_is_internal, FALSE);
  SELECT (m.member_type = 'store_internal') INTO v_dst_is_internal
    FROM members m WHERE m.id = v_to_member_id;
  v_dst_is_internal := COALESCE(v_dst_is_internal, FALSE);

  v_to_channel_id := p_to_channel_id;
  IF v_to_channel_id IS NULL THEN
    SELECT id INTO v_to_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id AND home_store_id = p_to_pickup_store_id
     LIMIT 1;
    IF v_to_channel_id IS NULL THEN
      SELECT id INTO v_to_channel_id
        FROM line_channels
       WHERE tenant_id = v_tenant_id
       LIMIT 1;
    END IF;
  END IF;
  IF v_to_channel_id IS NULL THEN
    RAISE EXCEPTION 'no line_channel available for receiving store';
  END IF;

  SELECT id INTO v_existing_order
    FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = v_orig.campaign_id
     AND channel_id  = v_to_channel_id
     AND member_id   = v_to_member_id
     AND status NOT IN ('expired','cancelled','transferred_out');

  IF v_existing_order IS NOT NULL THEN
    v_new_order_id := v_existing_order;
    v_appended := TRUE;
    SELECT order_no INTO v_new_order_no FROM customer_orders WHERE id = v_existing_order;
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[追加轉入 (' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
                   ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') ||
                   COALESCE(' / ' || p_reason, ''),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_new_order_id;
  ELSE
    SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id AND campaign_id = v_orig.campaign_id;
    v_new_order_no := v_campaign_no || '-TF' || lpad(v_seq::text, 4, '0');

    -- 同店：mirror source.status；跨店空中轉：直接 confirmed（略過總倉確認 gate）；
    -- 跨店經總倉：'pending'（維持總倉確認 gate）
    v_new_status := CASE
      WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN v_orig.status
      WHEN p_is_air_transfer THEN 'confirmed'
      ELSE 'pending'
    END;

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, notes,
      transferred_from_order_id, is_air_transfer,
      created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
      v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status,
      COALESCE(p_reason, '') ||
        E'\n[轉入 (部分, ' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
        ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
        to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
      p_order_id, p_is_air_transfer,
      p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_new_order_id;
  END IF;

  FOR v_p_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_p_sku_id := (v_p_item ->> 'sku_id')::BIGINT;
    v_p_qty    := (v_p_item ->> 'qty')::NUMERIC;
    IF v_p_qty IS NULL OR v_p_qty <= 0 THEN
      RAISE EXCEPTION 'p_items: qty must be > 0';
    END IF;

    SELECT id, qty, campaign_item_id, unit_price, reserved_movement_id
      INTO v_src_item_id, v_src_item_qty, v_src_item_ci, v_src_item_price, v_src_item_reserved
      FROM customer_order_items
     WHERE order_id = p_order_id
       AND sku_id   = v_p_sku_id
       AND status   != 'cancelled'
     ORDER BY id
     LIMIT 1
     FOR UPDATE;
    IF v_src_item_id IS NULL THEN
      RAISE EXCEPTION 'sku % not in order % (or already cancelled)', v_p_sku_id, p_order_id;
    END IF;
    IF v_src_item_reserved IS NOT NULL THEN
      RAISE EXCEPTION 'sku % already allocated (reserved_movement_id=%); release first',
                      v_p_sku_id, v_src_item_reserved;
    END IF;
    IF v_src_item_qty < v_p_qty THEN
      RAISE EXCEPTION 'sku % insufficient qty: source=%, requested=%',
                      v_p_sku_id, v_src_item_qty, v_p_qty;
    END IF;

    -- 內部單 → 真會員：轉出價鎖定當下 SKU 現售價（scope='retail' 最新生效版）；
    -- 查無現售價 fallback 來源價。其餘情境維持原價。
    v_item_price := v_src_item_price;
    IF v_src_is_internal AND NOT v_dst_is_internal THEN
      SELECT price INTO v_retail_price
        FROM prices
       WHERE tenant_id = v_tenant_id
         AND sku_id    = v_p_sku_id
         AND scope     = 'retail'
         AND effective_from <= v_now
         AND (effective_to IS NULL OR effective_to > v_now)
       ORDER BY effective_from DESC
       LIMIT 1;
      v_item_price := COALESCE(v_retail_price, v_src_item_price);
    END IF;

    IF v_src_item_qty = v_p_qty THEN
      UPDATE customer_order_items
         SET status = 'cancelled', updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    ELSE
      UPDATE customer_order_items
         SET qty = qty - v_p_qty, updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_new_order_id, v_src_item_ci, v_p_sku_id, v_p_qty, v_item_price,
      'pending', 'aid_transfer', p_operator, p_operator
    );
  END LOOP;

  SELECT COUNT(*) INTO v_remaining_count
    FROM customer_order_items
   WHERE order_id = p_order_id AND status != 'cancelled';

  IF v_remaining_count = 0 THEN
    UPDATE customer_orders
       SET status = 'transferred_out',
           transferred_to_order_id = v_new_order_id,
           notes = COALESCE(notes, '') ||
                   E'\n[全部轉出 → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  ELSE
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[' || CASE WHEN v_appended THEN '部分追加' ELSE '部分轉出' END ||
                   ' → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  END IF;

  -- 追加到「已取貨完成」的既有單時，把它重開 —— 否則新品項會被埋在 completed
  -- 單裡：待取清單看不到、is_order_item_pickup_ready 也擋著不給取（見檔頭）。
  IF v_appended THEN
    v_reopened := public._reopen_order_if_completed(
      v_new_order_id, p_operator,
      '追加轉入 ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')');
  END IF;

  RETURN v_new_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_transfer_order_partial(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN) TO authenticated;

COMMENT ON FUNCTION public.rpc_transfer_order_partial(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN) IS
  '部分轉出：新建轉入單時，跨店空中轉直接建 confirmed（略過總倉確認 gate），經總倉建 pending；'
  '同店 mirror source.status。追加到既有 active 單時不改其 status，'
  '但若那張單已 completed 則呼叫 _reopen_order_if_completed 重開（否則追加的品項看不到也取不到）。'
  '內部單(store_internal)轉給真會員 = 門市現貨銷售，轉出價鎖當下現售價(scope=retail、無則原價)。'
  '基底 20260714000090。';

-- ----------------------------------------------------------------
-- 3. rpc_create_customer_orders — 加單分支加重開（基底 20260630000000）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_customer_orders(
  p_campaign_id BIGINT,
  p_channel_id  BIGINT,
  p_rows        JSONB
) RETURNS TABLE (out_order_id BIGINT, out_order_no TEXT, out_item_count INT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_status       TEXT;
  v_campaign_no  TEXT;
  v_row          JSONB;
  v_item         JSONB;
  v_member_id    BIGINT;
  v_pickup_store BIGINT;
  v_nickname     TEXT;
  v_order_id     BIGINT;
  v_order_no     TEXT;
  v_seq          INT;
  v_ci_id        BIGINT;
  v_ci_price     NUMERIC;
  v_qty          NUMERIC;
  v_ci_sku       BIGINT;
  v_existing_qty NUMERIC;
  v_count        INT;
  v_blacklisted  BOOLEAN;
  v_member_name  TEXT;
  v_reopened     TEXT;
BEGIN
  SELECT status, campaign_no INTO v_status, v_campaign_no
    FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF v_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF v_status NOT IN ('open','closed') THEN
    RAISE EXCEPTION 'campaign % is %; only open/closed campaigns accept manual entry',
                    p_campaign_id, v_status;
  END IF;

  PERFORM 1 FROM line_channels WHERE id = p_channel_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'channel % not in tenant', p_channel_id; END IF;

  IF p_rows IS NULL OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'p_rows is empty';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_member_id    := (v_row ->> 'member_id')::BIGINT;
    v_pickup_store := (v_row ->> 'pickup_store_id')::BIGINT;
    v_nickname     := v_row ->> 'nickname';

    IF v_member_id IS NULL THEN RAISE EXCEPTION 'member_id required'; END IF;
    IF v_pickup_store IS NULL THEN RAISE EXCEPTION 'pickup_store_id required'; END IF;

    SELECT no_new_order, COALESCE(name, member_no)
      INTO v_blacklisted, v_member_name
      FROM members
     WHERE id = v_member_id AND tenant_id = v_tenant;
    IF v_blacklisted IS NULL THEN
      RAISE EXCEPTION 'member % not in tenant', v_member_id;
    END IF;
    IF v_blacklisted THEN
      RAISE EXCEPTION '會員「%」已被列入黑名單，禁止建立 / 加單', v_member_name;
    END IF;

    PERFORM 1 FROM stores WHERE id = v_pickup_store AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', v_pickup_store; END IF;

    -- 找既有訂單時排除已 cancelled / expired / transferred_out
    -- (對齊 customer_orders_trio_kind_active_uniq partial UNIQUE 索引)
    SELECT id INTO v_order_id FROM customer_orders
     WHERE tenant_id = v_tenant
       AND campaign_id = p_campaign_id
       AND channel_id  = p_channel_id
       AND member_id   = v_member_id
       AND status NOT IN ('cancelled','expired','transferred_out');

    IF v_order_id IS NULL THEN
      SELECT COUNT(*) + 1 INTO v_seq FROM customer_orders
       WHERE tenant_id = v_tenant AND campaign_id = p_campaign_id;
      v_order_no := v_campaign_no || '-' || lpad(v_seq::text, 4, '0');

      INSERT INTO customer_orders (
        tenant_id, order_no, campaign_id, channel_id, member_id,
        nickname_snapshot, pickup_store_id, status, created_by, updated_by
      ) VALUES (
        v_tenant, v_order_no, p_campaign_id, p_channel_id, v_member_id,
        v_nickname, v_pickup_store, 'pending', v_user, v_user
      ) RETURNING id INTO v_order_id;
    ELSE
      UPDATE customer_orders SET
        nickname_snapshot = COALESCE(v_nickname, nickname_snapshot),
        pickup_store_id   = v_pickup_store,
        updated_by        = v_user
      WHERE id = v_order_id
      RETURNING order_no INTO v_order_no;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_row -> 'items')
    LOOP
      v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
      v_qty   := (v_item ->> 'qty')::NUMERIC;
      IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'qty must be > 0'; END IF;

      SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
        FROM campaign_items
       WHERE id = v_ci_id AND tenant_id = v_tenant AND campaign_id = p_campaign_id;
      IF v_ci_price IS NULL THEN
        RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
      END IF;

      SELECT coi.qty INTO v_existing_qty FROM customer_order_items coi
       WHERE coi.order_id = v_order_id AND coi.campaign_item_id = v_ci_id;

      IF v_existing_qty IS NULL THEN
        INSERT INTO customer_order_items (
          tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
          status, source, created_by, updated_by
        ) VALUES (
          v_tenant, v_order_id, v_ci_id, v_ci_sku, v_qty, v_ci_price,
          'pending', 'manual', v_user, v_user
        );
      ELSE
        UPDATE customer_order_items coi SET
          qty        = v_existing_qty + v_qty,
          updated_by = v_user
        WHERE coi.order_id = v_order_id AND coi.campaign_item_id = v_ci_id;
      END IF;
    END LOOP;

    -- 加到「已取貨完成」的既有單時把它重開（同 rpc_transfer_order_partial）
    v_reopened := public._reopen_order_if_completed(v_order_id, v_user, '代客加單');

    SELECT COUNT(*) INTO v_count FROM customer_order_items coi WHERE coi.order_id = v_order_id;
    out_order_id   := v_order_id;
    out_order_no   := v_order_no;
    out_item_count := v_count;
    RETURN NEXT;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_customer_orders TO authenticated;

COMMENT ON FUNCTION public.rpc_create_customer_orders IS
  '小幫手代客 key 訂單。campaign 必須 status IN (open, closed);'
  'closed 是 HQ/店家補加單緩衝期(顧客 App 已隱藏不會撞到)。'
  '黑名單會員 (members.no_new_order = TRUE) 禁止建單 / 加單。'
  '加到已 completed 的既有單時呼叫 _reopen_order_if_completed 重開。';

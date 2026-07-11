-- ============================================================
-- 2026-07-12: 補貨現貨銷售鏈 — ride-along 單掛店內部會員 + 收貨推 ready + 轉手鎖現售價
--
-- 需求（使用者定案）：
--   補貨到店的貨要能賣給會員：「先掛到店家【內部】xx店，然後才能再轉單給客人」，
--   轉給客人時單價鎖定 SKU 現售價（prices scope='retail'）。
--
-- 現況缺口：
--   1. 補貨 ride-along 訂單（order_no='RR-<id>'、order_kind='restock'）
--      member_id=NULL，掛不到【內部】xx店，訂單頁看不出歸屬、轉手 modal 也無從操作。
--   2. ride-along 單永遠卡 'pending'：收貨鏈沒人推它，而
--      rpc_transfer_order_partial 要求 source status='ready' 才能轉 → 轉不了。
--   3. rpc_transfer_order_partial 轉出 item 價格直接抄來源價
--      （= 補貨建單時的分店價 snapshot），賣給會員應該用現售價。
--
-- 修法：
--   1. rpc_create_restock_request：加 p_member_id 參數（預設 NULL＝掛
--      rpc_get_or_create_store_member(p_store_id)【內部】xx店）；建單時可
--      直接指定真會員 → ride-along 單掛該會員、order items 單價鎖當下
--      現售價（貨到即該會員的可取貨訂單，免轉手）。
--      舊 3 參數簽名 DROP 掉再建 4 參數版（避免 PostgREST overload 歧義）。
--   2. rpc_receive_transfer 邏輯 D 擴充：收貨時 ride-along 單推 'ready'
--      （之後店端即可在訂單頁對它按「轉手」拆給客人，同店轉手新單 mirror ready、
--       客人當場可取貨；取貨守衛 Path C 由本補貨的已收轉貨單滿足）。
--      rpc_unreceive_transfer 加反向（ready → pending）。
--   3. rpc_transfer_order_partial：來源單的 member 是 store_internal 且
--      目標 member 是真會員（非 store_internal）→ 轉出 item 單價改用
--      當下現售價（prices scope='retail' 最新生效版；查無現售價 fallback 來源價）。
--      店↔店互助轉手（目標也是 internal）不受影響、維持原價。
--   4. customer_orders_trio_kind_active_uniq 排除 order_kind='restock'：
--      同店多張併行補貨的 ride-along 單共用 (sentinel campaign, sentinel channel,
--      內部會員, 'restock')，掛上內部會員後必撞唯一鍵（prod 實測撞出）。
--      RR 單唯一性由 order_no='RR-<id>' 保證；一般單/offset 的 dedup 語意不變。
--   5. Backfill：存量 ride-along 單補掛內部會員；linked transfer 已收貨的
--      ride-along 單補推 ready（RESTOCK#18 的 RR-18 在列）。
--
-- 基底版本：
--   rpc_create_restock_request  = 20260714000020（線上現行，逐字保留僅改 member_id）
--   rpc_receive_transfer        = 20260714000080（含邏輯 D；該檔若未套用，本檔已含其函式全文，
--                                 惟其 restock status backfill 仍建議先套 80 再套本檔）
--   rpc_unreceive_transfer      = 20260714000080（同上）
--   rpc_transfer_order_partial  = 20260714000010（逐字保留僅加內部單→真會員的現售價改寫）
-- Rollback：CREATE OR REPLACE 回上列各基底版本（rpc_create_restock_request 因簽名
--   變更需先 DROP FUNCTION public.rpc_create_restock_request(BIGINT,JSONB,TEXT,BIGINT)
--   再建回 20260714000020 的 3 參數版）；索引回復＝重建 20260516000000 版
--   （注意：須先清掉同 trio 多張 active restock 單否則建不回去）；backfill 回復：
--   UPDATE customer_orders SET member_id=NULL WHERE order_kind='restock';（不建議）
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_create_restock_request — ride-along 單掛店內部會員（可指定真會員）
--    舊 3 參數簽名先 DROP：CREATE 新 4 參數版若共存會造成 PostgREST
--    named-args 呼叫 overload 歧義。
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_create_restock_request(BIGINT, JSONB, TEXT);

CREATE OR REPLACE FUNCTION public.rpc_create_restock_request(
  p_store_id  BIGINT,
  p_lines     JSONB,
  p_notes     TEXT   DEFAULT NULL,
  p_member_id BIGINT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_request_id   BIGINT;
  v_line         JSONB;
  v_sku_id       BIGINT;
  v_count        INT := 0;
  v_is_virtual   BOOLEAN;
  v_campaign_id  BIGINT;
  v_channel_id   BIGINT;
  v_order_id     BIGINT;
  v_order_no     TEXT;
  v_campaign_item_id BIGINT;
  v_unit_price   NUMERIC;
  v_qty          NUMERIC;
  v_member_id    BIGINT;
  v_member_is_internal BOOLEAN := TRUE;
  v_retail_price NUMERIC;
  v_item_price   NUMERIC;
  v_now          TIMESTAMPTZ := NOW();
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create restock request', v_role;
  END IF;

  -- 店端 role 只能建自家店申請。「自己店」由 app_metadata.stores 店名經
  -- _jwt_store_ids() 推導（本系統 JWT 無 store_id claim，見 20260707000080 同型修法）。
  IF v_role IN ('store_manager','store_staff') THEN
    IF NOT (p_store_id = ANY (public._jwt_store_ids())) THEN
      RAISE EXCEPTION 'store role can only create request for own store';
    END IF;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', p_store_id; END IF;

  -- 1. 建 restock_request
  INSERT INTO restock_requests (
    tenant_id, requesting_store_id, status, notes,
    requested_by, requested_at, created_by, updated_by
  ) VALUES (
    v_tenant, p_store_id, 'pending', p_notes,
    v_user, NOW(), v_user, v_user
  ) RETURNING id INTO v_request_id;

  -- 2. 建 sentinel campaign + channel + customer_order
  --    ride-along 單預設掛店內部會員（【內部】xx店），貨到後轉手給客人；
  --    建單時也可直接指定真會員 → 貨到即該會員的可取貨訂單（免轉手）。
  v_campaign_id := public._restock_sentinel_campaign(v_tenant);
  v_channel_id  := public._restock_sentinel_channel(v_tenant, p_store_id);

  IF p_member_id IS NOT NULL THEN
    SELECT (m.member_type = 'store_internal') INTO v_member_is_internal
      FROM members m
     WHERE m.id = p_member_id AND m.tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'member % not in tenant', p_member_id;
    END IF;
    v_member_id := p_member_id;
  ELSE
    v_member_id := public.rpc_get_or_create_store_member(p_store_id, v_user);
    v_member_is_internal := TRUE;
  END IF;

  v_order_no := 'RR-' || v_request_id::TEXT;

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id, pickup_store_id,
    status, order_kind, order_type, external_source, external_order_no,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_order_no, v_campaign_id, v_channel_id, v_member_id, p_store_id,
    'pending', 'restock', 'regular', 'manual', v_order_no,
    CASE WHEN v_member_is_internal THEN '【內部】補貨申請 #' ELSE '【指定會員】補貨申請 #' END
      || v_request_id::TEXT,
    v_user, v_user
  ) RETURNING id INTO v_order_id;

  -- 3. 跑每一個 line:寫 restock_request_lines + customer_order_items
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku_id := (v_line ->> 'sku_id')::BIGINT;
    v_qty    := (v_line ->> 'qty')::NUMERIC;
    v_unit_price := COALESCE((v_line ->> 'unit_price')::NUMERIC, 0);

    SELECT p.is_virtual INTO v_is_virtual
      FROM skus s
      JOIN products p ON p.id = s.product_id
     WHERE s.id = v_sku_id AND s.tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sku % not in tenant', v_sku_id;
    END IF;
    IF v_is_virtual THEN
      RAISE EXCEPTION 'restock request cannot use virtual sku %', v_sku_id;
    END IF;

    IF v_qty <= 0 THEN
      RAISE EXCEPTION 'line qty must be > 0';
    END IF;

    INSERT INTO restock_request_lines (
      tenant_id, request_id, sku_id, qty, unit_price, notes,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_request_id, v_sku_id, v_qty, v_unit_price,
      v_line ->> 'notes', v_user, v_user
    );

    -- sentinel campaign_item per sku
    v_campaign_item_id := public._restock_sentinel_campaign_item(
      v_tenant, v_campaign_id, v_sku_id, v_unit_price
    );

    -- 指定真會員 → order item 單價鎖當下現售價（與轉手同規則；無則 fallback 分店價）；
    -- 內部單維持分店價 snapshot（轉手時才改現售價）。restock_request_lines 一律存分店價。
    v_item_price := v_unit_price;
    IF NOT v_member_is_internal THEN
      SELECT price INTO v_retail_price
        FROM prices
       WHERE tenant_id = v_tenant
         AND sku_id    = v_sku_id
         AND scope     = 'retail'
         AND effective_from <= v_now
         AND (effective_to IS NULL OR effective_to > v_now)
       ORDER BY effective_from DESC
       LIMIT 1;
      v_item_price := COALESCE(v_retail_price, v_unit_price);
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant, v_order_id, v_campaign_item_id, v_sku_id, v_qty, v_item_price,
      'pending', 'manual', v_user, v_user
    );

    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  RETURN v_request_id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_create_restock_request(BIGINT, JSONB, TEXT, BIGINT)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_restock_request IS
  'Case 2：分店建補貨申請（pending 狀態、限真實 SKU，同步建 restock customer_order）。'
  'p_member_id 預設 NULL＝掛店內部會員(【內部】xx店)；指定真會員時 order items 鎖現售價、'
  '貨到即該會員的可取貨訂單。店端角色只能建自家店申請（_jwt_store_ids() 判定）。';

-- ----------------------------------------------------------------
-- 2. rpc_receive_transfer — 邏輯 D 擴充：ride-along 單推 ready
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(p_transfer_id bigint, p_lines jsonb, p_operator uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id            UUID;
  v_status               TEXT;
  v_transfer_type        TEXT;
  v_dest_location        BIGINT;
  v_existing_notes       TEXT;
  v_customer_order_id    BIGINT;
  v_next_transfer_id     BIGINT;
  v_item                 RECORD;
  v_qty_received         NUMERIC;
  v_unit_cost            NUMERIC;
  v_in_mov_id            BIGINT;
  v_total_qty            NUMERIC := 0;
  v_total_variance       NUMERIC := 0;
  v_items_received       INTEGER := 0;
  v_lines_consumed       INTEGER := 0;
  v_lines_count          INTEGER;
  v_orders_advanced      INTEGER := 0;
  v_next_shipped         BOOLEAN := FALSE;
  v_leg2                 transfers%ROWTYPE;
  v_leg2_item            RECORD;
  v_leg2_mov             BIGINT;
  v_dest_store_id        BIGINT;
  v_restock_received     INTEGER := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is in status %, expected shipped', p_transfer_id, v_status;
  END IF;

  IF p_lines IS NOT NULL THEN
    v_lines_count := jsonb_array_length(p_lines);
    IF EXISTS (
      SELECT 1
        FROM jsonb_array_elements(p_lines) AS l
        LEFT JOIN transfer_items ti
          ON ti.id = (l->>'transfer_item_id')::BIGINT
         AND ti.transfer_id = p_transfer_id
       WHERE ti.id IS NULL
    ) THEN
      RAISE EXCEPTION 'p_lines contains transfer_item_id not belonging to transfer %', p_transfer_id;
    END IF;
  END IF;

  -- ===== 原有邏輯：寫 qty_received + dest_location inbound =====
  FOR v_item IN
    SELECT ti.id, ti.sku_id, ti.qty_shipped, sm.unit_cost AS out_cost
      FROM transfer_items ti
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE ti.transfer_id = p_transfer_id
     ORDER BY ti.id
  LOOP
    v_qty_received := v_item.qty_shipped;

    IF p_lines IS NOT NULL THEN
      SELECT (l->>'qty_received')::NUMERIC
        INTO v_qty_received
        FROM jsonb_array_elements(p_lines) AS l
       WHERE (l->>'transfer_item_id')::BIGINT = v_item.id
       LIMIT 1;

      IF FOUND THEN
        v_lines_consumed := v_lines_consumed + 1;
      ELSE
        v_qty_received := v_item.qty_shipped;
      END IF;
    END IF;

    IF v_qty_received IS NULL OR v_qty_received < 0 THEN
      RAISE EXCEPTION 'transfer_item % qty_received must be >= 0, got %', v_item.id, v_qty_received;
    END IF;
    IF v_qty_received > v_item.qty_shipped THEN
      RAISE EXCEPTION 'transfer_item % over-receipt: qty_received=% > qty_shipped=%',
        v_item.id, v_qty_received, v_item.qty_shipped;
    END IF;

    IF v_qty_received > 0 THEN
      v_unit_cost := COALESCE(ABS(v_item.out_cost), 0);

      v_in_mov_id := rpc_inbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_dest_location,
        p_sku_id          => v_item.sku_id,
        p_quantity        => v_qty_received,
        p_unit_cost       => v_unit_cost,
        p_movement_type   => 'transfer_in',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );

      UPDATE transfer_items
         SET qty_received   = v_qty_received,
             in_movement_id = v_in_mov_id,
             updated_by     = p_operator
       WHERE id = v_item.id;
    ELSE
      UPDATE transfer_items
         SET qty_received = 0,
             updated_by   = p_operator
       WHERE id = v_item.id;
    END IF;

    v_total_qty      := v_total_qty + v_qty_received;
    v_total_variance := v_total_variance + (v_qty_received - v_item.qty_shipped);
    v_items_received := v_items_received + 1;
  END LOOP;

  UPDATE transfers
     SET status      = 'received',
         received_by = p_operator,
         received_at = NOW(),
         notes       = CASE
                         WHEN p_notes IS NULL OR p_notes = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN p_notes
                         ELSE v_existing_notes || E'\n' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- ===== 邏輯 A：自動 ship 下一段（aid chain B 模型）=====
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_leg2 FROM transfers
     WHERE id = v_next_transfer_id FOR UPDATE;

    IF v_leg2.id IS NOT NULL AND v_leg2.status = 'draft' THEN
      FOR v_leg2_item IN
        SELECT ti.id AS leg2_item_id, ti.sku_id, ti2.qty_received
          FROM transfer_items ti
          JOIN transfer_items ti2
            ON ti2.transfer_id = p_transfer_id AND ti2.sku_id = ti.sku_id
         WHERE ti.transfer_id = v_leg2.id
      LOOP
        IF v_leg2_item.qty_received > 0 THEN
          v_leg2_mov := rpc_outbound(
            p_tenant_id       => v_leg2.tenant_id,
            p_location_id     => v_leg2.source_location,
            p_sku_id          => v_leg2_item.sku_id,
            p_quantity        => v_leg2_item.qty_received,
            p_movement_type   => 'transfer_out',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_leg2.id,
            p_operator        => p_operator
          );
          UPDATE transfer_items
             SET qty_shipped     = v_leg2_item.qty_received,
                 qty_requested   = v_leg2_item.qty_received,
                 out_movement_id = v_leg2_mov,
                 updated_by      = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        ELSE
          UPDATE transfer_items
             SET qty_shipped   = 0,
                 qty_requested = 0,
                 updated_by    = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        END IF;
      END LOOP;

      UPDATE transfers
         SET status      = 'shipped',
             shipped_by  = p_operator,
             shipped_at  = NOW(),
             updated_by  = p_operator
       WHERE id = v_leg2.id;
      v_next_shipped := TRUE;
    END IF;
  END IF;

  -- ===== 邏輯 B：aid 單 FK 直接推 customer_order → ready =====
  IF v_customer_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = NOW(),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_customer_order_id
       AND status = 'shipping';
    GET DIAGNOSTICS v_orders_advanced = ROW_COUNT;

  -- ===== 邏輯 C：hq_to_store wave transfer → 推該分店訂單 → ready =====
  -- 修：不再無條件推該店「所有」shipping 訂單；改成只推
  --     is_order_pickup_ready=true（依該訂單的團真的到齊、shortage-aware）的訂單，
  --     避免收到別團波次時把尚未出貨的團一起誤標為可取貨。
  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      WITH advanced AS (
        UPDATE customer_orders co
           SET status     = 'ready',
               ready_at   = NOW(),
               updated_by = p_operator,
               updated_at = NOW()
         WHERE co.tenant_id      = v_tenant_id
           AND co.pickup_store_id = v_dest_store_id
           AND co.status          = 'shipping'
           AND public.is_order_pickup_ready(co.id)
        RETURNING co.id
      )
      SELECT COUNT(*) INTO v_orders_advanced FROM advanced;
    END IF;
  END IF;

  -- ===== 邏輯 D：linked 補貨申請 → 已收貨；ride-along 單 → ready =====
  -- 店家收貨即補貨流程終點：把 linked_transfer_id 指向本單的補貨申請
  -- 推到 received。approved_transfer 為 legacy 防禦（現行直派皆直接 shipped）。
  UPDATE restock_requests
     SET status     = 'received',
         updated_by = p_operator
   WHERE linked_transfer_id = p_transfer_id
     AND status IN ('shipped', 'approved_transfer');
  GET DIAGNOSTICS v_restock_received = ROW_COUNT;

  -- ride-along 內部單（order_no='RR-<id>'、掛【內部】xx店）推 ready：
  -- 之後店端才能對它「轉手」拆給客人（rpc_transfer_order_partial 要求 ready）。
  UPDATE customer_orders co
     SET status     = 'ready',
         ready_at   = NOW(),
         updated_by = p_operator,
         updated_at = NOW()
    FROM restock_requests rr
   WHERE rr.linked_transfer_id = p_transfer_id
     AND co.tenant_id  = rr.tenant_id
     AND co.order_no   = 'RR-' || rr.id::TEXT
     AND co.order_kind = 'restock'
     AND co.status IN ('pending', 'confirmed', 'shipping');

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped,
    'restock_received',       v_restock_received
  );
END;
$function$;

-- ----------------------------------------------------------------
-- 3. rpc_unreceive_transfer — 反向：ride-along 單 ready → pending
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_unreceive_transfer(
  p_transfer_id bigint,
  p_operator    uuid,
  p_notes       text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
-- 邏輯 C 需重掃該店所有 ready 訂單並逐張跑 is_order_pickup_ready，覆寫 PostgREST
-- 預設 statement_timeout，避免大店退回時中途被砍。
SET statement_timeout TO '60000'
AS $function$
DECLARE
  v_tenant_id         UUID;
  v_status            TEXT;
  v_transfer_type     TEXT;
  v_dest_location     BIGINT;
  v_existing_notes    TEXT;
  v_customer_order_id BIGINT;
  v_next_transfer_id  BIGINT;
  v_leg2_status       TEXT;
  v_item              RECORD;
  v_orig              stock_movements%ROWTYPE;
  v_on_hand           NUMERIC;
  v_rev_id            BIGINT;
  v_items_reversed    INTEGER := 0;
  v_total_qty         NUMERIC := 0;
  v_dest_store_id     BIGINT;
  v_orders_reverted   INTEGER := 0;
  v_ord               RECORD;
  v_restock_reverted  INTEGER := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'received' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，僅「已收貨(received)」可退回取消收貨', p_transfer_id, v_status;
  END IF;

  -- 守衛：多段接力且後段已自動出貨（收貨時 ship 過），不允許直接退回本段
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT status INTO v_leg2_status FROM transfers WHERE id = v_next_transfer_id FOR UPDATE;
    IF v_leg2_status IS NOT NULL AND v_leg2_status <> 'draft' THEN
      RAISE EXCEPTION '此調撥為多段接力，後段調撥 %（狀態 %）已出貨，請先處理後段後再退回本段收貨',
        v_next_transfer_id, v_leg2_status;
    END IF;
  END IF;

  -- 逐項沖銷 transfer_in 入庫、並把 qty_received 歸零
  FOR v_item IN
    SELECT id, sku_id, qty_received, in_movement_id
      FROM transfer_items
     WHERE transfer_id = p_transfer_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.qty_received > 0 AND v_item.in_movement_id IS NOT NULL THEN
      SELECT * INTO v_orig FROM stock_movements WHERE id = v_item.in_movement_id;

      IF v_orig.id IS NULL
         OR v_orig.movement_type <> 'transfer_in'
         OR v_orig.source_doc_type <> 'transfer'
         OR v_orig.source_doc_id <> p_transfer_id THEN
        RAISE EXCEPTION 'transfer_item % 的 movement % 非本調撥入庫，無法退回收貨',
          v_item.id, v_item.in_movement_id;
      END IF;
      IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
        RAISE EXCEPTION 'movement % 已被沖銷過，不可重複退回收貨', v_orig.id;
      END IF;

      -- 物理守衛：入庫貨若已被取貨/售出使 on_hand 不足以沖銷 → 擋（避免庫存變負）
      SELECT on_hand INTO v_on_hand
        FROM stock_balances
       WHERE tenant_id   = v_orig.tenant_id
         AND location_id = v_orig.location_id
         AND sku_id      = v_orig.sku_id
       FOR UPDATE;
      IF COALESCE(v_on_hand, 0) < v_orig.quantity THEN
        RAISE EXCEPTION '分店庫存不足以退回收貨（SKU %：現有 %、需沖銷 %）：該批貨可能已被取貨/售出，無法退回',
          v_orig.sku_id, COALESCE(v_on_hand, 0), v_orig.quantity;
      END IF;

      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
      ) VALUES (
        v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
        -v_orig.quantity, v_orig.unit_cost, 'reversal',
        'transfer', p_transfer_id, v_item.id, v_orig.id,
        format('退回收貨 transfer=%s item=%s（沖銷 movement %s）%s',
               p_transfer_id, v_item.id, v_orig.id,
               COALESCE('：' || NULLIF(TRIM(p_notes), ''), '')),
        p_operator
      ) RETURNING id INTO v_rev_id;

      v_total_qty      := v_total_qty + v_orig.quantity;
      v_items_reversed := v_items_reversed + 1;
    END IF;

    UPDATE transfer_items
       SET qty_received   = 0,
           in_movement_id = NULL,
           updated_by     = p_operator,
           updated_at     = NOW()
     WHERE id = v_item.id;
  END LOOP;

  -- 調撥單退回 shipped
  UPDATE transfers
     SET status      = 'shipped',
         received_by = NULL,
         received_at = NULL,
         notes       = CASE
                         WHEN p_notes IS NULL OR TRIM(p_notes) = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN '退回收貨：' || p_notes
                         ELSE v_existing_notes || E'\n退回收貨：' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- 反向邏輯 B（aid 單 FK）/ 邏輯 C（hq_to_store）：
  -- 把因本次收貨被推到 ready、沖銷後已不再 pickup_ready 的訂單退回 shipping。
  -- 因其他已收波次而仍到貨的訂單維持 ready。已取貨(partially_completed/completed)不動。
  IF v_customer_order_id IS NOT NULL THEN
    FOR v_ord IN
      SELECT id FROM customer_orders
       WHERE id = v_customer_order_id AND status = 'ready'
       FOR UPDATE
    LOOP
      IF NOT public.is_order_pickup_ready(v_ord.id) THEN
        UPDATE customer_orders
           SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
         WHERE id = v_ord.id;
        PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
          format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
        v_orders_reverted := v_orders_reverted + 1;
      END IF;
    END LOOP;

  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      FOR v_ord IN
        SELECT id FROM customer_orders
         WHERE tenant_id       = v_tenant_id
           AND pickup_store_id = v_dest_store_id
           AND status          = 'ready'
         FOR UPDATE
      LOOP
        IF NOT public.is_order_pickup_ready(v_ord.id) THEN
          UPDATE customer_orders
             SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
           WHERE id = v_ord.id;
          PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
            format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
          v_orders_reverted := v_orders_reverted + 1;
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- ===== 反向邏輯 D：linked 補貨申請退回 shipped；ride-along 單退回 pending =====
  UPDATE restock_requests
     SET status     = 'shipped',
         updated_by = p_operator
   WHERE linked_transfer_id = p_transfer_id
     AND status = 'received';
  GET DIAGNOSTICS v_restock_reverted = ROW_COUNT;

  UPDATE customer_orders co
     SET status     = 'pending',
         ready_at   = NULL,
         updated_by = p_operator,
         updated_at = NOW()
    FROM restock_requests rr
   WHERE rr.linked_transfer_id = p_transfer_id
     AND co.tenant_id  = rr.tenant_id
     AND co.order_no   = 'RR-' || rr.id::TEXT
     AND co.order_kind = 'restock'
     AND co.status = 'ready';

  RETURN jsonb_build_object(
    'transfer_id',        p_transfer_id,
    'items_reversed',     v_items_reversed,
    'total_qty_reversed', v_total_qty,
    'orders_reverted',    v_orders_reverted,
    'restock_reverted',   v_restock_reverted
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) IS
  '退回收貨：rpc_receive_transfer 的反向。沖銷 transfer_in 入庫(reversal movement)、'
  'qty_received 歸零、調撥單 received→shipped；沖銷後不再 pickup_ready 的訂單退回 shipping；'
  'linked 補貨申請 received→shipped、ride-along 單 ready→pending。'
  '守衛：非 received / 後段已出貨 / movement 已沖銷 / on_hand 不足(貨已取用) 皆擋下。';

-- ----------------------------------------------------------------
-- 4. rpc_transfer_order_partial — 內部單 → 真會員：轉出價改鎖現售價
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

  RETURN v_new_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_transfer_order_partial(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN) TO authenticated;

COMMENT ON FUNCTION public.rpc_transfer_order_partial(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN) IS
  '部分轉出：新建轉入單時，跨店空中轉直接建 confirmed（略過總倉確認 gate），經總倉建 pending；'
  '同店 mirror source.status。追加到既有 active 單時不改其 status。'
  '內部單(store_internal)轉給真會員 = 門市現貨銷售，轉出價鎖當下現售價(scope=retail、無則原價)。'
  '基底 20260714000010。';

-- ----------------------------------------------------------------
-- 5. 唯一索引排除 restock ride-along 單
--    基底 20260516000000：key=(tenant,campaign,channel,member,order_kind)、
--    WHERE 排除 closed。加排 order_kind='restock'：同店多張併行補貨單
--    共用 sentinel trio + 內部會員，本來就該允許共存（唯一性由 order_no 保證）。
-- ----------------------------------------------------------------
DROP INDEX IF EXISTS customer_orders_trio_kind_active_uniq;

CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq
  ON customer_orders (tenant_id, campaign_id, channel_id, member_id, order_kind)
  WHERE status NOT IN ('transferred_out', 'expired', 'cancelled')
    AND order_kind <> 'restock';

COMMENT ON INDEX customer_orders_trio_kind_active_uniq IS
  '同 (tenant, campaign, channel, member, order_kind) 只允許一筆 active 訂單；'
  'closed (transferred_out/expired/cancelled) 不佔 slot。'
  '加 order_kind 是為了讓 store_internal member 可同時有 normal 與 offset 兩張單。'
  'order_kind=restock 的 ride-along 單排除在外（同店可多張併行補貨，唯一性由 order_no=RR-<id> 保證）。';

-- ----------------------------------------------------------------
-- 6. Backfill
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_uid          UUID;
  v_ord          RECORD;
  v_member_fixed INTEGER := 0;
  v_ready_fixed  INTEGER := 0;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  -- 5a. 存量 ride-along 單補掛店內部會員
  FOR v_ord IN
    SELECT co.id, co.pickup_store_id
      FROM customer_orders co
     WHERE co.order_kind = 'restock'
       AND co.member_id IS NULL
  LOOP
    UPDATE customer_orders
       SET member_id  = public.rpc_get_or_create_store_member(v_ord.pickup_store_id, v_uid),
           updated_by = v_uid,
           updated_at = NOW()
     WHERE id = v_ord.id;
    v_member_fixed := v_member_fixed + 1;
  END LOOP;

  -- 5b. linked transfer 已收貨的 ride-along 單補推 ready（含 RR-18）
  UPDATE customer_orders co
     SET status     = 'ready',
         ready_at   = COALESCE(t.received_at, NOW()),
         updated_by = v_uid,
         updated_at = NOW()
    FROM restock_requests rr
    JOIN transfers t ON t.id = rr.linked_transfer_id
   WHERE co.tenant_id  = rr.tenant_id
     AND co.order_no   = 'RR-' || rr.id::TEXT
     AND co.order_kind = 'restock'
     AND co.status IN ('pending', 'confirmed', 'shipping')
     AND t.status IN ('received', 'closed');
  GET DIAGNOSTICS v_ready_fixed = ROW_COUNT;

  RAISE NOTICE 'Backfill: % 張 ride-along 單補掛內部會員、% 張補推 ready', v_member_fixed, v_ready_fixed;
END $$;

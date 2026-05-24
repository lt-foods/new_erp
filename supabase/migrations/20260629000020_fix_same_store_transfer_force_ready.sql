-- ============================================================
-- Fix: 同店互轉訂單不應被強制設為 'ready'
--
-- 背景：
-- 20260508140000_transfer_same_store_skip_status.sql 為了「同店互轉時庫存沒
-- 移動」的 use case，在 rpc_transfer_order_to_store / rpc_transfer_order_partial
-- 把同店 (p_to_pickup_store_id == v_orig.pickup_store_id) 的新訂單 status 一律
-- 強制設為 'ready'，並補 4 筆 audit log (pending→confirmed→reserved→shipping
-- →ready, edit_reason='同店互轉自動推進')。
--
-- Bug 案例：GRP-20260523-002-0007 (member Peggy, 松山店, status=pending、
-- items pending、無 reserved_movement) → 轉到同店的 store_internal member
-- (松山店 自己的虛擬會員) → 新單 GRP-20260523-002-TF0008 (id=11703)。同店 →
-- 被強制設為 status='ready'，UI 直接讀 status='ready' 翻成「可取貨」。但
-- campaign 956 (GRP-20260523-002) 還 open、wave 都沒產生，物理上根本沒收貨。
--
-- Root cause：同店強制 'ready' 假設「庫存已經在這個店」，但對 source.status='pending'
-- 的訂單來說，根本沒收貨、沒 wave、沒 allocation。force ready 是錯的。
--
-- 修法：
-- 1. rpc_transfer_order_to_store / rpc_transfer_order_partial：
--    - 同店：新訂單 status 改成 mirror source 的 status (v_orig.status)
--    - 跨店：維持 'pending'（原本就是）
--    - 刪掉同店那 4 筆假的 audit log（沒有實際 transition、純粹是 audit noise）
-- 2. is_order_pickup_ready（修正 20260629000010 過嚴的副作用）：
--    - aid_transfer + 跨店 (transferred_from.pickup_store != co.pickup_store)：
--      只認 Path A (transfers FK 收貨)
--    - aid_transfer + 同店：放回 Path A/B/C（因為 campaign 的 wave 進到該店即算）
--    - 非 aid_transfer 訂單：Path A/B/C 維持
--    - 移除 20260629000010 的 `co.status='ready'` 逃生口 — 修了 RPC 後不再需要
-- 3. Backfill：把過去被同店強制設為 'ready' 但實際 pickup_ready=false 的訂單
--    退回 'pending'，並寫 1 筆修正 audit log。
--
-- Rollback: 把這 3 支 function CREATE OR REPLACE 回 20260629000010 的版本，
-- 並把這次 backfill UPDATE 的訂單手動改回 'ready'（可從本 migration 的
-- NOTICE 量觀察）。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. is_order_pickup_ready
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_order_pickup_ready(p_order_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM customer_orders co
     WHERE co.id = p_order_id
       AND co.status NOT IN ('completed','expired','cancelled','transferred_out')
       AND CASE
         -- Aid-transfer + 跨店：只認自己的 transfer 被收貨 (Path A)
         WHEN EXISTS (
                SELECT 1 FROM customer_order_items coi
                 WHERE coi.order_id = co.id AND coi.source = 'aid_transfer'
              )
              AND co.transferred_from_order_id IS NOT NULL
              AND (
                SELECT src.pickup_store_id FROM customer_orders src
                 WHERE src.id = co.transferred_from_order_id
              ) IS DISTINCT FROM co.pickup_store_id
         THEN
           EXISTS (
             SELECT 1 FROM transfers t
              WHERE t.customer_order_id = co.id
                AND t.tenant_id = co.tenant_id
                AND t.status IN ('received','closed')
           )
         ELSE (
           -- aid_transfer 同店、或非 aid 訂單：維持 Path A / B / C
           -- Path A：互助訂單 — transfer 直接 FK 到 order
           EXISTS (
             SELECT 1 FROM transfers t
              WHERE t.customer_order_id = co.id
                AND t.tenant_id = co.tenant_id
                AND t.status IN ('received','closed')
           )
           OR
           -- Path B：普通團購 (per-camp PR) — wave_items.campaign_id 匹配
           EXISTS (
             SELECT 1
               FROM picking_wave_items pwi
               JOIN transfers t
                 ON t.tenant_id = pwi.tenant_id
                AND t.transfer_type = 'hq_to_store'
                AND t.transfer_no = 'WAVE-' || pwi.wave_id || '-S' || co.pickup_store_id
                AND t.status IN ('received','closed')
              WHERE pwi.tenant_id = co.tenant_id
                AND pwi.campaign_id = co.campaign_id
                AND pwi.store_id = co.pickup_store_id
           )
           OR
           -- Path C：close_date aggregated PR fallback
           -- 不檢 campaign_id 嚴格相等、改檢「所有 active items 的 (sku, store)
           -- 都有對應 received transfer」即算 ready。
           NOT EXISTS (
             SELECT 1 FROM customer_order_items coi
              WHERE coi.order_id = co.id
                AND coi.status NOT IN ('picked_up', 'cancelled', 'expired')
                AND NOT EXISTS (
                  SELECT 1
                    FROM picking_wave_items pwi
                    JOIN transfers t
                      ON t.tenant_id = pwi.tenant_id
                     AND t.transfer_type = 'hq_to_store'
                     AND t.transfer_no = 'WAVE-' || pwi.wave_id || '-S' || co.pickup_store_id
                     AND t.status IN ('received','closed')
                   WHERE pwi.tenant_id = co.tenant_id
                     AND pwi.store_id = co.pickup_store_id
                     AND pwi.sku_id = coi.sku_id
                )
           )
         )
       END
  );
$function$;

COMMENT ON FUNCTION public.is_order_pickup_ready(bigint) IS
  'aid_transfer 訂單依「跨店 vs 同店」分流：跨店只認 Path A (transfers FK 收貨)、'
  '同店維持 Path A/B/C（campaign wave 到該店即算）。非 aid 訂單一律 Path A/B/C。';

-- ----------------------------------------------------------------
-- 2. rpc_transfer_order_to_store — 同店改 mirror source.status
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_transfer_order_to_store(
  p_order_id              BIGINT,
  p_to_pickup_store_id    BIGINT,
  p_to_member_id          BIGINT,
  p_to_channel_id         BIGINT,
  p_operator              UUID,
  p_reason                TEXT DEFAULT NULL
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
  v_item             RECORD;
  v_orig_mov         RECORD;
  v_rev_id           BIGINT;
  v_now              TIMESTAMPTZ := NOW();
  v_note_out         TEXT;
  v_note_in          TEXT;
  v_new_status       TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  IF v_orig.status NOT IN ('pending','confirmed','reserved','ready') THEN
    RAISE EXCEPTION 'order % status=%, only pending/confirmed/reserved/ready can be transferred',
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

  PERFORM 1 FROM line_channels
   WHERE id = v_to_channel_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'channel % not in tenant', v_to_channel_id;
  END IF;

  PERFORM 1 FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = v_orig.campaign_id
     AND channel_id  = v_to_channel_id
     AND member_id   = v_to_member_id;
  IF FOUND THEN
    RAISE EXCEPTION 'receiver already has order in (campaign=%, channel=%, member=%)',
                    v_orig.campaign_id, v_to_channel_id, v_to_member_id;
  END IF;

  -- E2: 釋放 reserved_movement（無條件、跟以前一致；同店也走這條）
  FOR v_item IN
    SELECT id, reserved_movement_id FROM customer_order_items
     WHERE order_id = p_order_id AND reserved_movement_id IS NOT NULL
  LOOP
    SELECT * INTO v_orig_mov FROM stock_movements WHERE id = v_item.reserved_movement_id;
    IF FOUND THEN
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, reverses, reason, operator_id
      ) VALUES (
        v_orig_mov.tenant_id, v_orig_mov.location_id, v_orig_mov.sku_id,
        -v_orig_mov.quantity, v_orig_mov.unit_cost, 'reversal',
        'order_transfer', p_order_id, v_orig_mov.id,
        'order #' || p_order_id || ' transferred out, release allocation', p_operator
      ) RETURNING id INTO v_rev_id;

      UPDATE stock_movements SET reversed_by = v_rev_id WHERE id = v_orig_mov.id;
      UPDATE customer_order_items SET reserved_movement_id = NULL WHERE id = v_item.id;
    END IF;
  END LOOP;

  SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
  SELECT COUNT(*) + 1 INTO v_seq
    FROM customer_orders
   WHERE tenant_id = v_tenant_id AND campaign_id = v_orig.campaign_id;
  v_new_order_no := v_campaign_no || '-TF' || lpad(v_seq::text, 4, '0');

  v_note_in := COALESCE(p_reason, '') ||
               E'\n[轉入 ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
               to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

  -- 同店：mirror source.status；跨店：'pending'
  v_new_status := CASE
    WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN v_orig.status
    ELSE 'pending'
  END;

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id,
    nickname_snapshot, pickup_store_id, status, notes,
    transferred_from_order_id,
    created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
    v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status, v_note_in,
    p_order_id,
    p_operator, p_operator, v_now, v_now
  ) RETURNING id INTO v_new_order_id;

  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by
  )
  SELECT tenant_id, v_new_order_id, campaign_item_id, sku_id, qty, unit_price,
         'pending', 'aid_transfer', notes, p_operator, p_operator
    FROM customer_order_items
   WHERE order_id = p_order_id;

  v_note_out := COALESCE(p_reason, '') ||
                E'\n[轉出 → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

  UPDATE customer_orders
     SET status                   = 'transferred_out',
         transferred_to_order_id  = v_new_order_id,
         notes                    = COALESCE(notes, '') || v_note_out,
         updated_by               = p_operator,
         updated_at               = v_now
   WHERE id = p_order_id;

  RETURN v_new_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_transfer_order_to_store(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT) TO authenticated;

-- ----------------------------------------------------------------
-- 3. rpc_transfer_order_partial — 同店改 mirror source.status
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

  IF v_orig.status NOT IN ('pending','confirmed','reserved','ready') THEN
    RAISE EXCEPTION 'order % status=%, only pending/confirmed/reserved/ready can be transferred',
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

    -- 同店：mirror source.status；跨店：'pending'
    v_new_status := CASE
      WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN v_orig.status
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
      v_tenant_id, v_new_order_id, v_src_item_ci, v_p_sku_id, v_p_qty, v_src_item_price,
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

-- ----------------------------------------------------------------
-- 4. Backfill：把過去被同店強制設為 'ready'、但實際 pickup_ready=false 的
--    訂單退回 'pending'，並寫 1 筆 audit log。
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_uid       UUID;
  v_reverted  INTEGER := 0;
  v_rec       RECORD;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  FOR v_rec IN
    SELECT co.id
      FROM customer_orders co
     WHERE co.status = 'ready'
       AND EXISTS (
         SELECT 1 FROM customer_order_audit_log al
          WHERE al.order_id = co.id
            AND al.field = 'status'
            AND al.edit_reason LIKE '同店互轉自動推進%'
       )
       AND NOT public.is_order_pickup_ready(co.id)
  LOOP
    UPDATE customer_orders
       SET status     = 'pending',
           ready_at   = NULL,
           updated_by = v_uid,
           updated_at = NOW()
     WHERE id = v_rec.id;

    PERFORM rpc_log_order_status_change(
      v_rec.id, 'ready', 'pending', v_uid,
      '修正：同店互轉曾被誤強制設為 ready；實際無收貨、退回 pending'
    );
    v_reverted := v_reverted + 1;
  END LOOP;

  RAISE NOTICE 'Backfill: reverted % orders from ready→pending (同店互轉誤判)', v_reverted;
END $$;

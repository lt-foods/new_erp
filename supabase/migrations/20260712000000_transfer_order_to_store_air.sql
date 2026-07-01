-- ============================================================
-- rpc_transfer_order_to_store 加 p_is_air_transfer
--
-- 背景：轉出訂單（整單）在 UI 上要能勾「空中轉」。之前只有部分轉出
-- (rpc_transfer_order_partial) 支援 p_is_air_transfer，整單這支完全沒有
-- 這個參數、新單一律以 column default (FALSE) 寫入 → 整單轉出永遠被當成
-- 「經總倉」，下游 rpc_ship_aid_order 一律建 2 段 chain、要總倉確認。
--
-- 兩種轉單實體流（跟 partial 一致、由下游 rpc_ship_aid_order 依此 flag 分流）：
--   空中轉 (is_air_transfer=true)：轉出店 → 分店收貨 → 顧客取貨（不經總倉）
--   經總倉 (false)              ：轉出店 → 總倉(收到) → 配送 → 分店收貨 → 顧客取貨
--
-- 改動：DROP 舊 6-arg 版、CREATE 7-arg 版（尾加 p_is_air_transfer BOOLEAN
--      DEFAULT FALSE），把 flag 寫入新（轉入）訂單的 is_air_transfer 欄。
--      其餘邏輯（F2 只允 'ready'、同店 mirror source.status、釋放 reserved、
--      整單轉出把來源設 transferred_out）完全保留。
--
-- 基底：20260629000040_transfer_require_ready_status.sql 的
--      rpc_transfer_order_to_store（時間最新版）。
-- Rollback：DROP 本 7-arg 版、CREATE OR REPLACE 回 20260629000040 的 6-arg 版
--          （GRANT 也指回 6-arg 簽章）。
-- ============================================================

-- 舊 6-arg 版要先 DROP，否則 7-arg（含 DEFAULT）會與其成為 overload、
-- 6 個具名參數的呼叫變 ambiguous。
DROP FUNCTION IF EXISTS public.rpc_transfer_order_to_store(
  BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT
);

CREATE OR REPLACE FUNCTION public.rpc_transfer_order_to_store(
  p_order_id              BIGINT,
  p_to_pickup_store_id    BIGINT,
  p_to_member_id          BIGINT,
  p_to_channel_id         BIGINT,
  p_operator              UUID,
  p_reason                TEXT DEFAULT NULL,
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
               E'\n[轉入 (' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
               ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
               to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

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
    v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status, v_note_in,
    p_order_id, p_is_air_transfer,
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

GRANT EXECUTE ON FUNCTION public.rpc_transfer_order_to_store(
  BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, BOOLEAN
) TO authenticated;

COMMENT ON FUNCTION public.rpc_transfer_order_to_store(
  BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, BOOLEAN
) IS
  '整單轉出：新（轉入）單帶 is_air_transfer flag（true=空中轉不經總倉、false=經總倉中轉）；'
  '下游 rpc_ship_aid_order 依此建 1 段 / 2 段 transfer chain。基底 20260629000040。';

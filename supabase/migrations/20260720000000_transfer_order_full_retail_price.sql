-- ============================================================
-- 2026-07-20: 整單轉手（rpc_transfer_order_to_store）補鎖現售價
--
-- 問題（使用者回報）：補貨申請轉單到客戶端，價格顯示是進貨價非售價。
--
-- 根因：20260714000090 的「內部單(store_internal)轉給真會員 → 轉出價鎖
--   現售價(scope='retail')」修法只加在 rpc_transfer_order_partial（部分轉出）。
--   前端轉手 modal（OrderTransferModal）預設「全選全量」＝整單轉出，走的是
--   rpc_transfer_order_to_store — 該函式 INSERT..SELECT 直接照抄來源
--   customer_order_items.unit_price（= 補貨建單時的分店進貨價 snapshot），
--   所以客人單的單價變成進貨價。
--
-- 修法：rpc_transfer_order_to_store 加上與 partial 版完全相同的規則 —
--   來源單 member 是 store_internal 且目標 member 是真會員（非 store_internal）
--   → 轉出 item 單價改鎖當下現售價（prices scope='retail' 最新生效版；
--   查無現售價 fallback 來源價）。店↔店互助轉手（目標也是 internal）與
--   真會員→真會員一般轉手維持原價，不受影響。其餘邏輯逐字保留。
--
-- 基底版本：
--   rpc_transfer_order_to_store = 20260714000010（線上現行，已比對
--   pg_get_functiondef 一致），僅加 v_src_is_internal / v_dst_is_internal
--   判定與 items INSERT..SELECT 的現售價 CASE。
-- Rollback：CREATE OR REPLACE 回 20260714000010 的
--   rpc_transfer_order_to_store。
-- ============================================================

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
  v_src_is_internal  BOOLEAN := FALSE;
  v_dst_is_internal  BOOLEAN := FALSE;
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

  -- 內部單（【內部】xx店）轉給真會員 = 門市現貨銷售 → 轉出價改鎖現售價。
  -- 店↔店互助（目標也是 store_internal）維持原價不變。（同 20260714000090 partial 版規則）
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

  PERFORM 1 FROM line_channels
   WHERE id = v_to_channel_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'channel % not in tenant', v_to_channel_id;
  END IF;

  -- 重複收件人守衛：只看 active 訂單，對齊 partial unique index
  -- customer_orders_trio_kind_active_uniq（closed 狀態不佔 slot）。
  PERFORM 1 FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = v_orig.campaign_id
     AND channel_id  = v_to_channel_id
     AND member_id   = v_to_member_id
     AND status NOT IN ('transferred_out', 'expired', 'cancelled');
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
    v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status, v_note_in,
    p_order_id, p_is_air_transfer,
    p_operator, p_operator, v_now, v_now
  ) RETURNING id INTO v_new_order_id;

  -- 內部單 → 真會員：轉出價鎖定當下 SKU 現售價（scope='retail' 最新生效版）；
  -- 查無現售價 fallback 來源價。其餘情境維持原價。
  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by
  )
  SELECT coi.tenant_id, v_new_order_id, coi.campaign_item_id, coi.sku_id, coi.qty,
         CASE WHEN v_src_is_internal AND NOT v_dst_is_internal
              THEN COALESCE(pr.price, coi.unit_price)
              ELSE coi.unit_price
         END,
         'pending', 'aid_transfer', coi.notes, p_operator, p_operator
    FROM customer_order_items coi
    LEFT JOIN LATERAL (
      SELECT p2.price
        FROM prices p2
       WHERE v_src_is_internal AND NOT v_dst_is_internal
         AND p2.tenant_id = v_tenant_id
         AND p2.sku_id    = coi.sku_id
         AND p2.scope     = 'retail'
         AND p2.effective_from <= v_now
         AND (p2.effective_to IS NULL OR p2.effective_to > v_now)
       ORDER BY p2.effective_from DESC
       LIMIT 1
    ) pr ON TRUE
   WHERE coi.order_id = p_order_id;

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
  '整單轉出：新（轉入）單帶 is_air_transfer flag。跨店空中轉直接建 confirmed（略過總倉確認 '
  'gate、直接可派貨），經總倉建 pending。重複收件人守衛只看 active 單。'
  '內部單(store_internal)轉給真會員 = 門市現貨銷售，轉出價鎖當下現售價(scope=retail、無則原價)，'
  '與 rpc_transfer_order_partial 同規則。基底 20260714000010。';

-- ----------------------------------------------------------------
-- Backfill：存量「補貨單整單轉手到真會員」帶錯進貨價的 item 改回現售價。
-- 只修尚未完成的單（pending/confirmed/shipping/ready）；已完成
-- (completed/partially_completed) 的單涉及既成交易，不回溯改價。
-- 套用當下 prod 掃描：僅 __INTERNAL_RESTOCK__-TF0093（ready、165→244）在列；
-- TF0104（completed、179 vs 239）不動、已另行回報。
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_fixed INTEGER := 0;
BEGIN
  UPDATE customer_order_items coi
     SET unit_price = f.retail,
         updated_at = NOW()
    FROM (
      SELECT coi2.id AS item_id, pr.price AS retail
        FROM customer_order_items coi2
        JOIN customer_orders dst ON dst.id = coi2.order_id
        JOIN customer_orders src ON src.id = dst.transferred_from_order_id
        JOIN members m ON m.id = dst.member_id
        JOIN LATERAL (
          SELECT p2.price
            FROM prices p2
           WHERE p2.tenant_id = coi2.tenant_id
             AND p2.sku_id    = coi2.sku_id
             AND p2.scope     = 'retail'
             AND p2.effective_from <= NOW()
             AND (p2.effective_to IS NULL OR p2.effective_to > NOW())
           ORDER BY p2.effective_from DESC
           LIMIT 1
        ) pr ON TRUE
       WHERE src.order_kind = 'restock'
         AND m.member_type <> 'store_internal'
         AND dst.status IN ('pending','confirmed','shipping','ready')
         AND coi2.status <> 'cancelled'
         AND coi2.unit_price IS DISTINCT FROM pr.price
    ) f
   WHERE coi.id = f.item_id;
  GET DIAGNOSTICS v_fixed = ROW_COUNT;
  RAISE NOTICE 'Backfill: % 個補貨轉手 item 改回現售價', v_fixed;
END $$;

-- ============================================================
-- Phase 5a-2: 總倉調度後端 — transfers schema delta + 4 批次 RPC
-- TEST: docs/TEST-transfer-hq-dispatch.md
--
-- 對應 lt-erp 圖 2「店轉店與退倉審核」總倉端調度功能：
--   - 待審核 / 已到總倉 / 已配送 / 已收到 / 空中轉 五個狀態 tabs (view 層 derive)
--   - 批次到倉 / 批次配送 / 批次刪除 三個批次按鈕
--   - 單筆「登記損壞」
--   - 整單溫層 + 空中轉 flag + 總倉備註
-- ============================================================

-- ============================================================
-- 1. SCHEMA DELTA
-- ============================================================

ALTER TABLE transfers
  ADD COLUMN shipping_temp TEXT
    CHECK (shipping_temp IN ('frozen','chilled','ambient','mixed')),
  ADD COLUMN is_air_transfer BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN hq_notes TEXT;

ALTER TABLE transfer_items
  ADD COLUMN damage_qty NUMERIC(18,3) NOT NULL DEFAULT 0
    CHECK (damage_qty >= 0),
  ADD COLUMN damage_notes TEXT,
  ADD COLUMN damage_movement_id BIGINT REFERENCES stock_movements(id);

CREATE INDEX idx_transfers_air ON transfers (tenant_id, is_air_transfer)
  WHERE is_air_transfer = TRUE;
CREATE INDEX idx_transfers_temp ON transfers (tenant_id, shipping_temp)
  WHERE shipping_temp IS NOT NULL;

COMMENT ON COLUMN transfers.shipping_temp   IS 'Phase 5a-2: 整單溫層；mixed=多 SKU 不同溫層';
COMMENT ON COLUMN transfers.is_air_transfer IS 'Phase 5a-2: 空中轉 — A 直接交付 B、不經總倉';
COMMENT ON COLUMN transfers.hq_notes        IS 'Phase 5a-2: 總倉端備註（與分店端 notes 區分）';
COMMENT ON COLUMN transfer_items.damage_qty IS 'Phase 5a-2: 收貨後損壞數量、累加';

-- ============================================================
-- 2. rpc_transfer_arrive_at_hq_batch — 批次到倉
-- ============================================================
-- 對 dest=HQ + status='shipped' 的 TR 批次標 received（內部包 rpc_receive_transfer 全收）
-- 單筆 fail 不影響整批；返回 succeeded / failed 清單

CREATE OR REPLACE FUNCTION rpc_transfer_arrive_at_hq_batch(
  p_transfer_ids   BIGINT[],
  p_hq_location_id BIGINT,
  p_operator       UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id          BIGINT;
  v_dest        BIGINT;
  v_status      TEXT;
  v_succeeded   BIGINT[] := ARRAY[]::BIGINT[];
  v_failed      JSONB    := '[]'::jsonb;
  v_err         TEXT;
BEGIN
  IF p_transfer_ids IS NULL OR array_length(p_transfer_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;

  FOREACH v_id IN ARRAY p_transfer_ids LOOP
    BEGIN
      SELECT dest_location, status INTO v_dest, v_status
        FROM transfers WHERE id = v_id FOR UPDATE;

      IF v_dest IS NULL THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason', 'not found');
        CONTINUE;
      END IF;
      IF v_dest <> p_hq_location_id THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason',
          'dest_location ' || v_dest || ' is not HQ ' || p_hq_location_id);
        CONTINUE;
      END IF;
      IF v_status <> 'shipped' THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason',
          'status=' || v_status || ', expected shipped');
        CONTINUE;
      END IF;

      PERFORM rpc_receive_transfer(v_id, NULL, p_operator, NULL);
      v_succeeded := v_succeeded || v_id;
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
      v_failed := v_failed || jsonb_build_object('id', v_id, 'reason', v_err);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', array_length(p_transfer_ids, 1),
    'succeeded', to_jsonb(v_succeeded),
    'failed',    v_failed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_transfer_arrive_at_hq_batch(BIGINT[], BIGINT, UUID) TO authenticated;

-- ============================================================
-- 3. rpc_transfer_distribute_batch — 批次配送
-- ============================================================
-- 對 source=HQ + status='draft'/'confirmed' 的 TR 批次推到 'shipped'
-- 每筆對 source_location 跑 rpc_outbound (transfer_out)、寫 out_movement_id

CREATE OR REPLACE FUNCTION rpc_transfer_distribute_batch(
  p_transfer_ids   BIGINT[],
  p_hq_location_id BIGINT,
  p_operator       UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id          BIGINT;
  v_t           transfers%ROWTYPE;
  v_ti          RECORD;
  v_out_id      BIGINT;
  v_succeeded   BIGINT[] := ARRAY[]::BIGINT[];
  v_failed      JSONB    := '[]'::jsonb;
  v_err         TEXT;
BEGIN
  IF p_transfer_ids IS NULL OR array_length(p_transfer_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;

  FOREACH v_id IN ARRAY p_transfer_ids LOOP
    BEGIN
      SELECT * INTO v_t FROM transfers WHERE id = v_id FOR UPDATE;

      IF v_t.id IS NULL THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason', 'not found');
        CONTINUE;
      END IF;
      IF v_t.source_location <> p_hq_location_id THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason',
          'source_location ' || v_t.source_location || ' is not HQ ' || p_hq_location_id);
        CONTINUE;
      END IF;
      IF v_t.status NOT IN ('draft','confirmed') THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason',
          'status=' || v_t.status || ', expected draft/confirmed');
        CONTINUE;
      END IF;

      -- 為每行跑 rpc_outbound、寫 out_movement_id
      FOR v_ti IN
        SELECT id AS ti_id, sku_id, qty_requested
          FROM transfer_items
         WHERE transfer_id = v_id
      LOOP
        v_out_id := rpc_outbound(
          p_tenant_id       => v_t.tenant_id,
          p_location_id     => p_hq_location_id,
          p_sku_id          => v_ti.sku_id,
          p_quantity        => v_ti.qty_requested,
          p_movement_type   => 'transfer_out',
          p_source_doc_type => 'transfer',
          p_source_doc_id   => v_id,
          p_operator        => p_operator,
          p_allow_negative  => FALSE
        );

        UPDATE transfer_items
           SET qty_shipped     = qty_requested,
               out_movement_id = v_out_id,
               updated_by      = p_operator
         WHERE id = v_ti.ti_id;
      END LOOP;

      UPDATE transfers
         SET status     = 'shipped',
             shipped_by = p_operator,
             shipped_at = NOW(),
             updated_by = p_operator
       WHERE id = v_id;

      v_succeeded := v_succeeded || v_id;
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
      v_failed := v_failed || jsonb_build_object('id', v_id, 'reason', v_err);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', array_length(p_transfer_ids, 1),
    'succeeded', to_jsonb(v_succeeded),
    'failed',    v_failed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_transfer_distribute_batch(BIGINT[], BIGINT, UUID) TO authenticated;

-- ============================================================
-- 4. rpc_register_damage — 損壞登記
-- ============================================================
-- 在 transfer_item 上累加 damage_qty + 寫 'damage' stock_movement 從 dest_location 扣
-- 只允 transfer status='received'/'closed'

CREATE OR REPLACE FUNCTION rpc_register_damage(
  p_transfer_item_id BIGINT,
  p_damage_qty       NUMERIC,
  p_notes            TEXT,
  p_operator         UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ti           transfer_items%ROWTYPE;
  v_t            transfers%ROWTYPE;
  v_remaining    NUMERIC;
  v_movement_id  BIGINT;
BEGIN
  IF p_damage_qty IS NULL OR p_damage_qty <= 0 THEN
    RAISE EXCEPTION 'damage_qty must be > 0';
  END IF;

  SELECT * INTO v_ti FROM transfer_items WHERE id = p_transfer_item_id FOR UPDATE;
  IF v_ti.id IS NULL THEN
    RAISE EXCEPTION 'transfer_item % not found', p_transfer_item_id;
  END IF;

  SELECT * INTO v_t FROM transfers WHERE id = v_ti.transfer_id;
  IF v_t.status NOT IN ('received','closed') THEN
    RAISE EXCEPTION 'transfer % status=%, only received/closed allows damage register',
                    v_t.id, v_t.status;
  END IF;

  v_remaining := COALESCE(v_ti.qty_received, 0) - COALESCE(v_ti.damage_qty, 0);
  IF p_damage_qty > v_remaining THEN
    RAISE EXCEPTION 'damage_qty % exceeds remaining (qty_received % - already_damaged %)',
                    p_damage_qty, v_ti.qty_received, v_ti.damage_qty;
  END IF;

  INSERT INTO stock_movements (
    tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
    source_doc_type, source_doc_id, source_doc_line_id,
    reason, operator_id
  ) VALUES (
    v_t.tenant_id, v_t.dest_location, v_ti.sku_id, -p_damage_qty,
    NULL, 'damage',
    'transfer', v_t.id, p_transfer_item_id,
    COALESCE(p_notes, '') || ' (transfer #' || v_t.id || ' item #' || v_ti.id || ')',
    p_operator
  ) RETURNING id INTO v_movement_id;

  UPDATE transfer_items
     SET damage_qty          = COALESCE(damage_qty, 0) + p_damage_qty,
         damage_notes        = COALESCE(damage_notes || E'\n', '') ||
                               COALESCE(p_notes, '(no note)'),
         damage_movement_id  = v_movement_id,
         updated_by          = p_operator
   WHERE id = p_transfer_item_id;

  RETURN v_movement_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_register_damage(BIGINT, NUMERIC, TEXT, UUID) TO authenticated;

-- ============================================================
-- 5. rpc_transfer_batch_delete — 批次刪除
-- ============================================================
-- 只允 status='draft' 的 TR；CASCADE 刪 transfer_items

CREATE OR REPLACE FUNCTION rpc_transfer_batch_delete(
  p_transfer_ids BIGINT[],
  p_operator     UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id        BIGINT;
  v_status    TEXT;
  v_deleted   BIGINT[] := ARRAY[]::BIGINT[];
  v_failed    JSONB    := '[]'::jsonb;
  v_err       TEXT;
BEGIN
  IF p_transfer_ids IS NULL OR array_length(p_transfer_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;

  FOREACH v_id IN ARRAY p_transfer_ids LOOP
    BEGIN
      SELECT status INTO v_status FROM transfers WHERE id = v_id FOR UPDATE;

      IF v_status IS NULL THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason', 'not found');
        CONTINUE;
      END IF;
      IF v_status <> 'draft' THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason',
          'status=' || v_status || ', only draft can be deleted');
        CONTINUE;
      END IF;

      DELETE FROM transfers WHERE id = v_id;  -- transfer_items CASCADE
      v_deleted := v_deleted || v_id;
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
      v_failed := v_failed || jsonb_build_object('id', v_id, 'reason', v_err);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', array_length(p_transfer_ids, 1),
    'deleted',   to_jsonb(v_deleted),
    'failed',    v_failed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_transfer_batch_delete(BIGINT[], UUID) TO authenticated;

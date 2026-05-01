-- ============================================================
-- rpc_transfer_distribute_batch — 支援店間轉貨（source 不限 HQ）
--
-- 原設計（20260508000000）強制 source=HQ，店間轉貨（松山店→平鎮店等）
-- 會被擋下、店長只能去 dispatch 失敗收尾。改：
--   1. 拿掉 source=HQ 檢查
--   2. outbound 從 transfer 自己的 source_location 出
--   3. p_hq_location_id 參數保留 backward compat 但不再用作 source 限制
--
-- TEST: docs/TEST-store-self-service.md 補 §2 「店間 transfer 也能批次配送」
-- Rollback: 重新 apply 20260508000000 對應段
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_transfer_distribute_batch(
  p_transfer_ids   BIGINT[],
  p_hq_location_id BIGINT,  -- 保留參數但不再用作 source filter
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
      -- 拿掉 source=HQ 強制檢查；任何 source 都可推
      IF v_t.status NOT IN ('draft','confirmed') THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason',
          'status=' || v_t.status || ', expected draft/confirmed');
        CONTINUE;
      END IF;

      -- outbound 從 transfer 自己的 source_location（HQ 或店間）
      FOR v_ti IN
        SELECT id AS ti_id, sku_id, qty_requested
          FROM transfer_items
         WHERE transfer_id = v_id
      LOOP
        v_out_id := rpc_outbound(
          p_tenant_id       => v_t.tenant_id,
          p_location_id     => v_t.source_location,
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
    'succeeded', v_succeeded,
    'failed', v_failed
  );
END;
$$;

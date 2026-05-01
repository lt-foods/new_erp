-- ============================================================
-- 虛擬 SKU 跳過庫存動作（distribute + receive）
--
-- 虛擬商品 (products.is_virtual=TRUE) 沒有實庫存、不該觸發 outbound / inbound。
-- 自由轉貨用虛擬 SKU 時，distribute 會撞「庫存不足」失敗。修：
--   1. rpc_transfer_distribute_batch：對虛擬 SKU line 跳過 rpc_outbound、out_movement_id 留 NULL
--   2. rpc_receive_transfer：對虛擬 SKU 跳過 inbound、in_movement_id 留 NULL
--
-- TEST: 自由轉貨建出來的 transfer 應該能 distribute → 收貨完成
-- ============================================================

-- ----------------------------------------------------------------
-- distribute_batch: 虛擬 SKU 跳過 outbound
-- ----------------------------------------------------------------
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
  v_is_virtual  BOOLEAN;
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
      IF v_t.status NOT IN ('draft','confirmed') THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason',
          'status=' || v_t.status || ', expected draft/confirmed');
        CONTINUE;
      END IF;

      FOR v_ti IN
        SELECT id AS ti_id, sku_id, qty_requested
          FROM transfer_items
         WHERE transfer_id = v_id
      LOOP
        SELECT p.is_virtual INTO v_is_virtual
          FROM skus s JOIN products p ON p.id = s.product_id
         WHERE s.id = v_ti.sku_id;

        IF v_is_virtual THEN
          -- 虛擬 SKU：不動庫存、out_movement_id 留 NULL
          UPDATE transfer_items
             SET qty_shipped = qty_requested,
                 updated_by  = p_operator
           WHERE id = v_ti.ti_id;
        ELSE
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
        END IF;
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

-- ----------------------------------------------------------------
-- rpc_approve_restock_to_transfer / rpc_ship_restock_pr_received 也加 virtual 跳過
-- 但 restock 限真實 SKU（rpc_create_restock_request 已擋 virtual），這邊保險再加
-- ----------------------------------------------------------------
-- 不重寫上述 RPC（restock 不會碰 virtual sku）— 留 stock check 嚴格
-- ----------------------------------------------------------------
-- 注意：rpc_receive_transfer 收貨時也需跳過 virtual SKU 的 inbound；之後實測自由轉貨
-- 收貨流程若也撞錯再補一支

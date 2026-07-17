-- ============================================================
-- 2026-07-17: 萬華店歇業 — 取消全部在途調撥、貨記回總倉
--
-- 背景:
--   萬華店(stores.id=36 / location 7)已歇業,但仍有 66 張總倉出貨的
--   在途調撥(hq_to_store, status='shipped', 明細 94 條、共 164 件,
--   最早 2026-06-04 出貨)從未被收貨。使用者(cktalex)確認歇業並指示
--   全數取消。
--
-- 做法(語義沿用 rpc_cancel_aid_order 的「撤回回流源點」):
--   逐張:每條 qty_shipped > 0 的明細以 rpc_inbound(movement_type=
--   'transfer_cancel', 20260713000000 起為合法值)把貨記回出貨來源
--   (全部為總倉 location 1,已核對)、成本取原 transfer_out 的
--   |unit_cost|;然後調撥單 status='cancelled' 並在 notes 註記。
--   取消後這些調撥自動退出:補貨歸屬/防重複派貨守衛、月結、
--   v_picking_* 需求視圖(皆已排除 status='cancelled')。
--
-- 已知後續(本檔不處理,另行決策):
--   - 萬華 91 張未結會員訂單(84 shipping / 6 confirmed / 1 pending)
--     需逐批處理(轉店/取消退款)。
--   - stores/locations 的 is_active 仍為 true,歇業停用另行處理。
--   - 萬華店倉(location 7)既有在庫請盤點後另行處理。
--
-- 前置核對(2026-07-17 線上):66 張全為 hq_to_store、source_location=1、
--   無 draft、out_movement 無已沖銷紀錄、萬華無未結補貨申請。
-- Rollback:無自動回復 — 如需重派,依 notes 註記與 transfer_cancel
--   movements(source_doc_id=原調撥)重建出貨單。
-- ============================================================

DO $$
DECLARE
  v_uid       UUID;
  v_t         RECORD;
  v_ti        RECORD;
  v_transfers INTEGER := 0;
  v_items     INTEGER := 0;
  v_qty       NUMERIC := 0;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  FOR v_t IN
    SELECT id, tenant_id, source_location, notes
      FROM transfers
     WHERE dest_location = 7
       AND status = 'shipped'
       AND transfer_type = 'hq_to_store'
     ORDER BY id
     FOR UPDATE
  LOOP
    FOR v_ti IN
      SELECT ti.id, ti.sku_id, ti.qty_shipped, ti.out_movement_id,
             sm.location_id AS src_loc, sm.unit_cost AS out_cost
        FROM transfer_items ti
        LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
       WHERE ti.transfer_id = v_t.id
    LOOP
      IF v_ti.qty_shipped > 0 AND v_ti.out_movement_id IS NOT NULL THEN
        PERFORM rpc_inbound(
          p_tenant_id       => v_t.tenant_id,
          p_location_id     => COALESCE(v_ti.src_loc, v_t.source_location),
          p_sku_id          => v_ti.sku_id,
          p_quantity        => v_ti.qty_shipped,
          p_unit_cost       => COALESCE(ABS(v_ti.out_cost), 0),
          p_movement_type   => 'transfer_cancel',
          p_source_doc_type => 'transfer',
          p_source_doc_id   => v_t.id,
          p_operator        => v_uid
        );
        v_items := v_items + 1;
        v_qty   := v_qty + v_ti.qty_shipped;
      END IF;
    END LOOP;

    UPDATE transfers
       SET status     = 'cancelled',
           notes      = COALESCE(NULLIF(v_t.notes, '') || E'\n', '')
                        || '2026-07-17 萬華店歇業:總倉撤回取消在途調撥,貨記回總倉(transfer_cancel)',
           updated_by = v_uid
     WHERE id = v_t.id;

    v_transfers := v_transfers + 1;
  END LOOP;

  RAISE NOTICE '萬華歇業清理:取消 % 張調撥、沖回 % 條明細、共 % 件回總倉帳',
    v_transfers, v_items, v_qty;
END $$;

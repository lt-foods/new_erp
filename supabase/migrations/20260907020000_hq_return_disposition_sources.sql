-- ============================================================
-- 總倉退回貨處理 — B 來源接線
-- 20260907020000_hq_return_disposition_sources.sql
--
-- 依賴：20260907010000（_hq_hold_return helper、hq_return_batches 表）
--       20260422120003（transfer_items、stock_movements、locations）
--       20260904020010（rpc_receive_transfer 寫 in_movement_id）
--       20260903000200（rpc_resolve_transfer_item_shortage 寫 shortage_restock_movement_id）
--
-- 本檔 append-only，不改任何既有表結構、不改 A 檔函式、不改任何 RPC。
-- ============================================================

-- ============================================================
-- 1. _hq_return_source_on_ti — trigger 函式
--
-- AFTER INSERT OR UPDATE OF in_movement_id, shortage_restock_movement_id
-- ON transfer_items FOR EACH ROW
--
-- 兩條來源各自檢查，同一列理論上只會命中一條：
--   A) in_movement_id 從 NULL→非NULL：store_return（退貨回總倉入庫）
--   B) shortage_restock_movement_id 從 NULL→非NULL：shortage（短少沖回）
--
-- 觸發時機：在入庫完成後（rpc_receive_transfer / rpc_resolve 已寫完
-- stock_movement 和 balance），同一交易內呼叫 _hq_hold_return 建批次＋凍結。
-- 不能留時間窗讓庫存先可派再凍結。
-- ============================================================
CREATE OR REPLACE FUNCTION public._hq_return_source_on_ti()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_transfer      RECORD;
  v_mov           RECORD;
  v_loc_type      TEXT;
  v_operator_id   UUID;
  v_auto_flag     TEXT;
  v_source_reason TEXT;
  v_batch_id      BIGINT;
BEGIN
  -- ================================================================
  -- 來源 A：in_movement_id（店家退貨回總倉的真入庫 movement）
  -- ================================================================
  IF  NEW.in_movement_id IS NOT NULL
  AND (TG_OP = 'INSERT' OR OLD.in_movement_id IS DISTINCT FROM NEW.in_movement_id)
  THEN
    -- 取父調撥單
    SELECT t.tenant_id, t.transfer_type, t.dest_location, t.notes
      INTO v_transfer
      FROM transfers t
     WHERE t.id = NEW.transfer_id;

    -- 只處理 return_to_hq（一般到貨 hq_to_store / store_to_store 跳過）
    IF v_transfer.transfer_type = 'return_to_hq' THEN

      -- 驗證 movement 存在且為正向入庫
      SELECT m.id, m.tenant_id, m.location_id, m.sku_id, m.quantity,
             m.movement_type, m.source_doc_type, m.source_doc_id, m.operator_id
        INTO v_mov
        FROM stock_movements m
       WHERE m.id = NEW.in_movement_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION '_hq_return_source: in_movement_id % not found', NEW.in_movement_id;
      END IF;

      -- 必須是正向 movement（quantity > 0）；短收沖帳單 in_movement_id IS NULL，
      -- 不會進到這裡；但 defensive check
      IF v_mov.quantity <= 0 THEN
        RAISE EXCEPTION '_hq_return_source: in_movement_id % quantity=% is not positive',
          NEW.in_movement_id, v_mov.quantity;
      END IF;

      -- tenant 一致
      IF v_mov.tenant_id != v_transfer.tenant_id THEN
        RAISE EXCEPTION '_hq_return_source: movement % tenant mismatch', NEW.in_movement_id;
      END IF;

      -- SKU 一致
      IF v_mov.sku_id != NEW.sku_id THEN
        RAISE EXCEPTION '_hq_return_source: movement % sku_id=% != item sku_id=%',
          NEW.in_movement_id, v_mov.sku_id, NEW.sku_id;
      END IF;

      -- movement location 必須是 dest_location（HQ）
      IF v_mov.location_id != v_transfer.dest_location THEN
        RAISE EXCEPTION '_hq_return_source: movement % location=% != transfer dest=%',
          NEW.in_movement_id, v_mov.location_id, v_transfer.dest_location;
      END IF;

      -- dest 必須是 central_warehouse
      SELECT l.type INTO v_loc_type
        FROM locations l
       WHERE l.id = v_transfer.dest_location;

      IF COALESCE(v_loc_type, '') != 'central_warehouse' THEN
        -- 不是總倉，跳過（不凍結）
        RETURN NEW;
      END IF;

      -- movement_type 必須是 transfer_in（防禦性）
      IF v_mov.movement_type != 'transfer_in' THEN
        RAISE EXCEPTION '_hq_return_source: in_movement_id % type=% expected transfer_in',
          NEW.in_movement_id, v_mov.movement_type;
      END IF;

      -- movement 必須真的屬於這張 transfer；NULL 也要擋，不可當成通過
      IF v_mov.source_doc_type IS DISTINCT FROM 'transfer'
      OR v_mov.source_doc_id IS DISTINCT FROM NEW.transfer_id
      THEN
        RAISE EXCEPTION '_hq_return_source: movement % source=%/% expected transfer/%',
          NEW.in_movement_id, v_mov.source_doc_type, v_mov.source_doc_id, NEW.transfer_id;
      END IF;

      -- transfer_items 觸發時 parent.received_by 尚未更新；操作者以來源 movement 為準
      v_operator_id := v_mov.operator_id;
      v_auto_flag := CASE
        WHEN v_operator_id = '00000000-0000-0000-0000-000000000000'::UUID
        THEN 'system' ELSE 'manual'
      END;

      -- 原因：只快照觸發當下父單已有 notes；不含本次收貨 p_notes
      v_source_reason := LEFT(v_transfer.notes, 200);

      -- 呼叫 A helper 建批次（冪等：同 source_movement_id 回傳既有 id）
      v_batch_id := public._hq_hold_return(
        p_tenant_id               => v_transfer.tenant_id,
        p_location_id             => v_transfer.dest_location,
        p_sku_id                  => NEW.sku_id,
        p_source_movement_id      => NEW.in_movement_id,
        p_source_transfer_item_id => NEW.id,
        p_source_kind             => 'store_return',
        p_source_reason           => v_source_reason,
        p_qty                     => v_mov.quantity,
        p_operator_id             => v_operator_id,
        p_auto_flag               => v_auto_flag
      );
    END IF;
  END IF;

  -- ================================================================
  -- 來源 B：shortage_restock_movement_id（短少沖回的真入庫 movement）
  -- ================================================================
  IF  NEW.shortage_restock_movement_id IS NOT NULL
  AND (TG_OP = 'INSERT' OR OLD.shortage_restock_movement_id IS DISTINCT FROM NEW.shortage_restock_movement_id)
  THEN
    -- 取父調撥單
    SELECT t.tenant_id, t.transfer_type, t.source_location
      INTO v_transfer
      FROM transfers t
     WHERE t.id = NEW.transfer_id;

    -- 驗證 movement
    SELECT m.id, m.tenant_id, m.location_id, m.sku_id, m.quantity,
           m.movement_type, m.source_doc_type, m.source_doc_id, m.operator_id
      INTO v_mov
      FROM stock_movements m
     WHERE m.id = NEW.shortage_restock_movement_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION '_hq_return_source: shortage_restock_movement_id % not found',
        NEW.shortage_restock_movement_id;
    END IF;

    IF v_mov.quantity <= 0 THEN
      RAISE EXCEPTION '_hq_return_source: shortage_restock_movement_id % quantity=% not positive',
        NEW.shortage_restock_movement_id, v_mov.quantity;
    END IF;

    IF v_mov.tenant_id != v_transfer.tenant_id THEN
      RAISE EXCEPTION '_hq_return_source: shortage movement % tenant mismatch',
        NEW.shortage_restock_movement_id;
    END IF;

    IF v_mov.sku_id != NEW.sku_id THEN
      RAISE EXCEPTION '_hq_return_source: shortage movement % sku_id=% != item sku_id=%',
        NEW.shortage_restock_movement_id, v_mov.sku_id, NEW.sku_id;
    END IF;

    -- movement location 必須是 source_location（短少沖回出貨端）
    IF v_mov.location_id != v_transfer.source_location THEN
      RAISE EXCEPTION '_hq_return_source: shortage movement % location=% != transfer source=%',
        NEW.shortage_restock_movement_id, v_mov.location_id, v_transfer.source_location;
    END IF;

    -- 出貨端必須是 central_warehouse（店對店短少不是本案 HQ 批次，不假移總倉）
    SELECT l.type INTO v_loc_type
      FROM locations l
     WHERE l.id = v_transfer.source_location;

    IF COALESCE(v_loc_type, '') != 'central_warehouse' THEN
      RETURN NEW;
    END IF;

    -- movement_type 必須是 transfer_cancel（防禦性）
    IF v_mov.movement_type != 'transfer_cancel' THEN
      RAISE EXCEPTION '_hq_return_source: shortage movement % type=% expected transfer_cancel',
        NEW.shortage_restock_movement_id, v_mov.movement_type;
    END IF;

    -- movement 必須真的屬於這張 transfer；NULL 也要擋，不可當成通過
    IF v_mov.source_doc_type IS DISTINCT FROM 'transfer'
    OR v_mov.source_doc_id IS DISTINCT FROM NEW.transfer_id
    THEN
      RAISE EXCEPTION '_hq_return_source: shortage movement % source=%/% expected transfer/%',
        NEW.shortage_restock_movement_id,
        v_mov.source_doc_type, v_mov.source_doc_id, NEW.transfer_id;
    END IF;

    -- shortage 的 operator：取 rpc_resolve 傳入的 p_operator（存在 shortage_resolution_by）
    v_operator_id := COALESCE(NEW.shortage_resolution_by,
                              '00000000-0000-0000-0000-000000000000'::UUID);
    v_auto_flag := 'manual';  -- shortage resolution 必定是人工操作

    v_source_reason := 'shortage:'
      || COALESCE(NEW.shortage_resolution, '')
      || COALESCE(' ' || LEFT(NEW.shortage_resolution_notes, 150), '');

    v_batch_id := public._hq_hold_return(
      p_tenant_id               => v_transfer.tenant_id,
      p_location_id             => v_transfer.source_location,
      p_sku_id                  => NEW.sku_id,
      p_source_movement_id      => NEW.shortage_restock_movement_id,
      p_source_transfer_item_id => NEW.id,
      p_source_kind             => 'shortage',
      p_source_reason           => v_source_reason,
      p_qty                     => v_mov.quantity,
      p_operator_id             => v_operator_id,
      p_auto_flag               => v_auto_flag
    );
  END IF;

  RETURN NEW;
END;
$$;

-- ⛔ 安全：不開放給任何前端角色
REVOKE ALL ON FUNCTION public._hq_return_source_on_ti() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._hq_return_source_on_ti() FROM anon;
REVOKE ALL ON FUNCTION public._hq_return_source_on_ti() FROM authenticated;

COMMENT ON FUNCTION public._hq_return_source_on_ti IS
  'B段接線 trigger 函式：transfer_items 的 in_movement_id（store_return）'
  '或 shortage_restock_movement_id（shortage）從 NULL 變非NULL 時，'
  '驗證 movement 真實性後呼叫 _hq_hold_return 建批次＋凍結。'
  'SECURITY DEFINER，REVOKE PUBLIC/anon/authenticated。';

-- ============================================================
-- 2. trigger 掛載
--
-- AFTER INSERT OR UPDATE：在 rpc_receive_transfer / rpc_resolve 已完成
-- stock_movement 寫入與 balance 更新之後，同一交易內建批次。
-- 不是 BEFORE（BEFORE 時 movement 還沒寫完 balance）。
-- ============================================================
CREATE TRIGGER trg_hq_return_source
  AFTER INSERT OR UPDATE OF in_movement_id, shortage_restock_movement_id
  ON public.transfer_items
  FOR EACH ROW
  EXECUTE FUNCTION public._hq_return_source_on_ti();

COMMENT ON TRIGGER trg_hq_return_source ON public.transfer_items IS
  'B段接線：store_return（in_movement_id）與 shortage（shortage_restock_movement_id）'
  '真來源寫入時建 hq_return_batches 批次。同一交易內，不留時間窗。';

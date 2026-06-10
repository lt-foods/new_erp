-- ============================================================
-- 採購單「刪除」+「斷貨」
--
-- 背景：
--   1. 重複開到一樣的採購單，需要可以刪掉（draft / sent / cancelled、
--      且尚無任何進貨紀錄時才允許）。
--   2. 供應商斷貨時，未到貨的量不再等待，要能直接把 PO 結掉。
--
-- 基底版本：
--   - rpc_delete_purchase_order / rpc_stockout_purchase_order 為全新函式，
--     無既有版本（已 grep supabase/migrations/ 確認）。
--   - purchase_orders 斷貨欄位為新增（stockout_at / stockout_by / stockout_reason）。
--
-- Rollback：
--   DROP FUNCTION IF EXISTS public.rpc_delete_purchase_order(BIGINT, UUID);
--   DROP FUNCTION IF EXISTS public.rpc_stockout_purchase_order(BIGINT, UUID, TEXT);
--   ALTER TABLE purchase_orders
--     DROP COLUMN IF EXISTS stockout_at,
--     DROP COLUMN IF EXISTS stockout_by,
--     DROP COLUMN IF EXISTS stockout_reason;
-- ============================================================

-- ------------------------------------------------------------
-- 1. purchase_orders 斷貨欄位
-- ------------------------------------------------------------

ALTER TABLE purchase_orders
  ADD COLUMN IF NOT EXISTS stockout_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS stockout_by     UUID,
  ADD COLUMN IF NOT EXISTS stockout_reason TEXT;

COMMENT ON COLUMN purchase_orders.stockout_at IS
  '標記斷貨的時間；NULL = 未斷貨。斷貨後 status 會轉 closed（已有部分到貨）或 cancelled（完全沒到貨）';

-- ------------------------------------------------------------
-- 2. RPC: rpc_delete_purchase_order
--    硬刪除 PO（限 draft / sent / cancelled、且無任何進貨單）。
--    來源 PR 品項解除 po_item_id 連結、PR 狀態回算，方便重新拆單。
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_delete_purchase_order(
  p_po_id    BIGINT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_po         purchase_orders%ROWTYPE;
  v_gr_count   INTEGER;
  v_wave_count INTEGER;
  v_pr_ids     BIGINT[];
BEGIN
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;

  IF v_po.status NOT IN ('draft','sent','cancelled') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可刪除（僅限草稿 / 已發送 / 已取消）',
      v_po.po_no, v_po.status;
  END IF;

  SELECT COUNT(*) INTO v_gr_count FROM goods_receipts WHERE po_id = p_po_id;
  IF v_gr_count > 0 THEN
    RAISE EXCEPTION '採購單 % 已有 % 筆進貨紀錄、不可刪除', v_po.po_no, v_gr_count;
  END IF;

  SELECT COUNT(*) INTO v_wave_count FROM picking_waves WHERE source_po_id = p_po_id;
  IF v_wave_count > 0 THEN
    RAISE EXCEPTION '採購單 % 已建立 % 張撿貨單、不可刪除', v_po.po_no, v_wave_count;
  END IF;

  -- 解除來源 PR 品項連結（先記下受影響的 PR、稍後回算狀態）
  SELECT ARRAY_AGG(DISTINCT pri.pr_id) INTO v_pr_ids
    FROM purchase_request_items pri
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
   WHERE poi.po_id = p_po_id;

  UPDATE purchase_request_items pri
     SET po_item_id = NULL,
         updated_by = p_operator,
         updated_at = NOW()
    FROM purchase_order_items poi
   WHERE poi.id = pri.po_item_id
     AND poi.po_id = p_po_id;

  -- PR 狀態回算：還有其他 PO 連結 → partially_ordered；全無 → submitted
  IF v_pr_ids IS NOT NULL THEN
    UPDATE purchase_requests pr
       SET status = CASE
             WHEN EXISTS (
               SELECT 1 FROM purchase_request_items x
                WHERE x.pr_id = pr.id AND x.po_item_id IS NOT NULL
             ) THEN 'partially_ordered'
             ELSE 'submitted'
           END,
           updated_by = p_operator,
           updated_at = NOW()
     WHERE pr.id = ANY(v_pr_ids)
       AND pr.status IN ('partially_ordered','fully_ordered');
  END IF;

  BEGIN
    -- purchase_order_items 由 FK ON DELETE CASCADE 一併刪除
    DELETE FROM purchase_orders WHERE id = p_po_id;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION '採購單 % 已被其他單據引用（帳款 / 需求單等）、無法刪除', v_po.po_no;
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_delete_purchase_order TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_purchase_order IS
  '硬刪除 PO（限 draft/sent/cancelled、無進貨單與撿貨單）；解除來源 PR 品項連結並回算 PR 狀態';

-- ------------------------------------------------------------
-- 3. RPC: rpc_stockout_purchase_order
--    供應商斷貨：未到貨的量不再等待。
--    已有部分到貨 → closed；完全沒到貨 → cancelled。
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_stockout_purchase_order(
  p_po_id    BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_po         purchase_orders%ROWTYPE;
  v_received   NUMERIC(18,3);
  v_new_status TEXT;
BEGIN
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;

  IF v_po.status NOT IN ('sent','partially_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可標記斷貨（需為「已發送」或「部分到貨」）',
      v_po.po_no, v_po.status;
  END IF;

  SELECT COALESCE(SUM(qty_received), 0) INTO v_received
    FROM purchase_order_items
   WHERE po_id = p_po_id;

  v_new_status := CASE WHEN v_received > 0 THEN 'closed' ELSE 'cancelled' END;

  UPDATE purchase_orders
     SET status          = v_new_status,
         stockout_at     = NOW(),
         stockout_by     = p_operator,
         stockout_reason = NULLIF(BTRIM(p_reason), ''),
         updated_by      = p_operator,
         updated_at      = NOW()
   WHERE id = p_po_id;

  RETURN jsonb_build_object('po_no', v_po.po_no, 'new_status', v_new_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_stockout_purchase_order TO authenticated;

COMMENT ON FUNCTION public.rpc_stockout_purchase_order IS
  '供應商斷貨：sent/partially_received 的 PO 直接結掉（有到貨→closed、無到貨→cancelled），記錄 stockout_at/by/reason';

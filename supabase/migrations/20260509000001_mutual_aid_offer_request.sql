-- ============================================================
-- Phase 5c step 2 — 互助交流板兩種 post type + 訂單聯動
--
-- 設計收斂：
--   - offer  「我有庫存可提供」 → 從既有 customer_order 釋出
--       UI: 我要認領 → call rpc_transfer_order_to_store(post.source_customer_order_id, 接收店, ...)
--           → 把 offering store 的訂單轉成接收店的
--   - request「我要求助」       → 純需求（沒 source order）
--       UI: 我可以提供 → 提供方選自己 pending 訂單 → call rpc_transfer_order_to_store
--
-- 變動：
--   1. mutual_aid_board 加 post_type、source_customer_order_id 欄位
--   2. DROP + RECREATE rpc_post_aid_board (加 p_post_type + p_source_customer_order_id)
-- ============================================================

-- ============================================================
-- 1. mutual_aid_board 加 post_type + source_customer_order_id
-- ============================================================

ALTER TABLE mutual_aid_board
  ADD COLUMN post_type TEXT NOT NULL DEFAULT 'offer'
    CHECK (post_type IN ('offer', 'request')),
  ADD COLUMN source_customer_order_id BIGINT REFERENCES customer_orders(id);

-- 5c step 1 期間的測試貼文沒 source_order、不能滿足新 constraint → 砍掉
-- production 沒人在用、安全；append-only trigger 暫關 + 補回
ALTER TABLE mutual_aid_replies DISABLE TRIGGER trg_no_mut_aid_replies;
DELETE FROM mutual_aid_replies
 WHERE board_id IN (SELECT id FROM mutual_aid_board WHERE source_customer_order_id IS NULL);
ALTER TABLE mutual_aid_replies ENABLE TRIGGER trg_no_mut_aid_replies;

DELETE FROM mutual_aid_board WHERE source_customer_order_id IS NULL;

-- offer 必須有 source_order；request 必須沒有
ALTER TABLE mutual_aid_board
  ADD CONSTRAINT aid_board_source_consistency CHECK (
    (post_type = 'offer'   AND source_customer_order_id IS NOT NULL)
    OR (post_type = 'request' AND source_customer_order_id IS NULL)
  );

CREATE INDEX idx_aid_active_by_type ON mutual_aid_board (tenant_id, post_type, status, expires_at)
  WHERE status = 'active';

CREATE INDEX idx_aid_source_order ON mutual_aid_board (source_customer_order_id)
  WHERE source_customer_order_id IS NOT NULL;

-- ============================================================
-- 2. rpc_post_aid_board 加新參數
-- ============================================================
-- DROP 舊版（6 args）+ CREATE 新版（8 args）
-- 6-arg 沒人在 prod 呼叫過、安全 drop

DROP FUNCTION IF EXISTS rpc_post_aid_board(BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID);

CREATE OR REPLACE FUNCTION rpc_post_aid_board(
  p_offering_store_id        BIGINT,
  p_sku_id                   BIGINT,
  p_qty_available            NUMERIC,
  p_expires_at               TIMESTAMPTZ,
  p_note                     TEXT,
  p_operator                 UUID,
  p_post_type                TEXT,
  p_source_customer_order_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id     UUID;
  v_board_id      BIGINT;
  v_order_tenant  UUID;
  v_order_store   BIGINT;
BEGIN
  IF p_post_type NOT IN ('offer', 'request') THEN
    RAISE EXCEPTION 'p_post_type must be offer or request';
  END IF;
  IF p_qty_available IS NULL OR p_qty_available <= 0 THEN
    RAISE EXCEPTION 'qty_available must be > 0';
  END IF;
  IF p_expires_at IS NULL OR p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'expires_at must be in the future';
  END IF;

  SELECT tenant_id INTO v_tenant_id FROM stores WHERE id = p_offering_store_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_offering_store_id;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM skus WHERE id = p_sku_id) THEN
    RAISE EXCEPTION 'sku % not found', p_sku_id;
  END IF;

  -- offer 必須帶 source_customer_order_id 且該 order 屬同 tenant、屬發貼店、未轉出
  IF p_post_type = 'offer' THEN
    IF p_source_customer_order_id IS NULL THEN
      RAISE EXCEPTION 'offer post requires p_source_customer_order_id';
    END IF;

    SELECT tenant_id, pickup_store_id INTO v_order_tenant, v_order_store
      FROM customer_orders WHERE id = p_source_customer_order_id;
    IF v_order_tenant IS NULL THEN
      RAISE EXCEPTION 'customer_order % not found', p_source_customer_order_id;
    END IF;
    IF v_order_tenant <> v_tenant_id THEN
      RAISE EXCEPTION 'cross-tenant order';
    END IF;
    IF v_order_store <> p_offering_store_id THEN
      RAISE EXCEPTION 'order pickup_store_id (%) does not match offering_store_id (%)',
                       v_order_store, p_offering_store_id;
    END IF;
  ELSE
    -- request：source_customer_order_id 須為 NULL
    IF p_source_customer_order_id IS NOT NULL THEN
      RAISE EXCEPTION 'request post must not have source_customer_order_id';
    END IF;
  END IF;

  INSERT INTO mutual_aid_board (
    tenant_id, offering_store_id, sku_id, qty_available, qty_remaining,
    expires_at, note, status, post_type, source_customer_order_id,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, p_offering_store_id, p_sku_id, p_qty_available, p_qty_available,
    p_expires_at, NULLIF(trim(p_note), ''), 'active', p_post_type, p_source_customer_order_id,
    p_operator, p_operator
  )
  RETURNING id INTO v_board_id;

  RETURN v_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_post_aid_board(BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID, TEXT, BIGINT) TO authenticated;

COMMENT ON FUNCTION rpc_post_aid_board IS
  'Phase 5c：發起互助貼文；offer 須帶 source_customer_order_id (對應 5b-1 的訂單轉出)、request 不帶';

-- ============================================================
-- 2026-08-02: 互助板 offer 可自訂釋出單價與商品說明
--
-- 需求（會員端現貨專區）：
--   1. 店家上架「我有庫存可提供」時可以改金額。App 顯示改後的價；
--      改得比原價（來源訂單 customer_order_items.unit_price）低時，
--      App 用刪除線顯示原價，代表比原價便宜。
--   2. 商品說明可以改寫原文（預設帶入 products.description，可編輯）。
--      App 詳情頁顯示改寫版，沒改就 fallback 回商品主檔的說明。
--
-- 變動：
--   1. mutual_aid_board 加 spot_price / spot_description（都可 NULL =
--      沒改，讀取端 fallback 回原價 / 原說明）
--   2. rpc_post_aid_board 加 p_spot_price + p_spot_description
--
-- 基底版本：20260509000001_mutual_aid_offer_request.sql 的 8 參數版
--   （已 grep supabase/migrations/ 確認：動過此函式的只有
--    20260509000000（6 參數初版）與 20260509000001（現行 8 參數版），
--    本檔基於後者擴寫，原有驗證邏輯一字未改）
--
-- 為何 DROP 再 CREATE：參數個數變了（8 → 10）。CREATE OR REPLACE 會多出
--   overload，之後具名呼叫撞 "function is not unique"。
--   新參數皆有 DEFAULT，已部署的舊前端具名呼叫 8 參數仍解得到，無空窗。
--
-- Rollback（回到 20260509000001 版本）：
--   DROP FUNCTION IF EXISTS rpc_post_aid_board(
--     BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID, TEXT, BIGINT, NUMERIC, TEXT);
--   -- 重跑 20260509000001 的 §2 段落
--   ALTER TABLE mutual_aid_board DROP COLUMN spot_price, DROP COLUMN spot_description;
-- ============================================================

ALTER TABLE mutual_aid_board
  ADD COLUMN spot_price       NUMERIC(18,4) CHECK (spot_price IS NULL OR spot_price > 0),
  ADD COLUMN spot_description TEXT;

COMMENT ON COLUMN mutual_aid_board.spot_price IS
  '釋出單價（店家上架時可改）；NULL = 沿用來源訂單原價。'
  '低於原價時會員端會以刪除線顯示原價。';
COMMENT ON COLUMN mutual_aid_board.spot_description IS
  '上架時改寫的商品說明（純文字）；NULL = 會員端 fallback 回 products.description。';

DROP FUNCTION IF EXISTS rpc_post_aid_board(
  BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID, TEXT, BIGINT);

CREATE OR REPLACE FUNCTION rpc_post_aid_board(
  p_offering_store_id        BIGINT,
  p_sku_id                   BIGINT,
  p_qty_available            NUMERIC,
  p_expires_at               TIMESTAMPTZ,
  p_note                     TEXT,
  p_operator                 UUID,
  p_post_type                TEXT,
  p_source_customer_order_id BIGINT,
  p_spot_price               NUMERIC DEFAULT NULL,
  p_spot_description         TEXT    DEFAULT NULL
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
  -- 自訂價 / 自訂說明只對 offer 有意義（request 是求援，不是上架商品）
  IF p_spot_price IS NOT NULL THEN
    IF p_post_type <> 'offer' THEN
      RAISE EXCEPTION 'spot_price is only valid for offer posts';
    END IF;
    IF p_spot_price <= 0 THEN
      RAISE EXCEPTION 'spot_price must be > 0';
    END IF;
  END IF;
  IF p_spot_description IS NOT NULL AND p_post_type <> 'offer' THEN
    RAISE EXCEPTION 'spot_description is only valid for offer posts';
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
    spot_price, spot_description,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, p_offering_store_id, p_sku_id, p_qty_available, p_qty_available,
    p_expires_at, NULLIF(trim(p_note), ''), 'active', p_post_type, p_source_customer_order_id,
    p_spot_price, NULLIF(trim(p_spot_description), ''),
    p_operator, p_operator
  )
  RETURNING id INTO v_board_id;

  RETURN v_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_post_aid_board(
  BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID, TEXT, BIGINT, NUMERIC, TEXT) TO authenticated;

COMMENT ON FUNCTION rpc_post_aid_board IS
  '發起互助貼文；offer 須帶 source_customer_order_id。'
  '2026-08-02 加 p_spot_price / p_spot_description（僅 offer 可用；NULL = 沿用原價 / 原說明）。';

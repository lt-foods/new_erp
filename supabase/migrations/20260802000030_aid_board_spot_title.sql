-- ============================================================
-- 2026-08-02: 互助板 offer 可自訂商品標題
--
-- 需求：會員 App 現貨專區的商品標題目前一律組自 SKU
--       （`product_name／variant_name`，例「火鍋肉片500g/包／(C)台灣梅花豬」），
--       店家希望能改成給顧客看的說法。上架時可填、發佈後也能改。
--
-- 沿用 spot_price / spot_description 的同一套語意：
--   NULL = 沒改，讀取端 fallback 回 SKU 組出來的標題。
--   商品主檔之後改名，沒改寫過的貼文會自動跟上。
--
-- 變動：
--   1. mutual_aid_board 加 spot_title
--   2. rpc_post_aid_board            10 → 11 參數（上架時填）
--   3. rpc_update_aid_board_listing   5 →  6 參數（發佈後改）
--
-- 基底版本（已 grep supabase/migrations/ 確認各自的最新版）：
--   - rpc_post_aid_board          → 20260802000000_aid_board_spot_price_description.sql
--     （歷史：20260509000000 6 參數 → 20260509000001 8 參數 → 20260802000000 10 參數）
--   - rpc_update_aid_board_listing → 20260802000020_aid_listing_edit_expires_at.sql
--     （歷史：20260802000010 4 參數 → 20260802000020 5 參數）
--   兩支的原有驗證邏輯一字未改，只多接一個參數。
--
-- 為何 DROP 再 CREATE：參數個數變了，CREATE OR REPLACE 會多出 overload，
--   之後具名呼叫撞 "function is not unique"。新參數有 DEFAULT，
--   已部署的舊前端具名呼叫仍解得到，無空窗。
--
-- Rollback：
--   DROP FUNCTION IF EXISTS rpc_post_aid_board(
--     BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID, TEXT, BIGINT, NUMERIC, TEXT, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(
--     BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT);
--   -- 重跑 20260802000000 的 §rpc 段落 與 20260802000020 整支
--   ALTER TABLE mutual_aid_board DROP COLUMN spot_title;
-- ============================================================

ALTER TABLE mutual_aid_board
  ADD COLUMN spot_title TEXT;

COMMENT ON COLUMN mutual_aid_board.spot_title IS
  '上架時自訂的商品標題（純文字）；NULL = 會員端 fallback 回 SKU 組出的 '
  'product_name／variant_name。';

-- ------------------------------------------------------------
-- 1. rpc_post_aid_board：10 → 11 參數
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS rpc_post_aid_board(
  BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID, TEXT, BIGINT, NUMERIC, TEXT);

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
  p_spot_description         TEXT    DEFAULT NULL,
  p_spot_title               TEXT    DEFAULT NULL
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
  -- 自訂價 / 說明 / 標題只對 offer 有意義（request 是求援，不是上架商品）
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
  IF p_spot_title IS NOT NULL AND p_post_type <> 'offer' THEN
    RAISE EXCEPTION 'spot_title is only valid for offer posts';
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
    spot_price, spot_description, spot_title,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, p_offering_store_id, p_sku_id, p_qty_available, p_qty_available,
    p_expires_at, NULLIF(trim(p_note), ''), 'active', p_post_type, p_source_customer_order_id,
    p_spot_price, NULLIF(trim(p_spot_description), ''), NULLIF(trim(p_spot_title), ''),
    p_operator, p_operator
  )
  RETURNING id INTO v_board_id;

  RETURN v_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_post_aid_board(
  BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID, TEXT, BIGINT, NUMERIC, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION rpc_post_aid_board IS
  '發起互助貼文；offer 須帶 source_customer_order_id。'
  '2026-08-02 加 p_spot_price / p_spot_description / p_spot_title'
  '（僅 offer 可用；NULL = 沿用原價 / 商品主檔說明 / SKU 組出的標題）。';

-- ------------------------------------------------------------
-- 2. rpc_update_aid_board_listing：5 → 6 參數
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION public.rpc_update_aid_board_listing(
  p_board_id         BIGINT,
  p_operator         UUID,
  p_spot_price       NUMERIC     DEFAULT NULL,
  p_spot_description TEXT        DEFAULT NULL,
  p_expires_at       TIMESTAMPTZ DEFAULT NULL,
  p_spot_title       TEXT        DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_post_type TEXT;
  v_status    TEXT;
BEGIN
  IF p_spot_price IS NOT NULL AND p_spot_price <= 0 THEN
    RAISE EXCEPTION 'spot_price must be > 0';
  END IF;
  -- 到期時間可以往後延，也可以縮短，但不能設到過去
  -- （設到過去等於立刻下架，那是「結束此貼」該做的事，語意分開）
  IF p_expires_at IS NOT NULL AND p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'expires_at must be in the future';
  END IF;

  SELECT post_type, status INTO v_post_type, v_status
    FROM mutual_aid_board WHERE id = p_board_id
    FOR UPDATE;
  IF v_post_type IS NULL THEN
    RAISE EXCEPTION 'board post % not found', p_board_id;
  END IF;
  IF v_post_type <> 'offer' THEN
    RAISE EXCEPTION 'only offer posts have price/description';
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'post is % — only active posts can be edited', v_status;
  END IF;

  UPDATE mutual_aid_board
     SET spot_price       = p_spot_price,
         spot_description = NULLIF(trim(p_spot_description), ''),
         spot_title       = NULLIF(trim(p_spot_title), ''),
         -- NULL = 不動（expires_at 是 NOT NULL，沒有「清除」的語意）
         expires_at       = COALESCE(p_expires_at, expires_at),
         updated_by       = p_operator
   WHERE id = p_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_aid_board_listing IS
  '互助板 offer 貼文發佈後編輯釋出單價 / 商品說明 / 商品標題 / 到期時間。'
  'spot_price、spot_description、spot_title 的 NULL = 清除自訂值'
  '（回沿用原價 / 商品主檔原文 / SKU 組出的標題）；'
  'expires_at 的 NULL = 不動（該欄 NOT NULL），且不得設到過去。僅 active 的 offer 可改。';

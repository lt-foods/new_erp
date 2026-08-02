-- ============================================================
-- 2026-08-02: 手動現貨可以只給本店會員看
--
-- 需求：手動上架的現貨要有一個開關控制「其他分店的會員看不看得到」。
--       預設看得到（維持現況）；關掉之後只有釋出店自己的會員看得到。
--
-- 和既有的「跨店金額隱藏」是兩件事，疊在一起是三段式：
--   開關 ON （預設）→ 別店會員看得到這張卡，但金額仍然隱藏（既有行為）
--   開關 OFF        → 別店會員的列表與詳情都查不到這筆，等於不存在
--
-- 變動：
--   1. mutual_aid_board 加 spot_visible_to_other_stores BOOLEAN NOT NULL DEFAULT TRUE
--   2. rpc_post_manual_spot            11 → 12 參數
--   3. rpc_update_aid_board_listing     9 → 10 參數
--
-- 基底版本（已 grep supabase/migrations/ 確認是最新版）：
--   - rpc_post_manual_spot         → 20260802000040_manual_spot_listing.sql（唯一版本）
--   - rpc_update_aid_board_listing → 20260802000040_manual_spot_listing.sql
--     （歷史：…000010 4 → …000020 5 → …000030 6 → …000040 9 參數）
--   兩支的原有驗證邏輯一字未改，只多接一個參數。
--   rpc_post_aid_board 不動：從訂單釋出的貼文一律走預設值 TRUE。
--
-- ⚠ update 的 p_visible_to_other_stores NULL 語意 = **不動**（同 p_expires_at /
--   p_qty_available），不是「關掉」。欄位是 NOT NULL，沒有「清除」的概念；
--   而且舊前端送 9 個具名參數時不該把可見性悄悄改掉。
--
-- ⚠ 過濾要在**後端**做（liff-api 的 list / detail 都要），不能只藏 UI。
--   detail 沒擋的話，知道 board id 就能直接開出別店設為不公開的商品。
--
-- 為何 DROP 再 CREATE：參數個數變了，CREATE OR REPLACE 會多出 overload，
--   之後具名呼叫撞 "function is not unique"。新參數有 DEFAULT，
--   已部署的舊前端具名呼叫仍解得到，無空窗。
--
-- Rollback：
--   DROP FUNCTION IF EXISTS public.rpc_post_manual_spot(
--     BIGINT, BIGINT, TEXT, NUMERIC, TIMESTAMPTZ, NUMERIC, TEXT, TEXT, JSONB, TEXT, UUID, BOOLEAN);
--   DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(
--     BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, JSONB, TEXT, NUMERIC, BOOLEAN);
--   -- 重跑 20260802000040 的 §2、§3 段落
--   ALTER TABLE mutual_aid_board DROP COLUMN spot_visible_to_other_stores;
-- ============================================================

ALTER TABLE mutual_aid_board
  ADD COLUMN spot_visible_to_other_stores BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN mutual_aid_board.spot_visible_to_other_stores IS
  'FALSE = 這筆現貨只有 offering_store_id 那間店的會員看得到（liff-api 的 '
  'list / detail 都會濾掉）。TRUE（預設）= 所有會員都看得到，但跨店的金額'
  '照舊隱藏。只對 offer 有意義。';

-- 只給本店看的那些，查詢一定會帶 offering_store_id，走這個 partial index
CREATE INDEX idx_aid_board_own_store_only
  ON mutual_aid_board (offering_store_id)
  WHERE spot_visible_to_other_stores = FALSE;

-- ------------------------------------------------------------
-- 1. rpc_post_manual_spot：11 → 12 參數
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_post_manual_spot(
  BIGINT, BIGINT, TEXT, NUMERIC, TIMESTAMPTZ, NUMERIC, TEXT, TEXT, JSONB, TEXT, UUID);

CREATE OR REPLACE FUNCTION public.rpc_post_manual_spot(
  p_offering_store_id BIGINT,
  p_sku_id            BIGINT,
  p_spot_title        TEXT,
  p_qty_available     NUMERIC,
  p_expires_at        TIMESTAMPTZ,
  p_spot_price        NUMERIC     DEFAULT NULL,
  p_spot_description  TEXT        DEFAULT NULL,
  p_spot_unit         TEXT        DEFAULT NULL,
  p_spot_images       JSONB       DEFAULT NULL,
  p_note              TEXT        DEFAULT NULL,
  p_operator          UUID        DEFAULT NULL,
  p_visible_to_other_stores BOOLEAN DEFAULT TRUE
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant_id UUID;
  v_title     TEXT := NULLIF(trim(p_spot_title), '');
  v_images    JSONB;
  v_board_id  BIGINT;
BEGIN
  IF p_qty_available IS NULL OR p_qty_available <= 0 THEN
    RAISE EXCEPTION 'qty_available must be > 0';
  END IF;
  IF p_expires_at IS NULL OR p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'expires_at must be in the future';
  END IF;
  IF p_spot_price IS NOT NULL AND p_spot_price <= 0 THEN
    RAISE EXCEPTION 'spot_price must be > 0';
  END IF;
  -- 沒選 SKU 就一定要有標題，否則會員端沒東西可顯示（也會撞 CHECK）
  IF p_sku_id IS NULL AND v_title IS NULL THEN
    RAISE EXCEPTION 'manual spot without sku_id requires spot_title';
  END IF;

  SELECT tenant_id INTO v_tenant_id FROM stores WHERE id = p_offering_store_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_offering_store_id;
  END IF;

  IF p_sku_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM skus WHERE id = p_sku_id) THEN
    RAISE EXCEPTION 'sku % not found', p_sku_id;
  END IF;

  -- 圖片必須是字串陣列（storage 相對路徑）；空陣列存 NULL = 沿用主檔圖
  IF p_spot_images IS NOT NULL THEN
    IF jsonb_typeof(p_spot_images) <> 'array' THEN
      RAISE EXCEPTION 'spot_images must be a JSON array of storage paths';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_spot_images) e
       WHERE jsonb_typeof(e) <> 'string'
    ) THEN
      RAISE EXCEPTION 'spot_images must contain only strings';
    END IF;
    v_images := NULLIF(p_spot_images, '[]'::jsonb);
  END IF;

  INSERT INTO mutual_aid_board (
    tenant_id, offering_store_id, sku_id, qty_available, qty_remaining,
    expires_at, note, status, post_type, source_customer_order_id,
    spot_price, spot_description, spot_title, spot_unit, spot_images,
    spot_visible_to_other_stores,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, p_offering_store_id, p_sku_id, p_qty_available, p_qty_available,
    p_expires_at, NULLIF(trim(p_note), ''), 'active', 'offer', NULL,
    p_spot_price, NULLIF(trim(p_spot_description), ''), v_title,
    NULLIF(trim(p_spot_unit), ''), v_images,
    COALESCE(p_visible_to_other_stores, TRUE),
    p_operator, p_operator
  )
  RETURNING id INTO v_board_id;

  RETURN v_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_post_manual_spot(
  BIGINT, BIGINT, TEXT, NUMERIC, TIMESTAMPTZ, NUMERIC, TEXT, TEXT, JSONB, TEXT, UUID, BOOLEAN) TO authenticated;

COMMENT ON FUNCTION public.rpc_post_manual_spot IS
  '手動上架現貨：post_type=offer 但沒有來源訂單。p_sku_id 可為 NULL（純手打，'
  '此時 p_spot_title 必填）。這種貼文不能被別店認領（沒有訂單可轉移）。'
  'p_visible_to_other_stores=FALSE 則只有釋出店的會員看得到。';

-- ------------------------------------------------------------
-- 2. rpc_update_aid_board_listing：9 → 10 參數
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, JSONB, TEXT, NUMERIC);

CREATE OR REPLACE FUNCTION public.rpc_update_aid_board_listing(
  p_board_id         BIGINT,
  p_operator         UUID,
  p_spot_price       NUMERIC     DEFAULT NULL,
  p_spot_description TEXT        DEFAULT NULL,
  p_expires_at       TIMESTAMPTZ DEFAULT NULL,
  p_spot_title       TEXT        DEFAULT NULL,
  p_spot_images      JSONB       DEFAULT NULL,
  p_spot_unit        TEXT        DEFAULT NULL,
  p_qty_available    NUMERIC     DEFAULT NULL,
  p_visible_to_other_stores BOOLEAN DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_post_type TEXT;
  v_status    TEXT;
  v_sku_id    BIGINT;
  v_order_id  BIGINT;
  v_title     TEXT := NULLIF(trim(p_spot_title), '');
  v_images    JSONB;
BEGIN
  IF p_spot_price IS NOT NULL AND p_spot_price <= 0 THEN
    RAISE EXCEPTION 'spot_price must be > 0';
  END IF;
  -- 到期時間可以往後延，也可以縮短，但不能設到過去
  -- （設到過去等於立刻下架，那是「結束此貼」該做的事，語意分開）
  IF p_expires_at IS NOT NULL AND p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'expires_at must be in the future';
  END IF;
  IF p_qty_available IS NOT NULL AND p_qty_available <= 0 THEN
    RAISE EXCEPTION 'qty_available must be > 0';
  END IF;
  IF p_spot_images IS NOT NULL THEN
    IF jsonb_typeof(p_spot_images) <> 'array' THEN
      RAISE EXCEPTION 'spot_images must be a JSON array of storage paths';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_spot_images) e
       WHERE jsonb_typeof(e) <> 'string'
    ) THEN
      RAISE EXCEPTION 'spot_images must contain only strings';
    END IF;
    v_images := NULLIF(p_spot_images, '[]'::jsonb);
  END IF;

  SELECT post_type, status, sku_id, source_customer_order_id
    INTO v_post_type, v_status, v_sku_id, v_order_id
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
  -- 手打商品沒有 SKU 可以 fallback，標題不能清空（先擋，別讓它撞 CHECK）
  IF v_sku_id IS NULL AND v_title IS NULL THEN
    RAISE EXCEPTION 'this listing has no sku — spot_title cannot be cleared';
  END IF;
  -- 數量只有手動現貨能改：從訂單釋出的貼文，qty 和認領扣量的帳綁在一起，
  -- 直接覆寫會讓已認領的量對不上（要調整請結束此貼重發）
  IF p_qty_available IS NOT NULL AND v_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'qty of an order-sourced listing cannot be edited';
  END IF;

  UPDATE mutual_aid_board
     SET spot_price       = p_spot_price,
         spot_description = NULLIF(trim(p_spot_description), ''),
         spot_title       = v_title,
         spot_unit        = NULLIF(trim(p_spot_unit), ''),
         spot_images      = v_images,
         -- NULL = 不動（expires_at 是 NOT NULL，沒有「清除」的語意）
         expires_at       = COALESCE(p_expires_at, expires_at),
         -- 手動現貨沒有認領扣量，qty_available / qty_remaining 一起覆寫
         qty_available    = COALESCE(p_qty_available, qty_available),
         qty_remaining    = COALESCE(p_qty_available, qty_remaining),
         -- NULL = 不動（欄位 NOT NULL；舊前端沒送就別動人家的可見性）
         spot_visible_to_other_stores =
           COALESCE(p_visible_to_other_stores, spot_visible_to_other_stores),
         updated_by       = p_operator
   WHERE id = p_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, JSONB, TEXT, NUMERIC, BOOLEAN) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_aid_board_listing IS
  '互助板 offer 貼文發佈後編輯釋出單價 / 商品說明 / 商品標題 / 單位 / 圖片 / '
  '到期時間 / 數量 / 跨店可見性。spot_price、spot_description、spot_title、'
  'spot_unit、spot_images 的 NULL = 清除自訂值（回沿用原價 / 主檔原文 / '
  'SKU 標題 / base_unit / 主檔圖）；expires_at、qty_available、'
  'visible_to_other_stores 的 NULL = 不動。qty_available 只有手動現貨'
  '（無來源訂單）能改。僅 active 的 offer 可改。';

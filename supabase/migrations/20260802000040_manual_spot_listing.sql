-- ============================================================
-- 2026-08-02: 手動新增現貨（不需要來源訂單）
--
-- 需求：現貨專區目前只能從「客人棄單的 ready 訂單」釋出。店家想直接把
--       店裡現有的東西丟上架 —— 可以從商品庫選 SKU，也可以完全手打
--       （店裡自製、臨時進的貨，主檔根本沒有）。金額自己填、圖片自己傳。
--
-- 資料模型：手動現貨就是 post_type='offer' 且 source_customer_order_id IS NULL
--   的 mutual_aid_board 列。不另立 is_manual 旗標 —— 「沒有來源訂單」本身
--   就是唯一且不會不同步的判準。
--
-- ⚠ 手動現貨**不能被別店認領**：認領走 rpc_transfer_order_partial，需要一張
--   真的訂單。admin 端會對 source_customer_order_id IS NULL 的貼文藏掉
--   「我要認領」。它是純粹的會員端商品，不是店對店互助標的。
--
-- 變動：
--   1. sku_id 放寬為 nullable（手打商品沒有 SKU）
--   2. 放寬 aid_board_source_consistency：offer 不再強制要有 source_order
--   3. 加 spot_images（JSONB，同 products.images 格式）、spot_unit
--   4. 三條 CHECK 守住放寬後的空間
--   5. 新增 rpc_post_manual_spot
--   6. rpc_update_aid_board_listing 6 → 9 參數（圖片 / 單位 / 數量也能改）
--
-- 基底版本（已 grep supabase/migrations/ 確認是最新版）：
--   - rpc_update_aid_board_listing → 20260802000030_aid_board_spot_title.sql
--     （歷史：20260802000010 4 → 20260802000020 5 → 20260802000030 6 參數）
--     原有的 offer/active 檢查與各參數 NULL 語意一字未改，只多接三個。
--   - rpc_post_aid_board **完全不動**：它的核心保證是「offer 必須來自訂單」，
--     那是認領/轉移流程安全的前提，不在這裡開洞。手動現貨走新的入口。
--
-- Rollback：
--   DROP FUNCTION IF EXISTS public.rpc_post_manual_spot(
--     BIGINT, BIGINT, TEXT, NUMERIC, TIMESTAMPTZ, NUMERIC, TEXT, TEXT, JSONB, TEXT, UUID);
--   DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(
--     BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, JSONB, TEXT, NUMERIC);
--   -- 重跑 20260802000030 的 §2 段落
--   ALTER TABLE mutual_aid_board
--     DROP CONSTRAINT chk_aid_board_request_needs_sku,
--     DROP CONSTRAINT chk_aid_board_displayable,
--     DROP CONSTRAINT aid_board_source_consistency,
--     DROP COLUMN spot_images,
--     DROP COLUMN spot_unit;
--   -- 復原 20260509000001 的原版（offer 必須有 source_order）：
--   DELETE FROM mutual_aid_board
--    WHERE post_type = 'offer' AND source_customer_order_id IS NULL;
--   ALTER TABLE mutual_aid_board ADD CONSTRAINT aid_board_source_consistency CHECK (
--     (post_type = 'offer' AND source_customer_order_id IS NOT NULL)
--     OR (post_type = 'request' AND source_customer_order_id IS NULL));
--   -- ⚠ 復原 sku_id NOT NULL 前要先清掉手打的列，否則 ALTER 會失敗：
--   --   DELETE FROM mutual_aid_board WHERE sku_id IS NULL;
--   ALTER TABLE mutual_aid_board ALTER COLUMN sku_id SET NOT NULL;
-- ============================================================

-- ------------------------------------------------------------
-- 1. 欄位
-- ------------------------------------------------------------
ALTER TABLE mutual_aid_board
  ALTER COLUMN sku_id DROP NOT NULL;

ALTER TABLE mutual_aid_board
  ADD COLUMN spot_images JSONB,
  ADD COLUMN spot_unit   TEXT;

COMMENT ON COLUMN mutual_aid_board.sku_id IS
  '對應商品 SKU。手動現貨可為 NULL（店家直接手打的商品，主檔沒有）；'
  'request 貼文一定要有（認領要靠它轉移訂單）。';

COMMENT ON COLUMN mutual_aid_board.spot_images IS
  '這則貼文專用的圖片（JSONB 字串陣列，storage products bucket 的相對路徑，'
  '格式同 products.images）；NULL = 會員端 fallback 回商品主檔的圖。';

COMMENT ON COLUMN mutual_aid_board.spot_unit IS
  '數量單位（例「包」「份」）；NULL = 會員端 fallback 回 skus.base_unit。';

-- 20260509000001 訂的 aid_board_source_consistency 是
--   「offer 一定有 source_order、request 一定沒有」。
-- 手動現貨正是「offer 但沒有 source_order」，所以要放寬成只管 request 那半邊。
-- offer 的 source_order 改由 rpc_post_aid_board 自己 RAISE 把關（那支沒動），
-- 走它的訂單釋出路徑一樣進不來沒有訂單的列。
ALTER TABLE mutual_aid_board
  DROP CONSTRAINT aid_board_source_consistency;

ALTER TABLE mutual_aid_board
  ADD CONSTRAINT aid_board_source_consistency
  CHECK (post_type <> 'request' OR source_customer_order_id IS NULL);

-- request 一定要有 SKU：它會被別店「回應求助」轉單，沒 SKU 沒得轉
ALTER TABLE mutual_aid_board
  ADD CONSTRAINT chk_aid_board_request_needs_sku
  CHECK (post_type <> 'request' OR sku_id IS NOT NULL);

-- 會員端一定要有東西可顯示：不是有 SKU（組得出標題）就是有自訂標題
ALTER TABLE mutual_aid_board
  ADD CONSTRAINT chk_aid_board_displayable
  CHECK (sku_id IS NOT NULL OR spot_title IS NOT NULL);

-- ------------------------------------------------------------
-- 2. rpc_post_manual_spot — 手動上架（新函式，無歷史版本）
-- ------------------------------------------------------------
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
  p_operator          UUID        DEFAULT NULL
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
    created_by, updated_by
  ) VALUES (
    v_tenant_id, p_offering_store_id, p_sku_id, p_qty_available, p_qty_available,
    p_expires_at, NULLIF(trim(p_note), ''), 'active', 'offer', NULL,
    p_spot_price, NULLIF(trim(p_spot_description), ''), v_title,
    NULLIF(trim(p_spot_unit), ''), v_images,
    p_operator, p_operator
  )
  RETURNING id INTO v_board_id;

  RETURN v_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_post_manual_spot(
  BIGINT, BIGINT, TEXT, NUMERIC, TIMESTAMPTZ, NUMERIC, TEXT, TEXT, JSONB, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_post_manual_spot IS
  '手動上架現貨：post_type=offer 但沒有來源訂單。p_sku_id 可為 NULL（純手打，'
  '此時 p_spot_title 必填）。這種貼文不能被別店認領（沒有訂單可轉移）。';

-- ------------------------------------------------------------
-- 3. rpc_update_aid_board_listing：6 → 9 參數
--    加 p_spot_images / p_spot_unit / p_qty_available
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT);

CREATE OR REPLACE FUNCTION public.rpc_update_aid_board_listing(
  p_board_id         BIGINT,
  p_operator         UUID,
  p_spot_price       NUMERIC     DEFAULT NULL,
  p_spot_description TEXT        DEFAULT NULL,
  p_expires_at       TIMESTAMPTZ DEFAULT NULL,
  p_spot_title       TEXT        DEFAULT NULL,
  p_spot_images      JSONB       DEFAULT NULL,
  p_spot_unit        TEXT        DEFAULT NULL,
  p_qty_available    NUMERIC     DEFAULT NULL
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
         updated_by       = p_operator
   WHERE id = p_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, JSONB, TEXT, NUMERIC) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_aid_board_listing IS
  '互助板 offer 貼文發佈後編輯釋出單價 / 商品說明 / 商品標題 / 單位 / 圖片 / '
  '到期時間 / 數量。spot_price、spot_description、spot_title、spot_unit、'
  'spot_images 的 NULL = 清除自訂值（回沿用原價 / 主檔原文 / SKU 標題 / '
  'base_unit / 主檔圖）；expires_at 與 qty_available 的 NULL = 不動。'
  'qty_available 只有手動現貨（無來源訂單）能改。僅 active 的 offer 可改。';

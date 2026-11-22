-- ============================================================================
-- 會員商城：原價劃掉＋優惠價、優惠標籤、商品介紹影片
--
-- 來源：2026-11-22 分店建議（各分店商品互相流通群）——
--   「有些客人不加群在商場逛，他們或許不知道這是特別優惠的價格」
--   1. 用原價劃掉、寫優惠價
--   2. 卡片上標「獨家優惠」之類的字樣
--   3. 商品頁圖片上有個小框，點了看包子媽的影片介紹
--
-- 資料放哪（老闆 2026-11-22 選的）
--   skus.original_price            原價，商品頁每個規格選填。開團不用重填，讀的是規格現值。
--                                  線上「零售價＝團購價」（229 個開團中的團只有 sentinel 那幾團不同），
--                                  所以沒有現成的「原價」可以拿來劃，一定要另外一欄。
--   group_buy_campaigns.promo_label 優惠標籤，每團自己打，最多 6 個字，留空不顯示。
--   products.intro_video_url       介紹影片連結（IG Reel / TikTok / YouTube），貼連結、不存檔案。
--
-- 寫入一律走新的小 RPC，**不動** rpc_upsert_sku / rpc_upsert_product / rpc_upsert_campaign：
--   那三支是整欄覆寫、參數固定，加參數等於重寫整支（rpc_upsert_campaign 被改過十幾次）。
--   比照 rpc_set_campaign_line_note（20260927010000）另開開關型 RPC。
--   守衛比照既有同類：規格／商品＝同 tenant（同 rpc_upsert_sku / rpc_set_retail_price）；
--   開團＝同 tenant ＋ 店家自開團只能改自己店的（同 rpc_set_campaign_line_note）。
--
-- 顯示規則在讀取端（liff-api）：原價要「大於這團的單價」才回，贈品（單價 0）不回。
-- 這裡只擋明顯錯的值（原價 ≤ 0、標籤超過 6 字、影片不是 https）。
--
-- 純新增（三個可為 NULL 的欄位、三支新函式），不改任何既有物件。
-- 上線順序不拘：前端與 liff-api 讀這三欄都是「另外一句、失敗就當沒有」，
--   本檔沒套時畫面跟現在一樣；本檔先套、前端沒上，欄位全是 NULL 也沒有任何效果。
-- 回退：DROP 三支函式；欄位留著無害（要拿掉就 ALTER TABLE … DROP COLUMN）。
-- ============================================================================

ALTER TABLE public.skus
  ADD COLUMN IF NOT EXISTS original_price NUMERIC(12, 2);
ALTER TABLE public.skus
  DROP CONSTRAINT IF EXISTS skus_original_price_positive;
ALTER TABLE public.skus
  ADD CONSTRAINT skus_original_price_positive
  CHECK (original_price IS NULL OR original_price > 0);
COMMENT ON COLUMN public.skus.original_price IS
  '原價（選填）。會員商城在它大於該團單價時畫刪除線；NULL = 不顯示。20261122000000';

ALTER TABLE public.group_buy_campaigns
  ADD COLUMN IF NOT EXISTS promo_label TEXT;
ALTER TABLE public.group_buy_campaigns
  DROP CONSTRAINT IF EXISTS group_buy_campaigns_promo_label_len;
ALTER TABLE public.group_buy_campaigns
  ADD CONSTRAINT group_buy_campaigns_promo_label_len
  CHECK (promo_label IS NULL OR char_length(promo_label) BETWEEN 1 AND 6);
COMMENT ON COLUMN public.group_buy_campaigns.promo_label IS
  '優惠標籤（例：獨家優惠），最多 6 字，會員商城卡片與商品頁顯示；NULL = 不顯示。20261122000000';

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS intro_video_url TEXT;
ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_intro_video_url_https;
ALTER TABLE public.products
  ADD CONSTRAINT products_intro_video_url_https
  CHECK (intro_video_url IS NULL
         OR (intro_video_url ~ '^https://[^[:space:]]+$' AND char_length(intro_video_url) <= 500));
COMMENT ON COLUMN public.products.intro_video_url IS
  '介紹影片連結（IG Reel / TikTok / YouTube）。會員商品頁圖片上的「影片介紹」小框；NULL = 不顯示。20261122000000';

-- ----------------------------------------------------------------------------
-- 規格的原價。p_price NULL（或 ≤ 0）= 清掉。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_sku_original_price(p_sku_id BIGINT, p_price NUMERIC)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_price  NUMERIC := CASE WHEN p_price IS NULL OR p_price <= 0 THEN NULL ELSE ROUND(p_price, 2) END;
BEGIN
  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'sku % not in tenant', p_sku_id; END IF;

  UPDATE skus
     SET original_price = v_price
   WHERE id = p_sku_id AND tenant_id = v_tenant
     AND original_price IS DISTINCT FROM v_price;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_set_sku_original_price(BIGINT, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_sku_original_price(BIGINT, NUMERIC) TO authenticated;

-- ----------------------------------------------------------------------------
-- 開團的優惠標籤。空白 = 清掉；超過 6 個字擋下（不要默默截字，截出來的字可能很怪）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_campaign_promo_label(p_id BIGINT, p_label TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_owner  BIGINT;
  v_status TEXT;
  v_label  TEXT := NULLIF(btrim(COALESCE(p_label, '')), '');
BEGIN
  SELECT owner_store_id, status INTO v_owner, v_status
    FROM group_buy_campaigns WHERE id = p_id AND tenant_id = v_tenant;
  IF v_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;
  -- 同 rpc_upsert_campaign / rpc_set_campaign_line_note：自開團只能改自己店的
  IF v_owner IS NOT NULL THEN PERFORM public._assert_own_store(v_owner); END IF;

  IF v_label IS NOT NULL AND char_length(v_label) > 6 THEN
    RAISE EXCEPTION '優惠標籤最多 6 個字（現在 % 個字）', char_length(v_label);
  END IF;

  UPDATE group_buy_campaigns
     SET promo_label = v_label
   WHERE id = p_id AND tenant_id = v_tenant
     AND promo_label IS DISTINCT FROM v_label;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_set_campaign_promo_label(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_campaign_promo_label(BIGINT, TEXT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 商品的介紹影片連結。空白 = 清掉。只收 https；哪些網站能直接嵌入播放由前端判斷
-- （嵌不了的，客人點了會改成開那個連結）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_product_intro_video(p_product_id BIGINT, p_url TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_url    TEXT := NULLIF(btrim(COALESCE(p_url, '')), '');
BEGIN
  PERFORM 1 FROM products WHERE id = p_product_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'product % not in tenant', p_product_id; END IF;

  IF v_url IS NOT NULL AND (v_url !~ '^https://[^[:space:]]+$' OR char_length(v_url) > 500) THEN
    RAISE EXCEPTION '影片連結要是 https:// 開頭的網址（不能有空白，500 字以內）';
  END IF;

  UPDATE products
     SET intro_video_url = v_url
   WHERE id = p_product_id AND tenant_id = v_tenant
     AND intro_video_url IS DISTINCT FROM v_url;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_set_product_intro_video(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_product_intro_video(BIGINT, TEXT) TO authenticated;

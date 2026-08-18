-- ============================================================
-- 2026-08-18: rpc_schedule_candidate 加 p_brand_id（B-2）
--
-- 以哪個版本為基底：
--   20260630000010_schedule_candidate_no_campaign.sql
--   （rpc_schedule_candidate 的最新定義，共 4 版：
--     20260514000002 / 20260514000003 / 20260514000010 / 20260630000010）
--   ⚠️ 20260514000002 的檔頭到現在還寫著「會建 campaign」，那是舊版、已過期，不要照它改。
--
-- rollback 指回：20260630000010_schedule_candidate_no_campaign.sql
--   （還原時：DROP 本檔的 4 參數版，重跑 20260630000010 的 3 參數版定義與 GRANT。）
--
-- 變更「只有兩處」，其餘（權限檢查、sku 建立、retail price、候選標記、
-- 回傳 JSONB 形狀）逐字保留：
--   1. 新增參數 p_brand_id BIGINT DEFAULT NULL
--   2. rpc_upsert_product 的 p_brand_id := NULL  →  p_brand_id := p_brand_id
--
-- ⛔ 刻意「沒有」恢復建 campaign 那段：
--   當初 PR #374（2026-05-29）拿掉它的原因至今不明（commit 與 PR 描述都只寫
--   「改成什麼」、沒寫「為什麼」）。原因不明就不要動它。
--   一鍵開團改走本次新增的 rpc_open_campaign_from_candidate（20260818000130），
--   那是「老闆自己按的第二顆鈕」，不是自動行為。
--
-- ⚠️⚠️ 為什麼一定要先 DROP 舊的 3 參數簽章：
--   CREATE OR REPLACE 只會覆蓋「完全相同簽章」的函式。加了一個有 DEFAULT 的參數
--   之後，(BIGINT, DATE, TEXT) 與 (BIGINT, DATE, TEXT, BIGINT) 是兩支不同的函式，
--   舊呼叫端 rpc_schedule_candidate(a, b, c) 會變成
--     ERROR: function rpc_schedule_candidate(bigint, date, text) is not unique
--   （2026-08-18 用 pglite / PostgreSQL 18 實測過這個錯誤訊息）
--   → 前端兩個呼叫點（community-candidates/page.tsx:200、:275）會當場全掛。
--   同樣手法的前例：20260701040000 與 20260703000010 都先 DROP 再 CREATE。
--
-- ℹ️ p_brand_id 的安全性由既有機制擋住，本檔不另外驗：
--   rpc_upsert_product 最新版（20260701050000:88-90）本來就有
--     IF p_brand_id IS NOT NULL THEN
--       PERFORM 1 FROM brands WHERE id = p_brand_id AND tenant_id = v_tenant;
--       IF NOT FOUND THEN RAISE EXCEPTION 'brand % not in tenant', p_brand_id; END IF;
--   → 傳別的租戶的 brand id 會被擋下。
--
-- ℹ️ 帶了品牌之後 skus.brand_id 會不會跟著對？會。
--   rpc_upsert_sku（20260424120000）INSERT 前會
--     SELECT id, name, brand_id, category_id INTO v_prod FROM products WHERE id = p_product_id
--   而本函式是「先 upsert_product、再 upsert_sku」，所以 sku 拿到的是剛寫進去的品牌。
--
-- Scope：只改 rpc_schedule_candidate，不動表、不動其他 RPC。
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_schedule_candidate(BIGINT, DATE, TEXT);

CREATE OR REPLACE FUNCTION public.rpc_schedule_candidate(
  p_candidate_id    BIGINT,
  p_scheduled_date  DATE,
  p_product_name    TEXT,
  p_brand_id        BIGINT DEFAULT NULL   -- ★ 新增：不傳＝維持原本行為（品牌留空）
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_user           UUID := auth.uid();
  v_role           TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_cand           RECORD;
  v_product_code   TEXT;
  v_product_id     BIGINT;
  v_sku_code       TEXT;
  v_sku_id         BIGINT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot schedule candidate', v_role;
  END IF;

  IF TRIM(COALESCE(p_product_name, '')) = '' THEN
    RAISE EXCEPTION 'product_name must not be blank';
  END IF;
  IF p_scheduled_date IS NULL THEN
    RAISE EXCEPTION 'scheduled_date must not be null';
  END IF;

  SELECT id, owner_action, adopted_product_id, adopted_sale_price, raw_text
    INTO v_cand
    FROM community_product_candidates
   WHERE id = p_candidate_id AND tenant_id = v_tenant
     FOR UPDATE;

  IF v_cand.id IS NULL THEN
    RAISE EXCEPTION 'candidate % not found or cross-tenant', p_candidate_id;
  END IF;

  IF v_cand.adopted_product_id IS NOT NULL THEN
    -- 已有對應商品：沿用既有 product / 第一個 sku，不重建（開團另由商品編輯頁手動建立）
    -- ⚠️ 這條路徑刻意不覆寫既有商品的品牌 —— 老闆已經維護過的商品不該被候選池的來源蓋掉。
    v_product_id := v_cand.adopted_product_id;

    SELECT product_code INTO v_product_code
      FROM products
     WHERE id = v_product_id AND tenant_id = v_tenant;

    SELECT id INTO v_sku_id
      FROM skus
     WHERE product_id = v_product_id AND tenant_id = v_tenant
     ORDER BY id
     LIMIT 1;
  ELSE
    v_product_code := public.rpc_next_product_code();
    v_product_id := public.rpc_upsert_product(
      p_id := NULL, p_product_code := v_product_code,
      p_name := TRIM(p_product_name), p_short_name := NULL,
      p_brand_id := p_brand_id, p_category_id := NULL,   -- ★ 原本寫死 NULL，改成帶入
      p_description := v_cand.raw_text, p_status := 'draft',
      p_reason := 'schedule candidate #' || p_candidate_id::TEXT
    );

    v_sku_code := public.rpc_next_sku_code(v_product_id);
    v_sku_id := public.rpc_upsert_sku(
      p_id := NULL, p_product_id := v_product_id, p_sku_code := v_sku_code,
      p_variant_name := NULL, p_spec := '{}'::jsonb,
      p_base_unit := NULL, p_weight_g := NULL, p_tax_rate := NULL,
      p_status := 'draft',
      p_reason := 'schedule candidate #' || p_candidate_id::TEXT
    );

    IF v_cand.adopted_sale_price IS NOT NULL THEN
      PERFORM public.rpc_set_retail_price(
        v_sku_id, v_cand.adopted_sale_price, NOW(),
        'schedule candidate #' || p_candidate_id::TEXT
      );
    END IF;
  END IF;

  -- NOTE: 不再建立 group_buy_campaigns / campaign_items。
  --       開團改由商品編輯頁「建立新開團」按鈕 (rpc_create_campaign_from_product) 觸發。

  UPDATE community_product_candidates
     SET adopted_product_id = v_product_id, owner_action = 'scheduled',
         scheduled_open_at  = p_scheduled_date,
         scheduled_by = v_user, scheduled_at = NOW(),
         updated_at = NOW(), updated_by = v_user
   WHERE id = p_candidate_id AND tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'product_id',         v_product_id,
    'product_code',       v_product_code,
    'sku_id',             v_sku_id,
    'campaign_id',        NULL,
    'campaign_no',        NULL,
    'already_scheduled',  FALSE
  );
END;
$$;

-- DROP 會把舊簽章的授權一起帶走，這裡重新明確授權（收斂到 authenticated）
REVOKE ALL ON FUNCTION public.rpc_schedule_candidate(BIGINT, DATE, TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_schedule_candidate(BIGINT, DATE, TEXT, BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_schedule_candidate(BIGINT, DATE, TEXT, BIGINT) IS
  '排程候選商品：建 draft product + sku（+ retail price）、標記候選 scheduled。'
  '不建開團。p_brand_id 不傳（DEFAULT NULL）＝與 20260630000010 行為完全相同；'
  '傳入時會寫進新建商品的 brand_id（沿用既有商品那條路徑不覆寫品牌）。';

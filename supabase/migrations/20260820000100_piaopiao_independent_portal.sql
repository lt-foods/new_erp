-- 漂漂館獨立入口：外觀/上架入口分開，但訂單、取貨、帳務仍共用既有系統。
-- 不沿用手機快速開團：那條是 fast/limited/food_train，且會顯示在主商城。

ALTER TABLE public.group_buy_campaigns
  ADD COLUMN IF NOT EXISTS sales_channel TEXT NOT NULL DEFAULT 'main'
  CHECK (sales_channel IN ('main', 'piaopiao'));

COMMENT ON COLUMN public.group_buy_campaigns.sales_channel IS
  '顧客看到的店面：main=既有商城；piaopiao=漂漂館專區。不是 close_type，不能拿一般團代替。';

CREATE INDEX IF NOT EXISTS idx_campaigns_piaopiao_shop
  ON public.group_buy_campaigns (tenant_id, status, end_at)
  WHERE sales_channel = 'piaopiao' AND is_for_shop IS TRUE;

CREATE TABLE IF NOT EXISTS public.piaopiao_publishers (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  line_user_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  lane TEXT NOT NULL CHECK (lane IN ('tong', 'chao')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_by UUID,
  updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, line_user_id)
);

COMMENT ON TABLE public.piaopiao_publishers IS
  '漂漂館外部上架員的 LINE 身分白名單；不是 ERP 員工帳號。';

CREATE TABLE IF NOT EXISTS public.piaopiao_publisher_requests (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  line_user_id TEXT NOT NULL,
  display_name TEXT,
  picture_url TEXT,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at TIMESTAMPTZ,
  reviewed_by UUID,
  UNIQUE (tenant_id, line_user_id)
);

CREATE TABLE IF NOT EXISTS public.piaopiao_publish_batches (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  publisher_id BIGINT NOT NULL REFERENCES public.piaopiao_publishers(id),
  request_id UUID NOT NULL,
  end_at TIMESTAMPTZ NOT NULL,
  pickup_deadline DATE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, publisher_id, request_id)
);

CREATE TABLE IF NOT EXISTS public.piaopiao_batch_campaigns (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  batch_id BIGINT NOT NULL REFERENCES public.piaopiao_publish_batches(id) ON DELETE CASCADE,
  campaign_id BIGINT NOT NULL REFERENCES public.group_buy_campaigns(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (campaign_id)
);

COMMENT ON TABLE public.piaopiao_batch_campaigns IS
  '漂漂館一次送出的批次與每個商品團的對照；供防連點重複建團使用。分享由上架員自行選擇 LINE 群組。';

-- 外部上架員與批次對照一律只能經過受控 RPC／Edge Function 進出。
-- 不開任何直接讀寫政策，避免登入會員或外部上架員看到彼此的 LINE 身分。
ALTER TABLE public.piaopiao_publishers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.piaopiao_publisher_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.piaopiao_publish_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.piaopiao_batch_campaigns ENABLE ROW LEVEL SECURITY;

-- 外部上架入口專用：1~5 個商品，每商品一團。任何一樣失敗，整批都不建立。
CREATE OR REPLACE FUNCTION public.rpc_piaopiao_publish_batch(
  p_tenant_id UUID,
  p_publisher_id BIGINT,
  p_request_id UUID,
  p_operator_id UUID,
  p_end_at TIMESTAMPTZ,
  p_pickup_deadline DATE,
  p_items JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_publisher public.piaopiao_publishers%ROWTYPE;
  v_batch_id BIGINT;
  v_brand_id BIGINT;
  v_category_id BIGINT;
  v_item JSONB;
  v_i INT := 0;
  v_name TEXT;
  v_description TEXT;
  v_images JSONB;
  v_supplier_id BIGINT;
  v_supplier_name TEXT;
  v_product_id BIGINT;
  v_product_code TEXT;
  v_sku_id BIGINT;
  v_sku_code TEXT;
  v_campaign_id BIGINT;
  v_campaign_no TEXT;
  v_variant JSONB;
  v_variant_name TEXT;
  v_cost NUMERIC;
  v_branch NUMERIC;
  v_retail NUMERIC;
  v_result JSONB := '[]'::jsonb;
  v_existing JSONB;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'piaopiao publish is service-only';
  END IF;
  IF p_tenant_id IS NULL OR p_publisher_id IS NULL OR p_request_id IS NULL OR p_operator_id IS NULL THEN
    RAISE EXCEPTION 'publisher, request and audit operator are required';
  END IF;
  IF p_end_at IS NULL OR p_end_at <= NOW() THEN
    RAISE EXCEPTION '收單時間必須晚於現在';
  END IF;
  IF p_pickup_deadline IS NULL OR p_pickup_deadline < DATE(p_end_at AT TIME ZONE 'Asia/Taipei') THEN
    RAISE EXCEPTION '取貨日不可早於收單日';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION '一次必須建立 1 到 5 樣商品';
  END IF;

  SELECT * INTO v_publisher
    FROM public.piaopiao_publishers
   WHERE id = p_publisher_id AND tenant_id = p_tenant_id AND is_active IS TRUE
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '上架資格不存在或已停用';
  END IF;

  -- 防止連點送出：同一個 request_id 永遠回同一批團，絕不重複建。
  SELECT b.id INTO v_batch_id
    FROM public.piaopiao_publish_batches b
   WHERE b.tenant_id = p_tenant_id
     AND b.publisher_id = p_publisher_id
     AND b.request_id = p_request_id
   FOR UPDATE;
  IF FOUND THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'campaign_id', s.campaign_id,
      'campaign_no', c.campaign_no,
      'name', c.name,
      'cover_image_path', c.cover_image_url
    ) ORDER BY s.id), '[]'::jsonb)
      INTO v_existing
      FROM public.piaopiao_batch_campaigns s
      JOIN public.group_buy_campaigns c ON c.id = s.campaign_id
     WHERE s.batch_id = v_batch_id;
    RETURN jsonb_build_object('batch_id', v_batch_id, 'campaigns', v_existing, 'reused', TRUE);
  END IF;

  -- 同 tenant 的號碼生成互斥，避免兩人同時發佈撞商品/SKU/團號。
  PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant_id::TEXT || ':piaopiao-publish', 0));

  INSERT INTO public.brands (tenant_id, code, name, is_active)
  VALUES (p_tenant_id, 'PIAOPIAO', '漂漂館', TRUE)
  ON CONFLICT (tenant_id, code) DO UPDATE SET is_active = TRUE, updated_at = NOW()
  RETURNING id INTO v_brand_id;

  -- 漂漂館是固定的商品分類，也同時保留品牌標記，方便既有商品後台搜尋／報表。
  INSERT INTO public.categories (tenant_id, parent_id, code, name, level, sort_order, is_active)
  VALUES (p_tenant_id, NULL, 'PIAOPIAO', '漂漂館', 1, 0, TRUE)
  ON CONFLICT (tenant_id, code) DO UPDATE SET is_active = TRUE, updated_at = NOW()
  RETURNING id INTO v_category_id;

  INSERT INTO public.piaopiao_publish_batches (
    tenant_id, publisher_id, request_id, end_at, pickup_deadline
  ) VALUES (
    p_tenant_id, p_publisher_id, p_request_id, p_end_at, p_pickup_deadline
  ) RETURNING id INTO v_batch_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_i := v_i + 1;
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION '第 % 樣商品格式不正確', v_i;
    END IF;
    v_name := NULLIF(btrim(v_item ->> 'name'), '');
    v_description := NULLIF(btrim(v_item ->> 'description'), '');
    v_images := COALESCE(v_item -> 'images', '[]'::jsonb);
    IF v_name IS NULL OR v_description IS NULL THEN
      RAISE EXCEPTION '第 % 樣商品必須填商品名稱與介紹', v_i;
    END IF;
    IF jsonb_typeof(v_images) <> 'array' OR jsonb_array_length(v_images) < 1
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_images) AS x WHERE jsonb_typeof(x) <> 'string'
                  OR x #>> '{}' !~ ('^piaopiao/' || v_publisher.id::TEXT || '/')) THEN
      RAISE EXCEPTION '第 % 樣商品至少要有一張本次上傳的商品圖', v_i;
    END IF;
    IF jsonb_typeof(v_item -> 'variants') <> 'array' OR jsonb_array_length(v_item -> 'variants') < 1 THEN
      RAISE EXCEPTION '第 % 樣商品至少要有一個規格', v_i;
    END IF;

    IF v_publisher.lane = 'chao' THEN
      SELECT id INTO v_supplier_id FROM public.suppliers
       WHERE tenant_id = p_tenant_id AND is_active IS TRUE AND btrim(name) = '潮包子'
       ORDER BY id LIMIT 1;
      IF v_supplier_id IS NULL THEN
        RAISE EXCEPTION '漂漂潮固定供應商「潮包子」尚未設定，請先由總部設定';
      END IF;
    ELSE
      v_supplier_id := NULLIF(v_item ->> 'supplier_id', '')::BIGINT;
      IF v_supplier_id IS NOT NULL THEN
        PERFORM 1 FROM public.suppliers WHERE id = v_supplier_id AND tenant_id = p_tenant_id AND is_active IS TRUE;
        IF NOT FOUND THEN RAISE EXCEPTION '第 % 樣商品的供應商不可用', v_i; END IF;
      ELSE
        v_supplier_name := NULLIF(btrim(v_item ->> 'supplier_name'), '');
        IF v_supplier_name IS NULL THEN RAISE EXCEPTION '第 % 樣商品必須選擇或新增供應商', v_i; END IF;
        SELECT id INTO v_supplier_id FROM public.suppliers
         WHERE tenant_id = p_tenant_id AND lower(btrim(name)) = lower(v_supplier_name)
         ORDER BY id LIMIT 1;
        IF v_supplier_id IS NULL THEN
          INSERT INTO public.suppliers (tenant_id, code, name, is_active, notes)
          VALUES (p_tenant_id,
            'PIAOPIAO-' || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYYYMMDD') || '-' || lpad(v_i::TEXT, 2, '0') || '-' || substring(md5(p_request_id::TEXT) FROM 1 FOR 6),
            v_supplier_name, TRUE, '由漂漂彤外部上架入口新增')
          RETURNING id INTO v_supplier_id;
        END IF;
      END IF;
    END IF;

    SELECT 'A' || lpad((COALESCE(MAX((substring(product_code FROM '^A(\d+)$'))::INT), 0) + 1)::TEXT, 5, '0')
      INTO v_product_code FROM public.products
     WHERE tenant_id = p_tenant_id AND product_code ~ '^A\d+$';

    INSERT INTO public.products (
      tenant_id, product_code, name, description, images, status, brand_id, category_id,
      storage_type, default_supplier_id, is_for_shop, sale_mode, created_by, updated_by
    ) VALUES (
      p_tenant_id, v_product_code, v_name, v_description, v_images, 'active', v_brand_id, v_category_id,
      'room_temp', v_supplier_id, TRUE, 'preorder', p_operator_id, p_operator_id
    ) RETURNING id INTO v_product_id;

    FOR v_variant IN SELECT value FROM jsonb_array_elements(v_item -> 'variants')
    LOOP
      v_variant_name := NULLIF(btrim(v_variant ->> 'name'), '');
      v_cost := NULLIF(v_variant ->> 'cost_price', '')::NUMERIC;
      v_branch := NULLIF(v_variant ->> 'branch_price', '')::NUMERIC;
      v_retail := NULLIF(v_variant ->> 'retail_price', '')::NUMERIC;
      IF v_variant_name IS NULL OR v_cost IS NULL OR v_branch IS NULL OR v_retail IS NULL
         OR v_cost < 0 OR v_branch <= 0 OR v_retail <= 0 OR v_cost > v_branch OR v_branch >= v_retail THEN
        RAISE EXCEPTION '第 % 樣商品每個規格都要填成本、分店、售價，且必須符合 成本 ≤ 分店價 < 售價', v_i;
      END IF;
      SELECT v_product_code || '-' || lpad((COUNT(*) + 1)::TEXT, 2, '0') INTO v_sku_code
        FROM public.skus WHERE tenant_id = p_tenant_id AND product_id = v_product_id;
      INSERT INTO public.skus (
        tenant_id, product_id, sku_code, variant_name, spec, base_unit, tax_rate, status,
        product_name, brand_id, category_id, created_by, updated_by
      ) VALUES (
        p_tenant_id, v_product_id, v_sku_code, v_variant_name, '{}'::jsonb, '件', 0.05, 'active',
        v_name, v_brand_id, v_category_id, p_operator_id, p_operator_id
      ) RETURNING id INTO v_sku_id;
      INSERT INTO public.sku_packs (sku_id, unit, qty_in_base, is_default_sale, created_by, updated_by)
      VALUES (v_sku_id, '件', 1, TRUE, p_operator_id, p_operator_id);
      PERFORM public.rpc_upsert_price(p_tenant_id, v_sku_id, 'cost', NULL, v_cost, NOW(), '漂漂館上架', p_operator_id);
      PERFORM public.rpc_upsert_price(p_tenant_id, v_sku_id, 'branch', NULL, v_branch, NOW(), '漂漂館上架', p_operator_id);
      PERFORM public.rpc_upsert_price(p_tenant_id, v_sku_id, 'retail', NULL, v_retail, NOW(), '漂漂館上架', p_operator_id);
      INSERT INTO public.sku_suppliers (tenant_id, sku_id, supplier_id, last_cost, is_preferred, created_by, updated_by)
      VALUES (p_tenant_id, v_sku_id, v_supplier_id, v_cost, TRUE, p_operator_id, p_operator_id);
      INSERT INTO public.supplier_skus (tenant_id, supplier_id, sku_id, default_unit_cost, is_preferred, created_by, updated_by)
      VALUES (p_tenant_id, v_supplier_id, v_sku_id, v_cost, TRUE, p_operator_id, p_operator_id);
    END LOOP;

    SELECT 'GRP-' || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYYYMMDD') || '-' ||
           lpad((COALESCE(MAX((substring(campaign_no FROM '^GRP-[0-9]{8}-(\d+)$'))::INT), 0) + 1)::TEXT, 3, '0')
      INTO v_campaign_no FROM public.group_buy_campaigns
     WHERE tenant_id = p_tenant_id
       AND campaign_no LIKE 'GRP-' || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYYYMMDD') || '-%';

    INSERT INTO public.group_buy_campaigns (
      tenant_id, campaign_no, name, description, cover_image_url, status, close_type,
      product_id, start_at, end_at, pickup_deadline, is_for_shop, sales_channel, created_by, updated_by
    ) VALUES (
      p_tenant_id, v_campaign_no, v_name, v_description, v_images ->> 0, 'open', 'regular',
      v_product_id, NOW(), p_end_at, p_pickup_deadline, TRUE, 'piaopiao', p_operator_id, p_operator_id
    ) RETURNING id INTO v_campaign_id;

    INSERT INTO public.campaign_items (tenant_id, campaign_id, sku_id, unit_price, sort_order, created_by, updated_by)
    SELECT p_tenant_id, v_campaign_id, s.id, p.price, row_number() OVER (ORDER BY s.id)::INT, p_operator_id, p_operator_id
      FROM public.skus s
      JOIN public.prices p ON p.tenant_id = p_tenant_id AND p.sku_id = s.id
                         AND p.scope = 'retail' AND p.effective_to IS NULL AND p.price > 0
     WHERE s.tenant_id = p_tenant_id AND s.product_id = v_product_id AND s.status = 'active';
    IF NOT EXISTS (SELECT 1 FROM public.campaign_items WHERE campaign_id = v_campaign_id) THEN
      RAISE EXCEPTION '第 % 樣商品無可販售規格，整批已取消', v_i;
    END IF;
    INSERT INTO public.piaopiao_batch_campaigns (tenant_id, batch_id, campaign_id)
    VALUES (p_tenant_id, v_batch_id, v_campaign_id);
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'campaign_id', v_campaign_id, 'campaign_no', v_campaign_no, 'name', v_name,
      'cover_image_path', v_images ->> 0
    ));
  END LOOP;

  RETURN jsonb_build_object('batch_id', v_batch_id, 'campaigns', v_result, 'reused', FALSE);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_piaopiao_publish_batch(UUID, BIGINT, UUID, UUID, TIMESTAMPTZ, DATE, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_piaopiao_publish_batch(UUID, BIGINT, UUID, UUID, TIMESTAMPTZ, DATE, JSONB) TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_piaopiao_publisher_overview()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner', 'admin', 'hq_manager') THEN
    RAISE EXCEPTION 'permission denied';
  END IF;
  RETURN jsonb_build_object(
    'requests', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.requested_at DESC)
      FROM public.piaopiao_publisher_requests r
     WHERE r.tenant_id = v_tenant
       AND NOT EXISTS (SELECT 1 FROM public.piaopiao_publishers p WHERE p.tenant_id = r.tenant_id AND p.line_user_id = r.line_user_id)), '[]'::jsonb),
    'publishers', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.lane, p.display_name)
      FROM public.piaopiao_publishers p WHERE p.tenant_id = v_tenant), '[]'::jsonb),
    'chao_supplier_ready', EXISTS (SELECT 1 FROM public.suppliers s WHERE s.tenant_id = v_tenant AND s.is_active AND btrim(s.name) = '潮包子')
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_approve_piaopiao_publisher(
  p_request_id BIGINT,
  p_display_name TEXT,
  p_lane TEXT
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_request public.piaopiao_publisher_requests%ROWTYPE;
  v_id BIGINT;
BEGIN
  IF v_role NOT IN ('owner', 'admin') THEN RAISE EXCEPTION 'permission denied'; END IF;
  IF p_lane NOT IN ('tong', 'chao') OR NULLIF(btrim(p_display_name), '') IS NULL THEN
    RAISE EXCEPTION '請指定顯示名稱與漂漂彤／漂漂潮';
  END IF;
  SELECT * INTO v_request FROM public.piaopiao_publisher_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '找不到這筆 LINE 開通申請'; END IF;
  INSERT INTO public.piaopiao_publishers (tenant_id, line_user_id, display_name, lane, is_active, created_by, updated_by)
  VALUES (v_tenant, v_request.line_user_id, btrim(p_display_name), p_lane, TRUE, auth.uid(), auth.uid())
  ON CONFLICT (tenant_id, line_user_id) DO UPDATE SET display_name = EXCLUDED.display_name, lane = EXCLUDED.lane, is_active = TRUE, updated_by = auth.uid(), updated_at = NOW()
  RETURNING id INTO v_id;
  UPDATE public.piaopiao_publisher_requests SET reviewed_at = NOW(), reviewed_by = auth.uid() WHERE id = p_request_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_set_piaopiao_publisher_active(p_publisher_id BIGINT, p_is_active BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner', 'admin') THEN RAISE EXCEPTION 'permission denied'; END IF;
  UPDATE public.piaopiao_publishers SET is_active = p_is_active, updated_by = auth.uid(), updated_at = NOW()
   WHERE id = p_publisher_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION '找不到上架員'; END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_piaopiao_publisher_overview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_approve_piaopiao_publisher(BIGINT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_set_piaopiao_publisher_active(BIGINT, BOOLEAN) TO authenticated;

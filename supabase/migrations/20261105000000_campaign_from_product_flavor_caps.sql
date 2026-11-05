-- ============================================================================
-- 20261105000000_campaign_from_product_flavor_caps.sql
--
-- 限量團：一個商品多個口味，每個口味各自限量（老闆 11/5）。
-- 商品頁「建立開團」選限量時，可以每個規格各填一個上限，建團時同一交易寫進 campaign_items.cap_qty。
-- 下單、後台加單、記事本留言本來就照 cap_qty 擋，這裡不動。
--
-- rpc_create_campaign_from_product 多收 p_item_caps JSONB（預設 NULL），格式 [{"sku_id":1,"cap_qty":3}]：
--   - 只有 close_type='limited' 且 sales_channel='main' 才收，其他情況傳非空就擋；空陣列等於沒給。
--   - 每個 cap_qty 是大於 0 的整數（0 在下單檢查裡等於不限，所以拒收）；每個 sku_id 屬於這個商品且 active；不可重複。
--   - 限量必填改成：總量有填，或所有 active 規格都有上限。兩者都沒有擋；只填一部分擋；兩者都給也擋。
--     以函式內當下查到的 active 規格為準；檢查之後規格才異動就整個團退回。
--   - 用 p_item_caps 時 total_cap_qty 存空。
--   - 舊呼叫（不傳 p_item_caps）行為不變；只有「限量且沒填總量」的錯誤訊息多寫了每個規格那一句。
--   - 權限：12 參數版沒有 REVOKE；新版 REVOKE PUBLIC、anon，只 GRANT authenticated。
--
-- 基底：rpc_create_campaign_from_product @ 20260929060000:15（只加一個參數、驗證、寫 cap_qty）。
-- 上線順序：先貼這份 SQL，再合併前端（步驟見 scripts/PROD-flavor-caps-2026-11/README.md）。
--   新前端只有在限量＋全部口味都填時才傳 p_item_caps；這份還沒貼的話，那種開團會失敗。
-- 可重貼：前置檢查接受基底版或本檔新版，整份貼兩次結果一樣。前置檢查不過會整份停下、一行都不改。
-- Rollback：scripts/PROD-flavor-caps-2026-11/rollback_20261105000000.sql
--   （DROP 13 參數版、逐字還原 12 參數版；已建好的團的上限留著照常有效）。
--
-- 前置檢查的 md5（算法同 20261028000000：取 pg_proc.prosrc，CRLF→LF 後 md5）：
--   12 參數基底版 b8a3151f926d1ca1b55173bb0ae65353
--   13 參數本檔版 871cad1fd6763b2d7e3110e27453ae29
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 前置檢查（不過就整份停下）
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_bad  TEXT[] := ARRAY[]::TEXT[];
  v_old  REGPROCEDURE := to_regprocedure('public.rpc_create_campaign_from_product(text, timestamp with time zone, date, bigint, text, timestamp with time zone, timestamp with time zone, boolean, boolean, text, text, numeric)');
  v_new  REGPROCEDURE := to_regprocedure('public.rpc_create_campaign_from_product(text, timestamp with time zone, date, bigint, text, timestamp with time zone, timestamp with time zone, boolean, boolean, text, text, numeric, jsonb)');
  v_md5  TEXT;
BEGIN
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'campaign_items' AND column_name = 'cap_qty';
  IF NOT FOUND THEN v_bad := v_bad || '找不到欄位 campaign_items.cap_qty'::TEXT; END IF;

  IF v_old IS NULL AND v_new IS NULL THEN
    v_bad := v_bad || '找不到 12 參數或 13 參數的 rpc_create_campaign_from_product'::TEXT;
  END IF;
  IF v_old IS NOT NULL THEN
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5 FROM pg_proc p WHERE p.oid = v_old;
    IF v_md5 IS DISTINCT FROM 'b8a3151f926d1ca1b55173bb0ae65353' THEN
      v_bad := v_bad || format('12 參數版內文不是預期的版本（線上 md5=%s）；可能有人改過，請先比對再決定', v_md5);
    END IF;
  END IF;
  IF v_new IS NOT NULL THEN
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5 FROM pg_proc p WHERE p.oid = v_new;
    IF v_md5 IS DISTINCT FROM '871cad1fd6763b2d7e3110e27453ae29' THEN
      v_bad := v_bad || format('13 參數版內文不是本檔版本（線上 md5=%s）；可能有人改過，請先比對再決定', v_md5);
    END IF;
  END IF;

  -- 同名但參數不同的版本（會變成兩支並存）
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public'
                AND p.proname = 'rpc_create_campaign_from_product'
                AND p.oid NOT IN (COALESCE(v_old::oid, 0), COALESCE(v_new::oid, 0))) THEN
    v_bad := v_bad || '已經有同名但參數不同的 rpc_create_campaign_from_product，請先查是誰建的'::TEXT;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。不符的項目：\n%',
      array_to_string(v_bad, E'\n');
  END IF;
END;
$precheck$;

-- ----------------------------------------------------------------------------
-- 1. 換成 13 參數版
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN, TEXT, TEXT, NUMERIC);

CREATE OR REPLACE FUNCTION public.rpc_create_campaign_from_product(
  p_name            TEXT,
  p_end_at          TIMESTAMPTZ,
  p_pickup_deadline DATE,
  p_product_id      BIGINT,
  p_description     TEXT DEFAULT NULL,
  p_customer_end_at TIMESTAMPTZ DEFAULT NULL,
  p_start_at        TIMESTAMPTZ DEFAULT NULL,
  p_auto_open       BOOLEAN DEFAULT FALSE,
  p_line_note       BOOLEAN DEFAULT TRUE,
  p_close_type      TEXT    DEFAULT 'regular',
  p_sales_channel   TEXT    DEFAULT 'main',
  p_total_cap_qty   NUMERIC DEFAULT NULL,
  p_item_caps       JSONB   DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_no          TEXT;
  v_campaign_id BIGINT;
  v_desc        TEXT;
  v_missing     TEXT;
  v_start_at    TIMESTAMPTZ;
  v_is_future   BOOLEAN;
  v_sort        INT := 1;
  r             RECORD;
  v_use_item_caps BOOLEAN := FALSE;
  v_cap_map     JSONB := '{}'::JSONB;
  v_elem        JSONB;
  v_sku_num     NUMERIC;
  v_cap_num     NUMERIC;
  v_cap         NUMERIC;
  v_bad         TEXT;
BEGIN
  IF COALESCE(p_close_type, 'regular') NOT IN ('regular', 'fast', 'limited', 'food_train') THEN
    RAISE EXCEPTION '開團類別不正確：%', p_close_type;
  END IF;
  IF COALESCE(p_sales_channel, 'main') NOT IN ('main', 'piaopiao') THEN
    RAISE EXCEPTION '銷售通路不正確：%', p_sales_channel;
  END IF;

  IF p_total_cap_qty IS NOT NULL AND p_total_cap_qty <= 0 THEN
    RAISE EXCEPTION '總量上限要大於 0';
  END IF;

  -- 每個規格各自的上限：只收陣列；空陣列等於沒給。
  IF p_item_caps IS NOT NULL THEN
    IF jsonb_typeof(p_item_caps) <> 'array' THEN
      RAISE EXCEPTION '每個規格的上限格式不正確';
    END IF;
    v_use_item_caps := jsonb_array_length(p_item_caps) > 0;
  END IF;
  IF v_use_item_caps AND NOT (COALESCE(p_close_type, 'regular') = 'limited' AND COALESCE(p_sales_channel, 'main') = 'main') THEN
    RAISE EXCEPTION '只有限量團可以填每個規格的上限';
  END IF;
  IF v_use_item_caps AND p_total_cap_qty IS NOT NULL THEN
    RAISE EXCEPTION '總量上限和每個規格的上限只能填一種';
  END IF;
  IF COALESCE(p_close_type, 'regular') = 'limited' AND COALESCE(p_sales_channel, 'main') <> 'piaopiao'
     AND p_total_cap_qty IS NULL AND NOT v_use_item_caps THEN
    RAISE EXCEPTION '限量團要填總量上限，或每個規格都填上限';
  END IF;

  IF v_use_item_caps THEN
    FOR v_elem IN SELECT value FROM jsonb_array_elements(p_item_caps) LOOP
      IF jsonb_typeof(v_elem) IS DISTINCT FROM 'object'
         OR jsonb_typeof(v_elem -> 'sku_id') IS DISTINCT FROM 'number'
         OR jsonb_typeof(v_elem -> 'cap_qty') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION '每個規格的上限格式不正確';
      END IF;
      v_sku_num := (v_elem ->> 'sku_id')::NUMERIC;
      v_cap_num := (v_elem ->> 'cap_qty')::NUMERIC;
      IF v_sku_num <= 0 OR v_sku_num <> trunc(v_sku_num) OR v_sku_num > 9223372036854775807 THEN
        RAISE EXCEPTION '每個規格的上限格式不正確';
      END IF;
      -- 0 在下單檢查裡等於不限（COALESCE(cap_qty, 0) > 0 才算有設），所以一定要擋。
      IF v_cap_num <= 0 OR v_cap_num <> trunc(v_cap_num) THEN
        RAISE EXCEPTION '每個規格的上限要填大於 0 的整數';
      END IF;
      IF v_cap_map ? trunc(v_sku_num)::TEXT THEN
        RAISE EXCEPTION '同一個規格不能重複填上限：%', trunc(v_sku_num)::TEXT;
      END IF;
      v_cap_map := v_cap_map || jsonb_build_object(trunc(v_sku_num)::TEXT, v_cap_num);
    END LOOP;
  END IF;

  v_start_at := COALESCE(p_start_at, NOW());
  v_is_future := v_start_at > NOW();

  IF p_end_at IS NULL THEN
    RAISE EXCEPTION '請設定店家收單時間';
  END IF;
  IF p_customer_end_at IS NOT NULL AND p_customer_end_at > p_end_at THEN
    RAISE EXCEPTION '客人收單時間不能晚於店家收單時間';
  END IF;
  IF p_customer_end_at IS NOT NULL AND v_start_at >= p_customer_end_at THEN
    RAISE EXCEPTION '開團時間必須早於客人收單時間';
  END IF;
  IF p_customer_end_at IS NULL AND v_start_at >= p_end_at THEN
    RAISE EXCEPTION '開團時間必須早於店家收單時間';
  END IF;

  -- 確認 product 在同 tenant
  PERFORM 1 FROM products WHERE id = p_product_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product % not in tenant', p_product_id;
  END IF;

  -- 以當下查到的啟用規格為準（畫面打開後可能有人新增或停用規格）。
  IF v_use_item_caps THEN
    SELECT string_agg(k.key, '、' ORDER BY k.key)
      INTO v_bad
      FROM jsonb_object_keys(v_cap_map) AS k(key)
     WHERE NOT EXISTS (
       SELECT 1
         FROM skus s
        WHERE s.id = k.key::BIGINT
          AND s.product_id = p_product_id
          AND s.tenant_id  = v_tenant
          AND s.status     = 'active'
     );
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '這些規格不屬於這個商品或已停用：%', v_bad;
    END IF;

    SELECT string_agg(
             s.sku_code || COALESCE(' (' || NULLIF(btrim(s.variant_name), '') || ')', ''),
             '、' ORDER BY s.id)
      INTO v_bad
      FROM skus s
     WHERE s.product_id = p_product_id
       AND s.tenant_id  = v_tenant
       AND s.status     = 'active'
       AND NOT (v_cap_map ? s.id::TEXT);
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '每個規格都要填上限，還沒填：%', v_bad;
    END IF;
  END IF;

  -- 開團前檢查所有 active SKU 都有現行 retail 價，防止 0 元加單。
  SELECT string_agg(
           s.sku_code || COALESCE(' (' || NULLIF(btrim(s.variant_name), '') || ')', ''),
           '、' ORDER BY s.id)
    INTO v_missing
    FROM skus s
   WHERE s.product_id = p_product_id
     AND s.tenant_id  = v_tenant
     AND s.status     = 'active'
     AND NOT EXISTS (
       SELECT 1
         FROM prices p
        WHERE p.sku_id       = s.id
          AND p.tenant_id    = v_tenant
          AND p.scope        = 'retail'
          AND p.effective_to IS NULL
     );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '無法開團：以下規格尚未設定零售價，請先到商品頁設定價格後再開團 → %', v_missing;
  END IF;

  v_desc := COALESCE(
    p_description,
    (SELECT description FROM products WHERE id = p_product_id AND tenant_id = v_tenant)
  );
  v_no := public.rpc_next_campaign_no();

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, description, status, product_id,
    start_at, end_at, customer_end_at, pickup_deadline, auto_open, line_note_enabled,
    close_type, sales_channel, total_cap_qty,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_name, v_desc,
    CASE WHEN v_is_future THEN 'draft' ELSE 'open' END,
    p_product_id, v_start_at, p_end_at, p_customer_end_at, p_pickup_deadline,
    COALESCE(p_auto_open, FALSE) AND v_is_future,
    COALESCE(p_line_note, TRUE),
    -- 漂漂館 = 常規 + sales_channel='piaopiao'（同 CampaignForm 的收單類型下拉）
    CASE WHEN COALESCE(p_sales_channel, 'main') = 'piaopiao' THEN 'regular' ELSE COALESCE(p_close_type, 'regular') END,
    COALESCE(p_sales_channel, 'main'),
    -- 總量上限只對限量 / 快團有意義（同 CampaignForm 只在這兩種顯示欄位）
    CASE WHEN COALESCE(p_sales_channel, 'main') <> 'piaopiao' AND COALESCE(p_close_type, 'regular') IN ('limited', 'fast')
         THEN p_total_cap_qty END,
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_campaign_id;

  -- 將該商品的所有 active SKU 補進 campaign_items。
  FOR r IN
    SELECT
      s.id AS sku_id,
      COALESCE(
        (SELECT p.price
           FROM prices p
          WHERE p.sku_id    = s.id
            AND p.scope     = 'retail'
            AND p.tenant_id = v_tenant
            AND p.effective_to IS NULL
          ORDER BY p.effective_from DESC
          LIMIT 1),
        0
      ) AS unit_price
    FROM skus s
   WHERE s.product_id = p_product_id
     AND s.tenant_id  = v_tenant
     AND s.status     = 'active'
   ORDER BY s.id
  LOOP
    v_cap := (v_cap_map ->> r.sku_id::TEXT)::NUMERIC;
    -- 上面檢查之後才新增的規格：整個團退回，不留「有的口味沒上限」的團。
    IF v_use_item_caps AND v_cap IS NULL THEN
      RAISE EXCEPTION '規格剛有異動，請重新開團：sku %', r.sku_id;
    END IF;
    INSERT INTO campaign_items (
      tenant_id, campaign_id, sku_id, unit_price, cap_qty, sort_order,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_campaign_id, r.sku_id, r.unit_price, v_cap, v_sort,
      auth.uid(), auth.uid()
    )
    ON CONFLICT (campaign_id, sku_id) DO NOTHING;
    v_sort := v_sort + 1;
  END LOOP;

  -- 上面檢查之後才停用的規格：填的上限每一格都要真的寫進團裡，少一格就整個團退回。
  IF v_use_item_caps AND (
       SELECT count(*)
         FROM campaign_items ci
        WHERE ci.campaign_id = v_campaign_id
          AND ci.cap_qty IS NOT NULL
     ) <> (SELECT count(*) FROM jsonb_object_keys(v_cap_map)) THEN
    RAISE EXCEPTION '規格剛有異動，請重新開團';
  END IF;

  RETURN v_campaign_id;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN, TEXT, TEXT, NUMERIC, JSONB)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN, TEXT, TEXT, NUMERIC, JSONB)
  TO authenticated;
COMMENT ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN, TEXT, TEXT, NUMERIC, JSONB) IS
    '從單一商品建團：未來 p_start_at 建為草稿，並可用 p_auto_open 沿用既有排程自動開團；'
  '未傳 p_start_at 的舊呼叫維持立即開團，自動開團固定關閉；p_line_note=FALSE 開團時不發 LINE 記事本；'
  'p_close_type / p_sales_channel 指定開團類別（漂漂館 = regular + piaopiao）；p_total_cap_qty 快團可選；'
  '限量團要填 p_total_cap_qty，或用 p_item_caps [{sku_id, cap_qty}] 給每個 active 規格各一個上限，兩者只能填一種。';

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- 20260927010000_line_note_campaign_opt_out.sql
--
-- 開團可以選「這團不發 LINE 記事本」。老闆 9/27：「在開團那邊做一個開關，要能說要不要發記事本」。
--
-- - group_buy_campaigns.line_note_enabled（預設 TRUE）：FALSE 的團開團時
--   _line_note_on_campaign_open 直接跳過，一個社群都不排。只管「開團那一刻」；
--   之後在開團彈窗手動勾社群發文照樣可以（那是人決定的）。
-- - rpc_create_campaign_from_product 多收 p_line_note（第 9 個參數、預設 TRUE，舊呼叫不用改）；
--   8 參數版 DROP 掉，否則 PostgREST 兩個同名函式對不出要呼叫哪一個。
-- - rpc_set_campaign_line_note(p_id, p_enabled)：編輯表單用，比照 rpc_set_campaign_auto_open 的守衛。
--
-- 基底：_line_note_on_campaign_open @ 20260927000000、
--       rpc_create_campaign_from_product @ 20260925000000（只加一個參數、一個欄位）。
-- rollback：還原那兩支到基底（8 參數版要先 DROP 9 參數版；殘留的 6 參數版不用還）；
--   DROP FUNCTION rpc_set_campaign_line_note(BIGINT, BOOLEAN)；欄位留著無害。
-- ============================================================================

ALTER TABLE public.group_buy_campaigns
  ADD COLUMN IF NOT EXISTS line_note_enabled BOOLEAN NOT NULL DEFAULT TRUE;
COMMENT ON COLUMN public.group_buy_campaigns.line_note_enabled IS
  'FALSE = 開團時不自動發 LINE 記事本（_line_note_on_campaign_open 跳過）。只管開團那一刻，手動發文不受影響。20260927010000';

-- ----------------------------------------------------------------------------
-- 1. 開團 trigger：關掉的團跳過
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_on_campaign_open()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c RECORD;
  v_post BIGINT;
BEGIN
  -- 只在「剛變成 open」時跑：INSERT 直接看 NEW，UPDATE 要 OLD 不是 open
  IF NEW.status <> 'open' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'open' THEN RETURN NEW; END IF;
  -- 補貨申請的 sentinel 團（20260612000020）建立時就是 open，不是要發的團
  IF NEW.campaign_no = '__INTERNAL_RESTOCK__' THEN RETURN NEW; END IF;
  -- 這團開團時不發記事本（開團表單的開關）
  IF NOT COALESCE(NEW.line_note_enabled, TRUE) THEN RETURN NEW; END IF;

  FOR v_c IN
    SELECT c.id AS community_id, c.account_id, c.post_mode
      FROM line_note_communities c
      JOIN line_note_accounts a ON a.id = c.account_id AND a.status = 'active'
     WHERE c.tenant_id = NEW.tenant_id
       AND c.auto_post_on_open
       AND c.share_from_community_id IS NULL
       AND (NEW.owner_store_id IS NULL OR c.store_id = NEW.owner_store_id)
       AND public._line_note_takes_channel(c.sales_channels, NEW.sales_channel)
  LOOP
    INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, share_state, created_by, updated_by)
    VALUES (NEW.tenant_id, v_c.community_id, NEW.id, 'queued',
            CASE WHEN v_c.post_mode = 'immediate' THEN 'none' ELSE 'scheduled' END,
            NEW.updated_by, NEW.updated_by)
    ON CONFLICT (community_id, campaign_id) DO NOTHING
    RETURNING id INTO v_post;
    IF v_post IS NOT NULL THEN
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
      VALUES (NEW.tenant_id, 'post', v_c.account_id, v_c.community_id, v_post, NEW.updated_by);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2. 商品頁建團：多收 p_line_note
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN);
-- 線上還殘留一支 6 參數版（p_customer_end_at 排在 p_description 前面，repo 裡沒有這個順序）：
-- 兩支同名同時存在，PostgREST 對只帶前五個參數的呼叫（匯入頁）對不出要哪一支。一起清掉。
DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TIMESTAMPTZ, TEXT);


CREATE OR REPLACE FUNCTION public.rpc_create_campaign_from_product(
  p_name            TEXT,
  p_end_at          TIMESTAMPTZ,
  p_pickup_deadline DATE,
  p_product_id      BIGINT,
  p_description     TEXT DEFAULT NULL,
  p_customer_end_at TIMESTAMPTZ DEFAULT NULL,
  p_start_at        TIMESTAMPTZ DEFAULT NULL,
  p_auto_open       BOOLEAN DEFAULT FALSE,
  p_line_note       BOOLEAN DEFAULT TRUE
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
BEGIN
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
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_name, v_desc,
    CASE WHEN v_is_future THEN 'draft' ELSE 'open' END,
    p_product_id, v_start_at, p_end_at, p_customer_end_at, p_pickup_deadline,
    COALESCE(p_auto_open, FALSE) AND v_is_future,
    COALESCE(p_line_note, TRUE),
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
    INSERT INTO campaign_items (
      tenant_id, campaign_id, sku_id, unit_price, sort_order,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_campaign_id, r.sku_id, r.unit_price, v_sort,
      auth.uid(), auth.uid()
    )
    ON CONFLICT (campaign_id, sku_id) DO NOTHING;
    v_sort := v_sort + 1;
  END LOOP;

  RETURN v_campaign_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN)
  TO authenticated;
COMMENT ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN) IS
  '從單一商品建團：未來 p_start_at 建為草稿，並可用 p_auto_open 沿用既有排程自動開團；'
  '未傳 p_start_at 的舊呼叫維持立即開團，自動開團固定關閉；p_line_note=FALSE 開團時不發 LINE 記事本；'
  '保留商品文案、active SKU 與現行 retail 價檢查。';

-- ----------------------------------------------------------------------------
-- 3. 編輯表單的開關
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_campaign_line_note(p_id BIGINT, p_enabled BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_owner  BIGINT;
  v_status TEXT;
BEGIN
  SELECT owner_store_id, status INTO v_owner, v_status
    FROM group_buy_campaigns WHERE id = p_id AND tenant_id = v_tenant;
  IF v_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;
  -- 同 rpc_upsert_campaign：自開團只能改自己店的
  IF v_owner IS NOT NULL THEN PERFORM public._assert_own_store(v_owner); END IF;

  UPDATE group_buy_campaigns
     SET line_note_enabled = COALESCE(p_enabled, TRUE)
   WHERE id = p_id AND line_note_enabled IS DISTINCT FROM COALESCE(p_enabled, TRUE);
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_set_campaign_line_note(BIGINT, BOOLEAN) TO authenticated;

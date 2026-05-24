-- ============================================================================
-- 開團「上架個人賣場」搬到 campaign 維度
--
-- 原本 products.is_for_shop 控制商品是否在會員 App / LIFF /shop 出現,
-- 但實務上同一商品在不同團期會想分別決定要不要曝光 (例如:測試團、
-- 內部團、員購團…). 改成放在 group_buy_campaigns 上,以團為單位控制。
-- DEFAULT TRUE 保持向後相容,既有團不會被隱藏。
-- ============================================================================

-- ── 1. 加欄位 ────────────────────────────────────────────────────────────────
ALTER TABLE group_buy_campaigns
  ADD COLUMN IF NOT EXISTS is_for_shop BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN group_buy_campaigns.is_for_shop IS
  'TRUE = 在會員 App / LIFF /shop 中顯示此團 (預設 TRUE)';

-- ── 2. rpc_upsert_campaign 收入 14 參數 (加 p_is_for_shop) ────────────────
-- 用動態 DROP 處理所有 overload (13 / 14 參數版本都清掉, 避免 ambiguous)
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT oid::regprocedure::text AS sig
      FROM pg_proc WHERE proname = 'rpc_upsert_campaign'
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.sig;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_campaign(
  p_id               BIGINT,
  p_campaign_no      TEXT,
  p_name             TEXT,
  p_description      TEXT        DEFAULT NULL,
  p_cover_image_url  TEXT        DEFAULT NULL,
  p_status           TEXT        DEFAULT 'draft',
  p_close_type       TEXT        DEFAULT 'regular',
  p_start_at         TIMESTAMPTZ DEFAULT NULL,
  p_end_at           TIMESTAMPTZ DEFAULT NULL,
  p_pickup_deadline  DATE        DEFAULT NULL,
  p_pickup_days      INTEGER     DEFAULT NULL,
  p_total_cap_qty    NUMERIC     DEFAULT NULL,
  p_notes            TEXT        DEFAULT NULL,
  p_is_for_shop      BOOLEAN     DEFAULT TRUE
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO group_buy_campaigns (
      tenant_id, campaign_no, name, description, cover_image_url,
      status, close_type, start_at, end_at, pickup_deadline, pickup_days,
      total_cap_qty, notes, is_for_shop, created_by, updated_by
    ) VALUES (
      v_tenant, p_campaign_no, p_name, p_description, p_cover_image_url,
      COALESCE(p_status,'draft'), COALESCE(p_close_type,'regular'),
      p_start_at, p_end_at, p_pickup_deadline, p_pickup_days,
      p_total_cap_qty, p_notes, COALESCE(p_is_for_shop, TRUE),
      auth.uid(), auth.uid()
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE group_buy_campaigns SET
      campaign_no = COALESCE(p_campaign_no, campaign_no),
      name = COALESCE(p_name, name),
      description = p_description,
      cover_image_url = p_cover_image_url,
      status = COALESCE(p_status, status),
      close_type = COALESCE(p_close_type, close_type),
      start_at = p_start_at,
      end_at = p_end_at,
      pickup_deadline = p_pickup_deadline,
      pickup_days = p_pickup_days,
      total_cap_qty = p_total_cap_qty,
      notes = p_notes,
      is_for_shop = COALESCE(p_is_for_shop, is_for_shop),
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign TO authenticated;

-- ============================================================================
-- 開團「美食列車」類別
--   group_buy_campaigns 新增 category 欄位 (主題分類, 與 close_type 正交)
--   rpc_upsert_campaign 加 p_category 參數 (COALESCE 維持向後相容)
--
-- 為何不用 DB trigger 觸發推播:
--   1. broadcast 放大效應大 (整 tenant 會員), 在 DB 觸發失敗排查困難
--   2. 避免 pg_net 依賴; admin 端 client-side 觸發更可控
--   3. 失敗時 admin UI 可顯示 toast, 不阻擋儲存
-- ============================================================================

-- ── 1. group_buy_campaigns.category 欄位 ────────────────────────────────────
ALTER TABLE group_buy_campaigns
  ADD COLUMN IF NOT EXISTS category TEXT NULL;

-- CHECK constraint: NULL 或 'food_train' (未來擴充再加新值)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'group_buy_campaigns'::regclass
       AND conname = 'group_buy_campaigns_category_chk'
  ) THEN
    ALTER TABLE group_buy_campaigns
      ADD CONSTRAINT group_buy_campaigns_category_chk
      CHECK (category IS NULL OR category IN ('food_train'));
  END IF;
END $$;

COMMENT ON COLUMN group_buy_campaigns.category IS
  '開團主題分類 (與 close_type 正交); NULL=一般, food_train=美食列車';

-- ── 2. rpc_upsert_campaign 加 p_category 參數 ──────────────────────────────
-- PostgreSQL 加 DEFAULT 參數會形成 overload, 先 DROP 舊 signature 再重建
DROP FUNCTION IF EXISTS public.rpc_upsert_campaign(
  BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ,
  DATE, INTEGER, NUMERIC, TEXT
);

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
  p_category         TEXT        DEFAULT NULL
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
      total_cap_qty, notes, category, created_by, updated_by
    ) VALUES (
      v_tenant, p_campaign_no, p_name, p_description, p_cover_image_url,
      COALESCE(p_status,'draft'), COALESCE(p_close_type,'regular'),
      p_start_at, p_end_at, p_pickup_deadline, p_pickup_days,
      p_total_cap_qty, p_notes, p_category, auth.uid(), auth.uid()
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
      category = COALESCE(p_category, category),  -- 不傳則維持原值, 顯式清回 NULL 不支援
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign TO authenticated;

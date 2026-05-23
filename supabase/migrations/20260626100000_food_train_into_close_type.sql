-- ============================================================================
-- 美食列車從獨立 category 欄位改成 close_type 第 4 值
--
-- 為何另開 migration:
--   #340 把 category 欄位 + 14 參數 rpc_upsert_campaign 已 merge 進 main 並
--   apply 到 prod。實際使用後決定不另闢類別維度，直接放進收單類型下拉
--   (regular / fast / limited / food_train)。本 migration 收斂:
--     1. close_type CHECK 放寬含 'food_train'
--     2. 把 category='food_train' 的既有開團搬到 close_type='food_train'
--     3. DROP category 欄位 + group_buy_campaigns_category_chk constraint
--     4. rpc_upsert_campaign 收回 13 參數 (移除 p_category)
--   全 idempotent: 對「prod 已套舊版」或「乾淨環境」皆安全。
-- ============================================================================

-- ── 1. close_type CHECK 放寬, 含 'food_train' ──────────────────────────────
ALTER TABLE group_buy_campaigns
  DROP CONSTRAINT IF EXISTS group_buy_campaigns_close_type_check;

ALTER TABLE group_buy_campaigns
  ADD CONSTRAINT group_buy_campaigns_close_type_check
  CHECK (close_type IN ('regular','fast','limited','food_train'));

COMMENT ON COLUMN group_buy_campaigns.close_type IS
  '開團類型: regular=常規, fast=快團(強制 end_at), limited=限量, food_train=美食列車(專區)';

-- ── 2. 把短暫存在的 category='food_train' 搬到 close_type ──────────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'group_buy_campaigns' AND column_name = 'category'
  ) THEN
    UPDATE group_buy_campaigns
       SET close_type = 'food_train'
     WHERE category = 'food_train' AND close_type != 'food_train';
  END IF;
END $$;

-- ── 3. DROP category 欄位 + CHECK constraint ───────────────────────────────
ALTER TABLE group_buy_campaigns
  DROP CONSTRAINT IF EXISTS group_buy_campaigns_category_chk;

ALTER TABLE group_buy_campaigns
  DROP COLUMN IF EXISTS category;

-- ── 4. rpc_upsert_campaign 收回 13 參數 (拿掉 p_category) ──────────────────
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
  p_notes            TEXT        DEFAULT NULL
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
      total_cap_qty, notes, created_by, updated_by
    ) VALUES (
      v_tenant, p_campaign_no, p_name, p_description, p_cover_image_url,
      COALESCE(p_status,'draft'), COALESCE(p_close_type,'regular'),
      p_start_at, p_end_at, p_pickup_deadline, p_pickup_days,
      p_total_cap_qty, p_notes, auth.uid(), auth.uid()
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
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign TO authenticated;

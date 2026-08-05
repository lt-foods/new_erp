-- ============================================================================
-- 商品（團購活動）瀏覽次數
--
-- 動機：店家想知道「這個商品有多少人看過」——沒下單的流量目前完全看不到，
-- 只能從訂單數反推，等於把「沒人看到」跟「看到但沒買」混成同一件事。
--
-- 資料形狀：每個 (campaign, member) 一列，累加 view_count。
--   → 總瀏覽次數 = SUM(view_count)、不重複瀏覽人數 = COUNT(*)，兩個都拿得到，
--     而且列數上限是 會員數 × 團數（不會像逐筆 event log 那樣無限長）。
--
-- 刻意 **不** 在 group_buy_campaigns 上放 view_count 計數欄：那張表有
-- trg_touch_gbc（BEFORE UPDATE 更新 updated_at），每次瀏覽都會把「更新時間」
-- 洗掉，管理頁的「更新」欄會變成無意義的瀏覽時間，開團列也會被瀏覽流量狂寫。
--
-- 寫入路徑：liff-api 的 `track_campaign_view` action（service role）→
--   rpc_track_campaign_view。會員端沒有 supabase auth JWT，一律走 edge function。
-- ============================================================================

CREATE TABLE IF NOT EXISTS campaign_views (
  id              BIGSERIAL   PRIMARY KEY,
  tenant_id       UUID        NOT NULL,
  campaign_id     BIGINT      NOT NULL REFERENCES group_buy_campaigns(id) ON DELETE CASCADE,
  member_id       BIGINT      NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  view_count      INT         NOT NULL DEFAULT 1,
  first_viewed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_viewed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, campaign_id, member_id)
);

-- 「這個團被誰看過幾次」：UNIQUE 的 (tenant_id, campaign_id, ...) 前綴就夠用。
-- 另外補一條給「這個會員最近看過什麼」（之後做瀏覽紀錄 / 推薦時會用到）。
CREATE INDEX IF NOT EXISTS idx_campaign_views_member_recent
  ON campaign_views (tenant_id, member_id, last_viewed_at DESC);

COMMENT ON TABLE  campaign_views                 IS '商品（團購活動）瀏覽次數，每個 (活動, 會員) 一列';
COMMENT ON COLUMN campaign_views.view_count      IS '該會員看這個團的次數（同一會員 N 分鐘內重複開只算一次，見 rpc_track_campaign_view）';
COMMENT ON COLUMN campaign_views.last_viewed_at  IS '最後一次瀏覽時間，也是去重視窗的判斷依據';

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- 寫入只走 service role（liff-api）與 SECURITY DEFINER RPC，故不開 write policy。
-- 讀取比照 auth_read_group_buy_campaigns：同租戶的後台使用者都看得到。
ALTER TABLE campaign_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auth_read_campaign_views ON campaign_views;
CREATE POLICY auth_read_campaign_views ON campaign_views
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

-- ── 記一次瀏覽 ───────────────────────────────────────────────────────────────
-- 去重視窗：同一會員在 p_dedupe_minutes 內重複打開同一個商品只算一次
-- （下拉重整 / 返回列表再點進來會重跑 useEffect，不去重的話數字會膨脹到沒有
--  參考價值）。回傳更新後的總計，前端可以直接顯示、不用再查一次。
CREATE OR REPLACE FUNCTION public.rpc_track_campaign_view(
  p_tenant          UUID,
  p_campaign_id     BIGINT,
  p_member_id       BIGINT,
  p_dedupe_minutes  INT DEFAULT 30
)
RETURNS TABLE (view_count BIGINT, viewer_count BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_tenant TEXT := auth.jwt() ->> 'tenant_id';
BEGIN
  -- service role（liff-api）沒有 tenant_id claim → 跳過；後台使用者只能動自己的租戶
  IF v_jwt_tenant IS NOT NULL AND v_jwt_tenant::UUID <> p_tenant THEN
    RAISE EXCEPTION 'tenant mismatch';
  END IF;
  IF p_campaign_id IS NULL OR p_member_id IS NULL THEN
    RAISE EXCEPTION 'campaign_id and member_id are required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_buy_campaigns c
     WHERE c.id = p_campaign_id AND c.tenant_id = p_tenant
  ) THEN
    RAISE EXCEPTION 'campaign not found';
  END IF;

  INSERT INTO campaign_views AS cv (tenant_id, campaign_id, member_id)
  VALUES (p_tenant, p_campaign_id, p_member_id)
  ON CONFLICT (tenant_id, campaign_id, member_id) DO UPDATE
     SET view_count = cv.view_count + CASE
           WHEN cv.last_viewed_at
                < NOW() - make_interval(mins => GREATEST(COALESCE(p_dedupe_minutes, 30), 0))
           THEN 1 ELSE 0 END,
         last_viewed_at = NOW();

  RETURN QUERY
  SELECT COALESCE(SUM(cv.view_count), 0)::BIGINT,
         COUNT(*)::BIGINT
    FROM campaign_views cv
   WHERE cv.tenant_id = p_tenant
     AND cv.campaign_id = p_campaign_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_track_campaign_view(UUID, BIGINT, BIGINT, INT)
  IS '記一次商品瀏覽（同會員同商品 N 分鐘內去重），回傳該商品的總瀏覽次數與不重複人數';

-- ── 讀計數 ───────────────────────────────────────────────────────────────────
-- 用 SQL 聚合而不是把列撈回前端 count：PostgREST 單次最多 1000 列，
-- 瀏覽列數會超過（本專案已為此踩過雷，見 rpc_member_campaign_order_counts）。
-- p_tenant 省略時取 JWT 的 tenant_id（後台呼叫）；liff-api 走 service role
-- 沒有 claim，一定要帶。
CREATE OR REPLACE FUNCTION public.rpc_campaign_view_counts(
  p_campaign_ids BIGINT[] DEFAULT NULL,
  p_tenant       UUID DEFAULT NULL
)
RETURNS TABLE (campaign_id BIGINT, view_count BIGINT, viewer_count BIGINT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_tenant TEXT := auth.jwt() ->> 'tenant_id';
  v_tenant     UUID := COALESCE(p_tenant, NULLIF(v_jwt_tenant, '')::UUID);
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;
  IF v_jwt_tenant IS NOT NULL AND v_jwt_tenant::UUID <> v_tenant THEN
    RAISE EXCEPTION 'tenant mismatch';
  END IF;

  RETURN QUERY
  SELECT cv.campaign_id,
         SUM(cv.view_count)::BIGINT AS view_count,
         COUNT(*)::BIGINT           AS viewer_count
    FROM campaign_views cv
   WHERE cv.tenant_id = v_tenant
     AND (p_campaign_ids IS NULL OR cv.campaign_id = ANY (p_campaign_ids))
   GROUP BY cv.campaign_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_campaign_view_counts(BIGINT[], UUID)
  IS '每個商品（團購活動）的總瀏覽次數與不重複瀏覽人數；p_campaign_ids 省略 = 全租戶';

GRANT EXECUTE ON FUNCTION public.rpc_track_campaign_view(UUID, BIGINT, BIGINT, INT)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_campaign_view_counts(BIGINT[], UUID)
  TO authenticated, service_role;

-- ============================================================================
-- 現貨專區（mutual_aid_board 的 offer 貼文）瀏覽次數
--
-- 跟 20260805000000_campaign_views 同一套做法，只是掛在另一種商品上：
-- 商城的團購商品 → campaign_views；現貨專區的商品 → spot_views。
-- 兩邊資料表不同（group_buy_campaigns / mutual_aid_board），FK 各自掛好才有
-- ON DELETE CASCADE，所以不合併成一張 (entity_type, entity_id) 的泛用表。
--
-- 寫入路徑：liff-api 的 `track_spot_view` action（service role）→
--   rpc_track_spot_view。
-- ============================================================================

CREATE TABLE IF NOT EXISTS spot_views (
  id              BIGSERIAL   PRIMARY KEY,
  tenant_id       UUID        NOT NULL,
  board_id        BIGINT      NOT NULL REFERENCES mutual_aid_board(id) ON DELETE CASCADE,
  member_id       BIGINT      NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  view_count      INT         NOT NULL DEFAULT 1,
  first_viewed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_viewed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, board_id, member_id)
);

CREATE INDEX IF NOT EXISTS idx_spot_views_member_recent
  ON spot_views (tenant_id, member_id, last_viewed_at DESC);

COMMENT ON TABLE  spot_views                IS '現貨專區商品瀏覽次數，每個 (貼文, 會員) 一列';
COMMENT ON COLUMN spot_views.board_id       IS 'mutual_aid_board.id（post_type=offer 的現貨貼文）';
COMMENT ON COLUMN spot_views.view_count     IS '該會員看這個現貨的次數（同一會員 N 分鐘內重複開只算一次）';
COMMENT ON COLUMN spot_views.last_viewed_at IS '最後一次瀏覽時間，也是去重視窗的判斷依據';

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- 寫入只走 service role（liff-api）與 SECURITY DEFINER RPC，故不開 write policy。
ALTER TABLE spot_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auth_read_spot_views ON spot_views;
CREATE POLICY auth_read_spot_views ON spot_views
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

-- ── 記一次瀏覽 ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_track_spot_view(
  p_tenant          UUID,
  p_board_id        BIGINT,
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
  IF v_jwt_tenant IS NOT NULL AND v_jwt_tenant::UUID <> p_tenant THEN
    RAISE EXCEPTION 'tenant mismatch';
  END IF;
  IF p_board_id IS NULL OR p_member_id IS NULL THEN
    RAISE EXCEPTION 'board_id and member_id are required';
  END IF;
  -- 只認現貨貼文（offer）；認領貼文 / 別租戶的 id 一律擋掉
  IF NOT EXISTS (
    SELECT 1 FROM mutual_aid_board b
     WHERE b.id = p_board_id
       AND b.tenant_id = p_tenant
       AND b.post_type = 'offer'
  ) THEN
    RAISE EXCEPTION 'spot product not found';
  END IF;

  INSERT INTO spot_views AS sv (tenant_id, board_id, member_id)
  VALUES (p_tenant, p_board_id, p_member_id)
  ON CONFLICT (tenant_id, board_id, member_id) DO UPDATE
     SET view_count = sv.view_count + CASE
           WHEN sv.last_viewed_at
                < NOW() - make_interval(mins => GREATEST(COALESCE(p_dedupe_minutes, 30), 0))
           THEN 1 ELSE 0 END,
         last_viewed_at = NOW();

  RETURN QUERY
  SELECT COALESCE(SUM(sv.view_count), 0)::BIGINT,
         COUNT(*)::BIGINT
    FROM spot_views sv
   WHERE sv.tenant_id = p_tenant
     AND sv.board_id = p_board_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_track_spot_view(UUID, BIGINT, BIGINT, INT)
  IS '記一次現貨商品瀏覽（同會員同商品 N 分鐘內去重），回傳總瀏覽次數與不重複人數';

-- ── 讀計數 ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_spot_view_counts(
  p_board_ids BIGINT[] DEFAULT NULL,
  p_tenant    UUID DEFAULT NULL
)
RETURNS TABLE (board_id BIGINT, view_count BIGINT, viewer_count BIGINT)
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
  SELECT sv.board_id,
         SUM(sv.view_count)::BIGINT AS view_count,
         COUNT(*)::BIGINT           AS viewer_count
    FROM spot_views sv
   WHERE sv.tenant_id = v_tenant
     AND (p_board_ids IS NULL OR sv.board_id = ANY (p_board_ids))
   GROUP BY sv.board_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_spot_view_counts(BIGINT[], UUID)
  IS '每個現貨商品的總瀏覽次數與不重複瀏覽人數；p_board_ids 省略 = 全租戶';

GRANT EXECUTE ON FUNCTION public.rpc_track_spot_view(UUID, BIGINT, BIGINT, INT)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_spot_view_counts(BIGINT[], UUID)
  TO authenticated, service_role;

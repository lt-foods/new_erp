-- ============================================================================
-- 廠商網站清單（Alex 2026-11-08：「有頁面清單可以編輯廠商帳密嗎」）
--
-- 廠商網站爬蟲（tools/vendor-scraper）的廠商清單原本在 repo 的 vendors.json、帳密在本機 .env，
-- 加一家或改密碼都要改檔案。改成資料庫一張表 + 後台頁（/community-candidates/vendor-sites），
-- 爬蟲由 scripts/vendor-sites-run.mjs 從這張表讀清單去跑。
--
-- 密碼是廠商網站的會員密碼（不是本系統的），老闆 11/8 決定直接存、靠權限擋：
--   - 讀：RLS 只開給 owner / admin / ''（legacy admin），店長與總倉其他角色連列都看不到
--   - 寫：只走 rpc_upsert_vendor_site（同一組角色）；p_password 給 NULL = 不改、'' = 清掉
--   - 爬蟲用 Management API（postgres）讀，繞過 RLS
-- 第一批 17 家由 scripts/vendor-sites-seed.mjs 從 vendors.json + .env 灌進去（密碼不進 git，所以不寫在這支）。
--
-- rollback：DROP FUNCTION public.rpc_upsert_vendor_site(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT[], TEXT, TEXT, BOOLEAN, TEXT),
--   public.rpc_vendor_site_mark_scraped(BIGINT, INT, TEXT); DROP TABLE public.vendor_sites;
--   （爬蟲退回 vendors.json + .env：tools/vendor-scraper/README.md）
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.vendor_sites (
  id               BIGSERIAL PRIMARY KEY,
  tenant_id        UUID        NOT NULL,
  key              TEXT        NOT NULL CHECK (key ~ '^[a-z0-9_-]{1,40}$'),
  name             TEXT        NOT NULL,
  supplier_id      BIGINT      REFERENCES public.suppliers(id) ON DELETE SET NULL,
  platform         TEXT        NOT NULL DEFAULT 'shop2000' CHECK (platform IN ('shop2000')),
  urls             TEXT[]      NOT NULL DEFAULT '{}',
  email            TEXT,
  password         TEXT,
  is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
  notes            TEXT,
  last_scraped_at  TIMESTAMPTZ,
  last_count       INT,
  last_error       TEXT,
  created_by       UUID,
  updated_by       UUID,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, key)
);
COMMENT ON TABLE public.vendor_sites IS
  '廠商網站爬蟲的廠商清單（20261108000000）：平台、網址、會員帳密。key = 爬蟲用的代號（line_post_id 的 web:<key>:<psn>），'
  '改了會讓同一個商品變成新貼文、重新解析，所以建立後不給改。';

DROP TRIGGER IF EXISTS trg_vendor_sites_touch ON public.vendor_sites;
CREATE TRIGGER trg_vendor_sites_touch BEFORE UPDATE ON public.vendor_sites
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE public.vendor_sites ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vendor_sites_admin_read ON public.vendor_sites;
CREATE POLICY vendor_sites_admin_read ON public.vendor_sites FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', ''));
REVOKE ALL ON public.vendor_sites FROM PUBLIC, anon;
GRANT SELECT ON public.vendor_sites TO authenticated;
GRANT USAGE ON SEQUENCE public.vendor_sites_id_seq TO authenticated;

-- 新增 / 修改（key 建立後不能改；密碼 NULL = 不動、'' = 清掉）
CREATE OR REPLACE FUNCTION public.rpc_upsert_vendor_site(
  p_id BIGINT, p_key TEXT, p_name TEXT, p_supplier_id BIGINT, p_platform TEXT, p_urls TEXT[],
  p_email TEXT, p_password TEXT, p_is_active BOOLEAN DEFAULT TRUE, p_notes TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_urls   TEXT[];
  v_id     BIGINT;
BEGIN
  IF v_tenant IS NULL OR v_role NOT IN ('owner', 'admin', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  IF COALESCE(btrim(p_name), '') = '' THEN RAISE EXCEPTION '名稱必填'; END IF;
  -- 網址：去空白、去重、至少一個
  v_urls := ARRAY(SELECT DISTINCT btrim(u) FROM unnest(COALESCE(p_urls, '{}')) u WHERE btrim(u) <> '');
  IF cardinality(v_urls) = 0 THEN RAISE EXCEPTION '至少要一個網址'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_urls) u WHERE u !~ '^https?://') THEN RAISE EXCEPTION '網址要以 http:// 或 https:// 開頭'; END IF;

  IF p_id IS NULL THEN
    IF p_key IS NULL OR p_key !~ '^[a-z0-9_-]{1,40}$' THEN RAISE EXCEPTION '代號只能是小寫英數、底線、減號'; END IF;
    INSERT INTO vendor_sites (tenant_id, key, name, supplier_id, platform, urls, email, password, is_active, notes, created_by, updated_by)
    VALUES (v_tenant, p_key, btrim(p_name), p_supplier_id, COALESCE(p_platform, 'shop2000'), v_urls,
            NULLIF(btrim(p_email), ''), NULLIF(p_password, ''), COALESCE(p_is_active, TRUE), NULLIF(btrim(p_notes), ''),
            auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE vendor_sites v
       SET name = btrim(p_name), supplier_id = p_supplier_id, platform = COALESCE(p_platform, v.platform), urls = v_urls,
           email = NULLIF(btrim(p_email), ''),
           password = CASE WHEN p_password IS NULL THEN v.password ELSE NULLIF(p_password, '') END,
           is_active = COALESCE(p_is_active, v.is_active), notes = NULLIF(btrim(p_notes), ''), updated_by = auth.uid()
     WHERE v.id = p_id AND v.tenant_id = v_tenant
    RETURNING v.id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'vendor_site % not found', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_upsert_vendor_site(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT[], TEXT, TEXT, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_upsert_vendor_site(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT[], TEXT, TEXT, BOOLEAN, TEXT) TO authenticated;

-- 爬蟲跑完回寫（scripts/vendor-sites-run.mjs，走 Management API）
CREATE OR REPLACE FUNCTION public.rpc_vendor_site_mark_scraped(p_id BIGINT, p_count INT, p_error TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  UPDATE vendor_sites
     SET last_scraped_at = now(), last_count = p_count, last_error = LEFT(p_error, 500)
   WHERE id = p_id;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_vendor_site_mark_scraped(BIGINT, INT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_vendor_site_mark_scraped(BIGINT, INT, TEXT) TO service_role;

-- ============================================================
-- 2026-08-18: 候選池「來源 → 品牌」對應（B-3）
--
-- 要解決什麼：
--   老闆要在候選池把「漂漂館」跟「找貨群」分開看。唯一能分辨來源的欄位是
--   community_product_candidates.source_channel（Bot 送進來的 payload.channel）。
--
-- ⚠️⚠️ 為什麼「不能用字串比對群名」（這是本檔存在的理由）：
--   Bot 那半（另一個 PR）回報的實際行為 —— source_channel 存的值有四種可能：
--     ① 群組：LINE API 查到的群名；查失敗時退而帶原始 groupId（C 開頭那串）
--        而且失敗會記 10 分鐘負快取 → 那 10 分鐘內同一個群進來的候選
--        source_channel 全部是 groupId、不是群名
--     ② 1:1：使用者暱稱；查失敗時帶 userId
--     ③ 多人聊天室：roomId（LINE 本來就沒有名稱可查）
--     ④ 來源缺漏：'unknown'
--   → 同一個群在不同時間會用「兩個不同字串」出現。
--     若用 source_channel ILIKE '%漂漂館%' 篩，查名失敗那批會被靜默歸到「找貨群」，
--     老闆只會覺得「有幾筆漂漂館的商品不見了」，完全看不出原因。
--
-- 做法：把「哪些 source_channel 屬於哪個品牌」做成一張可設定的對應表。
--   - 同一個群的「群名」與「groupId」各建一列、都指到漂漂館 → 歸同一邊（需求 1）
--   - ⛔ 群名／groupId 一律不寫死在程式碼裡，全部是資料，老闆在畫面上按一下就能設（需求 2）
--   - 沒對應到的（含既有 2495 筆 source_channel IS NULL）→ source_brand_id 為 NULL
--     ＝「找貨群」，⛔ 永遠不會被誤歸到漂漂館；「全部」也一筆都不會少（需求 3）
--   - 對應的是 brand_id 而不是寫死漂漂館 → 以後多一個子品牌群不用再改 schema
--
-- ⭐ 一個關鍵的安全設計：
--   同一張對應表同時餵給「畫面上的來源篩選」與「一鍵開團要標哪個品牌」，
--   兩者不可能各自解讀、不可能對不起來。
--
-- ⚠️ 仍然存在、且刻意留給老闆看見的缺口：
--   一個「還沒被對應過的新字串」第一次出現時，它會落在「找貨群」。
--   這無法自動解決（系統沒有別的線索知道那串 groupId 是哪個群），
--   所以 rpc_community_channel_summary 會把「未對應的來源」列出來，
--   前端顯示未對應筆數，讓它是「看得見的待辦」而不是「靜默的錯誤」。
--
-- Scope：新增 1 張表 + 1 個 view + 2 支 RPC。
--   ⛔ 不動 community_product_candidates 的任何欄位、不動任何既有函式、不改任何既有資料。
--
-- Rollback：
--   DROP FUNCTION IF EXISTS public.rpc_community_channel_summary();
--   DROP FUNCTION IF EXISTS public.rpc_set_community_channel_brand(TEXT, BIGINT);
--   DROP VIEW  IF EXISTS public.v_community_product_candidates;
--   DROP TABLE IF EXISTS public.community_channel_brands;
--   （前端要同時回退到直接讀 community_product_candidates）
-- ============================================================

-- ------------------------------------------------------------
-- 1. 對應表
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS community_channel_brands (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID   NOT NULL,
  source_channel TEXT   NOT NULL,
  brand_id       BIGINT NOT NULL REFERENCES brands(id),

  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- ⭐ 一個 source_channel 只能對到一個品牌。
  --    這個約束就是 v_community_product_candidates 不會把候選列複製成多筆的保證。
  UNIQUE (tenant_id, source_channel)
);

COMMENT ON TABLE community_channel_brands IS
  '(2026-08-18) 候選池來源 → 品牌對應。source_channel 可能是群名 / groupId / 暱稱 / userId / roomId / ''unknown''，'
  '同一個群的多個字串各建一列指到同一個品牌即可。沒對應到的一律視為「找貨群」（不標品牌）。';
COMMENT ON COLUMN community_channel_brands.source_channel IS
  '與 community_product_candidates.source_channel 逐字比對（區分大小寫、不做模糊比對）';

CREATE TRIGGER trg_touch_community_channel_brands
  BEFORE UPDATE ON community_channel_brands
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- 候選池那側的 join / GROUP BY 走這個索引（表會一直長大）
CREATE INDEX IF NOT EXISTS idx_ccp_source_channel
  ON community_product_candidates (tenant_id, source_channel);

-- ------------------------------------------------------------
-- 2. RLS —— 逐字沿用 community_product_candidates 的 ccp_hq_all
--    （同一批人看得到候選池、就同一批人能設定來源歸屬）
-- ------------------------------------------------------------
ALTER TABLE community_channel_brands ENABLE ROW LEVEL SECURITY;

CREATE POLICY ccb_hq_all
  ON community_channel_brands
  FOR ALL
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND COALESCE((SELECT auth.jwt() -> 'app_metadata' ->> 'role'), '')
        = ANY (ARRAY['owner','admin','hq_manager','assistant',''])
  )
  WITH CHECK (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND COALESCE((SELECT auth.jwt() -> 'app_metadata' ->> 'role'), '')
        = ANY (ARRAY['owner','admin','hq_manager','assistant',''])
  );

-- 寫入一律走下面的 RPC（SECURITY DEFINER），這裡只開讀
GRANT SELECT ON community_channel_brands TO authenticated;

-- ------------------------------------------------------------
-- 3. View：候選池 + 來源品牌
--
--    security_invoker = true → RLS 套用呼叫者，與 v_admin_member_list
--    （20260701020000）同慣例。⛔ 少了它就是拿 view owner 的權限讀，會跨租戶外洩。
--
--    LEFT JOIN 兩層都不會增列：
--      - community_channel_brands 有 UNIQUE (tenant_id, source_channel)
--      - brands.id 是 PK
--    → 「全部」的筆數與直接讀 community_product_candidates 完全相同。
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_community_product_candidates
WITH (security_invoker = true) AS
SELECT
  c.*,
  m.brand_id AS source_brand_id,
  b.code     AS source_brand_code,
  b.name     AS source_brand_name
FROM public.community_product_candidates c
LEFT JOIN public.community_channel_brands m
       ON m.tenant_id = c.tenant_id
      AND m.source_channel = c.source_channel
LEFT JOIN public.brands b
       ON b.id = m.brand_id
      AND b.tenant_id = m.tenant_id;

COMMENT ON VIEW public.v_community_product_candidates IS
  '候選池 + 來源所屬品牌。source_brand_id IS NULL ＝ 尚未對應到任何品牌（畫面上的「找貨群」）。'
  '寫入請走 community_product_candidates 本表，本 view 只供讀取與篩選。';

GRANT SELECT ON public.v_community_product_candidates TO authenticated;

-- ------------------------------------------------------------
-- 4. rpc_community_channel_summary
--    列出候選池出現過的所有 source_channel、各自幾筆、目前對到哪個品牌。
--    未對應的（brand_id IS NULL）就是老闆需要處理的待辦。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_community_channel_summary()
RETURNS TABLE (
  source_channel  TEXT,
  candidate_count BIGINT,
  brand_id        BIGINT,
  brand_code      TEXT,
  brand_name      TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot read candidate sources', v_role;
  END IF;

  RETURN QUERY
  -- 候選池裡出現過的來源（source_channel IS NULL 不列：沒有值就無從對應，
  -- 那 2495 筆舊資料本來就落在「找貨群」）
  WITH seen AS (
    SELECT c.source_channel AS ch, COUNT(*)::BIGINT AS cnt
      FROM community_product_candidates c
     WHERE c.tenant_id = v_tenant
       AND c.source_channel IS NOT NULL
     GROUP BY c.source_channel
  ),
  -- 已經設定過、但候選池目前還沒有資料的來源也要列出來（否則設完就消失、無法取消）
  mapped AS (
    SELECT m.source_channel AS ch, 0::BIGINT AS cnt
      FROM community_channel_brands m
     WHERE m.tenant_id = v_tenant
       AND NOT EXISTS (SELECT 1 FROM seen s WHERE s.ch = m.source_channel)
  ),
  all_ch AS (
    SELECT ch, cnt FROM seen
    UNION ALL
    SELECT ch, cnt FROM mapped
  )
  SELECT a.ch, a.cnt, m.brand_id, b.code, b.name
    FROM all_ch a
    LEFT JOIN community_channel_brands m
           ON m.tenant_id = v_tenant AND m.source_channel = a.ch
    LEFT JOIN brands b
           ON b.id = m.brand_id AND b.tenant_id = v_tenant
   ORDER BY (m.brand_id IS NOT NULL), a.cnt DESC, a.ch;  -- 未對應的排最前面
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_community_channel_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_community_channel_summary() TO authenticated;

COMMENT ON FUNCTION public.rpc_community_channel_summary() IS
  '候選池來源清單：每個 source_channel 幾筆候選、目前對到哪個品牌（NULL ＝ 尚未對應）。未對應的排最前面。';

-- ------------------------------------------------------------
-- 5. rpc_set_community_channel_brand
--    設定 / 取消一個來源的品牌歸屬。p_brand_id 傳 NULL ＝ 取消歸屬（回到「找貨群」）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_community_channel_brand(
  p_source_channel TEXT,
  p_brand_id       BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_ch     TEXT := NULLIF(btrim(COALESCE(p_source_channel, '')), '');
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot set candidate source brand', v_role;
  END IF;

  IF v_ch IS NULL THEN
    RAISE EXCEPTION 'source_channel must not be blank';
  END IF;

  IF p_brand_id IS NULL THEN
    DELETE FROM community_channel_brands
     WHERE tenant_id = v_tenant AND source_channel = v_ch;
    RETURN;
  END IF;

  -- 品牌必須在同 tenant（與 rpc_upsert_product 同一道守衛）
  PERFORM 1 FROM brands WHERE id = p_brand_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'brand % not in tenant', p_brand_id;
  END IF;

  INSERT INTO community_channel_brands (
    tenant_id, source_channel, brand_id, created_by, updated_by
  ) VALUES (
    v_tenant, v_ch, p_brand_id, v_user, v_user
  )
  ON CONFLICT (tenant_id, source_channel) DO UPDATE
    SET brand_id   = EXCLUDED.brand_id,
        updated_by = v_user,
        updated_at = NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_set_community_channel_brand(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_set_community_channel_brand(TEXT, BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_set_community_channel_brand(TEXT, BIGINT) IS
  '設定候選池來源歸屬哪個品牌；p_brand_id 傳 NULL ＝ 取消歸屬（回到未對應／找貨群）。'
  '同一個群若出現過群名與 groupId 兩種字串，兩個都設一次即可歸到同一邊。';

-- ============================================================================
-- LINE Login 綁定表 + 註冊 RPC
-- 顧客透過 LINE Login OAuth 綁定 / 註冊會員
-- 對應 PRD-LIFF 前端（改採 LINE Login 而非 LIFF SDK）
-- ============================================================================

-- ── 1. member_line_bindings：會員 ↔ LINE 綁定 ──────────────────────────────
CREATE TABLE IF NOT EXISTS member_line_bindings (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID    NOT NULL,
  store_id        BIGINT  NOT NULL REFERENCES stores(id),
  member_id       BIGINT  NOT NULL REFERENCES members(id),
  line_user_id    TEXT    NOT NULL,               -- LINE sub（同 provider 內跨 channel 不變）
  bound_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  unbound_at      TIMESTAMPTZ,                    -- 解綁 / 封鎖 OA 時填
  created_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- 一 LINE 帳號在同店只能綁一個會員
  UNIQUE (tenant_id, store_id, line_user_id),
  -- 一會員在同店只能綁一個 LINE
  UNIQUE (tenant_id, store_id, member_id)
);

CREATE INDEX IF NOT EXISTS idx_mlb_line_user ON member_line_bindings (tenant_id, line_user_id);
CREATE INDEX IF NOT EXISTS idx_mlb_member    ON member_line_bindings (tenant_id, member_id);

COMMENT ON TABLE  member_line_bindings IS 'LINE Login 顧客與會員綁定（per-store）';
COMMENT ON COLUMN member_line_bindings.line_user_id IS 'LINE id_token 的 sub 欄位';
COMMENT ON COLUMN member_line_bindings.unbound_at   IS '非 NULL = 已解綁（保留紀錄審計）';

-- ── 2. rpc_liff_lookup_by_phone：註冊前查手機，給「確認綁定」畫面用 ────────
CREATE OR REPLACE FUNCTION rpc_liff_lookup_by_phone(
  p_phone TEXT
) RETURNS TABLE (
  member_id       BIGINT,
  member_no       TEXT,
  name_masked     TEXT,
  home_store_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := (auth.jwt() ->> 'tenant_id')::UUID;
  v_hash   TEXT;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'missing tenant in jwt';
  END IF;

  v_hash := encode(digest(p_phone, 'sha256'), 'hex');

  RETURN QUERY
  SELECT m.id,
         m.member_no,
         -- 姓名 masking：王小明 → 王**
         CASE
           WHEN m.name IS NULL OR length(m.name) = 0 THEN NULL
           WHEN length(m.name) <= 1 THEN m.name
           ELSE substr(m.name, 1, 1) || repeat('*', length(m.name) - 1)
         END AS name_masked,
         s.name AS home_store_name
  FROM members m
  LEFT JOIN stores s ON s.id = m.home_store_id
  WHERE m.tenant_id  = v_tenant
    AND m.phone_hash = v_hash
    AND m.status NOT IN ('deleted', 'merged');
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_liff_lookup_by_phone(TEXT) TO authenticated;

-- ── 3. rpc_liff_register_and_bind：主要註冊 + 綁定流程 ────────────────────
-- 呼叫者 JWT 必帶：tenant_id、store_id、line_user_id、role='pending'
-- 流程：
--   a. 查 (tenant, phone_hash) 既有會員
--      - 有 → 綁定（若 store 不同 → 仍允許、一會員多店綁定）
--      - 無 → 建新會員（home_store_id = store_id）
--   b. INSERT member_line_bindings（衝突 → 回傳既有 binding）
--   c. 回傳 { member_id, is_new_member }
CREATE OR REPLACE FUNCTION rpc_liff_register_and_bind(
  p_phone      TEXT,
  p_last_name  TEXT,
  p_birthday   DATE
) RETURNS TABLE (
  member_id      BIGINT,
  is_new_member  BOOLEAN,
  was_bound      BOOLEAN        -- TRUE = 先前已綁（idempotent 呼叫）
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID   := (auth.jwt() ->> 'tenant_id')::UUID;
  v_store_id     BIGINT := (auth.jwt() ->> 'store_id')::BIGINT;
  v_line_user_id TEXT   := (auth.jwt() ->> 'line_user_id')::TEXT;
  v_phone_hash   TEXT;
  v_member_id    BIGINT;
  v_is_new       BOOLEAN := FALSE;
  v_was_bound    BOOLEAN := FALSE;
BEGIN
  IF v_tenant IS NULL OR v_store_id IS NULL OR v_line_user_id IS NULL THEN
    RAISE EXCEPTION 'jwt missing tenant_id/store_id/line_user_id';
  END IF;

  IF p_phone IS NULL OR length(trim(p_phone)) = 0 THEN
    RAISE EXCEPTION 'phone is required';
  END IF;
  IF p_last_name IS NULL OR length(trim(p_last_name)) = 0 THEN
    RAISE EXCEPTION 'last_name is required';
  END IF;
  IF p_birthday IS NULL THEN
    RAISE EXCEPTION 'birthday is required';
  END IF;

  -- 驗 store 屬於 tenant
  PERFORM 1 FROM stores WHERE id = v_store_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'store % not in tenant', v_store_id;
  END IF;

  v_phone_hash := encode(digest(p_phone, 'sha256'), 'hex');

  -- (a) 查既有會員（tenant 範圍，不限 store）
  SELECT id INTO v_member_id
  FROM members
  WHERE tenant_id = v_tenant
    AND phone_hash = v_phone_hash
    AND status NOT IN ('deleted', 'merged')
  LIMIT 1;

  IF v_member_id IS NULL THEN
    -- 建新會員
    INSERT INTO members (
      tenant_id, member_no,
      phone_hash, phone,
      name, birthday, birth_md,
      home_store_id, status,
      joined_at, created_by, updated_by
    ) VALUES (
      v_tenant,
      -- member_no 先用簡易版：M + 時戳 + 隨機（P1 抽成 rpc_gen_member_no）
      'M' || to_char(NOW(), 'YYYYMMDDHH24MISS') || lpad((random()*999)::int::text, 3, '0'),
      v_phone_hash,
      p_phone,
      p_last_name,
      p_birthday,
      to_char(p_birthday, 'MM-DD'),
      v_store_id,
      'active',
      NOW(), NULL, NULL
    )
    RETURNING id INTO v_member_id;
    v_is_new := TRUE;
  END IF;

  -- (b) INSERT binding（UNIQUE 衝突 → 已綁過）
  BEGIN
    INSERT INTO member_line_bindings (
      tenant_id, store_id, member_id, line_user_id
    ) VALUES (
      v_tenant, v_store_id, v_member_id, v_line_user_id
    );
  EXCEPTION WHEN unique_violation THEN
    v_was_bound := TRUE;
  END;

  RETURN QUERY SELECT v_member_id, v_is_new, v_was_bound;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_liff_register_and_bind(TEXT, TEXT, DATE) TO authenticated;

-- ── 4. rpc_liff_unbind：解綁（使用者主動或偵測封鎖 OA）─────────────────────
CREATE OR REPLACE FUNCTION rpc_liff_unbind() RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID   := (auth.jwt() ->> 'tenant_id')::UUID;
  v_store_id     BIGINT := (auth.jwt() ->> 'store_id')::BIGINT;
  v_line_user_id TEXT   := (auth.jwt() ->> 'line_user_id')::TEXT;
BEGIN
  UPDATE member_line_bindings
     SET unbound_at = NOW()
   WHERE tenant_id    = v_tenant
     AND store_id     = v_store_id
     AND line_user_id = v_line_user_id
     AND unbound_at IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_liff_unbind() TO authenticated;

-- ── 5. RLS ─────────────────────────────────────────────────────────────────
ALTER TABLE member_line_bindings ENABLE ROW LEVEL SECURITY;

-- 顧客只能讀自己的 binding
DROP POLICY IF EXISTS mlb_self_read ON member_line_bindings;
CREATE POLICY mlb_self_read ON member_line_bindings
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND member_id = NULLIF(auth.jwt() ->> 'member_id', '')::BIGINT
  );

-- HQ 全權
DROP POLICY IF EXISTS mlb_hq_all ON member_line_bindings;
CREATE POLICY mlb_hq_all ON member_line_bindings
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND (auth.jwt() ->> 'role') = 'hq'
  );

-- 店員讀該店
DROP POLICY IF EXISTS mlb_store_read ON member_line_bindings;
CREATE POLICY mlb_store_read ON member_line_bindings
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND store_id = NULLIF(auth.jwt() ->> 'store_id', '')::BIGINT
    AND (auth.jwt() ->> 'role') IN ('store_manager', 'store_staff')
  );

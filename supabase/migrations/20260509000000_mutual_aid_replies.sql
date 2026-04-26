-- ============================================================
-- Phase 5c step 1 — 互助交流板留言系統 + 純通訊 RPC
--   廢掉原 rpc_claim_aid 自動扣 qty / 自動建 transfer 的設計
--
-- 變動：
--   1. 新表 mutual_aid_replies (append-only thread)
--   2. 新 RPC rpc_post_aid_board   — 用 RPC 包 INSERT + 自動填 tenant/created_by
--   3. 新 RPC rpc_post_aid_reply   — 留言（自動 lookup author_label）
--   4. 新 RPC rpc_close_aid_board  — 手動關貼 (cancelled / exhausted)
--
-- 不動：mutual_aid_board (table)、mutual_aid_claims (table + legacy rpc_claim_aid)
--
-- post_type (offer / request) + source_customer_order_id 在 step 2 補
-- ============================================================

-- ============================================================
-- 1. mutual_aid_replies (append-only thread)
-- ============================================================

CREATE TABLE mutual_aid_replies (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  board_id      BIGINT NOT NULL REFERENCES mutual_aid_board(id) ON DELETE CASCADE,
  author_id     UUID,
  author_label  TEXT,
  body          TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 1000),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_aid_replies_board ON mutual_aid_replies (board_id, created_at);

-- append-only：禁 UPDATE / DELETE
CREATE TRIGGER trg_no_mut_aid_replies BEFORE UPDATE OR DELETE ON mutual_aid_replies
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();

COMMENT ON TABLE mutual_aid_replies IS
  '互助板留言 thread（append-only）；author_label 為 staff 顯示名 snapshot';

-- ============================================================
-- 2. rpc_post_aid_board(...)
-- ============================================================
-- 把 INSERT 包成 RPC：自動帶 tenant_id (從 store)、created_by/updated_by、qty_remaining=qty_available
-- 不直接讓 UI INSERT 是因為 tenant_id 計算 + qty_remaining 同步比較髒

CREATE OR REPLACE FUNCTION rpc_post_aid_board(
  p_offering_store_id BIGINT,
  p_sku_id            BIGINT,
  p_qty_available     NUMERIC,
  p_expires_at        TIMESTAMPTZ,
  p_note              TEXT,
  p_operator          UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id  UUID;
  v_board_id   BIGINT;
BEGIN
  IF p_qty_available IS NULL OR p_qty_available <= 0 THEN
    RAISE EXCEPTION 'qty_available must be > 0';
  END IF;
  IF p_expires_at IS NULL OR p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'expires_at must be in the future';
  END IF;

  SELECT tenant_id INTO v_tenant_id FROM stores WHERE id = p_offering_store_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'offering_store % not found', p_offering_store_id;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM skus WHERE id = p_sku_id) THEN
    RAISE EXCEPTION 'sku % not found', p_sku_id;
  END IF;

  INSERT INTO mutual_aid_board (
    tenant_id, offering_store_id, sku_id, qty_available, qty_remaining,
    expires_at, note, status, created_by, updated_by
  ) VALUES (
    v_tenant_id, p_offering_store_id, p_sku_id, p_qty_available, p_qty_available,
    p_expires_at, NULLIF(trim(p_note), ''), 'active', p_operator, p_operator
  )
  RETURNING id INTO v_board_id;

  RETURN v_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_post_aid_board(BIGINT, BIGINT, NUMERIC, TIMESTAMPTZ, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_post_aid_board IS
  'Phase 5c step 1：發起互助貼文（純通訊版）；qty_remaining = qty_available、不做扣量';

-- ============================================================
-- 3. rpc_post_aid_reply(...)
-- ============================================================
-- 對 board 留言、自動 lookup author_label (從 auth.users)

CREATE OR REPLACE FUNCTION rpc_post_aid_reply(
  p_board_id BIGINT,
  p_body     TEXT,
  p_operator UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_tenant_id    UUID;
  v_author_label TEXT;
  v_reply_id     BIGINT;
BEGIN
  IF p_body IS NULL OR length(trim(p_body)) = 0 THEN
    RAISE EXCEPTION 'body cannot be empty';
  END IF;
  IF length(p_body) > 1000 THEN
    RAISE EXCEPTION 'body too long (max 1000)';
  END IF;

  SELECT tenant_id INTO v_tenant_id FROM mutual_aid_board WHERE id = p_board_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'board % not found', p_board_id;
  END IF;

  -- 取 author display name；找不到 fallback 到 uid 前綴
  SELECT COALESCE(
           NULLIF(u.raw_user_meta_data ->> 'display_name', ''),
           NULLIF(u.raw_user_meta_data ->> 'name', ''),
           split_part(u.email, '@', 1),
           substring(p_operator::text, 1, 8)
         )
    INTO v_author_label
    FROM auth.users u
   WHERE u.id = p_operator;

  IF v_author_label IS NULL THEN
    v_author_label := COALESCE('用戶' || substring(p_operator::text, 1, 8), '匿名');
  END IF;

  INSERT INTO mutual_aid_replies (
    tenant_id, board_id, author_id, author_label, body
  ) VALUES (
    v_tenant_id, p_board_id, p_operator, v_author_label, trim(p_body)
  )
  RETURNING id INTO v_reply_id;

  RETURN v_reply_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_post_aid_reply(BIGINT, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_post_aid_reply IS
  'Phase 5c：對互助貼文留言；author_label snapshot from auth.users';

-- ============================================================
-- 4. rpc_close_aid_board(...)
-- ============================================================
-- 手動關貼。狀態只能 cancelled (作廢) / exhausted (清完了)；不再 RPC 自動扣量

CREATE OR REPLACE FUNCTION rpc_close_aid_board(
  p_board_id BIGINT,
  p_status   TEXT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_status NOT IN ('cancelled', 'exhausted') THEN
    RAISE EXCEPTION 'p_status must be cancelled or exhausted';
  END IF;

  UPDATE mutual_aid_board
     SET status = p_status,
         updated_by = p_operator
   WHERE id = p_board_id
     AND status = 'active';

  IF NOT FOUND THEN
    -- already closed or not exist；idempotent
    IF NOT EXISTS (SELECT 1 FROM mutual_aid_board WHERE id = p_board_id) THEN
      RAISE EXCEPTION 'board % not found', p_board_id;
    END IF;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_close_aid_board(BIGINT, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_close_aid_board IS
  'Phase 5c：手動關掉互助貼文（status active → cancelled / exhausted）';

-- ============================================================
-- 5. RLS for mutual_aid_replies
-- ============================================================

ALTER TABLE mutual_aid_replies ENABLE ROW LEVEL SECURITY;

-- 全 tenant 內 staff 可讀（純通訊板、不做隱私限制）
CREATE POLICY replies_read_all ON mutual_aid_replies
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
  );

-- INSERT 走 RPC SECURITY DEFINER，不從 client 直接 INSERT
-- 但 fallback：authenticated 可以對自己 author_id INSERT (避免 RPC 失效時完全 broken)
CREATE POLICY replies_authenticated_insert ON mutual_aid_replies
  FOR INSERT WITH CHECK (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND author_id = auth.uid()
  );

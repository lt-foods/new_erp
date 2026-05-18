-- ============================================================
-- 新增會員：會員編號系統自動產生 + 手機改非必填
--
-- rpc_upsert_member：
--  1) INSERT 未指定 member_no（NULL/空白）→ 沿用 rpc_next_member_no()
--     規則自動產號（M + 6 碼流水），對 UNIQUE(tenant_id, member_no)
--     衝突自動重試（併發保護）。仍接受外部指定編號（匯入等），
--     指定值衝突則明確報錯。
--  2) 手機非必填：移除 phone required 檢查；空白手機正規化為 NULL，
--     phone_hash 僅在有手機時計算。
--  姓名仍為必填。編輯路徑其餘行為不變。
--
-- 註：自帶 rpc_next_member_no()（與 20260613000020 同定義、idempotent），
-- 使本 migration 自足、不依賴 member_import 系列是否已套用。
-- ============================================================

-- 會員編號流水：M + 6 碼，忽略時間戳形式的舊編號（避免 INT 溢位）
CREATE OR REPLACE FUNCTION public.rpc_next_member_no()
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_next   INT;
BEGIN
  SELECT COALESCE(MAX((SUBSTRING(member_no FROM '^M(\d{1,9})$'))::INT), 0) + 1
    INTO v_next
    FROM members
   WHERE tenant_id = v_tenant
     AND member_no ~ '^M\d{1,9}$';
  RETURN 'M' || lpad(v_next::text, 6, '0');
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_next_member_no TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_upsert_member(
  p_id            BIGINT,
  p_member_no     TEXT,
  p_phone         TEXT,
  p_name          TEXT,
  p_gender        TEXT DEFAULT NULL,
  p_birthday      DATE DEFAULT NULL,
  p_email         TEXT DEFAULT NULL,
  p_tier_id       BIGINT DEFAULT NULL,
  p_home_store_id BIGINT DEFAULT NULL,
  p_status        TEXT DEFAULT 'active',
  p_notes         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_id          BIGINT;
  v_phone       TEXT := NULLIF(btrim(p_phone), '');
  v_phone_hash  TEXT;
  v_email_hash  TEXT;
  v_birth_md    TEXT;
  v_old_store   BIGINT;
  v_open_orders INT;
BEGIN
  IF p_name IS NULL OR p_name = '' THEN
    RAISE EXCEPTION 'name is required';
  END IF;

  v_phone_hash := CASE WHEN v_phone IS NOT NULL
                       THEN encode(digest(v_phone, 'sha256'), 'hex')
                  END;
  v_email_hash := CASE WHEN p_email IS NOT NULL AND p_email <> ''
                       THEN encode(digest(lower(p_email), 'sha256'), 'hex')
                  END;
  v_birth_md   := CASE WHEN p_birthday IS NOT NULL
                       THEN to_char(p_birthday, 'MM-DD')
                  END;

  IF p_tier_id IS NOT NULL THEN
    PERFORM 1 FROM member_tiers WHERE id = p_tier_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'tier % not in tenant', p_tier_id; END IF;
  END IF;

  IF p_id IS NULL THEN
    DECLARE
      v_member_no TEXT    := NULLIF(btrim(p_member_no), '');
      v_explicit  BOOLEAN := NULLIF(btrim(p_member_no), '') IS NOT NULL;
      v_try       INT     := 0;
    BEGIN
      LOOP
        IF v_member_no IS NULL THEN
          v_member_no := public.rpc_next_member_no();
        END IF;
        BEGIN
          INSERT INTO members (
            tenant_id, member_no, phone_hash, phone, email_hash, email,
            name, birthday, birth_md, gender, tier_id, home_store_id,
            status, notes, created_by, updated_by
          ) VALUES (
            v_tenant, v_member_no, v_phone_hash, v_phone, v_email_hash, p_email,
            p_name, p_birthday, v_birth_md, p_gender, p_tier_id, p_home_store_id,
            COALESCE(p_status, 'active'), p_notes, auth.uid(), auth.uid()
          ) RETURNING id INTO v_id;
          EXIT;
        EXCEPTION WHEN unique_violation THEN
          IF v_explicit THEN
            RAISE EXCEPTION '會員編號 % 已存在', v_member_no
              USING ERRCODE = 'unique_violation';
          END IF;
          v_try := v_try + 1;
          IF v_try > 10 THEN RAISE; END IF;
          v_member_no := NULL;  -- 重新自動產號重試
        END;
      END LOOP;
    END;
  ELSE
    SELECT home_store_id INTO v_old_store FROM members
     WHERE id = p_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_id; END IF;

    IF v_old_store IS DISTINCT FROM p_home_store_id THEN
      SELECT COUNT(*) INTO v_open_orders FROM customer_orders
       WHERE tenant_id = v_tenant
         AND member_id = p_id
         AND status NOT IN ('completed','cancelled','expired','transferred_out');
      IF v_open_orders > 0 THEN
        RAISE EXCEPTION '會員仍有 % 筆未取貨訂單，請先處理完才能改取貨店', v_open_orders;
      END IF;
    END IF;

    UPDATE members SET
      member_no     = COALESCE(p_member_no, member_no),
      phone_hash    = v_phone_hash,
      phone         = v_phone,
      email_hash    = v_email_hash,
      email         = p_email,
      name          = COALESCE(p_name, name),
      birthday      = p_birthday,
      birth_md      = v_birth_md,
      gender        = p_gender,
      tier_id       = p_tier_id,
      home_store_id = p_home_store_id,
      status        = COALESCE(p_status, status),
      notes         = p_notes,
      updated_by    = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'member % not in tenant', p_id; END IF;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_member TO authenticated;

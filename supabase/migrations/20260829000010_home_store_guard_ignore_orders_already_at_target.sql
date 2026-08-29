-- ============================================================
-- 改取貨店守衛：只擋「還在別家店」的未取貨訂單
--
-- 問題：守衛是「有任何未取貨訂單就擋」，完全不看那些訂單在哪一家店。
--   於是訂單早就下在 B 店、會員預設取貨店卻還停在 A 店時，改成 B 店
--   （＝把設定對齊現況、什麼都不會變動）也一樣被擋掉。
--   實例 M20260810095138853「Julie zhang-中和」：4 張未取貨訂單的
--   pickup_store_id 全部是 45 中和店，home_store_id 卻是 48 三峽店，
--   店員改成中和店被擋 →「儲存失敗：會員仍有 4 筆未取貨訂單」。
--
-- 為什麼放行是安全的：改 home_store_id **不會動到既有訂單**。
--   每張 customer_orders 自己帶 pickup_store_id，兩支 RPC 都只 UPDATE
--   members 一張表。守衛註解寫的「保護既有訂單的取貨地點」在
--   「訂單本來就在目標店」這個情形下無事可保護。
--
-- 而且不放行有實害：admin-line-push 是拿 members.home_store_id 去查
--   store_line_followers 並解 OA token（各加盟店各自的 OA，token 不能共用）。
--   訂單在 B 店、home_store 停在 A 店 = 到貨通知一律走 A 店的 OA 推播，
--   而會員綁的是 B 店 → 這位會員的到貨通知永遠推不出去。
--
-- 改法：母體加 `pickup_store_id IS DISTINCT FROM p_home_store_id`。
--   只剩「訂單還在別家店」時才擋，並在訊息裡點名是哪幾家店。
--   p_home_store_id 為 NULL（未指定）時所有未取貨訂單照擋 —— 清掉
--   home_store 會讓上面那條推播路徑失去目標，維持保守。
--   順帶把 rpc_set_member_home_store 漏掉的 'transferred_out' 補上
--   （20260507000001 只加進 rpc_upsert_member，20260605000012 新建這支時沒跟上；
--    貨已經在新單上，舊單留在原地不該擋改店）。
--
-- 基底版本：
--   rpc_upsert_member          → 20260617000010（自動產號版，線上版）
--   rpc_set_member_home_store  → 20260605000012（建立版，＝線上版）
-- rollback：直接重跑上面兩支 migration。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_set_member_home_store（會員明細頁「取貨店」的儲存鈕）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_member_home_store(
  p_member_id     BIGINT,
  p_home_store_id BIGINT
) RETURNS members
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_old_store   BIGINT;
  v_open_orders INT;
  v_stores      TEXT;
  v_row         members;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;

  IF p_home_store_id IS NOT NULL THEN
    PERFORM 1 FROM stores WHERE id = p_home_store_id AND tenant_id = v_tenant AND is_active = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant or inactive', p_home_store_id; END IF;
  END IF;

  SELECT home_store_id INTO v_old_store FROM members
   WHERE id = p_member_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;

  IF v_old_store IS DISTINCT FROM p_home_store_id THEN
    SELECT COUNT(*), string_agg(DISTINCT COALESCE(s.name, '未指定門市'), '、')
      INTO v_open_orders, v_stores
      FROM customer_orders co
      LEFT JOIN stores s ON s.id = co.pickup_store_id
     WHERE co.tenant_id = v_tenant
       AND co.member_id = p_member_id
       AND co.status NOT IN ('completed','cancelled','expired','transferred_out')
       AND co.pickup_store_id IS DISTINCT FROM p_home_store_id;
    IF v_open_orders > 0 THEN
      RAISE EXCEPTION '會員在「%」還有 % 筆未取貨訂單，請先處理完才能改取貨店', v_stores, v_open_orders;
    END IF;
  END IF;

  UPDATE members
     SET home_store_id = p_home_store_id,
         updated_by    = auth.uid(),
         updated_at    = NOW()
   WHERE id = p_member_id AND tenant_id = v_tenant
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_set_member_home_store(BIGINT, BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_set_member_home_store(BIGINT, BIGINT) IS
  '改會員預設取貨店。守衛只擋「還在別家店」的未取貨訂單 —— 訂單本來就在目標店時放行'
  '（改 home_store 不動既有訂單，且不改會讓到貨通知一直走錯 OA）。基底 20260605000012。';

-- ----------------------------------------------------------------
-- 2. rpc_upsert_member（會員編輯表單，同一套守衛）
-- ----------------------------------------------------------------
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
  v_stores      TEXT;
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
      SELECT COUNT(*), string_agg(DISTINCT COALESCE(s.name, '未指定門市'), '、')
        INTO v_open_orders, v_stores
        FROM customer_orders co
        LEFT JOIN stores s ON s.id = co.pickup_store_id
       WHERE co.tenant_id = v_tenant
         AND co.member_id = p_id
         AND co.status NOT IN ('completed','cancelled','expired','transferred_out')
         AND co.pickup_store_id IS DISTINCT FROM p_home_store_id;
      IF v_open_orders > 0 THEN
        RAISE EXCEPTION '會員在「%」還有 % 筆未取貨訂單，請先處理完才能改取貨店', v_stores, v_open_orders;
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

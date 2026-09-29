-- ============================================================================
-- 20260929020000_line_note_strict_member_match.sql
--
-- LINE 記事本留言加單：找會員改嚴格版 —— 不確定就回錯誤，不猜。
--
-- 盤點（2026-09-29，全站 3,472 則已加單留言）：
--   * 系統 member_no（M+6 碼）跟寫在姓名裡的舊編號**從來不是同一組號碼**：
--     20,251 位有 6 碼 member_no 的活人，姓名帶那組號碼的 0 位。
--     所以「member_no 直接命中」這一步每次命中都是錯的人（53 則 / 27 位留言者，
--     含 20260929010000 改順序後仍會退用到的 sophia031037 那種：本尊已被合併、
--     只剩 member_no 撞到別人）。整步拿掉。
--   * 撞號時拿「社群綁的店」挑人是猜的：同店也會撞（例：512668 兩位都在三峽，
--     挑到姓名寫著「不入單」的那位）。拿掉；只留「留言者暱稱／留言裡寫到的店名」
--     這一道，而且要剛好對到一位才算，否則回錯誤請店員指定。
--   * auto 記住的人：只在「這次沒寫號碼」或「那位會員姓名就帶這組號碼」時採用。
--
-- 順序：0) 認人（manual 一律；auto 見上）→ 1) 姓名帶這 6 碼：一位 → 用；
--       多位 → 暱稱／留言有寫店名且剛好對到一位 → 用；否則錯誤 →
--       2) 只有被合併掉的舊帳號帶這組號碼 → 跟到本尊 → 3) 找不到。
-- 取貨店維持＝會員自己的 home_store_id（rpc_line_note_apply_comment 沒動）。
--
-- 順手刪掉記錯的 auto 對應：留言帶號碼、對到的會員姓名卻沒有這組號碼。
-- 已開錯的訂單不在這裡動（清單另外交人工）。
--
-- 基底：_line_note_find_member ← 20260929010000_line_note_name_code_before_member_no.sql
--   （已 grep 確認為最新、與線上 pg_get_functiondef 逐字相同）。
-- Rollback：重跑 20260929010000 的 _line_note_find_member 段。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._line_note_find_member(
  p_tenant       UUID,
  p_code         TEXT,     -- 留言裡的 6 碼；可為 NULL（沒寫）
  p_commenter_id TEXT,     -- 留言者 id；可為 NULL
  p_store_id     BIGINT,   -- 保留參數相容，本版不再拿它挑人
  p_text         TEXT      -- 暱稱 + 留言內容，用來找有沒有寫店名
)
RETURNS TABLE (member_id BIGINT, home_store_id BIGINT, ambiguous TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_re      TEXT := '(^|[^0-9])' || COALESCE(p_code, '') || '([^0-9]|$)';
  v_id      BIGINT;
  v_home    BIGINT;
  v_src     TEXT;
  v_cands   BIGINT[];
  v_pick    BIGINT[];
  v_who     TEXT;
  v_status  TEXT;
  v_next    BIGINT;
  v_hops    INT := 0;
BEGIN
  -- 0) 認人：這位留言者之前指定過（manual）或成功對過（auto）的會員
  IF p_commenter_id IS NOT NULL THEN
    SELECT m.id, m.home_store_id, x.source INTO v_id, v_home, v_src
      FROM line_note_commenter_members x
      JOIN members m ON m.id = x.member_id
     WHERE x.tenant_id = p_tenant AND x.commenter_id = p_commenter_id
       AND m.tenant_id = p_tenant AND m.status NOT IN ('merged','deleted');
    IF v_id IS NOT NULL THEN
      IF v_src = 'manual' OR p_code IS NULL
         OR EXISTS (SELECT 1 FROM members m WHERE m.id = v_id AND m.name ~ v_re) THEN
        RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
      END IF;
      v_id := NULL; v_home := NULL;
    END IF;
  END IF;

  IF p_code IS NULL THEN
    RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT, NULL::TEXT; RETURN;
  END IF;

  -- 1) 姓名帶這 6 碼的活人
  SELECT COALESCE(array_agg(m.id ORDER BY m.id), '{}') INTO v_cands
    FROM members m
   WHERE m.tenant_id = p_tenant AND m.name ~ v_re AND m.status NOT IN ('merged','deleted');

  -- 多位 → 只認暱稱／留言裡寫到的店名（「三峽店」比對「三峽」；一個字的店名不算），要剛好一位
  IF array_length(v_cands, 1) > 1 AND COALESCE(p_text, '') <> '' THEN
    SELECT COALESCE(array_agg(m.id), '{}') INTO v_pick
      FROM members m
      JOIN stores s ON s.id = m.home_store_id
     WHERE m.id = ANY (v_cands)
       AND length(regexp_replace(s.name, '店$', '')) >= 2
       AND position(regexp_replace(s.name, '店$', '') IN p_text) > 0;
    IF array_length(v_pick, 1) = 1 THEN v_cands := v_pick; END IF;
  END IF;

  IF array_length(v_cands, 1) = 1 THEN
    SELECT m.id, m.home_store_id INTO v_id, v_home FROM members m WHERE m.id = v_cands[1];
    RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
  END IF;

  IF array_length(v_cands, 1) > 1 THEN
    SELECT string_agg(COALESCE(s.name, '未設店') || '：' || COALESCE(m.name, m.member_no), '、' ORDER BY s.name, m.id)
      INTO v_who
      FROM members m LEFT JOIN stores s ON s.id = m.home_store_id
     WHERE m.id = ANY (v_cands);
    RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT,
                        ('同一個號碼 ' || p_code || ' 有 ' || array_length(v_cands, 1) || ' 位會員（' || v_who
                         || '），不加單，請點「指定會員」選一次，之後這位留言者就會自動對上')::TEXT;
    RETURN;
  END IF;

  -- 2) 只有被合併掉的舊帳號帶這組號碼 → 跟著 merged_into_member_id 走到本尊
  SELECT m.merged_into_member_id INTO v_id
    FROM members m
   WHERE m.tenant_id = p_tenant AND m.name ~ v_re
   ORDER BY m.id LIMIT 1;
  WHILE v_id IS NOT NULL AND v_hops < 5 LOOP
    v_hops := v_hops + 1;
    SELECT m.home_store_id, m.status, m.merged_into_member_id
      INTO v_home, v_status, v_next
      FROM members m WHERE m.id = v_id AND m.tenant_id = p_tenant;
    IF v_status IS NULL THEN EXIT; END IF;
    IF v_status NOT IN ('merged','deleted') THEN
      RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
    END IF;
    v_id := v_next;
  END LOOP;

  -- 3) 找不到（系統 member_no 不再退用：它跟姓名裡的舊編號不是同一套號碼）
  RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
END;
$$;

-- 清掉記錯的 auto 對應：用新邏輯（不看記憶）重算這位留言者任一則帶號碼的留言，
-- 對到的不是記住的那位（或對不到）→ 刪，下次成功加單會重記
DELETE FROM public.line_note_commenter_members x
 WHERE x.source = 'auto'
   AND EXISTS (
     SELECT 1 FROM public.line_note_comments c
      WHERE c.tenant_id = x.tenant_id AND c.commenter_id = x.commenter_id
        AND c.member_no_hint IS NOT NULL
        AND (SELECT f.member_id FROM public._line_note_find_member(
               x.tenant_id, c.member_no_hint, NULL, NULL,
               COALESCE(c.commenter_name, '') || ' ' || COALESCE(c.text, '')) f)
            IS DISTINCT FROM x.member_id);

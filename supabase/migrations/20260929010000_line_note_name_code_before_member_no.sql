-- ============================================================================
-- 20260929010000_line_note_name_code_before_member_no.sql
--
-- LINE 記事本留言加單：「姓名裡的 6 碼」優先於「系統 member_no」。
--
-- 問題（2026-09-29 李玥萱回報「機器人加錯單，經國加到永和」）：
--   留言者「jenny 023012/經國」→ 本尊是經國店「jenny-023012」（號碼寫在姓名裡），
--   但 _line_note_find_member 第 1 步先比系統 member_no，剛好永和店另一位會員的
--   member_no 就是 M023012 → 直接命中、單開到永和那位身上。
--   接著 auto 記住了這個錯的對應；第 0 步對 auto 的檢查又接受「member_no = M||碼」，
--   所以之後每一則都照錯。
--   20260918010000 的前提就是「留言用的 6 碼是寫在姓名裡的舊編號，不是 member_no」，
--   但順序沒跟著改。線上盤點：42 張未結訂單（13 位留言者）開錯人。
--
-- 做法：
--   _line_note_find_member 順序改成 0) 認人 → 2) 姓名 6 碼 → 3) 合併本尊 → 1) member_no（最後才退用）。
--   第 0 步 auto 的「號碼是這位會員的」：姓名帶這組號碼才算；member_no 相符只在
--   沒有任何活人姓名帶這組號碼時才算。
--   順手刪掉已經記錯的 auto 對應（留言帶的號碼 = 對到那位的 member_no、但姓名沒有、
--   另有活人姓名帶這組號碼）。已開錯的訂單不在這裡動，交給人工處理。
--
-- 基底：_line_note_find_member ← 20260918010000_line_note_commenter_member_map.sql
--   （已 grep 確認為最新，且與線上 pg_get_functiondef 逐字相同）。
--   只動：第 0 步 auto 條件、第 1 步搬到最後；其餘逐字保留。
-- Rollback：重跑 20260918010000 的 _line_note_find_member 段（刪掉的 auto 對應不還原，
--   會在下一次成功加單時自動重記）。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._line_note_find_member(
  p_tenant       UUID,
  p_code         TEXT,     -- 留言裡的 6 碼；可為 NULL（沒寫）
  p_commenter_id TEXT,     -- 留言者 id；可為 NULL
  p_store_id     BIGINT,   -- 社群綁的店（沒綁就是店家自開團的店）；可為 NULL
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
      -- manual 一律採用；auto 要「沒寫號碼」或「號碼就是這位會員的」才採用，
      -- 留言者幫別人下單（用別人的號碼）時不能硬塞成本人。
      -- 「號碼是這位的」＝姓名帶這組號碼；member_no 相符只在沒有活人姓名帶這組號碼時才算
      -- （系統 member_no 跟各店舊編號會撞，20260929010000）。
      IF v_src = 'manual' OR p_code IS NULL
         OR EXISTS (SELECT 1 FROM members m WHERE m.id = v_id AND m.name ~ v_re)
         OR (EXISTS (SELECT 1 FROM members m WHERE m.id = v_id
                      AND (m.member_no = 'M' || p_code OR m.member_no = p_code))
             AND NOT EXISTS (SELECT 1 FROM members m
                              WHERE m.tenant_id = p_tenant AND m.name ~ v_re
                                AND m.status NOT IN ('merged','deleted'))) THEN
        RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
      END IF;
      v_id := NULL; v_home := NULL;
    END IF;
  END IF;

  IF p_code IS NULL THEN
    RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT, NULL::TEXT; RETURN;
  END IF;

  -- 2) 姓名帶這 6 碼的活人
  SELECT COALESCE(array_agg(m.id ORDER BY m.id), '{}') INTO v_cands
    FROM members m
   WHERE m.tenant_id = p_tenant AND m.name ~ v_re AND m.status NOT IN ('merged','deleted');

  IF array_length(v_cands, 1) > 1 THEN
    -- 2a) 社群綁的店（或店家自開團的店）那一位
    IF p_store_id IS NOT NULL THEN
      SELECT COALESCE(array_agg(m.id), '{}') INTO v_pick
        FROM members m WHERE m.id = ANY (v_cands) AND m.home_store_id = p_store_id;
      IF array_length(v_pick, 1) = 1 THEN v_cands := v_pick; END IF;
    END IF;
    -- 2b) 留言／暱稱裡寫到的店名（「三峽店」比對「三峽」；一個字的店名不算，太容易誤中）
    IF array_length(v_cands, 1) > 1 AND COALESCE(p_text, '') <> '' THEN
      SELECT COALESCE(array_agg(m.id), '{}') INTO v_pick
        FROM members m
        JOIN stores s ON s.id = m.home_store_id
       WHERE m.id = ANY (v_cands)
         AND length(regexp_replace(s.name, '店$', '')) >= 2
         AND position(regexp_replace(s.name, '店$', '') IN p_text) > 0;
      IF array_length(v_pick, 1) = 1 THEN v_cands := v_pick; END IF;
    END IF;
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

  -- 3) 只有被合併掉的舊帳號帶這組號碼 → 跟著 merged_into_member_id 走到本尊
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

  -- 1) member_no 直接命中：姓名裡沒有人帶這組號碼時才退用
  v_id := NULL; v_home := NULL;
  SELECT m.id, m.home_store_id INTO v_id, v_home
    FROM members m
   WHERE m.tenant_id = p_tenant
     AND (m.member_no = 'M' || p_code OR m.member_no = p_code)
     AND m.status NOT IN ('merged','deleted')
   ORDER BY m.id LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
  END IF;

  RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
END;
$$;

-- 清掉記錯的 auto 對應
DELETE FROM public.line_note_commenter_members x
 WHERE x.source = 'auto'
   AND EXISTS (
     SELECT 1 FROM public.line_note_comments c
       JOIN public.members m ON m.id = x.member_id
      WHERE c.tenant_id = x.tenant_id AND c.commenter_id = x.commenter_id
        AND c.member_no_hint IS NOT NULL
        AND m.member_no = 'M' || c.member_no_hint
        AND m.name !~ ('(^|[^0-9])' || c.member_no_hint || '([^0-9]|$)')
        AND EXISTS (SELECT 1 FROM public.members m2
                     WHERE m2.tenant_id = x.tenant_id
                       AND m2.name ~ ('(^|[^0-9])' || c.member_no_hint || '([^0-9]|$)')
                       AND m2.status NOT IN ('merged','deleted')));

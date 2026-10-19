-- ============================================================================
-- 20261019000000_line_note_unbind_member.sql
--
-- LINE 記事本留言加單：「取消綁定」—— 把留言者跟對錯的會員拆開。
--
-- 背景（2026-10-19 永和回報）：留言者「小琝 134879 永和」的留言被對到中和店的
--   「134879-中和」（M044580）。那位會員是 10/15 有人從留言人工加單時新建的；10/17 機器人
--   照姓名裡的 134879 對到他（當時只有他帶這組號碼）、加了兩張單，並把這位留言者 auto 記住
--   （line_note_commenter_members）。之後永和本尊改名帶上 134879，也照樣先吃記住的那位
--   → 客人在記事本下單、永和那邊看不到單。
--   原本沒有任何入口能看到「這位留言者綁的是誰」，也沒有辦法拿掉；已加單的留言連「指定會員」
--   都不出現（rpc_line_note_assign_member 擋 already_ordered）。
--
-- 做法：
--   1. rpc_line_note_commenter_binding(p_comment_id)：這則留言的留言者目前記住的會員
--      （指定會員彈窗顯示「目前綁定」用）。
--   2. rpc_line_note_unbind_member(p_comment_id, p_member_id)：
--      - 刪掉「這位留言者 → 這位會員」那一列（manual / auto 都刪）。
--      - 這位留言者對到這位會員的留言（ordered / duplicate / error）退回 unmatched，
--        清 member_id / customer_order_id，error 寫「原本對到誰、哪張單沒有自動取消」
--        → 回到待處理，再按「指定會員」選對的人。
--      - 訂單不動，只回傳單號：單可能已經撿貨／到店／被取走，取消與否交給店員判斷。
--   gate 同指定會員：_line_note_require_comment_access(p_comment_id)
--   （總部角色，或有 line_notes_view 且這則留言在看得到的範圍）。
--
-- 已知：「留言加單」分頁載入時 _line_note_settle_keyed_comments 會對待處理的留言再用
--   _line_note_find_member 找一次人；若姓名帶這組號碼的只剩對錯的那位、錯的單又還沒取消，
--   會被重新掛成「已有訂單」。這種直接按「指定會員」選對的人（manual 一律優先）。
--
-- 基底：兩支都是新函式（grep 確認 repo 與線上皆無同名）。
-- Rollback：
--   DROP FUNCTION public.rpc_line_note_unbind_member(BIGINT, BIGINT);
--   DROP FUNCTION public.rpc_line_note_commenter_binding(BIGINT);
--   （已退回待處理的留言要還原，照 error 欄寫的會員按「指定會員」即可）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 這位留言者目前記住的會員
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_commenter_binding(p_comment_id BIGINT)
RETURNS TABLE (member_id BIGINT, member_name TEXT, member_no TEXT, store_name TEXT, source TEXT, set_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_comment_access(p_comment_id);
BEGIN
  RETURN QUERY
  SELECT m.id, m.name::TEXT, m.member_no::TEXT, s.name::TEXT, x.source, x.set_at
    FROM line_note_comments c
    JOIN line_note_commenter_members x ON x.tenant_id = c.tenant_id AND x.commenter_id = c.commenter_id
    JOIN members m ON m.id = x.member_id
    LEFT JOIN stores s ON s.id = m.home_store_id
   WHERE c.id = p_comment_id AND c.tenant_id = v_tenant;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_commenter_binding(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_commenter_binding(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. 取消綁定：記住的人拿掉，對到這位會員的留言退回待處理；訂單不動、回傳單號
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_unbind_member(
  p_comment_id BIGINT,
  p_member_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_comment_access(p_comment_id);
  v_c      line_note_comments%ROWTYPE;
  v_who    TEXT;
  v_map    INT := 0;
  v_reset  INT := 0;
  v_orders JSONB;
BEGIN
  SELECT * INTO v_c FROM line_note_comments WHERE id = p_comment_id AND tenant_id = v_tenant;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'comment % not in tenant', p_comment_id; END IF;
  IF p_member_id IS NULL THEN RAISE EXCEPTION 'member_required: 沒有指定要取消綁定的會員'; END IF;

  SELECT COALESCE(m.name, m.member_no) || COALESCE('（' || s.name || '）', '')
    INTO v_who
    FROM members m LEFT JOIN stores s ON s.id = m.home_store_id
   WHERE m.id = p_member_id AND m.tenant_id = v_tenant;
  v_who := COALESCE(v_who, '會員 #' || p_member_id);

  -- 1) 記住的人
  IF v_c.commenter_id IS NOT NULL THEN
    DELETE FROM line_note_commenter_members x
     WHERE x.tenant_id = v_tenant AND x.commenter_id = v_c.commenter_id AND x.member_id = p_member_id;
    GET DIAGNOSTICS v_map = ROW_COUNT;
  END IF;

  -- 2) 這位留言者對到這位會員的留言 → 退回「找不到會員」（待處理）
  WITH tgt AS (
    SELECT c.id, c.customer_order_id AS order_id, co.order_no, co.status AS order_status, s.name AS store_name
      FROM line_note_comments c
      LEFT JOIN customer_orders co ON co.id = c.customer_order_id
      LEFT JOIN stores s ON s.id = co.pickup_store_id
     WHERE c.tenant_id = v_tenant
       AND c.member_id = p_member_id
       AND c.status IN ('ordered','duplicate','error')
       AND (c.id = p_comment_id OR (v_c.commenter_id IS NOT NULL AND c.commenter_id = v_c.commenter_id))
  ), upd AS (
    UPDATE line_note_comments c
       SET status = 'unmatched', member_id = NULL, customer_order_id = NULL, processed_at = NOW(),
           error = '已取消綁定：原本對到 ' || v_who
                   || CASE WHEN t.order_no IS NOT NULL
                           THEN '，訂單 ' || t.order_no || ' 沒有自動取消，請到訂單確認' ELSE '' END
                   || '。請按「指定會員」選對的人'
      FROM tgt t
     WHERE c.id = t.id
    RETURNING t.order_id, t.order_no, t.order_status, t.store_name
  )
  SELECT count(*)::INT,
         COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
                    'id', u.order_id, 'order_no', u.order_no, 'status', u.order_status, 'store_name', u.store_name))
                  FILTER (WHERE u.order_id IS NOT NULL), '[]'::jsonb)
    INTO v_reset, v_orders
    FROM upd u;

  IF v_map = 0 AND v_reset = 0 THEN
    RAISE EXCEPTION 'not_bound: 這位留言者沒有綁定這位會員（可能已經被別人取消或改指定）';
  END IF;

  RETURN jsonb_build_object('member', v_who, 'binding_removed', v_map > 0,
                            'comments', v_reset, 'orders', v_orders);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_unbind_member(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_unbind_member(BIGINT, BIGINT) TO authenticated;

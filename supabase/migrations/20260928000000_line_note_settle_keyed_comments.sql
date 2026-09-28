-- 20260928000000_line_note_settle_keyed_comments.sql
--
-- LINE 記事本：機器人看不懂的留言，只要**有人已經在系統裡幫這位會員加了單**，
-- 就自動移出「待處理」（改成 duplicate＝已有訂單，客人照樣會收到笑臉）。
--
-- 背景（2026-09-27）：看不懂的留言（「ABC+1」「BCG各2」）掛在待處理，
-- 店員 A 從加單頁直接 key 了單、沒回來按「已解決」；店員 B 之後處理待處理清單又 key 一次，
-- rpc_create_customer_orders 對既有品項是累加 → 數量變兩倍。
-- 二群 31 張、其他群 15 張，全部人工改回（見 customer_order_audit_log 的 edit_reason）。
--
-- 判準：留言的會員（member_id，沒有就用 _line_note_find_member 找，跟 rpc_line_note_apply_comment
-- 同一套）在該團有有效訂單，且**有品項是在留言之後才建的**。
--   * 「留言之後才建」是為了不吃掉「已經有單、客人又來追加」的留言 —— 那種訂單在留言前就存在，
--     照樣留在待處理給人看。
--   * 已知漏網：留言「AB各1」、店員只 key 了 A 也會被移走（看不懂的留言本來就無法逐項對）。
--     單號寫在 error 欄，列表上點得到，要追時看得到。
--   * 只動待處理（_line_note_comment_is_todo 那一套），pending 留給 worker 自己的去重處理。
--
-- 呼叫點：後台加單送出成功後（帶 campaign）、LINE 記事本「留言加單」分頁載入時（全租戶）。
-- 只看最近 60 天的留言，免得每次載入都掃歷史。
--
-- Rollback：
--   DROP FUNCTION public.rpc_line_note_settle_keyed_comments(BIGINT);
--   DROP FUNCTION public._line_note_settle_keyed_comments(UUID, BIGINT);
--   （已被改成 duplicate 的留言要退回可在後台按「退回未處理」）

CREATE OR REPLACE FUNCTION public._line_note_settle_keyed_comments(
  p_tenant      UUID,
  p_campaign_id BIGINT DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n INT;
BEGIN
  WITH todo AS (
    SELECT c.id, c.member_id, c.member_no_hint, c.commenter_id, c.commenter_name, c.text,
           c.commented_at, p.campaign_id, COALESCE(lc.store_id, g.owner_store_id) AS store_id
      FROM line_note_comments c
      JOIN line_note_posts p        ON p.id = c.post_id
      JOIN line_note_communities lc ON lc.id = p.community_id
      LEFT JOIN group_buy_campaigns g ON g.id = p.campaign_id
     WHERE c.tenant_id = p_tenant
       AND p.campaign_id IS NOT NULL
       AND (p_campaign_id IS NULL OR p.campaign_id = p_campaign_id)
       AND c.status IN ('unmatched','error','no_order')
       AND public._line_note_comment_is_todo(c.status, c.member_no_hint, c.text)
       AND c.commented_at > NOW() - INTERVAL '60 days'
  ), who AS (
    SELECT t.*,
           COALESCE(t.member_id,
             (SELECT f.member_id
                FROM public._line_note_find_member(
                       p_tenant, NULLIF(TRIM(COALESCE(t.member_no_hint, '')), ''), t.commenter_id, t.store_id,
                       COALESCE(t.commenter_name, '') || ' ' || COALESCE(t.text, '')) f)) AS mid
      FROM todo t
  ), hit AS (
    SELECT DISTINCT ON (w.id) w.id, w.mid, co.id AS order_id, co.order_no
      FROM who w
      JOIN customer_orders co
        ON co.tenant_id = p_tenant AND co.campaign_id = w.campaign_id AND co.member_id = w.mid
       AND co.status NOT IN ('cancelled','expired','transferred_out')
      JOIN customer_order_items coi
        ON coi.order_id = co.id AND coi.status <> 'cancelled' AND coi.created_at >= w.commented_at
     WHERE w.mid IS NOT NULL
     ORDER BY w.id, co.id
  )
  UPDATE line_note_comments c
     SET status = 'duplicate', member_id = h.mid, customer_order_id = h.order_id,
         error = '已有人工加的單 ' || h.order_no || '，自動移出待處理',
         processed_at = NOW()
    FROM hit h
   WHERE c.id = h.id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_settle_keyed_comments(UUID, BIGINT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_line_note_settle_keyed_comments(
  p_campaign_id BIGINT DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'insufficient_role'; END IF;
  RETURN public._line_note_settle_keyed_comments(v_tenant, p_campaign_id);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_settle_keyed_comments(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_settle_keyed_comments(BIGINT) TO authenticated;

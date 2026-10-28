-- ============================================================================
-- rollback_20261028000000.sql —— 整個還原 20261028000000_cap_check_order_entry_line_note.sql
--
-- ✅ 會改正式系統。由老闆本人貼進 Supabase SQL Editor（整份一個交易）。
-- 順序：
--   1. rpc_line_note_apply_comment 逐字還原成 20260918010000_line_note_commenter_member_map.sql:226 那版
--      （改回呼叫 rpc_create_customer_orders、不截量）；
--   2. rpc_line_note_campaign_targets 逐字還原成 20260929000000_line_note_no_bot_for_store_campaign.sql:208 那版
--      （改回呼叫三參數的 _line_note_comment_is_todo）；
--   3. DROP rpc_create_customer_orders_capped、_campaign_cap_remaining、_line_note_comment_is_todo 四參數版
--      （三參數、兩參數版不動）。
-- ⚠ 前端（後台加單頁）若已改呼叫 rpc_create_customer_orders_capped，要**先**把前端退回
--   （或同時退回），不然還原後後台加單會失敗。
-- 可重貼：CREATE OR REPLACE ＋ DROP ... IF EXISTS。
-- 貼完跑 postcheck_readonly.sql：「已還原」那幾列要 ✅。
-- ============================================================================

-- 1. 還原記事本留言加單（20260918010000:226-431 逐字）
CREATE OR REPLACE FUNCTION public.rpc_line_note_apply_comment(
  p_comment_id BIGINT,
  p_force      BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (out_status TEXT, out_error TEXT, out_order_id BIGINT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c            line_note_comments%ROWTYPE;
  v_tenant       UUID;
  v_campaign_id  BIGINT;
  v_channel_id   BIGINT;
  v_member_id    BIGINT;
  v_member_home  BIGINT;
  v_ambiguous    TEXT;
  v_hint         TEXT;
  v_items        JSONB := '[]'::jsonb;
  v_new_items    JSONB := '[]'::jsonb;
  v_dup_codes    TEXT[] := ARRAY[]::TEXT[];
  v_dup_order    BIGINT;
  v_p            JSONB;
  v_code         TEXT;
  v_qty          NUMERIC;
  v_ci           BIGINT;
  v_item_count   INT;
  v_order_id     BIGINT;
  v_err          TEXT;
  v_claim_tenant TEXT := auth.jwt() ->> 'tenant_id';
  v_store_id     BIGINT;   -- 這則留言所在社群綁的店（沒綁就退用店家自開團的店），撞號時的第一道判斷
BEGIN
  SELECT * INTO v_c FROM line_note_comments WHERE id = p_comment_id;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'comment % not found', p_comment_id; END IF;
  v_tenant := v_c.tenant_id;

  -- 呼叫者是後台使用者 → tenant 要對得上；是 service_role → 補 claims 給下游 RPC 用
  IF v_claim_tenant IS NOT NULL AND v_claim_tenant <> '' THEN
    IF v_claim_tenant::uuid <> v_tenant THEN RAISE EXCEPTION 'comment % not in tenant', p_comment_id; END IF;
  ELSE
    PERFORM set_config('request.jwt.claims',
      jsonb_build_object('tenant_id', v_tenant,
                         'app_metadata', jsonb_build_object('tenant_id', v_tenant, 'role', 'admin'))::text,
      TRUE);
  END IF;

  -- 已經加成單的不重跑（會變成重複單）。忽略／已解決／已有訂單這三種在
  -- p_force 時可以重跑 —— 後台「重試」用的，例如當初會員比對還壞掉時被標忽略的那批，
  -- 或先前的訂單已經取消、現在應該可以加了。
  IF v_c.status = 'ordered' OR (NOT p_force AND v_c.status IN ('ignored','resolved','duplicate')) THEN
    RETURN QUERY SELECT v_c.status, v_c.error, v_c.customer_order_id; RETURN;
  END IF;

  SELECT p.campaign_id, COALESCE(lc.store_id, g.owner_store_id)
    INTO v_campaign_id, v_store_id
    FROM line_note_posts p
    JOIN line_note_communities lc ON lc.id = p.community_id
    LEFT JOIN group_buy_campaigns g ON g.id = p.campaign_id
   WHERE p.id = v_c.post_id;

  -- 沒有任何數量 → 不是下單留言
  IF jsonb_array_length(COALESCE(v_c.parsed, '[]'::jsonb)) = 0 THEN
    UPDATE line_note_comments SET status = 'no_order', processed_at = NOW() WHERE id = p_comment_id;
    RETURN QUERY SELECT 'no_order'::TEXT, NULL::TEXT, NULL::BIGINT; RETURN;
  END IF;

  -- 會員：先認人（這位留言者之前指定過／對過的會員），再認號碼（member_no 或姓名裡的 6 碼）。
  -- 沒寫號碼也先問一次 —— 認得的人不用每次都寫號碼；認不得才回「沒有 6 碼」。
  v_hint := NULLIF(TRIM(COALESCE(v_c.member_no_hint, '')), '');

  SELECT f.member_id, f.home_store_id, f.ambiguous
    INTO v_member_id, v_member_home, v_ambiguous
    FROM public._line_note_find_member(
           v_tenant, v_hint, v_c.commenter_id, v_store_id,
           COALESCE(v_c.commenter_name, '') || ' ' || COALESCE(v_c.text, '')) f;

  IF v_member_id IS NULL THEN
    v_err := COALESCE(v_ambiguous,
                      CASE WHEN v_hint IS NULL THEN '留言裡沒有 6 碼會員編號'
                           ELSE '找不到會員編號 ' || v_hint END);
    UPDATE line_note_comments SET status = CASE WHEN v_ambiguous IS NULL THEN 'unmatched' ELSE 'error' END,
                                  error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT (CASE WHEN v_ambiguous IS NULL THEN 'unmatched' ELSE 'error' END)::TEXT, v_err, NULL::BIGINT; RETURN;
  END IF;

  -- 取貨店＝會員自己的店，沒有就不加
  IF v_member_home IS NULL THEN
    v_err := '會員沒有設定取貨店，請先到會員資料補上';
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, v_err, NULL::BIGINT; RETURN;
  END IF;
  v_channel_id := public._line_note_pick_channel(v_tenant, v_member_home);
  IF v_channel_id IS NULL THEN
    v_err := '這個租戶沒有任何啟用中的 LINE 渠道，無法建單';
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, v_err, NULL::BIGINT; RETURN;
  END IF;

  -- 品項：code → campaign_item；沒 code 且團只有一項 → 那一項
  SELECT count(*) INTO v_item_count FROM public._line_note_item_codes(v_campaign_id);
  FOR v_p IN SELECT * FROM jsonb_array_elements(v_c.parsed) LOOP
    IF COALESCE((v_p ->> 'cancel')::boolean, FALSE) THEN CONTINUE; END IF;  -- 取消留言不自動處理，留給人看
    v_qty  := (v_p ->> 'qty')::numeric;
    v_code := UPPER(NULLIF(TRIM(COALESCE(v_p ->> 'code', '')), ''));
    IF v_qty IS NULL OR v_qty <= 0 THEN CONTINUE; END IF;
    IF v_code IS NULL THEN
      IF v_item_count = 1 THEN
        SELECT ic.campaign_item_id, ic.code INTO v_ci, v_code FROM public._line_note_item_codes(v_campaign_id) ic;
      ELSE
        v_err := '沒寫品項代碼（這團有 ' || v_item_count || ' 項）';
        EXIT;
      END IF;
    ELSE
      SELECT ic.campaign_item_id INTO v_ci FROM public._line_note_item_codes(v_campaign_id) ic WHERE ic.code = v_code;
      IF v_ci IS NULL THEN v_err := '品項代碼 ' || v_code || ' 不在這團裡'; EXIT; END IF;
    END IF;
    v_items := v_items || jsonb_build_object('campaign_item_id', v_ci, 'qty', v_qty, 'code', v_code);
  END LOOP;

  IF v_err IS NOT NULL THEN
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, v_err, NULL::BIGINT; RETURN;
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN
    UPDATE line_note_comments SET status = 'no_order', member_id = v_member_id, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'no_order'::TEXT, NULL::TEXT, NULL::BIGINT; RETURN;
  END IF;

  -- 去重：這位會員在這團已經有同一品項的有效訂單（任何來源）→ 那一項不再加
  FOR v_p IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    SELECT co.id INTO v_order_id
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE co.tenant_id = v_tenant
       AND co.campaign_id = v_campaign_id
       AND co.member_id = v_member_id
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.campaign_item_id = (v_p ->> 'campaign_item_id')::bigint
       AND coi.status <> 'cancelled'
     ORDER BY co.id LIMIT 1;
    IF v_order_id IS NOT NULL THEN
      v_dup_codes := v_dup_codes || COALESCE(v_p ->> 'code', '?');
      v_dup_order := COALESCE(v_dup_order, v_order_id);
      v_order_id  := NULL;
    ELSE
      v_new_items := v_new_items || jsonb_build_object('campaign_item_id', (v_p ->> 'campaign_item_id')::bigint, 'qty', (v_p ->> 'qty')::numeric);
    END IF;
  END LOOP;

  IF jsonb_array_length(v_new_items) = 0 THEN
    v_err := '已有訂單（' || array_to_string(v_dup_codes, '、') || '），未重複加單';
    UPDATE line_note_comments
       SET status = 'duplicate', member_id = v_member_id, customer_order_id = v_dup_order,
           error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    PERFORM public._line_note_remember_commenter(v_tenant, v_c.commenter_id, v_c.commenter_name, v_member_id, 'auto');
    RETURN QUERY SELECT 'duplicate'::TEXT, v_err, v_dup_order; RETURN;
  END IF;

  BEGIN
    SELECT r.out_order_id INTO v_order_id
      FROM public.rpc_create_customer_orders(
             v_campaign_id, v_channel_id,
             jsonb_build_array(jsonb_build_object(
               'member_id', v_member_id,
               'nickname', v_c.commenter_name,
               'pickup_store_id', v_member_home,
               'items', v_new_items))) r
     LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  IF v_err IS NOT NULL THEN
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, v_err, NULL::BIGINT; RETURN;
  END IF;

  -- 這次新建的品項列標成機器人來源。
  -- ⚠ 不要用時間比對：created_at 預設是 NOW()（交易開始），任何在函式內取的
  --   clock_timestamp() 都比它晚，`created_at >= v_t0` 永遠是 false（20260909020000 的 bug）。
  --   去重已保證這些 campaign_item 在本單沒有 active 列 → status='pending' 的一定是剛插進去的；
  --   先前被取消的舊列是 cancelled，掃不到。
  UPDATE customer_order_items coi
     SET source = 'line_bot'
   WHERE coi.order_id = v_order_id
     AND coi.source = 'manual'
     AND coi.status = 'pending'
     AND coi.campaign_item_id IN (SELECT (x ->> 'campaign_item_id')::bigint FROM jsonb_array_elements(v_new_items) x);

  UPDATE line_note_comments
     SET status = 'ordered', member_id = v_member_id, customer_order_id = v_order_id,
         error = NULL, processed_at = NOW(),
         resolution_note = CASE WHEN array_length(v_dup_codes, 1) > 0
                                THEN '已略過重複：' || array_to_string(v_dup_codes, '、')
                                ELSE resolution_note END
   WHERE id = p_comment_id;
  PERFORM public._line_note_remember_commenter(v_tenant, v_c.commenter_id, v_c.commenter_name, v_member_id, 'auto');
  RETURN QUERY SELECT 'ordered'::TEXT, NULL::TEXT, v_order_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_apply_comment(BIGINT, BOOLEAN) TO authenticated;

-- 2. 還原開團彈窗的群組清單（20260929000000:208 逐字）
CREATE OR REPLACE FUNCTION public.rpc_line_note_campaign_targets(p_campaign_id bigint)
 RETURNS TABLE(community_id bigint, home_id text, home_name text, home_kind text, store_id bigint, store_name text, account_id bigint, account_label text, account_status text, auto_post_on_open boolean, listen_enabled boolean, sales_channels text[], in_scope boolean, can_post boolean, blocked_reason text, post_id bigint, post_status text, line_post_id text, post_text text, posted_at timestamp with time zone, last_read_at timestamp with time zone, closed_reason text, post_error text, share_state text, shared_at timestamp with time zone, comment_total integer, comment_ordered integer, comment_duplicate integer, comment_todo integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tenant   UUID    := public._current_tenant_id();
  -- 發文的角色集合＝rpc_line_note_queue_posts 會放行的那組，不要另外定義
  v_may_post BOOLEAN := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
                        = ANY (ARRAY['owner','admin','hq_manager','assistant','']);
  v_owner    BIGINT;
  v_cstat    TEXT;
  v_chan     TEXT;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'no tenant in token'; END IF;

  SELECT g.owner_store_id, g.status, g.sales_channel INTO v_owner, v_cstat, v_chan
    FROM group_buy_campaigns g WHERE g.id = p_campaign_id AND g.tenant_id = v_tenant;
  IF v_cstat IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;

  -- 分店只能看總部的團與自己店開的團
  IF NOT public._line_note_branch_visible_store(v_owner) THEN
    RAISE EXCEPTION 'wrong_store: 這不是你的店開的團';
  END IF;

  RETURN QUERY
  WITH c AS (
    SELECT lc.*,
           a.label  AS a_label,
           a.status AS a_status,
           -- 店家範圍：總部的團發到所有社群，店家自開的團只發到那家店的
           -- （跟 _line_note_on_campaign_open 同一條件，改一邊記得改另一邊）
           (v_owner IS NULL OR lc.store_id = v_owner) AS scoped,
           -- 類別範圍：漂漂館的團只發到有勾漂漂館的社群，反之亦然
           public._line_note_takes_channel(lc.sales_channels, v_chan) AS takes_chan,
           -- 子群：跟著母社群分享，不另外發文
           (SELECT COALESCE(NULLIF(m.home_name, ''), m.home_id) FROM line_note_communities m
             WHERE m.id = lc.share_from_community_id) AS parent_name
      FROM line_note_communities lc
      JOIN line_note_accounts a ON a.id = lc.account_id
     WHERE lc.tenant_id = v_tenant
       -- 分店看不到別家店綁的社群（總部社群 store_id IS NULL，大家都看得到）
       AND public._line_note_branch_visible_store(lc.store_id)
  ), p AS (
    SELECT lp.*,
           COALESCE(s.total, 0)     AS n_total,
           COALESCE(s.ordered, 0)   AS n_ordered,
           COALESCE(s.duplicate, 0) AS n_duplicate,
           COALESCE(s.todo, 0)      AS n_todo
      FROM line_note_posts lp
      LEFT JOIN LATERAL (
        SELECT count(*)::INT AS total,
               count(*) FILTER (WHERE cm.status = 'ordered')::INT   AS ordered,
               count(*) FILTER (WHERE cm.status = 'duplicate')::INT AS duplicate,
               count(*) FILTER (WHERE public._line_note_comment_is_todo(cm.status, cm.member_no_hint, cm.text))::INT AS todo
          FROM line_note_comments cm WHERE cm.post_id = lp.id
      ) s ON TRUE
     WHERE lp.tenant_id = v_tenant AND lp.campaign_id = p_campaign_id
  )
  SELECT c.id, c.home_id, c.home_name, c.home_kind,
         c.store_id, st.name,
         c.account_id, c.a_label, c.a_status,
         c.auto_post_on_open, c.listen_enabled,
         c.sales_channels,
         (c.scoped AND c.takes_chan) AS in_scope,
         -- can_post / blocked_reason 要跟 rpc_line_note_queue_posts 擋的東西**一模一樣**。
         -- 注意「已經發過」的判準是 posted 或 line_post_id 有值，不是「有這一列」——
         -- status='failed'（發文失敗、LINE 上根本沒東西）必須還能再發一次。
         (v_may_post AND v_owner IS NULL AND c.scoped AND c.takes_chan AND c.a_status = 'active'
            AND c.share_from_community_id IS NULL
            AND v_cstat IN ('open','closed')
            AND NOT (p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL))) AS can_post,
         CASE WHEN c.share_from_community_id IS NOT NULL
                                                    THEN '子群：跟著「' || COALESCE(c.parent_name, '?') || '」分享，不另外發文'
              WHEN p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL)
                                                    THEN '已經發過了'
              WHEN v_owner IS NOT NULL              THEN '門市自開團不發 LINE 記事本'
              WHEN NOT v_may_post                   THEN '發文到社群只有總部能操作'
              WHEN NOT c.scoped                     THEN '這個社群只收該店自開的團'
              WHEN NOT c.takes_chan                 THEN '這個社群沒有開放「' || public._line_note_channel_label(v_chan) || '」的團'
              WHEN c.a_status <> 'active'            THEN 'LINE 帳號沒有登入'
              WHEN v_cstat NOT IN ('open','closed')  THEN '這團不是開團中／已收單'
         END,
         p.id, p.status, p.line_post_id, p.text,
         p.posted_at, p.last_read_at, p.closed_reason, p.last_error,
         p.share_state, p.shared_at,
         p.n_total, p.n_ordered, p.n_duplicate, p.n_todo
    FROM c
    LEFT JOIN p ON p.community_id = c.id
    LEFT JOIN stores st ON st.id = c.store_id
   -- 範圍外（別家店的 / 沒開放這一類團的）不列出來 —— 清單只留真的發得到的。
   -- 唯一例外：已經有貼文的一定要出現，設定是後來才改的，歷史不能憑空消失。
   -- 一個都沒有時由彈窗寫出原因（「只發得到有勾這一類的社群」）。
   WHERE (c.scoped AND c.takes_chan) OR p.id IS NOT NULL
   ORDER BY (p.id IS NOT NULL) DESC, c.home_name NULLS LAST, c.id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_campaign_targets(BIGINT) TO authenticated;

-- 3. 拿掉三支新函式（上面兩支還原後已經沒有人叫它們）
DROP FUNCTION IF EXISTS public.rpc_create_customer_orders_capped(BIGINT, BIGINT, JSONB);
DROP FUNCTION IF EXISTS public._campaign_cap_remaining(BIGINT);
DROP FUNCTION IF EXISTS public._line_note_comment_is_todo(TEXT, TEXT, TEXT, TEXT);

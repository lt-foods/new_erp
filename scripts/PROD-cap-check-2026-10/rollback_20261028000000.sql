-- ============================================================================
-- rollback_20261028000000.sql —— 整個還原 20261028000000_cap_check_order_entry_line_note.sql
--
-- ✅ 會改正式系統。由老闆本人貼進 Supabase SQL Editor（整份一個交易）。
-- 順序：
--   1. rpc_line_note_apply_comment 逐字還原成 20260918010000_line_note_commenter_member_map.sql:226 那版
--      （改回呼叫 rpc_create_customer_orders、不截量）；
--   2. DROP rpc_create_customer_orders_capped、_campaign_cap_remaining。
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

-- 2. 拿掉兩支新函式
DROP FUNCTION IF EXISTS public.rpc_create_customer_orders_capped(BIGINT, BIGINT, JSONB);
DROP FUNCTION IF EXISTS public._campaign_cap_remaining(BIGINT);

-- ============================================================================
-- 20260908030000_line_note_member_by_name.sql
--
-- 記事本留言的「6 碼會員編號」對不到人：那 6 碼根本不在 members.member_no，
-- 而是在**姓名裡**。線上實際長相（松山社群）：
--   M034027 / '#17645466 : 【安文】298833-松山'        ← 匯入的（多半已 merged）
--   M20260801074315659 / '安文298833'                  ← LINE 註冊的（active）
-- 而 member_no 是 M013340～M044518 的流水號，跟社群暱稱的 6 碼是兩回事
-- （25,996 位會員裡 25,132 位的 name 帶 6 碼，member_no 命中 0 筆）。
--
-- 改法：找人時依序試
--   1. member_no = 'M'||6碼 或 = 6碼（新制若真的這樣編，維持相容）
--   2. name 內含該 6 碼（前後不是數字，'1232850' 不會命中 '123285'）
--      → 只收 active（排除 merged / deleted）；只有 merged 命中就跟著
--        merged_into_member_id 走（最多 5 跳，比照 rpc_search_members）
--   3. 命中多位活人 → 不猜，標 unmatched 並把候選人列在錯誤訊息裡給小幫手看
--
-- 基底：rpc_line_note_apply_comment @ 20260908020000（去重版，已 grep 全 migrations
--       確認是最新版）；去重、duplicate 狀態、下游呼叫全部原樣保留。
-- rollback：還原 20260908020000 的 rpc_line_note_apply_comment；
--           DROP FUNCTION public._line_note_find_member(UUID, TEXT);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 6 碼 → 會員
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_find_member(p_tenant UUID, p_code TEXT)
RETURNS TABLE (member_id BIGINT, home_store_id BIGINT, ambiguous TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_re      TEXT := '(^|[^0-9])' || p_code || '([^0-9]|$)';
  v_id      BIGINT;
  v_home    BIGINT;
  v_cnt     INT;
  v_who     TEXT;
  v_status  TEXT;
  v_next    BIGINT;
  v_hops    INT := 0;
BEGIN
  -- 1) member_no 直接命中
  SELECT m.id, m.home_store_id INTO v_id, v_home
    FROM members m
   WHERE m.tenant_id = p_tenant
     AND (m.member_no = 'M' || p_code OR m.member_no = p_code)
     AND m.status NOT IN ('merged','deleted')
   ORDER BY m.id LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
  END IF;

  -- 2) 姓名帶這 6 碼的活人
  SELECT count(*) INTO v_cnt
    FROM members m
   WHERE m.tenant_id = p_tenant AND m.name ~ v_re AND m.status NOT IN ('merged','deleted');

  IF v_cnt = 1 THEN
    SELECT m.id, m.home_store_id INTO v_id, v_home
      FROM members m
     WHERE m.tenant_id = p_tenant AND m.name ~ v_re AND m.status NOT IN ('merged','deleted');
    RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
  END IF;

  IF v_cnt > 1 THEN
    SELECT string_agg(m.member_no || '（' || COALESCE(m.name, '') || '）', '、' ORDER BY m.id)
      INTO v_who
      FROM members m
     WHERE m.tenant_id = p_tenant AND m.name ~ v_re AND m.status NOT IN ('merged','deleted');
    RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT,
                        ('有 ' || v_cnt || ' 位會員的名字都帶 ' || p_code || '：' || v_who || '，請人工確認')::TEXT;
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
    IF v_status IS NULL THEN EXIT; END IF;                       -- 指到別的 tenant / 不存在
    IF v_status NOT IN ('merged','deleted') THEN
      RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
    END IF;
    v_id := v_next;
  END LOOP;

  RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2. 留言 → 訂單（只換掉找人那一段，其餘同 20260908020000）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_apply_comment(p_comment_id BIGINT)
RETURNS TABLE (out_status TEXT, out_order_id BIGINT, out_error TEXT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c            line_note_comments%ROWTYPE;
  v_tenant       UUID;
  v_campaign_id  BIGINT;
  v_channel_id   BIGINT;
  v_store_id     BIGINT;
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

  IF v_c.status IN ('ordered','ignored','resolved','duplicate') THEN
    RETURN QUERY SELECT v_c.status, v_c.customer_order_id, v_c.error; RETURN;
  END IF;

  SELECT p.campaign_id, c.channel_id, lc.home_store_id
    INTO v_campaign_id, v_channel_id, v_store_id
    FROM line_note_posts p
    JOIN line_note_communities c ON c.id = p.community_id
    JOIN line_channels lc ON lc.id = c.channel_id
   WHERE p.id = v_c.post_id;

  -- 沒有任何數量 → 不是下單留言
  IF jsonb_array_length(COALESCE(v_c.parsed, '[]'::jsonb)) = 0 THEN
    UPDATE line_note_comments SET status = 'no_order', processed_at = NOW() WHERE id = p_comment_id;
    RETURN QUERY SELECT 'no_order'::TEXT, NULL::BIGINT, NULL::TEXT; RETURN;
  END IF;

  -- 會員：6 碼 → member_no 或姓名裡的號碼
  v_hint := NULLIF(TRIM(COALESCE(v_c.member_no_hint, '')), '');
  IF v_hint IS NULL THEN
    UPDATE line_note_comments SET status = 'unmatched', error = '留言裡沒有 6 碼會員編號', processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'unmatched'::TEXT, NULL::BIGINT, '留言裡沒有 6 碼會員編號'::TEXT; RETURN;
  END IF;

  SELECT f.member_id, f.home_store_id, f.ambiguous
    INTO v_member_id, v_member_home, v_ambiguous
    FROM public._line_note_find_member(v_tenant, v_hint) f;

  IF v_member_id IS NULL THEN
    v_err := COALESCE(v_ambiguous, '找不到會員編號 ' || v_hint);
    UPDATE line_note_comments SET status = 'unmatched', error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'unmatched'::TEXT, NULL::BIGINT, v_err; RETURN;
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
    RETURN QUERY SELECT 'error'::TEXT, NULL::BIGINT, v_err; RETURN;
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN
    UPDATE line_note_comments SET status = 'no_order', member_id = v_member_id, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'no_order'::TEXT, NULL::BIGINT, NULL::TEXT; RETURN;
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
    RETURN QUERY SELECT 'duplicate'::TEXT, v_dup_order, v_err; RETURN;
  END IF;

  BEGIN
    SELECT r.out_order_id INTO v_order_id
      FROM public.rpc_create_customer_orders(
             v_campaign_id, v_channel_id,
             jsonb_build_array(jsonb_build_object(
               'member_id', v_member_id,
               'nickname', v_c.commenter_name,
               'pickup_store_id', COALESCE(v_store_id, v_member_home),
               'items', v_new_items))) r
     LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  IF v_err IS NOT NULL THEN
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, NULL::BIGINT, v_err; RETURN;
  END IF;

  UPDATE line_note_comments
     SET status = 'ordered', member_id = v_member_id, customer_order_id = v_order_id,
         error = NULL, processed_at = NOW(),
         resolution_note = CASE WHEN array_length(v_dup_codes, 1) > 0
                                THEN '已略過重複：' || array_to_string(v_dup_codes, '、')
                                ELSE resolution_note END
   WHERE id = p_comment_id;
  RETURN QUERY SELECT 'ordered'::TEXT, v_order_id, NULL::TEXT;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_apply_comment(BIGINT) TO authenticated;

-- ============================================================================
-- 20260908020000_line_note_dedupe.sql
--
-- 記事本留言加單：先掃這位會員在這團有沒有已經加過同一品項，有就不再加。
-- 來源不限（LIFF 自己下的、小幫手用加單頁加的、前一則留言加的都算）。
-- 全部品項都已存在 → 留言標 'duplicate'（已有訂單，帶訂單號），不動訂單；
-- 部分已存在 → 只加沒有的，並在 resolution_note 記「已略過重複：A」。
--
-- 基底：rpc_line_note_apply_comment @ 20260908010000（唯一前版）。
-- rollback：還原 20260908010000 的 rpc_line_note_apply_comment；
--           ALTER TABLE line_note_comments DROP CONSTRAINT line_note_comments_status_check,
--             ADD CONSTRAINT line_note_comments_status_check CHECK (status IN
--             ('pending','ordered','unmatched','no_order','error','ignored','resolved'));
-- ============================================================================

ALTER TABLE line_note_comments DROP CONSTRAINT IF EXISTS line_note_comments_status_check;
ALTER TABLE line_note_comments ADD CONSTRAINT line_note_comments_status_check
  CHECK (status IN ('pending','ordered','unmatched','no_order','error','ignored','resolved','duplicate'));

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

  -- 會員：6 碼 → M000000
  v_hint := NULLIF(TRIM(COALESCE(v_c.member_no_hint, '')), '');
  IF v_hint IS NULL THEN
    UPDATE line_note_comments SET status = 'unmatched', error = '留言裡沒有 6 碼會員編號', processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'unmatched'::TEXT, NULL::BIGINT, '留言裡沒有 6 碼會員編號'::TEXT; RETURN;
  END IF;
  SELECT m.id, m.home_store_id INTO v_member_id, v_member_home
    FROM members m
   WHERE m.tenant_id = v_tenant
     AND (m.member_no = 'M' || v_hint OR m.member_no = v_hint)
     AND m.status IS DISTINCT FROM 'merged'
   ORDER BY m.id LIMIT 1;
  IF v_member_id IS NULL THEN
    UPDATE line_note_comments SET status = 'unmatched', error = '找不到會員編號 ' || v_hint, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'unmatched'::TEXT, NULL::BIGINT, ('找不到會員編號 ' || v_hint)::TEXT; RETURN;
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

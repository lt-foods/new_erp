-- ============================================================================
-- 20260909050000_line_note_apply_comment_force.sql
--
-- 標成「忽略」的留言要能再處理。原本 rpc_line_note_apply_comment 對
-- ordered/ignored/resolved/duplicate 一律早退，所以後台只能先「退回待處理」再等排程，
-- 兩步而且要等。加一個 p_force：後台按「重試」時帶 TRUE，直接重跑。
--
-- 實務情境：9/8 會員比對還壞掉時（那時只比 member_no），有 11 則被小幫手標了忽略，
-- 錯誤訊息都是「找不到會員編號 211811」之類；比對修好之後那些號碼查得到人，
-- 應該要能一鍵重跑。duplicate 也放行 —— 先前那張單如果已經取消，重跑就會真的加進去。
-- 'ordered' 不放行：那是真的加成單了，重跑會變重複單。
--
-- ⚠ 回傳欄位順序改成 (out_status, out_error, out_order_id)。原本是
--   (status, order_id, error)，而早退那支寫成 `SELECT v_c.status, v_c.customer_order_id, v_c.error`
--   —— customer_order_id 是 BIGINT、out_order_id 也是 BIGINT，但 error 是 TEXT 對到
--   out_error 的位置剛好也是 TEXT，所以型別檢查過得去、值卻是對的；不過為了讓
--   「早退」跟「正常結束」兩條路的欄位對應一眼看得出來一致，這裡統一成 status/error/order_id。
--   前端與 Edge Function 都是用欄位名取值（out_status / out_error / out_order_id），不受影響。
--
-- 基底：rpc_line_note_apply_comment @ 20260909030000（唯一前版，已 grep 確認）。
--       找人／取貨店／去重／來源標記全部原樣。
-- rollback：
--   DROP FUNCTION public.rpc_line_note_apply_comment(BIGINT, BOOLEAN);
--   還原 20260909030000 的單參數版本。
-- ============================================================================

-- 舊的單參數版本要先移除，否則跟「帶預設值的兩參數版」對 1 個引數的呼叫會 ambiguous
DROP FUNCTION IF EXISTS public.rpc_line_note_apply_comment(BIGINT);

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

  SELECT p.campaign_id INTO v_campaign_id FROM line_note_posts p WHERE p.id = v_c.post_id;

  -- 沒有任何數量 → 不是下單留言
  IF jsonb_array_length(COALESCE(v_c.parsed, '[]'::jsonb)) = 0 THEN
    UPDATE line_note_comments SET status = 'no_order', processed_at = NOW() WHERE id = p_comment_id;
    RETURN QUERY SELECT 'no_order'::TEXT, NULL::TEXT, NULL::BIGINT; RETURN;
  END IF;

  -- 會員：6 碼 → member_no 或姓名裡的號碼
  v_hint := NULLIF(TRIM(COALESCE(v_c.member_no_hint, '')), '');
  IF v_hint IS NULL THEN
    UPDATE line_note_comments SET status = 'unmatched', error = '留言裡沒有 6 碼會員編號', processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'unmatched'::TEXT, '留言裡沒有 6 碼會員編號'::TEXT, NULL::BIGINT; RETURN;
  END IF;

  SELECT f.member_id, f.home_store_id, f.ambiguous
    INTO v_member_id, v_member_home, v_ambiguous
    FROM public._line_note_find_member(v_tenant, v_hint) f;

  IF v_member_id IS NULL THEN
    v_err := COALESCE(v_ambiguous, '找不到會員編號 ' || v_hint);
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
  RETURN QUERY SELECT 'ordered'::TEXT, NULL::TEXT, v_order_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_apply_comment(BIGINT, BOOLEAN) TO authenticated;

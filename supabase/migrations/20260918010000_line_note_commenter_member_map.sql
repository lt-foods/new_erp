-- ============================================================================
-- 20260918010000_line_note_commenter_member_map.sql
--
-- LINE 記事本留言加單：撞號改「認人不認號」＋「社群綁的店」當第一道判斷。
--
-- 問題（Alex 2026-09-18）：留言用的 6 碼是寫在會員**姓名**裡的舊編號（各店以前各自編），
--   不是系統的 member_no，所以不同店本來就會撞：線上 1,039 組號碼有重複、其中 853 組
--   同一家店內就有兩個人。9/15 三峽社群 7 則留言全卡在「同一個號碼有 2 位會員」。
--   改 7 碼不可行（15,000 位會員重記號碼，同店重複的照樣撞）；而且之後會有**共用群**
--   （多店會員混在同一個群），靠社群綁哪家店也分不出來。
--
-- 做法：
--   1. `line_note_commenter_members`：留言者 id → 會員。每則留言都帶穩定的
--      `commenter_id`（線上 110 位重複留言者 108 位每次對到同一位會員）。
--      - manual：店員在留言列點「指定會員」選一次（rpc_line_note_assign_member）。
--        之後這個人不管留在哪個群、寫不寫號碼，都直接對到那位會員。
--      - auto：留言成功加單／判成已有訂單時順手記住（只在沒有 manual 紀錄時寫）。
--   2. `_line_note_find_member` 改 5 參數，順序：
--        0) 記住的人：manual 一律採用；auto 要「沒寫號碼」或「那位會員身上就是這組號碼」
--           才採用（留言者幫朋友用朋友的號碼下單時，不能硬塞成留言者本人）。
--        1) member_no 直接命中（原樣）
--        2) 姓名帶這 6 碼：一位 → 用；多位 → 先挑「社群綁的店（沒綁就用店家自開團的店）」
--           那一位；還是多位 → 挑留言／暱稱裡有寫到的店名（例：「404757 三峽」）；
--           仍分不出 → 維持原本的錯誤訊息，並提示點「指定會員」。
--        3) 只有被合併掉的舊帳號帶這組號碼 → 跟到本尊（原樣）
--   3. rpc_line_note_apply_comment：呼叫改帶 commenter_id / 店 / 文字；「沒有 6 碼」改成
--      先問一次認不認得人，認不得才回同一句錯誤；ordered / duplicate 收尾時記住這個人。
--   4. rpc_line_note_assign_member(p_comment_id, p_member_id)：總部角色限定
--      （_line_note_require_admin，跟其他 line_note 寫入 RPC 同一組），寫 manual 紀錄後
--      直接 p_force 重跑那則留言，回傳跟 apply_comment 相同的 (out_status, out_error, out_order_id)。
--
-- 基底（已 grep 確認皆為最新版、且與線上 pg_get_functiondef 逐字相同）：
--   _line_note_find_member       ← 20260909020000_line_note_no_channel_bot_source.sql（2 參數版，本檔 DROP 後改 5 參數）
--   rpc_line_note_apply_comment  ← 20260909050000_line_note_apply_comment_force.sql
--     （只動：多讀 v_store_id、find_member 呼叫、「沒有 6 碼」早退改到 find_member 之後、
--       ordered / duplicate 尾端各加一行 _line_note_remember_commenter；其餘逐字保留）
--
-- Rollback：
--   DROP FUNCTION public.rpc_line_note_assign_member(BIGINT, BIGINT);
--   DROP FUNCTION public._line_note_remember_commenter(UUID, TEXT, TEXT, BIGINT, TEXT);
--   DROP FUNCTION public._line_note_find_member(UUID, TEXT, TEXT, BIGINT, TEXT);
--   重跑 20260909020000 的 _line_note_find_member 段 + 20260909050000 的 rpc_line_note_apply_comment 段；
--   DROP TABLE public.line_note_commenter_members;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 留言者 → 會員
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.line_note_commenter_members (
  tenant_id      UUID   NOT NULL,
  commenter_id   TEXT   NOT NULL,
  member_id      BIGINT NOT NULL REFERENCES public.members(id) ON DELETE CASCADE,
  source         TEXT   NOT NULL CHECK (source IN ('manual','auto')),
  commenter_name TEXT,
  set_by         UUID,
  set_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, commenter_id)
);
CREATE INDEX IF NOT EXISTS idx_line_note_commenter_members_member ON public.line_note_commenter_members (member_id);
COMMENT ON TABLE public.line_note_commenter_members IS
  'LINE 記事本留言者（commenter_id）對應的會員。manual＝店員指定、auto＝加單成功時記住。找人時先查這裡。';

ALTER TABLE public.line_note_commenter_members ENABLE ROW LEVEL SECURITY;
-- 讀：比照 line_note_comments（總部角色 + line_notes_view 功能權限）；寫一律走 SECURITY DEFINER RPC
DROP POLICY IF EXISTS lncmm_read ON public.line_note_commenter_members;
CREATE POLICY lncmm_read ON public.line_note_commenter_members FOR SELECT
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (
      (SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')) = ANY (ARRAY['owner','admin','hq_manager','assistant',''])
      OR (SELECT public._jwt_has_perm('line_notes_view'))
    )
  );
GRANT SELECT ON public.line_note_commenter_members TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. 記住這個人（auto 不蓋 manual；manual 一律蓋）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_remember_commenter(
  p_tenant       UUID,
  p_commenter_id TEXT,
  p_name         TEXT,
  p_member_id    BIGINT,
  p_source       TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  IF p_commenter_id IS NULL OR p_member_id IS NULL THEN RETURN; END IF;
  INSERT INTO line_note_commenter_members (tenant_id, commenter_id, member_id, source, commenter_name, set_by, set_at)
  VALUES (p_tenant, p_commenter_id, p_member_id, p_source, p_name, auth.uid(), NOW())
  ON CONFLICT (tenant_id, commenter_id) DO UPDATE
     SET member_id = EXCLUDED.member_id, source = EXCLUDED.source,
         commenter_name = COALESCE(EXCLUDED.commenter_name, line_note_commenter_members.commenter_name),
         set_by = EXCLUDED.set_by, set_at = NOW()
   WHERE EXCLUDED.source = 'manual' OR line_note_commenter_members.source = 'auto';
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_remember_commenter(UUID, TEXT, TEXT, BIGINT, TEXT) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. 找人：認人 → member_no → 姓名 6 碼（撞號用店挑）→ 合併本尊
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public._line_note_find_member(UUID, TEXT);

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
      IF v_src = 'manual' OR p_code IS NULL
         OR EXISTS (SELECT 1 FROM members m WHERE m.id = v_id
                     AND (m.member_no = 'M' || p_code OR m.member_no = p_code OR m.name ~ v_re)) THEN
        RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
      END IF;
      v_id := NULL; v_home := NULL;
    END IF;
  END IF;

  IF p_code IS NULL THEN
    RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT, NULL::TEXT; RETURN;
  END IF;

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

  RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. rpc_line_note_apply_comment — 基底 20260909050000，改動處見檔頭
-- ----------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------
-- 5. 店員指定：這則留言是哪位會員 → 記住（manual）並立刻重跑那則留言
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_assign_member(
  p_comment_id BIGINT,
  p_member_id  BIGINT
)
RETURNS TABLE (out_status TEXT, out_error TEXT, out_order_id BIGINT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_c      line_note_comments%ROWTYPE;
  v_mstat  TEXT;
BEGIN
  SELECT * INTO v_c FROM line_note_comments WHERE id = p_comment_id AND tenant_id = v_tenant;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'comment % not in tenant', p_comment_id; END IF;
  IF v_c.commenter_id IS NULL THEN RAISE EXCEPTION 'no_commenter_id: 這則留言沒有留言者 id，無法記住'; END IF;
  IF v_c.status = 'ordered' THEN RAISE EXCEPTION 'already_ordered: 這則已經加成單了'; END IF;

  SELECT m.status INTO v_mstat FROM members m WHERE m.id = p_member_id AND m.tenant_id = v_tenant;
  IF v_mstat IS NULL THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;
  IF v_mstat IN ('merged','deleted') THEN RAISE EXCEPTION 'member_inactive: 這位會員已被合併／刪除'; END IF;

  PERFORM public._line_note_remember_commenter(v_tenant, v_c.commenter_id, v_c.commenter_name, p_member_id, 'manual');

  RETURN QUERY SELECT r.out_status, r.out_error, r.out_order_id
                 FROM public.rpc_line_note_apply_comment(p_comment_id, TRUE) r;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_assign_member(BIGINT, BIGINT) TO authenticated;

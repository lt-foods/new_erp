-- ============================================================================
-- 20261028000000_cap_check_order_entry_line_note.sql
--
-- 限量團「後台加單」與「LINE 記事本留言加單」也要擋上限。
--
-- 問題（2026-10-28）：只有客人商城下單 rpc_place_member_order_guarded 會檢查整團上限
--   （group_buy_campaigns.total_cap_qty）與品項上限（campaign_items.cap_qty）。
--   後台加單、記事本留言加單都走 rpc_create_customer_orders，完全不看上限 → 限量團被超賣
--   （GRP-20261015-020 上限 1 賣出 8、GRP-20261015-021 上限 16 賣出 19）。
--
-- 老闆 10/28 定案：
--   Q1 A 後台加單超過上限 → 直接擋，顯示「已達限量上限：…還剩 N 件，這次要加 M 件」
--   Q2 B 留言要的量超過剩下的 → 只加剩下的量（剩 0 才整則不加，標 error 進待處理）
--   Q3 A 後台一次送多位客人，加總超過 → 整批不送
--
-- 做法（不改 rpc_create_customer_orders 本身，另包一層）：
--   1. 新增 _campaign_cap_remaining(p_campaign_id)：每個品項的上限／已售／剩餘（只讀、內部用）。
--      已售算法逐字照 rpc_place_member_order_guarded（20261013000000_transfer_always_new_order.sql:1096）。
--   2. 新增 rpc_create_customer_orders_capped(p_campaign_id, p_channel_id, p_rows)：參數、回傳跟
--      rpc_create_customer_orders 一樣；先鎖團（同商城那支 group_buy_campaigns FOR UPDATE），
--      算本次所有客人所有品項加總，整團或任一品項會超過就丟中文錯誤（整批不送）；沒超過才
--      原封呼叫 rpc_create_customer_orders。
--   3. rpc_line_note_apply_comment：基底 20260918010000_line_note_commenter_member_map.sql:226 逐字，
--      只改「組好 v_new_items → 呼叫建單」那一段：
--        - DECLARE 多 10 個截量用的變數；
--        - 「全部重複」早退之後、呼叫建單之前，插入：鎖團 → 依剩餘量截量（Q2 B）→
--          全部截成 0 就標 error「已達限量上限，未加單（…）」早退 → v_new_items 換成截過的量；
--        - 呼叫改 rpc_create_customer_orders_capped（參數不變）；
--        - 收尾標 ordered 那一句的 resolution_note：有截量時併入「限量已滿，只加部分：A 要 3 件只加 1 件」
--          （跟原本「已略過重複：…」同一欄，兩個都有就用「；」接起來）。
--      認會員、取貨店、品項代碼、去重、記住留言者、標 line_bot 來源：一字未改。
--      ⚠ 只加到部分的留言狀態是 ordered，目前**不會**出現在「待處理」（見施工回報，等 CEO 決定）。
--
-- 不動：rpc_create_customer_orders（20261013000000:941）、rpc_place_member_order_guarded（20261013000000:1096）、
--   轉單（20261013000000）、互抵銷售（20260805000200／210／230）—— 它們照舊呼叫原本那支，不受上限影響。
--
-- 上線順序：⚠ **先半夜貼這份 migration，再合併前端**（前端改呼叫 rpc_create_customer_orders_capped；
--   前端先上、這支還沒貼的話，後台加單會整個失敗）。
--
-- 可重貼：三支都是 CREATE OR REPLACE；前置檢查接受「基底版」或「本檔新版」，整份貼兩次結果一樣。
--   Supabase SQL Editor 整份是一個交易：前置檢查不過會整份停下、一行都不改。
--
-- Rollback：scripts/PROD-cap-check-2026-10/rollback_20261028000000.sql
--   （rpc_line_note_apply_comment 逐字還原成 20260918010000:226 那版 → DROP 兩支新函式；
--     前端改回呼叫 rpc_create_customer_orders）
--
-- 前置檢查的 md5（算法同 20261013000000 檔頭：取 pg_proc.prosrc，CRLF→LF 後 md5）：
--                                    基底版                            本檔新版
--   rpc_line_note_apply_comment      abb0c5f491f7c4d10427691f09a01066  21fa8bf0908b959b2ffb454e4d12d19f
--   rpc_create_customer_orders       966e66281864bdd86ceb84cb01a6b81d  （不改，必須是這版）
--   _campaign_cap_remaining          （新函式：不存在，或本檔版 17b0aa2bf45fe6096b6765d50fb0f01a）
--   rpc_create_customer_orders_capped（新函式：不存在，或本檔版 bbe136060b43564dea8b799308807311）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 前置檢查（不過就整份停下）
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_bad  TEXT[] := ARRAY[]::TEXT[];
  v_rec  RECORD;
  v_oid  REGPROCEDURE;
  v_md5  TEXT;
BEGIN
  -- 要用到的欄位
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'group_buy_campaigns' AND column_name = 'total_cap_qty';
  IF NOT FOUND THEN v_bad := v_bad || '找不到欄位 group_buy_campaigns.total_cap_qty'::TEXT; END IF;
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'campaign_items' AND column_name = 'cap_qty';
  IF NOT FOUND THEN v_bad := v_bad || '找不到欄位 campaign_items.cap_qty'::TEXT; END IF;
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'customer_orders' AND column_name = 'order_kind';
  IF NOT FOUND THEN v_bad := v_bad || '找不到欄位 customer_orders.order_kind'::TEXT; END IF;

  FOR v_rec IN
    SELECT *
      FROM (VALUES
        -- 要覆寫的：線上必須是基底版或本檔新版
        ('public.rpc_line_note_apply_comment(bigint, boolean)', TRUE,
         'abb0c5f491f7c4d10427691f09a01066', '21fa8bf0908b959b2ffb454e4d12d19f'),
        -- 要呼叫、不改的：必須是 20261013000000:941 那版
        ('public.rpc_create_customer_orders(bigint, bigint, jsonb)', TRUE,
         '966e66281864bdd86ceb84cb01a6b81d', '966e66281864bdd86ceb84cb01a6b81d'),
        -- 本檔新建的：可以不存在；存在就必須是本檔版（重貼）
        ('public._campaign_cap_remaining(bigint)', FALSE,
         '17b0aa2bf45fe6096b6765d50fb0f01a', '17b0aa2bf45fe6096b6765d50fb0f01a'),
        ('public.rpc_create_customer_orders_capped(bigint, bigint, jsonb)', FALSE,
         'bbe136060b43564dea8b799308807311', 'bbe136060b43564dea8b799308807311')
      ) AS t(sig, must_exist, md5_base, md5_new)
  LOOP
    v_oid := to_regprocedure(v_rec.sig);
    IF v_oid IS NULL THEN
      IF v_rec.must_exist THEN
        v_bad := v_bad || format('找不到函式 %s（名稱或參數型別跟預期不一樣）', v_rec.sig);
      END IF;
      CONTINUE;
    END IF;
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5 FROM pg_proc p WHERE p.oid = v_oid;
    IF v_md5 IS DISTINCT FROM v_rec.md5_base AND v_md5 IS DISTINCT FROM v_rec.md5_new THEN
      v_bad := v_bad || format('%s 線上內文不是預期的版本（線上 md5=%s）；可能有人改過，請先比對再決定',
                               v_rec.sig, v_md5);
    END IF;
  END LOOP;

  -- 同名但參數不同的新函式（會變成兩支並存）
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public'
                AND p.proname IN ('_campaign_cap_remaining', 'rpc_create_customer_orders_capped')
                AND p.oid NOT IN (COALESCE(to_regprocedure('public._campaign_cap_remaining(bigint)')::oid, 0),
                                  COALESCE(to_regprocedure('public.rpc_create_customer_orders_capped(bigint, bigint, jsonb)')::oid, 0))) THEN
    v_bad := v_bad || '已經有同名但參數不同的 _campaign_cap_remaining／rpc_create_customer_orders_capped，請先查是誰建的'::TEXT;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。不符的項目：\n%',
      array_to_string(v_bad, E'\n');
  END IF;
END;
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. _campaign_cap_remaining(p_campaign_id) —— 一團每個品項的「上限／已售／剩餘」（只讀）
--    已售算法逐字照 rpc_place_member_order_guarded（20261013000000:1096，:1214-1222 整團、
--    :1246-1255 品項）：排除 cancelled／expired／transferred_out 的單、cancelled／expired 的品項，
--    只算 order_kind normal。上限的判斷也照它：COALESCE(cap, 0) > 0 才算有設上限。
--    沒設上限 → cap 與 remaining 回 NULL（＝不限）。剩餘最少回 0（已經超賣的不回負數）。
--    內部用，不開給前端（會看到別的租戶的團）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._campaign_cap_remaining(p_campaign_id BIGINT)
RETURNS TABLE (
  campaign_item_id BIGINT,
  item_cap         NUMERIC,
  item_sold        NUMERIC,
  item_remaining   NUMERIC,
  total_cap        NUMERIC,
  total_sold       NUMERIC,
  total_remaining  NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH g AS (
    SELECT gbc.id, gbc.tenant_id, gbc.total_cap_qty
      FROM group_buy_campaigns gbc
     WHERE gbc.id = p_campaign_id
  ), sold AS (
    SELECT coi.campaign_item_id, SUM(coi.qty) AS qty
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
      JOIN g ON co.tenant_id = g.tenant_id AND co.campaign_id = g.id
     WHERE co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND coi.status NOT IN ('cancelled', 'expired')
       AND COALESCE(co.order_kind, 'normal') = 'normal'
     GROUP BY coi.campaign_item_id
  ), tot AS (
    SELECT COALESCE(SUM(sold.qty), 0) AS qty FROM sold
  )
  SELECT ci.id,
         CASE WHEN COALESCE(ci.cap_qty, 0) > 0 THEN ci.cap_qty END,
         COALESCE(s.qty, 0),
         CASE WHEN COALESCE(ci.cap_qty, 0) > 0 THEN GREATEST(ci.cap_qty - COALESCE(s.qty, 0), 0) END,
         CASE WHEN COALESCE(g.total_cap_qty, 0) > 0 THEN g.total_cap_qty END,
         tot.qty,
         CASE WHEN COALESCE(g.total_cap_qty, 0) > 0 THEN GREATEST(g.total_cap_qty - tot.qty, 0) END
    FROM g
    JOIN campaign_items ci ON ci.campaign_id = g.id AND ci.tenant_id = g.tenant_id
    LEFT JOIN sold s ON s.campaign_item_id = ci.id
    CROSS JOIN tot;
$$;
REVOKE ALL ON FUNCTION public._campaign_cap_remaining(BIGINT) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._campaign_cap_remaining(BIGINT) IS
  '限量團每個品項的上限／已售／剩餘（已售算法同 rpc_place_member_order_guarded）。NULL＝沒設上限。內部用。';


-- ----------------------------------------------------------------------------
-- 2. rpc_create_customer_orders_capped —— 後台加單、LINE 記事本留言加單用的「有擋上限」版
--    參數、回傳跟 rpc_create_customer_orders 一模一樣；檢查通過才原封呼叫它。
--    老闆 10/28：Q1 A 超過上限直接擋；Q3 A 一次送多位客人，加總超過就整批不送。
--    ⚠ 轉單、互抵銷售照舊呼叫 rpc_create_customer_orders（搬既有訂單，不能被上限擋）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_customer_orders_capped(
  p_campaign_id BIGINT,
  p_channel_id  BIGINT,
  p_rows        JSONB
) RETURNS TABLE (out_order_id BIGINT, out_order_no TEXT, out_item_count INT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_req_total  NUMERIC;
  v_total_rem  NUMERIC;
  v_bad        RECORD;
BEGIN
  -- 鎖團：同商城 rpc_place_member_order_guarded（先 group_buy_campaigns FOR UPDATE，再碰訂單），
  -- 兩個人同時加同一團時排隊，不會兩筆都以為還有剩、一起超過。
  PERFORM 1 FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = v_tenant AND gbc.id = p_campaign_id
     FOR UPDATE;

  -- 找不到團、或 p_rows 格式不對：不在這裡擋，交給原本那支丟它原本的錯誤
  IF FOUND AND p_rows IS NOT NULL AND jsonb_typeof(p_rows) = 'array' THEN
    -- 本次所有客人、所有品項加總（Q3 A：整批一起算）
    SELECT COALESCE(SUM(req.qty), 0) INTO v_req_total
      FROM (
        SELECT (it ->> 'campaign_item_id')::BIGINT AS campaign_item_id, (it ->> 'qty')::NUMERIC AS qty
          FROM jsonb_array_elements(p_rows) r,
               jsonb_array_elements(CASE WHEN jsonb_typeof(r -> 'items') = 'array' THEN r -> 'items' ELSE '[]'::jsonb END) it
      ) req
     WHERE req.qty > 0;

    SELECT cr.total_remaining INTO v_total_rem
      FROM public._campaign_cap_remaining(p_campaign_id) cr
     LIMIT 1;

    IF v_total_rem IS NOT NULL AND v_req_total > v_total_rem THEN
      RAISE EXCEPTION '已達限量上限：整團還剩 % 件，這次要加 % 件',
        trim_scale(v_total_rem), trim_scale(v_req_total);
    END IF;

    SELECT req.campaign_item_id, req.qty, cr.item_remaining,
           TRIM(COALESCE(s.product_name, '') || CASE WHEN COALESCE(s.variant_name, '') <> '' THEN ' ' || s.variant_name ELSE '' END) AS item_name
      INTO v_bad
      FROM (
        SELECT (it ->> 'campaign_item_id')::BIGINT AS campaign_item_id, SUM((it ->> 'qty')::NUMERIC) AS qty
          FROM jsonb_array_elements(p_rows) r,
               jsonb_array_elements(CASE WHEN jsonb_typeof(r -> 'items') = 'array' THEN r -> 'items' ELSE '[]'::jsonb END) it
         WHERE (it ->> 'qty')::NUMERIC > 0
         GROUP BY (it ->> 'campaign_item_id')::BIGINT
      ) req
      JOIN public._campaign_cap_remaining(p_campaign_id) cr ON cr.campaign_item_id = req.campaign_item_id
      JOIN campaign_items ci ON ci.id = req.campaign_item_id
      LEFT JOIN skus s ON s.id = ci.sku_id
     WHERE cr.item_remaining IS NOT NULL
       AND req.qty > cr.item_remaining
     ORDER BY ci.sort_order, ci.id
     LIMIT 1;

    IF v_bad.campaign_item_id IS NOT NULL THEN
      RAISE EXCEPTION '已達限量上限：「%」還剩 % 件，這次要加 % 件',
        COALESCE(NULLIF(v_bad.item_name, ''), '品項 #' || v_bad.campaign_item_id),
        trim_scale(v_bad.item_remaining), trim_scale(v_bad.qty);
    END IF;
  END IF;

  RETURN QUERY
  SELECT r.out_order_id, r.out_order_no, r.out_item_count
    FROM public.rpc_create_customer_orders(p_campaign_id, p_channel_id, p_rows) r;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_create_customer_orders_capped(BIGINT, BIGINT, JSONB) TO authenticated;
COMMENT ON FUNCTION public.rpc_create_customer_orders_capped(BIGINT, BIGINT, JSONB) IS
  '後台加單／LINE 記事本留言加單：先鎖團、檢查整團與品項上限（已售算法同 rpc_place_member_order_guarded），沒超過才呼叫 rpc_create_customer_orders。超過就整批不送。';


-- ----------------------------------------------------------------------------
-- 3. rpc_line_note_apply_comment —— 基底 20260918010000:226 逐字，改動處見檔頭
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
  -- 20261028 限量上限：截量用
  v_capped       JSONB := '[]'::jsonb;   -- 截到剩餘量之後真正要加的品項
  v_cap_cut      TEXT[] := ARRAY[]::TEXT[];  -- 被截掉的品項說明（例：A 要 3 件只加 1 件）
  v_cap_note     TEXT;
  v_rem_item     NUMERIC;
  v_rem_total    NUMERIC;
  v_used_item    NUMERIC;
  v_used_total   NUMERIC;
  v_allow        NUMERIC;
  v_cut_code     TEXT;
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

  -- 20261028 限量上限（老闆 10/28 Q2 B：要的量超過剩下的，只加剩下的量；剩 0 才整則不加）。
  --   先鎖團（同商城 rpc_place_member_order_guarded：group_buy_campaigns FOR UPDATE），
  --   兩則留言／後台加單同時進來時排隊，剩餘量才算得準。
  --   剩餘量用 _campaign_cap_remaining（已售算法逐字照商城那支）；整團剩餘依品項順序分配。
  --   沒設上限的團：剩餘是 NULL，量一件都不截，行為跟原本一樣。
  PERFORM 1 FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = v_tenant AND gbc.id = v_campaign_id
     FOR UPDATE;

  FOR v_p IN SELECT * FROM jsonb_array_elements(v_new_items) LOOP
    v_ci  := (v_p ->> 'campaign_item_id')::bigint;
    v_qty := (v_p ->> 'qty')::numeric;
    v_rem_item := NULL; v_rem_total := NULL;
    SELECT cr.item_remaining, cr.total_remaining INTO v_rem_item, v_rem_total
      FROM public._campaign_cap_remaining(v_campaign_id) cr
     WHERE cr.campaign_item_id = v_ci;
    -- 這則留言前面已經分出去的量（同一品項寫兩次、或整團上限被前一項用掉）
    SELECT COALESCE(SUM((x ->> 'qty')::numeric) FILTER (WHERE (x ->> 'campaign_item_id')::bigint = v_ci), 0),
           COALESCE(SUM((x ->> 'qty')::numeric), 0)
      INTO v_used_item, v_used_total
      FROM jsonb_array_elements(v_capped) x;
    v_allow := v_qty;
    IF v_rem_item  IS NOT NULL THEN v_allow := LEAST(v_allow, v_rem_item  - v_used_item);  END IF;
    IF v_rem_total IS NOT NULL THEN v_allow := LEAST(v_allow, v_rem_total - v_used_total); END IF;
    v_allow := GREATEST(v_allow, 0);
    IF v_allow > 0 THEN
      v_capped := v_capped || jsonb_build_object('campaign_item_id', v_ci, 'qty', v_allow);
    END IF;
    IF v_allow < v_qty THEN
      v_cut_code := NULL;
      SELECT ic.code INTO v_cut_code FROM public._line_note_item_codes(v_campaign_id) ic WHERE ic.campaign_item_id = v_ci;
      v_cap_cut := v_cap_cut || (COALESCE(v_cut_code, '?') || ' 要 ' || trim_scale(v_qty)::text
                                 || ' 件只加 ' || trim_scale(v_allow)::text || ' 件');
    END IF;
  END LOOP;

  IF jsonb_array_length(v_capped) = 0 THEN
    -- 剩 0：整則不加，標 error → 進「待處理」
    v_err := '已達限量上限，未加單（' || array_to_string(v_cap_cut, '、') || '）';
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, v_err, NULL::BIGINT; RETURN;
  END IF;
  IF array_length(v_cap_cut, 1) > 0 THEN
    v_cap_note := '限量已滿，只加部分：' || array_to_string(v_cap_cut, '、');
  END IF;
  v_new_items := v_capped;   -- 下面建單、標 line_bot 來源都用截過的量

  BEGIN
    SELECT r.out_order_id INTO v_order_id
      FROM public.rpc_create_customer_orders_capped(
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
         resolution_note = CASE WHEN array_length(v_dup_codes, 1) > 0 OR v_cap_note IS NOT NULL
                                THEN concat_ws('；',
                                       CASE WHEN array_length(v_dup_codes, 1) > 0
                                            THEN '已略過重複：' || array_to_string(v_dup_codes, '、') END,
                                       v_cap_note)
                                ELSE resolution_note END
   WHERE id = p_comment_id;
  PERFORM public._line_note_remember_commenter(v_tenant, v_c.commenter_id, v_c.commenter_name, v_member_id, 'auto');
  RETURN QUERY SELECT 'ordered'::TEXT, NULL::TEXT, v_order_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_apply_comment(BIGINT, BOOLEAN) TO authenticated;

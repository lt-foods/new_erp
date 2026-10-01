-- ============================================================================
-- 拿掉採購單「發送供應商」那一步：建立採購單／回復斷貨之後，採購單直接是「已發送」
-- 規格：公司\01_進行中\需求暨計畫_NEW-ERP拿掉採購單發送供應商_2026-10-01.md（第三之一、四、五、八節）
--
-- 解決的問題
--   請購單按「📦 建立採購單」→ 拆出來的每張採購單都是草稿（20260428120000:367-373 寫死 'draft'），
--   還要每張各按一次「📤 發送供應商」。那個視窗只是排好一段下單文字給人複製（SendPOModal.tsx），
--   系統本身不會送出任何東西；按確認後唯一的系統動作是 rpc_send_purchase_order 把
--   draft → sent、記下管道。忘了按，樓下收貨頁、派貨工作台都看不到這張單。
--   「↩ 回復斷貨」也一樣：回復後採購單退回草稿（20260812000000:598-610），又要再按一次發送。
--
-- 做法（只新增兩支 rpc，各包一支既有函式 ＋ 既有的 rpc_send_purchase_order）
--   rpc_split_pr_to_pos_and_mark_sent(p_pr_id, p_dest_location_id, p_operator) RETURNS BIGINT[]
--     第 1 步 呼叫既有 rpc_split_pr_to_pos（一字不改）
--     第 2 步 對它回傳的每一張採購單呼叫既有 rpc_send_purchase_order(採購單, 'manual', p_operator)
--   rpc_restore_stockout_po_and_mark_sent(p_po_id, p_operator) RETURNS JSONB
--     第 1 步 呼叫既有 rpc_restore_stockout_po（一字不改）
--     第 2 步 對同一張單呼叫既有 rpc_send_purchase_order(p_po_id, 'manual', p_operator)
--   參數、回傳型別跟被包的那支一樣。回復那支的回傳 JSON 鍵也一樣，只有 po_status
--   從 'draft' 改成 'sent'（反映第 2 步之後的實際狀態）。
--
-- 整筆成功或整筆不做
--   兩步在同一個函式呼叫裡 ＝ 同一個交易。第 2 步任何一張失敗，例外往外丟，
--   第 1 步做的（建採購單、改請購單／還原客人訂單、發通知）全部一起退回。
--   - 第 1 步擋下來的情況（請購單未審核、已拆過、有未指派供應商；斷貨單有到貨量、
--     有進貨單、有撿貨單…）：錯誤訊息原封不動往上丟，畫面看到的跟改版前一樣。
--   - 第 2 步失敗：換成白話訊息（講清楚整筆沒做），原始訊息放在 DETAIL。
--
-- 第 2 步在正常情況一定過得了（rpc_send_purchase_order 的守衛逐條對過，20260428120000:443-472）
--   ① 管道限 line/email/phone/fax/manual → 本檔寫死 'manual'
--   ② 採購單要是 draft → 拆單剛建的一律 draft（:367-373）；回復剛把它設回 draft（20260812000000:598-610）
--   ③ 這張採購單的來源請購單不可是 pending_review／rejected
--      拆單：來源只有這一張請購單，而拆單本身就要求它 review_status = 'approved'（:342-344）
--      回復：一般是當初拆單時已核准的請購單；若事後被改成待審核／退回 → 整筆不做、白話告知
--
-- 本檔的範圍
--   🔒 **100% 只新增，不碰任何既有物件。**
--      新增 2 支函式（上面兩支）；0 張表、0 個索引、0 條 policy、0 個觸發器、0 個 ALTER、
--      0 個 CREATE OR REPLACE 打在既有函式上（前置檢查會擋同名的別人的函式）。
--   ⛔ 不改：rpc_split_pr_to_pos（唯一定義 20260428120000:316）、
--            rpc_send_purchase_order（唯一定義 20260428120000:431）、
--            rpc_restore_stockout_po（唯一定義 20260812000000:514）。
--   ⛔ 不拆「📤 發送供應商」與 SendPOModal：它只在草稿採購單出現，改版前就停在草稿的舊單還要靠它。
--   ⛔ 不通知廠商（跟以前一樣，系統從來沒有自動通知過廠商）。
--
-- 權限（不放寬、也不收緊）
--   既有三支的現況（查 repo，線上實際的執行權限用上線驗收查詢看）：
--     - 都是 SECURITY DEFINER；函式裡**沒有任何角色或租戶檢查**，p_operator 由呼叫端傳入。
--     - 都有 GRANT EXECUTE ... TO authenticated（20260428120000:421、:485；20260812000000:786），
--       全 repo 沒有任何一支 migration 從 PUBLIC／anon 收回 ⇒ 依 Postgres／Supabase 預設，
--       anon 也有執行權。
--   本檔兩支：
--     - 不加、也不減角色檢查（跟既有一樣）。
--     - SECURITY INVOKER：用呼叫者自己的身分去呼叫既有那兩支 ⇒ 呼叫者本來就要有那兩支的
--       執行權才做得成，**不會比「自己依序按兩次」多出任何權限**。
--       （若用 SECURITY DEFINER，哪天既有那兩支對某個角色收回了，本檔反而會變成後門。）
--       本檔函式本體不直接讀寫任何表，所以 INVOKER 不會碰到 RLS。
--     - 只 GRANT authenticated；PUBLIC、anon 收回。
--
-- 上線順序：先貼本檔 SQL → 跑上線驗收查詢 → 才合併前端。
--   前端先上、SQL 沒貼 → 按「建立採購單」「回復斷貨」會報找不到函式（什麼都不會寫入）。
--
-- Rollback：本檔沒有改任何既有物件，DROP 這 2 支函式、前端改回呼叫舊的兩支即可。
--   DROP FUNCTION IF EXISTS public.rpc_split_pr_to_pos_and_mark_sent(BIGINT, BIGINT, UUID);
--   DROP FUNCTION IF EXISTS public.rpc_restore_stockout_po_and_mark_sent(BIGINT, UUID);
--   （已經被標成「已發送」的採購單不會因為 DROP 而退回草稿。）
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有 DDL 之前、唯讀
--    這份 SQL 是貼進 SQL Editor 執行的，前提不成立時要在「還沒動任何東西」的階段就停下來。
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing  TEXT[] := ARRAY[]::TEXT[];
  v_conflict TEXT[] := ARRAY[]::TEXT[];
  v_name     TEXT;
  v_expected TEXT;
  v_rec      RECORD;
BEGIN
  -- 依賴的既有表
  FOREACH v_name IN ARRAY ARRAY[
    'purchase_orders', 'purchase_order_items',
    'purchase_requests', 'purchase_request_items'
  ] LOOP
    IF to_regclass('public.' || v_name) IS NULL THEN
      v_missing := v_missing || ('table public.' || v_name);
    END IF;
  END LOOP;

  -- 依賴的既有欄位（第 2 步會寫、或守衛會讀的）
  FOREACH v_name IN ARRAY ARRAY[
    'purchase_orders.status',
    'purchase_orders.sent_at',
    'purchase_orders.sent_by',
    'purchase_orders.sent_channel',
    'purchase_orders.stockout_at',
    'purchase_requests.review_status',
    'purchase_request_items.po_item_id'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_attribute a
       WHERE a.attrelid = to_regclass('public.' || split_part(v_name, '.', 1))
         AND a.attname = split_part(v_name, '.', 2)
         AND a.attnum > 0
         AND NOT a.attisdropped
    ) THEN
      v_missing := v_missing || ('column public.' || v_name);
    END IF;
  END LOOP;

  -- 依賴的既有函式：參數、回傳都要一模一樣，而且同名只能有一支
  -- （多一支同名的別種參數，本檔的呼叫可能會被解析到那一支去）
  -- ⚠️ 本檔只呼叫、不改；這裡是確認在不在、長得對不對，不是驗內容版本。
  FOR v_rec IN
    SELECT *
      FROM (VALUES
        ('rpc_split_pr_to_pos',     'p_pr_id bigint, p_dest_location_id bigint, p_operator uuid', 'bigint[]'),
        ('rpc_send_purchase_order', 'p_po_id bigint, p_channel text, p_operator uuid',            'void'),
        ('rpc_restore_stockout_po', 'p_po_id bigint, p_operator uuid',                            'jsonb')
      ) AS x(fn, args, result)
  LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public'
         AND p.proname = v_rec.fn
         AND pg_get_function_identity_arguments(p.oid) = v_rec.args
         AND pg_get_function_result(p.oid) = v_rec.result
    ) THEN
      v_missing := v_missing || ('function public.' || v_rec.fn || '(' || v_rec.args || ') RETURNS ' || v_rec.result);
    ELSIF (SELECT COUNT(*)
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname = v_rec.fn) > 1 THEN
      v_missing := v_missing || ('function public.' || v_rec.fn || ' 只能有一支（現在有好幾支同名）');
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    v_missing := v_missing || 'role authenticated'::TEXT;
  END IF;

  -- 「只新增」的保險：2 個新名字如果已經存在，必須是本檔建的（函式本體帶著本檔的記號）、
  -- 而且參數一模一樣。否則 CREATE OR REPLACE 會**蓋掉別人的函式**或多長一個同名多載 → 停。
  FOR v_rec IN
    SELECT p.proname,
           pg_get_function_identity_arguments(p.oid) AS args,
           (p.prosrc LIKE '%po_auto_mark_sent:20261002010000%') AS ours
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('rpc_split_pr_to_pos_and_mark_sent', 'rpc_restore_stockout_po_and_mark_sent')
  LOOP
    v_expected := CASE v_rec.proname
      WHEN 'rpc_split_pr_to_pos_and_mark_sent' THEN
        'p_pr_id bigint, p_dest_location_id bigint, p_operator uuid'
      WHEN 'rpc_restore_stockout_po_and_mark_sent' THEN
        'p_po_id bigint, p_operator uuid'
    END;

    IF NOT v_rec.ours OR v_rec.args IS DISTINCT FROM v_expected THEN
      v_conflict := v_conflict || ('public.' || v_rec.proname || '(' || v_rec.args || ')');
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。缺少：\n%',
      array_to_string(v_missing, E'\n');
  END IF;

  IF array_length(v_conflict, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。已經有同名但不是本檔建的函式（或參數不同），貼下去會蓋掉它：\n%',
      array_to_string(v_conflict, E'\n');
  END IF;
END
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. 新增：建立採購單，而且每張直接標成「已發送」（請購單頁「📦 建立採購單」用）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_split_pr_to_pos_and_mark_sent(
  p_pr_id            BIGINT,
  p_dest_location_id BIGINT,
  p_operator         UUID
) RETURNS BIGINT[]
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
-- po_auto_mark_sent:20261002010000（本檔記號：前置檢查靠它認出「這是本檔建的」，勿刪）
DECLARE
  v_po_ids BIGINT[];
  v_po_id  BIGINT;
  v_msg    TEXT;
  v_state  TEXT;
BEGIN
  -- 第 1 步：既有的拆單（一字不改）。它擋下來的情況，錯誤訊息原封不動往上丟。
  v_po_ids := public.rpc_split_pr_to_pos(p_pr_id, p_dest_location_id, p_operator);

  -- 第 2 步：拆出來的每一張，用既有的 rpc_send_purchase_order 標成已發送（管道 manual）。
  -- 任何一張失敗 → 例外往外丟 → 第 1 步建的採購單、改的請購單一起退回。
  -- >>> MARK_SENT_SPLIT BEGIN
  FOREACH v_po_id IN ARRAY COALESCE(v_po_ids, ARRAY[]::BIGINT[]) LOOP
    BEGIN
      PERFORM public.rpc_send_purchase_order(v_po_id, 'manual', p_operator);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
      RAISE EXCEPTION
        '採購單建好後要直接標成「已發送」時失敗，所以整筆都沒有做：一張採購單都沒有建立，請購單維持原狀。原因：%',
        CASE
          WHEN v_msg ~ '^PO has [0-9]+ PR pending review$' THEN '來源請購單還在「待審核」，要先審核通過'
          WHEN v_msg ~ '^PO has [0-9]+ rejected PR$'        THEN '來源請購單已被退回（審核不通過）'
          WHEN v_msg ~ '^PO [0-9]+ already sent'            THEN '採購單已經不是草稿（可能有人同時在操作）'
          ELSE v_msg
        END
        USING ERRCODE = v_state,
              DETAIL  = 'rpc_send_purchase_order(' || v_po_id || '): ' || v_msg;
    END;
  END LOOP;
  -- <<< MARK_SENT_SPLIT END

  RETURN v_po_ids;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_split_pr_to_pos_and_mark_sent(BIGINT, BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_split_pr_to_pos_and_mark_sent(BIGINT, BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_split_pr_to_pos_and_mark_sent(BIGINT, BIGINT, UUID) IS
  '請購單「建立採購單」：同一個交易裡先呼叫既有 rpc_split_pr_to_pos 依廠商拆單，再對每張呼叫既有 rpc_send_purchase_order(…, ''manual'', …) 標成已發送。任何一步失敗整筆不做。不通知廠商。SECURITY INVOKER、無角色檢查（跟既有兩支一樣）。';


-- ----------------------------------------------------------------------------
-- 2. 新增：回復斷貨，而且直接回到「已發送」（採購單編輯頁／列表頁「↩ 回復斷貨」用）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_restore_stockout_po_and_mark_sent(
  p_po_id    BIGINT,
  p_operator UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
-- po_auto_mark_sent:20261002010000（本檔記號：前置檢查靠它認出「這是本檔建的」，勿刪）
DECLARE
  v_res   JSONB;
  v_msg   TEXT;
  v_state TEXT;
BEGIN
  -- 第 1 步：既有的回復斷貨（一字不改）。它擋下來的情況（有到貨量、有進貨單、有撿貨單…），
  --         錯誤訊息原封不動往上丟。
  v_res := public.rpc_restore_stockout_po(p_po_id, p_operator);

  -- 第 2 步：同一張單用既有的 rpc_send_purchase_order 標成已發送（管道 manual）。
  -- 失敗 → 例外往外丟 → 第 1 步還原的客人訂單、開團商品、補貨申請、通知一起退回。
  -- >>> MARK_SENT_RESTORE BEGIN
  BEGIN
    PERFORM public.rpc_send_purchase_order(p_po_id, 'manual', p_operator);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    RAISE EXCEPTION
      '斷貨回復後要直接標成「已發送」時失敗，所以整筆都沒有做：這張單還是斷貨單，客人訂單、開團商品、補貨申請都沒有還原，也沒有發出「已恢復」通知。原因：%',
      CASE
        WHEN v_msg ~ '^PO has [0-9]+ PR pending review$' THEN '來源請購單還在「待審核」，要先審核通過'
        WHEN v_msg ~ '^PO has [0-9]+ rejected PR$'        THEN '來源請購單已被退回（審核不通過）'
        WHEN v_msg ~ '^PO [0-9]+ already sent'            THEN '採購單已經不是草稿（可能有人同時在操作）'
        ELSE v_msg
      END
      USING ERRCODE = v_state,
            DETAIL  = 'rpc_send_purchase_order(' || p_po_id || '): ' || v_msg;
  END;

  -- 回傳跟 rpc_restore_stockout_po 同一組鍵；po_status 改成第 2 步之後的實際狀態
  v_res := v_res || jsonb_build_object('po_status', 'sent');
  -- <<< MARK_SENT_RESTORE END

  RETURN v_res;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_restore_stockout_po_and_mark_sent(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_restore_stockout_po_and_mark_sent(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_restore_stockout_po_and_mark_sent(BIGINT, UUID) IS
  '回復斷貨並直接回到「已發送」：同一個交易裡先呼叫既有 rpc_restore_stockout_po（斷貨單 → draft、還原下游），再呼叫既有 rpc_send_purchase_order(…, ''manual'', …)。任何一步失敗整筆不做。回傳同 rpc_restore_stockout_po，po_status 為 sent。SECURITY INVOKER、無角色檢查（跟既有一樣）。';


-- ----------------------------------------------------------------------------
-- 3. 權限：anon 收回（Supabase 預設會把新函式的 EXECUTE 給 anon／authenticated）
-- ----------------------------------------------------------------------------
DO $revoke_anon$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION public.rpc_split_pr_to_pos_and_mark_sent(BIGINT, BIGINT, UUID) FROM anon;
    REVOKE ALL ON FUNCTION public.rpc_restore_stockout_po_and_mark_sent(BIGINT, UUID) FROM anon;
  END IF;
END
$revoke_anon$;

NOTIFY pgrst, 'reload schema';

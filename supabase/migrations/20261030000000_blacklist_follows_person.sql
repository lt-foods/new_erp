-- ============================================================================
-- 20261030000000 黑名單跟著「人」走，不只跟著那一列會員資料
--
-- 事件（2026-10-26 忠順 157680）：舊帳號 M037707 是黑名單（記事本機器人 9/21、10/21 都擋下），
--   本人從商城用手機重新註冊新帳號 M20261026150246424（舊帳號沒綁 LINE、手機對不上），
--   1 分鐘後下了 GRP-20261020-009-0001。三條下單路（商城 / 小幫手 / 機器人）的黑名單檢查
--   都只看「這一列」的 no_new_order，新列當然是乾淨的。
--   線上 2,395 位黑名單裡 2,348 位沒留手機 → 全部都能這樣繞；合併帳號時旗標也不會帶過去
--   （181 筆合併來源有旗標、目標沒有）。
--
-- 做兩件事：
--   1. rpc_merge_member：來源的 no_new_order / no_notify_pickup OR 到目標；目標沒備註就把
--      來源備註帶過去。目標原值記進 member_merges.moved（flags_copied / tgt_*_before），
--      rpc_unmerge_member 照原值還回去（備註只在還是當初帶過去那句時才還）。
--   2. members BEFORE INSERT 觸發器 trg_members_inherit_blacklist：新會員的姓名帶 6 碼，
--      同租戶同店已有「真的奧客」黑名單（見下）姓名帶同一組 6 碼 → 新列直接 no_new_order，
--      admin_note 寫「自動黑名單：同店 M0xxx（名）同 6 碼 xxxxxx，備註「…」，請確認後合併帳號」
--      讓小幫手在會員頁看得到該去合併。
--
-- ⚠ 「真的奧客」才算（老闆 10/30 定）：線上 2,231 筆黑名單是舊系統匯入的舊紀錄、
--   備註「找不到人／後台找不到人／未合併新系統／換過LINE／LINE被盜，換帳號」，意思是
--   「這筆舊的別用了」不是「這個人禁止下單」—— 已經有 733 位客人重新註冊同 6 碼的新帳號
--   正常在用。所以 _member_blacklist_is_ban(admin_note)：備註非空、且不含
--   「找不到人｜未合併｜換帳號｜換過｜被盜」才算；備註空白的舊紀錄（含 157680 本人）不算，
--   要擋的請小幫手先補備註。合併那條**不**看這個判斷：合併是小幫手明確的動作，照帶。
--
-- 6 碼比對：(?<![0-9])[0-9]{6}(?![0-9]) —— 跟 _line_note_find_member 同一套語意
--   （前後不能是數字，手機 10 碼不會被切出來），姓名裡每一組 6 碼都比。
--   只在 INSERT 時比；之後改名／換店不重比（避免小幫手編輯既有客人資料時誤觸）。
--   member_type = 'store_internal' 的容器會員不比。
--
-- 基底：rpc_merge_member / rpc_unmerge_member 皆以 20260831000050（手機讓號版）為底擴寫，
--   grep 確認之後沒有其他 migration 動過這兩支。
-- 回退：DROP TRIGGER trg_members_inherit_blacklist ON members;
--       DROP FUNCTION _members_inherit_blacklist(); DROP FUNCTION _member_blacklist_is_ban(TEXT);
--       兩支 RPC 重跑 20260831000050 的版本（moved 裡多出來的 key 讀不到就當 FALSE，無害）。
-- ============================================================================

-- ================= 1. rpc_merge_member =================
CREATE OR REPLACE FUNCTION public.rpc_merge_member(
  p_guest_id BIGINT,
  p_real_id  BIGINT,
  p_operator UUID DEFAULT NULL,
  p_reason   TEXT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tenant      UUID;
  v_operator    UUID;
  v_src_phone   TEXT;
  v_src_ph_hash TEXT;
  v_tgt_ph_hash TEXT;
  v_phone_moved BOOLEAN := FALSE;
  v_points      NUMERIC(18,2) := 0;
  v_wallet      NUMERIC(18,2) := 0;
  v_cards       INTEGER       := 0;
  v_src_line    TEXT;
  v_src_status  TEXT;
  -- 被搬走的列 id（供 rpc_unmerge_member 精準搬回）
  v_order_ids   BIGINT[] := '{}';
  v_alias_ids   BIGINT[] := '{}';
  v_tag_ids     BIGINT[] := '{}';
  v_card_ids    BIGINT[] := '{}';
  v_pl_ids      BIGINT[] := '{}';
  v_wl_ids      BIGINT[] := '{}';
  -- 20261030 黑名單跟人走：來源的旗標帶到目標；目標原值記進 moved 供 unmerge 還原
  v_src_nno     BOOLEAN := FALSE;
  v_src_nnp     BOOLEAN := FALSE;
  v_src_note    TEXT;
  v_tgt_nno     BOOLEAN := FALSE;
  v_tgt_nnp     BOOLEAN := FALSE;
  v_tgt_note    TEXT;
  v_flags_copied BOOLEAN := FALSE;
BEGIN
  v_operator := COALESCE(p_operator, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);

  SELECT tenant_id, line_user_id, status,
         COALESCE(no_new_order, FALSE), COALESCE(no_notify_pickup, FALSE), admin_note
    INTO v_tenant, v_src_line, v_src_status,
         v_src_nno, v_src_nnp, v_src_note
    FROM members WHERE id = p_guest_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'source member % not found', p_guest_id;
  END IF;

  IF v_src_line IS NOT NULL THEN
    RAISE EXCEPTION 'source member % is already bound to LINE — pick the unbound one as source', p_guest_id;
  END IF;

  IF v_src_status = 'merged' THEN
    RAISE EXCEPTION 'source member % is already merged', p_guest_id;
  END IF;

  IF p_guest_id = p_real_id THEN
    RAISE EXCEPTION 'source and target must differ';
  END IF;

  -- 精準守門：目標(已綁 LINE)可以有訂單；只有當「來源 active 訂單」與「目標 active
  -- 訂單」落在同一個 (tenant, campaign, channel, order_kind) 時，把來源訂單搬過去
  -- 才會撞 customer_orders_trio_kind_active_uniq。這種情形才擋（需先人工處理其一）。
  PERFORM 1
    FROM customer_orders s
    JOIN customer_orders t
      ON t.tenant_id   = s.tenant_id
     AND t.campaign_id = s.campaign_id
     AND t.channel_id  = s.channel_id
     AND t.order_kind  = s.order_kind
   WHERE s.member_id = p_guest_id
     AND t.member_id = p_real_id
     AND s.tenant_id = v_tenant
     AND s.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND t.status NOT IN ('transferred_out', 'expired', 'cancelled')
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'merge would collide: source % and target % both have an active order in the same campaign/channel, cannot merge', p_guest_id, p_real_id;
  END IF;

  -- 把來源（虛擬會員）的訂單搬到目標（LINE 會員）：已確認無同 trio+kind 的 active 撞單
  WITH upd AS (
    UPDATE customer_orders SET member_id = p_real_id
     WHERE member_id = p_guest_id AND tenant_id = v_tenant
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_order_ids FROM upd;

  WITH upd AS (
    UPDATE customer_line_aliases SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_alias_ids FROM upd;

  WITH upd AS (
    UPDATE member_tags SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_tag_ids FROM upd;

  SELECT COUNT(*) INTO v_cards FROM member_cards WHERE member_id = p_guest_id;
  v_cards := COALESCE(v_cards, 0);
  WITH upd AS (
    UPDATE member_cards SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_card_ids FROM upd;

  SELECT COALESCE(balance, 0) INTO v_points
    FROM member_points_balance WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  v_points := COALESCE(v_points, 0);

  SELECT COALESCE(balance, 0) INTO v_wallet
    FROM wallet_balances       WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  v_wallet := COALESCE(v_wallet, 0);

  WITH upd AS (
    UPDATE points_ledger SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_pl_ids FROM upd;

  WITH upd AS (
    UPDATE wallet_ledger SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_wl_ids FROM upd;

  IF v_points > 0 THEN
    INSERT INTO member_points_balance (tenant_id, member_id, balance, version, updated_at)
    VALUES (v_tenant, p_real_id, v_points, 1, NOW())
    ON CONFLICT (tenant_id, member_id) DO UPDATE
      SET balance          = member_points_balance.balance + EXCLUDED.balance,
          version          = member_points_balance.version + 1,
          last_movement_at = NOW(),
          updated_at       = NOW();
  END IF;

  IF v_wallet > 0 THEN
    INSERT INTO wallet_balances (tenant_id, member_id, balance, version, updated_at)
    VALUES (v_tenant, p_real_id, v_wallet, 1, NOW())
    ON CONFLICT (tenant_id, member_id) DO UPDATE
      SET balance          = wallet_balances.balance + EXCLUDED.balance,
          version          = wallet_balances.version + 1,
          last_movement_at = NOW(),
          updated_at       = NOW();
  END IF;

  DELETE FROM member_points_balance WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  DELETE FROM wallet_balances        WHERE tenant_id = v_tenant AND member_id = p_guest_id;

  -- ── 手機號：不能留在被併掉的死號身上 ──────────────────────────────────────
  -- 全站「這支號碼有人用了嗎」的查詢都排除 merged，唯獨 unique index 不排除；
  -- 留著就是一支查不到主人、誰也存不進去的號碼（見檔頭）。
  SELECT phone, phone_hash INTO v_src_phone, v_src_ph_hash
    FROM members WHERE id = p_guest_id;

  IF v_src_ph_hash IS NOT NULL THEN
    SELECT phone_hash INTO v_tgt_ph_hash
      FROM members WHERE id = p_real_id AND tenant_id = v_tenant
      FOR UPDATE;
    IF FOUND AND v_tgt_ph_hash IS NULL THEN
      -- 目標還沒有手機 → 交棒。合併的語意就是「這兩筆是同一個人」，
      -- 號碼要留在活著的那個帳號上，店員不必再手動補一次。
      -- 先讓號再寫入：unique index 是逐句即時檢查，同一句交換會直接撞。
      UPDATE members SET phone_hash = NULL WHERE id = p_guest_id;
      UPDATE members
         SET phone      = v_src_phone,
             phone_hash = v_src_ph_hash,
             updated_at = NOW(),
             updated_by = v_operator
       WHERE id = p_real_id;
      v_phone_moved := TRUE;
    END IF;
  END IF;

  -- ── 黑名單跟人走（20261030）────────────────────────────────────────────────
  -- 合併＝「這兩筆是同一個人」。來源被列黑名單（禁加單／不通知取貨），本尊也要是，
  -- 否則舊帳號擋住、新帳號照常從商城下單（2026-10-26 忠順 157680 就是這樣繞過去的）。
  -- 只 OR 上去、不清掉目標原本的旗標；目標沒備註才把來源備註帶過去（小幫手看得到為什麼）。
  -- 目標原值記進 moved，rpc_unmerge_member 判定「不是同一人」時照原值還回去。
  SELECT COALESCE(no_new_order, FALSE), COALESCE(no_notify_pickup, FALSE), admin_note
    INTO v_tgt_nno, v_tgt_nnp, v_tgt_note
    FROM members WHERE id = p_real_id AND tenant_id = v_tenant;
  IF (v_src_nno AND NOT v_tgt_nno) OR (v_src_nnp AND NOT v_tgt_nnp) THEN
    UPDATE members
       SET no_new_order     = no_new_order OR v_src_nno,
           no_notify_pickup = no_notify_pickup OR v_src_nnp,
           admin_note       = CASE WHEN NULLIF(btrim(COALESCE(admin_note, '')), '') IS NULL
                                   THEN NULLIF(btrim(COALESCE(v_src_note, '')), '')
                                   ELSE admin_note END,
           updated_at       = NOW(),
           updated_by       = v_operator
     WHERE id = p_real_id AND tenant_id = v_tenant;
    v_flags_copied := TRUE;
  END IF;

  UPDATE members
     SET status                = 'merged',
         merged_into_member_id = p_real_id,
         -- phone 原文留著（稽核／復原要用），只讓出 hash ＝ 只讓出「佔號」這件事
         phone_hash            = NULL,
         updated_at            = NOW(),
         updated_by            = v_operator
   WHERE id = p_guest_id;

  INSERT INTO member_merges (
    tenant_id, primary_member_id, merged_member_id,
    points_moved, wallet_moved, cards_moved, reason, operator_id, moved
  ) VALUES (
    v_tenant, p_real_id, p_guest_id,
    v_points, v_wallet, v_cards, p_reason, v_operator,
    jsonb_build_object(
      'v', 1,
      'source', 'recorded',
      'src_status_before', v_src_status,
      'order_ids',         to_jsonb(v_order_ids),
      'alias_ids',         to_jsonb(v_alias_ids),
      'tag_ids',           to_jsonb(v_tag_ids),
      'card_ids',          to_jsonb(v_card_ids),
      'points_ledger_ids', to_jsonb(v_pl_ids),
      'wallet_ledger_ids', to_jsonb(v_wl_ids),
      -- 手機交棒的紀錄，rpc_unmerge_member 靠它決定要不要從目標收回
      'phone_hash_released',   v_src_ph_hash,
      'phone_moved_to_target', v_phone_moved,
      -- 黑名單旗標有沒有從來源帶到目標；目標原值供 rpc_unmerge_member 還原
      'flags_copied',                v_flags_copied,
      'tgt_no_new_order_before',     v_tgt_nno,
      'tgt_no_notify_pickup_before', v_tgt_nnp,
      'tgt_admin_note_before',       v_tgt_note
    )
  );
END;
$function$;

-- ================= 2. rpc_unmerge_member =================
CREATE OR REPLACE FUNCTION public.rpc_unmerge_member(
  p_merge_id BIGINT,
  p_operator UUID DEFAULT NULL,
  p_reason   TEXT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  -- ⚠ 應用角色走 app_metadata（見 CLAUDE.md / 20260807000040）
  v_role       TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_operator   UUID;
  v_mm         member_merges%ROWTYPE;
  v_guest      BIGINT;
  v_real       BIGINT;
  v_moved      JSONB;
  v_recon      BOOLEAN := FALSE;
  v_status_to  TEXT;
  v_order_ids  BIGINT[] := '{}';
  v_alias_ids  BIGINT[] := '{}';
  v_tag_ids    BIGINT[] := '{}';
  v_card_ids   BIGINT[] := '{}';
  v_pl_ids     BIGINT[] := '{}';
  v_wl_ids     BIGINT[] := '{}';
  v_n_orders   INT := 0;
  v_n_alias    INT := 0;
  v_n_tags     INT := 0;
  v_n_cards    INT := 0;
  v_n_pl       INT := 0;
  v_n_wl       INT := 0;
  v_left       INT := 0;
  v_src_status TEXT;
  v_src_merged BIGINT;
  v_bal        NUMERIC(18,2);
  v_src_phone  TEXT;
  v_src_hash   TEXT;
  v_ph_moved   BOOLEAN := FALSE;
  v_flags_back BOOLEAN := FALSE;   -- 20261030：合併時帶過去的黑名單旗標有沒有還回去
BEGIN
  -- 會搬訂單與餘額，所以不是人人可按：總部層級 + 店長。
  -- '' = 沒有顯式 role 的 legacy/dev admin，對齊 apps/admin/src/lib/role.ts。
  -- store_staff 刻意不給（要復原請找店長）。
  IF v_role NOT IN ('owner','admin','hq','hq_manager','store_manager','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  v_operator := COALESCE(p_operator, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);

  SELECT * INTO v_mm FROM member_merges
   WHERE id = p_merge_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'merge_not_found: 找不到這筆合併紀錄';
  END IF;
  IF v_mm.reverted_at IS NOT NULL THEN
    RAISE EXCEPTION 'merge_already_reverted: 這筆合併已經復原過了';
  END IF;

  v_guest := v_mm.merged_member_id;
  v_real  := v_mm.primary_member_id;

  -- 店長只能動自己店的會員（身分 = app_metadata.stores 店名陣列，見 20260808000020）。
  -- 判定看「目標會員」= 合併紀錄掛在誰名下 = 店員正在看的那一頁。
  IF v_role = 'store_manager' AND NOT EXISTS (
    SELECT 1
      FROM members m
      JOIN stores s ON s.id = m.home_store_id AND s.tenant_id = m.tenant_id
     WHERE m.id = v_real AND m.tenant_id = v_tenant
       AND s.name IN (SELECT jsonb_array_elements_text(auth.jwt() -> 'app_metadata' -> 'stores'))
  ) THEN
    RAISE EXCEPTION 'wrong_store: 只能復原自己店會員的合併紀錄';
  END IF;

  -- 來源會員必須還停在「被這次合併併掉」的狀態。之後被 GDPR 刪除、或被再併去
  -- 別人身上的話，硬搬回來只會製造更難救的狀態 —— 擋下來讓人工處理。
  SELECT status, merged_into_member_id INTO v_src_status, v_src_merged
    FROM members WHERE id = v_guest AND tenant_id = v_tenant
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'merge_state_changed: 來源會員已不存在，無法復原';
  END IF;
  IF v_src_status <> 'merged' OR v_src_merged IS DISTINCT FROM v_real THEN
    RAISE EXCEPTION 'merge_state_changed: 來源會員目前的狀態不是「被併入此會員」（可能已被刪除或再次合併），無法自動復原';
  END IF;

  v_moved := v_mm.moved;

  IF v_moved ? 'order_ids' THEN
    -- A：合併當下記下來的精準清單
    v_status_to := COALESCE(v_moved ->> 'src_status_before', 'active');
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_order_ids FROM jsonb_array_elements_text(v_moved -> 'order_ids') x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_alias_ids FROM jsonb_array_elements_text(COALESCE(v_moved -> 'alias_ids', '[]'::jsonb)) x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_tag_ids   FROM jsonb_array_elements_text(COALESCE(v_moved -> 'tag_ids', '[]'::jsonb)) x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_card_ids  FROM jsonb_array_elements_text(COALESCE(v_moved -> 'card_ids', '[]'::jsonb)) x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_pl_ids    FROM jsonb_array_elements_text(COALESCE(v_moved -> 'points_ledger_ids', '[]'::jsonb)) x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_wl_ids    FROM jsonb_array_elements_text(COALESCE(v_moved -> 'wallet_ledger_ids', '[]'::jsonb)) x;
  ELSE
    -- B：舊紀錄，靠 updated_at 時間戳推回（理由見 20260809000020 檔頭）
    IF v_mm.points_moved <> 0 OR v_mm.wallet_moved <> 0 OR v_mm.cards_moved <> 0 THEN
      RAISE EXCEPTION 'unmerge_needs_manual: 這筆合併在記錄功能上線前完成，且動到了點數／儲值／卡片，無法安全地自動復原，請聯絡工程師處理';
    END IF;
    v_recon     := TRUE;
    v_status_to := 'active';
    SELECT COALESCE(array_agg(id), '{}') INTO v_order_ids
      FROM customer_orders
     WHERE tenant_id = v_tenant AND member_id = v_real AND updated_at = v_mm.created_at;
    SELECT COALESCE(array_agg(id), '{}') INTO v_alias_ids
      FROM customer_line_aliases
     WHERE member_id = v_real AND updated_at = v_mm.created_at;
  END IF;

  -- 搬回去之前先確認不會撞唯一索引：來源會員身上若已經有同 (campaign, channel, kind)
  -- 的 active 訂單（合併後又補單之類），硬搬會炸在 customer_orders_trio_kind_active_uniq。
  --
  -- ⚠ campaign_id / channel_id 用 `=` 而不是 IS NOT DISTINCT FROM：btree unique 視
  --   NULL 彼此為相異、本來就不強制唯一，用 IS NOT DISTINCT FROM 會把兩筆 NULL 當成
  --   撞到而擋掉根本不會撞的復原。這跟 rpc_merge_member 的守門是同一套語意。
  PERFORM 1
    FROM customer_orders s
    JOIN customer_orders t
      ON t.tenant_id   = s.tenant_id
     AND t.campaign_id = s.campaign_id
     AND t.channel_id  = s.channel_id
     AND t.order_kind  = s.order_kind
   WHERE s.id = ANY(v_order_ids)
     AND t.member_id = v_guest
     AND t.tenant_id = v_tenant
     AND s.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND t.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND s.order_kind <> 'restock'
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'unmerge_would_collide: 來源會員身上已有同一團同通路的有效訂單，搬回去會撞單，請先人工處理';
  END IF;

  -- ── 搬回來源 ─────────────────────────────────────────────────────────────
  UPDATE customer_orders       SET member_id = v_guest WHERE id = ANY(v_order_ids) AND tenant_id = v_tenant AND member_id = v_real;
  GET DIAGNOSTICS v_n_orders = ROW_COUNT;
  UPDATE customer_line_aliases SET member_id = v_guest WHERE id = ANY(v_alias_ids) AND member_id = v_real;
  GET DIAGNOSTICS v_n_alias = ROW_COUNT;
  UPDATE member_tags           SET member_id = v_guest WHERE id = ANY(v_tag_ids)   AND member_id = v_real;
  GET DIAGNOSTICS v_n_tags = ROW_COUNT;
  UPDATE member_cards          SET member_id = v_guest WHERE id = ANY(v_card_ids)  AND member_id = v_real;
  GET DIAGNOSTICS v_n_cards = ROW_COUNT;
  UPDATE points_ledger         SET member_id = v_guest WHERE id = ANY(v_pl_ids)    AND member_id = v_real;
  GET DIAGNOSTICS v_n_pl = ROW_COUNT;
  UPDATE wallet_ledger         SET member_id = v_guest WHERE id = ANY(v_wl_ids)    AND member_id = v_real;
  GET DIAGNOSTICS v_n_wl = ROW_COUNT;

  -- ── 餘額搬回來源 ─────────────────────────────────────────────────────────
  -- 合併是「加進目標」，復原就「從目標扣掉同一筆金額、還給來源」。目標的餘額在合併
  -- 之後可能又被動過，扣下去會變負數的話擋掉 —— 餘額是錢，寧可要求人工處理。
  IF v_mm.points_moved > 0 THEN
    SELECT COALESCE(balance, 0) INTO v_bal FROM member_points_balance
     WHERE tenant_id = v_tenant AND member_id = v_real FOR UPDATE;
    IF COALESCE(v_bal, 0) < v_mm.points_moved THEN
      RAISE EXCEPTION 'unmerge_balance_insufficient: 目標會員目前點數 % 少於當初併入的 %，扣回去會變負數，請先人工調整',
        COALESCE(v_bal, 0), v_mm.points_moved;
    END IF;
    UPDATE member_points_balance
       SET balance = balance - v_mm.points_moved, version = version + 1, updated_at = NOW()
     WHERE tenant_id = v_tenant AND member_id = v_real;
    INSERT INTO member_points_balance (tenant_id, member_id, balance, version, updated_at)
    VALUES (v_tenant, v_guest, v_mm.points_moved, 1, NOW())
    ON CONFLICT (tenant_id, member_id) DO UPDATE
      SET balance    = member_points_balance.balance + EXCLUDED.balance,
          version    = member_points_balance.version + 1,
          updated_at = NOW();
  END IF;

  IF v_mm.wallet_moved > 0 THEN
    SELECT COALESCE(balance, 0) INTO v_bal FROM wallet_balances
     WHERE tenant_id = v_tenant AND member_id = v_real FOR UPDATE;
    IF COALESCE(v_bal, 0) < v_mm.wallet_moved THEN
      RAISE EXCEPTION 'unmerge_balance_insufficient: 目標會員目前儲值金 % 少於當初併入的 %，扣回去會變負數，請先人工調整',
        COALESCE(v_bal, 0), v_mm.wallet_moved;
    END IF;
    UPDATE wallet_balances
       SET balance = balance - v_mm.wallet_moved, version = version + 1, updated_at = NOW()
     WHERE tenant_id = v_tenant AND member_id = v_real;
    INSERT INTO wallet_balances (tenant_id, member_id, balance, version, updated_at)
    VALUES (v_tenant, v_guest, v_mm.wallet_moved, 1, NOW())
    ON CONFLICT (tenant_id, member_id) DO UPDATE
      SET balance    = wallet_balances.balance + EXCLUDED.balance,
          version    = wallet_balances.version + 1,
          updated_at = NOW();
  END IF;

  -- ── 手機號還給來源 ───────────────────────────────────────────────────────
  -- 合併時把 phone_hash 讓掉了（20260831000050），phone 原文留在來源身上，
  -- 所以這裡重算即可。交棒給目標的那種要先從目標收回，否則兩邊撞 unique。
  -- ⚠ search_path 釘死 public，digest 在 extensions schema，一定要寫全名。
  SELECT phone INTO v_src_phone FROM members WHERE id = v_guest AND tenant_id = v_tenant;
  v_src_hash := CASE WHEN NULLIF(btrim(COALESCE(v_src_phone, '')), '') IS NOT NULL
                     THEN encode(extensions.digest(btrim(v_src_phone), 'sha256'), 'hex')
                END;
  v_ph_moved := COALESCE((v_moved ->> 'phone_moved_to_target')::BOOLEAN, FALSE);

  IF v_ph_moved AND v_src_hash IS NOT NULL THEN
    UPDATE members
       SET phone = NULL, phone_hash = NULL, updated_at = NOW(), updated_by = v_operator
     WHERE id = v_real AND tenant_id = v_tenant AND phone_hash = v_src_hash;
  END IF;

  -- 期間被別人（含目標自己重填）用走就不還 —— 只是不還，不擋復原。
  IF v_src_hash IS NOT NULL AND EXISTS (
    SELECT 1 FROM members o
     WHERE o.tenant_id = v_tenant AND o.phone_hash = v_src_hash AND o.id <> v_guest
  ) THEN
    v_src_hash := NULL;
  END IF;

  -- ── 黑名單旗標還給目標原值（20261030）──────────────────────────────────────
  -- 合併時把來源的禁加單／不通知旗標 OR 到目標身上（flags_copied）。復原＝「不是同一人」，
  -- 目標照合併前的原值還回去；備註只在還是當初帶過去的那句時才還，小幫手改過就不動。
  IF COALESCE((v_moved ->> 'flags_copied')::BOOLEAN, FALSE) THEN
    UPDATE members
       SET no_new_order     = COALESCE((v_moved ->> 'tgt_no_new_order_before')::BOOLEAN, no_new_order),
           no_notify_pickup = COALESCE((v_moved ->> 'tgt_no_notify_pickup_before')::BOOLEAN, no_notify_pickup),
           admin_note       = CASE WHEN admin_note IS NOT DISTINCT FROM
                                        (SELECT NULLIF(btrim(COALESCE(s.admin_note, '')), '') FROM members s WHERE s.id = v_guest)
                                   THEN v_moved ->> 'tgt_admin_note_before'
                                   ELSE admin_note END,
           updated_at       = NOW(),
           updated_by       = v_operator
     WHERE id = v_real AND tenant_id = v_tenant;
    v_flags_back := TRUE;
  END IF;

  -- ── 來源會員復活 ─────────────────────────────────────────────────────────
  UPDATE members
     SET status                = v_status_to,
         merged_into_member_id = NULL,
         phone_hash            = COALESCE(phone_hash, v_src_hash),
         updated_at            = NOW(),
         updated_by            = v_operator
   WHERE id = v_guest AND tenant_id = v_tenant;

  -- B 路徑漏掉的：合併時搬過去、但之後 updated_at 被覆蓋而推不回來的訂單。
  -- 沒辦法精算，至少把「目標身上還有多少張單」給出去讓人核對。
  IF v_recon THEN
    SELECT count(*) INTO v_left FROM customer_orders
     WHERE tenant_id = v_tenant AND member_id = v_real;
  END IF;

  UPDATE member_merges
     SET reverted_at = NOW(), reverted_by = v_operator, reverted_reason = p_reason
   WHERE id = p_merge_id;

  INSERT INTO member_audit_log (
    tenant_id, entity_type, entity_id, action, before_value, after_value, reason, operator_id
  ) VALUES (
    v_tenant, 'merge', p_merge_id, 'unmerge',
    jsonb_build_object('primary_member_id', v_real, 'merged_member_id', v_guest,
                       'points_moved', v_mm.points_moved, 'wallet_moved', v_mm.wallet_moved,
                       'cards_moved', v_mm.cards_moved, 'merged_at', v_mm.created_at),
    jsonb_build_object('reconstructed', v_recon, 'orders', v_n_orders, 'aliases', v_n_alias,
                       'tags', v_n_tags, 'cards', v_n_cards,
                       'points_ledger', v_n_pl, 'wallet_ledger', v_n_wl,
                       'restored_status', v_status_to, 'operator_role', v_role),
    p_reason, v_operator
  );

  RETURN jsonb_build_object(
    'merge_id',            p_merge_id,
    'source_member_id',    v_guest,
    'target_member_id',    v_real,
    'reconstructed',       v_recon,
    'orders_restored',     v_n_orders,
    -- 清單裡有、但實際沒搬回來的（合併後又被搬去第三個人身上）。
    -- 兩個數字不一樣時 UI 要講出來，不能只報成功。
    'orders_expected',     COALESCE(array_length(v_order_ids, 1), 0),
    'aliases_restored',    v_n_alias,
    'tags_restored',       v_n_tags,
    'cards_restored',      v_n_cards,
    'phone_restored',      v_src_hash IS NOT NULL,
    'flags_restored',      v_flags_back,
    'points_restored',     v_mm.points_moved,
    'wallet_restored',     v_mm.wallet_moved,
    'restored_status',     v_status_to,
    -- 只有 B 路徑給：目標名下剩餘的訂單總數，供人工核對有沒有漏搬
    'target_orders_total', CASE WHEN v_recon THEN v_left ELSE NULL END
  );
END;
$function$;

-- ================= 3. 註冊時同店同 6 碼的真奧客 → 新帳號直接黑名單 =================
-- 「真的奧客」判斷：備註非空，且不是「這筆舊的別用了」那幾種寫法。改字只改這裡。
CREATE OR REPLACE FUNCTION public._member_blacklist_is_ban(p_admin_note TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE
AS $$
  SELECT NULLIF(btrim(COALESCE(p_admin_note, '')), '') IS NOT NULL
     AND p_admin_note !~ '找不到人|未合併|換帳號|換過|被盜';
$$;

CREATE OR REPLACE FUNCTION public._members_inherit_blacklist()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_codes  TEXT[];
  v_hit    RECORD;
BEGIN
  IF COALESCE(NEW.no_new_order, FALSE)
     OR COALESCE(NEW.member_type, 'full') = 'store_internal'
     OR NEW.home_store_id IS NULL
     OR NULLIF(btrim(COALESCE(NEW.name, '')), '') IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT x[1]), '{}') INTO v_codes
    FROM regexp_matches(NEW.name, '((?<![0-9])[0-9]{6}(?![0-9]))', 'g') x;
  IF COALESCE(array_length(v_codes, 1), 0) = 0 THEN
    RETURN NEW;
  END IF;

  SELECT m.member_no, m.name, m.admin_note, m.no_notify_pickup, c.code
    INTO v_hit
    FROM unnest(v_codes) AS c(code)
    JOIN members m
      ON m.tenant_id = NEW.tenant_id
     AND m.home_store_id = NEW.home_store_id
     AND m.no_new_order
     AND m.status NOT IN ('merged', 'deleted')
     AND m.name ~ ('(?<![0-9])' || c.code || '(?![0-9])')
   WHERE public._member_blacklist_is_ban(m.admin_note)
   ORDER BY m.id
   LIMIT 1;

  IF v_hit.member_no IS NOT NULL THEN
    NEW.no_new_order     := TRUE;
    NEW.no_notify_pickup := COALESCE(NEW.no_notify_pickup, FALSE) OR COALESCE(v_hit.no_notify_pickup, FALSE);
    NEW.admin_note       := '自動黑名單：同店 ' || v_hit.member_no || '（' || COALESCE(v_hit.name, '') || '）同 6 碼 '
                            || v_hit.code || '，備註「' || btrim(v_hit.admin_note) || '」，請確認後合併帳號'
                            || COALESCE('；' || NULLIF(btrim(COALESCE(NEW.admin_note, '')), ''), '');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_members_inherit_blacklist ON public.members;
CREATE TRIGGER trg_members_inherit_blacklist
  BEFORE INSERT ON public.members
  FOR EACH ROW EXECUTE FUNCTION public._members_inherit_blacklist();

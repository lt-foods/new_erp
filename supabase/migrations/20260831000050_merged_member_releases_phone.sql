-- ============================================================================
-- 被合併掉的舊帳號不可以繼續佔著手機號碼
--
-- 災情（2026-08-31 林口店）：店員幫客人補手機，按儲存一律跳
--   「資料重複衝突(uniq_members_tenant_phone_hash_partial)」，
--   而畫面上、搜尋裡都找不到那支號碼被誰用走 —— 因為佔號的那筆
--   status='merged'（虛擬帳號併入 LINE 會員後的殘骸），全站的查詢
--   通通把它濾掉了：
--     liff-api lookupByPhone / registerAndBind：.not("status","in","(deleted,merged)")
--     rpc_search_members / rpc_resolve_member：一樣排除 merged
--   唯獨 uniq_members_tenant_phone_hash_partial 不排除。查得到的人都說沒人用，
--   存下去卻一定撞 —— 店員無解，只能回報「所有的手機號碼輸入後都有錯誤訊息」。
--   實例：M024298「#11245851 :【李菁】025744-林口女」(merged, 0919025744)
--         擋住 M20260831101500738「李菁 025744-林口」(active, 綁了 LINE)。
--   線上 83 筆 merged 殘骸各佔一支號碼，其中 24 筆的「活人本尊」根本沒有手機。
--   （status='deleted' 沒事：rpc_member_gdpr_delete 早就改寫成 'DELETED_'||id 讓號。）
--
-- 改法 —— 讓「死號不持有 phone_hash」變成硬性不變式：
--   1. rpc_merge_member：來源標 merged 的同時 phone_hash 清成 NULL；目標若還沒有
--      手機，就把號碼交棒過去（合併＝同一個人，號碼跟著活著的帳號走）。
--      phone 原文留在來源身上備查／供復原。
--   2. rpc_unmerge_member：復原時把號碼還回來源（交棒過的先從目標收回；
--      期間若已被別人用走就不還，只是不還，不擋復原）。
--   3. rpc_upsert_member：撞號時先看對手是誰 ——
--        merged/deleted → 就地讓號後照存（自癒，含本次修復前留下的舊殘骸）；
--        還活著的會員   → 改吐點得出名字的錯誤（誰佔走了、該去合併還是打錯字），
--      不要再讓店員看到 index 名稱。
--   4. Backfill 83 筆 + 加 CHECK 讓下次寫回去的路徑當場炸掉。
--
-- 基底版本（＝線上 pg_get_functiondef 抓下來的版本，逐字比對過）：
--   rpc_merge_member    → 20260809000010（記 moved 版）
--   rpc_unmerge_member  → 20260809000070（開放店長版）
--   rpc_upsert_member   → 20260829000010（改取貨店守衛版）
-- rollback：重跑上面三支 migration，並
--   ALTER TABLE members DROP CONSTRAINT members_merged_holds_no_phone_hash;
--   （backfill 不可逆，也不需要逆 —— 死號本來就不該持有號碼）
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
BEGIN
  v_operator := COALESCE(p_operator, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);

  SELECT tenant_id, line_user_id, status
    INTO v_tenant, v_src_line, v_src_status
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
      'phone_moved_to_target', v_phone_moved
    )
  );
END;
$function$
;

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
    'points_restored',     v_mm.points_moved,
    'wallet_restored',     v_mm.wallet_moved,
    'restored_status',     v_status_to,
    -- 只有 B 路徑給：目標名下剩餘的訂單總數，供人工核對有沒有漏搬
    'target_orders_total', CASE WHEN v_recon THEN v_left ELSE NULL END
  );
END;
$function$
;

-- ================= 3. rpc_upsert_member =================
CREATE OR REPLACE FUNCTION public.rpc_upsert_member(
  p_id            BIGINT,
  p_member_no     TEXT,
  p_phone         TEXT,
  p_name          TEXT,
  p_gender        TEXT DEFAULT NULL,
  p_birthday      DATE DEFAULT NULL,
  p_email         TEXT DEFAULT NULL,
  p_tier_id       BIGINT DEFAULT NULL,
  p_home_store_id BIGINT DEFAULT NULL,
  p_status        TEXT DEFAULT 'active',
  p_notes         TEXT DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_id          BIGINT;
  v_phone       TEXT := NULLIF(btrim(p_phone), '');
  v_phone_hash  TEXT;
  v_email_hash  TEXT;
  v_birth_md    TEXT;
  v_old_store   BIGINT;
  v_open_orders INT;
  v_stores      TEXT;
  v_cur_status  TEXT;
  v_dup_id      BIGINT;
  v_dup_no      TEXT;
  v_dup_name    TEXT;
  v_dup_status  TEXT;
BEGIN
  IF p_name IS NULL OR p_name = '' THEN
    RAISE EXCEPTION 'name is required';
  END IF;

  v_phone_hash := CASE WHEN v_phone IS NOT NULL
                       THEN encode(digest(v_phone, 'sha256'), 'hex')
                  END;
  v_email_hash := CASE WHEN p_email IS NOT NULL AND p_email <> ''
                       THEN encode(digest(lower(p_email), 'sha256'), 'hex')
                  END;
  v_birth_md   := CASE WHEN p_birthday IS NOT NULL
                       THEN to_char(p_birthday, 'MM-DD')
                  END;

  IF p_tier_id IS NOT NULL THEN
    PERFORM 1 FROM member_tiers WHERE id = p_tier_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'tier % not in tenant', p_tier_id; END IF;
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT home_store_id, status INTO v_old_store, v_cur_status
      FROM members WHERE id = p_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_id; END IF;
  END IF;

  -- 死號不持有 phone_hash（見檔頭）：連編輯路徑也一起守住，
  -- 免得從畫面上把一筆 merged 會員存回去時撞 CHECK。
  IF COALESCE(p_status, v_cur_status, 'active') IN ('merged', 'deleted') THEN
    v_phone_hash := NULL;
  END IF;

  -- ── 手機撞號：先問清楚是誰佔走的 ─────────────────────────────────────────
  -- 以前直接讓 unique index 炸出來，畫面只給得出 index 名稱；而佔號的多半是
  -- merged 殘骸 —— 店員在任何地方都查不到那支號碼，等於無解。
  IF v_phone_hash IS NOT NULL THEN
    SELECT id, member_no, name, status
      INTO v_dup_id, v_dup_no, v_dup_name, v_dup_status
      FROM members
     WHERE tenant_id = v_tenant
       AND phone_hash = v_phone_hash
       AND (p_id IS NULL OR id <> p_id)
     LIMIT 1;
    IF FOUND THEN
      IF v_dup_status IN ('merged', 'deleted') THEN
        -- 自癒：本次修復前留下的殘骸就地讓號，讓現役會員拿回自己的號碼
        UPDATE members
           SET phone_hash = NULL, updated_at = NOW(), updated_by = auth.uid()
         WHERE id = v_dup_id;
      ELSE
        RAISE EXCEPTION '手機 % 已經是會員「%」(%) 的號碼。同一個人請用「合併會員」把兩筆併起來，不同人請確認號碼有沒有輸錯。',
          v_phone, COALESCE(NULLIF(btrim(v_dup_name), ''), '未命名'), v_dup_no;
      END IF;
    END IF;
  END IF;

  IF p_id IS NULL THEN
    DECLARE
      v_member_no TEXT    := NULLIF(btrim(p_member_no), '');
      v_explicit  BOOLEAN := NULLIF(btrim(p_member_no), '') IS NOT NULL;
      v_try       INT     := 0;
    BEGIN
      LOOP
        IF v_member_no IS NULL THEN
          v_member_no := public.rpc_next_member_no();
        END IF;
        BEGIN
          INSERT INTO members (
            tenant_id, member_no, phone_hash, phone, email_hash, email,
            name, birthday, birth_md, gender, tier_id, home_store_id,
            status, notes, created_by, updated_by
          ) VALUES (
            v_tenant, v_member_no, v_phone_hash, v_phone, v_email_hash, p_email,
            p_name, p_birthday, v_birth_md, p_gender, p_tier_id, p_home_store_id,
            COALESCE(p_status, 'active'), p_notes, auth.uid(), auth.uid()
          ) RETURNING id INTO v_id;
          EXIT;
        EXCEPTION WHEN unique_violation THEN
          IF v_explicit THEN
            RAISE EXCEPTION '會員編號 % 已存在', v_member_no
              USING ERRCODE = 'unique_violation';
          END IF;
          v_try := v_try + 1;
          IF v_try > 10 THEN RAISE; END IF;
          v_member_no := NULL;  -- 重新自動產號重試
        END;
      END LOOP;
    END;
  ELSE
    -- v_old_store / v_cur_status 已在上面取好（撞號檢查要先知道 status）
    IF v_old_store IS DISTINCT FROM p_home_store_id THEN
      SELECT COUNT(*), string_agg(DISTINCT COALESCE(s.name, '未指定門市'), '、')
        INTO v_open_orders, v_stores
        FROM customer_orders co
        LEFT JOIN stores s ON s.id = co.pickup_store_id
       WHERE co.tenant_id = v_tenant
         AND co.member_id = p_id
         AND co.status NOT IN ('completed','cancelled','expired','transferred_out')
         AND co.pickup_store_id IS DISTINCT FROM p_home_store_id;
      IF v_open_orders > 0 THEN
        RAISE EXCEPTION '會員在「%」還有 % 筆未取貨訂單，請先處理完才能改取貨店', v_stores, v_open_orders;
      END IF;
    END IF;

    UPDATE members SET
      member_no     = COALESCE(p_member_no, member_no),
      phone_hash    = v_phone_hash,
      phone         = v_phone,
      email_hash    = v_email_hash,
      email         = p_email,
      name          = COALESCE(p_name, name),
      birthday      = p_birthday,
      birth_md      = v_birth_md,
      gender        = p_gender,
      tier_id       = p_tier_id,
      home_store_id = p_home_store_id,
      status        = COALESCE(p_status, status),
      notes         = p_notes,
      updated_by    = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'member % not in tenant', p_id; END IF;
  END IF;

  RETURN v_id;
END;
$function$
;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_member(
  BIGINT, TEXT, TEXT, TEXT, TEXT, DATE, TEXT, BIGINT, BIGINT, TEXT, TEXT
) TO authenticated;

-- ================= 4. Backfill：把 83 支被死號扣住的號碼放出來 =================
-- 逐筆做，不寫成一句 UPDATE：unique index 是逐句即時檢查，
-- 「來源讓號 + 目標接手」寫在同一句會撞在自己身上。
DO $backfill$
DECLARE
  r RECORD;
  v_moved INT := 0;
  v_freed INT := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT ON (s.merged_into_member_id)
           s.id AS src_id, s.tenant_id, s.merged_into_member_id AS tgt_id,
           s.phone, s.phone_hash
      FROM members s
      JOIN members t ON t.id = s.merged_into_member_id AND t.tenant_id = s.tenant_id
     WHERE s.status = 'merged'
       AND s.phone_hash IS NOT NULL
       AND t.phone_hash IS NULL          -- 本尊還沒有手機 → 號碼交棒過去
     ORDER BY s.merged_into_member_id, s.updated_at DESC NULLS LAST, s.id DESC
  LOOP
    UPDATE members SET phone_hash = NULL WHERE id = r.src_id;
    UPDATE members
       SET phone      = COALESCE(phone, r.phone),
           phone_hash = r.phone_hash,
           updated_at = NOW()
     WHERE id = r.tgt_id AND phone_hash IS NULL;
    v_moved := v_moved + 1;

    INSERT INTO member_audit_log (
      tenant_id, entity_type, entity_id, action, before_value, after_value, reason, operator_id
    ) VALUES (
      r.tenant_id, 'member', r.tgt_id, 'phone_reclaimed_from_merged',
      jsonb_build_object('phone', NULL),
      jsonb_build_object('phone', r.phone, 'from_member_id', r.src_id),
      '合併後手機留在被併掉的舊帳號上，導致本尊存不進同一支號碼（20260831000050）',
      '00000000-0000-0000-0000-000000000000'::uuid
    );
  END LOOP;

  -- 其餘（本尊已有別的號碼／找不到本尊）：只讓號，phone 原文留著備查
  UPDATE members SET phone_hash = NULL, updated_at = NOW()
   WHERE status = 'merged' AND phone_hash IS NOT NULL;
  GET DIAGNOSTICS v_freed = ROW_COUNT;

  RAISE NOTICE 'phone handed back to live member: %, merged rows freed: %', v_moved, v_freed;
END
$backfill$;

-- ================= 5. 不變式：merged 不得持有 phone_hash =================
-- 這是這次災情唯一「下次還會再犯」的點：只要有任何路徑把會員標成 merged 卻沒讓號，
-- 症狀就是查不到主人的撞號。與其靠人記得，不如當場炸掉。
-- （deleted 用 'DELETED_'||id 哨兵值佔位，本來就不會擋到真號碼，不列入。）
ALTER TABLE members
  ADD CONSTRAINT members_merged_holds_no_phone_hash
  CHECK (status <> 'merged' OR phone_hash IS NULL);

COMMENT ON CONSTRAINT members_merged_holds_no_phone_hash ON members IS
  '被合併掉的帳號不可持有 phone_hash：全站查詢都排除 merged，unique index 不排除，'
  '留著就是一支查不到主人、誰也存不進去的號碼（20260831000050）';

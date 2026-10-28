-- ============================================================================
--  02 取消 73 張（✅ 會改資料）
--  限量團超賣：GRP-20261015-024 洗面乳 42 張、GRP-20261016-048 辣椒醬 17 張、GRP-20261021-018 微燻李 14 張
--  ⇒ 逐張呼叫後台訂單頁紅色「取消」鈕背後那一支 rpc_cancel_aid_order，效果＝老闆一張一張按
--  日期：2026-10-28　阿寫寫、⛔ 阿審（Codex）審過之前不要貼
--  名單出處：公司\01_進行中\超賣名單_洗面乳辣椒醬微燻李_與全站掃描_2026-10-28.md
--  程式出處：工地 git origin/main 3248064c supabase/migrations/（行號寫在各段）
-- ============================================================================
--  ★ 這份在做什麼（整份只有一個 DO 區塊＝同一次；任何一步不對就整筆取消、什麼都沒改）
--    ① 先檢查（任何寫入之前）：三個團各剛好一個、同一家公司；名單 73 張＋0040、保留的 48 張都找得到；
--       要取消的單狀態只能是 待確認／已確認／出貨中（取消鈕自己的規則，20260826000010:73-77）或已取消（跳過）；
--       名單外不能有別的有效單；保留的單合計 5／34／21 件；要退儲值金的會員是正常狀態；
--       0040 復活時不會撞「一人一團一張」。不對 → 紅字【停】，什麼都沒改。
--    ② 逐張 PERFORM rpc_cancel_aid_order(訂單, '限量超賣：2026-10-28 老闆核准批次取消', 操作人)。
--       順序：一般單（含內部單 INT0047）照訂單編號 → TF0001 → 0040。
--       取消鈕本身會：單頭改已取消、蓋取消時間；用了儲值金的自動退回（:203-215）；
--       出貨中的互助單作廢調撥鏈（:115-200）；互助板帶來的量還回貼文（:85-110）。
--       ⚠ 它不改品項（品項維持等貨中）——系統所有「算已售／算需求」的地方都先排除已取消的單頭，見下方 Q1-b。
--    ③ 每張另寫一列編輯歷史 customer_order_audit_log（order／status／取消前狀態 → cancelled，原因固定那一句）：
--       取消鈕本身不寫編輯歷史（機制索引「查誰取消訂單」：20260826000010:231-236 只寫 cancelled_at＋updated_by），
--       這一列只是讓 04 確認、05 還原、重貼判斷認得出「這一次」做的是哪幾張，⛔ 原因不要改字。
--    ④ 自我驗算（同一個 DO 區塊裡、寫完再讀；不對就整筆取消）：
--       73 張＋0040 都是已取消；三團有效件數＝5／34／21；保留的 48 張狀態與修改時間沒變；
--       這三團以外沒有任何訂單在這一刻被改到；0040 的「轉去哪張」已清空。
--  ★ 取消後的件數是 5／34／21，不是 6／34／22：
--    洗面乳 0006（古華 6 件）、微燻李 0018（忠順 2 件）各有 1 件原本在上限內，但老闆決定整張取消、
--    之後自己用後台加單各補 1 件 → 補完才是 6／34／22（不在這份範圍）。
--  ★ 轉入單 TF0001（辣椒醬，經國店）：
--    它是 0040 整張轉出去的。取消 TF0001 時，取消鈕會把 0040 從「已轉出」退回「已確認」
--    （20260826000010:248-256；貨已到店的話還會直接推成「可取貨」:258-267）——等於超賣的那 1 張又活回來。
--    ⇒ 02 取消 TF0001 之後，接著取消 0040。0040 若被推成「可取貨」，取消鈕不收（:73-77）→ 【停】整筆回滾，改人工處理。
--    TF0001 身上的品項：整單轉出時原單品項沒被動過，_restore_transfer_source_items 判到就跳過、回 0
--    （20260818000030:58-93、:139-141），TF0001 的品項維持等貨中（跟其他 71 張一樣只停在單頭）；
--    部分轉出的話它會把量還回 0040、TF0001 的品項標已取消（:97-148），0040 之後一樣被取消。兩種最後辣椒醬都是 34 件。
--  ★ 要填的一行：下面 DECLARE 裡的 p_operator（操作人＝老闆本人的使用者 UUID，01 第⑥段列出，
--    CEO 在老闆確認後填）。⛔ 交件時刻意留空；空的、或不是這家公司的總部帳號，會直接【停】。
--  ★ 重貼：已經是已取消的單會跳過；73 張＋0040 全部已取消 → 顯示「已經做過，這次什麼都沒改」然後結束。
--  ★ 看到什麼要停：
--    ・紅字開頭【停】→ 什麼都沒改，截圖給 CEO（紅字會寫是哪一項不對）；⛔ 不要重貼
--    ・紅字寫 lock timeout／有人正在操作 → 什麼都沒改，過幾分鐘再貼一次；連續兩三次都這樣，截圖給 CEO
--    ・其他紅字（例如英文的 order ... is ready）→ 什麼都沒改，截圖給 CEO
--    ・Supabase 可能只顯示「Success. No rows returned」→ 正常，接著貼 04
--  ★ 做錯了怎麼辦：05（還原，備用）。
-- ============================================================================
--  開工前四問（2026-10-28 阿寫查；證據都是工地 git origin/main 3248064c 的檔:行）
--  Q1 這件事系統有沒有現成的做法？會連動什麼？
--    a. 現成做法＝後台訂單頁「取消」鈕：apps/admin/src/app/(protected)/orders/page.tsx:810-832、
--       apps/admin/src/components/OrderDetail.tsx:842-846，都是 sb.rpc("rpc_cancel_aid_order", {p_order_id, p_reason, p_operator: 登入者 id})。
--       這份照呼叫同一支，不另寫取消邏輯。
--       rpc_cancel_aid_order 最新定義 20260826000010:26（SECURITY DEFINER；GRANT authenticated :283）。
--       函式本體與它呼叫的 _restore_transfer_source_items（20260818000030:44）、_restore_aid_board_qty（20260824080000:22）、
--       rpc_wallet_refund（20260606000000:9）、is_order_pickup_ready（20260704000000:137）都沒有 auth.uid()／auth.jwt() 檢查
--       → SQL Editor（postgres 角色）呼叫得動；p_operator 只拿來寫 updated_by／退款紀錄操作人。
--       ⇒ 所以要由這份自己檢查操作人是總部帳號（取消鈕在前端靠「已登入」把關，函式不檢查）。
--    b. 只改單頭、不改品項，會不會還被算成已售／需求？逐支查過，全部先排除已取消的單頭：
--       ・商城上限檢查 rpc_place_member_order_guarded（最新 20261013000000:1096）：整團 :1220-1221、品項 :1253-1254
--         co.status NOT IN ('cancelled','expired','transferred_out') AND coi.status NOT IN ('cancelled','expired')
--       ・PR #1094 後台／記事本上限檢查 _campaign_cap_remaining（本分支 20261028000000:156，:176-177）同一套
--       ・請購單「同步最新開團數量」rpc_sync_pr_qty（20261001000000:785）→ _pr_qty_sync_preview 的需求來源
--         _pr_campaign_sku_remaining_rows（唯一版本 20260921001000:240）：:272 co.status NOT IN ('cancelled','expired','transferred_out')
--       ・派貨需求 v_picking_demand_by_po（最新 20261016000000:932）：:981 同上
--       ⇒ 單頭已取消、品項還等貨中的，上面四處都不算。
--    c. customer_orders 上的觸發器：trg_touch_corders（改到的單頭蓋修改時間，20260423120000:329）、
--       trg_release_idn_coverage（單頭變已取消時釋放庫存減抵單覆蓋，20260813002000:173-179）——跟手按取消鈕一樣會跑。
--  Q2 最新版：rpc_cancel_aid_order 共 9 支定義，最後一支 20260826000010:26（git grep -nE "CREATE (OR REPLACE )?FUNCTION (public\.)?rpc_cancel_aid_order\b"）。
--    _restore_transfer_source_items 只有 1 支（20260818000030:44）。
--    編輯歷史欄位白名單 customer_order_audit_log_field_check 最新 20260902040000:58-63（含 'status'）；entity_type 只收 order／item（20260605000001:12）。
--  Q3 還有誰在用：這份不改任何函式／表／觸發器，只「呼叫」取消鈕那支、加編輯歷史。
--  Q4 撞車：只新增 scripts/PROD-oversell-cancel-2026-10/ 底下的檔，不改任何既有檔。
--    開著的 PR 有沒有動到同一批資料：阿寫不准連 GitHub，⚠ 沒查，由 CEO 查。
-- ============================================================================

DO $oversell$
DECLARE
  -- ╔════════ 要填的一行（CEO 在老闆確認後填）════════╗
  p_operator      uuid := NULL;   -- ⬅ 操作人：01 第⑥段列出、老闆確認過的本人 UUID，例如 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'；⛔ 空的會直接停
  -- ╚════════════════════════════════════════════════╝
  -- ⛔ 下面這句是「這一次」的身分證，01／04／05 逐字相同，不要改字
  c_tag           CONSTANT text := '限量超賣：2026-10-28 老闆核准批次取消';
  c_tf_no         CONSTANT text := 'GRP-20261016-048-TF0001';
  c_src_no        CONSTANT text := 'GRP-20261016-048-0040';
  v_now           timestamptz := now();
  v_tenant        uuid;
  v_cnt           int;
  v_bad           text;
  v_cancel_nos    text[];     -- 73 張（洗面乳 42＋辣椒醬 17＋微燻李 14；需求單寫 72 是加總筆誤）
  v_keep_nos      text[];     -- 48 張
  v_camp_ids      bigint[];
  v_tf_id         bigint;
  v_src_id        bigint;
  v_keep_snap     jsonb;
  v_ret           jsonb;
  v_before        text;
  n_done          int := 0;
  n_skip          int := 0;
  n_wallet        int := 0;
  v_wallet_amt    numeric := 0;
  r               record;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  -- ── 0. 操作人 ──
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '【停】操作人 p_operator 是空的。要由 CEO 把老闆確認過的本人 UUID 填進去再貼。什麼都沒改。';
  END IF;

  -- ── 1. 名單 ──
  v_cancel_nos :=
       ARRAY(SELECT 'GRP-20261015-024-' || lpad(n::text, 4, '0') FROM generate_series(6, 46) n ORDER BY n)
    || ARRAY['GRP-20261015-024-INT0047']
    || ARRAY(SELECT 'GRP-20261016-048-' || lpad(n::text, 4, '0') FROM generate_series(27, 43) n WHERE n <> 40 ORDER BY n)
    || ARRAY[c_tf_no]
    || ARRAY(SELECT 'GRP-20261021-018-' || lpad(n::text, 4, '0') FROM generate_series(18, 31) n ORDER BY n);
  v_keep_nos :=
       ARRAY(SELECT 'GRP-20261015-024-' || lpad(n::text, 4, '0') FROM generate_series(1, 5) n ORDER BY n)
    || ARRAY(SELECT 'GRP-20261016-048-' || lpad(n::text, 4, '0') FROM generate_series(1, 26) n ORDER BY n)
    || ARRAY(SELECT 'GRP-20261021-018-' || lpad(n::text, 4, '0') FROM generate_series(1, 17) n ORDER BY n);
  IF cardinality(v_cancel_nos) <> 73 OR cardinality(v_keep_nos) <> 48 THEN
    RAISE EXCEPTION '【停】名單張數算錯（取消 %、保留 %）。什麼都沒改，請截圖給 CEO。', cardinality(v_cancel_nos), cardinality(v_keep_nos);
  END IF;

  -- ── 2. 對象：三個團各剛好一個、同一家公司 ──
  SELECT string_agg(x.no || ' 查到 ' || x.n || ' 個', '、') INTO v_bad
    FROM (SELECT v.no, (SELECT count(*) FROM public.group_buy_campaigns c WHERE c.campaign_no = v.no) AS n
            FROM unnest(ARRAY['GRP-20261015-024', 'GRP-20261016-048', 'GRP-20261021-018']) v(no)) x
   WHERE x.n <> 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】團號不對：%（要各剛好 1 個）。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;
  SELECT array_agg(id ORDER BY id), count(DISTINCT tenant_id), min(tenant_id::text)::uuid
    INTO v_camp_ids, v_cnt, v_tenant
    FROM public.group_buy_campaigns
   WHERE campaign_no IN ('GRP-20261015-024', 'GRP-20261016-048', 'GRP-20261021-018');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】三個團不是同一家公司。什麼都沒改，請截圖給 CEO。';
  END IF;

  -- 操作人要是這家公司的總部帳號（認法同 scripts/PROD-kiehls-cancel-2026-10/02：app_metadata.tenant_id＋總部角色）
  IF NOT EXISTS (SELECT 1 FROM auth.users u
                  WHERE u.id = p_operator
                    AND (u.raw_app_meta_data ->> 'tenant_id') = v_tenant::text
                    AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')) THEN
    RAISE EXCEPTION '【停】操作人 % 不是這家公司的總部帳號（或根本不是登入帳號）。請用 01 第⑥段列出、老闆確認過的本人 UUID。什麼都沒改。', p_operator;
  END IF;

  -- ── 3. 上鎖：三團全部訂單單頭（依 id 排序）──
  BEGIN
    PERFORM 1 FROM public.customer_orders co
      WHERE co.campaign_id = ANY (v_camp_ids)
      ORDER BY co.id
        FOR UPDATE;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION '【停】有人正在操作這幾團的訂單（例如店家正在取貨、改單），等了 15 秒還拿不到。什麼都沒改，請過幾分鐘再貼一次。';
  END;

  -- ── 4. 名單裡的單都要找得到（同團、同公司）──
  SELECT string_agg(v.no, '、') INTO v_bad
    FROM unnest(v_cancel_nos || v_keep_nos || ARRAY[c_src_no]) v(no)
   WHERE NOT EXISTS (SELECT 1 FROM public.customer_orders co
                      WHERE co.order_no = v.no AND co.campaign_id = ANY (v_camp_ids) AND co.tenant_id = v_tenant);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】這幾張單在這三團裡找不到：%。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;
  SELECT id INTO v_tf_id  FROM public.customer_orders WHERE order_no = c_tf_no  AND campaign_id = ANY (v_camp_ids);
  SELECT id INTO v_src_id FROM public.customer_orders WHERE order_no = c_src_no AND campaign_id = ANY (v_camp_ids);

  -- ── 5. 做過了沒（重貼安全）──
  SELECT count(*) INTO v_cnt FROM public.customer_orders
   WHERE order_no = ANY (v_cancel_nos || ARRAY[c_src_no]) AND campaign_id = ANY (v_camp_ids) AND status = 'cancelled';
  IF v_cnt = 74 THEN
    RAISE NOTICE '已經做過（73 張＋0040 都已經是已取消），這次什麼都沒改。請接著貼 04 確認。';
    RETURN;
  END IF;

  -- ── 6. 前置檢查（任何寫入之前）──
  -- 6-1. 要取消的單：狀態只能是 待確認／已確認／出貨中（取消鈕的規則），或已取消（跳過）
  SELECT string_agg(co.order_no || '＝' || co.status, '、' ORDER BY co.order_no) INTO v_bad
    FROM public.customer_orders co
   WHERE co.order_no = ANY (v_cancel_nos) AND co.campaign_id = ANY (v_camp_ids)
     AND co.status NOT IN ('pending', 'confirmed', 'shipping', 'cancelled');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】這幾張的狀態取消鈕不收（只收 待確認／已確認／出貨中）：%。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  -- 6-2. TF0001／0040 的關係
  IF (SELECT transferred_from_order_id FROM public.customer_orders WHERE id = v_tf_id) IS DISTINCT FROM v_src_id THEN
    RAISE EXCEPTION '【停】% 不是從 % 轉來的，跟名單說的不一樣。什麼都沒改，請截圖給 CEO。', c_tf_no, c_src_no;
  END IF;
  SELECT status INTO v_before FROM public.customer_orders WHERE id = v_src_id;
  IF (SELECT status FROM public.customer_orders WHERE id = v_tf_id) <> 'cancelled' THEN
    IF v_before <> 'transferred_out' THEN
      RAISE EXCEPTION '【停】% 還沒取消，但 % 不是「已轉出」（現在是 %）。什麼都沒改，請截圖給 CEO。', c_tf_no, c_src_no, v_before;
    END IF;
  ELSIF v_before NOT IN ('pending', 'confirmed', 'shipping', 'cancelled') THEN
    RAISE EXCEPTION '【停】% 已經取消過、% 現在是 %，取消鈕不收。什麼都沒改，請截圖給 CEO。', c_tf_no, c_src_no, v_before;
  END IF;

  -- 6-3. 0040 退回「已確認」時，不能撞一人一團一張（customer_orders_trio_kind_active_uniq，條件同
  --      rpc_restore_cancelled_order 守衛 5 20261013000000:1541-1558）。名單內的單會先被取消，不算。
  SELECT string_agg(co.order_no, '、') INTO v_bad
    FROM public.customer_orders co, public.customer_orders s
   WHERE s.id = v_src_id AND s.status = 'transferred_out'
     AND COALESCE(s.order_kind, '') <> 'restock'
     AND co.tenant_id = s.tenant_id AND co.campaign_id = s.campaign_id AND co.channel_id = s.channel_id
     AND co.member_id = s.member_id AND co.order_kind = s.order_kind AND co.id <> s.id
     AND co.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND co.order_no NOT LIKE 'SP-%' AND co.order_no NOT LIKE 'WS-%'
     AND co.aid_board_id IS NULL AND co.transferred_from_order_id IS NULL
     AND co.order_no <> ALL (v_cancel_nos);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】% 復活時會跟同一位客人在這團的 % 撞在一起（一人一團一張）。什麼都沒改，請截圖給 CEO。', c_src_no, v_bad;
  END IF;

  -- 6-4. 名單外不能有別的有效單（例如 10/28 查完之後又有人加單）
  SELECT string_agg(co.order_no, '、' ORDER BY co.order_no) INTO v_bad
    FROM public.customer_orders co
   WHERE co.campaign_id = ANY (v_camp_ids)
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND co.order_no <> ALL (v_cancel_nos || v_keep_nos || ARRAY[c_src_no]);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】名單外還有有效的單：%。名單要重查，什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  -- 6-5. 保留的單：都還有效、合計 5／34／21 件（有效＝單頭、品項都不是已取消／已過期，單頭也不是已轉出）
  SELECT string_agg(co.order_no || '＝' || co.status, '、') INTO v_bad
    FROM public.customer_orders co
   WHERE co.order_no = ANY (v_keep_nos) AND co.campaign_id = ANY (v_camp_ids)
     AND co.status IN ('cancelled', 'expired', 'transferred_out');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】要保留的單已經不是有效的：%。名單要重查，什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;
  SELECT string_agg(x.no || ' ' || trim_scale(x.q) || ' 件（應為 ' || trim_scale(x.want) || '）', '、') INTO v_bad
    FROM (SELECT v.no, v.want,
                 (SELECT COALESCE(sum(i.qty), 0)
                    FROM public.customer_orders co JOIN public.customer_order_items i ON i.order_id = co.id
                    JOIN public.group_buy_campaigns c ON c.id = co.campaign_id
                   WHERE c.campaign_no = v.no AND co.order_no = ANY (v_keep_nos)
                     AND i.status NOT IN ('cancelled', 'expired')) AS q
            FROM (VALUES ('GRP-20261015-024', 5::numeric), ('GRP-20261016-048', 34::numeric), ('GRP-20261021-018', 21::numeric)) v(no, want)) x
   WHERE x.q <> x.want;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】保留的單件數不對：%。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  -- 6-6. 要退儲值金的，會員要是正常狀態（退款函式只退 active 會員，20260606000000:31-37）
  SELECT string_agg(co.order_no, '、') INTO v_bad
    FROM public.customer_orders co LEFT JOIN public.members m ON m.id = co.member_id
   WHERE co.order_no = ANY (v_cancel_nos || ARRAY[c_src_no]) AND co.campaign_id = ANY (v_camp_ids)
     AND co.status <> 'cancelled'
     AND COALESCE(co.wallet_paid_amount, 0) > 0 AND co.member_id IS NOT NULL
     AND COALESCE(m.status, '') <> 'active';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】這幾張用了儲值金，但會員不是正常狀態、退不回去：%。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  -- 記下保留的 48 張現況（寫完要一模一樣）
  SELECT jsonb_object_agg(co.id::text, jsonb_build_array(co.status, co.updated_at)) INTO v_keep_snap
    FROM public.customer_orders co
   WHERE co.order_no = ANY (v_keep_nos) AND co.campaign_id = ANY (v_camp_ids);

  -- ── 7. 逐張取消：一般單（照訂單編號）→ TF0001 → 0040 ──
  FOR r IN
    SELECT co.id, co.order_no, 1 AS step FROM public.customer_orders co
     WHERE co.order_no = ANY (v_cancel_nos) AND co.campaign_id = ANY (v_camp_ids) AND co.id <> v_tf_id
    UNION ALL SELECT v_tf_id, c_tf_no, 2
    UNION ALL SELECT v_src_id, c_src_no, 3
    ORDER BY step, order_no
  LOOP
    SELECT status INTO v_before FROM public.customer_orders WHERE id = r.id;
    IF v_before = 'cancelled' THEN
      n_skip := n_skip + 1;
      CONTINUE;
    END IF;
    IF v_before NOT IN ('pending', 'confirmed', 'shipping') THEN
      -- 只有 0040 會走到這裡（第 6 步已擋其他）：取消 TF0001 時被系統直接推成「可取貨」
      RAISE EXCEPTION '【停】取消 % 之後，% 被系統退回成「%」（貨已經到店），取消鈕不收這個狀態。整筆取消、什麼都沒改；這一張要人工處理，請截圖給 CEO。',
        c_tf_no, r.order_no, v_before;
    END IF;

    v_ret := public.rpc_cancel_aid_order(r.id, c_tag, p_operator);
    n_done := n_done + 1;
    IF COALESCE((v_ret ->> 'wallet_refunded')::numeric, 0) > 0 THEN
      n_wallet := n_wallet + 1;
      v_wallet_amt := v_wallet_amt + (v_ret ->> 'wallet_refunded')::numeric;
    END IF;

    INSERT INTO public.customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field, before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_tenant, r.id, 'order', r.id, 'status', to_jsonb(v_before), to_jsonb('cancelled'::text), c_tag, p_operator
    );
  END LOOP;

  -- ── 8. 自我驗算（不對就整筆取消）──
  SELECT string_agg(co.order_no || '＝' || co.status, '、') INTO v_bad
    FROM public.customer_orders co
   WHERE co.order_no = ANY (v_cancel_nos || ARRAY[c_src_no]) AND co.campaign_id = ANY (v_camp_ids)
     AND co.status <> 'cancelled';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】驗算不過：這幾張沒有變成已取消：%。整筆取消、什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  SELECT string_agg(x.no || ' 剩 ' || trim_scale(x.q) || ' 件（應為 ' || trim_scale(x.want) || '）', '、') INTO v_bad
    FROM (SELECT v.no, v.want,
                 (SELECT COALESCE(sum(i.qty), 0)
                    FROM public.customer_orders co JOIN public.customer_order_items i ON i.order_id = co.id
                    JOIN public.group_buy_campaigns c ON c.id = co.campaign_id
                   WHERE c.campaign_no = v.no
                     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
                     AND i.status NOT IN ('cancelled', 'expired')) AS q
            FROM (VALUES ('GRP-20261015-024', 5::numeric), ('GRP-20261016-048', 34::numeric), ('GRP-20261021-018', 21::numeric)) v(no, want)) x
   WHERE x.q <> x.want;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】驗算不過：取消後有效件數不對：%。整筆取消、什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  SELECT string_agg(co.order_no, '、') INTO v_bad
    FROM public.customer_orders co
   WHERE co.order_no = ANY (v_keep_nos) AND co.campaign_id = ANY (v_camp_ids)
     AND (v_keep_snap -> co.id::text) IS DISTINCT FROM jsonb_build_array(co.status, co.updated_at);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】驗算不過：保留的單被動到了：%。整筆取消、什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  SELECT string_agg(co.order_no, '、') INTO v_bad
    FROM public.customer_orders co
   WHERE co.updated_at = v_now
     AND co.order_no <> ALL (v_cancel_nos || ARRAY[c_src_no]);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '【停】驗算不過：名單以外的訂單在這一刻被改到：%。整筆取消、什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  IF (SELECT transferred_to_order_id FROM public.customer_orders WHERE id = v_src_id) IS NOT NULL THEN
    RAISE EXCEPTION '【停】驗算不過：% 還掛著「轉去哪張」。整筆取消、什麼都沒改，請截圖給 CEO。', c_src_no;
  END IF;

  RAISE NOTICE '完成：這次取消 % 張（73 張超賣單＋0040 轉出原單，已經是取消的跳過 % 張）；儲值金自動退回 % 張、共 % 元。三團有效件數 5／34／21。請接著貼 04。',
    n_done, n_skip, n_wallet, trim_scale(v_wallet_amt);
END
$oversell$;

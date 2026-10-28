-- ============================================================================
-- cap_check_20261028_todo_verification.sql —— 限量「只加部分」的留言要進待處理（20261028000000 第 4、5 段）
-- ⛔ 只在本機臨時庫跑。會寫入資料。
--
-- 順序（空的臨時庫）：
--   1. cap_check_20261028_local_fixture.sql ＋ 檔頭列的逐字函式（含三參數 _line_note_comment_is_todo、
--      20260929000000 的 rpc_line_note_campaign_targets、20260928000000:27 的 _line_note_settle_keyed_comments）
--   2. 本檔「第一段」（:phase = 'before'）：灌資料、把舊版群組清單的輸出存進 _targets_before
--   3. 貼 migration
--   4. 本檔「第二段」（:phase = 'after'）
--   psql -v phase=before -f 本檔 → 貼 migration → psql -v phase=after -f 本檔
-- ============================================================================
\set ON_ERROR_STOP 1
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"00000000-0000-0000-0000-000000000001","app_metadata":{"tenant_id":"00000000-0000-0000-0000-000000000001","role":"admin"}}', false) \gset

\if :{?phase}
\else
  \echo '請帶 -v phase=before 或 -v phase=after'
  \quit
\endif

SELECT :'phase' = 'before' AS is_before \gset
\if :is_before
-- ── 第一段：資料（團 70 整團 2、一個品項；兩個社群各一篇貼文）＋ 舊版輸出快照 ──
INSERT INTO tenants VALUES ('00000000-0000-0000-0000-000000000001','active') ON CONFLICT DO NOTHING;
INSERT INTO stores (id, tenant_id, name) VALUES (1,'00000000-0000-0000-0000-000000000001','總部') ON CONFLICT DO NOTHING;
INSERT INTO line_channels (id, tenant_id, home_store_id) VALUES (1,'00000000-0000-0000-0000-000000000001',1) ON CONFLICT DO NOTHING;
INSERT INTO members (id, tenant_id, member_no, name, home_store_id)
SELECT g, '00000000-0000-0000-0000-000000000001', 'T' || g, '客' || g, 1 FROM generate_series(101,110) g;
INSERT INTO skus (id, product_name) VALUES (70,'限量品') ON CONFLICT DO NOTHING;
INSERT INTO line_note_accounts (id, label, status) VALUES (1,'帳號一','active');
INSERT INTO line_note_communities (id, store_id, tenant_id, home_id, home_name, home_kind, account_id, auto_post_on_open, listen_enabled, sales_channels)
VALUES (71, 1, '00000000-0000-0000-0000-000000000001','h71','社群甲','square',1,true,true,ARRAY['groupbuy']),
       (72, NULL, '00000000-0000-0000-0000-000000000001','h72','社群乙','group',1,false,true,ARRAY['groupbuy']);
INSERT INTO group_buy_campaigns (id, tenant_id, campaign_no, status, total_cap_qty, sales_channel)
VALUES (70,'00000000-0000-0000-0000-000000000001','GRP-70','open',2,'groupbuy');
INSERT INTO campaign_items (id, tenant_id, campaign_id, sku_id, unit_price, sort_order) VALUES (701,'00000000-0000-0000-0000-000000000001',70,70,100,1);
INSERT INTO line_note_posts (id, campaign_id, community_id, tenant_id, status, line_post_id, text)
VALUES (71,70,71,'00000000-0000-0000-0000-000000000001','posted','L71','團文甲'),
       (72,70,72,'00000000-0000-0000-0000-000000000001','posted','L72','團文乙');
-- 各種舊有狀態（用來驗「舊條件不變」）：pending／unmatched／error／no_order 帶編號／no_order 像下單／
-- no_order 聊天／ordered 一般／ordered 帶「已略過重複」／duplicate／resolved／ignored
INSERT INTO line_note_comments (id, tenant_id, post_id, status, member_no_hint, text, resolution_note) VALUES
 (7101,'00000000-0000-0000-0000-000000000001',72,'unmatched',NULL,'+1',NULL),
 (7102,'00000000-0000-0000-0000-000000000001',72,'error','T101','+1',NULL),
 (7103,'00000000-0000-0000-0000-000000000001',72,'no_order','T102','你好',NULL),
 (7104,'00000000-0000-0000-0000-000000000001',72,'no_order',NULL,'白+1',NULL),
 (7105,'00000000-0000-0000-0000-000000000001',72,'no_order',NULL,'謝謝',NULL),
 (7106,'00000000-0000-0000-0000-000000000001',72,'ordered','T103','+1',NULL),
 (7107,'00000000-0000-0000-0000-000000000001',72,'ordered','T104','A1 B1','已略過重複：A'),
 (7108,'00000000-0000-0000-0000-000000000001',72,'duplicate','T105','+1',NULL),
 (7109,'00000000-0000-0000-0000-000000000001',72,'resolved','T106','+1','限量已滿，只加部分：A 要 3 件只加 1 件'),
 (7110,'00000000-0000-0000-0000-000000000001',72,'ignored','T107','+1',NULL),
 (7111,'00000000-0000-0000-0000-000000000001',72,'ordered','T108','+1','備註：限量已滿，只加部分（不在開頭，不算）'),
 (7112,'00000000-0000-0000-0000-000000000001',72,'no_order','','你好',NULL),
 (7113,'00000000-0000-0000-0000-000000000001',72,'no_order','','白+1',NULL);
-- 社群甲：兩則真的留言，等貼完 migration 再跑 apply（上限 2：第一則 +3 只加 2、第二則 +1 加 0）
INSERT INTO line_note_comments (id, tenant_id, post_id, parsed, member_no_hint, commenter_name, text, commented_at) VALUES
 (7201,'00000000-0000-0000-0000-000000000001',71,'[{"qty":3}]','T109','客109','T109 +3', now() - interval '1 hour'),
 (7202,'00000000-0000-0000-0000-000000000001',71,'[{"qty":1}]','T110','客110','T110 +1', now() - interval '1 hour');
CREATE TABLE _targets_before AS SELECT * FROM rpc_line_note_campaign_targets(70);
CREATE TABLE _todo3_before AS
  SELECT id, public._line_note_comment_is_todo(status, member_no_hint, text) AS todo FROM line_note_comments;
SELECT 'before 快照', count(*) FROM _targets_before;

\else
-- ── 第二段（貼完 migration 之後）──
DO $t$ BEGIN
  -- 舊有條件不變：四參數版對每一則都跟三參數舊版一樣（7109 resolved、7111 前綴不在開頭都不算）
  IF EXISTS (SELECT 1 FROM line_note_comments c JOIN _todo3_before b ON b.id = c.id
              WHERE public._line_note_comment_is_todo(c.status, c.member_no_hint, c.text, c.resolution_note) IS DISTINCT FROM b.todo) THEN
    RAISE EXCEPTION 'A 失敗：四參數版跟舊版判斷不同'; END IF;
  IF EXISTS (SELECT 1 FROM line_note_comments c
              WHERE public._line_note_comment_is_todo(c.status, c.member_no_hint, c.text)
                    IS DISTINCT FROM (SELECT b.todo FROM _todo3_before b WHERE b.id = c.id)) THEN
    RAISE EXCEPTION 'A 失敗：三參數版被改到'; END IF;
  RAISE NOTICE '✅ A 舊有 13 則各狀態（含會員編號是空字串的 2 則）：四參數版＝三參數版（共 % 則待處理），三參數版沒變',
    (SELECT count(*) FROM _todo3_before WHERE todo);
END $t$;

-- 群組清單：貼完 migration、還沒有部分加單 → 輸出跟舊版完全一樣
DO $t$ BEGIN
  IF EXISTS (SELECT * FROM rpc_line_note_campaign_targets(70) EXCEPT SELECT * FROM _targets_before)
     OR EXISTS (SELECT * FROM _targets_before EXCEPT SELECT * FROM rpc_line_note_campaign_targets(70)) THEN
    RAISE EXCEPTION 'B 失敗：群組清單跟舊版不同'; END IF;
  RAISE NOTICE '✅ B 群組清單新版輸出＝舊版（% 列，含 comment_todo）', (SELECT count(*) FROM _targets_before);
END $t$;

-- 部分加單 → 兩處待處理都算到
DO $t$ DECLARE r record; c record; BEGIN
  SELECT * INTO r FROM rpc_line_note_apply_comment(7201);
  SELECT * INTO c FROM line_note_comments WHERE id = 7201;
  IF r.out_status <> 'ordered' OR c.resolution_note <> '限量已滿，只加部分：A 要 3 件只加 2 件' THEN RAISE EXCEPTION 'C 失敗 %', row_to_json(c); END IF;
  IF NOT public._line_note_comment_is_todo(c.status, c.member_no_hint, c.text, c.resolution_note) THEN RAISE EXCEPTION 'C 失敗：沒算待處理'; END IF;
  SELECT * INTO r FROM rpc_line_note_apply_comment(7202);
  IF r.out_status <> 'error' THEN RAISE EXCEPTION 'C 失敗：第二則 %', r.out_status; END IF;
  RAISE NOTICE '✅ C 部分加單：status=ordered、resolution_note=%、四參數判斷＝待處理', c.resolution_note;
END $t$;

DO $t$ DECLARE a record; BEGIN
  SELECT comment_total, comment_ordered, comment_duplicate, comment_todo INTO a FROM rpc_line_note_campaign_targets(70) WHERE post_id = 71;
  -- 社群甲：2 則；ordered 1（部分加單）；todo 2（部分加單＋限量已滿的 error）
  IF a.comment_total <> 2 OR a.comment_ordered <> 1 OR a.comment_todo <> 2 THEN RAISE EXCEPTION 'D 失敗 %', row_to_json(a); END IF;
  -- 社群乙沒動：整列跟舊版一樣
  IF EXISTS (SELECT * FROM rpc_line_note_campaign_targets(70) WHERE post_id = 72 EXCEPT SELECT * FROM _targets_before WHERE post_id = 72) THEN
    RAISE EXCEPTION 'D 失敗：社群乙變了'; END IF;
  -- 社群甲：除了四個留言統計數字，其他欄位跟舊版一樣
  IF EXISTS (
    SELECT community_id, home_id, home_name, home_kind, store_id, store_name, account_id, account_label, account_status,
           auto_post_on_open, listen_enabled, sales_channels, in_scope, can_post, blocked_reason, post_id, post_status,
           line_post_id, post_text, posted_at, last_read_at, closed_reason, post_error, share_state, shared_at
      FROM rpc_line_note_campaign_targets(70) WHERE post_id = 71
    EXCEPT
    SELECT community_id, home_id, home_name, home_kind, store_id, store_name, account_id, account_label, account_status,
           auto_post_on_open, listen_enabled, sales_channels, in_scope, can_post, blocked_reason, post_id, post_status,
           line_post_id, post_text, posted_at, last_read_at, closed_reason, post_error, share_state, shared_at
      FROM _targets_before WHERE post_id = 71) THEN
    RAISE EXCEPTION 'D 失敗：社群甲非統計欄位變了'; END IF;
  RAISE NOTICE '✅ D 開團彈窗群組清單：社群甲 total=% ordered=% todo=%（部分加單同時算已加單與待處理）；其他欄位、社群乙與舊版一樣',
    a.comment_total, a.comment_ordered, a.comment_todo;
END $t$;

-- settle 不會碰 ordered（它只掃 unmatched／error／no_order）：實際呼叫 20260928000000 那支
DO $t$ DECLARE c0 record; c1 record; n int; BEGIN
  SELECT * INTO c0 FROM line_note_comments WHERE id = 7201;
  n := public._line_note_settle_keyed_comments('00000000-0000-0000-0000-000000000001', 70);
  SELECT * INTO c1 FROM line_note_comments WHERE id = 7201;
  IF c1.status <> 'ordered' OR c1.resolution_note IS DISTINCT FROM c0.resolution_note
     OR c1.error IS DISTINCT FROM c0.error OR c1.processed_at IS DISTINCT FROM c0.processed_at THEN
    RAISE EXCEPTION 'E 失敗 %', row_to_json(c1); END IF;
  RAISE NOTICE '✅ E 實際跑 _line_note_settle_keyed_comments（改了 % 則）：部分加單那則 status／resolution_note／error 都沒變', n;
END $t$;

-- 前端待處理清單那條 PostgREST 條件（lineNoteStatus.ts TODO_COMMENT_OR_FILTER）翻成 SQL，逐則跟 DB 判斷比：
--   status.in.(pending,unmatched,error)
--   and(status.eq.no_order,or(member_no_hint.neq.,text.match.<regex>))   ← neq. ＝ <> ''（NULL 也不算）
--   and(status.eq.ordered,resolution_note.like.限量已滿，只加部分*)       ← like 的 * ＝ %
DO $t$ DECLARE n_new int; n_old int; n_empty int; BEGIN
  -- 新寫法（member_no_hint.neq.）翻成 SQL
  SELECT count(*) INTO n_new FROM line_note_comments c
   WHERE c.id >= 7100
     AND COALESCE(c.status IN ('pending','unmatched','error')
               OR (c.status = 'no_order' AND (c.member_no_hint <> '' OR c.text ~ '[+＋]\s*[0-9０-９]|[加打]\s*[0-9０-９一二三四五六七八九]'))
               OR (c.status = 'ordered' AND c.resolution_note LIKE '限量已滿，只加部分%'), FALSE)
         IS DISTINCT FROM public._line_note_comment_is_todo(c.status, c.member_no_hint, c.text, c.resolution_note);
  -- 舊寫法（member_no_hint.not.is.null）翻成 SQL：會把空字串算進來
  SELECT count(*) INTO n_old FROM line_note_comments c
   WHERE c.id >= 7100
     AND COALESCE(c.status IN ('pending','unmatched','error')
               OR (c.status = 'no_order' AND (c.member_no_hint IS NOT NULL OR c.text ~ '[+＋]\s*[0-9０-９]|[加打]\s*[0-9０-９一二三四五六七八九]'))
               OR (c.status = 'ordered' AND c.resolution_note LIKE '限量已滿，只加部分%'), FALSE)
         IS DISTINCT FROM public._line_note_comment_is_todo(c.status, c.member_no_hint, c.text, c.resolution_note);
  SELECT count(*) INTO n_empty FROM line_note_comments c WHERE c.id >= 7100 AND c.member_no_hint = '';
  IF n_new <> 0 THEN RAISE EXCEPTION 'G 失敗：新寫法 % 則跟 DB 不一致', n_new; END IF;
  IF n_old <> 1 THEN RAISE EXCEPTION 'G 前提不對：舊寫法應該剛好錯 1 則（空字串＋「你好」），實際 %', n_old; END IF;
  RAISE NOTICE '✅ G 前端清單條件翻成 SQL：新寫法逐則＝DB（會員編號空字串 % 則）；舊寫法 not.is.null 不一致 % 則', n_empty, n_old;
END $t$;

-- 給前端判斷比對用：每則留言的 DB 判斷（node 跑 lineNoteStatus.ts 逐則比）
\copy (SELECT json_agg(json_build_object('id', id, 'status', status, 'member_no_hint', member_no_hint, 'text', text, 'resolution_note', resolution_note, 'db_todo', public._line_note_comment_is_todo(status, member_no_hint, text, resolution_note)) ORDER BY id) FROM line_note_comments WHERE id >= 7100) TO 'todo_rows.json'

-- 按「已解決」（前端 setStatus 的寫法：status/resolved_at/resolution_note）→ 離開待處理，訂單不動
DO $t$ DECLARE c record; a record; v_order bigint; BEGIN
  SELECT customer_order_id INTO v_order FROM line_note_comments WHERE id = 7201;
  UPDATE line_note_comments SET status = 'resolved', resolution_note = '限量已滿，只加部分：A 要 3 件只加 2 件' WHERE id = 7201;
  SELECT * INTO c FROM line_note_comments WHERE id = 7201;
  IF public._line_note_comment_is_todo(c.status, c.member_no_hint, c.text, c.resolution_note) THEN RAISE EXCEPTION 'F 失敗：還在待處理'; END IF;
  SELECT comment_ordered, comment_todo INTO a FROM rpc_line_note_campaign_targets(70) WHERE post_id = 71;
  IF a.comment_todo <> 1 OR a.comment_ordered <> 0 THEN RAISE EXCEPTION 'F 失敗 %', row_to_json(a); END IF;
  IF c.customer_order_id IS DISTINCT FROM v_order OR (SELECT sum(qty) FROM customer_order_items WHERE order_id = v_order) <> 2 THEN
    RAISE EXCEPTION 'F 失敗：訂單被動到'; END IF;
  RAISE NOTICE '✅ F 按已解決後離開待處理（社群甲 todo 2→1），訂單仍是 2 件';
END $t$;
-- 給前端判斷比對用（按已解決之後）
\copy (SELECT json_agg(json_build_object('id', id, 'status', status, 'member_no_hint', member_no_hint, 'text', text, 'resolution_note', resolution_note, 'db_todo', public._line_note_comment_is_todo(status, member_no_hint, text, resolution_note)) ORDER BY id) FROM line_note_comments WHERE id >= 7100) TO 'todo_rows_after.json'
\endif

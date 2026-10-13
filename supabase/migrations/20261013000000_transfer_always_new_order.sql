-- ============================================================================
-- 轉單每次都開一張新單（不再併進收貨人的舊單）
-- ============================================================================
-- 問題：訂單頁「轉給別人」（整張轉 rpc_transfer_order_to_store、部分轉
--   rpc_transfer_order_partial）遇到收貨人在同一團已經有進行中的單，會把貨
--   「追加」進那張舊單、不另開新單。店家之間轉貨的收件人都是同一個「【內部】xx店」
--   會員，所以同一家店收到的轉貨永遠併進同一張。後果（實例：TF0536、TF0558）：
--     - 舊單已經可取貨／已完成 → 總倉收件匣看不到這一趟、派不出貨、沒有出貨單，
--       轉出店與收貨店兩邊月結都漏掉這筆。
--     - 轉出店一按，轉出記錄就顯示「收貨完成」，其實貨根本沒動。
--     - 隨貨單把別趟的貨一起印出來，路線（空中轉／經總倉）標的也是別趟的。
--   改成：每轉一次就開一張新的轉入單（TF 單）—— 整張轉、部分轉、跨店、同店換客人都一樣。
--   互助板的轉單本來就一律開新單（20260824060000），這次把同一個做法套到訂單頁。
--
-- 本檔內容（順序不可調動）：
--   0. 前置檢查（唯讀）：8 支要覆寫的函式比 md5、唯一索引比定義，任何一項不符就整份停下。
--   1. customer_orders_trio_kind_active_uniq 放行轉入單：
--      predicate 多一條 transferred_from_order_id IS NULL（其餘逐字照抄 20260901010000:67）。
--      ⚠ 一定要排在所有函式前面：函式改成一律開新單以後，如果索引還沒放寬，
--        只要收貨人在同一團已有進行中的單，每一筆轉單都會撞 duplicate key 失敗。
--      只會放寬（新 predicate 收進索引的列是舊的子集），不會因為既有資料建不起來。
--   2. rpc_transfer_order_to_store：拿掉「找收貨人既有單」「併入分支」「重開舊單」，
--      一律開新單；「轉給自己」守衛保留（收件人＝原單同一位會員、同一個頻道就擋）。
--      連結表 customer_order_transfer_links.appended 一律寫 FALSE。
--   3. rpc_transfer_order_partial：同上；互助板 aid_board_id 照蓋（單頭與連結表）。
--   4~6、8、9. 「找這位客人在這團的單來加」的入口，一律不挑轉入單（transferred_from_order_id IS NULL）：
--      4. rpc_create_customer_orders（代客加單；LINE 記事本加單、抵減單也走這支）
--      5. rpc_place_member_order_guarded（會員／LINE 下單）
--      6. _store_add_internal_order_item（採購單頁「分店／批發追加」）
--      8. rpc_add_pr_store_demands（請購單草稿「分店／批發加單」；跟 6 是兩份同樣的邏輯）
--         請購加單的自動確認與 pending 擋單也排除轉入單（經總倉轉入單一開就是 pending、
--         等總倉簽收，不能被推成 confirmed，也不該擋加單）。
--      9. rpc_create_store_internal_order（店長在代客加單畫面幫自己店叫貨）
--      （8、9 排在檔案最後，都在第 1 段索引之後。）
--      為什麼一定要一起改：同一人同一團可以有兩張單（自己的一般單＋別人轉來的轉入單）
--      以後，加單如果加進轉入單，那件貨不會進總倉撿貨，客人永遠拿不到。
--      4、5 原本沒有排序也沒有 LIMIT，一併補 ORDER BY id LIMIT 1，挑哪一張固定下來。
--      9 只加排除轉入單這一個條件；它原本沒排除已取消的單、也沒有 ORDER BY／LIMIT，
--      那是原本就有的問題，本檔不動。
--   7. rpc_restore_cancelled_order 守衛 5（一會員一活動一張單）：豁免條件對齊新索引
--      （WS-、aid_board_id、轉入單），不再被這些單誤擋。
--
-- 基底版本（每支都重新 grep「CREATE (OR REPLACE )?FUNCTION」取最後一支真的重建它的檔，
--   逐字複製整個定義，只改上面列的地方）：
--   customer_orders_trio_kind_active_uniq = 20260901010000_walkin_sale_schema.sql:67
--   rpc_transfer_order_to_store           = 20260831000090_store_campaign_no_transfer.sql:30
--   rpc_transfer_order_partial            = 20260831000090_store_campaign_no_transfer.sql:365
--   rpc_create_customer_orders            = 20260805000140_reopen_completed_order_on_append.sql:394
--   rpc_place_member_order_guarded        = 20260910050000_campaign_customer_end_at.sql:174
--   _store_add_internal_order_item        = 20261002000000_po_store_additions.sql:526
--   rpc_restore_cancelled_order           = 20260818000000_rpc_restore_cancelled_order.sql:102
--   rpc_add_pr_store_demands              = 20260924010000_pr_store_additions_allow_wholesale.sql:4
--   rpc_create_store_internal_order       = 20260507000000_order_transfer_and_internal.sql:111
--     （這支是唯一的定義；基底沒寫 public. 前綴、沒有 SET search_path，本檔照抄不補）
--   簽名、回傳型別、SECURITY DEFINER、SET search_path 都跟基底一樣 → CREATE OR REPLACE，
--   不需要 DROP。CREATE OR REPLACE 不改權限，所以本檔不重下 GRANT／REVOKE。
--   基底註解裡原本寫的門市名稱，本檔一律拿掉只留日期與單號（只動註解，程式一字未改）。
--
-- 前置檢查的 md5 怎麼算（審查的人可以自己重算）：
--   取函式定義裡「AS $tag$」到下一個「$tag$」之間的原文（＝ pg_proc.prosrc），
--   換行先正規化成 LF（CRLF → LF）再算 md5。前置檢查同樣比 md5(replace(prosrc, E'\r', ''))，
--   所以貼的時候換行是 CRLF 還是 LF 都不影響。
--   本機算法：git show HEAD:<基底檔> 存成檔案，用 node 依上面規則切出內文、
--   crypto.createHash('md5') 算；本檔新版用同一支程式對本檔算。
--                                    基底版                            本檔新版
--   rpc_transfer_order_to_store      3b7f89cb21ca045af2b9747714e94833  296dd44bc5e7293225c4ca4e9c5884bc
--   rpc_transfer_order_partial       184a8d947b1527b88acebd781e4e04bc  c96d9e66d1389f5ed810e8385676a4eb
--   rpc_create_customer_orders       33ab1b7d62197d34540936a87cc0dd81  966e66281864bdd86ceb84cb01a6b81d
--   rpc_place_member_order_guarded   7813f92d8e8a67dbaa74b10eea7be492  0d229ee6f5b4baaa9d2fad6bff204bdb
--   _store_add_internal_order_item   b5b1ef9c4c17a128d7bb239c5c2715d9  c0f1f3e8f4f984a0ef2b66c3297ac463
--   rpc_restore_cancelled_order      722a1a6903503eaa38b64aa15177870d  7c9c1801252437301f2ba226b54546ad
--   rpc_add_pr_store_demands         3ea3544904c5280747052c3abeee945a  b35fa35cf795c1130f98cec9e0d7553c
--   rpc_create_store_internal_order  18cd791444cc4dcad299af469ab048f1  879557850032331e9475268f5a03cffd
--   唯一索引比 pg_indexes.indexdef（去掉所有空白後逐字比），舊版與新版的完整字串寫在第 0 段。
--
-- 會鎖表多久（第 1 段）：
--   CREATE UNIQUE INDEX（不是 CONCURRENTLY）建索引期間對 customer_orders 拿 SHARE 鎖：
--   可以讀、不能寫（下單、轉單、取貨、改單都要排隊等它建完）。
--   DROP 舊索引＋改名拿 ACCESS EXCLUSIVE，只在建完之後那一瞬間（同一個交易裡緊接著提交）。
--   估計：1 秒上下。依據：partial btree、5 個整數／短字串欄位，只收進行中的一般單；
--   訂單 id 在 2026-08 初約 6.6 萬（20260805000140 檔頭的 order 65983），
--   整張表估 10 萬列級，這個量級建 btree 通常在 1 秒內。
--   ⚠ 沒有在正式庫實測過，請避開下單尖峰貼。
--   另外設 lock_timeout = 5 秒：5 秒內等不到鎖（有人正在寫訂單）就整段放棄、
--   索引維持舊版，不讓其他人的寫入一直排在本檔後面。遇到就過一兩分鐘整份重貼。
--
-- 整份可以重貼：
--   前置檢查同時認得「基底版」（第一次貼）和「本檔新版」（重貼／上次貼到一半）；
--   第 1 段看到索引已經是新版就什麼都不做；CREATE OR REPLACE／COMMENT 重跑結果一樣。
--   第 1 段的「建新索引 → 刪舊索引 → 新索引改名」包在同一個 DO 裡（同一個交易），
--   任何一步失敗整段退回、舊索引原封不動，不會出現「沒有唯一索引」的空窗。
--
-- 不在本檔範圍：
--   - 已經併在一起的舊單（例：TF0536、TF0558）一筆都不動，帳由人工調整。
--   - 不搬庫存、不補出貨單、不改任何既有資料。
--
-- 上線順序：先貼本檔（SQL），再合併前端（apps/admin OrderEntryView 送出前的加單提示）。
--   本檔先上、前端還沒合併也不會壞：函式名稱、參數都沒變。前端那處只是送出前
--   「原本 X → 變 X+qty」的提示；還沒合併時提示可能把轉入單上的數量也算進去，
--   不影響實際寫進哪一張單。
--
-- Rollback：
--   函式：各自 CREATE OR REPLACE 回上面列的基底版本（只重跑那一支函式定義，
--     不要整份重跑基底檔）。函式退回舊版、索引留新版不會壞：
--     舊函式找既有單時會挑到轉入單併進去（＝本檔之前的行為）。
--   索引：⚠ 只要已經出現「同一人同一團兩張進行中的單」（一般單＋轉入單，或兩張轉入單），
--     舊版索引就建不回去（會撞 duplicate key）＝ 無法回滾成舊版。留著新版配舊函式不會壞。
--     舊版定義（要回滾時用，建之前先確認沒有重複）：
--       DROP INDEX public.customer_orders_trio_kind_active_uniq;
--       CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq
--         ON public.customer_orders (tenant_id, campaign_id, channel_id, member_id, order_kind)
--        WHERE status <> ALL (ARRAY['transferred_out'::text, 'expired'::text, 'cancelled'::text])
--          AND order_kind <> 'restock'::text
--          AND order_no NOT LIKE 'SP-%'
--          AND order_no NOT LIKE 'WS-%'
--          AND aid_board_id IS NULL;
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有 DDL 之前、唯讀
--    這份 SQL 是貼進 SQL Editor 執行的（autocommit、沒有交易保護），
--    前提不成立時要在「還沒動任何東西」的階段就停下來。
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_bad  TEXT[] := ARRAY[]::TEXT[];
  v_rec  RECORD;
  v_oid  REGPROCEDURE;
  v_md5  TEXT;
  v_def  TEXT;
  -- 唯一索引：舊版＝ 20260901010000:67 建出來的樣子；新版＝本檔第 1 段建出來的樣子。
  -- 都是 pg_indexes.indexdef 的格式（比的時候兩邊都去掉所有空白）。
  v_idx_old CONSTANT TEXT :=
    'CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq ON public.customer_orders '
    'USING btree (tenant_id, campaign_id, channel_id, member_id, order_kind) '
    'WHERE ((status <> ALL (ARRAY[''transferred_out''::text, ''expired''::text, ''cancelled''::text])) '
    'AND (order_kind <> ''restock''::text) AND (order_no !~~ ''SP-%''::text) '
    'AND (order_no !~~ ''WS-%''::text) AND (aid_board_id IS NULL))';
  v_idx_new CONSTANT TEXT :=
    'CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq ON public.customer_orders '
    'USING btree (tenant_id, campaign_id, channel_id, member_id, order_kind) '
    'WHERE ((status <> ALL (ARRAY[''transferred_out''::text, ''expired''::text, ''cancelled''::text])) '
    'AND (order_kind <> ''restock''::text) AND (order_no !~~ ''SP-%''::text) '
    'AND (order_no !~~ ''WS-%''::text) AND (aid_board_id IS NULL) '
    'AND (transferred_from_order_id IS NULL))';
BEGIN
  -- 8 支要覆寫的函式：用完整簽名定位，線上內文必須是「基底版」或「本檔新版」
  FOR v_rec IN
    SELECT *
      FROM (VALUES
        ('public.rpc_transfer_order_to_store(bigint, bigint, bigint, bigint, uuid, text, boolean)',
         '20260831000090:30',  '3b7f89cb21ca045af2b9747714e94833', '296dd44bc5e7293225c4ca4e9c5884bc'),
        ('public.rpc_transfer_order_partial(bigint, bigint, bigint, bigint, uuid, text, jsonb, boolean, bigint)',
         '20260831000090:365', '184a8d947b1527b88acebd781e4e04bc', 'c96d9e66d1389f5ed810e8385676a4eb'),
        ('public.rpc_create_customer_orders(bigint, bigint, jsonb)',
         '20260805000140:394', '33ab1b7d62197d34540936a87cc0dd81', '966e66281864bdd86ceb84cb01a6b81d'),
        ('public.rpc_place_member_order_guarded(uuid, bigint, bigint, bigint, bigint, jsonb, text, text)',
         '20260910050000:174', '7813f92d8e8a67dbaa74b10eea7be492', '0d229ee6f5b4baaa9d2fad6bff204bdb'),
        ('public._store_add_internal_order_item(uuid, bigint, text, bigint, bigint, numeric, bigint, numeric, uuid, text, text)',
         '20261002000000:526', 'b5b1ef9c4c17a128d7bb239c5c2715d9', 'c0f1f3e8f4f984a0ef2b66c3297ac463'),
        ('public.rpc_restore_cancelled_order(bigint, uuid, text)',
         '20260818000000:102', '722a1a6903503eaa38b64aa15177870d', '7c9c1801252437301f2ba226b54546ad'),
        ('public.rpc_add_pr_store_demands(bigint, bigint, bigint, jsonb, uuid, uuid)',
         '20260924010000:4',   '3ea3544904c5280747052c3abeee945a', 'b35fa35cf795c1130f98cec9e0d7553c'),
        ('public.rpc_create_store_internal_order(bigint, bigint, jsonb, uuid, text)',
         '20260507000000:111', '18cd791444cc4dcad299af469ab048f1', '879557850032331e9475268f5a03cffd')
      ) AS t(sig, base_at, md5_base, md5_new)
  LOOP
    v_oid := to_regprocedure(v_rec.sig);
    IF v_oid IS NULL THEN
      v_bad := v_bad || format('找不到函式 %s（名稱或參數型別跟預期不一樣）', v_rec.sig);
      CONTINUE;
    END IF;

    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
      FROM pg_proc p
     WHERE p.oid = v_oid;

    IF v_md5 IS DISTINCT FROM v_rec.md5_base AND v_md5 IS DISTINCT FROM v_rec.md5_new THEN
      v_bad := v_bad || format(
        '%s 線上內文不是基底 %s 那一版，也不是本檔新版（線上 md5=%s）；可能有人改過，請先比對再決定',
        v_rec.sig, v_rec.base_at, v_md5);
    END IF;
  END LOOP;

  -- 唯一索引：必須是 20260901010000 那一版（第一次貼）或本檔新版（重貼）
  SELECT i.indexdef INTO v_def
    FROM pg_indexes i
   WHERE i.schemaname = 'public'
     AND i.indexname  = 'customer_orders_trio_kind_active_uniq';
  IF v_def IS NULL THEN
    v_bad := v_bad || '找不到唯一索引 public.customer_orders_trio_kind_active_uniq'::TEXT;
  ELSIF regexp_replace(v_def, '\s', '', 'g') <> regexp_replace(v_idx_old, '\s', '', 'g')
    AND regexp_replace(v_def, '\s', '', 'g') <> regexp_replace(v_idx_new, '\s', '', 'g') THEN
    v_bad := v_bad || format(
      '唯一索引 customer_orders_trio_kind_active_uniq 不是 20260901010000 那一版，也不是本檔新版（線上定義：%s）',
      v_def);
  END IF;

  -- 第 1 段建新索引時暫用的名字不能已經被占用
  IF to_regclass('public.customer_orders_trio_kind_active_uniq_20261013') IS NOT NULL THEN
    v_bad := v_bad || '暫用的索引名稱 public.customer_orders_trio_kind_active_uniq_20261013 已經存在（不該存在），請先查是誰建的'::TEXT;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。不符的項目：\n%',
      array_to_string(v_bad, E'\n');
  END IF;
END;
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. 唯一索引放行轉入單 —— 一定要排在所有函式前面
--
--    基底 20260901010000:67-73 逐字，只多最後一行 transferred_from_order_id IS NULL。
--    轉入單＝「一趟一張」：每轉一次就開一張新單，同一位收件人（例如【內部】xx店）
--    在同一團會有很多張，本來就不該被「一人一團一張」擋住；
--    跟 SP-（20260816000060）、WS-（20260901010000）、互助單（aid_board_id）同一個理由。
--
--    做法：同一個 DO（＝同一個交易）裡「先用暫用名字建好新索引 → 刪舊索引 → 新索引改名」。
--      - 任何一步失敗整段退回，舊索引原封不動，不會有「沒有唯一索引」的空窗。
--      - 先建新的再刪舊的：建索引期間只拿 SHARE 鎖（可讀、不可寫），
--        刪舊索引要的 ACCESS EXCLUSIVE 只在最後一瞬間。
--      - 索引已經是新版（重貼）就什麼都不做。
--      - lock_timeout 5 秒：等不到鎖就整段放棄（見檔頭「會鎖表多久」）。
-- ----------------------------------------------------------------------------
DO $idx$
DECLARE
  v_def TEXT;
  v_idx_new CONSTANT TEXT :=
    'CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq ON public.customer_orders '
    'USING btree (tenant_id, campaign_id, channel_id, member_id, order_kind) '
    'WHERE ((status <> ALL (ARRAY[''transferred_out''::text, ''expired''::text, ''cancelled''::text])) '
    'AND (order_kind <> ''restock''::text) AND (order_no !~~ ''SP-%''::text) '
    'AND (order_no !~~ ''WS-%''::text) AND (aid_board_id IS NULL) '
    'AND (transferred_from_order_id IS NULL))';
BEGIN
  SELECT i.indexdef INTO v_def
    FROM pg_indexes i
   WHERE i.schemaname = 'public'
     AND i.indexname  = 'customer_orders_trio_kind_active_uniq';

  IF regexp_replace(v_def, '\s', '', 'g') = regexp_replace(v_idx_new, '\s', '', 'g') THEN
    RAISE NOTICE '唯一索引 customer_orders_trio_kind_active_uniq 已經是本檔新版，第 1 段略過';
    RETURN;
  END IF;

  PERFORM set_config('lock_timeout', '5s', true);

  CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq_20261013
    ON public.customer_orders (tenant_id, campaign_id, channel_id, member_id, order_kind)
   WHERE status <> ALL (ARRAY['transferred_out'::text, 'expired'::text, 'cancelled'::text])
     AND order_kind <> 'restock'::text
     AND order_no NOT LIKE 'SP-%'
     AND order_no NOT LIKE 'WS-%'
     AND aid_board_id IS NULL
     AND transferred_from_order_id IS NULL;

  DROP INDEX public.customer_orders_trio_kind_active_uniq;

  ALTER INDEX public.customer_orders_trio_kind_active_uniq_20261013
    RENAME TO customer_orders_trio_kind_active_uniq;
EXCEPTION
  WHEN lock_not_available THEN
    RAISE EXCEPTION '第 1 段（放寬唯一索引）5 秒內等不到 customer_orders 的鎖（有人正在寫訂單），已整段放棄、索引維持舊版。請過一兩分鐘再整份重貼一次（前置檢查認得改過和沒改過的版本，重貼是安全的）';
END;
$idx$;

COMMENT ON INDEX public.customer_orders_trio_kind_active_uniq IS
  '一會員一活動一張 active 單（真團的核心不變量，rpc_create_customer_orders 靠它合併）。'
  'restock（RR- 補貨容器單）、SP-（現貨直配，20260816000060）、'
  'WS-（現場銷售，20260901010000）、互助認領單（aid_board_id）、'
  '轉入單（transferred_from_order_id，每轉一次開一張，20261013000000）除外 —— '
  '那些是「一次動作一張單」的語意，不該被合併。';


-- ----------------------------------------------------------------------------
-- 2. rpc_transfer_order_to_store —— 基底 20260831000090:30 逐字，只改（行號＝基底檔）：
--    :187-201 找收貨人既有單 → 拿掉；「轉給自己」改成直接比收件人＝原單同一人、同頻道
--    :225-240、:281 併入分支 → 拿掉，一律開新單（狀態規則 :262-268 不變；
--                  原本 ELSE 裡那段保留原縮排，方便逐行對照基底）
--    :331-337 併入後重開舊單 → 拿掉
--    :349 連結表 appended → FALSE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_transfer_order_to_store(p_order_id bigint, p_to_pickup_store_id bigint, p_to_member_id bigint, p_to_channel_id bigint, p_operator uuid, p_reason text DEFAULT NULL::text, p_is_air_transfer boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_orig             customer_orders%ROWTYPE;
  v_tenant_id        UUID;
  v_to_member_id     BIGINT;
  v_to_channel_id    BIGINT;
  v_new_order_id     BIGINT;
  v_new_order_no     TEXT;
  v_seq              INT;
  v_campaign_no      TEXT;
  v_item             RECORD;
  v_orig_mov         RECORD;
  v_rev_id           BIGINT;
  v_now              TIMESTAMPTZ := NOW();
  v_note_out         TEXT;
  v_note_in          TEXT;
  v_new_status       TEXT;
  v_src_is_internal  BOOLEAN := FALSE;
  v_dst_is_internal  BOOLEAN := FALSE;
  v_dup_order_id     BIGINT;
  v_dup_order_no     TEXT;
  v_appended         BOOLEAN := FALSE;
  v_active_count     INT;
  v_new_item_ids     BIGINT[];
BEGIN

  -- 20260831：店家自開團的訂單不能轉出。
  --   轉單是「把品項複製到另一張單」（跨店轉還會落在別家店），而自開團的帳
  --   整個綁在 (團, 主辦店) 上：_store_campaign_demand 只算
  --   pickup_store = 主辦店 的需求，取貨閘門 Path S 也要求
  --   gc.owner_store_id = co.pickup_store_id。轉出去的那張單因此永遠不會被算進
  --   收貨頁的需求、也永遠過不了閘門 —— 貨在店裡、客人卻領不到，而且畫面不會
  --   報錯（CLAUDE.md 記過的那種安靜卡死）。
  --   老闆指示：不要再想辦法讓它轉，不要的單就直接取消／刪掉。
  IF EXISTS (
    SELECT 1
      FROM customer_orders co
      JOIN group_buy_campaigns gc ON gc.id = co.campaign_id
     WHERE co.id = p_order_id
       AND gc.owner_store_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '門市團的訂單不能轉出：這團的貨是門市自己採購、自己收貨的。客人不要的話請直接取消訂單或刪掉品項';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 #%', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  -- 部分取貨的單不可整單轉出：整單轉出會把來源單標 transferred_out
  -- （整張不入統計），已取走品項的營收會跟著被歸零。剩餘品項請走
  -- rpc_transfer_order_partial（來源列標 cancelled、單頭由
  -- _close_orders_all_items_settled 收尾），營收留在原單上。
  IF v_orig.status = 'partially_completed' THEN
    RAISE EXCEPTION '訂單 % 已有品項取走（部分取貨），不可整單轉出；請改用部分轉出（只轉剩餘品項）',
                    p_order_id;
  END IF;

  -- 跨店轉單維持「貨到店 (status='ready') 才能轉」；
  -- 同店互轉（換客人）貨進同一間店、不影響總倉派貨量，到貨前也可轉。
  -- 同店預轉仍排除三種「貨不走本店波次」的單（轉走會斷到貨推進鏈）：
  --   a. 非一般團購單（restock ride-along 靠 order_no='RR-x' 特判推 ready、offset 無實貨）
  --   b. 有進行中的調撥 FK 指著它（互助/空中轉/補貨直派 → 到貨判定綁原單 id）
  --   c. 自己就是跨店轉入、貨還沒到的單（到貨判定同樣綁 transfer FK）
  IF v_orig.status <> 'ready' THEN
    IF p_to_pickup_store_id <> v_orig.pickup_store_id THEN
      RAISE EXCEPTION '貨還沒到分店、訂單 % 不可跨店轉單 (status=%)；同店換客人不受此限',
                      p_order_id, v_orig.status;
    END IF;
    IF v_orig.status NOT IN ('pending','confirmed','reserved','shipping') THEN
      RAISE EXCEPTION '訂單 % 狀態（%）不可轉單', p_order_id, v_orig.status;
    END IF;
    IF COALESCE(v_orig.order_kind, 'normal') <> 'normal' THEN
      RAISE EXCEPTION '訂單 % 不是一般團購單（%），須等分店收貨後再轉單',
                      p_order_id, v_orig.order_kind;
    END IF;
    IF EXISTS (SELECT 1 FROM transfers t
                WHERE t.customer_order_id = p_order_id
                  AND t.tenant_id = v_tenant_id
                  AND t.status <> 'cancelled') THEN
      RAISE EXCEPTION '訂單 % 有進行中的調撥，請等分店收貨後再轉單', p_order_id;
    END IF;
    IF v_orig.transferred_from_order_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM customer_orders src
          WHERE src.id = v_orig.transferred_from_order_id
            AND src.pickup_store_id IS DISTINCT FROM v_orig.pickup_store_id) THEN
      RAISE EXCEPTION '訂單 % 是跨店轉入、貨還沒到，請等分店收貨後再轉單', p_order_id;
    END IF;
  END IF;

  IF v_orig.transferred_to_order_id IS NOT NULL THEN
    RAISE EXCEPTION '訂單 #% 已轉出至訂單 #%，不可重複轉出',
                    p_order_id, v_orig.transferred_to_order_id;
  END IF;

  -- 整單轉出只帶 active（未取消、未取走）品項；一件都沒有就沒東西可轉
  SELECT COUNT(*) INTO v_active_count
    FROM customer_order_items
   WHERE order_id = p_order_id
     AND status IN ('pending','reserved','ready');
  IF v_active_count = 0 THEN
    RAISE EXCEPTION '訂單 #% 沒有可轉移的品項（未取消／未取走的品項為 0）', p_order_id;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_to_pickup_store_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收店（ID %）不存在或不屬於目前商戶', p_to_pickup_store_id;
  END IF;

  v_to_member_id := COALESCE(
    p_to_member_id,
    rpc_get_or_create_store_member(p_to_pickup_store_id, p_operator)
  );

  PERFORM 1 FROM members WHERE id = v_to_member_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收會員（ID %）不存在或不屬於目前商戶', v_to_member_id;
  END IF;

  -- 內部單（【內部】xx店）轉給真會員 = 門市現貨銷售 → 轉出價改鎖現售價。
  -- 店↔店互助（目標也是 store_internal）維持原價不變。（同 20260714000090 partial 版規則）
  SELECT (m.member_type = 'store_internal') INTO v_src_is_internal
    FROM members m WHERE m.id = v_orig.member_id;
  v_src_is_internal := COALESCE(v_src_is_internal, FALSE);
  SELECT (m.member_type = 'store_internal') INTO v_dst_is_internal
    FROM members m WHERE m.id = v_to_member_id;
  v_dst_is_internal := COALESCE(v_dst_is_internal, FALSE);

  v_to_channel_id := p_to_channel_id;
  IF v_to_channel_id IS NULL THEN
    SELECT id INTO v_to_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id AND home_store_id = p_to_pickup_store_id
     LIMIT 1;
    IF v_to_channel_id IS NULL THEN
      SELECT id INTO v_to_channel_id
        FROM line_channels
       WHERE tenant_id = v_tenant_id
       LIMIT 1;
    END IF;
  END IF;
  IF v_to_channel_id IS NULL THEN
    RAISE EXCEPTION '接收店找不到可用的 LINE 頻道，無法建立轉入訂單';
  END IF;

  PERFORM 1 FROM line_channels
   WHERE id = v_to_channel_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'LINE 頻道（ID %）不屬於目前商戶', v_to_channel_id;
  END IF;

  -- 20261013：每轉一次一律開新的轉入單，不再找接收人在同一團的既有單來併。
  --   併進舊單時：舊單已可取貨 → 總倉收件匣看不到這一趟、派不出貨、沒有出貨單，
  --   兩邊月結都漏（例：TF0536）；轉出店一按就顯示收貨完成；隨貨單印到別趟的貨。
  --   唯一索引 customer_orders_trio_kind_active_uniq 同檔已放行轉入單
  --   （transferred_from_order_id IS NOT NULL），第二張開得出來。
  -- 轉給自己（接收人＝原單同一位會員、同一個頻道；活動一定相同）→ 照舊擋下。
  IF v_to_member_id = v_orig.member_id AND v_to_channel_id = v_orig.channel_id THEN
    RAISE EXCEPTION '這張訂單本來就掛在該接收人（同活動、同頻道）名下，不需要轉出';
  END IF;

  -- E2: 釋放 reserved_movement（無條件、跟以前一致；同店也走這條）
  FOR v_item IN
    SELECT id, reserved_movement_id FROM customer_order_items
     WHERE order_id = p_order_id AND reserved_movement_id IS NOT NULL
  LOOP
    SELECT * INTO v_orig_mov FROM stock_movements WHERE id = v_item.reserved_movement_id;
    IF FOUND THEN
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, reverses, reason, operator_id
      ) VALUES (
        v_orig_mov.tenant_id, v_orig_mov.location_id, v_orig_mov.sku_id,
        -v_orig_mov.quantity, v_orig_mov.unit_cost, 'reversal',
        'order_transfer', p_order_id, v_orig_mov.id,
        'order #' || p_order_id || ' transferred out, release allocation', p_operator
      ) RETURNING id INTO v_rev_id;

      UPDATE stock_movements SET reversed_by = v_rev_id WHERE id = v_orig_mov.id;
      UPDATE customer_order_items SET reserved_movement_id = NULL WHERE id = v_item.id;
    END IF;
  END LOOP;

  -- 20261013：原本這裡分「併入既有單 / 開新單」兩條，併入那條已拿掉，一律開新單。
  --   下面這段就是原本 ELSE 裡的內容，刻意保留原縮排，方便逐行對照基底。
    SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
    -- TF 序號 = 該團既有 -TF 尾碼最大值 + 1。
    -- COUNT(*)+1 在 RR- 單被硬刪（rpc_delete_restock_request）後會倒退、
    -- 重發已用過的號碼 → duplicate key（2026-08-13 RR-435 事故）。
    -- 團鎖：來源單鎖擋不住兩張不同來源單同時轉出算出同一號。
    PERFORM pg_advisory_xact_lock(hashtext('order_tf_seq:' || v_orig.campaign_id::text));
    SELECT COALESCE(MAX(substring(order_no FROM '-TF([0-9]+)$')::INT), 0) + 1
      INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id
       AND campaign_id = v_orig.campaign_id
       AND order_no ~ '-TF[0-9]+$';
    -- lpad 超寬會截斷（lpad('10001',4)='1000'），寬度要跟著位數長
    v_new_order_no := v_campaign_no || '-TF' ||
                      lpad(v_seq::text, GREATEST(length(v_seq::text), 4), '0');

    v_note_in := COALESCE(p_reason, '') ||
                 E'\n[轉入 (' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
                 ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
                 to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

    -- 同店：mirror source.status；跨店空中轉：confirmed（尾端 helper 會接著
    -- 建 AT- 單並推 shipping）；跨店經總倉：'pending'（維持總倉確認 gate）
    v_new_status := CASE
      WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN v_orig.status
      WHEN p_is_air_transfer THEN 'confirmed'
      ELSE 'pending'
    END;

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, notes,
      transferred_from_order_id, is_air_transfer,
      created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
      v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status, v_note_in,
      p_order_id, p_is_air_transfer,
      p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_new_order_id;

  -- 內部單 → 真會員：轉出價鎖定當下 SKU 現售價（scope='retail' 最新生效版）；
  -- 查無現售價 fallback 來源價。其餘情境維持原價。
  -- RETURNING：本次搬進去的品項 id 要留給空中轉出貨（helper 只出這一批）
  WITH ins AS (
    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, notes, created_by, updated_by
    )
    SELECT coi.tenant_id, v_new_order_id, coi.campaign_item_id, coi.sku_id, coi.qty,
           CASE WHEN v_src_is_internal AND NOT v_dst_is_internal
                THEN COALESCE(pr.price, coi.unit_price)
                ELSE coi.unit_price
           END,
           'pending', 'aid_transfer', coi.notes, p_operator, p_operator
      FROM customer_order_items coi
      LEFT JOIN LATERAL (
        SELECT p2.price
          FROM prices p2
         WHERE v_src_is_internal AND NOT v_dst_is_internal
           AND p2.tenant_id = v_tenant_id
           AND p2.sku_id    = coi.sku_id
           AND p2.scope     = 'retail'
           AND p2.effective_from <= v_now
           AND (p2.effective_to IS NULL OR p2.effective_to > v_now)
         ORDER BY p2.effective_from DESC
         LIMIT 1
      ) pr ON TRUE
     WHERE coi.order_id = p_order_id
       -- 只複製 active 品項。cancelled（含部分轉出後留下的殘骸）/ expired /
       -- picked_up（貨已交付）帶過去 = 無中生有的重複品項（2026-08-10 事故）
       AND coi.status IN ('pending','reserved','ready')
    RETURNING id
  )
  SELECT COALESCE(array_agg(id), '{}'::BIGINT[]) INTO v_new_item_ids FROM ins;

  v_note_out := COALESCE(p_reason, '') ||
                E'\n[轉出' || CASE WHEN v_appended THEN '（併入既有單）' ELSE '' END ||
                ' → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

  UPDATE customer_orders
     SET status                   = 'transferred_out',
         transferred_to_order_id  = v_new_order_id,
         notes                    = COALESCE(notes, '') || v_note_out,
         updated_by               = p_operator,
         updated_at               = v_now
   WHERE id = p_order_id;

  -- 這一趟轉移的 order↔order 連結。**兩條分支都要寫**（新建轉入單 / 追加併入
  -- 既有單）—— 只有前者會寫 transferred_from_order_id，追加分支以前什麼線索都
  -- 沒留下，轉出店的儀表板提醒、轉出記錄、隨貨單三個畫面同時查無此事
  -- （2026-08-24 實例）。dest_item_ids 只放本次搬進去的品項，
  -- 轉出店才不會看到／印到別家店在同一張轉入單上的貨。
  -- 20261013：併入分支（連同併入後重開舊單那段）已拿掉，appended 一律寫 FALSE。
  INSERT INTO public.customer_order_transfer_links (
    tenant_id, source_order_id, dest_order_id, dest_item_ids,
    is_air_transfer, is_partial, appended, reason, transferred_at, created_by)
  VALUES (
    v_tenant_id, p_order_id, v_new_order_id, COALESCE(v_new_item_ids, '{}'::BIGINT[]),
    COALESCE(p_is_air_transfer, FALSE), FALSE, FALSE, p_reason, v_now, p_operator)
  ON CONFLICT (source_order_id, dest_order_id, transferred_at) DO NOTHING;

  -- 空中轉：貨當下就從轉出店出去 → 建 AT- 轉移單 + 出庫，轉入單進 shipping。
  -- 接收店在收貨頁收掉就可取貨，沒有「派貨」這一步。同店由 helper 判掉。
  IF COALESCE(p_is_air_transfer, FALSE) THEN
    PERFORM public._air_ship_order_items(
      v_new_order_id, v_orig.pickup_store_id, v_new_item_ids, p_operator, v_now);
  END IF;

  RETURN v_new_order_id;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 3. rpc_transfer_order_partial —— 基底 20260831000090:365 逐字，只改（行號＝基底檔）：
--    :511-535 找收貨人既有單（含互助板那段 v_existing_order := NULL）→ 拿掉；
--             「轉給自己」改成直接比收件人＝原單同一人、同頻道
--    :537-550、:593 併入分支 → 拿掉，一律開新單（狀態規則 :567-576 不變；
--                  原本 ELSE 裡那段保留原縮排，方便逐行對照基底）
--    :696-702 併入後重開舊單 → 拿掉
--    互助板 aid_board_id 照蓋（:581/:590 單頭、:712/:716 連結表），簽名不變、不 DROP。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_transfer_order_partial(p_order_id bigint, p_to_pickup_store_id bigint, p_to_member_id bigint, p_to_channel_id bigint, p_operator uuid, p_reason text, p_items jsonb, p_is_air_transfer boolean DEFAULT false, p_aid_board_id bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_orig             customer_orders%ROWTYPE;
  v_tenant_id        UUID;
  v_to_member_id     BIGINT;
  v_to_channel_id    BIGINT;
  v_new_order_id     BIGINT;
  v_new_order_no     TEXT;
  v_seq              INT;
  v_campaign_no      TEXT;
  v_p_item           JSONB;
  v_p_sku_id         BIGINT;
  v_p_qty            NUMERIC;
  v_src_item_id      BIGINT;
  v_src_item_qty     NUMERIC;
  v_src_item_ci      BIGINT;
  v_src_item_price   NUMERIC;
  v_src_item_reserved BIGINT;
  v_remaining_count  INT;
  v_now              TIMESTAMPTZ := NOW();
  v_existing_order   BIGINT;
  v_appended         BOOLEAN := FALSE;
  v_new_status       TEXT;
  v_src_is_internal  BOOLEAN := FALSE;
  v_dst_is_internal  BOOLEAN := FALSE;
  v_retail_price     NUMERIC;
  v_item_price       NUMERIC;
  v_reopened         TEXT;
  v_new_item_id      BIGINT;
  v_new_item_ids     BIGINT[] := '{}'::BIGINT[];
BEGIN

  -- 20260831：店家自開團的訂單不能轉出。
  --   轉單是「把品項複製到另一張單」（跨店轉還會落在別家店），而自開團的帳
  --   整個綁在 (團, 主辦店) 上：_store_campaign_demand 只算
  --   pickup_store = 主辦店 的需求，取貨閘門 Path S 也要求
  --   gc.owner_store_id = co.pickup_store_id。轉出去的那張單因此永遠不會被算進
  --   收貨頁的需求、也永遠過不了閘門 —— 貨在店裡、客人卻領不到，而且畫面不會
  --   報錯（CLAUDE.md 記過的那種安靜卡死）。
  --   老闆指示：不要再想辦法讓它轉，不要的單就直接取消／刪掉。
  IF EXISTS (
    SELECT 1
      FROM customer_orders co
      JOIN group_buy_campaigns gc ON gc.id = co.campaign_id
     WHERE co.id = p_order_id
       AND gc.owner_store_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '門市團的訂單不能轉出：這團的貨是門市自己採購、自己收貨的。客人不要的話請直接取消訂單或刪掉品項';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION '未指定任何要轉移的品項';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 #%', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  -- 跨店轉單維持「貨到店才能轉」：ready 之外也放行 partially_completed ——
  -- 已取走過品項代表貨到過店，剩餘 active 品項物理上就在店裡（內部現貨池
  -- 臨櫃賣掉一件就進 partially_completed，不放行等於池子賣過一次就不能再轉，
  -- 2026-08-14 INT0116）。品項挑選本來就限 active，picked_up 不會被轉走。
  -- 同店互轉（換客人）貨進同一間店、不影響總倉派貨量，到貨前也可轉。
  -- 同店預轉仍排除三種「貨不走本店波次」的單（轉走會斷到貨推進鏈）：
  --   a. 非一般團購單（restock ride-along 靠 order_no='RR-x' 特判推 ready、offset 無實貨）
  --   b. 有進行中的調撥 FK 指著它（互助/空中轉/補貨直派 → 到貨判定綁原單 id）
  --   c. 自己就是跨店轉入、貨還沒到的單（到貨判定同樣綁 transfer FK）
  IF v_orig.status NOT IN ('ready','partially_completed') THEN
    IF p_to_pickup_store_id <> v_orig.pickup_store_id THEN
      RAISE EXCEPTION '貨還沒到分店、訂單 % 不可跨店轉單 (status=%)；同店換客人不受此限',
                      p_order_id, v_orig.status;
    END IF;
    IF v_orig.status NOT IN ('pending','confirmed','reserved','shipping') THEN
      RAISE EXCEPTION '訂單 % 狀態（%）不可轉單', p_order_id, v_orig.status;
    END IF;
    IF COALESCE(v_orig.order_kind, 'normal') <> 'normal' THEN
      RAISE EXCEPTION '訂單 % 不是一般團購單（%），須等分店收貨後再轉單',
                      p_order_id, v_orig.order_kind;
    END IF;
    IF EXISTS (SELECT 1 FROM transfers t
                WHERE t.customer_order_id = p_order_id
                  AND t.tenant_id = v_tenant_id
                  AND t.status <> 'cancelled') THEN
      RAISE EXCEPTION '訂單 % 有進行中的調撥，請等分店收貨後再轉單', p_order_id;
    END IF;
    IF v_orig.transferred_from_order_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM customer_orders src
          WHERE src.id = v_orig.transferred_from_order_id
            AND src.pickup_store_id IS DISTINCT FROM v_orig.pickup_store_id) THEN
      RAISE EXCEPTION '訂單 % 是跨店轉入、貨還沒到，請等分店收貨後再轉單', p_order_id;
    END IF;
  END IF;

  IF v_orig.transferred_to_order_id IS NOT NULL THEN
    RAISE EXCEPTION '訂單 #% 已轉出至訂單 #%，不可重複轉出',
                    p_order_id, v_orig.transferred_to_order_id;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_to_pickup_store_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收店（ID %）不存在或不屬於目前商戶', p_to_pickup_store_id;
  END IF;

  v_to_member_id := COALESCE(
    p_to_member_id,
    rpc_get_or_create_store_member(p_to_pickup_store_id, p_operator)
  );

  PERFORM 1 FROM members WHERE id = v_to_member_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收會員（ID %）不存在或不屬於目前商戶', v_to_member_id;
  END IF;

  -- 內部單（【內部】xx店）轉給真會員 = 門市現貨銷售 → 轉出價改鎖現售價。
  -- 店↔店互助（目標也是 store_internal）維持原價不變。
  SELECT (m.member_type = 'store_internal') INTO v_src_is_internal
    FROM members m WHERE m.id = v_orig.member_id;
  v_src_is_internal := COALESCE(v_src_is_internal, FALSE);
  SELECT (m.member_type = 'store_internal') INTO v_dst_is_internal
    FROM members m WHERE m.id = v_to_member_id;
  v_dst_is_internal := COALESCE(v_dst_is_internal, FALSE);

  v_to_channel_id := p_to_channel_id;
  IF v_to_channel_id IS NULL THEN
    SELECT id INTO v_to_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id AND home_store_id = p_to_pickup_store_id
     LIMIT 1;
    IF v_to_channel_id IS NULL THEN
      SELECT id INTO v_to_channel_id
        FROM line_channels
       WHERE tenant_id = v_tenant_id
       LIMIT 1;
    END IF;
  END IF;
  IF v_to_channel_id IS NULL THEN
    RAISE EXCEPTION '接收店找不到可用的 LINE 頻道，無法建立轉入訂單';
  END IF;

  -- 20261013：每轉一次一律開新的轉入單，不再找接收人在同一團的既有單來併
  --   （原本只有互助板 p_aid_board_id 有值時才開新單，20260824060000）。
  --   (團, 頻道, 會員) 這把併單 key 對店與店之間的轉貨是退化的：收件人固定是
  --   接收店的「【內部】xx 店」，同一家店收的轉貨永遠併成同一張；舊單已可取貨時
  --   總倉收件匣看不到這一趟、派不出貨、沒有出貨單，兩邊月結都漏（例：TF0536）。
  --   唯一索引 customer_orders_trio_kind_active_uniq 同檔已放行轉入單
  --   （transferred_from_order_id IS NOT NULL），第二張開得出來。
  -- 轉給自己（接收人＝原單同一位會員、同一個頻道；活動一定相同）→ 照舊擋下
  -- （同 20260806000010 對整單轉的守衛）。
  IF v_to_member_id = v_orig.member_id AND v_to_channel_id = v_orig.channel_id THEN
    RAISE EXCEPTION '這張訂單本來就掛在該接收人（同活動、同頻道）名下，不需要轉出';
  END IF;

  -- 20261013：原本這裡分「併入既有單 / 開新單」兩條，併入那條已拿掉，一律開新單。
  --   下面這段就是原本 ELSE 裡的內容，刻意保留原縮排，方便逐行對照基底。
    SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
    -- TF 序號 = 該團既有 -TF 尾碼最大值 + 1。
    -- COUNT(*)+1 在 RR- 單被硬刪（rpc_delete_restock_request）後會倒退、
    -- 重發已用過的號碼 → duplicate key（2026-08-13 RR-435 事故）。
    -- 團鎖：來源單鎖擋不住兩張不同來源單同時轉出算出同一號。
    PERFORM pg_advisory_xact_lock(hashtext('order_tf_seq:' || v_orig.campaign_id::text));
    SELECT COALESCE(MAX(substring(order_no FROM '-TF([0-9]+)$')::INT), 0) + 1
      INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id
       AND campaign_id = v_orig.campaign_id
       AND order_no ~ '-TF[0-9]+$';
    -- lpad 超寬會截斷（lpad('10001',4)='1000'），寬度要跟著位數長
    v_new_order_no := v_campaign_no || '-TF' ||
                      lpad(v_seq::text, GREATEST(length(v_seq::text), 4), '0');

    -- 同店：mirror source.status，但 partially_completed 映成 'ready' ——
    -- 新單一件都還沒取走，掛「部分取貨」是錯的（取貨頁與收尾邏輯都會誤判）；
    -- 跨店空中轉：confirmed（尾端 helper 會接著建 AT- 單並推 shipping）；
    -- 跨店經總倉：'pending'（維持總倉確認 gate）
    v_new_status := CASE
      WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN
        CASE WHEN v_orig.status = 'partially_completed' THEN 'ready' ELSE v_orig.status END
      WHEN p_is_air_transfer THEN 'confirmed'
      ELSE 'pending'
    END;

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, notes,
      transferred_from_order_id, is_air_transfer, aid_board_id,
      created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
      v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status,
      COALESCE(p_reason, '') ||
        E'\n[轉入 (部分, ' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
        ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
        to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
      p_order_id, p_is_air_transfer, p_aid_board_id,
      p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_new_order_id;

  FOR v_p_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_p_sku_id := (v_p_item ->> 'sku_id')::BIGINT;
    v_p_qty    := (v_p_item ->> 'qty')::NUMERIC;
    IF v_p_qty IS NULL OR v_p_qty <= 0 THEN
      RAISE EXCEPTION '轉移數量必須大於 0';
    END IF;

    SELECT id, qty, campaign_item_id, unit_price, reserved_movement_id
      INTO v_src_item_id, v_src_item_qty, v_src_item_ci, v_src_item_price, v_src_item_reserved
      FROM customer_order_items
     WHERE order_id = p_order_id
       AND sku_id   = v_p_sku_id
       -- 只挑 active 品項當轉出來源；picked_up（貨已交付）/ expired 的列
       -- 拿來轉會把已交付的貨再轉給別人（同 2026-08-10 整單轉出復活 cancelled 品項的事故類型）
       AND status   IN ('pending','reserved','ready')
     ORDER BY id
     LIMIT 1
     FOR UPDATE;
    IF v_src_item_id IS NULL THEN
      RAISE EXCEPTION 'SKU % 不在訂單 #% 內（或品項已取消／已取走），無法轉移', v_p_sku_id, p_order_id;
    END IF;
    IF v_src_item_reserved IS NOT NULL THEN
      RAISE EXCEPTION 'SKU % 已有庫存配貨紀錄（#%），請先釋放配貨再轉移',
                      v_p_sku_id, v_src_item_reserved;
    END IF;
    IF v_src_item_qty < v_p_qty THEN
      RAISE EXCEPTION 'SKU % 可轉數量不足：來源剩 %、要求轉出 %',
                      v_p_sku_id, v_src_item_qty, v_p_qty;
    END IF;

    -- 內部單 → 真會員：轉出價鎖定當下 SKU 現售價（scope='retail' 最新生效版）；
    -- 查無現售價 fallback 來源價。其餘情境維持原價。
    v_item_price := v_src_item_price;
    IF v_src_is_internal AND NOT v_dst_is_internal THEN
      SELECT price INTO v_retail_price
        FROM prices
       WHERE tenant_id = v_tenant_id
         AND sku_id    = v_p_sku_id
         AND scope     = 'retail'
         AND effective_from <= v_now
         AND (effective_to IS NULL OR effective_to > v_now)
       ORDER BY effective_from DESC
       LIMIT 1;
      v_item_price := COALESCE(v_retail_price, v_src_item_price);
    END IF;

    IF v_src_item_qty = v_p_qty THEN
      UPDATE customer_order_items
         SET status = 'cancelled', updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    ELSE
      UPDATE customer_order_items
         SET qty = qty - v_p_qty, updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_new_order_id, v_src_item_ci, v_p_sku_id, v_p_qty, v_item_price,
      'pending', 'aid_transfer', p_operator, p_operator
    ) RETURNING id INTO v_new_item_id;
    -- 本次搬進去的品項 id 留給空中轉出貨（helper 只出這一批，
    -- 不能整張單重出 —— 之前分次追加的品項已經有自己的 AT- 單了）
    v_new_item_ids := array_append(v_new_item_ids, v_new_item_id);
  END LOOP;

  SELECT COUNT(*) INTO v_remaining_count
    FROM customer_order_items
   WHERE order_id = p_order_id AND status != 'cancelled';

  IF v_remaining_count = 0 THEN
    UPDATE customer_orders
       SET status = 'transferred_out',
           transferred_to_order_id = v_new_order_id,
           notes = COALESCE(notes, '') ||
                   E'\n[全部轉出 → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  ELSE
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[' || CASE WHEN v_appended THEN '部分追加' ELSE '部分轉出' END ||
                   ' → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  END IF;

  -- 部分取貨的來源單把剩餘 active 全轉走後要收尾成 completed：
  -- remaining_count 算 status != 'cancelled' 會數到 picked_up 列，永遠走不到
  -- transferred_out 分支（這是對的 —— 已取走的營收要留在原單），但也因此
  -- 沒人關單頭。helper 自帶守衛（無 active + 至少一件 picked_up 才動作），
  -- 其餘情境呼叫等於 no-op。
  PERFORM public._close_orders_all_items_settled(ARRAY[p_order_id], p_operator, v_now);

  -- 這一趟轉移的 order↔order 連結。**兩條分支都要寫**（新建轉入單 / 追加併入
  -- 既有單）—— 只有前者會寫 transferred_from_order_id，追加分支以前什麼線索都
  -- 沒留下，轉出店的儀表板提醒、轉出記錄、隨貨單三個畫面同時查無此事
  -- （2026-08-24 實例）。dest_item_ids 只放本次搬進去的品項，
  -- 轉出店才不會看到／印到別家店在同一張轉入單上的貨。
  -- 20261013：併入分支（連同併入後重開舊單那段）已拿掉，v_appended 恆為 FALSE。
  INSERT INTO public.customer_order_transfer_links (
    tenant_id, source_order_id, dest_order_id, dest_item_ids,
    is_air_transfer, is_partial, appended, reason, transferred_at, created_by,
    aid_board_id)
  VALUES (
    v_tenant_id, p_order_id, v_new_order_id, COALESCE(v_new_item_ids, '{}'::BIGINT[]),
    COALESCE(p_is_air_transfer, FALSE), TRUE, v_appended, p_reason, v_now, p_operator,
    p_aid_board_id)
  ON CONFLICT (source_order_id, dest_order_id, transferred_at) DO NOTHING;

  -- 空中轉：貨當下就從轉出店出去 → 建 AT- 轉移單 + 出庫，轉入單進 shipping。
  -- 接收店在收貨頁收掉就可取貨，沒有「派貨」這一步。同店由 helper 判掉。
  IF COALESCE(p_is_air_transfer, FALSE) THEN
    PERFORM public._air_ship_order_items(
      v_new_order_id, v_orig.pickup_store_id, v_new_item_ids, p_operator, v_now);
  END IF;

  RETURN v_new_order_id;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 4. rpc_create_customer_orders（代客加單；LINE 記事本加單、抵減單也走這支）
--    —— 基底 20260805000140:394 逐字，只改 :464-469 找單：
--    加 transferred_from_order_id IS NULL ＋ ORDER BY id LIMIT 1
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_customer_orders(
  p_campaign_id BIGINT,
  p_channel_id  BIGINT,
  p_rows        JSONB
) RETURNS TABLE (out_order_id BIGINT, out_order_no TEXT, out_item_count INT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_status       TEXT;
  v_campaign_no  TEXT;
  v_row          JSONB;
  v_item         JSONB;
  v_member_id    BIGINT;
  v_pickup_store BIGINT;
  v_nickname     TEXT;
  v_order_id     BIGINT;
  v_order_no     TEXT;
  v_seq          INT;
  v_ci_id        BIGINT;
  v_ci_price     NUMERIC;
  v_qty          NUMERIC;
  v_ci_sku       BIGINT;
  v_existing_qty NUMERIC;
  v_count        INT;
  v_blacklisted  BOOLEAN;
  v_member_name  TEXT;
  v_reopened     TEXT;
BEGIN
  SELECT status, campaign_no INTO v_status, v_campaign_no
    FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF v_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF v_status NOT IN ('open','closed') THEN
    RAISE EXCEPTION 'campaign % is %; only open/closed campaigns accept manual entry',
                    p_campaign_id, v_status;
  END IF;

  PERFORM 1 FROM line_channels WHERE id = p_channel_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'channel % not in tenant', p_channel_id; END IF;

  IF p_rows IS NULL OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'p_rows is empty';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_member_id    := (v_row ->> 'member_id')::BIGINT;
    v_pickup_store := (v_row ->> 'pickup_store_id')::BIGINT;
    v_nickname     := v_row ->> 'nickname';

    IF v_member_id IS NULL THEN RAISE EXCEPTION 'member_id required'; END IF;
    IF v_pickup_store IS NULL THEN RAISE EXCEPTION 'pickup_store_id required'; END IF;

    SELECT no_new_order, COALESCE(name, member_no)
      INTO v_blacklisted, v_member_name
      FROM members
     WHERE id = v_member_id AND tenant_id = v_tenant;
    IF v_blacklisted IS NULL THEN
      RAISE EXCEPTION 'member % not in tenant', v_member_id;
    END IF;
    IF v_blacklisted THEN
      RAISE EXCEPTION '會員「%」已被列入黑名單，禁止建立 / 加單', v_member_name;
    END IF;

    PERFORM 1 FROM stores WHERE id = v_pickup_store AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', v_pickup_store; END IF;

    -- 找既有訂單時排除已 cancelled / expired / transferred_out
    -- (對齊 customer_orders_trio_kind_active_uniq partial UNIQUE 索引)
    -- 20261013：轉入單（transferred_from_order_id IS NOT NULL）不能拿來加單 ——
    --   每轉一次開一張新單之後，同一人同一團可能同時有自己的單和別人轉來的單；
    --   加進轉入單的品項不會進總倉撿貨，客人永遠拿不到。只有轉入單時開新的一般單。
    --   原本沒有排序也沒有 LIMIT，補上 ORDER BY id LIMIT 1 讓挑哪一張固定下來。
    SELECT id INTO v_order_id FROM customer_orders
     WHERE tenant_id = v_tenant
       AND campaign_id = p_campaign_id
       AND channel_id  = p_channel_id
       AND member_id   = v_member_id
       AND status NOT IN ('cancelled','expired','transferred_out')
       AND transferred_from_order_id IS NULL
     ORDER BY id
     LIMIT 1;

    IF v_order_id IS NULL THEN
      SELECT COUNT(*) + 1 INTO v_seq FROM customer_orders
       WHERE tenant_id = v_tenant AND campaign_id = p_campaign_id;
      v_order_no := v_campaign_no || '-' || lpad(v_seq::text, 4, '0');

      INSERT INTO customer_orders (
        tenant_id, order_no, campaign_id, channel_id, member_id,
        nickname_snapshot, pickup_store_id, status, created_by, updated_by
      ) VALUES (
        v_tenant, v_order_no, p_campaign_id, p_channel_id, v_member_id,
        v_nickname, v_pickup_store, 'pending', v_user, v_user
      ) RETURNING id INTO v_order_id;
    ELSE
      UPDATE customer_orders SET
        nickname_snapshot = COALESCE(v_nickname, nickname_snapshot),
        pickup_store_id   = v_pickup_store,
        updated_by        = v_user
      WHERE id = v_order_id
      RETURNING order_no INTO v_order_no;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_row -> 'items')
    LOOP
      v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
      v_qty   := (v_item ->> 'qty')::NUMERIC;
      IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'qty must be > 0'; END IF;

      SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
        FROM campaign_items
       WHERE id = v_ci_id AND tenant_id = v_tenant AND campaign_id = p_campaign_id;
      IF v_ci_price IS NULL THEN
        RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
      END IF;

      SELECT coi.qty INTO v_existing_qty FROM customer_order_items coi
       WHERE coi.order_id = v_order_id AND coi.campaign_item_id = v_ci_id;

      IF v_existing_qty IS NULL THEN
        INSERT INTO customer_order_items (
          tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
          status, source, created_by, updated_by
        ) VALUES (
          v_tenant, v_order_id, v_ci_id, v_ci_sku, v_qty, v_ci_price,
          'pending', 'manual', v_user, v_user
        );
      ELSE
        UPDATE customer_order_items coi SET
          qty        = v_existing_qty + v_qty,
          updated_by = v_user
        WHERE coi.order_id = v_order_id AND coi.campaign_item_id = v_ci_id;
      END IF;
    END LOOP;

    -- 加到「已取貨完成」的既有單時把它重開（同 rpc_transfer_order_partial）
    v_reopened := public._reopen_order_if_completed(v_order_id, v_user, '代客加單');

    SELECT COUNT(*) INTO v_count FROM customer_order_items coi WHERE coi.order_id = v_order_id;
    out_order_id   := v_order_id;
    out_order_no   := v_order_no;
    out_item_count := v_count;
    RETURN NEXT;
  END LOOP;
END;
$$;


-- ----------------------------------------------------------------------------
-- 5. rpc_place_member_order_guarded（會員／LINE 下單）
--    —— 基底 20260910050000:174 逐字，只改 :340-349 找單：
--    加 co.transferred_from_order_id IS NULL ＋ ORDER BY co.id LIMIT 1（FOR UPDATE 保留）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_place_member_order_guarded(
  p_tenant UUID,
  p_campaign_id BIGINT,
  p_channel_id BIGINT,
  p_member_id BIGINT,
  p_pickup_store_id BIGINT,
  p_items JSONB,
  p_notes TEXT DEFAULT NULL,
  p_source TEXT DEFAULT 'liff'
) RETURNS TABLE (
  order_id BIGINT,
  order_no TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign group_buy_campaigns%ROWTYPE;
  v_member members%ROWTYPE;
  v_source TEXT := CASE WHEN p_source = 'pwa' THEN 'pwa' ELSE 'liff' END;
  v_requested_count INT := 0;
  v_requested_total NUMERIC := 0;
  v_total_sold NUMERIC := 0;
  v_order_id BIGINT;
  v_order_no TEXT;
  v_seq INT;
  v_req RECORD;
  v_ci RECORD;
  v_item_sold NUMERIC;
  v_existing_qty NUMERIC;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant required';
  END IF;
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'campaign_id required';
  END IF;
  IF p_channel_id IS NULL THEN
    RAISE EXCEPTION 'channel_id required';
  END IF;
  IF p_member_id IS NULL THEN
    RAISE EXCEPTION 'member_id required';
  END IF;
  IF p_pickup_store_id IS NULL THEN
    RAISE EXCEPTION 'pickup_store_id required';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items required';
  END IF;

  SELECT * INTO v_campaign
    FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = p_tenant
     AND gbc.id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found';
  END IF;
  IF v_campaign.status <> 'open' THEN
    RAISE EXCEPTION 'campaign not open';
  END IF;
  IF COALESCE(v_campaign.is_for_shop, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'campaign not available';
  END IF;
  -- 客人下單看的是「客人收單」（LEAST 會略過 NULL：沒設就退回店家收單）
  IF LEAST(v_campaign.customer_end_at, v_campaign.end_at) IS NOT NULL
     AND LEAST(v_campaign.customer_end_at, v_campaign.end_at) <= NOW() THEN
    RAISE EXCEPTION 'campaign already ended';
  END IF;

  SELECT * INTO v_member
    FROM members m
   WHERE m.tenant_id = p_tenant
     AND m.id = p_member_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member not found';
  END IF;
  IF COALESCE(v_member.no_new_order, false) THEN
    RAISE EXCEPTION 'member blocked';
  END IF;

  PERFORM 1 FROM stores s WHERE s.tenant_id = p_tenant AND s.id = p_pickup_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_store_id required';
  END IF;

  PERFORM 1 FROM line_channels lc WHERE lc.tenant_id = p_tenant AND lc.id = p_channel_id AND lc.is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no active channel for tenant';
  END IF;

  FOR v_req IN
    SELECT
      (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
      (x ->> 'qty')::NUMERIC AS qty
    FROM jsonb_array_elements(p_items) AS x
  LOOP
    IF v_req.campaign_item_id IS NULL OR v_req.qty IS NULL OR v_req.qty <= 0 THEN
      RAISE EXCEPTION 'qty must be > 0';
    END IF;
  END LOOP;

  SELECT COUNT(*), COALESCE(SUM(qty), 0)
    INTO v_requested_count, v_requested_total
    FROM (
      SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
             SUM((x ->> 'qty')::NUMERIC) AS qty
        FROM jsonb_array_elements(p_items) AS x
       GROUP BY (x ->> 'campaign_item_id')::BIGINT
    ) req;

  IF v_requested_count = 0 OR v_requested_total <= 0 THEN
    RAISE EXCEPTION 'items required';
  END IF;

  SELECT COALESCE(SUM(coi.qty), 0)
    INTO v_total_sold
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE co.tenant_id = p_tenant
     AND co.campaign_id = p_campaign_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND coi.status NOT IN ('cancelled', 'expired')
     AND COALESCE(co.order_kind, 'normal') = 'normal';

  IF COALESCE(v_campaign.total_cap_qty, 0) > 0
     AND v_total_sold + v_requested_total > v_campaign.total_cap_qty THEN
    RAISE EXCEPTION 'sold out';
  END IF;

  FOR v_req IN
    SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
           SUM((x ->> 'qty')::NUMERIC) AS qty
      FROM jsonb_array_elements(p_items) AS x
     GROUP BY (x ->> 'campaign_item_id')::BIGINT
  LOOP
    SELECT ci.id, ci.sku_id, ci.unit_price, ci.cap_qty
      INTO v_ci
      FROM campaign_items ci
     WHERE ci.tenant_id = p_tenant
       AND ci.campaign_id = p_campaign_id
       AND ci.id = v_req.campaign_item_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'campaign item not found';
    END IF;

    SELECT COALESCE(SUM(coi.qty), 0)
      INTO v_item_sold
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE co.tenant_id = p_tenant
       AND co.campaign_id = p_campaign_id
       AND coi.campaign_item_id = v_req.campaign_item_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND coi.status NOT IN ('cancelled', 'expired')
       AND COALESCE(co.order_kind, 'normal') = 'normal';

    IF COALESCE(v_ci.cap_qty, 0) > 0 AND v_item_sold + v_req.qty > v_ci.cap_qty THEN
      RAISE EXCEPTION 'item sold out';
    END IF;
  END LOOP;

  -- 20261013：轉入單（transferred_from_order_id IS NOT NULL）不能拿來加單 ——
  --   每轉一次開一張新單之後，同一人同一團可能同時有自己的單和別人轉來的單；
  --   加進轉入單的品項不會進總倉撿貨，客人永遠拿不到。只有轉入單時開新的一般單。
  --   原本沒有排序也沒有 LIMIT，補上 ORDER BY co.id LIMIT 1 讓挑哪一張固定下來。
  SELECT co.id, co.order_no
    INTO v_order_id, v_order_no
    FROM customer_orders co
   WHERE co.tenant_id = p_tenant
     AND co.campaign_id = p_campaign_id
     AND co.channel_id = p_channel_id
     AND co.member_id = p_member_id
     AND COALESCE(co.order_kind, 'normal') = 'normal'
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND co.transferred_from_order_id IS NULL
   ORDER BY co.id
   LIMIT 1
   FOR UPDATE;

  IF v_order_id IS NULL THEN
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders co
     WHERE co.tenant_id = p_tenant
       AND co.campaign_id = p_campaign_id;
    v_order_no := v_campaign.campaign_no || '-' || lpad(v_seq::TEXT, 4, '0');

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, order_kind, notes
    ) VALUES (
      p_tenant, v_order_no, p_campaign_id, p_channel_id, p_member_id,
      v_member.name, p_pickup_store_id, 'pending', 'normal', NULLIF(p_notes, '')
    )
    RETURNING id INTO v_order_id;
  ELSE
    UPDATE customer_orders co
       SET nickname_snapshot = COALESCE(v_member.name, co.nickname_snapshot),
           pickup_store_id = p_pickup_store_id,
           notes = NULLIF(p_notes, ''),
           updated_at = NOW()
     WHERE co.id = v_order_id;
  END IF;

  FOR v_req IN
    SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
           SUM((x ->> 'qty')::NUMERIC) AS qty
      FROM jsonb_array_elements(p_items) AS x
     GROUP BY (x ->> 'campaign_item_id')::BIGINT
  LOOP
    SELECT ci.sku_id, ci.unit_price
      INTO v_ci
      FROM campaign_items ci
     WHERE ci.tenant_id = p_tenant
       AND ci.campaign_id = p_campaign_id
       AND ci.id = v_req.campaign_item_id;

    SELECT coi.qty INTO v_existing_qty
      FROM customer_order_items coi
     WHERE coi.order_id = v_order_id
       AND coi.campaign_item_id = v_req.campaign_item_id
     FOR UPDATE;

    IF v_existing_qty IS NULL THEN
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status, source
      ) VALUES (
        p_tenant, v_order_id, v_req.campaign_item_id, v_ci.sku_id, v_req.qty, v_ci.unit_price, 'pending', v_source
      );
    ELSE
      UPDATE customer_order_items coi
         SET qty = v_existing_qty + v_req.qty,
             source = v_source,
             updated_at = NOW()
       WHERE coi.order_id = v_order_id
         AND coi.campaign_item_id = v_req.campaign_item_id;
    END IF;
  END LOOP;

  order_id := v_order_id;
  order_no := v_order_no;
  RETURN NEXT;
END;
$$;


-- ----------------------------------------------------------------------------
-- 6. _store_add_internal_order_item（採購單頁「分店／批發追加」）
--    —— 基底 20261002000000:526 逐字，只改 :581-597 找單：加 transferred_from_order_id IS NULL
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._store_add_internal_order_item(
  p_tenant           UUID,
  p_campaign_id      BIGINT,
  p_campaign_no      TEXT,
  p_campaign_item_id BIGINT,
  p_sku_id           BIGINT,
  p_unit_price       NUMERIC,
  p_store_id         BIGINT,
  p_qty              NUMERIC,
  p_operator         UUID,
  p_order_note       TEXT,
  p_item_note        TEXT,
  OUT o_order_id       BIGINT,
  OUT o_order_item_id  BIGINT,
  OUT o_order_created  BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- po_store_additions:20261002000000
DECLARE
  v_member_id    BIGINT;
  v_channel_id   BIGINT;
  v_order_status TEXT;
  v_seq          INTEGER;
  v_order_no     TEXT;
BEGIN
  o_order_created := FALSE;

  v_member_id := public.rpc_get_or_create_store_member(p_store_id, p_operator);

  SELECT id
    INTO v_channel_id
    FROM public.line_channels
   WHERE tenant_id = p_tenant
     AND home_store_id = p_store_id
     AND is_active = TRUE
   ORDER BY id
   LIMIT 1;

  IF v_channel_id IS NULL THEN
    SELECT id
      INTO v_channel_id
      FROM public.line_channels
     WHERE tenant_id = p_tenant
       AND is_active = TRUE
     ORDER BY id
     LIMIT 1;
  END IF;

  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION '此公司沒有可用的 LINE 頻道，不能建立店內單';
  END IF;

  -- 找既有的店家單：條件對齊唯一索引 customer_orders_trio_kind_active_uniq
  -- （最新定義 20260901010000:67：order_kind、排除 SP-／WS-、aid_board_id IS NULL）
  -- 20261013：索引同步放行轉入單（transferred_from_order_id IS NOT NULL，20261013000000），
  --   這裡跟著排除 —— 店與店轉貨收進來的轉入單不能拿來追加，否則追加的貨不會進總倉撿貨。
  SELECT id, status
    INTO o_order_id, v_order_status
    FROM public.customer_orders
   WHERE tenant_id = p_tenant
     AND campaign_id = p_campaign_id
     AND channel_id = v_channel_id
     AND member_id = v_member_id
     AND order_kind = 'normal'
     AND status NOT IN ('transferred_out','expired','cancelled')
     AND aid_board_id IS NULL
     AND order_no NOT LIKE 'SP-%'
     AND order_no NOT LIKE 'WS-%'
     AND transferred_from_order_id IS NULL
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF o_order_id IS NULL THEN
    SELECT COUNT(*) + 1
      INTO v_seq
      FROM public.customer_orders
     WHERE tenant_id = p_tenant
       AND campaign_id = p_campaign_id;

    LOOP
      v_order_no := p_campaign_no || '-INT' || lpad(v_seq::TEXT, 4, '0');

      BEGIN
        INSERT INTO public.customer_orders (
          tenant_id, order_no, campaign_id, channel_id, member_id,
          pickup_store_id, status, confirmed_at, order_kind, notes,
          created_by, updated_by
        ) VALUES (
          p_tenant, v_order_no, p_campaign_id, v_channel_id, v_member_id,
          p_store_id, 'confirmed', NOW(), 'normal',
          p_order_note,
          p_operator, p_operator
        )
        RETURNING id INTO o_order_id;

        o_order_created := TRUE;
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        v_seq := v_seq + 1;
      END;
    END LOOP;
  ELSE
    IF v_order_status NOT IN ('pending','confirmed') THEN
      RAISE EXCEPTION '此分店／批發在原團的店內單已進入後段狀態，不能再追加：order_id=%, status=%',
        o_order_id, v_order_status;
    END IF;
  END IF;

  INSERT INTO public.customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by
  ) VALUES (
    p_tenant, o_order_id, p_campaign_item_id, p_sku_id, p_qty, p_unit_price,
    'pending', 'store_internal', p_item_note,
    p_operator, p_operator
  )
  RETURNING id INTO o_order_item_id;
END;
$$;


-- ----------------------------------------------------------------------------
-- 7. rpc_restore_cancelled_order 守衛 5
--    —— 基底 20260818000000:102 逐字，只改 :157-175：豁免條件對齊新索引
--    （加 WS-、aid_board_id IS NULL、transferred_from_order_id IS NULL）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_restore_cancelled_order(
  p_order_id BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order        customer_orders%ROWTYPE;
  v_src          customer_orders%ROWTYPE;
  v_item_ids     BIGINT[] := ARRAY[]::BIGINT[];
  v_items        INTEGER  := 0;
  v_has_picked   BOOLEAN  := FALSE;
  v_has_active   BOOLEAN  := FALSE;
  v_new_status   TEXT;
  v_pickable     BOOLEAN  := FALSE;
  v_dup_no       TEXT;
  v_wallet       NUMERIC  := 0;
  v_wallet_id    BIGINT;
  v_redispatch   BOOLEAN  := FALSE;
BEGIN
  -- 與 rpc_cancel_aid_order 同一把鎖：不能一邊取消一邊復原
  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  -- 權限 + tenant 隔離 + FOR UPDATE（HQ tier 全部 / 店長限 app_metadata.stores
  -- 含本單 pickup_store；與改數量 / 刪品項同一道閘）
  v_order := public._check_order_edit_qty_perm(p_order_id);

  -- ── 守衛 1：只復原「已取消」 ──
  IF v_order.status <> 'cancelled' THEN
    RAISE EXCEPTION '訂單 % 目前是「%」，不是已取消的單，沒有東西可以復原',
      v_order.order_no, v_order.status;
  END IF;

  -- ── 守衛 2：斷貨取消歸採購單管 ──
  IF v_order.stockout_at IS NOT NULL THEN
    RAISE EXCEPTION '訂單 % 是供應商斷貨造成的取消，請到對應的採購單按「回復斷貨」一併還原；單獨復原這張單會讓採購 / 開團商品 / 補貨鏈的連動對不上',
      v_order.order_no;
  END IF;

  -- ── 守衛 3：轉入單（互助 / 轉給別人）──
  IF v_order.transferred_from_order_id IS NOT NULL THEN
    SELECT * INTO v_src FROM customer_orders WHERE id = v_order.transferred_from_order_id;
    RAISE EXCEPTION '訂單 % 是轉入單，取消時貨已經還給來源單 %（目前「%」）。請直接到來源單重新轉一次，復原這張會變成兩張單掛著同一批貨',
      v_order.order_no, COALESCE(v_src.order_no, '?'), COALESCE(v_src.status, '?');
  END IF;

  -- ── 守衛 4：現貨直配 ──
  IF v_order.order_no LIKE 'SP-%' THEN
    RAISE EXCEPTION '現貨直配單 % 的取消就是「把貨退回可分配」，沒有復原這個動作：請重新建立一張現貨直配單（會重新檢查現在還有幾件可以配）',
      v_order.order_no;
  END IF;

  -- ── 守衛 5：一會員一活動一張 active 單 ──
  -- 條件逐欄對齊 customer_orders_trio_kind_active_uniq 的 key 與 predicate。
  -- 用 `=` 而非 IS NOT DISTINCT FROM：唯一索引把 NULL 當互不相同，任一欄 NULL
  -- 本來就不會衝突，這裡跟著回 NULL → 不誤擋。
  -- 20261013：補齊索引後來加的豁免（WS- 20260901010000、aid_board_id 20260824060000、
  --   轉入單 20261013000000）—— 那些單不佔 slot，不該擋住復原。
  IF v_order.campaign_id IS NOT NULL
     AND v_order.order_kind IS NOT NULL
     AND v_order.order_kind <> 'restock' THEN
    SELECT co.order_no INTO v_dup_no
      FROM customer_orders co
     WHERE co.tenant_id   = v_order.tenant_id
       AND co.campaign_id = v_order.campaign_id
       AND co.channel_id  = v_order.channel_id
       AND co.member_id   = v_order.member_id
       AND co.order_kind  = v_order.order_kind
       AND co.id <> p_order_id
       AND co.status NOT IN ('transferred_out', 'expired', 'cancelled')
       AND co.order_no NOT LIKE 'SP-%'
       AND co.order_no NOT LIKE 'WS-%'
       AND co.aid_board_id IS NULL
       AND co.transferred_from_order_id IS NULL
     ORDER BY co.id
     LIMIT 1;

    IF v_dup_no IS NOT NULL THEN
      RAISE EXCEPTION '這位客人在同一檔團已經有一張進行中的訂單 %，同一檔團一位客人只能有一張單。請改在那張單上加品項，不要復原這張',
        v_dup_no;
    END IF;
  END IF;

  -- ── 品項還原 ──
  -- active 集合與 rpc_record_pickup 的 v_active_remaining、
  -- _close_orders_all_items_settled 同一套，不另外定義。
  SELECT EXISTS (SELECT 1 FROM customer_order_items x
                  WHERE x.order_id = p_order_id AND x.status = 'picked_up'),
         EXISTS (SELECT 1 FROM customer_order_items x
                  WHERE x.order_id = p_order_id
                    AND x.status IN ('pending', 'reserved', 'ready'))
    INTO v_has_picked, v_has_active;

  -- 只有「一件 active 品項都不剩」才需要還原品項 —— 那就是
  -- rpc_delete_order_item 刪到最後一項連帶取消整單的空殼單。
  -- 兩道限制缺一不可：
  --   (a) 還有 active 品項就完全不碰 cancelled 列。部分轉出（rpc_transfer_order_partial）
  --       把搬走的來源列標成 cancelled，貨已經在別人的單上，復活就是憑空生貨
  --       （CLAUDE.md 反覆記載的幽靈品項）。
  --   (b) updated_at 與單頭 cancelled_at **逐字相等**才還。兩者在同一個交易裡都是
  --       NOW()（＝交易時間戳，trg_touch_coi 也是 NOW()），所以相等 ⇔ 同一個交易被
  --       取消。刻意不用「相差幾秒內」的區間：那會把剛好在取消前一兩秒被搬走或被
  --       手動刪掉的列一起撈進來。
  --   斷貨列（stockout_at IS NOT NULL）一律不還，那歸採購單的回復斷貨管。
  IF NOT v_has_active AND v_order.cancelled_at IS NOT NULL THEN
    WITH upd AS (
      UPDATE customer_order_items coi
         SET status     = 'pending',
             updated_by = p_operator,
             updated_at = NOW()
       WHERE coi.order_id = p_order_id
         AND coi.status = 'cancelled'
         AND coi.stockout_at IS NULL
         AND coi.updated_at = v_order.cancelled_at
       RETURNING coi.id
    )
    SELECT COALESCE(ARRAY_AGG(id), ARRAY[]::BIGINT[]) INTO v_item_ids FROM upd;

    v_has_active := COALESCE(array_length(v_item_ids, 1), 0) > 0;
  END IF;
  v_items := COALESCE(array_length(v_item_ids, 1), 0);

  -- ── 守衛 6：救回來要有東西 ──
  IF NOT v_has_picked AND NOT v_has_active THEN
    RAISE EXCEPTION '訂單 % 沒有任何可以復原的品項（品項都已取消或斷貨），請改開一張新單',
      v_order.order_no;
  END IF;

  -- ── 儲值金：取消時退了多少就扣回多少（餘額不足會在這裡 RAISE 並整筆 rollback）──
  IF COALESCE(v_order.wallet_paid_amount, 0) > 0 AND v_order.member_id IS NOT NULL THEN
    v_wallet_id := rpc_wallet_spend(
      v_order.tenant_id,
      v_order.member_id,
      v_order.wallet_paid_amount,
      'customer_order',
      p_order_id,
      p_operator
    );
    v_wallet := v_order.wallet_paid_amount;
  END IF;

  -- ── 單頭狀態重算（規則同 rpc_restore_stockout_po:653-677）──
  IF v_has_picked AND v_has_active THEN
    v_new_status := 'partially_completed';
  ELSIF v_has_picked THEN
    v_new_status := 'completed';
  ELSIF v_order.confirmed_at IS NOT NULL THEN
    v_new_status := 'confirmed';
  ELSE
    v_new_status := 'pending';
  END IF;

  -- 派貨中被取消的單：transfer chain 已經反向回收，貨回到轉出端 → 要重新派。
  -- 回傳這個旗標讓前端把「需要重新派貨」講出來，不然店員會以為貨還在路上。
  v_redispatch := EXISTS (
    SELECT 1 FROM transfers t
     WHERE t.customer_order_id = p_order_id
       AND t.tenant_id = v_order.tenant_id
       AND t.status = 'cancelled'
  );

  UPDATE customer_orders
     SET status       = v_new_status,
         cancelled_at = NULL,
         -- 回到未出貨狀態就把出貨/到貨時間戳清掉，讓 status 與時間戳一致
         -- （對齊 20260814020010 的作法）；下面若過了取貨閘門會再補 ready_at。
         shipping_at  = CASE WHEN v_new_status IN ('pending', 'confirmed')
                             THEN NULL ELSE shipping_at END,
         ready_at     = CASE WHEN v_new_status IN ('pending', 'confirmed')
                             THEN NULL ELSE ready_at END,
         completed_at = CASE WHEN v_new_status = 'completed'
                             THEN COALESCE(completed_at, NOW()) ELSE NULL END,
         updated_by   = p_operator,
         updated_at   = NOW()
   WHERE id = p_order_id;

  -- 貨其實已經到店了就直接推 ready（同 rpc_cancel_aid_order 還原來源單那一段）：
  -- 波次早就跑完的話 confirmed 不會再被 mark_shipping 推進，會永遠卡住。
  IF v_new_status = 'confirmed' THEN
    v_pickable := public.is_order_pickup_ready(p_order_id);
    IF v_pickable THEN
      UPDATE customer_orders
         SET status     = 'ready',
             ready_at   = COALESCE(ready_at, NOW()),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = p_order_id
         AND status = 'confirmed';
      v_new_status := 'ready';
    END IF;
  END IF;

  -- ── 稽核 ──
  IF v_items > 0 THEN
    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    )
    SELECT v_order.tenant_id, p_order_id, 'item', x, 'status',
           to_jsonb('cancelled'::TEXT), to_jsonb('pending'::TEXT),
           format('復原取消訂單時一併還原%s',
                  COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
           p_operator
      FROM unnest(v_item_ids) AS x;
  END IF;

  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_order.tenant_id, p_order_id, 'order', p_order_id, 'status',
    to_jsonb('cancelled'::TEXT), to_jsonb(v_new_status),
    format('復原取消（還原品項 %s 項%s%s）%s',
           v_items,
           CASE WHEN v_wallet > 0
                THEN format('、重扣儲值金 %s', trim_scale(v_wallet)::TEXT) ELSE '' END,
           CASE WHEN v_redispatch THEN '、原派貨已回收需重派' ELSE '' END,
           COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
    p_operator
  );

  RETURN jsonb_build_object(
    'order_id',         p_order_id,
    'order_no',         v_order.order_no,
    'status',           v_new_status,
    'items_restored',   v_items,
    'pickup_ready',     v_pickable,
    'needs_redispatch', v_redispatch,
    'wallet_recharged', v_wallet,
    'wallet_ledger_id', v_wallet_id,
    -- 減抵單覆蓋刻意不還原（trg_release_idn_coverage 的釋放是不可逆的），
    -- 前端要提醒店家「需要的話請重開減抵單」
    'idn_coverage_restored', FALSE
  );
END;
$$;


-- ----------------------------------------------------------------------------
-- 8. rpc_add_pr_store_demands（請購單草稿「分店／批發加單」）
--    —— 基底 20260924010000:4 逐字，只改三處，都是加 transferred_from_order_id IS NULL：
--    :271-285 找單；:391-401 candidate_orders（自動確認）；:439-448 v_pending_order_nos（pending 擋單）
--    跟第 6 段 _store_add_internal_order_item 是「兩份同樣的邏輯」
--    （20261002000000 檔頭 :40-44：改一份要兩份一起改），所以一起改。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_add_pr_store_demands(
  p_pr_id        BIGINT,
  p_pr_item_id   BIGINT,
  p_campaign_id  BIGINT,
  p_additions    JSONB,
  p_operator     UUID,
  p_request_key  UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant                 UUID := public._current_tenant_id();
  v_role                   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_pr                     RECORD;
  v_campaign               RECORD;
  v_campaign_item_id        BIGINT;
  v_campaign_unit_price     NUMERIC;
  v_attr_count              INTEGER := 0;
  v_current_campaign_qty    NUMERIC := 0;
  v_store_added_qty         NUMERIC := 0;
  v_pr_delta_qty            NUMERIC := 0;
  v_demand_qty              NUMERIC := 0;
  v_already_qty             NUMERIC := 0;
  v_store_count             INTEGER := 0;
  v_order_count             INTEGER := 0;
  v_bad_count               INTEGER := 0;
  v_missing_store_ids       TEXT;
  v_member_id               BIGINT;
  v_channel_id              BIGINT;
  v_order_id                BIGINT;
  v_order_item_id           BIGINT;
  v_order_status            TEXT;
  v_pending_order_nos        TEXT;
  v_seq                     INTEGER;
  v_order_no                TEXT;
  v_existing                RECORD;
  r                         RECORD;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  IF v_role IN ('store_manager','store_staff') THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  IF v_role NOT IN ('owner','admin','hq_manager','purchaser','assistant','') THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;

  IF p_operator IS NULL THEN
    RAISE EXCEPTION 'operator is required';
  END IF;

  IF auth.uid() IS NOT NULL AND p_operator <> auth.uid() THEN
    RAISE EXCEPTION 'operator must match current user';
  END IF;

  IF p_request_key IS NULL THEN
    RAISE EXCEPTION 'request key is required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('pr_store_add:' || p_request_key::TEXT));

  SELECT
      pr_id,
      pr_item_id,
      campaign_id,
      created_by,
      COUNT(*) AS store_count,
      COALESCE(SUM(qty_added), 0) AS store_added_qty,
      COALESCE(MAX(pr_delta_qty), 0) AS pr_delta_qty,
      MAX(pr_qty_after) AS pr_qty_after
    INTO v_existing
    FROM public.purchase_request_store_additions
   WHERE tenant_id = v_tenant
     AND request_key = p_request_key
   GROUP BY pr_id, pr_item_id, campaign_id, created_by;

  IF FOUND THEN
    IF v_existing.pr_id <> p_pr_id
       OR v_existing.pr_item_id <> p_pr_item_id
       OR v_existing.campaign_id <> p_campaign_id
       OR v_existing.created_by <> p_operator THEN
      RAISE EXCEPTION 'request key already used by another store-addition request';
    END IF;

    RETURN jsonb_build_object(
      'pr_id', p_pr_id,
      'pr_item_id', p_pr_item_id,
      'campaign_id', p_campaign_id,
      'request_key', p_request_key,
      'store_count', v_existing.store_count,
      'store_added_qty', v_existing.store_added_qty,
      'pr_delta_qty', v_existing.pr_delta_qty,
      'new_pr_qty', v_existing.pr_qty_after,
      'idempotent', TRUE
    );
  END IF;

  IF p_additions IS NULL OR jsonb_typeof(p_additions) <> 'array' OR jsonb_array_length(p_additions) = 0 THEN
    RAISE EXCEPTION '請至少選一間分店或批發與數量';
  END IF;

  SELECT
      pr.id AS pr_id,
      pr.pr_no,
      pr.tenant_id,
      pr.status AS pr_status,
      pr.total_amount,
      pri.id AS pr_item_id,
      pri.sku_id,
      pri.qty_requested,
      pri.unit_cost,
      pri.source_campaign_id,
      pri.po_item_id
    INTO v_pr
    FROM public.purchase_requests pr
    JOIN public.purchase_request_items pri
      ON pri.pr_id = pr.id
   WHERE pr.id = p_pr_id
     AND pri.id = p_pr_item_id
     AND pr.tenant_id = v_tenant
   FOR UPDATE OF pr, pri;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到這張請購單品項';
  END IF;

  IF v_pr.pr_status <> 'draft' THEN
    RAISE EXCEPTION '只有草稿請購單可以分店／批發加單，目前狀態=%', v_pr.pr_status;
  END IF;

  IF v_pr.po_item_id IS NOT NULL THEN
    RAISE EXCEPTION '此品項已經建立採購單，不能在草稿頁追加分店／批發需求';
  END IF;

  SELECT id, campaign_no, name, status
    INTO v_campaign
    FROM public.group_buy_campaigns
   WHERE id = p_campaign_id
     AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到原團 %', p_campaign_id;
  END IF;

  IF v_campaign.status NOT IN ('closed','locked') THEN
    RAISE EXCEPTION '只有已結單/已鎖定的原團可以從請購單追加，目前狀態=%', v_campaign.status;
  END IF;

  SELECT ci.id, ci.unit_price
    INTO v_campaign_item_id, v_campaign_unit_price
    FROM public.campaign_items ci
   WHERE ci.tenant_id = v_tenant
     AND ci.campaign_id = p_campaign_id
     AND ci.sku_id = v_pr.sku_id;

  IF v_campaign_item_id IS NULL THEN
    RAISE EXCEPTION '此品項不屬於指定原團';
  END IF;

  SELECT COUNT(*)
    INTO v_attr_count
    FROM public.purchase_request_item_campaigns
   WHERE pr_item_id = p_pr_item_id;

  IF v_attr_count > 0 THEN
    SELECT qty_requested
      INTO v_current_campaign_qty
      FROM public.purchase_request_item_campaigns
     WHERE pr_item_id = p_pr_item_id
       AND campaign_id = p_campaign_id
       AND tenant_id = v_tenant;

    IF v_current_campaign_qty IS NULL THEN
      RAISE EXCEPTION '這個原團沒有綁在此請購品項上，請選正確原團';
    END IF;
  ELSE
    IF v_pr.source_campaign_id IS NULL THEN
      RAISE EXCEPTION '此品項缺少原團明細，不能用分店／批發加單';
    END IF;
    IF v_pr.source_campaign_id <> p_campaign_id THEN
      RAISE EXCEPTION '此品項的原團不符，不能用分店／批發加單';
    END IF;
    v_current_campaign_qty := v_pr.qty_requested;
  END IF;

  DROP TABLE IF EXISTS _pr_store_add_raw;
  CREATE TEMP TABLE _pr_store_add_raw ON COMMIT DROP AS
  SELECT
    x.store_id::BIGINT AS store_id,
    x.qty::NUMERIC AS qty
  FROM jsonb_to_recordset(p_additions) AS x(store_id BIGINT, qty NUMERIC);

  SELECT COUNT(*)
    INTO v_bad_count
    FROM _pr_store_add_raw
   WHERE store_id IS NULL
      OR qty IS NULL
      OR qty <= 0;

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION '分店／批發加單數量必須大於 0';
  END IF;

  DROP TABLE IF EXISTS _pr_store_add_input;
  CREATE TEMP TABLE _pr_store_add_input ON COMMIT DROP AS
  SELECT store_id, SUM(qty)::NUMERIC(18,3) AS qty
    FROM _pr_store_add_raw
   GROUP BY store_id;

  SELECT COUNT(*), COALESCE(SUM(qty), 0)
    INTO v_store_count, v_store_added_qty
    FROM _pr_store_add_input;

  SELECT string_agg(i.store_id::TEXT, ',')
    INTO v_missing_store_ids
    FROM _pr_store_add_input i
    LEFT JOIN public.stores s
      ON s.id = i.store_id
     AND s.tenant_id = v_tenant
     AND s.is_active = TRUE
     AND s.deleted_at IS NULL
     AND COALESCE(s.store_kind, 'branch') IN ('branch', 'wholesale')
   WHERE s.id IS NULL;

  IF v_missing_store_ids IS NOT NULL THEN
    RAISE EXCEPTION '有分店／批發不存在、停用或已刪除：%', v_missing_store_ids;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_campaign_id::TEXT), hashtext(v_pr.sku_id::TEXT));

  FOR r IN SELECT store_id, qty FROM _pr_store_add_input ORDER BY store_id
  LOOP
    v_member_id := public.rpc_get_or_create_store_member(r.store_id, p_operator);

    SELECT id
      INTO v_channel_id
      FROM public.line_channels
     WHERE tenant_id = v_tenant
       AND home_store_id = r.store_id
       AND is_active = TRUE
     ORDER BY id
     LIMIT 1;

    IF v_channel_id IS NULL THEN
      SELECT id
        INTO v_channel_id
        FROM public.line_channels
       WHERE tenant_id = v_tenant
         AND is_active = TRUE
       ORDER BY id
       LIMIT 1;
    END IF;

    IF v_channel_id IS NULL THEN
      RAISE EXCEPTION '此公司沒有可用的 LINE 頻道，不能建立店內單';
    END IF;

    -- 20261013：索引同步放行轉入單（transferred_from_order_id IS NOT NULL，20261013000000），
    --   這裡跟著排除 —— 店與店轉貨收進來的轉入單不能拿來追加，否則追加的貨不會進總倉撿貨。
    SELECT id, status
      INTO v_order_id, v_order_status
      FROM public.customer_orders
     WHERE tenant_id = v_tenant
       AND campaign_id = p_campaign_id
       AND channel_id = v_channel_id
       AND member_id = v_member_id
       AND order_kind = 'normal'
       AND status NOT IN ('transferred_out','expired','cancelled')
       AND aid_board_id IS NULL
       AND order_no NOT LIKE 'SP-%'
       AND order_no NOT LIKE 'WS-%'
       AND transferred_from_order_id IS NULL
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF v_order_id IS NULL THEN
      SELECT COUNT(*) + 1
        INTO v_seq
        FROM public.customer_orders
       WHERE tenant_id = v_tenant
         AND campaign_id = p_campaign_id;

      LOOP
        v_order_no := v_campaign.campaign_no || '-INT' || lpad(v_seq::TEXT, 4, '0');

        BEGIN
          INSERT INTO public.customer_orders (
            tenant_id, order_no, campaign_id, channel_id, member_id,
            pickup_store_id, status, confirmed_at, order_kind, notes,
            created_by, updated_by
          ) VALUES (
            v_tenant, v_order_no, p_campaign_id, v_channel_id, v_member_id,
            r.store_id, 'confirmed', NOW(), 'normal',
            format('【請購單草稿分店／批發加單】%s', v_pr.pr_no),
            p_operator, p_operator
          )
          RETURNING id INTO v_order_id;

          v_order_count := v_order_count + 1;
          EXIT;
        EXCEPTION WHEN unique_violation THEN
          v_seq := v_seq + 1;
        END;
      END LOOP;
    ELSE
      IF v_order_status NOT IN ('pending','confirmed') THEN
        RAISE EXCEPTION '此分店／批發在原團的店內單已進入後段狀態，不能從請購單草稿追加：order_id=%, status=%',
          v_order_id, v_order_status;
      END IF;

    END IF;

    INSERT INTO public.customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, notes, created_by, updated_by
    ) VALUES (
      v_tenant, v_order_id, v_campaign_item_id, v_pr.sku_id, r.qty, v_campaign_unit_price,
      'pending', 'store_internal', format('請購單 %s 草稿分店／批發加單', v_pr.pr_no),
      p_operator, p_operator
    )
    RETURNING id INTO v_order_item_id;

    INSERT INTO public.purchase_request_store_additions (
      tenant_id, pr_id, pr_item_id, campaign_id, store_id,
      order_id, order_item_id, sku_id, qty_added, request_key, created_by
    ) VALUES (
      v_tenant, p_pr_id, p_pr_item_id, p_campaign_id, r.store_id,
      v_order_id, v_order_item_id, v_pr.sku_id, r.qty, p_request_key, p_operator
    );
  END LOOP;

  SELECT d.delta_qty, d.demand_qty, d.already_qty
    INTO v_pr_delta_qty, v_demand_qty, v_already_qty
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id]) d
   WHERE d.campaign_id = p_campaign_id
     AND d.sku_id = v_pr.sku_id;

  v_pr_delta_qty := COALESCE(v_pr_delta_qty, 0);
  v_demand_qty := COALESCE(v_demand_qty, 0);
  v_already_qty := COALESCE(v_already_qty, 0);

  IF v_pr_delta_qty > 0 THEN
    INSERT INTO public.purchase_request_item_campaigns (
      pr_item_id, campaign_id, tenant_id, qty_requested
    ) VALUES (
      p_pr_item_id, p_campaign_id, v_tenant, v_current_campaign_qty + v_pr_delta_qty
    )
    ON CONFLICT (pr_item_id, campaign_id) DO UPDATE
       SET qty_requested = EXCLUDED.qty_requested;

    UPDATE public.purchase_request_items
       SET qty_requested = qty_requested + v_pr_delta_qty,
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = p_pr_item_id;

    INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
    VALUES (p_pr_id, p_campaign_id, v_tenant)
    ON CONFLICT (pr_id, campaign_id) DO NOTHING;

    UPDATE public.purchase_requests pr
       SET total_amount = COALESCE((
             SELECT SUM(pri.line_subtotal)
               FROM public.purchase_request_items pri
              WHERE pri.pr_id = p_pr_id
           ), 0),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE pr.id = p_pr_id;

  END IF;

  DROP TABLE IF EXISTS _pr_store_add_remaining;
  CREATE TEMP TABLE _pr_store_add_remaining ON COMMIT DROP AS
  SELECT d.sku_id, GREATEST(d.delta_qty, 0)::NUMERIC AS delta_qty
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id]) d
   WHERE d.campaign_id = p_campaign_id
     AND d.delta_qty > 0;

  WITH candidate_orders AS (
    SELECT DISTINCT co.id
      FROM public.customer_orders co
      JOIN public.customer_order_items coi
        ON coi.order_id = co.id
     WHERE co.tenant_id = v_tenant
       AND co.campaign_id = p_campaign_id
       AND co.status = 'pending'
       -- 20261013：經總倉轉入單一開就是 pending、等總倉簽收，不是店內單，不能被請購加單推成 confirmed
       AND co.transferred_from_order_id IS NULL
       AND coi.sku_id = v_pr.sku_id
       AND coi.status NOT IN ('cancelled','expired')
  ),
  safe_orders AS (
    SELECT co.id
      FROM public.customer_orders co
      JOIN candidate_orders cand
        ON cand.id = co.id
     WHERE NOT EXISTS (
       SELECT 1
         FROM public.customer_order_items oi
         JOIN _pr_store_add_remaining rem
           ON rem.sku_id = oi.sku_id
          AND rem.delta_qty > 0
        WHERE oi.order_id = co.id
          AND oi.status NOT IN ('cancelled','expired')
     )
  ),
  updated_orders AS (
    UPDATE public.customer_orders co
       SET status = 'confirmed',
           confirmed_at = COALESCE(co.confirmed_at, NOW()),
           updated_by = p_operator,
           updated_at = NOW()
      FROM safe_orders so
     WHERE co.id = so.id
       AND co.status = 'pending'
    RETURNING co.id
  )
  INSERT INTO public.customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  )
  SELECT
    v_tenant, id, 'order', NULL, 'status',
    to_jsonb('pending'::TEXT), to_jsonb('confirmed'::TEXT),
    format('auto-confirmed by PR store addition #%s', p_pr_id),
    p_operator
  FROM updated_orders;

  SELECT string_agg(DISTINCT co.order_no, ', ' ORDER BY co.order_no)
    INTO v_pending_order_nos
    FROM public.customer_orders co
    JOIN public.customer_order_items coi
      ON coi.order_id = co.id
   WHERE co.tenant_id = v_tenant
     AND co.campaign_id = p_campaign_id
     AND co.status = 'pending'
     -- 20261013：經總倉轉入單一開就是 pending、等總倉簽收，不是店內單，不該擋請購加單
     AND co.transferred_from_order_id IS NULL
     AND coi.sku_id = v_pr.sku_id
     AND coi.status NOT IN ('cancelled','expired');

  IF v_pending_order_nos IS NOT NULL THEN
    RAISE EXCEPTION '原團仍有同品項的未確認店內單，且同單其他品項還沒補進請購；請先處理舊待確認店內單或對原團補請購後再加單：%',
      v_pending_order_nos;
  END IF;

  UPDATE public.purchase_request_store_additions
     SET pr_delta_qty = v_pr_delta_qty,
         pr_qty_after = v_pr.qty_requested + v_pr_delta_qty
   WHERE tenant_id = v_tenant
     AND request_key = p_request_key;

  RETURN jsonb_build_object(
    'pr_id', p_pr_id,
    'pr_item_id', p_pr_item_id,
    'campaign_id', p_campaign_id,
    'request_key', p_request_key,
    'store_count', v_store_count,
    'store_added_qty', v_store_added_qty,
    'pr_delta_qty', v_pr_delta_qty,
    'demand_qty', v_demand_qty,
    'already_qty_before_sync', v_already_qty,
    'new_pr_qty', v_pr.qty_requested + v_pr_delta_qty,
    'created_order_count', v_order_count
  );
END;
$$;


-- ----------------------------------------------------------------------------
-- 9. rpc_create_store_internal_order（店長在代客加單畫面幫自己店叫貨）
--    —— 基底 20260507000000:111 逐字，只改 :172-177 找單：加 transferred_from_order_id IS NULL
--    基底沒有寫 public. 前綴、也沒有 SET search_path，照抄不補。
--    ⚠ 這支找單原本就沒有排除已取消／已過期／已轉出的單，也沒有 ORDER BY／LIMIT。
--      那是原本就有的問題，本檔刻意不動（動了會改到「店長叫貨加進哪一張」的既有行為）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_create_store_internal_order(
  p_campaign_id  BIGINT,
  p_store_id     BIGINT,
  p_items        JSONB,
  p_operator     UUID,
  p_notes        TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id    UUID;
  v_campaign_no  TEXT;
  v_campaign_st  TEXT;
  v_member_id    BIGINT;
  v_channel_id   BIGINT;
  v_seq          INT;
  v_order_no     TEXT;
  v_order_id     BIGINT;
  v_item         JSONB;
  v_ci_id        BIGINT;
  v_ci_sku       BIGINT;
  v_ci_price     NUMERIC;
  v_qty          NUMERIC;
  v_unit_price   NUMERIC;
BEGIN
  -- campaign 驗證
  SELECT tenant_id, campaign_no, status
    INTO v_tenant_id, v_campaign_no, v_campaign_st
    FROM group_buy_campaigns WHERE id = p_campaign_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_campaign_st NOT IN ('open','closed') THEN
    RAISE EXCEPTION 'campaign % is %; only open/closed accept internal order',
                    p_campaign_id, v_campaign_st;
  END IF;

  -- p_items 不可空
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;

  -- 取得 / 建立 store_internal member
  v_member_id := rpc_get_or_create_store_member(p_store_id, p_operator);

  -- 取該店任一 line_channel；無則 fallback 到第一個 channel
  SELECT id INTO v_channel_id
    FROM line_channels
   WHERE tenant_id = v_tenant_id AND home_store_id = p_store_id
   LIMIT 1;

  IF v_channel_id IS NULL THEN
    SELECT id INTO v_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id
     LIMIT 1;
  END IF;

  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION 'no line_channel available for tenant';
  END IF;

  -- 找既有 (UNIQUE: tenant+campaign+channel+member)
  -- 20261013：索引同步放行轉入單（transferred_from_order_id IS NOT NULL，20261013000000），
  --   這裡跟著排除 —— 店與店轉貨收進來的轉入單不能拿來追加，否則追加的貨不會進總倉撿貨。
  SELECT id INTO v_order_id FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = p_campaign_id
     AND channel_id  = v_channel_id
     AND member_id   = v_member_id
     AND transferred_from_order_id IS NULL;

  IF v_order_id IS NULL THEN
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id AND campaign_id = p_campaign_id;
    v_order_no := v_campaign_no || '-INT' || lpad(v_seq::text, 4, '0');

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      pickup_store_id, status, notes, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_no, p_campaign_id, v_channel_id, v_member_id,
      p_store_id, 'pending',
      COALESCE(p_notes, '【店長內部叫貨】'),
      p_operator, p_operator
    ) RETURNING id INTO v_order_id;
  END IF;

  -- 寫 items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
    v_qty   := (v_item ->> 'qty')::NUMERIC;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'qty must be > 0';
    END IF;

    SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
      FROM campaign_items
     WHERE id = v_ci_id AND tenant_id = v_tenant_id AND campaign_id = p_campaign_id;
    IF v_ci_price IS NULL THEN
      RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
    END IF;

    -- 自帶 unit_price 覆寫 (88 折用)；NULL 則用 list price
    v_unit_price := COALESCE((v_item ->> 'unit_price')::NUMERIC, v_ci_price);
    IF v_unit_price < 0 THEN
      RAISE EXCEPTION 'unit_price cannot be negative';
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_id, v_ci_id, v_ci_sku, v_qty, v_unit_price,
      'pending', 'store_internal', p_operator, p_operator
    );
  END LOOP;

  RETURN v_order_id;
END;
$$;

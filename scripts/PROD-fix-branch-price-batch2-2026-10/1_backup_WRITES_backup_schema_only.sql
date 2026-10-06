-- ============================================================================
--  第二批分店價錯價修正 1　備份（只新增備份，不改任何原本的資料）
--  日期：2026-10-07　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-第二批分店價錯價修正_九月十月_2026-10-07.md、派工單-第二批分店價錯價修正指令_2026-10-07.md
--  範本：第一批 NEW-ERP九月錯價修正_2026-09-29_1備份（9/30 已在正式系統跑過）；
--        跟第一批不同：①清單換成這一批 ②備份放在「這一批自己的位置」ops_price_fix_b2（不是第一批的 ops_sep_price_fix）
--        ③多一張「修正後十月的樣子」after_oct_lines（還原檔要用）
--  程式出處：唯讀鏡像 origin/main 500ecc32 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    把「改之前」的樣子完整抄一份，放到一個網站程式讀不到的地方（ops_price_fix_b2），之後修正、驗算、還原都靠它：
--      ・這一批品號的全部分店價版本（每一欄）
--      ・九月全部月結表頭、每一行明細、爭議（每一欄）
--      ・九月全部人工調整（有效的、作廢的都抄）
--      ・「現在還沒有九月月結的店」名單（修正時如果替它們新建草稿，還原時才知道要拿掉哪些）
--      ・八月逐筆基準（跟 0-C 同一套；修正檔會拿它逐筆比）
--    可以重跑：每跑一次就多一「輪」備份，修正檔一律用最新那一輪。
--    ⚠ 備份跟修正中間隔太久（中間有人重按月結、改價、加調整…），修正檔會發現「跟備份不一樣」而整筆停下來，那時再跑一次這份就好。
--  ★ 為什麼不跟第一批放在同一個位置（ops_sep_price_fix）：
--    ・第一批 9/30 的修正紀錄（修正編號 1）沒有還原、也不該還原。照第一批的寫法，修正檔看到那個位置「有修正還沒還原」
--      就會停（這一批根本做不下去）；第一批的驗算檔、還原檔則是去那個位置找「最近一次還沒還原的修正」——
--      這一批如果也寫進去，第一批的驗算／還原檔會找到這一批的紀錄，兩批互相干擾；要分開又得在舊表加欄位（⛔ 不准改舊表）。
--    ・這一批多了十月，要多存一張「修正後十月的樣子」，第一批的表沒有。
--    ⇒ 這一批用自己的位置 ops_price_fix_b2，表的結構照抄第一批 7 張、再加 1 張 after_oct_lines；
--      第一批的位置一個字都不讀、不改、不刪。
--  ★ 會不會動資料：不會動原本的任何一筆。只會新建 ops_price_fix_b2 這個位置和裡面的表，並寫入備份。
--  ★ 讀不讀得到：
--    ・ops_price_fix_b2 不在網站程式（API）開放的範圍（0-D 第 303 項可以確認），店家帳號、前端都讀不到。
--    ・另外每張表都開了「列層級保護（RLS）」而且沒有任何開放規則，也把 anon／authenticated 兩種帳號的權限全部收回。
--    ・貼完馬上貼 1-B 再確認一次。
--  ★ 貼的時候 Supabase 可能跳出的視窗（⚠ 我沒辦法在真的 Supabase 上看到畫面，按鈕文字以實際為準）：
--    ・如果跳出「這個查詢會建立沒有 RLS 的表」之類的提醒 → 這份裡每張表都有開 RLS，選「照樣執行／Run」或「執行並開啟 RLS」都可以。
--    ・如果跳出「destructive operation（破壞性操作）」→ 這份不該跳；跳了就先按取消，截圖給 CEO。
--  ★ 看到什麼要停：
--    ・紅字（錯誤）→ 什麼都沒寫進去（整份是同一次），截圖給 CEO
--      （清單裡還有佔位、有重複、有品號在系統查不到，都會在這裡停下來）
--    ・最後結果「八月借用現行價」不是 0 → 修正檔一定會停，先給 CEO 看
--  ★ 老闆另外要做：這份跑完，最後的結果表下載 CSV 存好；另外 0-A、0-B、0-C 的 CSV 也一起存。
-- ============================================================================

DO $bk$
DECLARE
  v_tenant uuid; v_cnt int; v_round int; v_msg text := ''; v_list jsonb;
BEGIN
  -- 建備份位置與表（放在同一個 DO 裡：任何一步失敗整份回滾，不會留下空殼）
  CREATE SCHEMA IF NOT EXISTS ops_price_fix_b2;
  REVOKE ALL ON SCHEMA ops_price_fix_b2 FROM PUBLIC;
  REVOKE ALL ON SCHEMA ops_price_fix_b2 FROM anon, authenticated;

  CREATE TABLE IF NOT EXISTS ops_price_fix_b2.rounds (
    bk_round   INT PRIMARY KEY,
    tenant_id  UUID NOT NULL,
    taken_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    counts     JSONB NOT NULL,
    no_sept_stores JSONB NOT NULL
  );
  CREATE TABLE IF NOT EXISTS ops_price_fix_b2.sku_list (
    bk_round INT NOT NULL, sku_id BIGINT NOT NULL, sku_code TEXT NOT NULL, correct_price NUMERIC NOT NULL, cls TEXT NOT NULL,
    PRIMARY KEY (bk_round, sku_id)
  );
  CREATE TABLE IF NOT EXISTS ops_price_fix_b2.bk_rows (
    bk_round INT NOT NULL, tbl TEXT NOT NULL, pk BIGINT NOT NULL, j JSONB NOT NULL,
    PRIMARY KEY (bk_round, tbl, pk)
  );
  CREATE TABLE IF NOT EXISTS ops_price_fix_b2.aug_lines (
    bk_round INT NOT NULL, store_id BIGINT, entry_type TEXT, transfer_id BIGINT, transfer_item_id BIGINT, sku_id BIGINT,
    qty NUMERIC, booked_at TIMESTAMPTZ, unit_price NUMERIC, amount NUMERIC
  );
  CREATE TABLE IF NOT EXISTS ops_price_fix_b2.fix_log (
    fix_id INT PRIMARY KEY, bk_round INT NOT NULL, operator UUID NOT NULL, void_ids BIGINT[] NOT NULL,
    done_at TIMESTAMPTZ NOT NULL DEFAULT now(), gen_result JSONB, summary JSONB,
    restored_at TIMESTAMPTZ, restore_summary JSONB
  );
  CREATE TABLE IF NOT EXISTS ops_price_fix_b2.after_rows (
    fix_id INT NOT NULL, tbl TEXT NOT NULL, pk BIGINT NOT NULL, j JSONB NOT NULL,
    PRIMARY KEY (fix_id, tbl, pk)
  );
  CREATE TABLE IF NOT EXISTS ops_price_fix_b2.after_sept_lines (
    fix_id INT NOT NULL, store_id BIGINT, entry_type TEXT, transfer_id BIGINT, transfer_item_id BIGINT, sku_id BIGINT,
    qty NUMERIC, booked_at TIMESTAMPTZ, unit_price NUMERIC, amount NUMERIC
  );
  -- 第一批沒有的表：修正剛做完時「這一批品號十月（10/1 ～ 修正當下）的每一筆帳」，還原檔用它確認十月沒有新的異動
  CREATE TABLE IF NOT EXISTS ops_price_fix_b2.after_oct_lines (
    fix_id INT NOT NULL, store_id BIGINT, entry_type TEXT, transfer_id BIGINT, transfer_item_id BIGINT, sku_id BIGINT,
    qty NUMERIC, booked_at TIMESTAMPTZ, unit_price NUMERIC, amount NUMERIC
  );
  ALTER TABLE ops_price_fix_b2.rounds           ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b2.sku_list         ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b2.bk_rows          ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b2.aug_lines        ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b2.fix_log          ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b2.after_rows       ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b2.after_sept_lines ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b2.after_oct_lines  ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON ALL TABLES IN SCHEMA ops_price_fix_b2 FROM PUBLIC;
  REVOKE ALL ON ALL TABLES IN SCHEMA ops_price_fix_b2 FROM anon, authenticated;
  -- 公司：只認「包子媽生鮮小舖」一家
  v_cnt := (SELECT COUNT(*) FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】系統裡叫「包子媽生鮮小舖」的公司有 % 家（要剛好 1 家）。什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;
  v_tenant := (SELECT t.id FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  -- 月結產生器用「stores 第一筆」認公司（20260901000000:135、20260907030000:750）→ 有別家公司的店就不能讓它自動重產
  IF (SELECT COUNT(DISTINCT s.tenant_id) FROM public.stores s) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.stores s WHERE s.tenant_id = v_tenant) THEN
    RAISE EXCEPTION '【停】店家資料裡不只一家公司（或沒有包子媽的店），月結產生器會認錯公司。什麼都沒改，請截圖給 CEO。';
  END IF;
  v_round := COALESCE((SELECT MAX(bk_round) FROM ops_price_fix_b2.rounds), 0) + 1;

  -- 這一批的清單（寫死，與 0-A～0-D、2 修正、3 驗算同一段）
  v_list := (SELECT jsonb_agg(jsonb_build_object('sku_code', v.sku_code, 'correct_price', v.correct_price, 'cls', v.cls))
               FROM (VALUES
    -- ▼▼▼ 清單段開始（只改這一段；每支檔裡這一段逐字相同）▼▼▼
    --   每行：品號、老闆 Excel 正確分店價、類別（A＝從 2026-09-01 00:00 台北時間起改；B＝10/05 才建的版本，從它原本的開始時間起改）
    --   出處：CEO 定案清單 修正清單_第二批_2026-10-07.csv（md5 ad875e3cab5e2cfb53b4f1e0462059d4），行尾註解是 Excel 列號
    ('G01843-01'::text, 87::numeric, 'A'::text),   -- 列 3
    ('G01842-01', 220, 'A'),   -- 列 4
    ('G01844-01', 66, 'A'),   -- 列 5
    ('G02125-01', 66, 'A'),   -- 列 5
    ('G01831-01', 50, 'A'),   -- 列 6
    ('G01835-01', 83, 'A'),   -- 列 8
    ('G01835-02', 83, 'A'),   -- 列 8
    ('G01835-03', 83, 'A'),   -- 列 8
    ('G01838-01', 125, 'A'),   -- 列 9
    ('G01836-02', 202, 'A'),   -- 列 10
    ('G01836-01', 124, 'A'),   -- 列 11
    ('G01846-01', 144, 'A'),   -- 列 12（老闆 10/7 更正為商品 G01846；0-D 10/7 查到它只有這 1 個規格）
    ('G01821-01', 43, 'A'),   -- 列 13
    ('G01821-02', 43, 'A'),   -- 列 13
    ('G01821-03', 43, 'A'),   -- 列 13
    ('G01663-01', 100, 'A'),   -- 列 14
    ('G01665-01', 78, 'A'),   -- 列 15
    ('G01665-02', 78, 'A'),   -- 列 15
    ('G01665-03', 78, 'A'),   -- 列 15
    ('G01665-04', 78, 'A'),   -- 列 15
    ('G01666-01', 105, 'A'),   -- 列 16
    ('G01666-02', 105, 'A'),   -- 列 16
    ('G01666-03', 105, 'A'),   -- 列 16
    ('G01666-04', 105, 'A'),   -- 列 16
    ('G01668-01', 113, 'A'),   -- 列 18
    ('G01814-01', 108, 'A'),   -- 列 19
    ('G01671-01', 108, 'A'),   -- 列 20
    ('G01675-01', 61, 'A'),   -- 列 21
    ('G01676-01', 122, 'A'),   -- 列 22
    ('G01672-01', 61, 'A'),   -- 列 23
    ('G01679-01', 779, 'A'),   -- 列 24
    ('G01680-01', 38, 'A'),   -- 列 25
    ('G01680-02', 38, 'A'),   -- 列 25
    ('G01654-01', 74, 'A'),   -- 列 26、38（同一規格同價，合併）
    ('G01681-01', 85, 'A'),   -- 列 27
    ('G01634-01', 78, 'A'),   -- 列 28
    ('G01634-02', 78, 'A'),   -- 列 28
    ('G01634-03', 78, 'A'),   -- 列 28
    ('G01636-01', 14, 'A'),   -- 列 29
    ('G01639-01', 51, 'A'),   -- 列 31
    ('G01639-02', 51, 'A'),   -- 列 31
    ('G01639-03', 51, 'A'),   -- 列 31
    ('G01639-04', 51, 'A'),   -- 列 31
    ('G01639-05', 51, 'A'),   -- 列 31
    ('G01640-01', 68, 'A'),   -- 列 32
    ('G01642-01', 93, 'A'),   -- 列 33
    ('G01646-01', 106, 'A'),   -- 列 34
    ('G01647-01', 189, 'A'),   -- 列 35
    ('G01615-01', 114, 'A'),   -- 列 37
    ('G01649-01', 155, 'A'),   -- 列 39
    ('G01653-01', 110, 'A'),   -- 列 40
    ('G01656-01', 302, 'A'),   -- 列 41
    ('G01657-01', 302, 'A'),   -- 列 42
    ('G01655-01', 213, 'A'),   -- 列 44
    ('G01628-01', 101, 'A'),   -- 列 46
    ('G01610-01', 101, 'A'),   -- 列 48
    ('G03061-02', 110, 'B'),   -- 列 49（B 類：10/05 才建）
    ('G01611-01', 134, 'A'),   -- 列 50
    ('G01629-01', 115, 'A'),   -- 列 52
    ('G01629-02', 115, 'A'),   -- 列 52
    ('G01632-01', 105, 'A'),   -- 列 54
    ('G01632-02', 105, 'A'),   -- 列 54
    ('G01632-03', 105, 'A'),   -- 列 54
    ('G01632-04', 105, 'A'),   -- 列 54
    ('G01621-01', 311, 'A'),   -- 列 55
    ('G01614-01', 73, 'A'),   -- 列 56
    ('G01623-01', 74, 'A'),   -- 列 57
    ('G01623-02', 74, 'A'),   -- 列 57
    ('G01624-01', 72, 'A'),   -- 列 58
    ('G01626-01', 474, 'A'),   -- 列 59
    ('G01626-02', 474, 'A'),   -- 列 59（規格編號與現價待 0-D 確認）
    ('G01626-03', 474, 'A'),   -- 列 59（規格編號與現價待 0-D 確認）
    ('G01626-04', 474, 'A'),   -- 列 59（規格編號與現價待 0-D 確認）
    ('G01626-05', 474, 'A'),   -- 列 59（規格編號與現價待 0-D 確認）
    ('G01583-02', 945, 'A'),   -- 列 62
    ('G01585-01', 121, 'A'),   -- 列 64
    ('G01589-01', 64, 'A'),   -- 列 66
    ('G01594-01', 123, 'A'),   -- 列 69
    ('G01597-03', 155, 'A'),   -- 列 72
    ('G01597-01', 169, 'A'),   -- 列 73
    ('G01597-02', 174, 'A'),   -- 列 74
    ('G01599-02', 198, 'A'),   -- 列 75
    ('G01600-01', 401, 'A'),   -- 列 77
    ('G01601-01', 117, 'A'),   -- 列 78
    ('G01602-01', 93, 'A'),   -- 列 79
    ('G01554-01', 37, 'A'),   -- 列 81
    ('G01556-01', 84, 'A'),   -- 列 82
    ('G00394-01', 163, 'A'),   -- 列 84
    ('G00394-02', 163, 'A'),   -- 列 84
    ('G00394-03', 163, 'A'),   -- 列 84
    ('G00394-04', 163, 'A'),   -- 列 84
    ('G00394-05', 163, 'A'),   -- 列 84
    ('G00894-02', 185, 'A'),   -- 列 86
    ('G02284-01', 151, 'A')   -- 列 87
    -- ▲▲▲ 清單段結束 ▲▲▲
                    ) v(sku_code, correct_price, cls));
  -- 佔位（品號裡有 ?）、重複、系統查不到：任何一項 → 整份停
  v_msg := (SELECT string_agg(x.sku_code, '、') FROM jsonb_to_recordset(v_list) AS x(sku_code text, correct_price numeric, cls text) WHERE x.sku_code LIKE '%?%');
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】清單裡還有佔位：%（要等老闆確認、CEO 換成真正的規格編號）。什麼都沒寫進去。', v_msg;
  END IF;
  v_cnt := (SELECT COUNT(*) - COUNT(DISTINCT x.sku_code) FROM jsonb_to_recordset(v_list) AS x(sku_code text, correct_price numeric, cls text));
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】清單裡有 % 個重複的品號。什麼都沒寫進去，請截圖給 CEO。', v_cnt;
  END IF;
  v_msg := (SELECT string_agg(x.sku_code, '、') FROM jsonb_to_recordset(v_list) AS x(sku_code text, correct_price numeric, cls text)
             WHERE NOT EXISTS (SELECT 1 FROM public.skus s WHERE s.sku_code = x.sku_code AND s.tenant_id = v_tenant));
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】清單裡這些品號在系統查不到：%。什麼都沒寫進去，請截圖給 CEO。', v_msg;
  END IF;
  INSERT INTO ops_price_fix_b2.sku_list (bk_round, sku_id, sku_code, correct_price, cls)
  SELECT v_round, s.id, x.sku_code, x.correct_price, x.cls
    FROM jsonb_to_recordset(v_list) AS x(sku_code text, correct_price numeric, cls text)
    JOIN public.skus s ON s.sku_code = x.sku_code AND s.tenant_id = v_tenant;
  v_cnt := (SELECT COUNT(*) FROM ops_price_fix_b2.sku_list WHERE bk_round = v_round);
  IF v_cnt <> jsonb_array_length(v_list) THEN
    RAISE EXCEPTION '【停】清單 % 個規格在系統只找到 % 個。什麼都沒寫進去，請截圖給 CEO。', jsonb_array_length(v_list), v_cnt;
  END IF;

  -- 原始資料（整列、每一欄）
  INSERT INTO ops_price_fix_b2.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'prices', x.pk, x.j FROM (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) x;
  INSERT INTO ops_price_fix_b2.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'sms', x.pk, x.j FROM (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01') x;
  INSERT INTO ops_price_fix_b2.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'smsi', x.pk, x.j FROM (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x;
  INSERT INTO ops_price_fix_b2.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'ssa', x.pk, x.j FROM (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01') x;
  INSERT INTO ops_price_fix_b2.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'ssd', x.pk, x.j FROM (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x;

  -- 八月逐筆基準
  INSERT INTO ops_price_fix_b2.aug_lines (bk_round, store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount)
  SELECT v_round, x.* FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) x;

  INSERT INTO ops_price_fix_b2.rounds (bk_round, tenant_id, counts, no_sept_stores)
  SELECT v_round, v_tenant,
         jsonb_build_object(
           'prices', (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'prices'),
           'prices_shared', (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'prices' AND j ->> 'scope_id' IS NULL),
           'sms',    (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'sms'),
           'sms_draft', (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'sms' AND j ->> 'status' = 'draft'),
           'sms_payable', (SELECT COALESCE(SUM((j ->> 'payable_amount')::numeric), 0) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'sms'),
           'smsi',   (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'smsi'),
           'ssa',    (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'ssa'),
           'ssa_active', (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'ssa' AND j ->> 'status' = 'active'),
           'ssa_active_sum', (SELECT COALESCE(SUM((j ->> 'amount')::numeric), 0) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'ssa' AND j ->> 'status' = 'active'),
           'ssd',    (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'ssd'),
           'aug',    (SELECT COUNT(*) FROM ops_price_fix_b2.aug_lines WHERE bk_round = v_round)),
         COALESCE((SELECT jsonb_agg(jsonb_build_object('store_id', s.id, 'code', s.code) ORDER BY s.code)
                     FROM public.stores s
                    WHERE s.tenant_id = v_tenant AND s.location_id IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM public.store_monthly_settlements m
                                       WHERE m.tenant_id = v_tenant AND m.settlement_month = DATE '2026-09-01' AND m.store_id = s.id)), '[]'::jsonb);
END $bk$;

-- 結果（最新一輪備份）
WITH r AS (SELECT * FROM ops_price_fix_b2.rounds ORDER BY bk_round DESC LIMIT 1)
SELECT "項目", "數字", "說明" FROM (
  SELECT 1 AS o, '備份輪次（這一批自己的位置 ops_price_fix_b2）' AS "項目", r.bk_round::text AS "數字", '備份時間 ' || to_char(r.taken_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') AS "說明" FROM r
  UNION ALL SELECT 2, '這一批品號：規格數', (SELECT COUNT(*) FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = r.bk_round)::text,
                   'A 類 ' || (SELECT COUNT(*) FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = r.bk_round AND l.cls = 'A') || ' 個、B 類 '
                   || (SELECT COUNT(*) FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = r.bk_round AND l.cls = 'B') || ' 個' FROM r
  UNION ALL SELECT 3, '這一批品號：分店價版本', r.counts ->> 'prices',
                   '其中全店共用 ' || (r.counts ->> 'prices_shared') || ' 個。只供對照：10/7 盤點⑤ 當時已知的 89 個規格共 116 個（全店共用；G01846、G01626-02～05 當時不在盤點裡）' FROM r
  UNION ALL SELECT 4, '九月月結表頭', r.counts ->> 'sms', '其中草稿 ' || (r.counts ->> 'sms_draft') || ' 張、應收合計 ' || trim_scale((r.counts ->> 'sms_payable')::numeric) || '（10/7 盤點：18 張全草稿、3,507,154）' FROM r
  UNION ALL SELECT 5, '九月月結明細', r.counts ->> 'smsi', '' FROM r
  UNION ALL SELECT 6, '九月人工調整', r.counts ->> 'ssa', '其中有效 ' || (r.counts ->> 'ssa_active') || ' 筆、合計 ' || trim_scale((r.counts ->> 'ssa_active_sum')::numeric) || '（10/7 盤點：有效 16 筆、−14,415）' FROM r
  UNION ALL SELECT 7, '九月月結爭議', r.counts ->> 'ssd', '正常應為 0' FROM r
  UNION ALL SELECT 8, '現在沒有九月月結的店', jsonb_array_length(r.no_sept_stores)::text,
                   COALESCE((SELECT string_agg(e ->> 'code', '、') FROM jsonb_array_elements(r.no_sept_stores) e), '') FROM r
  UNION ALL SELECT 9, '八月逐筆基準', r.counts ->> 'aug', '筆數要跟 0-C 第一列一樣' FROM r
  UNION ALL SELECT 10, '八月借用現行價的筆數',
                   (SELECT COUNT(*) FROM ops_price_fix_b2.aug_lines a
                     WHERE a.bk_round = r.bk_round
                       AND NOT EXISTS (SELECT 1 FROM public.prices pr
                                        WHERE pr.tenant_id = r.tenant_id AND pr.sku_id = a.sku_id AND pr.scope = 'branch' AND pr.scope_id IS NULL
                                          AND pr.price > 0 AND pr.effective_from <= a.booked_at
                                          AND (pr.effective_to IS NULL OR pr.effective_to > a.booked_at)))::text,
                   '不是 0 → 修正檔的八月檢查一定過不了，先停' FROM r
  UNION ALL SELECT 11, '外面讀不讀得到',
                   CASE WHEN has_schema_privilege('anon', 'ops_price_fix_b2', 'USAGE') OR has_schema_privilege('authenticated', 'ops_price_fix_b2', 'USAGE')
                        THEN '❌ 讀得到' ELSE '✅ 讀不到' END,
                   'anon／authenticated 對備份位置沒有權限；接著貼 1-B 再逐項確認' FROM r
) z ORDER BY o;

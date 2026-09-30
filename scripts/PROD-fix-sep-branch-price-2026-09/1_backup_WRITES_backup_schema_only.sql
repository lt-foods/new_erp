-- ============================================================================
--  九月錯價修正 1　備份（只新增備份，不改任何原本的資料）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-九月分店價錯價修正_2026-09-29.md（v2）第 3、8 節
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    把「改之前」的樣子完整抄一份，放到一個網站程式讀不到的地方（ops_sep_price_fix），之後修正、驗算、還原都靠它：
--      ・57 個品號的全部分店價版本（每一欄）
--      ・九月全部月結表頭、每一行明細、爭議（每一欄）
--      ・九月全部人工調整（有效的、作廢的都抄）
--      ・「現在還沒有九月月結的店」名單（修正時如果替它們新建草稿，還原時才知道要拿掉哪些）
--      ・八月逐筆基準（跟 0-C 同一套；修正檔會拿它逐筆比）
--    可以重跑：每跑一次就多一「輪」備份，修正檔一律用最新那一輪。
--    ⚠ 備份跟修正中間隔太久（中間有人重按月結、改價、加調整…），修正檔會發現「跟備份不一樣」而整筆停下來，那時再跑一次這份就好。
--  ★ 會不會動資料：不會動原本的任何一筆。只會新建 ops_sep_price_fix 這個位置和裡面的表，並寫入備份。
--  ★ 讀不讀得到：
--    ・ops_sep_price_fix 不在網站程式（API）開放的範圍（0-D 第 303 項可以確認），店家帳號、前端都讀不到。
--    ・另外每張表都開了「列層級保護（RLS）」而且沒有任何開放規則，也把 anon／authenticated 兩種帳號的權限全部收回。
--  ★ 貼的時候 Supabase 可能跳出的視窗（⚠ 我沒辦法在真的 Supabase 上看到畫面，按鈕文字以實際為準）：
--    ・如果跳出「這個查詢會建立沒有 RLS 的表」之類的提醒 → 這份裡每張表都有開 RLS，選「照樣執行／Run」或「執行並開啟 RLS」都可以。
--    ・如果跳出「destructive operation（破壞性操作）」→ 這份不該跳；跳了就先按取消，截圖給 CEO。
--  ★ 看到什麼要停：
--    ・紅字（錯誤）→ 什麼都沒寫進去（整份是同一次），截圖給 CEO
--    ・最後結果「八月借用現行價」不是 0 → 修正檔一定會停，先給 CEO 看
--  ★ 老闆另外要做：這份跑完，最後的結果表下載 CSV 存好；另外 0-A、0-B、0-C 的 CSV 也一起存。
-- ============================================================================

DO $bk$
DECLARE
  v_tenant uuid; v_cnt int; v_round int; v_msg text := '';
BEGIN
  -- 建備份位置與表（放在同一個 DO 裡：任何一步失敗整份回滾，不會留下空殼）
  CREATE SCHEMA IF NOT EXISTS ops_sep_price_fix;
  REVOKE ALL ON SCHEMA ops_sep_price_fix FROM PUBLIC;
  REVOKE ALL ON SCHEMA ops_sep_price_fix FROM anon, authenticated;

  CREATE TABLE IF NOT EXISTS ops_sep_price_fix.rounds (
    bk_round   INT PRIMARY KEY,
    tenant_id  UUID NOT NULL,
    taken_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    counts     JSONB NOT NULL,
    no_sept_stores JSONB NOT NULL
  );
  CREATE TABLE IF NOT EXISTS ops_sep_price_fix.sku_list (
    bk_round INT NOT NULL, sku_id BIGINT NOT NULL, sku_code TEXT NOT NULL, correct_price NUMERIC NOT NULL, cls TEXT NOT NULL,
    PRIMARY KEY (bk_round, sku_id)
  );
  CREATE TABLE IF NOT EXISTS ops_sep_price_fix.bk_rows (
    bk_round INT NOT NULL, tbl TEXT NOT NULL, pk BIGINT NOT NULL, j JSONB NOT NULL,
    PRIMARY KEY (bk_round, tbl, pk)
  );
  CREATE TABLE IF NOT EXISTS ops_sep_price_fix.aug_lines (
    bk_round INT NOT NULL, store_id BIGINT, entry_type TEXT, transfer_id BIGINT, transfer_item_id BIGINT, sku_id BIGINT,
    qty NUMERIC, booked_at TIMESTAMPTZ, unit_price NUMERIC, amount NUMERIC
  );
  CREATE TABLE IF NOT EXISTS ops_sep_price_fix.fix_log (
    fix_id INT PRIMARY KEY, bk_round INT NOT NULL, operator UUID NOT NULL, void_ids BIGINT[] NOT NULL,
    done_at TIMESTAMPTZ NOT NULL DEFAULT now(), gen_result JSONB, summary JSONB,
    restored_at TIMESTAMPTZ, restore_summary JSONB
  );
  CREATE TABLE IF NOT EXISTS ops_sep_price_fix.after_rows (
    fix_id INT NOT NULL, tbl TEXT NOT NULL, pk BIGINT NOT NULL, j JSONB NOT NULL,
    PRIMARY KEY (fix_id, tbl, pk)
  );
  CREATE TABLE IF NOT EXISTS ops_sep_price_fix.after_sept_lines (
    fix_id INT NOT NULL, store_id BIGINT, entry_type TEXT, transfer_id BIGINT, transfer_item_id BIGINT, sku_id BIGINT,
    qty NUMERIC, booked_at TIMESTAMPTZ, unit_price NUMERIC, amount NUMERIC
  );
  ALTER TABLE ops_sep_price_fix.rounds           ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_sep_price_fix.sku_list         ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_sep_price_fix.bk_rows          ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_sep_price_fix.aug_lines        ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_sep_price_fix.fix_log          ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_sep_price_fix.after_rows       ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_sep_price_fix.after_sept_lines ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON ALL TABLES IN SCHEMA ops_sep_price_fix FROM PUBLIC;
  REVOKE ALL ON ALL TABLES IN SCHEMA ops_sep_price_fix FROM anon, authenticated;
  -- 公司：只認「包子媽生鮮小舖」一家
  v_cnt := (SELECT COUNT(*) FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】系統裡叫「包子媽生鮮小舖」的公司有 % 家（要剛好 1 家）。什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;
  v_tenant := (SELECT t.id FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  -- 月結產生器用「stores 第一筆」認公司（20260901000000:136、20260907030000:750）→ 有別家公司的店就不能讓它自動重產
  IF (SELECT COUNT(DISTINCT s.tenant_id) FROM public.stores s) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.stores s WHERE s.tenant_id = v_tenant) THEN
    RAISE EXCEPTION '【停】店家資料裡不只一家公司（或沒有包子媽的店），月結產生器會認錯公司。什麼都沒改，請截圖給 CEO。';
  END IF;
  v_round := COALESCE((SELECT MAX(bk_round) FROM ops_sep_price_fix.rounds), 0) + 1;

  -- 57 個品號（寫死，與 0-A～0-D 同一份）
  INSERT INTO ops_sep_price_fix.sku_list (bk_round, sku_id, sku_code, correct_price, cls)
  SELECT v_round, s.id, v.sku_code, v.correct_price, v.cls
    FROM (VALUES
    ('G00199-01'::text, 109::numeric, 'A'::text),
    ('G01577-06', 270, 'A'),
    ('G01635-01', 142, 'A'),
    ('G01635-02', 142, 'A'),
    ('G01635-03', 142, 'A'),
    ('G01635-04', 142, 'A'),
    ('G01635-05', 142, 'A'),
    ('G01635-06', 142, 'A'),
    ('G01635-07', 142, 'A'),
    ('G01635-08', 142, 'A'),
    ('G01644-01', 40, 'A'),
    ('G01645-01', 74, 'A'),
    ('G01650-01', 132, 'A'),
    ('G01650-02', 132, 'A'),
    ('G01651-01', 60, 'A'),
    ('G01651-02', 60, 'A'),
    ('G01651-03', 60, 'A'),
    ('G01662-01', 81, 'A'),
    ('G01664-01', 48, 'A'),
    ('G01664-02', 48, 'A'),
    ('G01673-01', 64, 'A'),
    ('G01677-01', 109, 'A'),
    ('G01793-01', 110, 'A'),
    ('G01793-02', 110, 'A'),
    ('G01794-01', 123, 'A'),
    ('G01794-02', 123, 'A'),
    ('G01824-01', 54, 'A'),
    ('G01825-01', 108, 'A'),
    ('G01825-02', 108, 'A'),
    ('G01826-01', 155, 'B'),
    ('G01832-01', 116, 'A'),
    ('G01840-01', 37, 'A'),
    ('G01840-02', 37, 'A'),
    ('G01841-01', 90, 'A'),
    ('G01841-02', 90, 'A'),
    ('G01841-03', 90, 'A'),
    ('G01841-04', 90, 'A'),
    ('G01845-01', 124, 'A'),
    ('G01845-02', 124, 'A'),
    ('G01881-01', 105, 'A'),
    ('G01882-01', 78, 'A'),
    ('G01883-01', 78, 'A'),
    ('G01886-01', 82, 'A'),
    ('G01886-02', 82, 'A'),
    ('G01887-01', 50, 'A'),
    ('G01887-02', 50, 'A'),
    ('G01887-03', 50, 'A'),
    ('G01887-04', 50, 'A'),
    ('G01888-01', 90, 'A'),
    ('G01894-01', 210, 'A'),
    ('G01918-01', 145, 'A'),
    ('G02239-01', 77, 'C'),
    ('G02239-02', 77, 'C'),
    ('G02348-01', 315, 'A'),
    ('G02348-03', 315, 'A'),
    ('G02348-04', 315, 'A'),
    ('G02348-08', 945, 'A')
         ) v(sku_code, correct_price, cls)
    JOIN public.skus s ON s.sku_code = v.sku_code AND s.tenant_id = v_tenant;
  v_cnt := (SELECT COUNT(*) FROM ops_sep_price_fix.sku_list WHERE bk_round = v_round);
  IF v_cnt <> 57 THEN
    RAISE EXCEPTION '【停】57 個品號在系統只找到 % 個。什麼都沒寫進去，請截圖給 CEO。', v_cnt;
  END IF;

  -- 原始資料（整列、每一欄）
  INSERT INTO ops_sep_price_fix.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'prices', x.pk, x.j FROM (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round)) x;
  INSERT INTO ops_sep_price_fix.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'sms', x.pk, x.j FROM (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01') x;
  INSERT INTO ops_sep_price_fix.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'smsi', x.pk, x.j FROM (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x;
  INSERT INTO ops_sep_price_fix.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'ssa', x.pk, x.j FROM (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01') x;
  INSERT INTO ops_sep_price_fix.bk_rows (bk_round, tbl, pk, j) SELECT v_round, 'ssd', x.pk, x.j FROM (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x;

  -- 八月逐筆基準
  INSERT INTO ops_sep_price_fix.aug_lines (bk_round, store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount)
  SELECT v_round, x.* FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round)) x;

  INSERT INTO ops_sep_price_fix.rounds (bk_round, tenant_id, counts, no_sept_stores)
  SELECT v_round, v_tenant,
         jsonb_build_object(
           'prices', (SELECT COUNT(*) FROM ops_sep_price_fix.bk_rows WHERE bk_round = v_round AND tbl = 'prices'),
           'sms',    (SELECT COUNT(*) FROM ops_sep_price_fix.bk_rows WHERE bk_round = v_round AND tbl = 'sms'),
           'sms_draft', (SELECT COUNT(*) FROM ops_sep_price_fix.bk_rows WHERE bk_round = v_round AND tbl = 'sms' AND j ->> 'status' = 'draft'),
           'smsi',   (SELECT COUNT(*) FROM ops_sep_price_fix.bk_rows WHERE bk_round = v_round AND tbl = 'smsi'),
           'ssa',    (SELECT COUNT(*) FROM ops_sep_price_fix.bk_rows WHERE bk_round = v_round AND tbl = 'ssa'),
           'ssa_active', (SELECT COUNT(*) FROM ops_sep_price_fix.bk_rows WHERE bk_round = v_round AND tbl = 'ssa' AND j ->> 'status' = 'active'),
           'ssd',    (SELECT COUNT(*) FROM ops_sep_price_fix.bk_rows WHERE bk_round = v_round AND tbl = 'ssd'),
           'aug',    (SELECT COUNT(*) FROM ops_sep_price_fix.aug_lines WHERE bk_round = v_round)),
         COALESCE((SELECT jsonb_agg(jsonb_build_object('store_id', s.id, 'code', s.code) ORDER BY s.code)
                     FROM public.stores s
                    WHERE s.tenant_id = v_tenant AND s.location_id IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM public.store_monthly_settlements m
                                       WHERE m.tenant_id = v_tenant AND m.settlement_month = DATE '2026-09-01' AND m.store_id = s.id)), '[]'::jsonb);
END $bk$;

-- 結果（最新一輪備份）
WITH r AS (SELECT * FROM ops_sep_price_fix.rounds ORDER BY bk_round DESC LIMIT 1)
SELECT "項目", "數字", "說明" FROM (
  SELECT 1 AS o, '備份輪次' AS "項目", r.bk_round::text AS "數字", '備份時間 ' || to_char(r.taken_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') AS "說明" FROM r
  UNION ALL SELECT 2, '57 品號分店價版本', r.counts ->> 'prices', '盤點時是 96 個版本（(6).csv）；不一樣代表之後有人改過價' FROM r
  UNION ALL SELECT 3, '九月月結表頭', r.counts ->> 'sms', '其中草稿 ' || (r.counts ->> 'sms_draft') || ' 張（盤點時 18 張全草稿）' FROM r
  UNION ALL SELECT 4, '九月月結明細', r.counts ->> 'smsi', '' FROM r
  UNION ALL SELECT 5, '九月人工調整', r.counts ->> 'ssa', '其中有效 ' || (r.counts ->> 'ssa_active') || ' 筆' FROM r
  UNION ALL SELECT 6, '九月月結爭議', r.counts ->> 'ssd', '正常應為 0' FROM r
  UNION ALL SELECT 7, '現在沒有九月月結的店', jsonb_array_length(r.no_sept_stores)::text,
                   COALESCE((SELECT string_agg(e ->> 'code', '、') FROM jsonb_array_elements(r.no_sept_stores) e), '') FROM r
  UNION ALL SELECT 8, '八月逐筆基準', r.counts ->> 'aug', '筆數要跟 0-C 第一列一樣' FROM r
  UNION ALL SELECT 9, '八月借用現行價的筆數',
                   (SELECT COUNT(*) FROM ops_sep_price_fix.aug_lines a
                     WHERE a.bk_round = r.bk_round
                       AND NOT EXISTS (SELECT 1 FROM public.prices pr
                                        WHERE pr.tenant_id = r.tenant_id AND pr.sku_id = a.sku_id AND pr.scope = 'branch' AND pr.scope_id IS NULL
                                          AND pr.price > 0 AND pr.effective_from <= a.booked_at
                                          AND (pr.effective_to IS NULL OR pr.effective_to > a.booked_at)))::text,
                   '不是 0 → 修正檔的八月檢查一定過不了，先停' FROM r
  UNION ALL SELECT 10, '外面讀不讀得到',
                   CASE WHEN has_schema_privilege('anon', 'ops_sep_price_fix', 'USAGE') OR has_schema_privilege('authenticated', 'ops_sep_price_fix', 'USAGE')
                        THEN '❌ 讀得到' ELSE '✅ 讀不到' END,
                   'anon／authenticated 對備份位置沒有權限' FROM r
) z ORDER BY o;

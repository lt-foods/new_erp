-- ============================================================================
--  第三批分店價往回改（蛋小白雞蛋金磚 G02907-01） 1　備份（⛔ 會寫入：只新增備份，不改任何原本的資料）
--  日期：2026-11-02　阿寫寫、⛔ 還沒經阿審（Codex）審過之前不要貼
--  依據：派工單-蛋小白分店價往回改_第三批_2026-11-02.md
--  範本：第二批 scripts/PROD-fix-branch-price-batch2-2026-10/1_backup_WRITES_backup_schema_only.sql
--        【改寫處】①備份位置換成這一批自己的 ops_price_fix_b3（第一批 ops_sep_price_fix、第二批 ops_price_fix_b2 一個字都不碰）
--                  ②清單段 → 事實段（單一規格）
--                  ③備份範圍：九月月結 → 「十月」月結（全部店，因為產生器一次重產整個月）＋十月人工調整＋十月爭議
--                  ④八月逐筆基準 → 「十月以外每一個月份」的月結表頭／明細／調整／爭議整列備份（修正、驗算逐列比對，一個字不能變）
--                     ＋蛋小白 8/1～10/1 的每日對帳逐筆基準（0-C 風格）
--                  ⑤表：多 fix_targets（每家店預期差額）、after_egg_lines（蛋小白 10/1 起每一筆）；
--                     第二批的 aug_lines／after_sept_lines 改成 pre_lines／after_oct_lines
--  程式出處：工程紀錄本 origin/main bafc13d9 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    把「改之前」的樣子完整抄一份，放到一個網站程式讀不到的地方（ops_price_fix_b3），之後修正、驗算、還原都靠它：
--      ・G02907-01 的全部分店價版本（每一欄；派工單要的 26805、33876 兩列都在裡面，連同不會動的 24666）
--      ・十月「全部店」的月結表頭、每一行明細、爭議（每一欄）——派工單要的「11 家店十月草稿」是其中一部分；
--        其他店也要備份，因為月結產生器一叫就是整個月全部店（20260907030000:761-766），方案甲要靠它蓋回、方案乙要靠它比對
--      ・十月全部人工調整（有效的、作廢的都抄）
--      ・十月以外每一個月份（八月、九月、十一月…）的月結表頭／明細／調整／爭議（每一欄）：修正後逐列比，一個字都不能變
--      ・蛋小白 8/1～10/1 的每日對帳逐筆基準（同第二批 0-C 的比法）
--    可以重跑：每跑一次就多一「輪」備份，修正檔一律用最新那一輪。
--    ⚠ 備份跟修正中間隔太久（中間有人重按月結、改價、加調整、派車收貨…），修正檔會發現「跟備份不一樣」而整筆停下來，那時再跑一次這份就好。
--  ★ 會不會動資料：不會動原本的任何一筆。只會新建 ops_price_fix_b3 這個位置和裡面的表，並寫入備份。
--  ★ 讀不讀得到：
--    ・ops_price_fix_b3 不在網站程式（API）開放的範圍（0-D 第 303 項可以確認），店家帳號、前端都讀不到。
--    ・每張表都開了「列層級保護（RLS）」而且沒有任何開放規則，也把 anon／authenticated／authenticator 三種網站連線帳號的權限全部收回。
--    ・貼完馬上貼 1-B 再確認一次。
--  ★ 貼的時候 Supabase 可能跳出的視窗（⚠ 我沒辦法在真的 Supabase 上看到畫面，按鈕文字以實際為準）：
--    ・「這個查詢會建立沒有 RLS 的表」之類的提醒 → 這份裡每張表都有開 RLS，選「照樣執行／Run」或「執行並開啟 RLS」都可以。
--    ・「destructive operation（破壞性操作）」→ 這份不該跳；跳了就先按取消，截圖給 CEO。
--  ★ 看到什麼要停：紅字（錯誤）→ 什麼都沒寫進去（整份是同一次），截圖給 CEO
--  ★ 老闆另外要做：這份跑完，最後的結果表下載 CSV 存好；0-D 的 CSV 也一起存。
-- ============================================================================

DO $bk$
DECLARE
  f record; v_tenant uuid; v_cnt int; v_round int;
BEGIN
  -- 事實段
  SELECT * INTO f FROM (
  -- ▼▼▼ 事實段開始（0-D、1、2、3、4 每支檔這一段逐字相同；出處：派工單「事實」一節＋11/2 老闆貼的唯讀查詢結果）▼▼▼
  SELECT 'G02907-01'::text AS sku_code, 8442::bigint AS sku_id, 4213::bigint AS product_id,
         24666::bigint AS id_a, 26805::bigint AS id_b, 33876::bigint AS id_c,
         62::numeric AS price_a, 64::numeric AS price_b, 42::numeric AS price_new,
         (TIMESTAMP '2026-09-28 18:51:00' AT TIME ZONE 'Asia/Taipei') AS a_from_sec,
         (TIMESTAMP '2026-10-05 16:38:51' AT TIME ZONE 'Asia/Taipei') AS b_from_sec,
         (TIMESTAMP '2026-11-02 11:21:03' AT TIME ZONE 'Asia/Taipei') AS c_from_sec,
         '942e5393-b9aa-4b1b-9102-fd19f8015c31'::uuid AS c_by,
         DATE '2026-10-01' AS oct,
         ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei') AS oct_from,
         ((DATE '2026-11-01')::timestamp AT TIME ZONE 'Asia/Taipei') AS nov_from,
         11 AS exp_n_store, 12 AS exp_n_lines, (-836)::numeric AS exp_delta, 38::numeric AS exp_net_qty,
         ARRAY[-154,-132,-132,-88,-88,-66,-44,-44,-44,-44,0]::numeric[] AS exp_deltas,
         ARRAY[-268,-232,33,232]::numeric[] AS exp_adj
  -- ▲▲▲ 事實段結束 ▲▲▲
  ) x;

  -- 建備份位置與表（放在同一個 DO 裡：任何一步失敗整份回滾，不會留下空殼）
  CREATE SCHEMA IF NOT EXISTS ops_price_fix_b3;
  REVOKE ALL ON SCHEMA ops_price_fix_b3 FROM PUBLIC;
  REVOKE ALL ON SCHEMA ops_price_fix_b3 FROM anon, authenticated, authenticator;

  CREATE TABLE IF NOT EXISTS ops_price_fix_b3.rounds (
    bk_round  INT PRIMARY KEY,
    tenant_id UUID NOT NULL,
    taken_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    counts    JSONB NOT NULL
  );
  -- 整列備份：tbl＝prices（這個規格全部分店價版本）／sms、smsi、ssa、ssd（十月）／x_sms、x_smsi、x_ssa、x_ssd（十月以外每個月）
  CREATE TABLE IF NOT EXISTS ops_price_fix_b3.bk_rows (
    bk_round INT NOT NULL, tbl TEXT NOT NULL, pk BIGINT NOT NULL, j JSONB NOT NULL,
    PRIMARY KEY (bk_round, tbl, pk)
  );
  -- 蛋小白 8/1～10/1 的每日對帳逐筆基準（第二批 aug_lines 的同一種比法）
  CREATE TABLE IF NOT EXISTS ops_price_fix_b3.pre_lines (
    bk_round INT NOT NULL, store_id BIGINT, entry_type TEXT, transfer_id BIGINT, transfer_item_id BIGINT, sku_id BIGINT,
    qty NUMERIC, booked_at TIMESTAMPTZ, unit_price NUMERIC, amount NUMERIC
  );
  CREATE TABLE IF NOT EXISTS ops_price_fix_b3.fix_log (
    fix_id INT PRIMARY KEY, bk_round INT NOT NULL, operator UUID NOT NULL, mode TEXT NOT NULL,
    done_at TIMESTAMPTZ NOT NULL DEFAULT now(), gen_result JSONB, summary JSONB,
    restored_at TIMESTAMPTZ, restore_summary JSONB
  );
  -- 修正時每家「有蛋小白帳」的店：預期差額與修正前後應收
  CREATE TABLE IF NOT EXISTS ops_price_fix_b3.fix_targets (
    fix_id INT NOT NULL, store_id BIGINT NOT NULL, settlement_id BIGINT, n_lines INT, net_qty NUMERIC, delta NUMERIC,
    pay_before NUMERIC, pay_after NUMERIC,
    PRIMARY KEY (fix_id, store_id)
  );
  CREATE TABLE IF NOT EXISTS ops_price_fix_b3.after_rows (
    fix_id INT NOT NULL, tbl TEXT NOT NULL, pk BIGINT NOT NULL, j JSONB NOT NULL,
    PRIMARY KEY (fix_id, tbl, pk)
  );
  -- 修正剛做完時「十月（全部店、全部商品）每一筆帳」，還原檔用它確認十月沒有新的異動
  CREATE TABLE IF NOT EXISTS ops_price_fix_b3.after_oct_lines (
    fix_id INT NOT NULL, store_id BIGINT, entry_type TEXT, transfer_id BIGINT, transfer_item_id BIGINT, sku_id BIGINT,
    qty NUMERIC, booked_at TIMESTAMPTZ, unit_price NUMERIC, amount NUMERIC
  );
  -- 修正剛做完時「蛋小白 10/1 ～ 修正當下每一筆帳」（含十一月），還原檔用它確認沒有新派車
  CREATE TABLE IF NOT EXISTS ops_price_fix_b3.after_egg_lines (
    fix_id INT NOT NULL, store_id BIGINT, entry_type TEXT, transfer_id BIGINT, transfer_item_id BIGINT, sku_id BIGINT,
    qty NUMERIC, booked_at TIMESTAMPTZ, unit_price NUMERIC, amount NUMERIC
  );
  ALTER TABLE ops_price_fix_b3.rounds          ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b3.bk_rows         ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b3.pre_lines       ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b3.fix_log         ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b3.fix_targets     ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b3.after_rows      ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b3.after_oct_lines ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ops_price_fix_b3.after_egg_lines ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON ALL TABLES IN SCHEMA ops_price_fix_b3 FROM PUBLIC;
  REVOKE ALL ON ALL TABLES IN SCHEMA ops_price_fix_b3 FROM anon, authenticated, authenticator;

  -- 公司：只認「包子媽生鮮小舖」一家
  v_cnt := (SELECT COUNT(*) FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】系統裡叫「包子媽生鮮小舖」的公司有 % 家（要剛好 1 家）。什麼都沒寫進去，請截圖給 CEO。', v_cnt;
  END IF;
  v_tenant := (SELECT t.id FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  -- 月結產生器用「stores 第一筆」認公司（20260907030000:750）→ 有別家公司的店就不能讓它自動重產
  IF (SELECT COUNT(DISTINCT s.tenant_id) FROM public.stores s) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.stores s WHERE s.tenant_id = v_tenant) THEN
    RAISE EXCEPTION '【停】店家資料裡不只一家公司（或沒有包子媽的店），月結產生器會認錯公司。什麼都沒寫進去，請截圖給 CEO。';
  END IF;
  -- 規格：品號 ↔ 規格編號 ↔ 商品編號 要對得上
  IF NOT EXISTS (SELECT 1 FROM public.skus s WHERE s.tenant_id = v_tenant AND s.id = f.sku_id AND s.sku_code = f.sku_code AND s.product_id = f.product_id)
     OR (SELECT COUNT(*) FROM public.skus s WHERE s.tenant_id = v_tenant AND s.sku_code = f.sku_code) <> 1 THEN
    RAISE EXCEPTION '【停】品號 % 對不到規格 %／商品 %。什麼都沒寫進去，請截圖給 CEO。', f.sku_code, f.sku_id, f.product_id;
  END IF;
  v_round := COALESCE((SELECT MAX(bk_round) FROM ops_price_fix_b3.rounds), 0) + 1;

  -- 這個規格的全部分店價版本（含指定門市的，修正不會動它們，但還原要能逐欄比對）
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'prices', p.id, to_jsonb(p) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = f.sku_id AND p.scope = 'branch';
  -- 十月：全部店的月結表頭、明細、爭議、人工調整
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct;
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i
   WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct);
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d
   WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct);
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct;
  -- 十月以外每一個月份（修正後要一個字都不變）
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'x_sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct;
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'x_smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i
   WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct);
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'x_ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d
   WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct);
  INSERT INTO ops_price_fix_b3.bk_rows (bk_round, tbl, pk, j)
  SELECT v_round, 'x_ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month <> f.oct;

  -- 蛋小白 8/1～10/1 每日對帳逐筆基準（_store_inbound_lines，20260901000000:597-742）
  INSERT INTO ops_price_fix_b3.pre_lines (bk_round, store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount)
  SELECT v_round, st.id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at, l.unit_branch_price, l.amount
    FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), f.oct_from) l
   WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id;

  INSERT INTO ops_price_fix_b3.rounds (bk_round, tenant_id, counts)
  SELECT v_round, v_tenant, jsonb_build_object(
           'prices',      (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'prices'),
           'prices_ids',  (SELECT string_agg(pk::text || '＝' || trim_scale((j ->> 'price')::numeric)::text, '、' ORDER BY (j ->> 'effective_from')::timestamptz)
                             FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'prices'),
           'sms',         (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'sms'),
           'sms_draft',   (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'sms' AND j ->> 'status' = 'draft'),
           'sms_payable', (SELECT COALESCE(SUM((j ->> 'payable_amount')::numeric), 0) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'sms'),
           'smsi',        (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'smsi'),
           'ssa',         (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'ssa'),
           'ssa_active',  (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'ssa' AND j ->> 'status' = 'active'),
           'ssa_active_sum', (SELECT COALESCE(SUM((j ->> 'amount')::numeric), 0) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'ssa' AND j ->> 'status' = 'active'),
           'ssd',         (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'ssd'),
           'x_sms',       (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'x_sms'),
           'x_smsi',      (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'x_smsi'),
           'x_ssa',       (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'x_ssa'),
           'x_ssd',       (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'x_ssd'),
           'x_months',    (SELECT COALESCE(string_agg(DISTINCT left(j ->> 'settlement_month', 7), '、'), '（沒有）') FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'x_sms'),
           'pre_lines',   (SELECT COUNT(*) FROM ops_price_fix_b3.pre_lines WHERE bk_round = v_round));
END $bk$;

-- 結果（最新一輪備份）
WITH r AS (SELECT * FROM ops_price_fix_b3.rounds ORDER BY bk_round DESC LIMIT 1)
SELECT "項目", "數字", "說明" FROM (
  SELECT 1 AS o, '備份輪次（這一批自己的位置 ops_price_fix_b3）' AS "項目", r.bk_round::text AS "數字", '備份時間 ' || to_char(r.taken_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') AS "說明" FROM r
  UNION ALL SELECT 2, 'G02907-01 分店價版本', r.counts ->> 'prices', 'price_id＝價格：' || COALESCE(r.counts ->> 'prices_ids', '') || '（11/2 盤點：24666＝62、26805＝64、33876＝42）' FROM r
  UNION ALL SELECT 3, '十月月結表頭', r.counts ->> 'sms', '其中草稿 ' || (r.counts ->> 'sms_draft') || ' 張、應收合計 ' || trim_scale((r.counts ->> 'sms_payable')::numeric) || '（11/2 盤點：20 張全草稿）' FROM r
  UNION ALL SELECT 4, '十月月結明細', r.counts ->> 'smsi', '' FROM r
  UNION ALL SELECT 5, '十月人工調整', r.counts ->> 'ssa', '其中有效 ' || (r.counts ->> 'ssa_active') || ' 筆、合計 ' || trim_scale((r.counts ->> 'ssa_active_sum')::numeric) || '（11/2 盤點：4 筆 +33、+232、−232、−268，合計 −235）' FROM r
  UNION ALL SELECT 6, '十月月結爭議', r.counts ->> 'ssd', '正常應為 0' FROM r
  UNION ALL SELECT 7, '十月以外的月結表頭／明細／調整／爭議',
                   (r.counts ->> 'x_sms') || '／' || (r.counts ->> 'x_smsi') || '／' || (r.counts ->> 'x_ssa') || '／' || (r.counts ->> 'x_ssd'),
                   '月份：' || (r.counts ->> 'x_months') || '。修正後逐列比，一個字都不能變' FROM r
  UNION ALL SELECT 8, '蛋小白 8/1～10/1 每日對帳逐筆基準', r.counts ->> 'pre_lines', '11/2 盤點：九月沒有這個商品的派車 → 正常應為 0' FROM r
  UNION ALL SELECT 9, '外面讀不讀得到',
                   CASE WHEN has_schema_privilege('anon', 'ops_price_fix_b3', 'USAGE') OR has_schema_privilege('authenticated', 'ops_price_fix_b3', 'USAGE') OR has_schema_privilege('authenticator', 'ops_price_fix_b3', 'USAGE')
                        THEN '❌ 讀得到' ELSE '✅ 讀不到' END,
                   'anon／authenticated／authenticator 對備份位置沒有權限；接著貼 1-B 再逐項確認' FROM r
) z ORDER BY o;

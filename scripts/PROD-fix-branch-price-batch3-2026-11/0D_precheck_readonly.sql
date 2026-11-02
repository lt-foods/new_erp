-- ============================================================================
--  第三批分店價往回改（蛋小白雞蛋金磚 G02907-01） 0-D　執行前核對（只查不改）
--  日期：2026-11-02　阿寫寫、⛔ 還沒經阿審（Codex）審過之前不要貼
--  依據：派工單-蛋小白分店價往回改_第三批_2026-11-02.md（老闆 11/2 已點頭的做法）
--  範本：第二批 scripts/PROD-fix-branch-price-batch2-2026-10/0D_precheck_readonly.sql
--        【改寫處】①清單段 → 換成「事實段」（單一規格＋三個價格版本＋各店預期差額，全部寫死）
--                  ②A／B 類檢查 → 改成「三個價格版本跟 11/2 盤點逐一相同、前後接得上」
--                  ③十月月結：第二批是「有任何一張就停」；這批相反 → 「每一張都必須是草稿」
--                  ④多了「重產十月會不會連帶改到別的東西」的預覽（第二批的 0-A／0-E 併進來）
--                  ⑤人工調整：第二批列九月、預設可作廢；這批列十月、⛔ 一筆都不作廢、必須原樣保留
--                  ⑥程式核對多 5 項（產生器整月逐店跑、沒活動砍草稿、九月前凍結、查價工具、每日對帳）
--  程式出處：工程紀錄本 origin/main bafc13d9 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    ①找出「你本人」在 NEW-ERP 的使用者 UUID（修正檔的「操作人」要填它；prices.created_by 不可空白，
--      20260422120001:174）。下面 p_my_email 可以填你登入用的信箱（不填就全部列出來讓你認）。
--    ②確認真正的系統裡，修正會用到的程式跟工程紀錄本一樣（月結產生器、改價函式、查價工具、每日對帳、
--      自動蓋章、明細保護）、表上掛的自動動作（觸發器）、店家資料只有一家公司、這批的備份位置外面讀不到。
--    ③三個分店價版本跟 11/2 盤點一模一樣：62（9/28 18:51:00 起）→ 64（10/5 16:38:51 起，請購單核准蓋上去的）
--      → 42（11/2 11:21:03 起，老闆在商品頁改的），而且前後剛好接上、沒有第四個版本。
--    ④十月月結每一張都還是「草稿」（只要有一張已送店家／店家有異議／已確認／作廢 → ❌，修正檔會停）。
--    ⑤十月人工調整：還是那 6 筆（#56 −232、#57 +232、#58 −19、#59 −249、#60 +249、#62 −216，合計 −235），修正⛔不作廢、重產後必須原樣還在。
--    ⑥蛋小白十月的帳：每家店改價後差多少（應該＝11 家、合計 −836、計價數量 38）。
--    ⑦「重產十月月結」會不會連帶改到別的東西（月結產生器只能整個月、全部店一起重產，見下面說明）。
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：（選擇性）填信箱 → 整份貼上 → Run → 下載 CSV 給 CEO。
--  ★ 看到什麼要停：第一列「結果」是 ❌ → 不要做修正，截圖給 CEO。⚠ 是提醒，照說明欄判斷。
--  ★ ✅ 的意思是「關鍵句還在」，不是整支程式逐字一樣。
--  ★ 為什麼要看第 ⑦ 項（重要，CEO 要先裁決用哪一案）：
--    月結產生器 rpc_generate_hq_to_store_settlement 只收「月份＋操作人」兩個參數，一叫就把那個月「每一家店」
--    都重算一次（月結函式 20260907030000:689-1172；參數 :689-692、逐店迴圈 :761-766）；沒有「只算某幾家店」的參數。
--    它對每家店：草稿／已送／有異議 → 金額蓋掉、明細刪掉重建（upsert :968-991；刪舊明細 :994；重建 :1000-1154）；沒任何帳也沒調整 → 草稿直接刪掉（:902-912）；
--    原本沒有月結但有帳 → 新建一張草稿（upsert :968-991）。所以「只重產 11 家」做不到，修正檔有兩個方案（第 2 份檔頭）：
--      方案甲：照樣整月重產，但「其他店」做完後一律蓋回備份原樣（逐欄一樣，含最後異動時間、明細編號）
--      方案乙：整月重產，其他店只要有任何一分錢、任何一行跟備份不一樣就整筆停（一樣的話，只有最後異動時間、明細編號會變）
--    第 7500 項起列出每家店「現在重產會不會變」，讓 CEO／老闆看了再選。
-- ============================================================================

WITH
param AS (
  SELECT ''::text AS p_my_email   -- ⬅ 選填：你登入 NEW-ERP 用的信箱（填在兩個單引號中間）；不填就維持兩個單引號
),
fact AS (
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
         ARRAY[-249,-232,-216,-19,232,249]::numeric[] AS exp_adj
  -- ▲▲▲ 事實段結束 ▲▲▲
),
tchk AS (   -- 只認「包子媽生鮮小舖」一家（名稱去掉空白後完全相同；0 家或 2 家以上 → 第一列 ❌）
  SELECT COUNT(*) AS n FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖'
),
tn AS (
  SELECT t.id AS tenant_id FROM public.tenants t CROSS JOIN tchk
   WHERE tchk.n = 1 AND regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖'
),
skchk AS (   -- 品號 ↔ 規格編號 ↔ 商品編號 三者要對得上（11/2 盤點：G02907-01＝8442、商品 4213）
  SELECT (SELECT COUNT(*) FROM public.skus s, tn, fact WHERE s.tenant_id = tn.tenant_id AND s.sku_code = fact.sku_code) AS n_code,
         EXISTS (SELECT 1 FROM public.skus s, tn, fact WHERE s.tenant_id = tn.tenant_id AND s.id = fact.sku_id
                    AND s.sku_code = fact.sku_code AND s.product_id = fact.product_id) AS ok
),
checks(序, 項目, 簽名, 關鍵句, 必要) AS (
  VALUES
  (1, '月結產生器：用 stores 第一筆認公司（所以店家資料只能有一家公司）', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'SELECT tenant_id IN' || 'TO v_tenant FROM stores LIMIT 1;', TRUE),
  (2, '月結產生器：已確認／已結／已匯款／作廢的店整店跳過', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'AND status IN (''confirmed'',''settled'',''remitted'',''cancelled'') ) THEN CONTINUE;', TRUE),
  (3, '月結產生器：草稿／已寄出／爭議中的會被重算蓋掉（upsert）', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'ON CONFLICT (tenant_id, settlement_month, store_id) DO UP' || 'DATE SET payable_amount = EXCLUDED.payable_amount', TRUE),
  (4, '月結產生器：重算前先刪掉舊明細', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'DE' || 'LETE FROM store_monthly_settlement_items WHERE settlement_id = v_settlement_id;', TRUE),
  (5, '月結產生器：人工調整只算「有效」的', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'FROM store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = v_month_start AND a.store_id = v_store.id AND a.status = ''active'';', TRUE),
  (6, '月結產生器：應收＝分店價合計＋人工調整', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'v_payable := v_branch_total + v_adjust;', TRUE),
  (7, '（只供參考）月結產生器有沒有 9/07 版的防撞鎖', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'PERFORM pg_advisory_xact_lock( hashtext(''settlement:'' || v_tenant::TEXT || '':'' || v_month_start::TEXT) );', FALSE),
  (8, '【第三批新增】月結產生器：一次跑該公司「每一家」有倉別的店（沒有只跑某幾家的參數）', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'FOR v_store IN SELECT s.id, s.code, s.name, s.location_id FROM stores s WHERE s.tenant_id = v_tenant AND s.location_id IS NOT NULL LOOP', TRUE),
  (9, '【第三批新增】月結產生器：某店整月沒帳也沒調整 → 草稿直接刪掉', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'DE' || 'LETE FROM store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = v_month_start AND store_id = v_store.id AND status = ''draft''; CONTINUE;', TRUE),
  (10, '【第三批新增】月結產生器：2026-09 以前的月份凍結、不能重產（十月可以）', 'public.rpc_generate_hq_to_store_settlement(date,uuid)', 'IF v_month_start < DATE ''2026-09-01'' THEN', TRUE),
  (15, '改價函式：把「還在用、且結束日晚於新生效日」的舊版本截到新生效日', 'public.rpc_upsert_price(uuid,bigint,text,bigint,numeric,timestamptz,text,uuid)', 'UP' || 'DATE prices SET effective_to = p_effective_from WHERE tenant_id = p_tenant_id AND sku_id = p_sku_id AND scope = p_scope AND (scope_id IS NOT DISTINCT FROM p_scope_id) AND (effective_to IS NULL OR effective_to > p_effective_from);', TRUE),
  (16, '改價函式：新開一個版本，操作人寫進 created_by', 'public.rpc_upsert_price(uuid,bigint,text,bigint,numeric,timestamptz,text,uuid)', 'IN' || 'SERT IN' || 'TO prices (tenant_id, sku_id, scope, scope_id, price, effective_from, reason, created_by) VALUES (p_tenant_id, p_sku_id, p_scope, p_scope_id, p_price, p_effective_from, p_reason, p_operator)', TRUE),
  (17, '「最後異動時間」自動蓋章可以在交易內暫停（方案甲蓋回、還原要用）', 'public.touch_updated_at()', 'IF current_setting(''app.skip_updated_at'', true) = ''1'' THEN RETURN NEW;', TRUE),
  (18, '月結明細保護：只有已確認／已結清的明細不能改（草稿可以）', 'public.forbid_smsi_mutation_when_locked()', 'IF v_status IN (''confirmed'', ''settled'') THEN', TRUE),
  (19, '【第三批新增】查價工具：取「全店共用、價格>0、那一刻生效」的分店價', 'public._branch_price_at(uuid,bigint,timestamptz)', 'AND pr.scope = ''branch'' AND pr.scope_id IS NULL AND pr.price > 0 AND pr.effective_from <= p_at AND (pr.effective_to IS NULL OR pr.effective_to > p_at)', TRUE),
  (20, '【第三批新增】店家每日對帳：總倉派車用「派車當下」計價（驗算用它對帳）', 'public._store_inbound_lines(bigint,timestamptz,timestamptz)', 'AND t.shipped_at >= p_from AND t.shipped_at < p_to', TRUE)
),
f AS (
  SELECT c.序, c.簽名, p.oid,
         regexp_replace(regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', ' ', 'g'), '\s+', ' ', 'g') AS src
    FROM checks c JOIN pg_proc p ON p.oid = to_regprocedure(c.簽名)
),
exp_trg(tbl, tgname, note) AS (
  VALUES
    ('prices', 'trg_prices_sync_campaigns', '只同步「零售價」到草稿團，分店價不影響（20260819000000:1107-1136）'),
    ('store_monthly_settlements', 'trg_touch_sms', '改表頭時自動蓋「最後異動時間」（20260512000009:84）'),
    ('store_monthly_settlement_items', 'trg_smsi_immutable_when_locked', '已確認的明細不准改（20260512000013:46）')
),
trg AS (
  SELECT c.relname AS tbl, t.tgname, pg_get_triggerdef(t.oid) AS def, t.tgenabled
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND NOT t.tgisinternal
     AND c.relname IN ('prices','store_monthly_settlements','store_monthly_settlement_items','store_settlement_adjustments','store_settlement_disputes')
),
pgrst AS (   -- PostgREST 開放哪些 schema：角色／資料庫層設定（authenticator 等）＋本連線的 current_setting
  SELECT '角色或資料庫設定' AS src, cfg FROM pg_db_role_setting d, unnest(d.setconfig) cfg WHERE cfg LIKE 'pgrst.db_schemas=%'
  UNION ALL
  SELECT '本連線設定', current_setting('pgrst.db_schemas', true)
   WHERE COALESCE(current_setting('pgrst.db_schemas', true), '') <> ''
),
exposed AS (SELECT EXISTS (SELECT 1 FROM pgrst WHERE cfg LIKE '%ops_price_fix_b3%') AS yes),
users AS (
  SELECT u.id, u.email, u.last_sign_in_at, u.raw_app_meta_data ->> 'role' AS role,
         (SELECT COUNT(*) FROM public.prices p WHERE p.created_by = u.id) AS n_price,
         (SELECT COUNT(*) FROM public.prices p WHERE p.created_by = u.id
             AND (p.reason LIKE '2026-09-29 九月分店價錯價修正%' OR p.reason LIKE '2026-10-07 第二批分店價錯價修正%')) AS n_b12,
         (SELECT COUNT(*) FROM public.store_settlement_adjustments a WHERE a.created_by = u.id) AS n_adj,
         (SELECT COUNT(*) FROM public.store_monthly_settlements m WHERE m.created_by = u.id OR m.updated_by = u.id) AS n_sms
    FROM auth.users u
   WHERE (u.raw_app_meta_data ->> 'tenant_id') = (SELECT tenant_id::text FROM tn)
     AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')
),
-- ③ 這個規格的分店價版本（全部 scope=branch；全店共用＝scope_id 空白，跟查價工具同條件，20260715000000:83-114）
pv AS (
  SELECT p.* FROM public.prices p, tn, fact
   WHERE p.tenant_id = tn.tenant_id AND p.sku_id = fact.sku_id AND p.scope = 'branch'
),
pa AS (SELECT pv.* FROM pv, fact WHERE pv.id = fact.id_a),
pb AS (SELECT pv.* FROM pv, fact WHERE pv.id = fact.id_b),
pc AS (SELECT pv.* FROM pv, fact WHERE pv.id = fact.id_c),
pchk AS (
  SELECT
    (SELECT COUNT(*) FROM pv WHERE pv.scope_id IS NULL) AS n_shared,
    (SELECT COUNT(*) FROM pv WHERE pv.scope_id IS NOT NULL) AS n_scoped,
    EXISTS (SELECT 1 FROM pa, fact WHERE pa.scope_id IS NULL AND pa.price = fact.price_a
               AND pa.effective_from >= fact.a_from_sec AND pa.effective_from < fact.a_from_sec + interval '1 second') AS a_ok,
    EXISTS (SELECT 1 FROM pb, fact WHERE pb.scope_id IS NULL AND pb.price = fact.price_b
               AND pb.effective_from >= fact.b_from_sec AND pb.effective_from < fact.b_from_sec + interval '1 second') AS b_ok,
    EXISTS (SELECT 1 FROM pc, fact WHERE pc.scope_id IS NULL AND pc.price = fact.price_new AND pc.effective_to IS NULL AND pc.created_by = fact.c_by
               AND pc.effective_from >= fact.c_from_sec AND pc.effective_from < fact.c_from_sec + interval '1 second') AS c_ok,
    EXISTS (SELECT 1 FROM pa, pb WHERE pa.effective_to = pb.effective_from) AS ab_link,
    EXISTS (SELECT 1 FROM pb, pc WHERE pb.effective_to = pc.effective_from) AS bc_link
),
pres AS (
  SELECT CASE
           WHEN (SELECT NOT ok FROM skchk) THEN '❌ 品號 G02907-01 對不到規格 8442／商品 4213（或公司不對），修正檔會停'
           WHEN (SELECT n_shared FROM pchk) <> 3 THEN '❌ 全店共用的分店價版本有 ' || (SELECT n_shared FROM pchk) || ' 個（11/2 盤點是 3 個），修正檔會停'
           WHEN NOT (SELECT a_ok FROM pchk) THEN '❌ 版本 24666（62 元、2026-09-28 18:51:00 起）不一樣了，修正檔會停'
           WHEN NOT (SELECT b_ok FROM pchk) THEN '❌ 版本 26805（64 元、2026-10-05 16:38:51 起）不一樣了，修正檔會停'
           WHEN NOT (SELECT c_ok FROM pchk) THEN '❌ 版本 33876（42 元、2026-11-02 11:21:03 起、現在有效、老闆帳號建的）不一樣了，修正檔會停'
           WHEN NOT (SELECT ab_link FROM pchk) THEN '❌ 62 那段的結束時間沒有剛好接上 64 那段的開始時間，修正檔會停'
           WHEN NOT (SELECT bc_link FROM pchk) THEN '❌ 64 那段的結束時間沒有剛好接上 42 那段的開始時間，修正檔會停'
         END AS err
),
st AS (SELECT s.id, s.code, s.name, s.location_id FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id WHERE s.location_id IS NOT NULL),
-- ⑥ 蛋小白十月每一筆帳（店家每日對帳 _store_inbound_lines，20260901000000:597-742；口徑＝月結明細，正負號一致）
egg AS (
  SELECT st.id AS store_id, l.entry_type, l.transfer_item_id, l.qty, l.unit_branch_price, l.amount, l.received_at AS booked_at,
         CASE WHEN l.entry_type IN ('air_out','return_out') THEN -1 ELSE 1 END * l.qty AS sqty
    FROM st CROSS JOIN fact
    CROSS JOIN LATERAL public._store_inbound_lines(st.id, fact.oct_from, fact.nov_from) l
   WHERE l.sku_id = fact.sku_id AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out')
),
egg_win AS (   -- 落在「64 那段」（10/5 16:38:51 ～ 11/2 11:21:03）裡的：改價後單價會變成 42
  SELECT egg.*, egg.sqty * (fact.price_new - egg.unit_branch_price) AS delta
    FROM egg, pb, fact
   WHERE egg.booked_at >= pb.effective_from AND egg.booked_at < pb.effective_to
),
egg_store AS (
  SELECT e.store_id, COUNT(*) AS n_all,
         COUNT(*) FILTER (WHERE w.transfer_item_id IS NOT NULL) AS n_win,
         COALESCE(SUM(w.sqty), 0) AS net_qty, COALESCE(SUM(w.delta), 0) AS delta,
         string_agg(DISTINCT trim_scale(e.unit_branch_price)::text, '、') AS prices_now
    FROM egg e
    LEFT JOIN egg_win w ON w.store_id = e.store_id AND w.transfer_item_id = e.transfer_item_id AND w.entry_type = e.entry_type
   GROUP BY e.store_id
),
egg_sum AS (
  SELECT COUNT(*) AS n_store, COALESCE(SUM(n_win), 0) AS n_lines, COALESCE(SUM(net_qty), 0) AS net_qty, COALESCE(SUM(delta), 0) AS delta,
         COALESCE((SELECT array_agg(delta ORDER BY delta) FROM egg_store), ARRAY[]::numeric[]) AS deltas
    FROM egg_store
),
nov_win AS (   -- 十一月（11/1 00:00 ～ 11/2 11:21:03）如果有蛋小白的帳，也會被改價影響，但十一月不在修正範圍 → 修正檔會停
  SELECT COUNT(*) AS n
    FROM st CROSS JOIN fact CROSS JOIN pc
    CROSS JOIN LATERAL public._store_inbound_lines(st.id, fact.nov_from, GREATEST(pc.effective_from, fact.nov_from)) l
   WHERE l.sku_id = fact.sku_id
),
eres AS (
  SELECT CASE
           WHEN (SELECT err FROM pres) IS NOT NULL THEN '（價格版本不對，這項不算）'
           WHEN (SELECT n_store FROM egg_sum) <> (SELECT exp_n_store FROM fact)
             OR (SELECT n_lines FROM egg_sum) <> (SELECT exp_n_lines FROM fact)
             OR (SELECT net_qty FROM egg_sum) <> (SELECT exp_net_qty FROM fact)
             OR (SELECT delta FROM egg_sum) <> (SELECT exp_delta FROM fact)
             OR (SELECT deltas FROM egg_sum) <> (SELECT exp_deltas FROM fact)
             THEN '❌ 跟 11/2 盤點不一樣：現在 ' || (SELECT n_store FROM egg_sum) || ' 家店、' || (SELECT n_lines FROM egg_sum) || ' 筆、計價數量 '
                  || trim_scale((SELECT net_qty FROM egg_sum)) || '、差額 ' || trim_scale((SELECT delta FROM egg_sum))
                  || '（盤點：11 家、12 筆、38、−836）。修正檔會停'
           WHEN (SELECT n FROM nov_win) > 0 THEN '❌ 十一月 1～2 日有 ' || (SELECT n FROM nov_win) || ' 筆蛋小白的帳（盤點時 0 筆），修正檔會停'
         END AS err
),
-- ④ 十月月結
sm10 AS (SELECT m.* FROM public.store_monthly_settlements m, tn, fact WHERE m.tenant_id = tn.tenant_id AND m.settlement_month = fact.oct),
-- ⑤ 十月人工調整
adj10 AS (SELECT a.* FROM public.store_settlement_adjustments a, tn, fact WHERE a.tenant_id = tn.tenant_id AND a.settlement_month = fact.oct),
ares AS (
  SELECT CASE
           WHEN (SELECT COALESCE(array_agg(amount ORDER BY amount), ARRAY[]::numeric[]) FROM adj10 WHERE status = 'active') <> (SELECT exp_adj FROM fact)
             THEN '❌ 十月有效人工調整跟 11/2 盤點不一樣（盤點：6 筆（#56 −232、#57 +232、#58 −19、#59 −249、#60 +249、#62 −216，合計 −235）），修正檔會停'
         END AS err
),
-- ⑦ 現在「整月重產」會不會連帶改到東西：每家店，月結明細 vs. 現在照價目表即時算的每日對帳（蛋小白還沒改價，所以這裡算的是「蛋小白以外」的變動）
live AS (
  SELECT st.id AS store_id, l.transfer_item_id, l.entry_type, l.sku_id, l.qty, l.unit_branch_price, l.amount, l.received_at
    FROM st CROSS JOIN fact CROSS JOIN LATERAL public._store_inbound_lines(st.id, fact.oct_from, fact.nov_from) l
),
cur AS (
  SELECT m.store_id, i.transfer_item_id, i.entry_type, i.sku_id, i.qty_received AS qty, i.unit_branch_price, i.branch_amount AS amount, i.received_at
    FROM public.store_monthly_settlement_items i JOIN sm10 m ON m.id = i.settlement_id
),
ldiff AS (
  SELECT store_id, COUNT(*) AS n FROM ((SELECT * FROM live EXCEPT ALL SELECT * FROM cur) UNION ALL (SELECT * FROM cur EXCEPT ALL SELECT * FROM live)) d GROUP BY store_id
),
cdiff AS (   -- 成本那一欄：總倉派車／退貨看出庫異動，店轉店看轉出店的出庫異動（產生器 20260907030000:786-791、:1005-1016、view 20260825030000:61-87）
  SELECT m.store_id, COUNT(*) AS n
    FROM public.store_monthly_settlement_items i JOIN sm10 m ON m.id = i.settlement_id
    JOIN public.transfer_items ti ON ti.id = i.transfer_item_id
    LEFT JOIN public.stock_movements sm ON sm.id = ti.out_movement_id
   WHERE i.entry_type IN ('hq_inbound','return_out','air_in','air_out')
     AND i.unit_cost IS DISTINCT FROM CASE WHEN i.entry_type IN ('air_in','air_out') THEN COALESCE(sm.unit_cost, 0) ELSE sm.unit_cost END
   GROUP BY m.store_id
),
adjsum AS (SELECT store_id, SUM(amount) AS amt FROM adj10 WHERE status = 'active' GROUP BY store_id),
drift AS (
  SELECT st.id AS store_id, st.code, st.name, m.id AS sm_id, m.status,
         (es.store_id IS NOT NULL) AS is_target,
         COALESCE(ld.n, 0) AS n_line, COALESCE(cd.n, 0) AS n_cost,
         (m.id IS NOT NULL AND m.adjustment_amount <> COALESCE(aj.amt, 0)) AS adj_bad,
         (m.id IS NOT NULL AND m.payable_amount <> m.branch_amount + m.adjustment_amount) AS pay_bad,
         EXISTS (SELECT 1 FROM live l WHERE l.store_id = st.id) AS has_live,
         (aj.amt IS NOT NULL) AS has_adj
    FROM st
    LEFT JOIN sm10 m ON m.store_id = st.id
    LEFT JOIN egg_store es ON es.store_id = st.id
    LEFT JOIN ldiff ld ON ld.store_id = st.id
    LEFT JOIN cdiff cd ON cd.store_id = st.id
    LEFT JOIN adjsum aj ON aj.store_id = st.id
),
dres AS (
  SELECT d.*,
         CASE WHEN d.sm_id IS NULL AND (d.has_live OR d.has_adj) THEN 'new'          -- 重產會新建一張
              WHEN d.sm_id IS NOT NULL AND NOT d.has_live AND NOT d.has_adj THEN 'gone'  -- 重產會把草稿刪掉
              WHEN d.n_line > 0 OR d.n_cost > 0 OR d.adj_bad OR d.pay_bad THEN 'drift'
              WHEN d.sm_id IS NULL THEN 'none'
              ELSE 'same' END AS k
    FROM drift d
),
sep AS (
  SELECT m.settlement_month, COUNT(*) AS n, COUNT(*) FILTER (WHERE status = 'draft') AS n_draft, COALESCE(SUM(payable_amount), 0) AS pay
    FROM public.store_monthly_settlements m JOIN tn ON tn.tenant_id = m.tenant_id
   WHERE m.settlement_month IN (DATE '2026-08-01', DATE '2026-09-01', DATE '2026-11-01')
   GROUP BY m.settlement_month
)
SELECT "序", "區塊", "項目", "結果", "說明"
FROM (
  SELECT 0 AS 序, '總計' AS "區塊",
         (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
               WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
               ELSE '★ 總計（這一行就是結論）' END) AS "項目",
         CASE WHEN (SELECT n FROM tchk) <> 1 THEN '❌ 公司不對，⛔ 不要做修正'
              WHEN EXISTS (SELECT 1 FROM checks c WHERE c.必要 AND NOT EXISTS (
                             SELECT 1 FROM f WHERE f.序 = c.序 AND position(c.關鍵句 IN f.src) > 0))
              THEN '❌ 有必要的程式跟工程紀錄本不一樣（第 100 項起），⛔ 不要做修正'
              WHEN (SELECT yes FROM exposed) THEN '❌ 備份位置被開放給網站讀（第 303 項），⛔ 不要做備份／修正'
              WHEN (SELECT COUNT(DISTINCT tenant_id) FROM public.stores) <> 1 THEN '❌ 店家資料不只一家公司（第 300 項），⛔ 不要做修正'
              WHEN (SELECT err FROM pres) IS NOT NULL THEN (SELECT err FROM pres) || '（第 5000 項起），⛔ 不要做修正'
              WHEN EXISTS (SELECT 1 FROM sm10 WHERE status <> 'draft') THEN '❌ 十月月結有 ' || (SELECT COUNT(*) FROM sm10 WHERE status <> 'draft') || ' 張不是草稿（第 6000 項起），⛔ 不要做修正'
              WHEN (SELECT err FROM ares) IS NOT NULL THEN (SELECT err FROM ares) || '（第 6500 項起），⛔ 不要做修正'
              WHEN (SELECT err FROM eres) IS NOT NULL THEN (SELECT err FROM eres) || '（第 7000 項起），⛔ 不要做修正'
              WHEN EXISTS (SELECT 1 FROM dres WHERE is_target AND k <> 'same')
              THEN '❌ 有蛋小白帳的店，現在重產「蛋小白以外」也會變（第 7500 項起），兩個方案都會停；⛔ 先給 CEO 看'
              WHEN EXISTS (SELECT 1 FROM dres WHERE NOT is_target AND k IN ('new','gone','drift'))
              THEN '⚠ 可以做，但只能走「方案甲」：其他店現在重產會變（第 7500 項起），方案乙會停'
                   || CASE WHEN NOT EXISTS (SELECT 1 FROM pgrst) THEN '；另外「備份位置有沒有開放給網站讀」查不到，需人工確認（第 303 項）' ELSE '' END
              WHEN NOT EXISTS (SELECT 1 FROM pgrst)
              THEN '⚠ 需人工確認：其餘檢查都過，但「備份位置有沒有開放給網站讀」查不到設定（第 303 項），請到 Settings → API 確認 Exposed schemas 沒有 ops_price_fix_b3 再往下'
              ELSE '✅ 程式關鍵句都一樣、備份位置沒開放、只有一家公司、三個價格版本跟盤點一樣、十月月結全是草稿、人工調整 6 筆一樣、蛋小白 11 家 −836 一樣；現在重產除了蛋小白不會改到別的 → 方案甲、乙都可以走' END AS "結果",
         '往下看每一項；❌ 一律先停' AS "說明"
  UNION ALL
  SELECT 100 + c.序, '②程式核對', c.項目,
         CASE WHEN NOT EXISTS (SELECT 1 FROM f WHERE f.序 = c.序) THEN
                CASE WHEN c.必要 THEN '❌ 照名稱＋參數找不到這支' ELSE '⚠ 找不到這支' END
              WHEN EXISTS (SELECT 1 FROM f WHERE f.序 = c.序 AND position(c.關鍵句 IN f.src) > 0) THEN '✅ 一樣'
              WHEN c.必要 THEN '❌ 找不到這段，跟工程紀錄本不一樣'
              ELSE '⚠ 沒有（正式系統是 9/01 版，9/26 已知；修正檔自己會上鎖，不影響）' END,
         c.簽名 || '　同名函式 ' || (SELECT COUNT(*) FROM pg_proc p WHERE p.proname = split_part(split_part(c.簽名, '.', 2), '(', 1)) || ' 支'
    FROM checks c
  UNION ALL
  SELECT 200 + ROW_NUMBER() OVER (ORDER BY tbl, tgname), '②自動動作（觸發器）', trg.tbl || '：' || trg.tgname,
         CASE WHEN trg.tgenabled = 'D' THEN '⚠ 已停用'
              WHEN EXISTS (SELECT 1 FROM exp_trg e WHERE e.tbl = trg.tbl AND e.tgname = trg.tgname) THEN '✅ 預期中'
              ELSE '❌ 工程紀錄本沒有這個，修正前要先搞清楚它會做什麼' END,
         COALESCE((SELECT e.note FROM exp_trg e WHERE e.tbl = trg.tbl AND e.tgname = trg.tgname), trg.def)
    FROM trg
  UNION ALL
  SELECT 250 + ROW_NUMBER() OVER (ORDER BY e.tbl), '②自動動作（觸發器）', e.tbl || '：' || e.tgname,
         '⚠ 系統裡沒有這個（工程紀錄本有）', e.note
    FROM exp_trg e WHERE NOT EXISTS (SELECT 1 FROM trg WHERE trg.tbl = e.tbl AND trg.tgname = e.tgname)
  UNION ALL
  SELECT 300, '②其他', '店家資料裡有幾家公司（月結產生器只能有一家）',
         CASE WHEN (SELECT COUNT(DISTINCT tenant_id) FROM public.stores) = 1 THEN '✅ 1 家'
              ELSE '❌ ' || (SELECT COUNT(DISTINCT tenant_id) FROM public.stores) || ' 家，修正檔會停下來' END,
         '產生器用 stores 第一筆認公司（20260907030000:750）'
  UNION ALL
  SELECT 302, '②其他', '這一批的備份位置（ops_price_fix_b3）現在有沒有',
         CASE WHEN to_regnamespace('ops_price_fix_b3') IS NULL THEN '還沒有（正常，第 1 份備份才會建）' ELSE '已經有了（跑過第 1 份）' END,
         '這個位置不在網站程式讀得到的範圍（下一列）'
  UNION ALL
  SELECT 303, '②其他', '網站程式（API）讀得到哪些位置：有沒有包含備份位置 ops_price_fix_b3',
         CASE WHEN (SELECT yes FROM exposed) THEN '❌ 備份位置被開放給網站讀，⛔ 不要做備份／修正'
              WHEN NOT EXISTS (SELECT 1 FROM pgrst) THEN '⚠ 查不到設定（Supabase 預設只開 public、graphql_public）；請到 Settings → API 看 Exposed schemas 沒有 ops_price_fix_b3'
              ELSE '✅ 不包含備份位置' END,
         COALESCE((SELECT string_agg(src || '：' || cfg, '；') FROM pgrst), '（沒有任何 pgrst.db_schemas 設定）')
  UNION ALL
  SELECT 304, '②其他', '（只供參考）第一批、第二批的備份位置',
         'ℹ ops_sep_price_fix ' || CASE WHEN to_regnamespace('ops_sep_price_fix') IS NULL THEN '沒有' ELSE '有' END
           || '、ops_price_fix_b2 ' || CASE WHEN to_regnamespace('ops_price_fix_b2') IS NULL THEN '沒有' ELSE '有' END,
         '這一批用自己的位置 ops_price_fix_b3，不讀、不改、不刪前兩批的備份與修正紀錄'
  UNION ALL
  SELECT 400 + ROW_NUMBER() OVER (ORDER BY users.n_b12 DESC, users.last_sign_in_at DESC NULLS LAST), '①你的使用者UUID',
         COALESCE(users.email, '（沒有 email）') || CASE WHEN (SELECT p_my_email FROM param) <> '' AND lower(users.email) = lower(trim((SELECT p_my_email FROM param)))
                                                    THEN '　👉 就是你填的信箱' ELSE '' END
           || CASE WHEN users.n_b12 > 0 THEN '　👉 第一批／第二批修正用的就是這個帳號' ELSE '' END
           || CASE WHEN users.id = (SELECT c_by FROM fact) THEN '　👉 11/2 在商品頁把分店價改成 42 的就是這個帳號' ELSE '' END,
         users.id::text,
         '角色 ' || COALESCE(NULLIF(users.role, ''), '（空白＝總部）') || '　最後登入 '
           || COALESCE(to_char(users.last_sign_in_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '—')
           || '　建過價格 ' || users.n_price || ' 筆（其中前兩批修正寫的 ' || users.n_b12 || ' 筆）、人工調整 ' || users.n_adj || ' 筆、月結 ' || users.n_sms || ' 張'
    FROM users
   WHERE (SELECT p_my_email FROM param) = '' OR lower(users.email) = lower(trim((SELECT p_my_email FROM param)))
  UNION ALL
  SELECT 5000, '③分店價版本', 'G02907-01（規格 8442、商品 4213）三個版本跟 11/2 盤點比',
         COALESCE((SELECT err FROM pres), '✅ 3 個版本都一樣、前後剛好接上'),
         '全店共用 ' || (SELECT n_shared FROM pchk) || ' 個、指定門市的 ' || (SELECT n_scoped FROM pchk) || ' 個（指定門市的查價工具不看，修正不動）。'
           || '修正做法：刪掉 64 和 42 兩個版本（原樣在備份），從 64 那段原本的開始時間重開「42、沒有結束日」；62 那段一個字不動'
  UNION ALL
  SELECT 5000 + ROW_NUMBER() OVER (ORDER BY pv.effective_from, pv.id), '③分店價版本',
         'price_id ' || pv.id || CASE WHEN pv.scope_id IS NOT NULL THEN '（指定門市 ' || pv.scope_id || '）' ELSE '' END,
         'ℹ ' || trim_scale(pv.price) || ' 元，' || to_char(pv.effective_from AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS.US') || ' 起、'
           || CASE WHEN pv.effective_to IS NULL THEN '現在還有效' ELSE '到 ' || to_char(pv.effective_to AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS.US') END,
         '原因：' || COALESCE(pv.reason, '（空白）') || '；建立者 ' || pv.created_by::text
    FROM pv
  UNION ALL
  SELECT 6000, '④十月月結', '十月月結每一張都要是草稿',
         CASE WHEN NOT EXISTS (SELECT 1 FROM sm10 WHERE status <> 'draft') THEN '✅ ' || (SELECT COUNT(*) FROM sm10) || ' 張全是草稿'
              ELSE '❌ 有 ' || (SELECT COUNT(*) FROM sm10 WHERE status <> 'draft') || ' 張不是草稿，⛔ 不要做修正' END,
         '11/2 盤點：20 張全草稿。只要有一張已送店家／有異議／已確認／作廢，修正檔會整筆停（店家可能已經看過舊數字）'
           || CASE WHEN (SELECT COUNT(*) FROM sm10) <> 20 THEN '。⚠ 張數跟盤點不一樣（現在 ' || (SELECT COUNT(*) FROM sm10) || ' 張）' ELSE '' END
  UNION ALL
  SELECT 6000 + ROW_NUMBER() OVER (ORDER BY s.code), '④十月月結', s.code || '　' || s.name,
         '❌ 狀態＝' || m.status, '最後異動 ' || to_char(m.updated_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI')
    FROM sm10 m JOIN public.stores s ON s.id = m.store_id WHERE m.status <> 'draft'
  UNION ALL
  SELECT 6500, '⑤十月人工調整', '有效人工調整（修正⛔不作廢；重產後必須原樣還在）',
         COALESCE((SELECT err FROM ares), '✅ 6 筆，逐筆金額跟盤點一樣'),
         '有效 ' || (SELECT COUNT(*) FROM adj10 WHERE status = 'active') || ' 筆、合計 ' || trim_scale((SELECT COALESCE(SUM(amount), 0) FROM adj10 WHERE status = 'active'))
           || '；已作廢 ' || (SELECT COUNT(*) FROM adj10 WHERE status <> 'active') || ' 筆。月結產生器只把「有效」調整加總進應收、不會刪改調整本身（20260907030000:886-898）'
  UNION ALL
  SELECT 6500 + ROW_NUMBER() OVER (ORDER BY a.id), '⑤十月人工調整', s.code || '　' || s.name || '　#' || a.id,
         'ℹ ' || trim_scale(a.amount) || '（' || a.status || '）', a.reason
    FROM adj10 a JOIN public.stores s ON s.id = a.store_id
  UNION ALL
  SELECT 7000, '⑥蛋小白十月的帳', '改成 42 之後每家店差多少（跟 11/2 盤點比）',
         COALESCE((SELECT err FROM eres), '✅ ' || (SELECT n_store FROM egg_sum) || ' 家店、' || (SELECT n_lines FROM egg_sum) || ' 筆、計價數量 '
                  || trim_scale((SELECT net_qty FROM egg_sum)) || '、合計 ' || trim_scale((SELECT delta FROM egg_sum)) || '（跟盤點一樣）'),
         '只有落在 64 那段（10/5 16:38:51 ～ 11/2 11:21:03）的帳會變；十一月 1～2 日這段的蛋小白帳 ' || (SELECT n FROM nov_win) || ' 筆（要 0）'
  UNION ALL
  SELECT 7000 + ROW_NUMBER() OVER (ORDER BY es.delta, s.code), '⑥蛋小白十月的帳', s.code || '　' || s.name,
         'ℹ 差 ' || trim_scale(es.delta) || '（計價數量 ' || trim_scale(es.net_qty) || '）',
         '這家店十月蛋小白 ' || es.n_all || ' 筆、會變的 ' || es.n_win || ' 筆；現在單價 ' || COALESCE(es.prices_now, '—')
    FROM egg_store es JOIN public.stores s ON s.id = es.store_id
  UNION ALL
  SELECT 7500, '⑦現在重產十月會不會連帶變',
         '有蛋小白帳的店 ' || (SELECT COUNT(*) FROM dres WHERE is_target) || ' 家；其他有倉別的店 ' || (SELECT COUNT(*) FROM dres WHERE NOT is_target) || ' 家',
         CASE WHEN EXISTS (SELECT 1 FROM dres WHERE is_target AND k <> 'same') THEN '❌ 有蛋小白帳的店，蛋小白以外也會變 → 兩個方案都會停'
              WHEN EXISTS (SELECT 1 FROM dres WHERE NOT is_target AND k IN ('new','gone','drift')) THEN '⚠ 其他店有 ' || (SELECT COUNT(*) FROM dres WHERE NOT is_target AND k IN ('new','gone','drift')) || ' 家會變 → 只能走方案甲（方案乙會停）'
              ELSE '✅ 除了蛋小白，現在重產不會改到任何一家店 → 方案甲、乙結果一樣' END,
         '比法：每家店十月月結明細 vs. 現在照價目表即時算的每日對帳（逐行：單號品項、類型、數量、分店單價、金額、時點）＋成本單價＋人工調整合計。'
           || '⚠ 月結明細的「張數／筆數」欄沒在這裡預覽，修正檔做完會再比'
  UNION ALL
  SELECT 7500 + ROW_NUMBER() OVER (ORDER BY d.is_target DESC, d.code), '⑦現在重產十月會不會連帶變',
         d.code || '　' || d.name || CASE WHEN d.is_target THEN '（有蛋小白帳）' ELSE '' END,
         CASE d.k WHEN 'same' THEN '✅ 不會變' WHEN 'none' THEN '—（沒有月結、也沒有帳）'
                  WHEN 'new' THEN CASE WHEN d.is_target THEN '❌' ELSE '⚠' END || ' 重產會新建一張十月草稿'
                  WHEN 'gone' THEN CASE WHEN d.is_target THEN '❌' ELSE '⚠' END || ' 重產會把這張草稿刪掉（整月沒帳也沒調整）'
                  ELSE CASE WHEN d.is_target THEN '❌' ELSE '⚠' END || ' 重產會變' END,
         CASE WHEN d.k = 'drift' THEN '明細不同 ' || d.n_line || ' 行（兩邊合計）、成本單價不同 ' || d.n_cost || ' 行'
                || CASE WHEN d.adj_bad THEN '、人工調整合計跟有效調整不一樣' ELSE '' END
                || CASE WHEN d.pay_bad THEN '、應收≠分店價合計＋調整' ELSE '' END
                || CASE WHEN d.is_target THEN '。兩個方案都會停' ELSE '。方案甲：做完會蓋回原樣（這次不變，下次正常重產才會出現）；方案乙：會停' END
              WHEN d.k IN ('new','gone') THEN CASE WHEN d.is_target THEN '兩個方案都會停' ELSE '方案甲：做完會恢復原樣；方案乙：會停' END
              ELSE '' END
    FROM dres d WHERE d.k <> 'none'
  UNION ALL
  SELECT 7900, '⑧其他月份（修正不會碰；只供對照）', '八月／九月／十一月月結',
         'ℹ ' || COALESCE((SELECT string_agg(to_char(settlement_month, 'YYYY-MM') || '：' || n || ' 張（草稿 ' || n_draft || '）應收 ' || trim_scale(pay), '；' ORDER BY settlement_month) FROM sep), '（都沒有）'),
         '修正檔與驗算檔會逐列比對「十月以外每一個月份」的月結表頭／明細／調整／爭議，一個字都不能變'
) z
ORDER BY "序";

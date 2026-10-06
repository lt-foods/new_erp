-- ============================================================================
--  第二批分店價錯價修正 0-D　執行前核對（只查不改）
--  日期：2026-10-07　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-第二批分店價錯價修正_九月十月_2026-10-07.md、派工單-第二批分店價錯價修正指令_2026-10-07.md
--  範本：第一批 NEW-ERP九月錯價修正_2026-09-29_0-D（9/30 已在正式系統跑過）；程式核對 18 項、觸發器照舊，
--        加上這一批要老闆確認的規格（G01846、G01626、B 類）與 A 類的版本檢查
--  程式出處：唯讀鏡像 origin/main 500ecc32 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    ①找出「你本人」在 NEW-ERP 的使用者 UUID（一長串英數字）。修正檔要用它當「操作人」：
--      價格表每一筆都要記是誰改的（prices.created_by 不可空白，20260422120001:174），月結重產也要記。
--      ⬇ 下面 p_my_email 那一行可以填你登入 NEW-ERP 用的信箱（可以不填，不填就全部列出來讓你認）。
--      9/30 第一批修正用過的帳號會標出來（看價格表裡第一批修正寫的版本記在誰名下），方便你對照。
--      確認是你之後，把那串 UUID 交給 CEO，⛔ 不要用別人的。修正檔交件時操作人是空的，CEO 會在你確認後才填。
--    ②確認「真正的系統」裡，修正會用到的幾支程式跟工程紀錄本（origin/main）一樣：
--      月結產生器、確認月結、作廢調整、改價函式、自動蓋章、明細保護；
--      還有這幾張表上掛了哪些自動動作（觸發器）、店家資料是不是只有一家公司、這一批的備份位置外面讀不讀得到。
--    ③清單核對：清單裡還有沒有佔位、有沒有重複、每個規格在系統找不找得到。
--    ④這一批要你先確認的規格：
--      ・列 12 商品 G01846：列出底下「所有」規格（編號、品名、規格名、現在的分店價、九月十月帳的筆數），
--        你確認要改的是哪一個（或哪幾個），CEO 再把清單裡的佔位 G01846-?? 換成真正的編號
--      ・列 59 商品 G01626：列出底下「所有」規格，-02～-05 在不在、現在幾元；清單外如果還有別的規格也會標出來
--      ・B 類（10/05 才建的那個規格）：還是只有一個版本、九月十月還是沒有任何帳；
--        那個版本還是 10/7 盤點時的 109 元、2026-10-05 21:47（台北）那一分鐘開始（不一樣＝盤點後有人動過價 → ❌）
--      ・A 類：9/1 當天或之後有沒有別的價格版本（有就改不了）、9/1 當下是不是剛好一個版本、是不是本來就已經是正確價
--    ⑤十月月結有沒有人先產生了（只要有任何一張 → ❌，修正檔會停）；九月月結跟 10/7 盤點時一不一樣
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：（選擇性）填信箱 → 整份貼上 → Run → 下載 CSV 給 CEO。
--  ★ 看到什麼要停：「結果」欄有任何 ❌ → 不要做修正，截圖給 CEO。
--    ・佔位還沒換掉的時候，第一列一定是 ❌（正常）：先把第 5000 項起列出的 G01846 規格給老闆認，CEO 換掉佔位後再跑一次。
--    ⚠ 的是提醒，照說明欄判斷；第 107 項「沒有防撞鎖」是 9/26 就知道的事（9/30 第一批時也是這樣），修正檔自己會上鎖，不影響。
--  ★ ✅ 的意思是「關鍵句還在」，不是整支程式逐字一樣。
-- ============================================================================

WITH
param AS (
  SELECT ''::text AS p_my_email   -- ⬅ 選填：你登入 NEW-ERP 用的信箱（填在兩個單引號中間）；不填就維持兩個單引號
),
tchk AS (   -- 只認「包子媽生鮮小舖」一家（名稱去掉空白後完全相同；0 家或 2 家以上 → 第一列 ❌）
  SELECT COUNT(*) AS n FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖'
),
tn AS (
  SELECT t.id AS tenant_id FROM public.tenants t CROSS JOIN tchk
   WHERE tchk.n = 1 AND regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖'
),
vlist(sku_code, correct_price, cls) AS (   -- 第二批清單（寫死）
  VALUES
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
),
sk AS (
  SELECT s.id AS sku_id, v.sku_code, v.correct_price, v.cls,
         COALESCE(NULLIF(s.product_name, ''), '') AS pname, s.variant_name
    FROM vlist v
    JOIN public.skus s ON s.sku_code = v.sku_code
    JOIN tn ON tn.tenant_id = s.tenant_id
),
lchk AS (   -- 清單本身：佔位（品號裡有 ?）、重複、系統查不到
  SELECT (SELECT COUNT(*) FROM vlist) AS n_list,
         (SELECT COUNT(*) FROM vlist WHERE sku_code LIKE '%?%') AS n_ph,
         (SELECT string_agg(sku_code, '、') FROM vlist WHERE sku_code LIKE '%?%') AS ph,
         (SELECT COUNT(*) - COUNT(DISTINCT sku_code) FROM vlist) AS n_dup,
         (SELECT COUNT(*) FROM vlist v WHERE v.sku_code NOT LIKE '%?%' AND NOT EXISTS (SELECT 1 FROM sk WHERE sk.sku_code = v.sku_code)) AS n_miss,
         (SELECT string_agg(v.sku_code, '、') FROM vlist v WHERE v.sku_code NOT LIKE '%?%' AND NOT EXISTS (SELECT 1 FROM sk WHERE sk.sku_code = v.sku_code)) AS miss
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
  (8, '確認月結：先鎖住那一張再改狀態', 'public.rpc_confirm_store_monthly_settlement(bigint,uuid)', 'SELECT * IN' || 'TO v_s FROM store_monthly_settlements WHERE id = p_settlement_id FOR UP' || 'DATE;', TRUE),
  (9, '確認月結：只有草稿／已寄出可以確認', 'public.rpc_confirm_store_monthly_settlement(bigint,uuid)', 'IF v_s.status NOT IN (''draft'', ''sent'') THEN', TRUE),
  (10, '作廢調整：限總部（SQL 視窗沒有登入者＝視為總部）', 'public.rpc_void_settlement_adjustment(bigint,uuid,text)', 'IF NOT public._settlement_caller_is_hq() THEN', TRUE),
  (11, '作廢調整：先鎖住那一筆', 'public.rpc_void_settlement_adjustment(bigint,uuid,text)', 'SELECT * IN' || 'TO v_a FROM store_settlement_adjustments WHERE id = p_adjustment_id FOR UP' || 'DATE;', TRUE),
  (12, '作廢調整：月結已鎖就不准作廢', 'public.rpc_void_settlement_adjustment(bigint,uuid,text)', 'IF FOUND AND v_s.status NOT IN (''draft'', ''sent'', ''disputed'') THEN', TRUE),
  (13, '作廢調整：只改狀態／作廢人／時間／原因', 'public.rpc_void_settlement_adjustment(bigint,uuid,text)', 'UP' || 'DATE store_settlement_adjustments SET status = ''voided'', voided_by = p_operator, voided_at = NOW(), void_reason = NULLIF(TRIM(p_reason), ''''), updated_at = NOW() WHERE id = p_adjustment_id;', TRUE),
  (14, '總部判斷：沒有登入身分（空白角色）算總部', 'public._settlement_caller_is_hq()', 'IN ('''', ''owner'', ''admin'', ''hq_manager'', ''hq_accountant'');', TRUE),
  (15, '改價函式：把「還在用、且結束日晚於新生效日」的舊版本截到新生效日', 'public.rpc_upsert_price(uuid,bigint,text,bigint,numeric,timestamptz,text,uuid)', 'UP' || 'DATE prices SET effective_to = p_effective_from WHERE tenant_id = p_tenant_id AND sku_id = p_sku_id AND scope = p_scope AND (scope_id IS NOT DISTINCT FROM p_scope_id) AND (effective_to IS NULL OR effective_to > p_effective_from);', TRUE),
  (16, '改價函式：新開一個版本，操作人寫進 created_by', 'public.rpc_upsert_price(uuid,bigint,text,bigint,numeric,timestamptz,text,uuid)', 'IN' || 'SERT IN' || 'TO prices (tenant_id, sku_id, scope, scope_id, price, effective_from, reason, created_by) VALUES (p_tenant_id, p_sku_id, p_scope, p_scope_id, p_price, p_effective_from, p_reason, p_operator)', TRUE),
  (17, '「最後異動時間」自動蓋章可以在交易內暫停（還原要用）', 'public.touch_updated_at()', 'IF current_setting(''app.skip_updated_at'', true) = ''1'' THEN RETURN NEW;', TRUE),
  (18, '月結明細保護：只有已確認／已結清的明細不能改（草稿可以）', 'public.forbid_smsi_mutation_when_locked()', 'IF v_status IN (''confirmed'', ''settled'') THEN', TRUE)
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
exposed AS (SELECT EXISTS (SELECT 1 FROM pgrst WHERE cfg LIKE '%ops_price_fix_b2%') AS yes),
users AS (
  SELECT u.id, u.email, u.last_sign_in_at, u.raw_app_meta_data ->> 'role' AS role,
         (SELECT COUNT(*) FROM public.prices p WHERE p.created_by = u.id) AS n_price,
         (SELECT COUNT(*) FROM public.prices p WHERE p.created_by = u.id AND p.reason LIKE '2026-09-29 九月分店價錯價修正%') AS n_b1,
         (SELECT COUNT(*) FROM public.store_settlement_adjustments a WHERE a.created_by = u.id) AS n_adj,
         (SELECT COUNT(*) FROM public.store_monthly_settlements m WHERE m.created_by = u.id OR m.updated_by = u.id) AS n_sms
    FROM auth.users u
   WHERE (u.raw_app_meta_data ->> 'tenant_id') = (SELECT tenant_id::text FROM tn)
     AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')
),
pv AS (   -- 分店價版本（scope=branch、全店共用那一種，跟查價工具 _branch_price_at 同條件；20260715000000:83-114）
  SELECT p.* FROM public.prices p JOIN tn ON tn.tenant_id = p.tenant_id WHERE p.scope = 'branch' AND p.scope_id IS NULL
),
st AS (SELECT s.id, s.code FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id WHERE s.location_id IS NOT NULL),
fsku AS (   -- 要逐一列出的規格：商品 G01846、G01626 底下全部，加上清單裡的 B 類
  SELECT s.id AS sku_id, s.sku_code, split_part(s.sku_code, '-', 1) AS prod,
         COALESCE(NULLIF(s.product_name, ''), '') AS pname, COALESCE(s.variant_name, '') AS vname,
         (SELECT v.correct_price FROM vlist v WHERE v.sku_code = s.sku_code LIMIT 1) AS correct_price,
         (SELECT v.cls FROM vlist v WHERE v.sku_code = s.sku_code LIMIT 1) AS cls
    FROM public.skus s JOIN tn ON tn.tenant_id = s.tenant_id
   WHERE split_part(s.sku_code, '-', 1) IN ('G01846', 'G01626')
      OR s.sku_code IN (SELECT sku_code FROM vlist WHERE cls = 'B')
),
fl AS (   -- 這些規格九月、十月（到現在）的每一筆帳（全部類型）
  SELECT l.sku_id, l.entry_type,
         CASE WHEN l.received_at < ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei') THEN 9 ELSE 10 END AS mon
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), now()) l
   WHERE l.sku_id IN (SELECT sku_id FROM fsku)
),
fx AS (
  SELECT fsku.*,
         public._branch_price_at((SELECT tenant_id FROM tn), fsku.sku_id, now()) AS cur_price,
         (SELECT COUNT(*) FROM pv WHERE pv.sku_id = fsku.sku_id) AS n_ver,
         (SELECT COUNT(*) FROM pv WHERE pv.sku_id = fsku.sku_id AND pv.effective_from >= ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) AS n_post,
         (SELECT COUNT(*) FROM fl WHERE fl.sku_id = fsku.sku_id AND fl.mon = 9) AS n9,
         (SELECT COUNT(*) FROM fl WHERE fl.sku_id = fsku.sku_id AND fl.mon = 9 AND fl.entry_type = 'hq_inbound') AS n9_hq,
         (SELECT COUNT(*) FROM fl WHERE fl.sku_id = fsku.sku_id AND fl.mon = 10) AS n10,
         (SELECT COUNT(*) FROM fl WHERE fl.sku_id = fsku.sku_id AND fl.mon = 10 AND fl.entry_type = 'hq_inbound') AS n10_hq
    FROM fsku
),
bchk AS (   -- B 類：還是只有一個版本、9/1 之後才開、沒有結束日、還不是正確價、還是盤點時的 109 元／10-05 21:47 起、九月十月沒有任何帳
  SELECT v.sku_code, v.correct_price, x.sku_id,
         x.n_ver, x.n9, x.n10, x.cur_price,
         (SELECT pv.effective_from FROM pv WHERE pv.sku_id = x.sku_id ORDER BY pv.effective_from DESC LIMIT 1) AS v_from,
         (SELECT pv.effective_to FROM pv WHERE pv.sku_id = x.sku_id ORDER BY pv.effective_from DESC LIMIT 1) AS v_to,
         (SELECT pv.price FROM pv WHERE pv.sku_id = x.sku_id ORDER BY pv.effective_from DESC LIMIT 1) AS v_price
    FROM vlist v LEFT JOIN fx x ON x.sku_code = v.sku_code
   WHERE v.cls = 'B'
),
bres AS (
  SELECT b.*,
         CASE WHEN b.sku_id IS NULL THEN '❌ 系統查不到這個規格'
              WHEN b.n_ver <> 1 THEN '❌ 分店價版本有 ' || b.n_ver || ' 個（10/7 盤點時只有 1 個），修正檔會停'
              WHEN b.v_from < ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei') THEN '❌ 這個版本是 9/1 以前就開的，不是 B 類的樣子，修正檔會停'
              WHEN b.v_to IS NOT NULL THEN '❌ 這個版本已經有結束日，修正檔會停'
              WHEN b.v_price = b.correct_price THEN '❌ 已經是正確價 ' || trim_scale(b.correct_price) || '，不用改；請 CEO 從清單拿掉'
              -- 盤點基準只有 G03061-02：109 元、2026-10-05 21:47（台北）那一分鐘開始；不一樣＝盤點後有人動過價（修正檔同一條件會停）
              WHEN b.sku_code <> 'G03061-02' OR b.v_price IS DISTINCT FROM 109
                   OR NOT COALESCE(b.v_from >= (TIMESTAMP '2026-10-05 21:47' AT TIME ZONE 'Asia/Taipei')
                                   AND b.v_from < (TIMESTAMP '2026-10-05 21:48' AT TIME ZONE 'Asia/Taipei'), false)
                THEN '❌ 跟 10/7 盤點時不一樣（盤點時 G03061-02 是 109 元、2026-10-05 21:47 起）：盤點後有人動過這個商品的價，修正檔會停'
              WHEN b.n9 + b.n10 > 0 THEN '❌ 九月十月已經有 ' || (b.n9 + b.n10) || ' 筆帳（10/7 盤點時 0 筆），修正檔會停，先給 CEO 看'
              ELSE '✅ 只有一個版本、109 元、2026-10-05 21:47 起、九月十月沒有帳' END AS res
    FROM bchk b
),
achk AS (   -- A 類：9/1 當天或之後不可以有別的版本；9/1 當下剛好一個版本在用；那個版本還不是正確價
  SELECT sk.sku_code, sk.correct_price,
         (SELECT COUNT(*) FROM pv WHERE pv.sku_id = sk.sku_id AND pv.effective_from >= ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) AS n_post,
         (SELECT MIN(pv.effective_from) FROM pv WHERE pv.sku_id = sk.sku_id AND pv.effective_from >= ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) AS post_first,
         (SELECT COUNT(*) FROM pv WHERE pv.sku_id = sk.sku_id
             AND (pv.effective_to IS NULL OR pv.effective_to > ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'))) AS n_alive,
         (SELECT MIN(pv.price) FROM pv WHERE pv.sku_id = sk.sku_id
             AND (pv.effective_to IS NULL OR pv.effective_to > ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'))) AS alive_price
    FROM sk WHERE sk.cls = 'A'
),
ares AS (
  SELECT a.*,
         CASE WHEN a.n_post > 0 THEN '❌ 9/1 當天或之後才開的版本有 ' || a.n_post || ' 個（最早 '
                                      || to_char(a.post_first AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI') || '），改價函式不能往回押，修正檔會停'
              WHEN a.n_alive <> 1 THEN '❌ 9/1 當下在用的版本有 ' || a.n_alive || ' 個（要剛好 1 個），修正檔會停'
              WHEN a.alive_price = a.correct_price THEN '❌ 9/1 起在用的版本已經是正確價 ' || trim_scale(a.correct_price) || '，不用改；請 CEO 從清單拿掉'
              END AS res
    FROM achk a
),
oct AS (SELECT COUNT(*) AS n FROM public.store_monthly_settlements m JOIN tn ON tn.tenant_id = m.tenant_id WHERE m.settlement_month = DATE '2026-10-01'),
sep AS (
  SELECT COUNT(*) AS n, COUNT(*) FILTER (WHERE status = 'draft') AS n_draft, COALESCE(SUM(payable_amount), 0) AS pay,
         COALESCE(to_char(MAX(updated_at) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '—') AS last_at
    FROM public.store_monthly_settlements m JOIN tn ON tn.tenant_id = m.tenant_id WHERE m.settlement_month = DATE '2026-09-01'
)
SELECT "序", "區塊", "項目", "結果", "說明"
FROM (
  SELECT 0 AS 序, '總計' AS "區塊",
         (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
               WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
               WHEN (SELECT n_ph FROM lchk) > 0 THEN '❌ 清單裡還有佔位（' || (SELECT ph FROM lchk) || '）：先把第 5000 項起的 G01846 規格給老闆認，CEO 換掉佔位後再跑一次'
               WHEN (SELECT n_dup FROM lchk) > 0 THEN '❌ 清單裡有 ' || (SELECT n_dup FROM lchk) || ' 個重複的品號（第 301 項），請截圖給 CEO'
               WHEN (SELECT n_miss FROM lchk) > 0 THEN '❌ 清單有 ' || (SELECT n_miss FROM lchk) || ' 個規格在系統查不到（第 301 項），請截圖給 CEO'
               ELSE '★ 總計（這一行就是結論）' END) AS "項目",
         CASE WHEN EXISTS (SELECT 1 FROM checks c WHERE c.必要 AND NOT EXISTS (
                             SELECT 1 FROM f WHERE f.序 = c.序 AND position(c.關鍵句 IN f.src) > 0))
              THEN '❌ 有必要的程式跟工程紀錄本不一樣，⛔ 不要做修正'
              WHEN (SELECT yes FROM exposed) THEN '❌ 備份位置被開放給網站讀（第 303 項），⛔ 不要做備份／修正'
              WHEN (SELECT COUNT(DISTINCT tenant_id) FROM public.stores) <> 1 THEN '❌ 店家資料不只一家公司（第 300 項），⛔ 不要做修正'
              WHEN EXISTS (SELECT 1 FROM bres WHERE res NOT LIKE '✅%') THEN '❌ B 類的樣子跟盤點時不一樣（第 7000 項起），⛔ 不要做修正'
              WHEN EXISTS (SELECT 1 FROM ares WHERE res IS NOT NULL) THEN '❌ 有 A 類品號不能照 9/1 起改價（第 7100 項起），⛔ 不要做修正'
              WHEN (SELECT n FROM oct) > 0 THEN '❌ 十月月結已經有 ' || (SELECT n FROM oct) || ' 張（第 7500 項），這批不能修，⛔ 不要做修正；先另案處理十月草稿'
              WHEN (SELECT n_ph + n_dup + n_miss FROM lchk) > 0 OR (SELECT n FROM tchk) <> 1 THEN '❌ 清單或公司不對（看左邊「項目」），⛔ 不要做修正'
              ELSE '✅ 必要的程式關鍵句都一樣、備份位置沒開放、只有一家公司、清單齊全、A／B 類的版本都跟盤點時一樣、十月月結還沒有人產生' END AS "結果",
         '往下看每一項；❌ 一律先停' AS "說明"
  UNION ALL
  SELECT 100 + c.序, '②程式核對', c.項目,
         CASE WHEN NOT EXISTS (SELECT 1 FROM f WHERE f.序 = c.序) THEN
                CASE WHEN c.必要 THEN '❌ 照名稱＋參數找不到這支' ELSE '⚠ 找不到這支' END
              WHEN EXISTS (SELECT 1 FROM f WHERE f.序 = c.序 AND position(c.關鍵句 IN f.src) > 0) THEN '✅ 一樣'
              WHEN c.必要 THEN '❌ 找不到這段，跟工程紀錄本不一樣'
              ELSE '⚠ 沒有（正式系統是 9/01 版，9/26 已知）' END,
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
         '產生器用 stores 第一筆認公司（20260901000000:135）'
  UNION ALL
  SELECT 301, '③清單核對', '清單 ' || (SELECT n_list FROM lchk) || ' 個規格在系統找得到幾個',
         CASE WHEN (SELECT n_ph + n_dup + n_miss FROM lchk) = 0 THEN '✅ ' || (SELECT COUNT(*) FROM sk) || ' 個全部找得到'
              ELSE '❌ 找得到 ' || (SELECT COUNT(*) FROM sk) || ' 個' END,
         CASE WHEN (SELECT n_ph FROM lchk) > 0 THEN '佔位（還沒換成真正編號）：' || (SELECT ph FROM lchk) || '。' ELSE '' END
           || CASE WHEN (SELECT n_dup FROM lchk) > 0 THEN '重複 ' || (SELECT n_dup FROM lchk) || ' 個。' ELSE '' END
           || CASE WHEN (SELECT n_miss FROM lchk) > 0 THEN '查不到：' || (SELECT miss FROM lchk) || '。' ELSE '' END
  UNION ALL
  SELECT 302, '②其他', '這一批的備份位置（ops_price_fix_b2）現在有沒有',
         CASE WHEN to_regnamespace('ops_price_fix_b2') IS NULL THEN '還沒有（正常，第 1 份備份才會建）' ELSE '已經有了（跑過第 1 份）' END,
         '這個位置不在網站程式讀得到的範圍（下一列）'
  UNION ALL
  SELECT 303, '②其他', '網站程式（API）讀得到哪些位置：有沒有包含備份位置 ops_price_fix_b2',
         CASE WHEN (SELECT yes FROM exposed) THEN '❌ 備份位置被開放給網站讀，⛔ 不要做備份／修正'
              WHEN NOT EXISTS (SELECT 1 FROM pgrst) THEN '⚠ 查不到設定（Supabase 預設只開 public、graphql_public）；請到 Settings → API 看 Exposed schemas 沒有 ops_price_fix_b2'
              ELSE '✅ 不包含備份位置' END,
         COALESCE((SELECT string_agg(src || '：' || cfg, '；') FROM pgrst), '（沒有任何 pgrst.db_schemas 設定）')
  UNION ALL
  SELECT 304, '②其他', '（只供參考）第一批 9/30 的備份位置 ops_sep_price_fix',
         CASE WHEN to_regnamespace('ops_sep_price_fix') IS NULL THEN 'ℹ 沒有' ELSE 'ℹ 有' END,
         '這一批用自己的位置 ops_price_fix_b2，不讀、不改、不刪第一批的備份與修正紀錄'
  UNION ALL
  SELECT 400 + ROW_NUMBER() OVER (ORDER BY users.n_b1 DESC, users.last_sign_in_at DESC NULLS LAST), '①你的使用者UUID',
         COALESCE(users.email, '（沒有 email）') || CASE WHEN (SELECT p_my_email FROM param) <> '' AND lower(users.email) = lower(trim((SELECT p_my_email FROM param)))
                                                    THEN '　👉 就是你填的信箱' ELSE '' END
           || CASE WHEN users.n_b1 > 0 THEN '　👉 9/30 第一批修正用的就是這個帳號' ELSE '' END,
         users.id::text,
         '角色 ' || COALESCE(NULLIF(users.role, ''), '（空白＝總部）') || '　最後登入 '
           || COALESCE(to_char(users.last_sign_in_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '—')
           || '　建過價格 ' || users.n_price || ' 筆（其中第一批修正寫的 ' || users.n_b1 || ' 筆）、人工調整 ' || users.n_adj || ' 筆、月結 ' || users.n_sms || ' 張'
    FROM users
   WHERE (SELECT p_my_email FROM param) = '' OR lower(users.email) = lower(trim((SELECT p_my_email FROM param)))
  UNION ALL
  SELECT 5000, '④列 12 商品 G01846', '商品 G01846 底下有幾個規格',
         CASE WHEN (SELECT COUNT(*) FROM fx WHERE prod = 'G01846') = 0 THEN '❌ 系統裡找不到任何 G01846 開頭的規格'
              ELSE 'ℹ ' || (SELECT COUNT(*) FROM fx WHERE prod = 'G01846') || ' 個（下面逐一列出）' END,
         '老闆 10/7：列 12 是商品 G01846，正確分店價 144。⛔ 規格編號不准用猜的：請老闆從下面挑，CEO 再把清單裡的佔位換掉'
  UNION ALL
  SELECT 5000 + ROW_NUMBER() OVER (ORDER BY fx.sku_code), '④列 12 商品 G01846',
         fx.sku_code || '　' || fx.pname || '／' || fx.vname,
         'ℹ 現在分店價 ' || COALESCE(trim_scale(fx.cur_price)::text, '（查無）')
           || CASE WHEN fx.cls IS NOT NULL THEN '　（已在清單裡：正確價 ' || trim_scale(fx.correct_price) || '）' ELSE '' END,
         '分店價版本 ' || fx.n_ver || ' 個（9/1 當天或之後才開的 ' || fx.n_post || ' 個）；九月：派車 ' || fx.n9_hq || ' 筆（全部帳 ' || fx.n9 || ' 筆）；'
           || '十月到現在：派車 ' || fx.n10_hq || ' 筆（全部帳 ' || fx.n10 || ' 筆）'
    FROM fx WHERE fx.prod = 'G01846'
  UNION ALL
  SELECT 6000, '④列 59 商品 G01626', '商品 G01626 底下有幾個規格',
         CASE WHEN (SELECT COUNT(*) FROM fx WHERE prod = 'G01626') = 0 THEN '❌ 系統裡找不到任何 G01626 開頭的規格'
              ELSE 'ℹ ' || (SELECT COUNT(*) FROM fx WHERE prod = 'G01626') || ' 個；在清單裡 ' || (SELECT COUNT(*) FROM fx WHERE prod = 'G01626' AND cls IS NOT NULL)
                   || ' 個、清單外 ' || (SELECT COUNT(*) FROM fx WHERE prod = 'G01626' AND cls IS NULL) || ' 個' END,
         '老闆 10/7：蠶絲被 5 款都 474（清單寫 -01～-05）'
  UNION ALL
  SELECT 6000 + ROW_NUMBER() OVER (ORDER BY fx.sku_code), '④列 59 商品 G01626',
         fx.sku_code || '　' || fx.pname || '／' || fx.vname,
         CASE WHEN fx.cls IS NULL THEN '⚠ 不在清單裡（清單外的規格）：現在分店價 ' || COALESCE(trim_scale(fx.cur_price)::text, '（查無）') || '，要不要一起改請老闆決定'
              ELSE 'ℹ 在清單裡：現在分店價 ' || COALESCE(trim_scale(fx.cur_price)::text, '（查無）') || ' → 正確價 ' || trim_scale(fx.correct_price) END,
         '分店價版本 ' || fx.n_ver || ' 個（9/1 當天或之後才開的 ' || fx.n_post || ' 個）；九月：派車 ' || fx.n9_hq || ' 筆（全部帳 ' || fx.n9 || ' 筆）；'
           || '十月到現在：派車 ' || fx.n10_hq || ' 筆（全部帳 ' || fx.n10 || ' 筆）'
    FROM fx WHERE fx.prod = 'G01626'
  UNION ALL
  SELECT 6900 + ROW_NUMBER() OVER (ORDER BY v.sku_code), '④列 59 商品 G01626', v.sku_code,
         '❌ 清單裡有、系統查不到', '請 CEO 從清單拿掉這一行，或請老闆確認編號'
    FROM vlist v WHERE split_part(v.sku_code, '-', 1) = 'G01626' AND NOT EXISTS (SELECT 1 FROM sk WHERE sk.sku_code = v.sku_code)
  UNION ALL
  SELECT 7000 + ROW_NUMBER() OVER (ORDER BY b.sku_code), '④B 類（10/05 才建）', b.sku_code || '　正確價 ' || trim_scale(b.correct_price),
         b.res,
         '版本 ' || COALESCE(b.n_ver, 0) || ' 個；這個版本 ' || COALESCE(trim_scale(b.v_price)::text, '—') || ' 元，從 '
           || COALESCE(to_char(b.v_from AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '—') || ' 起、'
           || CASE WHEN b.v_to IS NULL THEN '沒有結束日' ELSE '到 ' || to_char(b.v_to AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI') END
           || '；九月帳 ' || COALESCE(b.n9, 0) || ' 筆、十月到現在 ' || COALESCE(b.n10, 0) || ' 筆。修正做法：刪掉這個版本（備份裡有），從同一個開始時間重開正確價'
    FROM bres b
  UNION ALL
  SELECT 7100, '④A 類（9/1 00:00 起改）', 'A 類 ' || (SELECT COUNT(*) FROM vlist WHERE cls = 'A') || ' 個（系統找得到 ' || (SELECT COUNT(*) FROM ares) || ' 個）',
         CASE WHEN (SELECT COUNT(*) FROM ares WHERE res IS NOT NULL) = 0 THEN '✅ 9/1 當天或之後都沒有別的版本、9/1 當下都剛好一個版本、都還不是正確價'
              ELSE '❌ ' || (SELECT COUNT(*) FROM ares WHERE res IS NOT NULL) || ' 個不行（下面逐一列出），修正檔會停' END,
         '修正檔開頭會再檢查一次同樣的條件'
  UNION ALL
  SELECT 7100 + ROW_NUMBER() OVER (ORDER BY a.sku_code), '④A 類（9/1 00:00 起改）', a.sku_code || '　正確價 ' || trim_scale(a.correct_price),
         a.res, ''
    FROM ares a WHERE a.res IS NOT NULL
  UNION ALL
  SELECT 7500, '⑤月結', '十月月結有沒有已經產生的',
         CASE WHEN (SELECT n FROM oct) = 0 THEN '✅ 0 張（10/7 盤點時也是 0 張）'
              ELSE '❌ 已經有 ' || (SELECT n FROM oct) || ' 張，這批不能修，⛔ 不要做修正' END,
         '修正檔⛔不會產生、也不會重產十月月結；只要已經有任何一張十月月結（不論狀態），修正檔會整筆停下、什麼都沒改，要先另案處理十月草稿'
  UNION ALL
  SELECT 7600, '⑤月結', '九月月結跟 10/7 盤點比（18 張全草稿、應收 3,507,154、最後異動 2026-10-01 09:25）',
         CASE WHEN (SELECT n = 18 AND n_draft = 18 AND pay = 3507154 AND last_at = '2026-10-01 09:25' FROM sep) THEN '✅ 一樣'
              ELSE '⚠ 不一樣' END,
         '現在 ' || (SELECT n FROM sep) || ' 張（草稿 ' || (SELECT n_draft FROM sep) || ' 張）、應收 ' || trim_scale((SELECT pay FROM sep)) || '、最後異動 ' || (SELECT last_at FROM sep)
           || '；不是草稿的話修正檔會停；不一樣的部分 0-A、0-E 會拆給你看'
) z
ORDER BY "序";

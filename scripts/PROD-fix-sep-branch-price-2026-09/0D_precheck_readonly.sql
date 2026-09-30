-- ============================================================================
--  九月錯價修正 0-D　執行前核對（只查不改）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-九月分店價錯價修正_2026-09-29.md（v2）第 3、8 節
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼（兩件事）
--    ①找出「你本人」在 NEW-ERP 的使用者 UUID（一長串英數字）。修正檔要用它當「操作人」：
--      價格表每一筆都要記是誰改的（prices.created_by 不可空白，20260422120001:174），月結重產也要記。
--      ⬇ 下面 p_my_email 那一行，把引號中間換成你登入 NEW-ERP 用的 email（可以不填，不填就全部列出來讓你認）。
--      確認是你之後，把那串 UUID 交給 CEO，⛔ 不要用別人的。
--    ②確認「真正的系統」裡，修正會用到的幾支程式跟工程紀錄本（origin/main）一樣：
--      月結產生器、確認月結、作廢調整、改價函式、自動蓋章、明細保護；
--      還有這幾張表上掛了哪些自動動作（觸發器）、店家資料是不是只有一家公司、備份放的位置外面讀不讀得到。
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：（選擇性）填 email → 整份貼上 → Run → 下載 CSV 給 CEO。
--  ★ 看到什麼要停：「結果」欄有任何 ❌ → 不要做修正，截圖給 CEO。
--    ⚠ 的是提醒，照說明欄判斷；第 7 項「沒有防撞鎖」是 9/26 就知道的事（★主檔_NEW-ERP出貨鏈.md:619），修正檔自己會上鎖，不影響。
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
v57(sku_code, correct_price, cls) AS (   -- 57 個品號與老闆 Excel 正確分店價（寫死；A=54 一般、B=和牛、C=豆皮餛飩）
  VALUES
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
),
sk AS (
  SELECT s.id AS sku_id, v.sku_code, v.correct_price, v.cls,
         COALESCE(NULLIF(s.product_name, ''), '') AS pname, s.variant_name
    FROM v57 v
    JOIN public.skus s ON s.sku_code = v.sku_code
    JOIN tn ON tn.tenant_id = s.tenant_id
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
exposed AS (SELECT EXISTS (SELECT 1 FROM pgrst WHERE cfg LIKE '%ops_sep_price_fix%') AS yes),
users AS (
  SELECT u.id, u.email, u.last_sign_in_at, u.raw_app_meta_data ->> 'role' AS role,
         (SELECT COUNT(*) FROM public.prices p WHERE p.created_by = u.id) AS n_price,
         (SELECT COUNT(*) FROM public.store_settlement_adjustments a WHERE a.created_by = u.id) AS n_adj,
         (SELECT COUNT(*) FROM public.store_monthly_settlements m WHERE m.created_by = u.id OR m.updated_by = u.id) AS n_sms
    FROM auth.users u
   WHERE (u.raw_app_meta_data ->> 'tenant_id') = (SELECT tenant_id::text FROM tn)
     AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')
)
SELECT "序", "區塊", "項目", "結果", "說明"
FROM (
  SELECT 0 AS 序, '總計' AS "區塊", (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT COUNT(*) FROM sk) <> 57 THEN '❌ 57 個品號只在系統找到 ' || (SELECT COUNT(*) FROM sk) || ' 個，這份結果不能用，請截圖給 CEO'
       ELSE '★ 總計（這一行就是結論）' END) AS "項目",
         CASE WHEN EXISTS (SELECT 1 FROM checks c WHERE c.必要 AND NOT EXISTS (
                             SELECT 1 FROM f WHERE f.序 = c.序 AND position(c.關鍵句 IN f.src) > 0))
              THEN '❌ 有必要的程式跟工程紀錄本不一樣，⛔ 不要做修正'
              WHEN (SELECT yes FROM exposed) THEN '❌ 備份位置被開放給網站讀（第 303 項），⛔ 不要做備份／修正'
              WHEN (SELECT COUNT(DISTINCT tenant_id) FROM public.stores) <> 1 THEN '❌ 店家資料不只一家公司（第 300 項），⛔ 不要做修正'
              ELSE '✅ 必要的程式關鍵句都一樣、備份位置沒開放、只有一家公司' END AS "結果",
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
         '產生器用 stores 第一筆認公司（20260901000000:136）'
  UNION ALL
  SELECT 301, '②其他', '57 個品號在系統找得到幾個',
         CASE WHEN (SELECT COUNT(*) FROM sk) = 57 THEN '✅ 57 個' ELSE '❌ ' || (SELECT COUNT(*) FROM sk) || ' 個' END, ''
  UNION ALL
  SELECT 302, '②其他', '備份放的地方（ops_sep_price_fix）現在有沒有',
         CASE WHEN to_regnamespace('ops_sep_price_fix') IS NULL THEN '還沒有（正常，第 1 份備份才會建）' ELSE '已經有了（跑過第 1 份）' END,
         '這個位置不在網站程式讀得到的範圍（下一列）'
  UNION ALL
  SELECT 303, '②其他', '網站程式（API）讀得到哪些位置：有沒有包含備份位置 ops_sep_price_fix',
         CASE WHEN (SELECT yes FROM exposed) THEN '❌ 備份位置被開放給網站讀，⛔ 不要做備份／修正'
              WHEN NOT EXISTS (SELECT 1 FROM pgrst) THEN '⚠ 查不到設定（Supabase 預設只開 public、graphql_public）；請到 Settings → API 看 Exposed schemas 沒有 ops_sep_price_fix'
              ELSE '✅ 不包含備份位置' END,
         COALESCE((SELECT string_agg(src || '：' || cfg, '；') FROM pgrst), '（沒有任何 pgrst.db_schemas 設定）')
  UNION ALL
  SELECT 400 + ROW_NUMBER() OVER (ORDER BY users.last_sign_in_at DESC NULLS LAST), '①你的使用者UUID',
         COALESCE(users.email, '（沒有 email）') || CASE WHEN (SELECT p_my_email FROM param) <> '' AND lower(users.email) = lower(trim((SELECT p_my_email FROM param)))
                                                    THEN '　👉 就是你填的 email' ELSE '' END,
         users.id::text,
         '角色 ' || COALESCE(NULLIF(users.role, ''), '（空白＝總部）') || '　最後登入 '
           || COALESCE(to_char(users.last_sign_in_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '—')
           || '　建過價格 ' || users.n_price || ' 筆、人工調整 ' || users.n_adj || ' 筆、月結 ' || users.n_sms || ' 張'
    FROM users
   WHERE (SELECT p_my_email FROM param) = '' OR lower(users.email) = lower(trim((SELECT p_my_email FROM param)))
) z
ORDER BY "序";

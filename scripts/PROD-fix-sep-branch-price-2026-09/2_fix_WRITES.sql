-- ============================================================================
--  九月錯價修正 2　修正（✅ 會改資料：改價＋重產九月月結，全部在同一次裡）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-九月分店價錯價修正_2026-09-29.md（v2）第 3、8 節
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼（全部在「同一次」裡，任何一步不對就整筆取消、什麼都沒改）
--    ①先上鎖（整張表）：月結表頭／明細／爭議、人工調整、價格表、派車單與明細、店家資料
--      → 貼的這段時間（估計幾十秒，正式資料量沒量過）：月結頁面連「看」都要等；其他畫面可以看，
--        但「產生月結、確認月結、加／作廢調整、改價、派車、收貨、退貨、店轉店」都會排隊等這份做完
--        —— ⚠ 請挑沒人在用後台、倉庫沒在派車收貨的時候貼
--      → ⛔ 這份「不排隊」：貼的當下只要有人正在用月結、派車、價格（任何一把鎖拿不到），就立刻停下、什麼都沒改，
--        紅字會寫「有人正在使用…請過幾分鐘再貼一次」。為什麼不排隊：排隊會跟正在跑的「產生月結／確認月結／改估價」互卡。
--      → 上鎖順序（跟第 4 份還原一模一樣）：①月結表頭 ②月結明細 ③月結爭議 ④人工調整 ⑤價格 ⑥派車單 ⑦派車明細 ⑧店家
--        ⑨月份鎖 ⑩九月月結各列 ⑪價格各列 ⑫人工調整各列
--  ★ 貼之前：先確認沒有人在後台操作（尤其月結、改價、派車、收貨），倉庫沒在派車收貨。
--    ②鎖住之後才檢查：九月月結全部還是草稿、價格版本／月結表頭明細／人工調整／爭議跟「最新一輪備份」一模一樣
--    ③作廢你指定的人工調整（下面 p_void_ids；⚠ 預設是空的＝一筆都不作廢）
--    ④改價（57 個品號，從 2026-09-01 00:00 台北時間起＝你 Excel 的正確價）
--        A 類 54 個：用系統的改價函式 rpc_upsert_price，生效日 9/1（20260422120001:473-502）
--        B 類 和牛 G01826-01：9/15 起那個 155 版本刪掉（備份裡有），再用改價函式從 9/1 起重開 155；
--            187 那個版本會被改價函式自動截到 9/1
--        C 類 豆皮餛飩 G02239-01／-02：85 那個版本（9/03 起）刪掉（備份裡有），再用改價函式從 9/1 起開 77；
--            77.5 那個版本會被改價函式自動截到 9/1
--        → 三類的新版本都記「你本人＋本次原因」；版本之間不重疊、不留空窗
--    ⑤同一次裡直接叫月結產生器重產 2026 年 9 月（rpc_generate_hq_to_store_settlement）
--    ⑥自己驗算，全部過了才算數：
--        ・57 個品號從 9/1 起只有一個版本、就是正確價
--        ・九月每一筆用到這 57 個品號的帳，單價＝正確價；九月月結明細也是
--        ・每張九月月結的貨款＝店家每日對帳加總
--        ・八月每一筆（備份時存的逐筆基準）查到的價、數量、時點完全沒變
--        ・原本那幾張草稿都還在、還是草稿；你指定的調整確實作廢了
--    ⑦把「改完之後的樣子」也存一份（還原檔要用它確認沒有人後來又動過）
--  ★ 你要填的：下面 DECLARE 裡的兩行
--    p_operator：0-D 查到的「你本人」UUID（'xxxxxxxx-xxxx-...'）。⛔ 空的、或不是包子媽的總部帳號，都會直接停下來。
--    p_void_ids：0-B 你決定要作廢的調整 ID，例如 ARRAY[123, 456]::bigint[]；不作廢就維持 ARRAY[]::bigint[]
--  ★ 貼了會怎樣：15 家店的每日進貨對帳馬上變正確價；九月草稿重產（9/27 之後的其他異動也會一起進來，0-A 看過的那些）；
--    今天以後派車也用正確價。最後結果表會列出做了什麼。
--  ★ 貼的時候 Supabase 可能跳出「destructive operation（破壞性操作）」提醒（因為 B／C 類要刪 3 個價格版本）
--    → 確認貼的是「2修正」這份、兩個參數都填好了，再按執行（⚠ 按鈕文字以實際畫面為準）。
--  ★ 看到什麼要停：
--    ・紅字開頭是【停】→ 什麼都沒改，截圖給 CEO（紅字會寫是哪一項不對）
--    ・紅字寫「有人正在使用月結／派車／價格」（或 lock timeout）→ 什麼都沒改，過幾分鐘再貼；連續兩三次都這樣，截圖給 CEO
--    ・最後結果表的「自我驗算」不是全部 ✅ → 不可能發生（不對會整筆取消）；如果真的看到，截圖給 CEO
--  ★ 做錯了怎麼辦：第 4 份還原（只要修正之後沒有人再動過這些資料，就能一欄不差地蓋回去）。
-- ============================================================================

DO $fix$
DECLARE
  -- ╔════════ 老闆要填的兩行 ════════╗
  p_operator     uuid     := NULL;                  -- ⬅ 0-D 查到的「你本人」UUID，例如 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
  p_void_ids     bigint[] := ARRAY[]::bigint[];     -- ⬅ 0-B 決定要作廢的調整 ID，例如 ARRAY[123, 456]::bigint[]；空的＝不作廢
  -- ╚════════════════════════════════╝
  p_void_reason  text := '2026-09-29 九月分店價錯價修正：此調整由回溯改價取代（老闆確認）';
  c_reason       text := '2026-09-29 九月分店價錯價修正：老闆 Excel 正確價，回溯自 2026-09-01 起';
  c_month        date := DATE '2026-09-01';
  c_sep          timestamptz := ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei');
  v_step text; v_tenant uuid; v_cnt int; v_round int; v_fix int; v_gen jsonb; v_msg text := ''; v_id bigint; v_id2 bigint; r record;
  v_pay_before numeric; v_pay_after numeric; v_created jsonb;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  -- ── 0. 參數 ──
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '【停】操作人 p_operator 是空的。請把 0-D 查到的你本人 UUID 填進去再貼。什麼都沒改。';
  END IF;
  IF p_void_ids IS NULL THEN p_void_ids := ARRAY[]::bigint[]; END IF;

  -- 表級鎖（在讀任何月結／價格／調整狀態之前）——一律 NOWAIT：拿不到就立刻放棄，⛔ 不排隊
  --   為什麼不排隊：排隊等鎖時，已經開始的產生器／確認月結（先讀月結表、後寫）或估價修正（先改 transfer_items、
  --   再呼叫產生器，順序跟我們相反）會跟我們互等（死鎖）。所以任何一把拿不到，整份立刻取消、什麼都沒改，請人稍後再貼。
  --   取得順序（2修正、4還原一模一樣）：
  --     ①月結表頭 ACCESS EXCLUSIVE（別人連看都要等；9/01 版產生器先讀後寫，只擋寫會讓它把舊價寫回去，本機實測過）
  --     ②月結明細 ③月結爭議 ④人工調整 ⑤價格：SHARE ROW EXCLUSIVE（別人可以看，不能新增／修改／刪除）
  --     ⑥派車單 ⑦派車明細 ⑧店家：SHARE（別人可以看，不能新增／修改：派車、收貨、退貨、店轉店都要等；
  --        店家每日對帳 _store_inbound_lines，20260901000000:597-742，只讀這幾張加價格表，鎖住後數字不會變）
  --     ⑨月份鎖（advisory，try 版）⑩九月月結各列 ⑪價格各列 ⑫人工調整各列（FOR UPDATE NOWAIT，雙保險）
  --   lock_timeout 15 秒保留當後備（NOWAIT 之外的意外等待）
  BEGIN
    v_step := '①月結表頭';  LOCK TABLE public.store_monthly_settlements       IN ACCESS EXCLUSIVE MODE NOWAIT;
    v_step := '②月結明細';  LOCK TABLE public.store_monthly_settlement_items  IN SHARE ROW EXCLUSIVE MODE NOWAIT;
    v_step := '③月結爭議';  LOCK TABLE public.store_settlement_disputes      IN SHARE ROW EXCLUSIVE MODE NOWAIT;
    v_step := '④人工調整';  LOCK TABLE public.store_settlement_adjustments   IN SHARE ROW EXCLUSIVE MODE NOWAIT;
    v_step := '⑤價格';      LOCK TABLE public.prices                         IN SHARE ROW EXCLUSIVE MODE NOWAIT;
    v_step := '⑥派車單';    LOCK TABLE public.transfers                      IN SHARE MODE NOWAIT;
    v_step := '⑦派車明細';  LOCK TABLE public.transfer_items                 IN SHARE MODE NOWAIT;
    v_step := '⑧店家';      LOCK TABLE public.stores                         IN SHARE MODE NOWAIT;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION '【停】有人正在使用月結／派車／價格（第 % 步「鎖」拿不到），這次什麼都沒改。請先確認沒有人在後台操作、倉庫沒在派車收貨，過幾分鐘再貼一次；連續兩三次都失敗，請截圖給 CEO。', v_step;
  END;

  -- ── 1. 公司 ──
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
  -- 操作人要是包子媽的總部帳號：公司看登入帳號 app_metadata.tenant_id（20260707000000:61-69 用同一欄認公司），
  -- 總部角色照 _settlement_caller_is_hq()（20260715000120:132-137）：空白／owner／admin／hq_manager／hq_accountant
  IF NOT EXISTS (SELECT 1 FROM auth.users u
                  WHERE u.id = p_operator
                    AND (u.raw_app_meta_data ->> 'tenant_id') = v_tenant::text
                    AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')) THEN
    RAISE EXCEPTION '【停】操作人 % 不是包子媽生鮮小舖的總部帳號（或根本不是登入帳號）。請用 0-D 列出的你本人 UUID。什麼都沒改。', p_operator;
  END IF;

  -- ── 2. 備份輪次 ──
  IF to_regclass('ops_sep_price_fix.fix_log') IS NULL THEN
    RAISE EXCEPTION '【停】還沒有備份（找不到 ops_sep_price_fix）。請先貼第 1 份（備份）。什麼都沒改。';
  END IF;
  v_round := (SELECT MAX(bk_round) FROM ops_sep_price_fix.rounds WHERE tenant_id = v_tenant);
  IF v_round IS NULL THEN
    RAISE EXCEPTION '【停】還沒有備份。請先貼第 1 份（備份）。什麼都沒改。';
  END IF;
  IF EXISTS (SELECT 1 FROM ops_sep_price_fix.fix_log WHERE restored_at IS NULL) THEN
    RAISE EXCEPTION '【停】已經修正過一次、而且還沒還原（第 % 次修正）。不能重複修正。什麼都沒改。',
      (SELECT MAX(fix_id) FROM ops_sep_price_fix.fix_log WHERE restored_at IS NULL);
  END IF;
  -- 備份裡的 57 品號清單＝這份寫死的清單
  v_cnt := (SELECT COUNT(*) FROM (VALUES
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
           FULL JOIN (SELECT * FROM ops_sep_price_fix.sku_list WHERE bk_round = v_round) b ON b.sku_code = v.sku_code
          WHERE b.sku_code IS NULL OR v.sku_code IS NULL OR b.correct_price <> v.correct_price OR b.cls <> v.cls);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】備份裡的品號清單跟這份不一樣（% 處）。什麼都沒改。', v_cnt;
  END IF;

  -- ── 3. 再上月份鎖與列鎖（表級鎖已在最前面拿到；一樣 NOWAIT，順序同還原檔）──
  -- 月份鎖：與月結產生器 9/07 版、退貨更正同一把（20260907030000:754-756）；確認月結也是先 FOR UPDATE 同一列（20260715000120:553-555）
  BEGIN
    v_step := '⑨月份鎖';
    IF NOT pg_try_advisory_xact_lock(hashtext('settlement:' || v_tenant::text || ':' || c_month::text)) THEN
      RAISE EXCEPTION USING ERRCODE = 'lock_not_available';
    END IF;
    v_step := '⑩九月月結各列';
    PERFORM 1 FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = c_month FOR UPDATE NOWAIT;
    v_step := '⑪價格各列';
    PERFORM 1 FROM public.prices WHERE tenant_id = v_tenant AND scope = 'branch' AND sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round) FOR UPDATE NOWAIT;
    v_step := '⑫人工調整各列';
    PERFORM 1 FROM public.store_settlement_adjustments WHERE tenant_id = v_tenant AND settlement_month = c_month FOR UPDATE NOWAIT;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION '【停】有人正在使用月結／派車／價格（第 % 步「鎖」拿不到），這次什麼都沒改。請先確認沒有人在後台操作、倉庫沒在派車收貨，過幾分鐘再貼一次；連續兩三次都失敗，請截圖給 CEO。', v_step;
  END;

  -- ── 4. 鎖住之後才檢查 ──
  IF EXISTS (SELECT 1 FROM public.store_monthly_settlements
              WHERE tenant_id = v_tenant AND settlement_month = c_month AND status <> 'draft') THEN
    RAISE EXCEPTION '【停】有店的九月月結已經不是草稿：%。什麼都沒改，請截圖給 CEO。',
      (SELECT string_agg(s.code || '＝' || m.status, '、') FROM public.store_monthly_settlements m JOIN public.stores s ON s.id = m.store_id
        WHERE m.tenant_id = v_tenant AND m.settlement_month = c_month AND m.status <> 'draft');
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round)) EXCEPT (SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices') EXCEPT (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round)))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '分店價版本有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01') EXCEPT (SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms') EXCEPT (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01'))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結表頭有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) EXCEPT (SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'smsi'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'smsi') EXCEPT (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結明細有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01') EXCEPT (SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa') EXCEPT (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01'))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月人工調整有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) EXCEPT (SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd') EXCEPT (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結爭議有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  IF v_msg <> '' THEN
    RAISE EXCEPTION '【停】現在的資料跟第 % 輪備份不一樣：%。什麼都沒改。請重貼第 1 份（備份）再來，或截圖給 CEO。', v_round, v_msg;
  END IF;

  v_pay_before := (SELECT COALESCE(SUM(payable_amount), 0) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = c_month);

  -- ── 5. 作廢人工調整（預設空＝不作廢）──
  FOREACH v_id IN ARRAY p_void_ids LOOP
    IF NOT EXISTS (SELECT 1 FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa' AND b.pk = v_id AND b.j ->> 'status' = 'active') THEN
      RAISE EXCEPTION '【停】要作廢的調整 ID % 不是「九月、包子媽、有效」的調整。什麼都沒改。', v_id;
    END IF;
    PERFORM public.rpc_void_settlement_adjustment(v_id, p_operator, p_void_reason);   -- 20260801000000:160-224
  END LOOP;

  -- ── 6. 改價 ──
  -- A 類：9/1 之後不可以有別的版本；9/1 當下剛好一個版本在用（它會被截到 9/1）
  FOR r IN SELECT * FROM ops_sep_price_fix.sku_list WHERE bk_round = v_round AND cls = 'A' ORDER BY sku_code LOOP
    IF EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = r.sku_id AND p.scope = 'branch'
                AND p.scope_id IS NULL AND p.effective_from >= c_sep) THEN
      RAISE EXCEPTION '【停】A 類 % 有 9/1 之後才開的價格版本，不能用改價函式往回押。什麼都沒改。', r.sku_code;
    END IF;
    IF (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = r.sku_id AND p.scope = 'branch'
         AND p.scope_id IS NULL AND (p.effective_to IS NULL OR p.effective_to > c_sep)) <> 1 THEN
      RAISE EXCEPTION '【停】A 類 % 在 9/1 當下不是剛好一個版本在用。什麼都沒改。', r.sku_code;
    END IF;
    PERFORM public.rpc_upsert_price(v_tenant, r.sku_id, 'branch', NULL, r.correct_price, c_sep, c_reason, p_operator);
  END LOOP;

  -- B 類（和牛）與 C 類（豆皮餛飩）共同檢查：9/1 當下剛好一個「跨 9/1」的舊版本、9/1 之後剛好一個開放版本、兩者首尾相接
  FOR r IN SELECT * FROM ops_sep_price_fix.sku_list WHERE bk_round = v_round AND cls IN ('B','C') ORDER BY sku_code LOOP
    IF (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = r.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
         AND p.effective_from < c_sep AND (p.effective_to IS NULL OR p.effective_to > c_sep)) <> 1
       OR (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = r.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
         AND p.effective_from >= c_sep) <> 1 THEN
      RAISE EXCEPTION '【停】% 的價格版本長得跟盤點時不一樣。什麼都沒改。', r.sku_code;
    END IF;
    v_id  := (SELECT p.id FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = r.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
               AND p.effective_from < c_sep AND (p.effective_to IS NULL OR p.effective_to > c_sep));
    v_id2 := (SELECT p.id FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = r.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
               AND p.effective_from >= c_sep);
    IF (SELECT effective_to FROM public.prices WHERE id = v_id) IS DISTINCT FROM (SELECT effective_from FROM public.prices WHERE id = v_id2)
       OR (SELECT effective_to FROM public.prices WHERE id = v_id2) IS NOT NULL THEN
      RAISE EXCEPTION '【停】% 的兩個版本沒有首尾相接，或 9/1 之後的版本已經結束。什麼都沒改。', r.sku_code;
    END IF;
    IF r.cls = 'B' THEN
      IF (SELECT price FROM public.prices WHERE id = v_id2) <> r.correct_price THEN
        RAISE EXCEPTION '【停】和牛 % 9/1 之後那個版本不是正確價 %。什麼都沒改。', r.sku_code, r.correct_price;
      END IF;
    END IF;
    -- B／C 同一路線（阿審裁定）：刪掉 9/1 之後才開的那個版本（和牛 155／餛飩 85，原樣在備份），
    -- 再用改價函式從 9/1 起重開正確價；跨 9/1 的舊版本（187／77.5）由函式自動截到 9/1（20260422120001:486-497）。
    -- 新版本記本次操作人與原因。
    DELETE FROM public.prices WHERE id = v_id2;
    PERFORM public.rpc_upsert_price(v_tenant, r.sku_id, 'branch', NULL, r.correct_price, c_sep, c_reason, p_operator);
  END LOOP;

  -- ── 7. 同一次裡重產九月月結 ──
  v_gen := public.rpc_generate_hq_to_store_settlement(c_month, p_operator);
  v_pay_after := (SELECT COALESCE(SUM(payable_amount), 0) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = c_month);

  -- ── 8. 自我驗算（任何一項不對 → 整筆取消）──
  -- 8-1 價格版本：9/1 之後只剩一個版本、從 9/1 開始、沒有結束日、就是正確價；9/1 當下查價＝正確價
  v_msg := (SELECT string_agg(l.sku_code, '、') FROM ops_sep_price_fix.sku_list l
             WHERE l.bk_round = v_round
               AND ( (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                        AND (p.effective_to IS NULL OR p.effective_to > c_sep)) <> 1
                  OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                        AND p.effective_from = c_sep AND p.effective_to IS NULL AND p.price = l.correct_price)
                  OR public._branch_price_at(v_tenant, l.sku_id, c_sep) IS DISTINCT FROM l.correct_price
                  OR public._branch_price_at(v_tenant, l.sku_id, now()) IS DISTINCT FROM l.correct_price));
  IF v_msg IS NOT NULL THEN RAISE EXCEPTION '【停】改價後這些品號的版本不對：%。已全部取消。', v_msg; END IF;
  -- 8-2 九月每一筆帳（店家每日對帳）單價＝正確價
  v_cnt := (SELECT COUNT(*) FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round)) x JOIN ops_sep_price_fix.sku_list l ON l.bk_round = v_round AND l.sku_id = x.sku_id
             WHERE x.unit_price <> l.correct_price);
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】改價後九月還有 % 筆帳不是正確價。已全部取消。', v_cnt; END IF;
  -- 8-3 九月月結明細單價＝正確價
  v_cnt := (SELECT COUNT(*) FROM public.store_monthly_settlement_items i
              JOIN public.store_monthly_settlements m ON m.id = i.settlement_id
              JOIN ops_sep_price_fix.sku_list l ON l.bk_round = v_round AND l.sku_id = i.sku_id
             WHERE m.tenant_id = v_tenant AND m.settlement_month = c_month
               AND i.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND i.unit_branch_price <> l.correct_price);
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】重產後九月月結還有 % 行不是正確價。已全部取消。', v_cnt; END IF;
  -- 8-4 每張九月月結貨款＝每日對帳加總
  v_cnt := (SELECT COUNT(*) FROM public.store_monthly_settlements m
             WHERE m.tenant_id = v_tenant AND m.settlement_month = c_month
               AND m.branch_amount <> COALESCE((SELECT SUM(l.amount) FROM public._store_inbound_lines(m.store_id, c_sep, ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l), 0));
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】重產後有 % 張九月月結貨款跟每日對帳加總不一樣。已全部取消。', v_cnt; END IF;
  -- 8-5 八月逐筆不變（跟備份時存的基準逐筆比，時點、數量、單價、金額都要一樣）
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round)) x)
               EXCEPT (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_sep_price_fix.aug_lines WHERE bk_round = v_round))
              UNION ALL
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_sep_price_fix.aug_lines WHERE bk_round = v_round)
               EXCEPT (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round)) x))) d);
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】改價後八月有 % 筆（兩邊合計）跟備份時不一樣。已全部取消，請截圖給 CEO。', v_cnt; END IF;
  -- 8-6 原本的草稿都還在、還是草稿
  v_cnt := (SELECT COUNT(*) FROM ops_sep_price_fix.bk_rows b
             WHERE b.bk_round = v_round AND b.tbl = 'sms'
               AND NOT EXISTS (SELECT 1 FROM public.store_monthly_settlements m WHERE m.id = b.pk AND m.status = 'draft'));
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】重產後有 % 張原本的草稿不見了或不是草稿。已全部取消，請截圖給 CEO。', v_cnt; END IF;
  -- 8-7 指定的調整都作廢了
  v_cnt := (SELECT COUNT(*) FROM unnest(p_void_ids) x(id)
             WHERE NOT EXISTS (SELECT 1 FROM public.store_settlement_adjustments a WHERE a.id = x.id AND a.status = 'voided'));
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】有 % 筆指定的調整沒有作廢成功。已全部取消。', v_cnt; END IF;

  -- ── 9. 留紀錄＋存「改完之後的樣子」（還原要用）──
  v_fix := COALESCE((SELECT MAX(fix_id) FROM ops_sep_price_fix.fix_log), 0) + 1;
  v_created := COALESCE((SELECT jsonb_agg(jsonb_build_object('settlement_id', m.id, 'store', s.code) ORDER BY s.code)
                           FROM public.store_monthly_settlements m JOIN public.stores s ON s.id = m.store_id
                          WHERE m.tenant_id = v_tenant AND m.settlement_month = c_month
                            AND NOT EXISTS (SELECT 1 FROM ops_sep_price_fix.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms' AND b.pk = m.id)), '[]'::jsonb);
  INSERT INTO ops_sep_price_fix.fix_log (fix_id, bk_round, operator, void_ids, gen_result, summary)
  VALUES (v_fix, v_round, p_operator, p_void_ids, v_gen, jsonb_build_object(
    '01 修正編號', v_fix,
    '02 用的備份輪次', v_round,
    '03 作廢的人工調整', CASE WHEN cardinality(p_void_ids) = 0 THEN '（沒有作廢任何一筆：p_void_ids 是空的）'
                              ELSE array_to_string(p_void_ids, '、') END,
    '04 改價', 'A 類 ' || (SELECT COUNT(*) FROM ops_sep_price_fix.sku_list WHERE bk_round = v_round AND cls = 'A') || ' 個（改價函式）／B 類和牛 1 個（刪 9/15 起 155、9/1 起重開 155）／C 類豆皮餛飩 2 個（刪 85、9/1 起開 77）',
    '05 九月月結應收合計', trim_scale(v_pay_before) || ' → ' || trim_scale(v_pay_after),
    '06 本次新建的九月月結', CASE WHEN jsonb_array_length(v_created) = 0 THEN '（沒有）'
                                  ELSE (SELECT string_agg(e ->> 'store', '、') FROM jsonb_array_elements(v_created) e) END,
    '06b 新建月結 ID', v_created,
    '07 自我驗算', '✅ 價格版本／九月逐筆單價／九月月結明細／貨款＝每日對帳／八月逐筆不變／原草稿仍在／調整作廢，全部通過',
    '08 操作人', p_operator::text));
  INSERT INTO ops_sep_price_fix.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'prices', x.pk, x.j FROM (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_sep_price_fix.sku_list l WHERE l.bk_round = v_round)) x;
  INSERT INTO ops_sep_price_fix.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'sms', x.pk, x.j FROM (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01') x;
  INSERT INTO ops_sep_price_fix.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'smsi', x.pk, x.j FROM (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x;
  INSERT INTO ops_sep_price_fix.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'ssa', x.pk, x.j FROM (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01') x;
  INSERT INTO ops_sep_price_fix.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'ssd', x.pk, x.j FROM (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x;
  INSERT INTO ops_sep_price_fix.after_sept_lines (fix_id, store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount)
  SELECT v_fix, x.* FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL ) x;
END $fix$;

-- 結果
SELECT key AS "項目", value AS "內容"
  FROM ops_sep_price_fix.fix_log f, jsonb_each_text(f.summary)
 WHERE f.fix_id = (SELECT MAX(fix_id) FROM ops_sep_price_fix.fix_log)
 ORDER BY key;

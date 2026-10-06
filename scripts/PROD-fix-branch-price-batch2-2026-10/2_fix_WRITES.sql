-- ============================================================================
--  第二批分店價錯價修正 2　修正（✅ 會改資料：改價＋重產九月月結，全部在同一次裡）
--  日期：2026-10-07　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-第二批分店價錯價修正_九月十月_2026-10-07.md、派工單-第二批分店價錯價修正指令_2026-10-07.md
--  範本：第一批 NEW-ERP九月錯價修正_2026-09-29_2修正（9/30 已在正式系統跑成功）；上鎖、鎖後檢查、重產、自我驗算的寫法照抄。
--        跟第一批不同：①清單換成這一批（佔位或查不到 → 整筆停）②A 類改價前先整批檢查、列出不行的是哪幾個
--        ③B 類（10/05 才建的版本）改成「刪掉、從同一個開始時間重開正確價」④多驗十月 ⑤⛔不產生十月月結
--        ⑥備份與修正紀錄放這一批自己的位置 ops_price_fix_b2（第一批的 ops_sep_price_fix 一個字都不碰）
--  程式出處：唯讀鏡像 origin/main 500ecc32 的 supabase/migrations/（行號寫在各段註解）
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
--    ②鎖住之後才檢查：九月月結全部還是草稿、十月月結一張都還沒有（有任何一張就整筆停）、
--      價格版本／月結表頭明細／人工調整／爭議跟「最新一輪備份」一模一樣
--    ③改價之前先把整批再檢查一次（不對就整筆停，紅字會列出是哪幾個品號）：
--        A 類：9/1 當天或之後不可以有別的價格版本；9/1 當下剛好一個版本在用；那個版本還不是正確價
--        B 類：還是只有一個版本、9/1 之後才開、沒有結束日、還不是正確價；九月十月還是沒有任何帳；
--            而且那個版本還是 10/7 盤點時的 109 元、2026-10-05 21:47（台北）那一分鐘開始（不一樣＝盤點後有人動過價）
--    ④作廢你指定的人工調整（下面 p_void_ids；⚠ 預設是空的＝一筆都不作廢）
--    ⑤改價
--        A 類：用系統的改價函式 rpc_upsert_price，從 2026-09-01 00:00（台北時間）起＝你 Excel 的正確價（20260422120001:473-502）；
--            9/1 當下在用的那個錯價版本會被函式自動截到 9/1
--        B 類：把 10/05 才建的那個錯價版本刪掉（備份裡有），再用改價函式「從它原本的開始時間」重開正確價。
--            不能直接從同一個時間點開新版本：舊版本會被截成「開始＝結束」，價格表不允許（20260422120001:176）
--        → 新版本都記「你本人＋本次原因」；版本之間不重疊、不留空窗
--    ⑥同一次裡直接叫月結產生器重產 2026 年 9 月（rpc_generate_hq_to_store_settlement）
--      ⛔ 十月不產生月結（月份還沒結束）；十月靠價目表改對，月底產生時自然是正確價
--    ⑦自己驗算，全部過了才算數：
--        ・A 類從 9/1 起只有一個版本、就是正確價；B 類只有一個版本、開始時間跟原本一樣、就是正確價
--        ・九月、十月（到現在）每一筆用到這批品號的帳，單價＝正確價；九月月結明細也是
--        ・每張九月月結的貨款＝店家每日對帳加總
--        ・八月每一筆（備份時存的逐筆基準）查到的價、數量、時點完全沒變
--        ・原本那幾張草稿都還在、還是草稿；你指定的調整確實作廢了；十月月結張數跟修正前一樣（沒有產生）
--    ⑧把「改完之後的樣子」也存一份（還原檔要用它確認沒有人後來又動過；十月只存這批品號）
--  ★ 要填的：下面 DECLARE 裡的兩行（CEO 在老闆確認後填）
--    p_operator：0-D 查到、老闆確認過的「老闆本人」UUID。⛔ 交件時刻意留空；空的、或不是包子媽的總部帳號，都會直接停下來。
--    p_void_ids：0-B 老闆決定要作廢的調整 ID，例如 ARRAY[123, 456]::bigint[]；不作廢就維持 ARRAY[]::bigint[]
--  ★ 清單：下面「清單段」跟 0-A～0-D、1 備份、3 驗算逐字相同。裡面還有佔位（品號帶 ?）就會直接停，什麼都沒改。
--  ★ 貼了會怎樣：有九月、十月帳的店，每日進貨對帳馬上變正確價；九月草稿重產（草稿存下來之後的其他異動也會一起進來，
--    0-A、0-E 看過的那些）；今天以後派車也用正確價。最後結果表會列出做了什麼。
--  ★ 貼的時候 Supabase 可能跳出「destructive operation（破壞性操作）」提醒（因為 B 類要刪 1 個價格版本）
--    → 確認貼的是「2修正」這份、兩個參數都填好了，再按執行（⚠ 按鈕文字以實際畫面為準）。
--  ★ 看到什麼要停：
--    ・紅字開頭是【停】→ 什麼都沒改，截圖給 CEO（紅字會寫是哪一項不對）
--    ・紅字寫「有人正在使用月結／派車／價格」（或 lock timeout）→ 什麼都沒改，過幾分鐘再貼；連續兩三次都這樣，截圖給 CEO
--    ・最後結果表的「自我驗算」不是全部 ✅ → 不可能發生（不對會整筆取消）；如果真的看到，截圖給 CEO
--  ★ 做錯了怎麼辦：第 4 份還原（只要修正之後沒有人再動過這些資料，就能一欄不差地蓋回去；只還原這一批）。
-- ============================================================================

DO $fix$
DECLARE
  -- ╔════════ 要填的兩行（CEO 在老闆確認後填）════════╗
  p_operator     uuid     := NULL;                  -- ⬅ 操作人：0-D 查到、老闆確認過的本人 UUID，例如 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'；⛔ 空的會直接停
  p_void_ids     bigint[] := ARRAY[]::bigint[];     -- ⬅ 0-B 決定要作廢的調整 ID，例如 ARRAY[123, 456]::bigint[]；空的＝不作廢
  -- ╚════════════════════════════════════════════════╝
  p_void_reason  text := '2026-10-07 第二批分店價錯價修正：此調整由回溯改價取代（老闆確認）';
  c_reason       text := '2026-10-07 第二批分店價錯價修正：老闆 Excel 正確價，回溯自 2026-09-01 起';
  c_reason_b     text := '2026-10-07 第二批分店價錯價修正：老闆 Excel 正確價，從原本那個版本的開始時間起';
  c_month        date := DATE '2026-09-01';
  c_sep          timestamptz := ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei');
  c_oct          timestamptz := ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei');
  v_step text; v_tenant uuid; v_cnt int; v_round int; v_fix int; v_gen jsonb; v_msg text := ''; v_id bigint; r record;
  v_pay_before numeric; v_pay_after numeric; v_created jsonb; v_list jsonb; v_from timestamptz;
  v_oct_sms_before int; v_oct_sms_after int; v_oct_lines int;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  -- ── 0. 參數與清單（這一段不讀任何資料表）──
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '【停】操作人 p_operator 是空的。要由 CEO 把老闆確認過的本人 UUID 填進去再貼。什麼都沒改。';
  END IF;
  IF p_void_ids IS NULL THEN p_void_ids := ARRAY[]::bigint[]; END IF;
  -- 這一批的清單（寫死，與 0-A～0-D、1 備份、3 驗算同一段）
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
  v_msg := (SELECT string_agg(x.sku_code, '、') FROM jsonb_to_recordset(v_list) AS x(sku_code text, correct_price numeric, cls text) WHERE x.sku_code LIKE '%?%');
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】清單裡還有佔位：%（要等老闆確認、CEO 換成真正的規格編號）。什麼都沒改。', v_msg;
  END IF;
  v_cnt := (SELECT COUNT(*) - COUNT(DISTINCT x.sku_code) FROM jsonb_to_recordset(v_list) AS x(sku_code text, correct_price numeric, cls text));
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】清單裡有 % 個重複的品號。什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;
  v_msg := '';

  -- 表級鎖（在讀任何月結／價格／調整狀態之前）——一律 NOWAIT：拿不到就立刻放棄，⛔ 不排隊
  --   為什麼不排隊：排隊等鎖時，已經開始的產生器／確認月結（先讀月結表、後寫）或估價修正（先改 transfer_items、
  --   再呼叫產生器，順序跟我們相反）會跟我們互等（死鎖）。所以任何一把拿不到，整份立刻取消、什麼都沒改，請人稍後再貼。
  --   取得順序（2修正、4還原一模一樣）：
  --     ①月結表頭 ACCESS EXCLUSIVE（別人連看都要等；9/01 版產生器先讀後寫，只擋寫會讓它把舊價寫回去，第一批本機實測過）
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
  -- 月結產生器用「stores 第一筆」認公司（20260901000000:135、20260907030000:750）→ 有別家公司的店就不能讓它自動重產
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
    RAISE EXCEPTION '【停】操作人 % 不是包子媽生鮮小舖的總部帳號（或根本不是登入帳號）。請用 0-D 列出、老闆確認過的本人 UUID。什麼都沒改。', p_operator;
  END IF;

  -- ── 2. 備份輪次（這一批自己的位置 ops_price_fix_b2；第一批的 ops_sep_price_fix 不讀不碰）──
  IF to_regclass('ops_price_fix_b2.fix_log') IS NULL THEN
    RAISE EXCEPTION '【停】還沒有這一批的備份（找不到 ops_price_fix_b2）。請先貼第 1 份（備份）。什麼都沒改。';
  END IF;
  v_round := (SELECT MAX(bk_round) FROM ops_price_fix_b2.rounds WHERE tenant_id = v_tenant);
  IF v_round IS NULL THEN
    RAISE EXCEPTION '【停】還沒有這一批的備份。請先貼第 1 份（備份）。什麼都沒改。';
  END IF;
  IF EXISTS (SELECT 1 FROM ops_price_fix_b2.fix_log WHERE restored_at IS NULL) THEN
    RAISE EXCEPTION '【停】這一批已經修正過一次、而且還沒還原（第 % 次修正）。不能重複修正。什麼都沒改。',
      (SELECT MAX(fix_id) FROM ops_price_fix_b2.fix_log WHERE restored_at IS NULL);
  END IF;
  -- 備份裡的品號清單＝這份寫死的清單
  v_cnt := (SELECT COUNT(*) FROM jsonb_to_recordset(v_list) AS v(sku_code text, correct_price numeric, cls text)
           FULL JOIN (SELECT * FROM ops_price_fix_b2.sku_list WHERE bk_round = v_round) b ON b.sku_code = v.sku_code
          WHERE b.sku_code IS NULL OR v.sku_code IS NULL OR b.correct_price <> v.correct_price OR b.cls <> v.cls);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】第 % 輪備份裡的品號清單跟這份不一樣（% 處）。什麼都沒改；清單改過的話要重貼第 1 份（備份）。', v_round, v_cnt;
  END IF;

  -- ── 3. 再上月份鎖與列鎖（表級鎖已在最前面拿到；一樣 NOWAIT，順序同還原檔）──
  -- 月份鎖：與月結產生器 9/07 版、退貨更正同一把（20260907030000:757-759）；確認月結也是先 FOR UPDATE 同一列（20260715000120:553-555）
  BEGIN
    v_step := '⑨月份鎖';
    IF NOT pg_try_advisory_xact_lock(hashtext('settlement:' || v_tenant::text || ':' || c_month::text)) THEN
      RAISE EXCEPTION USING ERRCODE = 'lock_not_available';
    END IF;
    v_step := '⑩九月月結各列';
    PERFORM 1 FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = c_month FOR UPDATE NOWAIT;
    v_step := '⑪價格各列';
    PERFORM 1 FROM public.prices WHERE tenant_id = v_tenant AND scope = 'branch' AND sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round) FOR UPDATE NOWAIT;
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
  -- 十月月結：只要已經有任何一張（不論狀態）就整筆停。
  --   這份不產生、也不重產十月；已經存在的十月月結會留著錯價，所以不能修，要先另案處理十月草稿。
  --   月結表頭在最前面已經鎖住（①），這裡查到的張數在這份做完之前不會變。8-8 的「前後張數相同」照舊保留。
  v_cnt := (SELECT COUNT(*) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = DATE '2026-10-01');
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】十月月結已經有人產生（% 張），這批不能修，先另案處理十月草稿；什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices') EXCEPT (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '分店價版本有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01') EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms') EXCEPT (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01'))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結表頭有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'smsi'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'smsi') EXCEPT (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結明細有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01') EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa') EXCEPT (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01'))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月人工調整有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd') EXCEPT (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結爭議有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  IF v_msg <> '' THEN
    RAISE EXCEPTION '【停】現在的資料跟第 % 輪備份不一樣：%。什麼都沒改。請重貼第 1 份（備份）再來，或截圖給 CEO。', v_round, v_msg;
  END IF;

  -- ── 4b. 改價之前，整批再檢查一次（任何一個不對 → 整筆停，紅字列出是哪幾個）──
  -- A 類：9/1 當天或之後不可以有別的版本（有的話改價函式不能往回押）
  v_msg := (SELECT string_agg(l.sku_code, '、' ORDER BY l.sku_code) FROM ops_price_fix_b2.sku_list l
             WHERE l.bk_round = v_round AND l.cls = 'A'
               AND EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch'
                            AND p.scope_id IS NULL AND p.effective_from >= c_sep));
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】這些 A 類品號在 9/1 當天或之後還有別的價格版本，不能用改價函式往回押：%。什麼都沒改，請截圖給 CEO。', v_msg;
  END IF;
  -- A 類：9/1 當下剛好一個版本在用（它會被截到 9/1）
  v_msg := (SELECT string_agg(l.sku_code, '、' ORDER BY l.sku_code) FROM ops_price_fix_b2.sku_list l
             WHERE l.bk_round = v_round AND l.cls = 'A'
               AND (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch'
                     AND p.scope_id IS NULL AND (p.effective_to IS NULL OR p.effective_to > c_sep)) <> 1);
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】這些 A 類品號在 9/1 當下不是剛好一個價格版本在用：%。什麼都沒改，請截圖給 CEO。', v_msg;
  END IF;
  -- A 類：9/1 起在用的那個版本還不是正確價（已經正確的一律不動）
  v_msg := (SELECT string_agg(l.sku_code, '、' ORDER BY l.sku_code) FROM ops_price_fix_b2.sku_list l
             WHERE l.bk_round = v_round AND l.cls = 'A'
               AND EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch'
                            AND p.scope_id IS NULL AND (p.effective_to IS NULL OR p.effective_to > c_sep) AND p.price = l.correct_price));
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】這些 A 類品號 9/1 起在用的價格本來就是正確價，不在修正範圍（已經正確的一律不動），請 CEO 從清單拿掉：%。什麼都沒改。', v_msg;
  END IF;
  -- B 類：只有一個版本、9/1 之後才開、沒有結束日、還不是正確價（10/7 盤點時的樣子）
  v_msg := (SELECT string_agg(l.sku_code, '、' ORDER BY l.sku_code) FROM ops_price_fix_b2.sku_list l
             WHERE l.bk_round = v_round AND l.cls = 'B'
               AND ( (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL) <> 1
                  OR EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                              AND (p.effective_from < c_sep OR p.effective_to IS NOT NULL OR p.price = l.correct_price))));
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】B 類 % 的價格版本長得跟盤點時不一樣（盤點時：只有一個、9/1 之後才開、沒有結束日、還是錯價）。什麼都沒改，請截圖給 CEO。', v_msg;
  END IF;
  -- B 類：那唯一一個版本要跟 10/7 盤點時一模一樣＝G03061-02、109 元、2026-10-05 21:47（台北）那一分鐘開始。
  --   不一樣就是盤點後有人動過這個商品的價（就算還沒有帳也停，不從別人改過的版本重開）。
  --   盤點基準只有 G03061-02 這一個；B 類出現別的品號一樣停（沒有盤點基準可以核對）。
  v_msg := (SELECT string_agg(l.sku_code, '、' ORDER BY l.sku_code) FROM ops_price_fix_b2.sku_list l
             WHERE l.bk_round = v_round AND l.cls = 'B'
               AND NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                                AND l.sku_code = 'G03061-02' AND p.price = 109
                                AND p.effective_from >= (TIMESTAMP '2026-10-05 21:47' AT TIME ZONE 'Asia/Taipei')
                                AND p.effective_from <  (TIMESTAMP '2026-10-05 21:48' AT TIME ZONE 'Asia/Taipei')));
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】B 類 % 的價格跟 10/7 盤點時不一樣（盤點時：109 元、2026-10-05 21:47 起）：盤點後有人動過這個商品的價。什麼都沒改，請截圖給 CEO。', v_msg;
  END IF;
  -- B 類：九月、十月（到現在）還是沒有任何帳（10/7 盤點時 0 筆；做法是照「沒有帳」定的）
  v_msg := (SELECT string_agg(l.sku_code || ' ' || x.n || ' 筆', '、' ORDER BY l.sku_code) FROM ops_price_fix_b2.sku_list l
             CROSS JOIN LATERAL (SELECT COUNT(*) AS n FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, c_sep, now()) li
                                  WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND li.sku_id = l.sku_id) x
             WHERE l.bk_round = v_round AND l.cls = 'B' AND x.n > 0);
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】B 類九月十月已經有帳了（盤點時 0 筆）：%。什麼都沒改，請截圖給 CEO。', v_msg;
  END IF;
  v_msg := '';

  v_pay_before := (SELECT COALESCE(SUM(payable_amount), 0) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = c_month);
  v_oct_sms_before := (SELECT COUNT(*) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = DATE '2026-10-01');

  -- ── 5. 作廢人工調整（預設空＝不作廢）──
  FOREACH v_id IN ARRAY p_void_ids LOOP
    IF NOT EXISTS (SELECT 1 FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa' AND b.pk = v_id AND b.j ->> 'status' = 'active') THEN
      RAISE EXCEPTION '【停】要作廢的調整 ID % 不是「九月、包子媽、有效」的調整。什麼都沒改。', v_id;
    END IF;
    PERFORM public.rpc_void_settlement_adjustment(v_id, p_operator, p_void_reason);   -- 20260801000000:160-224
  END LOOP;

  -- ── 6. 改價 ──
  -- A 類：從 9/1 00:00（台北）起開正確價；9/1 當下在用的版本由函式自動截到 9/1（20260422120001:486-497）
  FOR r IN SELECT * FROM ops_price_fix_b2.sku_list WHERE bk_round = v_round AND cls = 'A' ORDER BY sku_code LOOP
    PERFORM public.rpc_upsert_price(v_tenant, r.sku_id, 'branch', NULL, r.correct_price, c_sep, c_reason, p_operator);
  END LOOP;
  -- B 類：刪掉那唯一一個錯價版本（原樣在備份），再用改價函式「從它原本的開始時間」重開正確價。
  --   為什麼不直接呼叫改價函式：同一個開始時間的話，函式會把舊版本的結束日設成跟開始日一樣，
  --   違反價格表「結束日必須晚於開始日」的規則（20260422120001:176），整筆會失敗；
  --   改用更晚的時間又會留下一段錯價。刪掉再重開＝不重疊、不留空窗，還原檔整批放回備份（含原本的 id）就能精確恢復。
  FOR r IN SELECT * FROM ops_price_fix_b2.sku_list WHERE bk_round = v_round AND cls = 'B' ORDER BY sku_code LOOP
    v_id   := (SELECT p.id FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = r.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL);
    v_from := (SELECT p.effective_from FROM public.prices p WHERE p.id = v_id);
    DELETE FROM public.prices WHERE id = v_id;
    PERFORM public.rpc_upsert_price(v_tenant, r.sku_id, 'branch', NULL, r.correct_price, v_from, c_reason_b, p_operator);
  END LOOP;

  -- ── 7. 同一次裡重產九月月結（⛔ 只有九月；十月不產生）──
  v_gen := public.rpc_generate_hq_to_store_settlement(c_month, p_operator);
  v_pay_after := (SELECT COALESCE(SUM(payable_amount), 0) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = c_month);

  -- ── 8. 自我驗算（任何一項不對 → 整筆取消）──
  -- 8-1 A 類價格版本：9/1 之後只剩一個版本、從 9/1 開始、沒有結束日、就是正確價；9/1 當下與現在查價＝正確價
  v_msg := (SELECT string_agg(l.sku_code, '、') FROM ops_price_fix_b2.sku_list l
             WHERE l.bk_round = v_round AND l.cls = 'A'
               AND ( (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                        AND (p.effective_to IS NULL OR p.effective_to > c_sep)) <> 1
                  OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                        AND p.effective_from = c_sep AND p.effective_to IS NULL AND p.price = l.correct_price)
                  OR public._branch_price_at(v_tenant, l.sku_id, c_sep) IS DISTINCT FROM l.correct_price
                  OR public._branch_price_at(v_tenant, l.sku_id, now()) IS DISTINCT FROM l.correct_price));
  IF v_msg IS NOT NULL THEN RAISE EXCEPTION '【停】改價後這些 A 類品號的版本不對：%。已全部取消。', v_msg; END IF;
  -- 8-1b B 類價格版本：只有一個版本、開始時間＝備份裡原本那個版本的開始時間、沒有結束日、正確價、記在操作人名下
  v_msg := (SELECT string_agg(l.sku_code, '、') FROM ops_price_fix_b2.sku_list l
             WHERE l.bk_round = v_round AND l.cls = 'B'
               AND ( (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL) <> 1
                  OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = l.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                        AND p.effective_to IS NULL AND p.price = l.correct_price AND p.created_by = p_operator
                        AND p.effective_from = (SELECT (b.j ->> 'effective_from')::timestamptz FROM ops_price_fix_b2.bk_rows b
                                                 WHERE b.bk_round = v_round AND b.tbl = 'prices' AND (b.j ->> 'sku_id')::bigint = l.sku_id AND b.j ->> 'scope_id' IS NULL))
                  OR public._branch_price_at(v_tenant, l.sku_id, now()) IS DISTINCT FROM l.correct_price));
  IF v_msg IS NOT NULL THEN RAISE EXCEPTION '【停】改價後這些 B 類品號的版本不對：%。已全部取消。', v_msg; END IF;
  -- 8-2 九月每一筆帳（店家每日對帳）單價＝正確價
  v_cnt := (SELECT COUNT(*) FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) x JOIN ops_price_fix_b2.sku_list l ON l.bk_round = v_round AND l.sku_id = x.sku_id
             WHERE x.unit_price <> l.correct_price);
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】改價後九月還有 % 筆帳不是正確價。已全部取消。', v_cnt; END IF;
  -- 8-2b 十月（10/1 00:00 台北 ～ 現在）每一筆帳單價＝正確價（派車／店轉店／退貨差額＝0）
  v_oct_lines := (SELECT COUNT(*) FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, c_oct, now()) l
                   WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out')
                     AND l.sku_id IN (SELECT l2.sku_id FROM ops_price_fix_b2.sku_list l2 WHERE l2.bk_round = v_round));
  v_cnt := (SELECT COUNT(*) FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, c_oct, now()) l
              JOIN ops_price_fix_b2.sku_list sl ON sl.bk_round = v_round AND sl.sku_id = l.sku_id
             WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out')
               AND l.unit_branch_price <> sl.correct_price);
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】改價後十月還有 % 筆帳不是正確價。已全部取消。', v_cnt; END IF;
  -- 8-3 九月月結明細單價＝正確價
  v_cnt := (SELECT COUNT(*) FROM public.store_monthly_settlement_items i
              JOIN public.store_monthly_settlements m ON m.id = i.settlement_id
              JOIN ops_price_fix_b2.sku_list l ON l.bk_round = v_round AND l.sku_id = i.sku_id
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
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) x)
               EXCEPT (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.aug_lines WHERE bk_round = v_round))
              UNION ALL
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.aug_lines WHERE bk_round = v_round)
               EXCEPT (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) x))) d);
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】改價後八月有 % 筆（兩邊合計）跟備份時不一樣。已全部取消，請截圖給 CEO。', v_cnt; END IF;
  -- 8-6 原本的草稿都還在、還是草稿
  v_cnt := (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows b
             WHERE b.bk_round = v_round AND b.tbl = 'sms'
               AND NOT EXISTS (SELECT 1 FROM public.store_monthly_settlements m WHERE m.id = b.pk AND m.status = 'draft'));
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】重產後有 % 張原本的草稿不見了或不是草稿。已全部取消，請截圖給 CEO。', v_cnt; END IF;
  -- 8-7 指定的調整都作廢了
  v_cnt := (SELECT COUNT(*) FROM unnest(p_void_ids) x(id)
             WHERE NOT EXISTS (SELECT 1 FROM public.store_settlement_adjustments a WHERE a.id = x.id AND a.status = 'voided'));
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】有 % 筆指定的調整沒有作廢成功。已全部取消。', v_cnt; END IF;
  -- 8-8 沒有產生十月月結（張數跟修正前一樣）
  v_oct_sms_after := (SELECT COUNT(*) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = DATE '2026-10-01');
  IF v_oct_sms_after <> v_oct_sms_before THEN
    RAISE EXCEPTION '【停】十月月結張數變了（% → %），這份不該產生十月月結。已全部取消，請截圖給 CEO。', v_oct_sms_before, v_oct_sms_after;
  END IF;

  -- ── 9. 留紀錄＋存「改完之後的樣子」（還原要用）──
  v_fix := COALESCE((SELECT MAX(fix_id) FROM ops_price_fix_b2.fix_log), 0) + 1;
  v_created := COALESCE((SELECT jsonb_agg(jsonb_build_object('settlement_id', m.id, 'store', s.code) ORDER BY s.code)
                           FROM public.store_monthly_settlements m JOIN public.stores s ON s.id = m.store_id
                          WHERE m.tenant_id = v_tenant AND m.settlement_month = c_month
                            AND NOT EXISTS (SELECT 1 FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms' AND b.pk = m.id)), '[]'::jsonb);
  INSERT INTO ops_price_fix_b2.fix_log (fix_id, bk_round, operator, void_ids, gen_result, summary)
  VALUES (v_fix, v_round, p_operator, p_void_ids, v_gen, jsonb_build_object(
    '01 修正編號（這一批自己的編號）', v_fix,
    '02 用的備份輪次（ops_price_fix_b2）', v_round,
    '03 作廢的人工調整', CASE WHEN cardinality(p_void_ids) = 0 THEN '（沒有作廢任何一筆：p_void_ids 是空的）'
                              ELSE array_to_string(p_void_ids, '、') END,
    '04 改價', 'A 類 ' || (SELECT COUNT(*) FROM ops_price_fix_b2.sku_list WHERE bk_round = v_round AND cls = 'A') || ' 個（改價函式，2026-09-01 00:00 起）／B 類 '
               || (SELECT COUNT(*) FROM ops_price_fix_b2.sku_list WHERE bk_round = v_round AND cls = 'B') || ' 個（刪掉原本那個錯價版本、從同一個開始時間重開正確價）',
    '05 九月月結應收合計', trim_scale(v_pay_before) || ' → ' || trim_scale(v_pay_after),
    '05b 十月（不產生月結）', '這一批品號十月到現在 ' || v_oct_lines || ' 筆帳，單價全部＝正確價；十月月結修正前 ' || v_oct_sms_before || ' 張、修正後 ' || v_oct_sms_after || ' 張（沒有產生）',
    '06 本次新建的九月月結', CASE WHEN jsonb_array_length(v_created) = 0 THEN '（沒有）'
                                  ELSE (SELECT string_agg(e ->> 'store', '、') FROM jsonb_array_elements(v_created) e) END,
    '06b 新建月結 ID', v_created,
    '07 自我驗算', '✅ A 類版本／B 類版本／九月逐筆單價／十月逐筆單價／九月月結明細／貨款＝每日對帳／八月逐筆不變／原草稿仍在／調整作廢／沒有產生十月月結，全部通過',
    '08 操作人', p_operator::text));
  INSERT INTO ops_price_fix_b2.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'prices', x.pk, x.j FROM (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) x;
  INSERT INTO ops_price_fix_b2.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'sms', x.pk, x.j FROM (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01') x;
  INSERT INTO ops_price_fix_b2.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'smsi', x.pk, x.j FROM (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x;
  INSERT INTO ops_price_fix_b2.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'ssa', x.pk, x.j FROM (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01') x;
  INSERT INTO ops_price_fix_b2.after_rows (fix_id, tbl, pk, j) SELECT v_fix, 'ssd', x.pk, x.j FROM (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x;
  INSERT INTO ops_price_fix_b2.after_sept_lines (fix_id, store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount)
  SELECT v_fix, x.* FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL ) x;
  -- 十月只存這一批品號（還原只會改這些品號的價；其他品號十月的帳還原前後都不會變）
  INSERT INTO ops_price_fix_b2.after_oct_lines (fix_id, store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount)
  SELECT v_fix, x.* FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, c_oct, now()) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id IN (SELECT l2.sku_id FROM ops_price_fix_b2.sku_list l2 WHERE l2.bk_round = v_round)) x;
END $fix$;

-- 結果
SELECT key AS "項目", value AS "內容"
  FROM ops_price_fix_b2.fix_log f, jsonb_each_text(f.summary)
 WHERE f.fix_id = (SELECT MAX(fix_id) FROM ops_price_fix_b2.fix_log)
 ORDER BY key;

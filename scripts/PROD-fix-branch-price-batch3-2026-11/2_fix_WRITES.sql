-- ============================================================================
--  第三批分店價往回改（蛋小白雞蛋金磚 G02907-01） 2　修正
--  ⛔ 會寫入（改分店價版本＋重產十月月結草稿，全部在同一次裡）
--  日期：2026-11-02　阿寫寫、⛔ 還沒經阿審（Codex）審過之前不要貼
--  依據：派工單-蛋小白分店價往回改_第三批_2026-11-02.md（老闆 11/2 已點頭的做法）
--  範本：第二批 scripts/PROD-fix-branch-price-batch2-2026-10/2_fix_WRITES.sql（10/7 起在正式系統跑過）；
--        上鎖順序、NOWAIT、鎖後才比對備份、B 類「刪版本再用改價函式重開」、自我驗算、存「改完的樣子」照抄。
--        【改寫處】①清單 94 規格 → 事實段（單一規格、三個價格版本逐一核對）
--                  ②月份條件相反：第二批「十月有任何月結就停、只重產九月」→ 這批「十月月結必須全是草稿、重產十月」
--                  ③月結產生器只能整月重產（20260907030000:689-692、:761-766）→ 多一個參數 p_mode 讓 CEO 選方案甲／乙
--                  ④人工調整：第二批可指定作廢 → 這批⛔一筆都不作廢，重產後逐欄比對原樣還在
--                  ⑤自我驗算改寫：每家店差額＝預期（11 家、合計 −836）、蛋小白以外逐行不變、其他店依方案比對、
--                     十月以外每一個月份逐列一字不變、價格版本鏈 62→42 接續
--                  ⑥備份與修正紀錄放這一批自己的位置 ops_price_fix_b3（前兩批的位置一個字都不碰）
--  程式出處：工程紀錄本 origin/main bafc13d9 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼（全部在「同一次」裡，任何一步不對就整筆取消、什麼都沒改）
--    ①先上鎖（整張表）：月結表頭／明細／爭議、人工調整、價格表、派車單與明細、店家資料
--      → 貼的這段時間：月結頁面連「看」都要等；「產生月結、確認月結、加／作廢調整、改價、派車、收貨、退貨、店轉店」都要排隊等這份做完
--      → ⛔ 這份「不排隊」：任何一把鎖拿不到就立刻停下、什麼都沒改（紅字寫「有人正在使用…」），過幾分鐘再貼
--      → 上鎖順序（跟第 4 份還原一模一樣）：①月結表頭 ②月結明細 ③月結爭議 ④人工調整 ⑤價格 ⑥派車單 ⑦派車明細 ⑧店家
--        ⑨十月月份鎖 ⑩十月月結各列 ⑪這個規格的價格各列 ⑫十月人工調整各列
--    ②鎖住之後才檢查（任何一項不對 → 整筆停）：
--        ・現在的資料跟「最新一輪備份」一模一樣（價格版本、十月月結表頭／明細／爭議／調整、十月以外每個月份、蛋小白 8/1～10/1 每一筆）
--        ・十月月結每一張都還是草稿（有一張已送店家／有異議／已確認／作廢就停）
--        ・三個分店價版本跟 11/2 盤點一樣：62（9/28 18:51:00 起）→ 64（10/5 16:38:51 起）→ 42（11/2 11:21:03 起、老闆帳號建的、現在有效），前後剛好接上
--        ・十月有效人工調整還是那 6 筆（#56 −232、#57 +232、#58 −19、#59 −249、#60 +249、#62 −216，合計 −235）
--        ・蛋小白落在 64 那段的帳：11 家店、12 筆、計價數量 38、改價後合計 −836，各店差額跟盤點一樣；十一月 1～2 日沒有蛋小白的帳
--    ③改價：把 64（26805）和 42（33876）兩個版本刪掉（原樣在備份），再用系統改價函式 rpc_upsert_price
--        從「64 那段原本的開始時間」（2026-10-05 16:38:51）重開「42、沒有結束日」（20260422120001:473-502）。
--        62 那段（24666）的結束時間本來就等於這個時間點，函式不會動它（:486-492 只截「結束日晚於新開始日」的版本）。
--        為什麼不直接呼叫改價函式：64 那段會被截成「開始＝結束」，價格表不允許（20260422120001:176 CHECK）、42 那段又是更晚的版本
--        → 整筆失敗（機制索引 2658、2718 行）；這跟第二批 B 類同一個做法。
--    ④同一次裡叫月結產生器重產 2026 年 10 月（rpc_generate_hq_to_store_settlement）。
--        ⚠ 產生器沒有「只算某幾家店」的參數，一叫就是十月全部店（20260907030000:761-766），所以下面 p_mode 要選：
--        ・方案甲（填 '甲'）：重產完，「沒有蛋小白帳的店」一律蓋回備份原樣（表頭每一欄含最後異動時間、明細每一行含編號、爭議）。
--            結果＝真的只有 11 家店變；其他店就算「本來重產就會變」（0-D 第 7500 項 ⚠），這次也不變，留到下次正常重產才出現。
--        ・方案乙（填 '乙'）：整個月照產生器的結果；但其他店只要有任何一分錢、任何一行、張數跟備份不一樣，就整筆停。
--            通過的話，其他店只有「最後異動時間／異動人」和「明細內部編號」會變，金額一分不差。
--        兩案對那 11 家店的結果完全相同；人工調整兩案都一筆不動。
--    ⑤自己驗算，全部過了才算數（任何一項不對 → 整筆取消）：
--        ・價格：62 那段一個字沒變；42 從 10/5 16:38:51 起、沒有結束日、記在操作人名下；那一刻前一微秒查價＝62、那一刻起＝42、現在＝42
--        ・11 家店：月結還是同一張、還是草稿；應收與分店價合計的變化＝預期差額（合計 −836）；成本、調整、張數、筆數不變；
--          蛋小白以外的明細逐行不變；蛋小白落在 64 那段的明細單價＝42
--        ・其他店：方案甲逐欄＝備份；方案乙金額、明細逐行＝備份
--        ・十月人工調整、爭議逐欄＝備份（6 筆調整原樣還在、還是有效）
--        ・十月以外每一個月份的月結表頭／明細／調整／爭議逐列＝備份（八月、九月一個字沒變）；蛋小白 8/1～10/1 每一筆＝備份
--    ⑥把「改完之後的樣子」也存一份（第 4 份還原要用它確認沒有人後來又動過）
--  ★ 要填的：下面 DECLARE 裡的兩行（CEO 在老闆確認後填）
--    p_operator：0-D 查到、老闆確認過的「老闆本人」UUID。⛔ 交件時刻意留空；空的、或不是包子媽的總部帳號，都會直接停。
--    p_mode：'甲' 或 '乙'（CEO 裁決後填）。⛔ 交件時刻意留空；空的或填別的字，都會直接停。
--  ★ 貼了會怎樣：那 11 家店的十月草稿馬上變成 42 元算的數字；每日對帳也是；之後再派蛋小白一樣是 42。
--  ★ 貼的時候 Supabase 可能跳出「destructive operation（破壞性操作）」提醒（因為要刪 2 個價格版本；方案甲還要刪掉再放回其他店的草稿）
--    → 確認貼的是「第三批 2修正」這份、兩個參數都填好了，再按執行（⚠ 按鈕文字以實際畫面為準）。
--  ★ 看到什麼要停：
--    ・紅字開頭是【停】→ 什麼都沒改，截圖給 CEO（紅字會寫是哪一項不對）
--    ・紅字寫「有人正在使用月結／派車／價格」（或 lock timeout）→ 什麼都沒改，過幾分鐘再貼；連續兩三次都這樣，截圖給 CEO
--  ★ 做錯了怎麼辦：第 4 份還原（只要修正之後沒有人再動過這些資料，就能一欄不差地蓋回去；只還原這一批）。
--    ⚠ 恢復派車收貨之後就不能自動還原，所以貼完要「馬上」貼第 3 份驗算。
-- ============================================================================

DO $fix$
DECLARE
  -- ╔════════ 要填的兩行（CEO 在老闆確認後填）════════╗
  p_operator  uuid := NULL;   -- ⬅ 操作人：0-D 查到、老闆確認過的本人 UUID，例如 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'；⛔ 空的會直接停
  p_mode      text := NULL;   -- ⬅ 方案：'甲'（其他店蓋回原樣）或 '乙'（整月採用、其他店必須一分不差）；⛔ 空的會直接停
  -- ╚════════════════════════════════════════════════╝
  c_reason    text := '2026-11-02 第三批分店價往回改：蛋小白雞蛋金磚分店價 42，從 10/05 請購單核准蓋成 64 的那一刻起（老闆 11/2 確認）';
  f record;
  v_step text; v_tenant uuid; v_cnt int; v_round int; v_fix int; v_gen jsonb; v_msg text := '';
  v_from timestamptz; v_to timestamptz; v_new_id bigint;
  v_pay_before numeric; v_pay_after numeric; v_targets bigint[];
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  -- ── 0. 參數與事實段（這一段不讀任何資料表）──
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '【停】操作人 p_operator 是空的。要由 CEO 把老闆確認過的本人 UUID 填進去再貼。什麼都沒改。';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('甲', '乙') THEN
    RAISE EXCEPTION '【停】方案 p_mode 要填 ''甲'' 或 ''乙''（現在是 %）。由 CEO 裁決後填。什麼都沒改。', COALESCE(p_mode, '空的');
  END IF;
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
         ARRAY[-249,-232,-216,-19,232,249]::numeric[] AS exp_adj
  -- ▲▲▲ 事實段結束 ▲▲▲
  ) x;

  -- 表級鎖（在讀任何月結／價格／調整狀態之前）——一律 NOWAIT：拿不到就立刻放棄，⛔ 不排隊
  --   為什麼不排隊：排隊等鎖時，已經開始的產生器／確認月結（先讀月結表、後寫）或估價修正（先改 transfer_items、
  --   再呼叫產生器，順序跟我們相反）會跟我們互等（死鎖）。所以任何一把拿不到，整份立刻取消、什麼都沒改，請人稍後再貼。
  --   取得順序（2修正、4還原一模一樣；同第二批）：
  --     ①月結表頭 ACCESS EXCLUSIVE（別人連看都要等；正式系統的 9/01 版產生器沒有月份鎖、先讀後寫，只擋寫會讓它把舊價寫回去）
  --     ②月結明細 ③月結爭議 ④人工調整 ⑤價格：SHARE ROW EXCLUSIVE（別人可以看，不能新增／修改／刪除）
  --     ⑥派車單 ⑦派車明細 ⑧店家：SHARE（別人可以看，不能新增／修改：派車、收貨、退貨、店轉店都要等；
  --        店家每日對帳 _store_inbound_lines，20260901000000:597-742，只讀這幾張加價格表，鎖住後數字不會變）
  --     ※ 沒有鎖 stock_movements（出庫成本異動）：並行改成本的人不會讓這次立刻停；成本同步靠修正檔後置的逐欄驗算攔截（有差就整筆取消）
  --     ⑨月份鎖（advisory，try 版）⑩十月月結各列 ⑪價格各列 ⑫十月人工調整各列（FOR UPDATE NOWAIT，雙保險）
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

  -- ── 1. 公司、店家、操作人、規格 ──
  v_cnt := (SELECT COUNT(*) FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】系統裡叫「包子媽生鮮小舖」的公司有 % 家（要剛好 1 家）。什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;
  v_tenant := (SELECT t.id FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  -- 月結產生器用「stores 第一筆」認公司（20260907030000:750）→ 有別家公司的店就不能讓它自動重產
  IF (SELECT COUNT(DISTINCT s.tenant_id) FROM public.stores s) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.stores s WHERE s.tenant_id = v_tenant) THEN
    RAISE EXCEPTION '【停】店家資料裡不只一家公司（或沒有包子媽的店），月結產生器會認錯公司。什麼都沒改，請截圖給 CEO。';
  END IF;
  -- 操作人要是包子媽的總部帳號：公司看 app_metadata.tenant_id（20260707000000:61-69 同一欄），
  -- 總部角色照 _settlement_caller_is_hq()（20260715000120:132-137）：空白／owner／admin／hq_manager／hq_accountant
  IF NOT EXISTS (SELECT 1 FROM auth.users u
                  WHERE u.id = p_operator
                    AND (u.raw_app_meta_data ->> 'tenant_id') = v_tenant::text
                    AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')) THEN
    RAISE EXCEPTION '【停】操作人 % 不是包子媽生鮮小舖的總部帳號（或根本不是登入帳號）。請用 0-D 列出、老闆確認過的本人 UUID。什麼都沒改。', p_operator;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.skus s WHERE s.tenant_id = v_tenant AND s.id = f.sku_id AND s.sku_code = f.sku_code AND s.product_id = f.product_id)
     OR (SELECT COUNT(*) FROM public.skus s WHERE s.tenant_id = v_tenant AND s.sku_code = f.sku_code) <> 1 THEN
    RAISE EXCEPTION '【停】品號 % 對不到規格 %／商品 %。什麼都沒改，請截圖給 CEO。', f.sku_code, f.sku_id, f.product_id;
  END IF;

  -- ── 2. 備份輪次（這一批自己的位置 ops_price_fix_b3；前兩批的位置不讀不碰）──
  IF to_regclass('ops_price_fix_b3.fix_log') IS NULL THEN
    RAISE EXCEPTION '【停】還沒有這一批的備份（找不到 ops_price_fix_b3）。請先貼第 1 份（備份）。什麼都沒改。';
  END IF;
  v_round := (SELECT MAX(bk_round) FROM ops_price_fix_b3.rounds WHERE tenant_id = v_tenant);
  IF v_round IS NULL THEN
    RAISE EXCEPTION '【停】還沒有這一批的備份。請先貼第 1 份（備份）。什麼都沒改。';
  END IF;
  IF EXISTS (SELECT 1 FROM ops_price_fix_b3.fix_log WHERE restored_at IS NULL) THEN
    RAISE EXCEPTION '【停】這一批已經修正過一次、而且還沒還原（第 % 次修正）。不能重複修正。什麼都沒改。',
      (SELECT MAX(fix_id) FROM ops_price_fix_b3.fix_log WHERE restored_at IS NULL);
  END IF;

  -- ── 3. 月份鎖與列鎖（表級鎖已在最前面拿到；一樣 NOWAIT，順序同還原檔）──
  -- 月份鎖：與月結產生器 9/07 版、退貨更正同一把（20260907030000:757-759）；同一個交易再拿一次不會卡自己
  BEGIN
    v_step := '⑨十月月份鎖';
    IF NOT pg_try_advisory_xact_lock(hashtext('settlement:' || v_tenant::text || ':' || f.oct::text)) THEN
      RAISE EXCEPTION USING ERRCODE = 'lock_not_available';
    END IF;
    v_step := '⑩十月月結各列';
    PERFORM 1 FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = f.oct FOR UPDATE NOWAIT;
    v_step := '⑪價格各列';
    PERFORM 1 FROM public.prices WHERE tenant_id = v_tenant AND scope = 'branch' AND sku_id = f.sku_id FOR UPDATE NOWAIT;
    v_step := '⑫十月人工調整各列';
    PERFORM 1 FROM public.store_settlement_adjustments WHERE tenant_id = v_tenant AND settlement_month = f.oct FOR UPDATE NOWAIT;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION '【停】有人正在使用月結／派車／價格（第 % 步「鎖」拿不到），這次什麼都沒改。請先確認沒有人在後台操作、倉庫沒在派車收貨，過幾分鐘再貼一次；連續兩三次都失敗，請截圖給 CEO。', v_step;
  END;

  -- ── 4. 鎖住之後才比對：現在＝最新一輪備份（不一樣就是備份之後有人動過 → 停）──
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices') EXCEPT (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id))) d);
  IF v_cnt > 0 THEN v_msg := v_msg || '分店價版本有 ' || v_cnt || ' 筆不一樣；'; END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms') EXCEPT (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct))) d);
  IF v_cnt > 0 THEN v_msg := v_msg || '十月月結表頭有 ' || v_cnt || ' 筆不一樣；'; END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'smsi'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'smsi') EXCEPT (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)))) d);
  IF v_cnt > 0 THEN v_msg := v_msg || '十月月結明細有 ' || v_cnt || ' 筆不一樣；'; END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd') EXCEPT (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)))) d);
  IF v_cnt > 0 THEN v_msg := v_msg || '十月月結爭議有 ' || v_cnt || ' 筆不一樣；'; END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa') EXCEPT (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct))) d);
  IF v_cnt > 0 THEN v_msg := v_msg || '十月人工調整有 ' || v_cnt || ' 筆不一樣；'; END IF;
  IF v_msg <> '' THEN
    RAISE EXCEPTION '【停】現在的資料跟第 % 輪備份不一樣：%。什麼都沒改。請重貼第 1 份（備份）再來，或截圖給 CEO。', v_round, v_msg;
  END IF;

  -- ── 4b. 改價之前，事實再核對一次（跟 0-D 同樣條件；任何一項不對 → 整筆停）──
  -- 十月月結每一張都要是草稿（已送店家的店家可能看過舊數字；已確認的產生器會整店跳過，20260907030000:767-776）
  v_msg := (SELECT string_agg(s.code || '＝' || m.status, '、' ORDER BY s.code) FROM public.store_monthly_settlements m JOIN public.stores s ON s.id = m.store_id
             WHERE m.tenant_id = v_tenant AND m.settlement_month = f.oct AND m.status <> 'draft');
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】十月月結有店已經不是草稿：%。什麼都沒改，請截圖給 CEO。', v_msg;
  END IF;
  -- 三個分店價版本跟 11/2 盤點一樣、前後剛好接上、沒有第四個全店共用版本
  IF (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = f.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL) <> 3
     OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.id = f.id_a AND p.tenant_id = v_tenant AND p.sku_id = f.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                      AND p.price = f.price_a AND p.effective_from >= f.a_from_sec AND p.effective_from < f.a_from_sec + interval '1 second')
     OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.id = f.id_b AND p.tenant_id = v_tenant AND p.sku_id = f.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                      AND p.price = f.price_b AND p.effective_from >= f.b_from_sec AND p.effective_from < f.b_from_sec + interval '1 second')
     OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.id = f.id_c AND p.tenant_id = v_tenant AND p.sku_id = f.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                      AND p.price = f.price_new AND p.effective_to IS NULL AND p.created_by = f.c_by
                      AND p.effective_from >= f.c_from_sec AND p.effective_from < f.c_from_sec + interval '1 second')
     OR (SELECT effective_to FROM public.prices WHERE id = f.id_a) IS DISTINCT FROM (SELECT effective_from FROM public.prices WHERE id = f.id_b)
     OR (SELECT effective_to FROM public.prices WHERE id = f.id_b) IS DISTINCT FROM (SELECT effective_from FROM public.prices WHERE id = f.id_c) THEN
    RAISE EXCEPTION '【停】G02907-01 的分店價版本跟 11/2 盤點不一樣（盤點：24666＝62 從 9/28 18:51:00、26805＝64 從 10/5 16:38:51、33876＝42 從 11/2 11:21:03 現在有效，前後接上）。什麼都沒改，請截圖給 CEO。';
  END IF;
  v_from := (SELECT effective_from FROM public.prices WHERE id = f.id_b);   -- 64 那段原本的開始時間（含秒以下）
  v_to   := (SELECT effective_from FROM public.prices WHERE id = f.id_c);   -- 42 那段原本的開始時間
  -- 十月有效人工調整還是那 6 筆、逐筆金額排序後相等（⛔ 不作廢；重產後逐欄比對原樣還在）
  IF (SELECT COALESCE(array_agg(a.amount ORDER BY a.amount), ARRAY[]::numeric[]) FROM public.store_settlement_adjustments a
       WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct AND a.status = 'active') <> f.exp_adj THEN
    RAISE EXCEPTION '【停】十月有效人工調整跟 11/2 盤點不一樣（盤點：6 筆（#56 −232、#57 +232、#58 −19、#59 −249、#60 +249、#62 −216，合計 −235））。什麼都沒改，請截圖給 CEO。';
  END IF;
  -- 十一月 1～2 日（到 42 那段開始前）不可以有蛋小白的帳：那段也會被改價影響，但不在修正範圍
  v_cnt := (SELECT COUNT(*) FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.nov_from, GREATEST(v_to, f.nov_from)) l
             WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】十一月 1～2 日有 % 筆蛋小白的帳（盤點時 0 筆），不在這次修正範圍。什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;

  -- 每家「十月有蛋小白帳」的店：預期差額（落在 64 那段的帳 ×（42 − 現在單價），正負號照月結明細）
  v_fix := COALESCE((SELECT MAX(fix_id) FROM ops_price_fix_b3.fix_log), 0) + 1;
  INSERT INTO ops_price_fix_b3.fix_targets (fix_id, store_id, settlement_id, n_lines, net_qty, delta, pay_before)
  SELECT v_fix, e.store_id,
         (SELECT m.id FROM public.store_monthly_settlements m WHERE m.tenant_id = v_tenant AND m.settlement_month = f.oct AND m.store_id = e.store_id),
         COUNT(*) FILTER (WHERE e.in_win),
         COALESCE(SUM(e.sqty) FILTER (WHERE e.in_win), 0),
         COALESCE(SUM(e.sqty * (f.price_new - e.unit_branch_price)) FILTER (WHERE e.in_win), 0),
         (SELECT m.payable_amount FROM public.store_monthly_settlements m WHERE m.tenant_id = v_tenant AND m.settlement_month = f.oct AND m.store_id = e.store_id)
    FROM (SELECT st.id AS store_id, l.unit_branch_price,
                 CASE WHEN l.entry_type IN ('air_out','return_out') THEN -1 ELSE 1 END * l.qty AS sqty,
                 (l.received_at >= v_from AND l.received_at < v_to) AS in_win
            FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.oct_from, f.nov_from) l
           WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id
             AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out')) e
   GROUP BY e.store_id;
  IF (SELECT COUNT(*) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix) <> f.exp_n_store
     OR (SELECT SUM(n_lines) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix) <> f.exp_n_lines
     OR (SELECT SUM(net_qty) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix) <> f.exp_net_qty
     OR (SELECT SUM(delta) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix) <> f.exp_delta
     OR (SELECT array_agg(delta ORDER BY delta) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix) <> f.exp_deltas THEN
    RAISE EXCEPTION '【停】蛋小白十月的帳跟 11/2 盤點不一樣：現在 % 家店、% 筆、計價數量 %、差額 %（盤點：11 家、12 筆、38、−836）。什麼都沒改，請截圖給 CEO。',
      (SELECT COUNT(*) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix), (SELECT SUM(n_lines) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix),
      (SELECT trim_scale(SUM(net_qty)) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix), (SELECT trim_scale(SUM(delta)) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix);
  END IF;
  v_msg := (SELECT string_agg(s.code, '、' ORDER BY s.code) FROM ops_price_fix_b3.fix_targets t JOIN public.stores s ON s.id = t.store_id
             WHERE t.fix_id = v_fix AND t.settlement_id IS NULL);
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】這些有蛋小白帳的店還沒有十月月結草稿：%（盤點時 11 家都有）。什麼都沒改，請截圖給 CEO。', v_msg;
  END IF;
  v_targets := (SELECT array_agg(store_id ORDER BY store_id) FROM ops_price_fix_b3.fix_targets WHERE fix_id = v_fix);
  v_pay_before := (SELECT COALESCE(SUM(payable_amount), 0) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = f.oct);
  v_msg := '';

  -- ── 5. 改價：刪掉 64、42 兩個版本（原樣在備份），從 64 那段原本的開始時間重開 42、沒有結束日 ──
  --   62 那段（24666）結束時間＝v_from，改價函式只截「結束日晚於新開始日」的版本（20260422120001:486-492），不會動它
  DELETE FROM public.prices WHERE id IN (f.id_b, f.id_c) AND tenant_id = v_tenant AND sku_id = f.sku_id AND scope = 'branch' AND scope_id IS NULL;
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  IF v_cnt <> 2 THEN
    RAISE EXCEPTION '【停】要刪的 2 個價格版本只刪到 % 個。已全部取消，請截圖給 CEO。', v_cnt;
  END IF;
  v_new_id := public.rpc_upsert_price(v_tenant, f.sku_id, 'branch', NULL, f.price_new, v_from, c_reason, p_operator);

  -- ── 6. 同一次裡重產十月月結（產生器一次跑整個月、全部店；月結函式 20260907030000:689-1172；upsert :968-991、刪舊明細 :994、重建 :1000-1154）──
  v_gen := public.rpc_generate_hq_to_store_settlement(f.oct, p_operator);

  -- ── 6b. 方案甲：沒有蛋小白帳的店，十月表頭／明細／爭議一律蓋回備份原樣 ──
  --   刪掉再原樣放回（含原本的 id、最後異動時間）；放回是 INSERT，不會觸發「自動蓋最後異動時間」（trg_touch_sms 只掛 BEFORE UPDATE，20260512000009:84）；
  --   另外交易內設 app.skip_updated_at='1' 雙保險（20260611000010:12-21）。明細、爭議跟著表頭 ON DELETE CASCADE（20260512000009:67、20260715000120:87）。
  --   草稿明細可以刪（保護觸發器只擋已確認／已結清，20260512000013:15-48）。
  IF p_mode = '甲' THEN
    PERFORM set_config('app.skip_updated_at', '1', true);
    DELETE FROM public.store_monthly_settlements
     WHERE tenant_id = v_tenant AND settlement_month = f.oct AND status = 'draft' AND NOT (store_id = ANY (v_targets));
    INSERT INTO public.store_monthly_settlements
    SELECT (jsonb_populate_record(NULL::public.store_monthly_settlements, b.j)).*
      FROM ops_price_fix_b3.bk_rows b
     WHERE b.bk_round = v_round AND b.tbl = 'sms' AND NOT ((b.j ->> 'store_id')::bigint = ANY (v_targets))
     ORDER BY b.pk;
    INSERT INTO public.store_monthly_settlement_items
    SELECT (jsonb_populate_record(NULL::public.store_monthly_settlement_items, b.j)).*
      FROM ops_price_fix_b3.bk_rows b
     WHERE b.bk_round = v_round AND b.tbl = 'smsi'
       AND (b.j ->> 'settlement_id')::bigint IN (SELECT h.pk FROM ops_price_fix_b3.bk_rows h
                                                  WHERE h.bk_round = v_round AND h.tbl = 'sms' AND NOT ((h.j ->> 'store_id')::bigint = ANY (v_targets)))
     ORDER BY b.pk;
    INSERT INTO public.store_settlement_disputes
    SELECT (jsonb_populate_record(NULL::public.store_settlement_disputes, b.j)).*
      FROM ops_price_fix_b3.bk_rows b
     WHERE b.bk_round = v_round AND b.tbl = 'ssd'
       AND (b.j ->> 'settlement_id')::bigint IN (SELECT h.pk FROM ops_price_fix_b3.bk_rows h
                                                  WHERE h.bk_round = v_round AND h.tbl = 'sms' AND NOT ((h.j ->> 'store_id')::bigint = ANY (v_targets)))
     ORDER BY b.pk;
    PERFORM set_config('app.skip_updated_at', '0', true);
  END IF;
  v_pay_after := (SELECT COALESCE(SUM(payable_amount), 0) FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = f.oct);

  -- ── 7. 自我驗算（任何一項不對 → 整筆取消）──
  -- 7-1 價格：62 那段＝備份逐欄；指定門市的版本＝備份逐欄；全店共用只剩 2 個；新版本 42、從 v_from、沒有結束日、記在操作人名下
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id AND p.id <> v_new_id)
                 EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices' AND b.pk NOT IN (f.id_b, f.id_c)))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices' AND b.pk NOT IN (f.id_b, f.id_c))
                 EXCEPT (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id AND p.id <> v_new_id))) d);
  IF v_cnt > 0
     OR (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.sku_id = f.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL) <> 2
     OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.id = v_new_id AND p.tenant_id = v_tenant AND p.sku_id = f.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
                      AND p.price = f.price_new AND p.effective_from = v_from AND p.effective_to IS NULL AND p.created_by = p_operator AND p.reason = c_reason)
     OR (SELECT effective_to FROM public.prices WHERE id = f.id_a) IS DISTINCT FROM v_from
     OR public._branch_price_at(v_tenant, f.sku_id, v_from - interval '1 microsecond') IS DISTINCT FROM f.price_a
     OR public._branch_price_at(v_tenant, f.sku_id, v_from) IS DISTINCT FROM f.price_new
     OR public._branch_price_at(v_tenant, f.sku_id, v_to) IS DISTINCT FROM f.price_new
     OR public._branch_price_at(v_tenant, f.sku_id, now()) IS DISTINCT FROM f.price_new THEN
    RAISE EXCEPTION '【停】改價後 G02907-01 的價格版本不對（要：62 那段不變、從 10/5 16:38:51 起只剩 42 一個版本、前後接上）。已全部取消，請截圖給 CEO。';
  END IF;
  -- 7-2 十月月結：張數、每張的 id 跟備份一樣，全部還是草稿
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT s.id, s.store_id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                 EXCEPT (SELECT b.pk, (b.j ->> 'store_id')::bigint FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms'))
              UNION ALL
              ((SELECT b.pk, (b.j ->> 'store_id')::bigint FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms')
                 EXCEPT (SELECT s.id, s.store_id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct))) d);
  IF v_cnt > 0 OR EXISTS (SELECT 1 FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = f.oct AND status <> 'draft') THEN
    RAISE EXCEPTION '【停】重產後十月月結的張數／哪幾家店／狀態跟備份不一樣（% 處；方案 %：重產新建或刪掉了草稿）。已全部取消，請截圖給 CEO。', v_cnt, p_mode;
  END IF;
  -- 7-3 11 家店：應收、分店價合計的變化＝預期差額；其他欄位（成本、調整、張數、筆數、狀態、送出紀錄…）＝備份
  UPDATE ops_price_fix_b3.fix_targets t SET pay_after = m.payable_amount
    FROM public.store_monthly_settlements m WHERE t.fix_id = v_fix AND m.id = t.settlement_id;
  v_msg := (SELECT string_agg(s.code, '、' ORDER BY s.code)
              FROM ops_price_fix_b3.fix_targets t
              JOIN public.store_monthly_settlements m ON m.id = t.settlement_id
              JOIN ops_price_fix_b3.bk_rows b ON b.bk_round = v_round AND b.tbl = 'sms' AND b.pk = t.settlement_id
              JOIN public.stores s ON s.id = t.store_id
             WHERE t.fix_id = v_fix
               AND ( m.payable_amount - (b.j ->> 'payable_amount')::numeric <> t.delta
                  OR m.branch_amount  - (b.j ->> 'branch_amount')::numeric  <> t.delta
                  OR (to_jsonb(m) - 'payable_amount' - 'branch_amount' - 'updated_at' - 'updated_by')
                     <> (b.j - 'payable_amount' - 'branch_amount' - 'updated_at' - 'updated_by')));
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】重產後這些有蛋小白帳的店，月結表頭的變化不是只有蛋小白的差額：%。已全部取消，請截圖給 CEO。', v_msg;
  END IF;
  -- 7-4 11 家店的明細：蛋小白以外逐行＝備份；蛋小白落在 64 那段的行，單價變 42、金額＝正負號×數量×42，其餘欄位＝備份
  --     （比的是整行內容扣掉「明細編號、建立時間」——重產會刪掉重建，這兩欄一定會變，刪舊明細 20260907030000:994、重建 :1000-1154）
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT to_jsonb(i) - 'id' - 'created_at' AS j FROM public.store_monthly_settlement_items i
                 WHERE i.settlement_id IN (SELECT t.settlement_id FROM ops_price_fix_b3.fix_targets t WHERE t.fix_id = v_fix))
               EXCEPT ALL
               (SELECT CASE WHEN (b.j ->> 'sku_id')::bigint = f.sku_id
                             AND b.j ->> 'entry_type' IN ('hq_inbound','air_in','air_out','return_out')
                             AND (b.j ->> 'received_at')::timestamptz >= v_from AND (b.j ->> 'received_at')::timestamptz < v_to
                            THEN jsonb_set(jsonb_set(b.j, '{unit_branch_price}', to_jsonb(f.price_new::numeric(18,4))),
                                           '{branch_amount}', to_jsonb((CASE WHEN b.j ->> 'entry_type' IN ('air_out','return_out') THEN -1 ELSE 1 END
                                                                        * (b.j ->> 'qty_received')::numeric * f.price_new)::numeric(18,4)))
                            ELSE b.j END - 'id' - 'created_at'
                  FROM ops_price_fix_b3.bk_rows b
                 WHERE b.bk_round = v_round AND b.tbl = 'smsi'
                   AND (b.j ->> 'settlement_id')::bigint IN (SELECT t.settlement_id FROM ops_price_fix_b3.fix_targets t WHERE t.fix_id = v_fix)))
              UNION ALL
              ((SELECT CASE WHEN (b.j ->> 'sku_id')::bigint = f.sku_id
                             AND b.j ->> 'entry_type' IN ('hq_inbound','air_in','air_out','return_out')
                             AND (b.j ->> 'received_at')::timestamptz >= v_from AND (b.j ->> 'received_at')::timestamptz < v_to
                            THEN jsonb_set(jsonb_set(b.j, '{unit_branch_price}', to_jsonb(f.price_new::numeric(18,4))),
                                           '{branch_amount}', to_jsonb((CASE WHEN b.j ->> 'entry_type' IN ('air_out','return_out') THEN -1 ELSE 1 END
                                                                        * (b.j ->> 'qty_received')::numeric * f.price_new)::numeric(18,4)))
                            ELSE b.j END - 'id' - 'created_at'
                  FROM ops_price_fix_b3.bk_rows b
                 WHERE b.bk_round = v_round AND b.tbl = 'smsi'
                   AND (b.j ->> 'settlement_id')::bigint IN (SELECT t.settlement_id FROM ops_price_fix_b3.fix_targets t WHERE t.fix_id = v_fix))
               EXCEPT ALL
               (SELECT to_jsonb(i) - 'id' - 'created_at' FROM public.store_monthly_settlement_items i
                 WHERE i.settlement_id IN (SELECT t.settlement_id FROM ops_price_fix_b3.fix_targets t WHERE t.fix_id = v_fix)))) d);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】重產後有蛋小白帳的店，月結明細有 % 行（兩邊合計）不是「只有蛋小白單價變 42」。已全部取消，請截圖給 CEO。', v_cnt;
  END IF;
  -- 7-5 其他店（沒有蛋小白帳的）：方案甲＝逐欄跟備份一樣；方案乙＝表頭扣掉「最後異動時間／異動人」、明細扣掉「編號／建立時間」跟備份一樣
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT CASE WHEN p_mode = '甲' THEN to_jsonb(s) ELSE to_jsonb(s) - 'updated_at' - 'updated_by' END AS j
                  FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct AND NOT (s.store_id = ANY (v_targets)))
               EXCEPT ALL
               (SELECT CASE WHEN p_mode = '甲' THEN b.j ELSE b.j - 'updated_at' - 'updated_by' END
                  FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms' AND NOT ((b.j ->> 'store_id')::bigint = ANY (v_targets))))
              UNION ALL
              ((SELECT CASE WHEN p_mode = '甲' THEN b.j ELSE b.j - 'updated_at' - 'updated_by' END
                  FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms' AND NOT ((b.j ->> 'store_id')::bigint = ANY (v_targets)))
               EXCEPT ALL
               (SELECT CASE WHEN p_mode = '甲' THEN to_jsonb(s) ELSE to_jsonb(s) - 'updated_at' - 'updated_by' END
                  FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct AND NOT (s.store_id = ANY (v_targets))))) d);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】方案%：重產後沒有蛋小白帳的店，月結表頭有 % 筆（兩邊合計）跟備份不一樣。已全部取消。%', p_mode, v_cnt,
      CASE WHEN p_mode = '乙' THEN '其他店重產會變（0-D 第 7500 項），要改走方案甲或先查清楚，請截圖給 CEO。' ELSE '請截圖給 CEO。' END;
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT CASE WHEN p_mode = '甲' THEN to_jsonb(i) ELSE to_jsonb(i) - 'id' - 'created_at' END AS j
                  FROM public.store_monthly_settlement_items i
                 WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct AND NOT (s.store_id = ANY (v_targets))))
               EXCEPT ALL
               (SELECT CASE WHEN p_mode = '甲' THEN b.j ELSE b.j - 'id' - 'created_at' END
                  FROM ops_price_fix_b3.bk_rows b
                 WHERE b.bk_round = v_round AND b.tbl = 'smsi'
                   AND (b.j ->> 'settlement_id')::bigint IN (SELECT h.pk FROM ops_price_fix_b3.bk_rows h
                                                              WHERE h.bk_round = v_round AND h.tbl = 'sms' AND NOT ((h.j ->> 'store_id')::bigint = ANY (v_targets)))))
              UNION ALL
              ((SELECT CASE WHEN p_mode = '甲' THEN b.j ELSE b.j - 'id' - 'created_at' END
                  FROM ops_price_fix_b3.bk_rows b
                 WHERE b.bk_round = v_round AND b.tbl = 'smsi'
                   AND (b.j ->> 'settlement_id')::bigint IN (SELECT h.pk FROM ops_price_fix_b3.bk_rows h
                                                              WHERE h.bk_round = v_round AND h.tbl = 'sms' AND NOT ((h.j ->> 'store_id')::bigint = ANY (v_targets))))
               EXCEPT ALL
               (SELECT CASE WHEN p_mode = '甲' THEN to_jsonb(i) ELSE to_jsonb(i) - 'id' - 'created_at' END
                  FROM public.store_monthly_settlement_items i
                 WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct AND NOT (s.store_id = ANY (v_targets)))))) d);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】方案%：重產後沒有蛋小白帳的店，月結明細有 % 行（兩邊合計）跟備份不一樣。已全部取消。%', p_mode, v_cnt,
      CASE WHEN p_mode = '乙' THEN '其他店重產會變（0-D 第 7500 項），要改走方案甲或先查清楚，請截圖給 CEO。' ELSE '請截圖給 CEO。' END;
  END IF;
  -- 7-6 十月爭議、十月人工調整：逐欄＝備份（6 筆有效調整原樣還在；⛔ 這份不作廢、不新增任何一筆）
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd') EXCEPT (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)))
              UNION ALL
              ((SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct) EXCEPT (SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa'))
              UNION ALL
              ((SELECT b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa') EXCEPT (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct))) d);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】重產後十月爭議／人工調整有 % 筆（兩邊合計）跟備份不一樣。已全部取消，請截圖給 CEO。', v_cnt;
  END IF;
  -- 7-7 十月以外每一個月份（八月、九月…）的月結表頭／明細／調整／爭議：逐列＝備份（一個字都不能變）
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT 'x_sms' AS tbl, s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct
                UNION ALL SELECT 'x_smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct)
                UNION ALL SELECT 'x_ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct)
                UNION ALL SELECT 'x_ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month <> f.oct)
               EXCEPT (SELECT b.tbl, b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl IN ('x_sms','x_smsi','x_ssd','x_ssa')))
              UNION ALL
              ((SELECT b.tbl, b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl IN ('x_sms','x_smsi','x_ssd','x_ssa'))
               EXCEPT (SELECT 'x_sms' AS tbl, s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct
                UNION ALL SELECT 'x_smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct)
                UNION ALL SELECT 'x_ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month <> f.oct)
                UNION ALL SELECT 'x_ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month <> f.oct))) d);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】改價後十月以外的月份（八月、九月…）月結有 % 筆（兩邊合計）跟備份不一樣。已全部取消，請截圖給 CEO。', v_cnt;
  END IF;
  -- 7-8 蛋小白 8/1～10/1 每日對帳逐筆＝備份（時點、數量、單價、金額都要一樣；第二批 8-5 同一種比法）
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
                  FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), f.oct_from) l
                 WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id)
               EXCEPT ALL (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b3.pre_lines WHERE bk_round = v_round))
              UNION ALL
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b3.pre_lines WHERE bk_round = v_round)
               EXCEPT ALL (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
                  FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), f.oct_from) l
                 WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id))) d);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】改價後蛋小白 8/1～10/1 的帳有 % 筆（兩邊合計）跟備份不一樣。已全部取消，請截圖給 CEO。', v_cnt;
  END IF;
  -- 7-9 店家每日對帳：蛋小白落在 64 那段的每一筆單價＝42；11 家店的月結分店價合計＝每日對帳十月加總
  v_cnt := (SELECT COUNT(*) FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.oct_from, f.nov_from) l
             WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id
               AND l.entry_type IN ('hq_inbound','air_in','air_out','return_out')
               AND l.received_at >= v_from AND l.unit_branch_price <> f.price_new);
  IF v_cnt > 0 THEN RAISE EXCEPTION '【停】改價後十月還有 % 筆蛋小白的帳不是 42。已全部取消。', v_cnt; END IF;
  v_msg := (SELECT string_agg(s.code, '、' ORDER BY s.code)
              FROM ops_price_fix_b3.fix_targets t JOIN public.store_monthly_settlements m ON m.id = t.settlement_id JOIN public.stores s ON s.id = t.store_id
             WHERE t.fix_id = v_fix
               AND m.branch_amount <> COALESCE((SELECT SUM(l.amount) FROM public._store_inbound_lines(t.store_id, f.oct_from, f.nov_from) l), 0));
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '【停】重產後這些店十月月結的分店價合計跟每日對帳加總不一樣：%。已全部取消，請截圖給 CEO。', v_msg;
  END IF;
  -- 7-10 十月應收合計的變化＝ −836
  IF v_pay_after - v_pay_before <> f.exp_delta THEN
    RAISE EXCEPTION '【停】十月應收合計變了 %（要剛好 −836）。已全部取消，請截圖給 CEO。', trim_scale(v_pay_after - v_pay_before);
  END IF;

  -- ── 8. 留紀錄＋存「改完之後的樣子」（還原要用）──
  INSERT INTO ops_price_fix_b3.fix_log (fix_id, bk_round, operator, mode, gen_result, summary)
  VALUES (v_fix, v_round, p_operator, p_mode, v_gen, jsonb_build_object(
    '01 修正編號（這一批自己的編號）', v_fix,
    '02 用的備份輪次（ops_price_fix_b3）', v_round,
    '03 方案', CASE WHEN p_mode = '甲' THEN '甲：整月重產後，沒有蛋小白帳的店蓋回備份原樣' ELSE '乙：整月採用產生器結果（其他店金額逐行一分不差）' END,
    '04 改價', 'G02907-01：刪掉 26805（64）、33876（42）；新版本 ' || v_new_id || '＝42，從 '
               || to_char(v_from AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') || '（台北）起、沒有結束日；24666（62）不動',
    '05 十月應收合計', trim_scale(v_pay_before) || ' → ' || trim_scale(v_pay_after) || '（差 ' || trim_scale(v_pay_after - v_pay_before) || '）',
    '06 有蛋小白帳的店', (SELECT string_agg(s.code || ' ' || trim_scale(t.delta), '、' ORDER BY t.delta, s.code)
                            FROM ops_price_fix_b3.fix_targets t JOIN public.stores s ON s.id = t.store_id WHERE t.fix_id = v_fix),
    '07 人工調整', '十月 6 筆有效調整逐欄＝備份（一筆都沒作廢、沒新增）',
    '08 自我驗算', '✅ 價格版本鏈／11 家差額／蛋小白以外明細不變／其他店（方案' || p_mode || '）／十月爭議與調整／十月以外每個月份逐列不變／蛋小白 8/1～10/1 逐筆不變／每日對帳一致／應收合計 −836，全部通過',
    '09 操作人', p_operator::text));
  INSERT INTO ops_price_fix_b3.after_rows (fix_id, tbl, pk, j)
  SELECT v_fix, 'prices', p.id, to_jsonb(p) FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id;
  INSERT INTO ops_price_fix_b3.after_rows (fix_id, tbl, pk, j)
  SELECT v_fix, 'sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct;
  INSERT INTO ops_price_fix_b3.after_rows (fix_id, tbl, pk, j)
  SELECT v_fix, 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i
   WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct);
  INSERT INTO ops_price_fix_b3.after_rows (fix_id, tbl, pk, j)
  SELECT v_fix, 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d
   WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct);
  INSERT INTO ops_price_fix_b3.after_rows (fix_id, tbl, pk, j)
  SELECT v_fix, 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct;
  -- 十月全部店、全部商品的每一筆帳（還原前比：修正之後十月有任何新異動就不自動還原）
  INSERT INTO ops_price_fix_b3.after_oct_lines (fix_id, store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount)
  SELECT v_fix, st.id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at, l.unit_branch_price, l.amount
    FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.oct_from, f.nov_from) l
   WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL;
  -- 蛋小白 10/1 ～ 現在（含十一月）的每一筆帳
  INSERT INTO ops_price_fix_b3.after_egg_lines (fix_id, store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount)
  SELECT v_fix, st.id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at, l.unit_branch_price, l.amount
    FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.oct_from, now()) l
   WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id;
END $fix$;

-- 結果
SELECT key AS "項目", value AS "內容"
  FROM ops_price_fix_b3.fix_log f, jsonb_each_text(f.summary)
 WHERE f.fix_id = (SELECT MAX(fix_id) FROM ops_price_fix_b3.fix_log)
 ORDER BY key;

-- ============================================================================
--  第二批分店價錯價修正 4　還原（✅ 會改資料：把這一批的價格和九月月結蓋回修正之前的樣子）
--  日期：2026-10-07　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-第二批分店價錯價修正_九月十月_2026-10-07.md、派工單-第二批分店價錯價修正指令_2026-10-07.md
--  範本：第一批 NEW-ERP九月錯價修正_2026-09-29_4還原；上鎖、比對、換回、逐欄驗算的寫法照抄。
--        跟第一批不同：①只讀這一批自己的位置 ops_price_fix_b2，只還原這一批的修正（第一批 9/30 的修正與備份一個字都不碰）
--        ②比對「修正剛做完的樣子」時，多比十月這一批品號的每一筆帳
--  程式出處：唯讀鏡像 origin/main 500ecc32 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼（全部在同一次裡，不對就整筆取消）
--    ①上鎖（同修正檔，整張表）：月結表頭／明細／爭議、人工調整、價格表、派車單與明細、店家資料
--      → 貼的這段時間月結頁面連「看」都要等；產生／確認月結、調整、改價、派車、收貨、退貨、店轉店都要排隊等這份做完
--      → ⛔ 這份「不排隊」：只要有人正在用（任何一把鎖拿不到）就立刻停下、什麼都沒改，請過幾分鐘再貼
--      → 上鎖順序跟第 2 份修正一模一樣：①月結表頭 ②月結明細 ③月結爭議 ④人工調整 ⑤價格 ⑥派車單 ⑦派車明細 ⑧店家
--        ⑨月份鎖 ⑩九月月結各列 ⑪價格各列 ⑫人工調整各列
--  ★ 貼之前：先確認沒有人在後台操作、倉庫沒在派車收貨。
--      → 鎖住之後才比對，所以「比對通過」到「換回備份」之間，不可能有人插進新的派車或重產月結
--    ②先比對：現在的資料是不是還跟「修正剛做完的樣子」一模一樣？
--        比這一批品號的價格版本、九月月結表頭／明細／爭議、九月人工調整、九月每一筆派車／收貨／退貨／店轉店，
--        還有十月（10/1 ～ 現在）這一批品號的每一筆帳（有新的就算「被動過」）。
--        ⛔ 只要有任何一筆被動過（例如有人確認了月結、重按了月結、加了調整、又派了新的貨），就停下來、什麼都不改，
--           改成人工對帳 —— 不然會把別人的新資料蓋掉。
--        ⚠ 十月還在營業：修正之後只要這一批品號又派過車，這份就會停（請 CEO 改人工處理）。
--    ③都沒被動過 → 把這些資料「整筆換回備份」：
--        ・價格版本：修正新開的版本刪掉，被截短／刪掉的版本恢復原樣（每一欄，含原本的 id）
--        ・九月月結：表頭、明細、爭議恢復原樣（每一欄，含最後異動時間）；
--          修正時「新建」的月結（原本沒有九月月結的店）會被移除 —— 只移除修正檔記錄的那幾張
--        ・人工調整：作廢的恢復成有效（每一欄）
--        ・十月沒有月結可以還原；十月的帳是照價目表即時算的，價格版本換回去之後就回到修正前的算法
--    ④最後逐欄比對：全部＝備份，才算數
--  ★ 你要填的：通常不用填。p_fix_id 留 NULL＝還原這一批最近一次修正。
--  ★ 會不會動資料：會。
--  ★ 貼的時候 Supabase 可能跳出「destructive operation（破壞性操作）」提醒（因為要刪掉再放回）
--    → 確認貼的是「第二批 4還原」這份再按執行（⚠ 按鈕文字以實際畫面為準）。
--  ★ 看到什麼要停：
--    ・紅字開頭【停】→ 什麼都沒改。最常見是「修正之後又有人動過」→ 截圖給 CEO，改人工對帳
--    ・紅字寫「有人正在使用月結／派車／價格」（或 lock timeout）→ 什麼都沒改，過幾分鐘再貼；連續兩三次都這樣，截圖給 CEO
--  ★ 技術註記：表頭有「自動蓋最後異動時間」的觸發器（trg_touch_sms → touch_updated_at，20260512000009:84、20260611000010:12-21）。
--    這份用「刪掉再原樣放回」而不是改欄位，放回（INSERT）不會觸發它；另外交易內也設了 app.skip_updated_at='1' 雙保險。
--    明細的保護觸發器只擋「已確認／已結清」的明細（20260512000013:15-48），還原前已確認全部是草稿。
-- ============================================================================

DO $rs$
DECLARE
  p_fix_id int := NULL;   -- ⬅ 通常不用填；NULL＝還原這一批最近一次還沒還原的修正
  c_month  date := DATE '2026-09-01';
  c_oct    timestamptz := ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei');
  v_step text; v_tenant uuid; v_cnt int; v_round int; v_fix int; v_msg text := '';
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);
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

  IF to_regclass('ops_price_fix_b2.fix_log') IS NULL THEN
    RAISE EXCEPTION '【停】找不到這一批的備份與修正紀錄（ops_price_fix_b2）。什麼都沒改。';
  END IF;
  v_fix := COALESCE(p_fix_id, (SELECT MAX(fix_id) FROM ops_price_fix_b2.fix_log WHERE restored_at IS NULL));
  IF v_fix IS NULL THEN
    RAISE EXCEPTION '【停】這一批沒有可以還原的修正紀錄。什麼都沒改。';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops_price_fix_b2.fix_log WHERE fix_id = v_fix) THEN
    RAISE EXCEPTION '【停】這一批沒有第 % 次修正。什麼都沒改。', v_fix;
  END IF;
  IF (SELECT restored_at FROM ops_price_fix_b2.fix_log WHERE fix_id = v_fix) IS NOT NULL THEN
    RAISE EXCEPTION '【停】這一批第 % 次修正已經還原過了。什麼都沒改。', v_fix;
  END IF;
  v_round := (SELECT bk_round FROM ops_price_fix_b2.fix_log WHERE fix_id = v_fix);

  -- 上鎖（跟修正檔同一套、同一個順序）：全部 NOWAIT，拿不到就整份取消；鎖住後「比對 → 換回」之間不可能有新異動
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

  -- 比對「修正剛做完的樣子」
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) EXCEPT (SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'prices'))
              UNION ALL
              ((SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'prices') EXCEPT (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '分店價版本有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01') EXCEPT (SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'sms'))
              UNION ALL
              ((SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'sms') EXCEPT (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01'))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結表頭有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) EXCEPT (SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'smsi'))
              UNION ALL
              ((SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'smsi') EXCEPT (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結明細有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01') EXCEPT (SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'ssa'))
              UNION ALL
              ((SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'ssa') EXCEPT (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01'))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月人工調整有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) EXCEPT (SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'ssd'))
              UNION ALL
              ((SELECT a.pk, a.j FROM ops_price_fix_b2.after_rows a WHERE a.fix_id = v_fix AND a.tbl = 'ssd') EXCEPT (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月月結爭議有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL ) x) EXCEPT (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.after_sept_lines WHERE fix_id = v_fix))
              UNION ALL
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.after_sept_lines WHERE fix_id = v_fix) EXCEPT (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL ) x))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '九月派車／收貨／退貨／店轉店有 ' || v_cnt || ' 筆變動（兩邊合計）；';
  END IF;
  -- 十月（10/1 ～ 現在）這一批品號的每一筆帳（跟修正檔存的 after_oct_lines 比）
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, c_oct, now()) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id IN (SELECT l2.sku_id FROM ops_price_fix_b2.sku_list l2 WHERE l2.bk_round = v_round)) x) EXCEPT (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.after_oct_lines WHERE fix_id = v_fix))
              UNION ALL
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.after_oct_lines WHERE fix_id = v_fix) EXCEPT (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, c_oct, now()) l WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id IN (SELECT l2.sku_id FROM ops_price_fix_b2.sku_list l2 WHERE l2.bk_round = v_round)) x))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '十月這一批品號的派車／收貨／退貨／店轉店有 ' || v_cnt || ' 筆變動（兩邊合計）；';
  END IF;
  IF v_msg <> '' THEN
    RAISE EXCEPTION '【停】修正之後這些資料又被動過：%。為了不蓋掉別人的新資料，什麼都沒改。請截圖給 CEO，改人工對帳。', v_msg;
  END IF;

  -- 換回備份
  PERFORM set_config('app.skip_updated_at', '1', true);
  DELETE FROM public.store_monthly_settlement_items WHERE id IN (SELECT x.pk FROM (SELECT i.id AS pk, to_jsonb(i) AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x);
  DELETE FROM public.store_settlement_disputes WHERE id IN (SELECT x.pk FROM (SELECT d.id AS pk, to_jsonb(d) AS j FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01')) x);
  DELETE FROM public.store_monthly_settlements WHERE id IN (SELECT x.pk FROM (SELECT s.id AS pk, to_jsonb(s) AS j FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = DATE '2026-09-01') x);
  DELETE FROM public.store_settlement_adjustments WHERE id IN (SELECT x.pk FROM (SELECT a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = DATE '2026-09-01') x);
  DELETE FROM public.prices WHERE id IN (SELECT x.pk FROM (SELECT p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id IN (SELECT l.sku_id FROM ops_price_fix_b2.sku_list l WHERE l.bk_round = v_round)) x);
  INSERT INTO public.prices SELECT (jsonb_populate_record(NULL::public.prices, b.j)).* FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices' ORDER BY b.pk;
  INSERT INTO public.store_settlement_adjustments SELECT (jsonb_populate_record(NULL::public.store_settlement_adjustments, b.j)).* FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssa' ORDER BY b.pk;
  INSERT INTO public.store_monthly_settlements SELECT (jsonb_populate_record(NULL::public.store_monthly_settlements, b.j)).* FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms' ORDER BY b.pk;
  INSERT INTO public.store_monthly_settlement_items SELECT (jsonb_populate_record(NULL::public.store_monthly_settlement_items, b.j)).* FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'smsi' ORDER BY b.pk;
  INSERT INTO public.store_settlement_disputes SELECT (jsonb_populate_record(NULL::public.store_settlement_disputes, b.j)).* FROM ops_price_fix_b2.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd' ORDER BY b.pk;

  -- 逐欄＝備份
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
    RAISE EXCEPTION '【停】換回之後跟備份還是不一樣：%。已全部取消，請截圖給 CEO。', v_msg;
  END IF;

  UPDATE ops_price_fix_b2.fix_log
     SET restored_at = now(),
         restore_summary = jsonb_build_object(
           '01 還原的修正編號（這一批）', v_fix,
           '02 用的備份輪次（ops_price_fix_b2）', v_round,
           '03 價格版本', (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'prices') || ' 筆，逐欄＝備份',
           '04 九月月結表頭', (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'sms') || ' 張，逐欄＝備份',
           '05 九月月結明細', (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'smsi') || ' 行，逐欄＝備份',
           '06 九月人工調整', (SELECT COUNT(*) FROM ops_price_fix_b2.bk_rows WHERE bk_round = v_round AND tbl = 'ssa') || ' 筆，逐欄＝備份',
           '07 移除修正時新建的月結', COALESCE((SELECT f.summary ->> '06 本次新建的九月月結' FROM ops_price_fix_b2.fix_log f WHERE f.fix_id = v_fix), ''),
           '08 結果', '✅ 這一批全部換回修正之前的樣子（第一批 9/30 的修正沒有動）')
   WHERE fix_id = v_fix;
END $rs$;

-- 結果
SELECT key AS "項目", value AS "內容"
  FROM ops_price_fix_b2.fix_log f, jsonb_each_text(f.restore_summary)
 WHERE f.fix_id = (SELECT MAX(fix_id) FROM ops_price_fix_b2.fix_log WHERE restored_at IS NOT NULL)
 ORDER BY key;

-- ============================================================================
--  第三批分店價往回改（蛋小白雞蛋金磚 G02907-01） 4　還原
--  ⛔ 會寫入（把這一批的分店價版本和十月月結蓋回修正之前的樣子）
--  日期：2026-11-02　阿寫寫、⛔ 還沒經阿審（Codex）審過之前不要貼
--  依據：派工單-蛋小白分店價往回改_第三批_2026-11-02.md 第 5 點
--  範本：第二批 scripts/PROD-fix-branch-price-batch2-2026-10/4_restore_WRITES.sql；上鎖、比對、換回、逐欄驗算的寫法照抄。
--        【改寫處】①只讀這一批自己的位置 ops_price_fix_b3，只還原這一批（前兩批的修正與備份一個字都不碰）
--                  ②還原對象：這個規格的分店價版本＋「十月」月結表頭／明細／爭議（第二批是九月）
--                  ③比對「修正剛做完的樣子」：十月全部店全部商品的每一筆帳＋蛋小白 10/1 到現在每一筆（含十一月）
--                  ④人工調整修正時一筆都沒動 → 這份也不動，只比對它跟備份一樣
--  程式出處：工程紀錄本 origin/main bafc13d9 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼（全部在同一次裡，不對就整筆取消）
--    ①上鎖（跟修正檔同一套、同一個順序）：月結表頭／明細／爭議、人工調整、價格表、派車單與明細、店家資料
--      → ⛔ 這份「不排隊」：只要有人正在用（任何一把鎖拿不到）就立刻停下、什麼都沒改，請過幾分鐘再貼
--    ②先比對：現在的資料是不是還跟「修正剛做完的樣子」一模一樣？
--        比這個規格的價格版本、十月月結表頭／明細／爭議／人工調整、十月每一筆派車／收貨／退貨／店轉店（全部店、全部商品），
--        還有蛋小白 10/1 到現在（含十一月）的每一筆帳。
--        ⛔ 只要有任何一筆被動過（有人重按十月月結、送店家、加調整、又派了貨…），就停下來、什麼都不改，改成人工對帳 ——
--           不然會把別人的新資料蓋掉。
--    ③都沒被動過 → 「整筆換回備份」：
--        ・價格版本：修正新開的 42 刪掉，26805（64）、33876（42）原樣放回（每一欄，含原本的 id）；24666（62）本來就沒動
--        ・十月月結：全部店的表頭、明細、爭議恢復成備份（每一欄，含最後異動時間）
--        ・人工調整：修正時沒有動 → 這份不動，只確認它跟備份一樣
--    ④最後逐欄比對：全部＝備份，才算數
--    ※ 還原的是「指定資料表的資料列，逐欄相同」；自動編號（sequence）不還原（刪掉再放回會讓編號往前走，倒退共用編號比留著更危險）。
--    ※ 上鎖範圍同修正檔，沒有鎖 stock_movements；成本若被並行改動，靠後面的逐欄比對攔截。
--  ★ 你要填的：通常不用填。p_fix_id 留 NULL＝還原這一批最近一次修正。
--  ★ 貼的時候 Supabase 可能跳出「destructive operation（破壞性操作）」提醒（因為要刪掉再放回）
--    → 確認貼的是「第三批 4還原」這份再按執行（⚠ 按鈕文字以實際畫面為準）。
--  ★ 看到什麼要停：
--    ・紅字開頭【停】→ 什麼都沒改。最常見是「修正之後又有人動過」→ 截圖給 CEO，改人工對帳
--    ・紅字寫「有人正在使用月結／派車／價格」（或 lock timeout）→ 什麼都沒改，過幾分鐘再貼
--  ★ 技術註記：表頭有「自動蓋最後異動時間」的觸發器（trg_touch_sms → touch_updated_at，20260512000009:84、20260611000010:12-21）。
--    這份用「刪掉再原樣放回」而不是改欄位，放回（INSERT）不會觸發它；另外交易內也設了 app.skip_updated_at='1' 雙保險。
--    明細、爭議跟著表頭 ON DELETE CASCADE（20260512000009:67、20260715000120:87）；明細保護只擋已確認／已結清（20260512000013:15-48），
--    還原前已確認十月全部是草稿。
-- ============================================================================

DO $rs$
DECLARE
  p_fix_id int := NULL;   -- ⬅ 通常不用填；NULL＝還原這一批最近一次還沒還原的修正
  f record;
  v_step text; v_tenant uuid; v_cnt int; v_round int; v_fix int; v_msg text := '';
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);
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

  -- 公司：只認「包子媽生鮮小舖」一家
  v_cnt := (SELECT COUNT(*) FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】系統裡叫「包子媽生鮮小舖」的公司有 % 家（要剛好 1 家）。什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;
  v_tenant := (SELECT t.id FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖');

  IF to_regclass('ops_price_fix_b3.fix_log') IS NULL THEN
    RAISE EXCEPTION '【停】找不到這一批的備份與修正紀錄（ops_price_fix_b3）。什麼都沒改。';
  END IF;
  v_fix := COALESCE(p_fix_id, (SELECT MAX(fix_id) FROM ops_price_fix_b3.fix_log WHERE restored_at IS NULL));
  IF v_fix IS NULL THEN
    RAISE EXCEPTION '【停】這一批沒有可以還原的修正紀錄。什麼都沒改。';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops_price_fix_b3.fix_log WHERE fix_id = v_fix) THEN
    RAISE EXCEPTION '【停】這一批沒有第 % 次修正。什麼都沒改。', v_fix;
  END IF;
  IF (SELECT restored_at FROM ops_price_fix_b3.fix_log WHERE fix_id = v_fix) IS NOT NULL THEN
    RAISE EXCEPTION '【停】這一批第 % 次修正已經還原過了。什麼都沒改。', v_fix;
  END IF;
  v_round := (SELECT bk_round FROM ops_price_fix_b3.fix_log WHERE fix_id = v_fix);

  -- 上鎖（跟修正檔同一套、同一個順序）：全部 NOWAIT，拿不到就整份取消；鎖住後「比對 → 換回」之間不可能有新異動
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

  -- 比對「修正剛做完的樣子」（after_rows／after_oct_lines／after_egg_lines）
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT 'prices' AS tbl, p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id
                UNION ALL SELECT 'sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct
                UNION ALL SELECT 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                UNION ALL SELECT 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                UNION ALL SELECT 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct)
               EXCEPT (SELECT a.tbl, a.pk, a.j FROM ops_price_fix_b3.after_rows a WHERE a.fix_id = v_fix))
              UNION ALL
              ((SELECT a.tbl, a.pk, a.j FROM ops_price_fix_b3.after_rows a WHERE a.fix_id = v_fix)
               EXCEPT (SELECT 'prices' AS tbl, p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id
                UNION ALL SELECT 'sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct
                UNION ALL SELECT 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                UNION ALL SELECT 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                UNION ALL SELECT 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '價格／十月月結／爭議／人工調整有 ' || v_cnt || ' 筆不一樣；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
                  FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.oct_from, f.nov_from) l
                 WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL)
               EXCEPT ALL (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b3.after_oct_lines WHERE fix_id = v_fix))
              UNION ALL
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b3.after_oct_lines WHERE fix_id = v_fix)
               EXCEPT ALL (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
                  FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.oct_from, f.nov_from) l
                 WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '十月派車／收貨／退貨／店轉店有 ' || v_cnt || ' 筆變動（兩邊合計）；';
  END IF;
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
                  FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.oct_from, now()) l
                 WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id)
               EXCEPT ALL (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b3.after_egg_lines WHERE fix_id = v_fix))
              UNION ALL
              ((SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b3.after_egg_lines WHERE fix_id = v_fix)
               EXCEPT ALL (SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
                  FROM public.stores st CROSS JOIN LATERAL public._store_inbound_lines(st.id, f.oct_from, now()) l
                 WHERE st.tenant_id = v_tenant AND st.location_id IS NOT NULL AND l.sku_id = f.sku_id))) d);
  IF v_cnt > 0 THEN
    v_msg := v_msg || '蛋小白 10/1 到現在有 ' || v_cnt || ' 筆新的帳或變動（兩邊合計）；';
  END IF;
  IF EXISTS (SELECT 1 FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = f.oct AND status <> 'draft') THEN
    v_msg := v_msg || '十月月結有店已經不是草稿；';
  END IF;
  IF v_msg <> '' THEN
    RAISE EXCEPTION '【停】修正之後這些資料又被動過：%。為了不蓋掉別人的新資料，什麼都沒改。請截圖給 CEO，改人工對帳。', v_msg;
  END IF;

  -- 換回備份（價格＋十月月結表頭／明細／爭議；人工調整修正時沒動，不碰）
  PERFORM set_config('app.skip_updated_at', '1', true);
  DELETE FROM public.store_monthly_settlements WHERE tenant_id = v_tenant AND settlement_month = f.oct;   -- 明細、爭議跟著 CASCADE
  DELETE FROM public.prices WHERE tenant_id = v_tenant AND scope = 'branch' AND sku_id = f.sku_id;
  INSERT INTO public.prices SELECT (jsonb_populate_record(NULL::public.prices, b.j)).* FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'prices' ORDER BY b.pk;
  INSERT INTO public.store_monthly_settlements SELECT (jsonb_populate_record(NULL::public.store_monthly_settlements, b.j)).* FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'sms' ORDER BY b.pk;
  INSERT INTO public.store_monthly_settlement_items SELECT (jsonb_populate_record(NULL::public.store_monthly_settlement_items, b.j)).* FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'smsi' ORDER BY b.pk;
  INSERT INTO public.store_settlement_disputes SELECT (jsonb_populate_record(NULL::public.store_settlement_disputes, b.j)).* FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl = 'ssd' ORDER BY b.pk;
  PERFORM set_config('app.skip_updated_at', '0', true);

  -- 逐欄＝備份（價格、十月月結表頭／明細／爭議／人工調整）
  v_cnt := (SELECT COUNT(*) FROM (
              ((SELECT 'prices' AS tbl, p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id
                UNION ALL SELECT 'sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct
                UNION ALL SELECT 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                UNION ALL SELECT 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                UNION ALL SELECT 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct)
               EXCEPT (SELECT b.tbl, b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl IN ('prices','sms','smsi','ssd','ssa')))
              UNION ALL
              ((SELECT b.tbl, b.pk, b.j FROM ops_price_fix_b3.bk_rows b WHERE b.bk_round = v_round AND b.tbl IN ('prices','sms','smsi','ssd','ssa'))
               EXCEPT (SELECT 'prices' AS tbl, p.id AS pk, to_jsonb(p) AS j FROM public.prices p WHERE p.tenant_id = v_tenant AND p.scope = 'branch' AND p.sku_id = f.sku_id
                UNION ALL SELECT 'sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct
                UNION ALL SELECT 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                UNION ALL SELECT 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT s.id FROM public.store_monthly_settlements s WHERE s.tenant_id = v_tenant AND s.settlement_month = f.oct)
                UNION ALL SELECT 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a WHERE a.tenant_id = v_tenant AND a.settlement_month = f.oct))) d);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '【停】換回之後跟備份還是有 % 筆不一樣。已全部取消，請截圖給 CEO。', v_cnt;
  END IF;

  UPDATE ops_price_fix_b3.fix_log
     SET restored_at = now(),
         restore_summary = jsonb_build_object(
           '01 還原的修正編號（這一批）', v_fix,
           '02 用的備份輪次（ops_price_fix_b3）', v_round,
           '03 價格版本', (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'prices') || ' 筆，逐欄＝備份（26805＝64、33876＝42 放回原 id）',
           '04 十月月結表頭', (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'sms') || ' 張，逐欄＝備份',
           '05 十月月結明細', (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'smsi') || ' 行，逐欄＝備份',
           '06 十月人工調整', (SELECT COUNT(*) FROM ops_price_fix_b3.bk_rows WHERE bk_round = v_round AND tbl = 'ssa') || ' 筆，修正時沒動、現在逐欄＝備份',
           '07 結果', '✅ 這一批全部換回修正之前的樣子（第一批、第二批的修正沒有動）')
   WHERE fix_id = v_fix;
END $rs$;

-- 結果
SELECT key AS "項目", value AS "內容"
  FROM ops_price_fix_b3.fix_log f, jsonb_each_text(f.restore_summary)
 WHERE f.fix_id = (SELECT MAX(fix_id) FROM ops_price_fix_b3.fix_log WHERE restored_at IS NOT NULL)
 ORDER BY key;

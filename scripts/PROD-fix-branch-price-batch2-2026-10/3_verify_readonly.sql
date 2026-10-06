-- ============================================================================
--  第二批分店價錯價修正 3　驗算（只查不改）
--  日期：2026-10-07　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-第二批分店價錯價修正_九月十月_2026-10-07.md、派工單-第二批分店價錯價修正指令_2026-10-07.md
--  範本：第一批 NEW-ERP九月錯價修正_2026-09-29_3驗算（9/30 已在正式系統跑過）；
--        跟第一批不同：讀這一批自己的位置 ops_price_fix_b2；B 類另外驗；多驗十月；多看十月月結有沒有被產生
--  程式出處：唯讀鏡像 origin/main 500ecc32 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    修正（第 2 份）做完之後，用「另一次」重新檢查一遍（修正檔自己已經在同一次裡驗過，這份是事後再看一次）：
--      ・八月每一筆跟備份時的基準比，完全一樣
--      ・A 類：9/1 起只有一個版本、就是正確價；B 類：只有一個版本、開始時間跟原本一樣、就是正確價
--      ・九月、十月（到現在）每一筆帳，九月月結每一行，單價＝正確價；每張九月月結貨款＝每日對帳加總
--      ・修正之後有沒有人又動過這些資料（跟「改完之後的樣子」比）→ 有的話還原檔會拒絕自動還原
--      ・各店九月月結狀態（同盤點⑤：月結單上的錯價差額應該全部 0）；十月月結沒有被產生
--    （計畫第 2 節還要重跑盤點③⑤，那是另外兩份檔，CEO 會給）
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：整份貼上 → Run → 下載 CSV 給 CEO。
--  ★ 看到什麼要停：任何一列 ❌ → 截圖給 CEO。⚠ 是提醒（例如修正後又有新派車，屬正常營運，但會讓還原檔拒絕自動還原）。
-- ============================================================================

WITH
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
fx AS (SELECT * FROM ops_price_fix_b2.fix_log WHERE restored_at IS NULL ORDER BY fix_id DESC LIMIT 1),
lst AS (SELECT l.* FROM ops_price_fix_b2.sku_list l JOIN fx ON fx.bk_round = l.bk_round),
same_list AS (   -- 這份的清單＝修正時用的清單（備份裡那一輪）
  SELECT NOT EXISTS (SELECT 1 FROM vlist v FULL JOIN lst ON lst.sku_code = v.sku_code
                      WHERE v.sku_code IS NULL OR lst.sku_code IS NULL OR v.correct_price <> lst.correct_price OR v.cls <> lst.cls) AS yes
),
st AS (SELECT s.id, s.code, s.name FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id WHERE s.location_id IS NOT NULL),
aug_now AS (
  SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l
   WHERE l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT sku_id FROM lst)
),
aug_bk AS (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.aug_lines a JOIN fx ON fx.bk_round = a.bk_round),
aug_diff AS (
  (SELECT 'now' AS side, * FROM (SELECT * FROM aug_now EXCEPT SELECT * FROM aug_bk) a)
  UNION ALL
  (SELECT 'bk', * FROM (SELECT * FROM aug_bk EXCEPT SELECT * FROM aug_now) b)
),
sep_now AS (
  SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l
),
sep_bad AS (SELECT x.* FROM sep_now x JOIN lst ON lst.sku_id = x.sku_id WHERE x.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND x.unit_price <> lst.correct_price),
oct_now AS (   -- 十月（10/1 00:00 台北 ～ 現在）這一批品號的每一筆帳
  SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei'), now()) l
   WHERE l.sku_id IN (SELECT sku_id FROM lst)
),
oct_bad AS (SELECT x.* FROM oct_now x JOIN lst ON lst.sku_id = x.sku_id WHERE x.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND x.unit_price <> lst.correct_price),
sm AS (SELECT m.* FROM public.store_monthly_settlements m JOIN tn ON tn.tenant_id = m.tenant_id WHERE m.settlement_month = DATE '2026-09-01'),
item_bad AS (SELECT i.* FROM public.store_monthly_settlement_items i JOIN sm ON sm.id = i.settlement_id JOIN lst ON lst.sku_id = i.sku_id
              WHERE i.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND i.unit_branch_price <> lst.correct_price),
hdr_bad AS (SELECT sm.* FROM sm WHERE sm.branch_amount <> COALESCE((SELECT SUM(x.amount) FROM sep_now x WHERE x.store_id = sm.store_id), 0)),
price_bad AS (
  -- A 類：9/1 之後只剩一個版本、從 9/1 開始、沒有結束日、就是正確價
  SELECT lst.sku_code FROM lst, tn
   WHERE lst.cls = 'A'
     AND ( (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = tn.tenant_id AND p.sku_id = lst.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
              AND (p.effective_to IS NULL OR p.effective_to > ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'))) <> 1
        OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = tn.tenant_id AND p.sku_id = lst.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
              AND p.effective_from = ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei') AND p.effective_to IS NULL AND p.price = lst.correct_price))
  UNION ALL
  -- B 類：只有一個版本、開始時間＝備份裡原本那個版本的開始時間、沒有結束日、就是正確價
  SELECT lst.sku_code FROM lst, tn
   WHERE lst.cls = 'B'
     AND ( (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = tn.tenant_id AND p.sku_id = lst.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL) <> 1
        OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = tn.tenant_id AND p.sku_id = lst.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
              AND p.effective_to IS NULL AND p.price = lst.correct_price
              AND p.effective_from = (SELECT (b.j ->> 'effective_from')::timestamptz FROM ops_price_fix_b2.bk_rows b
                                       WHERE b.bk_round = lst.bk_round AND b.tbl = 'prices' AND (b.j ->> 'sku_id')::bigint = lst.sku_id AND b.j ->> 'scope_id' IS NULL)))
),
after_now AS (
  SELECT 'prices' AS tbl, p.id AS pk, to_jsonb(p) AS j FROM public.prices p, tn WHERE p.tenant_id = tn.tenant_id AND p.scope = 'branch' AND p.sku_id IN (SELECT sku_id FROM lst)
  UNION ALL SELECT 'sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s, tn WHERE s.tenant_id = tn.tenant_id AND s.settlement_month = DATE '2026-09-01'
  UNION ALL SELECT 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT id FROM sm)
  UNION ALL SELECT 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a, tn WHERE a.tenant_id = tn.tenant_id AND a.settlement_month = DATE '2026-09-01'
  UNION ALL SELECT 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT id FROM sm)
),
after_ref AS (SELECT a.tbl, a.pk, a.j FROM ops_price_fix_b2.after_rows a JOIN fx ON fx.fix_id = a.fix_id),
after_diff AS (SELECT tbl, COUNT(*) AS n FROM ((SELECT * FROM after_now EXCEPT SELECT * FROM after_ref) UNION ALL (SELECT * FROM after_ref EXCEPT SELECT * FROM after_now)) d GROUP BY tbl),
sep_ref AS (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.after_sept_lines a JOIN fx ON fx.fix_id = a.fix_id),
sep_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM sep_now EXCEPT SELECT * FROM sep_ref) UNION ALL (SELECT * FROM sep_ref EXCEPT SELECT * FROM sep_now)) d),
oct_ref AS (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_price_fix_b2.after_oct_lines a JOIN fx ON fx.fix_id = a.fix_id),
oct_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM oct_now EXCEPT SELECT * FROM oct_ref) UNION ALL (SELECT * FROM oct_ref EXCEPT SELECT * FROM oct_now)) d),
oct_sms AS (SELECT COUNT(*) AS n FROM public.store_monthly_settlements m JOIN tn ON tn.tenant_id = m.tenant_id WHERE m.settlement_month = DATE '2026-10-01')
SELECT "序", "檢查", "結果", "說明"
FROM (
  SELECT 0 AS "序", (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT n_ph FROM lchk) > 0 THEN '❌ 清單裡還有佔位（' || (SELECT ph FROM lchk) || '），這份結果不能用；請用跟第 2 份同一版清單的這一份'
       WHEN (SELECT n_dup FROM lchk) > 0 THEN '❌ 清單裡有 ' || (SELECT n_dup FROM lchk) || ' 個重複的品號，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT n_miss FROM lchk) > 0 THEN '❌ 清單有 ' || (SELECT n_miss FROM lchk) || ' 個規格在系統查不到（' || (SELECT miss FROM lchk) || '），這份結果不能用，請截圖給 CEO'
       WHEN EXISTS (SELECT 1 FROM fx) AND NOT (SELECT yes FROM same_list) THEN '❌ 這份的清單跟修正時用的清單不一樣，這份結果不能用；請用跟第 2 份同一版清單的這一份'
       ELSE '★ 總計（這一行就是結論）' END) AS "檢查",
         CASE WHEN NOT EXISTS (SELECT 1 FROM fx) THEN '❌ 找不到這一批還沒還原的修正紀錄（第 2 份還沒做，或已經還原）' ELSE '修正編號 ' || (SELECT fix_id FROM fx) || '（ops_price_fix_b2）' END AS "結果",
         '' AS "說明"
  UNION ALL SELECT 1, '八月逐筆跟備份基準一樣',
         CASE WHEN (SELECT COUNT(*) FROM aug_diff) = 0 THEN '✅ 一樣（' || (SELECT COUNT(*) FROM aug_now) || ' 筆）' ELSE '❌ 有 ' || (SELECT COUNT(*) FROM aug_diff) || ' 筆不同（兩邊合計）' END,
         '明細列在最下面（序 1001 起）'
  UNION ALL SELECT 2, '這一批品號的價格版本：A 類 9/1 起只有一個、是正確價；B 類只有一個、開始時間跟原本一樣、是正確價',
         CASE WHEN (SELECT COUNT(*) FROM price_bad) = 0 THEN '✅' ELSE '❌ ' || (SELECT string_agg(sku_code, '、') FROM price_bad) END, ''
  UNION ALL SELECT 3, '九月每一筆帳（每日對帳）單價＝正確價',
         CASE WHEN (SELECT COUNT(*) FROM sep_bad) = 0 THEN '✅' ELSE '❌ ' || (SELECT COUNT(*) FROM sep_bad) || ' 筆不是' END, ''
  UNION ALL SELECT 4, '九月月結明細單價＝正確價（同盤點⑤「月結單上的錯價差額」＝0）',
         CASE WHEN (SELECT COUNT(*) FROM item_bad) = 0 THEN '✅' ELSE '❌ ' || (SELECT COUNT(*) FROM item_bad) || ' 行不是' END, ''
  UNION ALL SELECT 5, '每張九月月結貨款＝每日對帳加總',
         CASE WHEN (SELECT COUNT(*) FROM hdr_bad) = 0 THEN '✅' ELSE '⚠ ' || (SELECT COUNT(*) FROM hdr_bad) || ' 張不一樣' END,
         '修正後九月又有新派車／收貨，而月結還沒重按，就會出現 ⚠（正常營運，不是修壞）'
  UNION ALL SELECT 6, '修正之後，價格／九月月結／調整／爭議有沒有人又動過',
         CASE WHEN NOT EXISTS (SELECT 1 FROM after_diff) THEN '✅ 沒有' ELSE '⚠ ' || (SELECT string_agg(tbl || ' ' || n || ' 筆', '、') FROM after_diff) END,
         '有動過的話，第 4 份還原會拒絕自動還原（要人工對帳）'
  UNION ALL SELECT 7, '修正之後，九月有沒有新的派車／收貨／退貨／店轉店',
         CASE WHEN (SELECT n FROM sep_diff) = 0 THEN '✅ 沒有' ELSE '⚠ 有 ' || (SELECT n FROM sep_diff) || ' 筆變動（兩邊合計）' END,
         '有的話，第 4 份還原會拒絕自動還原'
  UNION ALL SELECT 8, '九月月結狀態',
         '草稿 ' || (SELECT COUNT(*) FROM sm WHERE status = 'draft') || '／已寄出以後 ' || (SELECT COUNT(*) FROM sm WHERE status <> 'draft') || '／共 ' || (SELECT COUNT(*) FROM sm),
         '修正紀錄：' || COALESCE((SELECT f.summary ->> '06 本次新建的九月月結' FROM fx f), '')
  UNION ALL SELECT 9, '十月（到現在）這一批品號每一筆帳單價＝正確價（派車／店轉店／退貨差額＝0）',
         CASE WHEN (SELECT COUNT(*) FROM oct_bad) = 0 THEN '✅（' || (SELECT COUNT(*) FROM oct_now WHERE entry_type IN ('hq_inbound','air_in','air_out','return_out')) || ' 筆）'
              ELSE '❌ ' || (SELECT COUNT(*) FROM oct_bad) || ' 筆不是' END, ''
  UNION ALL SELECT 10, '修正之後，十月這一批品號有沒有新的帳',
         CASE WHEN (SELECT n FROM oct_diff) = 0 THEN '✅ 沒有' ELSE '⚠ 有 ' || (SELECT n FROM oct_diff) || ' 筆變動（兩邊合計）' END,
         '十月還在營業，新派車是正常的；但有的話，第 4 份還原會拒絕自動還原'
  UNION ALL SELECT 11, '十月月結有沒有被產生',
         CASE WHEN (SELECT n FROM oct_sms) = 0 THEN '✅ 0 張' ELSE 'ℹ ' || (SELECT n FROM oct_sms) || ' 張' END,
         '修正前後的張數：' || COALESCE((SELECT f.summary ->> '05b 十月（不產生月結）' FROM fx f), '')
           || '。修正檔不會產生十月月結；這裡如果不是 0，是有人在月結頁按了產生（修正前後都有可能），那幾張上面是按的當時的價，月底要重按產生月結'
  UNION ALL
  SELECT 1000 + ROW_NUMBER() OVER (ORDER BY d.store_id, d.entry_type, d.transfer_item_id, d.side)::int,
         '八月不同：' || CASE d.side WHEN 'now' THEN '現在' ELSE '備份' END,
         (SELECT code FROM st WHERE st.id = d.store_id) || '|' || d.entry_type || '|' || d.transfer_item_id,
         '時點 ' || to_char(d.booked_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') || '　數量 ' || trim_scale(d.qty) || '　單價 ' || trim_scale(d.unit_price)
    FROM aug_diff d
) z
ORDER BY "序"
LIMIT 500;

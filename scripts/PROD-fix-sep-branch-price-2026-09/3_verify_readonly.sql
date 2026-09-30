-- ============================================================================
--  九月錯價修正 3　驗算（只查不改）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-九月分店價錯價修正_2026-09-29.md（v2）第 3、8 節
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    修正（第 2 份）做完之後，用「另一次」重新檢查一遍（修正檔自己已經在同一次裡驗過，這份是事後再看一次）：
--      ・八月每一筆跟備份時的基準比，完全一樣
--      ・57 個品號的價格版本：9/1 起只有一個、就是正確價
--      ・九月每一筆帳、九月月結每一行，單價＝正確價；每張月結貨款＝每日對帳加總
--      ・修正之後有沒有人又動過這些資料（跟「改完之後的樣子」比）→ 有的話還原檔會拒絕自動還原
--      ・各店九月月結狀態（同盤點⑤：月結單上的錯價差額應該全部 0）
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
fx AS (SELECT * FROM ops_sep_price_fix.fix_log WHERE restored_at IS NULL ORDER BY fix_id DESC LIMIT 1),
lst AS (SELECT l.* FROM ops_sep_price_fix.sku_list l JOIN fx ON fx.bk_round = l.bk_round),
st AS (SELECT s.id, s.code, s.name FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id WHERE s.location_id IS NOT NULL),
aug_now AS (
  SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l
   WHERE l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT sku_id FROM lst)
),
aug_bk AS (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_sep_price_fix.aug_lines a JOIN fx ON fx.bk_round = a.bk_round),
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
sm AS (SELECT m.* FROM public.store_monthly_settlements m JOIN tn ON tn.tenant_id = m.tenant_id WHERE m.settlement_month = DATE '2026-09-01'),
item_bad AS (SELECT i.* FROM public.store_monthly_settlement_items i JOIN sm ON sm.id = i.settlement_id JOIN lst ON lst.sku_id = i.sku_id
              WHERE i.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND i.unit_branch_price <> lst.correct_price),
hdr_bad AS (SELECT sm.* FROM sm WHERE sm.branch_amount <> COALESCE((SELECT SUM(x.amount) FROM sep_now x WHERE x.store_id = sm.store_id), 0)),
price_bad AS (
  SELECT lst.* FROM lst, tn
   WHERE (SELECT COUNT(*) FROM public.prices p WHERE p.tenant_id = tn.tenant_id AND p.sku_id = lst.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
            AND (p.effective_to IS NULL OR p.effective_to > ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'))) <> 1
      OR NOT EXISTS (SELECT 1 FROM public.prices p WHERE p.tenant_id = tn.tenant_id AND p.sku_id = lst.sku_id AND p.scope = 'branch' AND p.scope_id IS NULL
            AND p.effective_from = ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei') AND p.effective_to IS NULL AND p.price = lst.correct_price)
),
after_now AS (
  SELECT 'prices' AS tbl, p.id AS pk, to_jsonb(p) AS j FROM public.prices p, tn WHERE p.tenant_id = tn.tenant_id AND p.scope = 'branch' AND p.sku_id IN (SELECT sku_id FROM lst)
  UNION ALL SELECT 'sms', s.id, to_jsonb(s) FROM public.store_monthly_settlements s, tn WHERE s.tenant_id = tn.tenant_id AND s.settlement_month = DATE '2026-09-01'
  UNION ALL SELECT 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT id FROM sm)
  UNION ALL SELECT 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a, tn WHERE a.tenant_id = tn.tenant_id AND a.settlement_month = DATE '2026-09-01'
  UNION ALL SELECT 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT id FROM sm)
),
after_ref AS (SELECT a.tbl, a.pk, a.j FROM ops_sep_price_fix.after_rows a JOIN fx ON fx.fix_id = a.fix_id),
after_diff AS (SELECT tbl, COUNT(*) AS n FROM ((SELECT * FROM after_now EXCEPT SELECT * FROM after_ref) UNION ALL (SELECT * FROM after_ref EXCEPT SELECT * FROM after_now)) d GROUP BY tbl),
sep_ref AS (SELECT store_id, entry_type, transfer_id, transfer_item_id, sku_id, qty, booked_at, unit_price, amount FROM ops_sep_price_fix.after_sept_lines a JOIN fx ON fx.fix_id = a.fix_id),
sep_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM sep_now EXCEPT SELECT * FROM sep_ref) UNION ALL (SELECT * FROM sep_ref EXCEPT SELECT * FROM sep_now)) d)
SELECT "序", "檢查", "結果", "說明"
FROM (
  SELECT 0 AS "序", (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT COUNT(*) FROM sk) <> 57 THEN '❌ 57 個品號只在系統找到 ' || (SELECT COUNT(*) FROM sk) || ' 個，這份結果不能用，請截圖給 CEO'
       ELSE '★ 總計（這一行就是結論）' END) AS "檢查",
         CASE WHEN NOT EXISTS (SELECT 1 FROM fx) THEN '❌ 找不到還沒還原的修正紀錄（第 2 份還沒做，或已經還原）' ELSE '修正編號 ' || (SELECT fix_id FROM fx) END AS "結果",
         '' AS "說明"
  UNION ALL SELECT 1, '八月逐筆跟備份基準一樣',
         CASE WHEN (SELECT COUNT(*) FROM aug_diff) = 0 THEN '✅ 一樣（' || (SELECT COUNT(*) FROM aug_now) || ' 筆）' ELSE '❌ 有 ' || (SELECT COUNT(*) FROM aug_diff) || ' 筆不同（兩邊合計）' END,
         '明細列在最下面（序 1001 起）'
  UNION ALL SELECT 2, '57 品號價格版本：9/1 起只有一個、是正確價',
         CASE WHEN (SELECT COUNT(*) FROM price_bad) = 0 THEN '✅' ELSE '❌ ' || (SELECT string_agg(sku_code, '、') FROM price_bad) END, ''
  UNION ALL SELECT 3, '九月每一筆帳（每日對帳）單價＝正確價',
         CASE WHEN (SELECT COUNT(*) FROM sep_bad) = 0 THEN '✅' ELSE '❌ ' || (SELECT COUNT(*) FROM sep_bad) || ' 筆不是' END, ''
  UNION ALL SELECT 4, '九月月結明細單價＝正確價（同盤點⑤「月結單上的錯價差額」＝0）',
         CASE WHEN (SELECT COUNT(*) FROM item_bad) = 0 THEN '✅' ELSE '❌ ' || (SELECT COUNT(*) FROM item_bad) || ' 行不是' END, ''
  UNION ALL SELECT 5, '每張九月月結貨款＝每日對帳加總',
         CASE WHEN (SELECT COUNT(*) FROM hdr_bad) = 0 THEN '✅' ELSE '⚠ ' || (SELECT COUNT(*) FROM hdr_bad) || ' 張不一樣' END,
         '修正後又有新派車／收貨，而月結還沒重按，就會出現 ⚠（正常營運，不是修壞）'
  UNION ALL SELECT 6, '修正之後，價格／月結／調整／爭議有沒有人又動過',
         CASE WHEN NOT EXISTS (SELECT 1 FROM after_diff) THEN '✅ 沒有' ELSE '⚠ ' || (SELECT string_agg(tbl || ' ' || n || ' 筆', '、') FROM after_diff) END,
         '有動過的話，第 4 份還原會拒絕自動還原（要人工對帳）'
  UNION ALL SELECT 7, '修正之後，九月有沒有新的派車／收貨／退貨／店轉店',
         CASE WHEN (SELECT n FROM sep_diff) = 0 THEN '✅ 沒有' ELSE '⚠ 有 ' || (SELECT n FROM sep_diff) || ' 筆變動（兩邊合計）' END,
         '有的話，第 4 份還原會拒絕自動還原'
  UNION ALL SELECT 8, '九月月結狀態',
         '草稿 ' || (SELECT COUNT(*) FROM sm WHERE status = 'draft') || '／已寄出以後 ' || (SELECT COUNT(*) FROM sm WHERE status <> 'draft') || '／共 ' || (SELECT COUNT(*) FROM sm),
         '修正紀錄：' || COALESCE((SELECT f.summary ->> '06 本次新建的九月月結' FROM fx f), '')
  UNION ALL
  SELECT 1000 + ROW_NUMBER() OVER (ORDER BY d.store_id, d.entry_type, d.transfer_item_id, d.side)::int,
         '八月不同：' || CASE d.side WHEN 'now' THEN '現在' ELSE '備份' END,
         (SELECT code FROM st WHERE st.id = d.store_id) || '|' || d.entry_type || '|' || d.transfer_item_id,
         '時點 ' || to_char(d.booked_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') || '　數量 ' || trim_scale(d.qty) || '　單價 ' || trim_scale(d.unit_price)
    FROM aug_diff d
) z
ORDER BY "序"
LIMIT 500;

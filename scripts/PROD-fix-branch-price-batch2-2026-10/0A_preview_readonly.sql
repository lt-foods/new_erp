-- ============================================================================
--  第二批分店價錯價修正 0-A　預覽（只查不改）
--  日期：2026-10-07　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-第二批分店價錯價修正_九月十月_2026-10-07.md、派工單-第二批分店價錯價修正指令_2026-10-07.md
--  範本：第一批 NEW-ERP九月錯價修正_2026-09-29_0-A（9/30 已在正式系統跑過）；只改清單、加十月、基準改成 10/7
--  程式出處：唯讀鏡像 origin/main 500ecc32 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    每一家店的九月月結，列出三個數字給你比：
--      ①「現在存著的草稿」：最後一次產生九月月結時存下來的金額
--        （10/7 盤點時：18 張全是草稿、應收合計 3,507,154、最後異動 10/01 09:25）
--      ②「照今天的資料、還是錯價」重算會是多少
--      ③「照今天的資料、改成正確價」重算會是多少
--    再拆成兩段：
--      「改價造成的差」＝ ③ − ②　← 這次修正要改的
--      「其他異動造成的差」＝ ② − ①　← 草稿存下來之後別的事（新派車、收貨、退貨、店轉店、人工調整）造成的，
--        修正檔重產九月月結時「也會一起進來」，這段你要先看懂再說「走」（逐筆拆解看 0-E、0-F）
--    另外多一欄「十月到現在：改價造成的差」：十月（10/1 00:00 台北時間 ～ 貼的當下）這批品號照正確價重算差多少。
--      ⛔ 修正不會產生十月月結；這一欄只會反映在店家每日進貨對帳，月底產生十月月結時自然用正確價。
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：Supabase → SQL Editor → 整份貼上 → Run → 右上角下載 CSV 給 CEO。
--  ★ 看到什麼要停：
--    ・第一列寫 ❌ → 不要往下做，截圖給 CEO
--      （清單裡還有佔位、有重複、或有品號在系統查不到時，這份「一個數字都不算」，只出第一列）
--    ・「目前狀態」有任何一家不是「草稿」→ 修正檔一定會停下來，先截圖給 CEO
--    ・「其他異動造成的差」金額很大、你看不懂 → 先停，問 CEO
--    ・還沒產生月結的店，如果「照今天資料重算」不是 0 → 修正時會「新建一張草稿」給它（下面會標）
--    ・第一列「這代表」寫「跟 10/7 盤點不一樣」→ 不一定是錯，但先問 CEO
--  ★ 出處：重算用店家每日進貨對帳同一支 _store_inbound_lines（20260901000000:597-742），
--    金額＝各行 amount 加總＋有效人工調整，與月結產生器 v_payable := v_branch_total + v_adjust 同口徑
--    （20260901000000:277，正式系統用的就是這一版；20260907030000:898 同）。
--    ⚠ 0-B 裡如果你決定作廢某幾筆人工調整，③ 還會再變（這份沒有扣掉作廢的）。
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
gate AS (   -- 有任何一項不對 → err 有值 → 下面一家店都不算
  SELECT CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
              WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
              WHEN lchk.n_ph > 0 THEN '❌ 清單裡還有佔位（' || lchk.ph || '），要等老闆確認、CEO 換成真正的規格編號；這份不算任何數字'
              WHEN lchk.n_dup > 0 THEN '❌ 清單裡有 ' || lchk.n_dup || ' 個重複的品號，請截圖給 CEO；這份不算任何數字'
              WHEN lchk.n_miss > 0 THEN '❌ 清單 ' || lchk.n_list || ' 個規格有 ' || lchk.n_miss || ' 個在系統查不到（' || lchk.miss || '），請截圖給 CEO；這份不算任何數字'
              END AS err
    FROM lchk
),
st AS (
  SELECT s.id, s.code, s.name, s.is_active FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id
   WHERE s.location_id IS NOT NULL AND (SELECT err FROM gate) IS NULL
),
ln AS (   -- 九月每一行（全部商品、全部類型）
  SELECT st.id AS store_id, l.sku_id, l.entry_type, l.qty, l.amount
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l
),
lx AS (
  SELECT ln.store_id, ln.amount AS amt_wrong,
         CASE WHEN sk.sku_id IS NOT NULL AND ln.entry_type IN ('hq_inbound','air_in','air_out','return_out')
              THEN (CASE WHEN ln.entry_type IN ('air_out','return_out') THEN -1 ELSE 1 END) * ln.qty * sk.correct_price
              ELSE ln.amount END AS amt_ok
    FROM ln LEFT JOIN sk ON sk.sku_id = ln.sku_id
),
lsum AS (SELECT store_id, SUM(amt_wrong) AS b_wrong, SUM(amt_ok) AS b_ok, COUNT(*) AS n FROM lx GROUP BY store_id),
ln10 AS (   -- 十月（10/1 00:00 台北時間 ～ 現在）這批品號的每一行
  SELECT st.id AS store_id, l.entry_type, l.qty, l.amount, sk.correct_price
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei'), now()) l
    JOIN sk ON sk.sku_id = l.sku_id
   WHERE l.entry_type IN ('hq_inbound','air_in','air_out','return_out')
),
osum AS (
  SELECT store_id,
         SUM((CASE WHEN entry_type IN ('air_out','return_out') THEN -1 ELSE 1 END) * qty * correct_price - amount) AS d_oct
    FROM ln10 GROUP BY store_id
),
adj AS (
  SELECT a.store_id, SUM(a.amount) AS adj, COUNT(*) AS n_adj
    FROM public.store_settlement_adjustments a JOIN tn ON tn.tenant_id = a.tenant_id
   WHERE a.settlement_month = DATE '2026-09-01' AND a.status = 'active'
   GROUP BY a.store_id
),
sm AS (
  SELECT m.* FROM public.store_monthly_settlements m JOIN tn ON tn.tenant_id = m.tenant_id
   WHERE m.settlement_month = DATE '2026-09-01'
),
base AS (   -- 跟 10/7 盤點（老闆 10/7 00:04 貼回的⑤）比：18 張全草稿、應收合計 3,507,154、最後異動 10/01 09:25
  SELECT COUNT(*) AS n, COUNT(*) FILTER (WHERE status = 'draft') AS n_draft, COALESCE(SUM(payable_amount), 0) AS pay,
         COALESCE(to_char(MAX(updated_at) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '—') AS last_at
    FROM sm
),
d AS (
  SELECT st.code, st.name, st.is_active, sm.id AS sm_id, sm.status, sm.payable_amount, sm.branch_amount, sm.adjustment_amount, sm.updated_at,
         COALESCE(lsum.b_wrong, 0) AS b_wrong, COALESCE(lsum.b_ok, 0) AS b_ok, COALESCE(lsum.n, 0) AS n_lines,
         COALESCE(adj.adj, 0) AS adj, COALESCE(adj.n_adj, 0) AS n_adj,
         COALESCE(lsum.b_wrong, 0) + COALESCE(adj.adj, 0) AS pay_wrong,
         COALESCE(lsum.b_ok, 0) + COALESCE(adj.adj, 0)    AS pay_ok,
         COALESCE(osum.d_oct, 0) AS d_oct
    FROM st
    LEFT JOIN lsum ON lsum.store_id = st.id
    LEFT JOIN osum ON osum.store_id = st.id
    LEFT JOIN adj  ON adj.store_id  = st.id
    LEFT JOIN sm   ON sm.store_id   = st.id
)
SELECT "店代號", "店名", "目前狀態", "①現在存著的草稿：應收", "草稿最後異動時間",
       "②今天資料＋錯價重算：應收", "③今天資料＋正確價重算：應收",
       "改價造成的差（③−②）", "其他異動造成的差（②−①）", "其中：有效人工調整",
       "十月到現在：改價造成的差（不產生十月月結）", "這代表"
FROM (
  SELECT 0 AS ord, '' AS k,
         COALESCE((SELECT err FROM gate), '★ 總計（這一行就是結論）') AS "店代號",
         COUNT(*) || ' 家店（有綁倉庫的）' AS "店名",
         '草稿 ' || COUNT(*) FILTER (WHERE d.status = 'draft') || ' 家／不是草稿 ' || COUNT(*) FILTER (WHERE d.status IS NOT NULL AND d.status <> 'draft')
           || ' 家／還沒產生 ' || COUNT(*) FILTER (WHERE d.sm_id IS NULL) || ' 家' AS "目前狀態",
         trim_scale(SUM(d.payable_amount)) AS "①現在存著的草稿：應收",
         (SELECT last_at FROM base) AS "草稿最後異動時間",
         trim_scale(SUM(d.pay_wrong)) AS "②今天資料＋錯價重算：應收",
         trim_scale(SUM(d.pay_ok)) AS "③今天資料＋正確價重算：應收",
         trim_scale(SUM(d.pay_ok - d.pay_wrong)) AS "改價造成的差（③−②）",
         trim_scale(SUM(d.pay_wrong - COALESCE(d.payable_amount, 0))) AS "其他異動造成的差（②−①）",
         trim_scale(SUM(d.adj)) AS "其中：有效人工調整",
         trim_scale(SUM(d.d_oct)) AS "十月到現在：改價造成的差（不產生十月月結）",
         CASE WHEN (SELECT err FROM gate) IS NOT NULL
              THEN '⛔ 先停：清單或公司不對，這份沒有算任何數字'
              WHEN COUNT(*) FILTER (WHERE d.status IS NOT NULL AND d.status <> 'draft') > 0
              THEN '🔴 有店的九月月結已經不是草稿，修正檔會停下來，先截圖給 CEO'
              ELSE '全部草稿（或還沒產生）；會新建草稿的店 '
                   || COUNT(*) FILTER (WHERE d.sm_id IS NULL AND (d.b_wrong <> 0 OR d.b_ok <> 0 OR d.adj <> 0)) || ' 家' END
           || '｜10/7 盤點：九月月結 18 張全草稿、應收 3,507,154、最後異動 2026-10-01 09:25；現在 '
           || (SELECT n FROM base) || ' 張（草稿 ' || (SELECT n_draft FROM base) || ' 張）、應收 ' || trim_scale((SELECT pay FROM base))
           || '、最後異動 ' || (SELECT last_at FROM base)
           || CASE WHEN (SELECT n = 18 AND n_draft = 18 AND pay = 3507154 AND last_at = '2026-10-01 09:25' FROM base)
                   THEN '（一樣）' ELSE '（⚠ 跟 10/7 盤點不一樣，先問 CEO）' END AS "這代表"
    FROM d
  UNION ALL
  SELECT 1, d.code,
         d.code, d.name || CASE WHEN d.is_active THEN '' ELSE '（已停用）' END,
         CASE WHEN d.sm_id IS NULL THEN '還沒產生' WHEN d.status = 'draft' THEN '草稿' ELSE '🔴 ' || d.status END,
         trim_scale(d.payable_amount),
         to_char(d.updated_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'),
         trim_scale(d.pay_wrong), trim_scale(d.pay_ok),
         trim_scale(d.pay_ok - d.pay_wrong),
         trim_scale(d.pay_wrong - COALESCE(d.payable_amount, 0)),
         trim_scale(d.adj),
         trim_scale(d.d_oct),
         CASE WHEN d.status IS NOT NULL AND d.status <> 'draft' THEN '🔴 不是草稿：修正檔會整筆停下來'
              WHEN d.sm_id IS NULL AND (d.b_wrong <> 0 OR d.b_ok <> 0 OR d.adj <> 0) THEN '⚠ 現在沒有九月月結；修正時會新建一張草稿'
              WHEN d.sm_id IS NULL THEN '沒有九月帳，修正時也不會建'
              WHEN d.pay_wrong - d.payable_amount <> 0 THEN '⚠ 草稿存下來之後有其他異動，重產時會一起進來'
              ELSE '' END
    FROM d
) z
ORDER BY ord, k;

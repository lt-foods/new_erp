-- ============================================================================
--  九月錯價修正 0-A　預覽（只查不改）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-九月分店價錯價修正_2026-09-29.md（v2）第 3、8 節
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    每一家店的九月月結，列出三個數字給你比：
--      ①「現在存著的草稿」：9/27 按產生月結時存下來的金額（如果之後有人重按過，就是那一次的）
--      ②「照今天的資料、還是錯價」重算會是多少
--      ③「照今天的資料、改成正確價」重算會是多少
--    再拆成兩段：
--      「改價造成的差」＝ ③ − ②　← 這次修正要改的
--      「其他異動造成的差」＝ ② − ①　← 9/27 之後別的事（新派車、收貨、退貨、店轉店、人工調整）造成的，
--        修正檔重產月結時「也會一起進來」，這段你要先看懂再說「走」
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：Supabase → SQL Editor → 整份貼上 → Run → 右上角下載 CSV 給 CEO。
--  ★ 看到什麼要停：
--    ・第一列寫 ❌ → 不要往下做，截圖給 CEO
--    ・「目前狀態」有任何一家不是「草稿」→ 修正檔一定會停下來，先截圖給 CEO
--    ・「其他異動造成的差」金額很大、你看不懂 → 先停，問 CEO
--    ・還沒產生月結的店，如果「照今天資料重算」不是 0 → 修正時會「新建一張草稿」給它（下面會標）
--  ★ 出處：重算用店家每日進貨對帳同一支 _store_inbound_lines（20260901000000:597-742），
--    金額＝各行 amount 加總＋有效人工調整，與月結產生器 v_payable := v_branch_total + v_adjust 同口徑
--    （20260907030000:895-898；9/26 正式庫是 20260901000000:74 那版，兩版這一段相同）。
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
st AS (
  SELECT s.id, s.code, s.name, s.is_active FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id
   WHERE s.location_id IS NOT NULL
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
d AS (
  SELECT st.code, st.name, st.is_active, sm.id AS sm_id, sm.status, sm.payable_amount, sm.branch_amount, sm.adjustment_amount, sm.updated_at,
         COALESCE(lsum.b_wrong, 0) AS b_wrong, COALESCE(lsum.b_ok, 0) AS b_ok, COALESCE(lsum.n, 0) AS n_lines,
         COALESCE(adj.adj, 0) AS adj, COALESCE(adj.n_adj, 0) AS n_adj,
         COALESCE(lsum.b_wrong, 0) + COALESCE(adj.adj, 0) AS pay_wrong,
         COALESCE(lsum.b_ok, 0) + COALESCE(adj.adj, 0)    AS pay_ok
    FROM st
    LEFT JOIN lsum ON lsum.store_id = st.id
    LEFT JOIN adj  ON adj.store_id  = st.id
    LEFT JOIN sm   ON sm.store_id   = st.id
)
SELECT "店代號", "店名", "目前狀態", "①現在存著的草稿：應收", "草稿最後異動時間",
       "②今天資料＋錯價重算：應收", "③今天資料＋正確價重算：應收",
       "改價造成的差（③−②）", "其他異動造成的差（②−①）", "其中：有效人工調整", "這代表"
FROM (
  SELECT 0 AS ord, '' AS k,
         (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT COUNT(*) FROM sk) <> 57 THEN '❌ 57 個品號只在系統找到 ' || (SELECT COUNT(*) FROM sk) || ' 個，這份結果不能用，請截圖給 CEO'
       ELSE '★ 總計（這一行就是結論）' END) AS "店代號",
         COUNT(*) || ' 家店（有綁倉庫的）' AS "店名",
         '草稿 ' || COUNT(*) FILTER (WHERE d.status = 'draft') || ' 家／不是草稿 ' || COUNT(*) FILTER (WHERE d.status IS NOT NULL AND d.status <> 'draft')
           || ' 家／還沒產生 ' || COUNT(*) FILTER (WHERE d.sm_id IS NULL) || ' 家' AS "目前狀態",
         trim_scale(SUM(d.payable_amount)) AS "①現在存著的草稿：應收",
         '' AS "草稿最後異動時間",
         trim_scale(SUM(d.pay_wrong)) AS "②今天資料＋錯價重算：應收",
         trim_scale(SUM(d.pay_ok)) AS "③今天資料＋正確價重算：應收",
         trim_scale(SUM(d.pay_ok - d.pay_wrong)) AS "改價造成的差（③−②）",
         trim_scale(SUM(d.pay_wrong - COALESCE(d.payable_amount, 0))) AS "其他異動造成的差（②−①）",
         trim_scale(SUM(d.adj)) AS "其中：有效人工調整",
         CASE WHEN COUNT(*) FILTER (WHERE d.status IS NOT NULL AND d.status <> 'draft') > 0
              THEN '🔴 有店的九月月結已經不是草稿，修正檔會停下來，先截圖給 CEO'
              ELSE '全部草稿（或還沒產生）；會新建草稿的店 '
                   || COUNT(*) FILTER (WHERE d.sm_id IS NULL AND (d.b_wrong <> 0 OR d.b_ok <> 0 OR d.adj <> 0)) || ' 家' END AS "這代表"
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
         CASE WHEN d.status IS NOT NULL AND d.status <> 'draft' THEN '🔴 不是草稿：修正檔會整筆停下來'
              WHEN d.sm_id IS NULL AND (d.b_wrong <> 0 OR d.b_ok <> 0 OR d.adj <> 0) THEN '⚠ 現在沒有九月月結；修正時會新建一張草稿'
              WHEN d.sm_id IS NULL THEN '沒有九月帳，修正時也不會建'
              WHEN d.pay_wrong - d.payable_amount <> 0 THEN '⚠ 9/27 之後有其他異動，重產時會一起進來'
              ELSE '' END
    FROM d
) z
ORDER BY ord, k;

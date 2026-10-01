-- ============================================================================
--  九月錯價修正 0-F　「新派車／新店轉店／新退貨」按日期拆開（只查不改）
--  日期：2026-09-30　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：CEO 9/30 派工；0-E 結果 (13).csv：01 新派車 358 筆＝80,591 元、05 新店轉店 10 筆＝0 元、07 新退貨 1 筆＝−101 元
--  程式出處：分類的 CTE 逐字沿用 0-E（NEW-ERP九月錯價修正_2026-09-29_0-E【唯讀】九月其他異動拆解.sql，
--            WITH 到 allp 為止），所以分類口徑跟 0-E 完全一樣
-- ============================================================================
--  ★ 這份在做什麼
--    0-E 只列了金額最大的 100 筆，看起來都在 9/29 下午。這份把 0-E 的
--      01 新派車（9/27 草稿之後才派）、05 新店轉店、07 新退貨
--    「全部」的筆數，按台北日期（計價時點＝派車／轉出／總倉收退貨那一刻）拆開：
--    每一天、每一類有幾筆、多少錢、當天最早和最晚的時間。
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：整份貼上 → Run → 下載 CSV 給 CEO。
--  ★ 怎麼看：
--    ・第一列（區段 0）：三類按日期加起來的筆數、金額，跟「同一份資料照 0-E 分類的各類合計」比，一樣＝✅、不一樣＝❌。
--      另外對照你 9/30 貼回的 0-E（(13).csv）數字；今天又有新派車的話會不一樣，那不算錯（會寫「資料又變了」）。
--    ・區段 1：各類合計；區段 2：每一天 × 每一類。
--  ★ 看到什麼要停：第一列 ❌ → 截圖給 CEO。
--  ⚠ 01 的分界（草稿時間）跟 0-E 一樣，是用月結表頭目前的 updated_at 推估。
-- ============================================================================

WITH
tchk AS (   -- 只認「包子媽生鮮小舖」一家（同 0-A～0-D）
  SELECT COUNT(*) AS n FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖'
),
tn AS (
  SELECT t.id AS tenant_id FROM public.tenants t CROSS JOIN tchk
   WHERE tchk.n = 1 AND regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖'
),
st AS (SELECT s.id, s.code, s.name FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id WHERE s.location_id IS NOT NULL),
sm AS (
  SELECT m.* FROM public.store_monthly_settlements m JOIN tn ON tn.tenant_id = m.tenant_id
   WHERE m.settlement_month = DATE '2026-09-01'
),
it AS (   -- 9/27 草稿明細（快照）
  SELECT sm.store_id, i.entry_type, i.transfer_id, i.transfer_item_id, i.sku_id,
         i.qty_received AS qty, i.unit_branch_price AS p, i.branch_amount AS a, i.received_at AS t
    FROM public.store_monthly_settlement_items i JOIN sm ON sm.id = i.settlement_id
),
ln AS (   -- 今天照錯價重算的每一行
  SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id,
         l.qty, l.unit_branch_price AS p, l.amount AS a, l.received_at AS t
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-10-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l
),
itg AS (   -- 先依配對鍵彙總，避免重複鍵讓 FULL JOIN 放大
  SELECT store_id, entry_type, transfer_item_id,
         MIN(transfer_id) AS transfer_id, MIN(sku_id) AS sku_id,
         SUM(qty) AS qty, CASE WHEN MIN(p) = MAX(p) THEN MIN(p) END AS p, SUM(a) AS a, MIN(t) AS t, COUNT(*) AS n
    FROM it GROUP BY store_id, entry_type, transfer_item_id
),
lng AS (
  SELECT store_id, entry_type, transfer_item_id,
         MIN(transfer_id) AS transfer_id, MIN(sku_id) AS sku_id,
         SUM(qty) AS qty, CASE WHEN MIN(p) = MAX(p) THEN MIN(p) END AS p, SUM(a) AS a, MIN(t) AS t, COUNT(*) AS n
    FROM ln GROUP BY store_id, entry_type, transfer_item_id
),
dup AS (   -- 重複鍵清單
  SELECT '9/27 草稿' AS side, store_id, entry_type, transfer_item_id, n FROM itg WHERE n > 1
  UNION ALL
  SELECT '今天重算', store_id, entry_type, transfer_item_id, n FROM lng WHERE n > 1
),
j AS (
  SELECT COALESCE(ln.store_id, it.store_id) AS store_id,
         COALESCE(ln.entry_type, it.entry_type) AS et,
         COALESCE(ln.transfer_id, it.transfer_id) AS tid,
         COALESCE(ln.transfer_item_id, it.transfer_item_id) AS tii,
         COALESCE(ln.sku_id, it.sku_id) AS sku_id,
         it.qty AS q0, ln.qty AS q1, it.p AS p0, ln.p AS p1,
         COALESCE(it.a, 0) AS a0, COALESCE(ln.a, 0) AS a1, it.t AS t0, ln.t AS t1,
         (it.transfer_item_id IS NOT NULL) AS in0, (ln.transfer_item_id IS NOT NULL) AS in1,
         CASE WHEN COALESCE(ln.entry_type, it.entry_type) IN ('air_out','return_out') THEN -1 ELSE 1 END AS sg,
         (COALESCE(it.n, 0) > 1 OR COALESCE(ln.n, 0) > 1) AS is_dup
    FROM lng ln FULL JOIN itg it
      ON it.store_id = ln.store_id AND it.entry_type = ln.entry_type AND it.transfer_item_id = ln.transfer_item_id
),
jx AS (SELECT j.*, sm.updated_at AS snap FROM j LEFT JOIN sm ON sm.store_id = j.store_id),
parts AS (   -- 每一行拆成「類別＋金額」
  -- 只在今天有
  SELECT jx.*, CASE
           WHEN et = 'hq_inbound' AND (snap IS NULL OR t1 >= snap) THEN '01 新派車（9/27 草稿之後才派）'
           WHEN et = 'hq_inbound' THEN '02 派車：9/27 前的單、當時沒算進草稿'
           WHEN et IN ('air_in','air_out') THEN '05 新店轉店'
           WHEN et = 'return_out' THEN '07 新退貨'
           ELSE '09 自由轉貨（新增／消失／估價改）' END AS cat,
         a1 AS amt
    FROM jx WHERE in1 AND NOT in0 AND NOT is_dup
  UNION ALL
  -- 只在 9/27 草稿有
  SELECT jx.*, CASE
           WHEN et = 'hq_inbound' THEN '04 派車單從月結消失（取消等）'
           WHEN et IN ('air_in','air_out') THEN '06 店轉店：數量變或消失'
           WHEN et = 'return_out' THEN '08 退貨：數量變或消失'
           ELSE '09 自由轉貨（新增／消失／估價改）' END,
         -a0
    FROM jx WHERE in0 AND NOT in1 AND NOT is_dup
  UNION ALL
  -- 兩邊都有：數量效果（用 9/27 的單價）
  SELECT jx.*, CASE
           WHEN et = 'hq_inbound' THEN '03 派車數量變（實收量變，取較大者）'
           WHEN et IN ('air_in','air_out') THEN '06 店轉店：數量變或消失'
           ELSE '08 退貨：數量變或消失' END,
         sg * (q1 - q0) * p0
    FROM jx WHERE in0 AND in1 AND NOT is_dup AND et IN ('hq_inbound','air_in','air_out','return_out')
  UNION ALL
  -- 兩邊都有：單價效果（用今天的數量）
  SELECT jx.*, '10 單價變（9/27 後改價或計價時點變）', sg * q1 * (p1 - p0)
    FROM jx WHERE in0 AND in1 AND NOT is_dup AND et IN ('hq_inbound','air_in','air_out','return_out')
  UNION ALL
  -- 兩邊都有：自由轉貨（估價）
  SELECT jx.*, '09 自由轉貨（新增／消失／估價改）', a1 - a0
    FROM jx WHERE in0 AND in1 AND NOT is_dup AND et NOT IN ('hq_inbound','air_in','air_out','return_out')
  UNION ALL
  -- 重複鍵：無法細分，整筆差額
  SELECT jx.*, '13 重複鍵（無法細分）', a1 - a0
    FROM jx WHERE is_dup
),
adj AS (
  SELECT a.store_id, SUM(a.amount) AS adj
    FROM public.store_settlement_adjustments a JOIN tn ON tn.tenant_id = a.tenant_id
   WHERE a.settlement_month = DATE '2026-09-01' AND a.status = 'active'
   GROUP BY a.store_id
),
hdr AS (   -- 表頭層級的兩類
  SELECT st.id AS store_id,
         COALESCE(adj.adj, 0) - COALESCE(sm.adjustment_amount, 0) AS d_adj,
         (COALESCE((SELECT SUM(it.a) FROM it WHERE it.store_id = st.id), 0) - COALESCE(sm.branch_amount, 0))
           + (COALESCE(sm.branch_amount, 0) + COALESCE(sm.adjustment_amount, 0) - COALESCE(sm.payable_amount, 0)) AS d_other
    FROM st LEFT JOIN sm ON sm.store_id = st.id LEFT JOIN adj ON adj.store_id = st.id
),
allp AS (
  SELECT store_id, cat, amt, 1 AS n FROM parts WHERE amt <> 0
  UNION ALL SELECT store_id, '11 人工調整變動', d_adj, 1 FROM hdr WHERE d_adj <> 0
  UNION ALL SELECT store_id, '12 其他（草稿表頭跟明細對不上）', d_other, 1 FROM hdr WHERE d_other <> 0
),
sel AS (   -- 0-E 的 01／05／07 三類（全部筆數，不只前 100）
  SELECT p.cat, p.amt, p.t1,
         to_char(p.t1 AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD') AS d
    FROM parts p
   WHERE p.amt <> 0
     AND (p.cat LIKE '01 %' OR p.cat LIKE '05 %' OR p.cat LIKE '07 %')
),
cat_all AS (   -- 同一份資料照 0-E 分類的各類合計（0-E 區段 1 的算法：allp 按類別加總）
  SELECT cat, SUM(amt) AS amt, COUNT(*) AS n FROM allp
   WHERE cat LIKE '01 %' OR cat LIKE '05 %' OR cat LIKE '07 %'
   GROUP BY cat
),
by_day AS (
  SELECT d, cat, COUNT(*) AS n, SUM(amt) AS amt, MIN(t1) AS t_min, MAX(t1) AS t_max FROM sel GROUP BY d, cat
),
day_sum AS (SELECT cat, SUM(n) AS n, SUM(amt) AS amt FROM by_day GROUP BY cat),
ref(cat_prefix, n, amt) AS (   -- 老闆 9/30 貼回的 0-E（(13).csv）
  VALUES ('01', 358, 80591), ('05', 10, 0), ('07', 1, -101)
),
chk AS (
  SELECT
    NOT EXISTS (SELECT 1 FROM cat_all c FULL JOIN day_sum s ON s.cat = c.cat
                 WHERE c.cat IS NULL OR s.cat IS NULL OR c.n <> s.n OR c.amt <> s.amt) AS same_as_0e,
    NOT EXISTS (SELECT 1 FROM ref r LEFT JOIN cat_all c ON left(c.cat, 2) = r.cat_prefix
                 WHERE COALESCE(c.n, 0) <> r.n OR COALESCE(c.amt, 0) <> r.amt) AS same_as_csv
)
SELECT "區段", "日期", "類別", "筆數", "金額", "當天最早", "當天最晚", "說明"
FROM (
  SELECT 0 AS o1, '' AS o2, '' AS o3,
         '0 總計' AS "區段",
         CASE WHEN (SELECT n FROM tchk) <> 1 THEN '❌ 找不到（或不只一家）包子媽生鮮小舖，這份結果不能用'
              ELSE '★ 總計（這一行就是結論）' END AS "日期",
         CASE WHEN (SELECT same_as_0e FROM chk) THEN '✅ 按日期加總＝0-E 各類合計（同一份資料）'
              ELSE '❌ 按日期加總跟 0-E 各類合計對不上，截圖給 CEO' END AS "類別",
         (SELECT COALESCE(SUM(n), 0) FROM by_day) AS "筆數",
         trim_scale((SELECT COALESCE(SUM(amt), 0) FROM by_day)) AS "金額",
         '' AS "當天最早", '' AS "當天最晚",
         CASE WHEN (SELECT same_as_csv FROM chk) THEN '跟 9/30 貼回的 0-E（(13).csv：01＝358 筆 80,591、05＝10 筆 0、07＝1 筆 −101）一樣'
              ELSE '跟 9/30 貼回的 0-E（(13).csv：01＝358 筆 80,591、05＝10 筆 0、07＝1 筆 −101）不一樣：貼回之後資料又變了（例如又有新派車），以今天這份為準' END AS "說明"
  UNION ALL
  SELECT 1, '', c.cat, '1 各類合計', '', c.cat, c.n, trim_scale(c.amt), '', '',
         '按日期加起來：' || COALESCE(s.n, 0) || ' 筆、' || COALESCE(trim_scale(s.amt), 0) || ' 元'
           || CASE WHEN s.n = c.n AND s.amt = c.amt THEN '　✅' ELSE '　❌' END
    FROM cat_all c LEFT JOIN day_sum s ON s.cat = c.cat
  UNION ALL
  SELECT 2, b.d, b.cat, '2 每天×每類', b.d, b.cat, b.n, trim_scale(b.amt),
         to_char(b.t_min AT TIME ZONE 'Asia/Taipei', 'HH24:MI'), to_char(b.t_max AT TIME ZONE 'Asia/Taipei', 'HH24:MI'), ''
    FROM by_day b
) z
ORDER BY o1, o2, o3;

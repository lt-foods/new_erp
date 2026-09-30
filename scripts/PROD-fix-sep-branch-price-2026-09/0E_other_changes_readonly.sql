-- ============================================================================
--  九月錯價修正 0-E　「其他異動造成的差」從哪裡來（只查不改）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：CEO 9/29 第 4 輪派工（老闆尚未授權貼備份或修正）
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    0-A 的「其他異動造成的差（②−①）」總計 80,490 元（9/29 老闆貼回的 (10).csv）。
--    這份把每家店「9/27 15:48 存下來的草稿明細」跟「今天照同一套算法（還是錯價）重算的每一行」逐行對起來，
--    把差額拆成下面幾類（金額正的＝重產後店家要多付，負的＝少付）：
--       1 新派車（9/27 草稿之後才派出去的）
--       2 派車：9/27 以前的單，但當時沒算進草稿（之後才改成已派車／已收貨）
--       3 派車數量變（之後收貨多收，算錢數量取「派出量、實收量」較大的那個）
--       4 派車單從月結消失（取消，或改成經總倉互助等）
--       5 新店轉店（收進＋轉出）
--       6 店轉店：數量變或消失
--       7 新退貨（總倉 9/27 之後才收到）
--       8 退貨：數量變或消失
--       9 自由轉貨（新增、消失、估價改了）
--      10 單價變（9/27 之後有人改價，或計價時點變了，同一筆帳查到不同價）
--      11 人工調整變動（照 0-B 應該是 0）
--      12 其他（草稿表頭跟草稿明細本來就對不上）
--      13 重複鍵（同一店＋類型＋明細編號在草稿或今天出現不只一行，無法細分；整筆差額放這裡，第一列會 ❌）
--    ⚠ 分類是「金額效果」拆解，不是「一筆明細只歸一類」：同一筆明細如果數量和單價都變了，
--      會拆成 03（或 06、08）的數量效果＋10 的單價效果兩筆金額。各類金額加總仍然等於總差額。
--    ⚠ 01「新派車」和 02「當時沒算進草稿」的分界：沒有固定的快照時間，這份用「月結表頭目前的最後異動時間（updated_at）」推估
--      9/27 草稿的時間。表頭如果之後被碰過（送出、撤回、加調整…），分界會往後移，但 01＋02 的合計和總數不受影響。
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：整份貼上 → Run → 下載 CSV 給 CEO（結果可能超過畫面筆數，請下載）。
--  ★ 怎麼看：
--    ・第一列（區段 0）：各類加總、跟「照 0-A 同一條公式直接算的總差額」比。兩個一樣＝✅；不一樣＝❌（會寫差多少）。
--      另外列出 0-A 當時的 80,490，今天重跑數字可能因為今天又有新派車而不同，這不算錯。
--    ・區段 1：各類合計（全部店加起來）
--    ・區段 2：各店×各類（只列金額不是 0 的）
--    ・區段 3：金額最大的前 100 筆明細（派車單號、計價時點、品號、數量、單價、金額）
--  ★ 看到什麼要停：第一列 ❌ → 截圖給 CEO（有重複鍵時，區段 4 會列出是哪些鍵）。
--  ★ 口徑出處：
--    ・草稿明細 store_monthly_settlement_items（20260512000009:59-71；entry_type 20260714000100:44-52；
--      unit_branch_price／branch_amount 20260715000000:71-73）。產生器存明細時，數量欄存的是「算錢數量」、時間欄存的是「這筆帳成立的時間」
--      （20260901000000 產生器 A 段註解；20260907030000:997-1000 同）。
--    ・今天重算用店家每日對帳同一支 _store_inbound_lines（20260901000000:597-742），與產生器同口徑（正式庫已核對，確認月結算法第 8 項 ✅）。
--    ・0-A 公式：② − ① ＝（今天每一行金額加總＋有效人工調整）−（草稿表頭「應收」）。
--    ・逐行配對鍵：店＋類型＋明細編號（transfer_item_id）。
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
direct AS (   -- 照 0-A 同一條公式直接算
  SELECT SUM(COALESCE((SELECT SUM(ln.a) FROM ln WHERE ln.store_id = st.id), 0) + COALESCE(adj.adj, 0) - COALESCE(sm.payable_amount, 0)) AS d
    FROM st LEFT JOIN sm ON sm.store_id = st.id LEFT JOIN adj ON adj.store_id = st.id
),
tot AS (SELECT COALESCE(SUM(amt), 0) AS s FROM allp),
top_rows AS (
  SELECT p.*, ROW_NUMBER() OVER (ORDER BY abs(p.amt) DESC, p.store_id, p.tii) AS rk
    FROM parts p WHERE p.amt <> 0
)
SELECT "區段", "店代號", "店名", "類別", "金額", "筆數", "派車單號", "計價時點", "品號", "數量（9/27→今天）", "單價（9/27→今天）", "說明"
FROM (
  SELECT 0 AS o1, 0::bigint AS o2, '' AS o3,
         '0 總計' AS "區段",
         CASE WHEN (SELECT n FROM tchk) <> 1 THEN '❌ 找不到（或不只一家）包子媽生鮮小舖，這份結果不能用'
              ELSE '★ 總計（這一行就是結論）' END AS "店代號",
         '' AS "店名",
         CASE WHEN (SELECT s FROM tot) <> (SELECT d FROM direct)
                THEN '❌ 各類加總跟直接算的總差額差 ' || trim_scale((SELECT s FROM tot) - (SELECT d FROM direct)) || ' 元，截圖給 CEO'
              WHEN EXISTS (SELECT 1 FROM dup)
                THEN '❌ 有 ' || (SELECT COUNT(*) FROM dup) || ' 個重複的配對鍵（區段 4），13 類無法細分，截圖給 CEO'
              ELSE '✅ 各類加總＝直接算的總差額，沒有重複鍵' END AS "類別",
         trim_scale((SELECT s FROM tot)) AS "金額",
         (SELECT COUNT(*) FROM allp) AS "筆數",
         NULL::bigint AS "派車單號", '' AS "計價時點", '' AS "品號", '' AS "數量（9/27→今天）", '' AS "單價（9/27→今天）",
         '直接算＝' || trim_scale((SELECT d FROM direct)) || '；0-A 當時（(10).csv）＝80490'
           || CASE WHEN (SELECT d FROM direct) = 80490 THEN '（一樣）'
                   ELSE '（不一樣：0-A 之後資料又變了，以今天這份的拆解為準）' END
           || '。01／02 的分界依月結表頭目前的 updated_at 推估；表頭被碰過分界會移動，總數不受影響。'
           || '分類是金額效果拆解（同一筆數量、單價都變會拆兩類），加總仍＝總差額' AS "說明"
  UNION ALL
  SELECT 1, 0, cat, '1 各類合計', '', '', cat, trim_scale(SUM(amt)), COUNT(*), NULL, '', '', '', '', ''
    FROM allp GROUP BY cat
  UNION ALL
  SELECT 2, 0, st.code || cat, '2 各店×各類', st.code, st.name, a.cat, trim_scale(SUM(a.amt)), COUNT(*), NULL, '', '', '', '', ''
    FROM allp a JOIN st ON st.id = a.store_id GROUP BY st.code, st.name, a.cat HAVING SUM(a.amt) <> 0
  UNION ALL
  SELECT 3, t.rk, '', '3 前 100 大明細', st.code, st.name, t.cat, trim_scale(t.amt), 1, t.tid,
         to_char(COALESCE(t.t1, t.t0) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'),
         sk.sku_code,
         COALESCE(trim_scale(t.q0)::text, '—') || ' → ' || COALESCE(trim_scale(t.q1)::text, '—'),
         COALESCE(trim_scale(t.p0)::text, '—') || ' → ' || COALESCE(trim_scale(t.p1)::text, '—'),
         t.et || '｜明細編號 ' || t.tii
    FROM top_rows t JOIN st ON st.id = t.store_id LEFT JOIN public.skus sk ON sk.id = t.sku_id
   WHERE t.rk <= 100
  UNION ALL
  SELECT 4, d.n::bigint, d.side, '4 重複鍵', st.code, st.name, '同一鍵出現 ' || d.n || ' 行（' || d.side || '）', NULL::numeric, d.n::bigint, NULL::bigint,
         '', '', '', '', d.entry_type || '｜明細編號 ' || d.transfer_item_id
    FROM dup d JOIN st ON st.id = d.store_id
) z
ORDER BY o1, o3, o2;

-- ============================================================================
--  第三批分店價往回改（蛋小白雞蛋金磚 G02907-01） 3　驗算（只查不改）
--  日期：2026-11-02　阿寫寫、⛔ 還沒經阿審（Codex）審過之前不要貼
--  依據：派工單-蛋小白分店價往回改_第三批_2026-11-02.md 第 4 點
--  範本：第二批 scripts/PROD-fix-branch-price-batch2-2026-10/3_verify_readonly.sql
--        【改寫處】①讀這一批自己的位置 ops_price_fix_b3 ②A／B 類價格檢查 → 單一規格「62→42 接續、無空洞無重疊」
--                  ③九月月結驗算 → 十月：11 家店每家差額＝預期、蛋小白以外不變、其他店依方案甲／乙比對
--                  ④八月逐筆 → 「十月以外每一個月份」月結逐列＝備份＋蛋小白 8/1～10/1 逐筆＝備份
--                  ⑤多驗十月人工調整 4 筆原樣還在、備份讀得到
--  程式出處：工程紀錄本 origin/main bafc13d9 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼：修正（第 2 份）做完之後，用「另一次」重新檢查一遍（修正檔自己在同一次裡已經驗過，這份是事後再看一次）：
--      ・價格版本鏈：62（不變）→ 42（從 10/5 16:38:51 起、沒有結束日），中間沒有空洞、沒有重疊
--      ・每家店十月應付的變化＝預期（11 家、合計 −836）；蛋小白以外的明細不變；其他店依方案比對
--      ・十月人工調整 4 筆還在、金額沒變；十月爭議沒變
--      ・八月、九月（十月以外每一個月份）月結一個字沒變；蛋小白 8/1～10/1 每一筆沒變
--      ・修正之後有沒有人又動過這些資料（跟「改完之後的樣子」比）→ 有的話第 4 份還原會拒絕自動還原
--      ・備份讀得到（這份讀得出來＝備份在；外面讀不到另看 1-B）
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：整份貼上 → Run → 下載 CSV 給 CEO。
--  ★ 看到什麼要停：任何一列 ❌ → 截圖給 CEO。⚠ 是提醒（例如修正後又有新派車，屬正常營運，但會讓還原檔拒絕自動還原）。
-- ============================================================================

WITH
fact AS (
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
),
tchk AS (   -- 只認「包子媽生鮮小舖」一家（名稱去掉空白後完全相同；0 家或 2 家以上 → 第一列 ❌）
  SELECT COUNT(*) AS n FROM public.tenants t WHERE regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖'
),
tn AS (
  SELECT t.id AS tenant_id FROM public.tenants t CROSS JOIN tchk
   WHERE tchk.n = 1 AND regexp_replace(COALESCE(t.name, ''), '[[:space:]' || chr(160) || chr(12288) || ']+', '', 'g') = '包子媽生鮮小舖'
),
fx AS (SELECT * FROM ops_price_fix_b3.fix_log WHERE restored_at IS NULL ORDER BY fix_id DESC LIMIT 1),
bk AS (SELECT b.* FROM ops_price_fix_b3.bk_rows b JOIN fx ON fx.bk_round = b.bk_round),
tg AS (SELECT t.* FROM ops_price_fix_b3.fix_targets t JOIN fx ON fx.fix_id = t.fix_id),
st AS (SELECT s.id, s.code, s.name FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id WHERE s.location_id IS NOT NULL),
v_from AS (SELECT (b.j ->> 'effective_from')::timestamptz AS ts FROM bk b, fact WHERE b.tbl = 'prices' AND b.pk = fact.id_b),
v_to   AS (SELECT (b.j ->> 'effective_from')::timestamptz AS ts FROM bk b, fact WHERE b.tbl = 'prices' AND b.pk = fact.id_c),
-- ① 價格版本鏈
pv AS (SELECT p.* FROM public.prices p, tn, fact WHERE p.tenant_id = tn.tenant_id AND p.sku_id = fact.sku_id AND p.scope = 'branch'),
pv_shared AS (SELECT * FROM pv WHERE scope_id IS NULL),
price_bad AS (
  SELECT '62 那段（24666）跟備份不一樣' AS why
   WHERE NOT EXISTS (SELECT 1 FROM pv, bk, fact WHERE pv.id = fact.id_a AND bk.tbl = 'prices' AND bk.pk = fact.id_a AND to_jsonb(pv) = bk.j)
  UNION ALL
  SELECT '全店共用版本不是剛好 2 個（62、42）' WHERE (SELECT COUNT(*) FROM pv_shared) <> 2
  UNION ALL
  SELECT '42 那個版本不是「從 10/5 16:38:51 起、沒有結束日」'
   WHERE NOT EXISTS (SELECT 1 FROM pv_shared p, fact WHERE p.id <> fact.id_a AND p.price = fact.price_new
                       AND p.effective_from = (SELECT ts FROM v_from) AND p.effective_to IS NULL)
  UNION ALL
  SELECT '62 那段的結束時間沒有剛好接上 42 那段的開始時間（有空洞或重疊）'
   WHERE (SELECT p.effective_to FROM pv_shared p, fact WHERE p.id = fact.id_a) IS DISTINCT FROM (SELECT ts FROM v_from)
  UNION ALL
  SELECT '查價結果不對（那一刻前 62、那一刻起 42、現在 42）'
   WHERE (SELECT public._branch_price_at(tn.tenant_id, fact.sku_id, (SELECT ts FROM v_from) - interval '1 microsecond') FROM tn, fact) IS DISTINCT FROM 62
      OR (SELECT public._branch_price_at(tn.tenant_id, fact.sku_id, (SELECT ts FROM v_from)) FROM tn, fact) IS DISTINCT FROM 42
      OR (SELECT public._branch_price_at(tn.tenant_id, fact.sku_id, now()) FROM tn, fact) IS DISTINCT FROM 42
  UNION ALL
  SELECT '指定門市的分店價版本跟備份不一樣'
   WHERE EXISTS ((SELECT p.id, to_jsonb(p) FROM pv p WHERE p.scope_id IS NOT NULL) EXCEPT (SELECT bk.pk, bk.j FROM bk WHERE bk.tbl = 'prices' AND bk.j ->> 'scope_id' IS NOT NULL))
      OR EXISTS ((SELECT bk.pk, bk.j FROM bk WHERE bk.tbl = 'prices' AND bk.j ->> 'scope_id' IS NOT NULL) EXCEPT (SELECT p.id, to_jsonb(p) FROM pv p WHERE p.scope_id IS NOT NULL))
),
-- ② 十月月結
sm AS (SELECT m.* FROM public.store_monthly_settlements m, tn, fact WHERE m.tenant_id = tn.tenant_id AND m.settlement_month = fact.oct),
tgx AS (
  SELECT tg.*, s.code, s.name, m.payable_amount AS pay_now, m.status,
         (bk.j ->> 'payable_amount')::numeric AS pay_bk, (bk.j ->> 'branch_amount')::numeric AS br_bk, m.branch_amount AS br_now,
         ((to_jsonb(m) - 'payable_amount' - 'branch_amount' - 'updated_at' - 'updated_by') = (bk.j - 'payable_amount' - 'branch_amount' - 'updated_at' - 'updated_by')) AS other_same,
         COALESCE((SELECT SUM(l.amount) FROM fact, public._store_inbound_lines(tg.store_id, fact.oct_from, fact.nov_from) l), 0) AS daily
    FROM tg
    JOIN st s ON s.id = tg.store_id
    LEFT JOIN sm m ON m.id = tg.settlement_id
    LEFT JOIN bk ON bk.tbl = 'sms' AND bk.pk = tg.settlement_id
),
tg_bad AS (SELECT * FROM tgx WHERE status IS DISTINCT FROM 'draft' OR pay_now - pay_bk <> delta OR br_now - br_bk <> delta OR NOT other_same OR br_now <> daily),
-- 11 家店的明細：蛋小白以外逐行＝備份；蛋小白落在 64 那段的行單價 42
it_now AS (
  SELECT to_jsonb(i) - 'id' - 'created_at' AS j FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT settlement_id FROM tg)
),
it_exp AS (
  SELECT CASE WHEN (b.j ->> 'sku_id')::bigint = fact.sku_id
               AND b.j ->> 'entry_type' IN ('hq_inbound','air_in','air_out','return_out')
               AND (b.j ->> 'received_at')::timestamptz >= (SELECT ts FROM v_from) AND (b.j ->> 'received_at')::timestamptz < (SELECT ts FROM v_to)
              THEN jsonb_set(jsonb_set(b.j, '{unit_branch_price}', to_jsonb(fact.price_new::numeric(18,4))),
                             '{branch_amount}', to_jsonb((CASE WHEN b.j ->> 'entry_type' IN ('air_out','return_out') THEN -1 ELSE 1 END
                                                          * (b.j ->> 'qty_received')::numeric * fact.price_new)::numeric(18,4)))
              ELSE b.j END - 'id' - 'created_at' AS j
    FROM bk b, fact
   WHERE b.tbl = 'smsi' AND (b.j ->> 'settlement_id')::bigint IN (SELECT settlement_id FROM tg)
),
it_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM it_now EXCEPT ALL SELECT * FROM it_exp) UNION ALL (SELECT * FROM it_exp EXCEPT ALL SELECT * FROM it_now)) d),
-- 其他店：方案甲＝逐欄；方案乙＝表頭扣掉最後異動時間／異動人、明細扣掉編號／建立時間
oth_now AS (
  SELECT 'h' AS k, CASE WHEN (SELECT mode FROM fx) = '甲' THEN to_jsonb(m) ELSE to_jsonb(m) - 'updated_at' - 'updated_by' END AS j
    FROM sm m WHERE m.store_id NOT IN (SELECT store_id FROM tg)
  UNION ALL
  SELECT 'i', CASE WHEN (SELECT mode FROM fx) = '甲' THEN to_jsonb(i) ELSE to_jsonb(i) - 'id' - 'created_at' END
    FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT id FROM sm WHERE store_id NOT IN (SELECT store_id FROM tg))
),
oth_bk AS (
  SELECT 'h' AS k, CASE WHEN (SELECT mode FROM fx) = '甲' THEN b.j ELSE b.j - 'updated_at' - 'updated_by' END AS j
    FROM bk b WHERE b.tbl = 'sms' AND (b.j ->> 'store_id')::bigint NOT IN (SELECT store_id FROM tg)
  UNION ALL
  SELECT 'i', CASE WHEN (SELECT mode FROM fx) = '甲' THEN b.j ELSE b.j - 'id' - 'created_at' END
    FROM bk b WHERE b.tbl = 'smsi'
     AND (b.j ->> 'settlement_id')::bigint IN (SELECT h.pk FROM bk h WHERE h.tbl = 'sms' AND (h.j ->> 'store_id')::bigint NOT IN (SELECT store_id FROM tg))
),
oth_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM oth_now EXCEPT ALL SELECT * FROM oth_bk) UNION ALL (SELECT * FROM oth_bk EXCEPT ALL SELECT * FROM oth_now)) d),
-- ③ 十月調整、爭議＝備份
adj_now AS (
  SELECT 'ssa' AS tbl, a.id AS pk, to_jsonb(a) AS j FROM public.store_settlement_adjustments a, tn, fact WHERE a.tenant_id = tn.tenant_id AND a.settlement_month = fact.oct
  UNION ALL SELECT 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT id FROM sm)
),
adj_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM adj_now EXCEPT SELECT tbl, pk, j FROM bk WHERE tbl IN ('ssa','ssd')) UNION ALL (SELECT tbl, pk, j FROM bk WHERE tbl IN ('ssa','ssd') EXCEPT SELECT * FROM adj_now)) d),
adj_act AS (SELECT COALESCE(array_agg(amount ORDER BY amount), ARRAY[]::numeric[]) AS a FROM public.store_settlement_adjustments x, tn, fact
             WHERE x.tenant_id = tn.tenant_id AND x.settlement_month = fact.oct AND x.status = 'active'),
-- ④ 十月以外每一個月份＝備份；蛋小白 8/1～10/1 逐筆＝備份
xm AS (SELECT m.id FROM public.store_monthly_settlements m, tn, fact WHERE m.tenant_id = tn.tenant_id AND m.settlement_month <> fact.oct),
x_now AS (
  SELECT 'x_sms' AS tbl, m.id AS pk, to_jsonb(m) AS j FROM public.store_monthly_settlements m WHERE m.id IN (SELECT id FROM xm)
  UNION ALL SELECT 'x_smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT id FROM xm)
  UNION ALL SELECT 'x_ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT id FROM xm)
  UNION ALL SELECT 'x_ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a, tn, fact WHERE a.tenant_id = tn.tenant_id AND a.settlement_month <> fact.oct
),
x_bk AS (SELECT tbl, pk, j FROM bk WHERE tbl IN ('x_sms','x_smsi','x_ssd','x_ssa')),
x_diff AS (SELECT tbl, COUNT(*) AS n FROM ((SELECT * FROM x_now EXCEPT SELECT * FROM x_bk) UNION ALL (SELECT * FROM x_bk EXCEPT SELECT * FROM x_now)) d GROUP BY tbl),
pre_now AS (
  SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
    FROM st CROSS JOIN fact CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), fact.oct_from) l
   WHERE l.sku_id = fact.sku_id
),
pre_bk AS (SELECT p.store_id, p.entry_type, p.transfer_id, p.transfer_item_id, p.sku_id, p.qty, p.booked_at, p.unit_price, p.amount
             FROM ops_price_fix_b3.pre_lines p JOIN fx ON fx.bk_round = p.bk_round),
pre_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM pre_now EXCEPT ALL SELECT * FROM pre_bk) UNION ALL (SELECT * FROM pre_bk EXCEPT ALL SELECT * FROM pre_now)) d),
-- ⑤ 蛋小白十月每一筆帳
egg_now AS (
  SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
    FROM st CROSS JOIN fact CROSS JOIN LATERAL public._store_inbound_lines(st.id, fact.oct_from, now()) l
   WHERE l.sku_id = fact.sku_id
),
egg_bad AS (SELECT * FROM egg_now WHERE entry_type IN ('hq_inbound','air_in','air_out','return_out') AND booked_at >= (SELECT ts FROM v_from) AND unit_price <> 42),
-- ⑥ 修正之後有沒有人又動過（跟「改完之後的樣子」比）
after_now AS (
  SELECT 'prices' AS tbl, p.id AS pk, to_jsonb(p) AS j FROM pv p
  UNION ALL SELECT 'sms', m.id, to_jsonb(m) FROM sm m
  UNION ALL SELECT 'smsi', i.id, to_jsonb(i) FROM public.store_monthly_settlement_items i WHERE i.settlement_id IN (SELECT id FROM sm)
  UNION ALL SELECT 'ssd', d.id, to_jsonb(d) FROM public.store_settlement_disputes d WHERE d.settlement_id IN (SELECT id FROM sm)
  UNION ALL SELECT 'ssa', a.id, to_jsonb(a) FROM public.store_settlement_adjustments a, tn, fact WHERE a.tenant_id = tn.tenant_id AND a.settlement_month = fact.oct
),
after_ref AS (SELECT a.tbl, a.pk, a.j FROM ops_price_fix_b3.after_rows a JOIN fx ON fx.fix_id = a.fix_id),
after_diff AS (SELECT tbl, COUNT(*) AS n FROM ((SELECT * FROM after_now EXCEPT SELECT * FROM after_ref) UNION ALL (SELECT * FROM after_ref EXCEPT SELECT * FROM after_now)) d GROUP BY tbl),
oct_now AS (
  SELECT st.id AS store_id, l.entry_type, l.transfer_id, l.transfer_item_id, l.sku_id, l.qty, l.received_at AS booked_at, l.unit_branch_price AS unit_price, l.amount
    FROM st CROSS JOIN fact CROSS JOIN LATERAL public._store_inbound_lines(st.id, fact.oct_from, fact.nov_from) l
),
oct_ref AS (SELECT a.store_id, a.entry_type, a.transfer_id, a.transfer_item_id, a.sku_id, a.qty, a.booked_at, a.unit_price, a.amount FROM ops_price_fix_b3.after_oct_lines a JOIN fx ON fx.fix_id = a.fix_id),
oct_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM oct_now EXCEPT ALL SELECT * FROM oct_ref) UNION ALL (SELECT * FROM oct_ref EXCEPT ALL SELECT * FROM oct_now)) d),
egg_ref AS (SELECT a.store_id, a.entry_type, a.transfer_id, a.transfer_item_id, a.sku_id, a.qty, a.booked_at, a.unit_price, a.amount FROM ops_price_fix_b3.after_egg_lines a JOIN fx ON fx.fix_id = a.fix_id),
egg_diff AS (SELECT COUNT(*) AS n FROM ((SELECT * FROM egg_now EXCEPT ALL SELECT * FROM egg_ref) UNION ALL (SELECT * FROM egg_ref EXCEPT ALL SELECT * FROM egg_now)) d),
pay AS (SELECT (SELECT COALESCE(SUM(payable_amount), 0) FROM sm) AS now_sum,
               (SELECT COALESCE(SUM((j ->> 'payable_amount')::numeric), 0) FROM bk WHERE tbl = 'sms') AS bk_sum)
SELECT "序", "檢查", "結果", "說明"
FROM (
  SELECT 0 AS "序",
         (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
               WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
               ELSE '★ 總計（這一行就是結論）' END) AS "檢查",
         CASE WHEN NOT EXISTS (SELECT 1 FROM fx) THEN '❌ 找不到這一批還沒還原的修正紀錄（第 2 份還沒做，或已經還原）'
              WHEN EXISTS (SELECT 1 FROM price_bad) OR EXISTS (SELECT 1 FROM tg_bad) OR (SELECT n FROM it_diff) > 0 OR (SELECT n FROM oth_diff) > 0
                OR (SELECT n FROM adj_diff) > 0 OR (SELECT a FROM adj_act) <> (SELECT exp_adj FROM fact) OR EXISTS (SELECT 1 FROM x_diff)
                OR (SELECT n FROM pre_diff) > 0 OR EXISTS (SELECT 1 FROM egg_bad)
                OR (SELECT COUNT(*) FROM tg) <> (SELECT exp_n_store FROM fact) OR (SELECT SUM(delta) FROM tg) <> (SELECT exp_delta FROM fact)
              THEN '❌ 有項目不對（看下面 ❌ 那幾列），截圖給 CEO'
              WHEN EXISTS (SELECT 1 FROM after_diff) OR (SELECT n FROM oct_diff) > 0 OR (SELECT n FROM egg_diff) > 0
              THEN '✅ 修正結果正確；⚠ 但修正之後資料又被動過（看第 20 項起），第 4 份還原會拒絕自動還原'
              ELSE '✅ 全部通過（修正編號 ' || (SELECT fix_id FROM fx) || '，方案' || (SELECT mode FROM fx) || '）' END AS "結果",
         '備份位置 ops_price_fix_b3 讀得到（這份能跑出來＝備份在）；外面讀不讀得到看 1-B' AS "說明"
  UNION ALL SELECT 1, '價格版本鏈：62（不變）→ 42（從 10/5 16:38:51 起、沒有結束日），無空洞無重疊',
         CASE WHEN NOT EXISTS (SELECT 1 FROM price_bad) THEN '✅' ELSE '❌ ' || (SELECT string_agg(why, '；') FROM price_bad) END,
         '現在版本：' || COALESCE((SELECT string_agg(trim_scale(p.price) || ' 元 ' || to_char(p.effective_from AT TIME ZONE 'Asia/Taipei', 'MM-DD HH24:MI:SS') || ' 起'
                                     || CASE WHEN p.effective_to IS NULL THEN '、現在有效' ELSE '、到 ' || to_char(p.effective_to AT TIME ZONE 'Asia/Taipei', 'MM-DD HH24:MI:SS') END, '；' ORDER BY p.effective_from)
                                     FROM pv_shared p), '（沒有）')
  UNION ALL SELECT 2, '有蛋小白帳的店：家數、合計差額（要 11 家、−836）',
         CASE WHEN (SELECT COUNT(*) FROM tg) = (SELECT exp_n_store FROM fact) AND (SELECT SUM(delta) FROM tg) = (SELECT exp_delta FROM fact) THEN '✅'
              ELSE '❌' END || ' ' || (SELECT COUNT(*) FROM tg) || ' 家、' || COALESCE(trim_scale((SELECT SUM(delta) FROM tg))::text, '—'),
         '每家的明細在第 100 項起'
  UNION ALL SELECT 3, '有蛋小白帳的店：每家應付變化＝預期、還是草稿、成本／調整／張數／筆數不變、分店價合計＝每日對帳',
         CASE WHEN NOT EXISTS (SELECT 1 FROM tg_bad) THEN '✅' ELSE '❌ ' || (SELECT string_agg(code, '、') FROM tg_bad) END, ''
  UNION ALL SELECT 4, '有蛋小白帳的店：蛋小白以外的明細逐行不變、蛋小白落在 64 那段的單價＝42',
         CASE WHEN (SELECT n FROM it_diff) = 0 THEN '✅' ELSE '❌ ' || (SELECT n FROM it_diff) || ' 行不同（兩邊合計）' END, ''
  UNION ALL SELECT 5, '沒有蛋小白帳的店（方案' || COALESCE((SELECT mode FROM fx), '—') || '）跟備份比',
         CASE WHEN (SELECT n FROM oth_diff) = 0 THEN '✅' ELSE '❌ ' || (SELECT n FROM oth_diff) || ' 筆不同（兩邊合計）' END,
         '方案甲：表頭、明細逐欄一樣；方案乙：金額與明細逐行一樣（最後異動時間、明細編號會變）'
  UNION ALL SELECT 6, '十月人工調整 4 筆還在、金額沒變；十月爭議沒變',
         CASE WHEN (SELECT n FROM adj_diff) = 0 AND (SELECT a FROM adj_act) = (SELECT exp_adj FROM fact) THEN '✅' ELSE '❌' END,
         '有效調整：' || array_to_string((SELECT a FROM adj_act), '、') || '；跟備份不同 ' || (SELECT n FROM adj_diff) || ' 筆'
  UNION ALL SELECT 7, '十月以外每一個月份（八月、九月…）月結表頭／明細／調整／爭議逐列＝備份',
         CASE WHEN NOT EXISTS (SELECT 1 FROM x_diff) THEN '✅ 一個字都沒變' ELSE '❌ ' || (SELECT string_agg(tbl || ' ' || n || ' 筆', '、') FROM x_diff) END, ''
  UNION ALL SELECT 8, '蛋小白 8/1～10/1 每日對帳逐筆＝備份',
         CASE WHEN (SELECT n FROM pre_diff) = 0 THEN '✅（' || (SELECT COUNT(*) FROM pre_now) || ' 筆）' ELSE '❌ ' || (SELECT n FROM pre_diff) || ' 筆不同' END, ''
  UNION ALL SELECT 9, '蛋小白 10/5 16:38:51 起每一筆帳單價＝42（每日對帳）',
         CASE WHEN NOT EXISTS (SELECT 1 FROM egg_bad) THEN '✅' ELSE '❌ ' || (SELECT COUNT(*) FROM egg_bad) || ' 筆不是 42' END,
         '蛋小白 10/1 起共 ' || (SELECT COUNT(*) FROM egg_now) || ' 筆'
  UNION ALL SELECT 10, '十月應收合計（備份 → 現在）',
         trim_scale((SELECT bk_sum FROM pay)) || ' → ' || trim_scale((SELECT now_sum FROM pay)) || '（差 ' || trim_scale((SELECT now_sum - bk_sum FROM pay)) || '）',
         '應該剛好差 −836；不是的話看第 20 項（修正後有沒有人又動過）'
  UNION ALL SELECT 20, '修正之後，價格／十月月結／調整／爭議有沒有人又動過',
         CASE WHEN NOT EXISTS (SELECT 1 FROM after_diff) THEN '✅ 沒有' ELSE '⚠ ' || (SELECT string_agg(tbl || ' ' || n || ' 筆', '、') FROM after_diff) END,
         '有動過的話，第 4 份還原會拒絕自動還原（要人工對帳）'
  UNION ALL SELECT 21, '修正之後，十月有沒有新的派車／收貨／退貨／店轉店（全部店、全部商品）',
         CASE WHEN (SELECT n FROM oct_diff) = 0 THEN '✅ 沒有' ELSE '⚠ 有 ' || (SELECT n FROM oct_diff) || ' 筆變動（兩邊合計）' END,
         '有的話，第 4 份還原會拒絕自動還原'
  UNION ALL SELECT 22, '修正之後，蛋小白有沒有新的帳（10/1 到現在，含十一月）',
         CASE WHEN (SELECT n FROM egg_diff) = 0 THEN '✅ 沒有' ELSE '⚠ 有 ' || (SELECT n FROM egg_diff) || ' 筆變動（兩邊合計）' END,
         '新派車是正常營運（已經是 42）；但有的話，第 4 份還原會拒絕自動還原'
  UNION ALL
  SELECT 100 + ROW_NUMBER() OVER (ORDER BY x.delta, x.code)::int, '店：' || x.code || '　' || x.name,
         CASE WHEN x.status IS DISTINCT FROM 'draft' OR x.pay_now - x.pay_bk <> x.delta OR x.br_now - x.br_bk <> x.delta OR NOT x.other_same OR x.br_now <> x.daily THEN '❌' ELSE '✅' END
           || ' 應付 ' || trim_scale(x.pay_bk) || ' → ' || COALESCE(trim_scale(x.pay_now)::text, '—') || '（預期差 ' || trim_scale(x.delta) || '）',
         '狀態 ' || COALESCE(x.status, '—') || '；蛋小白會變的帳 ' || x.n_lines || ' 筆、計價數量 ' || trim_scale(x.net_qty)
           || CASE WHEN NOT x.other_same THEN '；⚠ 表頭其他欄位跟備份不一樣' ELSE '' END
           || CASE WHEN x.br_now <> x.daily THEN '；⚠ 分店價合計 ' || trim_scale(x.br_now) || ' ≠ 每日對帳 ' || trim_scale(x.daily) ELSE '' END
    FROM tgx x
) z
ORDER BY "序";

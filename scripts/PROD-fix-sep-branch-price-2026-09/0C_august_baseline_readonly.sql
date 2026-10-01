-- ============================================================================
--  九月錯價修正 0-C　八月逐筆基準（只查不改）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-九月分店價錯價修正_2026-09-29.md（v2）第 3、8 節
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    57 個品號在八月（台北時間 8/1 00:00 ～ 9/1 00:00）每一筆「會用到分店價」的帳，一筆一列：
--    哪家店、哪一類（派車／店轉店收進／店轉店轉出／退貨）、明細編號、計價的時間點、數量、查到的分店價、金額，
--    以及這個價是「那個時間點生效的版本」還是「那時查不到、借用現行價」。
--    改價前跑一次、改價後（第 3 份驗算）再比一次，每一筆都要一模一樣才算過。
--    ⚠ 修正檔自己也會在同一次裡逐筆比（用第 1 份備份時存下的這份資料），不一樣就整筆取消。
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：整份貼上 → Run → 下載 CSV 存好（這是八月的「改之前」證據）。
--  ★ 看到什麼要停：
--    ・第一列寫 ❌ → 截圖給 CEO
--    ・第一列說「有 N 筆是借用現行價」且 N 不是 0 → 🔴 先停。這些筆改價後一定會變（查價工具查不到當時的價就用現行價，
--      20260715000000:103-114），修正檔的八月逐筆檢查會擋下來，要先請 CEO 想辦法
--  ★ 明細鍵：店代號＋類型＋明細編號（transfer_item_id；店轉店是轉出那一腿的明細）。
--  ★ 出處：_store_inbound_lines（20260901000000:597-742）；價格來源照抄 _branch_price_at（20260715000000:90-114）。
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
st AS (SELECT s.id, s.code, s.name FROM public.stores s JOIN tn ON tn.tenant_id = s.tenant_id WHERE s.location_id IS NOT NULL),
ln AS (
  SELECT st.code, st.name, l.*
    FROM st CROSS JOIN LATERAL public._store_inbound_lines(st.id, ((DATE '2026-08-01')::timestamp AT TIME ZONE 'Asia/Taipei'), ((DATE '2026-09-01')::timestamp AT TIME ZONE 'Asia/Taipei')) l
   WHERE l.entry_type IN ('hq_inbound','air_in','air_out','return_out') AND l.sku_id IN (SELECT sku_id FROM sk)
),
src AS (
  SELECT ln.*, sk.sku_code,
         (SELECT pr.id FROM public.prices pr, tn
           WHERE pr.tenant_id = tn.tenant_id AND pr.sku_id = ln.sku_id AND pr.scope = 'branch' AND pr.scope_id IS NULL
             AND pr.price > 0 AND pr.effective_from <= ln.received_at
             AND (pr.effective_to IS NULL OR pr.effective_to > ln.received_at)
           ORDER BY pr.effective_from DESC LIMIT 1) AS hit_id,
         (SELECT pr.id FROM public.prices pr, tn
           WHERE pr.tenant_id = tn.tenant_id AND pr.sku_id = ln.sku_id AND pr.scope = 'branch' AND pr.scope_id IS NULL
             AND pr.price > 0 AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1) AS fb_id
    FROM ln JOIN sk ON sk.sku_id = ln.sku_id
)
SELECT "明細鍵", "店代號", "店名", "類型", "品號", "派車單／轉貨單號", "明細編號", "計價時點", "數量", "查到的分店價", "金額", "價格來源"
FROM (
  SELECT 0 AS ord, '' AS k,
         '' AS "明細鍵",
         (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT COUNT(*) FROM sk) <> 57 THEN '❌ 57 個品號只在系統找到 ' || (SELECT COUNT(*) FROM sk) || ' 個，這份結果不能用，請截圖給 CEO'
       ELSE '★ 總計（這一行就是結論）' END) AS "店代號",
         '共 ' || COUNT(*) || ' 筆（' || COUNT(DISTINCT code) || ' 家店、' || COUNT(DISTINCT sku_code) || ' 個品號）' AS "店名",
         '' AS "類型", '' AS "品號", NULL::bigint AS "派車單／轉貨單號", NULL::bigint AS "明細編號", '' AS "計價時點",
         trim_scale(SUM(qty)) AS "數量", NULL::numeric AS "查到的分店價", trim_scale(SUM(amount)) AS "金額",
         CASE WHEN COUNT(*) FILTER (WHERE hit_id IS NULL) = 0 THEN '✅ 每一筆都是「當時生效的版本」'
              ELSE '🔴 有 ' || COUNT(*) FILTER (WHERE hit_id IS NULL) || ' 筆是借用現行價（或查無價），改價後會變 → 先停，截圖給 CEO' END AS "價格來源"
    FROM src
  UNION ALL
  SELECT 1, code || '|' || entry_type || '|' || transfer_item_id,
         code || '|' || entry_type || '|' || transfer_item_id,
         code, name,
         CASE entry_type WHEN 'hq_inbound' THEN '派車進貨' WHEN 'air_in' THEN '店轉店收進' WHEN 'air_out' THEN '店轉店轉出' ELSE '退貨回總倉' END,
         sku_code, transfer_id, transfer_item_id,
         to_char(received_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS'),
         trim_scale(qty), trim_scale(unit_branch_price), trim_scale(amount),
         CASE WHEN hit_id IS NOT NULL THEN '當時生效的版本 #' || hit_id
              WHEN fb_id IS NOT NULL THEN '🔴 當時查不到，借用現行價 #' || fb_id
              ELSE '🔴 查無任何分店價（算 0 元）' END
    FROM src
) z
ORDER BY ord, k;

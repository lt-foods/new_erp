-- ============================================================================
--  九月錯價修正 0-B　九月人工調整一筆一筆列出來（只查不改）
--  日期：2026-09-29　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-九月分店價錯價修正_2026-09-29.md（v2）第 3、8 節
--  程式出處：唯讀鏡像 origin/main c85e0e1d 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    九月月結草稿上現在「有效」的每一筆人工調整：編號（ID）、哪家店、多少錢、原因、什麼時候、誰建的。
--    你要一筆一筆判斷：這筆是不是「在補這批分店價打錯」？
--      ・是 → 把它的 ID 記下來，交給 CEO；修正檔會在同一次裡把它作廢，不然改價後店家會被「減收兩次」
--      ・不是（例如補運費、補別的事）→ 不用動
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：整份貼上 → Run → 下載 CSV 給 CEO。
--  ★ 看到什麼要停：第一列寫 ❌ → 截圖給 CEO。
--  ★ 出處：store_settlement_adjustments（20260801000000:51-66）；建立人是 auth.users 的登入帳號。
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
a AS (
  SELECT a.*, s.code, s.name AS sname, m.id AS sm_id, m.status AS sm_status,
         u.email AS creator_email
    FROM public.store_settlement_adjustments a
    JOIN tn ON tn.tenant_id = a.tenant_id
    JOIN public.stores s ON s.id = a.store_id
    LEFT JOIN public.store_monthly_settlements m
           ON m.tenant_id = a.tenant_id AND m.settlement_month = a.settlement_month AND m.store_id = a.store_id
    LEFT JOIN auth.users u ON u.id = a.created_by
   WHERE a.settlement_month = DATE '2026-09-01'
)
SELECT "調整ID", "店代號", "店名", "金額（負的＝少收）", "原因", "建立時間", "建立人帳號", "建立人UUID", "這家店九月月結", "狀態"
FROM (
  SELECT 0 AS ord, NULL::bigint AS k,
         NULL::bigint AS "調整ID",
         (CASE WHEN (SELECT n FROM tchk) = 0 THEN '❌ 找不到包子媽生鮮小舖這家公司，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT n FROM tchk) > 1 THEN '❌ 有 ' || (SELECT n FROM tchk) || ' 家公司都叫包子媽生鮮小舖，這份結果不能用，請截圖給 CEO'
       WHEN (SELECT COUNT(*) FROM sk) <> 57 THEN '❌ 57 個品號只在系統找到 ' || (SELECT COUNT(*) FROM sk) || ' 個，這份結果不能用，請截圖給 CEO'
       ELSE '★ 總計（這一行就是結論）' END) AS "店代號",
         '有效 ' || COUNT(*) FILTER (WHERE a.status = 'active') || ' 筆（' || COUNT(DISTINCT a.store_id) FILTER (WHERE a.status = 'active') || ' 家店）；已作廢 '
           || COUNT(*) FILTER (WHERE a.status = 'voided') || ' 筆（不用看）' AS "店名",
         trim_scale(SUM(a.amount) FILTER (WHERE a.status = 'active')) AS "金額（負的＝少收）",
         '請逐筆判斷：是不是在補這批分店價打錯？是的話把「調整ID」告訴 CEO' AS "原因",
         '' AS "建立時間", '' AS "建立人帳號", NULL::uuid AS "建立人UUID", '' AS "這家店九月月結", '' AS "狀態"
    FROM a
  UNION ALL
  SELECT 1, a.id, a.id, a.code, a.sname, trim_scale(a.amount), a.reason,
         to_char(a.created_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'),
         COALESCE(a.creator_email, '（登入帳號裡查不到）'), a.created_by,
         COALESCE(a.sm_status, '（還沒產生）'), '有效'
    FROM a WHERE a.status = 'active'
) z
ORDER BY ord, k;

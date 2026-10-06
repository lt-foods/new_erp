-- ============================================================================
--  第二批分店價錯價修正 0-B　九月人工調整一筆一筆列出來（只查不改）
--  日期：2026-10-07　阿寫寫、⛔ 還沒經阿審審過之前不要貼
--  依據：實作計畫-第二批分店價錯價修正_九月十月_2026-10-07.md、派工單-第二批分店價錯價修正指令_2026-10-07.md
--  範本：第一批 NEW-ERP九月錯價修正_2026-09-29_0-B（9/30 已在正式系統跑過）；只改清單與基準
--  程式出處：唯讀鏡像 origin/main 500ecc32 的 supabase/migrations/（行號寫在各段註解）
-- ============================================================================
--  ★ 這份在做什麼
--    九月月結草稿上現在「有效」的每一筆人工調整：編號（ID）、哪家店、多少錢、原因、什麼時候、誰建的。
--    你要一筆一筆判斷：這筆是不是「在補這一批（第二批）分店價打錯」？
--      ・是 → 把它的 ID 記下來，交給 CEO；修正檔會在同一次裡把它作廢，不然改價後店家會被「減收兩次」
--      ・不是（例如補運費、補別的事）→ 不用動
--    ⚠ 預設「一筆都不作廢」：9/30 第一批時有效調整 16 筆、合計 −14,415（含 9/30 下午新增的一筆 −360），
--      當時老闆裁定 16 筆都不作廢。第一列會比對現在是不是還是這個樣子。
--  ★ 會不會動資料：不會。只有 WITH／SELECT。
--  ★ 怎麼用：整份貼上 → Run → 下載 CSV 給 CEO。
--  ★ 看到什麼要停：第一列寫 ❌ → 截圖給 CEO；第一列「狀態」寫「⚠ 不一樣」→ 有新的調整或被作廢的，先給 CEO 看。
--  ★ 出處：store_settlement_adjustments（20260801000000:52-66）；建立人是 auth.users 的登入帳號。
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
               WHEN (SELECT n_ph FROM lchk) > 0 THEN '❌ 清單裡還有佔位（' || (SELECT ph FROM lchk) || '），要等老闆確認、CEO 換成真正的規格編號，請截圖給 CEO'
               WHEN (SELECT n_dup FROM lchk) > 0 THEN '❌ 清單裡有 ' || (SELECT n_dup FROM lchk) || ' 個重複的品號，請截圖給 CEO'
               WHEN (SELECT n_miss FROM lchk) > 0 THEN '❌ 清單 ' || (SELECT n_list FROM lchk) || ' 個規格有 ' || (SELECT n_miss FROM lchk) || ' 個在系統查不到（' || (SELECT miss FROM lchk) || '），請截圖給 CEO'
               ELSE '★ 總計（這一行就是結論）' END) AS "店代號",
         '有效 ' || COUNT(*) FILTER (WHERE a.status = 'active') || ' 筆（' || COUNT(DISTINCT a.store_id) FILTER (WHERE a.status = 'active') || ' 家店）；已作廢 '
           || COUNT(*) FILTER (WHERE a.status = 'voided') || ' 筆（不用看）' AS "店名",
         trim_scale(SUM(a.amount) FILTER (WHERE a.status = 'active')) AS "金額（負的＝少收）",
         '請逐筆判斷：是不是在補這一批分店價打錯？是的話把「調整ID」告訴 CEO（預設一筆都不作廢）' AS "原因",
         COALESCE(to_char(MAX(a.created_at) FILTER (WHERE a.status = 'active') AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '') AS "建立時間",
         '' AS "建立人帳號", NULL::uuid AS "建立人UUID", '' AS "這家店九月月結",
         '10/7 盤點：有效 16 筆、合計 −14,415 → 現在 ' || COUNT(*) FILTER (WHERE a.status = 'active') || ' 筆、合計 '
           || COALESCE(trim_scale(SUM(a.amount) FILTER (WHERE a.status = 'active'))::text, '0')
           || CASE WHEN COUNT(*) FILTER (WHERE a.status = 'active') = 16 AND COALESCE(SUM(a.amount) FILTER (WHERE a.status = 'active'), 0) = -14415
                   THEN '（一樣）' ELSE '（⚠ 不一樣：10/7 之後有新增或作廢，先給 CEO 看）' END AS "狀態"
    FROM a
  UNION ALL
  SELECT 1, a.id, a.id, a.code, a.sname, trim_scale(a.amount), a.reason,
         to_char(a.created_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'),
         COALESCE(a.creator_email, '（登入帳號裡查不到）'), a.created_by,
         COALESCE(a.sm_status, '（還沒產生）'), '有效'
    FROM a WHERE a.status = 'active'
) z
ORDER BY ord, k;

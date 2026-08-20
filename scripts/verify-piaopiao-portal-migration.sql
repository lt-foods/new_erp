-- 漂漂館獨立上架網站：migration 套完後的唯讀驗收。
-- 只查資料庫結構，不讀訂單／商品／會員資料。Supabase SQL Editor 整份貼上一次即可。
WITH checks(name, ok) AS (
  VALUES
    ('sales_channel 欄位（既有團預設 main）', EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'group_buy_campaigns'
        AND column_name = 'sales_channel'
        AND is_nullable = 'NO'
        AND column_default LIKE '%main%'
    )),
    ('漂漂館上架帳號表', to_regclass('public.piaopiao_publishers') IS NOT NULL),
    ('漂漂館建團批次表', to_regclass('public.piaopiao_publish_batches') IS NOT NULL),
    ('漂漂館團對照表', to_regclass('public.piaopiao_batch_campaigns') IS NOT NULL),
    ('圖片每日額度表', to_regclass('public.piaopiao_publisher_upload_days') IS NOT NULL),
    ('整批建團函式', to_regprocedure('public.rpc_piaopiao_publish_batch(uuid,bigint,uuid,uuid,timestamp with time zone,date,jsonb)') IS NOT NULL),
    ('圖片額度保留函式', to_regprocedure('public.rpc_piaopiao_reserve_upload_slot(uuid,bigint,uuid)') IS NOT NULL),
    ('上架帳號管理函式', to_regprocedure('public.rpc_piaopiao_publisher_overview()') IS NOT NULL)
), summary AS (
  SELECT bool_and(ok) AS all_ok,
         jsonb_object_agg(name, CASE WHEN ok THEN '✅' ELSE '❌' END) AS details
  FROM checks
)
SELECT CASE WHEN all_ok
            THEN '✅ 資料庫已完整就位：可部署三支後端，但還不可先上網站。'
            ELSE '❌ 資料庫未完整：立刻停止，不可部署後端或網站。'
       END AS result,
       details
FROM summary;

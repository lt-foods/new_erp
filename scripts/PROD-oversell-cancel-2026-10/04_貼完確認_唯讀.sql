-- ============================================================================
--  04 貼完確認（只查不改：整份只有一句查詢）
--  限量團超賣三團（洗面乳 024／辣椒醬 048／微燻李 018）：02 做完之後逐項確認
--  日期：2026-10-28　阿寫寫
--  「結果」欄：✅ 對　❌ 不對（截圖給 CEO）　ℹ 參考
--  看的是「最近一次 02」（用 02 寫進編輯歷史的那一句原因認）。用過 05 還原的話，最後一段會寫出來。
-- ============================================================================
WITH
param AS (
  SELECT '限量超賣：2026-10-28 老闆核准批次取消'::text AS tag,
         '還原：限量超賣批次取消（撤回 2026-10-28 那一次）'::text AS tag_undo
),
lst AS (
  SELECT 'GRP-20261015-024'::text AS campaign_no, 'GRP-20261015-024-' || lpad(n::text, 4, '0') AS order_no, 'cancel'::text AS kind
    FROM generate_series(6, 46) n
  UNION ALL SELECT 'GRP-20261015-024', 'GRP-20261015-024-INT0047', 'cancel'
  UNION ALL
  SELECT 'GRP-20261016-048', 'GRP-20261016-048-' || lpad(n::text, 4, '0'), 'cancel'
    FROM generate_series(27, 43) n WHERE n <> 40
  UNION ALL SELECT 'GRP-20261016-048', 'GRP-20261016-048-TF0001', 'cancel'
  UNION ALL SELECT 'GRP-20261016-048', 'GRP-20261016-048-0040', 'follow'
  UNION ALL
  SELECT 'GRP-20261021-018', 'GRP-20261021-018-' || lpad(n::text, 4, '0'), 'cancel'
    FROM generate_series(18, 31) n
  UNION ALL SELECT 'GRP-20261015-024', 'GRP-20261015-024-' || lpad(n::text, 4, '0'), 'keep' FROM generate_series(1, 5) n
  UNION ALL SELECT 'GRP-20261016-048', 'GRP-20261016-048-' || lpad(n::text, 4, '0'), 'keep' FROM generate_series(1, 26) n
  UNION ALL SELECT 'GRP-20261021-018', 'GRP-20261021-018-' || lpad(n::text, 4, '0'), 'keep' FROM generate_series(1, 17) n
),
exp AS (
  SELECT * FROM (VALUES
    ('GRP-20261015-024', '洗面乳', 6::numeric, 5::numeric),
    ('GRP-20261016-048', '辣椒醬', 34::numeric, 34::numeric),
    ('GRP-20261021-018', '微燻李', 22::numeric, 21::numeric)
  ) v(campaign_no, label, cap, after_qty)
),
cp AS (SELECT c.id, c.tenant_id, c.campaign_no FROM public.group_buy_campaigns c WHERE c.campaign_no IN (SELECT campaign_no FROM exp)),
ords AS (
  SELECT co.id, co.order_no, cp.campaign_no, co.status, co.cancelled_at, co.updated_at, co.transferred_to_order_id,
         COALESCE(co.wallet_paid_amount, 0) AS wallet, COALESCE(st.name, '?') AS store_name,
         (SELECT COALESCE(sum(i.qty), 0) FROM public.customer_order_items i
           WHERE i.order_id = co.id AND i.status NOT IN ('cancelled', 'expired')) AS live_qty
    FROM public.customer_orders co JOIN cp ON cp.id = co.campaign_id AND cp.tenant_id = co.tenant_id
    LEFT JOIN public.stores st ON st.id = co.pickup_store_id
),
t0 AS (    -- 最近一次 02 的時間
  SELECT max(a.created_at) AS at
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag
   WHERE a.entity_type = 'order' AND a.field = 'status' AND a.order_id IN (SELECT id FROM ords)
),
marked AS ( -- 那一次 02 取消的單
  SELECT a.order_id, a.before_value #>> '{}' AS before_status
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag
   WHERE a.entity_type = 'order' AND a.field = 'status' AND a.created_at = (SELECT at FROM t0)
     AND a.order_id IN (SELECT id FROM ords)
),
x AS (
  SELECT l.campaign_no, l.order_no, l.kind, o.id, o.status, o.cancelled_at, o.updated_at, o.wallet, o.store_name, o.live_qty,
         o.transferred_to_order_id, m.before_status, (m.order_id IS NOT NULL) AS in_batch
    FROM lst l LEFT JOIN ords o ON o.order_no = l.order_no AND o.campaign_no = l.campaign_no
    LEFT JOIN marked m ON m.order_id = o.id
),
eff AS (SELECT * FROM ords WHERE status NOT IN ('cancelled', 'expired', 'transferred_out')),
refund AS ( -- 這一次取消鈕寫的儲值金退款（原因＝'order_cancelled: ' || 02 那一句，20260826000010:204-212）
  SELECT count(*) AS n, COALESCE(sum(w.change), 0) AS amt
    FROM public.wallet_ledger w, param p
   WHERE w.type = 'refund' AND w.source_type = 'customer_order'
     AND w.source_id IN (SELECT order_id FROM marked)
     AND w.reason = 'order_cancelled: ' || p.tag
),
undo AS (  -- 05 是呼叫 rpc_restore_cancelled_order，它自己寫的編輯歷史原因結尾是「；原因：<05 那一句>」（20261013000000:1695-1700）
  SELECT count(*) AS n, max(a.created_at) AS at
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason LIKE '%；原因：' || p.tag_undo
   WHERE a.entity_type = 'order' AND a.field = 'status'
     AND a.order_id IN (SELECT id FROM ords) AND a.created_at > COALESCE((SELECT at FROM t0), '-infinity')
)
SELECT "段落", "項目", "門市", "件數", "結果", "說明"
FROM (
  SELECT 0 AS o1, 1 AS o2, '⓪ 02 做過了沒'::text AS "段落", '最近一次 02'::text AS "項目", NULL::text AS "門市",
         (SELECT count(*) FROM marked)::numeric AS "件數",
         CASE WHEN (SELECT at FROM t0) IS NULL THEN '❌ 還沒做過（先貼 02）' ELSE '✅ 有' END AS "結果",
         COALESCE(to_char((SELECT at FROM t0) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') || '，這一次取消 '
                  || (SELECT count(*) FROM marked) || ' 張（「件數」欄是張數；應為 74＝73 張＋0040，重貼補做的會少）', '') AS "說明"

  -- ① 逐張
  UNION ALL
  SELECT 1, ROW_NUMBER() OVER (ORDER BY x.campaign_no, x.order_no)::int, '① 要取消的單', x.order_no, x.store_name, x.live_qty,
         CASE WHEN x.id IS NULL THEN '❌ 找不到這張單'
              WHEN x.status = 'cancelled' THEN '✅ 已取消'
              ELSE '❌ 現在是 ' || x.status END,
         CASE WHEN x.in_batch THEN '02 取消（取消前 ' || x.before_status || '）' ELSE 'ℹ 不是最近一次 02 取消的（之前就取消了，或是別次）' END
           || CASE WHEN x.kind = 'follow' THEN '；0040＝TF0001 的原單' ||
                     CASE WHEN x.transferred_to_order_id IS NULL THEN '，轉去哪張已清空 ✅' ELSE '，⚠ 還掛著轉去哪張' END
                   ELSE '' END
           || CASE WHEN x.wallet > 0 THEN '；用過儲值金 $' || trim_scale(x.wallet) ELSE '' END
    FROM x WHERE x.kind IN ('cancel', 'follow')

  -- ② 總計
  UNION ALL
  SELECT 2, 1, '② 總計', '73 張＋0040 都是已取消', NULL,
         (SELECT count(*) FROM x WHERE kind IN ('cancel', 'follow') AND status = 'cancelled')::numeric,
         CASE WHEN (SELECT count(*) FROM x WHERE kind IN ('cancel', 'follow') AND status = 'cancelled') = 74 THEN '✅ 74 張' ELSE '❌ 應為 74 張' END,
         '「件數」欄是張數'
  UNION ALL
  SELECT 2, 2, '② 總計', e.label || '：現在的有效件數', NULL,
         (SELECT COALESCE(sum(live_qty), 0) FROM eff WHERE eff.campaign_no = e.campaign_no),
         CASE WHEN (SELECT COALESCE(sum(live_qty), 0) FROM eff WHERE eff.campaign_no = e.campaign_no) = e.after_qty
              THEN '✅ ' || trim_scale(e.after_qty) || ' 件'
              WHEN (SELECT COALESCE(sum(live_qty), 0) FROM eff WHERE eff.campaign_no = e.campaign_no) = e.cap
              THEN '✅ ' || trim_scale(e.cap) || ' 件（老闆已補單）'
              ELSE '❌ 應為 ' || trim_scale(e.after_qty) || ' 件（老闆補單後 ' || trim_scale(e.cap) || '）' END,
         '上限 ' || trim_scale(e.cap) || CASE WHEN e.after_qty < e.cap THEN '；老闆用後台加單補 1 件後會是 ' || trim_scale(e.cap) ELSE '' END
    FROM exp e
  UNION ALL
  SELECT 2, 3, '② 總計', '保留的 48 張都還有效', NULL,
         (SELECT count(*) FROM x WHERE kind = 'keep' AND status NOT IN ('cancelled', 'expired', 'transferred_out'))::numeric,
         CASE WHEN (SELECT count(*) FROM x WHERE kind = 'keep' AND status NOT IN ('cancelled', 'expired', 'transferred_out')) = 48
              THEN '✅ 48 張' ELSE '❌ 應為 48 張' END,
         COALESCE('不對的：' || (SELECT string_agg(order_no || '＝' || COALESCE(status, '找不到'), '、') FROM x
                                  WHERE kind = 'keep' AND (status IS NULL OR status IN ('cancelled', 'expired', 'transferred_out'))), '')
  UNION ALL
  SELECT 2, 4, '② 總計', '保留的單在 02 那一刻沒被動到', NULL,
         (SELECT count(*) FROM x WHERE kind = 'keep' AND updated_at = (SELECT at FROM t0))::numeric,
         CASE WHEN (SELECT count(*) FROM x WHERE kind = 'keep' AND updated_at = (SELECT at FROM t0)) = 0 THEN '✅ 0 張' ELSE '❌ 有' END, ''
  UNION ALL
  SELECT 2, 5, '② 總計', '名單外、現在還算有效的單', NULL,
         (SELECT count(*) FROM eff WHERE order_no NOT IN (SELECT order_no FROM lst))::numeric,
         'ℹ ' || (SELECT count(*) FROM eff WHERE order_no NOT IN (SELECT order_no FROM lst)) || ' 張',
         COALESCE((SELECT string_agg(order_no || '（' || store_name || ' ' || trim_scale(live_qty) || ' 件）', '、' ORDER BY order_no)
                     FROM eff WHERE order_no NOT IN (SELECT order_no FROM lst)),
                  '（沒有）') || '：老闆補給 0006 古華、0018 忠順的那 1 件會出現在這裡'

  -- ③ 儲值金
  UNION ALL
  SELECT 3, 1, '③ 儲值金', '這一次取消、用過儲值金的單', NULL,
         (SELECT COALESCE(sum(wallet), 0) FROM x WHERE in_batch AND wallet > 0),
         'ℹ ' || (SELECT count(*) FROM x WHERE in_batch AND wallet > 0) || ' 張', '「件數」欄是金額（元）'
  UNION ALL
  SELECT 3, 2, '③ 儲值金', '退款紀錄（wallet_ledger）', NULL, (SELECT amt FROM refund),
         CASE WHEN (SELECT n FROM refund) = (SELECT count(*) FROM x WHERE in_batch AND wallet > 0)
               AND (SELECT amt FROM refund) = (SELECT COALESCE(sum(wallet), 0) FROM x WHERE in_batch AND wallet > 0)
              THEN '✅ ' || (SELECT n FROM refund) || ' 筆，金額對得上' ELSE '❌ 跟上一列對不上' END,
         '取消鈕自己退的（rpc_wallet_refund）'

  -- ④ 05 還原過了沒
  UNION ALL
  SELECT 4, 1, '④ 05 還原過了沒', '02 之後的還原紀錄', NULL, (SELECT n FROM undo)::numeric,
         CASE WHEN (SELECT n FROM undo) = 0 THEN 'ℹ 沒有還原過' ELSE 'ℹ 還原過 ' || (SELECT n FROM undo) || ' 張' END,
         COALESCE('最近一次：' || to_char((SELECT at FROM undo) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS')
                  || '（還原過的話，上面 ① ② 會顯示 ❌，那是正常的）', '')
) z
ORDER BY o1, o2, "項目";

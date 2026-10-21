-- ============================================================================
--  04 貼完確認（只查不改：整份只有一句查詢）
--  契爾氏化妝水（G02596-01）團 GRP-20260910-027：02 做完之後逐項確認
--  日期：2026-10-21　阿寫寫
--  「結果」欄：✅ 對　❌ 不對（截圖給 CEO）　ℹ 參考
--  看的是「最近一次 02」（用 02 寫進編輯歷史的那一句原因認）。用過 05 還原的話，最後一段會寫出來。
-- ============================================================================
WITH
param AS (
  SELECT 'GRP-20260910-027'::text AS campaign_no,
         'G02596-01'::text        AS sku_code,
         26                       AS expect_rows,   -- 10/21 早上 27；松山 1 筆老闆已手動刪除
         32::numeric              AS expect_qty,    -- 10/21 早上 33；同上少 1 件
         '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消'::text AS tag_item,
         '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消（這張單沒有其他待取品項，整單取消）'::text AS tag_cancel,
         '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消（其他品項都取過了，訂單收尾為完成）'::text AS tag_done,
         '還原：契爾氏化妝水叫錯款式批次取消（撤回 2026-10-21 那一次）'::text AS tag_undo,
         '契爾氏叫錯款式批次取消'::text AS tag_release
),
cp AS (SELECT c.id, c.tenant_id FROM public.group_buy_campaigns c JOIN param p ON p.campaign_no = c.campaign_no),
sk AS (SELECT s.id, COALESCE(s.product_name, s.sku_code) || COALESCE('-' || s.variant_name, '') AS label
         FROM public.skus s JOIN cp ON cp.tenant_id = s.tenant_id JOIN param p ON p.sku_code = s.sku_code),
scope AS ( -- 這家公司、這一團、這個商品的全部品項（單頭、品項、團三者同一家公司）
  SELECT i.id, i.order_id, i.qty, i.status, i.stockout_at, i.updated_at, co.member_id
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
    JOIN cp ON cp.id = co.campaign_id AND cp.tenant_id = co.tenant_id AND cp.tenant_id = i.tenant_id
    JOIN sk ON sk.id = i.sku_id
),
t0 AS (    -- 最近一次 02 的時間
  SELECT max(a.created_at) AS at
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag_item
   WHERE a.entity_type = 'item' AND a.field = 'status'
     AND a.entity_id IN (SELECT id FROM scope) AND a.tenant_id IN (SELECT tenant_id FROM cp)
),
marked AS ( -- 那一次 02 取消的品項（看編輯歷史；只算這一團這商品）
  SELECT a.entity_id AS item_id, a.order_id
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag_item
   WHERE a.entity_type = 'item' AND a.field = 'status' AND a.created_at = (SELECT at FROM t0)
     AND a.entity_id IN (SELECT id FROM scope) AND a.tenant_id IN (SELECT tenant_id FROM cp)
),
touched_orders AS ( -- 那一次 02 碰到的訂單（有品項被取消的）
  SELECT DISTINCT order_id FROM marked
),
ord_cancel AS (
  SELECT a.order_id, a.before_value #>> '{}' AS before_status
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag_cancel
   WHERE a.entity_type = 'order' AND a.field = 'status' AND a.created_at = (SELECT at FROM t0)
     AND a.order_id IN (SELECT order_id FROM touched_orders) AND a.tenant_id IN (SELECT tenant_id FROM cp)
),
ord_done AS (
  SELECT a.order_id, a.before_value #>> '{}' AS before_status
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag_done
   WHERE a.entity_type = 'order' AND a.field = 'status' AND a.created_at = (SELECT at FROM t0)
     AND a.order_id IN (SELECT order_id FROM touched_orders) AND a.tenant_id IN (SELECT tenant_id FROM cp)
),
undo AS (  -- 05 還原過了沒（02 之後、這幾張單）
  SELECT count(*) AS n, max(a.created_at) AS at
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag_undo
   WHERE a.created_at > (SELECT at FROM t0) AND a.order_id IN (SELECT order_id FROM touched_orders)
),
paid AS (  -- 那幾張單裡，付過錢／用過儲值金的
  SELECT co.id FROM public.customer_orders co
   WHERE co.id IN (SELECT order_id FROM touched_orders)
     AND (COALESCE(co.payment_status, 'unpaid') = 'paid' OR COALESCE(co.wallet_paid_amount, 0) > 0)
),
expect_members AS (
  SELECT DISTINCT s.member_id FROM scope s WHERE s.id IN (SELECT item_id FROM marked) AND s.member_id IS NOT NULL
),
body AS (  -- 03 應該發的完整內文（寫法同 03／斷貨 (d) 段，本批只有一個商品）
  SELECT '您訂購的「' || label || '」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。' AS b FROM sk
),
notif AS ( -- 02 之後這批會員收到的「這一則」（類別、標題、內文全等），一位會員幾則
  SELECT n.member_id, count(*) AS c
    FROM public.notifications n
   WHERE n.tenant_id IN (SELECT tenant_id FROM cp)
     AND n.category = 'stockout' AND n.title = '商品斷貨通知' AND n.body = (SELECT b FROM body)
     AND n.created_at >= (SELECT at FROM t0)
     AND n.member_id IN (SELECT member_id FROM expect_members)
   GROUP BY n.member_id
),
rel AS (   -- 02 第 5 步還回的庫存減抵單：只看這 26 筆身上的、原因有本批標記、而且是 02 那一刻作廢或只扣量（沒作廢）的
  SELECT count(DISTINCT nn.id) AS n,
         count(DISTINCT nn.id) FILTER (WHERE nn.pool_qty > 0) AS n_pool
    FROM public.inventory_deduction_notes nn
    JOIN public.inventory_deduction_note_items ni ON ni.note_id = nn.id
    JOIN param p ON position(p.tag_release IN COALESCE(nn.reason, '')) > 0
   WHERE ni.order_item_id IN (SELECT item_id FROM marked)
     AND (nn.cancelled_at IS NULL OR nn.cancelled_at = (SELECT at FROM t0))
),
dn_void AS ( -- 02 那一刻被作廢的減抵單（含單頭取消時觸發器順便收斂的；只回報）
  SELECT count(*) AS n FROM public.inventory_deduction_notes nn
   WHERE nn.cancelled_at = (SELECT at FROM t0) AND nn.tenant_id IN (SELECT tenant_id FROM cp)
),
other_items AS ( -- 02 那一刻被改到、但不是那 26 筆的品項：分成【內部】現貨池容器的、其他的
  SELECT x.id, (COALESCE(m.member_type, '') = 'store_internal') AS is_pool
    FROM public.customer_order_items x
    JOIN public.customer_orders co ON co.id = x.order_id
    LEFT JOIN public.members m ON m.id = co.member_id
   WHERE x.updated_at = (SELECT at FROM t0) AND x.id NOT IN (SELECT item_id FROM marked)
),
other_orders AS ( -- 02 那一刻被改到、但不是整單取消／收尾完成的單頭
  SELECT co.id, (COALESCE(m.member_type, '') = 'store_internal') AS is_pool
    FROM public.customer_orders co
    LEFT JOIN public.members m ON m.id = co.member_id
   WHERE co.updated_at = (SELECT at FROM t0)
     AND co.id NOT IN (SELECT order_id FROM ord_cancel UNION ALL SELECT order_id FROM ord_done)
),
ci AS (    -- 開團商品設定（02 不該動）
  SELECT count(*) AS n,
         count(*) FILTER (WHERE x.stockout_at IS NOT NULL OR x.updated_at >= (SELECT at FROM t0)) AS changed
    FROM public.campaign_items x JOIN cp ON cp.id = x.campaign_id JOIN sk ON sk.id = x.sku_id
),
v AS (     -- 各項數字先算好
  SELECT
    (SELECT at FROM t0) AS at,
    (SELECT count(*) FROM marked) AS n_marked,
    (SELECT count(*) FROM scope s WHERE s.id IN (SELECT item_id FROM marked)
                                    AND s.status = 'cancelled' AND s.stockout_at = (SELECT at FROM t0)) AS n_still,
    (SELECT COALESCE(sum(s.qty), 0) FROM scope s WHERE s.id IN (SELECT item_id FROM marked)) AS q_marked,
    (SELECT count(*) FROM scope s WHERE s.status = 'pending') AS n_pending,
    (SELECT count(*) FROM public.customer_order_items x
      WHERE x.stockout_at = (SELECT at FROM t0) AND x.id NOT IN (SELECT item_id FROM marked)) AS n_other_stockout,
    (SELECT count(*) FROM other_items WHERE NOT is_pool) AS n_other_items,
    (SELECT count(*) FROM other_items WHERE is_pool) AS n_pool_items,
    (SELECT count(*) FROM other_orders WHERE NOT is_pool) AS n_other_orders,
    (SELECT count(*) FROM other_orders WHERE is_pool) AS n_pool_orders,
    (SELECT count(*) FROM ord_cancel) AS n_cancel,
    (SELECT count(*) FROM public.customer_orders co
      WHERE co.id IN (SELECT order_id FROM ord_cancel)
        AND co.status = 'cancelled' AND co.cancelled_at = (SELECT at FROM t0)) AS n_cancel_ok,
    (SELECT count(*) FROM public.customer_orders co
      WHERE co.id IN (SELECT order_id FROM ord_cancel) AND co.stockout_at IS NOT NULL) AS n_cancel_stockout,
    (SELECT count(*) FROM public.customer_orders co
      WHERE co.stockout_at = (SELECT at FROM t0) AND co.id NOT IN (SELECT order_id FROM ord_cancel)) AS n_other_order_stockout,
    (SELECT count(*) FROM ord_done) AS n_done,
    (SELECT count(*) FROM public.customer_orders co
      WHERE co.id IN (SELECT order_id FROM ord_done) AND co.status = 'completed') AS n_done_ok,
    (SELECT count(*) FROM paid) AS n_paid,
    (SELECT count(*) FROM paid WHERE id IN (SELECT order_id FROM ord_cancel UNION ALL SELECT order_id FROM ord_done)) AS n_paid_touched,
    (SELECT count(*) FROM expect_members) AS n_members,
    (SELECT COALESCE(sum(c), 0) FROM notif) AS n_notif,
    (SELECT count(*) FROM notif) AS n_notif_members,
    (SELECT count(*) FROM notif WHERE c > 1) AS n_notif_dup,
    (SELECT n FROM undo) AS n_undo,
    (SELECT at FROM undo) AS undo_at
)
SELECT "段落", "項目", "數量", "結果", "說明"
FROM (
  SELECT 0 AS o, '⓪ 02 做過了沒'::text AS "段落", '最近一次 02 的時間'::text AS "項目", (SELECT n_marked FROM v)::numeric AS "數量",
         CASE WHEN (SELECT at FROM v) IS NULL THEN '❌ 找不到 02 的紀錄（還沒貼 02？）'
              ELSE '✅ ' || to_char((SELECT at FROM v) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') END AS "結果",
         '台北時間；重貼 02 的話這個時間不會變（重貼不會重做）'::text AS "說明"
  UNION ALL
  SELECT 1, '① 26 筆都已取消', '那一次取消的品項', (SELECT n_marked FROM v),
         CASE WHEN (SELECT n_marked FROM v) = (SELECT expect_rows FROM param) AND (SELECT q_marked FROM v) = (SELECT expect_qty FROM param)
              THEN '✅ 26 筆、32 件' ELSE '❌ 應為 26 筆、32 件（現在 ' || (SELECT n_marked FROM v) || ' 筆、' || trim_scale((SELECT q_marked FROM v)) || ' 件）' END,
         '看 02 寫的編輯歷史（松山 1 筆是老闆 10/21 手動刪除的，不算在內）'
  UNION ALL
  SELECT 2, '① 26 筆都已取消', '現在還是「已取消＋斷貨」', (SELECT n_still FROM v),
         CASE WHEN (SELECT n_undo FROM v) > 0 THEN 'ℹ 已用 05 還原（' || to_char((SELECT undo_at FROM v) AT TIME ZONE 'Asia/Taipei', 'MM-DD HH24:MI') || '），這一列不適用'
              WHEN (SELECT n_still FROM v) = (SELECT expect_rows FROM param) THEN '✅ 26 筆'
              ELSE '❌ 應為 26 筆' END,
         '品項狀態已取消、斷貨時間＝02 那一刻'
  UNION ALL
  SELECT 3, '② 範圍', '這一團這商品還在等貨中的品項', (SELECT n_pending FROM v),
         CASE WHEN (SELECT n_undo FROM v) > 0 THEN 'ℹ 已用 05 還原，這一列不適用'
              WHEN (SELECT n_pending FROM v) = 0 THEN '✅ 0 筆' ELSE '❌ 應為 0 筆' END,
         '02 之後新下的單也會算進來'
  UNION ALL
  SELECT 4, '③ 沒有多動', '別的品項被蓋上同一個斷貨時間', (SELECT n_other_stockout FROM v),
         CASE WHEN (SELECT n_other_stockout FROM v) = 0 THEN '✅ 0 筆' ELSE '❌ 應為 0 筆' END, '全系統查'
  UNION ALL
  SELECT 5, '③ 沒有多動', '別的品項在 02 那一刻被改過（不含【內部】現貨池）', (SELECT n_other_items FROM v),
         CASE WHEN (SELECT n_other_items FROM v) = 0 THEN '✅ 0 筆' ELSE '❌ 應為 0 筆' END, '全系統查；看修改時間'
  UNION ALL
  SELECT 5.5, '③ 沒有多動', '【內部】現貨池的品項／單頭在 02 那一刻被改過', ((SELECT n_pool_items FROM v) + (SELECT n_pool_orders FROM v))::numeric,
         CASE WHEN (SELECT n_pool_items FROM v) + (SELECT n_pool_orders FROM v) = 0 THEN 'ℹ 0'
              WHEN (SELECT n_pool FROM rel) > 0 THEN 'ℹ 品項 ' || (SELECT n_pool_items FROM v) || ' 筆、單頭 ' || (SELECT n_pool_orders FROM v) || ' 張（02 把配過的貨還回池子）'
              ELSE '❌ 沒有還回池子的紀錄，卻改到池子' END,
         '只有 02 第 5 步把店內庫存配貨還回【內部】現貨池時才會有；預期 0'
  UNION ALL
  SELECT 6, '③ 沒有多動', '別的訂單單頭在 02 那一刻被改過（不含【內部】現貨池）', (SELECT n_other_orders FROM v),
         CASE WHEN (SELECT n_other_orders FROM v) = 0 THEN '✅ 0 張' ELSE '❌ 應為 0 張' END, '全系統查；只該有下面整單取消、收尾完成那幾張'
  UNION ALL
  SELECT 7, '③ 沒有多動', '開團商品設定（這團這商品）', (SELECT changed FROM ci),
         CASE WHEN (SELECT n FROM ci) = 0 THEN 'ℹ 找不到開團商品列'
              WHEN (SELECT changed FROM ci) = 0 THEN '✅ 沒被動' ELSE '❌ 02 之後被改過' END,
         '02 不蓋開團商品的斷貨標記（需求暨計畫第 3 節第 5 點）'
  UNION ALL
  SELECT 8, '④ 整單取消', '整單取消的單', (SELECT n_cancel FROM v),
         CASE WHEN (SELECT n_undo FROM v) > 0 THEN 'ℹ ' || (SELECT n_cancel FROM v) || ' 張（已用 05 還原）'
              WHEN (SELECT n_cancel_ok FROM v) = (SELECT n_cancel FROM v) THEN '✅ ' || (SELECT n_cancel FROM v) || ' 張，現在都是已取消'
              ELSE '❌ 其中只有 ' || (SELECT n_cancel_ok FROM v) || ' 張現在是已取消' END,
         '跟 01 第③段「整單取消」比；02 之前的狀態：'
           || COALESCE((SELECT string_agg(before_status || ' ' || n, '、') FROM (SELECT before_status, count(*) AS n FROM ord_cancel GROUP BY before_status) z), '（沒有）')
  UNION ALL
  SELECT 8.1, '④ 整單取消', '整單取消的單頭都有斷貨標記', (SELECT n_cancel_stockout FROM v),
         CASE WHEN (SELECT n_undo FROM v) > 0 THEN 'ℹ 已用 05 還原，這一列不適用'
              WHEN (SELECT n_cancel_stockout FROM v) = (SELECT n_cancel FROM v) THEN '✅ ' || (SELECT n_cancel FROM v) || ' 張都有'
              ELSE '❌ 只有 ' || (SELECT n_cancel_stockout FROM v) || ' 張有（應為 ' || (SELECT n_cancel FROM v) || ' 張）' END,
         '客人 App 會看到「⛔ 供應商斷貨，本筆訂單已取消」；後台不出現「復原取消」鈕（要救只能用 05）'
  UNION ALL
  SELECT 8.2, '④ 整單取消', '其他單頭被蓋上同一個斷貨時間', (SELECT n_other_order_stockout FROM v),
         CASE WHEN (SELECT n_other_order_stockout FROM v) = 0 THEN '✅ 0 張' ELSE '❌ 應為 0 張' END,
         '全系統查；收尾成已完成、單子留著、付過錢的單頭都不該蓋'
  UNION ALL
  SELECT 9, '④ 整單取消', '收尾成已完成的單', (SELECT n_done FROM v),
         CASE WHEN (SELECT n_undo FROM v) > 0 THEN 'ℹ ' || (SELECT n_done FROM v) || ' 張（已用 05 還原）'
              WHEN (SELECT n_done_ok FROM v) = (SELECT n_done FROM v) THEN '✅ ' || (SELECT n_done FROM v) || ' 張'
              ELSE '❌ 其中只有 ' || (SELECT n_done_ok FROM v) || ' 張現在是已完成' END,
         '跟 01 第③段「收尾成已完成」比'
  UNION ALL
  SELECT 10, '⑤ 付過錢的單沒被動', '付過錢／用過儲值金的單', (SELECT n_paid FROM v),
         CASE WHEN (SELECT n_paid_touched FROM v) = 0 THEN '✅ ' || (SELECT n_paid FROM v) || ' 張，單頭都沒被 02 改'
              ELSE '❌ 有 ' || (SELECT n_paid_touched FROM v) || ' 張被 02 改了單頭' END,
         '這種單只取消品項、不取消單、不退錢；有的話要人工處理退款'
  UNION ALL
  SELECT 11, '⑥ 通知（03）', '02 之後發給這批會員的「這一則」斷貨通知', (SELECT n_notif FROM v),
         CASE WHEN (SELECT n_notif FROM v) = 0 THEN 'ℹ 還沒發（沒有貼 03，或老闆決定不發）'
              WHEN (SELECT n_notif_members FROM v) = (SELECT n_members FROM v) AND (SELECT n_notif_dup FROM v) = 0
                THEN '✅ ' || (SELECT n_notif FROM v) || ' 則，一位會員一則'
              ELSE '❌ 應為 ' || (SELECT n_members FROM v) || ' 位各 1 則；現在 ' || (SELECT n_notif_members FROM v) || ' 位收到、共 ' || (SELECT n_notif FROM v) || ' 則' END,
         '類別、標題、內文跟 03 算出來的全等才算；應發 ' || (SELECT n_members FROM v) || ' 位會員（沒綁會員的發不到）'
  UNION ALL
  SELECT 12, '⑦ 其他', '還回去的庫存減抵單（這 26 筆身上的）', (SELECT n FROM rel),
         'ℹ ' || (SELECT n FROM rel) || ' 張', '品項有從店內庫存配過貨才會有；預期 0'
  UNION ALL
  SELECT 12.5, '⑦ 其他', '02 那一刻被作廢的庫存減抵單（全部）', (SELECT n FROM dn_void),
         'ℹ ' || (SELECT n FROM dn_void) || ' 張',
         '含單頭取消時觸發器「順便收斂」同張減抵單上其他已死訂單的（20260813002000:100-127）；不可逆'
  UNION ALL
  SELECT 13, '⑦ 其他', '05 還原過了沒（數量＝還原寫的編輯歷史列數）', (SELECT n_undo FROM v),
         CASE WHEN (SELECT n_undo FROM v) = 0 THEN 'ℹ 沒有還原過'
              ELSE 'ℹ 還原過：' || to_char((SELECT undo_at FROM v) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') END,
         '05 是備用的，平常不會貼'
) x
ORDER BY o;

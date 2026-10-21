-- ============================================================================
--  01 預覽（只查不改：整份只有一句查詢）
--  契爾氏 kiehl's 金盞花植物精華化妝水 40ml（商品 G02596-01）叫錯款式、廠商沒有正確款
--  團 GRP-20260910-027：02 會取消哪些客人品項、哪些訂單會整張取消、哪些付過錢不會動
--  日期：2026-10-21　阿寫寫
--  ⛔ 輸出不列客人姓名、電話、會員編號（只列門市、訂單號、狀態、件數）
-- ============================================================================
--  各段在看什麼
--    ⓪ 對象：團、商品各剛好一個；這團這商品接到的採購單；叫貨後取消照派原店（#1084）的分界時間原文
--    ① 會被 02 取消的品項，一筆一列：門市、訂單號、單頭狀態、件數、取消後這張單會怎樣
--    ② 總計：應為 25 筆、29 件，全部等貨中、沒有斷貨標記
--       （10/21 早上查是 27 筆 33 件；松山 1 筆已由老闆 10/21 中午在後台手動「刪除品項」（整單已一併取消）；
--        南平 1 張（3 件）店家 10/21～22 已按「取消訂單」，單頭已取消、不動；這兩張都不在範圍，會出現在第④段）
--    ③ 訂單收尾預估：整單取消幾張、收尾成已完成幾張、單子留著幾張、付過錢／用過儲值金不動幾張
--    ④ 同一團同一商品、不在這次範圍的品項（02 不會動）
--    ⑤ 正式系統裡實際掛的觸發器（跟程式碼紀錄比對；多出來的要先給 CEO 看）
--    ⑥ 請購單：還在草稿、還沒轉採購的這團這商品請購列（請購草稿同步按鈕會不會受影響）
--    ⑦ 02 做過了沒
--    ⑧ 03 通知預估：會發幾則、沒綁會員的有幾筆、通知文字
--    ⑨ 操作人候選：這家公司的總部帳號（老闆認出自己那一列，把那串 UUID 交給 CEO 填進 02／05）
--  「結果」欄：✅ 符合預期　❌ 跟預期不同（先停，截圖給 CEO；有任何一列 ❌ 就不要貼 02／03）　ℹ 參考　⚠ 要注意
-- ============================================================================
WITH
param AS (
  SELECT 'GRP-20260910-027'::text AS campaign_no,
         'G02596-01'::text        AS sku_code,
         25                       AS expect_rows,   -- 10/21 早上 27；松山 1 筆老闆已手動刪除、南平 1 張店家已按取消訂單
         29::numeric              AS expect_qty,    -- 10/21 早上 33；松山少 1 件、南平少 3 件
         '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消'::text AS tag_item
),
cp AS (
  SELECT c.id, c.tenant_id, c.campaign_no, c.status, c.end_at
    FROM public.group_buy_campaigns c JOIN param p ON p.campaign_no = c.campaign_no
),
sk AS (
  SELECT s.id, s.tenant_id, s.sku_code,
         COALESCE(s.product_name, s.sku_code) || COALESCE('-' || s.variant_name, '') AS label
    FROM public.skus s
    JOIN cp ON cp.tenant_id = s.tenant_id
    JOIN param p ON p.sku_code = s.sku_code
),
tgt AS (   -- 02 會取消的：這一團 × 這個商品 × 品項等貨中
  SELECT i.id AS item_id, i.order_id, i.qty, i.stockout_at,
         co.order_no, co.status AS order_status, co.member_id, co.order_kind,
         COALESCE(st.name, '?') AS store_name,
         COALESCE(m.member_type, '') AS member_type
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
    JOIN cp ON cp.id = co.campaign_id AND cp.tenant_id = co.tenant_id AND cp.tenant_id = i.tenant_id
    JOIN sk ON sk.id = i.sku_id
    LEFT JOIN public.stores st ON st.id = co.pickup_store_id
    LEFT JOIN public.members m ON m.id = co.member_id
   WHERE i.status = 'pending'
     AND co.status NOT IN ('cancelled', 'expired')   -- 單頭已取消／過期的不算（店家已按取消訂單），列在第④段
),
skip AS (  -- 不在範圍：單頭已取消／過期、品項還等貨中（店家按了後台「取消訂單」，它只改單頭不改品項）
  SELECT co.order_no, COALESCE(st.name, '?') AS store_name, co.status AS order_status, co.cancelled_at, i.qty
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
    JOIN cp ON cp.id = co.campaign_id AND cp.tenant_id = co.tenant_id AND cp.tenant_id = i.tenant_id
    JOIN sk ON sk.id = i.sku_id
    LEFT JOIN public.stores st ON st.id = co.pickup_store_id
   WHERE i.status = 'pending' AND co.status IN ('cancelled', 'expired')
),
tenant_bad AS ( -- 這一團這商品，單頭或品項的公司（租戶）跟團不一致的（02 會停）
  SELECT count(*) AS n
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
    JOIN cp ON cp.id = co.campaign_id
    JOIN public.skus s2 ON s2.id = i.sku_id JOIN param p ON p.sku_code = s2.sku_code
   WHERE co.tenant_id <> cp.tenant_id OR i.tenant_id <> cp.tenant_id
),
cov AS (   -- 這幾筆身上還有效的「從店內庫存配貨」量（02 會先還回；算法同 _order_item_stock_budget 的 mine 段）
  SELECT ni.order_item_id, SUM(GREATEST(ni.qty - COALESCE(ni.released_qty, 0), 0)) AS assigned
    FROM public.inventory_deduction_note_items ni
    JOIN public.inventory_deduction_notes n ON n.id = ni.note_id AND n.cancelled_at IS NULL
   WHERE ni.order_item_id IN (SELECT item_id FROM tgt)
   GROUP BY ni.order_item_id
),
ord AS (   -- 每張受影響的訂單：拿掉這幾筆之後還剩什麼（規則同 02 第 8 步＝刪除品項第 9 步）
  SELECT co.id, co.order_no, co.status, co.payment_status, co.wallet_paid_amount, co.cancelled_at, co.stockout_at,
         COALESCE(st.name, '?') AS store_name,
         count(*) FILTER (WHERE x.status IN ('pending', 'reserved', 'ready')
                            AND x.id NOT IN (SELECT item_id FROM tgt))                    AS open_left,
         COALESCE(bool_or(x.status = 'picked_up'), FALSE)                                  AS has_picked,
         count(*) FILTER (WHERE x.status NOT IN ('pending', 'reserved', 'ready', 'picked_up',
                                                 'cancelled', 'expired'))                  AS odd_items
    FROM public.customer_orders co
    JOIN public.customer_order_items x ON x.order_id = co.id
    LEFT JOIN public.stores st ON st.id = co.pickup_store_id
   WHERE co.id IN (SELECT order_id FROM tgt)
   GROUP BY co.id, co.order_no, co.status, co.payment_status, co.wallet_paid_amount, co.cancelled_at, co.stockout_at, st.name
),
fate AS (
  SELECT ord.*,
         CASE WHEN open_left > 0 THEN 'keep'
              WHEN has_picked THEN 'done'
              WHEN COALESCE(payment_status, 'unpaid') <> 'paid' AND COALESCE(wallet_paid_amount, 0) = 0 THEN 'cancel'
              ELSE 'paid' END AS fate
    FROM ord
),
other AS ( -- 同一團同一商品、不是等貨中的品項（02 不動）
  SELECT i.status, count(*) AS n, COALESCE(sum(i.qty), 0) AS q
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
    JOIN cp ON cp.id = co.campaign_id
    JOIN sk ON sk.id = i.sku_id
   WHERE i.status <> 'pending'
   GROUP BY i.status
),
po AS (    -- 這團這商品接到的採購單品項（請購單 → 採購單；連法同派貨需求表的 po_campaigns）
  SELECT DISTINCT p.po_no, p.status AS po_status, poi.id AS po_item_id, poi.qty_ordered, poi.qty_received,
         poi.created_at, poi.stockout_at
    FROM public.purchase_order_items poi
    JOIN public.purchase_orders p ON p.id = poi.po_id
    JOIN public.purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN sk ON sk.id = poi.sku_id
   WHERE pri.pr_id IN (SELECT prc.pr_id FROM public.purchase_request_campaigns prc JOIN cp ON cp.id = prc.campaign_id)
      OR pri.source_campaign_id IN (SELECT id FROM cp)
),
cutover AS ( -- #1084 分界時間：正式系統裡那支函式的原文（沒有這支＝#1084 沒貼過）
  SELECT p.prosrc, substring(p.prosrc FROM '''([^'']+)''') AS lit
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_picking_po_rule_cutover'
),
cutover2 AS (
  SELECT lit,
         CASE WHEN lit ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9:]+)?([+-][0-9]{2})?$' THEN lit::timestamptz END AS at
    FROM cutover
),
trg AS (   -- 正式系統裡實際掛在這四張表上的觸發器
  SELECT c.relname AS tbl, t.tgname, t.tgenabled, pr.proname
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_proc pr ON pr.oid = t.tgfoid
   WHERE NOT t.tgisinternal AND n.nspname = 'public'
     AND c.relname IN ('customer_orders', 'customer_order_items', 'customer_order_audit_log', 'notifications')
),
expect_trg AS (
  SELECT * FROM (VALUES
    ('customer_orders', 'trg_touch_corders', '改到的單頭蓋修改時間（20260423120000:329）'),
    ('customer_orders', 'trg_release_idn_coverage', '單頭變已取消時釋放庫存減抵單覆蓋（20260813002000:173-179）'),
    ('customer_order_items', 'trg_touch_coi', '改到的品項蓋修改時間（20260423120000:331）'),
    ('customer_order_items', 'trg_coi_backorder_source_clear', '待補貨時間清掉時一起清來源標記（20260902030000:185-191），02 不碰這兩欄'),
    ('customer_order_audit_log', 'trg_no_mut_coa', '編輯歷史只能新增、不能改刪（20260605000001:27-28）')
  ) v(tbl, tgname, what)
),
draft AS ( -- 還在草稿、還沒轉採購的這團這商品請購列
  SELECT count(*) AS n
    FROM public.purchase_request_items pri
    JOIN public.purchase_requests pr ON pr.id = pri.pr_id
    JOIN sk ON sk.id = pri.sku_id
   WHERE pr.status = 'draft' AND pri.po_item_id IS NULL
     AND (pri.pr_id IN (SELECT prc.pr_id FROM public.purchase_request_campaigns prc JOIN cp ON cp.id = prc.campaign_id)
          OR pri.source_campaign_id IN (SELECT id FROM cp))
),
done AS (  -- 02 留下的編輯歷史（原因那一句是固定的）
  SELECT count(*) AS n, max(a.created_at) AS at
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag_item
   WHERE a.entity_type = 'item' AND a.field = 'status'
),
mem AS (   -- 03 會發幾則（一位會員一則；沒綁會員的發不了，同斷貨 (d) 段）
  SELECT count(DISTINCT member_id) AS members, count(*) FILTER (WHERE member_id IS NULL) AS no_member
    FROM tgt
),
ops AS (   -- 這家公司的總部帳號（認法同 02：app_metadata.tenant_id＋總部角色）
  SELECT u.id, u.email, u.last_sign_in_at, COALESCE(u.raw_app_meta_data ->> 'role', '') AS role
    FROM auth.users u
   WHERE (u.raw_app_meta_data ->> 'tenant_id') IN (SELECT tenant_id::text FROM cp)
     AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')
)
SELECT "段落", "項目", "門市", "數量", "結果", "說明"
FROM (
  -- ⓪ 對象
  SELECT 0 AS o1, 1 AS o2, '⓪ 對象'::text AS "段落", '團 GRP-20260910-027'::text AS "項目", NULL::text AS "門市",
         NULL::numeric AS "數量",
         CASE WHEN (SELECT count(*) FROM cp) = 1 THEN '✅ 剛好 1 個' ELSE '❌ 查到 ' || (SELECT count(*) FROM cp) || ' 個' END AS "結果",
         COALESCE((SELECT '開團狀態 ' || status || COALESCE('／結單 ' || to_char(end_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '') FROM cp LIMIT 1), '') AS "說明"
  UNION ALL
  SELECT 0, 2, '⓪ 對象', '商品 G02596-01', NULL, NULL,
         CASE WHEN (SELECT count(*) FROM sk) = 1 THEN '✅ 剛好 1 個' ELSE '❌ 查到 ' || (SELECT count(*) FROM sk) || ' 個' END,
         COALESCE((SELECT label FROM sk LIMIT 1), '')
  UNION ALL
  SELECT 0, 3, '⓪ 對象', '採購單 ' || po.po_no, NULL, po.qty_received,
         'ℹ ' || po.po_status,
         '訂 ' || trim_scale(po.qty_ordered) || '／已收 ' || trim_scale(po.qty_received)
           || '／這一項成立 ' || to_char(po.created_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI')
           || CASE WHEN po.stockout_at IS NOT NULL THEN '／已標斷貨' ELSE '／沒標斷貨' END
           || '（02 不動採購單）'
    FROM po
  UNION ALL
  SELECT 0, 4, '⓪ 對象', '叫貨後取消照派原店（#1084）分界', NULL, NULL,
         CASE WHEN NOT EXISTS (SELECT 1 FROM cutover) THEN 'ℹ 正式系統沒有這支（#1084 沒貼過）→ 不套'
              WHEN (SELECT at FROM cutover2) IS NULL THEN '⚠ 分界不是日期：' || COALESCE((SELECT lit FROM cutover2), '（讀不到）')
              WHEN NOT EXISTS (SELECT 1 FROM po) THEN '⚠ 找不到這團這商品的採購單品項'
              WHEN (SELECT max(created_at) FROM po) < (SELECT at FROM cutover2) THEN '✅ 採購單品項早於分界 → 不套'
              ELSE '❌ 有採購單品項晚於分界，請先給 CEO 看' END,
         '分界原文：' || COALESCE((SELECT lit FROM cutover2), '（沒有）')
           || '。就算套，02 會蓋品項斷貨時間，#1084 那支表兩段都排除有斷貨標記的品項（20261016000000:848、:877）'

  -- ① 會被取消的品項（一筆一列）
  UNION ALL
  SELECT 1, ROW_NUMBER() OVER (ORDER BY t.store_name, t.order_no, t.item_id)::int, '① 會被取消的品項', t.order_no, t.store_name, t.qty,
         CASE t.order_status WHEN 'pending' THEN '待確認' WHEN 'confirmed' THEN '已確認' WHEN 'shipping' THEN '出貨中'
                             WHEN 'ready' THEN '可取貨' WHEN 'partially_completed' THEN '部分取貨' ELSE '❌ ' || t.order_status END
           || '／品項等貨中',
         CASE f.fate WHEN 'cancel' THEN '這張單只剩這一項 → 整單取消（單頭標斷貨）'
                     WHEN 'keep'   THEN '單上還有 ' || f.open_left || ' 項待取 → 只取消這一項，單子留著'
                     WHEN 'done'   THEN '其他品項都取過了 → 訂單收尾成「已完成」'
                     ELSE '⚠ 付過錢／用過儲值金 → 只取消這一項，單子不動、不退錢，要人工處理' END
           || CASE WHEN COALESCE(cv.assigned, 0) > 0 THEN '；⚠ 從店內庫存配過 ' || trim_scale(cv.assigned) || ' 件，02 會先還回' ELSE '' END
           || CASE WHEN t.member_type = 'store_internal' THEN '；⚠ 這是【內部】現貨池的單' ELSE '' END
           || CASE WHEN t.order_kind <> 'normal' THEN '；⚠ 單別 ' || t.order_kind ELSE '' END
           || CASE WHEN t.member_id IS NULL THEN '；沒綁會員（03 發不到）' ELSE '' END
    FROM tgt t JOIN fate f ON f.id = t.order_id LEFT JOIN cov cv ON cv.order_item_id = t.item_id

  -- ② 總計
  UNION ALL
  SELECT 2, 1, '② 總計', '等貨中的品項筆數', NULL, (SELECT count(*) FROM tgt),
         CASE WHEN (SELECT count(*) FROM tgt) = (SELECT expect_rows FROM param) THEN '✅ 25 筆' ELSE '❌ 應為 25 筆' END,
         '02 會先檢查這個數字，不是 25 就整份停下、什麼都不改（松山 1 筆老闆 10/21 已手動刪除、南平 1 張店家已按取消訂單，都不算在內）'
  UNION ALL
  SELECT 2, 2, '② 總計', '等貨中的件數', NULL, (SELECT COALESCE(sum(qty), 0) FROM tgt),
         CASE WHEN (SELECT COALESCE(sum(qty), 0) FROM tgt) = (SELECT expect_qty FROM param) THEN '✅ 29 件' ELSE '❌ 應為 29 件' END,
         '同上，不是 29 就停'
  UNION ALL
  SELECT 2, 3, '② 總計', '已經帶斷貨標記的', NULL, (SELECT count(*) FROM tgt WHERE stockout_at IS NOT NULL),
         CASE WHEN (SELECT count(*) FROM tgt WHERE stockout_at IS NOT NULL) = 0 THEN '✅ 0 筆' ELSE '❌ 應為 0' END,
         '有的話 02 會停'
  UNION ALL
  SELECT 2, 4, '② 總計', '涉及的門市／訂單', NULL, (SELECT count(DISTINCT order_id) FROM tgt),
         'ℹ ' || (SELECT count(DISTINCT store_name) FROM tgt) || ' 家店、' || (SELECT count(DISTINCT order_id) FROM tgt) || ' 張單',
         (SELECT string_agg(s || ' ' || n || ' 筆', '／' ORDER BY s) FROM (SELECT store_name AS s, count(*) AS n FROM tgt GROUP BY store_name) z)
  UNION ALL
  SELECT 2, 7, '② 總計', '公司（租戶）跟團不一致的品項', NULL, (SELECT n FROM tenant_bad),
         CASE WHEN (SELECT n FROM tenant_bad) = 0 THEN '✅ 0 筆' ELSE '❌ 應為 0（02 會停）' END,
         '這一團這商品的單頭、品項都要跟團是同一家公司'
  UNION ALL
  SELECT 2, 5, '② 總計', '單頭狀態不在預期裡的單', NULL,
         (SELECT count(*) FROM fate WHERE status NOT IN ('pending', 'confirmed', 'shipping', 'ready', 'partially_completed')),
         CASE WHEN (SELECT count(*) FROM fate WHERE status NOT IN ('pending', 'confirmed', 'shipping', 'ready', 'partially_completed')) = 0
              THEN '✅ 0 張' ELSE '❌ 應為 0（02 會停）' END,
         '預期只有 待確認／已確認／出貨中／可取貨／部分取貨'
  UNION ALL
  SELECT 2, 6, '② 總計', '單上有少見品項狀態的單', NULL, (SELECT count(*) FROM fate WHERE odd_items > 0),
         CASE WHEN (SELECT count(*) FROM fate WHERE odd_items > 0) = 0 THEN '✅ 0 張' ELSE '❌ 應為 0（02 會停）' END,
         '例如「部分領走」：收尾規則對不上，02 會停'

  -- ③ 訂單收尾預估
  UNION ALL
  SELECT 3, 1, '③ 訂單收尾', '整單取消', NULL, (SELECT count(*) FROM fate WHERE fate = 'cancel'),
         'ℹ ' || (SELECT count(*) FROM fate WHERE fate = 'cancel') || ' 張',
         '只剩這一項、一件都沒取、沒付款、沒用儲值金。單頭改「已取消」＋蓋斷貨時間（照斷貨的做法）→ 客人 App 看得到這張，寫「⛔ 供應商斷貨，本筆訂單已取消」；後台不會出現「復原取消」鈕（要救只能用 05）'
  UNION ALL
  SELECT 3, 2, '③ 訂單收尾', '收尾成已完成', NULL, (SELECT count(*) FROM fate WHERE fate = 'done'),
         'ℹ ' || (SELECT count(*) FROM fate WHERE fate = 'done') || ' 張', '其他品項都取過了'
  UNION ALL
  SELECT 3, 3, '③ 訂單收尾', '單子留著（還有別的待取品項）', NULL, (SELECT count(*) FROM fate WHERE fate = 'keep'),
         CASE WHEN (SELECT count(*) FROM fate WHERE fate = 'keep') = 0 THEN 'ℹ 0 張' ELSE '⚠ ' || (SELECT count(*) FROM fate WHERE fate = 'keep') || ' 張' END,
         '只少這一項、單頭狀態不變。⚠ 其中「出貨中」的單，店家收這批錯貨時客人仍可能收到「您的商品到貨」推播（既有行為，02 不改）'
  UNION ALL
  SELECT 3, 4, '③ 訂單收尾', '付過錢／用過儲值金（不動）', NULL, (SELECT count(*) FROM fate WHERE fate = 'paid'),
         CASE WHEN (SELECT count(*) FROM fate WHERE fate = 'paid') = 0 THEN '✅ 0 張' ELSE '⚠ ' || (SELECT count(*) FROM fate WHERE fate = 'paid') || ' 張，要人工處理退款' END,
         COALESCE((SELECT string_agg(store_name || ' ' || order_no, '、' ORDER BY store_name, order_no) FROM fate WHERE fate = 'paid'), '（沒有）')
  UNION ALL
  SELECT 3, 5, '③ 訂單收尾', '原本就有取消時間的（會整單取消的那幾張）', NULL,
         (SELECT count(*) FROM fate WHERE fate = 'cancel' AND cancelled_at IS NOT NULL),
         CASE WHEN (SELECT count(*) FROM fate WHERE fate = 'cancel' AND cancelled_at IS NOT NULL) = 0 THEN '✅ 0 張'
              ELSE '❌ ' || (SELECT count(*) FROM fate WHERE fate = 'cancel' AND cancelled_at IS NOT NULL) || ' 張（02 會停）' END,
         '以前取消過又被救回的單；02 寫入前會擋（不然 05 還原時會弄丟那個舊取消時間）'
  UNION ALL
  SELECT 3, 7, '③ 訂單收尾', '原本就有斷貨時間的（會整單取消的那幾張）', NULL,
         (SELECT count(*) FROM fate WHERE fate = 'cancel' AND stockout_at IS NOT NULL),
         CASE WHEN (SELECT count(*) FROM fate WHERE fate = 'cancel' AND stockout_at IS NOT NULL) = 0 THEN '✅ 0 張'
              ELSE '⚠ ' || (SELECT count(*) FROM fate WHERE fate = 'cancel' AND stockout_at IS NOT NULL) || ' 張' END,
         '02 不覆蓋原本的斷貨時間（05 也不會清它）；收尾成已完成、單子留著、付過錢的單頭都不蓋'
  UNION ALL
  SELECT 3, 6, '③ 訂單收尾', '從店內庫存配過貨的品項', NULL, (SELECT count(*) FROM cov WHERE assigned > 0),
         CASE WHEN (SELECT count(*) FROM cov WHERE assigned > 0) = 0 THEN 'ℹ 0 筆' ELSE '⚠ ' || (SELECT count(*) FROM cov WHERE assigned > 0) || ' 筆' END,
         '02 會先還回（跟刪除品項同一支）；⚠ 這一步 05 還原不會自動配回去'

  -- ④ 同團同商品、不在範圍的
  UNION ALL
  SELECT 4, 1, '④ 不在範圍（02 不動）', '品項狀態 ' || o.status, NULL, o.q, 'ℹ ' || o.n || ' 筆', '同一團同一商品，但不是等貨中（松山 1 筆老闆 10/21 已手動刪除品項，應該在「cancelled」這一列）'
    FROM other o
  UNION ALL
  SELECT 4, 2, '④ 不在範圍（02 不動）', '（沒有）', NULL, NULL, 'ℹ', '同一團同一商品沒有其他狀態的品項'
   WHERE NOT EXISTS (SELECT 1 FROM other)
  UNION ALL
  SELECT 4, 3, '④ 不在範圍（02 不動）', 'ℹ 單頭已取消、品項還等貨中：' || k.order_no, k.store_name, k.qty,
         'ℹ 單頭 ' || CASE k.order_status WHEN 'cancelled' THEN '已取消' ELSE '已過期' END
           || COALESCE('（' || to_char(k.cancelled_at AT TIME ZONE 'Asia/Taipei', 'MM-DD HH24:MI') || '）', ''),
         '店家按了後台「取消訂單」（只改單頭、不改品項，系統原本就這樣）；業務上已經取消 → 02 不動、03 不發、05 不碰；不算錯、不擋'
    FROM skip k

  -- ⑤ 觸發器
  UNION ALL
  SELECT 5, 1, '⑤ 正式系統的觸發器', t.tbl || '.' || t.tgname, NULL, NULL,
         CASE WHEN e.tgname IS NULL THEN '❌ 程式碼紀錄裡沒有這支，貼 02／03 之前先給 CEO 看'
              WHEN t.tgenabled = 'D' THEN '⚠ 已停用'
              ELSE '✅ 有、啟用中' END,
         COALESCE(e.what, '函式 ' || t.proname)
    FROM trg t LEFT JOIN expect_trg e ON e.tbl = t.tbl AND e.tgname = t.tgname
  UNION ALL
  SELECT 5, 2, '⑤ 正式系統的觸發器', e.tbl || '.' || e.tgname, NULL, NULL, '❌ 正式系統沒有這支：貼 02 之前要停，先給 CEO 看', e.what
    FROM expect_trg e WHERE NOT EXISTS (SELECT 1 FROM trg t WHERE t.tbl = e.tbl AND t.tgname = e.tgname)
  UNION ALL
  SELECT 5, 3, '⑤ 正式系統的觸發器', 'notifications（會員通知）', NULL, (SELECT count(*) FROM trg WHERE tbl = 'notifications'),
         CASE WHEN NOT EXISTS (SELECT 1 FROM trg WHERE tbl = 'notifications') THEN '✅ 沒有任何觸發器' ELSE '❌ 有觸發器，貼 03 之前先給 CEO 看' END,
         '沒有的話，03 只會在會員 App 通知中心留一則，不會推 LINE、不會推手機'

  -- ⑥ 請購草稿
  UNION ALL
  SELECT 6, 1, '⑥ 請購單', '還在草稿、還沒轉採購的這團這商品請購列', NULL, (SELECT n FROM draft),
         CASE WHEN (SELECT n FROM draft) = 0 THEN '✅ 0 列' ELSE '⚠ ' || (SELECT n FROM draft) || ' 列' END,
         '02 不改請購單；請購草稿的「同步最新開團數量」是按鈕、不會自己跑（#1049）。有草稿列的話，之後按同步會往下修'

  -- ⑦ 做過了沒
  UNION ALL
  SELECT 7, 1, '⑦ 02 做過了沒', '這一次取消留下的編輯歷史', NULL, (SELECT n FROM done),
         CASE WHEN (SELECT n FROM done) = 0 THEN 'ℹ 還沒做過' ELSE '⚠ 已經有 ' || (SELECT n FROM done) || ' 筆' END,
         CASE WHEN (SELECT n FROM done) = 0 THEN '可以照順序貼 02'
              ELSE '最近一次：' || to_char((SELECT at FROM done) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') || '（重貼 02 不會重做）' END

  -- ⑧ 03 通知預估
  UNION ALL
  SELECT 8, 1, '⑧ 03 通知預估', '會收到通知的會員', NULL, (SELECT members FROM mem),
         'ℹ ' || (SELECT members FROM mem) || ' 位（一位一則）',
         '沒綁會員、發不到的品項 ' || (SELECT no_member FROM mem) || ' 筆'
  UNION ALL
  SELECT 8, 2, '⑧ 03 通知預估', '通知文字', NULL, NULL, 'ℹ',
         '標題「商品斷貨通知」；內容「您訂購的「' || COALESCE((SELECT label FROM sk LIMIT 1), '?')
           || '」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。」'

  -- ⑨ 操作人候選
  UNION ALL
  SELECT 9, ROW_NUMBER() OVER (ORDER BY o.last_sign_in_at DESC NULLS LAST)::int, '⑨ 操作人候選', COALESCE(o.email, '（沒有 email）'), NULL, NULL,
         o.id::text,
         '角色 ' || CASE WHEN o.role = '' THEN '（空白＝總部）' ELSE o.role END || '　最後登入 '
           || COALESCE(to_char(o.last_sign_in_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '—')
           || '　→ 老闆認出自己那一列，把「結果」欄那串交給 CEO'
    FROM ops o
) x
ORDER BY o1, o2, "門市" NULLS FIRST, "項目";

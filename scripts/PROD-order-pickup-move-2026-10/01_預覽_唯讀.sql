-- ============================================================================
--  01 預覽（只看不改）：客人 4 張還沒取的訂單，取貨店 萬華 → 中和，貼 02 之前先看
--  日期：2026-10-31（第 4 版：撿貨單「已出倉、萬華實撿 0、沒派車單」那種列放過；第 5 版：放過的列再查會不會叫中和重派；第 6 版：同團同商品的所有採購單都查）　⛔ 審查問題清空之前不要貼 02
--  整份貼進 Supabase SQL Editor → 執行。每一列＝一張訂單，看最右邊「判斷」：
--    ✅ 02 會改這張　　✅ 已經改好了（02 貼過）　　❌ 02 會【停】，截圖給 CEO
--  條件跟 02 的檢查逐條相同（02 任何一張 ❌ 就一張都不改）。
--  「提醒_派貨草稿萬華格」那欄只是提醒、不擋：草稿是樓下手改的快照，02 不會動它。
--   不是 0 ＝ 進行中的派貨草稿上萬華那格還有數字；02 貼完後照 03 那一欄的說明，把萬華那格的數字搬到中和那格。
--  「撿貨單上的萬華列」每一列寫成 撿貨單id(狀態,排X,撿Y,有/沒派車單→放過/擋)：
--   →放過 ＝ 撿貨單已出倉、萬華那列一件都沒撿、也沒開派車單（貨確定沒送去萬華），不擋 02；→擋 ＝ 02 會停。
--  「重派風險_採購單」不是「無」＝ 上面「→放過」的那種列，它的採購單還會再收貨、或總倉實收比已排多，
--   02 改完後派貨工作台可能把這幾件再派一次到中和（貨其實已經在中和）→ 判斷欄 ❌、02 會停。
--   寫成 撿貨單id 命中採購單：採購單號(狀態,總倉實收X,已排Y)。第 6 版起查的是這張撿貨單的來源採購單＋同團同商品的所有採購單。
-- ============================================================================
WITH want(order_no, sku_code, qty) AS (
  VALUES ('GRP-20261007-053-0030', 'G03109-01',  4::numeric),
         ('GRP-20261007-063-0034', 'G03119-01',  1::numeric),
         ('GRP-20261008-018-0038', 'G03131-03',  2::numeric),
         ('GRP-20261011-043-0010', 'G03177-01', 12::numeric)
),
me AS (  -- 用 min()／count() 收成一列：會員編號查到不只 1 位時，下面照樣跑得出來、判斷欄會寫 ❌
  SELECT min(m.id) AS id, min(m.tenant_id::text)::uuid AS tenant_id, min(m.home_store_id) AS home_store_id,
         count(*) AS n
    FROM members m
   WHERE m.member_no = 'M20260810082311747'
),
fam AS (  -- 本人＋合併進來的舊會員編號
  SELECT m.id FROM members m JOIN me ON m.id = me.id OR m.merged_into_member_id = me.id
),
st AS (
  SELECT (SELECT count(*) FROM stores s, me WHERE s.tenant_id = me.tenant_id AND s.name LIKE '%萬華%') AS n_old,
         (SELECT count(*) FROM stores s, me WHERE s.tenant_id = me.tenant_id AND s.name LIKE '%中和%') AS n_new,
         (SELECT min(s.id) FROM stores s, me WHERE s.tenant_id = me.tenant_id AND s.name LIKE '%萬華%') AS old_id,
         (SELECT min(s.id) FROM stores s, me WHERE s.tenant_id = me.tenant_id AND s.name LIKE '%中和%') AS new_id
),
w AS (SELECT DISTINCT order_no FROM want),
o AS (
  SELECT w.order_no AS want_no, co.*
    FROM w
    LEFT JOIN customer_orders co
      ON co.order_no = w.order_no
     AND co.tenant_id = (SELECT tenant_id FROM me)
),
it AS (
  SELECT x.order_id,
         string_agg(s.sku_code || '×' || x.qty::numeric(18,1) || '(' || x.status || ')', '；' ORDER BY x.id) AS items,
         count(*) FILTER (WHERE x.status <> 'pending') AS n_not_pending,
         count(*) AS n_items,
         array_agg(DISTINCT x.sku_id) AS skus,
         -- 品項要跟 CEO 10/31 確認的一模一樣（商品碼×件數）
         (SELECT string_agg(sku_code || '×' || qty::numeric(18,1), '；' ORDER BY sku_code, qty) FROM want
           WHERE want.order_no = (SELECT order_no FROM customer_orders WHERE id = x.order_id))
           = string_agg(s.sku_code || '×' || x.qty::numeric(18,1), '；' ORDER BY s.sku_code, x.qty) AS sig_ok
    FROM customer_order_items x
    JOIN skus s ON s.id = x.sku_id
   WHERE x.order_id IN (SELECT id FROM o WHERE id IS NOT NULL)
   GROUP BY x.order_id
),
xfer AS (  -- 綁在這張單上的派車單，或下單後派往萬華、含同商品的派車單（沒取消的）
  SELECT o.id AS order_id,
         string_agg(DISTINCT t.transfer_no || '(' || t.status || ')', '、') AS list
    FROM o
    JOIN it ON it.order_id = o.id
    JOIN transfers t ON t.tenant_id = o.tenant_id
                    AND t.status <> 'cancelled'
                    AND (t.customer_order_id = o.id
                         OR (t.dest_location = (SELECT location_id FROM stores WHERE id = (SELECT old_id FROM st))
                             AND t.created_at >= o.created_at
                             AND EXISTS (SELECT 1 FROM transfer_items ti
                                          WHERE ti.transfer_id = t.id AND ti.sku_id = ANY (it.skus))))
   GROUP BY o.id
),
wave AS (  -- 總倉撿貨單上，這一團這商品還有萬華那一列（沒取消的撿貨單）
  -- 只放過一種（10/31 第 4 版）：撿貨單已出倉（shipped）、萬華那列實撿 0（不是空白）、而且沒有派車單
  --   ＝這列確定沒有貨送去萬華（派車只對實撿 > 0 的列開單：generate_transfer_from_wave 20260717000000:126 起）。
  --   其他（草稿／撿貨中／已撿完的任何數量、已出倉但有撿到或有派車單、實撿空白）照舊擋。
  --   ⛔ 放過條件跟 02 第 5 步撿貨單那一段逐字相同。
  -- 第 5 版（10/31 第 4 輪審查 P1）：放過的列再加一關「改完後派貨工作台會不會叫中和重派」：
  --   工作台算「已派」用撿貨單上排的 qty（view wave_qty :1016-1027），不是實撿；02 後中和那格會顯示還差（例：3810 需求 4、排 2）。
  --   只要那張撿貨單的採購單這商品「還有貨可以排」，工作台就可能預填、真的再派一次到中和。所以這兩種【停】：
  --   ① 採購單狀態不是 fully_received／closed／cancelled（＝draft／sent／partially_received，還會再收貨＝在途，
  --      view qty_in_transit :1116-1120 只在非 fully_received 時有值；closed／cancelled 工作台本來就不列 :948）；
  --   ② 總倉實收 > 這張採購單這商品已排（view has_stock_left :1133；view 是逐採購品項比，這裡用整張採購單這商品加總比，只會擋得更多）；
  --   查不到採購單（撿貨單沒有來源採購單）也算【停】。⛔ 條件跟 02 第 5 步逐字相同。
  -- 第 6 版（10/31 第 5 輪審查 P1）：不只查來源採購單——同一團同一商品可能連到好幾張採購單（view po_campaigns :956-971），
  --   工作台會跨採購單分配。所以來源採購單＋所有連到「這一團 × 這商品」的採購單，任一張命中 ①② 就【停】；
  --   算不出來（NULL）一律算命中。「重派風險_採購單」那欄列出命中的採購單號(狀態,總倉實收,已排)。
  SELECT o.id AS order_id,
         string_agg('撿貨單' || pw.id::text || '(' || pw.status
                    || ',排' || pwi.qty::numeric(18,1)
                    || ',撿' || COALESCE(pwi.picked_qty::numeric(18,1)::text, '空白')
                    || CASE WHEN pwi.generated_transfer_id IS NOT NULL THEN ',有派車單' ELSE ',沒派車單' END
                    || CASE WHEN COALESCE(pw.status = 'shipped' AND pwi.picked_qty = 0 AND pwi.generated_transfer_id IS NULL, FALSE)
                            THEN '→放過' ELSE '→擋' END
                    || ')', '、' ORDER BY pw.id, pwi.id) AS list,
         count(*) FILTER (WHERE NOT COALESCE(pw.status = 'shipped' AND pwi.picked_qty = 0 AND pwi.generated_transfer_id IS NULL, FALSE)) AS n_block,
         -- 第 5 版：放過的那種列，再看改完後工作台會不會叫中和重派（見下面 chk）
         string_agg('撿貨單' || pw.id::text || ' 命中採購單：'
                    || CASE WHEN COALESCE(chk.n_src, 0) <> 1 THEN '查不到來源採購單 ' ELSE '' END
                    || COALESCE(chk.hit_list, ''), '；' ORDER BY pw.id, pwi.id)
           FILTER (WHERE COALESCE(pw.status = 'shipped' AND pwi.picked_qty = 0 AND pwi.generated_transfer_id IS NULL, FALSE)
                     AND COALESCE(chk.n_src <> 1 OR chk.any_risk, TRUE)) AS redispatch_list
    FROM o
    JOIN it ON it.order_id = o.id
    JOIN picking_wave_items pwi ON pwi.tenant_id = o.tenant_id
                               AND pwi.campaign_id = o.campaign_id
                               AND pwi.store_id = (SELECT old_id FROM st)
                               AND pwi.sku_id = ANY (it.skus)
    JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
    LEFT JOIN LATERAL (  -- 【第 6 版 重派檢查】⛔ 01／02／03 這一段逐字相同（算法照派貨需求表 v_picking_demand_by_po 最新 20261016000000:932）
      -- 要查的採購單＝這張撿貨單的來源採購單＋依 view po_campaigns（:956-971）連到「這一團 × 這商品」的所有採購單
      --   （工作台會跨多張採購單分配，任一張還有貨可排就可能叫中和重派）。
      -- 每張：狀態不是 fully_received／closed／cancelled（＝draft／sent／partially_received，還會再收貨）、
      --   或總倉實收 > 已排、或算不出來（NULL）→ 算命中。
      SELECT count(*) FILTER (WHERE p.id = pw.source_po_id) AS n_src,
             bool_or(p.risky) AS any_risk,
             string_agg(p.po_no || '(' || p.po_status || ',總倉實收' || p.gr_qty::numeric(18,1)
                        || ',已排' || p.already_wave::numeric(18,1) || ')', '、' ORDER BY p.id) FILTER (WHERE p.risky) AS hit_list
        FROM (
          SELECT q.*,
                 COALESCE(q.po_status NOT IN ('fully_received', 'closed', 'cancelled') OR q.gr_qty > q.already_wave, TRUE) AS risky
            FROM (
              SELECT pox.id, pox.po_no, pox.status AS po_status,
                     -- 總倉實收：同 view 的 gr_qty（:949-956，confirmed 收貨單的 qty_received），加總這張採購單這商品
                     (SELECT COALESCE(sum(gri.qty_received), 0)
                        FROM public.goods_receipt_items gri
                        JOIN public.goods_receipts gr ON gr.id = gri.gr_id
                        JOIN public.purchase_order_items poi9 ON poi9.id = gri.po_item_id
                       WHERE gr.status = 'confirmed'
                         AND poi9.po_id = pox.id AND poi9.sku_id = pwi.sku_id) AS gr_qty,
                     -- 已排：同 view 的 po_sku_already_wave（:1051-1071）兩段原文，只取這張採購單這商品
                     (SELECT COALESCE(sum(u.qty), 0)
                        FROM ( SELECT pw.source_po_id AS po_id, pwi.sku_id, pwi.qty
                                 FROM public.picking_wave_items pwi
                                 JOIN public.picking_waves pw ON pw.id = pwi.wave_id
                                WHERE pw.status <> 'cancelled' AND pw.source_po_id IS NOT NULL
                               UNION ALL
                               SELECT poi.po_id, ti.sku_id, ti.qty_requested AS qty
                                 FROM public.restock_requests rr
                                 JOIN public.transfers t ON t.id = rr.linked_transfer_id
                                 JOIN public.transfer_items ti ON ti.transfer_id = t.id
                                 JOIN public.purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                                 JOIN public.purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                                WHERE t.transfer_type = 'hq_to_store' AND t.status <> 'cancelled') u
                       WHERE u.po_id = pox.id AND u.sku_id = pwi.sku_id) AS already_wave
                FROM public.purchase_orders pox
               WHERE pox.id = pw.source_po_id
                  OR pox.id IN (
                       SELECT poi8.po_id
                         FROM ( -- view po_campaigns（:957-971）原文
                                SELECT DISTINCT u.po_item_id, u.campaign_id
                                  FROM ( SELECT poi.id AS po_item_id, prc.campaign_id
                                           FROM public.purchase_order_items poi
                                           JOIN public.purchase_request_items pri ON pri.po_item_id = poi.id
                                           JOIN public.purchase_requests pr ON pr.id = pri.pr_id
                                           JOIN public.purchase_request_campaigns prc ON prc.pr_id = pr.id
                                         UNION
                                         SELECT poi.id AS po_item_id, pri.source_campaign_id AS campaign_id
                                           FROM public.purchase_order_items poi
                                           JOIN public.purchase_request_items pri ON pri.po_item_id = poi.id
                                          WHERE pri.source_campaign_id IS NOT NULL) u ) pc
                         JOIN public.purchase_order_items poi8 ON poi8.id = pc.po_item_id
                        WHERE pc.campaign_id = pwi.campaign_id AND poi8.sku_id = pwi.sku_id)
            ) q
        ) p
    ) chk ON TRUE
   GROUP BY o.id
),
draft AS (  -- 只提醒：進行中的派貨草稿，萬華那格同商品還有數字
  SELECT o.id AS order_id, count(*) AS n
    FROM o
    JOIN it ON it.order_id = o.id
    JOIN picking_draft_items di ON di.tenant_id = o.tenant_id
                               AND di.store_id = (SELECT old_id FROM st)
                               AND di.sku_id = ANY (it.skus)
                               AND di.qty > 0
    JOIN picking_drafts d ON d.id = di.draft_id AND d.status = 'draft'
   GROUP BY o.id
)
SELECT o.want_no                                            AS 訂單號,
       g.campaign_no                                        AS 團號,
       g.status                                             AS 團狀態,
       o.status                                             AS 訂單狀態,
       ps.name                                              AS 現在取貨店,
       hs.name                                              AS 會員綁定店,
       it.items                                             AS 品項_數量_狀態,
       COALESCE(xfer.list, '無')                            AS 派車單,
       COALESCE(wave.list, '無')                            AS 撿貨單上的萬華列,
       COALESCE(wave.redispatch_list, '無')                 AS 重派風險_採購單,
       COALESCE(draft.n, 0)                                 AS 提醒_派貨草稿萬華格,
       st.n_old                                             AS 萬華找到幾家,
       st.n_new                                             AS 中和找到幾家,
       CASE
         WHEN (SELECT n FROM me) <> 1                                THEN '❌ 會員編號查到的不是剛好 1 位'
         WHEN st.n_old <> 1 OR st.n_new <> 1                         THEN '❌ 萬華或中和店名查到的不是剛好 1 家'
         WHEN NOT EXISTS (SELECT 1 FROM stores WHERE id = st.new_id AND is_active) THEN '❌ 中和店不是啟用中'
         WHEN (SELECT home_store_id FROM me) IS DISTINCT FROM st.new_id THEN '❌ 會員綁定店不是中和'
         WHEN o.id IS NULL                                           THEN '❌ 找不到這張訂單'
         WHEN o.member_id IS NULL OR o.member_id NOT IN (SELECT id FROM fam) THEN '❌ 這張單不是這位會員的'
         WHEN o.pickup_store_id = st.new_id
              AND substring(coalesce(o.notes, '') FROM '[^\n]*$')        -- 備註最後一行就是 02 那一行
                  ~ ('^\[改取貨店\] 門市 #' || st.old_id || ' → #' || st.new_id
                     || '（\d{4}-\d{2}-\d{2} \d{2}:\d{2}）萬華店停業，2026-10-31 老闆核准改中和取貨$')
                                                                     THEN '✅ 已經改好了（02 貼過）'
         WHEN o.status NOT IN ('pending', 'confirmed')               THEN '❌ 訂單狀態不是待確認／已確認'
         WHEN o.pickup_store_id IS DISTINCT FROM st.old_id           THEN '❌ 取貨店已經不是萬華'
         WHEN COALESCE(o.order_kind, 'normal') <> 'normal'           THEN '❌ 不是一般團購單'
         WHEN g.owner_store_id IS NOT NULL                           THEN '❌ 門市團'
         WHEN o.transferred_from_order_id IS NOT NULL                THEN '❌ 是別張單轉來的'
         WHEN o.is_air_transfer OR o.aid_board_id IS NOT NULL        THEN '❌ 空中轉／互助單'
         WHEN it.order_id IS NULL OR it.n_not_pending > 0            THEN '❌ 品項不是全部「等貨中」'
         WHEN it.sig_ok IS NOT TRUE                                  THEN '❌ 品項跟 10/31 確認的不一樣'
         WHEN xfer.list IS NOT NULL                                  THEN '❌ 有派車單'
         WHEN wave.n_block > 0                                       THEN '❌ 總倉撿貨單上已經排了萬華'
         WHEN wave.redispatch_list IS NOT NULL                       THEN '❌ 改完工作台可能叫中和重派（採購單還會再收貨、或總倉實收比已排多）：' || wave.redispatch_list
         ELSE '✅ 02 會改這張'
       END                                                  AS 判斷
  FROM o
  CROSS JOIN st
  LEFT JOIN group_buy_campaigns g ON g.id = o.campaign_id
  LEFT JOIN stores ps ON ps.id = o.pickup_store_id
  LEFT JOIN stores hs ON hs.id = (SELECT home_store_id FROM me)
  LEFT JOIN it    ON it.order_id = o.id
  LEFT JOIN xfer  ON xfer.order_id = o.id
  LEFT JOIN wave  ON wave.order_id = o.id
  LEFT JOIN draft ON draft.order_id = o.id
 ORDER BY o.want_no;

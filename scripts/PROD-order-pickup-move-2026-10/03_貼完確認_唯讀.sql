-- ============================================================================
--  03 貼完確認（只看不改）：02 貼完之後，確認 4 張都已經改到中和取貨
--  日期：2026-10-31（第 4 版：多一欄「已出倉_中和多撿」，只提醒；第 5 版：多一欄「重派風險_採購單」，只提醒；第 6 版：同團同商品的所有採購單都查）
--  整份貼進 Supabase SQL Editor → 執行。每一列＝一張訂單，看最右邊「判斷」要 4 列都是 ✅。
--  「萬華_剩下需求」「中和_需求」＝派貨需求表（v_picking_demand_by_po 最新 20261016000000:976-986）
--   同一個算法、只算這一團這商品：取貨店在哪就算哪一家（單頭不是取消／過期／轉出，品項不是取消／過期）。
--   改好之後：這 4 張的件數算在「中和_需求」裡；「萬華_剩下需求」是萬華店其他客人還掛著的件數（預期 0）。
--  「派貨草稿_要搬的格子」不是「無」＝ 樓下進行中的派貨草稿上，這個商品萬華那格還有數字（這份不改它）：
--   照那一欄寫的做 —— 萬華那格的數字整個搬到中和那格（萬華改 0、中和加上同樣件數）。
--   「派貨草稿_應補到中和件數」＝那張草稿上萬華格的數字加總（就是中和那格要加的數）；
--   「本單件數」是這張單的件數，用來對照（草稿是按商品、不分團，萬華格可能比本單多或少）。
--  「已出倉_中和多撿」不是「無」＝ 這一團這商品，已出倉的撿貨單上中和那列實撿比排的多、萬華那列沒撿（第 4 版加，只提醒）：
--   ＝總倉當時已經把萬華那幾件改送到中和了（例：撿貨單 3810）。這張單的貨已經在中和，⛔ 不要再派一次。
--   ⚠ 派貨工作台算「已派」用的是排的數量、不是實撿數量，改完後中和那格可能顯示還差幾件——那是帳面，貨已經到了。
--   02 已先擋：那張撿貨單的來源採購單、或同團同商品的任一張採購單，還會再收貨或總倉實收比已排多，02 就不會改（工作台沒有貨可以再派）。
--  「重派風險_採購單」不是「無」＝ 02 貼完之後才變的：上面那些採購單有一張又被補登收貨、或狀態又變成還會收貨（第 5 版加、第 6 版查全部採購單，只提醒）：
--   這時派貨工作台可能預填中和要再派這幾件 ⇒ ⛔ 派貨時中和那格這商品改 0，截圖給 CEO。
-- ============================================================================
WITH want(order_no) AS (
  VALUES ('GRP-20261007-053-0030'), ('GRP-20261007-063-0034'),
         ('GRP-20261008-018-0038'), ('GRP-20261011-043-0010')
),
me AS (
  SELECT min(m.id) AS id, min(m.tenant_id::text)::uuid AS tenant_id FROM members m WHERE m.member_no = 'M20260810082311747'
),
st AS (
  SELECT (SELECT min(s.id) FROM stores s, me WHERE s.tenant_id = me.tenant_id AND s.name LIKE '%萬華%') AS old_id,
         (SELECT min(s.id) FROM stores s, me WHERE s.tenant_id = me.tenant_id AND s.name LIKE '%中和%') AS new_id
),
o AS (
  SELECT want.order_no AS want_no, co.*
    FROM want
    LEFT JOIN customer_orders co ON co.order_no = want.order_no AND co.tenant_id = (SELECT tenant_id FROM me)
),
it AS (
  SELECT x.order_id,
         string_agg(s.sku_code || '×' || x.qty::numeric(18,1) || '(' || x.status || ')', '；' ORDER BY x.id) AS items,
         array_agg(DISTINCT x.sku_id) AS skus
    FROM customer_order_items x JOIN skus s ON s.id = x.sku_id
   WHERE x.order_id IN (SELECT id FROM o WHERE id IS NOT NULL)
   GROUP BY x.order_id
),
dem AS (  -- 同派貨需求表 campaign_demand 的條件，只算這一團這商品、萬華與中和
  SELECT o.id AS order_id,
         sum(coi.qty) FILTER (WHERE c2.pickup_store_id = (SELECT old_id FROM st)) AS old_qty,
         sum(coi.qty) FILTER (WHERE c2.pickup_store_id = (SELECT new_id FROM st)) AS new_qty
    FROM o
    JOIN it ON it.order_id = o.id
    JOIN customer_orders c2 ON c2.campaign_id = o.campaign_id
                           AND c2.status NOT IN ('cancelled', 'expired', 'transferred_out')
                           AND (c2.transferred_from_order_id IS NULL
                                OR EXISTS (SELECT 1 FROM customer_orders src
                                            WHERE src.id = c2.transferred_from_order_id
                                              AND src.pickup_store_id = c2.pickup_store_id))
    JOIN customer_order_items coi ON coi.order_id = c2.id
                                 AND coi.status NOT IN ('cancelled', 'expired')
                                 AND coi.sku_id = ANY (it.skus)
   GROUP BY o.id
),
draft AS (  -- 進行中的派貨草稿：這個商品萬華那格還有數字的，列出要怎麼搬
  SELECT o.id AS order_id,
         sum(w.qty) AS move_qty,
         string_agg('草稿#' || d.id || '「' || d.name || '」：萬華格 ' || w.qty::numeric(18,1) || ' 改成 0；中和格 '
                    || COALESCE(z.qty, 0)::numeric(18,1) || ' 改成 ' || (COALESCE(z.qty, 0) + w.qty)::numeric(18,1),
                    '；' ORDER BY d.id) AS todo
    FROM o
    JOIN it ON it.order_id = o.id
    JOIN picking_draft_items w ON w.tenant_id = o.tenant_id AND w.store_id = (SELECT old_id FROM st)
                              AND w.sku_id = ANY (it.skus) AND w.qty > 0
    JOIN picking_drafts d ON d.id = w.draft_id AND d.status = 'draft'
    LEFT JOIN picking_draft_items z ON z.draft_id = w.draft_id AND z.sku_id = w.sku_id
                                   AND z.store_id = (SELECT new_id FROM st)
   GROUP BY o.id
),
sent AS (  -- 只提醒：已出倉撿貨單上，中和那列實撿 > 排、而且同一張撿貨單萬華那列實撿 0、沒派車單
  SELECT o.id AS order_id,
         string_agg('撿貨單' || pw.id::text || '：中和 排' || z.qty::numeric(18,1) || ' 撿' || z.picked_qty::numeric(18,1)
                    || '；萬華 排' || w.qty::numeric(18,1) || ' 撿0', '、' ORDER BY pw.id, z.id) AS list
    FROM o
    JOIN it ON it.order_id = o.id
    JOIN picking_wave_items z ON z.tenant_id = o.tenant_id AND z.campaign_id = o.campaign_id
                             AND z.store_id = (SELECT new_id FROM st) AND z.sku_id = ANY (it.skus)
                             AND z.picked_qty > z.qty
    JOIN picking_waves pw ON pw.id = z.wave_id AND pw.status = 'shipped'
    JOIN picking_wave_items w ON w.wave_id = z.wave_id AND w.sku_id = z.sku_id AND w.campaign_id = z.campaign_id
                             AND w.store_id = (SELECT old_id FROM st)
                             AND w.picked_qty = 0 AND w.generated_transfer_id IS NULL
   GROUP BY o.id
),
redis AS (  -- 只提醒：同 01／02 第 6 版重派檢查（chk 那一段逐字相同），02 貼完後採購單又變得「還有貨可以排」
  SELECT o.id AS order_id,
         string_agg('撿貨單' || pw.id::text || ' 命中採購單：'
                    || CASE WHEN COALESCE(chk.n_src, 0) <> 1 THEN '查不到來源採購單 ' ELSE '' END
                    || COALESCE(chk.hit_list, ''), '；' ORDER BY pw.id, pwi.id) AS list
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
   WHERE COALESCE(pw.status = 'shipped' AND pwi.picked_qty = 0 AND pwi.generated_transfer_id IS NULL, FALSE)
     AND COALESCE(chk.n_src <> 1 OR chk.any_risk, TRUE)
   GROUP BY o.id
),
lastline AS (  -- 備註最後一行是不是 02 那一行
  SELECT o.id AS order_id,
         substring(COALESCE(o.notes, '') FROM '[^\n]*$')
           ~ ('^\[改取貨店\] 門市 #' || (SELECT old_id FROM st) || ' → #' || (SELECT new_id FROM st)
              || '（\d{4}-\d{2}-\d{2} \d{2}:\d{2}）萬華店停業，2026-10-31 老闆核准改中和取貨$') AS ok
    FROM o WHERE o.id IS NOT NULL
)
SELECT o.want_no                                              AS 訂單號,
       ps.name                                                AS 現在取貨店,
       o.status                                               AS 訂單狀態,
       it.items                                               AS 品項_數量_狀態,
       COALESCE(lastline.ok, FALSE)                               AS 備註最後一行是本次那行,
       o.updated_at                                           AS 最後修改時間,
       COALESCE(dem.old_qty, 0)                               AS 萬華_剩下需求,
       COALESCE(dem.new_qty, 0)                               AS 中和_需求,
       (SELECT sum(x.qty) FROM customer_order_items x WHERE x.order_id = o.id) AS 本單件數,
       COALESCE(draft.move_qty, 0)                            AS 派貨草稿_應補到中和件數,
       COALESCE(draft.todo, '無')                             AS 派貨草稿_要搬的格子,
       COALESCE(sent.list, '無')                              AS 已出倉_中和多撿,
       COALESCE(redis.list, '無')                             AS 重派風險_採購單,
       CASE
         WHEN o.id IS NULL                                      THEN '❌ 找不到這張訂單'
         WHEN o.pickup_store_id IS DISTINCT FROM (SELECT new_id FROM st) THEN '❌ 取貨店不是中和'
         WHEN NOT COALESCE(lastline.ok, FALSE)                      THEN '❌ 備註最後一行不是 02 那一行'
         WHEN o.status NOT IN ('pending', 'confirmed')          THEN '⚠️ 已改到中和，但訂單狀態變了：' || o.status
         ELSE '✅ 已改到中和取貨'
       END                                                    AS 判斷
  FROM o
  LEFT JOIN stores ps ON ps.id = o.pickup_store_id
  LEFT JOIN it    ON it.order_id = o.id
  LEFT JOIN dem   ON dem.order_id = o.id
  LEFT JOIN draft ON draft.order_id = o.id
  LEFT JOIN sent  ON sent.order_id = o.id
  LEFT JOIN redis ON redis.order_id = o.id
  LEFT JOIN lastline ON lastline.order_id = o.id
 ORDER BY o.want_no;

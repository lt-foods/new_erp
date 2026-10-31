-- ============================================================================
--  01 預覽（只看不改）：客人 4 張還沒取的訂單，取貨店 萬華 → 中和，貼 02 之前先看
--  日期：2026-10-31　阿寫寫　⛔ 阿審（Codex）審過之前不要貼 02
--  整份貼進 Supabase SQL Editor → 執行。每一列＝一張訂單，看最右邊「判斷」：
--    ✅ 02 會改這張　　✅ 已經改好了（02 貼過）　　❌ 02 會【停】，截圖給 CEO
--  條件跟 02 的檢查逐條相同（02 任何一張 ❌ 就一張都不改）。
--  「提醒_派貨草稿」那欄只是提醒、不擋：草稿是樓下手改的快照，萬華那格有數字要自己改成 0。
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
  SELECT o.id AS order_id,
         string_agg(DISTINCT pw.id::text || '(' || pw.status || ')', '、') AS list
    FROM o
    JOIN it ON it.order_id = o.id
    JOIN picking_wave_items pwi ON pwi.tenant_id = o.tenant_id
                               AND pwi.campaign_id = o.campaign_id
                               AND pwi.store_id = (SELECT old_id FROM st)
                               AND pwi.sku_id = ANY (it.skus)
    JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
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
              AND o.notes LIKE '%萬華店停業，2026-10-31 老闆核准改中和取貨%' THEN '✅ 已經改好了（02 貼過）'
         WHEN o.status NOT IN ('pending', 'confirmed')               THEN '❌ 訂單狀態不是待確認／已確認'
         WHEN o.pickup_store_id IS DISTINCT FROM st.old_id           THEN '❌ 取貨店已經不是萬華'
         WHEN COALESCE(o.order_kind, 'normal') <> 'normal'           THEN '❌ 不是一般團購單'
         WHEN g.owner_store_id IS NOT NULL                           THEN '❌ 門市團'
         WHEN o.transferred_from_order_id IS NOT NULL                THEN '❌ 是別張單轉來的'
         WHEN o.is_air_transfer OR o.aid_board_id IS NOT NULL        THEN '❌ 空中轉／互助單'
         WHEN it.order_id IS NULL OR it.n_not_pending > 0            THEN '❌ 品項不是全部「等貨中」'
         WHEN it.sig_ok IS NOT TRUE                                  THEN '❌ 品項跟 10/31 確認的不一樣'
         WHEN xfer.list IS NOT NULL                                  THEN '❌ 有派車單'
         WHEN wave.list IS NOT NULL                                  THEN '❌ 總倉撿貨單上已經排了萬華'
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

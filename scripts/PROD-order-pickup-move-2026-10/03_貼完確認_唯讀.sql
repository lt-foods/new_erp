-- ============================================================================
--  03 貼完確認（只看不改）：02 貼完之後，確認 4 張都已經改到中和取貨
--  日期：2026-10-31　阿寫寫
--  整份貼進 Supabase SQL Editor → 執行。每一列＝一張訂單，看最右邊「判斷」要 4 列都是 ✅。
--  「萬華_剩下需求」「中和_需求」＝派貨需求表（v_picking_demand_by_po 最新 20261016000000:976-986）
--   同一個算法、只算這一團這商品：取貨店在哪就算哪一家（單頭不是取消／過期／轉出，品項不是取消／過期）。
--   改好之後：這 4 張的件數算在「中和_需求」裡；「萬華_剩下需求」是萬華店其他客人還掛著的件數（預期 0）。
--  「提醒_派貨草稿萬華格」不是 0 ＝ 樓下進行中的派貨草稿上萬華那格還有數字，記得改成 0（這份不改它）。
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
draft AS (
  SELECT o.id AS order_id, count(*) AS n
    FROM o
    JOIN it ON it.order_id = o.id
    JOIN picking_draft_items di ON di.tenant_id = o.tenant_id AND di.store_id = (SELECT old_id FROM st)
                               AND di.sku_id = ANY (it.skus) AND di.qty > 0
    JOIN picking_drafts d ON d.id = di.draft_id AND d.status = 'draft'
   GROUP BY o.id
)
SELECT o.want_no                                              AS 訂單號,
       ps.name                                                AS 現在取貨店,
       o.status                                               AS 訂單狀態,
       it.items                                               AS 品項_數量_狀態,
       (position('萬華店停業，2026-10-31 老闆核准改中和取貨' IN coalesce(o.notes, '')) > 0) AS 備註有本次那句,
       o.updated_at                                           AS 最後修改時間,
       COALESCE(dem.old_qty, 0)                               AS 萬華_剩下需求,
       COALESCE(dem.new_qty, 0)                               AS 中和_需求,
       COALESCE(draft.n, 0)                                   AS 提醒_派貨草稿萬華格,
       CASE
         WHEN o.id IS NULL                                      THEN '❌ 找不到這張訂單'
         WHEN o.pickup_store_id IS DISTINCT FROM (SELECT new_id FROM st) THEN '❌ 取貨店不是中和'
         WHEN position('萬華店停業，2026-10-31 老闆核准改中和取貨' IN coalesce(o.notes, '')) = 0 THEN '❌ 備註沒有本次那一句'
         WHEN o.status NOT IN ('pending', 'confirmed')          THEN '⚠️ 已改到中和，但訂單狀態變了：' || o.status
         ELSE '✅ 已改到中和取貨'
       END                                                    AS 判斷
  FROM o
  LEFT JOIN stores ps ON ps.id = o.pickup_store_id
  LEFT JOIN it    ON it.order_id = o.id
  LEFT JOIN dem   ON dem.order_id = o.id
  LEFT JOIN draft ON draft.order_id = o.id
 ORDER BY o.want_no;

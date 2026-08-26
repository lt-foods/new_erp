-- ============================================================
-- 2026-08-26 (1)：少發配貨可在收貨前直接配 —— 在途量算進可配額度
--
-- Alex：收貨頁對「已出貨還沒收」的派貨單就會出「⚖️ 配貨」鈕（short 用
-- shipped 對 demand 算），但視窗的可配額度只算已收貨實收量 → 到貨 0 /
-- 可配 0，什麼都不能做，只能先去收貨再回來。實際上配貨的儲存
-- （rpc_allocate_shortage）只是標記誰待補（backorder_at），不動庫存也
-- 不放行取貨 —— 取貨閘門自己有 campaign-local ＋實體庫存兩道數量守衛，
-- 所以收貨前先配（＝預先決定誰先拿、誰待補）在帳上是安全的：
--   - 待補的那幾件收貨時 _settle_arrived_backorders 只會在量真的夠時解除；
--   - 實收比派出少時，超過實收的部分閘門照樣擋，收貨頁會再亮短少，
--     店家回這個視窗把數字改小即可。
--
-- 改法：rpc_get_allocation_candidates 加 in_transit（同 (團,店,SKU) 已出貨
-- 未收貨的 qty_shipped 合計，status='shipped'；draft 未派出、cancelled 不算），
-- available 加上它，並回傳給前端顯示「＋在途 N」。
--
-- 基底：rpc_get_allocation_candidates ← 20260824040000（已重新 grep，
-- 之後無其他修改；線上版本 2026-08-26 比對過與該版一致）。
-- Rollback：重跑 20260824040000 的 A 段。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_get_allocation_candidates(p_transfer_id bigint, p_sku_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  WITH ctx AS (
    SELECT pwi.tenant_id, pwi.campaign_id, pwi.store_id, pwi.sku_id
      FROM picking_wave_items pwi
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND pwi.sku_id = p_sku_id
       AND pwi.campaign_id IS NOT NULL
     LIMIT 1
  ),
  supplied AS (
    -- 同一個 (團,店,品項) 可能分好幾批到，全部已收的實收量都算進可配額度
    SELECT COALESCE(SUM(ti.qty_received), 0) AS qty
      FROM ctx
      JOIN picking_wave_items pwi
        ON pwi.tenant_id = ctx.tenant_id AND pwi.campaign_id = ctx.campaign_id
       AND pwi.store_id  = ctx.store_id  AND pwi.sku_id      = ctx.sku_id
      JOIN transfers t      ON t.id = pwi.generated_transfer_id
                           AND t.status IN ('received', 'closed')
      JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = ctx.sku_id
  ),
  -- 20260826010000：已出貨、還沒收貨的在途量 —— 收貨前就能先配貨
  --（預先決定誰先拿、誰待補）。只算 shipped：draft 還沒派出、
  -- received/closed 已計入 supplied、cancelled 不算。
  in_transit AS (
    SELECT COALESCE(SUM(ti.qty_shipped), 0) AS qty
      FROM ctx
      JOIN picking_wave_items pwi
        ON pwi.tenant_id = ctx.tenant_id AND pwi.campaign_id = ctx.campaign_id
       AND pwi.store_id  = ctx.store_id  AND pwi.sku_id      = ctx.sku_id
      JOIN transfers t      ON t.id = pwi.generated_transfer_id
                           AND t.status = 'shipped'
      JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = ctx.sku_id
  ),
  note_cov AS (
    SELECT COALESCE(SUM(n.qty), 0) AS qty
      FROM ctx
      JOIN inventory_deduction_notes n
        ON n.tenant_id = ctx.tenant_id AND n.campaign_id = ctx.campaign_id
       AND n.store_id  = ctx.store_id  AND n.sku_id      = ctx.sku_id
     WHERE n.cancelled_at IS NULL
  ),
  offset_cov AS (
    SELECT COALESCE(SUM(-oi.qty), 0) AS qty
      FROM ctx
      JOIN customer_orders oo
        ON oo.tenant_id       = ctx.tenant_id
       AND oo.campaign_id     = ctx.campaign_id
       AND oo.pickup_store_id = ctx.store_id
       AND oo.order_kind      = 'offset'
       AND oo.status NOT IN ('cancelled', 'expired', 'transferred_out')
      JOIN customer_order_items oi
        ON oi.order_id = oo.id
       AND oi.sku_id   = ctx.sku_id
       AND oi.qty < 0
       AND oi.status NOT IN ('cancelled', 'expired')
  ),
  rows_all AS (
    SELECT coi.id            AS item_id,
           co.id             AS order_id,
           co.order_no,
           COALESCE(m.name, co.nickname_snapshot) AS customer,
           co.status         AS order_status,
           coi.status        AS item_status,
           coi.qty,
           coi.backorder_at,
           co.created_at,
           COALESCE(sm.created_at, coi.updated_at) AS picked_at
      FROM ctx
      JOIN customer_orders co
        ON co.tenant_id        = ctx.tenant_id
       AND co.campaign_id      = ctx.campaign_id
       AND co.pickup_store_id  = ctx.store_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND (co.transferred_from_order_id IS NULL OR EXISTS (
             SELECT 1 FROM customer_orders src
              WHERE src.id = co.transferred_from_order_id
                AND src.pickup_store_id = co.pickup_store_id))
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.sku_id   = ctx.sku_id
       AND coi.status NOT IN ('cancelled', 'expired')
      LEFT JOIN members m ON m.id = co.member_id
      LEFT JOIN stock_movements sm ON sm.id = coi.pickup_movement_id
  ),
  picked AS (
    SELECT COALESCE(SUM(r.qty), 0) AS qty FROM rows_all r
     WHERE r.item_status IN ('picked_up', 'partially_picked_up')
  ),
  -- 20260824040000：已可取貨（閘門放行）的未取列 —— 貨已經是他們的，
  -- 不再列入配貨候選（Alex：「剛配到的不用再出現」），但佔掉的量要從
  -- 可配額度扣掉，否則畫面數字會自相矛盾（已配 > 可配）。
  allocated AS (
    SELECT COALESCE(SUM(r.qty), 0) AS qty FROM rows_all r
     WHERE r.item_status IN ('pending', 'reserved', 'ready')
       AND public.is_order_item_pickup_ready(r.item_id)
  )
  SELECT jsonb_build_object(
    'store_id',    (SELECT store_id FROM ctx),
    'campaign_id', (SELECT campaign_id FROM ctx),
    'supplied',   (SELECT qty FROM supplied),
    'in_transit', (SELECT qty FROM in_transit),
    'covered',    (SELECT qty FROM note_cov) + (SELECT qty FROM offset_cov),
    'picked',     (SELECT qty FROM picked),
    'available', GREATEST((SELECT qty FROM supplied) + (SELECT qty FROM in_transit)
                          + (SELECT qty FROM note_cov)
                          + (SELECT qty FROM offset_cov) - (SELECT qty FROM picked)
                          - (SELECT qty FROM allocated), 0),
    'allocated', (SELECT qty FROM allocated),
    -- 店倉帳上可用現貨（開減抵單前的參考與前端預檢；伺服端還會再檢查一次）
    'store_on_hand', COALESCE((
      SELECT sb.on_hand - sb.reserved
        FROM ctx
        JOIN stores st ON st.id = ctx.store_id
        JOIN stock_balances sb
          ON sb.tenant_id = ctx.tenant_id
         AND sb.location_id = st.location_id
         AND sb.sku_id = ctx.sku_id
    ), 0),
    'notes', COALESCE((
      SELECT jsonb_agg(u.e ORDER BY u.kind_ord, u.oid)
        FROM (
          SELECT 1 AS kind_ord, n.id AS oid,
                 jsonb_build_object('id', n.id, 'note_no', n.note_no, 'qty', n.qty,
                                    'reason', n.reason, 'created_at', n.created_at,
                                    'kind', 'note') AS e
            FROM ctx
            JOIN inventory_deduction_notes n
              ON n.tenant_id = ctx.tenant_id AND n.campaign_id = ctx.campaign_id
             AND n.store_id  = ctx.store_id  AND n.sku_id      = ctx.sku_id
           WHERE n.cancelled_at IS NULL
          UNION ALL
          SELECT 2, oo.id,
                 jsonb_build_object('id', oo.id, 'note_no', oo.order_no,
                                    'qty', SUM(-oi.qty), 'reason', oo.notes,
                                    'created_at', oo.created_at, 'kind', 'offset')
            FROM ctx
            JOIN customer_orders oo
              ON oo.tenant_id       = ctx.tenant_id
             AND oo.campaign_id     = ctx.campaign_id
             AND oo.pickup_store_id = ctx.store_id
             AND oo.order_kind      = 'offset'
             AND oo.status NOT IN ('cancelled', 'expired', 'transferred_out')
            JOIN customer_order_items oi
              ON oi.order_id = oo.id
             AND oi.sku_id   = ctx.sku_id
             AND oi.qty < 0
             AND oi.status NOT IN ('cancelled', 'expired')
           GROUP BY oo.id, oo.order_no, oo.notes, oo.created_at
        ) u
    ), '[]'::jsonb),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'item_id',      r.item_id,
               'order_id',     r.order_id,
               'order_no',     r.order_no,
               'customer',     r.customer,
               'order_status', r.order_status,
               'qty',          r.qty,
               'backorder',    r.backorder_at IS NOT NULL,
               'created_at',   r.created_at
             ) ORDER BY r.created_at, r.order_no)
        FROM rows_all r
       WHERE r.item_status IN ('pending', 'reserved', 'ready')
         AND NOT public.is_order_item_pickup_ready(r.item_id)
    ), '[]'::jsonb),
    -- 已領走的行：對帳用，前端唯讀顯示，不參與配貨
    'picked_items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'item_id',      r.item_id,
               'order_id',     r.order_id,
               'order_no',     r.order_no,
               'customer',     r.customer,
               'order_status', r.order_status,
               'item_status',  r.item_status,
               'qty',          r.qty,
               'picked_at',    r.picked_at,
               'created_at',   r.created_at
             ) ORDER BY r.picked_at, r.order_no)
        FROM rows_all r
       WHERE r.item_status IN ('picked_up', 'partially_picked_up')
    ), '[]'::jsonb)
  );
$function$;

-- ============================================================
-- rpc_get_allocation_candidates：合併兩條平行改動
--
-- 20260805000160（#624）加了 picked_items（已領走的品項行，唯讀對帳）；
-- 20260805000170/180（#625 分支）加了 coverage（庫存減抵單＋抵減單）、
-- notes / store_on_hand / store_id / campaign_id。兩邊都以 20260805000060
-- 為基底、互相不知道對方 —— 部署順序是 160 先、170/180 後，
-- 所以線上現行版本「沒有 picked_items」，#624 的已領走清單目前是空的。
-- 本檔把兩邊欄位全部收齊。
--
-- 基底版本：20260805000180（coverage 版）＋ 20260805000160 的
--   picked_at / picked_items 逐字併入 rows_all 與輸出。
-- rollback: 重跑 20260805000180 的 rpc_get_allocation_candidates。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_get_allocation_candidates(
  p_transfer_id BIGINT,
  p_sku_id      BIGINT
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
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
       AND co.transferred_from_order_id IS NULL
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
  )
  SELECT jsonb_build_object(
    'store_id',    (SELECT store_id FROM ctx),
    'campaign_id', (SELECT campaign_id FROM ctx),
    'supplied',  (SELECT qty FROM supplied),
    'covered',   (SELECT qty FROM note_cov) + (SELECT qty FROM offset_cov),
    'picked',    (SELECT qty FROM picked),
    'available', GREATEST((SELECT qty FROM supplied) + (SELECT qty FROM note_cov)
                          + (SELECT qty FROM offset_cov) - (SELECT qty FROM picked), 0),
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
$$;

COMMENT ON FUNCTION public.rpc_get_allocation_candidates(BIGINT, BIGINT) IS
  '少發配貨候選：supplied/covered/picked/available + items（未取，可配）'
  '+ picked_items（已領走，唯讀對帳）+ notes（庫存減抵單/抵減單）+ store_on_hand + ctx。'
  '20260805000190 = 20260805000160 的 picked_items ∪ 20260805000180 的 coverage。';

-- ============================================================
-- 少發配貨視窗補列「已領走」的訂單
--
-- 動機：店家開「少發配貨」看到 到貨 10（已領走 8）卻只列 2 張訂單，
--   會以為漏單。其實已領走的訂單本來就不列（貨拿不回來、沒東西可配），
--   但只給一個總數對不了帳 —— 店家想知道那 8 件是「誰」領走的，
--   才能跟還沒拿到貨的客人解釋。
--
-- 做法：rpc_get_allocation_candidates 多回一個 picked_items 陣列
--   （item_status IN ('picked_up','partially_picked_up') 的品項行），
--   前端灰色唯讀顯示。原本的 supplied / picked / available / items
--   完全不動，配貨邏輯零改變。
--   領走時間取 pickup_movement（stock_movements.created_at），
--   沒有 movement 的舊資料退用品項 updated_at。
--
-- 基底版本：20260805000060_shortage_allocation 的 rpc_get_allocation_candidates
--   （唯一版本，20260805000070 / 20260805000100 皆未動這支）
-- rollback: 重跑 20260805000060 的 rpc_get_allocation_candidates。
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
    'supplied',  (SELECT qty FROM supplied),
    'picked',    (SELECT qty FROM picked),
    'available', GREATEST((SELECT qty FROM supplied) - (SELECT qty FROM picked), 0),
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
  '少發配貨候選：supplied/picked/available + items（未取，可配）+ picked_items（已領走，唯讀對帳用）。'
  '20260805000160 加 picked_items；配貨邏輯與 20260805000060 相同。';

-- ============================================================
-- 少發配貨（待補貨）
--
-- 動機：2026-08-05 松山店 / 永和店的阿猴鮮奶各派 10 瓶、訂單 11 瓶，7 筆訂單
--   卻全部顯示「可取貨」——因為 is_order_item_pickup_ready 的 Path B 是布林
--   EXISTS（該店該團該品項有收到貨 > 0 就全部放行），從不比較「到的量夠不夠分」。
--   先到的人領走，最後一位上門才發現沒貨。線上已收貨的單裡有 70 組（店 × 團 ×
--   品項）訂單量 > 到貨量，共缺 190 件、牽涉 267 筆未取訂單。
--
-- 做法：不新增分配表，只標記「沒配到的那些」。
--   customer_order_items.backorder_at 有值 = 待補貨，取貨閘門就擋下來。
--   沒有缺貨的單這欄永遠是 NULL → 現有行為完全不變，風險只落在真的缺貨的組合。
--   閘門一改，rpc_record_pickup 的品項擋板（呼叫同一支函式，見 20260801000000:745）
--   也跟著生效，伺服端擋得住，不只是畫面上不給點。
--
-- 排序基準：co.created_at, co.order_no。ordered_at 全庫都是 NULL（22522/22522），
--   created_at 又大量重複（近 30 天 22522 筆只有 8612 個相異值，開團是整批匯入的），
--   單靠時間排不出先後；order_no 末碼是團內流水號，拿來當同分決勝可還原批次內順序。
--
-- 基底版本：
--   is_order_item_pickup_ready = 20260704000000（唯一版本，已與線上 pg_get_functiondef 比對一致）
-- rollback:
--   重跑 20260704000000 的 CREATE OR REPLACE；
--   DROP FUNCTION IF EXISTS public.rpc_allocate_shortage(bigint,bigint,bigint[],uuid);
--   DROP FUNCTION IF EXISTS public.rpc_get_allocation_candidates(bigint,bigint);
--   DROP FUNCTION IF EXISTS public.rpc_cancel_backorder_items(bigint[],uuid,text);
--   ALTER TABLE customer_order_items DROP COLUMN IF EXISTS backorder_at, DROP COLUMN IF EXISTS backorder_by;
-- ============================================================

-- ------------------------------------------------------------
-- 1. 待補貨標記
-- ------------------------------------------------------------
ALTER TABLE customer_order_items
  ADD COLUMN IF NOT EXISTS backorder_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS backorder_by UUID;

COMMENT ON COLUMN customer_order_items.backorder_at IS
  '待補貨（少發配貨時沒配到）時間；NULL = 正常。由 rpc_allocate_shortage 寫入 / 清除。'
  '有值時 is_order_item_pickup_ready 回 false，取貨會被擋。';

-- 待補貨是少數，用部分索引讓「查某店還有哪些待補」不必全表掃
CREATE INDEX IF NOT EXISTS idx_coi_backorder
  ON customer_order_items (sku_id, order_id)
  WHERE backorder_at IS NOT NULL;

-- ------------------------------------------------------------
-- 2. 取貨閘門：加一個 backorder_at IS NULL（其餘與 20260704000000 逐字相同）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_order_item_pickup_ready(p_item_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE coi.id = p_item_id
       AND co.status NOT IN ('completed','expired','cancelled','transferred_out')
       -- 只有未取的 active item 才有「可取貨」可言
       AND coi.status IN ('pending','reserved','ready')
       -- 少發配貨：沒配到的品項標成待補貨，在補到之前不可取
       --（rpc_allocate_shortage 寫入 / 清除；沒有缺貨的單這欄永遠是 NULL，行為不變）
       AND coi.backorder_at IS NULL
       AND CASE
         -- aid_transfer + 跨店：只認自己的 transfer 被收貨 (Path A)
         WHEN EXISTS (
                SELECT 1 FROM customer_order_items x
                 WHERE x.order_id = co.id AND x.source = 'aid_transfer'
              )
              AND co.transferred_from_order_id IS NOT NULL
              AND (
                SELECT src.pickup_store_id FROM customer_orders src
                 WHERE src.id = co.transferred_from_order_id
              ) IS DISTINCT FROM co.pickup_store_id
         THEN EXISTS (
           SELECT 1 FROM transfers t
            WHERE t.customer_order_id = co.id
              AND t.tenant_id = co.tenant_id
              AND t.status IN ('received','closed')
         )
         ELSE (
           -- Path A：aid 單 transfer FK 收貨
           EXISTS (
             SELECT 1 FROM transfers t
              WHERE t.customer_order_id = co.id
                AND t.tenant_id = co.tenant_id
                AND t.status IN ('received','closed')
           )
           OR
           -- Path B：campaign 對齊且該波次該 SKU 實收 qty>0
           EXISTS (
             SELECT 1
               FROM picking_wave_items pwi
               JOIN transfers t ON t.id = pwi.generated_transfer_id
               JOIN transfer_items ti ON ti.transfer_id = t.id
                                     AND ti.sku_id = coi.sku_id
              WHERE pwi.tenant_id   = co.tenant_id
                AND pwi.campaign_id = co.campaign_id
                AND pwi.store_id    = co.pickup_store_id
                AND pwi.sku_id      = coi.sku_id
                AND t.status IN ('received','closed')
                AND ti.qty_received > 0
           )
           OR
           -- Path C：該 (campaign,store,sku) 完全無對齊波次（彙整 PR）才退用 store+sku 實收
           (
             NOT EXISTS (
               SELECT 1 FROM picking_wave_items pwi
                WHERE pwi.tenant_id   = co.tenant_id
                  AND pwi.campaign_id = co.campaign_id
                  AND pwi.store_id    = co.pickup_store_id
                  AND pwi.sku_id      = coi.sku_id
             )
             AND EXISTS (
               SELECT 1
                 FROM stores st
                 JOIN transfers t ON t.transfer_type = 'hq_to_store'
                                 AND t.dest_location = st.location_id
                                 AND t.tenant_id     = co.tenant_id
                                 AND t.status IN ('received','closed')
                 JOIN transfer_items ti ON ti.transfer_id = t.id
                                       AND ti.sku_id = coi.sku_id
                                       AND ti.qty_received > 0
                WHERE st.id = co.pickup_store_id
             )
           )
         )
       END
  );
$function$;

COMMENT ON FUNCTION public.is_order_item_pickup_ready(bigint) IS
  '單一品項是否已到貨可取（Path A/B/C，shortage-aware）。'
  '20260703000000 的整單判定搬到品項粒度：未到貨品項個別擋、已到貨可先取。'
  '20260805000060 加上待補貨（backorder_at）擋板：少發配貨時沒配到的品項不可取。';

-- ------------------------------------------------------------
-- 3. rpc_get_allocation_candidates — 某張派貨單某個品項的可配額度與候選訂單
--    回 { supplied, picked, available, allocated, items:[...] }
--    supplied  該店該團該品項「已實收」的總量（跨多批到貨累加）
--    picked    已經被領走的量（不能再配給別人）
--    available supplied − picked，這就是還能配出去的量
--    items     未取的品項行，依 created_at, order_no 排序（＝「依訂單時間」）
-- ------------------------------------------------------------
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
           co.created_at
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
    ), '[]'::jsonb)
  );
$$;

-- ------------------------------------------------------------
-- 4. rpc_allocate_shortage — 配貨：指定「配到的」品項，其餘同組未取品項全部標待補貨
--    p_allocated_item_ids 以外的候選一律 backorder；名單內的一律清除 backorder，
--    所以下一批到貨時再呼叫一次就能把先前沒配到的補回來。
--    只動 (該派貨單所屬的 團,店,品項) 這一組，不會波及別團別店。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_allocate_shortage(
  p_transfer_id        BIGINT,
  p_sku_id             BIGINT,
  p_allocated_item_ids BIGINT[],
  p_operator           UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ctx      RECORD;
  v_alloc    BIGINT[] := COALESCE(p_allocated_item_ids, ARRAY[]::BIGINT[]);
  v_freed    INT := 0;
  v_blocked  INT := 0;
BEGIN
  SELECT pwi.tenant_id, pwi.campaign_id, pwi.store_id, pwi.sku_id
    INTO v_ctx
    FROM picking_wave_items pwi
   WHERE pwi.generated_transfer_id = p_transfer_id
     AND pwi.sku_id = p_sku_id
     AND pwi.campaign_id IS NOT NULL
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION '這張派貨單的該品項查不到對應的撿貨波次（可能是補貨或自由轉貨），無法配貨';
  END IF;

  -- 配到的：解除待補貨
  UPDATE customer_order_items coi
     SET backorder_at = NULL, backorder_by = NULL, updated_by = p_operator, updated_at = NOW()
    FROM customer_orders co
   WHERE co.id = coi.order_id
     AND coi.id = ANY(v_alloc)
     AND coi.sku_id = v_ctx.sku_id
     AND co.tenant_id = v_ctx.tenant_id
     AND co.campaign_id = v_ctx.campaign_id
     AND co.pickup_store_id = v_ctx.store_id
     AND coi.backorder_at IS NOT NULL;
  GET DIAGNOSTICS v_freed = ROW_COUNT;

  -- 沒配到的：標待補貨（已領走的不動）
  UPDATE customer_order_items coi
     SET backorder_at = NOW(), backorder_by = p_operator, updated_by = p_operator, updated_at = NOW()
    FROM customer_orders co
   WHERE co.id = coi.order_id
     AND NOT (coi.id = ANY(v_alloc))
     AND coi.sku_id = v_ctx.sku_id
     AND co.tenant_id = v_ctx.tenant_id
     AND co.campaign_id = v_ctx.campaign_id
     AND co.pickup_store_id = v_ctx.store_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND co.transferred_from_order_id IS NULL
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND coi.status IN ('pending', 'reserved', 'ready')
     AND coi.backorder_at IS NULL;
  GET DIAGNOSTICS v_blocked = ROW_COUNT;

  RETURN jsonb_build_object('allocated', COALESCE(array_length(v_alloc, 1), 0),
                            'freed', v_freed, 'backordered', v_blocked);
END;
$$;

-- ------------------------------------------------------------
-- 5. rpc_cancel_backorder_items — 待補貨轉取消（確定補不到時的一鍵處理）
--    沿用既有斷貨語意（20260702020000）：品項 cancelled + stockout_at，
--    整單品項都沒了且沒收過錢 → 訂單也一併取消。不在這裡發通知（店家自己跟客人講）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_cancel_backorder_items(
  p_item_ids BIGINT[],
  p_operator UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_items   INT := 0;
  v_orders  INT := 0;
  v_ids     BIGINT[] := COALESCE(p_item_ids, ARRAY[]::BIGINT[]);
BEGIN
  UPDATE customer_order_items coi
     SET status = 'cancelled', stockout_at = NOW(),
         updated_by = p_operator, updated_at = NOW()
   WHERE coi.id = ANY(v_ids)
     AND coi.backorder_at IS NOT NULL       -- 只准取消待補貨的，避免誤砍正常品項
     AND coi.status IN ('pending', 'reserved', 'ready');
  GET DIAGNOSTICS v_items = ROW_COUNT;

  UPDATE customer_orders co
     SET status = 'cancelled', cancelled_at = NOW(), stockout_at = NOW(),
         updated_by = p_operator, updated_at = NOW()
   WHERE co.id IN (SELECT order_id FROM customer_order_items WHERE id = ANY(v_ids))
     AND co.status IN ('pending', 'confirmed', 'ready', 'shipping')
     AND COALESCE(co.payment_status, 'unpaid') <> 'paid'
     AND COALESCE(co.wallet_paid_amount, 0) = 0
     AND NOT EXISTS (
           SELECT 1 FROM customer_order_items x
            WHERE x.order_id = co.id AND x.status NOT IN ('cancelled', 'expired')
         );
  GET DIAGNOSTICS v_orders = ROW_COUNT;

  RETURN jsonb_build_object('items_cancelled', v_items, 'orders_cancelled', v_orders);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_get_allocation_candidates(BIGINT, BIGINT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_allocate_shortage(BIGINT, BIGINT, BIGINT[], UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_cancel_backorder_items(BIGINT[], UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_allocation_candidates(BIGINT, BIGINT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_allocate_shortage(BIGINT, BIGINT, BIGINT[], UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_backorder_items(BIGINT[], UUID) TO authenticated;

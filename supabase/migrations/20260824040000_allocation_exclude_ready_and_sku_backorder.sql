-- ============================================================
-- 2026-08-24 (4)：少發配貨候選排除已可取貨的列＋收貨頁每 SKU 待補與總倉補單回覆
--
-- Alex 三個定案：
--   1. 「剛配到的（已可取貨）不用再出現」——「⚖️ 少發配貨」的候選清單
--      排除閘門已放行的未取列；佔掉的量從可配額度扣掉（否則畫面出現
--      「已配 2 超過可配 1」的自相矛盾）。rpc_allocate_shortage 的迴圈
--      同步排除 —— 否則沒出現在 p_allocations 的它們會被誤標待補貨。
--   2. 收貨頁品項行要標「這個 SKU 待補幾件」（群組加總看不出是哪個規格）。
--   3. 總倉對短少開了重派補單（redispatch wave）時，店家要看得到、連回去追。
--
-- 基底（每支都重新 grep 過）：
--   rpc_get_allocation_candidates / rpc_allocate_shortage ← 20260807000000
--   rpc_get_ship_vs_demand_for_transfers ← 20260811000060
-- Rollback：重跑上列基底檔對應區塊。
-- ============================================================

-- ----------------------------------------------------------------
-- A. rpc_get_allocation_candidates：排除已可取貨列＋available 扣已配量
-- ----------------------------------------------------------------
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
    'supplied',  (SELECT qty FROM supplied),
    'covered',   (SELECT qty FROM note_cov) + (SELECT qty FROM offset_cov),
    'picked',    (SELECT qty FROM picked),
    'available', GREATEST((SELECT qty FROM supplied) + (SELECT qty FROM note_cov)
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

-- ----------------------------------------------------------------
-- B. rpc_allocate_shortage：迴圈同步排除已可取貨列
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_allocate_shortage(p_transfer_id bigint, p_sku_id bigint, p_allocations jsonb, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_ctx        RECORD;
  r            RECORD;
  v_alloc      NUMERIC;
  v_freed      INT := 0;
  v_blocked    INT := 0;
  v_split      INT := 0;
  v_new_disc   NUMERIC;
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

  FOR r IN
    SELECT coi.id, coi.qty, coi.tenant_id, coi.order_id, coi.campaign_item_id,
           coi.sku_id, coi.unit_price, coi.status, coi.source, coi.notes,
           coi.discount_amount, coi.discount_percent, coi.backorder_at
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id AND coi.sku_id = v_ctx.sku_id
     WHERE co.tenant_id       = v_ctx.tenant_id
       AND co.campaign_id     = v_ctx.campaign_id
       AND co.pickup_store_id = v_ctx.store_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND (co.transferred_from_order_id IS NULL OR EXISTS (
             SELECT 1 FROM customer_orders src
              WHERE src.id = co.transferred_from_order_id
                AND src.pickup_store_id = co.pickup_store_id))
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND coi.status IN ('pending', 'reserved', 'ready')
       -- 20260824040000：已可取貨的列不參與重新分配（畫面上也不列），
       -- 否則沒出現在 p_allocations 的它們會被誤標成待補貨。
       AND NOT public.is_order_item_pickup_ready(coi.id)
     ORDER BY coi.id
     FOR UPDATE OF coi
  LOOP
    v_alloc := COALESCE((p_allocations ->> r.id::text)::numeric, 0);
    v_alloc := GREATEST(LEAST(v_alloc, r.qty), 0);

    IF v_alloc >= r.qty THEN
      -- 全部配到：解除待補貨
      IF r.backorder_at IS NOT NULL THEN
        UPDATE customer_order_items
           SET backorder_at = NULL, backorder_by = NULL,
               updated_by = p_operator, updated_at = NOW()
         WHERE id = r.id;
        v_freed := v_freed + 1;
      END IF;

    ELSIF v_alloc <= 0 THEN
      -- 完全沒配到：整行待補貨
      IF r.backorder_at IS NULL THEN
        UPDATE customer_order_items
           SET backorder_at = NOW(), backorder_by = p_operator,
               updated_by = p_operator, updated_at = NOW()
         WHERE id = r.id;
        v_blocked := v_blocked + 1;
      END IF;

    ELSE
      -- 部分配到 → 拆行：原行留可取的量，另開一行掛待補貨
      -- 折扣按數量比例分攤（與 rpc_record_pickup 拆行同一套算法）
      v_new_disc := COALESCE(r.discount_amount, 0)
                    - round(COALESCE(r.discount_amount, 0) * v_alloc / r.qty);

      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, notes, discount_amount, discount_percent,
        backorder_at, backorder_by,
        created_by, updated_by, created_at, updated_at
      ) VALUES (
        r.tenant_id, r.order_id, r.campaign_item_id, r.sku_id, r.qty - v_alloc, r.unit_price,
        r.status, r.source, r.notes, v_new_disc, r.discount_percent,
        NOW(), p_operator,
        p_operator, p_operator, NOW(), NOW()
      );

      UPDATE customer_order_items
         SET qty = v_alloc,
             discount_amount = COALESCE(r.discount_amount, 0)
                               - v_new_disc,
             backorder_at = NULL,
             backorder_by = NULL,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = r.id;

      v_split := v_split + 1;
      v_blocked := v_blocked + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('freed', v_freed, 'backordered', v_blocked, 'split', v_split);
END;
$function$;

-- ----------------------------------------------------------------
-- C. rpc_get_ship_vs_demand_for_transfers：by_sku ＋ 總倉處理回覆
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_ship_vs_demand_for_transfers(
  p_transfer_ids BIGINT[]
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH pw AS (
    SELECT pwi.generated_transfer_id      AS tid,
           pwi.tenant_id,
           pwi.campaign_id,
           pwi.store_id,
           pwi.sku_id,
           COALESCE(pwi.picked_qty, pwi.qty) AS shipped
      FROM picking_wave_items pwi
     WHERE pwi.generated_transfer_id = ANY(p_transfer_ids)
       AND pwi.campaign_id IS NOT NULL
  ),
  dem AS (
    SELECT pw.tid, pw.sku_id, pw.shipped, d.demand, cov.covered, pri.prior, bo.backorder
      FROM pw
      CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(coi.qty), 0) AS demand
          FROM customer_orders co
          JOIN customer_order_items coi
            ON coi.order_id = co.id
           AND coi.sku_id   = pw.sku_id
           AND coi.status NOT IN ('cancelled', 'expired')
         WHERE co.tenant_id       = pw.tenant_id
           AND co.campaign_id     = pw.campaign_id
           AND co.pickup_store_id = pw.store_id
           AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
           AND co.transferred_from_order_id IS NULL
           AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      ) d
      CROSS JOIN LATERAL (
        -- coverage = 庫存減抵單（已用店內現貨交貨）+ 抵減單（開團時宣告用店內現貨）
        SELECT COALESCE((
                 SELECT SUM(n.qty) FROM inventory_deduction_notes n
                  WHERE n.tenant_id   = pw.tenant_id
                    AND n.campaign_id = pw.campaign_id
                    AND n.store_id    = pw.store_id
                    AND n.sku_id      = pw.sku_id
                    AND n.cancelled_at IS NULL
               ), 0)
             + COALESCE((
                 SELECT SUM(-oi.qty)
                   FROM customer_orders oo
                   JOIN customer_order_items oi
                     ON oi.order_id = oo.id
                    AND oi.sku_id   = pw.sku_id
                    AND oi.qty < 0
                    AND oi.status NOT IN ('cancelled', 'expired')
                  WHERE oo.tenant_id       = pw.tenant_id
                    AND oo.campaign_id     = pw.campaign_id
                    AND oo.pickup_store_id = pw.store_id
                    AND oo.order_kind      = 'offset'
                    AND oo.status NOT IN ('cancelled', 'expired', 'transferred_out')
               ), 0) AS covered
      ) cov
      CROSS JOIN LATERAL (
        -- 20260811(7)：這組還掛著幾件待補貨（backorder_at 未解）。
        -- 修掉假短少之後，「短少」歸零的組別連帶會失去收貨頁的「⚖️ 配貨」入口
        --（顯示條件是 short > 0 || covered > 0），而那是唯一能人工解除
        -- backorder_at 的地方。所以另外回一個 backorder，讓還有人在等的組別
        -- 一定看得到入口，也讓店家知道「這組還有 N 件沒配到」。
        SELECT COALESCE(SUM(coi.qty), 0) AS backorder
          FROM customer_orders co
          JOIN customer_order_items coi
            ON coi.order_id = co.id
           AND coi.sku_id   = pw.sku_id
           AND coi.status IN ('pending', 'reserved', 'ready')
           AND coi.backorder_at IS NOT NULL
         WHERE co.tenant_id       = pw.tenant_id
           AND co.campaign_id     = pw.campaign_id
           AND co.pickup_store_id = pw.store_id
           AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
           AND co.transferred_from_order_id IS NULL
           AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      ) bo
      CROSS JOIN LATERAL (
        -- 20260811(7)：同一 (團,店,SKU) 的「其他」已收批次實收量。
        -- 沒有這一項，第二批到貨會被當成「這團只到了這麼多」，
        -- 第一批早就收進來的量憑空消失 → 假短少。
        -- 條件比照 rpc_get_allocation_candidates 的 supplied。
        SELECT COALESCE(SUM(ti.qty_received), 0) AS prior
          FROM picking_wave_items p2
          JOIN transfers t       ON t.id = p2.generated_transfer_id
                                AND t.status IN ('received', 'closed')
          JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = pw.sku_id
         WHERE p2.tenant_id            = pw.tenant_id
           AND p2.campaign_id          = pw.campaign_id
           AND p2.store_id             = pw.store_id
           AND p2.sku_id               = pw.sku_id
           AND p2.generated_transfer_id IS DISTINCT FROM pw.tid
      ) pri
  ),
  per_line AS (
    SELECT dem.tid,
           dem.sku_id,
           -- over 維持單批語意，不加 prior（見檔頭）
           GREATEST(dem.shipped - dem.demand, 0)                                  AS over_qty,
           GREATEST(dem.demand - dem.prior - dem.shipped - dem.covered, 0)        AS short_qty,
           LEAST(dem.covered, GREATEST(dem.demand - dem.prior - dem.shipped, 0))  AS covered_qty,
           -- 沒在補缺口的減抵量 = 這批到貨其實是補回店家先墊的貨
           LEAST(
             GREATEST(dem.covered
                      - LEAST(dem.covered, GREATEST(dem.demand - dem.prior - dem.shipped, 0)), 0),
             dem.shipped
           ) AS prefilled_qty,
           dem.backorder                                                          AS backorder_qty
      FROM dem
  ),
  per_transfer AS (
    SELECT per_line.tid,
           SUM(per_line.over_qty)      AS over_qty,
           SUM(per_line.short_qty)     AS short_qty,
           SUM(per_line.covered_qty)   AS covered_qty,
           SUM(per_line.prefilled_qty) AS prefilled_qty,
           SUM(per_line.backorder_qty) AS backorder_qty
      FROM per_line
     GROUP BY per_line.tid
    HAVING SUM(per_line.over_qty) > 0
        OR SUM(per_line.short_qty) > 0
        OR SUM(per_line.covered_qty) > 0
        OR SUM(per_line.prefilled_qty) > 0
        OR SUM(per_line.backorder_qty) > 0
  ),
  by_sku AS (
    -- 20260824040000：每個 SKU 各自的 短少/待補 件數 —— 收貨頁品項行要
    -- 標「待補 N」，群組層加總看不出是哪個規格在等。
    SELECT per_line.tid,
           jsonb_object_agg(per_line.sku_id::text,
             jsonb_build_object('short', per_line.short_qty,
                                'backorder', per_line.backorder_qty)) AS by_sku
      FROM per_line
     WHERE per_line.short_qty > 0 OR per_line.backorder_qty > 0
     GROUP BY per_line.tid
  ),
  hq AS (
    -- 20260824040000：總倉對這張單短少/多收的處理回覆（含開出的重派補單）
    -- —— 店家要看得到總倉開了什麼、連回去追蹤。
    SELECT ti.transfer_id AS tid,
           jsonb_agg(jsonb_build_object(
             'sku_id',      ti.sku_id,
             'resolution',  ti.shortage_resolution,
             'wave_code',   pw2.wave_code,
             'wave_status', pw2.status) ORDER BY ti.id) AS hq
      FROM transfer_items ti
      LEFT JOIN picking_waves pw2 ON pw2.id = ti.shortage_redispatch_wave_id
     WHERE ti.transfer_id = ANY(p_transfer_ids)
       AND ti.shortage_resolution IS NOT NULL
     GROUP BY ti.transfer_id
  )
  SELECT COALESCE(
           jsonb_object_agg(
             t.tid::text,
             jsonb_build_object('over',      COALESCE(pt.over_qty, 0),
                                'short',     COALESCE(pt.short_qty, 0),
                                'covered',   COALESCE(pt.covered_qty, 0),
                                'prefilled', COALESCE(pt.prefilled_qty, 0),
                                'backorder', COALESCE(pt.backorder_qty, 0),
                                'by_sku',    COALESCE(bs.by_sku, '{}'::jsonb),
                                'hq',        COALESCE(hq.hq, '[]'::jsonb))
           ),
           '{}'::jsonb)
    FROM (SELECT tid FROM per_transfer UNION SELECT tid FROM hq) t
    LEFT JOIN per_transfer pt ON pt.tid = t.tid
    LEFT JOIN by_sku bs       ON bs.tid = t.tid
    LEFT JOIN hq              ON hq.tid = t.tid;
$$;

COMMENT ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) IS
  '收貨頁的派出量 vs 訂單需求：over（這一批多給）/ short（還缺幾件）/ '
  'covered（缺口已由店內現貨吸收）/ prefilled（這批是補回店家先墊的貨）/ '
  'backorder（這組還掛著幾件待補貨未解）。'
  'short/covered/prefilled 的供給側含同組其他已收批次的實收量（prior），'
  '多批到貨才不會被算成假短少；over 維持單批語意。'
  '20260824040000 起另回 by_sku（每 SKU 的 short/backorder，收貨頁品項行標待補用）'
  '與 hq（總倉對短少/多收的處理回覆，含重派補單 wave_code/status）。';

REVOKE ALL ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_ship_vs_demand_for_transfers(BIGINT[]) TO authenticated;

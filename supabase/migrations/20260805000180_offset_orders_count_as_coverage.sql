-- ============================================================
-- 抵減單（order_kind='offset' 負數訂單）納入短少/配貨的 coverage
--
-- 動機：「庫存抵減單」（rpc_create_offset_order，20260516）是開團時
--   店內已有現貨、不想讓總倉多採購的既有做法：開負數訂單讓採購聚合扣掉。
--   但 20260805000050/60 的短少警示與配貨 join 都只認 order_kind='normal'，
--   把抵減單無視 → 訂 8、抵減 -2、總倉照計畫派 6，收貨頁卻誤報「⚠ 少 2」，
--   配貨（含 20260805000070 backfill）還把本來就要吃店內現貨的客人標成
--   待補貨、擋住取貨。線上 7 組 (團,店,品項)、16 個品項共 20 件正被誤擋。
--
-- 修法：抵減單 = 「店內現貨吸收」的既有宣告，語意上就是 coverage ——
--   與 20260805000170 的庫存減抵單同等對待：
--   1. rpc_get_ship_vs_demand_for_transfers：coverage 加上 offset 量
--      （over 不動 — 每件貨背後都真的有客人，不是「沒訂單對應」）。
--   2. rpc_get_allocation_candidates：covered / available 加上 offset 量，
--      notes 清單一併回傳抵減單（kind='offset'）供畫面顯示。
--   3. rpc_create_inventory_deduction 的缺口上限也算入 offset（防重複覆蓋）。
--   4. 取貨閘門 Path D 同時認抵減單（整批沒到、全靠店內現貨的極端情況）。
--   5. Backfill：offset 覆蓋範圍內被誤標的 backorder_at 解除（只解不加，
--      依下單時間整行解，額度不夠的部分行保留讓店家自行處理）。
--
-- 需求端為何不直接把 offset 加進 demand：v4 短缺看板（20260801）是採購
--   前瞻模型、offset 屬需求抵減；這裡的「少 N」比的是「派出 vs 客人訂單」，
--   demand 保持 normal-only、offset 當 coverage，over（多給）的語意才不變。
--
-- 基底版本（全部 = 20260805000170，唯一版本）：
--   rpc_get_ship_vs_demand_for_transfers / rpc_get_allocation_candidates /
--   rpc_create_inventory_deduction / is_order_item_pickup_ready
-- rollback：重跑 20260805000170 的四支函式；DROP INDEX IF EXISTS idx_co_offset_group;
--   backorder 回填無法自動回復（backorder_by 留有 operator 可查）。
-- ============================================================

-- 取貨閘門 / coverage 都以 (tenant,campaign,store) 找抵減單，給個部分索引
CREATE INDEX IF NOT EXISTS idx_co_offset_group
  ON customer_orders (tenant_id, campaign_id, pickup_store_id)
  WHERE order_kind = 'offset';

-- ------------------------------------------------------------
-- 1. 短少警示：coverage = 庫存減抵單 + 抵減單（負數訂單）
-- ------------------------------------------------------------
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
    SELECT pw.tid, pw.shipped, d.demand, cov.covered
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
        -- coverage = 庫存減抵單（已交貨）+ 抵減單（開團時宣告用店內現貨）
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
  ),
  per_transfer AS (
    SELECT dem.tid,
           SUM(GREATEST(dem.shipped - dem.demand, 0))               AS over_qty,
           SUM(GREATEST(dem.demand - dem.shipped - dem.covered, 0)) AS short_qty,
           SUM(LEAST(dem.covered, GREATEST(dem.demand - dem.shipped, 0))) AS covered_qty
      FROM dem
     GROUP BY dem.tid
    HAVING SUM(GREATEST(dem.shipped - dem.demand, 0)) > 0
        OR SUM(GREATEST(dem.demand - dem.shipped - dem.covered, 0)) > 0
        OR SUM(LEAST(dem.covered, GREATEST(dem.demand - dem.shipped, 0))) > 0
  )
  SELECT COALESCE(
           jsonb_object_agg(
             per_transfer.tid::text,
             jsonb_build_object('over', per_transfer.over_qty,
                                'short', per_transfer.short_qty,
                                'covered', per_transfer.covered_qty)
           ),
           '{}'::jsonb)
    FROM per_transfer;
$$;

-- ------------------------------------------------------------
-- 2. 配貨視窗：covered / available 算入抵減單；notes 一併列出（kind 區分）
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
    ), '[]'::jsonb)
  );
$$;

-- ------------------------------------------------------------
-- 3. 開減抵單的缺口上限也算入抵減單（防同一缺口被覆蓋兩次）
--    （逐字沿用 20260805000170，只在 v_covered 加上 offset 量）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_inventory_deduction(
  p_store_id    BIGINT,
  p_campaign_id BIGINT,
  p_sku_id      BIGINT,
  p_allocations JSONB,
  p_reason      TEXT,
  p_operator    UUID,
  p_transfer_id BIGINT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_store     stores%ROWTYPE;
  r           RECORD;
  v_total     NUMERIC := 0;
  v_avail     NUMERIC;
  v_demand    NUMERIC;
  v_supplied  NUMERIC;
  v_covered   NUMERIC;
  v_note      inventory_deduction_notes%ROWTYPE;
  v_req_count INT;
  v_ord       RECORD;
  v_items     INT := 0;
  v_orders    INT := 0;
BEGIN
  IF p_allocations IS NULL OR p_allocations = '{}'::jsonb THEN
    RAISE EXCEPTION '沒有選擇要交貨的品項';
  END IF;

  SELECT * INTO v_store FROM stores WHERE id = p_store_id;
  IF NOT FOUND OR v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 不存在或未綁定倉別', p_store_id;
  END IF;

  -- 同組併發開單會各自過庫存檢查，鎖住整組序列化
  PERFORM pg_advisory_xact_lock(hashtext(format('idn:%s:%s:%s:%s',
    v_store.tenant_id, p_campaign_id, p_store_id, p_sku_id)));

  SELECT COUNT(*) INTO v_req_count FROM jsonb_object_keys(p_allocations);

  -- 建立暫存清單：驗證每一行屬於這組、還沒取、且是「待補貨」
  -- （先 DROP：同一交易內逐商品連續開單時 temp table 會殘留）
  DROP TABLE IF EXISTS _idn_targets;
  CREATE TEMP TABLE _idn_targets ON COMMIT DROP AS
  SELECT coi.id AS item_id, coi.order_id, coi.qty AS line_qty,
         LEAST((p_allocations ->> coi.id::text)::numeric, coi.qty) AS take_qty
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE coi.id IN (SELECT k::bigint FROM jsonb_object_keys(p_allocations) AS k)
     AND co.tenant_id       = v_store.tenant_id
     AND co.campaign_id     = p_campaign_id
     AND co.pickup_store_id = p_store_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND coi.sku_id = p_sku_id
     AND coi.status IN ('pending', 'reserved', 'ready')
     AND coi.backorder_at IS NOT NULL;

  IF (SELECT COUNT(*) FROM _idn_targets) <> v_req_count THEN
    RAISE EXCEPTION '有品項不是「待補貨」或已被取走 — 請重新整理畫面。'
      '（減抵單只能交「待補貨」的品項；還沒配貨的請先在配貨視窗儲存配貨）';
  END IF;

  FOR r IN SELECT * FROM _idn_targets LOOP
    IF r.take_qty IS NULL OR r.take_qty <= 0 OR r.take_qty <> FLOOR(r.take_qty) THEN
      RAISE EXCEPTION '品項 % 的交貨數量不合法（須為正整數）', r.item_id;
    END IF;
    v_total := v_total + r.take_qty;
  END LOOP;

  -- 店倉可用量檢查：現貨要先在帳上（庫存總覽可依商品新增庫存）
  SELECT on_hand - reserved INTO v_avail
    FROM stock_balances
   WHERE tenant_id = v_store.tenant_id
     AND location_id = v_store.location_id
     AND sku_id = p_sku_id
   FOR UPDATE;
  IF NOT FOUND THEN v_avail := 0; END IF;

  IF v_avail < v_total THEN
    RAISE EXCEPTION '店內帳上現貨不足：可用 % 件、要交 % 件。請先到「庫存總覽」對該商品新增庫存，再開減抵單',
      v_avail, v_total;
  END IF;

  INSERT INTO inventory_deduction_notes (
    tenant_id, note_no, campaign_id, store_id, sku_id, transfer_id,
    qty, reason, created_by
  ) VALUES (
    v_store.tenant_id,
    'DN' || to_char(NOW(), 'YYMMDD') || lpad(nextval('deduction_note_seq')::text, 4, '0'),
    p_campaign_id, p_store_id, p_sku_id, p_transfer_id,
    v_total, NULLIF(TRIM(p_reason), ''), p_operator
  ) RETURNING * INTO v_note;

  INSERT INTO inventory_deduction_note_items (note_id, order_id, order_item_id, qty)
  SELECT v_note.id, t.order_id, t.item_id, t.take_qty FROM _idn_targets t;

  -- 逐訂單交貨：先解除該訂單要交的行的待補貨（取貨閘門才會放行），
  -- 再走 rpc_record_pickup 入帳（sale 異動、拆行、訂單收尾、pickup event）。
  FOR v_ord IN SELECT DISTINCT order_id FROM _idn_targets LOOP
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = NOW()
      FROM _idn_targets t
     WHERE t.order_id = v_ord.order_id AND coi.id = t.item_id;

    PERFORM public.rpc_record_pickup(
      v_ord.order_id,
      (SELECT array_agg(t.item_id) FROM _idn_targets t WHERE t.order_id = v_ord.order_id),
      p_operator,
      format('庫存減抵單 %s：店內現貨交貨', v_note.note_no),
      (SELECT jsonb_object_agg(t.item_id::text, t.take_qty)
         FROM _idn_targets t WHERE t.order_id = v_ord.order_id)
    );
    v_orders := v_orders + 1;

    -- 部分交貨：rpc_record_pickup 拆行後原行（殘量）仍是 active，
    -- 沒交到的部分要標回待補貨，不然會被誤認為可取
    UPDATE customer_order_items coi
       SET backorder_at = NOW(), backorder_by = p_operator,
           updated_by = p_operator, updated_at = NOW()
      FROM _idn_targets t
     WHERE t.order_id = v_ord.order_id
       AND coi.id = t.item_id
       AND t.take_qty < t.line_qty
       AND coi.status IN ('pending', 'reserved', 'ready');
  END LOOP;

  SELECT COUNT(*) INTO v_items FROM _idn_targets;

  RETURN jsonb_build_object(
    'id', v_note.id, 'note_no', v_note.note_no, 'qty', v_total,
    'items', v_items, 'orders', v_orders
  );
END;
$$;

-- ------------------------------------------------------------
-- 4. 取貨閘門 Path D：庫存減抵單「或」抵減單都算貨到
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
           OR
           -- Path D：庫存減抵單 — 店家用店內現貨吸收這組缺口
           EXISTS (
             SELECT 1 FROM inventory_deduction_notes n
              WHERE n.tenant_id   = co.tenant_id
                AND n.campaign_id = co.campaign_id
                AND n.store_id    = co.pickup_store_id
                AND n.sku_id      = coi.sku_id
                AND n.cancelled_at IS NULL
           )
           OR
           -- Path D'：抵減單（order_kind='offset' 負數訂單）— 開團時就宣告
           -- 這組有店內現貨吸收，等同貨到（哪些行可取仍由 backorder_at 控管）
           EXISTS (
             SELECT 1
               FROM customer_orders oo
               JOIN customer_order_items oi
                 ON oi.order_id = oo.id
                AND oi.sku_id   = coi.sku_id
                AND oi.qty < 0
                AND oi.status NOT IN ('cancelled','expired')
              WHERE oo.tenant_id       = co.tenant_id
                AND oo.campaign_id     = co.campaign_id
                AND oo.pickup_store_id = co.pickup_store_id
                AND oo.order_kind      = 'offset'
                AND oo.status NOT IN ('cancelled','expired','transferred_out')
           )
         )
       END
  );
$function$;

COMMENT ON FUNCTION public.is_order_item_pickup_ready(bigint) IS
  '單一品項是否已到貨可取（Path A/B/C/D，shortage-aware）。'
  '20260703000000 的整單判定搬到品項粒度：未到貨品項個別擋、已到貨可先取。'
  '20260805000060 加上待補貨（backorder_at）擋板：少發配貨時沒配到的品項不可取。'
  '20260805000170 加 Path D：庫存減抵單（店內現貨吸收缺口）也算貨到。'
  '20260805000180 Path D 同時認抵減單（order_kind=offset 負數訂單）。';

-- ------------------------------------------------------------
-- 5. Backfill：解除抵減單覆蓋範圍內被誤標的待補貨
--    只解不加：spare = 實收 + coverage − 已領走 − 未被擋的 active 量，
--    依 (created_at, order_no) 整行解到額度用完；不夠的部分行保留。
-- ------------------------------------------------------------
DO $$
DECLARE
  v_grp    RECORD;
  v_row    RECORD;
  v_spare  NUMERIC;
  v_freed  INT := 0;
  v_kept   INT := 0;
BEGIN
  FOR v_grp IN
    SELECT off.tenant_id, off.campaign_id, off.store_id, off.sku_id, off.offset_qty
      FROM (
        SELECT co.tenant_id, co.campaign_id, co.pickup_store_id AS store_id,
               coi.sku_id, SUM(-coi.qty) AS offset_qty
          FROM customer_orders co
          JOIN customer_order_items coi
            ON coi.order_id = co.id AND coi.qty < 0
           AND coi.status NOT IN ('cancelled','expired')
         WHERE co.order_kind = 'offset'
           AND co.status NOT IN ('cancelled','expired','transferred_out')
         GROUP BY 1, 2, 3, 4
      ) off
     WHERE EXISTS (
       SELECT 1
         FROM customer_orders co
         JOIN customer_order_items coi ON coi.order_id = co.id
        WHERE co.tenant_id       = off.tenant_id
          AND co.campaign_id     = off.campaign_id
          AND co.pickup_store_id = off.store_id
          AND coi.sku_id         = off.sku_id
          AND coi.backorder_at IS NOT NULL
          AND coi.status IN ('pending','reserved','ready')
          AND co.status NOT IN ('cancelled','expired','transferred_out')
     )
  LOOP
    -- spare = 實收 + 減抵單 + 抵減 − 已領走 − 未被擋的 active 量
    SELECT COALESCE((
             SELECT SUM(ti.qty_received)
               FROM picking_wave_items pwi
               JOIN transfers t ON t.id = pwi.generated_transfer_id
                               AND t.status IN ('received','closed')
               JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = v_grp.sku_id
              WHERE pwi.tenant_id = v_grp.tenant_id AND pwi.campaign_id = v_grp.campaign_id
                AND pwi.store_id = v_grp.store_id AND pwi.sku_id = v_grp.sku_id
           ), 0)
         + v_grp.offset_qty
         + COALESCE((
             SELECT SUM(n.qty) FROM inventory_deduction_notes n
              WHERE n.tenant_id = v_grp.tenant_id AND n.campaign_id = v_grp.campaign_id
                AND n.store_id = v_grp.store_id AND n.sku_id = v_grp.sku_id
                AND n.cancelled_at IS NULL
           ), 0)
         - COALESCE((
             SELECT SUM(coi.qty)
               FROM customer_orders co
               JOIN customer_order_items coi ON coi.order_id = co.id AND coi.sku_id = v_grp.sku_id
              WHERE co.tenant_id = v_grp.tenant_id AND co.campaign_id = v_grp.campaign_id
                AND co.pickup_store_id = v_grp.store_id
                AND co.status NOT IN ('cancelled','expired','transferred_out')
                AND co.transferred_from_order_id IS NULL
                AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
                AND (coi.status IN ('picked_up','partially_picked_up')
                     OR (coi.status IN ('pending','reserved','ready') AND coi.backorder_at IS NULL))
           ), 0)
      INTO v_spare;

    FOR v_row IN
      SELECT coi.id, coi.qty
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id AND coi.sku_id = v_grp.sku_id
       WHERE co.tenant_id = v_grp.tenant_id AND co.campaign_id = v_grp.campaign_id
         AND co.pickup_store_id = v_grp.store_id
         AND co.status NOT IN ('cancelled','expired','transferred_out')
         AND coi.backorder_at IS NOT NULL
         AND coi.status IN ('pending','reserved','ready')
       ORDER BY co.created_at, co.order_no
    LOOP
      IF v_row.qty <= v_spare THEN
        UPDATE customer_order_items
           SET backorder_at = NULL, backorder_by = NULL, updated_at = NOW()
         WHERE id = v_row.id;
        v_spare := v_spare - v_row.qty;
        v_freed := v_freed + 1;
      ELSE
        v_kept := v_kept + 1;
      END IF;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'offset coverage backfill: freed % backordered items, kept % (insufficient coverage)',
    v_freed, v_kept;
END $$;

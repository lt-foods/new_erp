-- ============================================================
-- 2026-07-04: 取貨擋板改品項層級 — 已到貨品項可先取，未到貨品項個別擋
--
-- 回報案例：
--   訂單 GRP-20260609-025-0001 (id=25237, campaign 2386, 忠順店 store 51)：
--   WAVE-15-S51 (transfer 67) 收貨時 G00123-02 (sku 1026) 短收
--   qty_shipped=3 / qty_received=0，G00123-07 (sku 1031) 2 收 1。
--   20260703000000 的嚴格版 is_order_pickup_ready 是「整單」判定：
--   任一 active 品項 SKU 實收 0 → 整單 false → rpc_record_pickup 全擋，
--   連已實際到店的另外 5 項也不能先給會員取。
--
-- 修法：
--   1. 新增 is_order_item_pickup_ready(p_item_id)：把 20260703000000 的
--      Path A/B/C 判定逐字搬到「單一品項」粒度：
--        - Path A：aid 單 transfer FK 收貨（aid 跨店只認 Path A，沿用 20260629000020）。
--        - Path B：該品項 (campaign, store, sku) 有對齊波次且該 line qty_received>0。
--        - Path C：僅當該 (campaign, store, sku) 完全無對齊波次（彙整 PR）
--          才退用 store+sku 實收 qty_received>0（沿用 20260615000010 注意事項）。
--   2. is_order_pickup_ready 改寫為聚合：「仍有 active 品項，且所有 active
--      品項皆 item-ready」。與 20260703000000 語義完全等價
--      （∀item (PathA ∨ B(i) ∨ C(i)) ⟺ PathA ∨ ∀item (B(i) ∨ C(i))，
--      因 Path A 與 aid 跨店判定皆與 item 無關），單一事實來源避免兩份邏輯漂移。
--      shipping→ready 的整單推進（rpc_receive_transfer 邏輯 C）行為不變：
--      仍須「全到齊」才轉 ready。
--   3. rpc_record_pickup：整單 is_order_pickup_ready 擋板改為迴圈內逐品項
--      is_order_item_pickup_ready 擋板 — 未到貨品項擋（報品項名稱），
--      已到貨品項放行。部分取完後訂單照原邏輯轉 partially_completed，
--      剩餘品項待補到貨後可續取（UI 對 partially_completed 本就開放續取）。
--   4. 新增 v_order_item_pickup_ready view 給 UI 顯示品項到貨狀態
--      （比照 20260512000008 的 v_order_pickup_ready 模式）。
--
-- 基底版本：
--   - is_order_pickup_ready：20260703000000_strict_pickup_ready_shortage_aware.sql
--     （線上現行版，Path A/B/C 邏輯逐字搬入 item 版）。
--   - rpc_record_pickup：20260630000010_pickup_partial_qty_split.sql
--     （5-arg 拆行版；已 dump 線上確認一致；僅把整單擋板換成逐品項擋板）。
-- Rollback：
--   - is_order_pickup_ready：CREATE OR REPLACE 回 20260703000000 版本。
--   - rpc_record_pickup：CREATE OR REPLACE 回 20260630000010 版本。
--   - DROP VIEW v_order_item_pickup_ready;
--     DROP FUNCTION is_order_item_pickup_ready(bigint);
-- ============================================================

-- ----------------------------------------------------------------
-- 1. is_order_item_pickup_ready — 單一品項的到貨判定 (Path A/B/C)
-- ----------------------------------------------------------------
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
  '20260703000000 的整單判定搬到品項粒度：未到貨品項個別擋、已到貨可先取。';

GRANT EXECUTE ON FUNCTION public.is_order_item_pickup_ready(bigint) TO authenticated;

-- ----------------------------------------------------------------
-- 2. is_order_pickup_ready — 改寫為 item 版聚合（語義等價 20260703000000）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_order_pickup_ready(p_order_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM customer_orders co
     WHERE co.id = p_order_id
       AND co.status NOT IN ('completed','expired','cancelled','transferred_out')
       -- 必須還有未取的 active item，否則無從「取貨」
       AND EXISTS (
         SELECT 1 FROM customer_order_items coi
          WHERE coi.order_id = co.id
            AND coi.status IN ('pending','reserved','ready')
       )
       -- 所有 active item 都到貨才算整單 ready（shipping→ready 推進維持「全到齊」）
       AND NOT EXISTS (
         SELECT 1 FROM customer_order_items coi
          WHERE coi.order_id = co.id
            AND coi.status IN ('pending','reserved','ready')
            AND NOT public.is_order_item_pickup_ready(coi.id)
       )
  );
$function$;

COMMENT ON FUNCTION public.is_order_pickup_ready(bigint) IS
  '整單是否可取貨＝仍有 active 品項且所有 active 品項皆 is_order_item_pickup_ready。'
  '與 20260703000000 嚴格版語義等價；品項粒度邏輯統一在 is_order_item_pickup_ready。';

-- ----------------------------------------------------------------
-- 3. rpc_record_pickup — 整單擋板 → 逐品項擋板
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_record_pickup(
  p_order_id  bigint,
  p_item_ids  bigint[],
  p_operator  uuid,
  p_notes     text  DEFAULT NULL,
  p_item_qtys jsonb DEFAULT NULL   -- {"<item_id>": <取貨數量>}；缺項或 >=qty 視為整行取
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_pickup_loc       BIGINT;
  v_item             RECORD;
  v_take             NUMERIC;
  v_picked_disc      NUMERIC;
  v_movement_id      BIGINT;
  v_new_item_id      BIGINT;
  v_picked_item_id   BIGINT;
  v_picked_count     INT := 0;
  v_event_item_ids   BIGINT[] := ARRAY[]::BIGINT[];
  v_active_remaining INT;
  v_new_status       TEXT;
  v_event_type       TEXT;
  v_event_id         BIGINT;
  v_sku_label        TEXT;
  v_now              TIMESTAMPTZ := NOW();
BEGIN
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_item_ids is empty';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_pickup:' || p_order_id::text));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 %', p_order_id;
  END IF;

  IF v_order.status IN ('completed','expired','cancelled','transferred_out') THEN
    RAISE EXCEPTION '訂單 % 目前狀態為「%」，無法取貨', p_order_id, v_order.status;
  END IF;

  SELECT location_id INTO v_pickup_loc
    FROM stores
   WHERE id = v_order.pickup_store_id;

  IF v_pickup_loc IS NULL THEN
    RAISE EXCEPTION '分店 % 未設定倉庫位置 (location_id)、無法寫 stock_movement', v_order.pickup_store_id;
  END IF;

  -- 逐品項：判斷整行取 or 拆行部分取
  FOR v_item IN
    SELECT id, sku_id, qty, unit_price, status, source, campaign_item_id,
           tenant_id, notes, discount_amount, discount_percent, created_by
      FROM customer_order_items
     WHERE id = ANY(p_item_ids)
       AND order_id = p_order_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.status NOT IN ('pending','reserved','ready') THEN
      RAISE EXCEPTION '品項 % 狀態 % 不可取貨', v_item.id, v_item.status;
    END IF;

    -- 逐品項到貨擋板（取代舊的整單 is_order_pickup_ready 擋板）：
    -- 未到貨（該 SKU 分店實收 0）的品項個別擋，已到貨的品項放行先取
    IF NOT public.is_order_item_pickup_ready(v_item.id) THEN
      SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
        INTO v_sku_label FROM skus s WHERE s.id = v_item.sku_id;
      RAISE EXCEPTION '品項「%」分店尚未實收到貨，無法取貨（請取消勾選該品項，其餘已到貨品項可先取）',
        COALESCE(v_sku_label, v_item.sku_id::text);
    END IF;

    -- 本次取多少：p_item_qtys 指定則用之，否則整行取
    v_take := COALESCE((p_item_qtys ->> v_item.id::text)::numeric, v_item.qty);
    IF v_take IS NULL OR v_take <= 0 THEN
      RAISE EXCEPTION '品項 % 取貨數量 % 不合法（須 > 0）', v_item.id, v_take;
    END IF;
    IF v_take > v_item.qty THEN
      RAISE EXCEPTION '品項 % 取貨數量 % 超過待取數量 %', v_item.id, v_take, v_item.qty;
    END IF;

    IF v_take = v_item.qty THEN
      -- ── 整行取：沿用舊邏輯，直接標 picked_up ──
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
      ) VALUES (
        v_order.tenant_id, v_pickup_loc, v_item.sku_id, -v_take, 'sale',
        'customer_order', p_order_id, v_item.id,
        format('顧客取貨 order=%s item=%s', p_order_id, v_item.id), p_operator
      ) RETURNING id INTO v_movement_id;

      UPDATE customer_order_items
         SET status = 'picked_up',
             pickup_movement_id = v_movement_id,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v_item.id;

      v_picked_item_id := v_item.id;
    ELSE
      -- ── 部分取：拆行。新建 picked_up 行，原行扣量留待下次 ──
      -- line-level 折扣金額按取貨比例分攤，確保兩行小計加總 = 原行
      v_picked_disc := round(COALESCE(v_item.discount_amount, 0) * v_take / v_item.qty);

      -- 1) 先建 picked_up 行（暫不填 movement，先拿 id）
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, reserved_movement_id, pickup_movement_id, notes,
        discount_amount, discount_percent, created_by, updated_by, created_at, updated_at
      ) VALUES (
        v_item.tenant_id, p_order_id, v_item.campaign_item_id, v_item.sku_id, v_take, v_item.unit_price,
        'picked_up', v_item.source, NULL, NULL, v_item.notes,
        v_picked_disc, v_item.discount_percent, v_item.created_by, p_operator, v_now, v_now
      ) RETURNING id INTO v_new_item_id;

      -- 2) sale movement 指向新行
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
      ) VALUES (
        v_order.tenant_id, v_pickup_loc, v_item.sku_id, -v_take, 'sale',
        'customer_order', p_order_id, v_new_item_id,
        format('顧客部分取貨 order=%s item=%s (split from %s)', p_order_id, v_new_item_id, v_item.id), p_operator
      ) RETURNING id INTO v_movement_id;

      -- 3) 回填新行 movement
      UPDATE customer_order_items
         SET pickup_movement_id = v_movement_id
       WHERE id = v_new_item_id;

      -- 4) 原行扣量、保持 active 狀態，剩餘留待下次取
      UPDATE customer_order_items
         SET qty = qty - v_take,
             discount_amount = COALESCE(discount_amount, 0) - v_picked_disc,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v_item.id;

      v_picked_item_id := v_new_item_id;
    END IF;

    -- event 記錄「被取走」那一行的 id（拆行時是新行）→ 收據查到正確的 qty
    v_event_item_ids := v_event_item_ids || v_picked_item_id;
    v_picked_count := v_picked_count + 1;
  END LOOP;

  IF v_picked_count = 0 THEN
    RAISE EXCEPTION 'no items picked (check p_item_ids belongs to order %)', p_order_id;
  END IF;

  -- 重算 order status（剩餘 active 行 → partially_completed；全取完 → completed）
  SELECT COUNT(*) INTO v_active_remaining
    FROM customer_order_items
   WHERE order_id = p_order_id
     AND status IN ('pending','reserved','ready');

  IF v_active_remaining = 0 THEN
    v_new_status := 'completed';
    v_event_type := 'picked_up';
  ELSE
    v_new_status := 'partially_completed';
    v_event_type := 'partial_pickup';
  END IF;

  UPDATE customer_orders
     SET status       = v_new_status,
         completed_at = CASE WHEN v_new_status = 'completed' THEN v_now ELSE NULL END,
         updated_by   = p_operator,
         updated_at   = v_now
   WHERE id = p_order_id;

  INSERT INTO order_pickup_events (
    tenant_id, order_id, pickup_store_id, event_type, item_ids, notes, created_by
  ) VALUES (
    v_order.tenant_id, p_order_id, v_order.pickup_store_id, v_event_type,
    to_jsonb(v_event_item_ids), p_notes, p_operator
  ) RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'event_id',        v_event_id,
    'event_type',      v_event_type,
    'picked_count',    v_picked_count,
    'active_remaining', v_active_remaining,
    'new_status',      v_new_status
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) IS
  '取貨記帳。p_item_qtys={"<item_id>":<取貨數量>} 可指定部分取貨（拆行）。'
  '到貨擋板為品項層級（is_order_item_pickup_ready）：未到貨品項個別擋、已到貨可先取。';

GRANT EXECUTE ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) TO authenticated;

-- ----------------------------------------------------------------
-- 4. v_order_item_pickup_ready — UI 顯示品項到貨狀態
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_order_item_pickup_ready AS
SELECT
  coi.id AS item_id,
  coi.order_id,
  coi.tenant_id,
  public.is_order_item_pickup_ready(coi.id) AS pickup_ready
FROM customer_order_items coi;

GRANT SELECT ON public.v_order_item_pickup_ready TO authenticated;

COMMENT ON VIEW public.v_order_item_pickup_ready IS
  '品項可取貨判斷 view（item_id, order_id, pickup_ready），UI 取貨頁/對話框顯示哪些品項已到貨可取';

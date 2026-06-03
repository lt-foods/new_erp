-- ============================================================
-- 2026-07-03: 修「收貨短收 / 跨團誤判 → 訂單仍可取貨」
--
-- 回報案例：
--   訂單 GRP-20260531-002-0005 (id=17768, campaign 2205, 松山店 store 51) 的
--   G00123-05 (sku 1029)：在 WAVE-9-S51 (transfer 28) 收貨時短收 (qty_shipped=1,
--   qty_received=0)，物理上沒進該店；該訂單的團 (campaign 2205) 對應的波次
--   WAVE-11 generated_transfer_id 還是 NULL（根本沒出貨）。但訂單卻是 status='ready'、
--   可取貨。
--
-- 根因（兩層）：
--   1. rpc_receive_transfer 邏輯 C：收到任一 hq_to_store 波次時，把該分店
--      *所有* status='shipping' 的訂單無條件設成 'ready'，完全不檢查各訂單的
--      SKU 是否依「該訂單的團」實際到貨。store 51 收到的是 campaign 956 的
--      WAVE-9/10，卻把 campaign 2205 的 7 張訂單一起設成 ready。
--   2. is_order_pickup_ready 在 20260629000030 被簡化成只看 status='ready'
--      （thin alias），原本 20260614000040 的「逐項 campaign+store+sku 必須有
--      received 波次」嚴格檢查（安全網）被拿掉，於是 rpc_record_pickup 也擋不住。
--      且舊嚴格版只檢查 transfer 是否 received、沒檢查該 line 的 qty_received>0，
--      仍擋不住「收到但該項短收 0」。
--
-- 修法：
--   A. is_order_pickup_ready 改回嚴格、且 shortage-aware：
--      - Path A：aid 單 transfer FK 收貨（aid 跨店只認 Path A，沿用 20260629000020）。
--      - Path B：每個 active item 的 (campaign, store, sku) 有對齊波次且該 line
--        qty_received>0（用 generated_transfer_id 直連 transfer）。
--      - Path C：僅當該 (campaign, store, sku) *完全沒有* 對齊波次（純彙整 PR，
--        wave_items.campaign_id=MIN(camp) 對不上非 MIN 團，見 20260615000010）時，
--        才退而用 store+sku 的 received 且 qty_received>0 判定。
--        → 這樣「有對齊波次但還沒出貨/短收」(本案 campaign 2205) 不會走 Path C
--          被誤放；而真正的彙整 PR 仍保留可取貨。
--      - 必須仍有 active item 才可能 ready。
--   B. rpc_receive_transfer 邏輯 C：把 `WHERE status='shipping'` 改成
--      `WHERE status='shipping' AND public.is_order_pickup_ready(co.id)`，
--      只推「依該訂單的團真的到齊」的訂單。其餘邏輯 (A 自動 ship 下一段、
--      B aid FK 直推) 不動。
--   C. Backfill：把目前 status='ready' 但新嚴格版 is_order_pickup_ready=false 的
--      訂單退回 'shipping'、清 ready_at，並寫 audit log。
--      （partially_completed 已部分取貨、不可逆，不動。）
--
-- 基底版本：
--   - is_order_pickup_ready：20260630000040（= 20260630000020，thin alias 最新版）。
--   - rpc_receive_transfer：20260511000003_pickup_requires_store_receipt.sql（線上現行版，
--     本檔逐字複製後僅改邏輯 C）。
-- Rollback：
--   - is_order_pickup_ready：CREATE OR REPLACE 回 20260630000040 版本。
--   - rpc_receive_transfer：CREATE OR REPLACE 回 20260511000003 版本（邏輯 C 改回無條件
--     UPDATE status='shipping'）。
--   - 被 backfill 退回 shipping 的訂單，可依本 migration 的 NOTICE 數量人工檢視。
-- ============================================================

-- ----------------------------------------------------------------
-- A. is_order_pickup_ready — 嚴格 + shortage-aware (Path A/B/C)
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
       AND CASE
         -- aid_transfer + 跨店：只認自己的 transfer 被收貨 (Path A)
         WHEN EXISTS (
                SELECT 1 FROM customer_order_items coi
                 WHERE coi.order_id = co.id AND coi.source = 'aid_transfer'
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
           -- Path B/C（逐 active item，shortage-aware）：每項 SKU 都要實際到貨
           NOT EXISTS (
             SELECT 1
               FROM customer_order_items coi
              WHERE coi.order_id = co.id
                AND coi.status IN ('pending','reserved','ready')
                AND NOT (
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
           )
         )
       END
  );
$function$;

COMMENT ON FUNCTION public.is_order_pickup_ready(bigint) IS
  '訂單是否可取貨（嚴格、shortage-aware）：每個 active item 的 SKU 都要依「該訂單的團」'
  '實際到貨 (Path B：campaign 對齊波次 qty_received>0)；僅當無對齊波次（彙整 PR）才退用 '
  'store+sku 實收 (Path C)；aid 單走 transfer FK (Path A)。修 20260629000030 thin-alias '
  '把安全網拿掉導致跨團/短收訂單誤判可取貨。';

-- ----------------------------------------------------------------
-- B. rpc_receive_transfer — 邏輯 C 改成只推「真的到齊」的訂單
--    （以下為 20260511000003 線上版逐字複製，僅邏輯 C 的 UPDATE WHERE 加守衛）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(p_transfer_id bigint, p_lines jsonb, p_operator uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id            UUID;
  v_status               TEXT;
  v_transfer_type        TEXT;
  v_dest_location        BIGINT;
  v_existing_notes       TEXT;
  v_customer_order_id    BIGINT;
  v_next_transfer_id     BIGINT;
  v_item                 RECORD;
  v_qty_received         NUMERIC;
  v_unit_cost            NUMERIC;
  v_in_mov_id            BIGINT;
  v_total_qty            NUMERIC := 0;
  v_total_variance       NUMERIC := 0;
  v_items_received       INTEGER := 0;
  v_lines_consumed       INTEGER := 0;
  v_lines_count          INTEGER;
  v_orders_advanced      INTEGER := 0;
  v_next_shipped         BOOLEAN := FALSE;
  v_leg2                 transfers%ROWTYPE;
  v_leg2_item            RECORD;
  v_leg2_mov             BIGINT;
  v_dest_store_id        BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is in status %, expected shipped', p_transfer_id, v_status;
  END IF;

  IF p_lines IS NOT NULL THEN
    v_lines_count := jsonb_array_length(p_lines);
    IF EXISTS (
      SELECT 1
        FROM jsonb_array_elements(p_lines) AS l
        LEFT JOIN transfer_items ti
          ON ti.id = (l->>'transfer_item_id')::BIGINT
         AND ti.transfer_id = p_transfer_id
       WHERE ti.id IS NULL
    ) THEN
      RAISE EXCEPTION 'p_lines contains transfer_item_id not belonging to transfer %', p_transfer_id;
    END IF;
  END IF;

  -- ===== 原有邏輯：寫 qty_received + dest_location inbound =====
  FOR v_item IN
    SELECT ti.id, ti.sku_id, ti.qty_shipped, sm.unit_cost AS out_cost
      FROM transfer_items ti
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE ti.transfer_id = p_transfer_id
     ORDER BY ti.id
  LOOP
    v_qty_received := v_item.qty_shipped;

    IF p_lines IS NOT NULL THEN
      SELECT (l->>'qty_received')::NUMERIC
        INTO v_qty_received
        FROM jsonb_array_elements(p_lines) AS l
       WHERE (l->>'transfer_item_id')::BIGINT = v_item.id
       LIMIT 1;

      IF FOUND THEN
        v_lines_consumed := v_lines_consumed + 1;
      ELSE
        v_qty_received := v_item.qty_shipped;
      END IF;
    END IF;

    IF v_qty_received IS NULL OR v_qty_received < 0 THEN
      RAISE EXCEPTION 'transfer_item % qty_received must be >= 0, got %', v_item.id, v_qty_received;
    END IF;
    IF v_qty_received > v_item.qty_shipped THEN
      RAISE EXCEPTION 'transfer_item % over-receipt: qty_received=% > qty_shipped=%',
        v_item.id, v_qty_received, v_item.qty_shipped;
    END IF;

    IF v_qty_received > 0 THEN
      v_unit_cost := COALESCE(ABS(v_item.out_cost), 0);

      v_in_mov_id := rpc_inbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_dest_location,
        p_sku_id          => v_item.sku_id,
        p_quantity        => v_qty_received,
        p_unit_cost       => v_unit_cost,
        p_movement_type   => 'transfer_in',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );

      UPDATE transfer_items
         SET qty_received   = v_qty_received,
             in_movement_id = v_in_mov_id,
             updated_by     = p_operator
       WHERE id = v_item.id;
    ELSE
      UPDATE transfer_items
         SET qty_received = 0,
             updated_by   = p_operator
       WHERE id = v_item.id;
    END IF;

    v_total_qty      := v_total_qty + v_qty_received;
    v_total_variance := v_total_variance + (v_qty_received - v_item.qty_shipped);
    v_items_received := v_items_received + 1;
  END LOOP;

  UPDATE transfers
     SET status      = 'received',
         received_by = p_operator,
         received_at = NOW(),
         notes       = CASE
                         WHEN p_notes IS NULL OR p_notes = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN p_notes
                         ELSE v_existing_notes || E'\n' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- ===== 邏輯 A：自動 ship 下一段（aid chain B 模型）=====
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_leg2 FROM transfers
     WHERE id = v_next_transfer_id FOR UPDATE;

    IF v_leg2.id IS NOT NULL AND v_leg2.status = 'draft' THEN
      FOR v_leg2_item IN
        SELECT ti.id AS leg2_item_id, ti.sku_id, ti2.qty_received
          FROM transfer_items ti
          JOIN transfer_items ti2
            ON ti2.transfer_id = p_transfer_id AND ti2.sku_id = ti.sku_id
         WHERE ti.transfer_id = v_leg2.id
      LOOP
        IF v_leg2_item.qty_received > 0 THEN
          v_leg2_mov := rpc_outbound(
            p_tenant_id       => v_leg2.tenant_id,
            p_location_id     => v_leg2.source_location,
            p_sku_id          => v_leg2_item.sku_id,
            p_quantity        => v_leg2_item.qty_received,
            p_movement_type   => 'transfer_out',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_leg2.id,
            p_operator        => p_operator
          );
          UPDATE transfer_items
             SET qty_shipped     = v_leg2_item.qty_received,
                 qty_requested   = v_leg2_item.qty_received,
                 out_movement_id = v_leg2_mov,
                 updated_by      = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        ELSE
          UPDATE transfer_items
             SET qty_shipped   = 0,
                 qty_requested = 0,
                 updated_by    = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        END IF;
      END LOOP;

      UPDATE transfers
         SET status      = 'shipped',
             shipped_by  = p_operator,
             shipped_at  = NOW(),
             updated_by  = p_operator
       WHERE id = v_leg2.id;
      v_next_shipped := TRUE;
    END IF;
  END IF;

  -- ===== 邏輯 B：aid 單 FK 直接推 customer_order → ready =====
  IF v_customer_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = NOW(),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_customer_order_id
       AND status = 'shipping';
    GET DIAGNOSTICS v_orders_advanced = ROW_COUNT;

  -- ===== 邏輯 C：hq_to_store wave transfer → 推該分店訂單 → ready =====
  -- 修：不再無條件推該店「所有」shipping 訂單；改成只推
  --     is_order_pickup_ready=true（依該訂單的團真的到齊、shortage-aware）的訂單，
  --     避免收到別團波次時把尚未出貨的團一起誤標為可取貨。
  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      WITH advanced AS (
        UPDATE customer_orders co
           SET status     = 'ready',
               ready_at   = NOW(),
               updated_by = p_operator,
               updated_at = NOW()
         WHERE co.tenant_id      = v_tenant_id
           AND co.pickup_store_id = v_dest_store_id
           AND co.status          = 'shipping'
           AND public.is_order_pickup_ready(co.id)
        RETURNING co.id
      )
      SELECT COUNT(*) INTO v_orders_advanced FROM advanced;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped
  );
END;
$function$;

-- ----------------------------------------------------------------
-- C. Backfill：把目前 status='ready' 但嚴格版 pickup_ready=false 的訂單退回 shipping
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_uid       UUID;
  v_rec       RECORD;
  v_reverted  INTEGER := 0;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  FOR v_rec IN
    SELECT co.id
      FROM customer_orders co
     WHERE co.status = 'ready'
       AND NOT public.is_order_pickup_ready(co.id)
  LOOP
    UPDATE customer_orders
       SET status     = 'shipping',
           ready_at   = NULL,
           updated_by = v_uid,
           updated_at = NOW()
     WHERE id = v_rec.id;

    PERFORM rpc_log_order_status_change(
      v_rec.id, 'ready', 'shipping', v_uid,
      '修正：收貨時被 logic C 無條件設為 ready，但該訂單的團尚未實際到貨（或該項短收）；退回 shipping'
    );
    v_reverted := v_reverted + 1;
  END LOOP;

  RAISE NOTICE 'Backfill: reverted % orders ready->shipping (logic C 跨團/短收誤判)', v_reverted;
END $$;

-- ============================================================
-- 2026-06-30: rpc_record_pickup 支援「依數量分批取貨」（拆行法）
--
-- 需求：一個品項訂 10 個，這次只取 3 個、剩 7 個留著下次再取。
--
-- 設計（拆行 split-line）：
--   取部分數量時，把原品項行拆成兩行——
--     · 新建一行 qty=已取數量、status='picked_up'（連動 stock_movement）
--     · 原行 qty 扣掉已取數量、狀態保持 active（pending/reserved/ready）留待下次
--   整行取（take = qty）時完全沿用舊邏輯，零行為變化。
--
--   優點：拆完每一行仍是「整取」語義，所以收據(print)、小白單(print-list)、
--   退貨(rpc_create_order_return)、金額 view 全都不用改——它們看的是「行」，
--   而每行 qty 已經是正確的已取/待取數量。
--
-- 介面變更：新增可選參數 p_item_qtys jsonb = {"<item_id>": <取貨數量>, ...}。
--   未列入或值 >= 該品項 qty 者視為整行取。舊 caller（不傳 p_item_qtys）
--   行為完全不變。
--   ⚠️ 因為加參數會改 signature，先 DROP 舊的 4-arg 版再建 5-arg 版，
--      避免 PostgREST 重載歧義；末尾重新 GRANT。
--
-- 基底版本：20260614000030_fix_pickup_stock_movement.sql 的 rpc_record_pickup
--   （已 dump 線上確認一致；含 stock_movement 扣帳 + pickup_movement_id 回填）。
-- Rollback：DROP FUNCTION rpc_record_pickup(bigint,bigint[],uuid,text,jsonb);
--   再 CREATE OR REPLACE 回 20260614000030 的 4-arg 版本即可。
--   （拆出來的 picked_up 行與其 stock_movement 是正常取貨資料、不需回收。）
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_record_pickup(bigint, bigint[], uuid, text);

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

  IF NOT public.is_order_pickup_ready(p_order_id) THEN
    RAISE EXCEPTION '訂單 % 對應的分店尚未確認收到出倉單，無法取貨', p_order_id;
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
  '取貨記帳。p_item_qtys={"<item_id>":<取貨數量>} 可指定部分取貨：拆行——'
  '新建 picked_up 行(該數量)、原行扣量留待下次。未指定者整行取(沿用舊邏輯)。';

GRANT EXECUTE ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) TO authenticated;

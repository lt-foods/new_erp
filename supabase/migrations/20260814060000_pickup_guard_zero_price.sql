-- ============================================================================
-- 2026-08-14: 取貨加「0 元售價守衛」— 一般客人訂單的 0 元品項不可取貨
--
-- 災情：開團設定價本身是 0（campaign_items.unit_price = 0），客人下單照抄 0 元。
--   出貨鏈（開團→請購單→採購單→收貨→撿貨波次→transfer→分店→取貨）每一關判斷的
--   都是「數量」與「訂單狀態」，unit_price 從不參與 → 一路放行到取貨，等於把貨
--   免費送出去。資料庫層原本只有 CHECK (unit_price >= 0)
--   （20260423120000_stores_order_schema.sql:126），0 是合法值、全庫沒有一處對 0 拋錯。
--   請購單的送審驗價（purchase/requests/edit/page.tsx）驗的是 purchase_request_items
--   的進貨端價格，跟客人付的 campaign_items.unit_price 是兩套欄位，攔不到。
--   2026-08-14 實際三團中招：GRP-20260814-001 屏東手工水餃 24 筆（100%）、
--   GRP-20260720-004 洋車前子 34 筆（76%）、GRP-20260806-003 日本零食 54 筆，
--   靠人工與「重新同步商品/價格」批次回填救回（customer_order_audit_log 留有
--   before_value=0.0000 → after_value=209.0000 的紀錄）。
--
-- 守衛規則：品項迴圈內，COALESCE(v_item.unit_price, 0) = 0
--   且 COALESCE(v_order.order_kind, 'normal') = 'normal' → raise 'zero_price: …'。
--   v_item.unit_price 來自迴圈既有的 SELECT、v_order 是 customer_orders%ROWTYPE
--   且以 SELECT * 取得，兩者都是現成的，未更動任何既有查詢。
--   放在「品項狀態不可取貨」之後、「分店尚未實收到貨」之前。
--
-- 為什麼放行 restock / offset（誤擋會讓內部流程整條掛掉）：
--   order_kind 合法值只有 normal / offset / restock
--   （20260612000020_restock_creates_customer_order.sql:19）。
--   · restock：內部補貨申請，掛 sentinel 團 __INTERNAL_RESTOCK__、虛擬 SKU MISC-01，
--     建單時單價就是 0（20260612000020:37、20260515000000:73）—— 設計上就是 0 元。
--   · offset ：抵減單（負數訂單，20260516000000_allow_negative_order_qty.sql:20）
--     —— 設計上也是 0 元。
--   這兩類擋掉會讓內部補貨與抵減單無法取貨，故只擋 normal。
--
-- 基底：20260813000000_pickup_store_guard.sql 的 rpc_record_pickup **全文逐字複製**
--   （該支是最新版；其後的 migration 只引用未再改寫這支 —— 20260814020000 改的是
--   is_order_item_pickup_ready）。店家守衛、退貨守門、部分取貨拆行、active_remaining
--   等既有邏輯全數原樣保留，本檔只多出上述守衛。
-- Rollback：重跑 20260813000000_pickup_store_guard.sql（即移除本守衛，其餘不變）。
-- ============================================================================
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
  v_ret_guard        RECORD;
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
  -- 店家守衛（2026-08-13）
  v_jwt_role          TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores         JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_pickup_store_name TEXT;
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

  -- 店家守衛：分店角色只能替「自己店」的訂單取貨。庫存跟著 pickup_store_id
  -- 的 location 扣，跨店按取貨會扣到別店的帳、客人也拿不到貨。
  -- stores 為空（未設定的 legacy 帳號）或含「總倉」不鎖，對齊前端判定。
  IF v_jwt_role IN ('store_manager','store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉') THEN
    SELECT s.name INTO v_pickup_store_name
      FROM stores s
     WHERE s.id = v_order.pickup_store_id
       AND s.tenant_id = v_order.tenant_id;
    IF v_pickup_store_name IS NULL OR NOT (v_my_stores ? v_pickup_store_name) THEN
      RAISE EXCEPTION 'wrong_store: 此訂單的取貨店是「%」，分店帳號只能替自己店的訂單取貨，請由該店操作或先轉單',
        COALESCE(v_pickup_store_name, '未設定');
    END IF;
  END IF;

  SELECT location_id INTO v_pickup_loc
    FROM stores
   WHERE id = v_order.pickup_store_id;

  IF v_pickup_loc IS NULL THEN
    RAISE EXCEPTION '分店 % 未設定倉庫位置 (location_id)、無法寫 stock_movement', v_order.pickup_store_id;
  END IF;

  -- 退貨守門：同 SKU「本次取貨量」不得超過「active 品項量 − 未取退貨量」。
  -- 未取退貨（return_to_hq、notes header 不含 |取貨後退回）的貨已離店，
  -- 不能再被結帳；取貨後退回不計入（那批貨的錢在取貨時已收）。
  -- 前端 PickupDialog 有同款防線，但畫面 stale 時會失效，這裡是最後防線。
  FOR v_ret_guard IN
    SELECT r.sku_id, r.ret_qty,
           COALESCE(act.active_qty, 0) AS active_qty,
           COALESCE(req.take_qty, 0)   AS take_qty
      FROM (
        SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.customer_order_id = p_order_id
           AND t.tenant_id     = v_order.tenant_id
           AND t.transfer_type = 'return_to_hq'
           AND t.status IN ('shipped','received')
           AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
               NOT LIKE '%取貨後退回%'
         GROUP BY ti.sku_id
      ) r
      LEFT JOIN (
        SELECT coi.sku_id, SUM(coi.qty) AS active_qty
          FROM customer_order_items coi
         WHERE coi.order_id = p_order_id
           AND coi.status IN ('pending','reserved','ready')
         GROUP BY coi.sku_id
      ) act ON act.sku_id = r.sku_id
      LEFT JOIN (
        -- 本次各 SKU 取貨量（缺項＝整行取；clamp 到行量，超量交給主迴圈報錯）
        SELECT coi.sku_id,
               SUM(LEAST(COALESCE((p_item_qtys ->> coi.id::text)::numeric, coi.qty), coi.qty)) AS take_qty
          FROM customer_order_items coi
         WHERE coi.id = ANY(p_item_ids)
           AND coi.order_id = p_order_id
         GROUP BY coi.sku_id
      ) req ON req.sku_id = r.sku_id
     WHERE COALESCE(req.take_qty, 0) > COALESCE(act.active_qty, 0) - r.ret_qty
  LOOP
    SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
      INTO v_sku_label FROM skus s WHERE s.id = v_ret_guard.sku_id;
    RAISE EXCEPTION '品項「%」已退貨 % 件，本次最多可取 % 件（畫面資料可能過舊，請重新整理後再取）',
      COALESCE(v_sku_label, v_ret_guard.sku_id::text),
      v_ret_guard.ret_qty,
      GREATEST(v_ret_guard.active_qty - v_ret_guard.ret_qty, 0);
  END LOOP;

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

    -- 0 元防呆（2026-08-14）：一般客人訂單的品項單價是 0 = 開團沒設價，
    -- 取貨等於把貨免費送出去。restock（內部補貨，掛虛擬 SKU MISC-01）與
    -- offset（抵減負數單）設計上本來就是 0 元，放行不擋。
    IF COALESCE(v_item.unit_price, 0) = 0
       AND COALESCE(v_order.order_kind, 'normal') = 'normal' THEN
      RAISE EXCEPTION
        'zero_price: 品項「%」單價是 0 元，不可取貨。請先到開團頁補上售價（可用「重新同步商品/價格」批次回填），補完再取。',
        v_item.id;
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

  -- 重算 order status（剩餘 active 行 → partially_completed；全取完 → completed）。
  -- 2026-08-01：剩餘 active 量要扣掉「未取退貨」覆蓋 — 已退回總倉的量不會再被
  -- 取走，若某 SKU 的 active 量全被退貨蓋掉，該 SKU 的殘行不算「待取」。
  -- 否則部分退貨後取走剩餘可取量（訂5退2取3）會讓訂單永遠卡在 partially_completed。
  SELECT COUNT(*) INTO v_active_remaining
    FROM customer_order_items coi
    JOIN (
      SELECT act.sku_id
        FROM (
          SELECT sku_id, SUM(qty) AS active_qty
            FROM customer_order_items
           WHERE order_id = p_order_id
             AND status IN ('pending','reserved','ready')
           GROUP BY sku_id
        ) act
        LEFT JOIN (
          SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
            FROM transfers t
            JOIN transfer_items ti ON ti.transfer_id = t.id
           WHERE t.customer_order_id = p_order_id
             AND t.tenant_id     = v_order.tenant_id
             AND t.transfer_type = 'return_to_hq'
             AND t.status IN ('shipped','received')
             AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
                 NOT LIKE '%取貨後退回%'
           GROUP BY ti.sku_id
        ) r ON r.sku_id = act.sku_id
       WHERE act.active_qty - COALESCE(r.ret_qty, 0) > 0
    ) open_sku ON open_sku.sku_id = coi.sku_id
   WHERE coi.order_id = p_order_id
     AND coi.status IN ('pending','reserved','ready');

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
  '到貨擋板為品項層級（is_order_item_pickup_ready）：未到貨品項個別擋、已到貨可先取。'
  '退貨守門：同 SKU 取貨量不得超過 active 量 − 未取退貨量（取貨後退回不計）。'
  'active_remaining 排除量已被未取退貨覆蓋的 SKU（退光的殘行不擋 completed）。'
  '店家守衛：分店角色（store_manager/store_staff，app_metadata.stores 非空且不含總倉）'
  '只能替自己店（pickup_store_id 店名 ∈ stores）的訂單取貨，否則 raise wrong_store。'
  '0 元守衛：order_kind=normal 且品項 unit_price=0 → raise zero_price（restock/offset 放行）。';

GRANT EXECUTE ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) TO authenticated;

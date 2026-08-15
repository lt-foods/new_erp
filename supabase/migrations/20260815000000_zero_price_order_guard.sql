-- ============================================================================
-- 2026-08-15: $0 品項（漏填金額）— 訂單頁標示 + 取貨擋下 + 分店可補填
--
-- 需求：「訂單頁上面顯示現在有哪些訂單是 0 元，提醒店家漏填金額了，並在要取貨
--        的時候擋下裡面有零元品項的訂單」。
--
-- 現況（線上實測 2026-08-15）：
--   customer_order_items.unit_price = 0 且 status 未取消 → 233 列 / 194 張單。
--   其中 111 列已經 picked_up（貨白送了），96 列還在 confirmed/ready/shipping
--   等著被取走。來源 228 列是 source='manual'（小幫手代 key），notes 全為 NULL
--   —— 沒有任何一列是「刻意的贈品」，全部是開團時 campaign_items.unit_price
--   漏填（線上 45 個 campaign_item 單價是 0，含 8/17 才結單的進行中團）。
--
--   例外只有一種：members.member_type = 'store_internal' 的 RR- /【內部】xx 店
--   /OV- 容器單。那是店端現貨池的掛帳帳本，`_grow_internal_pool` 找不到
--   branch/retail 價時本來就會寫 0（見 20260814010000），轉單給真會員時
--   `rpc_transfer_order_partial` 會改鎖當下現售價 → 池子的 0 不會流到客人身上。
--   本次三段程式一律排除它，否則現貨池會整批被標紅 + 擋住。
--
-- 本次三段：
--   1. v_admin_orders_list + zero_price_lines（/orders 列表的紅標與「只看 $0」
--      伺服端篩選都靠它；PostgREST 直接 .gt("zero_price_lines", 0)）
--   2. rpc_record_pickup 加零元守衛 —— 取貨＝收錢，$0 收不到錢，擋在扣庫存之前
--   3. rpc_fill_zero_order_item_price —— 分店把 0 補成正數的唯一入口
--
-- ⚠ 為什麼一定要有第 3 段（CLAUDE.md「拿掉入口前先確認有人推得動」）：
--   改單價的 rpc_update_order_item_price 走 _check_order_edit_perm，它認的是
--   app_metadata.store_id，而線上 33 個分店帳號一個都沒有 store_id（店歸屬存在
--   app_metadata.stores 店名陣列，見 20260808000020）→ 店長/店員改單價一律
--   permission denied，前端 OrderDetail 的 canEdit 也只放 HQ / 總倉。
--   只加第 2 段的話，櫃台會變成「客人站在面前、按鈕按不下去、自己又改不了價」，
--   只能打電話找總部 —— 或更糟，改走轉單開一張新單（重複單）。
--   所以另開一支窄口徑 RPC：只能 0 → 正數、只能動未取品項，權限沿用備註那套
--   （_check_order_edit_notes_perm：HQ / 總倉 / 自店），不等於開放改價。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   - v_admin_orders_list：20260808000010_payable_exclude_cancelled_items.sql
--     （逐字保留，只在 LATERAL 加一個 count FILTER + 外層加一個 CASE 欄）
--   - rpc_record_pickup：20260813000000_pickup_store_guard.sql
--     （逐字保留，只在店家守衛後面插入零元守衛）
--
-- Rollback：
--   - 重跑 20260808000010 的 v_admin_orders_list 段落（少一欄，前端 .gt 會 400，
--     要連同前端一起回退）
--   - 重跑 20260813000000 的 rpc_record_pickup 段落（移除零元守衛）
--   - DROP FUNCTION public.rpc_fill_zero_order_item_price(BIGINT,BIGINT,NUMERIC,UUID,TEXT)
--
-- 對應前端（同一個 commit）：
--   - apps/admin/src/app/(protected)/orders/page.tsx（$0 提示條 + 只看 $0 篩選 + 列上紅標）
--   - apps/admin/src/app/(protected)/pickup/page.tsx（擋下取貨 + 櫃台補填金額）
--   - apps/admin/src/components/PickupDialog.tsx（$0 品項不可勾）
--   - apps/admin/src/lib/rpcError.ts（zero_price: 前綴中文化）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. v_admin_orders_list v3 — 加 zero_price_lines（$0 品項行數）
--    基底 20260808000010 逐字保留，只多一個彙總欄
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_admin_orders_list;

CREATE VIEW v_admin_orders_list
WITH (security_invoker = true) AS
SELECT
  o.*,
  c.name AS campaign_name,
  COALESCE(m.name, o.nickname_snapshot) AS member_name,
  s.name AS store_name,
  agg.line_count,
  agg.total_qty,
  agg.total_amount,
  agg.source_summary,
  -- 20260815000000：$0 品項行數（可能漏填金額）。store_internal 的容器單一律 0
  -- —— 池子單價本來就可能是 0，標紅只會製造雜訊（見檔頭）。
  CASE WHEN COALESCE(m.member_type, '') = 'store_internal' THEN 0
       ELSE agg.zero_price_lines END       AS zero_price_lines
FROM v_admin_orders o
LEFT JOIN group_buy_campaigns c ON c.id = o.campaign_id
LEFT JOIN members m ON m.id = o.member_id
LEFT JOIN stores s ON s.id = o.pickup_store_id
LEFT JOIN LATERAL (
  SELECT
    count(*)::int                          AS line_count,
    COALESCE(sum(i.qty), 0)                AS total_qty,
    COALESCE(sum(i.qty * i.unit_price), 0) AS total_amount,
    CASE WHEN count(DISTINCT i.source) > 1 THEN 'mixed'
         ELSE min(i.source) END            AS source_summary,
    count(*) FILTER (WHERE COALESCE(i.unit_price, 0) = 0)::int AS zero_price_lines
  FROM customer_order_items i
  WHERE i.order_id = o.id
    -- 20260808000010：已取消 / 斷貨的品項不算進項數 / 件數 / 金額
    AND i.status NOT IN ('cancelled','expired')
) agg ON true;

COMMENT ON VIEW v_admin_orders_list IS
  '/orders 列表查詢用：v_admin_orders + 可排序欄位（campaign_name / member_name / '
  'store_name / line_count / total_qty / total_amount / source_summary）。'
  '只給列表 + 選取全部用；tab 數量與趨勢的 rpc_order_overview 維持查 v_admin_orders，'
  '避免整表聚合時多揹 per-row 品項彙總。'
  '20260808000010：彙總排除 cancelled/expired 品項，與訂單明細的應收同一套語意。'
  '20260815000000：zero_price_lines = 單價 $0 的品項行數（漏填金額提示 / 「只看 $0」'
  '伺服端篩選）；store_internal 容器單恆為 0。';

GRANT SELECT ON v_admin_orders_list TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. rpc_record_pickup — 加零元守衛
--    基底 20260813000000 逐字保留，只在店家守衛之後插入零元守衛
-- ----------------------------------------------------------------------------

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
  -- 零元守衛（2026-08-15）
  v_is_internal_pool  BOOLEAN;
  v_zero_labels       TEXT[] := ARRAY[]::TEXT[];
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

  -- 零元守衛（2026-08-15）：本次要取的品項若單價是 $0，代表開團 / 代 key 時
  -- 漏填金額 —— 取貨就是收錢的那一刻，放行等於把貨白送出去（線上已經這樣送掉
  -- 111 列）。擋在扣庫存之前，補填金額後即可重取。
  -- 例外：【內部】xx 店 / RR- / OV- 容器單（member_type='store_internal'）的
  -- 池子單價本來就可能是 0，不是漏填。
  SELECT EXISTS (
    SELECT 1 FROM members mb
     WHERE mb.id = v_order.member_id
       AND mb.tenant_id = v_order.tenant_id
       AND mb.member_type = 'store_internal'
  ) INTO v_is_internal_pool;

  IF NOT v_is_internal_pool THEN
    SELECT array_agg(COALESCE(sk.variant_name, sk.product_name, sk.sku_code, coi.id::text)
                     ORDER BY coi.id)
      INTO v_zero_labels
      FROM customer_order_items coi
      LEFT JOIN skus sk ON sk.id = coi.sku_id
     WHERE coi.id = ANY(p_item_ids)
       AND coi.order_id = p_order_id
       AND coi.status IN ('pending','reserved','ready')
       AND COALESCE(coi.unit_price, 0) = 0;

    IF v_zero_labels IS NOT NULL AND array_length(v_zero_labels, 1) > 0 THEN
      RAISE EXCEPTION 'zero_price: 品項「%」的單價是 $0，看起來是開團時漏填金額。請先補上金額再取貨（取貨頁該品項旁可直接補填，或到訂單明細改單價）',
        array_to_string(v_zero_labels, '」、「');
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
  '零元守衛（20260815000000）：本次要取的品項單價為 $0 一律 raise zero_price'
  '（漏填金額 → 取貨等於白送）；member_type=store_internal 的容器單不受限。';

GRANT EXECUTE ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) TO authenticated;

-- ----------------------------------------------------------------------------
-- 3. rpc_fill_zero_order_item_price — 補填漏填的金額（櫃台可用）
--    刻意不是「改價」：只允許 0 → 正數、只允許未取品項，
--    所以權限可以放到自店（沿用備註那套 _check_order_edit_notes_perm）。
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_fill_zero_order_item_price(
  p_order_id       BIGINT,
  p_item_id        BIGINT,
  p_new_unit_price NUMERIC,
  p_operator       UUID,
  p_reason         TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order  customer_orders%ROWTYPE;
  v_old    NUMERIC;
  v_status TEXT;
  v_row    customer_order_items;
BEGIN
  -- HQ / 總倉 / 該訂單取貨店（app_metadata.stores 店名比對）
  v_order := public._check_order_edit_notes_perm(p_order_id);

  IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
    RAISE EXCEPTION 'zero_price_fill: 補填金額必須大於 0';
  END IF;

  SELECT unit_price, status INTO v_old, v_status
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'zero_price_fill: 品項 % 不屬於訂單 %', p_item_id, p_order_id;
  END IF;

  -- 只補填、不改價：非 0 的單價要改一律走 rpc_update_order_item_price（HQ 權限）
  IF COALESCE(v_old, 0) <> 0 THEN
    RAISE EXCEPTION 'zero_price_fill: 此品項單價已是 $%，補填功能只處理 $0 的品項；要改價請洽總部',
      v_old;
  END IF;

  -- 已取貨 / 已取消的行不補（那是事後改帳，金額已進收據 / 已結案）
  IF v_status NOT IN ('pending','reserved','ready') THEN
    RAISE EXCEPTION 'zero_price_fill: 品項狀態為「%」，只有未取貨的品項可以補填金額', v_status;
  END IF;

  UPDATE customer_order_items
     SET unit_price = p_new_unit_price,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'unit_price',
     to_jsonb(v_old), to_jsonb(p_new_unit_price),
     COALESCE(NULLIF(p_reason, ''), '補填漏填金額（取貨零元守衛）'), p_operator);

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.rpc_fill_zero_order_item_price(BIGINT, BIGINT, NUMERIC, UUID, TEXT) IS
  '補填漏填的品項金額：只允許 unit_price 0 → 正數、只允許未取貨品項。'
  '權限沿用 _check_order_edit_notes_perm（HQ / 總倉 / 自店），讓櫃台被零元守衛擋下時'
  '自己就能解，不必回頭找總部（分店帳號沒有 app_metadata.store_id，走不了'
  'rpc_update_order_item_price 的 _check_order_edit_perm）。每次寫一筆 audit log。';

GRANT EXECUTE ON FUNCTION public.rpc_fill_zero_order_item_price(BIGINT, BIGINT, NUMERIC, UUID, TEXT)
  TO authenticated;

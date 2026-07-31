-- ============================================================
-- 2026-07-31: 未取退貨要從應收扣掉 + 取貨結帳擋「已退貨量」
--
-- 回報案例（訂單 GRP-20260625-018-0015, id=37713）：
--   店端 17:12 對未取貨品項建破損退貨 TR2607310348（1 件、$199），
--   17:14 從「取貨前就開著」的取貨視窗結帳 → 前端退貨可取量防線因
--   stale 資料失效，rpc_record_pickup 後端無任何退貨檢查，6 件全標
--   picked_up、按 $1194 收款；退掉 1 件後應收 $995。事後訂單明細
--   應收也永遠顯示 $1194（v_customer_order_summary / rpc_wallet_pay_order /
--   admin OrderDetail 的 items_total 全部不看 return_to_hq transfer）。
--
-- 兩層修法：
--   1. 應收扣「未取退貨」：payable = (items_total − returned_deduction)
--        × (1−pct) + shipping − discount。
--      returned_deduction 只算「取貨前退回」的退貨（transfer notes 的
--      [order return...] header 不含 |取貨後退回 tag）：
--        - 未取退貨＝貨退回總倉、客人拿不到 → 不該收錢，直接從應收扣。
--        - 取貨後退回（|取貨後退回）＝錢已在取貨時收了，退款照既有設計
--          走 rpc_wallet_partial_refund 人工處理（docs/TEST-return-scenarios.md
--          §E.8），應收不動，避免已收款訂單 balance 亂掉。
--      金額分攤：退貨單只記 SKU+量，依品項行序 (id) 把退貨量分攤到該 SKU
--      未取消品項行、以該行 unit_price 折算（與 admin PickupDialog 的
--      分攤邏輯同構）。
--   2. rpc_record_pickup 加退貨守門：本次各 SKU 取貨量 >
--      「active 品項量 − 未取退貨量」即 RAISE，擋掉 stale 畫面把已退貨
--      的貨再結帳一次（前端防線的後端對應版）。
--
-- 影響面：
--   - v_customer_order_summary：admin OrderDetail / LIFF 會員端訂單卡共用，
--     新增 returned_qty / returned_deduction 欄位（前端可顯示扣減明細）。
--   - rpc_wallet_pay_order：儲值金結帳上限同步扣未取退貨。
--   - 店↔總倉月結（settlement return_out 沖回）是另一條金流，
--     20260714000100 已處理，本次不動。
--
-- 基底版本（改寫前已 dump 線上定義比對、與下列 repo 版本一致）：
--   - v_customer_order_summary：20260702020000_stockout_propagation.sql
--     （逐字保留，僅加 ret LATERAL + returned_* 欄位 + payable/balance_due 扣減）
--   - rpc_wallet_pay_order：20260606000030_payable_round_to_integer.sql
--     （逐字保留，僅加 v_returned_deduction 計算與 v_payable 扣減）
--   - rpc_record_pickup：20260704000000_item_level_pickup_gate.sql
--     （逐字保留，僅在主迴圈前加退貨守門）
-- Rollback：
--   - v_customer_order_summary 還原為 20260702020000 版本
--   - rpc_wallet_pay_order 還原為 20260606000030 版本
--   - rpc_record_pickup 還原為 20260704000000 版本
--
-- TEST: docs/TEST-return-payable-deduction.md
-- ============================================================

-- ------------------------------------------------------------
-- 1. v_customer_order_summary v3 — 應收扣未取退貨
-- ------------------------------------------------------------

DROP VIEW IF EXISTS v_customer_order_summary;

CREATE VIEW v_customer_order_summary AS
SELECT
  co.id,
  co.tenant_id,
  co.order_no,
  co.member_id,
  co.pickup_store_id          AS store_id,
  co.campaign_id,
  co.channel_id,
  co.status,
  co.payment_status,
  co.payment_method,
  co.paid_at,
  co.shipping_method,
  co.shipping_address,
  co.shipping_phone,
  co.shipping_note,
  co.remit_amount,
  co.remit_at,
  co.remit_note,
  co.shipping_fee,
  co.discount_amount,
  co.discount_percent,
  co.wallet_paid_amount,
  co.pickup_deadline,
  co.notes,
  co.created_at,
  co.confirmed_at,
  co.shipping_at,
  co.ready_at,
  co.completed_at,
  co.cancelled_at,
  co.stockout_at,
  agg.items_total,
  ret.returned_qty,
  ret.returned_deduction,
  GREATEST(
    0,
    ROUND(
      GREATEST(0, agg.items_total - ret.returned_deduction)
        * (1 - co.discount_percent / 100)
        + co.shipping_fee
        - co.discount_amount,
      0
    )
  )                                                                            AS payable_amount,
  GREATEST(
    0,
    GREATEST(
      0,
      ROUND(
        GREATEST(0, agg.items_total - ret.returned_deduction)
          * (1 - co.discount_percent / 100)
          + co.shipping_fee
          - co.discount_amount,
        0
      )
    ) - co.wallet_paid_amount
  )                                                                            AS balance_due,
  agg.items,
  (co.status IN ('reserved','ready','partially_ready',
                 'partially_completed','shipping','completed'))                AS arrived,
  (co.confirmed_at IS NOT NULL
    OR co.status IN ('reserved','ready','partially_ready',
                     'partially_completed','shipping','completed'))            AS settled,
  (co.payment_status = 'paid')                                                 AS paid,
  (co.status IN ('shipping','completed'))                                      AS shipped,
  ('S-' || lpad(co.id::text, 8, '0')
        || '-'
        || COALESCE(s.store_short_code, 'XX'))                                 AS settlement_no,
  s.name                                                                        AS store_name,
  s.code                                                                        AS store_code,
  gbc.name                                                                      AS campaign_name,
  gbc.cover_image_url                                                           AS campaign_cover_url,
  gbc.end_at                                                                    AS campaign_end_at,
  gbc.cutoff_date                                                               AS campaign_cutoff_date
FROM customer_orders co
LEFT JOIN stores               s   ON s.id = co.pickup_store_id
LEFT JOIN group_buy_campaigns  gbc ON gbc.id = co.campaign_id
LEFT JOIN LATERAL (
  SELECT
    COALESCE(SUM(coi.qty * coi.unit_price), 0)                                 AS items_total,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',               coi.id,
          'sku_id',           coi.sku_id,
          'sku_code',         sk.sku_code,
          'product_name',     sk.product_name,
          'variant_name',     sk.variant_name,
          'campaign_item_id', coi.campaign_item_id,
          'qty',              coi.qty,
          'unit_price',       coi.unit_price,
          'subtotal',         coi.qty * coi.unit_price,
          'status',           coi.status,
          'stockout',         (coi.stockout_at IS NOT NULL),
          'notes',            coi.notes,
          'image_url',        CASE
            WHEN jsonb_typeof(p.images) = 'array' AND jsonb_array_length(p.images) > 0 THEN
              COALESCE(p.images -> 0 ->> 'url', p.images ->> 0)
            ELSE NULL
          END
        ) ORDER BY coi.id
      ),
      '[]'::jsonb
    )                                                                           AS items
  FROM customer_order_items coi
  LEFT JOIN skus     sk ON sk.id = coi.sku_id
  LEFT JOIN products p  ON p.id  = sk.product_id
  WHERE coi.order_id = co.id
) agg ON TRUE
LEFT JOIN LATERAL (
  -- 未取退貨扣減：return_to_hq（shipped/received、notes header 不含
  -- |取貨後退回）依 SKU 聚合退貨量，按品項行序 (id) 分攤到未取消品項行、
  -- 以該行 unit_price 折算金額
  SELECT
    COALESCE(SUM(a.alloc_qty), 0)                AS returned_qty,
    COALESCE(SUM(a.alloc_qty * a.unit_price), 0) AS returned_deduction
  FROM (
    SELECT
      i.unit_price,
      LEAST(i.qty, GREATEST(r.ret_qty - i.prior_qty, 0)) AS alloc_qty
    FROM (
      SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
        FROM transfers t
        JOIN transfer_items ti ON ti.transfer_id = t.id
       WHERE t.customer_order_id = co.id
         AND t.tenant_id     = co.tenant_id
         AND t.transfer_type = 'return_to_hq'
         AND t.status IN ('shipped','received')
         AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
             NOT LIKE '%取貨後退回%'
       GROUP BY ti.sku_id
    ) r
    JOIN (
      SELECT coi.sku_id, coi.qty, coi.unit_price,
             COALESCE(SUM(coi.qty) OVER (
               PARTITION BY coi.sku_id ORDER BY coi.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS prior_qty
        FROM customer_order_items coi
       WHERE coi.order_id = co.id
         AND coi.status NOT IN ('cancelled','expired')
    ) i ON i.sku_id = r.sku_id
  ) a
) ret ON TRUE;

COMMENT ON VIEW v_customer_order_summary IS
  'LIFF 顧客端共用：訂單聚合 + 品項詳細 + percent + amount 雙折扣 + 儲值金抵扣 + balance_due'
  '（應收已四捨五入到整數 NTD）+ 斷貨標記（stockout_at / items[].stockout）'
  '+ 未取退貨扣減（returned_qty / returned_deduction；取貨後退回不扣、退款走 rpc_wallet_partial_refund）';

-- ------------------------------------------------------------
-- 2. rpc_wallet_pay_order — v_payable 同步扣未取退貨
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION rpc_wallet_pay_order(
  p_order_id  BIGINT,
  p_amount    NUMERIC,
  p_operator  UUID
) RETURNS JSONB AS $$
DECLARE
  v_order              customer_orders%ROWTYPE;
  v_member_status      TEXT;
  v_items_total        NUMERIC;
  v_returned_deduction NUMERIC;
  v_payable            NUMERIC;
  v_new_wallet_paid    NUMERIC;
  v_new_balance_due    NUMERIC;
  v_ledger_id          BIGINT;
  v_paid               BOOLEAN := FALSE;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  SELECT * INTO v_order FROM customer_orders
   WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  IF v_order.status IN ('completed','picked_up','cancelled','expired','transferred_out') THEN
    RAISE EXCEPTION 'order % is %, cannot be paid by wallet', p_order_id, v_order.status;
  END IF;
  IF v_order.payment_status = 'paid' THEN
    RAISE EXCEPTION 'order % already paid', p_order_id;
  END IF;
  IF v_order.member_id IS NULL THEN
    RAISE EXCEPTION 'order % has no member', p_order_id;
  END IF;

  SELECT status INTO v_member_status FROM members
   WHERE id = v_order.member_id AND tenant_id = v_order.tenant_id;
  IF v_member_status IS NULL THEN
    RAISE EXCEPTION 'member % not found', v_order.member_id;
  END IF;
  IF v_member_status <> 'active' THEN
    RAISE EXCEPTION 'member status=% cannot be charged', v_member_status;
  END IF;

  SELECT COALESCE(SUM(qty * unit_price), 0)
    INTO v_items_total
    FROM customer_order_items
   WHERE order_id = p_order_id;

  -- 未取退貨扣減（同 v_customer_order_summary 的 ret LATERAL）
  SELECT COALESCE(SUM(a.alloc_qty * a.unit_price), 0)
    INTO v_returned_deduction
    FROM (
      SELECT
        i.unit_price,
        LEAST(i.qty, GREATEST(r.ret_qty - i.prior_qty, 0)) AS alloc_qty
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
      JOIN (
        SELECT coi.sku_id, coi.qty, coi.unit_price,
               COALESCE(SUM(coi.qty) OVER (
                 PARTITION BY coi.sku_id ORDER BY coi.id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
               ), 0) AS prior_qty
          FROM customer_order_items coi
         WHERE coi.order_id = p_order_id
           AND coi.status NOT IN ('cancelled','expired')
      ) i ON i.sku_id = r.sku_id
    ) a;

  -- payable 四捨五入到整數 NTD（同 v_customer_order_summary）
  v_payable := GREATEST(
    0,
    ROUND(
      GREATEST(0, v_items_total - v_returned_deduction)
        * (1 - v_order.discount_percent / 100)
        + v_order.shipping_fee
        - v_order.discount_amount,
      0
    )
  );

  v_new_wallet_paid := v_order.wallet_paid_amount + p_amount;
  IF v_new_wallet_paid > v_payable THEN
    RAISE EXCEPTION 'wallet pay exceeds balance_due: paying=%, already_paid=%, payable=%',
      p_amount, v_order.wallet_paid_amount, v_payable;
  END IF;

  v_ledger_id := rpc_wallet_spend(
    v_order.tenant_id,
    v_order.member_id,
    p_amount,
    'customer_order',
    p_order_id,
    p_operator
  );

  v_new_balance_due := v_payable - v_new_wallet_paid;
  v_paid := (v_new_balance_due = 0);

  UPDATE customer_orders
     SET wallet_paid_amount = v_new_wallet_paid,
         payment_status = CASE WHEN v_paid THEN 'paid' ELSE payment_status END,
         paid_at        = CASE WHEN v_paid AND paid_at IS NULL THEN NOW() ELSE paid_at END,
         updated_by     = p_operator,
         updated_at     = NOW()
   WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'ledger_id',          v_ledger_id,
    'wallet_paid_amount', v_new_wallet_paid,
    'payable_amount',     v_payable,
    'balance_due',        v_new_balance_due,
    'payment_status',     CASE WHEN v_paid THEN 'paid' ELSE v_order.payment_status END,
    'paid_at',            CASE WHEN v_paid THEN COALESCE(v_order.paid_at, NOW()) ELSE v_order.paid_at END
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ------------------------------------------------------------
-- 3. rpc_record_pickup — 退貨守門（前端可取量防線的後端對應）
-- ------------------------------------------------------------

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
  '到貨擋板為品項層級（is_order_item_pickup_ready）：未到貨品項個別擋、已到貨可先取。'
  '退貨守門：同 SKU 取貨量不得超過 active 量 − 未取退貨量（取貨後退回不計）。';

GRANT EXECUTE ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) TO authenticated;

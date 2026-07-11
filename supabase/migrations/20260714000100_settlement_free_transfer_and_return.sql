-- ============================================================
-- 2026-07-12: 月結＝總倉當清算中心 — 自由轉貨兩邊記帳 + 退貨回總倉沖回
--
-- 需求（使用者）：「月結總倉要當交易所幫我們紀錄金額」。
--
-- 現況缺口（rpc_generate_hq_to_store_settlement = 20260512000012 現行版）：
--   只有三種分錄 hq_inbound / air_in / air_out，且 air 系列只認
--   customer_order_id IS NOT NULL 的 store_to_store（互助/轉手腿）。
--   1. 自由轉貨（store_to_store、無訂單 FK）完全不入帳：
--      收貨店白拿、出貨店白給，兩店之間的金額沒人記。
--   2. 退貨回總倉（transfer_type='return_to_hq'）沒有沖回：
--      店收貨時被記應付（hq_inbound），把貨退回總倉卻不退錢。
--
-- 修法：entry_type 加三種，payable 公式擴成：
--   payable = hq_inbound + air_in - air_out + free_in - free_out - return_out
--   - free_in ：自由轉貨收進（該店是 dest）  → 應付 +
--   - free_out：自由轉貨送出（該店是 source）→ 應付 −（貸記）
--   - return_out：退貨回總倉（該店是 source、總倉已收）→ 應付 −（沖回）
--
-- 金額基準：
--   - free_in / free_out：自由轉貨的行是「MISC 虛擬 SKU + 描述 + 估價」、
--     不動庫存、沒有成本分錄 → 以 transfer_items.estimated_amount（行總額）
--     入帳；估價空值以 0 計（＝該行不產生金額，店端要記帳就要填估價）。
--   - return_out：真 SKU、有出庫 movement → qty_received × 出貨當下
--     unit_cost（與 hq_inbound / air 系列同基準）。
--   兩店分錄鏡像同額，總倉純過帳（淨額 0）、只當交易所。
--
--   items 表加 description 欄：自由轉貨行只有描述沒有真 SKU，
--   月結明細沒有描述會全部顯示成 MISC 雜項。
--
-- 基底版本：rpc_generate_hq_to_store_settlement = 20260512000012（線上現行，
--   20260705000000 僅註解提及未改動）；逐字複製僅追加 D/E/F 分錄。
-- Rollback：
--   CREATE OR REPLACE 回 20260512000012 版本；
--   ALTER TABLE store_monthly_settlement_items DROP CONSTRAINT smsi_entry_type_check_v2;
--   （舊 CHECK 名 store_monthly_settlement_items_entry_type_check 需重建）；
--   description 欄可留（無害）。已生成的 draft 月結重跑生成器即回舊口徑；
--   confirmed/settled 不受影響（生成器本來就跳過）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. entry_type CHECK 擴充 + items 加 description
-- ------------------------------------------------------------
ALTER TABLE public.store_monthly_settlement_items
  DROP CONSTRAINT IF EXISTS store_monthly_settlement_items_entry_type_check;
ALTER TABLE public.store_monthly_settlement_items
  DROP CONSTRAINT IF EXISTS smsi_entry_type_check_v2;
ALTER TABLE public.store_monthly_settlement_items
  ADD CONSTRAINT smsi_entry_type_check_v2
    CHECK (entry_type IN ('hq_inbound','air_in','air_out','free_in','free_out','return_out'));

ALTER TABLE public.store_monthly_settlement_items
  ADD COLUMN IF NOT EXISTS description TEXT;

COMMENT ON COLUMN store_monthly_settlement_items.entry_type IS
  '結算明細類型：hq_inbound=從 HQ 收貨；air_in=空中轉收進；air_out=空中轉送出（負）；'
  'free_in=自由轉貨收進；free_out=自由轉貨送出（負）；return_out=退貨回總倉沖回（負）';

COMMENT ON COLUMN store_monthly_settlement_items.description IS
  '自由轉貨行的描述（MISC 虛擬 SKU 無品名可查）；真 SKU 行為 NULL';

-- ------------------------------------------------------------
-- 2. rpc_generate_hq_to_store_settlement — 加 free_in / free_out / return_out
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_generate_hq_to_store_settlement(
  p_month    DATE,
  p_operator UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant         UUID;
  v_month_start    DATE := DATE_TRUNC('month', p_month)::DATE;
  v_month_end      DATE := (DATE_TRUNC('month', p_month) + INTERVAL '1 month')::DATE;
  v_store          RECORD;
  v_settlement_id  BIGINT;
  v_hq_inbound     NUMERIC(18,4);
  v_air_in         NUMERIC(18,4);
  v_air_out        NUMERIC(18,4);
  v_free_in        NUMERIC(18,4);
  v_free_out       NUMERIC(18,4);
  v_return_out     NUMERIC(18,4);
  v_payable        NUMERIC(18,4);
  v_xfer_count     INTEGER;
  v_item_count     INTEGER;
  v_total_stores   INTEGER := 0;
  v_total_amount   NUMERIC(18,4) := 0;
BEGIN
  SELECT tenant_id INTO v_tenant FROM stores LIMIT 1;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'no stores found, cannot infer tenant_id';
  END IF;

  FOR v_store IN
    SELECT s.id, s.code, s.name, s.location_id
      FROM stores s
     WHERE s.tenant_id = v_tenant
       AND s.location_id IS NOT NULL
  LOOP
    -- 跳過已 confirmed/settled
    IF EXISTS (
      SELECT 1 FROM store_monthly_settlements
       WHERE tenant_id = v_tenant
         AND settlement_month = v_month_start
         AND store_id = v_store.id
         AND status IN ('confirmed','settled')
    ) THEN
      CONTINUE;
    END IF;

    -- A) hq_inbound: 從 HQ 收貨
    SELECT
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0)
      INTO v_hq_inbound
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'hq_to_store'
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- B) air_in: 空中轉收進來（該店是 dest）
    SELECT
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0)
      INTO v_air_in
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NOT NULL
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- C) air_out: 空中轉送出去（該店是 source）
    SELECT
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0)
      INTO v_air_out
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NOT NULL
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- D) free_in: 自由轉貨收進來（該店是 dest；無訂單 FK；估價入帳）
    SELECT
      COALESCE(SUM(COALESCE(ti.estimated_amount, 0)), 0)
      INTO v_free_in
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- E) free_out: 自由轉貨送出去（該店是 source；估價入帳、貸記）
    SELECT
      COALESCE(SUM(COALESCE(ti.estimated_amount, 0)), 0)
      INTO v_free_out
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- F) return_out: 退貨回總倉（該店是 source、總倉已收；成本沖回）
    SELECT
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0)
      INTO v_return_out
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    v_payable := v_hq_inbound + v_air_in - v_air_out + v_free_in - v_free_out - v_return_out;

    -- 沒任何活動就 skip + 砍 draft
    IF v_hq_inbound = 0 AND v_air_in = 0 AND v_air_out = 0
       AND v_free_in = 0 AND v_free_out = 0 AND v_return_out = 0 THEN
      DELETE FROM store_monthly_settlements
       WHERE tenant_id = v_tenant
         AND settlement_month = v_month_start
         AND store_id = v_store.id
         AND status = 'draft';
      CONTINUE;
    END IF;

    -- 計 transfer_count + item_count
    SELECT
      COUNT(DISTINCT t.id), COUNT(ti.id)
      INTO v_xfer_count, v_item_count
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.status IN ('received','closed')
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0
       AND (
         (t.transfer_type = 'hq_to_store' AND t.dest_location = v_store.location_id)
         OR
         (t.transfer_type = 'store_to_store'
          AND (t.dest_location = v_store.location_id OR t.source_location = v_store.location_id))
         OR
         (t.transfer_type = 'return_to_hq' AND t.source_location = v_store.location_id)
       );

    -- upsert (draft only)
    INSERT INTO store_monthly_settlements (
      tenant_id, settlement_month, store_id,
      payable_amount, transfer_count, item_count,
      status, created_by, updated_by
    ) VALUES (
      v_tenant, v_month_start, v_store.id,
      v_payable, v_xfer_count, v_item_count,
      'draft', p_operator, p_operator
    )
    ON CONFLICT (tenant_id, settlement_month, store_id)
    DO UPDATE SET
      payable_amount = EXCLUDED.payable_amount,
      transfer_count = EXCLUDED.transfer_count,
      item_count     = EXCLUDED.item_count,
      updated_by     = p_operator,
      updated_at     = NOW()
    WHERE store_monthly_settlements.status = 'draft'
    RETURNING id INTO v_settlement_id;

    -- 重建 items
    DELETE FROM store_monthly_settlement_items WHERE settlement_id = v_settlement_id;

    -- A) hq_inbound items
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      ti.qty_received * COALESCE(sm.unit_cost, 0),
      t.received_at, 'hq_inbound'
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'hq_to_store'
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- B) air_in items
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      ti.qty_received * COALESCE(sm.unit_cost, 0),
      t.received_at, 'air_in'
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NOT NULL
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- C) air_out items（line_amount 用負值）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      -1 * ti.qty_received * COALESCE(sm.unit_cost, 0),  -- 負值
      t.received_at, 'air_out'
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NOT NULL
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- D) free_in items（估價入帳；帶描述）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type, description
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, 0,
      COALESCE(ti.estimated_amount, 0),
      t.received_at, 'free_in', ti.description
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- E) free_out items（估價入帳、負值；帶描述）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type, description
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, 0,
      -1 * COALESCE(ti.estimated_amount, 0),  -- 負值
      t.received_at, 'free_out', ti.description
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- F) return_out items（成本沖回、負值）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      -1 * ti.qty_received * COALESCE(sm.unit_cost, 0),  -- 負值
      t.received_at, 'return_out'
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    v_total_stores := v_total_stores + 1;
    v_total_amount := v_total_amount + v_payable;
  END LOOP;

  RETURN jsonb_build_object(
    'month',         to_char(v_month_start, 'YYYY-MM'),
    'stores_count',  v_total_stores,
    'total_amount',  v_total_amount
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_generate_hq_to_store_settlement IS
  'HQ→店月結算（總倉當清算中心）：payable = hq_inbound + air_in - air_out '
  '+ free_in - free_out - return_out。自由轉貨以估價入帳（兩店鏡像同額、總倉淨額 0）、'
  '退貨回總倉以成本沖回。已 confirmed/settled 不重算。';

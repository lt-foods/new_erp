-- ============================================================
-- 2026-07-13: 月結雙價格口徑 — 每筆分錄同時帶「成本價」與「分店價」分開計算
--
-- 需求（使用者）：「月結算應該都要帶到分店價跟成本價兩個來分開計算」。
--
-- 現況缺口（rpc_generate_hq_to_store_settlement = 20260714000100 現行版）：
--   月結所有分錄只有一個金額基準 — 出貨當下 stock_movements.unit_cost
--   （成本價口徑）。分店價（prices scope='branch'，總部賣給加盟店的價格）
--   完全沒進月結，看不到兩個口徑的差額（= 總部毛利），也無從對帳。
--
-- 修法：
--   1. store_monthly_settlements 加兩欄，分開累計兩個口徑：
--      - cost_amount   成本價口徑總額（＝既有 payable_amount 的算法）
--      - branch_amount 分店價口徑總額
--      payable_amount 語義不變（＝成本口徑、confirm 後入 store_receivables
--      的金額），避免無預警改動實際請款金額；要切換請款口徑時只需把
--      confirm RPC 的取值換成 branch_amount。
--   2. store_monthly_settlement_items 每行加：
--      - unit_branch_price 分店價單價（收貨當下生效的 branch 價快照）
--      - branch_amount     分店價口徑行金額（正負號同 line_amount）
--   3. helper _branch_price_at(tenant, sku, at)：取「at 時點生效」的
--      分店價（prices scope='branch'、scope_id IS NULL、price > 0）；
--      該時點查無（收貨早於首次設價）則 fallback 現行價；再無則 NULL。
--   4. 重寫 rpc_generate_hq_to_store_settlement：六種 entry_type 全部
--      雙口徑計算。
--
-- 各 entry_type 的分店價基準：
--   - hq_inbound / air_in / air_out / return_out：真 SKU →
--     qty_received × _branch_price_at(sku, received_at)，air_out/return_out 取負。
--   - free_in / free_out：自由轉貨行是 MISC 虛擬 SKU + 估價、無真 SKU 可查價
--     → 兩個口徑同用 transfer_items.estimated_amount（unit_branch_price = 0）。
--   「無活動 skip」判斷擴成兩口徑皆 0 才 skip：0 成本入庫（防呆前舊資料）
--   但分店價有值的月份不會被誤刪。
--
-- 既有資料回填：
--   - header cost_amount 回填 = payable_amount（舊算法即成本口徑）。
--   - items 為 append-only（forbid_append_only_mutation），不回填；
--     draft 重跑生成器即補齊，confirmed/settled 維持原樣（branch 欄為 0）。
--
-- 基底版本：rpc_generate_hq_to_store_settlement = 20260714000100（線上現行）；
--   逐字複製僅追加分店價口徑欄位與計算。
-- Rollback：
--   CREATE OR REPLACE 回 20260714000100 版本；
--   DROP FUNCTION public._branch_price_at(UUID, BIGINT, TIMESTAMPTZ);
--   新欄位可留（無害），或
--   ALTER TABLE store_monthly_settlements DROP COLUMN cost_amount, DROP COLUMN branch_amount;
--   ALTER TABLE store_monthly_settlement_items DROP COLUMN unit_branch_price, DROP COLUMN branch_amount;
-- ============================================================

-- ------------------------------------------------------------
-- 1. 主檔加雙口徑總額
-- ------------------------------------------------------------
ALTER TABLE public.store_monthly_settlements
  ADD COLUMN IF NOT EXISTS cost_amount   NUMERIC(18,4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS branch_amount NUMERIC(18,4) NOT NULL DEFAULT 0;

COMMENT ON COLUMN store_monthly_settlements.cost_amount IS
  '成本價口徑總額（出貨當下 movement.unit_cost；自由轉貨以估價計）— 與 payable_amount 同基準';
COMMENT ON COLUMN store_monthly_settlements.branch_amount IS
  '分店價口徑總額（prices scope=branch 收貨當下生效價；自由轉貨以估價計）';

-- 既有資料回填：舊 payable_amount 即成本口徑
UPDATE public.store_monthly_settlements
   SET cost_amount = payable_amount
 WHERE cost_amount = 0
   AND payable_amount <> 0;

-- ------------------------------------------------------------
-- 2. 明細加分店價欄位
-- ------------------------------------------------------------
ALTER TABLE public.store_monthly_settlement_items
  ADD COLUMN IF NOT EXISTS unit_branch_price NUMERIC(18,4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS branch_amount     NUMERIC(18,4) NOT NULL DEFAULT 0;

COMMENT ON COLUMN store_monthly_settlement_items.unit_branch_price IS
  '分店價單價（收貨當下生效的 prices scope=branch 快照）；自由轉貨行為 0';
COMMENT ON COLUMN store_monthly_settlement_items.branch_amount IS
  '分店價口徑行金額（正負號同 line_amount）；自由轉貨行 = ±estimated_amount';

-- ------------------------------------------------------------
-- 3. helper：取指定時點生效的分店價
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._branch_price_at(
  p_tenant UUID,
  p_sku_id BIGINT,
  p_at     TIMESTAMPTZ
) RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    -- p_at 時點生效的版本
    (SELECT pr.price
       FROM public.prices pr
      WHERE pr.tenant_id    = p_tenant
        AND pr.sku_id       = p_sku_id
        AND pr.scope        = 'branch'
        AND pr.scope_id     IS NULL
        AND pr.price        > 0
        AND pr.effective_from <= p_at
        AND (pr.effective_to IS NULL OR pr.effective_to > p_at)
      ORDER BY pr.effective_from DESC
      LIMIT 1),
    -- fallback：現行價（收貨早於首次設價的舊資料）
    (SELECT pr.price
       FROM public.prices pr
      WHERE pr.tenant_id    = p_tenant
        AND pr.sku_id       = p_sku_id
        AND pr.scope        = 'branch'
        AND pr.scope_id     IS NULL
        AND pr.price        > 0
        AND pr.effective_to IS NULL
      ORDER BY pr.effective_from DESC
      LIMIT 1)
  )
$$;

COMMENT ON FUNCTION public._branch_price_at(UUID, BIGINT, TIMESTAMPTZ) IS
  '取 p_at 時點生效的分店價（prices scope=branch, scope_id NULL, price>0）；'
  '該時點查無則 fallback 現行價；再無則 NULL。月結雙口徑計算用。';

-- ------------------------------------------------------------
-- 4. rpc_generate_hq_to_store_settlement — 雙口徑計算
--    基底 20260714000100 逐字保留，追加分店價口徑。
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
  v_hq_inbound_b   NUMERIC(18,4);  -- 分店價口徑
  v_air_in_b       NUMERIC(18,4);
  v_air_out_b      NUMERIC(18,4);
  v_return_out_b   NUMERIC(18,4);
  v_payable        NUMERIC(18,4);
  v_branch_total   NUMERIC(18,4);
  v_xfer_count     INTEGER;
  v_item_count     INTEGER;
  v_total_stores   INTEGER := 0;
  v_total_amount   NUMERIC(18,4) := 0;
  v_total_branch   NUMERIC(18,4) := 0;
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

    -- A) hq_inbound: 從 HQ 收貨（成本口徑 + 分店價口徑）
    SELECT
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0),
      COALESCE(SUM(ti.qty_received * COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0)), 0)
      INTO v_hq_inbound, v_hq_inbound_b
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
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0),
      COALESCE(SUM(ti.qty_received * COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0)), 0)
      INTO v_air_in, v_air_in_b
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
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0),
      COALESCE(SUM(ti.qty_received * COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0)), 0)
      INTO v_air_out, v_air_out_b
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

    -- D) free_in: 自由轉貨收進來（該店是 dest；無訂單 FK；估價入帳、兩口徑同額）
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

    -- E) free_out: 自由轉貨送出去（該店是 source；估價入帳、貸記、兩口徑同額）
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

    -- F) return_out: 退貨回總倉（該店是 source、總倉已收；沖回）
    SELECT
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0),
      COALESCE(SUM(ti.qty_received * COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0)), 0)
      INTO v_return_out, v_return_out_b
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

    v_payable      := v_hq_inbound   + v_air_in   - v_air_out   + v_free_in - v_free_out - v_return_out;
    v_branch_total := v_hq_inbound_b + v_air_in_b - v_air_out_b + v_free_in - v_free_out - v_return_out_b;

    -- 沒任何活動就 skip + 砍 draft（兩口徑皆 0 才算無活動）
    IF v_hq_inbound = 0 AND v_air_in = 0 AND v_air_out = 0
       AND v_free_in = 0 AND v_free_out = 0 AND v_return_out = 0
       AND v_hq_inbound_b = 0 AND v_air_in_b = 0 AND v_air_out_b = 0
       AND v_return_out_b = 0 THEN
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
      payable_amount, cost_amount, branch_amount,
      transfer_count, item_count,
      status, created_by, updated_by
    ) VALUES (
      v_tenant, v_month_start, v_store.id,
      v_payable, v_payable, v_branch_total,
      v_xfer_count, v_item_count,
      'draft', p_operator, p_operator
    )
    ON CONFLICT (tenant_id, settlement_month, store_id)
    DO UPDATE SET
      payable_amount = EXCLUDED.payable_amount,
      cost_amount    = EXCLUDED.cost_amount,
      branch_amount  = EXCLUDED.branch_amount,
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
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      ti.qty_received * COALESCE(sm.unit_cost, 0),
      t.received_at, 'hq_inbound',
      bp.p, ti.qty_received * bp.p
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0) AS p
      ) bp
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
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      ti.qty_received * COALESCE(sm.unit_cost, 0),
      t.received_at, 'air_in',
      bp.p, ti.qty_received * bp.p
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0) AS p
      ) bp
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NOT NULL
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- C) air_out items（兩口徑皆負值）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      -1 * ti.qty_received * COALESCE(sm.unit_cost, 0),  -- 負值
      t.received_at, 'air_out',
      bp.p, -1 * ti.qty_received * bp.p
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0) AS p
      ) bp
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NOT NULL
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    -- D) free_in items（估價入帳、兩口徑同額；帶描述）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type, description,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, 0,
      COALESCE(ti.estimated_amount, 0),
      t.received_at, 'free_in', ti.description,
      0, COALESCE(ti.estimated_amount, 0)
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

    -- E) free_out items（估價入帳、負值、兩口徑同額；帶描述）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type, description,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, 0,
      -1 * COALESCE(ti.estimated_amount, 0),  -- 負值
      t.received_at, 'free_out', ti.description,
      0, -1 * COALESCE(ti.estimated_amount, 0)
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

    -- F) return_out items（沖回、兩口徑皆負值）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      -1 * ti.qty_received * COALESCE(sm.unit_cost, 0),  -- 負值
      t.received_at, 'return_out',
      bp.p, -1 * ti.qty_received * bp.p
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0) AS p
      ) bp
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
       AND ti.qty_received > 0;

    v_total_stores := v_total_stores + 1;
    v_total_amount := v_total_amount + v_payable;
    v_total_branch := v_total_branch + v_branch_total;
  END LOOP;

  RETURN jsonb_build_object(
    'month',               to_char(v_month_start, 'YYYY-MM'),
    'stores_count',        v_total_stores,
    'total_amount',        v_total_amount,
    'total_cost_amount',   v_total_amount,
    'total_branch_amount', v_total_branch
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_generate_hq_to_store_settlement IS
  'HQ→店月結算（雙價格口徑）：每筆分錄同時計成本價（movement.unit_cost）與'
  '分店價（prices scope=branch 收貨當下生效價）兩口徑，分開累計到 '
  'cost_amount / branch_amount。payable = 成本口徑（hq_inbound + air_in - air_out '
  '+ free_in - free_out - return_out）；自由轉貨兩口徑同用估價。'
  '已 confirmed/settled 不重算。';

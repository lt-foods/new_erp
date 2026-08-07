-- ============================================================
-- 2026-08-07: 月結月界改用台北時區（received_at 歸屬月份對齊 Asia/Taipei）
--
-- 問題：
--   rpc_generate_hq_to_store_settlement 的月界比較是
--   `t.received_at >= v_month_start`（TIMESTAMPTZ vs DATE），DATE 會用
--   DB session timezone（Supabase 預設 UTC）轉成當天 00:00 UTC ——
--   實際月切點是台北時間每月 1 號早上 08:00。1 號 00:00–08:00（台北）
--   收的貨會被算進上個月。
--   20260803000000（每日進貨對帳）日界已用 Asia/Taipei，並在檔頭註明
--   這個不一致（當時全量 7439 筆只有 2 筆落在此窗，先不動生成器）；
--   本 migration 就是把生成器補齊的那一支，改完後「每日進貨加總 =
--   該月月結 branch_amount」在跨月邊界日也成立。
--
-- 改動：
--   1. rpc_generate_hq_to_store_settlement v5：
--      新增 v_range_start / v_range_end TIMESTAMPTZ =
--      台北時間該月 1 號 00:00 起、次月 1 號 00:00 止（半開區間）。
--      A–F 匯總、transfer/item 筆數統計、A–F 明細 insert 共 13 處的
--      received_at 月界一致替換。其餘邏輯與 v4 完全相同
--      （settlement_month 主鍵、人工調整、鎖定跳過、無活動砍 draft 皆不動）。
--   2. rpc_update_free_transfer_amount v3：
--      入帳月份判定 DATE_TRUNC('month', received_at) 改為
--      DATE_TRUNC('month', received_at AT TIME ZONE 'Asia/Taipei')，
--      與生成器 v5 歸屬一致（鎖定檢查、改完重算的月份都用同一個月）。
--
-- 影響：
--   - 只影響 draft/sent/disputed 的重算；confirmed/settled/remitted/
--     cancelled 生成器本來就跳過，歷史鎖定月不會變動。
--   - 邊界窗（每月 1 號台北 00:00–08:00 收貨）的轉倉單，下次重算時
--     會移到正確（台北時間認知）的月份。
--
-- 基底版本：
--   rpc_generate_hq_to_store_settlement ← 20260801000000（v4, manual adjustment）
--   rpc_update_free_transfer_amount     ← 20260715000120（v2, estatement flow）
-- Rollback：
--   CREATE OR REPLACE 回上述兩個基底版本即可（無 schema 變動）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 生成器 v5：月界改台北時區
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_generate_hq_to_store_settlement(p_month date, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant         UUID;
  v_month_start    DATE := DATE_TRUNC('month', p_month)::DATE;
  v_month_end      DATE := (DATE_TRUNC('month', p_month) + INTERVAL '1 month')::DATE;
  -- 月界（台北時區）：received_at ∈ [該月1號00:00, 次月1號00:00) Asia/Taipei
  v_range_start    TIMESTAMPTZ := v_month_start::TIMESTAMP AT TIME ZONE 'Asia/Taipei';
  v_range_end      TIMESTAMPTZ := v_month_end::TIMESTAMP AT TIME ZONE 'Asia/Taipei';
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
  v_adjust         NUMERIC(18,4);  -- 人工調整（active 合計）
  v_cost_total     NUMERIC(18,4);
  v_branch_total   NUMERIC(18,4);
  v_payable        NUMERIC(18,4);
  v_xfer_count     INTEGER;
  v_item_count     INTEGER;
  v_total_stores   INTEGER := 0;
  v_total_amount   NUMERIC(18,4) := 0;
  v_total_cost     NUMERIC(18,4) := 0;
  v_total_branch   NUMERIC(18,4) := 0;
  v_total_adjust   NUMERIC(18,4) := 0;
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
    -- 跳過已鎖定/結案/作廢（confirmed 起不再重算；cancelled 舊版會 NULL crash，一併跳過）
    IF EXISTS (
      SELECT 1 FROM store_monthly_settlements
       WHERE tenant_id = v_tenant
         AND settlement_month = v_month_start
         AND store_id = v_store.id
         AND status IN ('confirmed','settled','remitted','cancelled')
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- D) free_in: 自由轉貨收進來（估價入帳、兩口徑同額）
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- E) free_out: 自由轉貨送出去（估價入帳、貸記、兩口徑同額）
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- F) return_out: 退貨回總倉（成本沖回 + 分店價沖回）
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- G) 人工調整（active 合計；只進 payable，不動貨款兩口徑）
    SELECT COALESCE(SUM(a.amount), 0)
      INTO v_adjust
      FROM store_settlement_adjustments a
     WHERE a.tenant_id = v_tenant
       AND a.settlement_month = v_month_start
       AND a.store_id = v_store.id
       AND a.status = 'active';

    v_cost_total   := v_hq_inbound   + v_air_in   - v_air_out   + v_free_in - v_free_out - v_return_out;
    v_branch_total := v_hq_inbound_b + v_air_in_b - v_air_out_b + v_free_in - v_free_out - v_return_out_b;
    -- 賣斷制：總倉出給分店、跟分店收「分店價」；成本口徑僅供總倉毛利參考
    v_payable      := v_branch_total + v_adjust;

    -- 沒任何活動就 skip + 砍 draft（兩口徑皆 0 且無 active 調整才算無活動；
    -- 只砍 draft，sent/disputed 已進流程不自動刪）
    IF v_hq_inbound = 0 AND v_air_in = 0 AND v_air_out = 0
       AND v_free_in = 0 AND v_free_out = 0 AND v_return_out = 0
       AND v_hq_inbound_b = 0 AND v_air_in_b = 0 AND v_air_out_b = 0
       AND v_return_out_b = 0 AND v_adjust = 0 THEN
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0
       AND (
         (t.transfer_type = 'hq_to_store' AND t.dest_location = v_store.location_id)
         OR
         (t.transfer_type = 'store_to_store'
          AND (t.dest_location = v_store.location_id OR t.source_location = v_store.location_id))
         OR
         (t.transfer_type = 'return_to_hq' AND t.source_location = v_store.location_id)
       );

    -- upsert（鎖定前狀態 draft/sent/disputed 都重算；status 本身不動）
    INSERT INTO store_monthly_settlements (
      tenant_id, settlement_month, store_id,
      payable_amount, cost_amount, branch_amount, adjustment_amount,
      transfer_count, item_count,
      status, created_by, updated_by
    ) VALUES (
      v_tenant, v_month_start, v_store.id,
      v_payable, v_cost_total, v_branch_total, v_adjust,
      v_xfer_count, v_item_count,
      'draft', p_operator, p_operator
    )
    ON CONFLICT (tenant_id, settlement_month, store_id)
    DO UPDATE SET
      payable_amount    = EXCLUDED.payable_amount,
      cost_amount       = EXCLUDED.cost_amount,
      branch_amount     = EXCLUDED.branch_amount,
      adjustment_amount = EXCLUDED.adjustment_amount,
      transfer_count    = EXCLUDED.transfer_count,
      item_count        = EXCLUDED.item_count,
      updated_by        = p_operator,
      updated_at        = NOW()
    WHERE store_monthly_settlements.status IN ('draft','sent','disputed')
    RETURNING id INTO v_settlement_id;

    -- 重建 items
    DELETE FROM store_monthly_settlement_items WHERE settlement_id = v_settlement_id;

    -- A) hq_inbound items（雙口徑）
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- B) air_in items（雙口徑）
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
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
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    v_total_stores := v_total_stores + 1;
    v_total_amount := v_total_amount + v_payable;
    v_total_cost   := v_total_cost + v_cost_total;
    v_total_branch := v_total_branch + v_branch_total;
    v_total_adjust := v_total_adjust + v_adjust;
  END LOOP;

  RETURN jsonb_build_object(
    'month',                to_char(v_month_start, 'YYYY-MM'),
    'stores_count',         v_total_stores,
    'total_amount',         v_total_amount,
    'total_cost_amount',    v_total_cost,
    'total_branch_amount',  v_total_branch,
    'total_adjustment',     v_total_adjust
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_generate_hq_to_store_settlement IS
  'HQ→店月結算（總倉當清算中心）：每筆分錄雙口徑 cost_amount / branch_amount。'
  'payable = 分店價口徑 + 人工調整（store_settlement_adjustments active 合計）。'
  'draft/sent/disputed 重建、confirmed/settled/remitted/cancelled 跳過（confirmed 起鎖定）。'
  '月界為台北時區：received_at ∈ [該月1號00:00, 次月1號00:00) Asia/Taipei。';

-- ------------------------------------------------------------
-- 2. 估價修正 v3：入帳月份判定改台北時區（其餘與 20260715000120 v2 相同）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_update_free_transfer_amount(
  p_transfer_item_id BIGINT,
  p_new_amount       NUMERIC,
  p_operator         UUID,
  p_reason           TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ti     RECORD;
  v_t      RECORD;
  v_month  DATE;
  v_old    NUMERIC;
  v_locked TEXT;
  v_regen  BOOLEAN := FALSE;
BEGIN
  IF p_new_amount IS NULL OR p_new_amount < 0 THEN
    RAISE EXCEPTION '估價需 >= 0（收到 %）', p_new_amount;
  END IF;

  SELECT * INTO v_ti FROM transfer_items WHERE id = p_transfer_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_item % 不存在', p_transfer_item_id;
  END IF;

  SELECT * INTO v_t FROM transfers WHERE id = v_ti.transfer_id;

  -- 僅自由轉貨行可修：店↔店、無訂單 FK（有訂單的是空中轉、走成本入帳）
  IF v_t.transfer_type <> 'store_to_store' OR v_t.customer_order_id IS NOT NULL THEN
    RAISE EXCEPTION '調撥單 % 不是自由轉貨（type=%），此行不可修估價',
      v_t.transfer_no, v_t.transfer_type;
  END IF;

  v_old := COALESCE(v_ti.estimated_amount, 0);

  -- 已入帳月份任一邊已鎖定（confirmed 起）→ 擋
  -- 月份歸屬與生成器 v5 一致：台北時區
  IF v_t.status IN ('received','closed') AND v_t.received_at IS NOT NULL THEN
    v_month := DATE_TRUNC('month', v_t.received_at AT TIME ZONE 'Asia/Taipei')::DATE;
    SELECT string_agg(st.name || '（' || s.status || '）', '、')
      INTO v_locked
      FROM store_monthly_settlements s
      JOIN stores st ON st.id = s.store_id
     WHERE s.tenant_id = v_t.tenant_id
       AND s.settlement_month = v_month
       AND s.status IN ('confirmed', 'remitted', 'settled')
       AND st.location_id IN (v_t.source_location, v_t.dest_location);
    IF v_locked IS NOT NULL THEN
      RAISE EXCEPTION '% 月結算已鎖定：%。鎖定後不可改估價，請走爭議流程。',
        to_char(v_month, 'YYYY-MM'), v_locked;
    END IF;
  END IF;

  UPDATE transfer_items
     SET estimated_amount = p_new_amount,
         notes = TRIM(BOTH E'\n' FROM
           COALESCE(notes || E'\n', '')
           || '[估價修正 ' || to_char(NOW(), 'YYYY-MM-DD') || '] $'
           || trim_scale(v_old)::TEXT || ' → $' || trim_scale(p_new_amount)::TEXT
           || COALESCE('（' || NULLIF(TRIM(p_reason), '') || '）', '')),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_transfer_item_id;

  -- 已收貨 → 重跑該月生成器重建兩邊 draft/sent/disputed（鎖定的本來就跳過）
  IF v_month IS NOT NULL THEN
    PERFORM public.rpc_generate_hq_to_store_settlement(v_month, p_operator);
    v_regen := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'transfer_item_id',        p_transfer_item_id,
    'transfer_no',             v_t.transfer_no,
    'old_amount',              v_old,
    'new_amount',              p_new_amount,
    'month',                   CASE WHEN v_month IS NULL THEN NULL
                                    ELSE to_char(v_month, 'YYYY-MM') END,
    'settlements_regenerated', v_regen
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_update_free_transfer_amount IS
  '自由轉貨行估價修正：入帳月份歸屬用 Asia/Taipei（同生成器 v5）；'
  '該月任一邊 confirmed/remitted/settled 即鎖定擋修；'
  '改完重跑該月生成器重建兩邊 draft/sent/disputed；修正軌跡 append 進 notes。';

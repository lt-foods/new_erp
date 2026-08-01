-- ============================================================
-- 2026-08-01: 月結人工調整（增減金額＋必填原因）
--
-- 需求：月結對帳時常有明細行以外的加減項（例：運費分攤、破損折讓、
--   活動補貼、上月尾差沖抵），總部要能對單一分店的月結單直接
--   「增加或減少金額」並記錄原因，店家核對與列印對帳單都要看得到。
--
-- 設計：
--   - 新表 store_settlement_adjustments：一筆調整 = 一個帶正負號的
--     金額（正=加收、負=減收）＋必填原因。錨定 (tenant, 月份, store)
--     而非 settlement_id —— 生成器重算會 DELETE/重建 draft 列，
--     錨月份+店讓調整在重算後自動保留、重新套用。
--   - 只能作廢（voided）不能改：留完整軌跡，改金額 = 作廢舊的再開新的。
--   - store_monthly_settlements 加 adjustment_amount 欄位（active 調整
--     合計）；payable_amount = branch_amount + adjustment_amount。
--     branch_amount / cost_amount 維持「純貨款」口徑，毛利顯示
--     （branch - cost）不受調整影響。
--   - 調整/作廢僅限鎖定前（draft/sent/disputed），confirmed 起擋下
--     —— 對齊 rpc_update_free_transfer_amount v2 的鎖定判斷。
--   - 角色 gate：僅總部（_settlement_caller_is_hq()，20260715000120）。
--     寫入全走 SECURITY DEFINER RPC；RLS 只開同 tenant SELECT
--     （比照 auth_read_sms pattern，店家核對頁要能讀）。
--   - 生成器 v4：重算時把 active 調整合計加回 payable；「該月無任何
--     調撥活動」但有 active 調整時不再砍 draft（例：純收費月份）。
--
-- 基底版本：
--   rpc_generate_hq_to_store_settlement ← 20260715000120（v3, estatement flow）
--   rpc_confirm_store_monthly_settlement / 其餘流程 RPC 不動
--     （confirm 讀 payable_amount，已含調整）。
-- Rollback：
--   CREATE OR REPLACE rpc_generate_hq_to_store_settlement 回 20260715000120 版；
--   DROP FUNCTION public.rpc_add_settlement_adjustment(BIGINT, NUMERIC, UUID, TEXT);
--   DROP FUNCTION public.rpc_void_settlement_adjustment(BIGINT, UUID, TEXT);
--   DROP TABLE public.store_settlement_adjustments;
--   ALTER TABLE store_monthly_settlements DROP COLUMN adjustment_amount;
--   （已含調整的 draft/sent/disputed 列重跑一次生成器歸回純貨款金額）
-- ============================================================

-- ------------------------------------------------------------
-- 1. 主檔加 adjustment_amount（active 調整合計，生成器/RPC 維護）
-- ------------------------------------------------------------
ALTER TABLE public.store_monthly_settlements
  ADD COLUMN IF NOT EXISTS adjustment_amount NUMERIC(18,4) NOT NULL DEFAULT 0;

COMMENT ON COLUMN store_monthly_settlements.adjustment_amount IS
  '人工調整合計（store_settlement_adjustments active 加總；正=加收、負=減收）。'
  'payable_amount = branch_amount + adjustment_amount。';

-- ------------------------------------------------------------
-- 2. 調整表（錨定 tenant+月份+store，生成器重算不失聯）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.store_settlement_adjustments (
  id               BIGSERIAL PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  settlement_month DATE NOT NULL,             -- 該月第一天（同 store_monthly_settlements）
  store_id         BIGINT NOT NULL REFERENCES public.stores(id),
  amount           NUMERIC(18,4) NOT NULL CHECK (amount <> 0),  -- 正=加收、負=減收
  reason           TEXT NOT NULL,
  status           TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','voided')),
  created_by       UUID NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  voided_by        UUID,
  voided_at        TIMESTAMPTZ,
  void_reason      TEXT,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ssa_month_store
  ON public.store_settlement_adjustments (tenant_id, settlement_month, store_id, status);

COMMENT ON TABLE store_settlement_adjustments IS
  '月結人工調整：總部對單一分店單一月份的加減金額（正=加收、負=減收）＋必填原因。'
  '只能作廢不能改；錨定月份+店，月結 draft 重算後自動重新套用。';

ALTER TABLE public.store_settlement_adjustments ENABLE ROW LEVEL SECURITY;

-- 同 tenant 皆可讀（比照 auth_read_sms/smsi；店家核對頁要顯示調整行）。
-- 寫入不開 policy —— 全部走下方 SECURITY DEFINER RPC。
DROP POLICY IF EXISTS auth_read_ssa ON public.store_settlement_adjustments;
CREATE POLICY auth_read_ssa ON public.store_settlement_adjustments
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

-- ------------------------------------------------------------
-- 3. RPC: 新增調整（增減金額＋必填原因）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_add_settlement_adjustment(
  p_settlement_id BIGINT,
  p_amount        NUMERIC,
  p_operator      UUID,
  p_reason        TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_s      store_monthly_settlements%ROWTYPE;
  v_reason TEXT;
  v_adj_id BIGINT;
  v_total  NUMERIC(18,4);
BEGIN
  IF NOT public._settlement_caller_is_hq() THEN
    RAISE EXCEPTION '僅總部帳號可調整月結金額（role=%）',
      COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  END IF;

  IF p_amount IS NULL OR p_amount = 0 THEN
    RAISE EXCEPTION '調整金額不可為 0（正=加收、負=減收）';
  END IF;
  v_reason := NULLIF(TRIM(p_reason), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION '調整金額必須填原因';
  END IF;

  SELECT * INTO v_s FROM store_monthly_settlements
   WHERE id = p_settlement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found', p_settlement_id;
  END IF;
  IF v_s.status NOT IN ('draft', 'sent', 'disputed') THEN
    RAISE EXCEPTION '狀態 % 不可調整金額（confirmed 起鎖定，請走爭議/沖帳流程）', v_s.status;
  END IF;

  INSERT INTO store_settlement_adjustments (
    tenant_id, settlement_month, store_id, amount, reason, created_by
  ) VALUES (
    v_s.tenant_id, v_s.settlement_month, v_s.store_id, p_amount, v_reason, p_operator
  ) RETURNING id INTO v_adj_id;

  SELECT COALESCE(SUM(amount), 0) INTO v_total
    FROM store_settlement_adjustments
   WHERE tenant_id = v_s.tenant_id
     AND settlement_month = v_s.settlement_month
     AND store_id = v_s.store_id
     AND status = 'active';

  UPDATE store_monthly_settlements
     SET adjustment_amount = v_total,
         payable_amount    = branch_amount + v_total,
         updated_by        = p_operator,
         updated_at        = NOW()
   WHERE id = p_settlement_id;

  RETURN jsonb_build_object(
    'adjustment_id',    v_adj_id,
    'settlement_id',    p_settlement_id,
    'amount',           p_amount,
    'adjustment_total', v_total,
    'payable_amount',   v_s.branch_amount + v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_add_settlement_adjustment(BIGINT, NUMERIC, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_add_settlement_adjustment IS
  '總部對月結單加一筆人工調整（正=加收、負=減收，原因必填）：僅鎖定前'
  '（draft/sent/disputed）可加；payable_amount 同步 = branch_amount + active 調整合計。';

-- ------------------------------------------------------------
-- 4. RPC: 作廢調整（不能改、只能廢；重開一筆取代）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_void_settlement_adjustment(
  p_adjustment_id BIGINT,
  p_operator      UUID,
  p_reason        TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_a     store_settlement_adjustments%ROWTYPE;
  v_s     store_monthly_settlements%ROWTYPE;
  v_total NUMERIC(18,4);
BEGIN
  IF NOT public._settlement_caller_is_hq() THEN
    RAISE EXCEPTION '僅總部帳號可作廢月結調整（role=%）',
      COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  END IF;

  SELECT * INTO v_a FROM store_settlement_adjustments
   WHERE id = p_adjustment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'adjustment % not found', p_adjustment_id;
  END IF;
  IF v_a.status <> 'active' THEN
    RAISE EXCEPTION 'adjustment % 已作廢', p_adjustment_id;
  END IF;

  SELECT * INTO v_s FROM store_monthly_settlements
   WHERE tenant_id = v_a.tenant_id
     AND settlement_month = v_a.settlement_month
     AND store_id = v_a.store_id
   FOR UPDATE;
  IF FOUND AND v_s.status NOT IN ('draft', 'sent', 'disputed') THEN
    RAISE EXCEPTION '該月結算已鎖定（%），調整不可作廢', v_s.status;
  END IF;

  UPDATE store_settlement_adjustments
     SET status      = 'voided',
         voided_by   = p_operator,
         voided_at   = NOW(),
         void_reason = NULLIF(TRIM(p_reason), ''),
         updated_at  = NOW()
   WHERE id = p_adjustment_id;

  IF v_s.id IS NOT NULL THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_total
      FROM store_settlement_adjustments
     WHERE tenant_id = v_a.tenant_id
       AND settlement_month = v_a.settlement_month
       AND store_id = v_a.store_id
       AND status = 'active';

    UPDATE store_monthly_settlements
       SET adjustment_amount = v_total,
           payable_amount    = branch_amount + v_total,
           updated_by        = p_operator,
           updated_at        = NOW()
     WHERE id = v_s.id;
  END IF;

  RETURN jsonb_build_object(
    'adjustment_id',    p_adjustment_id,
    'settlement_id',    v_s.id,
    'adjustment_total', COALESCE(v_total, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_void_settlement_adjustment(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_void_settlement_adjustment IS
  '作廢一筆月結人工調整（僅鎖定前）；payable_amount 同步回算。'
  '調整不能改金額，改 = 作廢舊的再加新的。';

-- ------------------------------------------------------------
-- 5. 生成器 v4：重算時套用 active 調整
--    （基底 20260715000120 v3 逐字保留，僅加 G) 調整段、skip 條件、
--      upsert 欄位與回傳 total_adjustment）
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
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
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
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
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
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
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
       AND t.received_at >= v_month_start
       AND t.received_at < v_month_end
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
  'draft/sent/disputed 重建、confirmed/settled/remitted/cancelled 跳過（confirmed 起鎖定）。';

-- ============================================================
-- 2026-07-15: 月結電子對帳流程（不再列印、線上送單/畫押/爭議/匯款/結案）
--
-- 需求（1688 群組拍板，Alex + 楊小胖）：
--   1. 總部核對無誤後「線上送單」給店家（取代列印）。
--   2. 店家線上核對：全部無誤 → 按同意畫押；有問題 → 逐行提出爭議
--      （爭議行排最上方、附備註），送出後換總部 review。
--   3. 總部處理爭議（例：用 rpc_update_free_transfer_amount 修自由轉貨
--      估價）、標記已處理，再重新送店家核對。
--   4. 兩邊都同意 → 鎖住（= 既有 confirmed，產生應收單）。
--   5. 店家匯款後按「已匯款」；總部收到款按「確認收款」→ 結案（settled，
--      同時把應收單入帳）。
--
-- 狀態機（store_monthly_settlements.status）：
--   draft ──送單──▶ sent ──店家全同意──▶ confirmed ──店家已匯款──▶ remitted
--     ▲               │店家提爭議                                      │
--     │               ▼                                               │總部確認收款
--     └(重算)      disputed ──總部全部處理+重新送單──▶ sent            ▼
--                                                                  settled
--   * cancelled 保留（無流程進入）。
--   * 「鎖住」= confirmed 起：月結生成器與估價修正都不再動它。
--
-- 生成器重算範圍調整：draft/sent/disputed 都重建（送單後、鎖定前內容
--   跟著來源資料走 —— 爭議修正才會反映到兩邊店的帳），confirmed/
--   settled/remitted/cancelled 跳過。爭議列錨定 transfer_item_id（重建
--   不失聯）。同時修一個潛在 bug：舊版 loop 只跳過 confirmed/settled，
--   若出現 disputed/cancelled 列，upsert 的 WHERE status='draft' 會讓
--   RETURNING 回 NULL → items INSERT 炸 NOT NULL。
--
-- 角色 gate（in-RPC、SECURITY DEFINER）：
--   HQ  = app_metadata.role IN ('','owner','admin','hq_manager','hq_accountant')
--         （'' = legacy/dev admin，對齊 role.ts HQ_ROLES 與 wallet RPC gate）
--   店家 = role IN ('store_manager','store_staff') 且 settlement.store_id ∈
--         _jwt_store_ids()（app_metadata.stores 店名 → id，20260707000070）。
--         HQ 也可代店家操作（現場電話確認等情境）。
--
-- 基底版本：
--   rpc_generate_hq_to_store_settlement ← 20260715000100（payable=分店價口徑）
--   rpc_confirm_store_monthly_settlement ← 20260512000015（唯一版本）
--   rpc_update_free_transfer_amount ← 20260715000110（唯一版本）
-- Rollback：
--   各函式 CREATE OR REPLACE 回上列基底版本；
--   DROP FUNCTION rpc_send_settlement_to_store, rpc_store_review_settlement,
--     rpc_resolve_settlement_dispute, rpc_mark_settlement_remitted,
--     rpc_settle_store_monthly_settlement, _settlement_caller_is_hq,
--     _settlement_caller_in_store;
--   DROP TABLE store_settlement_disputes;
--   ALTER TABLE store_monthly_settlements
--     DROP CONSTRAINT sms_status_check_v2（重建舊 CHECK），
--     DROP COLUMN sent_at, sent_by, store_agreed_at, store_agreed_by,
--       remitted_at, remitted_by, remit_note, settled_by;
--   （已進 sent/remitted 的列需先手動歸回 draft/settled）
-- ============================================================

-- ------------------------------------------------------------
-- 1. status CHECK 擴充 + 流程欄位
-- ------------------------------------------------------------
ALTER TABLE public.store_monthly_settlements
  DROP CONSTRAINT IF EXISTS store_monthly_settlements_status_check;
ALTER TABLE public.store_monthly_settlements
  DROP CONSTRAINT IF EXISTS sms_status_check_v2;
ALTER TABLE public.store_monthly_settlements
  ADD CONSTRAINT sms_status_check_v2
    CHECK (status IN ('draft','sent','disputed','confirmed','remitted','settled','cancelled'));

ALTER TABLE public.store_monthly_settlements
  ADD COLUMN IF NOT EXISTS sent_at         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sent_by         UUID,
  ADD COLUMN IF NOT EXISTS store_agreed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS store_agreed_by UUID,
  ADD COLUMN IF NOT EXISTS remitted_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS remitted_by     UUID,
  ADD COLUMN IF NOT EXISTS remit_note      TEXT,
  ADD COLUMN IF NOT EXISTS settled_by      UUID;

COMMENT ON COLUMN store_monthly_settlements.status IS
  '月結流程：draft=總部工作中；sent=已送店家核對；disputed=店家提出爭議待總部處理；'
  'confirmed=雙方同意鎖定(產生應收單)；remitted=店家已匯款；settled=總部確認收款結案；cancelled=作廢';
COMMENT ON COLUMN store_monthly_settlements.remit_note IS '店家按已匯款時填的備註（例：帳號後五碼）';

-- ------------------------------------------------------------
-- 2. 爭議表（錨定 transfer_item_id，月結 items 重建不失聯）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.store_settlement_disputes (
  id               BIGSERIAL PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  settlement_id    BIGINT NOT NULL REFERENCES public.store_monthly_settlements(id) ON DELETE CASCADE,
  transfer_item_id BIGINT NOT NULL,
  item_snapshot    JSONB NOT NULL,   -- 提出當下的行快照 {entry_type, description, sku_id, qty_received, branch_amount, received_at}
  reason           TEXT NOT NULL,
  status           TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
  raised_by        UUID NOT NULL,
  raised_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_by      UUID,
  resolved_at      TIMESTAMPTZ,
  resolution_note  TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ssd_settlement ON public.store_settlement_disputes (settlement_id, status);
-- 同一行同時只能有一筆 open 爭議
CREATE UNIQUE INDEX IF NOT EXISTS uq_ssd_open_per_item
  ON public.store_settlement_disputes (settlement_id, transfer_item_id)
  WHERE status = 'open';

COMMENT ON TABLE store_settlement_disputes IS
  '月結對帳爭議：店家對單一明細行（以 transfer_item_id 錨定）提出的異議；'
  '總部處理後標 resolved，全部 resolved 才能重新送單。';

ALTER TABLE public.store_settlement_disputes ENABLE ROW LEVEL SECURITY;

-- 讀：HQ 全 tenant；店家只看自己店的（寫入全部走 SECURITY DEFINER RPC，不開放直寫）
DROP POLICY IF EXISTS ssd_select ON public.store_settlement_disputes;
CREATE POLICY ssd_select ON public.store_settlement_disputes
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')
      OR EXISTS (
        SELECT 1 FROM store_monthly_settlements s
         WHERE s.id = settlement_id
           AND s.store_id = ANY (public._jwt_store_ids())
      )
    )
  );

-- ------------------------------------------------------------
-- 3. caller gate helpers
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._settlement_caller_is_hq()
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  -- '' = legacy/dev admin（app_metadata.role 未設），對齊 role.ts HQ_ROLES
  SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
         IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant');
$$;

CREATE OR REPLACE FUNCTION public._settlement_caller_in_store(p_store_id BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
         IN ('store_manager', 'store_staff')
     AND p_store_id = ANY (public._jwt_store_ids());
$$;

-- ------------------------------------------------------------
-- 4. 生成器 v3：draft/sent/disputed 重建；confirmed/settled/remitted/cancelled 跳過
--    （其餘與 20260715000100 逐字相同）
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
  v_cost_total     NUMERIC(18,4);
  v_branch_total   NUMERIC(18,4);
  v_payable        NUMERIC(18,4);
  v_xfer_count     INTEGER;
  v_item_count     INTEGER;
  v_total_stores   INTEGER := 0;
  v_total_amount   NUMERIC(18,4) := 0;
  v_total_cost     NUMERIC(18,4) := 0;
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

    v_cost_total   := v_hq_inbound   + v_air_in   - v_air_out   + v_free_in - v_free_out - v_return_out;
    v_branch_total := v_hq_inbound_b + v_air_in_b - v_air_out_b + v_free_in - v_free_out - v_return_out_b;
    -- 賣斷制：總倉出給分店、跟分店收「分店價」；成本口徑僅供總倉毛利參考
    v_payable      := v_branch_total;

    -- 沒任何活動就 skip + 砍 draft（兩口徑皆 0 才算無活動；只砍 draft，
    -- sent/disputed 已進流程不自動刪）
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

    -- upsert（鎖定前狀態 draft/sent/disputed 都重算；status 本身不動）
    INSERT INTO store_monthly_settlements (
      tenant_id, settlement_month, store_id,
      payable_amount, cost_amount, branch_amount,
      transfer_count, item_count,
      status, created_by, updated_by
    ) VALUES (
      v_tenant, v_month_start, v_store.id,
      v_payable, v_cost_total, v_branch_total,
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
  END LOOP;

  RETURN jsonb_build_object(
    'month',               to_char(v_month_start, 'YYYY-MM'),
    'stores_count',        v_total_stores,
    'total_amount',        v_total_amount,
    'total_cost_amount',   v_total_cost,
    'total_branch_amount', v_total_branch
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_generate_hq_to_store_settlement IS
  'HQ→店月結算（總倉當清算中心）：每筆分錄雙口徑 cost_amount / branch_amount。'
  'payable = 分店價口徑（賣斷制）。draft/sent/disputed 重建、'
  'confirmed/settled/remitted/cancelled 跳過（confirmed 起鎖定）。';

-- ------------------------------------------------------------
-- 5. confirm v2：接受 draft（總部直接確認）與 sent（店家同意畫押）
--    （其餘與 20260512000015 逐字相同）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_confirm_store_monthly_settlement(p_settlement_id bigint, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_s              store_monthly_settlements%ROWTYPE;
  v_recv_id        BIGINT;
  v_recv_no        TEXT;
  v_now            TIMESTAMPTZ := NOW();
BEGIN
  SELECT * INTO v_s FROM store_monthly_settlements
   WHERE id = p_settlement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found', p_settlement_id;
  END IF;
  IF v_s.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'settlement % not draft/sent (current: %)', p_settlement_id, v_s.status;
  END IF;
  IF v_s.payable_amount <= 0 THEN
    RAISE EXCEPTION 'settlement % amount must be > 0 (got %)',
      p_settlement_id, v_s.payable_amount;
  END IF;

  -- 產 receivable_no（格式：SR-YYYYMM-{store}-{seq}）
  v_recv_no := 'SR-' || to_char(v_s.settlement_month, 'YYYYMM')
            || '-' || v_s.store_id::text
            || '-' || nextval('store_receivables_id_seq')::text;

  -- 建 store_receivable
  INSERT INTO store_receivables (
    tenant_id, receivable_no, store_id,
    source_type, source_id,
    bill_date, due_date, amount,
    status, currency, notes,
    created_by, updated_by
  ) VALUES (
    v_s.tenant_id, v_recv_no, v_s.store_id,
    'store_monthly_settlement', v_s.id,
    (v_s.settlement_month + INTERVAL '1 month' - INTERVAL '1 day')::DATE,  -- 月底
    (v_s.settlement_month + INTERVAL '2 month' - INTERVAL '1 day')::DATE,  -- 次月底
    v_s.payable_amount,
    'pending', 'TWD',
    format('店月結算 %s %s', to_char(v_s.settlement_month, 'YYYY-MM'),
           (SELECT name FROM stores WHERE id = v_s.store_id)),
    p_operator, p_operator
  ) RETURNING id INTO v_recv_id;

  -- 更新 settlement 狀態 + FK
  UPDATE store_monthly_settlements
     SET status                  = 'confirmed',
         confirmed_at            = v_now,
         confirmed_by            = p_operator,
         generated_receivable_id = v_recv_id,
         updated_by              = p_operator,
         updated_at              = v_now
   WHERE id = p_settlement_id;

  RETURN jsonb_build_object(
    'settlement_id', p_settlement_id,
    'receivable_id', v_recv_id,
    'receivable_no', v_recv_no,
    'store_id',      v_s.store_id,
    'amount',        v_s.payable_amount
  );
END;
$function$;

-- ------------------------------------------------------------
-- 6. 估價修正 v2：鎖定判斷 confirmed/settled → confirmed/remitted/settled
--    （sent/disputed 仍可修，配合生成器 v3 重建；其餘與 20260715000110 相同）
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
  IF v_t.status IN ('received','closed') AND v_t.received_at IS NOT NULL THEN
    v_month := DATE_TRUNC('month', v_t.received_at)::DATE;
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

-- ------------------------------------------------------------
-- 7. 送單：draft/disputed → sent（disputed 需全部爭議已處理）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_send_settlement_to_store(
  p_settlement_id BIGINT,
  p_operator      UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_s    store_monthly_settlements%ROWTYPE;
  v_open INTEGER;
BEGIN
  IF NOT public._settlement_caller_is_hq() THEN
    RAISE EXCEPTION '僅總部帳號可送單（role=%）',
      COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  END IF;

  SELECT * INTO v_s FROM store_monthly_settlements WHERE id = p_settlement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found', p_settlement_id;
  END IF;
  IF v_s.status NOT IN ('draft', 'disputed') THEN
    RAISE EXCEPTION '狀態 % 不可送單（僅 draft / 爭議已全部處理的 disputed）', v_s.status;
  END IF;

  IF v_s.status = 'disputed' THEN
    SELECT COUNT(*) INTO v_open
      FROM store_settlement_disputes
     WHERE settlement_id = p_settlement_id AND status = 'open';
    IF v_open > 0 THEN
      RAISE EXCEPTION '尚有 % 筆爭議未處理，處理完才能重新送單', v_open;
    END IF;
  END IF;

  UPDATE store_monthly_settlements
     SET status     = 'sent',
         sent_at    = NOW(),
         sent_by    = p_operator,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_settlement_id;

  RETURN jsonb_build_object(
    'settlement_id', p_settlement_id,
    'status',        'sent',
    'was',           v_s.status
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_send_settlement_to_store IS
  '總部把月結對帳單送給店家線上核對：draft→sent；disputed（爭議全部 resolved 後）→sent。';

-- ------------------------------------------------------------
-- 8. 店家核對：同意畫押（→confirmed）或逐行提出爭議（→disputed）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_review_settlement(
  p_settlement_id BIGINT,
  p_operator      UUID,
  p_agree         BOOLEAN,
  p_disputes      JSONB DEFAULT NULL   -- [{transfer_item_id, reason}, ...]（p_agree=false 必填）
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_s        store_monthly_settlements%ROWTYPE;
  v_d        JSONB;
  v_item_id  BIGINT;
  v_reason   TEXT;
  v_item     RECORD;
  v_count    INTEGER := 0;
  v_confirm  JSONB;
BEGIN
  SELECT * INTO v_s FROM store_monthly_settlements WHERE id = p_settlement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found', p_settlement_id;
  END IF;

  -- 店家本人（store_manager/store_staff 且綁該店）或總部代操作
  IF NOT (public._settlement_caller_in_store(v_s.store_id) OR public._settlement_caller_is_hq()) THEN
    RAISE EXCEPTION '僅該分店帳號（或總部代操作）可核對此對帳單';
  END IF;

  IF v_s.status <> 'sent' THEN
    RAISE EXCEPTION '狀態 % 不可核對（需為 sent 已送核對）', v_s.status;
  END IF;

  IF p_agree THEN
    UPDATE store_monthly_settlements
       SET store_agreed_at = NOW(),
           store_agreed_by = p_operator,
           updated_by      = p_operator,
           updated_at      = NOW()
     WHERE id = p_settlement_id;

    -- 兩邊都同意 → 鎖定（沿用 confirm：產生應收單）
    v_confirm := public.rpc_confirm_store_monthly_settlement(p_settlement_id, p_operator);

    RETURN jsonb_build_object(
      'settlement_id', p_settlement_id,
      'status',        'confirmed',
      'receivable_no', v_confirm ->> 'receivable_no',
      'amount',        v_confirm -> 'amount'
    );
  END IF;

  -- 提出爭議
  IF p_disputes IS NULL OR jsonb_typeof(p_disputes) <> 'array' OR jsonb_array_length(p_disputes) = 0 THEN
    RAISE EXCEPTION '不同意時需至少提出一筆爭議（p_disputes）';
  END IF;

  FOR v_d IN SELECT * FROM jsonb_array_elements(p_disputes)
  LOOP
    v_item_id := (v_d ->> 'transfer_item_id')::BIGINT;
    v_reason  := NULLIF(TRIM(v_d ->> 'reason'), '');
    IF v_item_id IS NULL OR v_reason IS NULL THEN
      RAISE EXCEPTION '每筆爭議需含 transfer_item_id 與 reason（收到 %）', v_d;
    END IF;

    SELECT i.entry_type, i.description, i.sku_id, i.qty_received,
           i.branch_amount, i.received_at
      INTO v_item
      FROM store_monthly_settlement_items i
     WHERE i.settlement_id = p_settlement_id
       AND i.transfer_item_id = v_item_id
     LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'transfer_item % 不在此對帳單明細內', v_item_id;
    END IF;

    INSERT INTO store_settlement_disputes (
      tenant_id, settlement_id, transfer_item_id, item_snapshot, reason, raised_by
    ) VALUES (
      v_s.tenant_id, p_settlement_id, v_item_id,
      jsonb_build_object(
        'entry_type',    v_item.entry_type,
        'description',   v_item.description,
        'sku_id',        v_item.sku_id,
        'qty_received',  v_item.qty_received,
        'branch_amount', v_item.branch_amount,
        'received_at',   v_item.received_at
      ),
      v_reason, p_operator
    )
    ON CONFLICT (settlement_id, transfer_item_id) WHERE status = 'open'
    DO NOTHING;
    v_count := v_count + 1;
  END LOOP;

  UPDATE store_monthly_settlements
     SET status     = 'disputed',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_settlement_id;

  RETURN jsonb_build_object(
    'settlement_id', p_settlement_id,
    'status',        'disputed',
    'disputes',      v_count
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_store_review_settlement IS
  '店家線上核對月結對帳單：p_agree=true 同意畫押（→confirmed、產生應收單）；'
  'false 逐行提出爭議（→disputed，換總部處理）。店家本人或總部代操作。';

-- ------------------------------------------------------------
-- 9. 總部處理爭議
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_resolve_settlement_dispute(
  p_dispute_id BIGINT,
  p_operator   UUID,
  p_note       TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_d    store_settlement_disputes%ROWTYPE;
  v_open INTEGER;
BEGIN
  IF NOT public._settlement_caller_is_hq() THEN
    RAISE EXCEPTION '僅總部帳號可處理爭議';
  END IF;

  SELECT * INTO v_d FROM store_settlement_disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'dispute % not found', p_dispute_id;
  END IF;
  IF v_d.status <> 'open' THEN
    RAISE EXCEPTION 'dispute % 已處理過（%）', p_dispute_id, v_d.status;
  END IF;

  UPDATE store_settlement_disputes
     SET status          = 'resolved',
         resolved_by     = p_operator,
         resolved_at     = NOW(),
         resolution_note = NULLIF(TRIM(p_note), ''),
         updated_at      = NOW()
   WHERE id = p_dispute_id;

  SELECT COUNT(*) INTO v_open
    FROM store_settlement_disputes
   WHERE settlement_id = v_d.settlement_id AND status = 'open';

  RETURN jsonb_build_object(
    'dispute_id',     p_dispute_id,
    'settlement_id',  v_d.settlement_id,
    'open_remaining', v_open
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_resolve_settlement_dispute IS
  '總部標記單筆對帳爭議已處理（修正金額/說明後）；全部 resolved 才能重新送單。';

-- ------------------------------------------------------------
-- 10. 店家已匯款 / 總部確認收款結案
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_mark_settlement_remitted(
  p_settlement_id BIGINT,
  p_operator      UUID,
  p_note          TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_s store_monthly_settlements%ROWTYPE;
BEGIN
  SELECT * INTO v_s FROM store_monthly_settlements WHERE id = p_settlement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found', p_settlement_id;
  END IF;
  IF NOT (public._settlement_caller_in_store(v_s.store_id) OR public._settlement_caller_is_hq()) THEN
    RAISE EXCEPTION '僅該分店帳號（或總部代操作）可標記已匯款';
  END IF;
  IF v_s.status <> 'confirmed' THEN
    RAISE EXCEPTION '狀態 % 不可標記已匯款（需為 confirmed 已鎖定）', v_s.status;
  END IF;

  UPDATE store_monthly_settlements
     SET status      = 'remitted',
         remitted_at = NOW(),
         remitted_by = p_operator,
         remit_note  = NULLIF(TRIM(p_note), ''),
         updated_by  = p_operator,
         updated_at  = NOW()
   WHERE id = p_settlement_id;

  RETURN jsonb_build_object('settlement_id', p_settlement_id, 'status', 'remitted');
END;
$$;

COMMENT ON FUNCTION public.rpc_mark_settlement_remitted IS
  '店家匯款後按「已匯款」：confirmed→remitted，備註可填匯款帳號後五碼等。';

CREATE OR REPLACE FUNCTION public.rpc_settle_store_monthly_settlement(
  p_settlement_id BIGINT,
  p_operator      UUID,
  p_note          TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_s         store_monthly_settlements%ROWTYPE;
  v_r         store_receivables%ROWTYPE;
  v_remaining NUMERIC;
  v_payment   JSONB;
BEGIN
  IF NOT public._settlement_caller_is_hq() THEN
    RAISE EXCEPTION '僅總部帳號可確認收款結案';
  END IF;

  SELECT * INTO v_s FROM store_monthly_settlements WHERE id = p_settlement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found', p_settlement_id;
  END IF;
  -- 正常流程 remitted → settled；店家忘按已匯款但款已到，允許 confirmed 直接結案
  IF v_s.status NOT IN ('remitted', 'confirmed') THEN
    RAISE EXCEPTION '狀態 % 不可結案（需為 remitted / confirmed）', v_s.status;
  END IF;

  -- 同步應收單：把未收餘額一次入帳（沿用既有付款 RPC，含 paid/partially_paid 邏輯）
  IF v_s.generated_receivable_id IS NOT NULL THEN
    SELECT * INTO v_r FROM store_receivables WHERE id = v_s.generated_receivable_id;
    IF FOUND AND v_r.status IN ('pending', 'partially_paid') THEN
      v_remaining := v_r.amount - COALESCE(v_r.paid_amount, 0);
      IF v_remaining > 0 THEN
        v_payment := public.rpc_record_store_receivable_payment(
          v_r.id, v_remaining, 'bank_transfer', CURRENT_DATE, p_operator,
          TRIM(COALESCE('月結結案收款確認', '') || COALESCE('；' || NULLIF(TRIM(p_note), ''), ''))
        );
      END IF;
    END IF;
  END IF;

  UPDATE store_monthly_settlements
     SET status     = 'settled',
         settled_at = NOW(),
         settled_by = p_operator,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_settlement_id;

  RETURN jsonb_build_object(
    'settlement_id', p_settlement_id,
    'status',        'settled',
    'payment',       v_payment
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_settle_store_monthly_settlement IS
  '總部確認收到店家匯款 → 結案：remitted（或 confirmed 補按）→settled，'
  '並把對應應收單未收餘額入帳（rpc_record_store_receivable_payment）。';

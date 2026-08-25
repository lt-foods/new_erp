-- ============================================================
-- 2026-08-25: 店↔店轉貨「轉出即成立、兩邊媒合」＋ 經總倉互助提供店的抵扣修正
--
-- 老闆 2026-08-25 兩項指示：
--   (1) 全補：經總倉互助的提供店本來就該拿到抵扣，回頭把 7、8 月補上。
--   (2) 以後調整為「轉出店一轉出這筆帳就成立，兩邊就媒合完成」。
--
-- 壞在哪（bug，不是政策）：經總倉互助拆兩段 ——
--   Leg-1 提供店→總倉（store_to_store、customer_order_id IS NULL）
--   Leg-2 總倉→收貨店（hq_to_store、掛訂單）
--   Leg-1 掉進 free_out 分類，而那一類是**按估價 estimated_amount 計價**
--   （20260714000100 給自由轉貨的虛擬 SKU 用的）。互助 Leg-1 是真商品、
--   沒有估價欄 → 一律算 0；Leg-2 卻照 hq_inbound 跟收貨店收全額。
--   結果：提供店白給、收貨店照付，總倉兩頭賺 —— 而 20260714000100 檔頭
--   自己寫的設計意圖是「兩店分錄鏡像同額，總倉純過帳（淨額 0）、只當交易所」。
--   線上實況：6 條 Leg-1、已入帳 3 條，提供店應得而未得（分店價口徑）
--   松山 7 月、古華 8 月各一批。
--
-- 改法：
--   1. 新增 v_store_aid_transfer_legs —— 店↔店「訂單相關」轉貨的記帳腿，
--      一趟一列（品項層級），**時點＝轉出店 shipped_at、數量＝qty_shipped**。
--      經總倉的 Leg-1 在這裡直接對到 Leg-2 的收貨店，兩邊同一時點、同一金額。
--   2. air_in / air_out 改吃這支 view（原本綁 customer_order_id IS NOT NULL
--      ＋收貨時點，經總倉的 Leg-1 因為沒掛訂單根本進不來）。
--   3. hq_inbound 排除經總倉 Leg-2（否則收貨店被收兩次）。
--   4. free_in / free_out 排除 Leg-1（它不是自由轉貨，已改由 air_out 入帳）。
--   5. 張數／筆數同步改成同一套母體。
--
-- ⚠ 刻意**沒有**動的（範圍控制，改了會把錢搬到已寄出／已匯款的月份）：
--   - 自由轉貨（free_in/free_out）維持收貨時點＋估價。線上有跨月資料：
--     7 月出貨 8 月收 $16,018、6 月出貨 7 月收 $407（7 月已寄出、6 月有已匯款
--     的月結，生成器跳過已匯款 → 那 $407 會從 7 月消失卻補不進 6 月）。
--     要一併改成出貨時點，得先決定那兩筆怎麼處理。
--   - hq_to_store（總倉→分店補貨）維持收貨時點：店端點收數量才是應付依據，
--     短收時用出貨量會多收店家。
--   - return_to_hq 維持收貨時點（總倉點收）。
--   訂單相關的店↔店轉貨零跨月（實測 194 筆同月、54 筆跨月全是自由轉貨），
--   所以第 2 點回頭套用不會讓任何金額換月。
--
-- 已知取捨：改用 qty_shipped 之後，短收／拒收不會自動調帳（線上目前
--   出收量不同的只有 3 筆）。那是兩家店之間要處理的差異，需要時用
--   store_settlement_adjustments 人工調整。
--
-- 基底：rpc_generate_hq_to_store_settlement 線上 prosrc
--       md5 728af081fbcedf4d21b996289e8e6cd4（= 20260807000000 之後的現行版），
--       逐字保留，只改上述 5 處。
-- Rollback：重跑 20260807000000_settlement_taipei_month_boundary.sql，
--           並 DROP VIEW public.v_store_aid_transfer_legs;
--           之後重跑 rpc_generate_hq_to_store_settlement('2026-07-01'/'2026-08-01')。
-- ============================================================

-- ------------------------------------------------------------
-- 店↔店「訂單相關」轉貨的記帳腿（空中轉直送 + 經總倉互助的 Leg-1）
--
-- 為什麼要有這支：兩種路徑在 transfers 上長得完全不一樣 ——
--   空中轉：一段，store_to_store、掛訂單、source→dest 就是兩家店。
--   經總倉：兩段，Leg-1 沒掛訂單、dest 是總倉，真正的收貨店在 Leg-2 上。
-- 月結要的是「哪兩家店、什麼時候、多少錢」，所以在這裡先正規化成同一個形狀，
-- 上面的 air_in / air_out 才能用同一套條件、保證兩邊鏡像。
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_store_aid_transfer_legs
WITH (security_invoker = true) AS
SELECT
  t.tenant_id,
  t.id                                        AS transfer_id,
  ti.id                                       AS transfer_item_id,
  ti.sku_id,
  ti.qty_shipped                              AS qty,
  COALESCE(sm.unit_cost, 0)                   AS unit_cost,
  -- 這筆帳成立的時間＝轉出店出貨當下（不是收貨店收到的時候）
  t.shipped_at                                AS booked_at,
  t.source_location                           AS src_location,
  -- 經總倉：真正的收貨店在 Leg-2 上；空中轉：就是自己的 dest
  COALESCE(t2.dest_location, t.dest_location)  AS dst_location,
  (t.next_transfer_id IS NOT NULL)            AS via_hq
  FROM transfers t
  JOIN transfer_items ti ON ti.transfer_id = t.id
  LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
  LEFT JOIN transfers t2 ON t2.id = t.next_transfer_id AND t2.status <> 'cancelled'
 WHERE t.transfer_type = 'store_to_store'
   -- 出過貨就算數（shipped 起算），取消的不算
   AND t.status IN ('shipped','received','closed')
   AND t.shipped_at IS NOT NULL
   AND ti.qty_shipped > 0
   -- 訂單相關才進來：空中轉掛訂單、經總倉 Leg-1 靠 next_transfer_id 認。
   -- 兩者都不是 = 自由轉貨，維持走 free_in/free_out（估價、收貨時點）
   AND (t.customer_order_id IS NOT NULL OR t.next_transfer_id IS NOT NULL);

COMMENT ON VIEW public.v_store_aid_transfer_legs IS
  '店↔店訂單相關轉貨的記帳腿（空中轉直送 + 經總倉互助 Leg-1），品項層級一趟一列。'
  'booked_at = 轉出店出貨當下（老闆 2026-08-25「轉出即成立、兩邊媒合完成」），'
  'qty = qty_shipped，dst_location 已把經總倉的 Leg-1 對到 Leg-2 的收貨店。'
  '月結的 air_in / air_out 就吃這支，兩邊保證同時點同金額。自由轉貨不在此列。';

GRANT SELECT ON public.v_store_aid_transfer_legs TO authenticated;

-- ------------------------------------------------------------
-- 月結生成器：air_in / air_out 改吃上面那支 view；
-- hq_inbound 排除經總倉 Leg-2、free_* 排除 Leg-1。其餘逐字保留。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_generate_hq_to_store_settlement(
  p_month date,
  p_operator uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$

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
       AND ti.qty_received > 0
       -- 經總倉互助的 Leg-2 不算 hq_inbound：那批貨是別家店給的，已經在
       -- Leg-1 出貨當下由 air_in/air_out 兩邊媒合入帳（20260825030000）
       AND NOT EXISTS (
             SELECT 1 FROM transfers t1
              WHERE t1.next_transfer_id = t.id
                AND t1.transfer_type = 'store_to_store'
                AND t1.status <> 'cancelled');

    -- B) air_in: 店↔店轉貨收進來（該店是收貨店）
    -- 記帳時點＝**轉出店出貨當下**（老闆 2026-08-25：「轉出店一轉出這筆帳就
    -- 成立，兩邊就媒合完成」）→ 走 v_store_aid_transfer_legs，它已把經總倉的
    -- Leg-1 對到 Leg-2 的收貨店，兩邊同一時點、同一金額。
    SELECT
      COALESCE(SUM(l.qty * l.unit_cost), 0),
      COALESCE(SUM(l.qty * COALESCE(public._branch_price_at(v_tenant, l.sku_id, l.booked_at), 0)), 0)
      INTO v_air_in, v_air_in_b
      FROM public.v_store_aid_transfer_legs l
     WHERE l.tenant_id = v_tenant
       AND l.dst_location = v_store.location_id
       AND l.booked_at >= v_range_start
       AND l.booked_at < v_range_end;

    -- C) air_out: 店↔店轉貨送出去（該店是轉出店）—— 同 B 的時點與母體，只是
    -- 站在轉出店那一側（貸記）。經總倉的提供店以前掉進 free_out、用「估價」計價，
    -- 而真商品沒有估價 → 一律 0，兩邊的帳從來沒鏡像過。本次修正。
    SELECT
      COALESCE(SUM(l.qty * l.unit_cost), 0),
      COALESCE(SUM(l.qty * COALESCE(public._branch_price_at(v_tenant, l.sku_id, l.booked_at), 0)), 0)
      INTO v_air_out, v_air_out_b
      FROM public.v_store_aid_transfer_legs l
     WHERE l.tenant_id = v_tenant
       AND l.src_location = v_store.location_id
       AND l.booked_at >= v_range_start
       AND l.booked_at < v_range_end;

    -- D) free_in: 自由轉貨收進來（估價入帳、兩口徑同額）
    SELECT
      COALESCE(SUM(COALESCE(ti.estimated_amount, 0)), 0)
      INTO v_free_in
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       -- 經總倉互助的 Leg-1 不是自由轉貨：它有真商品、沒有估價，留在這裡等於
       -- 計價 0（20260825030000 起改由 air_out 以成本／分店價入帳）
       AND t.next_transfer_id IS NULL
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
       -- 經總倉互助的 Leg-1 不是自由轉貨：它有真商品、沒有估價，留在這裡等於
       -- 計價 0（20260825030000 起改由 air_out 以成本／分店價入帳）
       AND t.next_transfer_id IS NULL
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
    -- 張數／筆數要跟上面的分錄同母體：收貨時點那幾類 + 出貨時點的店↔店腿
    SELECT COUNT(DISTINCT x.tid), COUNT(*)
      INTO v_xfer_count, v_item_count
      FROM (
        SELECT t.id AS tid, ti.id AS iid
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.tenant_id = v_tenant
           AND t.status IN ('received','closed')
           AND t.received_at >= v_range_start
           AND t.received_at < v_range_end
           AND ti.qty_received > 0
           AND (
             (t.transfer_type = 'hq_to_store' AND t.dest_location = v_store.location_id
              AND NOT EXISTS (SELECT 1 FROM transfers t1
                               WHERE t1.next_transfer_id = t.id
                                 AND t1.transfer_type = 'store_to_store'
                                 AND t1.status <> 'cancelled'))
             OR
             (t.transfer_type = 'store_to_store' AND t.customer_order_id IS NULL
              AND t.next_transfer_id IS NULL
              AND (t.dest_location = v_store.location_id OR t.source_location = v_store.location_id))
             OR
             (t.transfer_type = 'return_to_hq' AND t.source_location = v_store.location_id)
           )
        UNION ALL
        SELECT l.transfer_id, l.transfer_item_id
          FROM public.v_store_aid_transfer_legs l
         WHERE l.tenant_id = v_tenant
           AND (l.dst_location = v_store.location_id OR l.src_location = v_store.location_id)
           AND l.booked_at >= v_range_start
           AND l.booked_at < v_range_end
      ) x;

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
       AND ti.qty_received > 0
       -- 經總倉互助的 Leg-2 不算 hq_inbound：那批貨是別家店給的，已經在
       -- Leg-1 出貨當下由 air_in/air_out 兩邊媒合入帳（20260825030000）
       AND NOT EXISTS (
             SELECT 1 FROM transfers t1
              WHERE t1.next_transfer_id = t.id
                AND t1.transfer_type = 'store_to_store'
                AND t1.status <> 'cancelled');

    -- B) air_in items（雙口徑）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, l.transfer_id, l.transfer_item_id,
      l.sku_id, l.qty, l.unit_cost,
      l.qty * l.unit_cost,
      -- received_at 欄位存的是**這筆帳成立的時間**＝轉出店出貨當下
      l.booked_at, 'air_in',
      bp.p, l.qty * bp.p
      FROM public.v_store_aid_transfer_legs l
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, l.sku_id, l.booked_at), 0) AS p
      ) bp
     WHERE l.tenant_id = v_tenant
       AND l.dst_location = v_store.location_id
       AND l.booked_at >= v_range_start
       AND l.booked_at < v_range_end;

    -- C) air_out items（兩口徑皆負值）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, l.transfer_id, l.transfer_item_id,
      l.sku_id, l.qty, l.unit_cost,
      -1 * l.qty * l.unit_cost,  -- 負值
      l.booked_at, 'air_out',
      bp.p, -1 * l.qty * bp.p
      FROM public.v_store_aid_transfer_legs l
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, l.sku_id, l.booked_at), 0) AS p
      ) bp
     WHERE l.tenant_id = v_tenant
       AND l.src_location = v_store.location_id
       AND l.booked_at >= v_range_start
       AND l.booked_at < v_range_end;

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
       -- 經總倉互助的 Leg-1 不是自由轉貨：它有真商品、沒有估價，留在這裡等於
       -- 計價 0（20260825030000 起改由 air_out 以成本／分店價入帳）
       AND t.next_transfer_id IS NULL
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
       -- 經總倉互助的 Leg-1 不是自由轉貨：它有真商品、沒有估價，留在這裡等於
       -- 計價 0（20260825030000 起改由 air_out 以成本／分店價入帳）
       AND t.next_transfer_id IS NULL
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
$fn$;

GRANT EXECUTE ON FUNCTION public.rpc_generate_hq_to_store_settlement(date, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_generate_hq_to_store_settlement(date, uuid) IS
  'HQ→店月結算。payable = hq_inbound + air_in − air_out + free_in − free_out − return_out + 人工調整（分店價口徑）。'
  '店↔店訂單相關轉貨（空中轉／經總倉互助）以**轉出店出貨當下**入帳、兩邊鏡像同額'
  '（v_store_aid_transfer_legs）；經總倉 Leg-2 不重複計 hq_inbound、Leg-1 不再誤入 free_out。'
  '自由轉貨、hq_to_store、return_to_hq 維持收貨時點。'
  '已 confirmed/settled/remitted/cancelled 不重算。基底 20260807000000。';

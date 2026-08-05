-- ============================================================
-- 庫存減抵單：短少的訂單用「店內現貨」直接交貨結案
--
-- 動機：2026-07-31 松山店的薏仁精粹洗碗精（G01196-01）派 6 瓶、訂單 8 瓶，
--   短少 2 瓶被標成待補貨、客人不能取。但店內架上本來就有現貨，
--   店家直接拿現貨給客人就好 —— 系統卻沒有任何方式表達這件事，
--   收貨頁的「⚠ 少 2 件」永遠掛著、取貨閘門也一直擋。
--
-- 運作方式（跟店家實際動作一致）：
--   1. 店內現貨若帳上沒有 → 先到「庫存總覽」用 rpc_add_stock_by_product
--      把現貨補進帳（manual_adjust +N）。
--   2. 開減抵單（rpc_create_inventory_deduction）：挑要交貨的待補貨品項，
--      開單當下就從店倉轉給會員 —— 內部直接走 rpc_record_pickup，
--      寫 sale(-N) 庫存異動、品項標已取貨、訂單照常結案，
--      跟客人到店取貨走同一套帳，之後不會重複扣。
--   3. 開單前檢查店倉可用量（on_hand − reserved）≥ 交貨量，
--      不夠就擋下並提示先去庫存總覽補庫存。
--
-- 對既有機制的影響：
--   - 短少警示（rpc_get_ship_vs_demand_for_transfers）short 淨掉減抵量，
--     並回傳 covered 讓收貨頁顯示「現貨減抵 N 件」。
--   - 配貨視窗（rpc_get_allocation_candidates）回傳 covered / notes /
--     store_on_hand / ctx（store_id, campaign_id）供快捷開單。
--   - 取貨閘門 is_order_item_pickup_ready 加 Path D：整批都沒到、
--     缺口全用現貨吸收的極端情況也放行（Path B 要 qty_received > 0）。
--     哪些行可交由 backorder_at 控管，減抵單 RPC 只解除自己要交貨的行。
--
-- 基底版本：
--   rpc_get_ship_vs_demand_for_transfers = 20260805000050（唯一版本）
--   rpc_get_allocation_candidates        = 20260805000060（唯一版本）
--   is_order_item_pickup_ready           = 20260805000060（前版 20260704000000）
--   rpc_record_pickup                    = 20260801000000（只呼叫、不改）
-- rollback:
--   重跑 20260805000050 的 rpc_get_ship_vs_demand_for_transfers、
--   20260805000060 的 rpc_get_allocation_candidates 與 is_order_item_pickup_ready；
--   DROP FUNCTION IF EXISTS public.rpc_create_inventory_deduction(BIGINT,BIGINT,BIGINT,JSONB,TEXT,UUID,BIGINT);
--   DROP FUNCTION IF EXISTS public.rpc_add_stock_by_product(BIGINT,BIGINT,NUMERIC,TEXT,UUID);
--   DROP FUNCTION IF EXISTS public.rpc_list_inventory_deduction_notes(BIGINT,INT);
--   DROP FUNCTION IF EXISTS public.rpc_get_backorder_items_for_store(BIGINT);
--   DROP TABLE IF EXISTS inventory_deduction_note_items;
--   DROP TABLE IF EXISTS inventory_deduction_notes;
--   DROP SEQUENCE IF EXISTS deduction_note_seq;
-- ============================================================

-- ------------------------------------------------------------
-- 1. 減抵單（主檔 + 明細行）
-- ------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS deduction_note_seq;

CREATE TABLE IF NOT EXISTS inventory_deduction_notes (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  note_no      TEXT NOT NULL,
  campaign_id  BIGINT NOT NULL,
  store_id     BIGINT NOT NULL,
  sku_id       BIGINT NOT NULL,
  transfer_id  BIGINT REFERENCES transfers(id),
  qty          NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  reason       TEXT,
  created_by   UUID NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  cancelled_by UUID,
  cancelled_at TIMESTAMPTZ,
  UNIQUE (tenant_id, note_no)
);

COMMENT ON TABLE inventory_deduction_notes IS
  '庫存減抵單：某組 (團,店,品項) 短少的訂單改用店內現貨直接交貨結案。'
  '開單當下走 rpc_record_pickup 扣庫存＋結案（與到店取貨同一套帳）。'
  'cancelled_at 目前恆為 NULL（開錯請走既有退貨流程沖回），保留欄位供未來作廢用。';
COMMENT ON COLUMN inventory_deduction_notes.transfer_id IS
  '從哪張派貨單的配貨視窗開的（追溯用）；獨立頁面開的為 NULL。';

CREATE TABLE IF NOT EXISTS inventory_deduction_note_items (
  id            BIGSERIAL PRIMARY KEY,
  note_id       BIGINT NOT NULL REFERENCES inventory_deduction_notes(id) ON DELETE CASCADE,
  order_id      BIGINT NOT NULL,
  order_item_id BIGINT NOT NULL,   -- 開單當下的品項行（部分交貨拆行後 = 原行 id）
  qty           NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE inventory_deduction_note_items IS
  '減抵單明細：這張單交貨了哪些訂單品項、各交幾件。';

CREATE INDEX IF NOT EXISTS idx_idn_items_note ON inventory_deduction_note_items (note_id);

-- 取貨閘門與額度計算都以 (tenant,campaign,store,sku) 整組查有效減抵
CREATE INDEX IF NOT EXISTS idx_idn_group
  ON inventory_deduction_notes (tenant_id, campaign_id, store_id, sku_id)
  WHERE cancelled_at IS NULL;

-- 讀寫全走 SECURITY DEFINER RPC；不開任何 policy = 擋掉所有直接存取
ALTER TABLE inventory_deduction_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_deduction_note_items ENABLE ROW LEVEL SECURITY;

-- 同 session 內的前一版草稿（宣告式、不扣庫存）已部署過線上，簽名不同要先拆掉
DROP FUNCTION IF EXISTS public.rpc_create_inventory_deduction(BIGINT, BIGINT, NUMERIC, TEXT, UUID);
DROP FUNCTION IF EXISTS public.rpc_cancel_inventory_deduction(BIGINT, UUID);

-- ------------------------------------------------------------
-- 2. rpc_add_stock_by_product — 庫存總覽「依商品新增庫存」
--    店內現貨常是帳外的（例：自購/贈品/盤盈沒入帳），開減抵單前先把帳補上。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_add_stock_by_product(
  p_location_id BIGINT,
  p_sku_id      BIGINT,
  p_qty         NUMERIC,
  p_reason      TEXT,
  p_operator    UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_loc      locations%ROWTYPE;
  v_move_id  BIGINT;
  v_on_hand  NUMERIC;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION '新增庫存數量必須 > 0';
  END IF;

  SELECT * INTO v_loc FROM locations WHERE id = p_location_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '倉別 % 不存在', p_location_id;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM skus WHERE id = p_sku_id) THEN
    RAISE EXCEPTION '品項 % 不存在', p_sku_id;
  END IF;

  -- unit_cost 留 NULL：apply_movement_to_balance 只在有成本時才動均成本
  INSERT INTO stock_movements (
    tenant_id, location_id, sku_id, quantity, movement_type,
    reason, operator_id
  ) VALUES (
    v_loc.tenant_id, p_location_id, p_sku_id, p_qty, 'manual_adjust',
    COALESCE(NULLIF(TRIM(p_reason), ''), '庫存總覽手動新增庫存'), p_operator
  ) RETURNING id INTO v_move_id;

  SELECT on_hand INTO v_on_hand
    FROM stock_balances
   WHERE tenant_id = v_loc.tenant_id AND location_id = p_location_id AND sku_id = p_sku_id;

  RETURN jsonb_build_object('movement_id', v_move_id, 'on_hand', COALESCE(v_on_hand, 0));
END;
$$;

COMMENT ON FUNCTION public.rpc_add_stock_by_product(BIGINT, BIGINT, NUMERIC, TEXT, UUID) IS
  '庫存總覽「依商品新增庫存」：對某倉別某品項寫 manual_adjust(+N)。'
  '不帶成本（均成本不變）。開庫存減抵單前把帳外現貨補進帳用。';

-- ------------------------------------------------------------
-- 3. rpc_create_inventory_deduction — 開減抵單：店內現貨直接交貨結案
--    p_allocations = {"<order_item_id>": <交貨數量>}；只收「待補貨」的品項。
--    開單當下逐訂單呼叫 rpc_record_pickup（sale 異動、品項 picked_up、
--    訂單 completed/partially_completed、pickup event）— 與到店取貨同一套帳。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_inventory_deduction(
  p_store_id    BIGINT,
  p_campaign_id BIGINT,
  p_sku_id      BIGINT,
  p_allocations JSONB,
  p_reason      TEXT,
  p_operator    UUID,
  p_transfer_id BIGINT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_store     stores%ROWTYPE;
  r           RECORD;
  v_take      NUMERIC;
  v_total     NUMERIC := 0;
  v_avail     NUMERIC;
  v_note      inventory_deduction_notes%ROWTYPE;
  v_req_count INT;
  v_ord       RECORD;
  v_items     INT := 0;
  v_orders    INT := 0;
BEGIN
  IF p_allocations IS NULL OR p_allocations = '{}'::jsonb THEN
    RAISE EXCEPTION '沒有選擇要交貨的品項';
  END IF;

  SELECT * INTO v_store FROM stores WHERE id = p_store_id;
  IF NOT FOUND OR v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 不存在或未綁定倉別', p_store_id;
  END IF;

  -- 同組併發開單會各自過庫存檢查，鎖住整組序列化
  PERFORM pg_advisory_xact_lock(hashtext(format('idn:%s:%s:%s:%s',
    v_store.tenant_id, p_campaign_id, p_store_id, p_sku_id)));

  SELECT COUNT(*) INTO v_req_count FROM jsonb_object_keys(p_allocations);

  -- 建立暫存清單：驗證每一行屬於這組、還沒取、且是「待補貨」
  -- （先 DROP：同一交易內逐商品連續開單時 temp table 會殘留）
  DROP TABLE IF EXISTS _idn_targets;
  CREATE TEMP TABLE _idn_targets ON COMMIT DROP AS
  SELECT coi.id AS item_id, coi.order_id, coi.qty AS line_qty,
         LEAST((p_allocations ->> coi.id::text)::numeric, coi.qty) AS take_qty
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE coi.id IN (SELECT k::bigint FROM jsonb_object_keys(p_allocations) AS k)
     AND co.tenant_id       = v_store.tenant_id
     AND co.campaign_id     = p_campaign_id
     AND co.pickup_store_id = p_store_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND coi.sku_id = p_sku_id
     AND coi.status IN ('pending', 'reserved', 'ready')
     AND coi.backorder_at IS NOT NULL;

  IF (SELECT COUNT(*) FROM _idn_targets) <> v_req_count THEN
    RAISE EXCEPTION '有品項不是「待補貨」或已被取走 — 請重新整理畫面。'
      '（減抵單只能交「待補貨」的品項；還沒配貨的請先在配貨視窗儲存配貨）';
  END IF;

  FOR r IN SELECT * FROM _idn_targets LOOP
    IF r.take_qty IS NULL OR r.take_qty <= 0 OR r.take_qty <> FLOOR(r.take_qty) THEN
      RAISE EXCEPTION '品項 % 的交貨數量不合法（須為正整數）', r.item_id;
    END IF;
    v_total := v_total + r.take_qty;
  END LOOP;

  -- 店倉可用量檢查：現貨要先在帳上（庫存總覽可依商品新增庫存）
  SELECT on_hand - reserved INTO v_avail
    FROM stock_balances
   WHERE tenant_id = v_store.tenant_id
     AND location_id = v_store.location_id
     AND sku_id = p_sku_id
   FOR UPDATE;
  IF NOT FOUND THEN v_avail := 0; END IF;

  IF v_avail < v_total THEN
    RAISE EXCEPTION '店內帳上現貨不足：可用 % 件、要交 % 件。請先到「庫存總覽」對該商品新增庫存，再開減抵單',
      v_avail, v_total;
  END IF;

  INSERT INTO inventory_deduction_notes (
    tenant_id, note_no, campaign_id, store_id, sku_id, transfer_id,
    qty, reason, created_by
  ) VALUES (
    v_store.tenant_id,
    'DN' || to_char(NOW(), 'YYMMDD') || lpad(nextval('deduction_note_seq')::text, 4, '0'),
    p_campaign_id, p_store_id, p_sku_id, p_transfer_id,
    v_total, NULLIF(TRIM(p_reason), ''), p_operator
  ) RETURNING * INTO v_note;

  INSERT INTO inventory_deduction_note_items (note_id, order_id, order_item_id, qty)
  SELECT v_note.id, t.order_id, t.item_id, t.take_qty FROM _idn_targets t;

  -- 逐訂單交貨：先解除該訂單要交的行的待補貨（取貨閘門才會放行），
  -- 再走 rpc_record_pickup 入帳（sale 異動、拆行、訂單收尾、pickup event）。
  FOR v_ord IN SELECT DISTINCT order_id FROM _idn_targets LOOP
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = NOW()
      FROM _idn_targets t
     WHERE t.order_id = v_ord.order_id AND coi.id = t.item_id;

    PERFORM public.rpc_record_pickup(
      v_ord.order_id,
      (SELECT array_agg(t.item_id) FROM _idn_targets t WHERE t.order_id = v_ord.order_id),
      p_operator,
      format('庫存減抵單 %s：店內現貨交貨', v_note.note_no),
      (SELECT jsonb_object_agg(t.item_id::text, t.take_qty)
         FROM _idn_targets t WHERE t.order_id = v_ord.order_id)
    );
    v_orders := v_orders + 1;

    -- 部分交貨：rpc_record_pickup 拆行後原行（殘量）仍是 active，
    -- 沒交到的部分要標回待補貨，不然會被誤認為可取
    UPDATE customer_order_items coi
       SET backorder_at = NOW(), backorder_by = p_operator,
           updated_by = p_operator, updated_at = NOW()
      FROM _idn_targets t
     WHERE t.order_id = v_ord.order_id
       AND coi.id = t.item_id
       AND t.take_qty < t.line_qty
       AND coi.status IN ('pending', 'reserved', 'ready');
  END LOOP;

  SELECT COUNT(*) INTO v_items FROM _idn_targets;

  RETURN jsonb_build_object(
    'id', v_note.id, 'note_no', v_note.note_no, 'qty', v_total,
    'items', v_items, 'orders', v_orders
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_inventory_deduction(BIGINT, BIGINT, BIGINT, JSONB, TEXT, UUID, BIGINT) IS
  '開庫存減抵單：待補貨品項改用店內現貨直接交貨結案。'
  '開單當下檢查店倉可用量、逐訂單走 rpc_record_pickup（與到店取貨同一套帳，不會重複扣）。'
  'p_allocations={"<order_item_id>":<交貨數量>}，可小於行量（拆行、殘量續掛待補貨）。';

-- ------------------------------------------------------------
-- 4. rpc_get_backorder_items_for_store — 某分店所有待補貨品項（獨立頁面開單用）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_backorder_items_for_store(
  p_store_id BIGINT
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'item_id',       x.item_id,
           'order_id',      x.order_id,
           'order_no',      x.order_no,
           'customer',      x.customer,
           'campaign_id',   x.campaign_id,
           'campaign_name', x.campaign_name,
           'sku_id',        x.sku_id,
           'sku_code',      x.sku_code,
           'sku_label',     x.sku_label,
           'qty',           x.qty,
           'backorder_at',  x.backorder_at,
           'ordered_at',    x.ordered_at,
           'store_on_hand', x.store_on_hand
         ) ORDER BY x.sku_label, x.ordered_at, x.order_no), '[]'::jsonb)
    FROM (
      SELECT coi.id AS item_id,
             co.id  AS order_id,
             co.order_no,
             COALESCE(m.name, co.nickname_snapshot) AS customer,
             co.campaign_id,
             gc.name AS campaign_name,
             coi.sku_id,
             s.sku_code,
             (COALESCE(s.product_name, '') ||
              CASE WHEN s.variant_name IS NOT NULL THEN ' / ' || s.variant_name ELSE '' END) AS sku_label,
             coi.qty,
             coi.backorder_at,
             co.created_at AS ordered_at,
             COALESCE(sb.on_hand - sb.reserved, 0) AS store_on_hand
        FROM customer_order_items coi
        JOIN customer_orders co ON co.id = coi.order_id
        JOIN stores st ON st.id = co.pickup_store_id
        JOIN skus s ON s.id = coi.sku_id
        LEFT JOIN group_buy_campaigns gc ON gc.id = co.campaign_id
        LEFT JOIN members m ON m.id = co.member_id
        LEFT JOIN stock_balances sb
          ON sb.tenant_id = co.tenant_id
         AND sb.location_id = st.location_id
         AND sb.sku_id = coi.sku_id
       WHERE co.pickup_store_id = p_store_id
         AND co.status NOT IN ('cancelled', 'expired', 'transferred_out', 'completed')
         AND coi.status IN ('pending', 'reserved', 'ready')
         AND coi.backorder_at IS NOT NULL
    ) x;
$$;

COMMENT ON FUNCTION public.rpc_get_backorder_items_for_store(BIGINT) IS
  '某分店所有「待補貨」品項（含店倉現貨可用量），庫存減抵單頁面開單用。';

-- ------------------------------------------------------------
-- 5. rpc_list_inventory_deduction_notes — 減抵單歷史清單
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_list_inventory_deduction_notes(
  p_store_id BIGINT DEFAULT NULL,
  p_limit    INT DEFAULT 50
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id',            n.id,
           'note_no',       n.note_no,
           'qty',           n.qty,
           'reason',        n.reason,
           'created_at',    n.created_at,
           'store_id',      n.store_id,
           'store_name',    st.name,
           'campaign_id',   n.campaign_id,
           'campaign_name', gc.name,
           'sku_code',      s.sku_code,
           'sku_label',     (COALESCE(s.product_name, '') ||
                             CASE WHEN s.variant_name IS NOT NULL THEN ' / ' || s.variant_name ELSE '' END),
           'lines',         COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'order_no', co.order_no,
                      'customer', COALESCE(m.name, co.nickname_snapshot),
                      'qty',      li.qty
                    ) ORDER BY li.id)
               FROM inventory_deduction_note_items li
               JOIN customer_orders co ON co.id = li.order_id
               LEFT JOIN members m ON m.id = co.member_id
              WHERE li.note_id = n.id
           ), '[]'::jsonb)
         ) ORDER BY n.id DESC), '[]'::jsonb)
    FROM (
      SELECT * FROM inventory_deduction_notes n0
       WHERE (p_store_id IS NULL OR n0.store_id = p_store_id)
       ORDER BY n0.id DESC
       LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    ) n
    JOIN stores st ON st.id = n.store_id
    JOIN skus s ON s.id = n.sku_id
    LEFT JOIN group_buy_campaigns gc ON gc.id = n.campaign_id;
$$;

COMMENT ON FUNCTION public.rpc_list_inventory_deduction_notes(BIGINT, INT) IS
  '庫存減抵單歷史清單（含明細行的訂單/顧客），減抵單頁面用。';

-- ------------------------------------------------------------
-- 6. 短少警示淨掉減抵量，並回傳 covered
--    over 維持看原始需求（減抵不該把單變成「多給」）；
--    covered 以該線原始缺口為上限，同組別批（short=0 的線）不會誤掛減抵標籤。
--    （基底：20260805000050，逐字保留原 join，只加 cov LATERAL 與欄位）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_ship_vs_demand_for_transfers(
  p_transfer_ids BIGINT[]
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH pw AS (
    SELECT pwi.generated_transfer_id      AS tid,
           pwi.tenant_id,
           pwi.campaign_id,
           pwi.store_id,
           pwi.sku_id,
           COALESCE(pwi.picked_qty, pwi.qty) AS shipped
      FROM picking_wave_items pwi
     WHERE pwi.generated_transfer_id = ANY(p_transfer_ids)
       AND pwi.campaign_id IS NOT NULL
  ),
  dem AS (
    SELECT pw.tid, pw.shipped, d.demand, cov.covered
      FROM pw
      CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(coi.qty), 0) AS demand
          FROM customer_orders co
          JOIN customer_order_items coi
            ON coi.order_id = co.id
           AND coi.sku_id   = pw.sku_id
           AND coi.status NOT IN ('cancelled', 'expired')
         WHERE co.tenant_id       = pw.tenant_id
           AND co.campaign_id     = pw.campaign_id
           AND co.pickup_store_id = pw.store_id
           AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
           AND co.transferred_from_order_id IS NULL
           AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      ) d
      CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(n.qty), 0) AS covered
          FROM inventory_deduction_notes n
         WHERE n.tenant_id   = pw.tenant_id
           AND n.campaign_id = pw.campaign_id
           AND n.store_id    = pw.store_id
           AND n.sku_id      = pw.sku_id
           AND n.cancelled_at IS NULL
      ) cov
  ),
  per_transfer AS (
    SELECT dem.tid,
           SUM(GREATEST(dem.shipped - dem.demand, 0))               AS over_qty,
           SUM(GREATEST(dem.demand - dem.shipped - dem.covered, 0)) AS short_qty,
           SUM(LEAST(dem.covered, GREATEST(dem.demand - dem.shipped, 0))) AS covered_qty
      FROM dem
     GROUP BY dem.tid
    HAVING SUM(GREATEST(dem.shipped - dem.demand, 0)) > 0
        OR SUM(GREATEST(dem.demand - dem.shipped - dem.covered, 0)) > 0
        OR SUM(LEAST(dem.covered, GREATEST(dem.demand - dem.shipped, 0))) > 0
  )
  SELECT COALESCE(
           jsonb_object_agg(
             per_transfer.tid::text,
             jsonb_build_object('over', per_transfer.over_qty,
                                'short', per_transfer.short_qty,
                                'covered', per_transfer.covered_qty)
           ),
           '{}'::jsonb)
    FROM per_transfer;
$$;

-- ------------------------------------------------------------
-- 7. 配貨視窗資料：加 covered / notes / store_on_hand / ctx
--    （基底：20260805000060，逐字保留原 CTE，只加欄位）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_allocation_candidates(
  p_transfer_id BIGINT,
  p_sku_id      BIGINT
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH ctx AS (
    SELECT pwi.tenant_id, pwi.campaign_id, pwi.store_id, pwi.sku_id
      FROM picking_wave_items pwi
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND pwi.sku_id = p_sku_id
       AND pwi.campaign_id IS NOT NULL
     LIMIT 1
  ),
  supplied AS (
    -- 同一個 (團,店,品項) 可能分好幾批到，全部已收的實收量都算進可配額度
    SELECT COALESCE(SUM(ti.qty_received), 0) AS qty
      FROM ctx
      JOIN picking_wave_items pwi
        ON pwi.tenant_id = ctx.tenant_id AND pwi.campaign_id = ctx.campaign_id
       AND pwi.store_id  = ctx.store_id  AND pwi.sku_id      = ctx.sku_id
      JOIN transfers t      ON t.id = pwi.generated_transfer_id
                           AND t.status IN ('received', 'closed')
      JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = ctx.sku_id
  ),
  covered AS (
    SELECT COALESCE(SUM(n.qty), 0) AS qty
      FROM ctx
      JOIN inventory_deduction_notes n
        ON n.tenant_id = ctx.tenant_id AND n.campaign_id = ctx.campaign_id
       AND n.store_id  = ctx.store_id  AND n.sku_id      = ctx.sku_id
     WHERE n.cancelled_at IS NULL
  ),
  rows_all AS (
    SELECT coi.id            AS item_id,
           co.id             AS order_id,
           co.order_no,
           COALESCE(m.name, co.nickname_snapshot) AS customer,
           co.status         AS order_status,
           coi.status        AS item_status,
           coi.qty,
           coi.backorder_at,
           co.created_at
      FROM ctx
      JOIN customer_orders co
        ON co.tenant_id        = ctx.tenant_id
       AND co.campaign_id      = ctx.campaign_id
       AND co.pickup_store_id  = ctx.store_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND co.transferred_from_order_id IS NULL
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.sku_id   = ctx.sku_id
       AND coi.status NOT IN ('cancelled', 'expired')
      LEFT JOIN members m ON m.id = co.member_id
  ),
  picked AS (
    SELECT COALESCE(SUM(r.qty), 0) AS qty FROM rows_all r
     WHERE r.item_status IN ('picked_up', 'partially_picked_up')
  )
  SELECT jsonb_build_object(
    'store_id',    (SELECT store_id FROM ctx),
    'campaign_id', (SELECT campaign_id FROM ctx),
    'supplied',  (SELECT qty FROM supplied),
    'covered',   (SELECT qty FROM covered),
    'picked',    (SELECT qty FROM picked),
    'available', GREATEST((SELECT qty FROM supplied) + (SELECT qty FROM covered)
                          - (SELECT qty FROM picked), 0),
    -- 店倉帳上可用現貨（開減抵單前的參考與前端預檢；伺服端還會再檢查一次）
    'store_on_hand', COALESCE((
      SELECT sb.on_hand - sb.reserved
        FROM ctx
        JOIN stores st ON st.id = ctx.store_id
        JOIN stock_balances sb
          ON sb.tenant_id = ctx.tenant_id
         AND sb.location_id = st.location_id
         AND sb.sku_id = ctx.sku_id
    ), 0),
    'notes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', n.id, 'note_no', n.note_no, 'qty', n.qty,
               'reason', n.reason, 'created_at', n.created_at
             ) ORDER BY n.id)
        FROM ctx
        JOIN inventory_deduction_notes n
          ON n.tenant_id = ctx.tenant_id AND n.campaign_id = ctx.campaign_id
         AND n.store_id  = ctx.store_id  AND n.sku_id      = ctx.sku_id
       WHERE n.cancelled_at IS NULL
    ), '[]'::jsonb),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'item_id',      r.item_id,
               'order_id',     r.order_id,
               'order_no',     r.order_no,
               'customer',     r.customer,
               'order_status', r.order_status,
               'qty',          r.qty,
               'backorder',    r.backorder_at IS NOT NULL,
               'created_at',   r.created_at
             ) ORDER BY r.created_at, r.order_no)
        FROM rows_all r
       WHERE r.item_status IN ('pending', 'reserved', 'ready')
    ), '[]'::jsonb)
  );
$$;

-- ------------------------------------------------------------
-- 8. 取貨閘門 Path D：有有效減抵單的組合放行
--    Path B 要該組 qty_received > 0 — 整批都沒到、缺口全用店內現貨吸收時
--    會卡住，所以減抵單本身也算「貨到了」。哪些行可取仍由 backorder_at 控管。
--    （基底：20260805000060，僅在 ELSE 分支追加 Path D，其餘逐字相同）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_order_item_pickup_ready(p_item_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE coi.id = p_item_id
       AND co.status NOT IN ('completed','expired','cancelled','transferred_out')
       -- 只有未取的 active item 才有「可取貨」可言
       AND coi.status IN ('pending','reserved','ready')
       -- 少發配貨：沒配到的品項標成待補貨，在補到之前不可取
       --（rpc_allocate_shortage 寫入 / 清除；沒有缺貨的單這欄永遠是 NULL，行為不變）
       AND coi.backorder_at IS NULL
       AND CASE
         -- aid_transfer + 跨店：只認自己的 transfer 被收貨 (Path A)
         WHEN EXISTS (
                SELECT 1 FROM customer_order_items x
                 WHERE x.order_id = co.id AND x.source = 'aid_transfer'
              )
              AND co.transferred_from_order_id IS NOT NULL
              AND (
                SELECT src.pickup_store_id FROM customer_orders src
                 WHERE src.id = co.transferred_from_order_id
              ) IS DISTINCT FROM co.pickup_store_id
         THEN EXISTS (
           SELECT 1 FROM transfers t
            WHERE t.customer_order_id = co.id
              AND t.tenant_id = co.tenant_id
              AND t.status IN ('received','closed')
         )
         ELSE (
           -- Path A：aid 單 transfer FK 收貨
           EXISTS (
             SELECT 1 FROM transfers t
              WHERE t.customer_order_id = co.id
                AND t.tenant_id = co.tenant_id
                AND t.status IN ('received','closed')
           )
           OR
           -- Path B：campaign 對齊且該波次該 SKU 實收 qty>0
           EXISTS (
             SELECT 1
               FROM picking_wave_items pwi
               JOIN transfers t ON t.id = pwi.generated_transfer_id
               JOIN transfer_items ti ON ti.transfer_id = t.id
                                     AND ti.sku_id = coi.sku_id
              WHERE pwi.tenant_id   = co.tenant_id
                AND pwi.campaign_id = co.campaign_id
                AND pwi.store_id    = co.pickup_store_id
                AND pwi.sku_id      = coi.sku_id
                AND t.status IN ('received','closed')
                AND ti.qty_received > 0
           )
           OR
           -- Path C：該 (campaign,store,sku) 完全無對齊波次（彙整 PR）才退用 store+sku 實收
           (
             NOT EXISTS (
               SELECT 1 FROM picking_wave_items pwi
                WHERE pwi.tenant_id   = co.tenant_id
                  AND pwi.campaign_id = co.campaign_id
                  AND pwi.store_id    = co.pickup_store_id
                  AND pwi.sku_id      = coi.sku_id
             )
             AND EXISTS (
               SELECT 1
                 FROM stores st
                 JOIN transfers t ON t.transfer_type = 'hq_to_store'
                                 AND t.dest_location = st.location_id
                                 AND t.tenant_id     = co.tenant_id
                                 AND t.status IN ('received','closed')
                 JOIN transfer_items ti ON ti.transfer_id = t.id
                                       AND ti.sku_id = coi.sku_id
                                       AND ti.qty_received > 0
                WHERE st.id = co.pickup_store_id
             )
           )
           OR
           -- Path D：庫存減抵單 — 店家用店內現貨吸收這組缺口
           EXISTS (
             SELECT 1 FROM inventory_deduction_notes n
              WHERE n.tenant_id   = co.tenant_id
                AND n.campaign_id = co.campaign_id
                AND n.store_id    = co.pickup_store_id
                AND n.sku_id      = coi.sku_id
                AND n.cancelled_at IS NULL
           )
         )
       END
  );
$function$;

COMMENT ON FUNCTION public.is_order_item_pickup_ready(bigint) IS
  '單一品項是否已到貨可取（Path A/B/C/D，shortage-aware）。'
  '20260703000000 的整單判定搬到品項粒度：未到貨品項個別擋、已到貨可先取。'
  '20260805000060 加上待補貨（backorder_at）擋板：少發配貨時沒配到的品項不可取。'
  '20260805000170 加 Path D：庫存減抵單（店內現貨吸收缺口）也算貨到。';

-- ------------------------------------------------------------
-- 9. 權限
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.rpc_create_inventory_deduction(BIGINT, BIGINT, BIGINT, JSONB, TEXT, UUID, BIGINT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_add_stock_by_product(BIGINT, BIGINT, NUMERIC, TEXT, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_list_inventory_deduction_notes(BIGINT, INT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_get_backorder_items_for_store(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_inventory_deduction(BIGINT, BIGINT, BIGINT, JSONB, TEXT, UUID, BIGINT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_add_stock_by_product(BIGINT, BIGINT, NUMERIC, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_list_inventory_deduction_notes(BIGINT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_backorder_items_for_store(BIGINT) TO authenticated;

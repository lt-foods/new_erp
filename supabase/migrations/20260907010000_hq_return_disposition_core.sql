-- ============================================================
-- 總倉退回貨處理 — A 核心（資料與處理）
-- 20260907010000_hq_return_disposition_core.sql
--
-- 依賴：20260422120003（stock_movements / stock_balances / locations / transfers / transfer_items）
--       20260713000000（movement_type CHECK 最新清單）
--       20260424120000（_current_tenant_id helper）
--
-- 本檔 append-only，不改任何既有表結構（movement_type CHECK 除外：新增兩值）。
-- ============================================================

-- ============================================================
-- 0. movement_type 擴充：hq_return_damage / hq_return_loss
--    基底＝20260713000000 的清單，僅新增，其餘原封不動。
-- ============================================================
ALTER TABLE public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_movement_type_check;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_movement_type_check CHECK (
    movement_type = ANY (ARRAY[
      'purchase_receipt',
      'return_to_supplier',
      'sale',
      'customer_return',
      'transfer_out',
      'transfer_in',
      'transfer_reject',
      'transfer_cancel',
      'stocktake_gain',
      'stocktake_loss',
      'damage',
      'manual_adjust',
      'reversal',
      'hq_return_damage',
      'hq_return_loss'
    ])
  );

-- ============================================================
-- 1. hq_return_batches — 總倉退回貨批次
--
-- 每筆代表「一條正向 stock_movement 送回總倉的那批貨」。
-- source_movement_id UNIQUE 防重複建批。
-- ============================================================
CREATE TABLE public.hq_return_batches (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID        NOT NULL,
  location_id          BIGINT      NOT NULL REFERENCES public.locations(id),
  sku_id               BIGINT      NOT NULL,
  source_movement_id   BIGINT      NOT NULL REFERENCES public.stock_movements(id),
  source_transfer_item_id BIGINT   REFERENCES public.transfer_items(id),
  source_kind          TEXT        NOT NULL CHECK (source_kind IN ('store_return','shortage')),
  source_reason        TEXT,
  total_qty            NUMERIC(18,3) NOT NULL CHECK (total_qty > 0),
  unit_cost            NUMERIC(18,4) NOT NULL DEFAULT 0
                       CHECK (unit_cost >= 0
                              AND unit_cost != 'NaN'::NUMERIC
                              AND unit_cost != 'Infinity'::NUMERIC
                              AND unit_cost != '-Infinity'::NUMERIC),
  qty_good             NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty_good >= 0),
  qty_damaged          NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty_damaged >= 0),
  qty_lost             NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty_lost >= 0),
  qty_revoked          NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty_revoked >= 0),
  status               TEXT        NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','partial','completed','revoked')),
  auto_flag            TEXT        CHECK (auto_flag IS NULL OR auto_flag IN ('system','manual')),
  created_by           UUID        NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- 來源 movement 唯一：同一筆正向 movement 不能建兩個批次
  CONSTRAINT uq_hq_return_source_movement UNIQUE (source_movement_id),

  -- 累積不超過總量（含撤回）
  CONSTRAINT chk_hq_return_qty_sum
    CHECK (qty_good + qty_damaged + qty_lost + qty_revoked <= total_qty),

  -- pending = total - good - damaged - lost - revoked
  -- status 與累積一致
  CONSTRAINT chk_hq_return_status_consistent CHECK (
    CASE
      WHEN qty_good + qty_damaged + qty_lost + qty_revoked = 0 THEN status IN ('pending','revoked')
      WHEN qty_good + qty_damaged + qty_lost + qty_revoked < total_qty THEN status = 'partial'
      WHEN qty_good + qty_damaged + qty_lost + qty_revoked = total_qty THEN status IN ('completed','revoked')
      ELSE FALSE
    END
  ),

  -- NaN / Infinity 防護（數量欄）
  CONSTRAINT chk_hq_return_qty_finite CHECK (
        total_qty    != 'NaN'::NUMERIC AND total_qty    != 'Infinity'::NUMERIC AND total_qty    != '-Infinity'::NUMERIC
    AND qty_good     != 'NaN'::NUMERIC AND qty_good     != 'Infinity'::NUMERIC AND qty_good     != '-Infinity'::NUMERIC
    AND qty_damaged  != 'NaN'::NUMERIC AND qty_damaged  != 'Infinity'::NUMERIC AND qty_damaged  != '-Infinity'::NUMERIC
    AND qty_lost     != 'NaN'::NUMERIC AND qty_lost     != 'Infinity'::NUMERIC AND qty_lost     != '-Infinity'::NUMERIC
    AND qty_revoked  != 'NaN'::NUMERIC AND qty_revoked  != 'Infinity'::NUMERIC AND qty_revoked  != '-Infinity'::NUMERIC
  )
);

COMMENT ON TABLE public.hq_return_batches IS '總倉退回貨批次：每筆來源 movement 唯一，追蹤好/破/失/撤/pending';
COMMENT ON COLUMN public.hq_return_batches.unit_cost IS '來源成本依據（來自 movement.unit_cost 或 0 表示未知），不從售價猜';
COMMENT ON COLUMN public.hq_return_batches.source_kind IS 'store_return＝門市退貨, shortage＝短少';

CREATE INDEX idx_hq_return_batches_tenant_status
  ON public.hq_return_batches (tenant_id, status, created_at DESC);

CREATE INDEX idx_hq_return_batches_tenant_loc_sku
  ON public.hq_return_batches (tenant_id, location_id, sku_id)
  WHERE status IN ('pending','partial');

-- ============================================================
-- 2. hq_return_events — 處理事件（append-only）
--
-- 每次處理（好/破/失分配）產生一筆事件。
-- request_id 冪等：同 UUID 重試回原結果，payload 不同拒絕。
-- ============================================================
CREATE TABLE public.hq_return_events (
  id                   BIGSERIAL PRIMARY KEY,
  batch_id             BIGINT      NOT NULL REFERENCES public.hq_return_batches(id),
  tenant_id            UUID        NOT NULL,
  request_id           UUID        NOT NULL,
  qty_good             NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty_good >= 0),
  qty_damaged          NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty_damaged >= 0),
  qty_lost             NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty_lost >= 0),
  damage_reason        TEXT,
  loss_reason          TEXT,
  goods_confirmed      BOOLEAN     NOT NULL DEFAULT FALSE,
  damage_movement_id   BIGINT      REFERENCES public.stock_movements(id),
  loss_movement_id     BIGINT      REFERENCES public.stock_movements(id),
  notes                TEXT,
  operator_id          UUID        NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- 同 request_id 不可二建
  CONSTRAINT uq_hq_return_event_request UNIQUE (request_id),

  -- 不能全 0
  CONSTRAINT chk_hq_return_event_nonzero CHECK (qty_good + qty_damaged + qty_lost > 0),

  -- 破損需原因
  CONSTRAINT chk_hq_return_event_damage_reason CHECK (qty_damaged = 0 OR damage_reason IS NOT NULL),
  -- 遺失需原因
  CONSTRAINT chk_hq_return_event_loss_reason CHECK (qty_lost = 0 OR loss_reason IS NOT NULL),

  -- NaN / Infinity 防護
  CONSTRAINT chk_hq_return_event_qty_finite CHECK (
        qty_good    != 'NaN'::NUMERIC AND qty_good    != 'Infinity'::NUMERIC AND qty_good    != '-Infinity'::NUMERIC
    AND qty_damaged != 'NaN'::NUMERIC AND qty_damaged != 'Infinity'::NUMERIC AND qty_damaged != '-Infinity'::NUMERIC
    AND qty_lost    != 'NaN'::NUMERIC AND qty_lost    != 'Infinity'::NUMERIC AND qty_lost    != '-Infinity'::NUMERIC
  )
);

COMMENT ON TABLE public.hq_return_events IS '總倉退回貨處理事件：append-only，每次處理一筆';
COMMENT ON COLUMN public.hq_return_events.request_id IS '前端冪等 UUID：重試回原結果，payload 不同拒絕';
COMMENT ON COLUMN public.hq_return_events.goods_confirmed IS '好貨實物已到確認（前端必傳 true 才計入 qty_good）';

CREATE INDEX idx_hq_return_events_batch
  ON public.hq_return_events (batch_id, created_at);

CREATE INDEX idx_hq_return_events_request
  ON public.hq_return_events (request_id);

-- 禁止 UPDATE / DELETE（append-only）
CREATE OR REPLACE FUNCTION public._forbid_hq_return_event_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'hq_return_events is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_update_hq_return_events
  BEFORE UPDATE ON public.hq_return_events
  FOR EACH ROW EXECUTE FUNCTION public._forbid_hq_return_event_mutation();

CREATE TRIGGER trg_no_delete_hq_return_events
  BEFORE DELETE ON public.hq_return_events
  FOR EACH ROW EXECUTE FUNCTION public._forbid_hq_return_event_mutation();

-- ============================================================
-- 3. RLS
--
-- 兩表都開 RLS。authenticated 只讀同 tenant，INSERT/UPDATE/DELETE 全封。
-- 資料寫入只透過 SECURITY DEFINER 函式。
-- ============================================================
ALTER TABLE public.hq_return_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hq_return_events  ENABLE ROW LEVEL SECURITY;

CREATE POLICY hq_return_batches_tenant_read ON public.hq_return_batches
  FOR SELECT TO authenticated
  USING (tenant_id = public._current_tenant_id());

CREATE POLICY hq_return_events_tenant_read ON public.hq_return_events
  FOR SELECT TO authenticated
  USING (tenant_id = public._current_tenant_id());

-- 明確不給 INSERT/UPDATE/DELETE policy → authenticated 直接寫會被 RLS 擋

-- ============================================================
-- 4. _hq_hold_return — 內部 helper：建批次＋同步 reserved
--
-- 參數：
--   p_tenant_id           UUID     — 租戶
--   p_location_id         BIGINT   — 總倉 location（必須 type='central_warehouse'）
--   p_sku_id              BIGINT   — SKU
--   p_source_movement_id  BIGINT   — 正向入庫 movement（quantity > 0，同 tenant）
--   p_source_transfer_item_id BIGINT — 可選，對應 transfer_item
--   p_source_kind         TEXT     — 'store_return' 或 'shortage'
--   p_source_reason       TEXT     — 原因文字
--   p_qty                 NUMERIC  — 回帳量（正數）
--   p_operator_id         UUID     — 操作者
--   p_auto_flag           TEXT     — 'system' 或 'manual'
--
-- 行為：
--   1. 驗證 movement 存在、quantity > 0、同 tenant、SKU 匹配
--   2. 驗證 location type = central_warehouse
--   3. 若同 source_movement_id 已有批次 → 回傳既有 batch_id（冪等，不二建）
--   4. 建批次，同步 stock_balances.reserved += p_qty
--   5. 回傳 batch_id
--
-- ⛔ REVOKE PUBLIC / anon / authenticated — 不作前端 RPC，僅供後端安全呼叫。
-- ============================================================
CREATE OR REPLACE FUNCTION public._hq_hold_return(
  p_tenant_id                UUID,
  p_location_id              BIGINT,
  p_sku_id                   BIGINT,
  p_source_movement_id       BIGINT,
  p_source_transfer_item_id  BIGINT DEFAULT NULL,
  p_source_kind              TEXT DEFAULT 'store_return',
  p_source_reason            TEXT DEFAULT NULL,
  p_qty                      NUMERIC DEFAULT NULL,
  p_operator_id              UUID DEFAULT NULL,
  p_auto_flag                TEXT DEFAULT 'system'
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_mov         RECORD;
  v_loc_type    TEXT;
  v_existing_id BIGINT;
  v_batch_id    BIGINT;
  v_hold_qty    NUMERIC(18,3);
  v_unit_cost   NUMERIC(18,4);
BEGIN
  -- 1. 驗證來源 movement
  SELECT id, tenant_id, location_id, sku_id, quantity, unit_cost
    INTO v_mov
    FROM stock_movements
   WHERE id = p_source_movement_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '_hq_hold_return: source movement % not found', p_source_movement_id;
  END IF;

  IF v_mov.tenant_id != p_tenant_id THEN
    RAISE EXCEPTION '_hq_hold_return: movement % belongs to different tenant', p_source_movement_id;
  END IF;

  IF v_mov.quantity <= 0 THEN
    RAISE EXCEPTION '_hq_hold_return: movement % quantity must be positive (got %)', p_source_movement_id, v_mov.quantity;
  END IF;

  IF v_mov.sku_id != p_sku_id THEN
    RAISE EXCEPTION '_hq_hold_return: movement % sku_id=% does not match p_sku_id=%', p_source_movement_id, v_mov.sku_id, p_sku_id;
  END IF;

  -- 2. 驗證 location type
  SELECT type INTO v_loc_type
    FROM locations
   WHERE id = p_location_id AND tenant_id = p_tenant_id;

  IF v_loc_type IS NULL THEN
    RAISE EXCEPTION '_hq_hold_return: location % not found for tenant', p_location_id;
  END IF;

  IF v_loc_type != 'central_warehouse' THEN
    RAISE EXCEPTION '_hq_hold_return: location % type=% is not central_warehouse', p_location_id, v_loc_type;
  END IF;

  -- 3. 冪等：同 source_movement_id 已有批次 → 回傳既有 id
  SELECT id INTO v_existing_id
    FROM hq_return_batches
   WHERE source_movement_id = p_source_movement_id;

  IF FOUND THEN
    RETURN v_existing_id;
  END IF;

  -- 4. 決定凍結量與成本
  v_hold_qty  := COALESCE(p_qty, v_mov.quantity);
  v_unit_cost := COALESCE(v_mov.unit_cost, 0);

  IF v_hold_qty <= 0 THEN
    RAISE EXCEPTION '_hq_hold_return: hold qty must be positive, got %', v_hold_qty;
  END IF;

  -- 5. 建批次
  INSERT INTO hq_return_batches (
    tenant_id, location_id, sku_id,
    source_movement_id, source_transfer_item_id,
    source_kind, source_reason,
    total_qty, unit_cost,
    auto_flag, created_by
  ) VALUES (
    p_tenant_id, p_location_id, p_sku_id,
    p_source_movement_id, p_source_transfer_item_id,
    p_source_kind, p_source_reason,
    v_hold_qty, v_unit_cost,
    p_auto_flag, COALESCE(p_operator_id, '00000000-0000-0000-0000-000000000000'::UUID)
  ) RETURNING id INTO v_batch_id;

  -- 6. 同步 reserved（鎖 balance 列）
  INSERT INTO stock_balances (tenant_id, location_id, sku_id, reserved)
  VALUES (p_tenant_id, p_location_id, p_sku_id, v_hold_qty)
  ON CONFLICT (tenant_id, location_id, sku_id) DO UPDATE
    SET reserved   = stock_balances.reserved + v_hold_qty,
        updated_at = NOW();

  RETURN v_batch_id;
END;
$$;

-- ⛔ 安全：不開放給任何前端角色
REVOKE ALL ON FUNCTION public._hq_hold_return(UUID, BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, NUMERIC, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._hq_hold_return(UUID, BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, NUMERIC, UUID, TEXT) FROM anon;
REVOKE ALL ON FUNCTION public._hq_hold_return(UUID, BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, NUMERIC, UUID, TEXT) FROM authenticated;

COMMENT ON FUNCTION public._hq_hold_return IS
  '內部 helper：建總倉退回貨批次＋凍結 reserved。僅供後端安全呼叫，'
  'REVOKE 了 PUBLIC/anon/authenticated。同 source_movement_id 冪等回傳既有 id。';

-- ============================================================
-- 5. rpc_dispose_hq_return — 前端 RPC：處理退回批次
--
-- 參數：
--   p_batch_id       BIGINT   — 批次 id
--   p_request_id     UUID     — 冪等 UUID（同 UUID 重試回原結果）
--   p_qty_good       NUMERIC  — 完好數量
--   p_qty_damaged    NUMERIC  — 破損數量
--   p_qty_lost       NUMERIC  — 遺失數量
--   p_damage_reason  TEXT     — 破損原因（破損 > 0 時必填）
--   p_loss_reason    TEXT     — 遺失原因（遺失 > 0 時必填）
--   p_goods_confirmed BOOLEAN — 好貨實物已到確認（好貨 > 0 時必須 true）
--   p_notes          TEXT     — 備註
--
-- 鎖順序：hq_return_batches(id) FOR UPDATE → stock_balances(tenant, location, sku) FOR UPDATE
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_dispose_hq_return(
  p_batch_id        BIGINT,
  p_request_id      UUID,
  p_qty_good        NUMERIC DEFAULT 0,
  p_qty_damaged     NUMERIC DEFAULT 0,
  p_qty_lost        NUMERIC DEFAULT 0,
  p_damage_reason   TEXT    DEFAULT NULL,
  p_loss_reason     TEXT    DEFAULT NULL,
  p_goods_confirmed BOOLEAN DEFAULT FALSE,
  p_notes           TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user          UUID := auth.uid();
  v_tenant        UUID := public._current_tenant_id();
  v_role          TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_batch         RECORD;
  v_pending       NUMERIC(18,3);
  v_this_total    NUMERIC(18,3);
  v_existing      RECORD;
  v_damage_mov_id BIGINT;
  v_loss_mov_id   BIGINT;
  v_event_id      BIGINT;
  v_new_status    TEXT;
BEGIN
  -- 0. auth 必須有值
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: not authenticated';
  END IF;

  -- 1. role 白名單
  IF v_role NOT IN ('owner','admin','hq_manager') THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: permission denied for role %', v_role;
  END IF;

  -- 2. 數量基本檢查
  IF p_qty_good    IS NULL OR p_qty_good    < 0
  OR p_qty_damaged IS NULL OR p_qty_damaged < 0
  OR p_qty_lost    IS NULL OR p_qty_lost    < 0 THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: quantities must be non-negative';
  END IF;

  v_this_total := p_qty_good + p_qty_damaged + p_qty_lost;

  IF v_this_total <= 0 THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: total disposition quantity must be > 0';
  END IF;

  -- NaN / Infinity 防護
  IF v_this_total = 'NaN'::NUMERIC OR v_this_total = 'Infinity'::NUMERIC OR v_this_total = '-Infinity'::NUMERIC THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: invalid numeric value in quantities';
  END IF;

  -- 破損需原因
  IF p_qty_damaged > 0 AND (p_damage_reason IS NULL OR TRIM(p_damage_reason) = '') THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: damage_reason required when qty_damaged > 0';
  END IF;

  -- 遺失需原因
  IF p_qty_lost > 0 AND (p_loss_reason IS NULL OR TRIM(p_loss_reason) = '') THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: loss_reason required when qty_lost > 0';
  END IF;

  -- 好貨需實物確認
  IF p_qty_good > 0 AND NOT p_goods_confirmed THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: goods_confirmed must be true when qty_good > 0';
  END IF;

  -- 3. 冪等：同 request_id 已存在 → 驗 payload 一致後回傳原結果
  SELECT * INTO v_existing
    FROM hq_return_events
   WHERE request_id = p_request_id;

  IF FOUND THEN
    -- payload 驗證：batch_id + 三個數量必須一致
    IF v_existing.batch_id    != p_batch_id
    OR v_existing.qty_good    != p_qty_good
    OR v_existing.qty_damaged != p_qty_damaged
    OR v_existing.qty_lost    != p_qty_lost THEN
      RAISE EXCEPTION 'rpc_dispose_hq_return: request_id % already used with different payload', p_request_id;
    END IF;

    RETURN jsonb_build_object(
      'event_id',    v_existing.id,
      'batch_id',    v_existing.batch_id,
      'idempotent',  TRUE
    );
  END IF;

  -- 4. 鎖批次（鎖順序第一：batch）
  SELECT * INTO v_batch
    FROM hq_return_batches
   WHERE id = p_batch_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: batch % not found', p_batch_id;
  END IF;

  IF v_batch.tenant_id != v_tenant THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: batch % belongs to different tenant', p_batch_id;
  END IF;

  IF v_batch.status IN ('completed','revoked') THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: batch % already %', p_batch_id, v_batch.status;
  END IF;

  -- 5. pending 剩餘量檢查
  v_pending := v_batch.total_qty - v_batch.qty_good - v_batch.qty_damaged - v_batch.qty_lost - v_batch.qty_revoked;

  IF v_this_total > v_pending THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: disposition qty (%) exceeds pending (%) for batch %',
      v_this_total, v_pending, p_batch_id;
  END IF;

  -- 6. 鎖 balance（鎖順序第二：balance）
  PERFORM 1
    FROM stock_balances
   WHERE tenant_id   = v_batch.tenant_id
     AND location_id = v_batch.location_id
     AND sku_id      = v_batch.sku_id
   FOR UPDATE;

  -- 7. 先減 pending/reserved（在寫負 movement 之前，避免被 guard trigger 擋）
  --    reserved 減去破損＋遺失＋好貨（好貨釋回 available，不再凍結）
  UPDATE stock_balances
     SET reserved   = reserved - v_this_total,
         updated_at = NOW()
   WHERE tenant_id   = v_batch.tenant_id
     AND location_id = v_batch.location_id
     AND sku_id      = v_batch.sku_id;

  -- 8. 更新批次累積
  v_new_status := CASE
    WHEN (v_batch.qty_good + p_qty_good) + (v_batch.qty_damaged + p_qty_damaged)
       + (v_batch.qty_lost + p_qty_lost) + v_batch.qty_revoked = v_batch.total_qty
    THEN 'completed'
    ELSE 'partial'
  END;

  UPDATE hq_return_batches
     SET qty_good    = qty_good    + p_qty_good,
         qty_damaged = qty_damaged + p_qty_damaged,
         qty_lost    = qty_lost    + p_qty_lost,
         status      = v_new_status,
         updated_at  = NOW()
   WHERE id = p_batch_id;

  -- 9. 破損 → 寫負 movement（hq_return_damage）
  IF p_qty_damaged > 0 THEN
    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost,
      movement_type, source_doc_type, source_doc_id,
      reason, operator_id, notes
    ) VALUES (
      v_batch.tenant_id, v_batch.location_id, v_batch.sku_id,
      -p_qty_damaged, v_batch.unit_cost,
      'hq_return_damage', 'hq_return_batch', p_batch_id,
      p_damage_reason, v_user, p_notes
    ) RETURNING id INTO v_damage_mov_id;
  END IF;

  -- 10. 遺失 → 寫負 movement（hq_return_loss）
  IF p_qty_lost > 0 THEN
    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost,
      movement_type, source_doc_type, source_doc_id,
      reason, operator_id, notes
    ) VALUES (
      v_batch.tenant_id, v_batch.location_id, v_batch.sku_id,
      -p_qty_lost, v_batch.unit_cost,
      'hq_return_loss', 'hq_return_batch', p_batch_id,
      p_loss_reason, v_user, p_notes
    ) RETURNING id INTO v_loss_mov_id;
  END IF;

  -- 11. 好貨：不寫 movement（已經在 on_hand 上，只是從 reserved 釋放回 available）
  --     on_hand 不變，reserved 已在步驟 7 減掉了

  -- 12. 建事件
  INSERT INTO hq_return_events (
    batch_id, tenant_id, request_id,
    qty_good, qty_damaged, qty_lost,
    damage_reason, loss_reason,
    goods_confirmed,
    damage_movement_id, loss_movement_id,
    notes, operator_id
  ) VALUES (
    p_batch_id, v_tenant, p_request_id,
    p_qty_good, p_qty_damaged, p_qty_lost,
    p_damage_reason, p_loss_reason,
    p_goods_confirmed,
    v_damage_mov_id, v_loss_mov_id,
    p_notes, v_user
  ) RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'event_id',          v_event_id,
    'batch_id',          p_batch_id,
    'idempotent',        FALSE,
    'qty_good',          p_qty_good,
    'qty_damaged',       p_qty_damaged,
    'qty_lost',          p_qty_lost,
    'damage_movement_id', v_damage_mov_id,
    'loss_movement_id',  v_loss_mov_id,
    'new_status',        v_new_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_dispose_hq_return(BIGINT, UUID, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_dispose_hq_return IS
  '總倉退回貨處理 RPC：分配好/破/失數量，寫負 movement 扣庫存（破/失），'
  '好貨釋放 reserved。request_id 冪等，payload 不同拒絕。'
  'role 白名單 owner/admin/hq_manager，auth.uid 操作者不可冒名。'
  '鎖順序：batch FOR UPDATE → balance FOR UPDATE。';

-- ============================================================
-- 6. trg_guard_hq_pending — 核心負異動 guard
--
-- 保護總倉 pending 批次的 SKU：任何 INSERT 負 movement 到該
-- (tenant, location, sku) 時，驗證 on_hand - 該 SKU 全部 pending ≥ 0。
--
-- ⛔ 本案自己的 rpc_dispose_hq_return 先減 pending/reserved 再寫負 movement，
--    所以不會被自己擋。但 rpc_outbound(p_allow_negative=true) 或直接 INSERT
--    負 movement 會被擋（如果會吃掉 pending 的量）。
--
-- 只在「該 SKU 在該 location 有 pending/partial 批次」時才生效，
-- 沒有本案 pending 的 SKU 不受影響；店鋪也不受影響。
-- ============================================================
CREATE OR REPLACE FUNCTION public._guard_hq_pending_stock()
RETURNS TRIGGER AS $$
DECLARE
  v_total_pending NUMERIC;
  v_balance_after NUMERIC;
BEGIN
  -- 只管負數 movement
  IF NEW.quantity >= 0 THEN
    RETURN NEW;
  END IF;

  -- 查這個 (tenant, location, sku) 有沒有 pending/partial 批次
  SELECT COALESCE(SUM(
    total_qty - qty_good - qty_damaged - qty_lost - qty_revoked
  ), 0) INTO v_total_pending
    FROM hq_return_batches
   WHERE tenant_id   = NEW.tenant_id
     AND location_id = NEW.location_id
     AND sku_id      = NEW.sku_id
     AND status IN ('pending','partial');

  -- 沒有 pending → 不干預（不改原系統負庫存政策）
  IF v_total_pending <= 0 THEN
    RETURN NEW;
  END IF;

  -- 有 pending → 鎖 balance 後算帳
  -- 注意：apply_movement_to_balance (AFTER INSERT) 還沒跑，
  --       所以 on_hand 還是「加上這筆 movement 之前」的值。
  --       加上 NEW.quantity（負數）之後的 on_hand 不能低於 pending。
  SELECT COALESCE(on_hand, 0) INTO v_balance_after
    FROM stock_balances
   WHERE tenant_id   = NEW.tenant_id
     AND location_id = NEW.location_id
     AND sku_id      = NEW.sku_id
   FOR UPDATE;

  v_balance_after := COALESCE(v_balance_after, 0) + NEW.quantity;  -- NEW.quantity is negative

  IF v_balance_after < v_total_pending THEN
    RAISE EXCEPTION 'guard_hq_pending: negative movement would reduce on_hand (%) below pending hq_return qty (%) for sku % at location %',
      v_balance_after, v_total_pending, NEW.sku_id, NEW.location_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- BEFORE INSERT：在 apply_movement_to_balance (AFTER INSERT) 之前檢查
CREATE TRIGGER trg_guard_hq_pending
  BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public._guard_hq_pending_stock();

COMMENT ON FUNCTION public._guard_hq_pending_stock IS
  '核心負異動 guard：保護總倉 pending 退回貨批次的 SKU 不被負 movement 吃掉。'
  '只在該 (tenant, location, sku) 有 pending/partial 批次時生效，'
  '其他 SKU 與店鋪完全不受影響。rpc_dispose_hq_return 先減 pending 再寫 movement 所以不被擋。';

-- ============================================================
-- 7. v_hq_return_batches_list — 同 tenant 總倉 list view
--
-- security_invoker=true → RLS 以呼叫者身分執行。
-- 欄位帶 pending 數、可讀狀態、來源 IDs（UI 可依此 join 品名店名）。
-- ============================================================
CREATE OR REPLACE VIEW public.v_hq_return_batches_list
WITH (security_invoker = true)
AS
SELECT
  b.id,
  b.tenant_id,
  b.location_id,
  b.sku_id,
  b.source_movement_id,
  b.source_transfer_item_id,
  b.source_kind,
  b.source_reason,
  b.total_qty,
  b.unit_cost,
  b.qty_good,
  b.qty_damaged,
  b.qty_lost,
  b.qty_revoked,
  (b.total_qty - b.qty_good - b.qty_damaged - b.qty_lost - b.qty_revoked) AS qty_pending,
  b.status,
  b.auto_flag,
  b.created_by,
  b.created_at,
  b.updated_at
FROM public.hq_return_batches b;

COMMENT ON VIEW public.v_hq_return_batches_list IS
  '總倉退回貨批次列表（security_invoker）：同 tenant 總倉角色可讀，'
  '帶 qty_pending 計算欄。UI 可依 sku_id / source_transfer_item_id join 品名店名。';

-- ============================================================
-- End of migration
-- ============================================================

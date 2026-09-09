-- ============================================================
-- 總倉退回貨處理 — A 核心（資料與處理）
-- 20260907010000_hq_return_disposition_core.sql
--
-- 依賴：20260422120003（stock_movements / stock_balances / locations / transfers / transfer_items）
--       20260424120000（_current_tenant_id helper）
--
-- 本檔 append-only，不改任何既有表結構。
-- ============================================================

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
  unit_cost            NUMERIC(18,4)
                       CHECK (unit_cost IS NULL OR (
                              unit_cost >= 0
                              AND unit_cost != 'NaN'::NUMERIC
                              AND unit_cost != 'Infinity'::NUMERIC
                              AND unit_cost != '-Infinity'::NUMERIC)),
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
COMMENT ON COLUMN public.hq_return_batches.unit_cost IS '逐字保存來源 movement.unit_cost；NULL 代表來源未記成本，不猜值';
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
  new_status           TEXT        NOT NULL CHECK (new_status IN ('partial','completed')),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- 每個 tenant 內同 request_id 不可二建
  CONSTRAINT uq_hq_return_event_request UNIQUE (tenant_id, request_id),

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
COMMENT ON COLUMN public.hq_return_events.new_status IS '本次事件完成當下的批次狀態；冪等重播不得用後來狀態重算';

CREATE INDEX idx_hq_return_events_batch
  ON public.hq_return_events (batch_id, created_at);

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

REVOKE ALL ON FUNCTION public._forbid_hq_return_event_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._forbid_hq_return_event_mutation() FROM anon;
REVOKE ALL ON FUNCTION public._forbid_hq_return_event_mutation() FROM authenticated;

-- ============================================================
-- 3. RLS
--
-- 兩表都開 RLS。authenticated 中只有同 tenant 的 owner/admin/hq_manager 可讀，
-- INSERT/UPDATE/DELETE 全封。
-- 資料寫入只透過 SECURITY DEFINER 函式。
-- ============================================================
ALTER TABLE public.hq_return_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hq_return_events  ENABLE ROW LEVEL SECURITY;

CREATE POLICY hq_return_batches_hq_read ON public.hq_return_batches
  FOR SELECT TO authenticated
  USING (
    tenant_id = public._current_tenant_id()
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('owner','admin','hq_manager')
  );

CREATE POLICY hq_return_events_hq_read ON public.hq_return_events
  FOR SELECT TO authenticated
  USING (
    tenant_id = public._current_tenant_id()
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('owner','admin','hq_manager')
  );

-- 明確不給 INSERT/UPDATE/DELETE policy → authenticated 直接寫會被 RLS 擋
REVOKE ALL ON TABLE public.hq_return_batches, public.hq_return_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.hq_return_batches, public.hq_return_events TO authenticated;

-- ============================================================
-- 4. _hq_hold_return — 內部 helper：建批次＋同步 reserved
--
-- 參數：
--   p_tenant_id           UUID     — 租戶
--   p_location_id         BIGINT   — 總倉 location（必須 type='central_warehouse'）
--   p_sku_id              BIGINT   — SKU
--   p_source_movement_id  BIGINT   — 正向入庫 movement（quantity > 0，同 tenant）
--   p_source_transfer_item_id BIGINT — 簽名保留預設，但實際必填且須反向指回 movement
--   p_source_kind         TEXT     — 'store_return' 或 'shortage'
--   p_source_reason       TEXT     — 原因文字
--   p_qty                 NUMERIC  — 回帳量（必填，正數，須等於 movement 與 item 來源量）
--   p_operator_id         UUID     — 操作者
--   p_auto_flag           TEXT     — 'system' 或 'manual'
--
-- 行為：
--   1. 驗證 movement、item、父 transfer 的 tenant/location/SKU/種類/數量/單據鏈
--   2. movement.source_doc_line_id 可 NULL；有值時須等於 item id
--   3. 先鎖 balance；若同 source_movement_id 已有批次，完整 payload 一致才回既有 id
--   4. 建批次，來源成本原值保存，同步 stock_balances.reserved += p_qty
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
  v_mov            RECORD;
  v_source         RECORD;
  v_loc_type       TEXT;
  v_existing       RECORD;
  v_batch_id       BIGINT;
  v_hold_qty       NUMERIC;
  v_operator_id    UUID;
  v_source_reason  TEXT;
BEGIN
  IF p_tenant_id IS NULL OR p_location_id IS NULL OR p_sku_id IS NULL
  OR p_source_movement_id IS NULL OR p_source_transfer_item_id IS NULL THEN
    RAISE EXCEPTION '_hq_hold_return: tenant, location, sku, source movement and source transfer item are required';
  END IF;

  IF p_source_kind IS NULL OR p_source_kind NOT IN ('store_return','shortage') THEN
    RAISE EXCEPTION '_hq_hold_return: invalid source_kind %', p_source_kind;
  END IF;

  IF p_auto_flag IS NULL OR p_auto_flag NOT IN ('system','manual') THEN
    RAISE EXCEPTION '_hq_hold_return: invalid auto_flag %', p_auto_flag;
  END IF;

  IF p_qty IS NULL THEN
    RAISE EXCEPTION '_hq_hold_return: hold quantity is required';
  END IF;
  IF p_qty = 'NaN'::NUMERIC OR p_qty = 'Infinity'::NUMERIC OR p_qty = '-Infinity'::NUMERIC THEN
    RAISE EXCEPTION '_hq_hold_return: hold quantity must be finite';
  END IF;
  IF p_qty <= 0 OR p_qty > 999999999999999.999::NUMERIC THEN
    RAISE EXCEPTION '_hq_hold_return: hold quantity out of range: %', p_qty;
  END IF;
  IF p_qty != ROUND(p_qty, 3) THEN
    RAISE EXCEPTION '_hq_hold_return: hold quantity must have at most 3 decimal places';
  END IF;

  v_hold_qty := p_qty;
  v_operator_id := COALESCE(p_operator_id, '00000000-0000-0000-0000-000000000000'::UUID);
  v_source_reason := NULLIF(BTRIM(p_source_reason), '');

  -- 1. 驗證來源 movement
  SELECT id, tenant_id, location_id, sku_id, quantity, unit_cost,
         movement_type, source_doc_type, source_doc_id, source_doc_line_id
    INTO v_mov
    FROM stock_movements
   WHERE id = p_source_movement_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '_hq_hold_return: source movement % not found', p_source_movement_id;
  END IF;

  IF v_mov.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION '_hq_hold_return: movement % belongs to different tenant', p_source_movement_id;
  END IF;

  IF v_mov.quantity <= 0
  OR v_mov.quantity = 'NaN'::NUMERIC
  OR v_mov.quantity = 'Infinity'::NUMERIC
  OR v_mov.quantity = '-Infinity'::NUMERIC THEN
    RAISE EXCEPTION '_hq_hold_return: movement % quantity must be positive (got %)', p_source_movement_id, v_mov.quantity;
  END IF;

  IF v_mov.sku_id IS DISTINCT FROM p_sku_id THEN
    RAISE EXCEPTION '_hq_hold_return: movement % sku_id=% does not match p_sku_id=%', p_source_movement_id, v_mov.sku_id, p_sku_id;
  END IF;

  IF v_mov.location_id IS DISTINCT FROM p_location_id THEN
    RAISE EXCEPTION '_hq_hold_return: movement % location=% does not match p_location_id=%',
      p_source_movement_id, v_mov.location_id, p_location_id;
  END IF;

  IF v_mov.quantity IS DISTINCT FROM v_hold_qty THEN
    RAISE EXCEPTION '_hq_hold_return: hold qty % does not match source movement quantity %',
      v_hold_qty, v_mov.quantity;
  END IF;

  IF v_mov.unit_cost IS NOT NULL AND (
       v_mov.unit_cost = 'NaN'::NUMERIC
    OR v_mov.unit_cost = 'Infinity'::NUMERIC
    OR v_mov.unit_cost = '-Infinity'::NUMERIC
  ) THEN
    RAISE EXCEPTION '_hq_hold_return: source movement % unit_cost must be finite', p_source_movement_id;
  END IF;

  -- 2. 驗證 location 與 transfer item / 父單 / movement 單據鏈
  SELECT type INTO v_loc_type
    FROM locations
   WHERE id = p_location_id AND tenant_id = p_tenant_id;

  IF v_loc_type IS NULL THEN
    RAISE EXCEPTION '_hq_hold_return: location % not found for tenant', p_location_id;
  END IF;

  IF v_loc_type != 'central_warehouse' THEN
    RAISE EXCEPTION '_hq_hold_return: location % type=% is not central_warehouse', p_location_id, v_loc_type;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM skus WHERE id = p_sku_id AND tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION '_hq_hold_return: sku % not found for tenant', p_sku_id;
  END IF;

  SELECT ti.id AS item_id, ti.transfer_id, ti.sku_id AS item_sku_id,
         ti.qty_received, ti.qty_shipped,
         ti.in_movement_id, ti.shortage_restock_movement_id,
         t.tenant_id AS transfer_tenant_id, t.transfer_type,
         t.source_location, t.dest_location,
         src.tenant_id AS source_location_tenant, src.type AS source_location_type,
         dst.tenant_id AS dest_location_tenant, dst.type AS dest_location_type
    INTO v_source
    FROM transfer_items ti
    JOIN transfers t ON t.id = ti.transfer_id
    JOIN locations src ON src.id = t.source_location
    JOIN locations dst ON dst.id = t.dest_location
   WHERE ti.id = p_source_transfer_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '_hq_hold_return: source transfer item % not found', p_source_transfer_item_id;
  END IF;

  IF v_source.transfer_tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION '_hq_hold_return: source transfer item % belongs to different tenant', p_source_transfer_item_id;
  END IF;
  IF v_source.source_location_tenant IS DISTINCT FROM p_tenant_id
  OR v_source.dest_location_tenant IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION '_hq_hold_return: source transfer item % parent locations belong to different tenant', p_source_transfer_item_id;
  END IF;
  IF v_source.item_sku_id IS DISTINCT FROM p_sku_id THEN
    RAISE EXCEPTION '_hq_hold_return: source transfer item % sku does not match source movement', p_source_transfer_item_id;
  END IF;
  IF v_mov.source_doc_type IS DISTINCT FROM 'transfer'
  OR v_mov.source_doc_id IS DISTINCT FROM v_source.transfer_id
  OR (v_mov.source_doc_line_id IS NOT NULL
      AND v_mov.source_doc_line_id IS DISTINCT FROM p_source_transfer_item_id) THEN
    RAISE EXCEPTION '_hq_hold_return: source movement % does not match transfer item % document chain',
      p_source_movement_id, p_source_transfer_item_id;
  END IF;

  IF p_source_kind = 'store_return' THEN
    IF v_source.transfer_type IS DISTINCT FROM 'return_to_hq'
    OR v_source.dest_location IS DISTINCT FROM p_location_id
    OR v_source.source_location_type IS DISTINCT FROM 'store'
    OR v_source.dest_location_type IS DISTINCT FROM 'central_warehouse'
    OR v_source.in_movement_id IS DISTINCT FROM p_source_movement_id
    OR v_source.qty_received IS DISTINCT FROM v_hold_qty
    OR v_mov.movement_type IS DISTINCT FROM 'transfer_in' THEN
      RAISE EXCEPTION '_hq_hold_return: source movement % is not the matching store-return receipt for item %',
        p_source_movement_id, p_source_transfer_item_id;
    END IF;
  ELSE
    IF v_source.transfer_type IS DISTINCT FROM 'hq_to_store'
    OR v_source.source_location IS DISTINCT FROM p_location_id
    OR v_source.source_location_type IS DISTINCT FROM 'central_warehouse'
    OR v_source.dest_location_type IS DISTINCT FROM 'store'
    OR v_source.shortage_restock_movement_id IS DISTINCT FROM p_source_movement_id
    OR (v_source.qty_shipped - v_source.qty_received) IS DISTINCT FROM v_hold_qty
    OR v_mov.movement_type IS DISTINCT FROM 'transfer_cancel' THEN
      RAISE EXCEPTION '_hq_hold_return: source movement % is not the matching shortage return for item %',
        p_source_movement_id, p_source_transfer_item_id;
    END IF;
  END IF;

  -- 3. 所有同 (tenant, location, sku) 寫入一律先鎖 balance。
  --    guard、hold、dispose 共用 balance → batch 鎖序，避免競態與死鎖。
  INSERT INTO stock_balances (tenant_id, location_id, sku_id)
  VALUES (p_tenant_id, p_location_id, p_sku_id)
  ON CONFLICT (tenant_id, location_id, sku_id) DO NOTHING;

  PERFORM 1 FROM stock_balances
   WHERE tenant_id = p_tenant_id AND location_id = p_location_id AND sku_id = p_sku_id
   FOR UPDATE;

  -- 4. 冪等：鎖後核對完整 payload，不能把錯誤來源靜默當重試。
  SELECT * INTO v_existing
    FROM hq_return_batches
   WHERE source_movement_id = p_source_movement_id
   FOR UPDATE;

  IF FOUND THEN
    IF v_existing.tenant_id IS DISTINCT FROM p_tenant_id
    OR v_existing.location_id IS DISTINCT FROM p_location_id
    OR v_existing.sku_id IS DISTINCT FROM p_sku_id
    OR v_existing.source_transfer_item_id IS DISTINCT FROM p_source_transfer_item_id
    OR v_existing.source_kind IS DISTINCT FROM p_source_kind
    OR v_existing.source_reason IS DISTINCT FROM v_source_reason
    OR v_existing.total_qty IS DISTINCT FROM v_hold_qty
    OR v_existing.unit_cost IS DISTINCT FROM v_mov.unit_cost
    OR v_existing.auto_flag IS DISTINCT FROM p_auto_flag
    OR v_existing.created_by IS DISTINCT FROM v_operator_id THEN
      RAISE EXCEPTION '_hq_hold_return: source movement % already held with different payload', p_source_movement_id;
    END IF;
    RETURN v_existing.id;
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
    p_source_kind, v_source_reason,
    v_hold_qty, v_mov.unit_cost,
    p_auto_flag, v_operator_id
  ) RETURNING id INTO v_batch_id;

  -- 6. 同步 reserved（balance 已鎖）
  UPDATE stock_balances
     SET reserved = reserved + v_hold_qty, updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND location_id = p_location_id AND sku_id = p_sku_id;

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
-- 鎖順序：未鎖讀 batch 定位鍵 → stock_balances FOR UPDATE → hq_return_batches FOR UPDATE
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
  v_user           UUID := auth.uid();
  v_tenant         UUID := public._current_tenant_id();
  v_role           TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_batch_key      RECORD;
  v_batch          RECORD;
  v_balance        RECORD;
  v_pending        NUMERIC;
  v_total_pending  NUMERIC;
  v_this_total     NUMERIC;
  v_existing       RECORD;
  v_damage_reason  TEXT := NULLIF(BTRIM(p_damage_reason), '');
  v_loss_reason    TEXT := NULLIF(BTRIM(p_loss_reason), '');
  v_notes          TEXT := NULLIF(BTRIM(p_notes), '');
  v_damage_mov_id  BIGINT;
  v_loss_mov_id    BIGINT;
  v_event_id       BIGINT;
  v_new_status     TEXT;
BEGIN
  -- 0. auth 必須有值
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: not authenticated';
  END IF;

  -- 1. role 白名單
  IF v_role NOT IN ('owner','admin','hq_manager') THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: permission denied for role %', v_role;
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: request_id is required';
  END IF;
  IF p_batch_id IS NULL THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: batch_id is required';
  END IF;

  -- 2. 數量逐欄驗證；不可先塞入 NUMERIC(18,3) 讓資料庫四捨五入。
  IF p_qty_good IS NULL OR p_qty_damaged IS NULL OR p_qty_lost IS NULL THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: quantity values cannot be NULL';
  END IF;
  IF p_goods_confirmed IS NULL THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: goods_confirmed cannot be NULL';
  END IF;

  IF p_qty_good IN ('NaN'::NUMERIC, 'Infinity'::NUMERIC, '-Infinity'::NUMERIC)
  OR p_qty_damaged IN ('NaN'::NUMERIC, 'Infinity'::NUMERIC, '-Infinity'::NUMERIC)
  OR p_qty_lost IN ('NaN'::NUMERIC, 'Infinity'::NUMERIC, '-Infinity'::NUMERIC) THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: quantity values must be finite numeric values';
  END IF;

  IF p_qty_good < 0 OR p_qty_damaged < 0 OR p_qty_lost < 0 THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: quantities must be non-negative';
  END IF;

  IF p_qty_good > 999999999999999.999::NUMERIC
  OR p_qty_damaged > 999999999999999.999::NUMERIC
  OR p_qty_lost > 999999999999999.999::NUMERIC THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: quantity value exceeds NUMERIC(18,3) range';
  END IF;

  IF p_qty_good != ROUND(p_qty_good, 3)
  OR p_qty_damaged != ROUND(p_qty_damaged, 3)
  OR p_qty_lost != ROUND(p_qty_lost, 3) THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: quantities must have at most 3 decimal places';
  END IF;

  v_this_total := p_qty_good + p_qty_damaged + p_qty_lost;

  IF v_this_total <= 0 THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: total disposition quantity must be > 0';
  END IF;

  IF v_this_total > 999999999999999.999::NUMERIC THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: total quantity exceeds NUMERIC(18,3) range';
  END IF;

  -- 破損需原因
  IF p_qty_damaged > 0 AND v_damage_reason IS NULL THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: damage_reason required when qty_damaged > 0';
  END IF;

  -- 遺失需原因
  IF p_qty_lost > 0 AND v_loss_reason IS NULL THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: loss_reason required when qty_lost > 0';
  END IF;

  -- 好貨需實物確認
  IF p_qty_good > 0 AND NOT p_goods_confirmed THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: goods_confirmed must be true when qty_good > 0';
  END IF;

  -- 3. 同 tenant + request_id 序列化。第二個請求等第一個完成後重讀事件。
  PERFORM pg_advisory_xact_lock(hashtext(v_tenant::TEXT), hashtext(p_request_id::TEXT));

  -- 冪等：核對完整標準化 payload，並回傳第一次的完整原結果。
  SELECT * INTO v_existing
    FROM hq_return_events
   WHERE tenant_id = v_tenant
     AND request_id = p_request_id;

  IF FOUND THEN
    IF v_existing.batch_id IS DISTINCT FROM p_batch_id
    OR v_existing.qty_good IS DISTINCT FROM p_qty_good
    OR v_existing.qty_damaged IS DISTINCT FROM p_qty_damaged
    OR v_existing.qty_lost IS DISTINCT FROM p_qty_lost
    OR v_existing.damage_reason IS DISTINCT FROM v_damage_reason
    OR v_existing.loss_reason IS DISTINCT FROM v_loss_reason
    OR v_existing.goods_confirmed IS DISTINCT FROM p_goods_confirmed
    OR v_existing.notes IS DISTINCT FROM v_notes THEN
      RAISE EXCEPTION 'rpc_dispose_hq_return: request_id % already used with different payload', p_request_id;
    END IF;

    RETURN jsonb_build_object(
      'event_id',           v_existing.id,
      'batch_id',           v_existing.batch_id,
      'idempotent',         TRUE,
      'qty_good',           v_existing.qty_good,
      'qty_damaged',        v_existing.qty_damaged,
      'qty_lost',           v_existing.qty_lost,
      'damage_movement_id', v_existing.damage_movement_id,
      'loss_movement_id',   v_existing.loss_movement_id,
      'new_status',         v_existing.new_status
    );
  END IF;

  -- 4. 未鎖查定位鍵，接著一律 balance → batch；鎖後重新讀完整批次。
  SELECT tenant_id, location_id, sku_id INTO v_batch_key
    FROM hq_return_batches
   WHERE id = p_batch_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: batch % not found', p_batch_id;
  END IF;

  IF v_batch_key.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: batch % belongs to different tenant', p_batch_id;
  END IF;

  INSERT INTO stock_balances (tenant_id, location_id, sku_id)
  VALUES (v_tenant, v_batch_key.location_id, v_batch_key.sku_id)
  ON CONFLICT (tenant_id, location_id, sku_id) DO NOTHING;

  SELECT * INTO v_balance
    FROM stock_balances
   WHERE tenant_id = v_tenant
     AND location_id = v_batch_key.location_id
     AND sku_id = v_batch_key.sku_id
   FOR UPDATE;

  SELECT * INTO v_batch
    FROM hq_return_batches
   WHERE id = p_batch_id
     AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND
  OR v_batch.location_id IS DISTINCT FROM v_batch_key.location_id
  OR v_batch.sku_id IS DISTINCT FROM v_batch_key.sku_id THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: batch % changed while locking', p_batch_id;
  END IF;

  IF v_batch.status IN ('completed','revoked') THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: batch % already %', p_batch_id, v_batch.status;
  END IF;

  -- 5. 鎖後檢查本批 pending、同 SKU 全部 pending、reserved 與實際庫存。
  v_pending := v_batch.total_qty - v_batch.qty_good - v_batch.qty_damaged - v_batch.qty_lost - v_batch.qty_revoked;

  IF v_this_total > v_pending THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: disposition qty (%) exceeds pending (%) for batch %',
      v_this_total, v_pending, p_batch_id;
  END IF;

  SELECT COALESCE(SUM(total_qty - qty_good - qty_damaged - qty_lost - qty_revoked), 0)
    INTO v_total_pending
    FROM hq_return_batches
   WHERE tenant_id = v_batch.tenant_id
     AND location_id = v_batch.location_id
     AND sku_id = v_batch.sku_id
     AND status IN ('pending','partial');

  IF v_balance.reserved < v_total_pending THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: reserved (%) is below total pending (%) for sku %',
      v_balance.reserved, v_total_pending, v_batch.sku_id;
  END IF;

  IF v_balance.on_hand < p_qty_damaged + p_qty_lost THEN
    RAISE EXCEPTION 'rpc_dispose_hq_return: on_hand (%) is below damaged/lost deduction (%) for sku %',
      v_balance.on_hand, p_qty_damaged + p_qty_lost, v_batch.sku_id;
  END IF;

  -- 6. 先減 pending/reserved（在寫負 movement 之前，避免被 guard trigger 擋）
  --    reserved 減去破損＋遺失＋好貨（好貨釋回 available，不再凍結）
  UPDATE stock_balances
     SET reserved   = reserved - v_this_total,
         updated_at = NOW()
   WHERE tenant_id   = v_batch.tenant_id
     AND location_id = v_batch.location_id
     AND sku_id      = v_batch.sku_id;

  -- 7. 更新批次累積
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

  -- 8. 破損 → 沿用既有 damage
  IF p_qty_damaged > 0 THEN
    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost,
      movement_type, source_doc_type, source_doc_id,
      reason, operator_id, notes
    ) VALUES (
      v_batch.tenant_id, v_batch.location_id, v_batch.sku_id,
      -p_qty_damaged, v_batch.unit_cost,
      'damage', 'hq_return_batch', p_batch_id,
      v_damage_reason, v_user, v_notes
    ) RETURNING id INTO v_damage_mov_id;
  END IF;

  -- 9. 遺失 → 沿用既有 manual_adjust，單據鏈與原因明確標示本案
  IF p_qty_lost > 0 THEN
    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost,
      movement_type, source_doc_type, source_doc_id,
      reason, operator_id, notes
    ) VALUES (
      v_batch.tenant_id, v_batch.location_id, v_batch.sku_id,
      -p_qty_lost, v_batch.unit_cost,
      'manual_adjust', 'hq_return_batch', p_batch_id,
      '退回總倉遺失：' || v_loss_reason, v_user, v_notes
    ) RETURNING id INTO v_loss_mov_id;
  END IF;

  -- 10. 好貨：不寫 movement（已經在 on_hand 上，只是從 reserved 釋放回 available）
  --     on_hand 不變，reserved 已在步驟 7 減掉了

  -- 11. 建 append-only 事件，保存本次當時結果供日後重播。
  INSERT INTO hq_return_events (
    batch_id, tenant_id, request_id,
    qty_good, qty_damaged, qty_lost,
    damage_reason, loss_reason,
    goods_confirmed,
    damage_movement_id, loss_movement_id,
    notes, operator_id, new_status
  ) VALUES (
    p_batch_id, v_tenant, p_request_id,
    p_qty_good, p_qty_damaged, p_qty_lost,
    v_damage_reason, v_loss_reason,
    p_goods_confirmed,
    v_damage_mov_id, v_loss_mov_id,
    v_notes, v_user, v_new_status
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

REVOKE ALL ON FUNCTION public.rpc_dispose_hq_return(BIGINT, UUID, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_dispose_hq_return(BIGINT, UUID, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_dispose_hq_return(BIGINT, UUID, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_dispose_hq_return(BIGINT, UUID, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_dispose_hq_return IS
  '總倉退回貨處理 RPC：分配好/破/失數量，寫負 movement 扣庫存（破/失），'
  '好貨釋放 reserved。request_id 冪等，payload 不同拒絕。'
  'role 白名單 owner/admin/hq_manager，auth.uid 操作者不可冒名。'
  '鎖順序：balance FOR UPDATE → batch FOR UPDATE。';

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
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total_pending NUMERIC;
  v_balance_after NUMERIC;
BEGIN
  -- 只管負數 movement
  IF NEW.quantity >= 0 THEN
    RETURN NEW;
  END IF;

  -- 先建立並鎖 balance；即使起初 pending=0，也要等同 SKU 正在建立的 hold。
  INSERT INTO stock_balances (tenant_id, location_id, sku_id)
  VALUES (NEW.tenant_id, NEW.location_id, NEW.sku_id)
  ON CONFLICT (tenant_id, location_id, sku_id) DO NOTHING;

  SELECT on_hand INTO v_balance_after
    FROM stock_balances
   WHERE tenant_id   = NEW.tenant_id
     AND location_id = NEW.location_id
     AND sku_id      = NEW.sku_id
   FOR UPDATE;

  -- 鎖到 balance 後才重讀全部 pending。
  SELECT COALESCE(SUM(
    total_qty - qty_good - qty_damaged - qty_lost - qty_revoked
  ), 0) INTO v_total_pending
    FROM hq_return_batches
   WHERE tenant_id   = NEW.tenant_id
     AND location_id = NEW.location_id
     AND sku_id      = NEW.sku_id
     AND status IN ('pending','partial');

  -- 鎖後仍沒有 pending → 不干預（不改原系統負庫存政策）
  IF v_total_pending <= 0 THEN
    RETURN NEW;
  END IF;

  -- 注意：apply_movement_to_balance (AFTER INSERT) 還沒跑，
  --       所以 on_hand 還是「加上這筆 movement 之前」的值。
  --       加上 NEW.quantity（負數）之後的 on_hand 不能低於 pending。
  v_balance_after := COALESCE(v_balance_after, 0) + NEW.quantity;  -- NEW.quantity is negative

  IF v_balance_after < v_total_pending THEN
    RAISE EXCEPTION 'guard_hq_pending: negative movement would reduce on_hand (%) below pending hq_return qty (%) for sku % at location %',
      v_balance_after, v_total_pending, NEW.sku_id, NEW.location_id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._guard_hq_pending_stock() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._guard_hq_pending_stock() FROM anon;
REVOKE ALL ON FUNCTION public._guard_hq_pending_stock() FROM authenticated;

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

REVOKE ALL ON TABLE public.v_hq_return_batches_list FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_hq_return_batches_list TO authenticated;

COMMENT ON VIEW public.v_hq_return_batches_list IS
  '總倉退回貨批次列表（security_invoker）：同 tenant 總倉角色可讀，'
  '帶 qty_pending 計算欄。UI 可依 sku_id / source_transfer_item_id join 品名店名。';

-- ============================================================
-- End of migration
-- ============================================================

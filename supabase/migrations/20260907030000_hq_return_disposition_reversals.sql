-- ============================================================
-- 總倉退回貨處理 — C 原單更正／撤回保護
-- 20260907030000_hq_return_disposition_reversals.sql
--
-- 不重抄三支既有大 RPC；共同卡在：
--   1. stock_movements 真 reversal 寫入前
--   2. transfer_items 來源欄位／數量被改寫前
--   3. return_to_hq 單頭月份或狀態被改寫前
--   4. 真正最新版月結生成器開始判斷／計價前
-- ============================================================

-- 撤回軌跡直接連到 append-only stock_movements。BEFORE hook 先原子撤批，
-- reversal row 落表後再由 AFTER hook 補 FK，避免依賴 deferred FK 時序。
ALTER TABLE public.hq_return_batches
  ADD COLUMN revoked_by_movement_id BIGINT,
  ADD COLUMN revoked_by UUID,
  ADD COLUMN revoked_at TIMESTAMPTZ,
  ADD COLUMN revoke_reason TEXT,
  ADD CONSTRAINT uq_hq_return_batch_revoke_movement UNIQUE (revoked_by_movement_id),
  ADD CONSTRAINT fk_hq_return_batch_revoke_movement
    FOREIGN KEY (revoked_by_movement_id)
    REFERENCES public.stock_movements(id),
  ADD CONSTRAINT chk_hq_return_batch_revoke_evidence CHECK (
    (status = 'revoked') =
    (revoked_by IS NOT NULL
     AND revoked_at IS NOT NULL
     AND revoke_reason IS NOT NULL)
    AND (revoked_by_movement_id IS NULL OR status = 'revoked')
  ) NOT VALID;

COMMENT ON COLUMN public.hq_return_batches.revoked_by_movement_id IS
  '真正沖銷 source_movement_id 的 append-only reversal movement；C hook 寫入';
COMMENT ON COLUMN public.hq_return_batches.revoked_by IS
  '撤回操作者，取真正 reversal movement.operator_id';
COMMENT ON COLUMN public.hq_return_batches.revoked_at IS
  'C hook 實際撤回時間';
COMMENT ON COLUMN public.hq_return_batches.revoke_reason IS
  '真正 reversal movement.reason 的不可空快照';

ALTER TABLE public.store_monthly_settlement_items
  ALTER COLUMN unit_cost DROP NOT NULL,
  ALTER COLUMN line_amount DROP NOT NULL;

-- ============================================================
-- 1. 月鎖 primitive
--
-- return_to_hq 的金額月份＝來源店＋received_at 台北月份。
-- C 新增 settlement advisory lock，並在本檔末讓真正最新版月結生成器
-- 共用；再鎖該店該月 row，避免「檢查時尚無 row、另一邊同時建帳」。
-- ============================================================
CREATE OR REPLACE FUNCTION public._hq_assert_return_month_open(
  p_tenant_id       UUID,
  p_source_location BIGINT,
  p_received_at     TIMESTAMPTZ
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_month       DATE;
  v_store_id    BIGINT;
  v_store_name  TEXT;
  v_status      TEXT;
BEGIN
  IF p_received_at IS NULL THEN
    RETURN;
  END IF;

  SELECT s.id, s.name
    INTO v_store_id, v_store_name
    FROM public.stores s
   WHERE s.tenant_id = p_tenant_id
     AND s.location_id = p_source_location
   ORDER BY s.id
   LIMIT 1;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION '_hq_return_month: source location % is not a store of tenant %',
      p_source_location, p_tenant_id;
  END IF;

  v_month := DATE_TRUNC('month', p_received_at AT TIME ZONE 'Asia/Taipei')::DATE;
  -- 舊撤收 RPC 在進入本 helper 前可能已鎖 balance。不可在此等待月份鎖，
  -- 否則多品項撤收會形成 balance→month／month→balance 的死鎖環；忙碌時
  -- 立即拒絕並讓外層整筆 rollback，生成器則使用同 key 的 blocking lock。
  IF NOT pg_try_advisory_xact_lock(
    hashtext('settlement:' || p_tenant_id::TEXT || ':' || v_month::TEXT)
  ) THEN
    RAISE EXCEPTION '該月份正在產生或更正對帳單，這次退貨操作未執行，請稍後重試';
  END IF;

  SELECT sms.status
    INTO v_status
    FROM public.store_monthly_settlements sms
   WHERE sms.tenant_id = p_tenant_id
     AND sms.store_id = v_store_id
     AND sms.settlement_month = v_month
   FOR UPDATE;

  IF v_status IN ('confirmed','settled','remitted') THEN
    RAISE EXCEPTION '退貨／短收沖帳落在已鎖定月份：% %（%）。不能自動更正或撤回，請人工對帳。',
      v_store_name, TO_CHAR(v_month, 'YYYY-MM'), v_status;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._hq_assert_return_month_open(UUID, BIGINT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._hq_assert_return_month_open(UUID, BIGINT, TIMESTAMPTZ) FROM anon;
REVOKE ALL ON FUNCTION public._hq_assert_return_month_open(UUID, BIGINT, TIMESTAMPTZ) FROM authenticated;

-- ============================================================
-- 2. 共同 reversal hook
--
-- trigger 名稱刻意排在 trg_guard_hq_pending 前：先把完整 pending 批次撤回、
-- 釋放 reserved，A 的負異動 guard 才能用撤回後的 pending 驗這筆負數。
-- ============================================================
CREATE OR REPLACE FUNCTION public._hq_revoke_return_on_reversal()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_orig             public.stock_movements%ROWTYPE;
  v_batch            public.hq_return_batches%ROWTYPE;
  v_item             public.transfer_items%ROWTYPE;
  v_transfer         public.transfers%ROWTYPE;
  v_credit           public.transfers%ROWTYPE;
  v_balance_reserved NUMERIC;
  v_total_pending    NUMERIC;
  v_auth_uid         UUID;
  v_claim_tenant     UUID;
BEGIN
  IF NEW.reverses IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_orig
    FROM public.stock_movements
   WHERE id = NEW.reverses;

  IF NOT FOUND THEN
    RETURN NEW; -- 原 FK 會給一致的不存在錯誤；C 不接管無批次的歷史路徑。
  END IF;

  -- A 處理破損／遺失所產生的負 movement 不可再私自反向；目前沒有
  -- event reversal 財務流程，必須保留 append-only 證據後人工盤點／對帳。
  IF v_orig.source_doc_type = 'hq_return_batch'
     AND EXISTS (
       SELECT 1 FROM public.hq_return_batches b
        WHERE b.id = v_orig.source_doc_id
     ) THEN
    RAISE EXCEPTION '已處理的總倉退回貨異動 % 不能直接反向；請走人工盤點與對帳',
      v_orig.id;
  END IF;

  SELECT * INTO v_batch
    FROM public.hq_return_batches
   WHERE source_movement_id = v_orig.id;

  IF NOT FOUND THEN
    RETURN NEW; -- 其他既有 reversal 完全沿用原行為。
  END IF;

  SELECT * INTO v_item
    FROM public.transfer_items
   WHERE id = v_batch.source_transfer_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '_hq_return_reversal: source item % not found',
      v_batch.source_transfer_item_id;
  END IF;

  SELECT * INTO v_transfer
    FROM public.transfers
   WHERE id = v_item.transfer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '_hq_return_reversal: source transfer % not found', v_item.transfer_id;
  END IF;

  -- 真撤回一律需要可歸責的真人 JWT，不把「缺 JWT」當成 service 特權。
  -- 自動接貨是正向 movement（NEW.reverses IS NULL），在上方已直接放行。
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION '_hq_return_reversal: authenticated operator is required';
  END IF;
  IF NEW.operator_id IS DISTINCT FROM v_auth_uid THEN
    RAISE EXCEPTION '_hq_return_reversal: operator must equal auth.uid()';
  END IF;
  v_claim_tenant := public._current_tenant_id();
  IF v_claim_tenant IS DISTINCT FROM v_batch.tenant_id THEN
    RAISE EXCEPTION '_hq_return_reversal: batch not in current tenant';
  END IF;

  -- reversal 本身與原 movement、batch、item、父單必須逐項相符。
  IF NEW.movement_type IS DISTINCT FROM 'reversal'
  OR NEW.quantity IS DISTINCT FROM -v_orig.quantity
  OR NEW.tenant_id IS DISTINCT FROM v_orig.tenant_id
  OR NEW.location_id IS DISTINCT FROM v_orig.location_id
  OR NEW.sku_id IS DISTINCT FROM v_orig.sku_id
  OR NEW.unit_cost IS DISTINCT FROM v_orig.unit_cost
  OR NEW.source_doc_type IS DISTINCT FROM 'transfer'
  OR NEW.source_doc_id IS DISTINCT FROM v_transfer.id
  OR NEW.source_doc_line_id IS DISTINCT FROM v_item.id
  OR NULLIF(BTRIM(NEW.reason), '') IS NULL THEN
    RAISE EXCEPTION '_hq_return_reversal: movement does not exactly reverse source %', v_orig.id;
  END IF;

  IF v_orig.quantity <= 0
  OR v_orig.source_doc_type IS DISTINCT FROM 'transfer'
  OR v_orig.source_doc_id IS DISTINCT FROM v_transfer.id
  OR (v_orig.source_doc_line_id IS NOT NULL
      AND v_orig.source_doc_line_id IS DISTINCT FROM v_item.id)
  OR v_orig.tenant_id IS DISTINCT FROM v_batch.tenant_id
  OR v_orig.location_id IS DISTINCT FROM v_batch.location_id
  OR v_orig.sku_id IS DISTINCT FROM v_batch.sku_id
  OR v_orig.quantity IS DISTINCT FROM v_batch.total_qty
  OR v_item.sku_id IS DISTINCT FROM v_batch.sku_id
  OR v_transfer.tenant_id IS DISTINCT FROM v_batch.tenant_id THEN
    RAISE EXCEPTION '_hq_return_reversal: source movement/batch/item chain is inconsistent';
  END IF;

  IF v_batch.source_kind = 'store_return' THEN
    IF v_orig.movement_type IS DISTINCT FROM 'transfer_in'
    OR v_transfer.transfer_type IS DISTINCT FROM 'return_to_hq'
    OR v_transfer.dest_location IS DISTINCT FROM v_batch.location_id
    OR v_item.in_movement_id IS DISTINCT FROM v_orig.id
    OR v_item.qty_received IS DISTINCT FROM v_orig.quantity THEN
      RAISE EXCEPTION '_hq_return_reversal: store-return source is no longer current';
    END IF;

    -- 真退貨原單自己的月份（舊 RPC 只查短收 credit 子單，這裡補齊）。
    PERFORM public._hq_assert_return_month_open(
      v_transfer.tenant_id, v_transfer.source_location, v_transfer.received_at
    );
  ELSE
    IF v_batch.source_kind IS DISTINCT FROM 'shortage'
    OR v_orig.movement_type IS DISTINCT FROM 'transfer_cancel'
    OR v_transfer.transfer_type IS DISTINCT FROM 'hq_to_store'
    OR v_transfer.source_location IS DISTINCT FROM v_batch.location_id
    OR v_item.shortage_restock_movement_id IS DISTINCT FROM v_orig.id THEN
      RAISE EXCEPTION '_hq_return_reversal: shortage source is no longer current';
    END IF;

    -- 短收回帳的錢落在純記帳 return_to_hq 子單月份。
    IF v_item.shortage_return_transfer_id IS NOT NULL THEN
      SELECT * INTO v_credit
        FROM public.transfers
       WHERE id = v_item.shortage_return_transfer_id;
      IF NOT FOUND OR v_credit.transfer_type IS DISTINCT FROM 'return_to_hq' THEN
        RAISE EXCEPTION '_hq_return_reversal: shortage credit transfer is invalid';
      END IF;
      PERFORM public._hq_assert_return_month_open(
        v_credit.tenant_id, v_credit.source_location, v_credit.received_at
      );
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.stock_movements r WHERE r.reverses = v_orig.id
  ) THEN
    RAISE EXCEPTION '_hq_return_reversal: source movement % was already reversed', v_orig.id;
  END IF;

  -- A 的共同鎖序：balance → batch。鎖後重讀 batch，避免同時處理／撤回。
  INSERT INTO public.stock_balances (tenant_id, location_id, sku_id)
  VALUES (v_batch.tenant_id, v_batch.location_id, v_batch.sku_id)
  ON CONFLICT (tenant_id, location_id, sku_id) DO NOTHING;

  SELECT reserved INTO v_balance_reserved
    FROM public.stock_balances
   WHERE tenant_id = v_batch.tenant_id
     AND location_id = v_batch.location_id
     AND sku_id = v_batch.sku_id
   FOR UPDATE;

  SELECT * INTO v_batch
    FROM public.hq_return_batches
   WHERE source_movement_id = v_orig.id
   FOR UPDATE;

  IF v_batch.status IS DISTINCT FROM 'pending'
  OR v_batch.qty_good <> 0
  OR v_batch.qty_damaged <> 0
  OR v_batch.qty_lost <> 0
  OR v_batch.qty_revoked <> 0
  OR EXISTS (
    SELECT 1 FROM public.hq_return_events e WHERE e.batch_id = v_batch.id
  ) THEN
    RAISE EXCEPTION '總倉退回貨批次 % 已開始處理，不能局部撤回；本次原單操作已整筆取消',
      v_batch.id;
  END IF;

  SELECT COALESCE(SUM(
           total_qty - qty_good - qty_damaged - qty_lost - qty_revoked
         ), 0)
    INTO v_total_pending
    FROM public.hq_return_batches
   WHERE tenant_id = v_batch.tenant_id
     AND location_id = v_batch.location_id
     AND sku_id = v_batch.sku_id
     AND status IN ('pending','partial');

  IF COALESCE(v_balance_reserved, 0) < v_total_pending THEN
    RAISE EXCEPTION '_hq_return_reversal: reserved % is below all pending return qty %',
      COALESCE(v_balance_reserved, 0), v_total_pending;
  END IF;

  UPDATE public.stock_balances
     SET reserved = reserved - v_batch.total_qty,
         version = version + 1,
         updated_at = NOW()
   WHERE tenant_id = v_batch.tenant_id
     AND location_id = v_batch.location_id
     AND sku_id = v_batch.sku_id;

  UPDATE public.hq_return_batches
     SET qty_revoked = total_qty,
         status = 'revoked',
         revoked_by = NEW.operator_id,
         revoked_at = NOW(),
         revoke_reason = BTRIM(NEW.reason),
         updated_at = NOW()
   WHERE id = v_batch.id;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._hq_revoke_return_on_reversal() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._hq_revoke_return_on_reversal() FROM anon;
REVOKE ALL ON FUNCTION public._hq_revoke_return_on_reversal() FROM authenticated;

CREATE TRIGGER trg_00_hq_return_reversal
  BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public._hq_revoke_return_on_reversal();

CREATE OR REPLACE FUNCTION public._hq_link_return_reversal()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_batch public.hq_return_batches%ROWTYPE;
BEGIN
  IF NEW.reverses IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_batch
    FROM public.hq_return_batches
   WHERE source_movement_id = NEW.reverses
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_batch.status IS DISTINCT FROM 'revoked'
  OR v_batch.qty_revoked IS DISTINCT FROM v_batch.total_qty
  OR v_batch.revoked_by_movement_id IS NOT NULL
  OR v_batch.revoked_by IS DISTINCT FROM NEW.operator_id
  OR v_batch.revoke_reason IS DISTINCT FROM BTRIM(NEW.reason) THEN
    RAISE EXCEPTION '_hq_return_reversal: batch % revocation evidence is inconsistent', v_batch.id;
  END IF;

  UPDATE public.hq_return_batches
     SET revoked_by_movement_id = NEW.id,
         updated_at = NOW()
   WHERE id = v_batch.id;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._hq_link_return_reversal() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._hq_link_return_reversal() FROM anon;
REVOKE ALL ON FUNCTION public._hq_link_return_reversal() FROM authenticated;

-- AFTER trigger 名稱排在 trg_apply_movement 後；若補證據失敗，整筆 INSERT
-- （包含 apply_movement_to_balance 的庫存變更）仍在同一交易一起 rollback。
CREATE TRIGGER trg_zz_hq_return_reversal_link
  AFTER INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public._hq_link_return_reversal();

-- ============================================================
-- 3. item 守門
--
-- 防止不寫 reversal 就清／換來源 id；同時持續核對 store return 的
-- qty_received，以及 shortage 的 qty_shipped - qty_received。數量採 deferred
-- final-state 檢查：整張 unreceive 會先把 qty_received 歸零，稍後才撤 shortage，
-- 不可把同一交易中的合法暫態誤判成旁路。
-- ============================================================
CREATE OR REPLACE FUNCTION public._guard_hq_return_item_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_source RECORD;
  v_batch  public.hq_return_batches%ROWTYPE;
  v_return RECORD;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT t.tenant_id, t.source_location, t.received_at
      INTO v_return
      FROM public.transfers t
     WHERE t.id = NEW.transfer_id
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('received','closed');
    IF FOUND THEN
      PERFORM public._hq_assert_return_month_open(
        v_return.tenant_id, v_return.source_location, v_return.received_at
      );
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    SELECT t.tenant_id, t.source_location, t.received_at
      INTO v_return
      FROM public.transfers t
     WHERE t.id = OLD.transfer_id
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('received','closed');
    IF FOUND THEN
      PERFORM public._hq_assert_return_month_open(
        v_return.tenant_id, v_return.source_location, v_return.received_at
      );
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.hq_return_batches b
       WHERE b.source_transfer_item_id = OLD.id
    ) THEN
      RAISE EXCEPTION 'transfer_item % 已有總倉退回貨軌跡，不能刪除', OLD.id;
    END IF;
    RETURN OLD;
  END IF;

  -- return_to_hq item 會直接影響退貨月結；即使純短收 credit 子單沒有
  -- hq_return batch，新增／刪除／改量也不能穿過月份鎖。
  IF NEW.transfer_id IS DISTINCT FROM OLD.transfer_id
  OR NEW.sku_id IS DISTINCT FROM OLD.sku_id
  OR NEW.qty_shipped IS DISTINCT FROM OLD.qty_shipped
  OR NEW.qty_received IS DISTINCT FROM OLD.qty_received THEN
    FOR v_return IN
      SELECT DISTINCT t.tenant_id, t.source_location, t.received_at
        FROM public.transfers t
       WHERE t.id IN (OLD.transfer_id, NEW.transfer_id)
         AND t.transfer_type = 'return_to_hq'
         AND t.status IN ('received','closed')
         AND t.received_at IS NOT NULL
       ORDER BY t.received_at, t.tenant_id, t.source_location
    LOOP
      PERFORM public._hq_assert_return_month_open(
        v_return.tenant_id, v_return.source_location, v_return.received_at
      );
    END LOOP;
  END IF;

  -- item/父單/SKU 是永久來源鏈；即使批次已撤回也不可改寫歷史歸屬。
  IF (NEW.id IS DISTINCT FROM OLD.id
      OR NEW.transfer_id IS DISTINCT FROM OLD.transfer_id
      OR NEW.sku_id IS DISTINCT FROM OLD.sku_id)
     AND EXISTS (
       SELECT 1 FROM public.hq_return_batches b
        WHERE b.source_transfer_item_id = OLD.id
     ) THEN
    RAISE EXCEPTION 'transfer_item % 已有總倉退回貨軌跡，不能改 item/transfer/SKU 歸屬', OLD.id;
  END IF;

  -- 舊指標若被清掉或換掉，對應 batch 必須已由「那一筆真 reversal」完整撤回。
  FOR v_source IN
    SELECT OLD.in_movement_id AS movement_id
     WHERE OLD.in_movement_id IS NOT NULL
       AND NEW.in_movement_id IS DISTINCT FROM OLD.in_movement_id
    UNION ALL
    SELECT OLD.shortage_restock_movement_id
     WHERE OLD.shortage_restock_movement_id IS NOT NULL
       AND NEW.shortage_restock_movement_id IS DISTINCT FROM OLD.shortage_restock_movement_id
  LOOP
    SELECT * INTO v_batch
      FROM public.hq_return_batches
     WHERE source_movement_id = v_source.movement_id;

    IF FOUND AND (
         v_batch.status IS DISTINCT FROM 'revoked'
      OR v_batch.qty_revoked IS DISTINCT FROM v_batch.total_qty
      OR v_batch.revoked_by_movement_id IS NULL
      OR NOT EXISTS (
        SELECT 1
          FROM public.stock_movements r
         WHERE r.id = v_batch.revoked_by_movement_id
           AND r.reverses = v_source.movement_id
           AND r.quantity = -v_batch.total_qty
           AND r.movement_type = 'reversal'
      )
    ) THEN
      RAISE EXCEPTION '來源 movement % 尚未真實完整沖銷，不能清除或替換 item 指標',
        v_source.movement_id;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._guard_hq_return_item_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._guard_hq_return_item_mutation() FROM anon;
REVOKE ALL ON FUNCTION public._guard_hq_return_item_mutation() FROM authenticated;

CREATE TRIGGER trg_00_guard_hq_return_item_write
  BEFORE INSERT OR UPDATE ON public.transfer_items
  FOR EACH ROW EXECUTE FUNCTION public._guard_hq_return_item_mutation();

CREATE TRIGGER trg_00_guard_hq_return_item_delete
  BEFORE DELETE ON public.transfer_items
  FOR EACH ROW EXECUTE FUNCTION public._guard_hq_return_item_mutation();

CREATE OR REPLACE FUNCTION public._assert_hq_return_item_sources_current()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item  public.transfer_items%ROWTYPE;
  v_batch public.hq_return_batches%ROWTYPE;
BEGIN
  -- Constraint trigger 可能在同一 item 的後續 UPDATE 之後才執行，必須讀
  -- 當下最終 row，不能使用較早事件攜帶的 NEW 快照。
  SELECT * INTO v_item
    FROM public.transfer_items
   WHERE id = NEW.id;
  IF NOT FOUND THEN
    RETURN NULL; -- DELETE 已由 BEFORE guard 另行保護。
  END IF;

  FOR v_batch IN
    SELECT b.*
      FROM public.hq_return_batches b
     WHERE b.source_transfer_item_id = v_item.id
  LOOP
    IF v_batch.source_kind = 'store_return'
       AND v_item.in_movement_id IS NOT DISTINCT FROM v_batch.source_movement_id
       AND v_item.qty_received IS DISTINCT FROM v_batch.total_qty THEN
      RAISE EXCEPTION 'store return item % 的 qty_received 與來源批次不一致；請用完整實收更正流程', v_item.id;
    END IF;

    IF v_batch.source_kind = 'shortage'
       AND v_item.shortage_restock_movement_id IS NOT DISTINCT FROM v_batch.source_movement_id
       AND (v_item.qty_shipped - v_item.qty_received) IS DISTINCT FROM v_batch.total_qty THEN
      RAISE EXCEPTION 'shortage item % 的 qty_shipped/qty_received 與來源批次不一致；請先完整撤銷短少處理', v_item.id;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public._assert_hq_return_item_sources_current() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_hq_return_item_sources_current() FROM anon;
REVOKE ALL ON FUNCTION public._assert_hq_return_item_sources_current() FROM authenticated;

CREATE CONSTRAINT TRIGGER trg_assert_hq_return_item_sources_current
  AFTER INSERT OR UPDATE ON public.transfer_items
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public._assert_hq_return_item_sources_current();

-- ============================================================
-- 4. header 守門
--
-- 同時驗 OLD/NEW 的來源店與台北月份。短收純記帳子單沒有 batch，仍由
-- shortage_return_transfer_id 關係辨認。真正退貨尚有 active batch 時，
-- 不能跳過 reversal 直接離開 received/closed。
-- ============================================================
CREATE OR REPLACE FUNCTION public._guard_hq_return_transfer_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_has_batch  BOOLEAN;
  v_has_active BOOLEAN;
  v_is_credit  BOOLEAN;
  v_guard      RECORD;
BEGIN
  SELECT EXISTS (
           SELECT 1
             FROM public.transfer_items ti
             JOIN public.hq_return_batches b ON b.source_transfer_item_id = ti.id
            WHERE ti.transfer_id = OLD.id
         ),
         EXISTS (
           SELECT 1
             FROM public.transfer_items ti
             JOIN public.hq_return_batches b ON b.source_transfer_item_id = ti.id
            WHERE ti.transfer_id = OLD.id
              AND b.status IN ('pending','partial')
         ),
         EXISTS (
           SELECT 1 FROM public.transfer_items ti
            WHERE ti.shortage_return_transfer_id = OLD.id
         )
    INTO v_has_batch, v_has_active, v_is_credit;

  IF TG_OP = 'DELETE' THEN
    IF OLD.transfer_type = 'return_to_hq'
       AND (OLD.status IN ('received','closed') OR v_has_batch OR v_is_credit) THEN
      PERFORM public._hq_assert_return_month_open(
        OLD.tenant_id, OLD.source_location, OLD.received_at
      );
    END IF;
    IF v_has_batch THEN
      RAISE EXCEPTION 'return transfer % 已有總倉退回貨軌跡，不能刪除', OLD.id;
    END IF;
    RETURN OLD;
  END IF;

  IF v_has_batch AND (
       NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
    OR NEW.transfer_type IS DISTINCT FROM OLD.transfer_type
    OR NEW.source_location IS DISTINCT FROM OLD.source_location
    OR NEW.dest_location IS DISTINCT FROM OLD.dest_location
  ) THEN
    RAISE EXCEPTION 'return transfer % 已有總倉退回貨軌跡，不能改 tenant/type/location', OLD.id;
  END IF;

  IF v_has_active
     AND OLD.status IN ('received','closed')
     AND NEW.status NOT IN ('received','closed') THEN
    RAISE EXCEPTION 'return transfer % 仍有未處理退回貨，必須先由真 reversal 完整撤回', OLD.id;
  END IF;

  IF v_has_active AND NEW.status IN ('received','closed') AND NEW.received_at IS NULL THEN
    RAISE EXCEPTION 'return transfer % 有未處理退回貨，received_at 不可清空', OLD.id;
  END IF;

  -- 排序後依序鎖 OLD/NEW 可能涉及的月份，避免跨月互換產生反向鎖序。
  FOR v_guard IN
    SELECT DISTINCT x.tenant_id, x.source_location, x.received_at
      FROM (VALUES
        (OLD.tenant_id, OLD.source_location, OLD.received_at,
         OLD.transfer_type, OLD.status),
        (NEW.tenant_id, NEW.source_location, NEW.received_at,
         NEW.transfer_type, NEW.status)
      ) AS x(tenant_id, source_location, received_at, transfer_type, status)
     WHERE x.transfer_type = 'return_to_hq'
       AND x.received_at IS NOT NULL
       AND (x.status IN ('received','closed') OR v_has_batch OR v_is_credit)
     ORDER BY x.received_at, x.tenant_id, x.source_location
  LOOP
    PERFORM public._hq_assert_return_month_open(
      v_guard.tenant_id, v_guard.source_location, v_guard.received_at
    );
  END LOOP;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._guard_hq_return_transfer_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._guard_hq_return_transfer_mutation() FROM anon;
REVOKE ALL ON FUNCTION public._guard_hq_return_transfer_mutation() FROM authenticated;

CREATE TRIGGER trg_00_guard_hq_return_transfer_update
  BEFORE UPDATE OF tenant_id, transfer_type, source_location, dest_location, status, received_at
  ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION public._guard_hq_return_transfer_mutation();

CREATE TRIGGER trg_00_guard_hq_return_transfer_delete
  BEFORE DELETE ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION public._guard_hq_return_transfer_mutation();

COMMENT ON FUNCTION public._hq_revoke_return_on_reversal() IS
  'C共同撤回 hook：真 reversal 才能原子撤回未處理 batch、釋放 reserved；partial/completed 拒絕。'
  '先驗 return/shortage 月鎖，並拒絕反向 A 已產生的處理負異動。';
COMMENT ON FUNCTION public._hq_link_return_reversal() IS
  'C AFTER hook：真正 reversal row 落表後，把 immutable movement id 補回已撤 batch；失敗整筆 rollback。';
COMMENT ON FUNCTION public._guard_hq_return_item_mutation() IS
  'C item 守門：來源 id 必須先真 reversal；不可刪除或改寫來源歸屬。';
COMMENT ON FUNCTION public._assert_hq_return_item_sources_current() IS
  'C deferred item 守門：交易最終狀態仍掛來源 movement 時，qty_received 與 shortage 的 qty_shipped-qty_received 必須一致。';
COMMENT ON FUNCTION public._guard_hq_return_transfer_mutation() IS
  'C header 守門：return_to_hq OLD/NEW 台北月份均驗月鎖；active batch 不可直接取消或撤回。';

-- ============================================================
-- 5. 月結生成器共用同一把 tenant/month lock
--
-- 真正最後 CREATE 原樣取自 20260901000000_settlement_dispatch_basis.sql:74。
-- 唯一行為差異：取得 tenant 後、任何鎖定判斷／金額讀取前拿 C 同 key。
-- ============================================================
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
  -- 月界（台北時區）：[該月1號00:00, 次月1號00:00) Asia/Taipei。
  -- ⚠ 拿來比對的欄位**每一段不一樣**（2026-09-01 起）：
  --   hq_inbound      → shipped_at（總倉派車日；本次改動）
  --   air_in/air_out  → v_store_aid_transfer_legs.booked_at（＝轉出店 shipped_at，2026-08-25 起）
  --   free_*/return_* → received_at（維持收貨日，刻意沒動）
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
  -- ⛔ 8 月以前一律擋在資料庫這一層（老闆 2026-08-31 裁示「8 月不進系統」）。
  --
  -- 為什麼要擋在這裡而不是只擋前端：這支是 SECURITY DEFINER RPC，
  -- 任何登入帳號都叫得動（下面有 GRANT ... TO authenticated），
  -- 前端月份選擇器擋不住直接打 API 的人，也擋不住下面那個內部呼叫者。
  --
  -- ⚠️ **這是故意的副作用，不是漏想**：從此 7 月、8 月**再也不能重產**。
  --   要動舊月份，先貼回滾檔回到 8/25 版，跑完再貼回來。
  -- ⚠️ **會連帶擋掉一條既有功能**：rpc_update_free_transfer_amount
  --   （最新版 20260807000000:517）改完估價會 PERFORM 這支重跑該月 ——
  --   若那筆自由轉貨是 8 月以前收貨的，**整個估價修改會失敗**（不是只跳過重算）。
  --   這是刻意選的方向：讓它「大聲失敗」，好過讓它把舊月份用新制重算掉。
  --   要改成「舊月份就跳過重算、估價照改」是另一支 migration 的事。
  IF v_month_start < DATE '2026-09-01' THEN
    RAISE EXCEPTION '月結從 2026 年 9 月起改用「派車就算錢」的新算法；% 月以及更早的月份已經凍結，不能再重新產生（老闆 2026-08-31 決定：8 月以前用系統外的對帳單處理）。真的要重算舊月份，請先請工程師把系統換回 8 月 25 日的版本。',
      to_char(v_month_start, 'YYYY-MM');
  END IF;

  SELECT tenant_id INTO v_tenant FROM stores LIMIT 1;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'no stores found, cannot infer tenant_id';
  END IF;

  -- C：與退貨更正／撤回共用 tenant＋month transaction lock。
  -- 必須早於任何 locked-status 判斷與金額來源讀取。
  PERFORM pg_advisory_xact_lock(
    hashtext('settlement:' || v_tenant::TEXT || ':' || v_month_start::TEXT)
  );

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

    -- A) hq_inbound: 總倉派給店家（成本口徑 + 分店價口徑）
    -- 記帳時點＝**總倉派車出貨當下**（老闆 2026-08-31：「錢在總倉派出去那一刻就算」）。
    -- 數量＝MAX(派出量, 實收量)：超收的店照實收收（不會少收）、
    -- 未收／短收的照派出量收（店家不按收貨不再等於不用付錢）。
    -- 狀態白名單加 'shipped'：照 20260825030000:82 的樣板 ——
    --   ⚠ 作廢單（cancelled）身上**是帶著 shipped_at 的**，靠這串白名單擋掉，
    --     不是靠時窗擋。⛔ 不可以改寫成 status <> 'draft' 之類的黑名單。
    SELECT
      COALESCE(SUM(GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * COALESCE(sm.unit_cost, 0)), 0),
      COALESCE(SUM(GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.shipped_at), 0)), 0)
      INTO v_hq_inbound, v_hq_inbound_b
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'hq_to_store'
       AND t.status IN ('shipped','received','closed')
       AND t.dest_location = v_store.location_id
       AND t.shipped_at >= v_range_start
       AND t.shipped_at < v_range_end
       AND GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) > 0
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
      COALESCE(SUM(ti.qty_received * sm.unit_cost), 0),
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
    -- 張數／筆數要跟上面的分錄同母體。分錄現在有三種時點，所以這裡拆三段：
    --   1) hq_to_store           → 派車時點（2026-09-01 起，條件與 A 段逐條相同）
    --   2) 自由轉貨／退貨回總倉  → 收貨時點（未改）
    --   3) 店↔店訂單相關腿       → 轉出時點（20260825030000，未改）
    -- ⚠ 第 1 段是**跟著 A 段一起改的**，不是順手改的：
    --   不改的話，「派了但店家從沒按收貨」那批（正是本案要處理的主要對象）
    --   會算出 payable_amount 幾萬元、transfer_count 卻是 0，
    --   而下面的 A) items 明細又真的插了列 ⇒ 同一張對帳單自己打自己的臉。
    SELECT COUNT(DISTINCT x.tid), COUNT(*)
      INTO v_xfer_count, v_item_count
      FROM (
        -- 1) hq_to_store：派車時點
        SELECT t.id AS tid, ti.id AS iid
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.tenant_id = v_tenant
           AND t.transfer_type = 'hq_to_store'
           AND t.status IN ('shipped','received','closed')
           AND t.dest_location = v_store.location_id
           AND t.shipped_at >= v_range_start
           AND t.shipped_at < v_range_end
           AND GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) > 0
           AND NOT EXISTS (SELECT 1 FROM transfers t1
                            WHERE t1.next_transfer_id = t.id
                              AND t1.transfer_type = 'store_to_store'
                              AND t1.status <> 'cancelled')
        UNION ALL
        -- 2) 自由轉貨／退貨回總倉：收貨時點
        SELECT t.id AS tid, ti.id AS iid
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.tenant_id = v_tenant
           AND t.status IN ('received','closed')
           AND t.received_at >= v_range_start
           AND t.received_at < v_range_end
           AND ti.qty_received > 0
           AND (
             (t.transfer_type = 'store_to_store' AND t.customer_order_id IS NULL
              AND t.next_transfer_id IS NULL
              AND (t.dest_location = v_store.location_id OR t.source_location = v_store.location_id))
             OR
             (t.transfer_type = 'return_to_hq' AND t.source_location = v_store.location_id)
           )
        UNION ALL
        -- 3) 店↔店訂單相關腿：轉出時點
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
    -- ⚠ 欄位名沿用 qty_received / received_at 不改名（改名會連動前端 14 檔），
    --   但存進去的是「這筆帳的計價數量」＝MAX(派出量,實收量) 與
    --   「這筆帳成立的時間」＝總倉派車當下 —— 同 20260825030000:398 的處理慣例。
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)), sm.unit_cost,
      CASE
        WHEN sm.unit_cost IS NULL THEN NULL
        ELSE GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * sm.unit_cost
      END,
      t.shipped_at, 'hq_inbound',
      bp.p, GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * bp.p
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.shipped_at), 0) AS p
      ) bp
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'hq_to_store'
       AND t.status IN ('shipped','received','closed')
       AND t.dest_location = v_store.location_id
       AND t.shipped_at >= v_range_start
       AND t.shipped_at < v_range_end
       AND GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) > 0
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
      ti.sku_id, ti.qty_received, sm.unit_cost,
      CASE WHEN sm.unit_cost IS NULL THEN NULL ELSE -1 * ti.qty_received * sm.unit_cost END,  -- 負值
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
  'hq_inbound 以**總倉派車出貨當下**入帳（老闆 2026-08-31「錢在總倉派出去那一刻就算」），'
  '數量 = MAX(派出量, 實收量)，狀態白名單 shipped/received/closed（作廢單有 shipped_at，靠白名單擋）。'
  '店↔店訂單相關轉貨（空中轉／經總倉互助）以**轉出店出貨當下**入帳、兩邊鏡像同額'
  '（v_store_aid_transfer_legs）；經總倉 Leg-2 不重複計 hq_inbound、Leg-1 不再誤入 free_out。'
  '自由轉貨、return_to_hq 維持收貨時點（return_to_hq 是「總倉同意才沖帳」的語意，刻意不改）。'
  '短收差額由 20260901000010 產生的純記帳 return_to_hq 沖掉（restock_hq/redispatch 兩顆鈕都會產），'
  '⚠ 沖帳的分店價以「按鈕當下」計價，與原扣款的「派車當下」在改過價的商品上會有差額。'
  '已 confirmed/settled/remitted/cancelled 不重算。基底 20260825030000。'
  'C 起與退貨月份守門共用 tenant＋month advisory transaction lock，鎖在狀態判斷與金額讀取之前。';

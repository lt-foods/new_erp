-- ============================================================
-- 2026-08-10: 短收處理新增「沖回總倉庫存」(restock_hq)
--
-- 問題（松山 WAVE-1149-S2 / WAVE-1153-S2 短收 4 件）：
--   派貨出倉時 transfer_out 已扣總倉庫存；店端實收填 0 之後，
--   那批貨不進店、也沒有任何機制把它記回總倉 —— 帳上憑空消失。
--   既有的 rpc_resolve_transfer_item_shortage 只打標記
--   （replenish / cancel_orders / vendor_claim / accept），
--   全都不會動庫存。但實務上最常見的短收原因是「漏裝／揀貨少拿，
--   貨其實還在總倉」，這種 case 需要把帳補回來，貨才能再派。
--
-- 修法：
--   1. transfer_items.shortage_resolution 允許值加 'restock_hq'，
--      新欄 shortage_restock_movement_id 記沖回的 movement（防重複沖）。
--   2. rpc_resolve_transfer_item_shortage v2：p_resolution='restock_hq'
--      時把 (qty_shipped − qty_received) 以原出庫成本
--      rpc_inbound(movement_type='transfer_cancel') 回 source_location
--      （語意同 20260713000000：對方沒收到的貨記回出貨端），
--      並記 movement id。守衛：無短收量 / 已沖回過 / 調撥非
--      received|closed 皆擋。
--
-- 真的遺失（物流丟件、供應商短裝）仍走 vendor_claim / accept，
-- 庫存以實收為準、不沖回。
--
-- 基底版本：rpc_resolve_transfer_item_shortage ←
--   20260607000040_transfer_shortage_resolution.sql（唯一版本；
--   逐字保留 role gate 與原 4 個 resolution 的行為）。
--
-- Rollback:
--   - CREATE OR REPLACE 回 20260607000040 版本
--   - constraint 還原（先確認沒有 restock_hq 資料）：
--       ALTER TABLE transfer_items DROP CONSTRAINT transfer_items_shortage_resolution_check;
--       ALTER TABLE transfer_items ADD CONSTRAINT transfer_items_shortage_resolution_check
--         CHECK (shortage_resolution IS NULL OR shortage_resolution IN
--           ('replenish','cancel_orders','vendor_claim','accept'));
--   - ALTER TABLE transfer_items DROP COLUMN IF EXISTS shortage_restock_movement_id;
--     （已沖回的 movement 需另以 reversal 處理，不自動回滾）
-- ============================================================

-- ----------------------------------------------------------------
-- 1. schema：允許值 + 沖回 movement 記錄欄
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_conname TEXT;
BEGIN
  -- 原 CHECK 是 20260607000040 的行內匿名 constraint，名字自動生成；
  -- 依定義內容找出來丟掉再重建（含 restock_hq）
  SELECT conname INTO v_conname
    FROM pg_constraint
   WHERE conrelid = 'transfer_items'::regclass
     AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%shortage_resolution%';
  IF v_conname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE transfer_items DROP CONSTRAINT %I', v_conname);
  END IF;
END $$;

ALTER TABLE transfer_items
  ADD CONSTRAINT transfer_items_shortage_resolution_check
    CHECK (shortage_resolution IS NULL OR shortage_resolution IN
      ('replenish','cancel_orders','vendor_claim','accept','restock_hq'));

ALTER TABLE transfer_items
  ADD COLUMN IF NOT EXISTS shortage_restock_movement_id BIGINT;

COMMENT ON COLUMN transfer_items.shortage_resolution IS
  '短收處理方式:replenish=補出貨/cancel_orders=取消客戶訂單/vendor_claim=供應商求償/'
  'accept=接受認賠/restock_hq=貨仍在總倉,短收量沖回出貨端庫存';
COMMENT ON COLUMN transfer_items.shortage_restock_movement_id IS
  'restock_hq 沖回出貨端庫存的 stock_movement id（有值=已沖回，不可重複沖）';

-- ----------------------------------------------------------------
-- 2. rpc_resolve_transfer_item_shortage v2 — 支援 restock_hq
--    基底：20260607000040 逐字保留，加 restock_hq 分支。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_resolve_transfer_item_shortage(
  p_transfer_item_id BIGINT,
  p_resolution       TEXT,
  p_notes            TEXT,
  p_operator         UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role      TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_item      transfer_items%ROWTYPE;
  v_transfer  transfers%ROWTYPE;
  v_shortage  NUMERIC;
  v_unit_cost NUMERIC;
  v_mov_id    BIGINT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot resolve shortage', v_role;
  END IF;
  IF p_resolution NOT IN ('replenish','cancel_orders','vendor_claim','accept','restock_hq') THEN
    RAISE EXCEPTION 'invalid resolution: %', p_resolution;
  END IF;

  SELECT * INTO v_item FROM transfer_items
   WHERE id = p_transfer_item_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_item % not found', p_transfer_item_id;
  END IF;

  -- restock_hq：短收量以原出庫成本記回出貨端庫存
  IF p_resolution = 'restock_hq' THEN
    v_shortage := COALESCE(v_item.qty_shipped, 0) - COALESCE(v_item.qty_received, 0);
    IF v_shortage <= 0 THEN
      RAISE EXCEPTION '此明細沒有短收數量（出 % / 收 %），不需沖回',
        v_item.qty_shipped, v_item.qty_received;
    END IF;
    IF v_item.shortage_restock_movement_id IS NOT NULL THEN
      RAISE EXCEPTION '此明細已沖回過出貨端庫存（movement %），不可重複沖回',
        v_item.shortage_restock_movement_id;
    END IF;

    SELECT * INTO v_transfer FROM transfers
     WHERE id = v_item.transfer_id
     FOR UPDATE;
    IF v_transfer.status NOT IN ('received','closed') THEN
      RAISE EXCEPTION '調撥單 % 狀態為「%」，僅已收貨(received/closed)可沖回短收',
        v_item.transfer_id, v_transfer.status;
    END IF;

    SELECT COALESCE(ABS(unit_cost), 0) INTO v_unit_cost
      FROM stock_movements
     WHERE id = v_item.out_movement_id;

    -- 語意同 transfer_cancel（20260713000000）：對方沒收到的貨記回出貨端
    v_mov_id := rpc_inbound(
      p_tenant_id       => v_transfer.tenant_id,
      p_location_id     => v_transfer.source_location,
      p_sku_id          => v_item.sku_id,
      p_quantity        => v_shortage,
      p_unit_cost       => COALESCE(v_unit_cost, 0),
      p_movement_type   => 'transfer_cancel',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_item.transfer_id,
      p_operator        => p_operator
    );
  END IF;

  UPDATE transfer_items
     SET shortage_resolution          = p_resolution,
         shortage_resolution_at       = NOW(),
         shortage_resolution_by       = p_operator,
         shortage_resolution_notes    = NULLIF(TRIM(p_notes), ''),
         shortage_restock_movement_id = COALESCE(v_mov_id, shortage_restock_movement_id),
         updated_by                   = p_operator
   WHERE id = p_transfer_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_resolve_transfer_item_shortage(BIGINT, TEXT, TEXT, UUID)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_resolve_transfer_item_shortage(BIGINT, TEXT, TEXT, UUID) IS
  'HQ 處理收貨短少:標記 resolution(replenish/cancel_orders/vendor_claim/accept/restock_hq)+ 備註。'
  'restock_hq 會把短收量以原出庫成本沖回出貨端庫存(transfer_cancel movement,防重複);'
  '其餘 resolution 僅打標記,實際補出貨/取消訂單由其他流程做。';

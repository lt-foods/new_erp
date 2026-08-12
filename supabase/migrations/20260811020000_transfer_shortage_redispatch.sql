-- ============================================================
-- 2026-08-11: 收貨短少新增「拒絕短收（沖回＋自動重派撿貨單）」(redispatch)
--
-- 需求（使用者 2026-08-11）：收貨短少要能「拒絕」— 短收量沖回總倉之後，
-- 自動再開一張撿貨單回原店家、接回原訂單，不必人工去自由轉貨建單。
--
-- 現況痛點：restock_hq 只把短收量沖回總倉庫存，貨帳回來了但沒人重派 —
--   工作台的需求模型認為該 (po, sku, store) 已派過（wave_qty 含原出貨），
--   不會再邀請派貨；replenish 選項只是連去自由轉貨頁手動建單，而自由轉貨
--   不掛 campaign → 原團購單收貨後接不回（單頭卡 shipping/confirmed）。
--
-- 修法：
--   1. transfer_items.shortage_resolution 允許值加 'redispatch'，
--      新欄 shortage_redispatch_wave_id 記重派 wave（防重複重派）。
--   2. rpc_resolve_transfer_item_shortage v3：p_resolution='redispatch' 時
--      a) 短收量沖回總倉（與 restock_hq 完全同語意：原出庫成本、
--         movement_type='transfer_cancel'；若該明細先前已沖回過則跳過）。
--      b) 自動開一張 draft 撿貨單（單一品項 × 原店 × 短收量），
--         wave_date 預設隔天（同派貨工作台慣例，可在收件匣撿貨單上調整）。
--         campaign_id / source_po_id 皆繼承原出貨 wave 的 wave item —
--         campaign 對得上，出貨時 rpc_mark_orders_shipping_for_wave 才推得動
--         原訂單（confirmed→shipping），店端收貨走 rpc_receive_transfer
--         邏輯 C 推 ready；source_po_id 對得上，工作台的 already_wave
--         帳才會把沖回的貨視為「已被重派佔用」，不會被派給別人。
--      守衛：短收量>0 / 未重派過 / 調撥已收貨(received|closed) /
--         出貨端必須是總倉（店對店短收沒有「從總倉再撿一次」的語意，
--         請走自由轉貨）/ 收貨端要對得到分店。
--
-- 真的遺失（物流丟件、供應商短裝）仍走 vendor_claim / accept；
-- 只想補帳不重派仍可用 restock_hq。
--
-- 基底版本：rpc_resolve_transfer_item_shortage ←
--   20260810000010_shortage_restock_back_to_source.sql（v2，最新版；
--   逐字保留 role gate、restock_hq 分支與原 4 個 resolution 的行為）。
--   曾動過此 function 的 migration：20260607000040（v1）、20260810000010（v2）。
--
-- Rollback:
--   - CREATE OR REPLACE 回 20260810000010 版本
--   - constraint 還原（先確認沒有 redispatch 資料）：
--       ALTER TABLE transfer_items DROP CONSTRAINT transfer_items_shortage_resolution_check;
--       ALTER TABLE transfer_items ADD CONSTRAINT transfer_items_shortage_resolution_check
--         CHECK (shortage_resolution IS NULL OR shortage_resolution IN
--           ('replenish','cancel_orders','vendor_claim','accept','restock_hq'));
--   - ALTER TABLE transfer_items DROP COLUMN IF EXISTS shortage_redispatch_wave_id;
--     （已建立的重派 wave / 已沖回的 movement 需人工處理，不自動回滾）
-- ============================================================

-- ----------------------------------------------------------------
-- 1. schema：允許值 + 重派 wave 記錄欄
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_conname TEXT;
BEGIN
  -- 依定義內容找出現行 CHECK（20260810000010 已改為具名，但保守處理）
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
      ('replenish','cancel_orders','vendor_claim','accept','restock_hq','redispatch'));

ALTER TABLE transfer_items
  ADD COLUMN IF NOT EXISTS shortage_redispatch_wave_id BIGINT REFERENCES picking_waves(id);

COMMENT ON COLUMN transfer_items.shortage_resolution IS
  '短收處理方式:replenish=補出貨/cancel_orders=取消客戶訂單/vendor_claim=供應商求償/'
  'accept=接受認賠/restock_hq=貨仍在總倉,短收量沖回出貨端庫存/'
  'redispatch=拒絕短收:沖回總倉並自動開撿貨單重派回原店';
COMMENT ON COLUMN transfer_items.shortage_redispatch_wave_id IS
  'redispatch 自動建立的重派撿貨單 wave id（有值=已重派過，不可重複重派）';

-- ----------------------------------------------------------------
-- 2. rpc_resolve_transfer_item_shortage v3 — 支援 redispatch
--    基底：20260810000010 逐字保留，加 redispatch 分支。
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
  v_role        TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_item        transfer_items%ROWTYPE;
  v_transfer    transfers%ROWTYPE;
  v_shortage    NUMERIC;
  v_unit_cost   NUMERIC;
  v_mov_id      BIGINT;
  -- redispatch 用
  v_src_type    TEXT;
  v_store_id    BIGINT;
  v_campaign_id BIGINT;
  v_src_po_id   BIGINT;
  v_wave_id     BIGINT;
  v_wave_code   TEXT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot resolve shortage', v_role;
  END IF;
  IF p_resolution NOT IN ('replenish','cancel_orders','vendor_claim','accept','restock_hq','redispatch') THEN
    RAISE EXCEPTION 'invalid resolution: %', p_resolution;
  END IF;

  SELECT * INTO v_item FROM transfer_items
   WHERE id = p_transfer_item_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_item % not found', p_transfer_item_id;
  END IF;

  -- restock_hq / redispatch 共同前置：算短收量、鎖調撥單、驗狀態
  IF p_resolution IN ('restock_hq','redispatch') THEN
    v_shortage := COALESCE(v_item.qty_shipped, 0) - COALESCE(v_item.qty_received, 0);
    IF v_shortage <= 0 THEN
      RAISE EXCEPTION '此明細沒有短收數量（出 % / 收 %），不需處理',
        v_item.qty_shipped, v_item.qty_received;
    END IF;

    SELECT * INTO v_transfer FROM transfers
     WHERE id = v_item.transfer_id
     FOR UPDATE;
    IF v_transfer.status NOT IN ('received','closed') THEN
      RAISE EXCEPTION '調撥單 % 狀態為「%」，僅已收貨(received/closed)可處理短收',
        v_item.transfer_id, v_transfer.status;
    END IF;
  END IF;

  -- restock_hq：短收量以原出庫成本記回出貨端庫存（20260810000010 原行為）
  IF p_resolution = 'restock_hq' THEN
    IF v_item.shortage_restock_movement_id IS NOT NULL THEN
      RAISE EXCEPTION '此明細已沖回過出貨端庫存（movement %），不可重複沖回',
        v_item.shortage_restock_movement_id;
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

  -- redispatch：拒絕短收 — 沖回總倉 + 自動開撿貨單重派回原店
  IF p_resolution = 'redispatch' THEN
    IF v_item.shortage_redispatch_wave_id IS NOT NULL THEN
      RAISE EXCEPTION '此明細已重派過（撿貨單 wave %），不可重複重派',
        v_item.shortage_redispatch_wave_id;
    END IF;

    -- 重派 = 從總倉再撿一次；店對店短收沒有這個語意 → 擋下，請走自由轉貨
    SELECT l.type INTO v_src_type FROM locations l WHERE l.id = v_transfer.source_location;
    IF COALESCE(v_src_type, '') <> 'central_warehouse' THEN
      RAISE EXCEPTION '調撥單 % 的出貨端不是總倉，無法自動重派；店對店短收請改用「補出貨」走自由轉貨',
        v_transfer.transfer_no;
    END IF;

    SELECT ds.id INTO v_store_id
      FROM stores ds
     WHERE ds.location_id = v_transfer.dest_location
     ORDER BY ds.id
     LIMIT 1;
    IF v_store_id IS NULL THEN
      RAISE EXCEPTION '調撥單 % 的收貨端對不到分店，無法自動重派', v_transfer.transfer_no;
    END IF;

    -- a) 沖回總倉（同 restock_hq；先前已用 restock_hq 沖回過就不重複沖）
    IF v_item.shortage_restock_movement_id IS NULL THEN
      SELECT COALESCE(ABS(unit_cost), 0) INTO v_unit_cost
        FROM stock_movements
       WHERE id = v_item.out_movement_id;

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

    -- b) 繼承原出貨 wave 的 campaign / source_po：
    --    campaign 對上 → 出貨時 rpc_mark_orders_shipping_for_wave 推得動原訂單；
    --    source_po 對上 → rpc_create_wave_from_po 的 already_wave 帳把沖回的貨
    --    視為已被本次重派佔用，工作台不會再派給別人。
    --    補貨直派 transfer 沒有 wave item → 兩者為 NULL，收貨端仍有
    --    _advance_arrived_confirmed_orders（20260811000020）接手推單。
    SELECT pwi.campaign_id, pw.source_po_id
      INTO v_campaign_id, v_src_po_id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id
     WHERE pwi.generated_transfer_id = v_item.transfer_id
       AND pwi.sku_id = v_item.sku_id
     LIMIT 1;

    -- c) 開 draft 撿貨單（wave_code 用 sequence，同 20260609000001）
    v_wave_code := 'WV'
                || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYMMDD')
                || LPAD(nextval('public.picking_wave_code_seq')::TEXT, 6, '0');

    INSERT INTO picking_waves (
      tenant_id, wave_code, wave_date, status, source_po_id,
      store_count, item_count, total_qty, note, created_by, updated_by
    ) VALUES (
      v_transfer.tenant_id, v_wave_code, CURRENT_DATE + 1, 'draft', v_src_po_id,
      1, 1, v_shortage,
      '短收重派 ← ' || v_transfer.transfer_no || '（短收 ' || v_shortage || ' 件）',
      p_operator, p_operator
    ) RETURNING id INTO v_wave_id;

    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, campaign_id, note,
      created_by, updated_by
    ) VALUES (
      v_transfer.tenant_id, v_wave_id, v_item.sku_id, v_store_id, v_shortage,
      v_campaign_id, '短收重派 ← ' || v_transfer.transfer_no,
      p_operator, p_operator
    );

    INSERT INTO picking_wave_audit_log (
      tenant_id, wave_id, action, after_value, note, created_by
    ) VALUES (
      v_transfer.tenant_id, v_wave_id, 'wave_created',
      jsonb_build_object(
        'redispatch_from_transfer_id', v_item.transfer_id,
        'transfer_item_id', v_item.id,
        'sku_id', v_item.sku_id,
        'store_id', v_store_id,
        'qty', v_shortage,
        'campaign_id', v_campaign_id,
        'source_po_id', v_src_po_id
      ),
      '收貨短少拒絕短收自動重派', p_operator
    );
  END IF;

  UPDATE transfer_items
     SET shortage_resolution          = p_resolution,
         shortage_resolution_at       = NOW(),
         shortage_resolution_by       = p_operator,
         shortage_resolution_notes    = NULLIF(TRIM(p_notes), ''),
         shortage_restock_movement_id = COALESCE(v_mov_id, shortage_restock_movement_id),
         shortage_redispatch_wave_id  = COALESCE(v_wave_id, shortage_redispatch_wave_id),
         updated_by                   = p_operator
   WHERE id = p_transfer_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_resolve_transfer_item_shortage(BIGINT, TEXT, TEXT, UUID)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_resolve_transfer_item_shortage(BIGINT, TEXT, TEXT, UUID) IS
  'HQ 處理收貨短少:標記 resolution(replenish/cancel_orders/vendor_claim/accept/restock_hq/redispatch)+ 備註。'
  'restock_hq 把短收量以原出庫成本沖回出貨端庫存(transfer_cancel movement,防重複);'
  'redispatch=拒絕短收:沖回總倉＋自動開 draft 撿貨單重派回原店(繼承原 wave 的 campaign/source_po,'
  '出貨收貨後原訂單自動推進);其餘 resolution 僅打標記。';

-- ============================================================
-- 2026-09-03：單頭備註要寫得出「誰做的」
--
-- 老闆 2026-09-03（看到中和店那筆撤銷後回到收貨短少、備註寫著
--   「撤銷處理（09/03 22:16）：… ← 不同意退貨-跟店家收錢｜實收 6 → 5」）：「這筆誰做的」
--
-- 就是這個洞：20260903000200 的撤銷、20260903000005 的實收調整都會往
-- transfers.notes 追加一行軌跡（總倉收件匣把它當「店家收貨備註」顯示，
-- v_hq_exceptions 20260824020000:1467 / :1529），但那行**只有時間沒有人**
-- ⇒ 看到那行的人問「誰做的」時，只能靠 transfer_items.updated_by 反查 auth.users，
--   而且那一欄會被下一個動作蓋掉 ⇒ 隔一手就查不到了。
-- 對照組：「異常 → 已處理」那一頁有「誰按的」欄（讀 shortage_resolution_by），
--   但撤銷之後那一列就消失了 ⇒ 備註是撤銷唯一的軌跡，它非寫名字不可。
--
-- 改了什麼（兩支各兩處，其餘逐字保留 20260903000200 的全文）：
--   1. DECLARE 多一個 v_op_name。
--   2. 組 v_log 之前查名字（public.rpc_get_staff_names，20260428170000 —— 前端
--      「誰按的」那一欄用的同一支 ⇒ 兩邊叫同一個名字），格式從
--      「撤銷處理（09/03 22:16）：…」變成「撤銷處理（09/03 22:16・cktalex）：…」。
--      查不到就退回 uid 前 8 碼。
--   ⛔ 判定、守衛、庫存動作、回傳值一律沒動。
--
-- ⚠️ 既有的備註行**不回填**：那是自由文字，用字串手術去插名字風險大於價值，
--   而且既有那兩行（松山 / 中和的撤銷）已經查證過都是 cktalex
--   （transfer_items.updated_by = 39fd694d-…7246）。⇒ 只修往後。
--
-- 基底：20260903000200_shortage_resolution_undo.sql 的兩支（已對線上
--   pg_get_functiondef() 逐字 diff 確認 repo == 線上）。
-- Rollback：兩支改回 20260903000200 的版本（把 v_op_name 與那段 SELECT 拿掉、
--   format 少一個 %s）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_undo_transfer_item_shortage(
  p_transfer_item_id BIGINT,
  p_operator         UUID,
  p_notes            TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_transfer_id  BIGINT;
  v_item         transfer_items%ROWTYPE;
  v_transfer     transfers%ROWTYPE;
  v_orig         stock_movements%ROWTYPE;
  v_on_hand      NUMERIC;
  v_wave         RECORD;
  v_locked       TEXT;
  v_label        TEXT;
  v_res          TEXT;
  v_res_label    TEXT;
  v_restock_reversed NUMERIC := 0;
  v_wave_cancelled   BOOLEAN := FALSE;
  v_ret_cancelled    BOOLEAN := FALSE;
  v_qty_restored     NUMERIC := NULL;
  v_existing_notes   TEXT;
  v_log              TEXT;
  v_op_name          TEXT;   -- 20260903000210：備註要寫「誰做的」
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot undo shortage resolution', v_role;
  END IF;

  -- 鎖的順序跟 rpc_adjust_received_transfer 一致（advisory → transfers → transfer_items），
  -- 所以先不鎖只讀出 transfer_id。
  SELECT transfer_id INTO v_transfer_id
    FROM transfer_items WHERE id = p_transfer_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_item % not found', p_transfer_item_id;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || v_transfer_id));

  SELECT * INTO v_transfer FROM transfers WHERE id = v_transfer_id FOR UPDATE;
  SELECT * INTO v_item     FROM transfer_items WHERE id = p_transfer_item_id FOR UPDATE;

  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_transfer.tenant_id THEN
    RAISE EXCEPTION 'transfer_item not in current tenant';
  END IF;

  IF v_item.shortage_resolution IS NULL THEN
    RAISE EXCEPTION '這一筆沒有處理紀錄，不用撤銷（可能已經被別人撤掉了，請重新整理）';
  END IF;

  v_res := v_item.shortage_resolution;
  v_res_label := CASE v_res
                   WHEN 'restock_hq'    THEN '同意退回-不補貨'
                   WHEN 'redispatch'    THEN '同意退回-補貨'
                   WHEN 'reject_return' THEN '不同意退貨-跟店家收錢'
                   WHEN 'over_ack'      THEN '多收知道了'
                   WHEN 'accept'        THEN '當作沒了（舊）'
                   WHEN 'vendor_claim'  THEN '供應商求償（舊）'
                   WHEN 'replenish'     THEN '補出貨（舊）'
                   ELSE v_res
                 END;

  SELECT COALESCE(NULLIF(TRIM(v_item.description), ''),
                  NULLIF(TRIM(COALESCE(s.product_name, '')
                              || COALESCE(' / ' || NULLIF(s.variant_name, ''), '')), ''),
                  '品項#' || v_item.id::TEXT)
    INTO v_label
    FROM skus s WHERE s.id = v_item.sku_id;
  v_label := COALESCE(v_label, '品項#' || v_item.id::TEXT);

  -- ===== 守衛 A：cancel_orders（舊值）—— 客人已收到取消通知 =====
  -- 逐字沿用邏輯 H 的守衛理由（20260901000020:167-172）。
  IF v_res = 'cancel_orders' THEN
    RAISE EXCEPTION '這一筆當初的處理是「取消客戶訂單」，客人已經收到取消通知，不能一鍵撤銷 — 請聯繫總倉人工處理';
  END IF;

  -- ===== 守衛 B：重派撿貨單已離開 draft =====
  IF v_item.shortage_redispatch_wave_id IS NOT NULL THEN
    SELECT pw.id, pw.wave_code, pw.status INTO v_wave
      FROM picking_waves pw
     WHERE pw.id = v_item.shortage_redispatch_wave_id
     FOR UPDATE;
    IF v_wave.id IS NOT NULL AND v_wave.status NOT IN ('draft','cancelled') THEN
      RAISE EXCEPTION '補派的撿貨單 %（目前「%」）已經在進行中，不能直接撤銷 — 請先到「📋 撿貨單」把那張單取消，再回來撤銷這一筆',
        v_wave.wave_code, v_wave.status;
    END IF;
  END IF;

  -- ===== 守衛 C：沖帳落在已鎖定的月份（同 20260901000020 守衛 B-1）=====
  IF v_item.shortage_return_transfer_id IS NOT NULL THEN
    SELECT string_agg(DISTINCT st.name || '（' || sms.status || '）', '、')
      INTO v_locked
      FROM transfers rt
      JOIN stores st ON st.location_id = rt.source_location
      JOIN store_monthly_settlements sms
        ON sms.store_id = st.id
       AND sms.settlement_month = DATE_TRUNC('month', rt.received_at AT TIME ZONE 'Asia/Taipei')::DATE
     WHERE rt.id = v_item.shortage_return_transfer_id
       AND rt.status IN ('received','closed')
       AND sms.status IN ('confirmed','settled','remitted');
    IF v_locked IS NOT NULL THEN
      RAISE EXCEPTION '這一筆的短收已經沖過帳，而那筆沖帳所在月份的對帳單已經鎖定：%。鎖定後不能自動撤銷，請聯繫總倉人工處理。',
        v_locked;
    END IF;
  END IF;

  -- ===== 守衛 D：reject_return 還原實收會動到錢、而那個月已鎖定 =====
  -- 判準與 rpc_resolve_transfer_item_shortage 的補回段一模一樣（改一邊要改兩邊）。
  IF v_res = 'reject_return'
     AND v_item.shortage_prev_qty_received IS NOT NULL
     AND NOT (
       v_transfer.transfer_type = 'hq_to_store'
       OR (v_transfer.transfer_type = 'store_to_store'
           AND (v_transfer.customer_order_id IS NOT NULL
                OR v_transfer.next_transfer_id IS NOT NULL))
     ) THEN
    SELECT string_agg(DISTINCT st.name || '（' || sms.status || '）', '、')
      INTO v_locked
      FROM stores st
      JOIN store_monthly_settlements sms
        ON sms.store_id = st.id
       AND sms.settlement_month
           = DATE_TRUNC('month', COALESCE(v_transfer.received_at, NOW()) AT TIME ZONE 'Asia/Taipei')::DATE
     WHERE st.location_id IN (v_transfer.source_location, v_transfer.dest_location)
       AND sms.status IN ('confirmed','settled','remitted');
    IF v_locked IS NOT NULL THEN
      RAISE EXCEPTION '把實收還原回去會動到這張單的月結金額，但該月對帳單已鎖定：%。請聯繫總倉人工處理。',
        v_locked;
    END IF;
  END IF;

  -- ===== a) 沖銷「記回出貨端」的那筆 transfer_cancel 入庫 =====
  IF v_item.shortage_restock_movement_id IS NOT NULL THEN
    SELECT * INTO v_orig FROM stock_movements
     WHERE id = v_item.shortage_restock_movement_id;
    IF v_orig.id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
      SELECT on_hand INTO v_on_hand
        FROM stock_balances
       WHERE tenant_id   = v_orig.tenant_id
         AND location_id = v_orig.location_id
         AND sku_id      = v_orig.sku_id
       FOR UPDATE;
      IF COALESCE(v_on_hand, 0) < v_orig.quantity THEN
        RAISE EXCEPTION '出貨端庫存不足以撤回這筆沖回（SKU %：現有 %、需沖銷 %）— 沖回的貨可能已經被派出去了，請聯繫總倉',
          v_orig.sku_id, COALESCE(v_on_hand, 0), v_orig.quantity;
      END IF;
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
      ) VALUES (
        v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
        -v_orig.quantity, v_orig.unit_cost, 'reversal',
        'transfer', v_transfer_id, v_item.id, v_orig.id,
        format('撤銷短少處理（%s）transfer=%s item=%s（沖銷 movement %s）',
               v_res, v_transfer_id, v_item.id, v_orig.id),
        p_operator
      );
      v_restock_reversed := v_orig.quantity;
    END IF;
  END IF;

  -- ===== b) 取消 draft 的重派撿貨單 =====
  IF v_item.shortage_redispatch_wave_id IS NOT NULL THEN
    UPDATE picking_waves
       SET status = 'cancelled', updated_by = p_operator, updated_at = NOW()
     WHERE id = v_item.shortage_redispatch_wave_id
       AND status = 'draft';
    IF FOUND THEN
      INSERT INTO picking_wave_audit_log (
        tenant_id, wave_id, action, after_value, note, created_by
      ) VALUES (
        v_transfer.tenant_id, v_item.shortage_redispatch_wave_id, 'wave_cancelled',
        jsonb_build_object('undo_transfer_id', v_transfer_id,
                           'transfer_item_id', v_item.id),
        '總倉撤銷短收處理，收回重派', p_operator
      );
      v_wave_cancelled := TRUE;
    END IF;
  END IF;

  -- ===== c) 作廢短收沖帳的純記帳單（只改狀態，不碰庫存）=====
  IF v_item.shortage_return_transfer_id IS NOT NULL THEN
    UPDATE transfers
       SET status     = 'cancelled',
           notes      = COALESCE(notes, '')
                        || ' [總倉撤銷短收處理，連帶作廢 '
                        || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD') || ']',
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_item.shortage_return_transfer_id
       AND status IN ('received','closed');
    IF FOUND THEN
      v_ret_cancelled := TRUE;
    END IF;
  END IF;

  -- ===== d) reject_return 補上去的實收 → 還原 =====
  IF v_res = 'reject_return' AND v_item.shortage_prev_qty_received IS NOT NULL THEN
    v_qty_restored := v_item.shortage_prev_qty_received;
  END IF;

  -- ===== e) 清掉處理標記 ⇒ 那一列回到「未處理」，自己重新出現在總倉收件匣 =====
  UPDATE transfer_items
     SET qty_received                 = COALESCE(v_qty_restored, qty_received),
         shortage_resolution          = NULL,
         shortage_resolution_at       = NULL,
         shortage_resolution_by       = NULL,
         shortage_resolution_notes    = NULL,
         shortage_restock_movement_id = NULL,
         shortage_redispatch_wave_id  = NULL,
         shortage_return_transfer_id  = NULL,
         shortage_prev_qty_received   = NULL,
         updated_by                   = p_operator,
         updated_at                   = NOW()
   WHERE id = p_transfer_item_id;

  -- ===== 軌跡：撤銷會把「已處理」那一頁的紀錄刪掉，所以一定要往單頭備註留一行 =====
  -- 總倉收件匣的短少列會把 transfers.notes 當「店家收貨備註」顯示（v_hq_exceptions）。
  SELECT notes INTO v_existing_notes FROM transfers WHERE id = v_transfer_id;
  -- 20260903000210：備註要寫得出「誰做的」。rpc_get_staff_names（20260428170000）
  -- 是既有的唯一查名機制（SECURITY DEFINER 讀 auth.users），前端「誰按的」那一欄用的也是它
  -- ⇒ 兩邊會叫同一個名字。查不到就退回 uid 前 8 碼（那支函式自己也是這個 fallback）。
  SELECT n.display_name INTO v_op_name
    FROM public.rpc_get_staff_names(ARRAY[p_operator]) n LIMIT 1;

  v_log := format('撤銷處理（%s・%s）：%s ← %s',
                  to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'MM/DD HH24:MI'),
                  COALESCE(NULLIF(TRIM(v_op_name), ''), left(p_operator::TEXT, 8)),
                  v_label, v_res_label)
           || CASE WHEN v_qty_restored IS NOT NULL
                   THEN format('｜實收 %s → %s',
                               trim_scale(v_item.qty_received), trim_scale(v_qty_restored))
                   ELSE '' END
           || CASE WHEN v_restock_reversed > 0
                   THEN format('｜沖回出貨端的 %s 件已沖銷', trim_scale(v_restock_reversed))
                   ELSE '' END
           || CASE WHEN v_wave_cancelled THEN '｜補派撿貨單已取消' ELSE '' END
           || CASE WHEN v_ret_cancelled  THEN '｜短收沖帳單已作廢' ELSE '' END
           || COALESCE('｜' || NULLIF(TRIM(p_notes), ''), '');

  UPDATE transfers
     SET notes = CASE
                   WHEN v_existing_notes IS NULL OR TRIM(v_existing_notes) = '' THEN v_log
                   ELSE v_existing_notes || E'\n' || v_log
                 END,
         updated_by = p_operator
   WHERE id = v_transfer_id;

  RETURN jsonb_build_object(
    'transfer_item_id',   p_transfer_item_id,
    'transfer_id',        v_transfer_id,
    'undone_resolution',  v_res,
    'qty_received',       (SELECT qty_received FROM transfer_items WHERE id = p_transfer_item_id),
    'qty_restored',       v_qty_restored,
    'restock_reversed',   v_restock_reversed,
    'wave_cancelled',     v_wave_cancelled,
    'return_cancelled',   v_ret_cancelled
  );
END;
$fn$;

COMMENT ON FUNCTION public.rpc_undo_transfer_item_shortage(BIGINT, UUID, TEXT) IS
  '撤銷單筆短少／多收的總倉處理（20260903000200）：沖銷記回出貨端的入庫、取消 draft 重派撿貨單、'
  '作廢短收沖帳單、還原 reject_return 補上去的實收，然後清掉 shortage_* 欄位 ⇒ 該列回到收件匣。'
  '邏輯與 rpc_unreceive_transfer 的反向邏輯 H 同一套（那支是整張單、這支是單筆）。'
  '擋下：cancel_orders（客人已收到取消通知）／重派撿貨單已離開 draft／沖帳或補回實收落在已鎖定的月份。'
  '20260903000210：往 transfers.notes 追加的軌跡改成帶操作者名字（撤銷後「已處理」那一頁就查不到了，備註是唯一軌跡）。';

GRANT EXECUTE ON FUNCTION public.rpc_undo_transfer_item_shortage(BIGINT, UUID, TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpc_adjust_received_transfer(
  p_transfer_id BIGINT,
  p_lines       JSONB,
  p_operator    UUID,
  p_notes       TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_tenant_id       UUID;
  v_status          TEXT;
  v_transfer_type   TEXT;
  v_dest_location   BIGINT;
  v_shipped_at      TIMESTAMPTZ;
  v_existing_notes  TEXT;
  v_line            RECORD;
  v_label           TEXT;
  v_changes         TEXT[] := '{}'::TEXT[];
  v_items_changed   INTEGER := 0;
  v_qty_delta       NUMERIC := 0;
  v_locked          TEXT;
  v_dest_store_id   BIGINT;
  v_log             TEXT;
  v_op_name         TEXT;   -- 20260903000210：備註要寫「誰做的」
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  IF p_lines IS NULL
     OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '沒有要調整的品項';
  END IF;

  SELECT tenant_id, status, transfer_type, dest_location, shipped_at, notes
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_shipped_at, v_existing_notes
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant_id THEN
    RAISE EXCEPTION 'transfer not in current tenant';
  END IF;

  IF v_status <> 'received' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，只有「已收貨」的單可以調整實收數量', p_transfer_id, v_status;
  END IF;

  -- 守衛 A：短收沖帳記帳單本身
  IF EXISTS (SELECT 1 FROM transfer_items ti
              WHERE ti.shortage_return_transfer_id = p_transfer_id) THEN
    RAISE EXCEPTION '調撥單 % 是短收沖帳用的記帳單（月結靠它退錢給店家），不能改它的實收數量。', p_transfer_id;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_lines) AS l
      LEFT JOIN transfer_items ti
        ON ti.id = (l->>'transfer_item_id')::BIGINT
       AND ti.transfer_id = p_transfer_id
     WHERE ti.id IS NULL
  ) THEN
    RAISE EXCEPTION 'p_lines 含有不屬於調撥單 % 的品項', p_transfer_id;
  END IF;

  -- 同一個品項在 p_lines 出現兩次 → 第二次拿到的是過期的 old_qty，備註會寫錯。
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_lines) AS l
     GROUP BY (l->>'transfer_item_id')
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'p_lines 有重複的品項';
  END IF;

  FOR v_line IN
    SELECT ti.id,
           ti.qty_shipped,
           ti.qty_received                       AS old_qty,
           ti.shortage_resolution,
           (l->>'qty_received')::NUMERIC         AS new_qty,
           COALESCE(NULLIF(TRIM(ti.description), ''),
                    NULLIF(TRIM(COALESCE(s.product_name, '')
                                || COALESCE(' / ' || NULLIF(s.variant_name, ''), '')), ''),
                    '品項#' || ti.id::TEXT)      AS label
      FROM jsonb_array_elements(p_lines) AS l
      JOIN transfer_items ti
        ON ti.id = (l->>'transfer_item_id')::BIGINT
       AND ti.transfer_id = p_transfer_id
      LEFT JOIN skus s ON s.id = ti.sku_id
     ORDER BY ti.id
     FOR UPDATE OF ti
  LOOP
    IF v_line.new_qty IS NULL OR v_line.new_qty < 0 THEN
      RAISE EXCEPTION '「%」的實收「%」不是有效數量，請填 0 或正整數',
        v_line.label, COALESCE(v_line.new_qty::TEXT, 'null');
    END IF;

    CONTINUE WHEN v_line.new_qty = v_line.old_qty;

    v_label := v_line.label;

    -- 守衛 B：總倉已處理過的短少／多收
    -- ⚠️ 20260903000200 只改這段的**錯誤訊息**：撤銷不再需要「整張重來」——
    --   總倉可以到「收件匣 → 異常 → 已處理」單筆按「撤銷」
    --   （rpc_undo_transfer_item_shortage），撤完這一列就回到未處理、實收也就改得動了。
    --   ⛔ 判定條件一字未改（含 over_ack 的例外）。
    IF v_line.shortage_resolution IS NOT NULL
       AND v_line.shortage_resolution <> 'over_ack' THEN
      RAISE EXCEPTION '「%」的差異總倉已經處理過（%），不能再改實收。請總倉到「收件匣 → 異常 → 已處理」把那一筆「撤銷」，或用「↩ 返回收貨配單」整張重來。',
        v_label, v_line.shortage_resolution;
    END IF;

    -- 守衛 C：會讓月結數量變動，且該月對帳單已鎖定 → 擋
    -- 月結 hq_to_store 的量 = GREATEST(派出, 實收)（20260901000000），
    -- 所以只有「新舊兩邊的 GREATEST 不同」才真的動到金額（改小通常不會動到）。
    IF v_transfer_type = 'hq_to_store'
       AND GREATEST(v_line.qty_shipped, v_line.old_qty)
           <> GREATEST(v_line.qty_shipped, v_line.new_qty) THEN
      SELECT string_agg(DISTINCT st.name || '（' || sms.status || '）', '、')
        INTO v_locked
        FROM stores st
        JOIN store_monthly_settlements sms
          ON sms.store_id = st.id
         AND sms.settlement_month
             = DATE_TRUNC('month', COALESCE(v_shipped_at, NOW()) AT TIME ZONE 'Asia/Taipei')::DATE
       WHERE st.location_id = v_dest_location
         AND sms.status IN ('confirmed', 'settled', 'remitted');
      IF v_locked IS NOT NULL THEN
        RAISE EXCEPTION '「%」改了會動到月結金額，但該月對帳單已鎖定：%。請聯繫總倉人工處理。',
          v_label, v_locked;
      END IF;
    END IF;

    -- ⛔ 這裡刻意什麼庫存都不寫。這支是紀錄，不是進出貨。
    --    in_movement_id 也**不動** —— 它指著當初真的入過庫的那筆異動，
    --    取消收貨要靠它把貨沖回去（見 20260903000010）。
    UPDATE transfer_items
       SET qty_received = v_line.new_qty,
           -- over_ack 只是「知道了」的記號，數量改了就讓它重新回總倉收件匣
           shortage_resolution    = CASE WHEN shortage_resolution = 'over_ack'
                                         THEN NULL ELSE shortage_resolution END,
           shortage_resolution_at = CASE WHEN shortage_resolution = 'over_ack'
                                         THEN NULL ELSE shortage_resolution_at END,
           shortage_resolution_by = CASE WHEN shortage_resolution = 'over_ack'
                                         THEN NULL ELSE shortage_resolution_by END,
           updated_by     = p_operator,
           updated_at     = NOW()
     WHERE id = v_line.id;

    -- trim_scale：qty 是 numeric(18,3)，直接印會變成「10.000 → 8」，備註要給人看的
    v_changes       := v_changes || format('%s %s → %s', v_label,
                                          trim_scale(v_line.old_qty), trim_scale(v_line.new_qty));
    v_items_changed := v_items_changed + 1;
    v_qty_delta     := v_qty_delta + (v_line.new_qty - v_line.old_qty);
  END LOOP;

  IF v_items_changed = 0 THEN
    RAISE EXCEPTION '沒有任何數量被改動';
  END IF;

  -- 單頭備註：總倉收件匣的短少／多收列會把 transfers.notes 當「店家收貨備註」顯示
  -- （v_hq_exceptions 20260824020000），所以調整紀錄寫在這裡總倉看得到。
  -- 20260903000210：備註要寫得出「誰做的」。rpc_get_staff_names（20260428170000）
  -- 是既有的唯一查名機制（SECURITY DEFINER 讀 auth.users），前端「誰按的」那一欄用的也是它
  -- ⇒ 兩邊會叫同一個名字。查不到就退回 uid 前 8 碼（那支函式自己也是這個 fallback）。
  SELECT n.display_name INTO v_op_name
    FROM public.rpc_get_staff_names(ARRAY[p_operator]) n LIMIT 1;

  v_log := format('實收調整（%s・%s）：%s',
                  to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'MM/DD HH24:MI'),
                  COALESCE(NULLIF(TRIM(v_op_name), ''), left(p_operator::TEXT, 8)),
                  array_to_string(v_changes, '、'))
           || COALESCE('｜' || NULLIF(TRIM(p_notes), ''), '');

  UPDATE transfers
     SET notes = CASE
                   WHEN v_existing_notes IS NULL OR TRIM(v_existing_notes) = '' THEN v_log
                   ELSE v_existing_notes || E'\n' || v_log
                 END,
         updated_by = p_operator
   WHERE id = p_transfer_id;

  SELECT id INTO v_dest_store_id
    FROM stores
   WHERE tenant_id = v_tenant_id AND location_id = v_dest_location
   LIMIT 1;

  RETURN jsonb_build_object(
    'transfer_id',    p_transfer_id,
    'items_changed',  v_items_changed,
    'qty_delta',      v_qty_delta,
    'dest_store_id',  v_dest_store_id,
    'total_received', (SELECT COALESCE(SUM(qty_received), 0)
                         FROM transfer_items WHERE transfer_id = p_transfer_id),
    'total_shipped',  (SELECT COALESCE(SUM(qty_shipped), 0)
                         FROM transfer_items WHERE transfer_id = p_transfer_id),
    'short_lines',    (SELECT COUNT(*) FROM transfer_items
                        WHERE transfer_id = p_transfer_id
                          AND qty_received < qty_shipped
                          AND shortage_resolution IS NULL),
    'over_lines',     (SELECT COUNT(*) FROM transfer_items
                        WHERE transfer_id = p_transfer_id
                          AND qty_received > qty_shipped
                          AND shortage_resolution IS NULL)
  );
END;
$fn$;

COMMENT ON FUNCTION public.rpc_adjust_received_transfer(BIGINT, JSONB, UUID, TEXT) IS
  '已收貨調撥單的實收數量再調整（2026-09-03）：**純紀錄** —— 只改 qty_received，'
  '不寫任何庫存異動、不碰訂單／取貨／配單（跟會員端完全脫鉤）。'
  '用途是回頭跟總倉更正「這批到底來了幾件」：少收／多收沿用 v_hq_exceptions 既有流程'
  '（總倉收件匣 → 同意退回 → 20260901000010 沖帳單），月結量因 GREATEST(派出, 實收) 自動跟著走。'
  '架上數量對不上請走庫存總覽的新增庫存／盤點。連帶依賴 20260903000010。'
  '20260903000200：守衛 B 的訊息改指向「異常 → 已處理 → 撤銷」。'
  '20260903000210：「實收調整」那行備註改成帶操作者名字。';

GRANT EXECUTE ON FUNCTION public.rpc_adjust_received_transfer(BIGINT, JSONB, UUID, TEXT)
  TO authenticated, service_role;

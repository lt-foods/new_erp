-- ============================================================
-- 2026-09-03：已收貨的調撥單可以「再調整實收數量」
--
-- 老闆需求（2026-09-03，收貨待辦「已收」分頁截圖）：
--   「已收這邊要可以再調整數量，然後對應到月結單的數量，少收要跟收貨少收一樣流程。」
--
-- 在這支之前，收貨當下填錯數量只有一條路：整張「↩ 返回收貨配單」
--   （rpc_unreceive_transfer）把配單決策全部退掉再收一次 —— 對「只是某一列
--   多打／少打一件」來說代價太大，而且貨已被取走時直接被守衛擋死（那正是
--   最需要把帳改對的情況）。
--
-- 這支做什麼（rpc_adjust_received_transfer）：
--   對 status='received' 的調撥單，逐列把 qty_received 改成新的數字，
--   並把庫存差額補上／沖掉。**不動單頭狀態、不重跑配單。**
--
-- 三個問題的答案（對應老闆那句話的三段）：
--
--   1. 「可以再調整數量」
--      庫存用「先沖銷原入庫、再照新數量重新入庫」兩筆異動處理，
--      不是寫一筆差額。理由：rpc_unreceive_transfer 沖銷時是拿
--      transfer_items.in_movement_id 那一筆、整筆反向（20260901000020 那段
--      逐項沖銷），它假設「in_movement_id 的數量 == qty_received」。
--      寫差額會打破這個假設 ⇒ 之後對這張單按取消收貨會沖不乾淨 ＝ 幽靈庫存。
--
--   2. 「對應到月結單的數量」
--      月結 hq_to_store 的數量是 GREATEST(qty_shipped, qty_received)
--      （20260901000000 派車制）⇒ 改大實收，草稿重產時金額就跟著大；
--      改小則維持派出量（老闆拍板：錢在派出那一刻就算）。
--      ⚠ 因此「改到會讓月結數量變動、而那個月的對帳單已經鎖定
--        （confirmed/settled/remitted）」時直接擋下 —— 鎖定月份生成器不會重算，
--        放行只會讓帳面永遠對不回來（同 20260901000020 守衛 B-1 的理由）。
--
--   3. 「少收要跟收貨少收一樣流程」
--      不必另外做：v_hq_exceptions 的 transfer_short / transfer_over 兩段
--      （20260824020000）認的就是「t.status='received' AND qty_received <> qty_shipped
--       AND shortage_resolution IS NULL」的**當下值**。這支改完 qty_received，
--      該列自己就出現在總倉收件匣，總倉按「同意退回」→ 20260901000010 產沖帳單
--      → 月結 F 段沖掉。跟收貨當下填少走的是同一條路。
--
-- 守衛（每一條都對應一個會出事的情境）：
--   A. 這張單本身是短收沖帳記帳單（有人的 shortage_return_transfer_id 指著它）
--      → 拒絕。它沒有實體貨（in_movement_id 全 NULL），改它的實收＝憑空生貨。
--      （同 20260901000020 守衛 A 的理由，只是換一個入口。）
--   B. 該列的短少／多收總倉已經處理過（shortage_resolution 非 NULL）
--      → 拒絕，除了 'over_ack'（那只是「知道了」的記號，沒有任何庫存／金流動作，
--        數量改了就把記號清掉讓它重新回到收件匣）。
--        其餘 replenish / restock_hq / redispatch / cancel_orders / vendor_claim /
--        accept 都已經產生庫存異動、重派單、取消通知或沖帳單 ——
--        改數量會讓那些處理對不上，要退請走「↩ 返回收貨配單」（它有整套反向邏輯）。
--   C. 多段接力且後段已離開 draft → 拒絕（後段是照本段實收出貨的，同 unreceive）。
--   D. 調降時分店庫存不足以扣回 → 拒絕（貨多半已被取貨／售出：那代表貨真的收到了，
--      帳不該改小；硬扣會把 on_hand 扣成負的，取貨閘門的實體守衛
--      20260818000010 會跟著失真）。
--   E. 該列沒有入庫異動卻有實收量 → 拒絕（純記帳單或髒資料，不在這裡處理）。
--
-- 刻意不做（想清楚了才不做，不是漏掉）：
--   - **不重跑配單**（邏輯 C/E、_advance_arrived_confirmed_orders、_trim_internal_pool）。
--     這支是「把帳改對」，不是重新決定貨給誰。改大之後多出來的量，店員用
--     收貨頁的「⚖️ 配貨」自己配；取貨閘門本來就是即時看 on_hand，不需要誰去推。
--   - **不清 backorder_at**：解除待補貨是 _settle_arrived_backorders 的職責，
--     它掛在「收貨」那條路上（20260811000050 的順序約定）。
--   - **不動單頭 status / received_at**：這張單本來就已經收過了。
--   ✅ 有做的例外：調降時重跑 _settle_restock_ride_along —— RR- 內部單的品項數量
--      是申請量、必須對齊實收（20260810000000 那一課），不重跑就會把沒到的貨
--      掛在店身上。它對「received >= need」是 no-op，重跑安全。
--
-- 基底：無（新函式）。沒有改寫任何既有函式或 view。
-- Rollback：DROP FUNCTION public.rpc_adjust_received_transfer(bigint, jsonb, uuid, text);
--   （前端的「✎ 修改實收」按鈕會拿到 42883，功能等於關閉；已寫進去的調整
--     本身是正常的庫存異動與 qty_received，不需要回滾資料。）
-- ============================================================

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
  v_next_transfer   BIGINT;
  v_leg2_status     TEXT;
  v_line            RECORD;
  v_orig            stock_movements%ROWTYPE;
  v_on_hand         NUMERIC;
  v_rev_id          BIGINT;
  v_in_mov_id       BIGINT;
  v_unit_cost       NUMERIC;
  v_label           TEXT;
  v_changes         TEXT[] := '{}'::TEXT[];
  v_items_changed   INTEGER := 0;
  v_qty_delta       NUMERIC := 0;
  v_decreased       BOOLEAN := FALSE;
  v_locked          TEXT;
  v_dest_store_id   BIGINT;
  v_rr              RECORD;
  v_log             TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  IF p_lines IS NULL
     OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '沒有要調整的品項';
  END IF;

  SELECT tenant_id, status, transfer_type, dest_location, shipped_at, notes, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_shipped_at,
         v_existing_notes, v_next_transfer
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
    RAISE EXCEPTION '調撥單 % 是短收沖帳用的記帳單，沒有實體貨，不能調整實收數量。', p_transfer_id;
  END IF;

  -- 守衛 C：多段接力且後段已出貨
  IF v_next_transfer IS NOT NULL THEN
    SELECT status INTO v_leg2_status FROM transfers WHERE id = v_next_transfer FOR UPDATE;
    IF v_leg2_status IS NOT NULL AND v_leg2_status <> 'draft' THEN
      RAISE EXCEPTION '此調撥為多段接力，後段調撥 %（狀態 %）是照本段實收出貨的，請先處理後段再調整本段實收',
        v_next_transfer, v_leg2_status;
    END IF;
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

  -- 同一個品項在 p_lines 出現兩次 → 第二次會拿到過期的 old_qty，
  -- 沖銷檢查會爆在半路（前面的異動已經寫進去了）。直接擋在最前面。
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
           ti.sku_id,
           ti.qty_shipped,
           ti.qty_received                       AS old_qty,
           ti.in_movement_id,
           ti.shortage_resolution,
           ti.description,
           sm.unit_cost                          AS out_cost,
           (l->>'qty_received')::NUMERIC         AS new_qty,
           COALESCE(NULLIF(TRIM(ti.description), ''),
                    NULLIF(TRIM(COALESCE(s.product_name, '')
                                || COALESCE(' / ' || NULLIF(s.variant_name, ''), '')), ''),
                    '品項#' || ti.id::TEXT)      AS label
      FROM jsonb_array_elements(p_lines) AS l
      JOIN transfer_items ti
        ON ti.id = (l->>'transfer_item_id')::BIGINT
       AND ti.transfer_id = p_transfer_id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
      LEFT JOIN skus s            ON s.id  = ti.sku_id
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
    IF v_line.shortage_resolution IS NOT NULL
       AND v_line.shortage_resolution <> 'over_ack' THEN
      RAISE EXCEPTION '「%」的差異總倉已經處理過（%），不能再改實收。要整張重來請按「↩ 返回收貨配單」，或聯繫總倉。',
        v_label, v_line.shortage_resolution;
    END IF;

    -- 守衛 E：有實收量卻沒有入庫異動
    IF v_line.old_qty > 0 AND v_line.in_movement_id IS NULL THEN
      RAISE EXCEPTION '「%」沒有對應的入庫異動（可能是純記帳單或歷史資料），不能在這裡調整實收', v_label;
    END IF;

    -- 守衛（月結）：會讓月結數量變動，且該月對帳單已鎖定 → 擋
    -- 月結 hq_to_store 的量 = GREATEST(派出, 實收)（20260901000000），
    -- 所以只有「新舊兩邊的 GREATEST 不同」才真的動到金額。
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

    -- ===== 庫存：先沖銷原入庫，再照新數量重新入庫 =====
    IF v_line.old_qty > 0 THEN
      SELECT * INTO v_orig FROM stock_movements WHERE id = v_line.in_movement_id;

      IF v_orig.id IS NULL
         OR v_orig.movement_type <> 'transfer_in'
         OR v_orig.source_doc_type <> 'transfer'
         OR v_orig.source_doc_id <> p_transfer_id THEN
        RAISE EXCEPTION '「%」的入庫異動 % 不是本調撥的入庫，無法調整實收',
          v_label, v_line.in_movement_id;
      END IF;
      IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
        RAISE EXCEPTION '「%」的入庫異動 % 已被沖銷過，無法再調整實收', v_label, v_orig.id;
      END IF;

      -- 守衛 D：調降時庫存要夠扣（調升不必檢查）
      IF v_line.new_qty < v_line.old_qty THEN
        SELECT on_hand INTO v_on_hand
          FROM stock_balances
         WHERE tenant_id   = v_orig.tenant_id
           AND location_id = v_orig.location_id
           AND sku_id      = v_orig.sku_id
         FOR UPDATE;
        IF COALESCE(v_on_hand, 0) < (v_line.old_qty - v_line.new_qty) THEN
          RAISE EXCEPTION '「%」庫存不足以調降實收（現有 %、要扣回 %）：該批貨可能已被取貨／售出，無法改小',
            v_label, trim_scale(COALESCE(v_on_hand, 0)), trim_scale(v_line.old_qty - v_line.new_qty);
        END IF;
      END IF;

      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
      ) VALUES (
        v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
        -v_orig.quantity, v_orig.unit_cost, 'reversal',
        'transfer', p_transfer_id, v_line.id, v_orig.id,
        format('調整實收 transfer=%s item=%s：%s → %s（沖銷 movement %s）',
               p_transfer_id, v_line.id, trim_scale(v_line.old_qty),
               trim_scale(v_line.new_qty), v_orig.id),
        p_operator
      ) RETURNING id INTO v_rev_id;
    END IF;

    v_in_mov_id := NULL;
    IF v_line.new_qty > 0 THEN
      v_unit_cost := COALESCE(ABS(v_line.out_cost), 0);
      v_in_mov_id := rpc_inbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_dest_location,
        p_sku_id          => v_line.sku_id,
        p_quantity        => v_line.new_qty,
        p_unit_cost       => v_unit_cost,
        p_movement_type   => 'transfer_in',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );
    END IF;

    UPDATE transfer_items
       SET qty_received   = v_line.new_qty,
           in_movement_id = v_in_mov_id,
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
    IF v_line.new_qty < v_line.old_qty THEN
      v_decreased := TRUE;
    END IF;
  END LOOP;

  IF v_items_changed = 0 THEN
    RAISE EXCEPTION '沒有任何數量被改動';
  END IF;

  -- 單頭備註：總倉收件匣的短少／多收列會把 transfers.notes 當「店家收貨備註」顯示
  -- （v_hq_exceptions 20260824020000），所以調整紀錄寫在這裡總倉看得到。
  v_log := format('實收調整（%s）：%s',
                  to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'MM/DD HH24:MI'),
                  array_to_string(v_changes, '、'))
           || COALESCE('｜' || NULLIF(TRIM(p_notes), ''), '');

  UPDATE transfers
     SET notes = CASE
                   WHEN v_existing_notes IS NULL OR TRIM(v_existing_notes) = '' THEN v_log
                   ELSE v_existing_notes || E'\n' || v_log
                 END,
         updated_by = p_operator
   WHERE id = p_transfer_id;

  -- 調降 → RR- ride-along 內部單要對齊新的實收（20260810000000 那一課）。
  -- received >= need 時整支 no-op，重跑安全；調升不跑（復活取消的品項是
  -- _unsettle_restock_ride_along 的職責，不在這支的範圍）。
  IF v_decreased AND v_transfer_type = 'hq_to_store' THEN
    FOR v_rr IN
      SELECT DISTINCT rr.id
        FROM restock_requests rr
       WHERE rr.status = 'received'
         AND (rr.linked_transfer_id = p_transfer_id
              OR EXISTS (
                   SELECT 1
                     FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
                    WHERE pwi.generated_transfer_id = p_transfer_id
                      AND pwi.store_id = rr.requesting_store_id
                      AND pwi.sku_id IN (SELECT sku_id FROM restock_request_lines
                                          WHERE request_id = rr.id AND cancelled_at IS NULL)))
    LOOP
      PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
    END LOOP;
  END IF;

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
  '已收貨調撥單的實收數量再調整（2026-09-03）：逐列改 qty_received，庫存以'
  '「沖銷原入庫＋照新量重新入庫」處理，單頭狀態與配單決策一律不動。'
  '少收／多收沿用 v_hq_exceptions 既有流程（總倉收件匣 → 同意退回 → 20260901000010 沖帳單）；'
  '月結數量因 GREATEST(派出, 實收) 而自動跟著走，鎖定月份會被守衛擋下。';

GRANT EXECUTE ON FUNCTION public.rpc_adjust_received_transfer(BIGINT, JSONB, UUID, TEXT)
  TO authenticated, service_role;

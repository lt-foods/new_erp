-- ============================================================
-- 2026-09-03：已收貨的調撥單可以「再調整實收數量」——**純紀錄**，不動庫存
--
-- ⚠️ 檔名說明：本檔原本叫 20260903000000_adjust_received_transfer.sql，PR #900 合併後
--   發現跟同一天的 20260903000000_undo_pickup_keeps_container_ready.sql（PR #901）
--   **撞號**（CLAUDE.md「開新 migration 前先看有沒有撞號」那條）。兩支都已套上正式庫、
--   而本 repo 一律走 Management API 直接跑 SQL、不寫 supabase_migrations 追蹤表
--   ⇒ 改名安全。本檔改成 000005（仍排在 000000 之後、000010 之前），
--   引用它的地方（20260903000010 檔頭、TransferReceiveModal.tsx）已一併改。
--   ⛔ 20260903000100 檔頭寫的「20260903000000 那件事」指的是**另一支**（取貨閘門那支），
--     不是本檔 —— 改名後那句話反而更精確，不用動它。
--
-- 老闆需求（2026-09-03，收貨待辦「已收」分頁）：
--   ①「已收這邊要可以再調整數量，然後對應到月結單的數量，少收要跟收貨少收一樣流程。」
--   ②（看到第一版擋下來的錯誤訊息後）「這些調整都會有錯誤訊息，
--      調整只是對總倉的紀錄，月結跟提醒總倉多來貨或少來貨。」
--   ③「跟會員端都要脫鉤。」
--
-- 所以這支的定位是：**回頭跟總倉更正「這批到底來了幾件」的一筆紀錄**。
--   它只改 transfer_items.qty_received，其他什麼都不碰：
--     ⛔ 不寫任何 stock_movements（不加庫存、不扣庫存、不會把 on_hand 扣成負的）
--     ⛔ 不碰 customer_orders / customer_order_items / 取貨閘門 / 到貨通知
--     ⛔ 不重跑配單、不清 backorder_at、不動單頭 status / received_at
--     ⛔ 不碰 RR- 內部單（ride-along）
--   ⇒ 會員端（客人看到的到貨、取貨頁能不能領）完全不受影響 —— 這是老闆 ③ 的要求。
--
-- 改完之後貨真的對不上架上的數量時，正解是**庫存總覽的新增庫存／盤點**
--   （CLAUDE.md 既有規矩：帳面與實物不合走盤點，不要靠別的單據硬繞）。
--
-- 那三件事各自怎麼成立：
--   1.「調整數量」＝ UPDATE qty_received。就這樣。
--   2.「對應到月結單的數量」：月結 hq_to_store 的量是
--      GREATEST(qty_shipped, qty_received)（20260901000000 派車制）
--      ⇒ 改大，草稿重產時金額跟著大；改小維持派出量（錢在派出那一刻就算），
--        那一段要總倉按「同意退回」才沖掉（20260901000010）。
--      ⚠️ 因此只有「會讓 GREATEST 變動」而且「那個月的對帳單已鎖定」時才擋
--        （鎖定月份生成器不會重算，放行＝帳面永遠對不回來，同 20260901000020 守衛 B-1）。
--   3.「少收要跟收貨少收一樣流程」：不必另外做。v_hq_exceptions 的
--      transfer_short / transfer_over 兩段（20260824020000）認的就是
--      「t.status='received' AND qty_received <> qty_shipped AND shortage_resolution IS NULL」
--      的**當下值** ⇒ 改完那一列自己出現在總倉收件匣，總倉按「同意退回」
--      → 20260901000010 產沖帳單 → 月結 F 段沖掉。跟收貨當下填少同一條路。
--
-- ⚠️ 連帶必要的一支：**20260903000010** 把 rpc_unreceive_transfer 的逐項沖銷條件
--   從「qty_received > 0 AND in_movement_id IS NOT NULL」改成只看 in_movement_id。
--   因為這支不動庫存，會出現「qty_received = 0 但 in_movement_id 還指著真的入過庫
--   的那筆異動」，舊條件會跳過它 ⇒ 取消收貨後貨還在店裡、單子卻回到 shipped，
--   再收一次就再入庫一遍＝憑空生貨。**兩支要一起貼。**
--
-- 只保留三道守衛（第一版那些「庫存不夠扣」「多段接力後段已出貨」「沒有入庫異動」
-- 全部拿掉 —— 純紀錄沒有那些顧慮，而且它們就是老闆 ② 抱怨的錯誤訊息）：
--   A. 這張單本身是短收沖帳記帳單（有人的 shortage_return_transfer_id 指著它）→ 拒絕。
--      它的 qty_received 是月結 F 段的沖帳金額來源，改它＝改一筆已經發生的退款。
--   B. 該列的短少／多收總倉已經處理過（shortage_resolution 非 NULL）→ 拒絕。
--      那些處理已經產生庫存異動／重派單／取消通知／沖帳單，改數量會讓它們對不上。
--      例外 'over_ack'（只是「知道了」的記號，沒有任何庫存或金流動作）：
--      數量改了就把記號清掉，讓它重新回到收件匣。
--   C. 會讓月結數量變動、而那個月的對帳單已鎖定（confirmed/settled/remitted）→ 拒絕。
--
-- 基底：無（新函式）。沒有改寫任何既有函式或 view。
-- Rollback：DROP FUNCTION public.rpc_adjust_received_transfer(bigint, jsonb, uuid, text);
--   （前端的「✎ 修改實收」會拿到 42883 ＝ 功能關閉。已寫下的 qty_received 是
--     正常欄位值，不需要回滾資料；要還原個別單子就再調一次回原本的數字。）
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
  v_line            RECORD;
  v_label           TEXT;
  v_changes         TEXT[] := '{}'::TEXT[];
  v_items_changed   INTEGER := 0;
  v_qty_delta       NUMERIC := 0;
  v_locked          TEXT;
  v_dest_store_id   BIGINT;
  v_log             TEXT;
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
    IF v_line.shortage_resolution IS NOT NULL
       AND v_line.shortage_resolution <> 'over_ack' THEN
      RAISE EXCEPTION '「%」的差異總倉已經處理過（%），不能再改實收。請聯繫總倉，或用「↩ 返回收貨配單」整張重來。',
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
  '架上數量對不上請走庫存總覽的新增庫存／盤點。連帶依賴 20260903000010。';

GRANT EXECUTE ON FUNCTION public.rpc_adjust_received_transfer(BIGINT, JSONB, UUID, TEXT)
  TO authenticated, service_role;

-- ============================================================
-- 2026-09-03：總倉短收處理補上第三顆「不同意退貨（要跟店家收錢）」
--
-- 老闆 2026-09-03：「還是把總倉拒絕的功能做上」。
-- 在這之前 TransferShortageResolveModal 只有兩顆「同意退回」，第三種答案是一行
-- 「🚧 還在施工，這種先不要按、這筆會留在清單」的說明 —— 於是總倉遇到
-- 「這批我們確定有出、店家自己搞丟」的單子沒有出口，只能讓它一直躺在異常清單。
--
-- 為什麼實作起來「什麼都不用做」：
--   2026-09-01 起月結是**派車制**（20260901000000）：hq_to_store 的量是
--   GREATEST(qty_shipped, qty_received)，店↔店的 air_in/air_out 自 20260825030000
--   起兩邊都吃 qty_shipped ⇒ **短收本來就照派出量跟店家收錢**。
--   「同意退回」之所以會少收錢，是因為 20260901000010 額外產了一張純記帳的
--   return_to_hq 沖帳單把它沖掉。
--   ⇒ 「不同意退貨」＝ 不產沖帳單、不記回庫存，只打上處理標記讓它離開收件匣。
--
-- 所以本檔只做兩件事（其餘全文逐字保留）：
--   1. transfer_items 的 CHECK 加一個允許值 'reject_return'。
--   2. rpc_resolve_transfer_item_shortage：允許值清單加 'reject_return'，
--      並把它併進「restock_hq / redispatch 共同前置」那個 IF —— 只為了沿用
--      三道既有檢查（真的有短收、調撥單鎖住、狀態是 received/closed）。
--      restock_hq 記回庫存那段、redispatch 開撿貨單那段、20260901000010 的沖帳單那段
--      判定條件都是 `IN ('restock_hq','redispatch')`，reject_return 一段都進不去。
--
-- 連帶（沒有動到、確認過就是這樣）：
--   - v_hq_exceptions 的 transfer_short 分支要求 shortage_resolution IS NULL
--     （或 replenish 且還沒補到）⇒ 打上 reject_return 之後那一列自己從清單消失，
--     view 一個字都不用改（20260824020000:1487-1513）。
--   - 「異常 → 已處理」分頁是 PostgREST 直查 shortage_resolution IS NOT NULL
--     ⇒ 也自動看得到，只在前端補一個顯示字樣。
--
-- 基底：線上 pg_get_functiondef() 現況（2026-09-03 取出）＝
--   20260901000010_shortage_return_booking.sql 的 v4（該檔為現行最新版；
--   標準查法確認共 4 版：20260607000040 / 20260810000010 / 20260811020000 / 20260901000010）。
--   本檔以該全文逐字複製、只動上述兩處。
-- Rollback：CHECK 拿掉 'reject_return'（要先確認沒有資料用了這個值），
--   函式把兩處改回 20260901000010 的寫法。
-- ============================================================

ALTER TABLE transfer_items
  DROP CONSTRAINT IF EXISTS transfer_items_shortage_resolution_check;

ALTER TABLE transfer_items
  ADD CONSTRAINT transfer_items_shortage_resolution_check
  CHECK (shortage_resolution IS NULL OR shortage_resolution = ANY (ARRAY[
    'replenish'::text, 'cancel_orders'::text, 'vendor_claim'::text, 'accept'::text,
    'restock_hq'::text, 'redispatch'::text, 'over_ack'::text,
    'reject_return'::text   -- 20260903000020：不同意退貨（照派出量跟店家收錢）
  ]));

COMMENT ON COLUMN transfer_items.shortage_resolution IS
  '短收／多收的處理方式：restock_hq=同意退回-不補貨／redispatch=同意退回-補貨／'
  'reject_return=不同意退貨（照派出量跟店家收錢，不沖帳不記回庫存）／'
  'over_ack=多收知道了／replenish・cancel_orders・vendor_claim・accept=已不給按的舊值。';

CREATE OR REPLACE FUNCTION public.rpc_resolve_transfer_item_shortage(p_transfer_item_id bigint, p_resolution text, p_notes text, p_operator uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- 2026-09-01 切片 1.5：沖帳用的純記帳退貨單
  v_ret_no          TEXT;
  v_ret_transfer_id BIGINT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot resolve shortage', v_role;
  END IF;
  -- 20260903000020：加 'reject_return'（不同意退貨＝要跟店家收錢）。老闆 2026-09-03。
  IF p_resolution NOT IN ('replenish','cancel_orders','vendor_claim','accept','restock_hq','redispatch','reject_return') THEN
    RAISE EXCEPTION 'invalid resolution: %', p_resolution;
  END IF;

  SELECT * INTO v_item FROM transfer_items
   WHERE id = p_transfer_item_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_item % not found', p_transfer_item_id;
  END IF;

  -- restock_hq / redispatch / reject_return 共同前置：算短收量、鎖調撥單、驗狀態
  -- 20260903000020：reject_return 併進來只為了拿這三道檢查（真的有短收、狀態是已收貨）。
  -- 它自己**不做任何動作** —— 下面的 restock_hq / redispatch / 沖帳單三段都用
  -- `p_resolution IN ('restock_hq','redispatch')` 判定，reject_return 一段都進不去，
  -- 最後只落在末尾那個無條件的 UPDATE（打上處理標記 ⇒ 從收件匣消失）。
  -- 這正是「不同意退貨」的正確語意：什麼都不用做，錢本來就照派出量收
  -- （20260901000000 派車制：GREATEST(派出, 實收)；店↔店的 air_in/air_out
  --  自 20260825030000 起兩邊都吃 qty_shipped）⇒ 不沖帳＝照收。
  IF p_resolution IN ('restock_hq','redispatch','reject_return') THEN
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

  -- ============================================================
  -- 2026-09-01 切片 1.5：同意退回 → 產一張純記帳的 return_to_hq 讓月結 F 段沖帳
  --
  -- ⛔⛔ 這一段**只 INSERT 兩張表，絕對不可以呼叫 rpc_inbound / rpc_outbound**。
  --    貨已經在上面用 transfer_cancel 記回出貨端了（:152-162 / :194-204），
  --    這裡再動一次庫存 ＝ 同一批貨入庫兩次。
  --    （安全性依據：唯一改庫存餘額的 trigger trg_apply_movement 掛在
  --      AFTER INSERT ON stock_movements，transfers/transfer_items 上沒有。）
  --
  -- 四道條件缺一不可：
  --   1. 只有兩顆「同意退回」會沖帳（不同意/認賠那些只打標記，本來就該照收）
  --   2. 只做 hq_to_store —— 店↔店的錢走 air_in/air_out，用退貨去沖會做出新的錯帳
  --      （restock_hq 沒有總倉守衛，店↔店的單真的按得下去，所以這條一定要擋）
  --   3. 沒沖過才沖（先按 restock_hq 再按 redispatch 會走到這裡第二次）
  --   4. 真的有短收
  -- ============================================================
  IF p_resolution IN ('restock_hq','redispatch')
     AND v_transfer.transfer_type = 'hq_to_store'
     AND v_item.shortage_return_transfer_id IS NULL
     AND COALESCE(v_shortage, 0) > 0
  THEN
    v_ret_no := public._next_transfer_no();

    -- 建單欄位寫法沿用 20260801000000_full_return_closes_order.sql:161-171，
    -- 但狀態直接寫 'received'＋received_at：F 段只吃 received/closed，
    -- 且用 received_at 分月份 ⇒ 沖帳落在「按鈕當下」那個月。
    -- ⛔ 不掛 customer_order_id：這不是客人退貨，掛了會被訂單收尾邏輯誤判。
    INSERT INTO transfers (
      tenant_id, transfer_no, source_location, dest_location,
      status, transfer_type,
      requested_by, shipped_by, shipped_at, received_by, received_at,
      notes, created_by, updated_by
    ) VALUES (
      v_transfer.tenant_id, v_ret_no,
      v_transfer.dest_location,     -- 從「收貨的那家店」退回
      v_transfer.source_location,   -- 回到「原本出貨的那一端」
      'received', 'return_to_hq',
      p_operator, p_operator, NOW(), p_operator, NOW(),
      '[短收沖帳] 原調撥 ' || v_transfer.transfer_no
        || '（品項 #' || v_item.id || '，短收 ' || trim_scale(v_shortage) || '）'
        || ' — 純記帳單，庫存已由 transfer_cancel 異動處理，本單不動庫存',
      p_operator, p_operator
    ) RETURNING id INTO v_ret_transfer_id;

    -- out_movement_id **指向原單那一筆出庫異動**：F 段的
    -- LEFT JOIN stock_movements 會取到與原本收錢時完全同一個 unit_cost。
    -- ⛔ 不要為了「乾淨」把它留白 —— 留白會讓成本口徑沖成 0，只沖掉分店價那一半。
    -- ⚠️ in_movement_id 刻意留 NULL（本單沒有真的入庫）。
    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped, qty_received,
      out_movement_id, notes, created_by, updated_by
    ) VALUES (
      v_ret_transfer_id, v_item.sku_id, v_shortage, v_shortage, v_shortage,
      v_item.out_movement_id,
      '短收沖帳：成本沿用原出庫異動 '
        || COALESCE(v_item.out_movement_id::TEXT, '(原單無出庫異動，成本以 0 計)'),
      p_operator, p_operator
    );
  END IF;

  UPDATE transfer_items
     SET shortage_resolution          = p_resolution,
         shortage_resolution_at       = NOW(),
         shortage_resolution_by       = p_operator,
         shortage_resolution_notes    = NULLIF(TRIM(p_notes), ''),
         shortage_restock_movement_id = COALESCE(v_mov_id, shortage_restock_movement_id),
         shortage_redispatch_wave_id  = COALESCE(v_wave_id, shortage_redispatch_wave_id),
         shortage_return_transfer_id  = COALESCE(v_ret_transfer_id, shortage_return_transfer_id),
         updated_by                   = p_operator
   WHERE id = p_transfer_item_id;
END;
$function$;

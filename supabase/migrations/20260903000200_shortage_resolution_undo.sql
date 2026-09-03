-- ============================================================
-- 2026-09-03：總倉短收／多收的「已處理」紀錄可以撤銷，而且「不同意退貨」要把實收補回派出量
--
-- 老闆 2026-09-03（看著「異常 → 已處理」那一頁的兩筆 reject_return）：
--   「要可以撤銷，然後不同意退貨原本收貨的要加回來」「這兩筆要可以撤銷」
--
-- ------------------------------------------------------------
-- 一、為什麼「不同意退貨」要把實收改回派出量
-- ------------------------------------------------------------
-- 20260903000020 把 reject_return 實作成「什麼都不做，只打處理標記」，理由是
-- 派車制（20260901000000）本來就照 GREATEST(派出, 實收) 收錢 ⇒ 不沖帳＝照收。
-- 錢是對的，但**紀錄留在自相矛盾的狀態**：那一列永遠寫著「派出 4 / 實收 1 / 少收 3」，
-- 而總倉已經裁定「這 3 件算你收到了、照 4 件收錢」。實際踩到的兩件事：
--   1. 松山那筆（WAVE-2458-S2，本檔 ⑤ 會回填）的少收根本是**紀錄問題不是實體問題**：
--      入庫異動 #136851 真的入了 4 件，是後來用 rpc_adjust_received_transfer
--      （純紀錄）把實收一路改成 4→2→4→1 才生出「少收 3」。
--      貨在架上、帳上寫少收 ⇒ 取貨閘門的記帳側守衛（_pickup_group_supplied
--      吃 hq_to_store 的 qty_received）反而擋住那 3 件。
--   2. 打了標記之後 rpc_adjust_received_transfer 守衛 B 就鎖住那一列，
--      再也改不動 —— 錯的數字就永久留在那裡。
-- ⇒ 「不同意退貨」＝ 總倉不承認這筆短收 ⇒ 實收補回派出量，帳面才跟收錢口徑一致，
--   而那一列也自然不再是短收（v_hq_exceptions 的 transfer_short 要
--   qty_received < qty_shipped）。
--
-- ⛔⛔ 這個補回是**純紀錄**，一筆 stock_movements 都不寫 —— 跟 20260903000005 同一個
--   定位（老闆原話：「調整只是對總倉的紀錄」「跟會員端都要脫鉤」）。
--   真的架上少一件（中和那筆 WAVE-2464-S45 是真短收，入庫只入了 5）時，
--   正解仍是庫存總覽的新增庫存／盤點，不是靠這支生貨。
--   放行的安全性靠取貨閘門**第二道**守衛（實體庫存 on_hand − 已承諾未取，
--   20260818000010）—— 兩道是 AND，記帳側放寬了實體側照樣擋
--   （CLAUDE.md「取貨閘門有兩道數量守衛」那條）。
--
-- 錢會不會動：
--   hq_to_store  金額 = GREATEST(派出, 實收)，而 reject_return 的前置檢查已經保證
--                實收 < 派出 ⇒ 補到派出量 GREATEST 不變 ⇒ **不動錢**。
--   店↔店空中轉／互助腿  air_in/air_out 吃 v_store_aid_transfer_legs 的 qty_shipped
--                （20260825030000）⇒ **不動錢**。
--   自由轉貨 / return_to_hq  free_in/free_out/return_out 三段的母體都有
--                `ti.qty_received > 0`，return_out 的金額還直接乘 qty_received
--                ⇒ 實收 0 補成正數會讓它開始入帳 ⇒ **會動錢** ⇒ 才需要問月份鎖沒鎖。
--
-- ------------------------------------------------------------
-- 二、撤銷（rpc_undo_transfer_item_shortage，本檔新增）
-- ------------------------------------------------------------
-- 不是新發明的邏輯：rpc_unreceive_transfer 的「反向邏輯 H」（20260824030000 引入、
-- 20260901000020 補上沖帳單那段）早就會在整張單取消收貨時逐項撤回總倉的處理。
-- 本檔把那一段抽成**單筆**入口，讓「異常 → 已處理」那一頁按得到，
-- 不必為了撤一筆而把整張單退回 shipped（那會連帶動庫存、訂單、RR- 單）。
--
-- 逐項要撤的東西（順序照邏輯 H）：
--   a) restock_hq / redispatch 沖回出貨端的那筆 transfer_cancel 入庫 → 寫 reversal 沖銷
--      （含 on_hand 不足就擋的實體守衛：貨可能已經被派出去了）
--   b) redispatch 開的 draft 重派撿貨單 → 取消 + 寫 picking_wave_audit_log
--   c) 20260901000010 產的 return_to_hq 純記帳沖帳單 → status='cancelled'（不碰庫存，
--      F 段白名單只吃 received/closed ⇒ 一改就不再沖帳）
--   d) reject_return 補上去的實收 → 用 shortage_prev_qty_received 還原
--   e) 清掉 shortage_* 六個欄位 ⇒ 那一列回到「未處理」，自己重新出現在收件匣
--
-- 三道擋下來的情況（前兩道逐字沿用邏輯 H 的守衛，理由相同）：
--   A. cancel_orders（舊值）：客人已經收到取消通知，不可自動復原。
--   B. 重派撿貨單已離開 draft：貨已經在重撿／重派路上，撤了兩頭錯帳
--      → 請先到「📋 撿貨單」把它取消（rpc_cancel_picking_wave 只擋 shipped/cancelled）。
--   C. 沖帳單所在月份的對帳單已鎖定（confirmed/settled/remitted）：生成器不會重算
--      鎖定月份，硬撤＝鎖定的對帳單上留一筆沒有憑證的退款（同 20260901000020 守衛 B-1）。
--   D'（reject_return 專屬）：補回實收會動到錢、而那個月已鎖定 → 擋（口徑同上面「一、」）。
--
-- ⚠️ 撤銷會把處理紀錄從「已處理」那一頁**刪掉**（那一頁讀的是 transfer_items 現值），
--   所以一律往 transfers.notes 追加一行「撤銷處理（MM/DD HH:MI）：…」——
--   總倉收件匣的短少列會把 transfers.notes 當「店家收貨備註」顯示（v_hq_exceptions），
--   撤銷的軌跡才不會消失。⛔ 不要把這行拿掉。
--
-- ------------------------------------------------------------
-- 基底版本（都用標準查法確認過，且已對線上 pg_get_functiondef() 逐字 diff 過）
-- ------------------------------------------------------------
--   rpc_resolve_transfer_item_shortage ← 20260903000020（第 5 版；共 5 版：
--     20260607000040 / 20260810000010 / 20260811020000 / 20260901000010 / 20260903000020）
--     本檔為第 6 版：只動 reject_return 那一段 + 末尾 UPDATE 兩個欄位，其餘逐字保留。
--   rpc_adjust_received_transfer ← 20260903000005（唯一版）。本檔只改守衛 B 的**錯誤訊息**
--     （指向新的「撤銷」鈕），程式行為一字不變。
--   rpc_undo_transfer_item_shortage ← 新函式（無基底）。
--   ⛔ 沒有動 rpc_unreceive_transfer：它的邏輯 H 已經會清掉 shortage_* 欄位，
--     而它同時把 qty_received 歸零 ⇒ 不需要為了新欄位重抄那 700 行。
--     shortage_prev_qty_received 殘留也不會出事：resolve 每次寫入都覆蓋
--     （非 reject_return 一律寫 NULL），前端也只在 reject_return 的列上讀它。
--
-- Rollback：
--   DROP FUNCTION public.rpc_undo_transfer_item_shortage(bigint, uuid, text);
--   rpc_resolve_transfer_item_shortage / rpc_adjust_received_transfer 改回
--     20260903000020 / 20260903000005 的版本；
--   ALTER TABLE transfer_items DROP COLUMN shortage_prev_qty_received;
--   已被補回的 qty_received 要還原就逐筆改回 shortage_prev_qty_received 的值
--   （先撈出來留底再 DROP COLUMN）。
-- ============================================================

-- ============================================================
-- ① 記住 reject_return 補回實收之前的數字
-- ============================================================
ALTER TABLE transfer_items
  ADD COLUMN IF NOT EXISTS shortage_prev_qty_received NUMERIC(18,3);

COMMENT ON COLUMN transfer_items.shortage_prev_qty_received IS
  '「不同意退貨（reject_return）」把 qty_received 補回 qty_shipped 之前的實收量'
  '（20260903000200）。兩個用途：撤銷時還原、「異常 → 已處理」那一頁算「少幾件」。'
  '只有 shortage_resolution = ''reject_return'' 的列上才有意義 —— '
  'rpc_resolve_transfer_item_shortage 對其他 resolution 一律寫 NULL。';

-- ============================================================
-- ② rpc_resolve_transfer_item_shortage v6
--    reject_return 改成「補回實收」（純紀錄），其餘逐字保留 20260903000020。
-- ============================================================
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
  -- 20260903000200：reject_return 補回實收用
  v_prev_qty        NUMERIC;
  v_locked          TEXT;
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
  -- 20260903000200 起它多做一件事：把 qty_received 補回 qty_shipped（見下面那段）。
  -- restock_hq 記回庫存那段、redispatch 開撿貨單那段、20260901000010 的沖帳單那段
  -- 判定條件都是 `IN ('restock_hq','redispatch')`，reject_return 一段都進不去。
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

  -- ============================================================
  -- 20260903000200：reject_return（不同意退貨）＝ 總倉不承認這筆短收
  --   ⇒ 把實收補回派出量。**純紀錄**，一筆 stock_movements 都不寫
  --   （同 20260903000005 的定位；架上真的少貨請走庫存總覽的新增庫存／盤點）。
  --   舊值存進 shortage_prev_qty_received：撤銷要還原，「已處理」那一頁也要用它
  --   才算得出「少幾件」（補回之後 qty_shipped - qty_received 會是 0）。
  --
  -- 月結守衛：這個補回會不會動到錢？
  --   hq_to_store：金額 = GREATEST(派出, 實收)（20260901000000 派車制），
  --     而上面已經保證實收 < 派出 ⇒ 補到派出量 GREATEST 不變 ⇒ 不會動。
  --   店↔店的空中轉／互助腿（有掛訂單或有 next_transfer_id）：air_in/air_out 吃
  --     v_store_aid_transfer_legs 的 qty_shipped（20260825030000）⇒ 不會動。
  --   其餘（自由轉貨 store_to_store、return_to_hq）：free_in / free_out / return_out
  --     三段的母體都有 `ti.qty_received > 0`，return_out 金額還直接乘 qty_received
  --     ⇒ 實收 0 補成正數會讓它開始入帳 ⇒ 會動到錢 ⇒ 要問月份鎖沒鎖
  --     （理由同 20260903000005 守衛 C：鎖定月份生成器不會重算，
  --       放行＝帳面永遠對不回來）。
  -- ============================================================
  IF p_resolution = 'reject_return' THEN
    v_prev_qty := COALESCE(v_item.qty_received, 0);

    IF NOT (
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
        RAISE EXCEPTION '把實收補回派出量會動到這張單的月結金額，但該月對帳單已鎖定：%。請聯繫總倉人工處理。',
          v_locked;
      END IF;
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
  --    貨已經在上面用 transfer_cancel 記回出貨端了，
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
         -- 20260903000200：不同意退貨 ⇒ 實收補回派出量（純紀錄），舊值留著給撤銷／畫面用。
         -- ⛔ 其他 resolution 一律把 prev 寫回 NULL：這一欄只在 reject_return 的列上有意義，
         --   留著上一輪的殘值會讓「已處理」那一頁的「少幾件」算錯。
         qty_received                 = CASE WHEN p_resolution = 'reject_return'
                                            THEN qty_shipped ELSE qty_received END,
         shortage_prev_qty_received   = CASE WHEN p_resolution = 'reject_return'
                                            THEN v_prev_qty ELSE NULL END,
         updated_by                   = p_operator
   WHERE id = p_transfer_item_id;
END;
$function$;

COMMENT ON FUNCTION public.rpc_resolve_transfer_item_shortage(bigint, text, text, uuid) IS
  '總倉處理收貨短少（v6，20260903000200）：restock_hq／redispatch＝同意退回'
  '（記回出貨端庫存、redispatch 另開重派撿貨單、hq_to_store 另產 return_to_hq 沖帳單）；'
  'reject_return＝不同意退貨，把 qty_received 補回 qty_shipped（**純紀錄，不寫庫存**）'
  '並把舊值存進 shortage_prev_qty_received。要撤銷走 rpc_undo_transfer_item_shortage。';

-- ============================================================
-- ③ rpc_undo_transfer_item_shortage（新）—— 單筆撤銷
--    邏輯逐段對齊 rpc_unreceive_transfer 的「反向邏輯 H」（20260901000020:485-586）。
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
  v_log := format('撤銷處理（%s）：%s ← %s',
                  to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'MM/DD HH24:MI'),
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
  '擋下：cancel_orders（客人已收到取消通知）／重派撿貨單已離開 draft／沖帳或補回實收落在已鎖定的月份。';

GRANT EXECUTE ON FUNCTION public.rpc_undo_transfer_item_shortage(BIGINT, UUID, TEXT)
  TO authenticated, service_role;

-- ============================================================
-- ④ rpc_adjust_received_transfer：守衛 B 的錯誤訊息改指向新的「撤銷」鈕
--    （程式行為一字不變；全文逐字複製 20260903000005，只動那一句 RAISE。）
--    為什麼要改：那道守衛就是使用者最常撞到的一道 —— 按了處理標記之後實收就鎖住了，
--    而舊訊息只給「整張重來」這條路（會連帶動庫存／訂單／RR- 單），
--    現在有單筆撤銷了，訊息要把人帶到對的地方。
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
  '架上數量對不上請走庫存總覽的新增庫存／盤點。連帶依賴 20260903000010。'
  '20260903000200：守衛 B 的訊息改指向「異常 → 已處理 → 撤銷」。';

GRANT EXECUTE ON FUNCTION public.rpc_adjust_received_transfer(BIGINT, JSONB, UUID, TEXT)
  TO authenticated, service_role;

-- ============================================================
-- ⑤ 回填既有的 reject_return 列 —— 老闆指名的那兩筆就是這裡處理掉的
--
-- 2026-09-03 對正式庫查證：全站 reject_return 共 2 列，兩列都是 hq_to_store：
--   #29225 WAVE-2458-S2 松山店 G02093-01（派 4 / 收 1；入庫異動 #136851 實際入了 4 件，
--          少收 3 是後來用 rpc_adjust_received_transfer 純紀錄改成 4→2→4→1 改出來的）
--   #29509 WAVE-2464-S45 中和店 G02180-07（派 6 / 收 5；入庫異動 #134313 只入 5，真短收 1）
-- 兩列補回實收都不動錢（hq_to_store 的金額是 GREATEST(派出, 實收)，實收 < 派出
-- ⇒ 補到派出量 GREATEST 不變）⇒ 不需要問月份鎖沒鎖。
--
-- ⛔ 條件裡的 hq_to_store 不是裝飾：非 hq_to_store 的 reject_return 補回實收**會**動到
--   free_in / free_out / return_out（那三段的母體有 `ti.qty_received > 0`），
--   而這支 UPDATE 沒有月份鎖定守衛。線上目前 0 列，真的出現的話請用畫面上的
--   「撤銷」再重按一次（那條路才有守衛 D）。
-- ============================================================
UPDATE transfer_items ti
   SET shortage_prev_qty_received = ti.qty_received,
       qty_received               = ti.qty_shipped,
       updated_at                 = NOW()
 WHERE ti.shortage_resolution = 'reject_return'
   AND ti.shortage_prev_qty_received IS NULL
   AND ti.qty_received < ti.qty_shipped
   AND EXISTS (SELECT 1 FROM transfers t
                WHERE t.id = ti.transfer_id AND t.transfer_type = 'hq_to_store');

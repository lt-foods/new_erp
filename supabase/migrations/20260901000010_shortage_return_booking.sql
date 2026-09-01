-- ============================================================
-- 2026-09-01（切片 1.5）：短收「同意退回」→ 自動產一張純記帳的退貨單沖帳
--
-- ⛔⛔ 這支跟 20260901000000_settlement_dispatch_basis.sql **必須同一天一起貼**。
--     只貼 20260901000000 不貼這支 ＝ 短收的貨照派出量跟店家收錢，
--     跟老闆 2026-08-31 拍板 1「同意退回就自動沖帳」正好相反。
--
-- 老闆拍板 1：「短收：總倉在異常按『同意退回』→ 該筆自動沖帳（派 10 收 8 → 淨收 8）」。
--
-- 壞在哪：總倉那兩顆「同意退回」鈕（畫面字樣見
--   apps/admin/src/components/TransferShortageResolveModal.tsx:105/:122/:155）
--   按下去只寫**一筆庫存異動**（20260811020000:152-162 restock_hq、
--   :194-204 redispatch，都是 movement_type='transfer_cancel'），
--   **從來沒有建立任何 return_to_hq 調撥單**。
--   而月結的退貨沖帳（F 段）是靠 transfer_type='return_to_hq' 認的
--   ⇒ 接不到，一毛都沖不掉。
--   舊制（按實收量算錢）下這個缺口看不出來，因為短收的本來就沒被收錢；
--   改成派車制之後它就變成「店家被多收」。
--
-- 改法（CEO 2026-09-01 在老闆拍板 1 範圍內選定的甲案）：
--   兩顆鈕在原有動作之後，**額外**產生一張 transfer_type='return_to_hq'、
--   status='received' 的調撥單，讓月結 F 段現成接住。
--   ⇒ 月結引擎一行都不用再動。
--
-- ⛔⛔ 這張單是「**純記帳單**」——它不可以動任何庫存：
--   貨已經由既有的 transfer_cancel 異動記回出貨端了（上面那兩處），
--   再動一次庫存 ＝ 同一批貨入庫兩次。
--   ✅ 已查證安全：全庫唯一會改庫存餘額的 trigger 是 trg_apply_movement，
--      它掛在 **AFTER INSERT ON stock_movements**
--      （20260422120003_inventory_schema.sql:254-256）；
--      transfers / transfer_items 上只有 trg_touch_*（BEFORE UPDATE 改 updated_at，
--      同檔 :282／:284）。
--   ⇒ 只 INSERT transfers + transfer_items、**不呼叫 rpc_inbound/rpc_outbound**，
--     庫存就一定不會動。
--   ⛔ 所以本檔**刻意沒有**照抄範本 20260801000000_full_return_closes_order.sql
--     裡的 rpc_outbound 那一段（該檔 :248-257）——那段是給「真的有貨在搬」的
--     客人退貨用的。範本只借它的**建單欄位寫法**（:161-171 建 transfers、
--     :259-266 建 transfer_items）。
--
-- 金額怎麼對上原本被收的錢：
--   數量  = 本次同意退回的短收量（qty_shipped − qty_received），
--           三個數量欄位都填它，qty_variance 生成欄自然是 0。
--   成本  = transfer_items.out_movement_id **指向原單那一筆出庫異動**
--           ⇒ F 段的 LEFT JOIN stock_movements 取到的 unit_cost
--             與原本被收錢時**完全同一個值**（精準鏡像）。
--   月份  = received_at = 按鈕當下 ⇒ F 段自然歸到「按鈕那個月」。
--
-- ⚠️⚠️ **一個沒有做到的地方，必須知道（見施工回報「第二輪／甲案的一半」）**：
--   分店價這一側**沒有辦法精準鏡像**。F 段的分店價是用
--   `_branch_price_at(..., t.received_at)` 查的（20260901000000:229-230），
--   也就是**按鈕當下**的價；原本被收錢時用的是**派車當下**的價
--   （同檔 :144）。這兩個時點之間如果那個商品的分店價改過版
--   （prices.effective_from/effective_to 是真的分版的，見
--    20260715000000:83-114），沖回去的金額就會跟當初收的不一樣。
--   ⇒ 為什麼還是選「按鈕當下」：如果改成用派車日，沖帳會掉進**派車那個月**，
--     而那個月很可能已經鎖定（confirmed 以上生成器直接跳過）或已被
--     20260901000000:108 的 9 月硬擋擋住 ⇒ **這筆錢會安靜地永遠回不到店家**。
--     兩害相權，寧可價差、不要整筆消失。
--   ⇒ 驗證腳本 §8-c 會把「兩個時點價格不同」的筆數與金額抓出來給人看，
--     不讓它安靜發生。要做到精準鏡像需要動 F 段（見施工回報的提案），
--     ⛔ 本檔沒有做，等裁示。
--
-- 只做 hq_to_store（⚠️ 這是施工者的判斷，規格沒指定，見施工回報）：
--   restock_hq 這一支**沒有**總倉守衛（redispatch 有，20260811020000:173-177），
--   所以店↔店的單也按得下去。但店↔店那一段的錢走的是 air_in/air_out
--   （8/25 起用 qty_shipped 兩邊鏡像），不是 hq_inbound；
--   對它產 return_to_hq 會變成「用退貨去沖一筆不是這樣收的錢」＝製造新的錯帳。
--   而 20260825030000:40-42 檔頭已經寫明店↔店短收「需要時用
--   store_settlement_adjustments 人工調整」。⇒ 本檔只對 hq_to_store 產沖帳單。
--
-- 不會重複產（冪等）：
--   新欄位 transfer_items.shortage_return_transfer_id 有值就不再產。
--   ⚠️ 這道防線是必要的，不能只靠原本那兩個守衛：
--     先按 restock_hq（設 shortage_restock_movement_id）、再按 redispatch，
--     第二次會通過 redispatch 自己的守衛（它只看 shortage_redispatch_wave_id）
--     ⇒ 沒有這個新欄位就會產出**兩張**沖帳單 ＝ 退兩次錢。
--
-- 基底版本：rpc_resolve_transfer_item_shortage ← 20260811020000（v3，現行最新版；
--   已用標準查法確認共 3 版：20260607000040 / 20260810000010 / 20260811020000，
--   且 8/24 那兩支重做只在註解裡提到它、沒有重新定義）。
--   本檔逐字保留 v3 全文，只加：DECLARE 兩個變數、末尾一段建單、UPDATE 多寫一欄。
-- Rollback：見 切片1_回滾SQL_貼了就回到8月25日版_2026-09-01.sql 的**第 1 段**
--   （⛔ 第 1 段要在第 3 段「引擎回舊版」之前跑；
--     ⛔ 而且回滾之後一定要跑那份檔案的「附錄 B」把已產生的沖帳單作廢，
--       否則舊月結配上還留著的沖帳單 ＝ 店家被退兩次錢。
--     新欄位 shortage_return_transfer_id 可留著不刪，留著無害，
--     附錄 A／B 正是靠它找到那些單）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. schema：冪等用的欄位（有值＝這筆短收已經產過沖帳單）
-- ------------------------------------------------------------
ALTER TABLE transfer_items
  ADD COLUMN IF NOT EXISTS shortage_return_transfer_id BIGINT REFERENCES transfers(id);

COMMENT ON COLUMN transfer_items.shortage_return_transfer_id IS
  '短收「同意退回」自動產生的純記帳退貨單 transfer id（有值＝已沖過帳，不可重複沖）。'
  '該退貨單只為了讓月結 F 段沖帳，不代表有貨在搬——庫存另由 transfer_cancel 異動處理。';

-- ------------------------------------------------------------
-- 2. rpc_resolve_transfer_item_shortage v4
--    ＝ 20260811020000 v3 逐字 ＋ 末尾的沖帳單
-- ------------------------------------------------------------
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
  -- 2026-09-01 切片 1.5：沖帳用的純記帳退貨單
  v_ret_no          TEXT;
  v_ret_transfer_id BIGINT;
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
$$;

GRANT EXECUTE ON FUNCTION public.rpc_resolve_transfer_item_shortage(BIGINT, TEXT, TEXT, UUID)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_resolve_transfer_item_shortage(BIGINT, TEXT, TEXT, UUID) IS
  '2026-09-01 起(切片1.5):restock_hq/redispatch 且原單是 hq_to_store 時,額外產一張'
  'status=received 的純記帳 return_to_hq(不動庫存),讓月結 F 段自動沖掉短收那筆錢;'
  '冪等靠 transfer_items.shortage_return_transfer_id。'
  '⚠ 分店價以「按鈕當下」計價,與原扣款的「派車當下」在改過價的商品上會有差額。'
  'HQ 處理收貨短少:標記 resolution(replenish/cancel_orders/vendor_claim/accept/restock_hq/redispatch)+ 備註。'
  'restock_hq 把短收量以原出庫成本沖回出貨端庫存(transfer_cancel movement,防重複);'
  'redispatch=拒絕短收:沖回總倉＋自動開 draft 撿貨單重派回原店(繼承原 wave 的 campaign/source_po,'
  '出貨收貨後原訂單自動推進);其餘 resolution 僅打標記。';

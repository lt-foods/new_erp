-- ============================================================================
-- 2026-09-04（店家退貨頁 · 第 2 支）：總倉「同意收回」的那一刻才扣店家庫存
--
-- ============================================================================
-- 【一】老闆 2026-09-04 裁示 2（乙案），逐字錨定
-- ============================================================================
--   「先不扣 → 帳上還是 10，旁邊標『退貨中 3』讓人看得到；
--     **總倉按同意的那一刻才真的扣**。不同意的話什麼都沒動過，乾乾淨淨」
--     （出處：需求暨計畫_店家退貨頁_2026-09-04.md 第 10-11 行）
--
-- ⛔⛔ 【三支必須一起貼，順序不可顛倒】
--   1️⃣ 20260904020000（建單不扣）→ 2️⃣ 本檔（同意才扣）→ 3️⃣ 20260904020020（不同意零動作）
--   只貼 1️⃣ 不貼本檔 ＝ 店家退的貨會**憑空進總倉庫存**（店家那邊永遠不會被扣）。
--
-- ============================================================================
-- 【二】為什麼非得改 rpc_receive_transfer 這支共用函式不可（我找過別條路）
-- ============================================================================
--   「同意收回」只有兩個入口，而兩個最後都走這一支：
--     ① 總倉收件匣那顆鈕（單筆與批次都是）→ rpc_transfer_arrive_at_hq_batch
--        （hq/inbox/page.tsx:1583-1586、:1752-1754）→ 該支 20260508000000:82
--        `PERFORM rpc_receive_transfer(v_id, NULL, p_operator, NULL);`
--     ② 48 小時自動同意（20260903010020:174-181）→ 直接 PERFORM rpc_receive_transfer
--   ⇒ 掛在這一支，兩個入口一次到位，**總倉端前端一行都不用改**（老闆要的「零改動」）。
--
--   ⛔ 試過但走不通的三條：
--     - 掛 trigger 在 transfers 狀態變更上：那個 UPDATE 在主迴圈**之後**（基底 :163），
--       出庫異動晚一步建，總倉就會用 0 成本入庫（成本口徑沖成 0）。
--     - 讓店家端自己先扣：那就是甲案，老闆已經否決。
--     - 另外做一顆「同意」鈕：要改 hq/inbox/page.tsx，那支檔在 PR #906 手上（禁碰），
--       而且違反老闆「總倉端零改動」。
--
-- ============================================================================
-- 【三】改了什麼（基底逐字自證）
-- ============================================================================
--   基底＝ 20260827000000_receive_gate_only_batch_sku_orders.sql:30
--     （用定義鏈查法自排確認：git grep -nE "CREATE (OR REPLACE )?FUNCTION (public\.)?rpc_receive_transfer"
--       ⇒ 最後一支就是它；本機 12 個近期分支逐一掃過，沒有任何一支重定義它）
--
--   對基底做 diff：
--     被刪／改的行 = **2 行**，而且都是同一件事 ——
--         <          customer_order_id, next_transfer_id
--         <          v_customer_order_id, v_next_transfer_id
--       既有 7 個欄位與 7 個變數**一字未動**，只在尾巴各加一個 source_location /
--       v_source_location（扣店家庫存要知道出貨端是哪一個位置，基底沒取這一欄）。
--     其餘 diff 區塊全是 a（append）：DECLARE 加 8 個變數、主迴圈之前插入一段。
--
--   ⛔ 沒有動到的（Alex 與歷次修法的設計決定，逐字保留）：
--     邏輯 A0（解除待補貨）／B（訂單推 ready）／C（取貨閘門前濾，20260827 的效能修法）／
--     D（補貨申請狀態同步）／E（自動配單）／F（現貨池），以及多收放行、
--     qty_received 寫法、notes append 規則、回傳欄位 —— 全部一字未改。
--
-- ============================================================================
-- 【四】⚠️⚠️ 扣不動的時候會怎樣（做了會怎樣／不做會怎樣，兩邊都講）
-- ============================================================================
--   情境：店家送出退貨之後、總倉按同意之前，把那批貨賣掉或被客人取走了。
--
--   本檔的處置＝**大聲擋下、整筆回滾**（單維持待處理、貨與帳都沒動）。
--   ⭐ 這不是我自己定的新規則，是本系統退貨路徑的**既有慣例**：
--       rpc_outbound 預設 p_allow_negative=FALSE（20260705000000:156-166）本來就丟
--       Insufficient stock；rpc_create_order_return 的 COMMENT（20260801000000:356）
--       白紙黑字寫著「非 restock 路徑不夠店端庫存時由 rpc_outbound 擋 Insufficient stock」。
--       本檔只是把訊息從英文換成店員看得懂的話，並且在扣之前先鎖再驗（不靠負庫存兜底）。
--
--   做了（擋下來）的代價：
--     - 總倉那個人會看到「成功 0 / 失敗 1  #<單號>: 這張退貨單扣不動…」，這張單留在待處理。
--     - 48 小時自動同意那支（20260903010020）每 30 分鐘會再試一次，每次都失敗，
--       失敗被它自己的 EXCEPTION 收進 failed 清單裡 ⇒ **不會有人被通知**，
--       這張單會一直卡著，直到店家把貨補回來或有人手動處理。
--       ⚠️ 這一條請老闆知道。緩解做在店家端：退貨頁的進度列表會**即時**比對
--       「店裡在庫 vs 這張單要退的量」，不夠時當場標紅字提醒店家先處理。
--   不做（放行、允許扣成負）的代價：
--     - 店家庫存變負數，而 on_hand 被全站好幾道閘門讀著（取貨閘門的實體側、
--       現場銷售可賣量、派貨可配量）⇒ 會誤擋別人的取貨，變成更難查的問題。
--     - 這正是 20260904010010／010020 那一組鎖在防的事，反著做等於把它推回去。
--
-- ============================================================================
-- 【五】鎖：與 9/04 上午那三支同一家族、同一個鎖序（⛔ 要改就四支一起改）
-- ============================================================================
--   四支都是「ORDER BY location_id, sku_id 去重後逐列 FOR UPDATE、放在主迴圈之前」：
--     20260904010000（✎修改實收）／20260904010010（取貨）／20260904010020（現場銷售）／本檔。
--   順序不一致就會各拿一半互相等（死鎖）。⛔ 只改一邊等於沒改。
--   ⚠️ 那三支在 PR #909 裡，本檔基準（7587aba7）沒有它們 —— 本檔**不依賴**它們，
--     鎖序寫成一樣是為了它們合併之後不會打架。
--
-- ============================================================================
-- 【六】確認過不會誤傷的三種既有單據
-- ============================================================================
--   ① 舊路徑退貨（rpc_create_order_return，內部調撥頁那顆橘色鈕）：
--      建單當下就寫了 out_movement_id（20260801000000:248-265）
--      ⇒ 新增那段的 EXISTS 為假、整段跳過，行為與上線前**一模一樣**。
--   ② 短收沖帳單（20260901000010:317 / 20260903000020:268 / 20260903000200:370）：
--      三種都生而 status='received'，進不了本函式（基底 :82-84 只收 shipped）。
--   ③ 一般派貨／補貨／店對店（hq_to_store、store_to_store）：
--      新增那段第一個條件就是 v_transfer_type = 'return_to_hq' ⇒ 碰都碰不到。
--
-- Rollback：CREATE OR REPLACE 回 20260827000000:30 的版本即可
--   （本檔沒有動任何 schema、沒有新增欄位、沒有改 CHECK、沒有資料異動）。
--   ⚠️ 三支一組：回滾任一支，乙案就變成半套（見【一】）。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(p_transfer_id bigint, p_lines jsonb, p_operator uuid, p_notes text DEFAULT NULL::text, p_auto_allocate boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id            UUID;
  v_status               TEXT;
  v_transfer_type        TEXT;
  v_dest_location        BIGINT;
  v_existing_notes       TEXT;
  v_customer_order_id    BIGINT;
  v_next_transfer_id     BIGINT;
  v_item                 RECORD;
  v_qty_received         NUMERIC;
  v_unit_cost            NUMERIC;
  v_in_mov_id            BIGINT;
  v_total_qty            NUMERIC := 0;
  v_total_variance       NUMERIC := 0;
  v_items_received       INTEGER := 0;
  v_lines_consumed       INTEGER := 0;
  v_lines_count          INTEGER;
  v_orders_advanced      INTEGER := 0;
  v_next_shipped         BOOLEAN := FALSE;
  v_leg2                 transfers%ROWTYPE;
  v_leg2_item            RECORD;
  v_leg2_mov             BIGINT;
  v_dest_store_id        BIGINT;
  v_restock_received     INTEGER := 0;
  v_rr                   RECORD;
  v_prog                 RECORD;
  v_recv_skus            BIGINT[];   -- 20260811(3)：本次實收 > 0 的 SKU
  v_backorders_freed     INTEGER := 0;   -- 20260811(6)：本次到貨解除的待補貨列數
  v_sk                   RECORD;     -- 20260814(2)：逐 SKU 算本批多給
  v_grown                NUMERIC;
  v_surplus              JSONB := '[]'::jsonb;
  v_gate_candidates      BIGINT[];   -- 20260827：邏輯 C 的前濾母體
  -- ↓↓ 20260904020010 新增（店家退貨頁乙案：同意那一刻才扣店家庫存）
  v_source_location      BIGINT;     -- 基底沒取這一欄，扣店家庫存要用
  v_defer_lock           RECORD;
  v_defer                RECORD;
  v_defer_item           RECORD;
  v_defer_on_hand        NUMERIC;
  v_defer_mtype          TEXT;
  v_defer_out_mov        BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id, source_location
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id, v_source_location
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is in status %, expected shipped', p_transfer_id, v_status;
  END IF;

  IF p_lines IS NOT NULL THEN
    v_lines_count := jsonb_array_length(p_lines);
    IF EXISTS (
      SELECT 1
        FROM jsonb_array_elements(p_lines) AS l
        LEFT JOIN transfer_items ti
          ON ti.id = (l->>'transfer_item_id')::BIGINT
         AND ti.transfer_id = p_transfer_id
       WHERE ti.id IS NULL
    ) THEN
      RAISE EXCEPTION 'p_lines contains transfer_item_id not belonging to transfer %', p_transfer_id;
    END IF;
  END IF;

  -- ==========================================================================
  -- 20260904020010（店家退貨頁 · 乙案）：「同意收回」的那一刻才扣店家庫存
  --   老闆 2026-09-04 原話：「總倉按同意的那一刻才真的扣」。
  --   完整推導見檔頭。本檔唯一新增的行為就是這一段。
  --
  -- 為什麼一定要放在主迴圈**之前**：下面那個迴圈是靠
  --   LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id 取 out_cost，
  --   再用它當入總倉的成本（:132 v_unit_cost := COALESCE(ABS(v_item.out_cost), 0)）。
  --   出庫異動晚一步建，總倉就會用 0 成本入庫 —— 短收沖帳單那支檔
  --   （20260901000010）檔頭已經寫過同型的坑：「留白會讓成本口徑沖成 0」。
  -- ==========================================================================
  -- ⛔ 兩層 IF 不是多寫的：外層先用一個變數比對擋掉，裡面那個 EXISTS 才不會對
  --   每一張 hq_to_store 派貨單都跑一次。這支函式是 8/27 那次 DB OOM 的主角
  --   （檔頭:4-11 記著批次收貨單張 2,685ms），熱路徑上不可以無條件多一個子查詢。
  IF v_transfer_type = 'return_to_hq' THEN
   IF EXISTS (
       SELECT 1 FROM transfer_items ti
        WHERE ti.transfer_id = p_transfer_id
          AND ti.out_movement_id IS NULL
          AND ti.qty_shipped > 0
          AND ti.sku_id IS NOT NULL
     ) THEN

    -- 舊路徑（rpc_create_order_return，20260801000000:248-265）建單當下就寫了
    -- out_movement_id ⇒ 整段 EXISTS 為假、完全跳過，行為與本檔上線前一模一樣。
    -- 短收沖帳單（20260901000010 / 20260903000020 / 20260903000200）生而 status='received'，
    -- 進不了這支函式（:82-84 只收 shipped）⇒ 也碰不到這一段。

    IF v_source_location IS NULL THEN
      RAISE EXCEPTION '退貨單 % 沒有出貨端位置，無法扣店家庫存', p_transfer_id;
    END IF;

    -- ⛔ 這種單不接受「只收一部分」。
    --   下面扣的是 qty_shipped 全額，而主迴圈會照 p_lines 決定總倉入幾件 ——
    --   兩個數字不一樣的話，差額會**憑空從店家消失**（店家扣 10、總倉只進 8）。
    --   今天沒有任何入口會走到這裡（總倉那顆鈕與 48h cron 都傳 p_lines = NULL，
    --   出處 20260508000000:82、20260903010020:174-181），所以這道守衛擋不到任何現有流程；
    --   它是留給「哪天有人給退貨單加了部分收貨」的那個人看的 —— 讓他當場失敗，
    --   而不是讓庫存無聲無息少掉。
    IF p_lines IS NOT NULL THEN
      RAISE EXCEPTION '退貨單不支援「只收一部分」：這張單有還沒扣過店家庫存的品項，必須整張收（請不要帶 p_lines）。';
    END IF;

    -- 破損 / 一般退貨：tag 與 movement_type 的對應逐字沿用
    -- rpc_create_order_return（20260801000000:95-97 的 CHECK、:149-151 的 tag）。
    v_defer_mtype := CASE
      WHEN COALESCE(v_existing_notes, '') LIKE '[order return|破損%' THEN 'damage'
      ELSE 'customer_return'
    END;

    -- ① 預鎖：把這次會扣到的 (location_id, sku_id) 去重、**排序後**逐列鎖起來。
    --    ⛔ ORDER BY location_id, sku_id 這個順序與 20260904010000（✎修改實收）、
    --      20260904010010（取貨）、20260904010020（現場銷售）**完全一致**，
    --      四支才不會各拿一半互相等（死鎖）。只改一邊等於沒改。
    --    餘額列不存在時 FOR UPDATE 鎖不到東西 —— 那代表 on_hand 視同 0，
    --    下面②一定擋下來，不會有漏網。
    FOR v_defer_lock IN
      SELECT DISTINCT v_source_location AS location_id, ti.sku_id
        FROM transfer_items ti
       WHERE ti.transfer_id = p_transfer_id
         AND ti.out_movement_id IS NULL
         AND ti.qty_shipped > 0
         AND ti.sku_id IS NOT NULL
       ORDER BY 1, 2
    LOOP
      PERFORM 1
         FROM stock_balances
        WHERE tenant_id   = v_tenant_id
          AND location_id = v_defer_lock.location_id
          AND sku_id      = v_defer_lock.sku_id
        FOR UPDATE;
    END LOOP;

    -- ② 鎖到手才重驗夠不夠扣。⭐ 同一個 SKU 分散在多行時要**加總**再比 ——
    --   逐行比會讓「每一行看起來都夠、加起來卻不夠」整批漏過去
    --   （這是 20260904010010 第二輪學到的同一課，寫在那支的②③段）。
    --   ⛔ 虛擬商品（is_virtual）整個跳過：rpc_inbound 從 20260903000100:56-64 起
    --     對虛擬 SKU 直接 RETURN NULL，這裡若照扣就變成「店家扣了、總倉沒進」＝只出不進。
    --     進出都不寫才是一致的。（建單那支 20260904020000 已經擋掉虛擬商品，
    --     這裡是給歷史資料的第二層防線。）
    FOR v_defer IN
      SELECT ti.sku_id,
             SUM(ti.qty_shipped) AS need,
             COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'')
               || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''),
               s.sku_code, '品項#' || ti.sku_id::TEXT) AS sku_label
        FROM transfer_items ti
        LEFT JOIN skus s ON s.id = ti.sku_id
       WHERE ti.transfer_id = p_transfer_id
         AND ti.out_movement_id IS NULL
         AND ti.qty_shipped > 0
         AND ti.sku_id IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM skus s2 JOIN products p2 ON p2.id = s2.product_id
            WHERE s2.id = ti.sku_id AND p2.is_virtual
         )
       GROUP BY ti.sku_id, s.product_name, s.variant_name, s.sku_code
       ORDER BY ti.sku_id
    LOOP
      SELECT COALESCE(on_hand, 0) INTO v_defer_on_hand
        FROM stock_balances
       WHERE tenant_id   = v_tenant_id
         AND location_id = v_source_location
         AND sku_id      = v_defer.sku_id;

      IF COALESCE(v_defer_on_hand, 0) < v_defer.need THEN
        -- ⛔ 大聲擋下、整筆回滾（＝這張單維持待處理、貨帳都沒動）。
        --   這是本系統退貨路徑的**既有慣例**，不是新規則：
        --   rpc_outbound 預設 p_allow_negative=FALSE（20260705000000:156-166）就會
        --   丟 Insufficient stock，rpc_create_order_return 的 COMMENT
        --   （20260801000000:356）白紙黑字寫著「非 restock 路徑不夠店端庫存時
        --   由 rpc_outbound 擋 Insufficient stock」。這裡只是把訊息換成店家看得懂的話。
        --   ⭐ 訊息刻意不帶前綴（像 stock_short:）—— rpcError.ts 在 PR #909 裡，本波不碰，
        --     加了前綴店員會看到掛在句子前面的英文。批次那層（rpc_transfer_arrive_at_hq_batch
        --     20260508000000:84-87）會把它包成「#<單號id>: <訊息>」顯示，單號那半不用自己寫。
        RAISE EXCEPTION '這張退貨單扣不動：「%」店裡現在只有 % 件、這張單要退 % 件。貨可能已經賣掉或被客人取走了 —— 這張單維持在待處理，庫存與帳都沒有變動。',
          v_defer.sku_label,
          trim_scale(COALESCE(v_defer_on_hand, 0)), trim_scale(v_defer.need);
      END IF;
    END LOOP;

    -- ③ 逐行真的扣。走 rpc_outbound（不是自己 INSERT）＝ 白吃它既有的
    --   可用量守衛與 avg_cost 取價，成本才會跟著這批貨進總倉。
    FOR v_defer_item IN
      SELECT ti.id, ti.sku_id, ti.qty_shipped
        FROM transfer_items ti
       WHERE ti.transfer_id = p_transfer_id
         AND ti.out_movement_id IS NULL
         AND ti.qty_shipped > 0
         AND ti.sku_id IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM skus s2 JOIN products p2 ON p2.id = s2.product_id
            WHERE s2.id = ti.sku_id AND p2.is_virtual
         )
       ORDER BY ti.id
    LOOP
      v_defer_out_mov := rpc_outbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_source_location,
        p_sku_id          => v_defer_item.sku_id,
        p_quantity        => v_defer_item.qty_shipped,
        p_movement_type   => v_defer_mtype,
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );

      UPDATE transfer_items
         SET out_movement_id = v_defer_out_mov,
             updated_by      = p_operator
       WHERE id = v_defer_item.id;
    END LOOP;
   END IF;
  END IF;

  -- ===== 原有邏輯：寫 qty_received + dest_location inbound =====
  FOR v_item IN
    SELECT ti.id, ti.sku_id, ti.qty_shipped, sm.unit_cost AS out_cost
      FROM transfer_items ti
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE ti.transfer_id = p_transfer_id
     ORDER BY ti.id
  LOOP
    v_qty_received := v_item.qty_shipped;

    IF p_lines IS NOT NULL THEN
      SELECT (l->>'qty_received')::NUMERIC
        INTO v_qty_received
        FROM jsonb_array_elements(p_lines) AS l
       WHERE (l->>'transfer_item_id')::BIGINT = v_item.id
       LIMIT 1;

      IF FOUND THEN
        v_lines_consumed := v_lines_consumed + 1;
      ELSE
        v_qty_received := v_item.qty_shipped;
      END IF;
    END IF;

    IF v_qty_received IS NULL OR v_qty_received < 0 THEN
      RAISE EXCEPTION 'transfer_item % qty_received must be >= 0, got %', v_item.id, v_qty_received;
    END IF;
    -- 20260824020000：允許多收（實收 > 派出）。總倉實際多裝了就照實入庫，
    -- 差異走 v_hq_exceptions 的 transfer_over 分支回報總倉（同短少那套收件匣）。
    -- 上限守衛拿掉的是「帳跟不上實物」的錯：擋下來店家只能少報，貨照樣在店裡。

    IF v_qty_received > 0 THEN
      v_unit_cost := COALESCE(ABS(v_item.out_cost), 0);

      v_in_mov_id := rpc_inbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_dest_location,
        p_sku_id          => v_item.sku_id,
        p_quantity        => v_qty_received,
        p_unit_cost       => v_unit_cost,
        p_movement_type   => 'transfer_in',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );

      UPDATE transfer_items
         SET qty_received   = v_qty_received,
             in_movement_id = v_in_mov_id,
             updated_by     = p_operator
       WHERE id = v_item.id;
    ELSE
      UPDATE transfer_items
         SET qty_received = 0,
             updated_by   = p_operator
       WHERE id = v_item.id;
    END IF;

    v_total_qty      := v_total_qty + v_qty_received;
    v_total_variance := v_total_variance + (v_qty_received - v_item.qty_shipped);
    v_items_received := v_items_received + 1;
  END LOOP;

  UPDATE transfers
     SET status      = 'received',
         received_by = p_operator,
         received_at = NOW(),
         notes       = CASE
                         WHEN p_notes IS NULL OR p_notes = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN p_notes
                         ELSE v_existing_notes || E'\n' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- ===== 邏輯 A0（20260811(6)）：本次到貨 → 解除待補貨 =====
  -- 少發配貨（rpc_allocate_shortage）把沒配到的品項標 backorder_at，取貨閘門
  -- 因此回 false。在這支之前，全 DB 沒有任何路徑會在「補的那批貨到店」時把它
  -- 清掉 —— 補出第二批、店家收了貨，品項還是掛「待補貨」，要有人記得回收貨頁
  -- 再點一次「⚖️ 配貨」才解得開。
  --
  -- **必須排在邏輯 A/B/C/E 之前**：邏輯 C 的 is_order_pickup_ready() 與
  -- 邏輯 E 的 _advance_arrived_confirmed_orders 都含 backorder_at IS NULL，
  -- 先解除才推得動單頭；順序反了這批單要等下一次收貨才會動。
  --
  -- 20260813：手動配單模式（p_auto_allocate = FALSE）**仍照跑** —— 這是
  -- 「先前⚖️配貨決定」的完成、有帳面+實體雙守衛，不是新的配單決策；
  -- 關掉會重演松山單卡 6 天災情。要重新決定配給誰請用 ⚖️ 配貨。
  IF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    SELECT ARRAY_AGG(DISTINCT ti.sku_id)
      INTO v_recv_skus
      FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id
       AND ti.qty_received > 0;

    IF v_dest_store_id IS NOT NULL AND v_recv_skus IS NOT NULL THEN
      v_backorders_freed := public._settle_arrived_backorders(
        v_dest_store_id, v_recv_skus, p_operator, NOW());
    END IF;
  END IF;

  -- ===== 邏輯 A：自動 ship 下一段（aid chain B 模型）=====
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_leg2 FROM transfers
     WHERE id = v_next_transfer_id FOR UPDATE;

    IF v_leg2.id IS NOT NULL AND v_leg2.status = 'draft' THEN
      FOR v_leg2_item IN
        SELECT ti.id AS leg2_item_id, ti.sku_id, ti2.qty_received
          FROM transfer_items ti
          JOIN transfer_items ti2
            ON ti2.transfer_id = p_transfer_id AND ti2.sku_id = ti.sku_id
         WHERE ti.transfer_id = v_leg2.id
      LOOP
        IF v_leg2_item.qty_received > 0 THEN
          v_leg2_mov := rpc_outbound(
            p_tenant_id       => v_leg2.tenant_id,
            p_location_id     => v_leg2.source_location,
            p_sku_id          => v_leg2_item.sku_id,
            p_quantity        => v_leg2_item.qty_received,
            p_movement_type   => 'transfer_out',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_leg2.id,
            p_operator        => p_operator
          );
          UPDATE transfer_items
             SET qty_shipped     = v_leg2_item.qty_received,
                 qty_requested   = v_leg2_item.qty_received,
                 out_movement_id = v_leg2_mov,
                 updated_by      = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        ELSE
          UPDATE transfer_items
             SET qty_shipped   = 0,
                 qty_requested = 0,
                 updated_by    = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        END IF;
      END LOOP;

      UPDATE transfers
         SET status      = 'shipped',
             shipped_by  = p_operator,
             shipped_at  = NOW(),
             updated_by  = p_operator
       WHERE id = v_leg2.id;
      v_next_shipped := TRUE;
    END IF;
  END IF;

  -- ===== 邏輯 B：aid 單 FK 直接推 customer_order → ready =====
  IF v_customer_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = NOW(),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_customer_order_id
       AND status = 'shipping';
    GET DIAGNOSTICS v_orders_advanced = ROW_COUNT;

  -- ===== 邏輯 C：hq_to_store wave transfer → 推該分店訂單 → ready =====
  -- 修：不再無條件推該店「所有」shipping 訂單；改成只推
  --     is_order_pickup_ready=true（依該訂單的團真的到齊、shortage-aware）的訂單，
  --     避免收到別團波次時把尚未出貨的團一起誤標為可取貨。
  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    -- 20260827000000：只對「有本批 SKU active 品項」的派貨中訂單跑閘門。
    -- 閘門 ~8ms/張、原本逐張調撥單掃該店**全部** shipping 單（實測松山 236 張
    -- ＝每張調撥單 ~2 秒；批次收 8~14 張 = 16~27 秒，8/27 把 1GB 機器壓掛的主因）。
    -- 收貨只改變本批 SKU 的到貨／庫存事實，沒含這些 SKU 的訂單閘門結果與收貨前
    -- 相同，濾掉語意不變；歷史卡住的單改由「收到它的 SKU 那批」或手動 ⚖️ 配貨
    -- 觸發。v_recv_skus 為 NULL（本批零實收）整段跳過。
    -- **一定要兩步走**：前濾寫成同一句的 IN (子查詢) 時 planner 會把閘門函式
    -- 下推到 customer_orders 掃描層、先於 semi-join 執行（實測 2.4s，等於沒濾），
    -- 先收斂成陣列再 UPDATE 就沒有重排空間。
    IF v_dest_store_id IS NOT NULL AND v_recv_skus IS NOT NULL THEN
      SELECT COALESCE(ARRAY_AGG(DISTINCT coi.order_id), '{}'::BIGINT[])
        INTO v_gate_candidates
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id
       WHERE co.tenant_id       = v_tenant_id
         AND co.pickup_store_id = v_dest_store_id
         AND co.status          = 'shipping'
         AND coi.status IN ('pending','reserved','ready')
         AND coi.sku_id = ANY (v_recv_skus);

      IF cardinality(v_gate_candidates) > 0 THEN
        WITH advanced AS (
          UPDATE customer_orders co
             SET status     = 'ready',
                 ready_at   = NOW(),
                 updated_by = p_operator,
                 updated_at = NOW()
           WHERE co.id = ANY (v_gate_candidates)
             AND co.status = 'shipping'
             AND public.is_order_pickup_ready(co.id)
          RETURNING co.id
        )
        SELECT COUNT(*) INTO v_orders_advanced FROM advanced;
      END IF;
    END IF;
  END IF;

  -- ===== 邏輯 D：linked 補貨申請 → 已收貨；ride-along 單 → ready =====
  -- 店家收貨即補貨流程終點：把 linked_transfer_id 指向本單的補貨申請
  -- 推到 received。approved_transfer 為 legacy 防禦（現行直派皆直接 shipped）。
  FOR v_rr IN
    SELECT id FROM restock_requests
     WHERE linked_transfer_id = p_transfer_id
       AND status IN ('shipped', 'approved_transfer')
  LOOP
    UPDATE restock_requests
       SET status = 'received', updated_by = p_operator
     WHERE id = v_rr.id;
    v_restock_received := v_restock_received + 1;

    -- 20260810：ride-along 內部單改由 settle helper 收尾 —— 品項先對齊實收
    -- （短收 0 → cancelled、部分 → 拆行），再推 ready / 全未到自動取消。
    PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
  END LOOP;

  -- ===== 邏輯 D2（20260717）：wave 路徑補貨申請 → 已出貨/已收貨 =====
  -- 本調撥若為撿貨單產物（picking_wave_items.generated_transfer_id 指向本單），
  -- 歸屬的補貨申請（歸屬原則同 20260715000020）「全數出貨且全數到店」→ received、
  -- ride-along 單推 ready；已全數出貨但仍有他張在途 → 至少推 shipped。
  FOR v_rr IN
    SELECT DISTINCT rr.id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN restock_requests rr
        ON rr.tenant_id = v_tenant_id
       AND rr.requesting_store_id = pwi.store_id
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND rr.status IN ('approved_pr', 'approved_transfer', 'shipped')
       AND (pw.source_restock_request_id = rr.id
            OR (pwi.campaign_id IS NULL
                AND rr.linked_pr_id IS NOT NULL
                AND pw.source_po_id IN (
                  SELECT DISTINCT poi.po_id
                    FROM purchase_request_items pri
                    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
                   WHERE pri.pr_id = rr.linked_pr_id)))
       AND pwi.sku_id IN (SELECT sku_id FROM restock_request_lines
                           WHERE request_id = rr.id AND cancelled_at IS NULL)
  LOOP
    SELECT * INTO v_prog FROM public._restock_wave_progress(v_rr.id);
    IF v_prog.fully_dispatched AND v_prog.all_arrived THEN
      UPDATE restock_requests
         SET status = 'received', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer', 'shipped');
      v_restock_received := v_restock_received + 1;

      -- 20260810：ride-along 單交給 settle helper —— 短收品項對齊實收後
      -- 才推 ready；全未到則整單自動取消，不再掛在店身上。
      PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
    ELSIF v_prog.fully_dispatched THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer');
    END IF;
  END LOOP;

  -- ===== 邏輯 E（20260811(3)，20260811(5) 從邏輯 C 搬到這裡）=====
  -- 補貨路線發的團沒有 campaign 對齊波次，客人單從來沒被推到 'shipping'，
  -- 邏輯 C 接不到。這裡把「對得上本次到貨 SKU」的 confirmed 單依訂單時間、
  -- 在可配量內推 ready，並把【內部】xx 店現貨池扣掉相應的量。
  --
  -- **必須排在 D/D2 之後**：ride-along 單要先被 _settle_restock_ride_along
  -- 推成 ready（並對齊實收量）， _trim_internal_pool 才吃得到它 ——
  -- 那支只認已到貨的容器單（20260811000040）。
  --
  -- 20260813：p_auto_allocate = FALSE（手動配單模式）時跳過 —— 收貨只入庫，
  -- 配給哪些 confirmed 單由店家在收貨頁「手動配單」彈窗自己勾
  -- （rpc_manual_allocate_confirmed_orders，同一支 helper 推進）。
  IF p_auto_allocate AND v_customer_order_id IS NULL AND v_transfer_type = 'hq_to_store' THEN
    IF v_dest_store_id IS NOT NULL THEN
      SELECT ARRAY_AGG(DISTINCT ti.sku_id)
        INTO v_recv_skus
        FROM transfer_items ti
       WHERE ti.transfer_id = p_transfer_id
         AND ti.qty_received > 0;

      IF v_recv_skus IS NOT NULL THEN
        v_orders_advanced := v_orders_advanced
          + public._advance_arrived_confirmed_orders(
              v_dest_store_id, v_recv_skus, p_operator, NOW());
      END IF;
    END IF;
  END IF;

  -- ===== 邏輯 F（20260814(2)）：多給的跳出【內部】店 =====
  -- 本批實收扣掉「本店對這個 SKU 還沒交出去的帳」之後仍有剩 → 沒有訂單主人，
  -- 掛進【內部】xx 店現貨池，店員才轉得出去（在這之前只進 on_hand，
  -- 池子看不到 → 帳上等於隱形，只能靠人工開內部單）。
  --
  -- **必須排在邏輯 B/C/E 之後**：那些是把貨配給客人的路徑，配掉的量會變成
  -- 「已承諾未取」，_grow_internal_pool 的自由量才扣得到；順序反了會把
  -- 客人的貨掛進池子，重演 20260811000030 忠順那種「團友撲空」。
  -- 手動配單模式（p_auto_allocate=FALSE）在這裡通常算不出剩餘（沒配的單
  -- 還是 confirmed，自由量已扣掉它們），真正的結算在
  -- rpc_receive_transfer_manual 配完單之後再跑一次 —— 同一支 helper，
  -- 依當下自由量重算，不會重複掛。
  IF v_customer_order_id IS NULL AND v_transfer_type = 'hq_to_store'
     AND v_dest_store_id IS NOT NULL THEN
    FOR v_sk IN
      SELECT ti.sku_id, SUM(ti.qty_received) AS received
        FROM transfer_items ti
       WHERE ti.transfer_id = p_transfer_id
         AND ti.qty_received > 0
       GROUP BY ti.sku_id
       ORDER BY ti.sku_id
    LOOP
      v_grown := public._grow_internal_pool(
        v_dest_store_id, v_sk.sku_id, v_sk.received, p_operator, NOW(),
        '[收貨多給|TF#' || p_transfer_id::TEXT || ']');
      IF v_grown > 0 THEN
        v_surplus := v_surplus
          || jsonb_build_object('sku_id', v_sk.sku_id, 'qty', v_grown);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped,
    'restock_received',       v_restock_received,
    'backorders_freed',       v_backorders_freed,
    'auto_allocate',          p_auto_allocate,
    'surplus',                v_surplus
  );
END;
$function$;

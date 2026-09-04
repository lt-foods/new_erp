-- ============================================================
-- 2026-09-04：「✎ 修改實收」改成會連動店家庫存（不再是純紀錄）
--
-- ⚠️⚠️ 本檔改寫的是 PR #900（rpc_adjust_received_transfer）的行為，
--   那是另一位工程師（@alexktchen）做的功能。老闆 2026-09-04 親自裁示要改，
--   比照 PR #903 的做法：**紀錄、月結對應、撤銷語意逐字保留，只加庫存那一段**，
--   並在 PR 說明裡向原作者完整揭露改了哪一段、為什麼改。
--
-- ------------------------------------------------------------
-- 一、為什麼要改（2026-09-04 平鎮真實事故）
-- ------------------------------------------------------------
-- 平鎮實際收到 5 件，店員在收貨畫面誤鍵成 2 → 庫存只入了 2。
-- 老闆用「✎ 修改實收」把數字改回 5，以為貨就回來了 —— **庫存還是 2**
-- （20260903000005 的定位是純紀錄，一筆 stock_movements 都不寫）。
-- 要讓架上數字對，還得再去「庫存總覽 → ＋新增庫存」補 3 件。
-- 現場的店員不會知道有第二步，也沒有任何畫面提醒他 ⇒ 帳實不符會一直累積。
--
-- 老闆裁示（2026-09-04）：
--   ①「往上改（新 > 舊）：差額自動補進店家庫存，要留痕、寫明是哪張單的實收更正。」
--   ②「往下改（新 < 舊）：先看店家現在的庫存扣不扣得動。夠就自動扣；
--      不夠（貨已經賣掉／被客人取走）就**大聲擋下來並講原因**。」
--   ③「⛔ 不准扣成負的，⛔ 不准靜默跳過。」
--
-- ⛔ 沒有動的部分（20260903000005 / 20260903000200 的定位原封不動）：
--   ⛔ 不碰 customer_orders / customer_order_items / 取貨閘門 / 到貨通知
--   ⛔ 不重跑配單、不清 backorder_at、不動單頭 status / received_at
--   ⛔ 不碰 RR- 內部單（ride-along）、不碰現貨池（_grow_internal_pool）
--   ⇒ 老闆 2026-09-03「跟會員端都要脫鉤」那條**仍然成立**：這次只多寫庫存異動，
--     客人的訂單狀態、到貨通知、配單決策一個都沒動。
--   ⚠️ 唯一的間接效果是取貨閘門的**實體側**守衛（on_hand − 已承諾未取，
--     20260818000010）會跟著真實庫存走 —— 補了貨就放行、扣了貨就擋住。
--     這正是它該有的行為（貨真的在／真的不在），不是副作用。
--
-- ------------------------------------------------------------
-- 二、庫存記在哪、用什麼 movement_type（沒有新增任何 type）
-- ------------------------------------------------------------
-- 補進去那筆：`transfer_in`，location = 收貨端 v_dest_location，欄位與收貨路徑
--   （rpc_receive_transfer 最新版 20260827000000:131-150）走的 rpc_inbound 一致
--   ⇒ 跟原路同一套帳。單價見「五、」。
-- 沖掉那筆：`reversal` + `reverses` 指回原入庫 —— 逐字比照
--   rpc_unreceive_transfer 最新版（20260903000010:185-198）⇒ 跟「退回收貨」同一種痕跡。
-- 兩個值都在 stock_movements 現行 CHECK 清單裡（最新清單 20260713000000:28-42）
-- ⇒ **本檔不需要動 stock_movements 的 CHECK，也沒有新增 movement_type。**
--
-- ⭐ 虛擬商品（MISC-01 之類）：整段庫存連動 no-op，判斷提在迴圈最上面。
--   🔴 2026-09-04 第二輪修正 —— 第一輪的做法（補那筆走 rpc_inbound、白吃它的
--     虛擬商品守衛）**有 bug**：立新被守衛擋掉回 NULL，沖舊卻是自己 INSERT、
--     照寫不誤 ⇒ 虛擬商品被**單向沖掉**，正好把 #902 修好的「只進不出」
--     倒過來再犯一次。現在改成整段跳過，進出都不寫。
--   代價是虛擬商品判斷式在本檔多了一份（與 rpc_inbound 20260903000100:56-64
--     同源，⛔ 那邊改要跟著改）。換到的是新入庫那筆能帶 source_doc_line_id
--     與 reason —— rpc_inbound 不吃這兩個參數，而 movement 是 append-only、
--     補不回來，給它加 DEFAULT 參數又會撞出 ambiguous 重載害全站入庫爆掉。
--     詳細取捨寫在「立新」那段的註解裡。
--
-- ------------------------------------------------------------
-- 三、為什麼是「沖舊立新」而不是「只補一筆差額」⭐ 本檔最關鍵的一段
-- ------------------------------------------------------------
-- 直覺做法是「改 2→5 就寫一筆 +3」。**那樣會弄壞「↩ 返回收貨配單」。**
-- rpc_unreceive_transfer（20260903000010:159-200）逐項沖銷時，
-- 沖的量取自 `in_movement_id` 指著的那筆異動本身（v_orig.quantity），
-- 不是 qty_received。所以只補差額的話：
--   • 2→5 之後取消收貨 → 它只沖回當初那 2 件，我補的 3 件憑空留在店裡（生貨）。
--   • 5→3 之後取消收貨 → 它要沖 5 件但店裡剩 3 件，撞上它的實體守衛
--     （20260903000010:180-183）整張單退不掉，訊息還會誤導成「貨被取走了」。
--
-- ⇒ 本檔改成：**沖掉舊的那筆入庫、用新實收量重開一筆**，並把 in_movement_id 指到新的。
--   由此建立一條不變式：
--
--       ⭐ in_movement_id 指著的異動，quantity 永遠 = 該列的 qty_received。
--
--   維持這條不變式，rpc_unreceive_transfer **一行都不用改**就永遠沖對量，
--   而且新開的那筆通過它的三項身分檢查（transfer_in / source_doc_type='transfer' /
--   source_doc_id 相符，20260903000010:162-167），舊的那筆已被我們 reverses 掉、
--   新的沒有 ⇒ 它的「已被沖銷過」守衛（:169-171）也不會誤擋。
--   ⛔ 誰要把這裡改回「只寫一筆差額」，請先讀完這一段。
--
-- 淨效果 = 新實收量 − 舊入庫量，跟「補差額」在正常情況下完全一樣
-- （收貨後直接改，舊入庫量 == 舊實收量）。
--
-- ⚠️ 唯一會不一樣的情況：**20260903000005 上線（2026-09-03）到本檔上線之間，
--   被「純紀錄」調整過的列** —— 那些列的 in_movement.quantity 已經 ≠ qty_received。
--   例：入庫真的入了 4、純紀錄把實收改成 1，今天再改成 2
--       → 庫存從 4 變成 2（−2），不是「1→2 所以 +1」。
--   這是**對的**（改完庫存 = 實收 = 2，帳實一致），但數字跟直覺不同，
--   所以回傳值與畫面把「實收變動」與「庫存變動」分開顯示，不讓人誤會。
--   上線前請先查有幾列是這種（查詢附在施工回報裡）。
--
-- ------------------------------------------------------------
-- 四、寫入順序：先立新、後沖舊（⛔ 不可對調）
-- ------------------------------------------------------------
-- stock_balances **沒有** on_hand >= 0 的 CHECK（20260422120003:30-41），
-- trg_apply_movement 也只是加減不擋負（:210-247）⇒ 負庫存只能靠呼叫端自己擋。
-- 先扣後補的話中間會短暫變負；先補後扣則中間值 = on_hand + 新實收量 ≥ 0 恆成立。
-- 再加上寫入前的淨額守衛（on_hand ≥ 舊入庫量 − 新實收量），
-- 帳面**任何一刻**都不會是負的。
--
-- ------------------------------------------------------------
-- 四之二、鎖：⛔ 只鎖自己這一邊等於沒鎖（2026-09-04 第二輪補，審查 P0）
-- ------------------------------------------------------------
-- 本檔讓「往下改實收」會真的扣庫存之後，扣庫存就有了**兩個入口**：
-- 取貨（rpc_record_pickup）與本函式。兩邊都是「先讀 on_hand 判斷夠不夠 →
-- 再寫異動」，中間沒有鎖，兩人同時做就會扣成負的：
--
--     [改實收] 讀 on_hand = 5，準備扣 3            ┐
--     [取 貨 ] 閘門讀 on_hand = 5，準備取 5        │ 兩邊都覺得自己夠
--     [改實收] 寫 −3 → on_hand = 2  (commit)      │
--     [取 貨 ] 寫 sale −5 → on_hand = **−3**  ⛔  ┘
--
-- ⇒ 扣庫存其實有**三個**入口（第三個是現場銷售，第二輪審查才抓到）：
--     ① 本檔        rpc_adjust_received_transfer  ✎ 修改實收
--     ② 20260904010010  rpc_record_pickup         取貨
--     ③ 20260904010020  rpc_create_walkin_sale    現場銷售（門市臨櫃結帳）
--   **三支必須一起在線上**，少任何一支，另外兩支的鎖都擋不住那一邊趁隙寫進來
--   （三支中任兩支的組合都湊得出上面那張圖）。
-- ⇒ 三支的鎖序都是「ORDER BY location_id, sku_id 去重後逐列 FOR UPDATE，
--   而且放在主迴圈之前」。順序不一致就會各拿一半互相等（死鎖）。
--   ⛔ 要改鎖序就三支一起改。
-- ⚠ 但三支的**性格不同**，⛔ 不要抄錯邊：
--     本檔與取貨 → 鎖完發現不夠就**大聲失敗**（貨不能憑空生出來給客人）
--     現場銷售   → 鎖完發現不夠就**多補一點照樣結帳**
--                 （客人站在櫃台前、貨一定會離開，擋下來只會讓帳跟現實脫節。
--                   老闆 2026-09-01 親自定的，見 20260904010020 檔頭【二】）
--
-- ------------------------------------------------------------
-- 四之三、成本口徑：avg_cost 要跟「只補差額」等價（第二輪補，審查 P1）
-- ------------------------------------------------------------
-- trg_apply_movement 只在 quantity > 0 時重算加權平均（20260422120003:230-237）。
-- 「沖舊立新」的立新那筆被完整加權一次、沖舊那筆一毛都沒退 ⇒ avg_cost 被多拉
-- 一次，而後續出庫是讀 avg_cost 當成本的（20260705000000:144-181）⇒ 會一路髒下去。
--
-- 修法：兩筆寫完後把 avg_cost 拉回「只補差額」該有的值 ——
--   目標價值 = 調整前價值 + (新實收 − 舊入庫) × 這批貨的單價
-- 單價優先取**原入庫那筆**的 unit_cost（這批貨實際入帳的價），沒有才退回出庫單價。
--
-- 驗收（寫死在程式碼註解裡當回歸基準）：原有 10 件 @$100、這批單價 $80，
--   「一次收 8」與「先收 5 再改成 8」**兩條路徑的最終 avg_cost 都必須 = 91.1111**。
--
-- ------------------------------------------------------------
-- 五、跟「短少處理」「撤銷」的互鎖 —— 查證後結論：既有守衛 B 已經夠，不加新的
-- ------------------------------------------------------------
-- 會不會「總倉已按同意退回把貨記回總倉，店家再往上改實收 ⇒ 貨變兩份」？
-- **不會**：守衛 B（本檔逐字保留）擋掉所有 shortage_resolution 非 NULL 的列。
-- 逐一查證（rpc_resolve_transfer_item_shortage 最新版 20260903000200:111-313）：
--   restock_hq / redispatch → 寫 rpc_inbound(...,'transfer_cancel') 記回出貨端 → 守衛 B 擋 ✅
--   reject_return           → 補回 qty_received（純紀錄）                → 守衛 B 擋 ✅
--   cancel_orders / vendor_claim / accept / replenish → 純標記            → 守衛 B 擋 ✅
--   over_ack（唯一放行的）  → rpc_ack_transfer_over（20260824020000:1600-1616）
--                             只 UPDATE 一個標記欄位，一筆庫存／金流都沒有 ✅
-- ⇒ 唯一能走到庫存那段的，是「總倉還沒處理」或「只按過多收知道了」的列，不可能雙算。
-- ⚠️ 但守衛 B 的份量因為本檔而**變重了**：以前它擋的是「帳對不上」，
--   現在它擋的是「貨會變兩份」。⛔ 誰想放寬它，先把上面這張表重跑一遍。
--
-- 撤銷（rpc_undo_transfer_item_shortage，20260903000200:429）之後再調整：
--   撤銷把 restock_hq/redispatch 記回**出貨端**的那筆沖掉、清空 shortage_* 欄位
--   ⇒ 該列回到未處理，守衛 B 放行。此時店家庫存從頭到尾沒被撤銷動過
--   （撤銷動的是出貨端），所以接著調整就是單純的「店家庫存 = 新實收量」⇒ 帳對 ✅
-- 調整完再處理短少：調整後那一列的 qty_received 是新值，
--   resolve 依 `qty_shipped - qty_received` 算短少量（20260903000200:158-161）
--   ⇒ 拿到的是更正後的數字 ⇒ 帳對 ✅
--
-- ------------------------------------------------------------
-- 基底版本
-- ------------------------------------------------------------
--   rpc_adjust_received_transfer ← **20260903000200:704**（第 2 版；共 2 版：
--     20260903000005 建立、20260903000200 改守衛 B 的錯誤訊息）。
--     ⚠️ 不是 20260903000005 —— 用標準查法確認：
--        git grep -nE "CREATE (OR REPLACE )?FUNCTION (public\.)?rpc_adjust_received_transfer" \
--          origin/main -- supabase/migrations | sort   → 最後一行是 20260903000200。
--     本檔為第 3 版：DECLARE 加變數、迴圈查詢多取三個欄位、迴圈裡插入庫存段、
--     UPDATE 多寫 in_movement_id、備註與回傳多帶庫存資訊。**其餘逐字保留。**
--   ⛔ 沒有動 rpc_receive_transfer / rpc_unreceive_transfer / rpc_inbound /
--     rpc_resolve_transfer_item_shortage / rpc_undo_transfer_item_shortage —— 一行都沒有。
--
-- 上線順序（⛔ 不可顛倒，完整說明見修復腳本檔頭）：
--   1️⃣ 本檔 → 2️⃣ 20260904010010 → 3️⃣ 20260904010020
--   → 4️⃣ 跑 D:\1人公司\公司\01_進行中\實收連動_修復不一致列_2026-09-04.sql
--        第 ① 段預覽 → 第 ② 段修復 → 第 ③ 段驗證
--   ⚠️ 第 4 步**不是選配**：純紀錄期間（20260903000005 起）留下的
--     「帳面實收 ≠ 實際入庫」歷史列，本檔開頭的 `CONTINUE WHEN new_qty = old_qty`
--     會直接跳過（比的是帳面實收），⇒ 老闆在畫面上重存同一個數字**不會有反應**，
--     那些列只有靠那支腳本才修得掉。
--
-- Rollback：
--   CREATE OR REPLACE 回 20260903000200:704 那一版（純紀錄）。
--   ⚠️ 本檔 / 20260904010010 / 20260904010020 **三支是一組**，要回就三支一起回；
--     只回一支等於把負庫存的洞留兩邊。
--   ⚠️ 已經寫下去的庫存異動是 append-only、不會自動回滾；要還原就對每一筆
--     開反向 manual_adjust。回滾前先撈：
--       SELECT * FROM stock_movements
--        WHERE source_doc_type = 'transfer' AND reason LIKE '實收更正 transfer=%';
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
  -- 20260904010000 庫存連動用
  -- %ROWTYPE 不是 RECORD：逐字比照 rpc_unreceive_transfer（20260903000010:42）。
  -- 差別在查無資料時 —— %ROWTYPE 的欄位結構永遠存在，v_orig.id 讀得到 NULL；
  -- 裸 RECORD 在第一次就查不到列時可能是「尚未指派」，底下的 IS NULL 檢查就接不住。
  v_orig            stock_movements%ROWTYPE;   -- 該列當初真的入過庫的那筆 transfer_in
  v_old_stock       NUMERIC;   -- ↑ 的數量（沒有入庫紀錄就是 0）
  v_need            NUMERIC;   -- 要淨扣的量（> 0 才要問庫存夠不夠）
  v_new_mov_id      BIGINT;
  v_line_delta      NUMERIC;   -- 這一列真正的庫存變動
  v_stock_delta     NUMERIC := 0;
  v_stock_changes   TEXT[] := '{}'::TEXT[];
  -- 2026-09-04 第二輪（審查 P0 / P1-1 / P2）新增
  v_lock            RECORD;    -- 預鎖用（鎖序與 20260904010010 一致）
  v_is_virtual      BOOLEAN;   -- 虛擬商品（MISC-01 之類）整段跳過
  v_unit_cost       NUMERIC;   -- 這批貨真正的入庫單價 = avg_cost 校正的基準
  v_onhand_before   NUMERIC;   -- 寫任何異動**之前**的 on_hand
  v_avg_before      NUMERIC;   -- 寫任何異動**之前**的 avg_cost
  v_onhand_after    NUMERIC;   -- 兩筆都寫完之後的 on_hand
  v_transfer_no     TEXT;      -- 給人看的單號（寫進新入庫異動的 reason）
  v_virtual_lines   INTEGER := 0;  -- 這次改到幾列是虛擬商品（不進庫存）
  -- 2026-09-04 第三輪（審查 P1-1）：成本為 0 的批次 ⇒ 均價校正跳過，⛔ 但不准靜默
  v_cost_skipped     BOOLEAN;             -- 這一列的均價校正跳過了嗎
  v_cost_warn        TEXT;                -- ↑ 掛在兩筆異動 reason 尾巴的警語
  v_cost_warn_lines  INTEGER := 0;        -- 這次總共幾列是這種情況
  v_cost_warn_labels TEXT[] := '{}'::TEXT[];   -- 是哪幾樣商品（回傳給前端 / 寫進備註）
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  IF p_lines IS NULL
     OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '沒有要調整的品項';
  END IF;

  -- 2026-09-04 第二輪：多取 transfer_no —— 新寫的那筆入庫異動 reason 要給人看，
  -- 而人看得懂的是單號，不是 transfer 的內部 id。
  SELECT tenant_id, status, transfer_type, dest_location, shipped_at, notes, transfer_no
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_shipped_at, v_existing_notes,
         v_transfer_no
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

  -- ==========================================================================
  -- 預鎖（2026-09-04 第二輪補；配 20260904010010）
  --   把這次會碰到的 (location_id, sku_id) 去重、**排序後**逐列鎖起來。
  --   ⛔ ORDER BY location_id, sku_id 這個順序與 20260904010010（取貨扣庫存）
  --     完全一致 —— 兩支都會鎖到同一批餘額列，各用各的順序就會各拿一半、
  --     互相等到天亮（死鎖）。只改一邊等於沒改。
  --   ⚠ 放在主迴圈**之前**：主迴圈的 FOR UPDATE OF ti 會鎖 transfer_items，
  --     先鎖 stock_balances 再鎖 transfer_items，順序與取貨那支
  --     （stock_balances → customer_order_items）同向，兩支不會反向交錯。
  --   餘額列不存在時鎖不到東西 —— 那代表 on_hand 視同 0，守衛 D 一樣擋得住。
  -- ==========================================================================
  FOR v_lock IN
    SELECT DISTINCT v_dest_location AS location_id, ti.sku_id
      FROM jsonb_array_elements(p_lines) AS l
      JOIN transfer_items ti
        ON ti.id = (l->>'transfer_item_id')::BIGINT
       AND ti.transfer_id = p_transfer_id
     WHERE ti.sku_id IS NOT NULL
     ORDER BY 1, 2
  LOOP
    PERFORM 1
       FROM stock_balances
      WHERE tenant_id   = v_tenant_id
        AND location_id = v_lock.location_id
        AND sku_id      = v_lock.sku_id
      FOR UPDATE;
  END LOOP;

  FOR v_line IN
    -- 20260904010000：多取 sku_id / in_movement_id / out_cost 三個欄位給庫存段用。
    -- out_cost 的取法逐字比照收貨路徑（20260827000000:101-105）：
    -- LEFT JOIN 出庫那筆異動拿 unit_cost，補進去的那筆才跟原路同一個單價口徑。
    -- FOR UPDATE OF ti 只鎖 transfer_items，多一個 LEFT JOIN 不影響（同 skus 那個）。
    SELECT ti.id,
           ti.sku_id,
           ti.in_movement_id,
           om.unit_cost                          AS out_cost,
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
      LEFT JOIN stock_movements om ON om.id = ti.out_movement_id
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
    -- ⚠️ 20260904010000：這道守衛的份量變重了。以前放行只會讓帳面對不上，
    --   現在放行會讓**貨變兩份**（總倉已把短少的貨記回出貨端，這裡又補進店家庫存）。
    --   ⛔ 要放寬它之前，先重跑本檔檔頭「五、」那張逐一查證表。
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

    -- ============================================================
    -- 守衛 D ＋ 庫存連動（20260904010000 新增；本檔唯一新增的行為）
    --   ⛔ 這裡以前寫的是「刻意什麼庫存都不寫」。老闆 2026-09-04 裁示改掉，
    --     理由與完整推導見本檔檔頭「一、」「三、」「四、」。
    -- ============================================================
    v_new_mov_id := v_line.in_movement_id;   -- 沒進到底下的 swap 就維持原狀
    v_old_stock  := 0;
    -- ⚠ 每一圈都要重置：v_orig 是 %ROWTYPE 變數，這一圈若沒有 in_movement_id
    --   就**不會**執行底下那個 SELECT INTO，殘值會原封不動留到這一圈被讀到
    --   （寫 reason 時要拿 v_orig.id 判斷「原本有沒有入庫紀錄」，讀到上一圈的
    --   id 會寫出一句看起來很具體、其實指著別的品項的鬼話）。
    v_orig       := NULL;

    -- ------------------------------------------------------------------
    -- 虛擬商品：整段庫存連動一律 no-op（2026-09-04 第二輪補）
    --
    -- 🔴 這修掉的是第一輪的一個真 bug（審查沒抓到，我自己複查時發現）：
    --   第一輪「立新」走 rpc_inbound（虛擬 SKU 回 NULL、什麼都不寫），
    --   但「沖舊」是自己 INSERT、**照寫不誤** ⇒ 虛擬商品會被**單向沖掉**
    --   （只出不進），正好把 #902 修好的「只進不出」倒過來再犯一次，
    --   而且會把 MISC-01 的 on_hand 一路扣成負的。
    --
    -- 判斷式與 rpc_inbound（20260903000100:56-64）同源。
    -- ⛔ 那邊改了虛擬商品的規則，這裡要跟著改。
    -- （沒有直接沿用 rpc_inbound 的守衛，是因為它不吃 reason /
    --   source_doc_line_id —— 見下面「立新」那段的說明。）
    SELECT EXISTS (
      SELECT 1 FROM skus s JOIN products p ON p.id = s.product_id
       WHERE s.id = v_line.sku_id AND p.is_virtual
    ) INTO v_is_virtual;
    IF v_is_virtual THEN
      -- 回傳給前端：庫存 0 變動有兩種原因（「本來就一樣」vs「這商品不進庫存」），
      -- 畫面要講對，不然改了自由轉貨的實收會看到一句對不上的解釋。
      v_virtual_lines := v_virtual_lines + 1;
    END IF;
    -- ------------------------------------------------------------------

    IF v_line.in_movement_id IS NOT NULL AND NOT v_is_virtual THEN
      SELECT * INTO v_orig FROM stock_movements WHERE id = v_line.in_movement_id;
      -- 身分檢查：三項條件逐字取自 rpc_unreceive_transfer（20260903000010:162-167）。
      -- 指到別張單的異動就不是我們有資格沖的，寧可擋下來也不要亂動別人的庫存。
      -- （SELECT INTO 查無資料時整個 record 會是 NULL ⇒ v_orig.id IS NULL 接得住，
      --   不會讀到上一圈的殘值。）
      IF v_orig.id IS NULL
         OR v_orig.movement_type <> 'transfer_in'
         OR v_orig.source_doc_type <> 'transfer'
         OR v_orig.source_doc_id <> p_transfer_id THEN
        RAISE EXCEPTION '「%」的入庫紀錄（異動 %）不是這張調撥單入的庫，系統不敢動它的庫存。請聯繫總倉人工處理。',
          v_label, v_line.in_movement_id;
      END IF;
      IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
        RAISE EXCEPTION '「%」的入庫紀錄（異動 %）已經被沖銷過，不能再改實收。請用「↩ 返回收貨配單」整張重來。',
          v_label, v_orig.id;
      END IF;
      v_old_stock := v_orig.quantity;
    END IF;

    -- 庫存本來就等於新實收量 → 什麼都不寫（不留兩筆互相抵銷的異動），
    -- 而且 in_movement_id 維持指著它，不變式照樣成立。
    -- 虛擬商品（本迴圈最上面查過）連沖舊都不寫，整段跳過。
    IF NOT v_is_virtual AND v_old_stock <> v_line.new_qty THEN

      -- ------------------------------------------------------------------
      -- 這批貨真正的入庫單價 —— 也是下面 avg_cost 校正的基準（P1-1）
      --   優先用**原入庫那筆**的 unit_cost：那就是這批貨當初實際入帳的價，
      --   比出庫那筆更貼近「這批貨值多少」。原入庫不存在或沒有單價時
      --   （純紀錄期間沒有 in_movement_id、或早期資料）才退回出庫單價 ——
      --   那是收貨路徑（20260827000000:101-105）本來就在用的口徑。
      -- ------------------------------------------------------------------
      v_unit_cost := COALESCE(NULLIF(v_orig.unit_cost, 0),
                              ABS(NULLIF(v_line.out_cost, 0)),
                              0);

      -- ------------------------------------------------------------------
      -- 成本為 0 的批次：均價校正會跳過 —— ⛔ 但不准靜默（2026-09-04 第三輪，審查 P1-1）
      --
      -- 【什麼時候會發生】v_unit_cost 只有在「原入庫那筆的 unit_cost 是 0 或 NULL」
      --   **而且**「出庫那筆的 unit_cost 也是 0 或 NULL」時才會是 0。實務上是：
      --     · 該列在純紀錄期間（20260903000005 起）被改過、沒有 in_movement_id
      --       可沿用，而它的出庫異動又是早期沒帶成本的資料
      --     · 這商品在出貨端本來就沒有成本（從沒進過貨、成本從沒建過）
      --   ⇒ 正常收貨路徑走 rpc_inbound 一定帶成本。這是**邊界情況、不是常態**。
      --
      -- 【為什麼是「跳過校正」而不是「照公式算」】
      --   trigger（20260422120003:232-237）對 unit_cost = 0 的入庫**刻意不重算**
      --   avg_cost —— 0 被當成「成本未知」，不拿去稀釋均價。於是：
      --     路徑一 一次收 8 件 @0        → avg_cost 不動
      --     路徑二 先收 5 @0、再改成 8   → 立新 +8@0 不重算、沖舊 −5 也不重算
      --                                   → avg_cost 也不動
      --   **兩條路徑本來就一致（都是「不動」）**。這時候硬套本檔的校正公式
      --   反而會讓兩條路徑分岔：審查舉例的 1,000 ÷ 13 = 76.9231 是「改實收」
      --   這條路獨有的數字，「一次收 8」永遠算不出它。⇒ 跳過才是對的。
      --
      -- 【但它確實留下一個問題，所以要大聲】
      --   avg_cost 沒動 ⇒ 這批 0 成本的貨是用**店裡原本的均價**在計價，庫存價值
      --   偏高（後續出庫的 COGS 也是）。這不是本檔造成的（trigger 對「0 成本入庫」
      --   一直都這樣），但本檔多寫了兩筆異動，不講清楚，事後查帳會以為是這次調整
      --   弄出來的。⇒ 兩筆異動的 reason 掛警語、單頭備註寫一句、回傳 JSON 帶旗標。
      --   ⛔ 不 RAISE：擋下來會讓老闆連數量都改不了，而數量那部分完全正確。
      --     老闆 2026-09-04「不准靜默跳過」要的是**看得見**，不是**做不了**。
      --
      -- ⚠ 還有一種更窄的偏差，本段管不到、也不打算管：原入庫成本是 0、但出庫那筆
      --   有成本時，v_unit_cost 會取到出庫價 ⇒ 校正照跑，可是當初那筆 0 成本入庫
      --   從沒稀釋過均價 ⇒ 校正後的值仍與「一次收足」不同。那個差是**歷史那筆
      --   0 成本入庫**留下的，要修得回頭改歷史，超出本案範圍。若真的碰上，
      --   走「庫存總覽 → 盤點」重估比在這裡硬算安全。
      --
      --   【為什麼不在畫面上標它】（2026-09-04 第四輪，審查 P2，⛔ 這是刻意的決定）
      --     1. 標了老闆也**沒辦法在這個畫面上處理它** —— 要修得走「庫存總覽 → 盤點」
      --        重估。收貨畫面多一個看不懂又按不掉的紅字，只會讓人開始忽略紅字，
      --        連上面那個「原批成本為 0」的真警語都跟著被略過。
      --     2. 它**不是這次調整造成的**，是歷史那筆 0 成本入庫留下的。掛在
      --        「✎ 修改實收」的結果上，反而會讓事後查帳的人以為是這次弄出來的。
      --     3. 數量完全正確，差的只有庫存金額；真正會看到它的人是查庫存價值的時候，
      --        那個入口本來就不是收貨畫面。
      --     ⇒ 改成「**看得到有幾列**」而不是「每列都跳警語」：修復腳本第 ①／①-2 段
      --       各加了一欄（成本備註 ／ 均價校正後仍略有出入），老闆上線前一定會跑那段。
      --   ⚠ 這個偏差要成立，得「原入庫寫 0 成本、同一批的出庫卻有成本」。現行收貨路徑
      --     的入庫成本是從出庫那筆帶過來的（20260827000000:101-105），兩邊不會這樣打架
      --     ⇒ 推斷**是歷史資料才有、上線後不會再長**。⛔ 但我沒有連資料庫查過實際
      --     有幾列，這是照程式邏輯推的 —— 請以修復腳本 ①-2 跑出來的數字為準。
      -- ------------------------------------------------------------------
      v_cost_skipped := (v_old_stock > 0 AND v_unit_cost = 0);
      v_cost_warn    := CASE WHEN v_cost_skipped
                             THEN '｜⚠ 原批成本為 0，均價未校正'
                             ELSE '' END;
      IF v_cost_skipped THEN
        v_cost_warn_lines  := v_cost_warn_lines + 1;
        v_cost_warn_labels := v_cost_warn_labels || v_label;
      END IF;

      -- 寫任何異動**之前**先把餘額記下來（avg_cost 校正要用）。
      -- 這一列在函式開頭的預鎖段就已經鎖住了，這裡再 FOR UPDATE 是同一把鎖，
      -- 讀到的值別人動不了。
      SELECT on_hand, avg_cost INTO v_onhand_before, v_avg_before
        FROM stock_balances
       WHERE tenant_id   = v_tenant_id
         AND location_id = v_dest_location
         AND sku_id      = v_line.sku_id
       FOR UPDATE;
      v_onhand_before := COALESCE(v_onhand_before, 0);
      v_avg_before    := COALESCE(v_avg_before, 0);

      -- 守衛 D：往下扣之前先問店裡夠不夠。⛔ 不夠一律擋下、不扣成負的、不靜默跳過。
      v_need := v_old_stock - v_line.new_qty;   -- > 0 代表這一列要淨扣
      IF v_need > 0 AND v_onhand_before < v_need THEN
        RAISE EXCEPTION
          '「%」改小要從店裡扣回 % 件，但店裡現在只有 % 件 —— 這批貨可能已經賣掉或被客人取走了。這次調整**整批都沒有存檔**。請先確認實際數量：真的少了就走「庫存總覽 → 盤點」，或請總倉在收件匣處理。',
          v_label, trim_scale(v_need), trim_scale(v_onhand_before);
      END IF;

      -- ① 先立新（+ 新實收量）
      -- ② 後沖舊（− 舊入庫量）
      -- ⛔ 順序不可對調：先扣後補中間會出現負庫存（檔頭「四、」）。
      v_new_mov_id := NULL;
      IF v_line.new_qty > 0 THEN
        -- 欄位與收貨路徑（rpc_receive_transfer 最新版 20260827000000:131-150）
        -- 走的 rpc_inbound 完全一致：同 'transfer_in'、同 source_doc、
        -- 同 v_dest_location ⇒ 補進去的貨跟原本收貨那批走同一套帳。
        --
        -- ⭐ 為什麼是自己 INSERT，而不是呼叫 rpc_inbound（第一輪的做法，本輪改掉）：
        --   rpc_inbound 的參數只到 source_doc_id，**不吃 source_doc_line_id、
        --   也不吃 reason**。少了這兩個，「舊入庫量 0 → 新實收 > 0」那條路
        --   （純紀錄期間調過、或本來就實收 0）寫出來的異動只留得下 transfer
        --   層級的痕跡，事後查不出「哪一列、為什麼多這些貨」。
        --   而這條路又補不回來：
        --     · stock_movements 是 append-only（trg_no_update_mov，
        --       20260422120003:259-270 無條件 RAISE）⇒ 寫完再補 reason 不可能
        --     · 給 rpc_inbound 加 DEFAULT 參數會多出一支 11 參數的重載，
        --       跟現有 9 參數版撞成 ambiguous ⇒ **全站入庫一起爆**，⛔ 不能做
        --   ⇒ 只剩自己 INSERT。代價是虛擬商品守衛要自己判一次，已經提到本迴圈
        --     最上面（v_is_virtual），並註明與 rpc_inbound 同源、那邊改要跟著改。
        INSERT INTO stock_movements (
          tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
          source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
        ) VALUES (
          v_tenant_id, v_dest_location, v_line.sku_id,
          v_line.new_qty, v_unit_cost, 'transfer_in',
          'transfer', p_transfer_id, v_line.id,
          -- 尾巴的 v_cost_warn：原批成本為 0 時掛「⚠ 原批成本為 0，均價未校正」，
          -- 否則是空字串。⛔ 不准拿掉 —— 那是這種列唯一看得見的訊號（P1-1）。
          format('實收更正（調撥單 %s／品項 #%s）：實收由 %s 改為 %s，本筆是改後重記的入庫%s%s%s',
                 COALESCE(v_transfer_no, '#' || p_transfer_id::TEXT), v_line.id,
                 trim_scale(v_line.old_qty), trim_scale(v_line.new_qty),
                 COALESCE('，沖銷原入庫 movement ' || v_orig.id::TEXT, '（原本沒有入庫紀錄）'),
                 COALESCE('；' || NULLIF(TRIM(p_notes), ''), ''),
                 v_cost_warn),
          p_operator
        ) RETURNING id INTO v_new_mov_id;
      END IF;

      IF v_old_stock > 0 THEN
        -- 寫法逐字比照 rpc_unreceive_transfer（20260903000010:185-198）：
        -- 'reversal' + reverses 指回原入庫 ⇒ 稽核上跟「退回收貨」同一種痕跡，
        -- 而且原入庫被 reverses 佔掉之後不會再被沖第二次。
        -- reason 就是老闆要的留痕：哪張單、哪一列、實收從幾改到幾、改由哪筆重記。
        INSERT INTO stock_movements (
          tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
          source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
        ) VALUES (
          v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
          -v_orig.quantity, v_orig.unit_cost, 'reversal',
          'transfer', p_transfer_id, v_line.id, v_orig.id,
          format('實收更正 transfer=%s item=%s：實收 %s → %s（沖銷入庫 movement %s，改由 movement %s 重記）%s%s',
                 p_transfer_id, v_line.id,
                 trim_scale(v_line.old_qty), trim_scale(v_line.new_qty), v_orig.id,
                 COALESCE(v_new_mov_id::TEXT, '無（實收改成 0）'),
                 COALESCE('：' || NULLIF(TRIM(p_notes), ''), ''),
                 v_cost_warn),   -- 同上：原批成本為 0 時的警語，⛔ 不准拿掉
          p_operator
        );
      END IF;

      -- ==================================================================
      -- avg_cost 校正（2026-09-04 第二輪，審查 P1-1）
      --
      -- 【問題】trg_apply_movement（20260422120003:230-237）只在 quantity > 0
      --   時重算加權平均。「沖舊立新」寫的是 +新實收 與 −舊入庫 兩筆，於是
      --   **立新那筆被完整加權了一次、沖舊那筆一毛都沒退回去** ⇒ avg_cost 被
      --   這批貨的成本多拉一次。這不只是看起來不準：後續出庫是讀 avg_cost 當
      --   成本的（20260705000000:144-181），會一路髒下去。
      --
      -- 【正解】這次調整對庫存價值的真正影響 = 淨變動量 × 這批貨的單價，
      --   跟「只補一筆差額」完全一樣。所以兩筆寫完後把 avg_cost 拉回該有的值：
      --       目標庫存價值 = 調整前價值 + (新實收 − 舊入庫) × 單價
      --       目標 avg_cost = 目標庫存價值 ÷ 調整後 on_hand
      --
      -- 【驗收基準（審查給的數字，寫死在這裡當回歸依據）】
      --   店裡原有 10 件、avg_cost $100（價值 $1,000），這批貨單價 $80：
      --
      --     路徑一「一次就收 8 件」
      --       +8@80 → avg = (1,000 + 8×80) ÷ 18 = 1,640 ÷ 18 = 91.1111
      --
      --     路徑二「先收 5 件、再用『✎ 修改實收』改成 8」
      --       收 5    → avg = (1,000 + 5×80) ÷ 15 = 1,400 ÷ 15 = 93.3333
      --       改 5→8  → 兩筆寫完後 trigger 會算成 88.6956  ⛔ 錯
      --                 本段校正：目標價值 = 1,400 + (8−5)×80 = 1,640
      --                           目標 avg  = 1,640 ÷ 18       = 91.1111  ✅
      --
      --   ⇒ **兩條路徑的最終 avg_cost 都必須是 91.1111**，這就是本段的驗收條件。
      --   （avg_cost 是 NUMERIC(18,4)，讀回來的 93.3333 已經是四捨五入過的值，
      --     所以實際算出來是 1,639.9995 ÷ 18 = 91.11108…，存回去仍是 91.1111。
      --     這種尾差是 trigger 本來就有的近似，不是本段引入的。）
      --
      -- 【為什麼是直接 UPDATE stock_balances】
      --   全庫目前只有 trigger 一處寫這張表，本段是**第二處** —— 這件事我清楚，
      --   而且是找不到更輕的做法才這樣做：
      --     · 只寫一筆差額 → 弄壞 rpc_unreceive_transfer（檔頭「三、」已論證）
      --     · 把「補償單價」塞進立新那筆讓 trigger 自己算對 → 那個假單價會進
      --       stock_movements.unit_cost，污染成本稽核，比 avg_cost 偏差更糟
      --     · movement 是 append-only，寫完不能回頭改
      --   ⚠ 只碰 avg_cost 一個欄位，on_hand 仍然完全由 trigger 維護。
      --   ⚠ 該列此刻被預鎖與上面的 FOR UPDATE 鎖著，讀寫都在鎖的保護內。
      -- ==================================================================
      -- ⚠ 這個條件與上面 v_cost_skipped 是同一件事的兩面：
      --     v_old_stock > 0 AND v_unit_cost = 0  → v_cost_skipped，跳過校正並留痕
      --     v_old_stock > 0 AND v_unit_cost > 0  → 就是下面這個 IF，正常校正
      --   ⛔ 要改其中一個，另一個要一起改，否則會變成「跳過了卻沒留痕」。
      IF v_old_stock > 0 AND v_unit_cost > 0 THEN
        -- 舊入庫量 = 0 時沒有「沖舊」那筆，trigger 算的本來就是對的，不必校正。
        SELECT on_hand INTO v_onhand_after
          FROM stock_balances
         WHERE tenant_id   = v_tenant_id
           AND location_id = v_dest_location
           AND sku_id      = v_line.sku_id;

        -- on_hand <= 0 就不動 avg_cost，與 trigger 同一個口徑
        -- （20260422120003:234 也是 (on_hand + quantity) > 0 才重算）。
        IF COALESCE(v_onhand_after, 0) > 0 THEN
          UPDATE stock_balances
             SET avg_cost   = GREATEST(
                   (v_onhand_before * v_avg_before
                    + (v_line.new_qty - v_old_stock) * v_unit_cost) / v_onhand_after,
                   0),
                 updated_at = NOW()
           WHERE tenant_id   = v_tenant_id
             AND location_id = v_dest_location
             AND sku_id      = v_line.sku_id;
        END IF;
      END IF;

      -- 真正落地的庫存變動。（虛擬商品在本迴圈最上面就整段跳過了，走不到這裡。）
      v_line_delta := v_line.new_qty - v_old_stock;
      IF v_line_delta <> 0 THEN
        v_stock_delta   := v_stock_delta + v_line_delta;
        v_stock_changes := v_stock_changes
                           || format('%s %s%s', v_label,
                                     CASE WHEN v_line_delta > 0 THEN '+' ELSE '' END,
                                     trim_scale(v_line_delta));
      END IF;
    END IF;

    UPDATE transfer_items
       SET qty_received = v_line.new_qty,
           -- 20260904010000：in_movement_id 跟著改指到重記的那筆
           -- ⇒ 維持「它的 quantity 永遠 = qty_received」的不變式（檔頭「三、」）。
           in_movement_id = v_new_mov_id,
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
  -- 20260904010000：多寫一段庫存同步結果 —— 店家與總倉都要看得到貨到底動了沒有。
  v_log := format('實收調整（%s）：%s',
                  to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'MM/DD HH24:MI'),
                  array_to_string(v_changes, '、'))
           || CASE WHEN array_length(v_stock_changes, 1) IS NULL
                   THEN '｜庫存未變動'
                   ELSE '｜庫存同步：' || array_to_string(v_stock_changes, '、') END
           -- P1-1 留痕：成本為 0 的批次數量照調，但均價沒有校正。寫進單頭是因為
           -- stock_movements.reason 埋得太深，總倉收件匣看得到的只有這裡。
           || CASE WHEN v_cost_warn_lines = 0 THEN ''
                   ELSE '｜⚠ ' || array_to_string(v_cost_warn_labels, '、')
                        || ' 原批成本為 0，數量已更正、均價未校正（庫存價值偏高，'
                        || '要修請走「庫存總覽 → 盤點」重估）' END
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
    -- 20260904010000：庫存實際動了多少，另外回報。
    -- ⚠️ 跟 qty_delta 不一定相等 —— 20260903000005 純紀錄期間被調過的列，
    --   入庫量早就 ≠ 實收量，這次會一次校正回來（檔頭「三、」最後一段）。
    --   前端偵測到兩者不同時要分開講清楚，不要只報一個數字。
    'stock_delta',    v_stock_delta,
    'stock_note',     CASE WHEN array_length(v_stock_changes, 1) IS NULL
                           THEN NULL ELSE array_to_string(v_stock_changes, '、') END,
    -- 這次改到的列裡，有幾列是虛擬商品（自由轉貨的 MISC-01 之類，不進庫存）。
    -- 給前端分辨「庫存 0 變動」的兩種原因用：本來就一樣 vs 這商品不進庫存。
    'virtual_lines',  v_virtual_lines,
    -- P1-1（2026-09-04 第三輪）：這次有幾列因為「原批成本為 0」而**沒有校正均價**。
    -- 數量是照做的，只有均價那一段跳過。> 0 時前端要把 note 那句顯示出來
    -- ⛔ 不要吞掉 —— 這是這種列唯一會浮到畫面上的訊號。
    'avg_cost_uncorrected',      v_cost_warn_lines,
    'avg_cost_uncorrected_note', CASE WHEN v_cost_warn_lines = 0 THEN NULL
                                      ELSE array_to_string(v_cost_warn_labels, '、')
                                           || ' 原批成本為 0，數量已更正、均價未校正' END,
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
  '已收貨調撥單的實收數量再調整（2026-09-03 建立，20260904010000 起**會連動店家庫存**）：'
  '改 qty_received，並把該列的入庫異動沖舊立新，使 in_movement_id 指著的異動'
  'quantity 永遠 = qty_received ⇒ rpc_unreceive_transfer 沖得回正確的量。'
  '往上改自動補庫存（transfer_in，同收貨路徑）；往下改先檢查 on_hand，'
  '不夠就整批擋下（守衛 D）⛔ 不扣成負的、不靜默跳過。'
  '沖舊立新會讓 trigger 多加權一次成本，所以函式內手動把 avg_cost 校正回'
  '「等同一次收足」的值；原批成本為 0 時**刻意不校正**（trigger 對 0 成本入庫'
  '本來就不重算，硬校正反而讓兩條路徑分岔），改成大聲留痕：'
  '兩筆異動 reason 掛警語、單頭備註寫一句、回傳 avg_cost_uncorrected(_note)。'
  '仍**不碰**訂單／取貨閘門／配單／現貨池（老闆 2026-09-03「跟會員端脫鉤」）。'
  '少收／多收沿用 v_hq_exceptions 既有流程（總倉收件匣 → 同意退回 → 20260901000010 沖帳單），'
  '月結量因 GREATEST(派出, 實收) 自動跟著走。連帶依賴 20260903000010。';

GRANT EXECUTE ON FUNCTION public.rpc_adjust_received_transfer(BIGINT, JSONB, UUID, TEXT)
  TO authenticated, service_role;

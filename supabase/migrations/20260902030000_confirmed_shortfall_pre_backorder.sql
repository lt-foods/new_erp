-- ============================================================
-- 2026-09-02：確定短少 → 提前標待補貨（選項二 · 尾端標記）
--
-- 老闆 9/1（PO2608211561 情境）：「早知道只到 10、3 個確定不會來，店家會要求
--   立刻通知客人 —— 結果什麼都不能做，要等貨到。」
--
-- ⛔⛔ 本檔**刻意不碰配貨引擎**（rpc_allocate_shortage / rpc_get_allocation_candidates，
--   Alex 8/24～8/26 的地盤）。原因見 2026-09-02 施工回報第二節，一句話：
--   「確定短少」是**廠商→總倉**那一段的事實，配貨引擎的 in_transit 是
--   **總倉→店家**已裝上車的量（transfer_items.qty_shipped）。兩者不同段，
--   相減會把店家本來配得到的量憑空砍掉。而且貨沒到總倉時建不出撿貨波次
--   （20260816000050:366-372 後端硬擋），配貨視窗根本開不起來。
--
-- 做法：總倉在採購單上記「這 N 件確定不會到」→ 直接把該 SKU **最晚下單的 N 件**
--   標成待補貨（backorder_at）→ 取貨閘門第 1 關擋住、客人端立刻進「待到貨」桶
--   → 總倉再按「取消待補貨並通知」結案。全程不建派貨單、不動庫存。
--
-- 基底（開工當天用標準查法重驗，2026-09-02）：
--   rpc_cancel_backorder_items ← 20260808000000_close_order_when_remaining_items_stockout.sql:322
--   （查法 git grep -lE "FUNCTION (public\.)?rpc_cancel_backorder_items" HEAD -- supabase/migrations | sort | tail -1）
--   本檔第 5 段是該版**逐字保留**，只加：v_coi_ids / v_notified 宣告、
--   第一段 UPDATE 改成 CTE + RETURNING（為了只通知本次真的取消的那幾筆）、
--   通知區塊、回傳多一個 notified 欄位、COMMENT。其餘一字未動。
--
-- 抄用（⛔ 不自己重寫，重寫必失準）：
--   權限守衛     ← rpc_create_stocktake 20260615000040:72-82（見決定（5））
--   拆行含折扣分攤 ← rpc_allocate_shortage 20260824040000:269-299
--   併行還原     ← rpc_unassign_stock_from_order_item 20260825020000:698-735（見決定（3））
--   排序三鍵     ← _settle_arrived_backorders 20260811000050:258（本檔倒轉成 DESC）
--   採購品項→團→客人單 ← _stockout_po_items 20260812000000:296-300
--   通知寫法     ← _stockout_po_items 20260812000000:381-396
--
-- ⚠️ 設計決定（每一個都有非這樣不可的理由，改之前先讀）：
--
-- （1）**confirmed_shortfall 不加 CHECK 約束。**
--   直覺會想寫 CHECK (confirmed_shortfall <= qty_ordered - qty_received)。
--   ⛔ 不可以：CHECK 是**整列**約束，收貨把 qty_received 加上去時它也會被檢查。
--   已填 3、後來又多到貨讓未收量掉到 2 → **收貨會被這道 CHECK 擋下來整個失敗**。
--   守衛一律寫在 RPC 裡（只在「填」的時候檢查），不寫進資料表。
--
-- （2）**backorder_source / backorder_split_parent_id 用 trigger 保證失效，不逐支改函式。**
--   全 repo 有 **25 處**會把 backorder_at 設回 NULL（散在 20 支 migration，
--   大半是 Alex 的）。逐支去補「順便清旗標」＝改 20 支別人的函式，
--   而且漏一支就會留下假標記（畫面說「總倉確認不會到」但其實是引擎標的）。
--   ⇒ 一支 BEFORE trigger 保證「backorder_at 是 NULL ⇒ 兩個旗標也是 NULL」。
--
-- （3）🔴🔴 **改 N 之前先把上次拆出來的行「併回母行」——這是折扣複利誤差的根治法。**
--   （2026-09-02 阿審 P0-3；本節的手算請連同驗收標準一起保留）
--
--   ⚠️ 病灶：拆行的折扣是 `disc - round(disc * v_alloc / qty)`。
--     對**已經拆過、折扣已經是四捨五入結果**的殘行再拆一次 ＝ 對圓過的數再圓一次。
--
--   **驗收例（阿審給的，兩條路徑客人留存折扣必須一字不差）：訂 5 件、折扣 7 元**
--
--   ┌ 路徑乙（直接標 N=4）
--   │ v_take=4 → v_alloc = 5-4 = 1
--   │ v_new_disc = 7 - round(7×1/5) = 7 - round(1.4) = 7 - 1 = 6   → 待補行 qty4 disc6
--   │ 原行 qty1、disc = 7 - 6 = 1                                   → **客人留 1 件、折扣 1 元**
--   └
--   ┌ 路徑甲（先標 N=3，再改成 N=4）
--   │ 【N=3】v_alloc = 5-3 = 2
--   │        v_new_disc = 7 - round(7×2/5) = 7 - round(2.8) = 7 - 3 = 4 → 子行 qty3 disc4
--   │        母行 qty2、disc = 7 - 4 = 3
--   │ 【改 N=4，修好後】先清除 → 子行還活著且有 parent → **併回母行**：
--   │        母行 qty = 2+3 = 5、disc = 3+4 = 7，子行刪除
--   │        ⇒ 狀態與「從沒標過」**逐位元相同**
--   │ 【再標 N=4】走的就是路徑乙那三行             → **客人留 1 件、折扣 1 元** ✅
--   └
--   ❌ 修好之前（阿審實際驗算）：路徑甲會得到「客人留 1 件、折扣 **2** 元」——
--      與路徑乙差 1 元。⇒ **兩條路徑相同 N 卻收不同的錢。**
--
--   ⭐ 為什麼併回去而不是「改用原始基準重算」：併回去之後狀態**真的**回到原點，
--     兩條路徑之後跑的是同一段程式碼，相等是**結構上保證**的，不必靠再算一次對答案。
--   ⭐ 併行的條件與作法**逐項比照 Alex 自己的 rpc_unassign_stock_from_order_item
--     （20260825020000:698-735）**：被動過的、已取消的、被 backorders 那兩條
--     NO ACTION 外鍵引用到的、被未釋放減抵單引用到的，**一律不併**（留著比刪失敗好）。
--     差別只有「怎麼認出子行」：他用 notes 字串比對，本檔用專屬欄位
--     backorder_split_parent_id ——字串比對會被人改備註弄壞，欄位不會。
--
--   ⚠️ **併不回去時**（子行已被取消／被外鍵引用／母行已不在）：不強行還原，
--     照現值按比例拆。此時兩條路徑的**分配**會不同，但**總額恆等**（見決定（4）），
--     而且那是真的發生過的歷史（有人被取消了），不是誤差。
--
-- （4）**已取消的行：不可變、且計入「短少已成立」額度。**（老闆規則）
--   取消並通知之後，那幾行 status='cancelled' 但 backorder_at / source 都留著
--   （rpc_cancel_backorder_items 不碰這兩欄）⇒ 是這筆短少的歷史憑證。
--   - 清除**不碰它們**（阿審 P1-5）：把 source 清掉會讓「這位是總倉判定短少取消的」消失。
--   - 重標時它們**算進 N**：已經取消 3 件、N 改成 4 ⇒ 只需要再標 1 件。
--   ⇒ 恆等式：**已取消件數 ＋ 目前待補件數 ＋ 未標到(unmet) ＝ N**
--
-- （5）**權限：抄 rpc_create_stocktake 的寫法，但比它更嚴。**
--   house pattern（20260615000040:72-82）＝
--     v_tenant := public._current_tenant_id();  ← 連 tenant 停權都一起擋
--     v_role   := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
--     IF v_role NOT IN (...) THEN RAISE EXCEPTION 'permission denied: role % ...'
--     ＋ 物件必須屬於本 tenant，否則 RAISE
--   ⭐ 為什麼算 house pattern：①機制索引點名它是「限 owner/admin/hq_manager/warehouse」
--     的既有範例 ②它同樣是 SECURITY DEFINER 的寫入型 RPC ③它同時做了角色與 tenant 兩層。
--   ⭐ 本檔**比它嚴兩點**：
--     a) ⛔ **不收 p_operator 參數**（house pattern 收 `COALESCE(p_operator, auth.uid())`）——
--        收了就能冒名寫稽核欄位。一律 auth.uid()，冒名不了。
--     b) 角色名單取採購網域 RLS（20260502010000:18）的
--        owner/admin/hq_manager/purchaser，但**拿掉那個空字串 ''**。
--        ⚠️ 風險已知：若線上真的有「角色是空字串」的總部帳號，他們會被擋。
--        兩種失敗方向比較過 —— 擋錯了只是不能用、錯誤訊息會把 role 印出來、一眼可修；
--        放行錯了是**任何登入帳號都能取消客人的訂單**。往安全那邊倒。
--
-- （6）**唯讀那支回傳欄位盤點（阿審 P0-2）**：見 rpc_get_confirmed_shortfall_items 檔內表。
--   ⛔ 不回客人姓名、不回 member_id、不回電話（customer_orders 也沒有電話欄，
--      電話在 members；本檔完全不 JOIN members 取任何個資欄位）。
--
-- rollback:
--   DROP FUNCTION IF EXISTS public.rpc_set_confirmed_shortfall(BIGINT, NUMERIC);
--   DROP FUNCTION IF EXISTS public.rpc_get_confirmed_shortfall_items(BIGINT);
--   DROP TRIGGER IF EXISTS trg_coi_backorder_source_clear ON customer_order_items;
--   DROP FUNCTION IF EXISTS public._coi_clear_backorder_source();
--   ALTER TABLE customer_order_items DROP COLUMN IF EXISTS backorder_source,
--     DROP COLUMN IF EXISTS backorder_split_parent_id;
--   ALTER TABLE purchase_order_items DROP COLUMN IF EXISTS confirmed_shortfall,
--     DROP COLUMN IF EXISTS confirmed_shortfall_at, DROP COLUMN IF EXISTS confirmed_shortfall_by;
--   並重跑 20260808000000 的 rpc_cancel_backorder_items（把通知拿掉）。
--   ⚠️ 已經標出去的 backorder_at 不會自己收回 —— 要先用 rpc_set_confirmed_shortfall(po_item, NULL)
--     逐張清乾淨再回滾，否則客人會卡在「待到貨」而沒有任何地方看得到原因。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. purchase_order_items：確定短少欄位
-- ----------------------------------------------------------------
ALTER TABLE purchase_order_items
  ADD COLUMN IF NOT EXISTS confirmed_shortfall    NUMERIC(18,3),
  ADD COLUMN IF NOT EXISTS confirmed_shortfall_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS confirmed_shortfall_by UUID;

COMMENT ON COLUMN purchase_order_items.confirmed_shortfall IS
  '總倉已向廠商確認「這幾件確定不會到」的數量；NULL = 沒有這回事。'
  '與 stockout_at 的分工：stockout_at ＝整個品項供應商完全給不了（會取消該團所有客人）；'
  'confirmed_shortfall ＝只少幾件，其餘照到、照派。'
  '⛔ 這一欄只記「決定」，本身不改任何數量、不動庫存 —— 真正的效果是 '
  'rpc_set_confirmed_shortfall 把最晚下單的 N 件標成待補貨。'
  '⛔ 刻意沒有 CHECK 約束：CHECK 會在收貨改 qty_received 時一起被檢查，'
  '已填 3 而後續到貨讓未收量掉到 2 會直接把收貨擋掉。守衛全在 RPC。';

-- ----------------------------------------------------------------
-- 2. customer_order_items：待補貨的來源標記（G2）與拆行母子關係（P0-3）
-- ----------------------------------------------------------------
ALTER TABLE customer_order_items
  ADD COLUMN IF NOT EXISTS backorder_source         TEXT,
  ADD COLUMN IF NOT EXISTS backorder_split_parent_id BIGINT;

COMMENT ON COLUMN customer_order_items.backorder_source IS
  '這一列的 backorder_at 是誰標的。NULL ＝ 少發配貨引擎標的（這批不夠分，'
  '下一批到貨會自動解除）；''confirmed_shortfall'' ＝ 總倉已向廠商確認不會到。'
  '⚠️ 只在 backorder_at IS NOT NULL 時有意義 —— trigger 保證 backorder_at '
  '被清掉時本欄一起清掉（全 repo 有 25 處會清 backorder_at，不可能逐支去改）。'
  '⚠️ 被「取消並通知」取消的列會保留本欄（那是稽核憑證），清除路徑刻意不碰。';

COMMENT ON COLUMN customer_order_items.backorder_split_parent_id IS
  'rpc_set_confirmed_shortfall 拆行時，子行指回母行的 id。'
  '⭐ 存在的唯一理由：改 N 之前要能把子行**併回母行**，讓狀態完全回到未標記前 —— '
  '否則對已經圓過的折扣再圓一次，會出現「同樣的 N、走不同路徑、客人付不同的錢」'
  '（2026-09-02 阿審 P0-3：訂5折7，先3後4 客人留 2 元、直接 4 留 1 元）。'
  '⛔ 不要拿它做別的用途；⛔ 也不要加外鍵（母行可能被別的流程刪掉，'
  '加了外鍵會讓那些流程失敗——併行邏輯本來就會檢查母行還在不在）。';

-- backorder_at 一旦被清掉，來源標記與母子關係都必須跟著消失。
-- ⭐ 沒有這支的話：提前標的行被收貨自動解除（_settle_arrived_backorders）之後，
--   旗標會殘留；日後配貨引擎因為別的原因重標同一行，畫面就會顯示
--   「總倉確認不會到」—— 一句不是事實的話。
CREATE OR REPLACE FUNCTION public._coi_clear_backorder_source()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.backorder_at IS NULL THEN
    NEW.backorder_source := NULL;
    NEW.backorder_split_parent_id := NULL;
  END IF;
  RETURN NEW;
END;
$$;

-- ⚠️ WHEN 子句是刻意的：customer_order_items 是最熱的表之一，
--   沒有 WHEN 的話每一次 INSERT/UPDATE 都要進 plpgsql 一趟。
--   加了之後只有「要清而還沒清」的那極少數列才會真的執行函式本體。
DROP TRIGGER IF EXISTS trg_coi_backorder_source_clear ON customer_order_items;
CREATE TRIGGER trg_coi_backorder_source_clear
  BEFORE INSERT OR UPDATE ON customer_order_items
  FOR EACH ROW
  WHEN (NEW.backorder_at IS NULL
        AND (NEW.backorder_source IS NOT NULL OR NEW.backorder_split_parent_id IS NOT NULL))
  EXECUTE FUNCTION public._coi_clear_backorder_source();

-- ----------------------------------------------------------------
-- 3. rpc_set_confirmed_shortfall — 填/改/清「確定短少」，並同步標記尾端 N 件
-- ----------------------------------------------------------------
-- ⚠️ 舊簽章（帶 p_operator）若曾建立過要先移除，否則 CREATE OR REPLACE 會變成多載，
--   前端呼叫時 PostgREST 會挑錯支（本檔從未部署，這行是防呆）。
DROP FUNCTION IF EXISTS public.rpc_set_confirmed_shortfall(BIGINT, NUMERIC, UUID);

CREATE OR REPLACE FUNCTION public.rpc_set_confirmed_shortfall(
  p_po_item_id BIGINT,
  p_qty        NUMERIC
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- 權限：抄 rpc_create_stocktake 20260615000040:72-82，但⛔ 不收 p_operator
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role',
                                  auth.jwt() ->> 'role', '');
  v_poi          purchase_order_items%ROWTYPE;
  v_po_status    TEXT;
  v_outstanding  NUMERIC;
  v_campaign_ids BIGINT[];
  v_clearing     BOOLEAN;
  v_qty          NUMERIC;
  v_settled      NUMERIC := 0;
  v_need         NUMERIC;
  v_take         NUMERIC;
  v_alloc        NUMERIC;
  v_new_disc     NUMERIC;
  v_new_id       BIGINT;
  r              RECORD;
  c              RECORD;
  v_parent       customer_order_items%ROWTYPE;
  v_cleared      INT := 0;
  v_merged       INT := 0;
  v_marked       INT := 0;
  v_split        INT := 0;
  v_item_ids     BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  -- ── 權限（P0-1）─────────────────────────────────────────────────────
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'permission denied: 未登入';
  END IF;
  IF v_role NOT IN ('owner', 'admin', 'hq_manager', 'purchaser') THEN
    RAISE EXCEPTION 'permission denied: role % cannot set confirmed shortfall', v_role;
  END IF;

  -- 鎖住採購品項所屬的採購單：同一張單同時有人收貨 / 按斷貨時，
  -- 「未收量」是我們守衛的分母，不鎖會拿到過期讀取（2026-08-20 的教訓：
  -- 排隊只保證後跑，不會讓已經讀進 payload 的數字變新）。
  -- ⭐ 同一句順便做 tenant 圈禁：別的 tenant 的 po_item 直接查不到 → NOT FOUND。
  SELECT po.status INTO v_po_status
    FROM purchase_order_items poi
    JOIN purchase_orders po ON po.id = poi.po_id
   WHERE poi.id = p_po_item_id
     AND po.tenant_id = v_tenant
   FOR UPDATE OF po;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單品項 #%（或不屬於此帳號的公司）', p_po_item_id;
  END IF;

  SELECT * INTO v_poi FROM purchase_order_items WHERE id = p_po_item_id FOR UPDATE;

  -- ── 清除模式先判定（阿審 P1-4）───────────────────────────────────────
  -- ⭐ 清除**不受下面那批「填入守衛」管**。理由：貨後來補齊了（fully_received）
  --   或品項被標了斷貨之後，舊的 confirmed_shortfall 還掛著，
  --   若清除也被擋住，那個標記就**永遠拿不掉**，客人也永遠卡在待補貨。
  --   ⇒ 填入要嚴、清除要一直放得行。
  v_clearing := (p_qty IS NULL OR p_qty = 0);
  v_qty := CASE WHEN v_clearing THEN NULL ELSE p_qty END;

  IF NOT v_clearing THEN
    IF v_qty < 0 THEN
      RAISE EXCEPTION '確定短少要填正整數，收到 %', v_qty;
    END IF;
    -- 阿審 P2：訊息說「正整數」就要真的擋非整數（件數本來就是整數）
    IF v_qty <> trunc(v_qty) THEN
      RAISE EXCEPTION '確定短少要填正整數，收到 %（不接受小數）', v_qty;
    END IF;
    IF v_po_status NOT IN ('sent', 'partially_received') THEN
      RAISE EXCEPTION '這張採購單目前是「%」，只有已發送 / 部分到貨的單可以填確定短少'
                      '（要清除舊標記不受此限）', v_po_status;
    END IF;
    IF v_poi.stockout_at IS NOT NULL THEN
      RAISE EXCEPTION '這個品項已經標記斷貨了，不需要再填確定短少';
    END IF;
    v_outstanding := v_poi.qty_ordered - COALESCE(v_poi.qty_received, 0);
    IF v_outstanding <= 0 THEN
      RAISE EXCEPTION '這個品項已經全部到貨（訂 %、已收 %），沒有未到量可以標短少',
        v_poi.qty_ordered, COALESCE(v_poi.qty_received, 0);
    END IF;
    IF v_qty > v_outstanding THEN
      RAISE EXCEPTION '確定短少 % 超過未到量 %（訂 %、已收 %）',
        v_qty, v_outstanding, v_poi.qty_ordered, COALESCE(v_poi.qty_received, 0);
    END IF;
  END IF;

  -- 受影響開團：採購品項 → 請購單品項 → 請購單 → purchase_request_campaigns
  -- （逐字比照 _stockout_po_items 20260812000000:296-300）
  SELECT ARRAY_AGG(DISTINCT prc.campaign_id) INTO v_campaign_ids
    FROM purchase_order_items poi
    JOIN purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
   WHERE poi.id = p_po_item_id;

  -- ── 已成立額度：已經「取消並通知」掉的件數（決定（4））─────────────────
  -- ⭐ 一定要算在**任何寫入之前**：它同時是下面那道硬擋的分母。
  -- ⛔ 清除路徑不受它擋（見下），所以這裡只算不擋。
  IF v_campaign_ids IS NOT NULL THEN
    SELECT COALESCE(SUM(coi.qty), 0) INTO v_settled
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE co.tenant_id   = v_tenant
       AND co.campaign_id = ANY(v_campaign_ids)
       AND coi.sku_id     = v_poi.sku_id
       AND coi.backorder_source = 'confirmed_shortfall'
       AND coi.status = 'cancelled';
  END IF;

  -- 🔴 阿審第三輪：N 改得比「已經取消掉的件數」還小 → **硬擋**。
  -- 為什麼不能默默接受：那些客人**已經收到取消通知了**，收不回來。
  -- 若放行 N=1 而已取消 3，恆等式「已取消 ＋ 這次標的 ＋ unmet ＝ N」
  -- 會變成 3 + 0 + (-2) = 1 —— 一個負的 unmet，畫面上會變成「還缺 -2 件」這種鬼話。
  IF NOT v_clearing AND v_qty < v_settled THEN
    RAISE EXCEPTION '確定短少不能少於 % —— 這筆短少已經取消並通知過 % 件客人訂單，'
                    '那些通知收不回來，數字不可以倒退。'
                    '真的要改更小，請先去把那幾張已取消的訂單處理掉（回復或另行補償）',
                    v_settled, v_settled;
  END IF;

  -- ── 第一步：把「上一次由本功能標的、而且還活著的」收回 ──────────────
  -- ⛔ 只碰 status IN ('pending','reserved','ready')（阿審 P1-5）：
  --   已經被「取消並通知」取消掉的列是**稽核憑證**，清掉 source 等於
  --   把「這位是總倉判定短少而取消的」這件事抹掉。
  -- ⛔ 只收回 backorder_source='confirmed_shortfall' 的，配貨引擎標的不碰。
  IF v_campaign_ids IS NOT NULL THEN
    -- (a) 子行：併回母行（P0-3 的根治法，作法比照 20260825020000:698-735）
    FOR c IN
      SELECT coi.id, coi.qty, coi.discount_amount, coi.backorder_split_parent_id AS parent_id,
             coi.status AS item_status, coi.order_id, coi.sku_id
        FROM customer_order_items coi
        JOIN customer_orders co ON co.id = coi.order_id
       WHERE co.tenant_id   = v_tenant
         AND co.campaign_id = ANY(v_campaign_ids)
         AND coi.sku_id     = v_poi.sku_id
         AND coi.backorder_at IS NOT NULL
         AND coi.backorder_source = 'confirmed_shortfall'
         AND coi.status IN ('pending', 'reserved', 'ready')
         AND coi.backorder_split_parent_id IS NOT NULL
       ORDER BY coi.id
       FOR UPDATE OF coi
    LOOP
      -- 母行必須還在、還活著、狀態一致、而且沒有被別人動過（沒被標待補貨）。
      SELECT * INTO v_parent
        FROM customer_order_items p
       WHERE p.id = c.parent_id
         AND p.order_id = c.order_id
         AND p.sku_id   = c.sku_id
         AND p.status   = c.item_status
         AND p.backorder_at IS NULL
       FOR UPDATE;

      -- ⛔ backorders 那兩條外鍵是 NO ACTION：被引用到就刪不掉（Alex 20260825020000:715-719）。
      --   被引用、或被還沒釋放的減抵單引用 → **不併**，留著那一行比整支失敗好。
      IF FOUND
         AND NOT EXISTS (SELECT 1 FROM backorders b
                          WHERE b.original_customer_order_item_id = c.id
                             OR b.rollover_customer_order_item_id = c.id)
         AND NOT EXISTS (SELECT 1 FROM inventory_deduction_note_items ni
                           JOIN inventory_deduction_notes n
                             ON n.id = ni.note_id AND n.cancelled_at IS NULL
                          WHERE ni.order_item_id = c.id
                            AND ni.qty > COALESCE(ni.released_qty, 0))
      THEN
        UPDATE customer_order_items
           SET qty             = qty + c.qty,
               discount_amount = COALESCE(discount_amount, 0) + COALESCE(c.discount_amount, 0),
               updated_by      = v_user,
               updated_at      = NOW()
         WHERE id = v_parent.id;
        DELETE FROM customer_order_items WHERE id = c.id;
        v_merged  := v_merged + 1;
        v_cleared := v_cleared + 1;
      ELSE
        -- 併不回去（母行不見了 / 被外鍵引用 / 被減抵單佔著）→ 至少把旗標收回來。
        -- ⚠️ 此時折扣停在現值，改 N 之後的分配會與「一次到位」不同，但總額恆等。
        UPDATE customer_order_items
           SET backorder_at = NULL, backorder_by = NULL,
               updated_by = v_user, updated_at = NOW()
         WHERE id = c.id;
        v_cleared := v_cleared + 1;
      END IF;
    END LOOP;

    -- (b) 整行標記（沒拆過的）：單純把旗標收回來
    WITH cleared AS (
      UPDATE customer_order_items coi
         SET backorder_at = NULL,
             backorder_by = NULL,
             updated_by   = v_user,
             updated_at   = NOW()
        FROM customer_orders co
       WHERE co.id = coi.order_id
         AND co.tenant_id   = v_tenant
         AND co.campaign_id = ANY(v_campaign_ids)
         AND coi.sku_id     = v_poi.sku_id
         AND coi.backorder_at IS NOT NULL
         AND coi.backorder_source = 'confirmed_shortfall'
         AND coi.status IN ('pending', 'reserved', 'ready')
         AND coi.backorder_split_parent_id IS NULL
      RETURNING coi.id
    )
    SELECT v_cleared + COUNT(*) INTO v_cleared FROM cleared;
    -- backorder_source / split_parent_id 由 trg_coi_backorder_source_clear 自動清掉
  END IF;

  -- ── 第二步：寫回採購單品項的決定 ────────────────────────────────────
  UPDATE purchase_order_items
     SET confirmed_shortfall    = v_qty,
         confirmed_shortfall_at = CASE WHEN v_qty IS NULL THEN NULL ELSE NOW() END,
         confirmed_shortfall_by = CASE WHEN v_qty IS NULL THEN NULL ELSE v_user END,
         updated_by             = v_user,
         updated_at             = NOW()
   WHERE id = p_po_item_id;

  IF v_clearing OR v_campaign_ids IS NULL THEN
    RETURN jsonb_build_object(
      'confirmed_shortfall', v_qty,
      'cleared',  v_cleared,
      'merged',   v_merged,
      -- 🔴 第四輪 P2：這裡原本寫死 0，害畫面永遠說「已取消 0 件」——
      --   而清除路徑正是最需要講出這個數字的地方（那幾位客人已經收到取消通知、
      --   清除救不回來）。回真數。
      'settled',  v_settled,
      'marked',   0,
      'split',    0,
      'unmet',    COALESCE(v_qty, 0),
      'item_ids', '[]'::jsonb
    );
  END IF;

  -- ── 第三步：扣掉已成立額度（決定（4））──────────────────────────────
  -- v_settled 在函式前段就算好了（那裡同時是「不可倒退」硬擋的分母），這裡直接用。
  -- 恆等式：**已取消 ＋ 這次標的 ＋ unmet ＝ N**
  --   · v_qty >= v_settled 由前面的硬擋保證 ⇒ v_need 不可能是負的
  --   · 因此 unmet = GREATEST(v_need, 0) 裡的 GREATEST 只是防禦，不會真的夾到
  v_need := v_qty - v_settled;

  -- ── 第四步：把最晚下單的 N 件標成待補貨 ─────────────────────────────
  -- 排序＝_settle_arrived_backorders:258 的三鍵（co.created_at, co.order_no, coi.id）
  -- **整個倒轉成 DESC** —— 那支是「由早到晚配給誰」，這支是「由晚到早誰拿不到」。
  -- ⚠️ N 是**件數不是行數**：最晚那一筆可能訂 5 件而只短少 3 件 → 要拆行。
  IF v_need > 0 THEN
    FOR r IN
      SELECT coi.id, coi.qty, coi.tenant_id, coi.order_id, coi.campaign_item_id,
             coi.sku_id, coi.unit_price, coi.status, coi.source, coi.notes,
             coi.discount_amount, coi.discount_percent
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id AND coi.sku_id = v_poi.sku_id
       WHERE co.tenant_id   = v_tenant
         AND co.campaign_id = ANY(v_campaign_ids)
         AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
         -- 排除跨店衍生單、保留同店衍生單（20260807000000 的一致性配套）
         AND (co.transferred_from_order_id IS NULL OR EXISTS (
               SELECT 1 FROM customer_orders src
                WHERE src.id = co.transferred_from_order_id
                  AND src.pickup_store_id = co.pickup_store_id))
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND coi.status IN ('pending', 'reserved', 'ready')
         AND coi.backorder_at IS NULL
       ORDER BY co.created_at DESC, co.order_no DESC, coi.id DESC
       FOR UPDATE OF coi
    LOOP
      EXIT WHEN v_need <= 0;

      -- ⛔ 已經可取貨的不動：貨已經是他們的了，不可以事後收回
      --   （與 rpc_allocate_shortage 20260824040000:242 同一條原則）
      -- ⚠️ 這一關刻意放在**迴圈裡**而不是 WHERE：is_order_item_pickup_ready 是四道關
      --   的複合查詢，放進 WHERE 會對整團（跨 17 家店、可能上百張單）每一列都跑一次；
      --   放這裡只跑到「真的要標的那幾件」為止（N 通常個位數）。結果完全相同。
      CONTINUE WHEN public.is_order_item_pickup_ready(r.id);

      v_take := LEAST(r.qty, v_need);

      IF v_take >= r.qty THEN
        -- 整行都拿不到
        UPDATE customer_order_items
           SET backorder_at     = NOW(),
               backorder_by     = v_user,
               backorder_source = 'confirmed_shortfall',
               updated_by       = v_user,
               updated_at       = NOW()
         WHERE id = r.id;
        v_item_ids := v_item_ids || r.id;
        v_marked := v_marked + 1;
      ELSE
        -- 部分拿不到 → 拆行：原行留拿得到的量，另開一行掛待補貨
        -- ⛔ 以下拆行與折扣分攤**逐字抄自 rpc_allocate_shortage 20260824040000:269-299**
        --   （該處註解：與 rpc_record_pickup 拆行同一套算法）。
        --   ⛔ 不可以自己重寫：漏掉折扣按數量比例分攤 ＝ 直接算錯客人要付多少錢。
        --   對應關係：那支的 v_alloc（配到的量）＝ 本支的 r.qty - v_take。
        -- ⭐ 只會拆「沒被我們拆過」的行 —— 上一步已經把自己的子行併回母行了，
        --   所以這裡拿到的一定是原始基準（P0-3 的根治點，檔頭有手算）。
        v_alloc := r.qty - v_take;

        v_new_disc := COALESCE(r.discount_amount, 0)
                      - round(COALESCE(r.discount_amount, 0) * v_alloc / r.qty);

        INSERT INTO customer_order_items (
          tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
          status, source, notes, discount_amount, discount_percent,
          backorder_at, backorder_by, backorder_source, backorder_split_parent_id,
          created_by, updated_by, created_at, updated_at
        ) VALUES (
          r.tenant_id, r.order_id, r.campaign_item_id, r.sku_id, r.qty - v_alloc, r.unit_price,
          r.status, r.source, r.notes, v_new_disc, r.discount_percent,
          NOW(), v_user, 'confirmed_shortfall', r.id,
          v_user, v_user, NOW(), NOW()
        )
        RETURNING id INTO v_new_id;
        v_item_ids := v_item_ids || v_new_id;

        UPDATE customer_order_items
           SET qty = v_alloc,
               discount_amount = COALESCE(r.discount_amount, 0)
                                 - v_new_disc,
               updated_by = v_user,
               updated_at = NOW()
         WHERE id = r.id;

        v_split  := v_split + 1;
        v_marked := v_marked + 1;
      END IF;

      v_need := v_need - v_take;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'confirmed_shortfall', v_qty,
    'cleared',  v_cleared,
    'merged',   v_merged,
    -- 已經取消掉的件數（算進 N，不再重標）
    'settled',  v_settled,
    'marked',   v_marked,
    'split',    v_split,
    -- 還沒標到的件數：等貨的客人不夠多時會 > 0，畫面要照實講，⛔ 不可以裝作標滿了
    'unmet',    GREATEST(COALESCE(v_need, 0), 0),
    'item_ids', COALESCE(to_jsonb(v_item_ids), '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_set_confirmed_shortfall(BIGINT, NUMERIC) IS
  '填 / 改 / 清「確定短少」：把該採購品項所屬各團、同 SKU、**最晚下單的 N 件**'
  '標成待補貨（backorder_at + backorder_source=''confirmed_shortfall''）。'
  '排序＝co.created_at, co.order_no, coi.id 由晚到早（_settle_arrived_backorders:258 倒轉）；'
  'N 是件數不是行數，最晚那筆量比 N 大時拆行（折扣按數量比例分攤，'
  '逐字比照 rpc_allocate_shortage:269-299）。'
  '權限：role IN (owner, admin, hq_manager, purchaser) ＋ 採購單必須屬於本 tenant；'
  '⛔ 不收 operator 參數，一律 auth.uid()，杜絕冒名。'
  '⭐ 三種呼叫走同一條路：p_qty=N 首次填 ／ p_qty=M 改數字 ／ p_qty=NULL 或 0 清除。'
  '⭐⭐ 改數字前會先把**上次拆出來的子行併回母行**（backorder_split_parent_id），'
  '狀態完全回到未標記前 —— 否則對已四捨五入的折扣再圓一次，'
  '「先標3再改4」與「直接標4」客人留存折扣會差 1 元（阿審 2026-09-02 P0-3，檔頭有手算）。'
  '併不回去時（子行已取消／被 backorders 外鍵引用／母行不在）不強行還原，總額仍恆等。'
  '⛔ 清除只作用於 active 列（pending/reserved/ready）：已被「取消並通知」取消的列是'
  '稽核憑證，不可變，而且**計入 N**（恆等式：已取消 + 這次標的 + unmet = N）。'
  '⛔⛔ **N 不可以小於已取消件數**（會 RAISE）：那些客人已經收到取消通知、收不回來，'
  '硬放行會讓 unmet 變負數（畫面出現「還缺 -2 件」）。'
  '⚠️ 恆等式的邊界：它只在 confirmed_shortfall 有值時成立。清除（N=NULL）刻意**不受**'
  '此擋 —— 否則貨補齊之後舊標記又清不掉（就是第 2 輪 P1-4 那個病）；'
  '清除之後已取消的列仍留著稽核標記，只是不再有 N 可以對照。'
  '⚠️ 清除路徑刻意不受「只能填短少」那批守衛限制 —— 貨補齊或已斷貨之後'
  '還是要清得掉舊標記，否則客人永遠卡在待補貨。'
  '⚠️ 已經可取貨（閘門放行）的列不標 —— 貨已經是客人的了，不事後收回。'
  '⛔ 本函式不動庫存、不建任何單、不通知客人 —— 通知在 rpc_cancel_backorder_items。';

REVOKE ALL ON FUNCTION public.rpc_set_confirmed_shortfall(BIGINT, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_confirmed_shortfall(BIGINT, NUMERIC) TO authenticated;

-- ----------------------------------------------------------------
-- 4. rpc_get_confirmed_shortfall_items — 目前被本功能標住的是哪幾筆（唯讀）
--
-- ⭐ 為什麼需要它：採購單頁那顆「取消待補貨並通知」要餵 item ids 給
--   rpc_cancel_backorder_items，而標記時回傳的 id 會過期（客人可能自己取消、
--   或收到貨被自動解除）。⛔ 不可以拿標記當下的 id 去取消 —— 那會取消到
--   已經不該取消的東西。一律按鈕當下重查。
--   同一份資料也拿來做「取消前先看名單」（阿審 P1-6）。
--
-- ⭐ 回傳欄位盤點（阿審 P0-2）：
--   item_id     必要 —— 要餵給 rpc_cancel_backorder_items
--   order_no    必要 —— 操作者要認得出是哪一張單（老闆指定「單號」）
--   store_name  必要 —— 老闆指定「店」
--   qty         必要 —— 老闆指定「件數」
--   created_at  必要 —— 這功能砍的是「最晚下單的」，要看得出時間順序才驗得了
--   notifiable  必要 —— 布林值，不是個資；畫面要照實說「幾位收得到、幾位收不到」
--   ⛔ 不回客人姓名／member_id／電話：確認一份要取消的清單用單號＋店＋件數就夠。
--     （電話本來就不在 customer_orders，在 members；本函式完全不 JOIN members。）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_confirmed_shortfall_items(p_po_item_id BIGINT)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role',
                              auth.jwt() ->> 'role', '');
  v_sku_id   BIGINT;
  v_shortfall NUMERIC;
  v_campaigns BIGINT[];
  v_out      jsonb;
BEGIN
  -- 權限與 tenant：與 rpc_set_confirmed_shortfall 同一套（P0-2）
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'permission denied: 未登入';
  END IF;
  IF v_role NOT IN ('owner', 'admin', 'hq_manager', 'purchaser') THEN
    RAISE EXCEPTION 'permission denied: role % cannot read confirmed shortfall items', v_role;
  END IF;

  SELECT poi.sku_id, poi.confirmed_shortfall
    INTO v_sku_id, v_shortfall
    FROM purchase_order_items poi
    JOIN purchase_orders po ON po.id = poi.po_id
   WHERE poi.id = p_po_item_id
     AND po.tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單品項 #%（或不屬於此帳號的公司）', p_po_item_id;
  END IF;

  SELECT ARRAY_AGG(DISTINCT prc.campaign_id) INTO v_campaigns
    FROM purchase_request_items pri
    JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
   WHERE pri.po_item_id = p_po_item_id;

  WITH rows_all AS (
    SELECT coi.id AS item_id,
           co.order_no,
           st.name AS store_name,
           coi.qty,
           co.created_at,
           (co.member_id IS NOT NULL) AS notifiable
      FROM customer_orders co
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.sku_id   = v_sku_id
       AND coi.status IN ('pending', 'reserved', 'ready')
       AND coi.backorder_at IS NOT NULL
       AND coi.backorder_source = 'confirmed_shortfall'
      LEFT JOIN stores st ON st.id = co.pickup_store_id
     WHERE co.tenant_id   = v_tenant
       AND co.campaign_id = ANY(COALESCE(v_campaigns, ARRAY[]::BIGINT[]))
  ),
  cancelled AS (
    -- 已經取消掉的（決定（4）：不可變、計入 N），畫面要能說「已處理 X 件」
    SELECT COALESCE(SUM(coi.qty), 0) AS qty
      FROM customer_orders co
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.sku_id   = v_sku_id
       AND coi.backorder_source = 'confirmed_shortfall'
       AND coi.status = 'cancelled'
     WHERE co.tenant_id   = v_tenant
       AND co.campaign_id = ANY(COALESCE(v_campaigns, ARRAY[]::BIGINT[]))
  )
  SELECT jsonb_build_object(
    'confirmed_shortfall', v_shortfall,
    'marked_qty',    COALESCE((SELECT SUM(qty) FROM rows_all), 0),
    'cancelled_qty', (SELECT qty FROM cancelled),
    'notifiable',    COALESCE((SELECT COUNT(*) FROM rows_all WHERE notifiable), 0),
    'unnotifiable',  COALESCE((SELECT COUNT(*) FROM rows_all WHERE NOT notifiable), 0),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'item_id',    r.item_id,
               'order_no',   r.order_no,
               'store_name', r.store_name,
               'qty',        r.qty,
               'notifiable', r.notifiable,
               'created_at', r.created_at
             ) ORDER BY r.created_at DESC, r.order_no DESC)
        FROM rows_all r
    ), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION public.rpc_get_confirmed_shortfall_items(BIGINT) IS
  '這個採購品項目前因「確定短少」被標成待補貨的客人品項（唯讀，取消前先看名單用）。'
  '權限與 tenant 圈禁同 rpc_set_confirmed_shortfall。'
  '⛔ 刻意不回客人姓名／member_id／電話 —— 確認一份要取消的清單，'
  '單號＋分店＋件數＋下單時間就夠（欄位盤點見函式上方註解）。'
  'notifiable ＝ 綁了會員、取消時收得到通知的筆數；unnotifiable ＝ 收不到的筆數'
  '（rpc_cancel_backorder_items 的通知條件是 member_id IS NOT NULL，同一個判準）。'
  'cancelled_qty ＝ 這筆短少已經取消掉的件數（計入 N，不會再被重標）。'
  '⚠️ 呼叫端要在「按取消的當下」重查，⛔ 不可以沿用標記當時回傳的 item_ids —— '
  '中間客人可能自己取消、或補到貨被 _settle_arrived_backorders 自動解除。';

REVOKE ALL ON FUNCTION public.rpc_get_confirmed_shortfall_items(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_confirmed_shortfall_items(BIGINT) TO authenticated;

-- ----------------------------------------------------------------
-- 5. rpc_cancel_backorder_items — 補上顧客通知（G1）
--    基底 20260808000000:322 逐字保留，只加：
--      a) v_coi_ids / v_notified 宣告
--      b) 第一段 UPDATE → CTE + RETURNING（只通知本次真的取消的那幾筆）
--      c) 通知區塊（抄 _stockout_po_items 20260812000000:381-396）
--      d) 回傳多一個 notified
--    ⛔ 第二段 UPDATE、v_order_ids 的取法、_close_orders_all_items_settled 呼叫
--       全部一字未動（它們用的是 v_ids ＝呼叫端給的全部 id，不是 v_coi_ids）。
--    ⛔ 簽章不動（p_operator 保留），但 20260902030000（第四輪）起**它的值一律不用**，
--       三個稽核寫入點（兩段 UPDATE 的 updated_by ＋ _close_orders_all_items_settled）
--       全部改成 v_actor := auth.uid()。
--
--       ⭐ 為什麼「保留參數但忽略」而不是「拿掉參數＋同步改兩個呼叫點」：
--         **這個 repo 的前端與資料庫不是同時上線的** —— 前端自動部署、DB 是人工貼。
--         拿掉參數就要 DROP FUNCTION 再建，只要兩邊上線有時間差，
--         其中一個方向就會出現「函式簽章對不上」而整顆鈕壞掉：
--           · DB 先上 → 舊前端還在送 p_operator → PostgREST 找不到函式 → 店家按了就噴錯
--           · 前端先上 → 新前端不送 → 舊函式兩個參數都必填 → 一樣噴錯
--         機制索引已經記過同一種事故（20260825010000／PR #838：
--         「DB 守衛先上、配套前端沒部署 ⇒ 店家跨店轉單吃到看不懂的錯誤」，
--         教訓逐字：「**兩層要一起上線。只擋 DB 不動前端 ＝ 店家撞一堆看不懂的錯誤**」）。
--         保留參數則**兩種上線順序都不會壞**：舊前端照送、值被忽略；新前端送不送都行。
--       ⚠️ 代價：簽章上留了一個沒有作用的參數。用 COMMENT 與這段註解標清楚，
--         ⛔ 不要有人再把它接回稽核欄位。
--       ⓘ 前端**刻意不動**（兩個呼叫點照樣送 p_operator）：送了也只是被忽略，
--         改了反而製造上面那個時間差風險，而且不在本輪範圍。
--
--    🔴 2026-09-02 第三輪追加 e) 身分守衛。**呼叫點全掃過才動手**：
--       ① 前端       ShortageAllocateModal.tsx:338（既有）、purchase/orders/edit:709（本次新增）
--       ② Edge Function  supabase/functions 全目錄 grep → **0 筆**
--       ③ 其他 SQL 函式  `(PERFORM|SELECT|:=|=) rpc_cancel_backorder_items(` → **0 筆**
--       ④ 排程           pg_cron 四支 job 全查 → **0 筆碰 backorder**
--       ⑤ GRANT 對象     只有 `TO authenticated`（20260805000060:330），**沒有 service_role**
--       ⇒ 兩個呼叫點都是登入後台的瀏覽器，auth.uid() 不可能是 NULL。
--
--    🔴🔴 **但「角色白名單照抄新的兩支」不成立 —— 這是查證推翻的，不是我怕**：
--       `20260811000050` 檔頭第 6-7 行（Alex 自己寫的松山店災情）逐字：
--         「**店家在收貨頁跑「⚖️ 配貨」**把 10 件配掉」
--       ⇒ 這顆取消鈕住在配貨視窗裡，而配貨視窗是**分店店員**在用的。
--       套 owner/admin/hq_manager/purchaser ⇒ **店家從此按不了這顆鈕**（既有功能被我弄壞）。
--
--    ⇒ 本輪只補「**能證明不會弄壞既有行為**」的三道：
--         (1) 未登入擋掉        (2) **tenant 圈禁**（阿審 P0 的正主：跨公司取消別人的客人）
--         (3) 停用帳號擋掉（role='disabled'；機制索引：停用只改 role，JWT 沒到期前照樣能打）
--       ⛔ **刻意不做**「誰可以取消」的角色收斂 —— 那是產品決定不是技術決定
--         （店員該不該有權取消客人訂單？），要老闆拍板。已列進回報等裁示。
--
--    ⭐ 8/18 鐵則反問「有哪些既有行為是靠『沒有這道鎖』才成立的」：
--       答案就是上面那條 —— **分店店員取消待補貨**這個既有行為，
--       正是靠「沒有角色檢查」才成立的。這也是為什麼不能照抄新兩支的名單。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_cancel_backorder_items(
  p_item_ids BIGINT[],
  p_operator UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_items     INT := 0;
  v_orders    INT := 0;
  v_completed INT := 0;
  v_notified  INT := 0;                      -- 20260902030000
  v_ids       BIGINT[] := COALESCE(p_item_ids, ARRAY[]::BIGINT[]);
  v_order_ids BIGINT[];
  v_coi_ids   BIGINT[];                      -- 20260902030000：本次真的取消的品項
  v_tenant    UUID;                          -- 20260902030000(3)：身分守衛
  v_role      TEXT;                          -- 20260902030000(3)
  v_actor     UUID;                          -- 20260902030000(4)：真正的操作者
BEGIN
  -- 20260902030000（第三輪 P0）：身分守衛。
  -- ⚠️ 這裡**只擋三件事**，⛔ 沒有做「誰可以取消」的角色收斂 —— 理由見本段檔頭：
  --   這顆鈕的既有使用者包含**分店店員**（20260811000050 檔頭第 6-7 行有實例），
  --   套總部角色名單會直接弄壞既有功能。要不要收斂是老闆的產品決定。
  v_tenant := public._current_tenant_id();   -- 未登入 / 缺 tenant claim / 租戶停權 都會在這裡炸
  v_role   := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
  -- 20260902030000（第四輪 P1）：稽核欄位一律寫「真正登入的人」。
  -- ⛔ p_operator 是呼叫端自己填的字串，可以隨便填別人的 uuid ＝ 冒名。
  --    參數本身保留（見檔頭「為什麼不拿掉」），但**值一律不用**。
  v_actor  := auth.uid();

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'permission denied: 未登入';
  END IF;
  -- 停用帳號：機制索引「停用只改 role，JWT 到期前 perms 還在」⇒ 一定要自己擋
  IF v_role = 'disabled' THEN
    RAISE EXCEPTION 'permission denied: 帳號已停用';
  END IF;
  -- 🔴 阿審第三輪 P0 的正主：跨公司取消別人家的客人訂單。
  -- ⛔ 用「有任何一筆不屬於本公司就整批拒絕」而不是「默默濾掉」——
  --   默默濾掉會讓呼叫端以為全部取消了（畫面又說謊一次）。
  IF EXISTS (
        SELECT 1
          FROM customer_order_items coi
          JOIN customer_orders co ON co.id = coi.order_id
         WHERE coi.id = ANY(v_ids)
           AND co.tenant_id IS DISTINCT FROM v_tenant
     ) THEN
    RAISE EXCEPTION 'permission denied: 品項不屬於此帳號的公司';
  END IF;

  -- 20260902030000：改成 CTE + RETURNING —— 通知只發給「這一次真的被取消」的品項，
  -- 同一批 id 重按第二次不會再發一次（防重發，同 _stockout_po_items 的作法）。
  WITH upd AS (
    UPDATE customer_order_items coi
       SET status = 'cancelled', stockout_at = NOW(),
           updated_by = v_actor, updated_at = NOW()
     WHERE coi.id = ANY(v_ids)
       AND coi.backorder_at IS NOT NULL       -- 只准取消待補貨的，避免誤砍正常品項
       AND coi.status IN ('pending', 'reserved', 'ready')
    RETURNING coi.id
  )
  SELECT ARRAY_AGG(id), COUNT(*) INTO v_coi_ids, v_items FROM upd;

  UPDATE customer_orders co
     SET status = 'cancelled', cancelled_at = NOW(), stockout_at = NOW(),
         updated_by = v_actor, updated_at = NOW()
   WHERE co.id IN (SELECT order_id FROM customer_order_items WHERE id = ANY(v_ids))
     AND co.status IN ('pending', 'confirmed', 'ready', 'shipping')
     AND COALESCE(co.payment_status, 'unpaid') <> 'paid'
     AND COALESCE(co.wallet_paid_amount, 0) = 0
     AND NOT EXISTS (
           SELECT 1 FROM customer_order_items x
            WHERE x.order_id = co.id AND x.status NOT IN ('cancelled', 'expired')
         );
  GET DIAGNOSTICS v_orders = ROW_COUNT;

  -- 20260808000000：已取走一部分、剩下的待補貨這次被取消 → 訂單收尾成 completed
  SELECT ARRAY_AGG(DISTINCT order_id) INTO v_order_ids
    FROM customer_order_items WHERE id = ANY(v_ids);
  v_completed := public._close_orders_all_items_settled(v_order_ids, v_actor, NOW());

  -- 20260902030000（G1）：顧客通知（in-app 通知中心留底；**綁定會員的訂單才發得了**）
  --   ⭐ 這一段之前**完全不存在** —— 按「取消待補貨」客人收不到任何東西，
  --     而另一條取消路徑（採購單斷貨 _stockout_po_items）本來就會通知。
  --     這條是例外不是設計，本次補齊。
  --   ⚠️ 文案與 _stockout_po_items 20260812000000:381-396 **刻意保持一致**
  --     （對客人來說是同一件事：訂的東西供不了、已取消）。
  --     ⛔ 要改字請兩邊一起改，不要只改一邊。
  IF v_coi_ids IS NOT NULL THEN
    INSERT INTO notifications (tenant_id, member_id, category, title, body, url)
    SELECT
      co.tenant_id,
      co.member_id,
      'stockout',
      '商品斷貨通知',
      '您訂購的「' || string_agg(DISTINCT COALESCE(sk.product_name, sk.sku_code)
                                  || COALESCE('-' || sk.variant_name, ''), '、')
        || '」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。',
      '/orders'
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    JOIN skus sk ON sk.id = coi.sku_id
    WHERE coi.id = ANY(v_coi_ids)
      AND co.member_id IS NOT NULL
    GROUP BY co.tenant_id, co.member_id;
    GET DIAGNOSTICS v_notified = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'items_cancelled',  COALESCE(v_items, 0),
    'orders_cancelled', v_orders,
    'orders_completed', v_completed,
    'notified',         v_notified          -- 20260902030000
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_cancel_backorder_items(BIGINT[], UUID) IS
  '待補貨確定補不到 → 品項 cancelled + stockout_at（沿用斷貨語意）。'
  '整單品項都沒了且沒收過錢 → 訂單一併取消；'
  '已取走一部分、剩下的這次取消掉 → 訂單收尾成 completed（20260808000000）。'
  '20260902030000 起**會通知顧客**（category=stockout，文案同 _stockout_po_items）：'
  '⚠️ 只有 member_id IS NOT NULL（綁會員）的訂單發得出去，'
  '回傳 notified ＝ 實際發出的通知筆數（一位會員一筆，不是品項數）。'
  '只通知本次真的被取消的品項，重按不會重發。'
  '⚠️ 這是相對 20260808000000 的**行為變更**：收貨頁「✕ 補不到了，把待補貨轉取消」'
  '這條既有路徑也會開始發通知（先前是靜默取消）。取捨：另一條取消路徑本來就通知，'
  '這條是例外；包一層新函式會產生兩支語意幾乎相同的東西，必然漂移。'
  '⚠️ 本函式**不清** backorder_at / backorder_source —— 取消掉的列要留著那兩欄'
  '當稽核憑證（rpc_set_confirmed_shortfall 靠它認出「已成立」的短少額度）。'
  '⚠️⚠️ **p_operator 這個參數的值從 20260902030000 起被完全忽略**（保留只為簽章相容，'
  '因為前端自動部署、DB 人工貼，拿掉參數會在上線時間差裡讓這顆鈕整個壞掉）。'
  '稽核欄位一律寫 auth.uid() —— 呼叫端自己填的 uuid 可以冒名，不能信。'
  '⛔ 不要再把 p_operator 接回 updated_by。'
  '20260902030000（第三輪）加身分守衛三道：未登入擋、role=disabled 擋、'
  '**品項必須屬於呼叫者的 tenant**（有任一筆不是就整批拒絕，⛔ 不默默濾掉）。'
  '⛔ 刻意**沒有**角色白名單：這顆鈕的既有使用者包含分店店員'
  '（20260811000050 檔頭：「店家在收貨頁跑⚖️配貨」），'
  '套總部角色名單會弄壞既有功能。「店員該不該有權取消客人訂單」是產品決定，待老闆裁示。';

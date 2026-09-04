-- ============================================================================
-- 2026-09-04（店家退貨頁 · 第 1 支）：店家自建退貨單 —— 送出時「不動庫存」
--
-- ============================================================================
-- 【一】老闆 2026-09-04 裁示 2（乙案），逐字錨定
-- ============================================================================
--   「先不扣 → 帳上還是 10，旁邊標『退貨中 3』讓人看得到；
--     **總倉按同意的那一刻才真的扣**。不同意的話什麼都沒動過，乾乾淨淨」
--     （出處：需求暨計畫_店家退貨頁_2026-09-04.md 第 10-11 行）
--
--   ⇒ 本檔負責「送出不扣」那一半。另外兩半在：
--       20260904020010 —— 總倉同意（rpc_receive_transfer）那一刻才扣店家、入總倉
--       20260904020020 —— 總倉不同意（rpc_reject_transfer）零庫存動作
--
-- ⛔⛔ 【三支必須一起貼，順序不可顛倒】
--   1️⃣ 20260904020000（本檔：建單不扣）
--   2️⃣ 20260904020010（同意才扣）
--   3️⃣ 20260904020020（不同意零動作）
--   只貼 1️⃣ 不貼 2️⃣ ＝ 店家退的貨會**憑空進總倉庫存**（店家那邊沒扣），總倉帳面虛胖。
--   只貼 1️⃣ 不貼 3️⃣ ＝ 總倉按「不同意」時會對店家 rpc_inbound 一次，
--                       而店家從來沒被扣過 ⇒ **憑空生貨**。
--   ⇒ 三支要嘛一起貼，要嘛一支都不要貼。
--
-- ============================================================================
-- 【二】做了會怎樣／不做會怎樣（兩邊都講）
-- ============================================================================
--   做了：店家送出退貨之後、總倉還沒回覆之前，店家帳上那幾件**還在**。
--     ⇒ 好處：總倉不同意時，貨帳兩邊都不用回復，乾乾淨淨（老闆要的）。
--     ⇒ 代價：等待期間店家帳面看起來比實際多。所以庫存頁那一格會標「退貨中 N」，
--             退貨頁的進度列表也會即時比對「在庫 vs 退貨中」並示警。
--     ⇒ 代價二：等待期間店家把那批貨賣掉／取貨掉，總倉按同意時會**扣不動而失敗**
--             （處置見 20260904020010 檔頭【四】，那是本系統既有慣例，不是新規則）。
--   不做（維持現行 rpc_create_order_return 建單即扣）：
--     總倉還沒回答，貨已經從店家帳上消失；不同意的話要靠 rpc_reject_transfer
--     再 inbound 回去 —— 貨帳來回搬，老闆原話「貨來來回回浪費時間」。
--
-- ============================================================================
-- 【三】為什麼 notes 一定要以「[order return」開頭（⛔ 不可改字）
-- ============================================================================
--   總倉端那兩顆鈕與 48 小時自動同意**都是靠這個前綴認人的**，本檔照抄，
--   才能做到老闆要的「總倉端零改動」：
--     ① 畫面（hq/inbox/page.tsx:181-183 isOrderReturnTransfer、:2937-2959 兩顆鈕）
--        ＝ notes.startsWith("[order return")
--     ② 48h 自動同意（20260903010020:143）＝ COALESCE(t.notes,'') LIKE '[order return%'
--   ⚠️ ②那支還在 PR #906、本檔基準（7587aba7）裡沒有它，但老闆 2026-09-04 已經把它
--      貼進正式庫（cron jobid=5）⇒ 本檔建出來的單**上線當天就會被它掃到**。
--   ⇒ 改這個前綴 ＝ 退貨單在總倉收件匣上完全消失、也不會自動同意。⛔ 不要改。
--
--   格式沿用 rpc_create_order_return（20260801000000:146-159）與前端解析器
--   returnNote.ts 的既有約定：`[order return{|破損}{: 原因}]`
--     少收   → [order return: 少收]      → 畫面顯示「退貨：少收」
--     破損   → [order return|破損]        → 畫面顯示「退貨・破損」
--     過期   → [order return: 過期]
--     客人退 → [order return: 客人退]
--   ⭐ 四個原因都是**系統固定字串**、沒有使用者自由文字進到方括號裡
--      ⇒ returnNote.ts 的 regex（/^\[order return([^\]:]*)(?::\s*([^\]]*))?\]/）
--        不可能被使用者輸入的 `]` 打斷。這比既有路徑（把 p_reason 塞進括號）更安全。
--
-- ============================================================================
-- 【四】跟既有東西的關係（每一條都查過）
-- ============================================================================
--   ① ⛔ 不碰 rpc_create_order_return（20260801000000:59）。
--      那條路（內部調撥頁 →「↩ 退貨回總倉」→ 必須先挑一張客人訂單）**照舊完整保留**，
--      它建單即扣庫存、會做「全數退貨收尾」（把訂單推成 cancelled/completed）、
--      取貨守門與應收扣減都吃它建的單。本檔是**另開一條**，不是取代。
--      ⇒ 兩條路建出來的單 notes 都以 [order return 開頭，所以退貨頁的進度列表兩種都看得到。
--
--   ② customer_order_id 刻意留 NULL（本頁不綁訂單）。查證過三個下游都因此自動跳過：
--      - rpc_receive_transfer 邏輯 B（20260827000000:256-265）條件是
--        `v_customer_order_id IS NOT NULL` ⇒ 不會誤把別人的訂單推成 ready
--        （這正是 20260903010020 檔頭第 22-31 行列為「連帶行為」的那一條，本頁天生沒有）
--      - rpc_reject_transfer 的 return_to_hq 復原分支（20260827020000）條件同樣是
--        v_co_id IS NOT NULL ⇒ 不會亂改訂單狀態
--      - rpc_unreject_transfer（20260731000000:291-293）綁訂單才擋，本頁的單不受影響
--        （但它另有一條限制，見 20260904020020 檔頭【五】）
--
--   ③ ⛔ 虛擬商品（products.is_virtual，自由轉貨的 MISC-01 之類）本頁一律拒收。
--      理由：rpc_inbound 從 20260903000100:56-64 起對虛擬 SKU 直接 RETURN NULL、
--      但 rpc_outbound（最新版 20260705000000:121）**沒有**同一道守衛
--      ⇒ 若讓虛擬商品走本流程，同意時會變成「店家扣了、總倉沒進」＝ 只出不進，
--        正好把 #902 才修好的「只進不出」倒過來再犯一次。
--      擋在建單這一步最乾淨：店家在畫面上就看得到為什麼不能退。
--
--   ④ 9/01 起的「短收沖帳單」（20260901000010:317-324、20260903000020:268、
--      20260903000200:370）也是 transfer_type='return_to_hq'，但它們
--      **生而 status='received'、notes 以 '[短收沖帳]' 開頭、out_movement_id 指向原出庫**。
--      ⇒ 本檔的 view 與退貨頁都用「status='shipped' ＋ notes LIKE '[order return%'」框母體，
--        它們三種一個都框不進來。⛔ 這是刻意的：那是純記帳單，動到它就會做出錯帳。
--
-- ============================================================================
-- 【五】Rollback
-- ============================================================================
--   DROP VIEW IF EXISTS public.v_store_pending_returns;
--   DROP FUNCTION IF EXISTS public.rpc_create_store_return(BIGINT, JSONB, TEXT, UUID);
--   ⚠️ 三支一組：要回就三支一起回（見上面【一】）。
--   ⚠️ 已經建出來、還沒被總倉處理的單（status='shipped'、out_movement_id IS NULL）
--     回滾後會變成「總倉一按同意就把貨憑空記進總倉」——
--     所以回滾前要先把那些單處理掉或改成 cancelled。
--
-- ============================================================================
-- 【六】2026-09-04 第二輪（阿審審查報告）改了兩處，都在本檔
-- ============================================================================
--   P0 店別守門：原本「空白身分不驗店」⇒ 有 tenant_id、沒有 role 的登入者可以
--     指定同公司任一家店建退貨單，48h 自動同意後真的扣那家店的庫存。
--     改成「只有總部三個角色可代操，其餘含空白身分一律驗 _jwt_store_ids()」。
--     詳細出處寫在函式內店別守門那一段。
--   P1 併發：原本沒有鎖，兩張單同時建可以各自看到舊的「已在等回覆」數字而都通過，
--     加起來超過在庫 ⇒ 兩張都卡死在總倉。改成「先鎖 (店,SKU) 餘額列 → 重讀 → 才比」，
--     鎖序與 20260904010000 家族一致。⚠️ 鎖只是排隊點，本檔**仍然一筆庫存都不寫**（乙案）。
--
-- 本檔不改任何既有函式、不改任何既有 view、不改任何 schema、無資料異動。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. v_store_pending_returns —— 「退貨中 N」的唯一資料來源
-- ----------------------------------------------------------------------------
-- 給兩個地方用：庫存總覽那一格的「退貨中 N」小標、退貨頁的示警比對。
-- ⭐ 用 out_movement_id IS NULL 當判準，不是用什麼旗標欄位：
--   「有沒有出庫異動」就是「有沒有真的扣過」這件事本身，不會過期、不會被改壞。
--   舊路徑（rpc_create_order_return）建的單一定有 out_movement_id
--   （20260801000000:248-265 建單當下就寫）⇒ 它們不會被算進「退貨中」，
--   這是對的：那些貨已經從店家帳上扣掉了，沒有「帳面比實際多」的問題要提醒。
CREATE OR REPLACE VIEW public.v_store_pending_returns AS
SELECT
  t.tenant_id,
  t.source_location             AS location_id,
  ti.sku_id,
  SUM(ti.qty_shipped)::NUMERIC  AS pending_qty,
  COUNT(DISTINCT t.id)::INT     AS doc_count,
  -- 2026-09-04 第二輪：擋下來的時候要講得出「被誰占著」，不然店家只看到一個數字，
  -- 不知道要去看哪一張單。⭐ 單號從**同一個母體**算出來，⛔ 不要在別的地方
  -- 另寫一份 WHERE 去撈單號 —— 那兩份遲早會漂移。
  -- 寫法沿用既有的 20260702000010:39（同樣是 view 裡的 string_agg(DISTINCT …, … ORDER BY …)）；
  -- 加 ORDER BY 是為了每次列出來的順序一樣，不然同一個錯誤訊息會忽前忽後。
  STRING_AGG(DISTINCT t.transfer_no, '、' ORDER BY t.transfer_no)  AS doc_nos
FROM public.transfers t
JOIN public.transfer_items ti ON ti.transfer_id = t.id
WHERE t.transfer_type = 'return_to_hq'
  AND t.status        = 'shipped'          -- 已送出、總倉還沒回覆
  AND COALESCE(t.notes, '') LIKE '[order return%'
  AND ti.out_movement_id IS NULL           -- ＝ 還沒扣過店家庫存
  AND ti.qty_shipped > 0
  AND ti.sku_id IS NOT NULL
GROUP BY t.tenant_id, t.source_location, ti.sku_id;

GRANT SELECT ON public.v_store_pending_returns TO authenticated;

COMMENT ON VIEW public.v_store_pending_returns IS
  '每家店每個 SKU「已送出退貨、總倉還沒回覆、而且還沒扣過庫存」的件數（乙案）。'
  '母體＝return_to_hq ＋ status=shipped ＋ notes 以 [order return 開頭 ＋ out_movement_id IS NULL。'
  'doc_nos＝占著這些量的退貨單單號（給「退不了」的錯誤訊息指路用，與 pending_qty 同一個母體）。'
  '⛔ 短收沖帳單（notes 以 [短收沖帳 開頭、生而 received）不在母體內，那是純記帳單。';

-- ----------------------------------------------------------------------------
-- 2. rpc_create_store_return —— 店家從商品下手建退貨單（不綁訂單、不動庫存）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_store_return(
  p_store_id  BIGINT,
  p_lines     JSONB,      -- [{"sku_id": 123, "qty": 3}, ...]
  p_reason    TEXT,       -- 少收 / 破損 / 過期 / 客人退（四選一，⛔ 不吃自由文字）
  p_operator  UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- 角色與租戶：寫法逐字沿用 rpc_create_order_return（20260801000000:71-73）
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := COALESCE(p_operator, auth.uid());
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_store_loc    BIGINT;
  v_store_name   TEXT;
  v_hq_loc       BIGINT;
  v_transfer_id  BIGINT;
  v_transfer_no  TEXT;
  v_line         JSONB;
  v_sku_id       BIGINT;
  v_qty          NUMERIC;
  v_sku_label    TEXT;
  v_on_hand      NUMERIC;
  v_pending      NUMERIC;
  v_pending_nos  TEXT;
  v_lock         RECORD;   -- 2026-09-04 第二輪：預鎖用（(店, SKU) 去重排序）
  v_need         RECORD;   -- 2026-09-04 第二輪：鎖到手之後逐 SKU 重驗用
  v_notes        TEXT;
  v_count        INT   := 0;
  v_total_qty    NUMERIC := 0;
  v_result_lines JSONB := '[]'::JSONB;
BEGIN
  -- 原因四選一（老闆 2026-09-04 逐字定：少收／破損／過期／客人退）
  IF p_reason IS NULL OR p_reason NOT IN ('少收','破損','過期','客人退') THEN
    RAISE EXCEPTION '退貨原因必須是「少收／破損／過期／客人退」其中一個，收到的是「%」',
      COALESCE(p_reason, '(空白)');
  END IF;

  -- 角色白名單逐字沿用 rpc_create_order_return（20260801000000:99-101）。
  -- ⚠️ 空字串仍在清單裡（＝進得了這道門），但它**不再是店別守門的例外**，見下面。
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','clerk','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create store return', v_role;
  END IF;

  SELECT location_id, name INTO v_store_loc, v_store_name
    FROM stores
   WHERE id = p_store_id AND tenant_id = v_tenant;
  IF v_store_loc IS NULL THEN
    RAISE EXCEPTION '門市 % 沒有設定倉庫位置（location_id），無法建退貨單', p_store_id;
  END IF;

  -- ==========================================================================
  -- 店別守門（2026-09-04 第二輪 · 阿審 P0）
  -- ==========================================================================
  -- 🔴 第一輪寫成「只有 store_manager/store_staff/clerk 才驗自己店」，那是照抄
  --   rpc_create_order_return（20260801000000:139-143）的形狀 —— 但**抄錯了殺傷力**：
  --   舊介面必須先挑一張既有的客人訂單，退的是那張單上的品項；本頁是**直接選店家、
  --   直接選商品**，所以「空白身分不驗店」在這裡等於「有 tenant_id、沒有 role 的
  --   登入者可以指定同公司任何一家店建退貨單」，48 小時自動同意
  --   （20260903010020）之後就真的把那家店的庫存扣掉了。
  --
  -- ⇒ 本函式改成：**只有總部三個角色可以代任一家店操作，其餘（含空白身分）
  --   一律要證明自己屬於該店。**
  --
  -- 「總部帳號可以代操」是本系統的既有慣例，不是我新開的口子，出處三處：
  --   ① 20260831000000:60-61（_is_branch_scoped_user 的檔頭）：
  --      「其餘（owner / admin / hq_manager / purchaser / assistant / '' legacy）都不鎖」
  --   ② 20260826010000:56-58（_assert_stocktake_store_scope）：
  --      「stores 為空的 legacy 帳號、含「總倉」者、HQ 角色不鎖」
  --   ③ 20260714000090:93-98（rpc_create_restock_request）：
  --      店端角色才比對 _jwt_store_ids()，HQ 角色直接過。
  -- 「自己店」的推導同樣沿用 _jwt_store_ids()（20260707000070:26）——
  --   本系統 JWT 沒有 store_id claim，只有 app_metadata.stores 的**店名**陣列。
  --
  -- ⚠️ 跟慣例不一樣的**那一點**（刻意的）：慣例把空白身分歸在「HQ 那一邊、不鎖」，
  --   本函式把它歸在「要驗」那一邊。理由就是上面那段殺傷力差異。
  --   ⇒ 代價：真的用空白身分的舊管理員帳號，在這一頁會被擋（訊息有講怎麼辦）。
  --     不做的代價：任何一個 role 掉了的 token 都能扣別家店的庫存。兩者取後者。
  -- ⛔ 舊函式 rpc_create_order_return 的同款寫法**本波不動**（那是別人的檔、
  --   而且它必須先挑既有訂單，殺傷面小），已登記技術債。
  IF v_role NOT IN ('owner','admin','hq_manager') THEN
    IF NOT (p_store_id = ANY (public._jwt_store_ids())) THEN
      RAISE EXCEPTION '這個帳號不能幫「%」建退貨單 —— 只有這家店自己的帳號、或總部帳號（owner／admin／hq_manager）可以。如果你就是這家店的人卻被擋，請總部確認你的帳號有掛到這家店。',
        v_store_name;
    END IF;
  END IF;

  -- 總倉 location 取法逐字沿用 rpc_create_order_return（20260801000000:122-131），
  -- 也與 48h 自動同意的母體（20260903010020:149-156）同一個口徑：
  -- type='central_warehouse' AND is_active ORDER BY id LIMIT 1（單數一個）。
  SELECT id INTO v_hq_loc
    FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN
    RAISE EXCEPTION '找不到啟用中的總倉，無法建退貨單';
  END IF;
  IF v_hq_loc = v_store_loc THEN
    RAISE EXCEPTION '這個帳號的位置就是總倉，不能退貨給自己';
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '請至少選一項商品';
  END IF;

  -- ==========================================================================
  -- 第 1 趟：**只檢查形狀、不讀庫存、不寫任何東西**
  --
  -- ⛔ 順序不可以顛倒成「先建單、邊檢查邊寫明細」（我第一版就是那樣，錯的）：
  --   第 2 趟的防線要讀 v_store_pending_returns，而那個 view 的母體是
  --   「status='shipped' ＋ notes 以 [order return 開頭 ＋ out_movement_id IS NULL」
  --   —— 本單自己**完全符合**。單建下去、明細寫進去之後，同一個交易裡再讀那個 view，
  --   就會把「這張單自己剛寫的行」也算成「已經在等回覆的量」
  --   ⇒ 同一張單重複選到同一個商品時，第二行會被自己擋掉（而且訊息完全看不出原因）。
  --   ⇒ 檢查全部做完才建單，順便也符合「要嘛整張成立、要嘛什麼都沒發生」。
  -- ⭐ 2026-09-04 第二輪把「讀庫存比數量」整段搬到第 2 趟（鎖之後）——
  --   在鎖之前讀到的數字隨時可能被別人改掉，比了也不算數。
  -- ==========================================================================
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku_id := (v_line ->> 'sku_id')::BIGINT;
    v_qty    := (v_line ->> 'qty')::NUMERIC;

    IF v_sku_id IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '品項資料不完整（商品 %、數量 %），請重新選一次', v_sku_id, v_qty;
    END IF;

    SELECT COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'')
             || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), s.sku_code)
      INTO v_sku_label
      FROM skus s
     WHERE s.id = v_sku_id AND s.tenant_id = v_tenant;
    IF v_sku_label IS NULL THEN
      RAISE EXCEPTION '找不到商品 %（或不屬於本公司）', v_sku_id;
    END IF;

    -- ⛔ 虛擬商品擋在這裡，理由見檔頭【四】③
    IF EXISTS (
      SELECT 1 FROM skus s JOIN products p ON p.id = s.product_id
       WHERE s.id = v_sku_id AND p.is_virtual
    ) THEN
      RAISE EXCEPTION '「%」是系統用的虛擬商品（沒有實體），不能用退貨頁退回總倉', v_sku_label;
    END IF;

    -- 檢查過的行先收進來，第 3 趟才真的寫（這一趟一個字都沒寫進資料庫）
    v_result_lines := v_result_lines || jsonb_build_object(
      'sku_id', v_sku_id,
      'sku_label', v_sku_label,
      'qty', v_qty
    );
    v_count     := v_count + 1;
    v_total_qty := v_total_qty + v_qty;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION '請至少選一項商品';
  END IF;

  -- ==========================================================================
  -- 第 2 趟：**先鎖再驗**（2026-09-04 第二輪 · 阿審 P1）
  --
  -- 🔴 第一輪是「讀 stock_balances → 讀 v_store_pending_returns → 比一比」，
  --   全程沒有鎖。兩個人（或同一個人按兩次）同時對同一家店同一個商品送退貨，
  --   兩邊都讀到「還沒有人在等」的舊數字、兩邊都通過，結果**加起來超過店裡有的量**
  --   ⇒ 總倉按同意時扣不動，兩張單都卡死（48h cron 每 30 分鐘重試一次也一樣失敗）。
  --
  -- ⭐ 為什麼「鎖 stock_balances」擋得住「兩張 transfers 互相看不到」：
  --   鎖是**排隊點**，不是要保護 stock_balances 本身（本函式一筆庫存都不寫，乙案）。
  --   PostgreSQL 預設 READ COMMITTED 下，B 交易卡在 FOR UPDATE 等 A 提交，
  --   放行之後 B **下一個 SELECT 會拿新的快照** ⇒ 讀 v_store_pending_returns 時
  --   看得到 A 剛寫進去的那張單。⇒ 「鎖住 → 重讀 → 再比」這個順序不可以顛倒，
  --   顛倒了就等於沒鎖。
  --   ⚠️ 餘額列不存在時 FOR UPDATE 鎖不到東西（沒有排隊點）—— 但那代表 on_hand 視同 0，
  --     下面一定擋下來（本次量 > 0），不會有漏網。同 20260904020010:233-234。
  --
  -- ⛔ 鎖序＝ORDER BY location_id, sku_id，與 20260904010000（✎修改實收）／010010（取貨）／
  --   010020（現場銷售）／20260904020010（本案同意扣庫存）**完全一致**，
  --   四支才不會各拿一半互相等（死鎖）。⛔ 只改一邊等於沒改。
  -- ==========================================================================
  FOR v_lock IN
    SELECT DISTINCT v_store_loc AS location_id, (l ->> 'sku_id')::BIGINT AS sku_id
      FROM jsonb_array_elements(p_lines) AS l
     ORDER BY 1, 2
  LOOP
    PERFORM 1
       FROM stock_balances
      WHERE tenant_id   = v_tenant
        AND location_id = v_lock.location_id
        AND sku_id      = v_lock.sku_id
      FOR UPDATE;
  END LOOP;

  -- 鎖到手才重讀、才比。⭐ 同一張單重複選到同一個商品要**先加總再比** ——
  --   逐行比會讓「每一行看起來都夠、加起來卻不夠」整批漏過去
  --   （同 20260904020010:252-254 那一課）。
  -- ⚠️ 這道防線**不是**新規則，是把「總倉同意那一刻扣不動就會失敗」（20260904020010）
  --   這件事提前講 —— 不擋的話店家可以退 100 件他只有 10 件的貨，
  --   那張單會永遠卡在總倉那邊按不下去。
  -- ⚠️ 它擋不住「送出之後才把貨賣掉」那一種（那要到同意那一刻才知道），
  --   所以退貨頁的進度列表另外做了即時比對示警。
  FOR v_need IN
    SELECT g.sku_id,
           g.need,
           COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'')
             || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''),
             s.sku_code, '品項#' || g.sku_id::TEXT) AS sku_label
      FROM (
        SELECT (l ->> 'sku_id')::BIGINT      AS sku_id,
               SUM((l ->> 'qty')::NUMERIC)   AS need
          FROM jsonb_array_elements(p_lines) AS l
         GROUP BY 1
      ) g
      LEFT JOIN skus s ON s.id = g.sku_id AND s.tenant_id = v_tenant
     ORDER BY g.sku_id
  LOOP
    SELECT COALESCE(on_hand, 0) INTO v_on_hand
      FROM stock_balances
     WHERE tenant_id = v_tenant AND location_id = v_store_loc AND sku_id = v_need.sku_id;
    v_on_hand := COALESCE(v_on_hand, 0);

    SELECT COALESCE(pending_qty, 0), doc_nos
      INTO v_pending, v_pending_nos
      FROM v_store_pending_returns
     WHERE tenant_id = v_tenant AND location_id = v_store_loc AND sku_id = v_need.sku_id;
    v_pending := COALESCE(v_pending, 0);

    IF v_on_hand < v_pending + v_need.need THEN
      -- 大聲擋下、整筆回滾（一張單都沒建、一筆明細都沒寫）。
      -- ⭐ 訊息要講得出「被誰占著」：只給數字的話，店家不知道要去看哪一張單。
      RAISE EXCEPTION '「%」退不了：店裡帳上 % 件，其中 % 件已經在等總倉回覆（單號 %），這次要退 % 件 —— 最多只能再退 % 件。',
        v_need.sku_label,
        trim_scale(v_on_hand),
        trim_scale(v_pending),
        COALESCE(v_pending_nos, '無'),
        trim_scale(v_need.need),
        trim_scale(GREATEST(v_on_hand - v_pending, 0));
    END IF;
  END LOOP;

  -- ==========================================================================
  -- 第 3 趟：檢查全過了，這時候才建單
  -- ==========================================================================

  -- notes：⛔ 前綴與格式不可改，理由見檔頭【三】
  v_notes := CASE WHEN p_reason = '破損'
                  THEN '[order return|破損]'
                  ELSE '[order return: ' || p_reason || ']'
             END;

  v_transfer_no := public._next_transfer_no();

  -- 建單欄位寫法沿用 rpc_create_order_return（20260801000000:161-171），
  -- 兩處刻意不同：
  --   ① customer_order_id 留 NULL（本頁不綁訂單，理由見檔頭【四】②）
  --   ② status 仍是 'shipped' —— 總倉那兩顆鈕與 48h cron 都只認 shipped，
  --      改成別的狀態＝總倉收件匣上看不到這張單。
  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, customer_order_id,
    requested_by, shipped_by, shipped_at,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_transfer_no, v_store_loc, v_hq_loc,
    'shipped', 'return_to_hq', NULL,
    v_user, v_user, NOW(),
    v_notes, v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  -- ⭐⭐ 乙案核心：這裡**刻意什麼庫存都不寫**。
  --   ⛔ 不呼叫 rpc_outbound（那是 rpc_create_order_return:248-257 在做的事）。
  --   out_movement_id 留 NULL —— 它同時就是「還沒扣過」這件事的判準，
  --   20260904020010（同意才扣）與 20260904020020（不同意零動作）都靠它認人。
  --   ⛔ 誰要在這裡補上 rpc_outbound，請先讀老闆 2026-09-04 裁示 2（檔頭【一】）。
  FOR v_line IN SELECT * FROM jsonb_array_elements(v_result_lines)
  LOOP
    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped,
      out_movement_id, created_by, updated_by
    ) VALUES (
      v_transfer_id,
      (v_line ->> 'sku_id')::BIGINT,
      (v_line ->> 'qty')::NUMERIC,
      (v_line ->> 'qty')::NUMERIC,
      NULL, v_user, v_user
    );
  END LOOP;

  RETURN jsonb_build_object(
    'transfer_id',  v_transfer_id,
    'transfer_no',  v_transfer_no,
    'store_id',     p_store_id,
    'store_name',   v_store_name,
    'reason',       p_reason,
    'lines',        v_count,
    'total_qty',    v_total_qty,
    'stock_moved',  FALSE,     -- ⭐ 乙案：送出這一刻一筆庫存都沒動
    'items',        v_result_lines
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_store_return(BIGINT, JSONB, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_store_return(BIGINT, JSONB, TEXT, UUID) IS
  '店家退貨頁：從商品下手建 return_to_hq 退貨單，⛔ 送出時一筆庫存都不動（老闆 2026-09-04 乙案）。'
  '庫存在總倉按「同意收回」那一刻才扣（20260904020010）；按「不同意」則零庫存動作（20260904020020）。'
  'notes 以 [order return 開頭 ⇒ 總倉那兩顆鈕與 48h 自動同意（20260903010020）零改動就吃得到。'
  'customer_order_id 留 NULL（不綁訂單）⇒ 不會誤動客人訂單狀態。'
  '原因四選：少收／破損／過期／客人退。虛擬商品一律擋（rpc_outbound 沒有虛擬守衛、會只出不進）。'
  '前置防線：先鎖 (店, SKU) 的 stock_balances 列、鎖到手才重讀在庫與「已在等回覆的量」，'
  '在庫 < 已在等回覆 ＋ 本次量 → 擋（訊息含占著量的單號、最多還能退幾件）。鎖只為讀一致，不寫庫存。'
  '店別守門：總部帳號（owner/admin/hq_manager）可代任一店；其餘含空白身分一律要通過 _jwt_store_ids()。';

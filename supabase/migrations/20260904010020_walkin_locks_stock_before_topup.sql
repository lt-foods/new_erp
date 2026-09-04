-- ============================================================================
-- 20260904010020：現場銷售補庫存之前先鎖住餘額列，鎖完重讀一次 on_hand
--
-- ⛔⛔ 先讀這一段再改任何一行：本檔的鎖跟 20260904010010（取貨）**性格相反**。
--     取貨那支：鎖完發現不夠 → **大聲失敗**，不准取。
--     本檔這支：鎖完發現不夠 → **多補一點**，照樣結帳成功。
--     ⛔ 不准把取貨那支的 RAISE 抄過來。抄過來就等於把老闆 2026-09-01 親自定的
--       「現場銷售永不因缺貨被擋」推翻掉 —— 那條規矩底下有一整段推導，見下方【二】。
--
-- ----------------------------------------------------------------------------
-- 【一】為什麼要有這一支（它是同一個 P0 的第三個入口）
-- ----------------------------------------------------------------------------
-- 20260904010000 讓「✎ 修改實收」往下改會真的扣店家庫存，20260904010010 把
-- 取貨那側鎖起來。審查第二輪（2026-09-04）指出扣庫存其實有**三個**入口，
-- 第三個是現場銷售 rpc_create_walkin_sale（20260901010010 起的 walkin 家族）。
--
-- 它原本只拿 advisory lock `walkinsale:租戶:店:商品`，接著**無鎖**讀 on_hand 與
-- 可賣量、用舊值算「要補幾件」。advisory lock 只擋得住「另一台收銀機」——
-- 改實收與取貨拿的是 `transfer:*` / 什麼都不拿，跟它是不同把鎖，不會互相等：
--
--     店裡 on_hand = 10
--     [現場銷售] 讀 on_hand = 10、可賣量 10，客人買 5 → 算出「不用補」  ┐
--     [取  貨 ] 鎖住餘額列、驗過 10 ≥ 10，寫 sale −10 → on_hand = 0     │
--     [現場銷售] 寫 sale −5 → trigger 這時才排到鎖 → 0 + (−5) = **−5** ⛔┘
--
-- 這正是老闆 2026-09-04「⛔ 不准扣成負的」要擋的東西，而且 20260901040000
-- 檔頭第 15-16 行自己就寫著「走 +N/−N 而不是負庫存，是因為 on_hand 被全站
-- 好幾道閘門讀著，讓它變負數會誤擋別人的取貨」—— 它的設計目標本來就是
-- 「絕不讓 on_hand 變負」，只是少了鎖，目標達不到。本檔補的就是那把鎖。
--
-- ----------------------------------------------------------------------------
-- 【二】⛔ 老闆的鐵律逐字保留：現場銷售永不因缺貨被擋
-- ----------------------------------------------------------------------------
-- Alex 2026-09-01（20260901040000 檔頭第 5-6 行逐字抄回來）：
--   「其實根本不用介面上選補貨，背後幫它自動補就好，反正就是 +n -n，
--     只要在銷售頁上顯示貨不足但是它也可以結單。」
--
-- 為什麼「不擋」是對的（同檔第 8-13 行，逐字保留）：
--   客人就站在櫃台前、東西在店員手上，貨**一定會**離開這家店。系統擋下來不會
--   讓貨留下，只會讓帳跟現實脫節 —— 店員繞過系統手收現金，那筆交易就完全消失
--   （沒有銷售、沒有扣庫存、沒有日結）。把它記成「+N 入帳 → −N 賣掉」才是那
--   一刻真正發生的事。
--
-- ⇒ 本檔**只加鎖、不加守衛**。加完之後這支函式能失敗的理由，跟加之前
--   一模一樣（分店帳號賣別店的貨、單價 ≤ 0、空購物車、賣給【內部】店容器帳號、
--   不可新增訂單的會員）—— **數量仍然不是其中之一**。
--
-- ----------------------------------------------------------------------------
-- 【三】鎖了為什麼就不會變負（不必再加任何檢查）
-- ----------------------------------------------------------------------------
-- 可賣量 _sku_walkin_qty（20260901020000:68）＝
--     GREATEST(on_hand − promised − (pool_claimed − pool_arrived), 0)
-- pool_arrived 是 pool_claimed 的子集：兩者在 _sku_commitment（20260816000000）
-- 是同一個 base、同樣 `mtype='store_internal' AND kind<>'offset'`，只差狀態條件 ——
-- pool_claimed 是 `NOT IN (cancelled, expired, transferred_out, completed)`（:123-126），
-- pool_arrived 是 `IN (ready, partially_completed)`（:127-130），後者被前者完全包住，
-- 且 base 已經濾掉 qty ≤ 0（:105）⇒ 括號內恆 ≥ 0 ⇒ **可賣量 ≤ on_hand**。
--
-- 這支對庫存的淨影響：
--     補進來 v_add = GREATEST(需求 − 可賣量, 0)，賣掉 −需求
--     ⇒ 淨變動 = v_add − 需求 = −LEAST(可賣量, 需求) ≥ −on_hand
-- ⇒ 只要 on_hand 與可賣量是**當下鎖住、沒有人能動**的值，賣完不可能低於 0。
--   會變負，唯一的原因就是那兩個數字是舊的。所以本檔要做的只有一件事：
--   **鎖了再讀**。讀到新鮮的數字，補的量自然就夠。
--
-- 反過來說，讀到偏低的舊值（例如剛好有人正在補貨）只會讓它「多補一點」——
-- 補進來的當場全部賣掉，淨變動仍是 −LEAST(可賣量, 需求)，不會多也不會少。
-- 這個方向本來就安全，不需要處理。
--
-- ----------------------------------------------------------------------------
-- 【四】鎖序：⛔ 三支必須一致，只改一支等於沒改
-- ----------------------------------------------------------------------------
-- 20260904010000（改實收）、20260904010010（取貨）、本檔（現場銷售）會鎖到
-- 同一批 (location_id, sku_id)。三支一律：
--     ORDER BY location_id, sku_id 去重後逐列 FOR UPDATE，放在進主迴圈之前
-- 各用各的順序，兩人各拿一半就互相等到天亮（死鎖）。
-- 現場銷售永遠只碰 v_store.location_id 一個倉，所以實際上是照 sku_id 排；
-- location_id 仍然寫進 ORDER BY，讓三支的規則長得一模一樣。
--
-- 與既有 advisory lock 的先後：本檔的餘額列鎖放在
--   `walkin_sale_seq:店`（取單號，基底 20260901040000:171）之後、
--   `walkinsale:租戶:店:商品`（基底 :196，在主迴圈裡）之前。
-- 全庫只有現場銷售家族會拿這兩把 advisory lock —— 查過：
--     git grep -n "walkinsale:\|walkin_sale_seq:" HEAD -- supabase/migrations
--   8 個命中全部落在 20260901010010 / 20260901020000 / 20260901030000 /
--   20260901040000，也就是同一支函式的四個版本，沒有第二支函式在拿。
-- ⇒ 拿 advisory lock 的順序全站一致，三支拿餘額列鎖的順序又一致 ⇒ 湊不出互等的環。
--
-- ----------------------------------------------------------------------------
-- 【五】餘額列不存在時鎖不到東西 —— 這件事查過了，安全
-- ----------------------------------------------------------------------------
-- 該 (倉, 商品) 從沒進過貨時 stock_balances 沒有那一列，FOR UPDATE 鎖不到。
-- 此時讀到的 on_hand 是 0（原本就 COALESCE 成 0）⇒ 可賣量 0 ⇒ 補的量 = 全部需求
-- ⇒ 淨變動 0 ⇒ 不可能變負。就算此刻剛好有人正在建那一列（收貨、改實收往上補），
-- 對方加多少就是多少，我們 +N/−N 淨變動 0，加起來仍然是對的。
--
-- ⚠ 審查建議「先 INSERT ... ON CONFLICT DO NOTHING 把列生出來再鎖」——
--   **刻意不做**：那會在庫存總覽長出一堆 on_hand = 0 的空列（現在只有真的
--   進過貨才有列），是看得見的行為改變；而上面已經證明不做也不會變負。
--   ⇒ 用不到的代價不要付。
--
-- ----------------------------------------------------------------------------
-- 【六】代價（老闆要知道的那一面）
-- ----------------------------------------------------------------------------
-- 做了：同一家店同一個商品，若總倉正在改實收／別的客人正在取貨，收銀機會多等
--       那筆交易做完（通常是零點幾秒）才結帳成功。**不會失敗，只會慢一下。**
-- 不做：就是上面那張圖 —— 現場銷售把 on_hand 扣成負數。負庫存會讓取貨閘門的
--       實體守衛把**別的客人**的貨擋下來（明明架上有貨卻取不了），而且現場銷售
--       這支本來的設計就是要避免這件事。
--
-- ----------------------------------------------------------------------------
-- 【七】基底
-- ----------------------------------------------------------------------------
-- 20260901040000_walkin_auto_topup_never_blocks.sql:43（rpc_create_walkin_sale
-- 第 4 版）。用定義鏈查法確認它是最後一支：
--     git grep -nE "CREATE (OR REPLACE )?FUNCTION (public\.)?rpc_create_walkin_sale" \
--       HEAD -- supabase/migrations | sort
--   → 20260901010010:53 / 20260901020000:106 / 20260901030000:30 / 20260901040000:43
--   最後一行就是基底。（20260901010030 是 rpc_walkin_stock_topups 那支稽核報表，
--    20260901010020 是 rpc_pos_search_products，都沒有重定義本函式。）
--
-- 基底函式本體 347 行**逐字保留**，只在兩處插入：
--   ① DECLARE 加 1 個變數（v_lock）
--   ② 第 3 段主迴圈**之前**插入預鎖段
-- 既有的參數驗證、店家守衛、會員守衛、單號規則、補帳算式、from_pool 夾擠、
-- 開單、sale movement、扣現貨池、取貨事件、回傳欄位 —— 一行都沒有改。
-- ⛔ 特別是 `v_add := GREATEST(v_s.need - v_cap, 0)` 這一行原封不動：
--   本檔改的是「v_cap 讀的時候有沒有鎖」，不是「怎麼算補多少」。
--
-- ----------------------------------------------------------------------------
-- 【八】上線順序（⛔ 不可顛倒）
-- ----------------------------------------------------------------------------
--   1️⃣ 20260904010000（改實收會動庫存）
--   2️⃣ 20260904010010（取貨先鎖再扣）
--   3️⃣ 本檔（現場銷售先鎖再補）
--   4️⃣ 跑 D:\1人公司\公司\01_進行中\實收連動_修復不一致列_2026-09-04.sql
--      第 ① 段預覽 → 第 ② 段修復 → 第 ③ 段驗證
--   ⚠️ 第 4 步**不是選配**：純紀錄期間留下的「帳面實收 ≠ 實際入庫」歷史列，
--     在畫面上重存同一個數字不會有反應（20260904010000 開頭就 CONTINUE 掉了），
--     只有那支腳本修得掉。完整說明在那支腳本的檔頭。
--
-- ----------------------------------------------------------------------------
-- 【九】Rollback
-- ----------------------------------------------------------------------------
-- CREATE OR REPLACE 回 20260901040000:43-389 那一版即可（沒有動 schema、
-- 沒有新增欄位、沒有改 CHECK；純函式覆寫）。
-- ⚠ 但 20260904010000 / 20260904010010 / 本檔**三支是一組**：回滾任一支，
--   負庫存的洞就從三邊變兩邊 —— 要回就三支一起回。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_create_walkin_sale(
  p_store_id        BIGINT,
  p_lines           JSONB,
  p_operator        UUID,
  p_member_id       BIGINT  DEFAULT NULL,
  p_customer_name   TEXT    DEFAULT NULL,
  p_payment_method  TEXT    DEFAULT 'cash',
  p_discount_amount NUMERIC DEFAULT 0,
  p_notes           TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_role   TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores  JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_store      stores%ROWTYPE;
  v_now        TIMESTAMPTZ := NOW();
  v_member     members%ROWTYPE;
  v_member_id  BIGINT;
  v_name       TEXT;
  v_l          RECORD;
  v_s          RECORD;
  v_plain      NUMERIC;
  v_add        NUMERIC;
  v_cap        NUMERIC;
  v_from_pool  NUMERIC;
  v_pool_plan  JSONB := '{}'::jsonb;
  v_pool_total NUMERIC := 0;
  v_added      JSONB := '[]'::jsonb;
  v_add_total  NUMERIC := 0;
  v_c          RECORD;
  v_on_hand    NUMERIC;
  v_campaign   BIGINT;
  v_channel    BIGINT;
  v_ci         BIGINT;
  v_order_id   BIGINT;
  v_order_no   TEXT;
  v_seq        INT;
  v_item_id    BIGINT;
  v_move_id    BIGINT;
  v_item_ids   BIGINT[] := ARRAY[]::BIGINT[];
  v_items_out  JSONB := '[]'::jsonb;
  v_total      NUMERIC := 0;
  v_discount   NUMERIC := GREATEST(COALESCE(p_discount_amount, 0), 0);
  -- 實體庫存鎖（20260904010020）：鎖序與 20260904010000 / 20260904010010 一致
  v_lock       RECORD;
BEGIN
  -- ==========================================================================
  -- 1. 參數與權限
  -- ==========================================================================
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '缺少操作人';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '沒有任何品項，無法結帳';
  END IF;

  SELECT * INTO v_store FROM stores WHERE id = p_store_id;
  IF NOT FOUND OR v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 不存在或未綁定倉別', p_store_id;
  END IF;

  -- 店家守衛：逐字對齊 rpc_record_pickup（20260813000000）/ rpc_create_spot_sale。
  -- ⚠ 一律用 app_metadata.stores（**店名陣列**），不可以用 store_id ——
  --    線上 33 個分店帳號沒有任何一個有 store_id（20260808000020）。
  IF v_jwt_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉')
     AND NOT (v_my_stores ? v_store.name) THEN
    RAISE EXCEPTION 'wrong_store: 這是「%」的庫存，分店帳號只能賣自己店的貨', v_store.name;
  END IF;

  -- 逐列驗證（值不合法要在動任何一筆庫存之前就擋掉）
  FOR v_l IN
    SELECT (e ->> 'sku_id')::BIGINT                        AS sku_id,
           (e ->> 'qty')::NUMERIC                          AS qty,
           (e ->> 'unit_price')::NUMERIC                   AS unit_price,
           COALESCE((e ->> 'add_stock_qty')::NUMERIC, 0)   AS add_qty,
           ord
      FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS t(e, ord)
     ORDER BY ord
  LOOP
    IF v_l.sku_id IS NULL OR NOT EXISTS (SELECT 1 FROM skus WHERE id = v_l.sku_id) THEN
      RAISE EXCEPTION '第 % 列：品項 % 不存在', v_l.ord, COALESCE(v_l.sku_id::TEXT, 'NULL');
    END IF;
    IF v_l.qty IS NULL OR v_l.qty <= 0 OR v_l.qty <> FLOOR(v_l.qty) THEN
      RAISE EXCEPTION '第 % 列：數量必須是正整數', v_l.ord;
    END IF;
    -- 零元守衛的同一個理由（20260815000000）：$0 = 把貨白送出去。
    -- 現場銷售當場收錢，沒有「事後補填金額」的機會，所以擋在這裡。
    IF v_l.unit_price IS NULL OR v_l.unit_price <= 0 THEN
      RAISE EXCEPTION '第 % 列：單價必須大於 0', v_l.ord;
    END IF;
    IF v_l.add_qty < 0 OR v_l.add_qty <> FLOOR(v_l.add_qty) THEN
      RAISE EXCEPTION '第 % 列：補庫存數量必須是非負整數', v_l.ord;
    END IF;
  END LOOP;

  -- 收件人：有帶會員就用會員，沒有就用該店的「現場客」共用假會員
  IF p_member_id IS NOT NULL THEN
    SELECT * INTO v_member FROM members WHERE id = p_member_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION '會員 % 不存在', p_member_id;
    END IF;
    IF COALESCE(v_member.member_type, '') = 'store_internal' THEN
      RAISE EXCEPTION '不能把貨賣給【內部】店帳號 —— 那是現貨池容器，不是客人';
    END IF;
    IF COALESCE(v_member.no_new_order, FALSE) THEN
      RAISE EXCEPTION '會員「%」已被標記為不可新增訂單', COALESCE(v_member.name, p_member_id::TEXT);
    END IF;
    v_member_id := v_member.id;
    v_name      := COALESCE(NULLIF(TRIM(p_customer_name), ''), v_member.name);
  ELSE
    v_member_id := public._walkin_member(v_store.tenant_id, p_store_id);
    v_name      := COALESCE(NULLIF(TRIM(p_customer_name), ''), '現場客');
  END IF;

  -- ==========================================================================
  -- 2. 先取單號
  --
  -- 刻意排在開單之前：缺貨補帳寫的 manual_adjust 要在 reason 裡帶單號，
  -- 事後才對得回「哪一筆現場銷售補的」（稽核報表 rpc_walkin_stock_topups
  -- 就是靠這個字串）。晚一步生號的話那些 movement 只剩時間可以猜。
  --
  -- MAX-based，不用 COUNT(*)+1 —— 單被硬刪後 COUNT 會倒退、重發已用過的號碼
  -- 撞 unique（20260813000010 湖口 RR-435 事故）。
  -- ==========================================================================
  PERFORM pg_advisory_xact_lock(hashtext('walkin_sale_seq:' || p_store_id::TEXT));
  SELECT COALESCE(MAX(substring(order_no FROM '^WS-' || p_store_id::TEXT || '-([0-9]+)$')::INT), 0) + 1
    INTO v_seq
    FROM customer_orders
   WHERE tenant_id = v_store.tenant_id
     AND order_no ~ ('^WS-' || p_store_id::TEXT || '-[0-9]+$');
  -- lpad 超寬會截斷（lpad('10001',4)='1000'），寬度要跟著位數長
  v_order_no := 'WS-' || p_store_id::TEXT || '-' ||
                LPAD(v_seq::TEXT, GREATEST(length(v_seq::TEXT), 4), '0');

  -- ==========================================================================
  -- 3. 逐 SKU：鎖 → 補庫存（選配）→ 可賣量閘門 → 記下要從池子扣多少
  --
  -- 依 sku_id 排序取鎖，兩個櫃台同時結帳到同一組商品時不會互相死鎖。
  -- 這一整段**必須在寫任何 sale movement 之前跑完**：sale 會把 on_hand 打下去，
  -- 之後再算 _sku_free_qty 就不是「這批貨賣掉前的自由量」了，from_pool 會算錯。
  -- ==========================================================================
  -- ==========================================================================
  -- 20260904010020：**鎖了再讀** —— 先把這次會碰到的餘額列鎖起來
  --   （本檔唯一新增的行為，完整推導見檔頭）
  --
  -- ⛔ 這裡只鎖、**不擋**。鎖的用途是讓下面那兩個數字（on_hand 與 v_cap 可賣量）
  --   在讀的當下沒有人能動 —— 讀到新鮮的值，「缺多少補多少」自然就補得夠。
  --   ⛔ 不准在這裡（或這個迴圈裡）加任何數量相關的 RAISE：
  --     **現場銷售永不因缺貨被擋**（Alex 2026-09-01；檔頭【二】逐字保留）。
  --     20260904010010（取貨）鎖完不夠是大聲失敗 —— 那是**相反的性格**，
  --     它守的是「客人拿走不存在的貨」，這裡守的是「帳跟現實脫節」。
  --     ⛔ 不要抄錯邊。
  --
  -- ⛔ ORDER BY location_id, sku_id 這個順序與 20260904010000（✎ 修改實收）、
  --   20260904010010（取貨）完全一致 —— 三支會鎖到同一批餘額列，各用各的順序
  --   就會各拿一半、互相等到天亮（死鎖）。只改一支等於沒改。
  --   現場銷售永遠只碰 v_store.location_id 一個倉，所以實際上是照 sku_id 排；
  --   location_id 照樣寫進 ORDER BY，讓三支的規則長得一模一樣。
  --
  -- 位置：放在主迴圈**之前**，這次要碰的列一次鎖齊（同另外兩支）。
  -- 迴圈裡那把 advisory lock（walkinsale:*）保留 —— 它擋的是另一台收銀機，
  -- 跟餘額列鎖擋的東西不同，兩個都要。
  --
  -- 餘額列不存在時 FOR UPDATE 鎖不到任何東西 —— 那代表 on_hand 視同 0、
  -- 可賣量 0，於是整筆需求都會被補進來、當場賣掉，淨變動 0，不可能變負
  -- （檔頭【五】有完整推導；那裡也寫了為什麼不先 INSERT 一列空的）。
  -- ==========================================================================
  FOR v_lock IN
    SELECT DISTINCT v_store.location_id            AS location_id,
                    (e ->> 'sku_id')::BIGINT       AS sku_id
      FROM jsonb_array_elements(p_lines) AS t(e)
     ORDER BY 1, 2
  LOOP
    PERFORM 1
       FROM stock_balances
      WHERE tenant_id   = v_store.tenant_id
        AND location_id = v_lock.location_id
        AND sku_id      = v_lock.sku_id
      FOR UPDATE;
  END LOOP;

  FOR v_s IN
    SELECT (e ->> 'sku_id')::BIGINT                      AS sku_id,
           SUM((e ->> 'qty')::NUMERIC)                   AS need,
           SUM(COALESCE((e ->> 'add_stock_qty')::NUMERIC, 0)) AS add_qty
      FROM jsonb_array_elements(p_lines) AS t(e)
     GROUP BY 1
     ORDER BY 1
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext(format('walkinsale:%s:%s:%s',
      v_store.tenant_id, p_store_id, v_s.sku_id)));

    -- ---- 先算「不補的話能賣幾件」 ----
    -- 承諾分項與在庫一次取齊：補帳上限、from_pool、錯誤訊息都要用。
    SELECT * INTO v_c FROM public._sku_commitment(p_store_id, ARRAY[v_s.sku_id]);
    SELECT COALESCE(sb.on_hand, 0) INTO v_on_hand
      FROM stock_balances sb
     WHERE sb.tenant_id   = v_store.tenant_id
       AND sb.location_id = v_store.location_id
       AND sb.sku_id      = v_s.sku_id;
    -- 沒有 balance 列時 SELECT INTO 給的是 NULL，不是 0
    v_on_hand := COALESCE(v_on_hand, 0);

    -- ★ 可賣量：**不扣 waiting**（見 20260901020000 檔頭）。canonical 算法在
    --   _sku_walkin_qty，這裡一定要呼叫它、不要就地抄公式 —— 列表
    --   （rpc_pos_search_products）跟這道閘門各算各的，就是「列表寫可用 3、
    --   視窗說 0」那個坑。
    v_cap := public._sku_walkin_qty(p_store_id, v_s.sku_id);

    -- ---- 缺貨自動補帳：缺多少補多少，補進來的當場全部賣掉 ----
    --
    -- Alex 2026-09-01：「其實根本不用介面上選補貨，背後幫它自動補就好，
    --   反正就是 +n -n，只要在銷售頁上顯示貨不足但是它也可以結單。」
    --
    -- 為什麼「不擋」是對的：客人就站在櫃台前、東西在店員手上，貨**一定會**離開
    --   這家店。系統擋下來不會讓貨留下，只會讓帳跟現實脫節。把它記成
    --   「+N 入帳 → −N 賣掉」才是那一刻真正發生的事。
    --   （同 CLAUDE.md 空中轉出庫 p_allow_negative 的理由：「貨實際上離開轉出店了，
    --     記下這筆出庫比拒絕記錄準確」。這裡走 +N/−N 而不是負庫存，是因為
    --     on_hand 被全站好幾道閘門讀著，讓它變負數會誤擋別人的取貨。）
    --
    -- 代價是帳面差異被抹平（on_hand 淨變化 0），所以**紀錄就是唯一的訊號**：
    --   每一筆都寫 manual_adjust ＋ reason 帶單號，`/pos/topups` 是那份稽核清單，
    --   同一家店常態性補帳會在那裡跳出來提醒去盤點。刪那支報表＝這個口就沒人看著了。
    --
    -- p_lines[].add_stock_qty 已經沒有作用（保留只為了不讓舊版前端送過來時報錯）：
    --   補多少完全由「缺多少」決定，店員填不了、也不用填。
    --
    -- ⚠ 沒有角色守衛是刻意的：一旦自動化，擋 store_staff 就等於「店員結不了帳」，
    --   而結不了帳的後果是貨照樣出去、系統上沒有這筆。操作人記在 movement 上。
    v_add := GREATEST(v_s.need - v_cap, 0);

    IF v_add > 0 THEN
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, movement_type,
        unit_cost, reason, operator_id
      ) VALUES (
        v_store.tenant_id, v_store.location_id, v_s.sku_id, v_add, 'manual_adjust',
        -- 成本一定要帶：沒帶的話該倉 avg_cost 若是 0，後面那筆 sale 的 COGS
        -- 就是 0、毛利虛高（同 _air_ship_order_items 的 p_fallback_unit_cost）
        public._current_cost_price(v_store.tenant_id, v_s.sku_id),
        '現場銷售即時入帳 ' || v_order_no || '（結帳時架上有貨、帳上沒有，系統自動補）',
        p_operator
      ) RETURNING id INTO v_move_id;

      v_add_total := v_add_total + v_add;
      v_added := v_added || jsonb_build_object(
        'sku_id', v_s.sku_id, 'qty', v_add, 'movement_id', v_move_id);

      -- 補進來的量 1:1 加到在庫與可賣量（promised / 池子都沒動）
      v_on_hand := v_on_hand + v_add;
      v_cap     := v_cap + v_add;
    END IF;

    -- 完全不動池子就能賣的量（要從池子吃掉多少，拿這個當基準）
    v_plain := GREATEST(v_on_hand - COALESCE(v_c.promised, 0)
                        - COALESCE(v_c.pool_claimed, 0), 0);

    -- 超出「不動池子的量」的部分＝從【內部】店已到貨池子賣掉的，開完單要扣池子。
    -- 夾在 pool_arrived 以內：叫 _consume_internal_pool 吃超過池子有的量，
    -- 單頭 notes 會寫出一個根本沒發生的數字。
    v_from_pool := LEAST(GREATEST(v_s.need - v_plain, 0), COALESCE(v_c.pool_arrived, 0));
    IF v_from_pool > 0 THEN
      v_pool_plan  := v_pool_plan || jsonb_build_object(v_s.sku_id::TEXT, v_from_pool);
      v_pool_total := v_pool_total + v_from_pool;
    END IF;
  END LOOP;

  -- ==========================================================================
  -- 4. 開單（sentinel trio → 單頭 → 品項 + sale movement）
  -- ==========================================================================
  v_campaign := public._restock_sentinel_campaign(v_store.tenant_id);
  v_channel  := public._restock_sentinel_channel(v_store.tenant_id, p_store_id);

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id,
    nickname_snapshot, pickup_store_id, status,
    ready_at, completed_at, ordered_at,
    order_kind, order_type, payment_method, discount_amount, notes,
    created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_store.tenant_id, v_order_no, v_campaign, v_channel, v_member_id,
    v_name, p_store_id, 'completed',
    v_now, v_now, v_now,
    -- ⛔ order_kind 維持 'normal'：全站 188 處用 `order_kind='normal' OR IS NULL`
    --    當口徑，新 kind 會讓現場銷售從營收 / 商品分析整批消失。
    'normal', 'regular', NULLIF(TRIM(p_payment_method), ''), v_discount,
    '【現場銷售】門市臨櫃結帳，當場交貨扣庫存' ||
      CASE WHEN v_add_total > 0
             THEN E'\n其中 ' || v_add_total || ' 件結帳時帳上沒有，系統自動補帳入庫（見 /pos/topups）'
           ELSE '' END ||
      CASE WHEN v_pool_total > 0
             THEN E'\n其中 ' || v_pool_total || ' 件來自【內部】' || v_store.name || '現貨池（已從池子扣除）'
           ELSE '' END ||
      COALESCE(E'\n' || NULLIF(TRIM(p_notes), ''), ''),
    p_operator, p_operator, v_now, v_now
  ) RETURNING id INTO v_order_id;

  -- 逐列：品項（直接 picked_up）→ sale movement → 回填 pickup_movement_id。
  -- 欄位與寫法逐字對齊 rpc_record_pickup 的「整行取」分支，撤銷取貨 / 退貨 /
  -- 月結 / 成本才會把它當成一般的取貨看待。
  FOR v_l IN
    SELECT (e ->> 'sku_id')::BIGINT      AS sku_id,
           (e ->> 'qty')::NUMERIC        AS qty,
           (e ->> 'unit_price')::NUMERIC AS unit_price,
           ord
      FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS t(e, ord)
     ORDER BY ord
  LOOP
    v_ci := public._restock_sentinel_campaign_item(
              v_store.tenant_id, v_campaign, v_l.sku_id, v_l.unit_price);

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_store.tenant_id, v_order_id, v_ci, v_l.sku_id, v_l.qty, v_l.unit_price,
      'picked_up', 'walk_in', p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_item_id;

    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, movement_type,
      source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
    ) VALUES (
      v_store.tenant_id, v_store.location_id, v_l.sku_id, -v_l.qty, 'sale',
      'customer_order', v_order_id, v_item_id,
      format('現場銷售 order=%s item=%s', v_order_id, v_item_id), p_operator
    ) RETURNING id INTO v_move_id;

    UPDATE customer_order_items
       SET pickup_movement_id = v_move_id
     WHERE id = v_item_id;

    v_item_ids  := v_item_ids || v_item_id;
    v_total     := v_total + v_l.qty * v_l.unit_price;
    v_items_out := v_items_out || jsonb_build_object(
      'item_id', v_item_id, 'sku_id', v_l.sku_id, 'qty', v_l.qty,
      'unit_price', v_l.unit_price, 'subtotal', v_l.qty * v_l.unit_price);
  END LOOP;

  -- ==========================================================================
  -- 5. 扣【內部】店現貨池
  --
  -- 不扣的話同一批貨掛兩份承諾：池子還寫著 ×N、但貨已經賣掉了 —— 就是
  -- 2026-08-11 忠順「池子掛 ×10、實際只剩 2」那件事。扣法沿用共用 helper，
  -- **不要再抄一份拆行邏輯**（CLAUDE.md 明文）。
  -- ==========================================================================
  FOR v_s IN SELECT key::BIGINT AS sku_id, value::TEXT::NUMERIC AS qty
               FROM jsonb_each(v_pool_plan)
  LOOP
    PERFORM public._consume_internal_pool(
      p_store_id, v_s.sku_id, v_s.qty, p_operator, v_now,
      '[已現場售出 ' || v_order_no || ']');
  END LOOP;

  -- ==========================================================================
  -- 6. 取貨事件
  --
  -- ⚠ 這一段不能省：rpc_undo_pickup 第一件事就是找最後一筆取貨事件，
  --    找不到會直接 RAISE「沒有取貨事件可撤銷」→ 店員按錯就救不回來。
  -- ==========================================================================
  INSERT INTO order_pickup_events (
    tenant_id, order_id, pickup_store_id, event_type, item_ids, notes, created_by
  ) VALUES (
    v_store.tenant_id, v_order_id, p_store_id, 'picked_up',
    to_jsonb(v_item_ids), '現場銷售 ' || v_order_no, p_operator
  );

  RETURN jsonb_build_object(
    'order_id',       v_order_id,
    'order_no',       v_order_no,
    'member_id',      v_member_id,
    'customer_name',  v_name,
    'items',          v_items_out,
    'items_total',    v_total,
    'discount',       v_discount,
    'total',          GREATEST(v_total - v_discount, 0),
    'payment_method', NULLIF(TRIM(p_payment_method), ''),
    'from_pool',      v_pool_total,
    'stock_added',    v_added
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_walkin_sale(BIGINT, JSONB, UUID, BIGINT, TEXT, TEXT, NUMERIC, TEXT) IS
  '現場銷售（門市臨櫃結帳）：多品項、當場交貨扣庫存，開一張 WS- 顧客訂單'
  '（單頭 completed、品項 picked_up、每列一筆 sale movement）。'
  '**數量不會擋結帳**：帳上不夠的部分自動寫 manual_adjust 補進來再賣掉'
  '（on_hand 淨變化 0，reason 帶單號，稽核看 /pos/topups）。'
  '成交後扣【內部】店已到貨現貨池。'
  '20260904010020 起：算補帳量之前先鎖住 stock_balances 餘額列，'
  '讀到的 on_hand／可賣量才不會是舊值（否則與取貨／改實收併發會扣成負庫存）。'
  '⛔ 那把鎖**只是為了讀到新鮮數字**，不是閘門 —— 不准在它後面加任何'
  '會讓結帳失敗的數量守衛（Alex 2026-09-01「顯示貨不足但是它也可以結單」）。'
  '20260904010020。';

REVOKE ALL ON FUNCTION public.rpc_create_walkin_sale(BIGINT, JSONB, UUID, BIGINT, TEXT, TEXT, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_walkin_sale(BIGINT, JSONB, UUID, BIGINT, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;

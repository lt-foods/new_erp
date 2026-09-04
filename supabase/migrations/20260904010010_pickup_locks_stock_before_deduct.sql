-- ============================================================================
-- 20260904010010：取貨扣庫存前先鎖住餘額列，鎖完重驗一次夠不夠
--
-- 【為什麼要有這一支】
-- 20260904010000 讓「✎ 修改實收」往下改時會真的從店裡扣庫存。扣庫存這件事
-- 從此有了**兩個入口**（取貨、改實收），而這兩個入口都是「先讀 on_hand 判斷
-- 夠不夠 → 再寫異動」，中間**沒有任何鎖**。兩人同時做就會這樣：
--
--     [改實收] 讀 on_hand = 5，準備扣 3            ┐
--     [取 貨 ] 閘門讀 on_hand = 5，準備取 5        │ 兩邊都覺得自己夠
--     [改實收] 寫 −3 → on_hand = 2  (commit)      │
--     [取 貨 ] 寫 sale −5 → on_hand = **−3**  ⛔  ┘ 貨變負的，客人拿了不存在的貨
--
-- 老闆 2026-09-04 裁示「⛔ 不准扣成負的」。20260904010000 已經把改實收那側
-- 鎖起來了（守衛 D），但只鎖一邊等於沒鎖 —— 另一邊照樣可以趁隙寫進去。
-- 所以取貨這側必須一起補，兩支才構成一道完整的防線。
--
-- 【為什麼 trigger 自己的 FOR UPDATE 不夠】
-- trg_apply_movement（20260422120003:212-251）確實有 SELECT ... FOR UPDATE，
-- 但它保護的是「兩筆異動的加總不會互相蓋掉」，**不是**「餘額不會變負」——
-- 它只做 on_hand + NEW.quantity，一個下限都沒有。真正的下限檢查一直在呼叫端。
--
-- 【鎖序：⛔ 三支必須一致，不可以只改一邊】
-- 扣庫存的入口有三個（第三個是現場銷售，第二輪審查才抓到）：
--     ① 20260904010000  rpc_adjust_received_transfer  ✎ 修改實收
--     ② 本檔            rpc_record_pickup             取貨
--     ③ 20260904010020  rpc_create_walkin_sale        現場銷售（門市臨櫃結帳）
-- 三支會鎖到同一批 (location_id, sku_id)。若各用各的迴圈順序，兩人各拿一半就
-- 互相等到天亮（死鎖）。三支一律：
--     ORDER BY location_id, sku_id 去重後逐列 FOR UPDATE
-- 而且都放在「進主迴圈之前」，先把這次要碰的列一次鎖齊。
--
-- ⚠ 但三支的**性格不同**，⛔ 不要抄錯邊：本檔與改實收是「不夠就大聲失敗」，
--   現場銷售是「不夠就多補一點照樣結帳」（老闆 2026-09-01 親自定的：客人站在
--   櫃台前、貨一定會離開這家店，擋下來只會讓帳跟現實脫節）。
--   ⛔ 不要把本檔的 RAISE 抄到現場銷售那支去。
--
-- 【豁免口徑逐字對齊取貨閘門，⛔ 不可以比閘門嚴】
-- is_order_item_pickup_ready 的門市實體守衛（20260901020000:266-283）刻意
-- 豁免兩種單：member_type='store_internal' 的容器單（RR- / OV- / AB- /
-- 【內部】xx 店）與 order_kind='offset' 的抵減單。理由是它們被排除在「已承諾」
-- 母體之外，再要它們自己過 on_hand 守衛會被擋死。
-- ⚠ 本檔這一段是「把閘門**已經有的**判準，在寫入前用鎖再確認一次」，不是新規則。
--   嚴一格就會擋掉閘門明明放行的正常取貨 —— 現貨池單第一個卡死。
--
-- 【對正常取貨的影響：零】
-- 閘門的實體守衛算的是「跨團累計承諾 ≤ on_hand」，比本檔的「本次取貨量 ≤
-- on_hand」**更嚴**。閘門放行得了的，本檔一定也放行得了。本檔只會在
-- 「閘門讀完之後、寫入之前，貨被別人扣走」這個瞬間擋下來 —— 那本來就該擋。
--
-- 【基底】
-- 20260819000000_gift_exempt_zero_price_guard.sql:183（rpc_record_pickup 第 13 版；
-- 用 CREATE (OR REPLACE) FUNCTION (public.)?rpc_record_pickup 查定義鏈確認是最後一支。
-- ⚠ 帶 public. 前綴查只抓得到 8 支、會漏掉前 5 支早期版本）。
-- 基底函式本體 329 行**逐字保留**，只在兩處插入：
--   ① DECLARE 加 4 個變數
--   ② 取得 v_pickup_loc 之後、退貨守門之前，插入預鎖段與重驗段
-- 既有的守衛（訂單狀態、店家守衛、零元/贈品守衛、退貨守門、逐品項閘門、
-- 拆行邏輯、狀態重算、事件寫入、回傳欄位）一行都沒有改。
--
-- 【上線順序（⛔ 不可顛倒）】
--   1️⃣ 20260904010000（改實收會動庫存）
--   2️⃣ 本檔（取貨先鎖再扣）
--   3️⃣ 20260904010020（現場銷售先鎖再補）
--   4️⃣ 跑 D:\1人公司\公司\01_進行中\實收連動_修復不一致列_2026-09-04.sql
--      第 ① 段預覽 → **停下來看** → 第 ② 段（先演練，再把 v_dry_run 改 FALSE 正式跑）
--      → 第 ③ 段驗證
--   ⚠️ 第 4 步**不是選配**：純紀錄期間（20260903000005 起）留下的
--     「帳面實收 ≠ 實際入庫」歷史列，在畫面上重存同一個數字不會有反應
--     （20260904010000 開頭就 CONTINUE 掉了，比的是帳面實收），只有那支腳本修得掉。
--     完整說明在那支腳本的檔頭。
--
-- 【Rollback】
-- CREATE OR REPLACE 回 20260819000000:183-511 的版本即可（本檔沒有動任何 schema、
-- 沒有新增欄位、沒有改 CHECK；純函式覆寫）。
-- ⚠ 但 20260904010000 / 本檔 / 20260904010020 **三支是一組**：回滾任一支，
--   負庫存的洞就從三邊變兩邊 —— 要回就三支一起回。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_record_pickup(
  p_order_id  bigint,
  p_item_ids  bigint[],
  p_operator  uuid,
  p_notes     text  DEFAULT NULL,
  p_item_qtys jsonb DEFAULT NULL   -- {"<item_id>": <取貨數量>}；缺項或 >=qty 視為整行取
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_pickup_loc       BIGINT;
  v_item             RECORD;
  v_ret_guard        RECORD;
  v_take             NUMERIC;
  v_picked_disc      NUMERIC;
  v_movement_id      BIGINT;
  v_new_item_id      BIGINT;
  v_picked_item_id   BIGINT;
  v_picked_count     INT := 0;
  v_event_item_ids   BIGINT[] := ARRAY[]::BIGINT[];
  v_active_remaining INT;
  v_new_status       TEXT;
  v_event_type       TEXT;
  v_event_id         BIGINT;
  v_sku_label        TEXT;
  v_now              TIMESTAMPTZ := NOW();
  -- 店家守衛（2026-08-13）
  v_jwt_role          TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores         JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_pickup_store_name TEXT;
  -- 零元守衛（2026-08-15）
  v_is_internal_pool  BOOLEAN;
  v_zero_labels       TEXT[] := ARRAY[]::TEXT[];
  -- 實體庫存鎖（20260904010010）
  v_lock              RECORD;
  v_stock_short       RECORD;
  v_stock_exempt      BOOLEAN;
  v_stock_store_name  TEXT;
BEGIN
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_item_ids is empty';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_pickup:' || p_order_id::text));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 %', p_order_id;
  END IF;

  IF v_order.status IN ('completed','expired','cancelled','transferred_out') THEN
    RAISE EXCEPTION '訂單 % 目前狀態為「%」，無法取貨', p_order_id, v_order.status;
  END IF;

  -- 店家守衛：分店角色只能替「自己店」的訂單取貨。庫存跟著 pickup_store_id
  -- 的 location 扣，跨店按取貨會扣到別店的帳、客人也拿不到貨。
  -- stores 為空（未設定的 legacy 帳號）或含「總倉」不鎖，對齊前端判定。
  IF v_jwt_role IN ('store_manager','store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉') THEN
    SELECT s.name INTO v_pickup_store_name
      FROM stores s
     WHERE s.id = v_order.pickup_store_id
       AND s.tenant_id = v_order.tenant_id;
    IF v_pickup_store_name IS NULL OR NOT (v_my_stores ? v_pickup_store_name) THEN
      RAISE EXCEPTION 'wrong_store: 此訂單的取貨店是「%」，分店帳號只能替自己店的訂單取貨，請由該店操作或先轉單',
        COALESCE(v_pickup_store_name, '未設定');
    END IF;
  END IF;

  -- 零元守衛（2026-08-15）：本次要取的品項若單價是 $0，代表開團 / 代 key 時
  -- 漏填金額 —— 取貨就是收錢的那一刻，放行等於把貨白送出去（線上已經這樣送掉
  -- 111 列）。擋在扣庫存之前，補填金額後即可重取。
  -- 例外：【內部】xx 店 / RR- / OV- 容器單（member_type='store_internal'）的
  -- 池子單價本來就可能是 0，不是漏填。
  -- 20260819000000：刻意送的贈品也是例外，但必須被明確標記過 ——
  -- 品項自己標（coi.is_gift，rpc_mark_order_item_gift）或整個開團商品是贈品
  -- （campaign_items.is_gift，rpc_set_campaign_item_gift，促銷活動一次標全團生效）。
  -- 兩層讀取時 OR，不做欄位同步（見本檔檔頭）。
  SELECT EXISTS (
    SELECT 1 FROM members mb
     WHERE mb.id = v_order.member_id
       AND mb.tenant_id = v_order.tenant_id
       AND mb.member_type = 'store_internal'
  ) INTO v_is_internal_pool;

  IF NOT v_is_internal_pool THEN
    SELECT array_agg(COALESCE(sk.variant_name, sk.product_name, sk.sku_code, coi.id::text)
                     ORDER BY coi.id)
      INTO v_zero_labels
      FROM customer_order_items coi
      LEFT JOIN skus sk ON sk.id = coi.sku_id
      LEFT JOIN campaign_items gi ON gi.id = coi.campaign_item_id
     WHERE coi.id = ANY(p_item_ids)
       AND coi.order_id = p_order_id
       AND coi.status IN ('pending','reserved','ready')
       AND COALESCE(coi.unit_price, 0) = 0
       AND NOT COALESCE(coi.is_gift, FALSE)
       AND NOT COALESCE(gi.is_gift, FALSE);

    IF v_zero_labels IS NOT NULL AND array_length(v_zero_labels, 1) > 0 THEN
      RAISE EXCEPTION 'zero_price: 品項「%」的單價是 $0，看起來是開團時漏填金額。請先補上金額再取貨（取貨頁該品項旁可直接補填）；若這是刻意送的贈品，改按該品項旁的「🎁 這是贈品」標記後即可取貨',
        array_to_string(v_zero_labels, '」、「');
    END IF;
  END IF;

  SELECT location_id INTO v_pickup_loc
    FROM stores
   WHERE id = v_order.pickup_store_id;

  IF v_pickup_loc IS NULL THEN
    RAISE EXCEPTION '分店 % 未設定倉庫位置 (location_id)、無法寫 stock_movement', v_order.pickup_store_id;
  END IF;

  -- ==========================================================================
  -- 20260904010010：扣庫存前先鎖住餘額列，鎖完重驗一次夠不夠
  --   （本檔唯一新增的行為，完整推導見檔頭）
  -- ==========================================================================

  -- ① 預鎖：把這次會扣到的 (location_id, sku_id) 去重、**排序後**逐列鎖起來。
  --    ⛔ ORDER BY location_id, sku_id 這個順序與 20260904010000（✎修改實收
  --      往下扣）完全一致，兩支才不會各拿一半互相等（死鎖）。只改一邊等於沒改。
  --    取貨永遠只扣 v_pickup_loc 一個倉，所以實際上是照 sku_id 排；location_id
  --    仍然寫進 ORDER BY，是為了讓兩支的規則長得一模一樣、將來誰都不會看錯。
  --    餘額列**不存在**時 FOR UPDATE 鎖不到任何東西 —— 那代表 on_hand 視同 0，
  --    下面的重驗一定擋下來（豁免單除外），不會有漏網。
  FOR v_lock IN
    SELECT DISTINCT v_pickup_loc AS location_id, coi.sku_id
      FROM customer_order_items coi
     WHERE coi.id = ANY(p_item_ids)
       AND coi.order_id = p_order_id
       AND coi.sku_id IS NOT NULL
     ORDER BY 1, 2
  LOOP
    PERFORM 1
       FROM stock_balances
      WHERE tenant_id   = v_order.tenant_id
        AND location_id = v_lock.location_id
        AND sku_id      = v_lock.sku_id
      FOR UPDATE;
  END LOOP;

  -- ② 豁免：口徑**逐字對齊**取貨閘門的門市實體守衛（20260901020000:266-283）。
  --    容器單（member_type='store_internal'：RR- / OV- / AB- /【內部】xx 店）與
  --    offset 抵減單在閘門那邊就刻意不受 on_hand 管 —— 它們被排除在「已承諾」
  --    母體之外，再要它們自己過守衛會被 on_hand 擋死。
  --    ⚠ 這裡**不可以**比閘門嚴。嚴一格就會擋掉閘門明明放行的正常取貨，
  --      現貨池單第一個卡死（#901 才剛修好「整店現貨池轉不出去」）。
  --    v_is_internal_pool 是零元守衛（20260815000000）算好的同一個值，直接沿用，
  --    不另外查一次 —— 兩處判準永遠一致。
  v_stock_exempt := v_is_internal_pool
                    OR COALESCE(v_order.order_kind, 'normal') = 'offset';

  -- ③ 重驗：鎖已經到手，這時候讀到的 on_hand 才是別人動不了的。
  --    量的算法比照上面的退貨守門：缺項＝整行取、LEAST clamp 到行量
  --    （超量交給主迴圈報錯）；狀態限定 pending/reserved/ready，與主迴圈的
  --    放行條件一致，已取走的行不會被重複算進來。
  --    同一個 SKU 分散在多行時要**加總**再比 —— 逐行比會讓「各行都夠、加起來
  --    不夠」漏過去。
  IF NOT v_stock_exempt THEN
    SELECT s.name INTO v_stock_store_name
      FROM stores s
     WHERE s.id = v_order.pickup_store_id
       AND s.tenant_id = v_order.tenant_id;

    FOR v_stock_short IN
      SELECT req.sku_id,
             req.take_qty,
             COALESCE(sb.on_hand, 0) AS on_hand
        FROM (
          SELECT coi.sku_id,
                 SUM(LEAST(COALESCE((p_item_qtys ->> coi.id::text)::numeric, coi.qty),
                           coi.qty)) AS take_qty
            FROM customer_order_items coi
           WHERE coi.id = ANY(p_item_ids)
             AND coi.order_id = p_order_id
             AND coi.status IN ('pending','reserved','ready')
           GROUP BY coi.sku_id
        ) req
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_order.tenant_id
              AND sb.location_id = v_pickup_loc
              AND sb.sku_id      = req.sku_id
       WHERE req.take_qty > COALESCE(sb.on_hand, 0)
       ORDER BY req.sku_id
    LOOP
      SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
        INTO v_sku_label FROM skus s WHERE s.id = v_stock_short.sku_id;
      RAISE EXCEPTION 'stock_short: 這次要取「%」% 件，但「%」現在架上只剩 % 件，取了會變成負庫存。這批貨可能剛被別人取走、或是「✎ 修改實收」剛把數量改小了。請重新整理畫面確認；如果貨其實在架上只是帳沒入，請到「庫存總覽 → ＋新增庫存」把帳補上再取。',
        COALESCE(v_sku_label, v_stock_short.sku_id::text),
        trim_scale(v_stock_short.take_qty),
        COALESCE(v_stock_store_name, '這家店'),
        trim_scale(v_stock_short.on_hand);
    END LOOP;
  END IF;

  -- 退貨守門：同 SKU「本次取貨量」不得超過「active 品項量 − 未取退貨量」。
  -- 未取退貨（return_to_hq、notes header 不含 |取貨後退回）的貨已離店，
  -- 不能再被結帳；取貨後退回不計入（那批貨的錢在取貨時已收）。
  -- 前端 PickupDialog 有同款防線，但畫面 stale 時會失效，這裡是最後防線。
  FOR v_ret_guard IN
    SELECT r.sku_id, r.ret_qty,
           COALESCE(act.active_qty, 0) AS active_qty,
           COALESCE(req.take_qty, 0)   AS take_qty
      FROM (
        SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.customer_order_id = p_order_id
           AND t.tenant_id     = v_order.tenant_id
           AND t.transfer_type = 'return_to_hq'
           AND t.status IN ('shipped','received')
           AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
               NOT LIKE '%取貨後退回%'
         GROUP BY ti.sku_id
      ) r
      LEFT JOIN (
        SELECT coi.sku_id, SUM(coi.qty) AS active_qty
          FROM customer_order_items coi
         WHERE coi.order_id = p_order_id
           AND coi.status IN ('pending','reserved','ready')
         GROUP BY coi.sku_id
      ) act ON act.sku_id = r.sku_id
      LEFT JOIN (
        -- 本次各 SKU 取貨量（缺項＝整行取；clamp 到行量，超量交給主迴圈報錯）
        SELECT coi.sku_id,
               SUM(LEAST(COALESCE((p_item_qtys ->> coi.id::text)::numeric, coi.qty), coi.qty)) AS take_qty
          FROM customer_order_items coi
         WHERE coi.id = ANY(p_item_ids)
           AND coi.order_id = p_order_id
         GROUP BY coi.sku_id
      ) req ON req.sku_id = r.sku_id
     WHERE COALESCE(req.take_qty, 0) > COALESCE(act.active_qty, 0) - r.ret_qty
  LOOP
    SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
      INTO v_sku_label FROM skus s WHERE s.id = v_ret_guard.sku_id;
    RAISE EXCEPTION '品項「%」已退貨 % 件，本次最多可取 % 件（畫面資料可能過舊，請重新整理後再取）',
      COALESCE(v_sku_label, v_ret_guard.sku_id::text),
      v_ret_guard.ret_qty,
      GREATEST(v_ret_guard.active_qty - v_ret_guard.ret_qty, 0);
  END LOOP;

  -- 逐品項：判斷整行取 or 拆行部分取
  FOR v_item IN
    SELECT id, sku_id, qty, unit_price, status, source, campaign_item_id,
           tenant_id, notes, discount_amount, discount_percent, created_by,
           -- 20260819000000：拆行要把贈品標記帶到 picked_up 那一行，
           -- 否則部分取貨之後收據 / 明細看不出那一件是送的
           is_gift, gift_reason, gift_marked_by, gift_marked_at
      FROM customer_order_items
     WHERE id = ANY(p_item_ids)
       AND order_id = p_order_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.status NOT IN ('pending','reserved','ready') THEN
      RAISE EXCEPTION '品項 % 狀態 % 不可取貨', v_item.id, v_item.status;
    END IF;

    -- 逐品項到貨擋板（取代舊的整單 is_order_pickup_ready 擋板）：
    -- 未到貨（該 SKU 分店實收 0）的品項個別擋，已到貨的品項放行先取
    IF NOT public.is_order_item_pickup_ready(v_item.id) THEN
      SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
        INTO v_sku_label FROM skus s WHERE s.id = v_item.sku_id;
      RAISE EXCEPTION '品項「%」分店尚未實收到貨，無法取貨（請取消勾選該品項，其餘已到貨品項可先取）',
        COALESCE(v_sku_label, v_item.sku_id::text);
    END IF;

    -- 本次取多少：p_item_qtys 指定則用之，否則整行取
    v_take := COALESCE((p_item_qtys ->> v_item.id::text)::numeric, v_item.qty);
    IF v_take IS NULL OR v_take <= 0 THEN
      RAISE EXCEPTION '品項 % 取貨數量 % 不合法（須 > 0）', v_item.id, v_take;
    END IF;
    IF v_take > v_item.qty THEN
      RAISE EXCEPTION '品項 % 取貨數量 % 超過待取數量 %', v_item.id, v_take, v_item.qty;
    END IF;

    IF v_take = v_item.qty THEN
      -- ── 整行取：沿用舊邏輯，直接標 picked_up ──
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
      ) VALUES (
        v_order.tenant_id, v_pickup_loc, v_item.sku_id, -v_take, 'sale',
        'customer_order', p_order_id, v_item.id,
        format('顧客取貨 order=%s item=%s', p_order_id, v_item.id), p_operator
      ) RETURNING id INTO v_movement_id;

      UPDATE customer_order_items
         SET status = 'picked_up',
             pickup_movement_id = v_movement_id,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v_item.id;

      v_picked_item_id := v_item.id;
    ELSE
      -- ── 部分取：拆行。新建 picked_up 行，原行扣量留待下次 ──
      -- line-level 折扣金額按取貨比例分攤，確保兩行小計加總 = 原行
      v_picked_disc := round(COALESCE(v_item.discount_amount, 0) * v_take / v_item.qty);

      -- 1) 先建 picked_up 行（暫不填 movement，先拿 id）
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, reserved_movement_id, pickup_movement_id, notes,
        discount_amount, discount_percent, created_by, updated_by, created_at, updated_at,
        is_gift, gift_reason, gift_marked_by, gift_marked_at
      ) VALUES (
        v_item.tenant_id, p_order_id, v_item.campaign_item_id, v_item.sku_id, v_take, v_item.unit_price,
        'picked_up', v_item.source, NULL, NULL, v_item.notes,
        v_picked_disc, v_item.discount_percent, v_item.created_by, p_operator, v_now, v_now,
        v_item.is_gift, v_item.gift_reason, v_item.gift_marked_by, v_item.gift_marked_at
      ) RETURNING id INTO v_new_item_id;

      -- 2) sale movement 指向新行
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
      ) VALUES (
        v_order.tenant_id, v_pickup_loc, v_item.sku_id, -v_take, 'sale',
        'customer_order', p_order_id, v_new_item_id,
        format('顧客部分取貨 order=%s item=%s (split from %s)', p_order_id, v_new_item_id, v_item.id), p_operator
      ) RETURNING id INTO v_movement_id;

      -- 3) 回填新行 movement
      UPDATE customer_order_items
         SET pickup_movement_id = v_movement_id
       WHERE id = v_new_item_id;

      -- 4) 原行扣量、保持 active 狀態，剩餘留待下次取
      UPDATE customer_order_items
         SET qty = qty - v_take,
             discount_amount = COALESCE(discount_amount, 0) - v_picked_disc,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v_item.id;

      v_picked_item_id := v_new_item_id;
    END IF;

    -- event 記錄「被取走」那一行的 id（拆行時是新行）→ 收據查到正確的 qty
    v_event_item_ids := v_event_item_ids || v_picked_item_id;
    v_picked_count := v_picked_count + 1;
  END LOOP;

  IF v_picked_count = 0 THEN
    RAISE EXCEPTION 'no items picked (check p_item_ids belongs to order %)', p_order_id;
  END IF;

  -- 重算 order status（剩餘 active 行 → partially_completed；全取完 → completed）。
  -- 2026-08-01：剩餘 active 量要扣掉「未取退貨」覆蓋 — 已退回總倉的量不會再被
  -- 取走，若某 SKU 的 active 量全被退貨蓋掉，該 SKU 的殘行不算「待取」。
  -- 否則部分退貨後取走剩餘可取量（訂5退2取3）會讓訂單永遠卡在 partially_completed。
  SELECT COUNT(*) INTO v_active_remaining
    FROM customer_order_items coi
    JOIN (
      SELECT act.sku_id
        FROM (
          SELECT sku_id, SUM(qty) AS active_qty
            FROM customer_order_items
           WHERE order_id = p_order_id
             AND status IN ('pending','reserved','ready')
           GROUP BY sku_id
        ) act
        LEFT JOIN (
          SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
            FROM transfers t
            JOIN transfer_items ti ON ti.transfer_id = t.id
           WHERE t.customer_order_id = p_order_id
             AND t.tenant_id     = v_order.tenant_id
             AND t.transfer_type = 'return_to_hq'
             AND t.status IN ('shipped','received')
             AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
                 NOT LIKE '%取貨後退回%'
           GROUP BY ti.sku_id
        ) r ON r.sku_id = act.sku_id
       WHERE act.active_qty - COALESCE(r.ret_qty, 0) > 0
    ) open_sku ON open_sku.sku_id = coi.sku_id
   WHERE coi.order_id = p_order_id
     AND coi.status IN ('pending','reserved','ready');

  IF v_active_remaining = 0 THEN
    v_new_status := 'completed';
    v_event_type := 'picked_up';
  ELSE
    v_new_status := 'partially_completed';
    v_event_type := 'partial_pickup';
  END IF;

  UPDATE customer_orders
     SET status       = v_new_status,
         completed_at = CASE WHEN v_new_status = 'completed' THEN v_now ELSE NULL END,
         updated_by   = p_operator,
         updated_at   = v_now
   WHERE id = p_order_id;

  INSERT INTO order_pickup_events (
    tenant_id, order_id, pickup_store_id, event_type, item_ids, notes, created_by
  ) VALUES (
    v_order.tenant_id, p_order_id, v_order.pickup_store_id, v_event_type,
    to_jsonb(v_event_item_ids), p_notes, p_operator
  ) RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'event_id',        v_event_id,
    'event_type',      v_event_type,
    'picked_count',    v_picked_count,
    'active_remaining', v_active_remaining,
    'new_status',      v_new_status
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) IS
  '取貨記帳。p_item_qtys={"<item_id>":<取貨數量>} 可指定部分取貨（拆行）。'
  '到貨擋板為品項層級（is_order_item_pickup_ready）：未到貨品項個別擋、已到貨可先取。'
  '退貨守門：同 SKU 取貨量不得超過 active 量 − 未取退貨量（取貨後退回不計）。'
  'active_remaining 排除量已被未取退貨覆蓋的 SKU（退光的殘行不擋 completed）。'
  '店家守衛：分店角色（store_manager/store_staff，app_metadata.stores 非空且不含總倉）'
  '只能替自己店（pickup_store_id 店名 ∈ stores）的訂單取貨，否則 raise wrong_store。'
  '零元守衛（20260815000000）：本次要取的品項單價為 $0 一律 raise zero_price'
  '（漏填金額 → 取貨等於白送）；member_type=store_internal 的容器單不受限。'
  '20260819000000：已標記的贈品（customer_order_items.is_gift 或 campaign_items.is_gift）'
  '不受零元守衛限制；拆行時贈品標記會複製到 picked_up 那一行。'
  '20260904010010：扣庫存前先按 (location_id, sku_id) 排序鎖住 stock_balances，'
  '鎖到手才重驗 on_hand 夠不夠本次取貨量，不夠 raise stock_short。'
  '豁免口徑對齊 is_order_item_pickup_ready 的門市實體守衛（容器單與 offset 單不受限）。'
  '鎖序與 rpc_adjust_received_transfer（20260904010000）、'
  'rpc_create_walkin_sale（20260904010020）一致，三支不會互鎖。'
  '⚠ 三支性格不同：本檔與改實收「不夠就失敗」，現場銷售「不夠就補到夠、照樣結帳」。';

GRANT EXECUTE ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) TO authenticated;

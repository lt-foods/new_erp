-- ============================================================================
-- 現場銷售 (2/3)：rpc_create_walkin_sale —— 一支 RPC、一個交易、多品項、當場扣庫存
-- ============================================================================
-- 需求（Alex 2026-09-01），規劃見 docs/PLAN-現場銷售POS.md。
--
-- 它跟現貨直配（rpc_create_spot_sale，20260824060000）差在哪：
--   現貨直配 = 開一張「待取」單，客人回來取貨時才由 rpc_record_pickup 扣庫存。
--   現場銷售 = 客人**人就在櫃台**，開單與交貨是同一件事 → 單頭直接 completed、
--              品項直接 picked_up、當場寫 sale movement，而且一次可以買很多樣。
--   線上實測（2026-09-01）：SP- 單 111 張、平均品項數 1.00、37% 在 6 小時內
--   就取貨 —— 店員本來就在拿現貨直配當現場銷售用，只是一次只能一項、要按兩次。
--
-- 為什麼不呼叫 rpc_record_pickup：它會跑 is_order_item_pickup_ready 到貨閘門，
--   而現場銷售的貨**不需要「到過店」**（本來就在架上）。閘門那一整套是為了
--   「總倉發的貨到了沒」設計的，套在臨櫃結帳上只會誤擋。
--   代價是閘門的實體庫存守衛（20260818000010）也不會跑 → **本函式自己的
--   可賣量閘門就是唯一防線**（見 §可賣量）。
--
-- 可賣量 = _sku_free_qty_with_pool（在庫 − 待客取 − 等貨中 − 在途池子），
--   ⛔ 不是 on_hand。別的客人正在等的貨不可以被現場客買走 —— 那是
--   2026-08-18 松山「on_hand=0 還一直放行取貨」的同一個坑。
--   超出純自由量的部分成交後呼叫 _consume_internal_pool 扣【內部】店現貨池，
--   否則同一批貨掛兩份承諾，下一位客人的取貨閘門會被擋掉（忠順 ×10 事故）。
--
-- 缺貨補帳（p_lines[].add_stock_qty）：
--   店員在結帳當下發現帳上沒貨、但架上有 → 同一個交易內先寫
--   manual_adjust(+N) 再賣。要嘛全成、要嘛整筆 rollback。
--   這是本案唯一的高風險設計，四道配套一個都不能少：
--     1. 限 store_manager 以上（Alex 決議）；store_staff 直接 RAISE。
--     2. 帶 _current_cost_price 當成本 —— 不帶的話該倉 avg_cost 是 0 時，
--        後面那筆 sale 的 COGS 就是 0、毛利虛高。
--     3. reason 固定 '現場銷售即時入帳 <單號>'，事後查得出來（報表靠這個字串）。
--     4. 單頭 notes 標明有幾件是補帳的。
--   明確不做：不碰減抵單（Path D 無條件豁免正是松山那次的元凶）、
--   不做負庫存直售（p_allow_negative）—— 現場的東西店員數得出來。
--
-- 參數：
--   p_lines = [{sku_id, qty, unit_price, add_stock_qty?}]（同一個 SKU 可以有
--     多列，價格可以不同；閘門依 SKU 聚合後判斷）。
--   p_member_id NULL → 用該店的「現場客」共用假會員（_walkin_member）。
--     店員勾了「建立為會員」時，前端先開會員再把 member_id 帶進來，不走假會員。
--   p_customer_name → nickname_snapshot（＝需求說的「依照人名產生訂單」）。
--
-- 基底版本：無（新函式）。用到的既有零件全部照原樣呼叫，沒有複製任何一份邏輯：
--   _walkin_member(20260901010000) / _restock_sentinel_*(20260612000020) /
--   _sku_free_qty + _sku_commitment(20260816000000) /
--   _sku_free_qty_with_pool + _consume_internal_pool(20260824060000) /
--   _current_cost_price(20260705000000)
-- Rollback：DROP FUNCTION public.rpc_create_walkin_sale(BIGINT, JSONB, UUID,
--   BIGINT, TEXT, TEXT, NUMERIC, TEXT);
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
  v_free       NUMERIC;
  v_cap        NUMERIC;
  v_from_pool  NUMERIC;
  v_pool_plan  JSONB := '{}'::jsonb;
  v_pool_total NUMERIC := 0;
  v_added      JSONB := '[]'::jsonb;
  v_add_total  NUMERIC := 0;
  v_c          RECORD;
  v_on_hand    NUMERIC;
  v_over       NUMERIC;
  v_hint       TEXT;
  v_sku_label  TEXT;
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

    -- ---- 缺貨補帳 ----
    IF v_s.add_qty > 0 THEN
      -- Alex 決議：只有店長以上能補。角色清單對齊 rpc_undo_pickup（20260807000010），
      -- '' 是沒有顯式 role 的 legacy / dev admin，漏掉會把舊帳號全擋在外面。
      IF v_jwt_role NOT IN ('owner', 'admin', 'hq_manager', 'store_manager', '') THEN
        RAISE EXCEPTION 'permission denied: 「%」沒有權限在結帳時補庫存，'
          '請店長操作，或先到「庫存總覽」把現貨入帳', v_jwt_role;
      END IF;

      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, movement_type,
        unit_cost, reason, operator_id
      ) VALUES (
        v_store.tenant_id, v_store.location_id, v_s.sku_id, v_s.add_qty, 'manual_adjust',
        -- 成本一定要帶：沒帶的話該倉 avg_cost 若是 0，後面那筆 sale 的 COGS
        -- 就是 0、毛利虛高（同 _air_ship_order_items 的 p_fallback_unit_cost）
        public._current_cost_price(v_store.tenant_id, v_s.sku_id),
        '現場銷售即時入帳 ' || v_order_no || '（結帳時架上有貨、帳上沒有）', p_operator
      ) RETURNING id INTO v_move_id;

      v_add_total := v_add_total + v_s.add_qty;
      v_added := v_added || jsonb_build_object(
        'sku_id', v_s.sku_id, 'qty', v_s.add_qty, 'movement_id', v_move_id);
    END IF;

    -- ---- 可賣量閘門 ----
    v_free := public._sku_free_qty(p_store_id, v_s.sku_id);
    v_cap  := public._sku_free_qty_with_pool(p_store_id, v_s.sku_id);

    IF v_cap < v_s.need THEN
      -- 錯誤訊息要講得出「那些貨去哪了」＋「下一步做什麼」，
      -- 不然店員只看到「不足」會以為系統壞了（同 20260824060000 的教訓）
      SELECT * INTO v_c FROM public._sku_commitment(p_store_id, ARRAY[v_s.sku_id]);
      SELECT COALESCE(sb.on_hand, 0) INTO v_on_hand
        FROM stock_balances sb
       WHERE sb.tenant_id   = v_store.tenant_id
         AND sb.location_id = v_store.location_id
         AND sb.sku_id      = v_s.sku_id;
      SELECT COALESCE(s.product_name, '') ||
             CASE WHEN s.variant_name IS NOT NULL THEN ' / ' || s.variant_name ELSE '' END
        INTO v_sku_label FROM skus s WHERE s.id = v_s.sku_id;

      v_over := GREATEST(COALESCE(v_c.promised, 0) + COALESCE(v_c.waiting, 0)
                         + COALESCE(v_c.pool_claimed, 0) - COALESCE(v_on_hand, 0), 0);

      -- 三種原因講三句不同的話。分不清楚的話店員只會看到同一句罐頭訊息，
      -- 照著去「新增庫存」補了 N 件回來發現可賣量還是 0（20260824060000 的災情）。
      IF v_over > 0 THEN
        v_hint := '帳上已超額 ' || v_over || ' 件（承諾多於在庫）：'
                  || '架上真的有貨就在這一列勾「補庫存」補超過 ' || v_over || ' 件，'
                  || '數量對不上請改走「庫存盤點」重盤一次。';
      ELSIF COALESCE(v_c.promised, 0) + COALESCE(v_c.waiting, 0)
            + COALESCE(v_c.pool_claimed, 0) > 0 THEN
        v_hint := '這批貨被別的客人佔著（待客取 / 等貨中）。'
                  || '架上實際有更多貨的話，在這一列勾「補庫存」把現貨入帳。';
      ELSE
        v_hint := '這家店帳上就只有 ' || COALESCE(v_on_hand, 0) || ' 件。'
                  || '架上真的有更多，在這一列勾「補庫存」把差額入帳再賣。';
      END IF;

      RAISE EXCEPTION '「%」可賣 % 件、要賣 % 件。'
        '（在庫 %，其中待客取 %、等貨中 %、內部單 %（已到 %））%',
        COALESCE(v_sku_label, v_s.sku_id::TEXT), v_cap, v_s.need,
        COALESCE(v_on_hand, 0), COALESCE(v_c.promised, 0),
        COALESCE(v_c.waiting, 0), COALESCE(v_c.pool_claimed, 0),
        COALESCE(v_c.pool_arrived, 0), v_hint;
    END IF;

    -- 超出純自由量的部分＝從【內部】店現貨池賣掉的，開完單要扣池子
    v_from_pool := GREATEST(v_s.need - v_free, 0);
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
             THEN E'\n其中 ' || v_add_total || ' 件是結帳時現場補帳入庫（架上有貨、帳上沒有）'
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
  '可賣量閘門用 _sku_free_qty_with_pool（不是 on_hand），成交後扣內部現貨池；'
  '缺貨可在同一交易補 manual_adjust（限 store_manager 以上，帶成本、留 reason）。'
  '20260901010010。';

REVOKE ALL ON FUNCTION public.rpc_create_walkin_sale(BIGINT, JSONB, UUID, BIGINT, TEXT, TEXT, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_walkin_sale(BIGINT, JSONB, UUID, BIGINT, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;

-- ============================================================================
-- 現場銷售的補庫存：夾在「這一筆真正缺的量」，補多少就當場賣掉多少
-- ============================================================================
-- Alex 2026-09-01：「現場銷售的補庫存就是補多少馬上就賣掉，只是一筆記錄而已。」
--
-- 這是對的心智模型，但**上一版沒有在結構上保證**：`add_stock_qty` 是店員在
-- 畫面上自己填的數字，RPC 只要求非負整數。填得比缺的量大時，多的部分不會被
-- 同一筆交易的 sale 扣掉，會留在 on_hand 變成**沒有來源的庫存** ——
-- 那正是本功能最該防的幽靈庫存（CLAUDE.md 記過的忠順池子 ×10、松山
-- on_hand=0 還能取貨，都是這個形狀）。
--
-- 改法：把補的量夾成 `LEAST(店員填的, need − 可賣量)`。
--   * 補進來的每一件都會被同一筆交易的 sale 扣掉 → on_hand 淨變化 0，
--     兩筆異動（manual_adjust +N / sale −N）只是把「架上本來就有、帳上沒有」
--     這件事記下來。
--   * 補完必定剛好夠：可賣量 = on_hand − promised − 在途池子，補的量 1:1 加到
--     on_hand，promised 與池子都沒動 → 不會出現「補了還是不夠」。
--   * 真的要把架上整批入帳，走「庫存總覽 → 新增庫存」或盤點 —— 那裡才有
--     完整的理由欄與覆核，不該從收銀台開這個口。
--
-- 順帶：把「取分項 / 算可賣量」搬到補帳**之前**（原本補完才算），
--   夾上限需要補之前的可賣量。補完直接把 v_on_hand / v_cap 各加 v_add，
--   不用再查一次 DB。
--
-- 基底版本：rpc_create_walkin_sale = 20260901020000（本檔函式本體由該檔逐字
--   抽出後只改補帳段與宣告，非手抄）。
-- Rollback：重跑 20260901020000 的 rpc_create_walkin_sale。
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

    -- ---- 缺貨補帳：補多少就當場賣掉多少，一件都不留 ----
    --
    -- 上限夾死在「這一筆真正缺的量」（need − cap）。店員在畫面上填再大的數字都
    -- 只會補到剛好夠 —— 補進來的每一件都會被同一筆交易的 sale 扣掉，on_hand
    -- 淨變化 0，兩筆異動只是把「架上本來就有、帳上沒有」這件事記下來。
    --
    -- 為什麼要夾：不夾的話多補的部分會留在 on_hand 變成沒有來源的庫存 ——
    -- 那正是本功能最該防的幽靈庫存（CLAUDE.md 記過的忠順 ×10 / 松山 on_hand=0
    -- 還能取貨都是這個形狀）。真的要把架上整批入帳，走「庫存總覽 → 新增庫存」
    -- 或盤點，那裡才有完整的理由欄與覆核。
    v_add := LEAST(GREATEST(COALESCE(v_s.add_qty, 0), 0),
                   GREATEST(v_s.need - v_cap, 0));

    IF v_add > 0 THEN
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
        v_store.tenant_id, v_store.location_id, v_s.sku_id, v_add, 'manual_adjust',
        -- 成本一定要帶：沒帶的話該倉 avg_cost 若是 0，後面那筆 sale 的 COGS
        -- 就是 0、毛利虛高（同 _air_ship_order_items 的 p_fallback_unit_cost）
        public._current_cost_price(v_store.tenant_id, v_s.sku_id),
        '現場銷售即時入帳 ' || v_order_no || '（結帳時架上有貨、帳上沒有）', p_operator
      ) RETURNING id INTO v_move_id;

      v_add_total := v_add_total + v_add;
      v_added := v_added || jsonb_build_object(
        'sku_id', v_s.sku_id, 'qty', v_add, 'movement_id', v_move_id);

      -- 補進來的量 1:1 加到在庫與可賣量（promised / 池子都沒動），
      -- 所以補完必定剛好夠，不用再查一次
      v_on_hand := v_on_hand + v_add;
      v_cap     := v_cap + v_add;
    END IF;

    -- 完全不動池子就能賣的量（要從池子吃掉多少，拿這個當基準）
    v_plain := GREATEST(v_on_hand - COALESCE(v_c.promised, 0)
                        - COALESCE(v_c.pool_claimed, 0), 0);

    IF v_cap < v_s.need THEN
      -- 錯誤訊息要講得出「那些貨去哪了」＋「下一步做什麼」，而且**下一步要真的有用**。
      -- 舊版把 waiting 算進「超額」，於是對「團購 8 件在等貨、架上 2 件」這種情況
      -- 叫店員「補超過 6 件」—— 照做會憑空生出 8 件庫存只為了賣 2 件。
      SELECT COALESCE(s.product_name, '') ||
             CASE WHEN s.variant_name IS NOT NULL THEN ' / ' || s.variant_name ELSE '' END
        INTO v_sku_label FROM skus s WHERE s.id = v_s.sku_id;

      IF COALESCE(v_c.promised, 0) > 0
         AND v_on_hand - COALESCE(v_c.promised, 0) < v_s.need THEN
        v_hint := '架上這批貨已經配給在等取貨的客人（待客取 '
                  || COALESCE(v_c.promised, 0) || ' 件），不能賣給現場客。';
      ELSIF COALESCE(v_c.pool_claimed, 0) - COALESCE(v_c.pool_arrived, 0) > 0 THEN
        v_hint := '有 ' || (COALESCE(v_c.pool_claimed, 0) - COALESCE(v_c.pool_arrived, 0))
                  || ' 件是還在路上的補貨（內部單），還沒到店。';
      ELSE
        v_hint := '這家店帳上只有 ' || v_on_hand || ' 件。';
      END IF;

      -- 補庫存要補的量＝剛好補到夠（可賣量會 1:1 跟著在庫加），
      -- 不要再叫他補一個把 waiting 算進去的大數字
      v_hint := v_hint || '架上真的有貨的話，在這一列勾「補庫存」補 '
                || (v_s.need - v_cap) || ' 件；數量對不上請改走「庫存盤點」重盤一次。';

      IF COALESCE(v_c.waiting, 0) > 0 THEN
        v_hint := v_hint || '（另有 ' || COALESCE(v_c.waiting, 0)
                  || ' 件是團購客人下單在等貨、貨還沒到，那批不影響現在能賣多少。）';
      END IF;

      RAISE EXCEPTION '「%」現在能賣 % 件、要賣 % 件。（在庫 %，其中待客取 %、內部單 %（已到 %））%',
        COALESCE(v_sku_label, v_s.sku_id::TEXT), v_cap, v_s.need,
        v_on_hand, COALESCE(v_c.promised, 0),
        COALESCE(v_c.pool_claimed, 0), COALESCE(v_c.pool_arrived, 0), v_hint;
    END IF;

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
  '可賣量閘門用 _sku_walkin_qty（在庫 − 待客取 − 在途內部單，**不扣等貨中**），'
  '成交後扣內部現貨池；缺貨可在同一交易補 manual_adjust，'
  '但**夾在這一筆真正缺的量**（補多少當場賣掉多少、on_hand 淨變化 0），'
  '限 store_manager 以上、帶成本、reason 帶單號。20260901030000。';

REVOKE ALL ON FUNCTION public.rpc_create_walkin_sale(BIGINT, JSONB, UUID, BIGINT, TEXT, TEXT, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_walkin_sale(BIGINT, JSONB, UUID, BIGINT, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;

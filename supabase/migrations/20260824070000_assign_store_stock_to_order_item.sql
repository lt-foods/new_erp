-- ============================================================================
-- 訂單頁「從庫存配貨」：把店內現貨指派給這張單的某個品項
--
-- 需求（Alex 2026-08-24）：「可以有一個方式讓我直接從庫存配貨給某個訂單，
--   直接做在訂單的詳細頁面，打開後就可以直接調整訂單數量，要可以從庫存指派
--   給那張訂單」。
--
-- 現況：把店內現貨變成「這位客人可以取」只有三條路，全都不在訂單頁：
--   1. rpc_create_inventory_deduction（庫存減抵單）—— 只吃**已標待補貨**的品項，
--      而且開單當下就 rpc_record_pickup 結案（＝直接交貨，客人還沒來就不能用）。
--   2. rpc_allocate_shortage（少發配貨）—— 綁在收貨頁的某一張 transfer 上。
--   3. rpc_create_spot_sale（現貨直配）—— 只能開**新的** SP- 單，不能配給既有訂單。
--   店員手上有貨、客人有一張還在等貨的單，中間沒有橋。
--
-- 本檔新增：
--   1. _order_item_stock_budget(item_id) — 這一行「還能從店內庫存指派幾件」的
--      唯一算法（含拆解，給畫面顯示用）。
--   2. rpc_get_order_item_stock_budget(item_id) — 上面那支的 JSONB 包裝（前端預檢）。
--   3. rpc_assign_stock_to_order_item(item_id, qty, operator, reason, use_pool)
--      —— 開一張 DN 覆蓋這一行（取貨閘門 Path D 放行）、清掉待補貨旗標、
--      需要時從【內部】店現貨池扣（同 20260824060000 的現貨直配），
--      整單都可取時把單頭 confirmed → ready。
--      **不扣庫存、不結案** —— 客人到店取貨時才走 rpc_record_pickup 扣帳，
--      與到店取貨同一套帳。要「當場交貨結案」請照舊用庫存減抵單。
--
-- 預算算法（為什麼不是直接用 _sku_free_qty_with_pool）：
--   自由量把 waiting（confirmed 還在等貨的需求）整個扣掉，而這一行**自己就是**
--   那些 waiting 之一 —— 用自由量會變成「自己擋自己」，一件也指派不出去
--   （同 20260811000050 _settle_arrived_backorders 檔頭的坑）。
--   所以這裡的母體是「對這批實體庫存已經有主張的量」：
--     committed = Σ 同店同 SKU 的 active 品項（排除本行、內部容器單、offset、待補貨）
--                 · 單頭已承諾（ready / partially_completed / shipping）→ 整行 qty
--                 · 其餘（還在 confirmed / pending 等貨）→ 只算它身上已開的 DN 覆蓋量
--     assignable            = on_hand − committed − 在途池子 − 已到貨池子
--     assignable_with_pool  = on_hand − committed − 在途池子
--   母體刻意跟取貨閘門的實體庫存守衛（20260818000010）對齊：那道守衛只算
--   「單頭已承諾」的行，所以還在等貨的單不會互相擋；但**已經被 DN 指派過**的行
--   要算進來，否則同一批貨可以指派給無限多張 confirmed 單（那正是 2026-08-18
--   松山「on_hand = 0 還說可取」的形狀）。
--
-- 為什麼用 DN 而不是把單頭推 ready 就好：
--   取貨閘門 Path C（本店該 SKU 有收過貨）是 qty-blind 而且要看歷史，店內現貨
--   可能是盤盈 / 自購 / 手動入帳，根本沒有 transfer 紀錄；DN 是 Path D，
--   對「貨就在架上」這件事是唯一誠實的表達（rpc_create_spot_sale 同理由）。
--   DN 的覆蓋在訂單被取消 / 逾期時會自動釋放（20260813002000 的 trigger），
--   不會留下殭屍覆蓋。
--
-- 配不滿一整行時要**拆行**（同 rpc_allocate_shortage 20260805000100）：
--   取貨閘門與 rpc_record_pickup 看到的永遠是「整行可取」或「整行待補」——
--   閘門的實體庫存守衛把本行的 **整行 qty** 算進累計，所以「4 件的行只配 3 件」
--   不拆的話閘門照樣回 false，等於白配（實測：松山 76737 配 3/4 後 gate 仍是 f）。
--   拆法比照少發配貨：原行留下已配到的量，餘量另開一行標 backorder_at（待補貨），
--   折扣按數量比例分攤。
--
-- 單頭處理：整單的 active 品項都通過閘門才把 confirmed 推 ready
--   （同 _advance_arrived_confirmed_orders 的「整單裝得下才推」）。只指派到其中
--   一項時單頭不動 —— 取貨頁本來就逐品項放行（20260824050000），confirmed 單
--   靠 Path D 的品項也勾得到。
--
-- 基底版本：本檔三支函式皆為新增，不改任何既有函式。
-- Rollback：
--   DROP FUNCTION public.rpc_assign_stock_to_order_item(BIGINT,NUMERIC,UUID,TEXT,BOOLEAN);
--   DROP FUNCTION public.rpc_get_order_item_stock_budget(BIGINT);
--   DROP FUNCTION public._order_item_stock_budget(BIGINT);
--   已經指派出去的 DN 不會被 rollback 清掉：要收回請取消該訂單（覆蓋會自動釋放）
--   或人工把 inventory_deduction_notes.cancelled_at 補上。
--
-- 對應前端（同一個 commit）：
--   apps/admin/src/components/AssignStockModal.tsx（新）
--   apps/admin/src/components/OrderDetail.tsx（品項列多一顆「📦 從庫存配貨」）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. _order_item_stock_budget — 這一行還能從店內庫存指派幾件（唯一算法）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._order_item_stock_budget(
  p_item_id BIGINT
) RETURNS TABLE (
  tenant_id            UUID,
  order_id             BIGINT,
  order_no             TEXT,
  order_status         TEXT,
  campaign_id          BIGINT,
  store_id             BIGINT,
  store_name           TEXT,
  location_id          BIGINT,
  sku_id               BIGINT,
  sku_label            TEXT,
  item_qty             NUMERIC,
  item_status          TEXT,
  backordered          BOOLEAN,
  assigned             NUMERIC,  -- 這一行已經被 DN 覆蓋的量
  on_hand              NUMERIC,
  committed            NUMERIC,  -- 別行對這批實體庫存的主張
  waiting              NUMERIC,  -- 同店同 SKU 還在等貨的需求（顯示用，不進算式）
  pool                 NUMERIC,  -- 內部現貨池（含在途）
  pool_arrived         NUMERIC,
  assignable           NUMERIC,  -- 不動池子時還能指派幾件
  assignable_with_pool NUMERIC   -- 允許扣池子時還能指派幾件
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH it AS (
    SELECT coi.id, coi.order_id, coi.sku_id, coi.qty, coi.status AS item_status,
           coi.backorder_at,
           co.tenant_id, co.order_no, co.status AS order_status, co.campaign_id,
           co.pickup_store_id
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE coi.id = p_item_id
  ),
  st AS (
    SELECT it.*, s.id AS s_store_id, s.name AS s_store_name, s.location_id AS s_location_id
      FROM it LEFT JOIN stores s ON s.id = it.pickup_store_id
  ),
  -- 這一行身上還有效的 DN 覆蓋量（作廢的單不算，released 的部分不算）
  mine AS (
    SELECT COALESCE(SUM(GREATEST(ni.qty - COALESCE(ni.released_qty, 0), 0)), 0) AS assigned
      FROM inventory_deduction_note_items ni
      JOIN inventory_deduction_notes n ON n.id = ni.note_id AND n.cancelled_at IS NULL
     WHERE ni.order_item_id = p_item_id
  ),
  bal AS (
    SELECT COALESCE(sb.on_hand, 0) AS on_hand
      FROM st LEFT JOIN stock_balances sb
             ON sb.tenant_id   = st.tenant_id
            AND sb.location_id = st.s_location_id
            AND sb.sku_id      = st.sku_id
  ),
  -- 別行的主張：單頭已承諾 → 整行；還在等貨 → 只算它身上的 DN 覆蓋
  others AS (
    SELECT COALESCE(SUM(
             CASE WHEN yo.status IN ('ready','partially_completed','shipping') THEN y.qty
                  ELSE LEAST(y.qty, COALESCE(cov.q, 0)) END), 0) AS committed
      FROM st
      JOIN customer_orders yo
        ON yo.tenant_id       = st.tenant_id
       AND yo.pickup_store_id = st.s_store_id
       AND yo.status NOT IN ('cancelled','expired','transferred_out')
      JOIN customer_order_items y
        ON y.order_id = yo.id
       AND y.sku_id   = st.sku_id
       AND y.status IN ('pending','reserved','ready')
       AND y.qty > 0
       AND y.id <> p_item_id
       -- 待補貨的行已被少發配貨擋掉，不佔預算（同取貨閘門的實體守衛）
       AND y.backorder_at IS NULL
      LEFT JOIN members ym ON ym.id = yo.member_id
      LEFT JOIN LATERAL (
        SELECT SUM(GREATEST(ni.qty - COALESCE(ni.released_qty, 0), 0)) AS q
          FROM inventory_deduction_note_items ni
          JOIN inventory_deduction_notes n ON n.id = ni.note_id AND n.cancelled_at IS NULL
         WHERE ni.order_item_id = y.id
      ) cov ON TRUE
     WHERE COALESCE(ym.member_type, '') <> 'store_internal'
       AND COALESCE(yo.order_kind, 'normal') <> 'offset'
  ),
  k AS (
    SELECT COALESCE(c.waiting, 0)      AS waiting,
           COALESCE(c.pool_claimed, 0) AS pool,
           COALESCE(c.pool_arrived, 0) AS pool_arrived
      FROM st
      LEFT JOIN LATERAL public._sku_commitment(st.s_store_id, ARRAY[st.sku_id]) c ON TRUE
  )
  SELECT st.tenant_id,
         st.order_id,
         st.order_no,
         st.order_status,
         st.campaign_id,
         st.s_store_id,
         st.s_store_name,
         st.s_location_id,
         st.sku_id,
         COALESCE(sk.product_name, '') ||
           CASE WHEN sk.variant_name IS NOT NULL THEN ' / ' || sk.variant_name ELSE '' END,
         st.qty,
         st.item_status,
         st.backorder_at IS NOT NULL,
         mine.assigned,
         bal.on_hand,
         others.committed,
         k.waiting,
         k.pool,
         k.pool_arrived,
         GREATEST(bal.on_hand - others.committed - (k.pool - k.pool_arrived) - k.pool_arrived, 0),
         GREATEST(bal.on_hand - others.committed - (k.pool - k.pool_arrived), 0)
    FROM st
    LEFT JOIN skus sk ON sk.id = st.sku_id
    CROSS JOIN mine
    CROSS JOIN bal
    CROSS JOIN others
    CROSS JOIN k;
$$;

COMMENT ON FUNCTION public._order_item_stock_budget(BIGINT) IS
  '訂單品項「還能從店內庫存指派幾件」的唯一算法（含拆解，畫面與 RPC 共用）。'
  '母體＝別行對這批實體庫存的主張：單頭已承諾的整行算，還在等貨的只算它身上的 DN 覆蓋。'
  '刻意不扣 waiting —— 本行自己就是 waiting 之一，扣了會自己擋自己。';

REVOKE ALL ON FUNCTION public._order_item_stock_budget(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._order_item_stock_budget(BIGINT) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. rpc_get_order_item_stock_budget — 前端預檢（伺服端開單時會再驗一次）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_order_item_stock_budget(
  p_item_id BIGINT
) RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'item_id',              p_item_id,
    'order_id',             b.order_id,
    'order_no',             b.order_no,
    'order_status',         b.order_status,
    'store_id',             b.store_id,
    'store_name',           b.store_name,
    'sku_id',               b.sku_id,
    'sku_label',            b.sku_label,
    'item_qty',             b.item_qty,
    'item_status',          b.item_status,
    'backordered',          b.backordered,
    'assigned',             b.assigned,
    'on_hand',              b.on_hand,
    'committed',            b.committed,
    'waiting',              b.waiting,
    'pool',                 b.pool,
    'pool_arrived',         b.pool_arrived,
    'assignable',           LEAST(b.assignable,           GREATEST(b.item_qty - b.assigned, 0)),
    'assignable_with_pool', LEAST(b.assignable_with_pool, GREATEST(b.item_qty - b.assigned, 0)),
    'gate_ready',           public.is_order_item_pickup_ready(p_item_id)
  )
    FROM public._order_item_stock_budget(p_item_id) b;
$$;

COMMENT ON FUNCTION public.rpc_get_order_item_stock_budget(BIGINT) IS
  '訂單頁「從庫存配貨」彈窗的預檢：在庫 / 別人的主張 / 等貨 / 內部池 / 還能指派幾件 / '
  '這一行目前過不過取貨閘門。上限已夾到「本行還沒被指派的量」。';

REVOKE ALL ON FUNCTION public.rpc_get_order_item_stock_budget(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_order_item_stock_budget(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 3. rpc_assign_stock_to_order_item — 把店內現貨指派給這一行
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_assign_stock_to_order_item(
  p_item_id  BIGINT,
  p_qty      NUMERIC,
  p_operator UUID,
  p_reason   TEXT    DEFAULT NULL,
  p_use_pool BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_role  TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_b         RECORD;
  v_now       TIMESTAMPTZ := NOW();
  v_room      NUMERIC;
  v_cap       NUMERIC;
  v_from_pool NUMERIC := 0;
  v_pool_done NUMERIC;
  v_note_id   BIGINT;
  v_note_no   TEXT;
  v_all_ready BOOLEAN;
  v_advanced  BOOLEAN := FALSE;
  v_hint      TEXT;
  v_keep      NUMERIC;
  v_rest      NUMERIC := 0;
  v_rest_id   BIGINT;
  v_row       customer_order_items%ROWTYPE;
  v_new_disc  NUMERIC;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 OR p_qty <> FLOOR(p_qty) THEN
    RAISE EXCEPTION '配貨數量必須是正整數';
  END IF;
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '缺少操作人';
  END IF;

  SELECT * INTO v_b FROM public._order_item_stock_budget(p_item_id);
  IF NOT FOUND OR v_b.order_id IS NULL THEN
    RAISE EXCEPTION '找不到訂單品項 #%', p_item_id;
  END IF;
  IF v_b.store_id IS NULL OR v_b.location_id IS NULL THEN
    RAISE EXCEPTION '這張單的取貨門市沒有綁定倉別，算不出店內庫存';
  END IF;
  IF v_b.item_status NOT IN ('pending','reserved','ready') THEN
    RAISE EXCEPTION '這個品項是「%」，不能再配貨（已取貨 / 已取消的行不動）', v_b.item_status;
  END IF;
  IF v_b.order_status IN ('cancelled','expired','transferred_out') THEN
    RAISE EXCEPTION '訂單狀態為「%」，不能配貨', v_b.order_status;
  END IF;

  -- 店家守衛：分店角色只能配自己店的貨（規則對齊 rpc_create_spot_sale /
  -- rpc_record_pickup —— 線上分店帳號沒有 store_id，一律看 app_metadata.stores 店名陣列）
  IF v_jwt_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉')
     AND NOT (v_my_stores ? v_b.store_name) THEN
    RAISE EXCEPTION 'wrong_store: 這是「%」的單，分店帳號只能配自己店的貨', v_b.store_name;
  END IF;

  -- 同一個 (店, SKU) 併發配貨會各自過預算，鎖住整組序列化
  -- （與 rpc_create_spot_sale 同一把鎖：兩邊搶的是同一批實體庫存）
  PERFORM pg_advisory_xact_lock(hashtext(format('spotsale:%s:%s:%s',
    v_b.tenant_id, v_b.store_id, v_b.sku_id)));

  -- 拿鎖之後重算一次（前面那次只是為了驗參數）
  SELECT * INTO v_b FROM public._order_item_stock_budget(p_item_id);

  v_room := GREATEST(v_b.item_qty - v_b.assigned, 0);
  IF v_room <= 0 THEN
    RAISE EXCEPTION '這一行 % 件已經全部配過了（已指派 % 件），要再給請先改訂單數量',
      v_b.item_qty, v_b.assigned;
  END IF;
  IF p_qty > v_room THEN
    RAISE EXCEPTION '這一行只剩 % 件還沒配（共 % 件、已指派 % 件），不能配 % 件',
      v_room, v_b.item_qty, v_b.assigned, p_qty;
  END IF;

  v_cap := CASE WHEN p_use_pool THEN v_b.assignable_with_pool ELSE v_b.assignable END;
  IF v_cap < p_qty THEN
    IF NOT p_use_pool AND v_b.pool_arrived > 0 THEN
      v_hint := '這批貨掛在【內部】' || v_b.store_name || '現貨池（已到貨 '
                || v_b.pool_arrived || ' 件），從訂單頁的「📦 從庫存配貨」配就會自動從池子扣。';
    ELSIF v_b.on_hand <= 0 THEN
      v_hint := '店倉帳上這個商品是 0 件。架上實際有貨的話，請先到「庫存總覽」'
                || '對這個商品「＋ 新增庫存」把現貨入帳。';
    ELSE
      v_hint := '在庫 ' || v_b.on_hand || ' 件已經被別的單佔走 ' || v_b.committed
                || ' 件（已承諾未取 ＋ 已配過的單）。架上實際有更多貨請先「＋ 新增庫存」。';
    END IF;
    RAISE EXCEPTION '「%」在「%」可配 % 件、要配 % 件。%',
      COALESCE(NULLIF(v_b.sku_label, ''), v_b.sku_id::TEXT), v_b.store_name,
      v_cap, p_qty, v_hint;
  END IF;

  -- 超出「不動池子」的部分要從已到貨的池子扣（同 rpc_create_spot_sale）
  v_from_pool := GREATEST(p_qty - v_b.assignable, 0);

  -- 待補貨旗標：這批貨到位了就該解除，否則閘門 backorder_at IS NULL 那關過不了
  UPDATE customer_order_items
     SET backorder_at = NULL,
         backorder_by = NULL,
         updated_by   = p_operator,
         updated_at   = v_now
   WHERE id = p_item_id
     AND backorder_at IS NOT NULL;

  -- 配不滿整行 → 拆行（同 rpc_allocate_shortage 20260805000100）。
  -- 閘門的實體庫存守衛算的是**整行 qty**，不拆的話「4 件只配 3 件」照樣過不了，
  -- 等於白配。原行留下已配到的量，餘量另開一行掛待補貨。
  v_keep := v_b.assigned + p_qty;
  IF v_keep < v_b.item_qty THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id FOR UPDATE;
    v_rest := v_row.qty - v_keep;
    -- 折扣按數量比例分攤（與 rpc_record_pickup / 少發配貨拆行同一套算法）
    v_new_disc := COALESCE(v_row.discount_amount, 0)
                  - round(COALESCE(v_row.discount_amount, 0) * v_keep / v_row.qty);

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, notes, discount_amount, discount_percent,
      backorder_at, backorder_by,
      is_gift, gift_reason, gift_marked_by, gift_marked_at,
      created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_row.tenant_id, v_row.order_id, v_row.campaign_item_id, v_row.sku_id,
      v_rest, v_row.unit_price,
      v_row.status, v_row.source,
      TRIM(BOTH E'\n' FROM COALESCE(v_row.notes || E'\n', '')
           || '[未配到，待補貨｜拆分自#' || v_row.id || ']'),
      v_new_disc, v_row.discount_percent,
      v_now, p_operator,
      -- 贈品旗標要跟著拆，不然餘量那行會被取貨的零元守衛擋下
      v_row.is_gift, v_row.gift_reason, v_row.gift_marked_by, v_row.gift_marked_at,
      p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_rest_id;

    UPDATE customer_order_items
       SET qty             = v_keep,
           discount_amount = COALESCE(v_row.discount_amount, 0) - v_new_disc,
           updated_by      = p_operator,
           updated_at      = v_now
     WHERE id = p_item_id;
  END IF;

  -- DN 覆蓋：取貨閘門 Path D 放行。**不扣庫存、不結案** ——
  -- 客人到店取貨時才由 rpc_record_pickup 寫 sale，與到店取貨同一套帳。
  INSERT INTO inventory_deduction_notes (
    tenant_id, note_no, campaign_id, store_id, sku_id, transfer_id,
    qty, reason, created_by
  ) VALUES (
    v_b.tenant_id,
    'DN' || to_char(v_now, 'YYMMDD') || lpad(nextval('deduction_note_seq')::text, 4, '0'),
    v_b.campaign_id, v_b.store_id, v_b.sku_id, NULL,
    p_qty,
    COALESCE(NULLIF(TRIM(p_reason), ''), '訂單頁從庫存配貨 ' || v_b.order_no),
    p_operator
  ) RETURNING id, note_no INTO v_note_id, v_note_no;

  INSERT INTO inventory_deduction_note_items (note_id, order_id, order_item_id, qty)
  VALUES (v_note_id, v_b.order_id, p_item_id, p_qty);

  -- 現貨池：這批貨改掛在客人頭上了，池子要同額扣掉（承諾總量不變）
  IF v_from_pool > 0 THEN
    v_pool_done := public._consume_internal_pool(
      v_b.store_id, v_b.sku_id, v_from_pool, p_operator, v_now,
      '[已配給訂單 ' || v_b.order_no || ']');
    IF v_pool_done < v_from_pool THEN
      RAISE EXCEPTION '【內部】%現貨池只扣得到 % 件、需要 % 件（可能同時有人在動同一批貨），請重新整理後再試',
        v_b.store_name, v_pool_done, v_from_pool;
    END IF;
  END IF;

  -- 單頭：整單的 active 品項都過得了閘門才把 confirmed 推 ready
  -- （同 _advance_arrived_confirmed_orders 的「整單裝得下才推」；只配到其中一項時
  --  單頭不動 —— 取貨頁逐品項放行，confirmed 單靠 Path D 的品項也勾得到）
  IF v_b.order_status = 'confirmed' THEN
    SELECT bool_and(public.is_order_item_pickup_ready(c.id)) INTO v_all_ready
      FROM customer_order_items c
     WHERE c.order_id = v_b.order_id
       AND c.status IN ('pending','reserved','ready');
    IF COALESCE(v_all_ready, FALSE) THEN
      UPDATE customer_orders
         SET status     = 'ready',
             ready_at   = v_now,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v_b.order_id
         AND status = 'confirmed';
      v_advanced := TRUE;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'item_id',      p_item_id,
    'order_id',     v_b.order_id,
    'order_no',     v_b.order_no,
    'qty',          p_qty,
    'from_pool',    v_from_pool,
    'note_no',      v_note_no,
    'split_qty',    v_rest,      -- 拆出去掛待補貨的量（0 = 整行都配到了）
    'split_item_id', v_rest_id,
    'order_status', CASE WHEN v_advanced THEN 'ready' ELSE v_b.order_status END,
    'advanced',     v_advanced,
    'gate_ready',   public.is_order_item_pickup_ready(p_item_id)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_assign_stock_to_order_item(BIGINT, NUMERIC, UUID, TEXT, BOOLEAN) IS
  '訂單頁「從庫存配貨」：把店內現貨指派給這張單的某個品項 —— 開 DN 覆蓋（取貨閘門 '
  'Path D 放行）＋清待補貨旗標，需要時從【內部】店現貨池扣（p_use_pool），'
  '整單都可取時把 confirmed 推 ready。不扣庫存、不結案（取貨時才走 rpc_record_pickup）。'
  '要「當場交貨結案」請用庫存減抵單 rpc_create_inventory_deduction。'
  '可配量走 _order_item_stock_budget（不扣 waiting —— 本行自己就是 waiting）。';

REVOKE ALL ON FUNCTION public.rpc_assign_stock_to_order_item(BIGINT, NUMERIC, UUID, TEXT, BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_assign_stock_to_order_item(BIGINT, NUMERIC, UUID, TEXT, BOOLEAN)
  TO authenticated;

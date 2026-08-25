-- ============================================================================
-- 訂單頁「取消配貨」：把 20260824070000 配出去的店內現貨收回庫存
--
-- 需求（Alex 2026-08-25）：「那配貨了可以再取消配貨到庫存」。
--
-- 現況：20260824070000 只做得到單向配出去。要收回只有兩條路，兩條都不能用：
--   1. 取消整張訂單（trg_release_idn_coverage 會自動釋放覆蓋）—— 客人的單還在，
--      不能為了收回一件貨把整張單殺掉。
--   2. 人工 UPDATE inventory_deduction_notes.cancelled_at —— 20260805000170 的
--      檔頭就寫著「cancelled_at 目前恆為 NULL，保留欄位供未來作廢用」，
--      全 repo 沒有任何 RPC 寫得到它（rpc_cancel_inventory_deduction 在那支
--      migration 裡是被 DROP 掉的舊草稿）。
--   店員配錯人、客人改主意、要把貨讓給更早的單，中間沒有回頭路。
--
-- 本檔新增／修改：
--   1. inventory_deduction_notes 兩個新欄位（配貨當下的來源記帳，取消時才還得準）：
--      pool_qty          —— 這張 DN 有幾件是從【內部】店現貨池扣來的
--      pool_restored_qty —— 其中已經還回池子的量（多次部分取消時冪等）
--   2. _restore_internal_pool — _consume_internal_pool（20260824060000）的反向：
--      把標著指定字串的 cancelled 容器單品項復活回池子。
--   3. rpc_assign_stock_to_order_item v2 — 基底 20260824070000，只加兩件事：
--      池子標記字串帶上 DN 單號（取消時才認得出是哪一張配貨吃的）、
--      把 v_from_pool 記進 pool_qty。其餘邏輯逐字保留。
--   4. rpc_get_order_stock_assignments(order_id) — 訂單頁一次撈完整張單哪幾行
--      配過貨、各幾件（按鈕要不要出現靠它）。
--   5. rpc_unassign_stock_from_order_item(item_id, qty, operator, reason)
--      —— 釋放 DN 覆蓋、需要時把池子還回去、把配貨當下拆出去的待補貨行併回來、
--      單頭 ready 退回 confirmed。
--
-- 「還回庫存」是什麼意思（為什麼不用碰 stock_movements）：
--   配貨當下就**沒有扣庫存**（DN 只是取貨閘門 Path D 的覆蓋，貨到取貨那一刻
--   才由 rpc_record_pickup 扣）。所以取消配貨＝把「這批貨已經有主人」這個主張
--   拿掉，on_hand 一件都不會動。收回之後那幾件就會重新出現在別人的可配量裡
--   （_order_item_stock_budget 的 committed 少掉、庫存總覽的可分配多回來）。
--
-- 已取貨的行不給取消：貨真的交出去了（rpc_record_pickup 已寫 sale movement），
--   要收回是退貨的職責（rpc_return_order_items），不是這裡。
--
-- 釋放的記法沿用 20260813002000 那一套（覆蓋量的唯一表達方式）：
--   明細 released_qty 遞增（冪等），整張覆蓋歸零 → cancelled_at + reason 註記；
--   只釋放一部分 → 單頭 qty 遞減 + reason 註記。**不刪任何一列**，DN 是帳。
--
-- 池子怎麼還（為什麼要多記 pool_qty 那一欄）：
--   配貨時若動到現貨池，_consume_internal_pool 會把容器單的品項標成 cancelled
--   （整行吃掉）或拆一行出來標掉（吃一部分）。取消配貨時得知道「這張 DN 當初
--   吃了池子幾件」才還得回去 —— 而那個數字在 v1 只出現在 RPC 的回傳值裡，
--   沒有落地，事後推不出來（同店同 SKU 可能有好幾張 DN 交錯吃過池子）。
--   所以 v2 開始記在 DN 上，並把標記字串從 '[已配給訂單 GRP-x]' 改成
--   '[已配給訂單 GRP-x DN2608250069]' —— 一張 DN 一組標記，還的時候只認自己那組。
--   ⚠ v1 建的舊 DN pool_qty 一律是 0（欄位 DEFAULT），所以舊單取消時**不會**
--   亂還池子 —— 這是刻意的：認不出來的就不要動，寧可少還也不要憑空長出貨。
--   （線上 2026-08-25 盤點：v1 只建過 DN2608250069 一張，該店該 SKU 沒有池子，
--     from_pool = 0，所以沒有漏帳。）
--
-- 還池子的方向是「復活那一列」，不是「併回母行」：
--   拆行留下的 cancelled 列身上可能已經有別人的拆分標記（短收未到、已配給團購單…），
--   要從 notes 反解出正確的母行 id 很脆弱。直接把 cancelled 列改回 pending
--   （只還一部分時再拆一次）數量就對了 —— 池子的算法（_sku_commitment 的
--   pool_claimed / pool_arrived）看的是 active 品項的 qty 總和，不管它分幾列。
--   還過的列蓋 '[配貨已取消，退回池子]'，下一次搜尋跳過它 → 不會重複還。
--
-- 部分取消時先還「自由量」、最後才還池子（pool_restored_qty 追蹤）：
--   池子是店家自己那批貨的歸屬，先還通用的那部分比較不會動到歸屬。
--
-- 只收回一部分時**不再拆行**（配出去的時候會拆，收回不用）：
--   配貨要拆是因為閘門的實體庫存守衛算的是「整行 qty」，不拆的話配 3/4 等於白配。
--   反過來收回時，行變成「整行 4 件、只剩 3 件有覆蓋」，那道守衛照樣拿整行 4 件
--   去比可用量 → 不夠就整行不放行。方向是保守的（擋住、不會多發），
--   下一批貨到店時自然重算，所以不用為了收回再拆一次行。
--
-- 拆出去的待補貨行會併回來：
--   配不滿整行時 v1 會拆一行標待補貨（閘門算的是整行 qty，不拆等於白配）。
--   整筆取消時如果那一行還原封不動（還掛著拆分標記、還是待補貨、身上沒有別的
--   DN 覆蓋），就併回母行、把畫面收回配貨前的樣子；被動過就留著不硬併。
--
-- 單頭：ready → confirmed（配貨時是 confirmed → ready 的反向）。
--   判準跟推進時同一套：整單 active 品項是不是都還過得了取貨閘門，
--   過不了才退回 confirmed。有取過貨的單（partially_completed）不動。
--   ⚠ 取貨閘門 Path D 是**群組** EXISTS（qty-blind），同組還有別張 DN 時
--   閘門仍會放行、單頭就留在 ready —— 那是誠實的（那批貨確實還在架上）。
--
-- 基底版本：
--   rpc_assign_stock_to_order_item = 20260824070000（唯一版本，本檔 v2）
--   _consume_internal_pool         = 20260824060000（唯一版本，本檔不改，只加反向）
--   _order_item_stock_budget       = 20260824070000（唯一版本，本檔不改）
--   _release_idn_coverage_for_orders = 20260813002000（唯一版本，本檔不改，記法對齊它）
-- Rollback：
--   -- rpc_assign_stock_to_order_item 指回 20260824070000 的版本
--   DROP FUNCTION public.rpc_unassign_stock_from_order_item(BIGINT,NUMERIC,UUID,TEXT);
--   DROP FUNCTION public.rpc_get_order_stock_assignments(BIGINT);
--   DROP FUNCTION public._restore_internal_pool(BIGINT,BIGINT,NUMERIC,UUID,TIMESTAMPTZ,TEXT);
--   ALTER TABLE inventory_deduction_notes DROP COLUMN IF EXISTS pool_restored_qty;
--   ALTER TABLE inventory_deduction_notes DROP COLUMN IF EXISTS pool_qty;
--   （已經取消掉的配貨不會自己長回來：DN 的 cancelled_at / released_qty 有留帳，
--     要復原就重新配一次。）
--
-- 對應前端（同一個 commit）：
--   apps/admin/src/components/UnassignStockModal.tsx（新）
--   apps/admin/src/components/OrderDetail.tsx（配過貨的品項列多一顆「↩️ 取消配貨」）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. DN 記下「這張配貨吃了池子幾件 / 還回去幾件」
-- ----------------------------------------------------------------------------
ALTER TABLE inventory_deduction_notes
  ADD COLUMN IF NOT EXISTS pool_qty NUMERIC(18,3) NOT NULL DEFAULT 0;

ALTER TABLE inventory_deduction_notes
  ADD COLUMN IF NOT EXISTS pool_restored_qty NUMERIC(18,3) NOT NULL DEFAULT 0;

COMMENT ON COLUMN inventory_deduction_notes.pool_qty IS
  '這張減抵單有幾件是從【內部】店現貨池扣來的（rpc_assign_stock_to_order_item 寫入）。'
  '取消配貨時要還回池子的上限。20260825020000 之前建立的單一律 0（認不出來就不還）。';

COMMENT ON COLUMN inventory_deduction_notes.pool_restored_qty IS
  '上述池子量已經還回去多少（rpc_unassign_stock_from_order_item 寫入），'
  '多次部分取消時用來冪等；永遠 ≤ pool_qty。';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_idn_pool_restored_qty') THEN
    ALTER TABLE inventory_deduction_notes
      ADD CONSTRAINT chk_idn_pool_restored_qty
      CHECK (pool_restored_qty >= 0 AND pool_restored_qty <= pool_qty);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2. _restore_internal_pool — _consume_internal_pool 的反向
--    把標著 p_label 的 cancelled 容器單品項復活回池子，回傳實際還回去的量。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._restore_internal_pool(
  p_store_id BIGINT,
  p_sku_id   BIGINT,
  p_qty      NUMERIC,
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW(),
  p_label    TEXT DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- 還過的列蓋這個章，下一次搜尋跳過 → 重跑不會重複還
  c_done     CONSTANT TEXT := '[配貨已取消，退回池子]';
  v_tenant   UUID;
  v_stem     TEXT;
  v_left     NUMERIC := p_qty;
  v_done     NUMERIC := 0;
  v_take     NUMERIC;
  v_new_disc NUMERIC;
  v_pool     RECORD;
  v_touched  BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 OR p_label IS NULL OR TRIM(p_label) = '' THEN
    RETURN 0;
  END IF;

  SELECT tenant_id INTO v_tenant FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL THEN
    RETURN 0;
  END IF;

  -- _consume_internal_pool 整行吃掉時寫 '[X]'、拆行時寫 '[X|拆分自#123]'，
  -- 去掉尾括號當前綴就兩種都認得（position() 而非 LIKE：標記裡有底線也不會誤判）
  v_stem := CASE WHEN right(p_label, 1) = ']'
                 THEN left(p_label, length(p_label) - 1)
                 ELSE p_label END;

  FOR v_pool IN
    SELECT coi.*
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
      JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
     WHERE co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       -- 吃的時候只吃 ready/partially_completed，但吃完可能被收尾成 completed，
       -- 所以還的時候母體要放寬一級（下面會把單頭一起開回來）
       AND co.status IN ('ready','partially_completed','completed')
       AND coi.sku_id = p_sku_id
       AND coi.status = 'cancelled'
       AND coi.qty > 0
       AND position(v_stem  IN COALESCE(coi.notes, '')) > 0
       AND position(c_done  IN COALESCE(coi.notes, '')) = 0
     ORDER BY coi.id DESC          -- 後吃的先還
       FOR UPDATE OF coi
  LOOP
    EXIT WHEN v_left <= 0;
    v_take    := LEAST(v_pool.qty, v_left);
    v_touched := v_touched || v_pool.order_id;

    IF v_take >= v_pool.qty THEN
      -- 整行還回去：復活成 pending（容器單的 active 品項一律算進 pool_claimed，
      -- 用哪一個 active status 對 _sku_commitment 沒有差別）
      UPDATE customer_order_items
         SET status     = 'pending',
             notes      = TRIM(BOTH E'\n' FROM COALESCE(notes || E'\n', '') || c_done),
             updated_by = p_operator,
             updated_at = p_at
       WHERE id = v_pool.id;
    ELSE
      -- 只還一部分：拆一列 active 出來（折扣按數量比例分攤，同 _consume_internal_pool）
      v_new_disc := round(COALESCE(v_pool.discount_amount, 0) * v_take / v_pool.qty);
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, notes, discount_amount, discount_percent,
        is_gift, gift_reason, gift_marked_by, gift_marked_at,
        created_by, updated_by, created_at, updated_at
      ) VALUES (
        v_pool.tenant_id, v_pool.order_id, v_pool.campaign_item_id, v_pool.sku_id,
        v_take, v_pool.unit_price,
        'pending', v_pool.source,
        TRIM(BOTH E'\n' FROM COALESCE(v_pool.notes || E'\n', '') || c_done),
        v_new_disc, v_pool.discount_percent,
        v_pool.is_gift, v_pool.gift_reason, v_pool.gift_marked_by, v_pool.gift_marked_at,
        p_operator, p_operator, p_at, p_at
      );
      -- 沒還到的部分留在原本那列（仍掛著配貨標記，之後還認得出來）
      UPDATE customer_order_items
         SET qty             = v_pool.qty - v_take,
             discount_amount = COALESCE(v_pool.discount_amount, 0) - v_new_disc,
             updated_by      = p_operator,
             updated_at      = p_at
       WHERE id = v_pool.id;
    END IF;

    v_left := v_left - v_take;
    v_done := v_done + v_take;
  END LOOP;

  -- 容器單被 _close_orders_all_items_settled 收尾成 completed 的話要開回來，
  -- 否則池子的算法（pool_arrived 只認 ready/partially_completed）看不到剛還的貨
  IF array_length(v_touched, 1) > 0 THEN
    UPDATE customer_orders co
       SET status     = CASE WHEN EXISTS (SELECT 1 FROM customer_order_items x
                                           WHERE x.order_id = co.id AND x.status = 'picked_up')
                             THEN 'partially_completed' ELSE 'ready' END,
           completed_at = NULL,
           updated_by = p_operator,
           updated_at = p_at
     WHERE co.id = ANY(v_touched)
       AND co.status = 'completed'
       AND EXISTS (SELECT 1 FROM customer_order_items x
                    WHERE x.order_id = co.id
                      AND x.status IN ('pending','reserved','ready'));
  END IF;

  RETURN v_done;
END;
$$;

COMMENT ON FUNCTION public._restore_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT) IS
  '_consume_internal_pool 的反向：把標著 p_label 的 cancelled 容器單品項還回池子。'
  '整行還 → status 改回 pending；只還一部分 → 拆一列 active 出來。'
  '還過的列蓋 [配貨已取消，退回池子] 章，重跑不會重複還。'
  '被收尾成 completed 的容器單會一起開回來。回傳實際還回去的量。';

REVOKE ALL ON FUNCTION public._restore_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._restore_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT)
  TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. rpc_assign_stock_to_order_item v2
--    基底 20260824070000 逐字保留，只改兩處（都標了 ← v2）：
--      a. 池子標記帶上 DN 單號 —— 取消配貨才認得出是哪一張吃的
--      b. 把 v_from_pool 記進 inventory_deduction_notes.pool_qty
--    ⚠ DN 必須在扣池子**之前**建（v1 就是這個順序），標記字串才拿得到單號。
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
    qty, reason, created_by,
    pool_qty                                            -- ← v2：取消配貨要還池子的上限
  ) VALUES (
    v_b.tenant_id,
    'DN' || to_char(v_now, 'YYMMDD') || lpad(nextval('deduction_note_seq')::text, 4, '0'),
    v_b.campaign_id, v_b.store_id, v_b.sku_id, NULL,
    p_qty,
    COALESCE(NULLIF(TRIM(p_reason), ''), '訂單頁從庫存配貨 ' || v_b.order_no),
    p_operator,
    v_from_pool                                         -- ← v2
  ) RETURNING id, note_no INTO v_note_id, v_note_no;

  INSERT INTO inventory_deduction_note_items (note_id, order_id, order_item_id, qty)
  VALUES (v_note_id, v_b.order_id, p_item_id, p_qty);

  -- 現貨池：這批貨改掛在客人頭上了，池子要同額扣掉（承諾總量不變）
  IF v_from_pool > 0 THEN
    v_pool_done := public._consume_internal_pool(
      v_b.store_id, v_b.sku_id, v_from_pool, p_operator, v_now,
      -- ← v2：帶上 DN 單號，取消配貨時只還自己這張吃掉的那幾列
      '[已配給訂單 ' || v_b.order_no || ' ' || v_note_no || ']');
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
  'Path D 放行）＋清待補貨旗標，需要時從【內部】店現貨池扣（p_use_pool，扣掉的量記在 '
  'DN.pool_qty、池子那幾列標上 DN 單號），整單都可取時把 confirmed 推 ready。'
  '不扣庫存、不結案（取貨時才走 rpc_record_pickup）。反向＝rpc_unassign_stock_from_order_item。'
  '要「當場交貨結案」請用庫存減抵單 rpc_create_inventory_deduction。'
  '可配量走 _order_item_stock_budget（不扣 waiting —— 本行自己就是 waiting）。';

REVOKE ALL ON FUNCTION public.rpc_assign_stock_to_order_item(BIGINT, NUMERIC, UUID, TEXT, BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_assign_stock_to_order_item(BIGINT, NUMERIC, UUID, TEXT, BOOLEAN)
  TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. rpc_get_order_stock_assignments — 這張單哪幾行配過店內現貨、各幾件
--    （訂單頁一次撈完；「↩️ 取消配貨」按鈕要不要出現靠它）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_order_stock_assignments(
  p_order_id BIGINT
) RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_object_agg(x.order_item_id::text, x.info), '{}'::jsonb)
    FROM (
      SELECT ni.order_item_id,
             jsonb_build_object(
               'assigned', SUM(GREATEST(ni.qty - COALESCE(ni.released_qty, 0), 0)),
               'from_pool', SUM(GREATEST(COALESCE(n.pool_qty, 0)
                                         - COALESCE(n.pool_restored_qty, 0), 0)),
               'notes', jsonb_agg(jsonb_build_object(
                          'note_no', n.note_no,
                          'qty',     GREATEST(ni.qty - COALESCE(ni.released_qty, 0), 0),
                          'reason',  n.reason,
                          'created_at', n.created_at) ORDER BY n.id)
             ) AS info
        FROM inventory_deduction_note_items ni
        JOIN inventory_deduction_notes n ON n.id = ni.note_id AND n.cancelled_at IS NULL
       WHERE ni.order_id = p_order_id
         AND ni.qty > COALESCE(ni.released_qty, 0)
       GROUP BY ni.order_item_id
    ) x;
$$;

COMMENT ON FUNCTION public.rpc_get_order_stock_assignments(BIGINT) IS
  '這張訂單各品項身上還有效的減抵覆蓋量（= 從庫存配過幾件）。'
  '回傳 {order_item_id: {assigned, from_pool, notes[]}}；訂單頁用來決定要不要出'
  '「↩️ 取消配貨」按鈕。';

REVOKE ALL ON FUNCTION public.rpc_get_order_stock_assignments(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_order_stock_assignments(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. rpc_unassign_stock_from_order_item — 取消配貨，把貨還回庫存
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_unassign_stock_from_order_item(
  p_item_id  BIGINT,
  p_qty      NUMERIC DEFAULT NULL,   -- NULL = 這一行配過的全部收回
  p_operator UUID    DEFAULT NULL,
  p_reason   TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_role   TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores  JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_b          RECORD;
  v_now        TIMESTAMPTZ := NOW();
  v_qty        NUMERIC;
  v_left       NUMERIC;
  v_take       NUMERIC;
  v_pool_take  NUMERIC;
  v_pool_done  NUMERIC;
  v_pool_total NUMERIC := 0;
  v_pool_miss  NUMERIC := 0;
  v_free_rest  NUMERIC;
  v_pool_rest  NUMERIC;
  v_note_rest  NUMERIC;
  v_notes      TEXT[] := ARRAY[]::TEXT[];
  v_n          RECORD;
  v_merged_id  BIGINT;
  v_merged_qty NUMERIC := 0;
  v_sib        customer_order_items%ROWTYPE;
  v_all_ready  BOOLEAN;
  v_reverted   BOOLEAN := FALSE;
  v_tag        TEXT;
BEGIN
  IF p_qty IS NOT NULL AND (p_qty <= 0 OR p_qty <> FLOOR(p_qty)) THEN
    RAISE EXCEPTION '取消數量必須是正整數';
  END IF;
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '缺少操作人';
  END IF;

  SELECT * INTO v_b FROM public._order_item_stock_budget(p_item_id);
  IF NOT FOUND OR v_b.order_id IS NULL THEN
    RAISE EXCEPTION '找不到訂單品項 #%', p_item_id;
  END IF;

  -- 已取貨 = 貨真的交出去了（sale movement 已寫），這裡收不回來
  IF v_b.item_status = 'picked_up' THEN
    RAISE EXCEPTION '這個品項已經取貨了，要收回請走退貨流程（不是取消配貨）';
  END IF;
  IF v_b.item_status NOT IN ('pending','reserved','ready') THEN
    RAISE EXCEPTION '這個品項是「%」，沒有可取消的配貨', v_b.item_status;
  END IF;
  -- 訂單取消 / 逾期時 trg_release_idn_coverage 已經全額釋放過了
  IF v_b.order_status IN ('cancelled','expired','transferred_out') THEN
    RAISE EXCEPTION '訂單狀態為「%」，覆蓋已經自動釋放，不用再取消配貨', v_b.order_status;
  END IF;

  -- 店家守衛：同 rpc_assign_stock_to_order_item
  IF v_jwt_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉')
     AND NOT (v_my_stores ? v_b.store_name) THEN
    RAISE EXCEPTION 'wrong_store: 這是「%」的單，分店帳號只能動自己店的貨', v_b.store_name;
  END IF;

  -- 與配貨搶同一把鎖：兩邊動的是同一批實體庫存的主張
  PERFORM pg_advisory_xact_lock(hashtext(format('spotsale:%s:%s:%s',
    v_b.tenant_id, v_b.store_id, v_b.sku_id)));

  SELECT * INTO v_b FROM public._order_item_stock_budget(p_item_id);

  IF v_b.assigned <= 0 THEN
    RAISE EXCEPTION '這一行沒有從庫存配過貨，沒有東西可以取消';
  END IF;

  v_qty := COALESCE(p_qty, v_b.assigned);
  IF v_qty > v_b.assigned THEN
    RAISE EXCEPTION '這一行只從庫存配過 % 件，不能取消 % 件', v_b.assigned, v_qty;
  END IF;

  v_left := v_qty;
  v_tag  := COALESCE(NULLIF(TRIM(p_reason), ''), '訂單頁取消配貨');

  -- 逐張 DN 釋放覆蓋（後配的先收回）。記法對齊 _release_idn_coverage_for_orders：
  -- 明細 released_qty 遞增、單頭 qty 遞減、整張歸零就作廢，**不刪列**。
  FOR v_n IN
    SELECT ni.id AS ni_id, ni.qty AS ni_qty, COALESCE(ni.released_qty, 0) AS ni_released,
           n.id AS note_id, n.note_no, n.qty AS note_qty, n.reason AS note_reason,
           COALESCE(n.pool_qty, 0) AS pool_qty,
           COALESCE(n.pool_restored_qty, 0) AS pool_restored
      FROM inventory_deduction_note_items ni
      JOIN inventory_deduction_notes n ON n.id = ni.note_id
     WHERE ni.order_item_id = p_item_id
       AND n.cancelled_at IS NULL
       AND ni.qty > COALESCE(ni.released_qty, 0)
     ORDER BY n.id DESC
       FOR UPDATE OF ni, n
  LOOP
    EXIT WHEN v_left <= 0;

    v_take := LEAST(v_n.ni_qty - v_n.ni_released, v_left);

    UPDATE inventory_deduction_note_items
       SET released_qty = v_n.ni_released + v_take
     WHERE id = v_n.ni_id;

    -- 這張單還沒還的池子量，以及「非池子」的那部分還剩多少 ——
    -- 先還自由量、池子留到最後才還
    v_pool_rest := GREATEST(v_n.pool_qty - v_n.pool_restored, 0);
    v_free_rest := GREATEST((v_n.ni_qty - v_n.ni_released) - v_pool_rest, 0);
    v_pool_take := GREATEST(v_take - v_free_rest, 0);

    IF v_pool_take > 0 THEN
      v_pool_done := public._restore_internal_pool(
        v_b.store_id, v_b.sku_id, v_pool_take, p_operator, v_now,
        '[已配給訂單 ' || v_b.order_no || ' ' || v_n.note_no || ']');
      -- 還不回去（池子那幾列已經被別的流程動過）就記帳、不擋下整筆取消：
      -- 覆蓋已經釋放，那幾件會以「自由量」的身分回到可配量，總量不會憑空多出來。
      v_pool_miss  := v_pool_miss + (v_pool_take - v_pool_done);
      v_pool_total := v_pool_total + v_pool_done;
      UPDATE inventory_deduction_notes
         SET pool_restored_qty = v_n.pool_restored + v_pool_take
       WHERE id = v_n.note_id;
    END IF;

    -- 單頭：整張覆蓋歸零 → 作廢；還有剩 → qty 遞減（沿用 20260813002000 的記法）
    SELECT COALESCE(SUM(GREATEST(x.qty - COALESCE(x.released_qty, 0), 0)), 0)
      INTO v_note_rest
      FROM inventory_deduction_note_items x
     WHERE x.note_id = v_n.note_id;

    IF v_note_rest <= 0 THEN
      UPDATE inventory_deduction_notes
         SET cancelled_at = v_now,
             cancelled_by = p_operator,
             reason = NULLIF(TRIM(COALESCE(reason, '')
                       || format(' [%s，覆蓋全數釋放]', v_tag)), '')
       WHERE id = v_n.note_id;
    ELSE
      UPDATE inventory_deduction_notes
         SET qty = v_note_rest,
             reason = NULLIF(TRIM(COALESCE(reason, '')
                       || format(' [%s，釋放 %s 件]', v_tag, trim_scale(v_take)::text)), '')
       WHERE id = v_n.note_id;
    END IF;

    v_notes := v_notes || v_n.note_no;
    v_left  := v_left - v_take;
  END LOOP;

  IF v_left > 0 THEN
    RAISE EXCEPTION '只收得回 % 件（要求 % 件），請重新整理後再試', v_qty - v_left, v_qty;
  END IF;

  -- 配貨當下拆出去的待補貨行：整筆收回而且那一行還原封不動 → 併回來，
  -- 把畫面收回配貨前的樣子。被動過（改量 / 自己也配過貨 / 已取消）就留著。
  IF v_qty >= v_b.assigned THEN
    SELECT * INTO v_sib
      FROM customer_order_items s
     WHERE s.order_id = v_b.order_id
       AND s.sku_id   = v_b.sku_id
       AND s.id      <> p_item_id
       AND s.status   = v_b.item_status
       AND s.backorder_at IS NOT NULL
       AND s.qty > 0
       AND position('[未配到，待補貨｜拆分自#' || p_item_id || ']' IN COALESCE(s.notes, '')) > 0
       AND NOT EXISTS (
             SELECT 1 FROM inventory_deduction_note_items ni
               JOIN inventory_deduction_notes n ON n.id = ni.note_id AND n.cancelled_at IS NULL
              WHERE ni.order_item_id = s.id
                AND ni.qty > COALESCE(ni.released_qty, 0))
       -- backorders 那兩條 FK 是 NO ACTION：被引用到就刪不掉（整筆取消會一起炸），
       -- 有人引用就不併，留著那一行比取消失敗好
       AND NOT EXISTS (
             SELECT 1 FROM backorders b
              WHERE b.original_customer_order_item_id = s.id
                 OR b.rollover_customer_order_item_id = s.id)
     ORDER BY s.id
     LIMIT 1
       FOR UPDATE;

    IF FOUND THEN
      UPDATE customer_order_items
         SET qty             = qty + v_sib.qty,
             discount_amount = COALESCE(discount_amount, 0) + COALESCE(v_sib.discount_amount, 0),
             updated_by      = p_operator,
             updated_at      = v_now
       WHERE id = p_item_id;
      DELETE FROM customer_order_items WHERE id = v_sib.id;
      v_merged_id  := v_sib.id;
      v_merged_qty := v_sib.qty;
    END IF;
  END IF;

  -- 單頭：配貨推上去的 ready 要退回 confirmed（判準同推進時：整單 active 品項
  -- 是不是都還過得了閘門）。有取過貨的單（partially_completed）不動。
  IF v_b.order_status = 'ready' THEN
    SELECT bool_and(public.is_order_item_pickup_ready(c.id)) INTO v_all_ready
      FROM customer_order_items c
     WHERE c.order_id = v_b.order_id
       AND c.status IN ('pending','reserved','ready');
    IF NOT COALESCE(v_all_ready, TRUE) THEN
      UPDATE customer_orders
         SET status     = 'confirmed',
             ready_at   = NULL,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v_b.order_id
         AND status = 'ready';
      v_reverted := TRUE;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'item_id',       p_item_id,
    'order_id',      v_b.order_id,
    'order_no',      v_b.order_no,
    'qty',           v_qty,
    'remaining',     GREATEST(v_b.assigned - v_qty, 0),
    'to_pool',       v_pool_total,
    'pool_missing',  v_pool_miss,
    'notes',         to_jsonb(v_notes),
    'merged_item_id',  v_merged_id,
    'merged_qty',      v_merged_qty,
    'order_status',  CASE WHEN v_reverted THEN 'confirmed' ELSE v_b.order_status END,
    'reverted',      v_reverted,
    'gate_ready',    public.is_order_item_pickup_ready(p_item_id)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_unassign_stock_from_order_item(BIGINT, NUMERIC, UUID, TEXT) IS
  '訂單頁「取消配貨」＝ rpc_assign_stock_to_order_item 的反向：釋放這一行的 DN 覆蓋'
  '（released_qty 遞增、歸零就作廢單頭，不刪列）、把當初從現貨池扣的量還回池子'
  '（DN.pool_qty 為上限）、整筆取消時把拆出去的待補貨行併回來、單頭 ready 退回 confirmed。'
  '不動 stock_balances —— 配貨本來就沒扣庫存，收回只是把「這批貨有主人」的主張拿掉，'
  '那幾件會重新出現在別人的可配量裡。已取貨的行不給取消（走退貨流程）。';

REVOKE ALL ON FUNCTION public.rpc_unassign_stock_from_order_item(BIGINT, NUMERIC, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_unassign_stock_from_order_item(BIGINT, NUMERIC, UUID, TEXT)
  TO authenticated;

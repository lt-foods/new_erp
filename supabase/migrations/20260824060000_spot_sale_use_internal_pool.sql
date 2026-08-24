-- ============================================================================
-- 現貨直配：把「掛在【內部】xx 店現貨池」的貨也算進可配量（配掉時自動扣池子）
--
-- 回報（Alex 2026-08-24）：「調整庫存完不能把庫存再轉出去」——
--   店員在庫存總覽「＋ 新增庫存」把架上現貨入帳，回頭按「🤝 配給客人」，
--   可配量還是 0；彈窗的提示又寫「架上實際有貨 → 先用『＋ 新增庫存』入帳」，
--   於是繞不出來（線上實測：平鎮店 8/21 08:10 新增 +4 → 08:38 自己撤銷）。
--
-- 線上實測（2026-08-24，四間店 672 組有庫存的 (店,SKU)）：
--   在庫 > 待客取（架上真的有多的貨）的 127 組裡，**100 組配不出去**，
--   其中 82 組的擋路者是 pool（【內部】店容器單），只有 19 組是 waiting。
--   平鎮店一家就有 607 件、松山 105 件卡在這裡。
--   而 pool 裡真正「還在路上」的只有 32 件 —— 也就是說擋住的幾乎全是
--   **已經到店、就在架上**的貨。
--
-- 為什麼原本要扣 pool：池子（RR- / OV- / AB- / SP- 容器單）是店端的現貨帳本，
--   把它賣掉而不扣池子 = 同一批貨掛兩份承諾（取貨閘門的實體庫存守衛
--   20260818000010 會擋下後面那個客人）。原設計因此要求「池子的貨走訂單頁的
--   『轉單給客人』」—— 那條路是對的，但店員在庫存總覽看到有貨卻只拿到一個
--   0 和一句幫不上忙的提示，實務上就是死路。
--
-- 改法：**可配量 = 自由量 ＋ 已到貨的池子量**，而且配掉的時候在同一個交易裡
--   把池子扣掉（跟「轉單給客人」對池子做的事一樣）。承諾總量不變：
--   池子 −N、對客人的承諾 +N。
--
--   free            = on_hand − promised − waiting − pool_claimed        （舊，不動）
--   free_with_pool  = on_hand − promised − waiting − (pool_claimed − pool_arrived)
--
--   在途的池子量（pool_claimed − pool_arrived）**維持保留** —— RR- 單在補貨到店
--   之前就存在，拿架上的貨去沖它就是 20260811000040 修過的那個錯。
--
-- 本檔內容：
--   1. _consume_internal_pool(店, SKU, 量, 操作人, 時間, 標記) — 新：
--      從**已到貨**的容器單吃掉指定數量（整行 cancelled / 拆行，折扣按比例分攤），
--      收尾接 _close_orders_all_items_settled。
--   2. _trim_internal_pool 改成委派上面那支（**零行為變更**的純去重：
--      上限算法、排序、標記字串、回傳值逐字保留）。
--   3. _sku_free_qty_with_pool(店, SKU) — 新：含池子的可配量，全站唯一算法。
--   4. rpc_get_spot_availability：多回 pool_arrived / pool_in_transit / free_with_pool。
--   5. rpc_create_spot_sale：多一個 p_use_pool（預設 FALSE，維持舊行為）。
--      TRUE 時閘門改用 free_with_pool，超出自由量的部分開單後立刻從池子扣，
--      扣不滿就整筆 RAISE（交易回滾）。錯誤訊息改成「講得出下一步」。
--   6. rpc_get_stock_commitment_bulk / rpc_list_allocatable_pairs：
--      「可分配」一律改用 free_with_pool（庫存總覽的欄位與「只看可分配>0」
--      篩選才會跟按鈕按得下去的量一致），另外多回 pool_arrived。
--
-- ⚠ rpc_create_spot_sale 的 8 參數版本要 DROP 掉：新版多一個帶預設值的參數，
--   兩支並存時用 8 個具名參數呼叫會 function is not unique。
--
-- 基底版本（append-only，逐字比對線上 pg_get_functiondef 後抽出）：
--   _trim_internal_pool             = 20260811000040
--   _sku_free_qty / _sku_commitment = 20260816000000（本檔不動）
--   rpc_get_spot_availability       = 20260816000010
--   rpc_get_stock_commitment_bulk   = 20260816000030
--   rpc_list_allocatable_pairs      = 20260816000030
--   rpc_create_spot_sale            = 20260816000060
--
-- Rollback：
--   重跑 20260811000040 的 _trim_internal_pool、20260816000010 的
--   rpc_get_spot_availability、20260816000030 的 rpc_get_stock_commitment_bulk
--   與 rpc_list_allocatable_pairs、20260816000060 的 rpc_create_spot_sale
--   （並 DROP 9 參數版），再
--   DROP FUNCTION public._consume_internal_pool(BIGINT,BIGINT,NUMERIC,UUID,TIMESTAMPTZ,TEXT);
--   DROP FUNCTION public._sku_free_qty_with_pool(BIGINT,BIGINT);
--   已經配出去的 SP- 單不要回滾：池子那一列已標 [已配給客人 SP-...]，
--   要退請走訂單頁取消品項（池子的量要人工加回）。
--
-- 對應前端（同一個 commit）：
--   apps/admin/src/components/SpotSaleModal.tsx
--   apps/admin/src/app/(protected)/inventory/page.tsx
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. _consume_internal_pool — 從已到貨的【內部】店容器單吃掉 N 件
--    （原本內嵌在 _trim_internal_pool 的迴圈，本檔抽出來共用）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._consume_internal_pool(
  p_store_id BIGINT,
  p_sku_id   BIGINT,
  p_qty      NUMERIC,
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW(),
  p_label    TEXT DEFAULT '[已配給團購單]'
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_left     NUMERIC := p_qty;
  v_done     NUMERIC := 0;
  v_new_disc NUMERIC;
  v_split    TEXT;
  v_pool     RECORD;
  v_touched  BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RETURN 0;
  END IF;

  SELECT tenant_id INTO v_tenant FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL THEN
    RETURN 0;
  END IF;

  -- 只吃**已到貨**的容器單（ready / partially_completed）：RR- ride-along 單在
  -- 補貨到店前就存在（pending/confirmed），吃它等於拿還在路上的貨當現貨
  -- （20260811000040 的教訓）。排序讓最早的池子先被吃掉。
  FOR v_pool IN
    SELECT coi.*
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
      JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
     WHERE co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.status IN ('ready','partially_completed')
       AND coi.sku_id = p_sku_id
       AND coi.qty > 0
       AND coi.status IN ('pending','reserved','ready')
     ORDER BY co.created_at, coi.id
     FOR UPDATE OF coi
  LOOP
    EXIT WHEN v_left <= 0;
    v_touched := v_touched || v_pool.order_id;

    IF v_pool.qty <= v_left THEN
      -- 整行被吃掉
      UPDATE customer_order_items
         SET status     = 'cancelled',
             notes      = TRIM(BOTH E'\n' FROM COALESCE(notes || E'\n', '') || p_label),
             updated_by = p_operator,
             updated_at = p_at
       WHERE id = v_pool.id;
      v_left := v_left - v_pool.qty;
      v_done := v_done + v_pool.qty;
    ELSE
      -- 只被吃掉一部分：拆行（折扣按數量比例分攤，同 20260805000100 / 20260810000000）
      -- 拆分標記沿用原字串格式：'[xxx]' → '[xxx|拆分自#123]'
      v_split := CASE
                   WHEN right(p_label, 1) = ']'
                     THEN left(p_label, length(p_label) - 1) || '|拆分自#' || v_pool.id || ']'
                   ELSE p_label || '（拆分自#' || v_pool.id || '）'
                 END;
      v_new_disc := round(COALESCE(v_pool.discount_amount, 0) * v_left / v_pool.qty);
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, notes, discount_amount, discount_percent,
        created_by, updated_by, created_at, updated_at
      ) VALUES (
        v_pool.tenant_id, v_pool.order_id, v_pool.campaign_item_id, v_pool.sku_id,
        v_left, v_pool.unit_price,
        'cancelled', v_pool.source,
        TRIM(BOTH E'\n' FROM COALESCE(v_pool.notes || E'\n', '') || v_split),
        v_new_disc, v_pool.discount_percent,
        p_operator, p_operator, p_at, p_at
      );
      UPDATE customer_order_items
         SET qty             = v_pool.qty - v_left,
             discount_amount = COALESCE(v_pool.discount_amount, 0) - v_new_disc,
             updated_by      = p_operator,
             updated_at      = p_at
       WHERE id = v_pool.id;
      v_done := v_done + v_left;
      v_left := 0;
    END IF;
  END LOOP;

  -- CLAUDE.md：任何把品項改成 cancelled 的路徑，後面接單頭收尾
  IF array_length(v_touched, 1) > 0 THEN
    PERFORM public._close_orders_all_items_settled(v_touched, p_operator, p_at);
  END IF;

  RETURN v_done;
END;
$$;

COMMENT ON FUNCTION public._consume_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT) IS
  '從【內部】xx 店容器單（只算已到貨：ready / partially_completed）吃掉指定數量。'
  '整行吃掉 → cancelled；只吃一部分 → 拆行（折扣按比例分攤），一律標 p_label。'
  '回傳實際吃掉的量（池子不夠時會小於 p_qty，呼叫端自己決定要不要 RAISE）。'
  '呼叫端：_trim_internal_pool（自動配單收斂超額）、rpc_create_spot_sale（現貨直配）。';

REVOKE ALL ON FUNCTION public._consume_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._consume_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT)
  TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. _trim_internal_pool — 改成委派 _consume_internal_pool（零行為變更）
--    上限算法（兩層夾擊）、只吃已到貨、標記字串、回傳值全部逐字保留。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._trim_internal_pool(
  p_store_id BIGINT,
  p_sku_id   BIGINT,
  p_max_trim NUMERIC,
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_pool_qty NUMERIC;
  v_on_hand  NUMERIC := 0;
  v_promised NUMERIC := 0;
  v_trim     NUMERIC;
BEGIN
  IF p_max_trim IS NULL OR p_max_trim <= 0 THEN
    RETURN 0;
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;
  END IF;

  -- 池子目前掛著的未取量。
  -- 20260811(5)：只算**已到貨**的容器單 —— RR- ride-along 單在補貨到店前
  -- 就存在（pending/confirmed），把它算進來等於拿還在路上的貨沖銷已交付量。
  SELECT COALESCE(SUM(coi.qty), 0) INTO v_pool_qty
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status IN ('ready','partially_completed')
     AND coi.sku_id = p_sku_id
     AND coi.qty > 0
     AND coi.status IN ('pending','reserved','ready');

  SELECT COALESCE(sb.on_hand, 0) INTO v_on_hand
    FROM stock_balances sb
   WHERE sb.tenant_id = v_tenant AND sb.location_id = v_loc AND sb.sku_id = p_sku_id;
  v_on_hand := COALESCE(v_on_hand, 0);

  -- 對客人的承諾（未取）；排除 store_internal 容器單與抵減單
  SELECT COALESCE(SUM(coi2.qty), 0) INTO v_promised
    FROM customer_orders co2
    JOIN customer_order_items coi2 ON coi2.order_id = co2.id
    LEFT JOIN members m2 ON m2.id = co2.member_id
   WHERE co2.tenant_id       = v_tenant
     AND co2.pickup_store_id = p_store_id
     AND co2.status IN ('ready','partially_completed','shipping')
     AND COALESCE(co2.order_kind, 'normal') <> 'offset'
     AND COALESCE(m2.member_type, '') <> 'store_internal'
     AND coi2.sku_id = p_sku_id
     AND coi2.qty > 0
     AND coi2.status IN ('pending','reserved','ready');

  v_trim := LEAST(p_max_trim, GREATEST(v_pool_qty - (v_on_hand - v_promised), 0));
  IF v_trim <= 0 THEN
    RETURN 0;
  END IF;

  RETURN public._consume_internal_pool(
    p_store_id, p_sku_id, v_trim, p_operator, p_at, '[已配給團購單]');
END;
$$;

COMMENT ON FUNCTION public._trim_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ) IS
  '自動配單後收斂【內部】店現貨池的超額掛帳：'
  'trim = LEAST(本次配出量, GREATEST(池子未取量 − (on_hand − 已承諾未取), 0))。'
  '實際扣行的動作委派 _consume_internal_pool（20260824060000 抽出，行為不變）。';

-- ----------------------------------------------------------------------------
-- 3. _sku_free_qty_with_pool — 含「已到貨池子」的可配量（全站唯一算法）
--    ＝ on_hand − promised − waiting − 在途池子量，下限 0。
--    與 _sku_free_qty 的差別只有一項：已到貨的池子量不再扣掉，因為配掉的
--    當下會呼叫 _consume_internal_pool 把池子扣掉，承諾總量不變。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sku_free_qty_with_pool(
  p_store_id BIGINT,
  p_sku_id   BIGINT
) RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT GREATEST(
           COALESCE(oh.on_hand, 0)
           - COALESCE(c.promised, 0)
           - COALESCE(c.waiting, 0)
           - (COALESCE(c.pool_claimed, 0) - COALESCE(c.pool_arrived, 0)),
           0)
    FROM (
      SELECT sb.on_hand
        FROM stores st
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = st.tenant_id
              AND sb.location_id = st.location_id
              AND sb.sku_id      = p_sku_id
       WHERE st.id = p_store_id
    ) oh
    LEFT JOIN LATERAL public._sku_commitment(p_store_id, ARRAY[p_sku_id]) c ON TRUE;
$$;

COMMENT ON FUNCTION public._sku_free_qty_with_pool(BIGINT, BIGINT) IS
  '含【內部】店現貨池（已到貨部分）的可配量：'
  'on_hand − promised − waiting − 在途池子量，下限 0。'
  '現貨直配（rpc_create_spot_sale p_use_pool=TRUE）的可配量上限；'
  '配掉超出 _sku_free_qty 的部分時會同步 _consume_internal_pool 扣池子。'
  '在途的池子量刻意不釋放 —— RR- 單在到店前就存在，拿架上的貨沖它是 20260811000040 修過的錯。';

REVOKE ALL ON FUNCTION public._sku_free_qty_with_pool(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._sku_free_qty_with_pool(BIGINT, BIGINT) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. rpc_get_spot_availability — 多回池子拆解與 free_with_pool
--    基底 20260816000010，既有欄位一個都沒動（前端舊版照樣讀得到）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_spot_availability(
  p_store_id BIGINT,
  p_sku_id   BIGINT
) RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'on_hand',      COALESCE(oh.on_hand, 0),
    'promised',     COALESCE(c.promised, 0),
    'waiting',      COALESCE(c.waiting, 0),
    'pool',         COALESCE(c.pool_claimed, 0),
    'free',         public._sku_free_qty(p_store_id, p_sku_id),
    -- 池子拆解：已到貨的可以配（配掉會自動扣池子），在途的維持保留
    'pool_arrived',    COALESCE(c.pool_arrived, 0),
    'pool_in_transit', COALESCE(c.pool_claimed, 0) - COALESCE(c.pool_arrived, 0),
    'free_with_pool',  public._sku_free_qty_with_pool(p_store_id, p_sku_id),
    'suggest_price', COALESCE(
      (SELECT p.price FROM prices p
        WHERE p.tenant_id = oh.tenant_id AND p.sku_id = p_sku_id AND p.scope = 'branch'
          AND p.effective_from <= NOW() AND (p.effective_to IS NULL OR p.effective_to > NOW())
        ORDER BY p.effective_from DESC LIMIT 1),
      (SELECT p.price FROM prices p
        WHERE p.tenant_id = oh.tenant_id AND p.sku_id = p_sku_id AND p.scope = 'retail'
          AND p.effective_from <= NOW() AND (p.effective_to IS NULL OR p.effective_to > NOW())
        ORDER BY p.effective_from DESC LIMIT 1),
      0)
  )
    FROM (
      SELECT st.tenant_id, sb.on_hand
        FROM stores st
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = st.tenant_id
              AND sb.location_id = st.location_id
              AND sb.sku_id      = p_sku_id
       WHERE st.id = p_store_id
    ) oh
    LEFT JOIN LATERAL public._sku_commitment(p_store_id, ARRAY[p_sku_id]) c ON TRUE;
$$;

COMMENT ON FUNCTION public.rpc_get_spot_availability(BIGINT, BIGINT) IS
  '現貨直配彈窗的預檢：在庫 / 待客取 / 等貨中 / 內部池（含拆已到貨與在途）/ '
  '自由量 / 含池子可配量 / 建議售價。'
  '伺服端開單時會再驗一次 _sku_free_qty(_with_pool)，這裡只是畫面預檢。';

REVOKE ALL ON FUNCTION public.rpc_get_spot_availability(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_spot_availability(BIGINT, BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. rpc_create_spot_sale — 多一個 p_use_pool
--    基底 20260816000060（逐字抽出線上定義後只改閘門／池子扣減／錯誤訊息）
-- ----------------------------------------------------------------------------
-- 舊的 8 參數版本一定要先 DROP：新版多一個帶預設值的參數，兩支並存時
-- 用 8 個具名參數呼叫會 "function is not unique"（前端就是這樣呼叫的）。
DROP FUNCTION IF EXISTS public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.rpc_create_spot_sale(
  p_store_id   BIGINT,
  p_sku_id     BIGINT,
  p_qty        NUMERIC,
  p_unit_price NUMERIC,
  p_member_id  BIGINT,
  p_operator   UUID,
  p_nickname   TEXT    DEFAULT NULL,
  p_reason     TEXT    DEFAULT NULL,
  p_use_pool   BOOLEAN DEFAULT FALSE
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
  v_free       NUMERIC;
  v_free_pool  NUMERIC;
  v_cap        NUMERIC;
  v_from_pool  NUMERIC := 0;
  v_pool_done  NUMERIC;
  v_c          RECORD;
  v_on_hand    NUMERIC;
  v_over       NUMERIC;
  v_hint       TEXT;
  v_member     members%ROWTYPE;
  v_campaign   BIGINT;
  v_channel    BIGINT;
  v_ci         BIGINT;
  v_order_id   BIGINT;
  v_order_no   TEXT;
  v_seq        INT;
  v_item_id    BIGINT;
  v_note_id    BIGINT;
  v_note_no    TEXT;
  v_sku_label  TEXT;
BEGIN
  -- ---------- 參數驗證 ----------
  IF p_qty IS NULL OR p_qty <= 0 OR p_qty <> FLOOR(p_qty) THEN
    RAISE EXCEPTION '配貨數量必須是正整數';
  END IF;
  IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
    RAISE EXCEPTION '單價必須大於 0（$0 品項會在取貨時被擋下）';
  END IF;
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '缺少操作人';
  END IF;

  SELECT * INTO v_store FROM stores WHERE id = p_store_id;
  IF NOT FOUND OR v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 不存在或未綁定倉別', p_store_id;
  END IF;

  -- 店家守衛：分店角色只能配「自己店」的貨。配單會佔用該店的自由量、
  -- 取貨時扣的也是該店庫存 —— 跨店配等於把別店的貨賣掉。
  -- 規則對齊 rpc_record_pickup（20260813000000）：stores 為空的 legacy 帳號、
  -- 含「總倉」者、HQ 角色不鎖。分店身分一律看 app_metadata.stores 店名陣列
  -- （線上 33 個分店帳號沒有任何一個有 store_id，見 20260808000020）。
  IF v_jwt_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉')
     AND NOT (v_my_stores ? v_store.name) THEN
    RAISE EXCEPTION 'wrong_store: 這是「%」的庫存，分店帳號只能配自己店的貨', v_store.name;
  END IF;

  SELECT * INTO v_member FROM members WHERE id = p_member_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '會員 % 不存在', p_member_id;
  END IF;
  -- 內部店假會員是現貨池容器，不是客人；要動池子請走「轉單給客人」
  IF COALESCE(v_member.member_type, '') = 'store_internal' THEN
    RAISE EXCEPTION '不能把貨直配給【內部】店帳號 —— 那是現貨池容器。'
      '要把池子的貨賣掉請用訂單頁的「轉單給客人」';
  END IF;
  IF COALESCE(v_member.no_new_order, FALSE) THEN
    RAISE EXCEPTION '會員「%」已被標記為不可新增訂單', COALESCE(v_member.name, p_member_id::TEXT);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM skus WHERE id = p_sku_id) THEN
    RAISE EXCEPTION '品項 % 不存在', p_sku_id;
  END IF;

  -- ---------- 可配量閘門 ----------
  -- 同一個 (店, SKU) 併發配單會各自過閘門，鎖住整組序列化
  PERFORM pg_advisory_xact_lock(hashtext(format('spotsale:%s:%s:%s',
    v_store.tenant_id, p_store_id, p_sku_id)));

  v_free      := public._sku_free_qty(p_store_id, p_sku_id);
  v_free_pool := public._sku_free_qty_with_pool(p_store_id, p_sku_id);
  v_cap       := CASE WHEN p_use_pool THEN v_free_pool ELSE v_free END;

  IF v_cap < p_qty THEN
    -- 錯誤訊息要講清楚「那些貨去哪了」＋「下一步該做什麼」，
    -- 不然店員只看到「不足」會以為系統壞了（或照舊提示一直去新增庫存）
    SELECT * INTO v_c FROM public._sku_commitment(p_store_id, ARRAY[p_sku_id]);
    SELECT COALESCE(sb.on_hand, 0) INTO v_on_hand
      FROM stock_balances sb
     WHERE sb.tenant_id   = v_store.tenant_id
       AND sb.location_id = v_store.location_id
       AND sb.sku_id      = p_sku_id;
    SELECT COALESCE(s.product_name, '') ||
           CASE WHEN s.variant_name IS NOT NULL THEN ' / ' || s.variant_name ELSE '' END
      INTO v_sku_label FROM skus s WHERE s.id = p_sku_id;

    -- 帳上已經超額多少（承諾 > 在庫）：新增庫存要補超過這個數才會有可配量，
    -- 不講的話店員補了 N 件看到可配量還是 0，只會以為系統壞掉
    v_over := GREATEST(COALESCE(v_c.promised, 0) + COALESCE(v_c.waiting, 0)
                       + COALESCE(v_c.pool_claimed, 0) - COALESCE(v_on_hand, 0), 0);

    IF NOT p_use_pool AND COALESCE(v_c.pool_arrived, 0) > 0 THEN
      v_hint := '這批貨掛在【內部】' || v_store.name || '現貨池（已到貨 '
                || COALESCE(v_c.pool_arrived, 0) || ' 件）。'
                || '從庫存總覽的「🤝 配給客人」配就會自動從池子扣，'
                || '或到那張內部單按「轉單給客人」。';
    ELSIF v_over > 0 THEN
      v_hint := '帳上已超額 ' || v_over || ' 件（承諾多於在庫）：'
                || '要「新增庫存」的話得補超過 ' || v_over || ' 件才會有可配量，'
                || '數量對不上請改走「庫存盤點」重盤一次。';
    ELSE
      v_hint := '架上實際有更多貨的話，請先到「庫存總覽」對這個商品「新增庫存」把現貨入帳。';
    END IF;

    RAISE EXCEPTION '「%」可配 % 件、要配 % 件。'
      '（在庫 %，其中待客取 %、等貨中 %、內部單 %（已到 %））%',
      COALESCE(v_sku_label, p_sku_id::TEXT), v_cap, p_qty,
      COALESCE(v_on_hand, 0), COALESCE(v_c.promised, 0),
      COALESCE(v_c.waiting, 0), COALESCE(v_c.pool_claimed, 0),
      COALESCE(v_c.pool_arrived, 0), v_hint;
  END IF;

  -- 超出自由量的部分要從已到貨的池子扣（下面開完單才扣，標記帶得到單號）
  v_from_pool := GREATEST(p_qty - v_free, 0);

  -- ---------- sentinel trio ----------
  v_campaign := public._restock_sentinel_campaign(v_store.tenant_id);
  v_channel  := public._restock_sentinel_channel(v_store.tenant_id, p_store_id);
  v_ci       := public._restock_sentinel_campaign_item(
                  v_store.tenant_id, v_campaign, p_sku_id, p_unit_price);

  -- ---------- 開新單（一次配單一張單）----------
  -- 2026-08-16 回報：兩次配單被併成同一張，會員端「待取貨」只看到 1 筆，
  -- 沒辦法分別取貨 / 分別取消。改成每次配單各開一張 SP- 單。
  --
  -- 能這樣做是因為 customer_orders_trio_kind_active_uniq 的 predicate 已把
  -- SP- 單排除（見同批 migration）。**不新增 order_kind**：新 kind 會被全站
  -- 26 支用 (order_kind='normal' OR IS NULL) 的口徑整批排除（營收、未結金額、
  -- 商品分析…），那才是真正危險的改法。
  --
  -- SP- 序號：MAX-based，不用 COUNT(*)+1 —— 單被硬刪後 COUNT 會倒退、
  -- 重發已用過的號碼撞 unique（20260813000010 湖口 RR-435 事故）。
  PERFORM pg_advisory_xact_lock(hashtext('spot_sale_seq:' || p_store_id::TEXT));
  SELECT COALESCE(MAX(substring(order_no FROM '^SP-' || p_store_id::TEXT || '-([0-9]+)$')::INT), 0) + 1
    INTO v_seq
    FROM customer_orders
   WHERE tenant_id = v_store.tenant_id
     AND order_no ~ ('^SP-' || p_store_id::TEXT || '-[0-9]+$');
  -- lpad 超寬會截斷（lpad('10001',4)='1000'），寬度要跟著位數長
  v_order_no := 'SP-' || p_store_id::TEXT || '-' ||
                LPAD(v_seq::TEXT, GREATEST(length(v_seq::TEXT), 4), '0');

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id,
    nickname_snapshot, pickup_store_id, status, ready_at,
    order_kind, order_type, notes,
    created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_store.tenant_id, v_order_no, v_campaign, v_channel, p_member_id,
    COALESCE(NULLIF(TRIM(p_nickname), ''), v_member.name),
    p_store_id, 'ready', v_now,
    'normal', 'regular',
    '【現貨直配】店內現貨直接配給客人（待取，取貨時才扣庫存收款）' ||
      CASE WHEN v_from_pool > 0
             THEN E'\n其中 ' || v_from_pool || ' 件來自【內部】' || v_store.name || '現貨池（已從池子扣除）'
           ELSE '' END ||
      COALESCE(E'\n' || p_reason, ''),
    p_operator, p_operator, v_now, v_now
  ) RETURNING id INTO v_order_id;

  -- ---------- 品項 ----------
  -- 每次配單一列（不與既有列合併）：兩次配單可能不同價，合併會蓋掉價格。
  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_store.tenant_id, v_order_id, v_ci, p_sku_id, p_qty, p_unit_price,
    'pending', 'manual',
    '[現貨直配] ' || to_char(v_now, 'YYYY-MM-DD HH24:MI') || COALESCE(' / ' || p_reason, ''),
    p_operator, p_operator, v_now, v_now
  ) RETURNING id INTO v_item_id;

  -- ---------- 扣現貨池 ----------
  -- 池子（RR- / OV- / AB- 容器單）是店端的現貨帳本。這批貨改掛在客人名下了，
  -- 池子要同額扣掉，否則同一批貨會有兩份承諾 —— 取貨閘門的實體庫存守衛
  -- （20260818000010）會擋下後面那個客人，而且店員看到的可轉出量是假的。
  -- 扣不滿代表併發或資料異常，整筆 RAISE 讓交易回滾（寧可不開單）。
  IF v_from_pool > 0 THEN
    v_pool_done := public._consume_internal_pool(
      p_store_id, p_sku_id, v_from_pool, p_operator, v_now,
      '[已配給客人 ' || v_order_no || ']');
    IF v_pool_done < v_from_pool THEN
      RAISE EXCEPTION '【內部】%現貨池只扣得到 % 件、需要 % 件（可能同時有人在動同一批貨），請重新整理後再試',
        v_store.name, v_pool_done, v_from_pool;
    END IF;
  END IF;

  -- ---------- 取貨閘門 coverage ----------
  -- 開一張 DN 減抵單 → is_order_item_pickup_ready 的 Path D 放行。
  -- 不靠 Path C（「本店該 SKU 有收過貨」）—— 那是 qty-blind 而且要看歷史，
  -- 自由庫存可能是盤盈 / 自購進來的，根本沒有 transfer 紀錄。
  -- 掛在 sentinel 團底下，不會跟任何真團的 covered 口徑相撞
  -- （真團的 covered 走 picking_wave_items.campaign_id，sentinel 團沒有波次）。
  INSERT INTO inventory_deduction_notes (
    tenant_id, note_no, campaign_id, store_id, sku_id, transfer_id,
    qty, reason, created_by
  ) VALUES (
    v_store.tenant_id,
    'DN' || to_char(v_now, 'YYMMDD') || lpad(nextval('deduction_note_seq')::text, 4, '0'),
    v_campaign, p_store_id, p_sku_id, NULL,
    p_qty, COALESCE(NULLIF(TRIM(p_reason), ''), '現貨直配'), p_operator
  ) RETURNING id, note_no INTO v_note_id, v_note_no;

  INSERT INTO inventory_deduction_note_items (note_id, order_id, order_item_id, qty)
  VALUES (v_note_id, v_order_id, v_item_id, p_qty);

  -- ---------- 收尾 ----------
  RETURN jsonb_build_object(
    'order_id',   v_order_id,
    'order_no',   v_order_no,
    'status',     'ready',
    'item_id',    v_item_id,
    'qty',        p_qty,
    'unit_price', p_unit_price,
    'amount',     p_qty * p_unit_price,
    'note_no',    v_note_no,
    'free_before', v_free,
    'from_pool',   v_from_pool
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT, BOOLEAN) IS
  '現貨直配：把店內現貨直接配給客人（待取，取貨時才扣庫存收款），一次配單一張 SP- 單。'
  '可配量上限＝p_use_pool 為 FALSE 時 _sku_free_qty（在庫 − 待客取 − 等貨 − 內部單）；'
  'TRUE 時 _sku_free_qty_with_pool（已到貨的內部現貨池也算可配），'
  '超出自由量的部分開單後立刻 _consume_internal_pool 從池子扣掉（承諾總量不變）。'
  '同時開一張 DN 讓取貨閘門 Path D 放行。';

REVOKE ALL ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT, BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT, BOOLEAN)
  TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. 庫存總覽的「可分配」欄位與「只看可分配>0」篩選改用 free_with_pool
--    —— 欄位上寫得出來的量，按鈕就要按得下去，兩邊不能各算各的。
--    基底：20260816000030（一間店只呼叫一次 _sku_commitment 的形狀要保留，
--    不要退回 per-row LATERAL，文山 50 列 3.8s 的坑）。
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_get_stock_commitment_bulk(JSONB);

CREATE OR REPLACE FUNCTION public.rpc_get_stock_commitment_bulk(
  p_pairs JSONB
) RETURNS TABLE (
  location_id    BIGINT,
  sku_id         BIGINT,
  promised       NUMERIC,
  waiting        NUMERIC,
  pool           NUMERIC,
  free           NUMERIC,
  pool_arrived   NUMERIC,
  free_with_pool NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH req AS (
    SELECT DISTINCT
           (e ->> 'location_id')::BIGINT AS loc_id,
           (e ->> 'sku_id')::BIGINT      AS s_id
      FROM jsonb_array_elements(COALESCE(p_pairs, '[]'::jsonb)) e
  ),
  -- 只有「有對應分店」的倉別才談得上承諾（總倉沒有客人訂單掛在上面）
  st AS (
    SELECT s.id AS store_id, s.tenant_id, s.location_id
      FROM stores s
     WHERE s.location_id IN (SELECT DISTINCT loc_id FROM req)
  ),
  -- ★ 一間店一次：把該店被問到的所有 SKU 一起丟進去，單趟 GROUP BY 算完。
  --   不要寫成 LEFT JOIN LATERAL _sku_commitment(store, ARRAY[req.s_id])
  --   —— 那會變成每列掃一遍該店訂單（文山 50 列 = 3.8s）。
  comm AS (
    SELECT st.location_id, k.sku_id, k.promised, k.waiting, k.pool_claimed, k.pool_arrived
      FROM st
      CROSS JOIN LATERAL public._sku_commitment(
        st.store_id,
        ARRAY(SELECT r.s_id FROM req r WHERE r.loc_id = st.location_id)
      ) k
  )
  SELECT req.loc_id,
         req.s_id,
         COALESCE(c.promised, 0),
         COALESCE(c.waiting, 0),
         COALESCE(c.pool_claimed, 0),
         GREATEST(
           COALESCE(sb.on_hand, 0)
           - COALESCE(c.promised, 0)
           - COALESCE(c.waiting, 0)
           - COALESCE(c.pool_claimed, 0),
           0),
         COALESCE(c.pool_arrived, 0),
         -- 可分配（含已到貨的內部現貨池）：與 _sku_free_qty_with_pool 同一套
         GREATEST(
           COALESCE(sb.on_hand, 0)
           - COALESCE(c.promised, 0)
           - COALESCE(c.waiting, 0)
           - (COALESCE(c.pool_claimed, 0) - COALESCE(c.pool_arrived, 0)),
           0)
    FROM req
    JOIN st ON st.location_id = req.loc_id
    LEFT JOIN stock_balances sb
           ON sb.tenant_id   = st.tenant_id
          AND sb.location_id = st.location_id
          AND sb.sku_id      = req.s_id
    LEFT JOIN comm c
           ON c.location_id = req.loc_id
          AND c.sku_id      = req.s_id;
$$;

COMMENT ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) IS
  '一次取多組 (倉別, SKU) 的承諾量拆解，給庫存總覽的列表用。'
  'free＝on_hand − promised − waiting − pool_claimed（純自由量）；'
  'free_with_pool＝再把已到貨的內部現貨池加回來（現貨直配配得掉的量，'
  '與 _sku_free_qty_with_pool 同一套）。'
  '一間店只呼叫一次 _sku_commitment（原本每列一次，文山 50 列 3.8s）。';

REVOKE ALL ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_list_allocatable_pairs(
  p_location_id BIGINT   DEFAULT NULL,
  p_sku_ids     BIGINT[] DEFAULT NULL,
  p_limit       INT      DEFAULT 5000
) RETURNS TABLE (
  location_id BIGINT,
  sku_id      BIGINT,
  free        NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH st AS (
    SELECT s.id AS store_id, s.tenant_id, s.location_id
      FROM stores s
     WHERE s.location_id IS NOT NULL
       AND (p_location_id IS NULL OR s.location_id = p_location_id)
  ),
  -- 一間店一次，NULL = 該店全部有承諾的 SKU（單趟 GROUP BY）
  comm AS (
    SELECT st.location_id, k.sku_id, k.promised, k.waiting, k.pool_claimed, k.pool_arrived
      FROM st
      CROSS JOIN LATERAL public._sku_commitment(st.store_id, p_sku_ids) k
  )
  SELECT sb.location_id,
         sb.sku_id,
         sb.on_hand - COALESCE(c.promised, 0) - COALESCE(c.waiting, 0)
                    - (COALESCE(c.pool_claimed, 0) - COALESCE(c.pool_arrived, 0)) AS free
    FROM st
    JOIN stock_balances sb
      ON sb.tenant_id   = st.tenant_id
     AND sb.location_id = st.location_id
     AND sb.on_hand     > 0
    LEFT JOIN comm c
           ON c.location_id = sb.location_id
          AND c.sku_id      = sb.sku_id
   WHERE (p_sku_ids IS NULL OR sb.sku_id = ANY (p_sku_ids))
     AND sb.on_hand - COALESCE(c.promised, 0) - COALESCE(c.waiting, 0)
                    - (COALESCE(c.pool_claimed, 0) - COALESCE(c.pool_arrived, 0)) > 0
   ORDER BY free DESC, sb.sku_id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 5000), 1), 20000);
$$;

COMMENT ON FUNCTION public.rpc_list_allocatable_pairs(BIGINT, BIGINT[], INT) IS
  '列出「現在配得掉」的 (倉別, SKU)：庫存總覽「只看可分配>0」的候選集合。'
  '可分配的定義與 _sku_free_qty_with_pool / rpc_get_stock_commitment_bulk.free_with_pool '
  '完全同一套（含已到貨的內部現貨池，配掉時會自動扣池子）。'
  '一間店只呼叫一次 _sku_commitment；p_location_id 為 NULL 時掃全部分店。';

REVOKE ALL ON FUNCTION public.rpc_list_allocatable_pairs(BIGINT, BIGINT[], INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_list_allocatable_pairs(BIGINT, BIGINT[], INT) TO authenticated;

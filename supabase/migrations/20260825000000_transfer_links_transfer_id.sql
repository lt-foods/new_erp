-- ============================================================
-- 2026-08-25: customer_order_transfer_links 加 transfer_id ——
--             收貨頁的 AT- 單要對得回「是哪一趟、哪家店轉出來的」
--
-- 症狀（平鎮店收貨頁）：同一張轉入單（__INTERNAL_RESTOCK__-TF0497 / #81254）
--   被三家店分三趟空中轉追加（文山 8/21、古華 8/22、經國 8/25），三張 AT- 單
--   在收貨頁全部標「✈ 空中轉 · 來自 文山店」—— 因為畫面反查的是
--   customer_orders.transferred_from_order_id，那一欄只指得到第一趟。
--   後果是店家之間互相指責（被冤枉的店會被念）。
--
-- 為什麼不是改抓 transfers.source_location：空中轉那一段是對的，但經總倉
--   互助的 Leg-2 source 就是總倉（CLAUDE.md「Leg-1 身上沒有訂單」那條），
--   永遠查不出原始店。也不要在畫面上拿 shipped_at 與 link.transferred_at
--   做時間窗比對 —— 那是一次性回填的 heuristic，不該變成每次開頁都跑的邏輯。
--
-- 做法：連結表加 transfer_id（這一趟的貨走的那張 AT- 調撥單）。
--   1. 寫入點一（空中轉，全部路徑）：_air_ship_order_items 建完 AT- 單回頭蓋。
--      兩支轉單 RPC 都是「先寫 link、再呼叫本 helper」（同一交易），
--      rpc_ship_aid_order 後備出貨時 link 更早就存在 → helper 蓋章一處全包，
--      兩支大 RPC 一字不動。以 dest_item_ids && p_item_ids 對（不是時間戳：
--      後備出貨的 NOW() 跟 link.transferred_at 差得遠）。
--   2. 寫入點二（經總倉）：rpc_ship_aid_order 的 2 段分支建完 Leg-2 蓋。
--      蓋 Leg-2 不是 Leg-1 —— Leg-2 才是掛 customer_order_id、收貨店在
--      /wms/inbound 會遇到的那張；Leg-1 的 dest 是總倉。
--   3. 回填兩段（只認 transfer_no LIKE 'AT-%'，⚠ 補貨直派 TR- 單也掛
--      customer_order_id，不加這個守衛會把 TR- 蓋到同店換客人的 link 上 ——
--      套用前實測咬到 3 張 TR2608040384~86）：
--      Pass A：t.shipped_at 落在 [l.transferred_at, +1 秒)（同交易產物；
--              不能用等號 —— 回填的 transferred_at 被截到秒、transfers 留毫秒，
--              同 20260824070000 檔頭）。兩側都要求唯一，歧義不蓋。
--      Pass B：剩下的（經總倉 Leg-2 —— 出貨時間跟轉單時間差得遠），
--              該轉入單只剩一條未蓋 link 且只有一張未蓋的 AT- 單才蓋。
--      套用前實測（2026-08-25 正式庫）：AT- 單全站 22 張，
--      Pass A 11 + Pass B 11 = 22，unmatched 0、歧義 0；
--      截圖那三趟 AT-O81254-* 分別對回文山／古華／經國，與人工判讀一致。
--      對不上的 link 留 NULL（本來就沒有調撥單：經總倉未派、同店換客人），
--      前端 fallback 走原本的訂單鏈反查。
--
-- 基底（⚠ 已與線上 prosrc 逐字比對相符，md5 對過）：
--   - _air_ship_order_items / rpc_ship_aid_order：20260814030000（線上＝repo）。
-- Rollback：
--   重跑 20260814030000 的兩支 function；
--   ALTER TABLE customer_order_transfer_links DROP COLUMN transfer_id;
-- ============================================================

ALTER TABLE public.customer_order_transfer_links
  ADD COLUMN IF NOT EXISTS transfer_id BIGINT
    REFERENCES public.transfers(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.customer_order_transfer_links.transfer_id IS
  '這一趟轉移的貨走的那張 AT- 調撥單（空中轉一趟一張；經總倉指 Leg-2 —— '
  '掛 customer_order_id、收貨店收的那張）。NULL = 這一趟沒有調撥單'
  '（經總倉還沒派貨、同店換客人）或回填對不上的舊資料。'
  '收貨頁 /wms/inbound 靠它顯示「來自哪家店」；不要再用 transferred_from_order_id '
  '反查 —— 一張轉入單可有多趟來源，那一欄只指得到第一趟。';

CREATE INDEX IF NOT EXISTS idx_transfer_links_transfer
  ON public.customer_order_transfer_links (transfer_id)
  WHERE transfer_id IS NOT NULL;

-- ------------------------------------------------------------
-- 1. _air_ship_order_items：建完 AT- 單回頭蓋 link.transfer_id。
--    基底 20260814030000 逐字保留，只加尾端 UPDATE 一段。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._air_ship_order_items(
  p_order_id     BIGINT,       -- 轉入單（新建或併入的既有單）
  p_src_store_id BIGINT,       -- 轉出店
  p_item_ids     BIGINT[],     -- 本次搬進轉入單的 customer_order_items.id
  p_operator     UUID,
  p_at           TIMESTAMPTZ
) RETURNS BIGINT               -- 建好的 transfer id；沒建（同店 / 無品項）→ NULL
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ord           customer_orders%ROWTYPE;
  v_src_location  BIGINT;
  v_dst_location  BIGINT;
  v_transfer_id   BIGINT;
  v_transfer_no   TEXT;
  v_prior         INT;
  v_item          RECORD;
  v_fallback_cost NUMERIC;
  v_mov_id        BIGINT;
  v_shipped       INT := 0;
BEGIN
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_ord FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到轉入訂單 #%', p_order_id;
  END IF;

  SELECT location_id INTO v_src_location FROM stores WHERE id = p_src_store_id;
  SELECT location_id INTO v_dst_location FROM stores WHERE id = v_ord.pickup_store_id;
  IF v_src_location IS NULL OR v_dst_location IS NULL THEN
    RAISE EXCEPTION '空中轉需要轉出店與接收店都有對應倉庫：轉出店 #% 的倉庫=%、接收店 #% 的倉庫=%',
                    p_src_store_id, v_src_location, v_ord.pickup_store_id, v_dst_location;
  END IF;

  -- 同一間店 = 貨沒有移動（同店換客人、或併入的既有單本來就在轉出店）→ 不建轉移單
  IF v_src_location = v_dst_location THEN
    RETURN NULL;
  END IF;

  -- 同一張轉入單可能被分次追加（部分轉出兩次以上）→ 單號加序避免撞
  -- transfers_tenant_id_transfer_no_key
  SELECT COUNT(*) INTO v_prior FROM transfers WHERE customer_order_id = p_order_id;
  v_transfer_no := 'AT-O' || p_order_id || '-' || EXTRACT(EPOCH FROM p_at)::BIGINT
                   || CASE WHEN v_prior > 0 THEN '-' || (v_prior + 1)::TEXT ELSE '' END;

  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, is_air_transfer, customer_order_id, next_transfer_id,
    notes, requested_by, shipped_by, shipped_at, created_by, updated_by
  ) VALUES (
    v_ord.tenant_id, v_transfer_no, v_src_location, v_dst_location,
    'shipped', 'store_to_store', TRUE, p_order_id, NULL,
    '[空中轉] 轉單時自動出貨 → 訂單 #' || p_order_id || ' (' || v_ord.order_no || ')',
    p_operator, p_operator, p_at, p_operator, p_operator
  ) RETURNING id INTO v_transfer_id;

  FOR v_item IN
    SELECT coi.sku_id, coi.qty
      FROM customer_order_items coi
     WHERE coi.id = ANY(p_item_ids)
       AND coi.order_id = p_order_id
       AND coi.sku_id IS NOT NULL
       AND coi.status IN ('pending','reserved','ready')
     ORDER BY coi.id
  LOOP
    -- avg_cost 缺值時以現行成本價計價，否則月結 air_in / air_out 會是 0 元
    v_fallback_cost := public._current_cost_price(v_ord.tenant_id, v_item.sku_id);

    -- p_allow_negative => TRUE：轉出店的 on_hand 常低於實際（同 SKU 被別張單
    -- 取走、到貨沒入帳…）。擋下來整筆轉單就失敗、單子永遠卡在收件匣
    -- （2026-08-01 湖口 → 龍潭那兩張卡了 13 天）。貨實際上是離開轉出店了，
    -- 記下這筆出庫比拒絕記錄準確；負庫存在庫存頁看得到，由盤點收。
    v_mov_id := rpc_outbound(
      p_tenant_id          => v_ord.tenant_id,
      p_location_id        => v_src_location,
      p_sku_id             => v_item.sku_id,
      p_quantity           => v_item.qty,
      p_movement_type      => 'transfer_out',
      p_source_doc_type    => 'transfer',
      p_source_doc_id      => v_transfer_id,
      p_operator           => p_operator,
      p_allow_negative     => TRUE,
      p_fallback_unit_cost => v_fallback_cost
    );

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped, out_movement_id,
      created_by, updated_by
    ) VALUES (
      v_transfer_id, v_item.sku_id, v_item.qty, v_item.qty, v_mov_id,
      p_operator, p_operator
    );
    v_shipped := v_shipped + 1;
  END LOOP;

  -- 一件都沒搬到（品項都被取消 / 沒有 sku）→ 不留空殼轉移單
  IF v_shipped = 0 THEN
    DELETE FROM transfers WHERE id = v_transfer_id;
    RETURN NULL;
  END IF;

  -- 這張 AT- 單對回它那一趟的 order↔order 連結（20260825000000）：
  -- 收貨頁靠 link.transfer_id 顯示「來自哪家店」。兩支轉單 RPC 都是
  -- 「先寫 link、再呼叫本 helper」（同交易）；rpc_ship_aid_order 後備出貨時
  -- link 更早就存在。用品項集合對、不用時間戳 —— 後備出貨的 NOW() 跟
  -- link.transferred_at 差得遠，時間窗對不上。
  UPDATE customer_order_transfer_links
     SET transfer_id = v_transfer_id
   WHERE dest_order_id = p_order_id
     AND transfer_id IS NULL
     AND dest_item_ids && p_item_ids;

  -- 轉入單直接進「配送中」：接收店在收貨頁收掉這張 AT- 單就變可取貨
  -- （rpc_receive_transfer 邏輯 B：customer_order_id FK → shipping → ready）。
  -- 併入的既有單若已 ready / 部分取貨，不倒退它的 status。
  UPDATE customer_orders
     SET status      = 'shipping',
         shipping_at = COALESCE(shipping_at, p_at),
         updated_by  = p_operator,
         updated_at  = p_at
   WHERE id = p_order_id
     AND status IN ('pending','confirmed');

  RETURN v_transfer_id;
END;
$$;

COMMENT ON FUNCTION public._air_ship_order_items(BIGINT, BIGINT, BIGINT[], UUID, TIMESTAMPTZ) IS
  '空中轉出貨共用實作：建 AT- 轉移單（store_to_store/shipped/is_air_transfer）＋轉出店出庫'
  '（allow_negative，缺 avg_cost 時 fallback 現行成本價）＋轉入單 pending/confirmed → shipping。'
  '同 location 或沒有可出貨品項 → 回 NULL 不建單。呼叫者：兩支轉單 RPC + rpc_ship_aid_order。'
  '建完回頭把 customer_order_transfer_links.transfer_id 蓋上（以 dest_item_ids 對趟次）。'
  '基底 20260814030000。';

GRANT EXECUTE ON FUNCTION public._air_ship_order_items(BIGINT, BIGINT, BIGINT[], UUID, TIMESTAMPTZ)
  TO authenticated;

-- ------------------------------------------------------------
-- 2. rpc_ship_aid_order：經總倉分支建完 Leg-2 蓋 link.transfer_id。
--    基底 20260814030000 逐字保留（空中轉分支委派 helper，蓋章已在 helper 裡）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_ship_aid_order(
  p_order_id BIGINT,
  p_operator UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order        customer_orders%ROWTYPE;
  v_src_order    customer_orders%ROWTYPE;
  v_src_store_id BIGINT;
  v_src_location BIGINT;
  v_dst_location BIGINT;
  v_hq_location  BIGINT;
  v_leg1_id      BIGINT;
  v_leg2_id      BIGINT;
  v_leg1_no      TEXT;
  v_leg2_no      TEXT;
  v_item         RECORD;
  v_mov_id       BIGINT;
  v_items_count  INTEGER := 0;
  v_total_qty    NUMERIC := 0;
  v_epoch        BIGINT;
  v_item_ids     BIGINT[];
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  IF v_order.status <> 'confirmed' THEN
    RAISE EXCEPTION 'aid order % is %, only confirmed can ship', p_order_id, v_order.status;
  END IF;

  IF v_order.transferred_from_order_id IS NULL THEN
    RAISE EXCEPTION 'aid order % has no transferred_from_order_id', p_order_id;
  END IF;

  -- 已經有轉移單就不要再出一次（空中轉自 20260814030000 起在轉單時就出貨，
  -- 這支只剩「補推卡住的舊單」的後備角色）
  IF EXISTS (
    SELECT 1 FROM transfers
     WHERE customer_order_id = p_order_id AND status <> 'cancelled'
  ) THEN
    RAISE EXCEPTION '訂單 #% 已經有轉移單、不需要再派貨（請到收貨頁收該張 AT- 單）', p_order_id;
  END IF;

  SELECT * INTO v_src_order
    FROM customer_orders
   WHERE id = v_order.transferred_from_order_id;
  IF NOT FOUND OR v_src_order.pickup_store_id IS NULL THEN
    RAISE EXCEPTION 'source order % has no pickup_store', v_order.transferred_from_order_id;
  END IF;
  v_src_store_id := v_src_order.pickup_store_id;

  SELECT location_id INTO v_src_location
    FROM stores WHERE id = v_src_store_id;
  IF v_src_location IS NULL THEN
    RAISE EXCEPTION 'store % has no location_id', v_src_store_id;
  END IF;

  SELECT location_id INTO v_dst_location
    FROM stores WHERE id = v_order.pickup_store_id;
  IF v_dst_location IS NULL THEN
    RAISE EXCEPTION 'store % has no location_id', v_order.pickup_store_id;
  END IF;

  IF v_src_location = v_dst_location THEN
    RAISE EXCEPTION 'source and dest store share location_id %, cannot ship', v_src_location;
  END IF;

  -- 收 aid items 預檢
  IF NOT EXISTS (
    SELECT 1 FROM customer_order_items
     WHERE order_id = p_order_id AND source = 'aid_transfer'
  ) THEN
    RAISE EXCEPTION 'order % has no aid_transfer items', p_order_id;
  END IF;

  IF COALESCE(v_order.is_air_transfer, FALSE) THEN
    -- ========== 空中轉：1 段，跟轉單時的自動出貨走同一個 helper ==========
    SELECT COALESCE(array_agg(id), '{}'::BIGINT[])
      INTO v_item_ids
      FROM customer_order_items
     WHERE order_id = p_order_id
       AND source = 'aid_transfer'
       AND status IN ('pending','reserved','ready');

    v_leg1_id := public._air_ship_order_items(
      p_order_id, v_src_store_id, v_item_ids, p_operator, NOW());

    IF v_leg1_id IS NULL THEN
      RAISE EXCEPTION '訂單 #% 沒有可出貨的品項（未取消／未取走的品項為 0）', p_order_id;
    END IF;

    SELECT COUNT(*), COALESCE(SUM(qty_shipped), 0)
      INTO v_items_count, v_total_qty
      FROM transfer_items WHERE transfer_id = v_leg1_id;

    RETURN jsonb_build_object(
      'order_id', p_order_id,
      'is_air_transfer', TRUE,
      'transfer_ids', jsonb_build_array(v_leg1_id),
      'items_count', v_items_count,
      'total_qty', v_total_qty
    );
  ELSE
    -- ========== 經總倉：2 段（逐字保留 20260510000004）==========
    SELECT id INTO v_hq_location
      FROM locations
     WHERE tenant_id = v_order.tenant_id
       AND type = 'central_warehouse'
       AND is_active
     ORDER BY id
     LIMIT 1;
    IF v_hq_location IS NULL THEN
      RAISE EXCEPTION 'no central warehouse location for tenant';
    END IF;

    v_epoch := EXTRACT(EPOCH FROM NOW())::BIGINT;
    v_leg1_no := 'AT-O' || p_order_id || '-L1-' || v_epoch;
    v_leg2_no := 'AT-O' || p_order_id || '-L2-' || v_epoch;

    -- Leg-2：先建（draft），拿 id
    INSERT INTO transfers (
      tenant_id, transfer_no, source_location, dest_location,
      status, transfer_type, customer_order_id, next_transfer_id,
      requested_by, created_by, updated_by
    ) VALUES (
      v_order.tenant_id, v_leg2_no, v_hq_location, v_dst_location,
      'draft', 'hq_to_store', p_order_id, NULL,
      p_operator, p_operator, p_operator
    ) RETURNING id INTO v_leg2_id;

    FOR v_item IN
      SELECT sku_id, qty FROM customer_order_items
       WHERE order_id = p_order_id AND source = 'aid_transfer'
    LOOP
      INSERT INTO transfer_items (
        transfer_id, sku_id, qty_requested, qty_shipped,
        created_by, updated_by
      ) VALUES (
        v_leg2_id, v_item.sku_id, v_item.qty, 0,
        p_operator, p_operator
      );
    END LOOP;

    -- Leg-1：source → HQ，立刻 ship + outbound source
    INSERT INTO transfers (
      tenant_id, transfer_no, source_location, dest_location,
      status, transfer_type, customer_order_id, next_transfer_id,
      requested_by, shipped_by, shipped_at, created_by, updated_by
    ) VALUES (
      v_order.tenant_id, v_leg1_no, v_src_location, v_hq_location,
      'shipped', 'store_to_store', NULL, v_leg2_id,
      p_operator, p_operator, NOW(), p_operator, p_operator
    ) RETURNING id INTO v_leg1_id;

    FOR v_item IN
      SELECT sku_id, qty FROM customer_order_items
       WHERE order_id = p_order_id AND source = 'aid_transfer'
    LOOP
      v_mov_id := rpc_outbound(
        p_tenant_id       => v_order.tenant_id,
        p_location_id     => v_src_location,
        p_sku_id          => v_item.sku_id,
        p_quantity        => v_item.qty,
        p_movement_type   => 'transfer_out',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => v_leg1_id,
        p_operator        => p_operator
      );
      INSERT INTO transfer_items (
        transfer_id, sku_id, qty_requested, qty_shipped,
        out_movement_id, created_by, updated_by
      ) VALUES (
        v_leg1_id, v_item.sku_id, v_item.qty, v_item.qty,
        v_mov_id, p_operator, p_operator
      );
      v_items_count := v_items_count + 1;
      v_total_qty := v_total_qty + v_item.qty;
    END LOOP;

    -- link.transfer_id 蓋 Leg-2（20260825000000）—— Leg-2 才是掛
    -- customer_order_id、收貨店在 /wms/inbound 會遇到的那張；Leg-1 的 dest
    -- 是總倉。這支是後備入口，訂單可能是 20260824060000 一趟一單之前的
    -- 併單舊資料（多條 link）——那種情況多條 link 蓋同一張 Leg-2 是事實：
    -- 這次出貨把整張單的 aid 品項都裝在同一箱。只蓋還沒有 transfer_id 的。
    UPDATE customer_order_transfer_links
       SET transfer_id = v_leg2_id
     WHERE dest_order_id = p_order_id
       AND transfer_id IS NULL;

    UPDATE customer_orders
       SET status = 'shipping',
           shipping_at = NOW(),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = p_order_id;

    RETURN jsonb_build_object(
      'order_id', p_order_id,
      'is_air_transfer', FALSE,
      'transfer_ids', jsonb_build_array(v_leg1_id, v_leg2_id),
      'items_count', v_items_count,
      'total_qty', v_total_qty
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_ship_aid_order(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_ship_aid_order IS
  'Aid order 派貨：confirmed → shipping。空中轉委派 _air_ship_order_items（跟轉單時的自動出貨'
  '同一套，容忍轉出店庫存不足）；經總倉維持 2 段 chain，Leg-2 蓋 link.transfer_id。'
  '已有轉移單者擋下（不重複出貨）。'
  '空中轉自 20260814030000 起在轉單時就出貨，這支只剩補推舊單的後備角色。基底 20260814030000。';

-- ------------------------------------------------------------
-- 3. 回填既有資料。
--    ⚠ 兩段都只認 transfer_no LIKE 'AT-%'：補貨直派的 TR- 單也掛
--    customer_order_id，但那不是轉單趟次 —— 不加守衛，Pass B 會把 TR-
--    蓋到「同店換客人」的 link 上（套用前實測咬到 TR2608040384~86 三張）。
-- ------------------------------------------------------------

-- Pass A：同交易產物 —— t.shipped_at 落在 [l.transferred_at, +1 秒)。
-- 不能用等號：連結表回填時 transferred_at 被截到秒、transfers 留著毫秒
-- （20260824070000 檔頭，線上 link 516 = 09:13:06 對 09:13:06.810991）。
-- 兩側都要求唯一（一條 link 只有一張候選、一張 transfer 只有一條候選），
-- 歧義的不蓋、留給 Pass B 或人工。
WITH cand AS (
  SELECT l.id AS link_id, t.id AS transfer_id
    FROM customer_order_transfer_links l
    JOIN transfers t
      ON t.customer_order_id = l.dest_order_id
     AND t.status <> 'cancelled'
     AND t.transfer_no LIKE 'AT-%'
     AND t.shipped_at >= l.transferred_at
     AND t.shipped_at <  l.transferred_at + INTERVAL '1 second'
   WHERE l.transfer_id IS NULL
), one_tr_per_link AS (
  SELECT link_id, MIN(transfer_id) AS transfer_id
    FROM cand GROUP BY link_id HAVING COUNT(DISTINCT transfer_id) = 1
), uniq AS (
  SELECT MIN(link_id) AS link_id, transfer_id
    FROM one_tr_per_link GROUP BY transfer_id HAVING COUNT(*) = 1
)
UPDATE customer_order_transfer_links l
   SET transfer_id = u.transfer_id
  FROM uniq u
 WHERE l.id = u.link_id;

-- Pass B：剩下的（經總倉 Leg-2 —— transfer 是派貨當下建的，時間跟
-- link.transferred_at 差得遠，Pass A 撈不到）。該轉入單只剩一條未蓋的
-- link 且只有一張未被蓋走的 AT- 單，才一對一蓋上；其餘留 NULL 給前端 fallback。
WITH lone_link AS (
  SELECT dest_order_id, MIN(id) AS link_id
    FROM customer_order_transfer_links
   WHERE transfer_id IS NULL
   GROUP BY dest_order_id HAVING COUNT(*) = 1
), lone_tr AS (
  SELECT t.customer_order_id AS dest_order_id, MIN(t.id) AS transfer_id
    FROM transfers t
   WHERE t.customer_order_id IS NOT NULL
     AND t.status <> 'cancelled'
     AND t.transfer_no LIKE 'AT-%'
     AND NOT EXISTS (SELECT 1 FROM customer_order_transfer_links l2
                      WHERE l2.transfer_id = t.id)
   GROUP BY t.customer_order_id HAVING COUNT(*) = 1
)
UPDATE customer_order_transfer_links l
   SET transfer_id = lt.transfer_id
  FROM lone_link ll
  JOIN lone_tr lt USING (dest_order_id)
 WHERE l.id = ll.link_id;

-- 驗證（套用後跑）：
--   SELECT COUNT(*) FILTER (WHERE l.id IS NOT NULL) AS linked, COUNT(*) AS at_total
--     FROM transfers t
--     LEFT JOIN customer_order_transfer_links l ON l.transfer_id = t.id
--    WHERE t.customer_order_id IS NOT NULL AND t.status <> 'cancelled'
--      AND t.transfer_no LIKE 'AT-%';
--   -- 預期 linked = at_total（2026-08-25 實測 22 = 22）

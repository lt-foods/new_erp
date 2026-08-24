-- ============================================================
-- 2026-08-24: 互助的貨要看得出「哪一趟是哪一趟」—— 互助轉單一律開新單
--
-- 症狀（店家回報）：「為什麼我都找不到 #249 其中一筆提供給互助的單？」
--   互助板 #249 是平鎮店的需求貼文（艋舺嫩煎雞腿排 (C)紐奧良 ×2）。
--   松山店 8/24 12:27 從 OV-2-0001 提供 1 件過去，但那件**沒有自己的單**：
--   它被併進平鎮店既有的 __INTERNAL_RESTOCK__-TF0497。那張單身上已經有
--   皮蛋醬（文山 8/21）、堅果（SP-1-0002 8/21）、牛肉絲（古華 8/22）——
--   4 家店、跨 4 天、4 件不相干的貨掛在同一張單上，店員看不出哪一件是
--   哪一次互助來的，也印不出只有自己那批貨的隨貨單。
--
-- 為什麼會併：rpc_transfer_order_partial 建轉入單前會找
--   (tenant, campaign, channel, member) 都相同的 active 單，找到就併進去。
--   這把 key 是為了「同一位客人同一團只有一張單」而設，對互助卻是**退化**的：
--   收件人固定是接收店的「【內部】xx 店」、來源又常是 __INTERNAL_RESTOCK__
--   sentinel 團 → 一家店所有的互助收貨，永遠都是同一把 key。
--   而併單那條路是被 customer_orders_trio_kind_active_uniq 這個唯一索引
--   逼出來的，不是可以單純拿掉的分支。
--
-- 做法：
--   1. customer_orders 加 aid_board_id（哪一則互助貼文帶來的這張單）。
--   2. customer_orders_trio_kind_active_uniq 的 predicate 加
--      「AND aid_board_id IS NULL」—— 互助單不受「一團一頻道一會員一張單」限制，
--      其餘完全不變（restock / SP- 的既有豁免原樣保留）。
--   3. rpc_transfer_order_partial 加 p_aid_board_id：非 NULL 時跳過併單、
--      一律開新單，並把 board id 蓋在新單與 customer_order_transfer_links 上。
--   4. rpc_claim_manual_spot 透傳 p_board_id。
--   5. 回填：把已經被併進容器單、且辨識得出屬於互助板的品項搬成獨立單
--      （線上剛好 1 筆 = #249 那筆；更早的轉移在連結表回填時原始 reason 就
--       已經遺失，辨識不出來，留給新分頁用「一趟轉移一列」的方式呈現）。
--
-- 基底版本（⚠ 一律以**線上 prosrc** 為基底重寫，不是 repo 檔案）：
--   - rpc_transfer_order_partial：線上版（含 20260824000100 的
--     customer_order_transfer_links 寫入段）。repo 最新的
--     20260814030000_air_transfer_ship_on_transfer.sql 少了那一段，
--     照 repo 改會把 #826 的連結表修正整個蓋掉。
--   - rpc_claim_manual_spot：線上版（= 20260816000000_manual_spot_claimable.sql）。
--
-- 沒有動到的：
--   - 非互助的轉單（p_aid_board_id 預設 NULL）行為一字未改，照樣併單。
--   - 現貨池：池子是獨立的 OV- 單（_get_or_create_surplus_pool_order），
--     _trim_internal_pool / _sku_commitment 都是逐品項加總，
--     同一批貨拆成兩張單不影響任何數量。
--   - 取貨閘門、月結、撿貨：都以品項為單位，品項 id 在回填時是**搬列不是複製**
--     （同 _stockout_po_items 的原則），所有既有引用都還指得到。
--
-- Rollback：
--   DROP INDEX customer_orders_trio_kind_active_uniq;
--   CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq ON public.customer_orders
--     USING btree (tenant_id, campaign_id, channel_id, member_id, order_kind)
--     WHERE ((status <> ALL (ARRAY['transferred_out'::text,'expired'::text,'cancelled'::text]))
--            AND (order_kind <> 'restock'::text) AND (order_no !~~ 'SP-%'::text));
--   -- 並把 rpc_transfer_order_partial / rpc_claim_manual_spot 重跑線上舊版
--   -- （DROP FUNCTION rpc_transfer_order_partial(bigint,bigint,bigint,bigint,uuid,text,jsonb,boolean,bigint) 之後）
--   ALTER TABLE customer_order_transfer_links DROP COLUMN aid_board_id;
--   ALTER TABLE customer_orders DROP COLUMN aid_board_id;
-- ============================================================

-- ------------------------------------------------------------
-- 1. 互助貼文 → 轉入單 的印記
-- ------------------------------------------------------------
ALTER TABLE public.customer_orders
  ADD COLUMN IF NOT EXISTS aid_board_id BIGINT
    REFERENCES public.mutual_aid_board(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.customer_orders.aid_board_id IS
  '這張轉入單是哪一則互助貼文帶來的（一趟互助 = 一張單）。'
  '非 NULL 的單不受 customer_orders_trio_kind_active_uniq 限制 —— '
  '同一家店對同一個 sentinel 團會有很多趟互助收貨，本來就不該只有一張單。';

CREATE INDEX IF NOT EXISTS idx_customer_orders_aid_board
  ON public.customer_orders (aid_board_id) WHERE aid_board_id IS NOT NULL;

ALTER TABLE public.customer_order_transfer_links
  ADD COLUMN IF NOT EXISTS aid_board_id BIGINT
    REFERENCES public.mutual_aid_board(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.customer_order_transfer_links.aid_board_id IS
  '這一趟轉移是哪一則互助貼文促成的（互助板的「我提供出去的」分頁靠它撈）。';

CREATE INDEX IF NOT EXISTS idx_transfer_links_aid_board
  ON public.customer_order_transfer_links (aid_board_id) WHERE aid_board_id IS NOT NULL;

-- ------------------------------------------------------------
-- 2. 唯一索引放行互助單
--    predicate 其餘部分逐字照抄線上定義，只多一個 aid_board_id IS NULL
-- ------------------------------------------------------------
DROP INDEX IF EXISTS public.customer_orders_trio_kind_active_uniq;

CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq
  ON public.customer_orders
  USING btree (tenant_id, campaign_id, channel_id, member_id, order_kind)
  WHERE ((status <> ALL (ARRAY['transferred_out'::text, 'expired'::text, 'cancelled'::text]))
         AND (order_kind <> 'restock'::text)
         AND (order_no !~~ 'SP-%'::text)
         AND (aid_board_id IS NULL));

-- ------------------------------------------------------------
-- 3. rpc_transfer_order_partial：加 p_aid_board_id
--    舊的 8 參數版本一定要 DROP —— 只 CREATE OR REPLACE 會多出一個
--    overload，8 個位置參數的呼叫會變成 "function is not unique"。
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_transfer_order_partial(
  bigint, bigint, bigint, bigint, uuid, text, jsonb, boolean);

CREATE OR REPLACE FUNCTION public.rpc_transfer_order_partial(
  p_order_id bigint,
  p_to_pickup_store_id bigint,
  p_to_member_id bigint,
  p_to_channel_id bigint,
  p_operator uuid,
  p_reason text,
  p_items jsonb,
  p_is_air_transfer boolean DEFAULT false,
  p_aid_board_id bigint DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$
DECLARE
  v_orig             customer_orders%ROWTYPE;
  v_tenant_id        UUID;
  v_to_member_id     BIGINT;
  v_to_channel_id    BIGINT;
  v_new_order_id     BIGINT;
  v_new_order_no     TEXT;
  v_seq              INT;
  v_campaign_no      TEXT;
  v_p_item           JSONB;
  v_p_sku_id         BIGINT;
  v_p_qty            NUMERIC;
  v_src_item_id      BIGINT;
  v_src_item_qty     NUMERIC;
  v_src_item_ci      BIGINT;
  v_src_item_price   NUMERIC;
  v_src_item_reserved BIGINT;
  v_remaining_count  INT;
  v_now              TIMESTAMPTZ := NOW();
  v_existing_order   BIGINT;
  v_appended         BOOLEAN := FALSE;
  v_new_status       TEXT;
  v_src_is_internal  BOOLEAN := FALSE;
  v_dst_is_internal  BOOLEAN := FALSE;
  v_retail_price     NUMERIC;
  v_item_price       NUMERIC;
  v_reopened         TEXT;
  v_new_item_id      BIGINT;
  v_new_item_ids     BIGINT[] := '{}'::BIGINT[];
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION '未指定任何要轉移的品項';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 #%', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  -- 跨店轉單維持「貨到店才能轉」：ready 之外也放行 partially_completed ——
  -- 已取走過品項代表貨到過店，剩餘 active 品項物理上就在店裡（內部現貨池
  -- 臨櫃賣掉一件就進 partially_completed，不放行等於池子賣過一次就不能再轉，
  -- 2026-08-14 湖口 INT0116）。品項挑選本來就限 active，picked_up 不會被轉走。
  -- 同店互轉（換客人）貨進同一間店、不影響總倉派貨量，到貨前也可轉。
  -- 同店預轉仍排除三種「貨不走本店波次」的單（轉走會斷到貨推進鏈）：
  --   a. 非一般團購單（restock ride-along 靠 order_no='RR-x' 特判推 ready、offset 無實貨）
  --   b. 有進行中的調撥 FK 指著它（互助/空中轉/補貨直派 → 到貨判定綁原單 id）
  --   c. 自己就是跨店轉入、貨還沒到的單（到貨判定同樣綁 transfer FK）
  IF v_orig.status NOT IN ('ready','partially_completed') THEN
    IF p_to_pickup_store_id <> v_orig.pickup_store_id THEN
      RAISE EXCEPTION '貨還沒到分店、訂單 % 不可跨店轉單 (status=%)；同店換客人不受此限',
                      p_order_id, v_orig.status;
    END IF;
    IF v_orig.status NOT IN ('pending','confirmed','reserved','shipping') THEN
      RAISE EXCEPTION '訂單 % 狀態（%）不可轉單', p_order_id, v_orig.status;
    END IF;
    IF COALESCE(v_orig.order_kind, 'normal') <> 'normal' THEN
      RAISE EXCEPTION '訂單 % 不是一般團購單（%），須等分店收貨後再轉單',
                      p_order_id, v_orig.order_kind;
    END IF;
    IF EXISTS (SELECT 1 FROM transfers t
                WHERE t.customer_order_id = p_order_id
                  AND t.tenant_id = v_tenant_id
                  AND t.status <> 'cancelled') THEN
      RAISE EXCEPTION '訂單 % 有進行中的調撥，請等分店收貨後再轉單', p_order_id;
    END IF;
    IF v_orig.transferred_from_order_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM customer_orders src
          WHERE src.id = v_orig.transferred_from_order_id
            AND src.pickup_store_id IS DISTINCT FROM v_orig.pickup_store_id) THEN
      RAISE EXCEPTION '訂單 % 是跨店轉入、貨還沒到，請等分店收貨後再轉單', p_order_id;
    END IF;
  END IF;

  IF v_orig.transferred_to_order_id IS NOT NULL THEN
    RAISE EXCEPTION '訂單 #% 已轉出至訂單 #%，不可重複轉出',
                    p_order_id, v_orig.transferred_to_order_id;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_to_pickup_store_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收店（ID %）不存在或不屬於目前商戶', p_to_pickup_store_id;
  END IF;

  v_to_member_id := COALESCE(
    p_to_member_id,
    rpc_get_or_create_store_member(p_to_pickup_store_id, p_operator)
  );

  PERFORM 1 FROM members WHERE id = v_to_member_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收會員（ID %）不存在或不屬於目前商戶', v_to_member_id;
  END IF;

  -- 內部單（【內部】xx店）轉給真會員 = 門市現貨銷售 → 轉出價改鎖現售價。
  -- 店↔店互助（目標也是 store_internal）維持原價不變。
  SELECT (m.member_type = 'store_internal') INTO v_src_is_internal
    FROM members m WHERE m.id = v_orig.member_id;
  v_src_is_internal := COALESCE(v_src_is_internal, FALSE);
  SELECT (m.member_type = 'store_internal') INTO v_dst_is_internal
    FROM members m WHERE m.id = v_to_member_id;
  v_dst_is_internal := COALESCE(v_dst_is_internal, FALSE);

  v_to_channel_id := p_to_channel_id;
  IF v_to_channel_id IS NULL THEN
    SELECT id INTO v_to_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id AND home_store_id = p_to_pickup_store_id
     LIMIT 1;
    IF v_to_channel_id IS NULL THEN
      SELECT id INTO v_to_channel_id
        FROM line_channels
       WHERE tenant_id = v_tenant_id
       LIMIT 1;
    END IF;
  END IF;
  IF v_to_channel_id IS NULL THEN
    RAISE EXCEPTION '接收店找不到可用的 LINE 頻道，無法建立轉入訂單';
  END IF;

  SELECT id INTO v_existing_order
    FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = v_orig.campaign_id
     AND channel_id  = v_to_channel_id
     AND member_id   = v_to_member_id
     AND status NOT IN ('expired','cancelled','transferred_out');

  -- 查到的既有單 = 來源單本身（同活動＋同頻道＋同會員轉給自己）→ 擋下，
  -- 否則會把品項「轉進」它自己（同 20260806000010 對整單轉的守衛）
  IF v_existing_order = p_order_id THEN
    RAISE EXCEPTION '這張訂單本來就掛在該接收人（同活動、同頻道）名下，不需要轉出';
  END IF;

  -- 互助板的轉單一律開新單，不併進既有的容器單（20260824060000）。
  -- (團, 頻道, 會員) 這把併單 key 對互助來說是退化的：收件人固定是接收店的
  -- 「【內部】xx 店」、來源又常是 __INTERNAL_RESTOCK__ sentinel 團 —— 於是
  -- 同一家店所有的互助收貨永遠併成同一張。2026-08-24 平鎮店 TF0497 就堆了
  -- 4 家店、跨 4 天的 4 件不相干的貨（皮蛋醬／堅果／牛肉絲／雞腿排），
  -- 店員看不出哪一件是哪一次互助來的，也印不出只有自己那批貨的單。
  -- 新單身上會蓋 aid_board_id，而 customer_orders_trio_kind_active_uniq
  -- 的 predicate 已排除蓋過章的單，所以第二張開得出來。
  IF p_aid_board_id IS NOT NULL THEN
    v_existing_order := NULL;
  END IF;

  IF v_existing_order IS NOT NULL THEN
    v_new_order_id := v_existing_order;
    v_appended := TRUE;
    SELECT order_no INTO v_new_order_no FROM customer_orders WHERE id = v_existing_order;
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[追加轉入 (部分, ' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
                   ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') ||
                   COALESCE(' / ' || p_reason, ''),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_new_order_id;
  ELSE
    SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
    -- TF 序號 = 該團既有 -TF 尾碼最大值 + 1。
    -- COUNT(*)+1 在 RR- 單被硬刪（rpc_delete_restock_request）後會倒退、
    -- 重發已用過的號碼 → duplicate key（2026-08-13 湖口 RR-435 事故）。
    -- 團鎖：來源單鎖擋不住兩張不同來源單同時轉出算出同一號。
    PERFORM pg_advisory_xact_lock(hashtext('order_tf_seq:' || v_orig.campaign_id::text));
    SELECT COALESCE(MAX(substring(order_no FROM '-TF([0-9]+)$')::INT), 0) + 1
      INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id
       AND campaign_id = v_orig.campaign_id
       AND order_no ~ '-TF[0-9]+$';
    -- lpad 超寬會截斷（lpad('10001',4)='1000'），寬度要跟著位數長
    v_new_order_no := v_campaign_no || '-TF' ||
                      lpad(v_seq::text, GREATEST(length(v_seq::text), 4), '0');

    -- 同店：mirror source.status，但 partially_completed 映成 'ready' ——
    -- 新單一件都還沒取走，掛「部分取貨」是錯的（取貨頁與收尾邏輯都會誤判）；
    -- 跨店空中轉：confirmed（尾端 helper 會接著建 AT- 單並推 shipping）；
    -- 跨店經總倉：'pending'（維持總倉確認 gate）
    v_new_status := CASE
      WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN
        CASE WHEN v_orig.status = 'partially_completed' THEN 'ready' ELSE v_orig.status END
      WHEN p_is_air_transfer THEN 'confirmed'
      ELSE 'pending'
    END;

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, notes,
      transferred_from_order_id, is_air_transfer, aid_board_id,
      created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
      v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status,
      COALESCE(p_reason, '') ||
        E'\n[轉入 (部分, ' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
        ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
        to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
      p_order_id, p_is_air_transfer, p_aid_board_id,
      p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_new_order_id;
  END IF;

  FOR v_p_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_p_sku_id := (v_p_item ->> 'sku_id')::BIGINT;
    v_p_qty    := (v_p_item ->> 'qty')::NUMERIC;
    IF v_p_qty IS NULL OR v_p_qty <= 0 THEN
      RAISE EXCEPTION '轉移數量必須大於 0';
    END IF;

    SELECT id, qty, campaign_item_id, unit_price, reserved_movement_id
      INTO v_src_item_id, v_src_item_qty, v_src_item_ci, v_src_item_price, v_src_item_reserved
      FROM customer_order_items
     WHERE order_id = p_order_id
       AND sku_id   = v_p_sku_id
       -- 只挑 active 品項當轉出來源；picked_up（貨已交付）/ expired 的列
       -- 拿來轉會把已交付的貨再轉給別人（同 2026-08-10 整單轉出復活 cancelled 品項的事故類型）
       AND status   IN ('pending','reserved','ready')
     ORDER BY id
     LIMIT 1
     FOR UPDATE;
    IF v_src_item_id IS NULL THEN
      RAISE EXCEPTION 'SKU % 不在訂單 #% 內（或品項已取消／已取走），無法轉移', v_p_sku_id, p_order_id;
    END IF;
    IF v_src_item_reserved IS NOT NULL THEN
      RAISE EXCEPTION 'SKU % 已有庫存配貨紀錄（#%），請先釋放配貨再轉移',
                      v_p_sku_id, v_src_item_reserved;
    END IF;
    IF v_src_item_qty < v_p_qty THEN
      RAISE EXCEPTION 'SKU % 可轉數量不足：來源剩 %、要求轉出 %',
                      v_p_sku_id, v_src_item_qty, v_p_qty;
    END IF;

    -- 內部單 → 真會員：轉出價鎖定當下 SKU 現售價（scope='retail' 最新生效版）；
    -- 查無現售價 fallback 來源價。其餘情境維持原價。
    v_item_price := v_src_item_price;
    IF v_src_is_internal AND NOT v_dst_is_internal THEN
      SELECT price INTO v_retail_price
        FROM prices
       WHERE tenant_id = v_tenant_id
         AND sku_id    = v_p_sku_id
         AND scope     = 'retail'
         AND effective_from <= v_now
         AND (effective_to IS NULL OR effective_to > v_now)
       ORDER BY effective_from DESC
       LIMIT 1;
      v_item_price := COALESCE(v_retail_price, v_src_item_price);
    END IF;

    IF v_src_item_qty = v_p_qty THEN
      UPDATE customer_order_items
         SET status = 'cancelled', updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    ELSE
      UPDATE customer_order_items
         SET qty = qty - v_p_qty, updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_new_order_id, v_src_item_ci, v_p_sku_id, v_p_qty, v_item_price,
      'pending', 'aid_transfer', p_operator, p_operator
    ) RETURNING id INTO v_new_item_id;
    -- 本次搬進去的品項 id 留給空中轉出貨（helper 只出這一批，
    -- 不能整張單重出 —— 之前分次追加的品項已經有自己的 AT- 單了）
    v_new_item_ids := array_append(v_new_item_ids, v_new_item_id);
  END LOOP;

  SELECT COUNT(*) INTO v_remaining_count
    FROM customer_order_items
   WHERE order_id = p_order_id AND status != 'cancelled';

  IF v_remaining_count = 0 THEN
    UPDATE customer_orders
       SET status = 'transferred_out',
           transferred_to_order_id = v_new_order_id,
           notes = COALESCE(notes, '') ||
                   E'\n[全部轉出 → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  ELSE
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[' || CASE WHEN v_appended THEN '部分追加' ELSE '部分轉出' END ||
                   ' → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  END IF;

  -- 部分取貨的來源單把剩餘 active 全轉走後要收尾成 completed：
  -- remaining_count 算 status != 'cancelled' 會數到 picked_up 列，永遠走不到
  -- transferred_out 分支（這是對的 —— 已取走的營收要留在原單），但也因此
  -- 沒人關單頭。helper 自帶守衛（無 active + 至少一件 picked_up 才動作），
  -- 其餘情境呼叫等於 no-op。
  PERFORM public._close_orders_all_items_settled(ARRAY[p_order_id], p_operator, v_now);

  -- 追加到「已取貨完成」的既有單時，把它重開 —— 否則新品項會被埋在 completed
  -- 單裡：待取清單看不到、is_order_item_pickup_ready 也擋著不給取（見 20260805000140）。
  IF v_appended THEN
    v_reopened := public._reopen_order_if_completed(
      v_new_order_id, p_operator,
      '追加轉入 ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')');
  END IF;

  -- 這一趟轉移的 order↔order 連結。**兩條分支都要寫**（新建轉入單 / 追加併入
  -- 既有單）—— 只有前者會寫 transferred_from_order_id，追加分支以前什麼線索都
  -- 沒留下，轉出店的儀表板提醒、轉出記錄、隨貨單三個畫面同時查無此事
  -- （2026-08-24 松山→古華喜願蛋）。dest_item_ids 只放本次搬進去的品項，
  -- 轉出店才不會看到／印到別家店在同一張轉入單上的貨。
  INSERT INTO public.customer_order_transfer_links (
    tenant_id, source_order_id, dest_order_id, dest_item_ids,
    is_air_transfer, is_partial, appended, reason, transferred_at, created_by,
    aid_board_id)
  VALUES (
    v_tenant_id, p_order_id, v_new_order_id, COALESCE(v_new_item_ids, '{}'::BIGINT[]),
    COALESCE(p_is_air_transfer, FALSE), TRUE, v_appended, p_reason, v_now, p_operator,
    p_aid_board_id)
  ON CONFLICT (source_order_id, dest_order_id, transferred_at) DO NOTHING;

  -- 空中轉：貨當下就從轉出店出去 → 建 AT- 轉移單 + 出庫，轉入單進 shipping。
  -- 接收店在收貨頁收掉就可取貨，沒有「派貨」這一步。同店由 helper 判掉。
  IF COALESCE(p_is_air_transfer, FALSE) THEN
    PERFORM public._air_ship_order_items(
      v_new_order_id, v_orig.pickup_store_id, v_new_item_ids, p_operator, v_now);
  END IF;

  RETURN v_new_order_id;
END;
$fn$;

-- 線上 ACL 原樣還原（DROP 會一起帶走 GRANT）
GRANT EXECUTE ON FUNCTION public.rpc_transfer_order_partial(
  bigint, bigint, bigint, bigint, uuid, text, jsonb, boolean, bigint)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.rpc_transfer_order_partial(
  bigint, bigint, bigint, bigint, uuid, text, jsonb, boolean, bigint) IS
  '部分轉單。p_aid_board_id 非 NULL = 這是互助板的轉單：一律開新單（不併進'
  '既有容器單）、並把貼文 id 蓋在轉入單與 customer_order_transfer_links 上。';

-- ------------------------------------------------------------
-- 4. rpc_claim_manual_spot：透傳 board id（簽名不變，直接 REPLACE）
-- ------------------------------------------------------------
-- ⚠ 參數預設值要跟線上一字不差，少寫會被擋：
--   ERROR 42P13: cannot remove parameter defaults from existing function
CREATE OR REPLACE FUNCTION public.rpc_claim_manual_spot(
  p_board_id bigint,
  p_to_store_id bigint,
  p_qty numeric,
  p_operator uuid,
  p_reason text DEFAULT NULL::text,
  p_is_air_transfer boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $claim$
DECLARE
  v_board        mutual_aid_board%ROWTYPE;
  v_tenant       UUID;
  v_store_name   TEXT;
  v_member       BIGINT;
  v_campaign     BIGINT;
  v_channel      BIGINT;
  v_ci           BIGINT;
  v_price        NUMERIC;
  v_seq          INT;
  v_order_no     TEXT;
  v_order_id     BIGINT;
  v_dest_order   BIGINT;
  v_board_status TEXT;
  v_now          TIMESTAMPTZ := NOW();
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION '認領數量需 > 0';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('aid_board_claim:' || p_board_id::TEXT));

  SELECT * INTO v_board FROM mutual_aid_board WHERE id = p_board_id FOR UPDATE;
  IF v_board.id IS NULL THEN
    RAISE EXCEPTION '找不到互助貼文 #%', p_board_id;
  END IF;
  IF v_board.post_type <> 'offer' THEN
    RAISE EXCEPTION '只有「釋出」貼文可以認領';
  END IF;
  IF v_board.status <> 'active' THEN
    RAISE EXCEPTION '此貼文已結束（%），不能認領', v_board.status;
  END IF;
  -- 有來源訂單的貼文走原本那條（前端直接呼叫 rpc_transfer_order_partial），
  -- 不要在這裡另外生一張載體單、憑空多出一份貨
  IF v_board.source_customer_order_id IS NOT NULL THEN
    RAISE EXCEPTION '此貼文有來源訂單，請走原本的認領流程';
  END IF;
  IF v_board.sku_id IS NULL THEN
    RAISE EXCEPTION '此貼文還沒選商品，釋出店要先用「✏️ 修改內容」補選商品才能被認領';
  END IF;
  IF v_board.qty_remaining < p_qty THEN
    RAISE EXCEPTION '認領數量超過剩餘量（剩 %）', v_board.qty_remaining;
  END IF;
  IF p_to_store_id = v_board.offering_store_id THEN
    RAISE EXCEPTION '接收店不能是釋出店本身';
  END IF;

  SELECT tenant_id, name INTO v_tenant, v_store_name
    FROM stores WHERE id = v_board.offering_store_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION '釋出店（ID %）不存在', v_board.offering_store_id;
  END IF;

  v_member   := rpc_get_or_create_store_member(v_board.offering_store_id, p_operator);
  v_campaign := _restock_sentinel_campaign(v_tenant);
  v_channel  := _restock_sentinel_channel(v_tenant, v_board.offering_store_id);

  -- 單價：貼文自訂價 → 分店價 → 零售價 → 0（同 _grow_internal_pool）
  v_price := v_board.spot_price;
  IF v_price IS NULL THEN
    SELECT price INTO v_price
      FROM prices
     WHERE tenant_id = v_tenant AND sku_id = v_board.sku_id AND scope = 'branch'
       AND effective_from <= v_now AND (effective_to IS NULL OR effective_to > v_now)
     ORDER BY effective_from DESC
     LIMIT 1;
  END IF;
  IF v_price IS NULL THEN
    SELECT price INTO v_price
      FROM prices
     WHERE tenant_id = v_tenant AND sku_id = v_board.sku_id AND scope = 'retail'
       AND effective_from <= v_now AND (effective_to IS NULL OR effective_to > v_now)
     ORDER BY effective_from DESC
     LIMIT 1;
  END IF;
  v_price := COALESCE(v_price, 0);

  SELECT COUNT(*) + 1 INTO v_seq
    FROM customer_orders
   WHERE tenant_id = v_tenant
     AND order_no LIKE 'AB-' || v_board.offering_store_id::TEXT || '-%';
  v_order_no := 'AB-' || v_board.offering_store_id::TEXT || '-' || LPAD(v_seq::TEXT, 4, '0');

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id, pickup_store_id,
    status, ready_at, order_kind, order_type, notes,
    created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant, v_order_no, v_campaign, v_channel, v_member, v_board.offering_store_id,
    'ready', v_now, 'restock', 'regular',
    '【內部】互助板現貨載體 #' || p_board_id ||
      COALESCE('（' || NULLIF(trim(v_board.spot_title), '') || '）', ''),
    p_operator, p_operator, v_now, v_now
  ) RETURNING id INTO v_order_id;

  v_ci := _restock_sentinel_campaign_item(v_tenant, v_campaign, v_board.sku_id, v_price);

  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant, v_order_id, v_ci, v_board.sku_id, p_qty, v_price,
    'pending', 'store_internal', '[互助板認領 #' || p_board_id || ']',
    p_operator, p_operator, v_now, v_now
  );

  -- 轉給認領店：空中轉當下就建 AT- 單並從釋出店出庫（20260814030000），
  -- 沒勾則走經總倉兩段（總倉收件匣派貨）
  v_dest_order := rpc_transfer_order_partial(
    p_order_id           => v_order_id,
    p_to_pickup_store_id => p_to_store_id,
    p_to_member_id       => NULL,
    p_to_channel_id      => NULL,
    p_operator           => p_operator,
    p_reason             => COALESCE(NULLIF(trim(p_reason), ''), '互助板認領 #' || p_board_id),
    p_items              => jsonb_build_array(
                              jsonb_build_object('sku_id', v_board.sku_id, 'qty', p_qty)
                            ),
    p_is_air_transfer    => COALESCE(p_is_air_transfer, FALSE),
    -- 互助認領一律開新單、並把貼文 id 蓋在轉入單與轉移連結上（20260824060000）
    p_aid_board_id       => p_board_id
  );

  v_board_status := rpc_consume_aid_board(p_board_id, p_qty, p_operator);

  RETURN jsonb_build_object(
    'board_id',         p_board_id,
    'board_status',     v_board_status,
    'carrier_order_id', v_order_id,
    'carrier_order_no', v_order_no,
    'dest_order_id',    v_dest_order,
    'qty',              p_qty
  );
END;
$claim$;

GRANT EXECUTE ON FUNCTION public.rpc_claim_manual_spot(
  bigint, bigint, numeric, uuid, text, boolean)
  TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- 5. 回填：已被併進容器單的互助品項 → 拆成獨立轉入單
--
--    只處理「辨識得出是互助板」的轉移（reason 帶「互助板」）。更早的併入在
--    20260824000100 回填連結表時原始 reason 就已經遺失，硬猜會把一般的店對店
--    轉貨也拆掉 —— 那些改用新分頁「一趟轉移一列」呈現就夠了，不動資料。
--
--    ⚠ 搬列（UPDATE order_id）不是複製：品項 id 不變，
--      customer_order_transfer_links.dest_item_ids、撿貨、月結的既有引用
--      才不會斷（同 _stockout_po_items 的原則）。
-- ------------------------------------------------------------
DO $backfill$
DECLARE
  r              RECORD;
  v_seq          INT;
  v_campaign_no  TEXT;
  v_new_order_id BIGINT;
  v_new_order_no TEXT;
  v_new_status   TEXT;
  v_split        INT := 0;
  v_now          TIMESTAMPTZ := NOW();
BEGIN
  FOR r IN
    SELECT l.id AS link_id, l.source_order_id, l.dest_order_id, l.dest_item_ids,
           l.is_air_transfer, l.reason, l.transferred_at,
           (regexp_match(l.reason, '互助板[^#]*#([0-9]+)'))[1]::BIGINT AS board_id,
           d.tenant_id, d.campaign_id, d.channel_id, d.member_id,
           d.pickup_store_id, d.status AS dest_status, d.nickname_snapshot,
           s.order_no AS src_no
      FROM customer_order_transfer_links l
      JOIN customer_orders d ON d.id = l.dest_order_id
      JOIN customer_orders s ON s.id = l.source_order_id
     WHERE l.appended
       AND l.reason ~ '互助板'
       AND s.pickup_store_id IS DISTINCT FROM d.pickup_store_id
     ORDER BY l.transferred_at
  LOOP
    -- 只搬還在店裡的品項；已取貨 / 已取消的動了就是改到歷史
    IF NOT EXISTS (
      SELECT 1 FROM customer_order_items i
       WHERE i.id = ANY (r.dest_item_ids)
         AND i.order_id = r.dest_order_id
         AND i.status IN ('pending','reserved','ready')
    ) THEN CONTINUE; END IF;

    -- 搬走之後容器單不能一件都不剩（那是把容器單搬空、留一張空殼）
    IF NOT EXISTS (
      SELECT 1 FROM customer_order_items i
       WHERE i.order_id = r.dest_order_id
         AND NOT (i.id = ANY (r.dest_item_ids))
    ) THEN CONTINUE; END IF;

    SELECT campaign_no INTO v_campaign_no
      FROM group_buy_campaigns WHERE id = r.campaign_id;

    -- TF 序號比照 rpc_transfer_order_partial：MAX+1，不是 COUNT+1
    PERFORM pg_advisory_xact_lock(hashtext('order_tf_seq:' || r.campaign_id::text));
    SELECT COALESCE(MAX(substring(order_no FROM '-TF([0-9]+)$'))::INT, 0) + 1
      INTO v_seq
      FROM customer_orders
     WHERE tenant_id = r.tenant_id AND campaign_id = r.campaign_id
       AND order_no ~ '-TF[0-9]+$';
    v_new_order_no := v_campaign_no || '-TF' ||
                      lpad(v_seq::text, GREATEST(length(v_seq::text), 4), '0');

    -- 容器單掛 partially_completed 是因為**別的**品項被取走了；
    -- 拆出來這張一件都還沒取，掛 ready 才對（同 RPC 的 mirror 規則）
    v_new_status := CASE WHEN r.dest_status = 'partially_completed'
                         THEN 'ready' ELSE r.dest_status END;

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id, nickname_snapshot,
      pickup_store_id, status, notes, transferred_from_order_id, is_air_transfer,
      aid_board_id, created_at, updated_at
    ) VALUES (
      r.tenant_id, v_new_order_no, r.campaign_id, r.channel_id, r.member_id,
      r.nickname_snapshot, r.pickup_store_id, v_new_status,
      '[回填拆單] 原本併在訂單 #' || r.dest_order_id || '，依來源單 #' ||
        r.source_order_id || ' (' || r.src_no || ') 拆成獨立轉入單' ||
        COALESCE(' / ' || r.reason, ''),
      r.source_order_id, COALESCE(r.is_air_transfer, FALSE),
      r.board_id, r.transferred_at, v_now
    ) RETURNING id INTO v_new_order_id;

    UPDATE customer_order_items
       SET order_id = v_new_order_id, updated_at = v_now
     WHERE id = ANY (r.dest_item_ids) AND order_id = r.dest_order_id;

    UPDATE customer_order_transfer_links
       SET dest_order_id = v_new_order_id, appended = FALSE, aid_board_id = r.board_id
     WHERE id = r.link_id;

    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[拆單] 來源單 #' || r.source_order_id || ' 那一趟的貨已拆到 ' ||
                   v_new_order_no || '（' || to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') || '）',
           updated_at = v_now
     WHERE id = r.dest_order_id;

    v_split := v_split + 1;
  END LOOP;

  RAISE NOTICE '互助回填拆單：% 筆', v_split;
END;
$backfill$;

-- ============================================================================
-- 2026-08-16：手動現貨也能被別店認領（互助交流板）
--
-- 需求（店家回報）：「互助交流上面針對有人釋出，分店上來要可以認領，
--   現在怎麼看不到認領的按鈕」。
--
-- 現況（線上實測 2026-08-16）：進行中的釋出貼文 29 則，其中
--   **27 則是「➕ 手動新增現貨」發的**（source_customer_order_id IS NULL）——
--   前端刻意不畫認領鈕（「沒有訂單可以轉移給別店」），只有 2 則從訂單釋出的
--   才有鈕。而 27 則裡有 20 則連 sku_id 都是 NULL（純手打標題）。
--
-- 認領的本體是「訂單轉移」：rpc_transfer_order_partial 把釋出店那張來源訂單的
-- 品項轉成認領店的單，貨才會走既有那一套（空中轉當下建 AT- 單並出庫 / 經總倉
-- 兩段派貨、收貨頁收貨、月結一加一扣）。手動現貨沒有來源訂單，所以要補一張。
--
-- 做法：
--   1. rpc_claim_manual_spot(board, to_store, qty, operator, reason, is_air)
--      認領當下才在釋出店建一張**載體單** AB-<store>-<seq>
--      （restock sentinel trio ＋【內部】xx 店 member、order_kind='restock'、
--       單頭 ready 以便轉單），寫一列 qty = 認領量的品項，接著在**同一個交易**
--      裡呼叫 rpc_transfer_order_partial 轉給認領店，最後 rpc_consume_aid_board 扣量。
--
--      ⚠ 為什麼是「認領當下才建、當下就轉走」，不是發文時就建：
--        載體單掛在 member_type='store_internal' 上，只要它以 ready 停留在庫裡，
--        就會進 _trim_internal_pool（20260811000030 / 20260811000040）的池子口徑 ——
--        手動現貨常常是店家自己的貨、根本不在 stock_balances.on_hand 裡，
--        下一次自動配單就會把它當「超額掛帳」砍掉（標 [已配給團購單]），
--        貼文的貨會莫名其妙消失。建完就轉走則品項立刻變 cancelled / 換到別店，
--        不在 ('pending','reserved','ready') 口徑內，池子收斂看不到它。
--
--      單價：spot_price 優先 → 分店價 → 零售價 → 0（同 _grow_internal_pool 的
--      fallback 順序）。0 元守衛（20260815000000）本來就排除 store_internal 容器單，
--      且 rpc_transfer_order_partial 轉給真會員時會改鎖現售價，不會流到客人身上。
--
--      庫存：轉出是既有那一套（空中轉走 _air_ship_order_items，p_allow_negative
--      => TRUE，20260814030000）。手動現貨的貨本來就可能沒入帳，出庫記成負的
--      比拒絕記錄準確，交給盤點。
--
--   2. rpc_update_aid_board_listing 10 → 11 參數（加 p_sku_id）：
--      既有 20 則沒 SKU 的貼文要能「補選商品」才認領得了。只有手動現貨
--      （source_customer_order_id IS NULL）能改 SKU —— 從訂單釋出的貼文
--      SKU 綁著來源訂單品項，改了就對不到帳。
--      NULL = 不動（不是清除）：清掉 SKU 只會讓貼文退回不可認領，沒有意義。
--
--      連帶修 qty_available 覆寫：原版「手動現貨沒有認領扣量」所以
--      qty_available / qty_remaining 一起覆寫；手動現貨開放認領之後這個假設
--      不成立了，改成保留已認領量（remaining = 新 available − 已認領），
--      並擋下「改到比已認領量還小」。
--
-- 基底版本（append-only，逐字保留所有 prior fix；已與線上 pg_get_functiondef
--   逐字 diff 確認一致）：
--   rpc_update_aid_board_listing = 20260802000050_spot_cross_store_visibility.sql
--
-- Rollback：
--   DROP FUNCTION public.rpc_claim_manual_spot(BIGINT,BIGINT,NUMERIC,UUID,TEXT,BOOLEAN);
--   DROP FUNCTION public.rpc_update_aid_board_listing(
--     BIGINT,UUID,NUMERIC,TEXT,TIMESTAMPTZ,TEXT,JSONB,TEXT,NUMERIC,BOOLEAN,BIGINT);
--   重跑 20260802000050 的 rpc_update_aid_board_listing 段落（前端要一起回退，
--   不然編輯表單送 11 個參數會 404）。
--   已認領出去的貨要退回請走既有的「↩ 退單（已收貨）」/ 撤回派貨，
--   載體單 AB-<store>-<seq> 留著當軌跡，不要直接刪。
--
-- 對應前端（同一個 commit）：
--   apps/admin/src/app/(protected)/inventory/mutual-aid/page.tsx
--     - 手動現貨 + 有 SKU → 出「✋ 我要認領」（走 rpc_claim_manual_spot）
--     - 手動現貨 + 沒 SKU → 提示先補選商品，編輯表單多一個商品選擇
--     - ➕ 手動新增現貨：商品改必填（不選就沒人能認領）
--     - 📦 我有庫存可提供：可釋出訂單放寬到 ready + partially_completed
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. rpc_claim_manual_spot — 手動現貨的認領（建載體單 → 轉單 → 扣貼文量）
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_claim_manual_spot(
  p_board_id        BIGINT,
  p_to_store_id     BIGINT,
  p_qty             NUMERIC,
  p_operator        UUID,
  p_reason          TEXT    DEFAULT NULL,
  p_is_air_transfer BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    p_is_air_transfer    => COALESCE(p_is_air_transfer, FALSE)
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
$$;

COMMENT ON FUNCTION public.rpc_claim_manual_spot(BIGINT, BIGINT, NUMERIC, UUID, TEXT, BOOLEAN) IS
  '互助板「手動現貨」（無來源訂單）的跨店認領：在釋出店建 AB- 載體單（restock '
  'sentinel trio、單頭 ready）→ 同交易內 rpc_transfer_order_partial 轉給認領店 → '
  'rpc_consume_aid_board 扣量。載體單建完就轉走，不會停留在現貨池被 _trim_internal_pool 砍。';

GRANT EXECUTE ON FUNCTION public.rpc_claim_manual_spot(BIGINT, BIGINT, NUMERIC, UUID, TEXT, BOOLEAN)
  TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. rpc_update_aid_board_listing：10 → 11 參數（加 p_sku_id 補選商品）
--    基底 20260802000050 逐字保留，只加 SKU 補選與 qty_remaining 保留已認領量
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, JSONB, TEXT, NUMERIC, BOOLEAN);

CREATE OR REPLACE FUNCTION public.rpc_update_aid_board_listing(
  p_board_id         BIGINT,
  p_operator         UUID,
  p_spot_price       NUMERIC     DEFAULT NULL,
  p_spot_description TEXT        DEFAULT NULL,
  p_expires_at       TIMESTAMPTZ DEFAULT NULL,
  p_spot_title       TEXT        DEFAULT NULL,
  p_spot_images      JSONB       DEFAULT NULL,
  p_spot_unit        TEXT        DEFAULT NULL,
  p_qty_available    NUMERIC     DEFAULT NULL,
  p_visible_to_other_stores BOOLEAN DEFAULT NULL,
  p_sku_id           BIGINT      DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_post_type TEXT;
  v_status    TEXT;
  v_sku_id    BIGINT;
  v_order_id  BIGINT;
  v_title     TEXT := NULLIF(trim(p_spot_title), '');
  v_images    JSONB;
  v_available NUMERIC;
  v_remaining NUMERIC;
  v_claimed   NUMERIC;
BEGIN
  IF p_spot_price IS NOT NULL AND p_spot_price <= 0 THEN
    RAISE EXCEPTION 'spot_price must be > 0';
  END IF;
  -- 到期時間可以往後延，也可以縮短，但不能設到過去
  -- （設到過去等於立刻下架，那是「結束此貼」該做的事，語意分開）
  IF p_expires_at IS NOT NULL AND p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'expires_at must be in the future';
  END IF;
  IF p_qty_available IS NOT NULL AND p_qty_available <= 0 THEN
    RAISE EXCEPTION 'qty_available must be > 0';
  END IF;
  IF p_spot_images IS NOT NULL THEN
    IF jsonb_typeof(p_spot_images) <> 'array' THEN
      RAISE EXCEPTION 'spot_images must be a JSON array of storage paths';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_spot_images) e
       WHERE jsonb_typeof(e) <> 'string'
    ) THEN
      RAISE EXCEPTION 'spot_images must contain only strings';
    END IF;
    v_images := NULLIF(p_spot_images, '[]'::jsonb);
  END IF;

  SELECT post_type, status, sku_id, source_customer_order_id, qty_available, qty_remaining
    INTO v_post_type, v_status, v_sku_id, v_order_id, v_available, v_remaining
    FROM mutual_aid_board WHERE id = p_board_id
    FOR UPDATE;
  IF v_post_type IS NULL THEN
    RAISE EXCEPTION 'board post % not found', p_board_id;
  END IF;
  IF v_post_type <> 'offer' THEN
    RAISE EXCEPTION 'only offer posts have price/description';
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'post is % — only active posts can be edited', v_status;
  END IF;
  -- 手打商品沒有 SKU 可以 fallback，標題不能清空（先擋，別讓它撞 CHECK）
  IF v_sku_id IS NULL AND p_sku_id IS NULL AND v_title IS NULL THEN
    RAISE EXCEPTION 'this listing has no sku — spot_title cannot be cleared';
  END IF;
  -- SKU 補選只給手動現貨：從訂單釋出的貼文 SKU 綁著來源訂單品項，改了對不到帳
  IF p_sku_id IS NOT NULL AND v_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'sku of an order-sourced listing cannot be changed';
  END IF;
  IF p_sku_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM skus WHERE id = p_sku_id) THEN
    RAISE EXCEPTION 'sku % not found', p_sku_id;
  END IF;
  -- 數量只有手動現貨能改：從訂單釋出的貼文，qty 和認領扣量的帳綁在一起，
  -- 直接覆寫會讓已認領的量對不上（要調整請結束此貼重發）
  IF p_qty_available IS NOT NULL AND v_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'qty of an order-sourced listing cannot be edited';
  END IF;
  -- 手動現貨自 20260816000000 起也會被認領扣量 → 改總量時要保留已認領的部分
  v_claimed := GREATEST(COALESCE(v_available, 0) - COALESCE(v_remaining, 0), 0);
  IF p_qty_available IS NOT NULL AND p_qty_available < v_claimed THEN
    RAISE EXCEPTION '已被認領 % 件，數量不能改到比它還小', v_claimed;
  END IF;

  UPDATE mutual_aid_board
     SET spot_price       = p_spot_price,
         spot_description = NULLIF(trim(p_spot_description), ''),
         spot_title       = v_title,
         spot_unit        = NULLIF(trim(p_spot_unit), ''),
         spot_images      = v_images,
         -- NULL = 不動（清掉 SKU 只會讓貼文退回不可認領，沒有意義）
         sku_id           = COALESCE(p_sku_id, sku_id),
         -- NULL = 不動（expires_at 是 NOT NULL，沒有「清除」的語意）
         expires_at       = COALESCE(p_expires_at, expires_at),
         -- 手動現貨改總量：剩餘量 = 新總量 − 已認領量（原版直接覆寫，
         -- 那是「手動現貨不會被認領」年代的假設）
         qty_available    = COALESCE(p_qty_available, qty_available),
         qty_remaining    = CASE
                              WHEN p_qty_available IS NULL THEN qty_remaining
                              ELSE p_qty_available - v_claimed
                            END,
         -- NULL = 不動（欄位 NOT NULL；舊前端沒送就別動人家的可見性）
         spot_visible_to_other_stores =
           COALESCE(p_visible_to_other_stores, spot_visible_to_other_stores),
         updated_by       = p_operator
   WHERE id = p_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, JSONB, TEXT, NUMERIC, BOOLEAN, BIGINT)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_update_aid_board_listing IS
  '互助板 offer 貼文發佈後編輯釋出單價 / 商品說明 / 商品標題 / 單位 / 圖片 / '
  '到期時間 / 數量 / 跨店可見性 / 補選商品(SKU)。spot_price、spot_description、'
  'spot_title、spot_unit、spot_images 送 NULL = 清除自訂值；expires_at、'
  'qty_available、visible_to_other_stores、sku_id 送 NULL = 不動。'
  'sku_id 與 qty 只有手動現貨（無來源訂單）能改；改總量時剩餘量會保留已認領的部分。';

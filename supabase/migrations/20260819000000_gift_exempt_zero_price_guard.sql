-- ============================================================================
-- 2026-08-19: 贈品排除零元守衛 —— 「刻意送的」與「漏填金額的」分開
--
-- 需求：「單價是零設定阻擋非常好，但有一種是屬贈品的狀況（尤其辦促銷活動）
--        是否要多一個設定排除」。
--
-- 為什麼不做成「一個開關關掉守衛」：
--   20260815000000 的零元守衛擋的是「開團 / 代 key 漏填金額」，線上已經因此白送
--   111 列。做成全域（或每店）開關 = 促銷期間關掉、漏填的也一起放行，等於守衛不
--   存在；而促銷結束沒人記得關回去。所以做成**標記制**：$0 只有被明確標成贈品
--   才放行，誰標的、什麼時候、為什麼，全部留痕。
--
-- 兩層標記（讀取時 OR，不做欄位同步）：
--   A. campaign_items.is_gift  —— 開團層級（促銷活動主用）。
--      團購訂單的單價一律來自 campaign_items（rpc_create_customer_orders 只收
--      {campaign_item_id, qty}，前端根本沒有單價欄），所以促銷贈品的正解是把那個
--      開團商品標成贈品；標下去**當下就對該團所有既有 / 未來訂單生效**，不用回頭
--      一張一張處理。
--   B. customer_order_items.is_gift —— 單一訂單層級（臨時、個案）。
--      櫃台被守衛擋下時當場標（同 rpc_fill_zero_order_item_price 的權限：
--      HQ / 總倉 / 自店），或事後在訂單明細標。
--
--   判定一律是 `coi.is_gift OR ci.is_gift`（讀取時 join，不寫回 coi）。
--   刻意不用 trigger 把 A 同步進 B：
--     - 有 50 支 migration 會 INSERT customer_order_items（轉單 / 拆行 / 配貨…），
--       同步欄位就要逐一補，漏一支就是「贈品變成漏填、櫃台被擋」。
--     - A 要能追溯生效（促銷開跑後才想到要標），寫回欄位就得再寫 backfill。
--
-- 三個「會把贈品價格改掉」的地方一起關掉，否則標了也會被蓋回零售價（而且是
-- 連既有 pending 訂單一起蓋 → 贈品變成跟客人收錢）：
--   - rpc_resync_campaign_from_product（重新同步商品/價格）
--   - _sync_retail_price_to_campaigns（draft 團跟著零售價走的 trigger）
--   - rpc_fill_zero_order_item_price（補金額成功 = 這列不是贈品 → 清掉 B 標記）
--
-- 基底版本（append-only，逐字保留所有 prior fix；每一支都重新 grep 過）：
--   - v_admin_orders_list                 ← 20260815000000（本檔加 gift 排除 + gift_lines）
--   - rpc_record_pickup                   ← 20260815000000（本檔只改零元守衛 + 拆行帶 gift 欄）
--   - rpc_fill_zero_order_item_price      ← 20260815000000（本檔只加「補完清 gift 標記」）
--   - rpc_resync_campaign_from_product    ← 20260620000060（本檔只加 6 處 is_gift 排除）
--   - _sync_retail_price_to_campaigns     ← 20260514000008（本檔只加 1 處 is_gift 排除）
--
-- Rollback：
--   ALTER TABLE customer_order_items DROP COLUMN is_gift, DROP COLUMN gift_reason,
--     DROP COLUMN gift_marked_by, DROP COLUMN gift_marked_at;
--   ALTER TABLE campaign_items DROP COLUMN is_gift, DROP COLUMN gift_reason;
--   customer_order_audit_log_field_check 重跑 20260625000000 的版本（少 'is_gift'；
--     要先清掉 field='is_gift' 的稽核列，否則 ADD CONSTRAINT 會被既有資料擋下）。
--   DROP FUNCTION public.rpc_mark_order_item_gift(BIGINT,BIGINT,BOOLEAN,UUID,TEXT);
--   DROP FUNCTION public.rpc_set_campaign_item_gift(BIGINT,BOOLEAN,TEXT);
--   重跑 20260815000000（view / rpc_record_pickup / rpc_fill_zero_order_item_price）、
--   20260620000060（resync）、20260514000008 第 2 段（_sync_retail_price_to_campaigns）。
--   ⚠ view 少一欄 gift_lines，前端要一起回退。
--
-- 對應前端（同一個 commit）：
--   - apps/admin/src/lib/orderGift.ts（唯一判定 isGiftLine，前端各頁不要各寫一份）
--   - apps/admin/src/app/(protected)/pickup/page.tsx（贈品不擋 + 當場標記）
--   - apps/admin/src/components/PickupDialog.tsx（贈品可勾、顯示 🎁）
--   - apps/admin/src/components/OrderDetail.tsx（品項列 🎁 標記 / 取消標記）
--   - apps/admin/src/app/(protected)/orders/page.tsx（$0 提示排除贈品 + 🎁 欄）
--   - apps/admin/src/components/CampaignItemsTable.tsx（開團商品標贈品）
--   - apps/admin/src/lib/rpcError.ts（gift_mark / campaign_gift 前綴中文化）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 欄位
-- ----------------------------------------------------------------------------

ALTER TABLE campaign_items
  ADD COLUMN IF NOT EXISTS is_gift     BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS gift_reason TEXT;

COMMENT ON COLUMN campaign_items.is_gift IS
  '20260819000000：這個開團商品是贈品（促銷活動）。TRUE → 該團所有 $0 訂單品項免除'
  '取貨零元守衛，且「重新同步商品/價格」與零售價 trigger 都不再改它的單價。'
  '只能經 rpc_set_campaign_item_gift 設定（管理員限定，會一併把單價設為 0）。';

COMMENT ON COLUMN campaign_items.gift_reason IS
  '20260819000000：標成贈品的理由（例：週年慶滿額贈）。顯示在開團商品列與訂單品項的 🎁 提示。';

ALTER TABLE customer_order_items
  ADD COLUMN IF NOT EXISTS is_gift        BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS gift_reason    TEXT,
  ADD COLUMN IF NOT EXISTS gift_marked_by UUID,
  ADD COLUMN IF NOT EXISTS gift_marked_at TIMESTAMPTZ;

COMMENT ON COLUMN customer_order_items.is_gift IS
  '20260819000000：這一列是刻意送的贈品（單一訂單個案）。TRUE → 免除取貨零元守衛。'
  '開團層級的促銷贈品走 campaign_items.is_gift，不寫回這裡（判定是兩者 OR）。'
  '只能經 rpc_mark_order_item_gift 設定，每次寫一筆 customer_order_audit_log。';

COMMENT ON COLUMN customer_order_items.gift_reason IS
  '20260819000000：標成贈品的理由（必填，例：買二送一 / 客訴補償）。';
COMMENT ON COLUMN customer_order_items.gift_marked_by IS
  '20260819000000：標記贈品的操作者（櫃台自己標的也留痕，供 HQ 事後檢視）。';
COMMENT ON COLUMN customer_order_items.gift_marked_at IS
  '20260819000000：標記贈品的時間。';

-- customer_order_audit_log.field 是白名單 CHECK，沒擴充的話 rpc_mark_order_item_gift
-- 寫 audit 會直接違反 constraint（＝標記贈品整支失敗）。
-- 基底清單：20260625000000_pr_create_lock_campaign_and_orders.sql（逐字保留 + 'is_gift'）。
ALTER TABLE customer_order_audit_log DROP CONSTRAINT customer_order_audit_log_field_check;
ALTER TABLE customer_order_audit_log
  ADD CONSTRAINT customer_order_audit_log_field_check
    CHECK (field IN (
      'unit_price','item_notes','item_discount_amount','item_discount_percent',
      'discount_amount','discount_percent','order_notes',
      'qty',      -- Stage 3 (店家改 qty)
      'status',   -- Stage 4 (PR auto-confirm)
      'is_gift'   -- 20260819000000 (標記/取消標記贈品)
    ));

-- ----------------------------------------------------------------------------
-- 2. v_admin_orders_list v4 — $0 提示排除贈品，另回 gift_lines
--    基底 20260815000000 逐字保留，只在 LATERAL 加 campaign_items join、
--    zero_price_lines 加排除條件、多一個 gift_lines 欄。
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_admin_orders_list;

CREATE VIEW v_admin_orders_list
WITH (security_invoker = true) AS
SELECT
  o.*,
  c.name AS campaign_name,
  COALESCE(m.name, o.nickname_snapshot) AS member_name,
  s.name AS store_name,
  agg.line_count,
  agg.total_qty,
  agg.total_amount,
  agg.source_summary,
  -- 20260815000000：$0 品項行數（可能漏填金額）。store_internal 的容器單一律 0
  -- —— 池子單價本來就可能是 0，標紅只會製造雜訊（見 20260815000000 檔頭）。
  -- 20260819000000：刻意標成贈品的列（品項自己標，或整個開團商品是贈品）不算漏填。
  CASE WHEN COALESCE(m.member_type, '') = 'store_internal' THEN 0
       ELSE agg.zero_price_lines END       AS zero_price_lines,
  -- 20260819000000：贈品行數（列表顯示 🎁，讓 HQ 看得到誰在送東西）
  agg.gift_lines                           AS gift_lines
FROM v_admin_orders o
LEFT JOIN group_buy_campaigns c ON c.id = o.campaign_id
LEFT JOIN members m ON m.id = o.member_id
LEFT JOIN stores s ON s.id = o.pickup_store_id
LEFT JOIN LATERAL (
  SELECT
    count(*)::int                          AS line_count,
    COALESCE(sum(i.qty), 0)                AS total_qty,
    COALESCE(sum(i.qty * i.unit_price), 0) AS total_amount,
    CASE WHEN count(DISTINCT i.source) > 1 THEN 'mixed'
         ELSE min(i.source) END            AS source_summary,
    count(*) FILTER (
      WHERE COALESCE(i.unit_price, 0) = 0
        AND NOT COALESCE(i.is_gift, FALSE)
        AND NOT COALESCE(gi.is_gift, FALSE)
    )::int                                 AS zero_price_lines,
    count(*) FILTER (
      WHERE COALESCE(i.is_gift, FALSE) OR COALESCE(gi.is_gift, FALSE)
    )::int                                 AS gift_lines
  FROM customer_order_items i
  -- 20260819000000：開團層級的贈品標記（促銷活動一次標、全團訂單生效）
  LEFT JOIN campaign_items gi ON gi.id = i.campaign_item_id
  WHERE i.order_id = o.id
    -- 20260808000010：已取消 / 斷貨的品項不算進項數 / 件數 / 金額
    AND i.status NOT IN ('cancelled','expired')
) agg ON true;

COMMENT ON VIEW v_admin_orders_list IS
  '/orders 列表查詢用：v_admin_orders + 可排序欄位（campaign_name / member_name / '
  'store_name / line_count / total_qty / total_amount / source_summary）。'
  '只給列表 + 選取全部用；tab 數量與趨勢的 rpc_order_overview 維持查 v_admin_orders，'
  '避免整表聚合時多揹 per-row 品項彙總。'
  '20260808000010：彙總排除 cancelled/expired 品項，與訂單明細的應收同一套語意。'
  '20260815000000：zero_price_lines = 單價 $0 的品項行數（漏填金額提示 / 「只看 $0」'
  '伺服端篩選）；store_internal 容器單恆為 0。'
  '20260819000000：zero_price_lines 排除贈品（customer_order_items.is_gift 或'
  ' campaign_items.is_gift）；另加 gift_lines = 贈品行數。';

GRANT SELECT ON v_admin_orders_list TO authenticated;

-- ----------------------------------------------------------------------------
-- 3. rpc_record_pickup — 零元守衛放行「已標記的贈品」
--    基底 20260815000000 逐字保留，只動兩處：守衛條件、拆行時帶贈品標記。
-- ----------------------------------------------------------------------------

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
  '不受零元守衛限制；拆行時贈品標記會複製到 picked_up 那一行。';

GRANT EXECUTE ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. rpc_fill_zero_order_item_price — 補金額成功就清掉品項層級的贈品標記
--    基底 20260815000000 逐字保留，只多改那一段 UPDATE。
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_fill_zero_order_item_price(
  p_order_id       BIGINT,
  p_item_id        BIGINT,
  p_new_unit_price NUMERIC,
  p_operator       UUID,
  p_reason         TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order  customer_orders%ROWTYPE;
  v_old    NUMERIC;
  v_status TEXT;
  v_row    customer_order_items;
BEGIN
  -- HQ / 總倉 / 該訂單取貨店（app_metadata.stores 店名比對）
  v_order := public._check_order_edit_notes_perm(p_order_id);

  IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
    RAISE EXCEPTION 'zero_price_fill: 補填金額必須大於 0';
  END IF;

  SELECT unit_price, status INTO v_old, v_status
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'zero_price_fill: 品項 % 不屬於訂單 %', p_item_id, p_order_id;
  END IF;

  -- 只補填、不改價：非 0 的單價要改一律走 rpc_update_order_item_price（HQ 權限）
  IF COALESCE(v_old, 0) <> 0 THEN
    RAISE EXCEPTION 'zero_price_fill: 此品項單價已是 $%，補填功能只處理 $0 的品項；要改價請洽總部',
      v_old;
  END IF;

  -- 已取貨 / 已取消的行不補（那是事後改帳，金額已進收據 / 已結案）
  IF v_status NOT IN ('pending','reserved','ready') THEN
    RAISE EXCEPTION 'zero_price_fill: 品項狀態為「%」，只有未取貨的品項可以補填金額', v_status;
  END IF;

  -- 20260819000000：補得出金額 = 這一列不是贈品，順手清掉品項層級的贈品標記
  -- （不清的話畫面會同時出現「$120」和「🎁 贈品」，而且未來改回 0 就會靜默放行）。
  -- 開團層級的 campaign_items.is_gift 不在這裡動 —— 那是整個團的設定，
  -- 要改請走 rpc_set_campaign_item_gift（管理員）。
  UPDATE customer_order_items
     SET unit_price     = p_new_unit_price,
         is_gift        = FALSE,
         gift_reason    = NULL,
         gift_marked_by = NULL,
         gift_marked_at = NULL,
         updated_by     = p_operator,
         updated_at     = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'unit_price',
     to_jsonb(v_old), to_jsonb(p_new_unit_price),
     COALESCE(NULLIF(p_reason, ''), '補填漏填金額（取貨零元守衛）'), p_operator);

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.rpc_fill_zero_order_item_price(BIGINT, BIGINT, NUMERIC, UUID, TEXT) IS
  '補填漏填的品項金額：只允許 unit_price 0 → 正數、只允許未取貨品項。'
  '權限沿用 _check_order_edit_notes_perm（HQ / 總倉 / 自店），讓櫃台被零元守衛擋下時'
  '自己就能解，不必回頭找總部（分店帳號沒有 app_metadata.store_id，走不了'
  'rpc_update_order_item_price 的 _check_order_edit_perm）。每次寫一筆 audit log。'
  '20260819000000：補完一併清掉品項層級的贈品標記（is_gift / gift_reason /'
  ' gift_marked_by / gift_marked_at）—— 有金額就不是贈品。';

GRANT EXECUTE ON FUNCTION public.rpc_fill_zero_order_item_price(BIGINT, BIGINT, NUMERIC, UUID, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. rpc_mark_order_item_gift — 單一訂單品項標／取消標「贈品」
--    權限沿用 _check_order_edit_notes_perm（HQ / 總倉 / 自店），理由同
--    rpc_fill_zero_order_item_price：客人站在櫃台前，只能自己解得開，
--    否則店員只剩「打電話找總部」或「轉單開新單」（＝重複單）兩條路。
--    代價用留痕補：理由必填 + gift_marked_by/at + 一筆 audit log，
--    列表也看得到 🎁 行數，HQ 事後查得到誰在送東西。
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_mark_order_item_gift(
  p_order_id BIGINT,
  p_item_id  BIGINT,
  p_is_gift  BOOLEAN,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order    customer_orders%ROWTYPE;
  v_price    NUMERIC;
  v_status   TEXT;
  v_old      BOOLEAN;
  v_ci_gift  BOOLEAN;
  v_reason   TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_row      customer_order_items;
BEGIN
  -- HQ / 總倉 / 該訂單取貨店（app_metadata.stores 店名比對）
  v_order := public._check_order_edit_notes_perm(p_order_id);

  SELECT coi.unit_price, coi.status, COALESCE(coi.is_gift, FALSE),
         COALESCE(ci.is_gift, FALSE)
    INTO v_price, v_status, v_old, v_ci_gift
    FROM customer_order_items coi
    LEFT JOIN campaign_items ci ON ci.id = coi.campaign_item_id
   WHERE coi.id = p_item_id AND coi.order_id = p_order_id
   FOR UPDATE OF coi;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'gift_mark: 品項 % 不屬於訂單 %', p_item_id, p_order_id;
  END IF;

  -- 已取貨 / 已取消的行不動（那是事後改帳：貨已交付、金額已進收據）
  IF v_status NOT IN ('pending','reserved','ready') THEN
    RAISE EXCEPTION 'gift_mark: 品項狀態為「%」，只有未取貨的品項可以標記贈品', v_status;
  END IF;

  IF p_is_gift THEN
    -- 贈品＝不收錢。有金額的品項要送，先把金額改成 0（總部改價），
    -- 否則會出現「$120 的贈品」這種既收錢又標贈品的帳。
    IF COALESCE(v_price, 0) <> 0 THEN
      RAISE EXCEPTION 'gift_mark: 此品項單價是 $%，有金額的品項不是贈品；要免費送請先請總部把單價改成 0',
        v_price;
    END IF;
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'gift_mark: 請填寫贈品原因（例：促銷活動買二送一 / 客訴補償），這筆會留在異動紀錄裡';
    END IF;
  ELSIF v_ci_gift THEN
    -- 開團層級標成贈品時，個別品項取消標記沒有意義（讀取時是 OR，仍然免除守衛），
    -- 直接講清楚要去哪裡改，不要讓人以為按了沒反應。
    RAISE EXCEPTION 'gift_mark: 這是「開團商品」層級的贈品設定（整個團都適用），無法在單張訂單取消；請到該開團的商品明細取消贈品設定';
  END IF;

  UPDATE customer_order_items
     SET is_gift        = p_is_gift,
         gift_reason    = CASE WHEN p_is_gift THEN v_reason ELSE NULL END,
         gift_marked_by = CASE WHEN p_is_gift THEN p_operator ELSE NULL END,
         gift_marked_at = CASE WHEN p_is_gift THEN NOW() ELSE NULL END,
         updated_by     = p_operator,
         updated_at     = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'is_gift',
     to_jsonb(v_old), to_jsonb(p_is_gift),
     COALESCE(v_reason, CASE WHEN p_is_gift THEN '標記為贈品' ELSE '取消贈品標記' END),
     p_operator);

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.rpc_mark_order_item_gift(BIGINT, BIGINT, BOOLEAN, UUID, TEXT) IS
  '標記／取消標記單一訂單品項為贈品（免除取貨零元守衛）。'
  '只允許未取貨品項；標記時單價必須是 0 且理由必填。'
  '權限沿用 _check_order_edit_notes_perm（HQ / 總倉 / 自店），每次寫一筆 audit log'
  '（field=is_gift）。開團層級的贈品（campaign_items.is_gift）要走'
  ' rpc_set_campaign_item_gift，在這裡取消不了。';

GRANT EXECUTE ON FUNCTION public.rpc_mark_order_item_gift(BIGINT, BIGINT, BOOLEAN, UUID, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. rpc_set_campaign_item_gift — 開團商品標／取消標「贈品」（促銷活動主用）
--    管理員限定（對齊 rpc_resync_campaign_from_product 的 owner/admin/'' 允許清單，
--    '' 是沒有顯式 role 的 legacy/dev admin，漏掉它會把舊帳號全擋在外面）。
--    標下去＝該團所有既有 / 未來的 $0 訂單品項一起免除守衛，不用回頭一張一張標。
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_set_campaign_item_gift(
  p_campaign_item_id BIGINT,
  p_is_gift          BOOLEAN,
  p_reason           TEXT DEFAULT NULL
) RETURNS campaign_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  -- 應用角色一律讀 app_metadata；頂層 role 永遠是 'authenticated'（見 CLAUDE.md）
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_row    campaign_items;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION 'campaign_gift: 權限不足，只有管理員可以把開團商品設為贈品（role=%）', v_role;
  END IF;

  IF p_is_gift AND v_reason IS NULL THEN
    RAISE EXCEPTION 'campaign_gift: 請填寫贈品原因（例：週年慶滿額贈），會顯示在開團商品與訂單品項上';
  END IF;

  -- 標成贈品＝單價設 0（贈品不收錢），並從此不再被「重新同步商品/價格」與
  -- 零售價 trigger 蓋回零售價。取消標記時單價維持 0，要恢復售價請按
  -- 「重新同步商品/價格」（既有訂單的金額是 snapshot，兩個方向都不會被改動）。
  UPDATE campaign_items
     SET is_gift     = p_is_gift,
         gift_reason = CASE WHEN p_is_gift THEN v_reason ELSE NULL END,
         unit_price  = CASE WHEN p_is_gift THEN 0 ELSE unit_price END,
         updated_by  = auth.uid(),
         updated_at  = NOW()
   WHERE id = p_campaign_item_id AND tenant_id = v_tenant
   RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'campaign_gift: 開團商品 % 不在 tenant 內', p_campaign_item_id;
  END IF;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.rpc_set_campaign_item_gift(BIGINT, BOOLEAN, TEXT) IS
  '把開團商品標成贈品（促銷活動）：is_gift=TRUE + 單價設 0 + 理由必填。'
  '效果＝該開團商品的所有 $0 訂單品項（既有與未來）免除取貨零元守衛，'
  '且 rpc_resync_campaign_from_product 與 _sync_retail_price_to_campaigns 都不再改它的單價。'
  '管理員限定（app_metadata.role ∈ owner / admin / 空字串）。取消標記不會自動恢復售價。';

GRANT EXECUTE ON FUNCTION public.rpc_set_campaign_item_gift(BIGINT, BOOLEAN, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------------------
-- 7. rpc_resync_campaign_from_product — 重新同步時跳過贈品
--    基底 20260620000060 逐字保留。不做這段的話：促銷期間按一次「重新同步
--    商品/價格」，贈品就被蓋回零售價，而且會連既有 pending 訂單一起回填
--    ——「送的」瞬間變成「跟客人收錢」，而且沒有人會發現。
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_resync_campaign_from_product(
  p_campaign_id BIGINT,
  p_dry_run     BOOLEAN DEFAULT TRUE,
  p_operator    UUID    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role      TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_op        UUID := COALESCE(p_operator, auth.uid());
  v_camp      group_buy_campaigns%ROWTYPE;
  v_prod_name TEXT;
  v_bad_cnt   INT;
  v_bad_list  TEXT;
  v_name_changed       BOOLEAN := FALSE;
  v_items_repriced     INT := 0;
  v_items_removed_cnt  INT := 0;
  v_items_removed_json JSONB;
  v_skus_added         INT := 0;
  v_orders             INT := 0;
  v_lines              INT := 0;
  v_amt_before         NUMERIC := 0;
  v_amt_after          NUMERIC := 0;
  v_items_json         JSONB;
  v_result             JSONB;
BEGIN
  -- ---------- 權限：僅管理員 ----------
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION '權限不足：僅管理員可重新同步開團（role=%）', v_role;
  END IF;

  -- ---------- 開團 + 狀態守門 ----------
  SELECT * INTO v_camp
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF v_camp.id IS NULL THEN
    RAISE EXCEPTION 'campaign % 不在 tenant 內', p_campaign_id;
  END IF;
  IF v_camp.status NOT IN ('draft','open') THEN
    RAISE EXCEPTION '只有草稿/開團中的開團可以重新同步（目前狀態：%）', v_camp.status;
  END IF;

  -- ---------- 守門：已在 campaign_items 的 active SKU 必須都有有效零售價 ----------
  SELECT COUNT(*),
         string_agg(s.sku_code, ', ' ORDER BY s.sku_code)
    INTO v_bad_cnt, v_bad_list
    FROM campaign_items ci
    JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
   WHERE ci.campaign_id = p_campaign_id
     AND ci.tenant_id   = v_tenant
     AND s.status = 'active'
     -- 20260819000000：贈品本來就是 $0、也不跟零售價走，缺價不該擋住整支 resync
     AND NOT COALESCE(ci.is_gift, FALSE)
     AND COALESCE((
           SELECT pr.price FROM prices pr
            WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
              AND pr.scope = 'retail' AND pr.effective_to IS NULL
            ORDER BY pr.effective_from DESC LIMIT 1
         ), 0) <= 0;
  IF v_bad_cnt > 0 THEN
    RAISE EXCEPTION '仍有 % 個 active SKU 沒有有效零售價，請先到商品頁設定售價（避免回填成 0）：%',
      v_bad_cnt, v_bad_list;
  END IF;

  -- ---------- 名稱 ----------
  IF v_camp.product_id IS NOT NULL THEN
    SELECT name INTO v_prod_name
      FROM products WHERE id = v_camp.product_id AND tenant_id = v_tenant;
  END IF;
  v_name_changed := (v_prod_name IS NOT NULL AND v_prod_name IS DISTINCT FROM v_camp.name);

  -- ---------- 預覽：reprice 列表 ----------
  SELECT COUNT(*),
         jsonb_agg(jsonb_build_object(
           'sku_id', t.sku_id, 'sku_code', t.sku_code,
           'old_price', t.old_price, 'new_price', t.new_price
         ) ORDER BY t.sku_code)
    INTO v_items_repriced, v_items_json
    FROM (
      SELECT ci.sku_id, s.sku_code, ci.unit_price AS old_price,
             (SELECT pr.price FROM prices pr
               WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
                 AND pr.scope = 'retail' AND pr.effective_to IS NULL
               ORDER BY pr.effective_from DESC LIMIT 1) AS new_price
        FROM campaign_items ci
        JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
       WHERE ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
         AND s.status = 'active'
         -- 20260819000000：贈品的 $0 是刻意的，不列入重新定價
         AND NOT COALESCE(ci.is_gift, FALSE)
    ) t
   WHERE t.old_price IS DISTINCT FROM t.new_price;

  -- ---------- 預覽：將被移除的 discontinued SKU items（無訂單引用）----------
  SELECT COUNT(*),
         jsonb_agg(jsonb_build_object(
           'ci_id', t.ci_id, 'sku_id', t.sku_id, 'sku_code', t.sku_code,
           'unit_price', t.unit_price
         ) ORDER BY t.sku_code)
    INTO v_items_removed_cnt, v_items_removed_json
    FROM (
      SELECT ci.id AS ci_id, ci.sku_id, s.sku_code, ci.unit_price
        FROM campaign_items ci
        JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
       WHERE ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
         AND s.status = 'discontinued'
         AND NOT EXISTS (
           SELECT 1 FROM customer_order_items coi WHERE coi.campaign_item_id = ci.id
         )
    ) t;

  -- ---------- 預覽：補進的新 active SKU ----------
  SELECT COUNT(*) INTO v_skus_added
    FROM skus s
   WHERE v_camp.product_id IS NOT NULL
     AND s.tenant_id  = v_tenant
     AND s.product_id = v_camp.product_id
     AND s.status     = 'active'
     AND NOT EXISTS (SELECT 1 FROM campaign_items ci
                      WHERE ci.campaign_id = p_campaign_id
                        AND ci.tenant_id = v_tenant AND ci.sku_id = s.id)
     AND COALESCE((
           SELECT pr.price FROM prices pr
            WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
              AND pr.scope = 'retail' AND pr.effective_to IS NULL
            ORDER BY pr.effective_from DESC LIMIT 1
         ), 0) > 0;

  -- 受影響的「待確認」訂單
  SELECT COUNT(DISTINCT co.id) FILTER (
           WHERE coi.unit_price IS DISTINCT FROM rc.new_price),
         COUNT(*) FILTER (
           WHERE coi.unit_price IS DISTINCT FROM rc.new_price)
    INTO v_orders, v_lines
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN LATERAL (
      SELECT (SELECT pr.price FROM prices pr
                WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                  AND pr.scope = 'retail' AND pr.effective_to IS NULL
                ORDER BY pr.effective_from DESC LIMIT 1) AS new_price
    ) rc ON TRUE
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending'
     -- 20260819000000：贈品列不回填價格
     AND NOT EXISTS (SELECT 1 FROM campaign_items gi
                      WHERE gi.id = coi.campaign_item_id AND gi.is_gift)
     AND NOT COALESCE(coi.is_gift, FALSE);

  SELECT
    COALESCE(SUM(coi.qty * coi.unit_price), 0),
    COALESCE(SUM(coi.qty * CASE
       -- 20260819000000：贈品列不重新定價，預覽金額也要維持現價
       WHEN COALESCE(coi.is_gift, FALSE) OR COALESCE(gi.is_gift, FALSE) THEN coi.unit_price
       ELSE COALESCE(
         CASE WHEN s.status = 'active' THEN
           (SELECT pr.price FROM prices pr
             WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
               AND pr.scope = 'retail' AND pr.effective_to IS NULL
             ORDER BY pr.effective_from DESC LIMIT 1)
         END, coi.unit_price)
     END), 0)
    INTO v_amt_before, v_amt_after
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id
    LEFT JOIN campaign_items gi ON gi.id = coi.campaign_item_id
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending';

  v_result := jsonb_build_object(
    'dry_run',             p_dry_run,
    'campaign_id',         p_campaign_id,
    'campaign_no',         v_camp.campaign_no,
    'campaign_status',     v_camp.status,
    'name_before',         v_camp.name,
    'name_after',          COALESCE(v_prod_name, v_camp.name),
    'name_changed',        v_name_changed,
    'items',               COALESCE(v_items_json, '[]'::jsonb),
    'items_repriced',      v_items_repriced,
    'items_removed',       COALESCE(v_items_removed_json, '[]'::jsonb),
    'items_removed_count', v_items_removed_cnt,
    'skus_added',          v_skus_added,
    'pending_orders',      v_orders,
    'pending_order_lines', v_lines,
    'amount_before',       v_amt_before,
    'amount_after',        v_amt_after
  );

  IF p_dry_run THEN
    RETURN v_result;
  END IF;

  -- ================= 實跑（單一交易，出錯全 rollback）=================

  IF v_name_changed THEN
    UPDATE group_buy_campaigns
       SET name = v_prod_name, updated_at = NOW()
     WHERE id = p_campaign_id AND tenant_id = v_tenant;
  END IF;

  -- 移除 discontinued SKU 的 campaign_items（無訂單引用的才動）
  DELETE FROM campaign_items ci
   USING skus s
   WHERE ci.sku_id = s.id AND s.tenant_id = ci.tenant_id
     AND ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
     AND s.status = 'discontinued'
     AND NOT EXISTS (
       SELECT 1 FROM customer_order_items coi WHERE coi.campaign_item_id = ci.id
     );

  UPDATE campaign_items ci
     SET unit_price = (SELECT pr.price FROM prices pr
                         WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
                           AND pr.scope = 'retail' AND pr.effective_to IS NULL
                         ORDER BY pr.effective_from DESC LIMIT 1),
         updated_at = NOW(),
         updated_by = v_op
    FROM skus s
   WHERE ci.sku_id = s.id AND s.tenant_id = ci.tenant_id
     AND ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
     AND s.status = 'active'
     -- 20260819000000：贈品維持 $0，不被同步蓋回零售價
     AND NOT COALESCE(ci.is_gift, FALSE)
     AND ci.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  INSERT INTO campaign_items
    (tenant_id, campaign_id, sku_id, unit_price, sort_order, created_by, updated_by)
  SELECT v_tenant, p_campaign_id, s.id,
         (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1),
         999, v_op, v_op
    FROM skus s
   WHERE v_camp.product_id IS NOT NULL
     AND s.tenant_id  = v_tenant
     AND s.product_id = v_camp.product_id
     AND s.status     = 'active'
     AND NOT EXISTS (SELECT 1 FROM campaign_items ci
                      WHERE ci.campaign_id = p_campaign_id
                        AND ci.tenant_id = v_tenant AND ci.sku_id = s.id)
     AND COALESCE((SELECT pr.price FROM prices pr
                    WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
                      AND pr.scope = 'retail' AND pr.effective_to IS NULL
                    ORDER BY pr.effective_from DESC LIMIT 1), 0) > 0
  ON CONFLICT (campaign_id, sku_id) DO NOTHING;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  SELECT co.tenant_id, co.id, 'item', coi.id, 'unit_price',
         to_jsonb(coi.unit_price),
         to_jsonb((SELECT pr.price FROM prices pr
                     WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                       AND pr.scope = 'retail' AND pr.effective_to IS NULL
                     ORDER BY pr.effective_from DESC LIMIT 1)),
         '開團「重新同步商品/價格」批次回填（待確認訂單）',
         COALESCE(v_op, co.updated_by, co.created_by, v_camp.created_by)
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending'
     -- 20260819000000：贈品列不回填價格
     AND NOT EXISTS (SELECT 1 FROM campaign_items gi
                      WHERE gi.id = coi.campaign_item_id AND gi.is_gift)
     AND NOT COALESCE(coi.is_gift, FALSE)
     AND coi.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  UPDATE customer_order_items coi
     SET unit_price = (SELECT pr.price FROM prices pr
                         WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                           AND pr.scope = 'retail' AND pr.effective_to IS NULL
                         ORDER BY pr.effective_from DESC LIMIT 1),
         updated_at = NOW(),
         updated_by = v_op
    FROM customer_orders co, skus s
   WHERE coi.order_id = co.id
     AND s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
     AND co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending'
     -- 20260819000000：贈品列不回填價格
     AND NOT EXISTS (SELECT 1 FROM campaign_items gi
                      WHERE gi.id = coi.campaign_item_id AND gi.is_gift)
     AND NOT COALESCE(coi.is_gift, FALSE)
     AND coi.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  RETURN v_result || jsonb_build_object('applied', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_resync_campaign_from_product(BIGINT, BOOLEAN, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_resync_campaign_from_product(BIGINT, BOOLEAN, UUID) IS
  '開團重新同步：名稱←product、campaign_items 單價←現行零售價、補 active SKU、'
  '移除 discontinued SKU（無訂單引用者）、回填 status=pending 訂單明細並寫 customer_order_audit_log。'
  'draft/open 限定、僅管理員(owner/admin) 限定、active SKU 缺有效零售價則拒跑、p_dry_run 預設只預覽。'
  '20260819000000：贈品（campaign_items.is_gift / customer_order_items.is_gift）全程跳過'
  '——不重新定價、不回填訂單、缺零售價也不擋跑。';

-- ----------------------------------------------------------------------------
-- 8. _sync_retail_price_to_campaigns — 零售價 trigger 不要蓋掉贈品
--    基底 20260514000008 逐字保留，只多一個 is_gift 條件。
--    （draft 團的單價跟零售價走；贈品是刻意的 $0，跟著走就變成收錢。）
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._sync_retail_price_to_campaigns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.scope IS DISTINCT FROM 'retail' THEN
    RETURN NEW;
  END IF;
  IF NEW.effective_to IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- 只動 draft 階段（open 後鎖定）
  UPDATE campaign_items ci
     SET unit_price = NEW.price,
         updated_at = NOW()
    FROM group_buy_campaigns gbc
   WHERE ci.tenant_id  = NEW.tenant_id
     AND ci.sku_id     = NEW.sku_id
     AND ci.campaign_id = gbc.id
     AND gbc.tenant_id = NEW.tenant_id
     AND gbc.status    = 'draft'
     -- 20260819000000：贈品的 $0 是刻意的，不跟零售價走
     AND NOT COALESCE(ci.is_gift, FALSE);

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._sync_retail_price_to_campaigns() IS
  'prices(scope=retail, 現行) 異動時同步 draft 開團的 campaign_items.unit_price。'
  'open 之後鎖定（20260514000008）。20260819000000：贈品（is_gift）不同步。';

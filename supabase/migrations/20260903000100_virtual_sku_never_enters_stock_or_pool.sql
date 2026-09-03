-- ============================================================
-- 2026-09-03: 虛擬轉貨商品（MISC-01）不進庫存、也不進現貨池
-- ============================================================
-- 症狀：全站 15 個店倉的庫存裡掛著 821 件「虛擬轉貨商品」（平鎮 219、三峽 211、
--   龍潭 153、松山 45…），而且 9 家店的【內部】現貨池單上還掛著 36 件（松山 13 件）。
--   這東西是自由轉貨用的虛擬 SKU（products.is_virtual）—— 沒有實體、永遠取不走、
--   永遠轉不掉，只會坐在池子裡；而且它把整張池子單的取貨閘門釘成 false
--   （is_order_pickup_ready 是全品項 AND），就是 20260903000000 那件事的助燃劑。
--
-- 根因：20260515000006 立過規矩「虛擬 SKU 跳過 outbound / inbound」，但只有
--   rpc_transfer_distribute_batch 那半留到今天；rpc_receive_transfer 的收貨端
--   在後續多次 CREATE OR REPLACE 裡把 is_virtual 判斷弄丟了（線上 prosrc 現在
--   一個 is_virtual 都沒有）。於是自由轉貨變成**只進不出**：
--     transfer_in 811 件 / transfer_reject 28 / transfer_cancel 4 / reversal −22 = 821，
--   出庫側一筆都沒有（distribute 照規矩跳過了）。單價全 0，所以只是虛胖、不影響月結金額。
--   收貨多給那段（_grow_internal_pool）也照樣把它掛進池子。
--
-- 改法（守衛放在最低層，不去動兩支上萬字元的收貨 RPC）：
--   A. rpc_inbound —— 虛擬 SKU 不寫 movement、回 NULL。這是全站唯一入庫入口
--      （10 支 RPC 都走它），一處補完。全庫沒有任何 %movement_id% 欄位是 NOT NULL，
--      回 NULL 不會炸；transfer_items.in_movement_id 留 NULL 正是 20260515000006 的原設計。
--   B. _grow_internal_pool —— 虛擬 SKU 直接回 0，不進現貨池。兩支收貨 RPC
--      （rpc_receive_transfer / rpc_receive_transfer_manual）都呼叫它，一處補完。
--   C. 清既有殘留：池子單上的虛擬 SKU 列標 cancelled（前端會畫刪除線，店家看得到），
--      並沖掉 15 個店倉的 821 件假庫存（manual_adjust，單價 0）。
--
-- 沒有動的部分：自由轉貨本身的流程（建單 / 派送 / 收貨 / 估價）一字未改 ——
--   虛擬 SKU 的量與描述本來就記在 transfer_items.description / estimated_amount 上，
--   不靠 stock_balances。
--
-- 基底版本：rpc_inbound → 20260422120003_inventory_schema.sql（線上核對一致）
--           _grow_internal_pool → 20260816000000_sku_commitment_canonical.sql
--             （改用 _sku_free_qty 的那版；2026-09-03 對線上 pg_get_functiondef 核對過）
-- Rollback：兩支各自重跑基底版本的 CREATE OR REPLACE；假庫存要還原就再開一筆
--   反向 manual_adjust（movements 是 append-only，不刪）。
-- ============================================================

-- ----------------------------------------------------------------
-- A. rpc_inbound：虛擬 SKU 不入庫
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_inbound(p_tenant_id uuid, p_location_id bigint, p_sku_id bigint, p_quantity numeric, p_unit_cost numeric, p_movement_type text, p_source_doc_type text, p_source_doc_id bigint, p_operator uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_id BIGINT;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Inbound quantity must be positive';
  END IF;

  -- 虛擬商品（自由轉貨的 MISC-01 之類）沒有實體、不進庫存：不寫 movement、回 NULL。
  -- 出庫側 rpc_transfer_distribute_batch 從 20260515000006 起就是這樣跳過的，
  -- 入庫側後來在多次 CREATE OR REPLACE 中弄丟 → 只進不出、庫存虛胖 821 件。
  -- 守衛放在這裡而不是各收貨 RPC：這是全站唯一入庫入口，補一次全部路徑生效。
  IF EXISTS (
    SELECT 1 FROM skus s JOIN products p ON p.id = s.product_id
     WHERE s.id = p_sku_id AND p.is_virtual
  ) THEN
    RETURN NULL;
  END IF;

  INSERT INTO stock_movements
    (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
     source_doc_type, source_doc_id, operator_id)
  VALUES
    (p_tenant_id, p_location_id, p_sku_id, p_quantity, p_unit_cost, p_movement_type,
     p_source_doc_type, p_source_doc_id, p_operator)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.rpc_inbound(UUID, BIGINT, BIGINT, NUMERIC, NUMERIC, TEXT, TEXT, BIGINT, UUID) IS
  '入庫：寫一筆正數 stock_movements（餘額由 trg_apply_movement 維護）。'
  '虛擬商品（products.is_virtual）不進庫存、回 NULL（20260903000100，'
  '恢復 20260515000006 的規則）。';


-- ----------------------------------------------------------------
-- B. _grow_internal_pool：虛擬 SKU 不進現貨池
--    逐字取自線上定義，只插入開頭那一段守衛。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._grow_internal_pool(p_store_id bigint, p_sku_id bigint, p_max_grow numeric, p_operator uuid, p_at timestamp with time zone DEFAULT now(), p_tag text DEFAULT NULL::text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tenant     UUID;
  v_loc        BIGINT;
  v_grow       NUMERIC;
  v_order_id   BIGINT;
  v_campaign   BIGINT;
  v_ci         BIGINT;
  v_price      NUMERIC;
BEGIN
  IF p_max_grow IS NULL OR p_max_grow <= 0 THEN
    RETURN 0;
  END IF;

  -- 虛擬商品不掛進現貨池：它沒有實體，取不走也轉不掉，只會一直坐在池子裡，
  -- 而且會把整張池子單的取貨閘門（is_order_pickup_ready 全品項 AND）釘成 false。
  IF EXISTS (
    SELECT 1 FROM skus s JOIN products p ON p.id = s.product_id
     WHERE s.id = p_sku_id AND p.is_virtual
  ) THEN
    RETURN 0;
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;
  END IF;

  -- 自由量 = on_hand − 已承諾未取 − confirmed 未配需求 − 池子未取（含在途）。
  -- 比 trim 的目標水位多扣「confirmed 未配需求」：還沒配到貨的客人單
  -- 下一批就要吃這批貨，先掛進池子會被轉走 ——「8 位團友撲空」的鏡像版。
  -- LEAST(p_max_grow, ...)：只掛本批造成的自由量，不順手做全域收斂。
  v_grow := LEAST(p_max_grow, public._sku_free_qty(p_store_id, p_sku_id));

  IF v_grow <= 0 THEN
    RETURN 0;
  END IF;

  v_order_id := public._get_or_create_surplus_pool_order(p_store_id, p_operator, p_at);
  SELECT campaign_id INTO v_campaign FROM customer_orders WHERE id = v_order_id;

  -- 品項單價：分店價（branch）優先、退 retail、再退 0 —— 池子單價本來就只是
  -- 掛帳顯示，轉單給真會員時 rpc_transfer_order_partial 會改鎖當下現售價。
  SELECT price INTO v_price
    FROM prices
   WHERE tenant_id = v_tenant AND sku_id = p_sku_id AND scope = 'branch'
     AND effective_from <= p_at AND (effective_to IS NULL OR effective_to > p_at)
   ORDER BY effective_from DESC
   LIMIT 1;
  IF v_price IS NULL THEN
    SELECT price INTO v_price
      FROM prices
     WHERE tenant_id = v_tenant AND sku_id = p_sku_id AND scope = 'retail'
       AND effective_from <= p_at AND (effective_to IS NULL OR effective_to > p_at)
     ORDER BY effective_from DESC
     LIMIT 1;
  END IF;
  v_price := COALESCE(v_price, 0);

  v_ci := public._restock_sentinel_campaign_item(v_tenant, v_campaign, p_sku_id, v_price);

  -- 一批一列（notes 帶來源 tag），退回收貨才對得到帳；不跟既有列合併。
  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant, v_order_id, v_ci, p_sku_id, v_grow, v_price,
    'pending', 'store_internal', p_tag, p_operator, p_operator, p_at, p_at
  );

  UPDATE customer_orders
     SET updated_by = p_operator, updated_at = p_at
   WHERE id = v_order_id;

  RETURN v_grow;
END;
$function$;

COMMENT ON FUNCTION public._grow_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT) IS
  '把收貨多給的量掛進【內部】xx 店現貨池（_trim_internal_pool 的鏡像），回傳實際掛進去的量。'
  '上限 = LEAST(本批多給, _sku_free_qty)。虛擬商品一律回 0，不進池子（20260903000100）。';


-- ----------------------------------------------------------------
-- C. 清既有殘留
--    C1. 池子單上的虛擬 SKU 列 → cancelled（+ notes 標記），並重算單頭
--    C2. 15 個店倉的假庫存 → manual_adjust 沖掉（單價 0，不影響月結金額）
--    兩段都有守衛，重跑不會加倍。
-- ----------------------------------------------------------------
DO $fix$
DECLARE
  v_order_ids BIGINT[];
  v_rows      INT := 0;
  v_locs      INT := 0;
  v_qty       NUMERIC := 0;
BEGIN
  -- C1
  WITH tgt AS (
    SELECT coi.id, coi.order_id
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
      JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
      JOIN skus s ON s.id = coi.sku_id
      JOIN products p ON p.id = s.product_id AND p.is_virtual
     WHERE coi.status IN ('pending','reserved','ready')
  ), upd AS (
    UPDATE customer_order_items coi
       SET status     = 'cancelled',
           notes      = COALESCE(NULLIF(coi.notes, ''), '') || ' [虛擬轉貨商品不進現貨池，20260903000100 清除]',
           updated_at = NOW()
      FROM tgt
     WHERE coi.id = tgt.id
     RETURNING tgt.order_id
  )
  SELECT ARRAY_AGG(DISTINCT order_id), COUNT(*) INTO v_order_ids, v_rows FROM upd;

  IF v_order_ids IS NOT NULL THEN
    -- 取消品項後一律重算單頭（CLAUDE.md：沒有待取品項 + 有取過貨 → completed）
    PERFORM public._close_orders_all_items_settled(v_order_ids, NULL, NOW());
  END IF;
  RAISE NOTICE '池子虛擬品項清除：% 列 / % 張單', v_rows, COALESCE(array_length(v_order_ids, 1), 0);

  -- C2
  WITH tgt AS (
    SELECT sb.tenant_id, sb.location_id, sb.sku_id, sb.on_hand
      FROM stock_balances sb
      JOIN skus s ON s.id = sb.sku_id
      JOIN products p ON p.id = s.product_id AND p.is_virtual
     WHERE sb.on_hand > 0
  ), ins AS (
    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
      source_doc_type, source_doc_id, reason, operator_id
    )
    SELECT tgt.tenant_id, tgt.location_id, tgt.sku_id, -tgt.on_hand, 0, 'manual_adjust',
           NULL, NULL,
           '虛擬轉貨商品不進庫存：沖掉收貨端誤入帳的 ' || tgt.on_hand || ' 件（20260903000100）',
           '00000000-0000-0000-0000-000000000000'::uuid
      FROM tgt
    RETURNING quantity
  )
  SELECT COUNT(*), COALESCE(SUM(-quantity), 0) INTO v_locs, v_qty FROM ins;
  RAISE NOTICE '假庫存沖銷：% 個店倉 / % 件', v_locs, v_qty;
END
$fix$;

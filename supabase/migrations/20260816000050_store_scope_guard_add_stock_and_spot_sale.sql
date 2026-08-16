-- ============================================================
-- 分店帳號只能動「自己店」的庫存：新增庫存 / 現貨直配 補上店家守衛
--
-- 回報（Alex 2026-08-16）：「新增庫存只能新增自己店的庫存，這邊要擋住」。
--
-- 現況：兩支 RPC 都是 SECURITY DEFINER ＋ GRANT 給 authenticated，
-- 而且**完全沒有檢查呼叫者是哪一家店**：
--   * rpc_add_stock_by_product(p_location_id, ...)：任意倉別都能 +N。
--   * rpc_create_spot_sale(p_store_id, ...)：任意分店的貨都能配給客人。
-- 前端各自有擋（庫存總覽把倉別清單過濾成只有自己店、分店帳號 locked；
-- 庫存列表也只顯示自己店），但那只是 UI —— 直接打 PostgREST 就繞過了。
-- 這正是 CLAUDE.md 記過的「按鈕拿掉但 API 還通等於沒停」
-- （前例：rpc_create_free_transfer 停用時必須連 EXECUTE 一起收回）。
--
-- 守衛規則（逐字對齊 rpc_record_pickup 的取貨店守衛，20260813000000）：
--   JWT app_metadata.role ∈ ('store_manager','store_staff')
--   且 app_metadata.stores（**店名陣列**）非空、不含「總倉」
--   → 目標倉別/分店的店名必須在 stores 裡，否則 raise 'wrong_store: …'。
--   HQ 層級（owner/admin/hq_manager/hq_accountant/''）、service_role、
--   以及沒有 stores 的 legacy 分店帳號不受影響（維持現行行為，不製造新的卡關）。
--
-- ⚠ 一定要用 app_metadata.stores（店名陣列），**不可以用 store_id**：
--   線上 33 個分店帳號沒有任何一個有 store_id（店歸屬存在 stores 名稱陣列，
--   見 20260808000020）。用 store_id 判會把所有分店帳號一律擋死 ——
--   20260815000000 檔頭記過這個坑（rpc_update_order_item_price 就是這樣壞的）。
--
-- 總倉倉別的處理：rpc_add_stock_by_product 的 p_location_id 可能是總倉
--   （沒有對應 stores 列）。分店帳號指到那裡一律擋（找不到店名 → 不在清單內）；
--   HQ 不受影響，照常可以對總倉加庫存。
--
-- 基底版本：
--   rpc_add_stock_by_product = 20260805000170（唯一版本）
--   rpc_create_spot_sale     = 20260816000045（最新；本檔的函式本體是從該檔
--                              逐字抽出後插入守衛，不是手抄）
-- rollback:
--   重跑 20260805000170 的 rpc_add_stock_by_product；
--   重跑 20260816000045 的 rpc_create_spot_sale。
-- ============================================================

-- ------------------------------------------------------------
-- 1. rpc_add_stock_by_product ＋ 店家守衛
--    （基底 20260805000170 逐字保留，只在倉別檢查後插入守衛）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_add_stock_by_product(
  p_location_id BIGINT,
  p_sku_id      BIGINT,
  p_qty         NUMERIC,
  p_reason      TEXT,
  p_operator    UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_role   TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores  JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_loc        locations%ROWTYPE;
  v_store_name TEXT;
  v_move_id    BIGINT;
  v_on_hand    NUMERIC;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION '新增庫存數量必須 > 0';
  END IF;

  SELECT * INTO v_loc FROM locations WHERE id = p_location_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '倉別 % 不存在', p_location_id;
  END IF;

  -- 店家守衛：分店角色只能對自己店的倉別加庫存。
  -- 這一欄直接影響「可分配」與現貨直配的可配量，跨店加等於幫別店憑空生貨。
  IF v_jwt_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉') THEN
    SELECT s.name INTO v_store_name
      FROM stores s
     WHERE s.location_id = p_location_id
       AND s.tenant_id   = v_loc.tenant_id;
    IF v_store_name IS NULL OR NOT (v_my_stores ? v_store_name) THEN
      RAISE EXCEPTION 'wrong_store: 這個倉別（%）不是你的店，分店帳號只能對自己店新增庫存',
        COALESCE(v_store_name, v_loc.name);
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM skus WHERE id = p_sku_id) THEN
    RAISE EXCEPTION '品項 % 不存在', p_sku_id;
  END IF;

  -- unit_cost 留 NULL：apply_movement_to_balance 只在有成本時才動均成本
  INSERT INTO stock_movements (
    tenant_id, location_id, sku_id, quantity, movement_type,
    reason, operator_id
  ) VALUES (
    v_loc.tenant_id, p_location_id, p_sku_id, p_qty, 'manual_adjust',
    COALESCE(NULLIF(TRIM(p_reason), ''), '庫存總覽手動新增庫存'), p_operator
  ) RETURNING id INTO v_move_id;

  SELECT on_hand INTO v_on_hand
    FROM stock_balances
   WHERE tenant_id = v_loc.tenant_id AND location_id = p_location_id AND sku_id = p_sku_id;

  RETURN jsonb_build_object('movement_id', v_move_id, 'on_hand', COALESCE(v_on_hand, 0));
END;
$$;

COMMENT ON FUNCTION public.rpc_add_stock_by_product(BIGINT, BIGINT, NUMERIC, TEXT, UUID) IS
  '庫存總覽「依商品新增庫存」：對某倉別某品項寫 manual_adjust(+N)。'
  '不帶成本（均成本不變）。20260816000050 加店家守衛：分店角色只能對自己店的倉別加。';

REVOKE ALL ON FUNCTION public.rpc_add_stock_by_product(BIGINT, BIGINT, NUMERIC, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_add_stock_by_product(BIGINT, BIGINT, NUMERIC, TEXT, UUID) TO authenticated;

-- ------------------------------------------------------------
-- 2. rpc_create_spot_sale ＋ 店家守衛
--    （基底 20260816000045 逐字抽出，只加 DECLARE 兩個變數與守衛段）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_spot_sale(
  p_store_id   BIGINT,
  p_sku_id     BIGINT,
  p_qty        NUMERIC,
  p_unit_price NUMERIC,
  p_member_id  BIGINT,
  p_operator   UUID,
  p_nickname   TEXT DEFAULT NULL,
  p_reason     TEXT DEFAULT NULL
) RETURNS jsonb
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
  v_c          RECORD;
  v_on_hand    NUMERIC;
  v_member     members%ROWTYPE;
  v_campaign   BIGINT;
  v_channel    BIGINT;
  v_ci         BIGINT;
  v_order_id   BIGINT;
  v_order_no   TEXT;
  v_status     TEXT;
  v_appended   BOOLEAN := FALSE;
  v_reopened   TEXT;
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

  v_free := public._sku_free_qty(p_store_id, p_sku_id);

  IF v_free < p_qty THEN
    -- 錯誤訊息要講清楚「那些貨去哪了」，不然店員只看到「不足」會以為系統壞了
    SELECT * INTO v_c FROM public._sku_commitment(p_store_id, ARRAY[p_sku_id]);
    SELECT COALESCE(sb.on_hand, 0) INTO v_on_hand
      FROM stock_balances sb
     WHERE sb.tenant_id   = v_store.tenant_id
       AND sb.location_id = v_store.location_id
       AND sb.sku_id      = p_sku_id;
    SELECT COALESCE(s.product_name, '') ||
           CASE WHEN s.variant_name IS NOT NULL THEN ' / ' || s.variant_name ELSE '' END
      INTO v_sku_label FROM skus s WHERE s.id = p_sku_id;

    RAISE EXCEPTION '「%」可配 % 件、要配 % 件。'
      '（在庫 %，其中待客取 %、等貨中 %、內部單 %）'
      '架上實際有更多貨的話，請先到「庫存總覽」對這個商品「新增庫存」把現貨入帳。',
      COALESCE(v_sku_label, p_sku_id::TEXT), v_free, p_qty,
      COALESCE(v_on_hand, 0), COALESCE(v_c.promised, 0),
      COALESCE(v_c.waiting, 0), COALESCE(v_c.pool_claimed, 0);
  END IF;

  -- ---------- sentinel trio ----------
  v_campaign := public._restock_sentinel_campaign(v_store.tenant_id);
  v_channel  := public._restock_sentinel_channel(v_store.tenant_id, p_store_id);
  v_ci       := public._restock_sentinel_campaign_item(
                  v_store.tenant_id, v_campaign, p_sku_id, p_unit_price);

  -- ---------- 找既有單 / 開新單 ----------
  -- customer_orders_trio_kind_active_uniq 是
  -- (tenant, campaign, channel, member, order_kind) 的 partial UNIQUE，
  -- predicate 只排除 transferred_out/expired/cancelled —— 'completed' 仍佔著
  -- slot，所以結案的單要重開而不是另開新單（20260805000140）。
  SELECT id, order_no, status INTO v_order_id, v_order_no, v_status
    FROM customer_orders
   WHERE tenant_id   = v_store.tenant_id
     AND campaign_id = v_campaign
     AND channel_id  = v_channel
     AND member_id   = p_member_id
     AND COALESCE(order_kind, 'normal') = 'normal'
     AND status NOT IN ('transferred_out', 'expired', 'cancelled');

  IF v_order_id IS NOT NULL THEN
    -- 目前線上這個 trio 的單只會是 ready / partially_completed / completed
    -- （同店池子轉單 mirror 來源的 ready）。萬一未來出現 pending/confirmed
    -- （例：跨店空中轉的轉入單還沒收貨），append 進去的品項會卡在
    -- 「/pickup 只讓 ready/partially_completed/shipping 勾品項」外面 ——
    -- 貨在店裡卻發不出去。與其默默產生一個沒人推得動的狀態，不如擋下。
    IF v_status IN ('pending', 'confirmed', 'shipping') THEN
      RAISE EXCEPTION '這位客人在本店已有一張尚未到貨的現貨單（% / %），'
        '請先在訂單頁處理完再配。', v_order_no, v_status;
    END IF;
    v_appended := TRUE;
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[現貨直配] ' || to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') ||
                   COALESCE(' / ' || p_reason, ''),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_order_id;
  ELSE
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
        COALESCE(E'\n' || p_reason, ''),
      p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_order_id;
  END IF;

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
  IF v_appended THEN
    -- 結案單被追加品項要重開，否則品項變幽靈（20260805000140）
    v_reopened := public._reopen_order_if_completed(
      v_order_id, p_operator, '現貨直配追加品項');
  END IF;

  SELECT order_no, status INTO v_order_no, v_status
    FROM customer_orders WHERE id = v_order_id;

  RETURN jsonb_build_object(
    'order_id',   v_order_id,
    'order_no',   v_order_no,
    'status',     v_status,
    'item_id',    v_item_id,
    'qty',        p_qty,
    'unit_price', p_unit_price,
    'amount',     p_qty * p_unit_price,
    'note_no',    v_note_no,
    'appended',   v_appended,
    'reopened',   v_reopened,
    'free_before', v_free
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT) IS
  '現貨直配：把店內自由庫存直接配給客人，不需要先開團（資料層掛 sentinel 假團）。'
  '配單＝待取：當下不扣庫存、不收款，客人到店取貨時才寫 sale 並結案。'
  '可配量上限＝_sku_free_qty（在庫 − 待客取 − 等貨 − 內部單），內部單的貨請走轉單。'
  '20260816000050 加店家守衛：分店角色只能配自己店的貨。';

REVOKE ALL ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT)
  TO authenticated;

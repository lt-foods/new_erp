-- ============================================================
-- 現貨直配：一次配單 = 一張單（不再併進同一張）
--
-- 回報（Alex 2026-08-16，附會員端截圖）：「待取貨的品項還是沒有分開」。
--   實測：16:46 配洗臉巾、16:49 配手腕包，兩次被併成 SP-2-0001，
--   會員端「待取貨」只顯示 1 筆。店員沒辦法分別取貨、分別取消，
--   客人也看不出這是兩次不同的配貨。
--
-- 原本會併單，是因為 customer_orders_trio_kind_active_uniq 這支
-- partial UNIQUE 保證「同 tenant/團/頻道/會員/order_kind 只有一張 active 單」，
-- 而現貨直配全部掛在同一個 sentinel 假團底下 → 同一位客人在同一店必然撞號，
-- 只能 append。
--
-- 改法：**放寬索引 predicate，把 SP- 單排除在唯一性之外**（該索引本來就有
--   `order_kind <> 'restock'` 這個先例），rpc_create_spot_sale 改成一律開新單。
--
-- ⚠ 為什麼不用新增 order_kind='spot'：
--   全站 26 支函式用 `order_kind = 'normal' OR order_kind IS NULL` 當口徑
--   （營收報表、會員未結金額、商品分析、缺口計算…）。新 kind 會讓現貨直配
--   的單從那些口徑裡整批消失 —— 那是靜默錯帳，比併單嚴重得多。
--   維持 normal、只在索引 predicate 上開洞，才不動任何既有口徑。
--   （同 CLAUDE.md「斷貨單沿用 status='cancelled'，不要新增 status 值」的理由。）
--
-- 唯一性放寬的風險評估：這支索引的用意是「一會員一活動一張單」，那是**真團**的
--   不變量（rpc_create_customer_orders 靠它合併同團訂單）。SP- 單掛在 sentinel
--   假團底下，那個不變量本來就沒有意義 —— 客人不是「照開團下單」，是店員一次
--   一次配的。排除它不影響任何真團。
--
-- 基底版本：
--   rpc_create_spot_sale = 20260816000050（最新；本檔函式本體從該檔逐字抽出後
--                          替換「找既有單/append」段，非手抄）
-- rollback:
--   重跑 20260816000050 的 rpc_create_spot_sale；
--   DROP INDEX customer_orders_trio_kind_active_uniq; 再建回含
--   `AND order_no NOT LIKE 'SP-%'` 之前的版本（見下方 rollback SQL 註解）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 唯一索引排除 SP- 單
--    原版（rollback 用）：
--      CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq
--        ON public.customer_orders (tenant_id, campaign_id, channel_id, member_id, order_kind)
--       WHERE status <> ALL (ARRAY['transferred_out','expired','cancelled'])
--         AND order_kind <> 'restock';
-- ------------------------------------------------------------
DROP INDEX IF EXISTS public.customer_orders_trio_kind_active_uniq;

CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq
  ON public.customer_orders (tenant_id, campaign_id, channel_id, member_id, order_kind)
 WHERE status <> ALL (ARRAY['transferred_out'::text, 'expired'::text, 'cancelled'::text])
   AND order_kind <> 'restock'::text
   AND order_no NOT LIKE 'SP-%';

COMMENT ON INDEX public.customer_orders_trio_kind_active_uniq IS
  '一會員一活動一張 active 單（真團的核心不變量，rpc_create_customer_orders 靠它合併）。'
  '排除 order_kind=''restock''（RR-/OV- 容器單每店可多張）與 SP- 現貨直配單'
  '（掛 sentinel 假團、一次配單一張，20260816000060）。';

-- ------------------------------------------------------------
-- 2. rpc_create_spot_sale：一律開新單
--    （基底 20260816000050 逐字抽出，只換「找既有單/append」那一段）
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
    'free_before', v_free
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT) IS
  '現貨直配：把店內自由庫存直接配給客人，不需要先開團（資料層掛 sentinel 假團）。'
  '配單＝待取：當下不扣庫存、不收款，客人到店取貨時才寫 sale 並結案。'
  '可配量上限＝_sku_free_qty（在庫 − 待客取 − 等貨 − 內部單），內部單的貨請走轉單。'
  '20260816000060：一次配單開一張 SP- 單（不再併進既有單），可分別取貨／取消。'
  '分店角色只能配自己店的貨（店家守衛）。';

REVOKE ALL ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT)
  TO authenticated;

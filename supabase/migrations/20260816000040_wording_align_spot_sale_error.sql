-- ============================================================
-- 用語對齊：錯誤訊息的「已承諾未取 / 內部店現貨池」→「待客取 / 內部單」
--
-- 使用者回饋（2026-08-16）：「池子」「已承諾」看不懂，改成店員讀得懂的說法。
-- 庫存總覽的欄位已改成「待客取 / 內部單 / 可分配」，但 rpc_create_spot_sale
-- 配量不足時丟出的錯誤訊息還是舊詞 —— 那句話會原封不動顯示在配單視窗上，
-- 跟畫面欄位對不起來，店員會以為是兩件事。
--
-- 純文案調整，邏輯一個字沒動（本檔的函式本體是從 20260816000010 逐字抽出來，
-- 只替換那一行訊息字串，不是手抄）。
--
-- 用語對照（使用者語言 vs 工程語言）：
--   待客取 = promised   （貨到店＋客人單掛著，等他來領）
--   等貨中 = waiting    （客人下單了但貨還沒到）
--   內部單 = pool_claimed（掛在【內部】xx 店名下的 RR- / OV- 單）
--   可分配 = free       （沒人認領，可以直接配給客人）
-- 函式/欄位名維持英文原詞，不跟著改 —— 改了反而對不上
--   _sku_commitment / _grow_internal_pool / pool_claimed。
--
-- 基底：rpc_create_spot_sale = 20260816000010（唯一版本）
-- rollback: 重跑 20260816000010 的 rpc_create_spot_sale。
-- ============================================================

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
  '同客人在同店會併進同一張 SP- 單（結案的自動重開）。';

REVOKE ALL ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT)
  TO authenticated;

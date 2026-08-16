-- ============================================================
-- 現貨直配 rpc_create_spot_sale：選商品 → 選客人 → 配掉，全程不用先開團
--
-- 需求（Alex 2026-08-16）：「直接選商品直接配庫存給客人，不跟著開團」。
-- 規劃見 docs/PLAN-現貨直配與承諾收斂.md，畫面見 docs/mockups/spot-sale.html。
--
-- 現況缺口：店裡的自由庫存（沒有任何訂單掛著的貨）唯一的出口是
--   ①「加單頁 → 店內現貨 → 現貨配單」—— 但要求該商品已經在某個團裡；
--   ② 池子（RR-/OV-）的「轉單給客人」—— 只能賣已經掛進池子的貨。
--   兩條都走不通時店員只能繞過系統直接賣 → 收了錢帳上沒單、盤點對不上。
--   2026-08-16 實測松山店：自由量 203 件 / 47 個 SKU 完全沒有出口。
--
-- 語意（與 rpc_create_offset_sale 20260805000230 同一套）：
--   配單 ＝ 把貨掛到客人名下、狀態**待取**。當下不扣庫存、不收款；
--   客人到店走正常取貨（rpc_record_pickup）時才寫 sale、結案、收款。
--   —— 不要改成開單即結案：客人還沒到店，訂單顯示「已取貨」是錯的
--   （20260805000230 就是為了修這件事）。
--
-- 資料層：訂單模型的核心不變量不動（campaign_id / campaign_item_id 都 NOT NULL）。
--   「不掛團」是對使用者而言；資料層用 sentinel 假團補位 ——
--   `__INTERNAL_RESTOCK__`（`_restock_sentinel_campaign`，補貨申請早就在用），
--   campaign_item 由 `_restock_sentinel_campaign_item` 按需自動建，
--   所以店員不必先開團、也不必先把商品加進團的品項清單。
--   共用既有 sentinel 而不另開新團：全站 10+ 處 `.neq('__INTERNAL_RESTOCK__')`
--   濾網（會員商城 / admin 開團列表 / 請購頁 / 商品頁 / liff-api）現成，
--   另開一個要逐處補條件，漏一處就靜默外顯給客人。
--
-- 幾個刻意的選擇：
--   * order_kind 維持 'normal'（不新增 'spot'）。新 kind 會被全站
--     `(order_kind = 'normal' OR IS NULL)` 的口徑整批排除 —— 包含
--     _sku_commitment 的 promised/waiting，那等於配出去的貨不算承諾、
--     自由量永遠算不完，同一批貨會被賣兩次。同 CLAUDE.md「斷貨單沿用
--     status='cancelled'，不要新增 status 值」的理由。
--   * 可配量閘門用 **_sku_free_qty**（20260816000000），不是
--     `on_hand − reserved`：reserved 欄位全站實際上沒在維護承諾量，
--     用它會把「別的客人正在等的貨」和「池子登記的貨」一起賣掉
--     （＝忠順 8 位團友撲空那型災情）。池子的貨要賣走既有「轉單給客人」。
--   * 單價由呼叫端帶入且必須 > 0：sentinel campaign_item 的 unit_price 是
--     每 (團,SKU) 一份、多位客人共用，拿它當售價會互相蓋。品項單價以參數
--     為準（同 rpc_transfer_order_partial「轉出價鎖定當下現售價」的既例）。
--     0 元會在取貨時被 20260815000000 的守衛擋下 —— 那是真客人的單，
--     不在 store_internal 豁免範圍，所以這裡就要擋。
--   * 每次配單開**新的一列**（不與既有列合併數量）：兩次配單可能不同價，
--     合併會把價蓋掉；分列後前端也看得出「這批是什麼時候配的」。
--
-- 基底版本：
--   _sku_free_qty / _sku_commitment      = 20260816000000（本次相依）
--   _restock_sentinel_campaign / _channel / _campaign_item = 20260612000020
--   _reopen_order_if_completed           = 20260805000140（只呼叫、不改）
--   rpc_record_pickup                    = 20260801000000（不呼叫 —— 配單＝待取）
--   is_order_item_pickup_ready Path D    = 20260805000170（靠 DN 減抵單放行）
-- rollback:
--   DROP FUNCTION IF EXISTS public.rpc_create_spot_sale(BIGINT,BIGINT,NUMERIC,NUMERIC,BIGINT,UUID,TEXT,TEXT);
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
      '（在庫 %，其中已承諾未取 %、等貨中 %、內部店現貨池 %）'
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
  '可配量上限＝_sku_free_qty（on_hand − 承諾 − 等貨 − 池子），池子的貨請走轉單。'
  '同客人在同店會併進同一張 SP- 單（結案的自動重開）。';

REVOKE ALL ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_spot_sale(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, UUID, TEXT, TEXT)
  TO authenticated;

-- ------------------------------------------------------------
-- rpc_get_spot_availability — 前端顯示自由量拆解（庫存總覽動作列）
--   一次回四個數字，讓畫面能寫「在庫 6 − 承諾 2 − 等貨 1 − 池子 1 ＝ 自由 2」，
--   店員才知道「不能配」是因為貨有主人、還是帳上根本沒貨。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_spot_availability(
  p_store_id BIGINT,
  p_sku_id   BIGINT
) RETURNS jsonb
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
  '庫存總覽「配給客人」動作列用：自由量拆解（在庫/承諾/等貨/池子/自由）＋建議售價。'
  '伺服端開單時會再驗一次 _sku_free_qty，這裡只是畫面預檢。';

REVOKE ALL ON FUNCTION public.rpc_get_spot_availability(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_spot_availability(BIGINT, BIGINT) TO authenticated;

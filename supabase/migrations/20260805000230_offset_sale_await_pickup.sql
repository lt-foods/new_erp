-- ============================================================
-- 現貨直售 → 現貨配單：配給客人＝「待取」，不再自動結案
--
-- 動機：2026-08-06 00:21 實際使用回饋 —— 店家在加單頁把店內現貨配給客人時，
--   客人根本還沒到店，訂單卻直接變「已完成／已取貨」。正確語意是「配單」：
--   品項掛在客人名下、狀態待取；客人到店走正常取貨流程（取貨頁），
--   那時才扣店庫存、收款 —— 收款提醒點也因此回到取貨動作上。
--
-- 改法（基底 = 20260805000210，只拿掉自動取貨那段）：
--   1. 沿用 reuse-first：先配客人「已下單未取」的品項，不足才補建訂單
--   2. 沿用店倉現貨閘門（帳上要有貨才能配）
--   3. 開庫存減抵單（coverage）→ 取貨閘門 Path D 放行，客人在取貨頁「可取」
--   4. 不呼叫 rpc_record_pickup：不寫 sale、不結案 —— 客人取貨時才扣庫存
--   收貨頁標籤照常運作：貨沒到前 covered 吸收缺口；總倉補貨到店後轉為
--   prefilled（補回先墊，見 20260805000220）。
--
-- rollback: 重跑 20260805000210 的 rpc_create_offset_sale。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_create_offset_sale(
  p_campaign_id BIGINT,
  p_channel_id  BIGINT,
  p_store_id    BIGINT,
  p_member_id   BIGINT,
  p_nickname    TEXT,
  p_items       JSONB,     -- [{campaign_item_id, qty}], qty > 0 整數
  p_reason      TEXT,
  p_operator    UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_store     stores%ROWTYPE;
  r           RECORD;
  x           RECORD;
  v_left      NUMERIC;
  v_take      NUMERIC;
  v_total     NUMERIC := 0;
  v_avail     NUMERIC;
  v_shortfall JSONB;
  v_order_no  TEXT;
  v_note_no   TEXT;
  v_sku_label TEXT;
  v_ord       RECORD;
  v_orders    INT := 0;
  v_reused    NUMERIC := 0;
  v_added     NUMERIC := 0;
BEGIN
  IF p_member_id IS NULL THEN
    RAISE EXCEPTION '現貨直售必須指定客人（純抵減請走 rpc_create_offset_order）';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) e
     WHERE (e->>'qty')::numeric <= 0
        OR (e->>'qty')::numeric <> FLOOR((e->>'qty')::numeric)
  ) THEN
    RAISE EXCEPTION '現貨直售品項數量必須為正整數';
  END IF;

  SELECT * INTO v_store FROM stores WHERE id = p_store_id;
  IF NOT FOUND OR v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 不存在或未綁定倉別', p_store_id;
  END IF;

  -- 需求彙總（同 SKU 多列先合併）
  DROP TABLE IF EXISTS _os_req;
  CREATE TEMP TABLE _os_req ON COMMIT DROP AS
  SELECT (e->>'campaign_item_id')::bigint AS ci_id,
         ci.sku_id,
         SUM((e->>'qty')::numeric)        AS qty
    FROM jsonb_array_elements(p_items) e
    JOIN campaign_items ci
      ON ci.id = (e->>'campaign_item_id')::bigint
     AND ci.campaign_id = p_campaign_id
   GROUP BY 1, 2;

  IF (SELECT COUNT(*) FROM _os_req) <> (
        SELECT COUNT(DISTINCT (e->>'campaign_item_id')::bigint) FROM jsonb_array_elements(p_items) e) THEN
    RAISE EXCEPTION '有品項不屬於這個開團';
  END IF;

  SELECT SUM(qty) INTO v_total FROM _os_req;

  -- 同組併發：鎖住 (店, 團, 客人) 免得兩台同時各建一筆
  PERFORM pg_advisory_xact_lock(hashtext(format('offsale:%s:%s:%s:%s',
    v_store.tenant_id, p_campaign_id, p_store_id, p_member_id)));

  -- 店倉可用量檢查（現貨要先在帳上；庫存總覽可依商品新增庫存）
  FOR r IN SELECT * FROM _os_req LOOP
    SELECT COALESCE(sb.on_hand - sb.reserved, 0) INTO v_avail
      FROM stock_balances sb
     WHERE sb.tenant_id = v_store.tenant_id
       AND sb.location_id = v_store.location_id
       AND sb.sku_id = r.sku_id
     FOR UPDATE;
    IF NOT FOUND THEN v_avail := 0; END IF;
    IF v_avail < r.qty THEN
      SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
        INTO v_sku_label FROM skus s WHERE s.id = r.sku_id;
      RAISE EXCEPTION '「%」店內帳上現貨不足：可用 % 件、要交 % 件。請先到「庫存總覽」對該商品新增庫存',
        COALESCE(v_sku_label, r.sku_id::text), v_avail, r.qty;
    END IF;
  END LOOP;

  -- ① 這位客人在本團本店「已經下過、還沒取」的量
  DROP TABLE IF EXISTS _os_have;
  CREATE TEMP TABLE _os_have ON COMMIT DROP AS
  SELECT q.sku_id, COALESCE(SUM(coi.qty), 0) AS qty
    FROM (SELECT DISTINCT sku_id FROM _os_req) q
    LEFT JOIN customer_orders co
      ON co.tenant_id       = v_store.tenant_id
     AND co.campaign_id     = p_campaign_id
     AND co.pickup_store_id = p_store_id
     AND co.member_id       = p_member_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND co.transferred_from_order_id IS NULL
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
    LEFT JOIN customer_order_items coi
      ON coi.order_id = co.id
     AND coi.sku_id   = q.sku_id
     AND coi.status IN ('pending', 'reserved', 'ready')
   GROUP BY q.sku_id;

  -- ② 不足的部分才補建訂單（既有的量直接拿來交，不重複加）
  --    別名不可用 r / x —— 那是本函式的 RECORD 變數名，PL/pgSQL 會報
  --    「column reference is ambiguous」。
  SELECT jsonb_agg(jsonb_build_object('campaign_item_id', req.ci_id,
                                      'qty', req.qty - COALESCE(hav.qty, 0)))
    INTO v_shortfall
    FROM _os_req req
    LEFT JOIN _os_have hav ON hav.sku_id = req.sku_id
   WHERE req.qty - COALESCE(hav.qty, 0) > 0;

  SELECT COALESCE(SUM(LEAST(req.qty, COALESCE(hav.qty, 0))), 0),
         COALESCE(SUM(GREATEST(req.qty - COALESCE(hav.qty, 0), 0)), 0)
    INTO v_reused, v_added
    FROM _os_req req LEFT JOIN _os_have hav ON hav.sku_id = req.sku_id;

  IF v_shortfall IS NOT NULL THEN
    SELECT c.out_order_no INTO v_order_no
      FROM public.rpc_create_customer_orders(
        p_campaign_id, p_channel_id,
        jsonb_build_array(jsonb_build_object(
          'member_id', p_member_id,
          'nickname', p_nickname,
          'pickup_store_id', p_store_id,
          'items', v_shortfall
        ))
      ) c
     LIMIT 1;
  END IF;

  -- ③ 決定實際要交哪幾行（由舊到新吃滿，含剛補建/併入的量）
  DROP TABLE IF EXISTS _os_take;
  CREATE TEMP TABLE _os_take (order_id BIGINT, item_id BIGINT, take NUMERIC) ON COMMIT DROP;

  FOR r IN SELECT * FROM _os_req LOOP
    v_left := r.qty;
    FOR x IN
      SELECT coi.id, coi.order_id, coi.qty
        FROM customer_orders co
        JOIN customer_order_items coi
          ON coi.order_id = co.id
         AND coi.sku_id   = r.sku_id
         AND coi.status IN ('pending', 'reserved', 'ready')
       WHERE co.tenant_id       = v_store.tenant_id
         AND co.campaign_id     = p_campaign_id
         AND co.pickup_store_id = p_store_id
         AND co.member_id       = p_member_id
         AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
         AND co.transferred_from_order_id IS NULL
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       ORDER BY coi.id
       FOR UPDATE OF coi
    LOOP
      EXIT WHEN v_left <= 0;
      v_take := LEAST(x.qty, v_left);
      INSERT INTO _os_take VALUES (x.order_id, x.id, v_take);
      v_left := v_left - v_take;
    END LOOP;
    IF v_left > 0 THEN
      RAISE EXCEPTION '找不到足夠的訂單品項可交貨（還差 % 件），請重新整理畫面再試', v_left;
    END IF;
  END LOOP;

  -- ④ 開庫存減抵單（不是抵減單）：picked_up 本身就會離開採購需求池，
  --    再開負數訂單會讓同一件被扣兩次；減抵單只當收貨頁的 coverage。
  --    一個 SKU 一張單；用 RETURNING 收進暫存表對回 sku，
  --    不要靠 created_at 去 join（同一句 INSERT 的多張單時間戳一樣）
  DROP TABLE IF EXISTS _os_note;
  CREATE TEMP TABLE _os_note (note_id BIGINT, sku_id BIGINT, note_no TEXT) ON COMMIT DROP;

  WITH ins AS (
    INSERT INTO inventory_deduction_notes (
      tenant_id, note_no, campaign_id, store_id, sku_id, transfer_id,
      qty, reason, created_by
    )
    SELECT v_store.tenant_id,
           'DN' || to_char(NOW(), 'YYMMDD') || lpad(nextval('deduction_note_seq')::text, 4, '0'),
           p_campaign_id, p_store_id, req.sku_id, NULL,
           req.qty,
           COALESCE(NULLIF(TRIM(p_reason), ''), '加單頁現貨配單'),
           p_operator
      FROM _os_req req
    RETURNING id, sku_id, note_no
  )
  INSERT INTO _os_note SELECT ins.id, ins.sku_id, ins.note_no FROM ins;

  SELECT n.note_no INTO v_note_no FROM _os_note n ORDER BY n.note_id LIMIT 1;

  INSERT INTO inventory_deduction_note_items (note_id, order_id, order_item_id, qty)
  SELECT n.note_id, t.order_id, t.item_id, t.take
    FROM _os_take t
    JOIN customer_order_items coi ON coi.id = t.item_id
    JOIN _os_note n ON n.sku_id = coi.sku_id;

  -- ⑤ 解除被配到品項的待補貨擋板（若有）→ 搭配減抵單 Path D，客人即為「可取」。
  --    不呼叫 rpc_record_pickup：配單＝待取，客人到店取貨時才寫 sale、扣庫存、結案。
  UPDATE customer_order_items coi
     SET backorder_at = NULL, backorder_by = NULL,
         updated_by = p_operator, updated_at = NOW()
    FROM _os_take t
   WHERE coi.id = t.item_id
     AND coi.backorder_at IS NOT NULL;

  SELECT COUNT(DISTINCT t.order_id) INTO v_orders FROM _os_take t;

  RETURN jsonb_build_object(
    'note_no', v_note_no,
    'order_no', COALESCE(v_order_no,
                 (SELECT co.order_no FROM _os_take t JOIN customer_orders co ON co.id = t.order_id LIMIT 1)),
    'assigned_qty', v_total,
    'reused_qty', v_reused,   -- 直接交付客人原本就下過的量
    'added_qty', v_added,     -- 客人沒下過、這次才補建的量
    'orders', v_orders
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_offset_sale(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, JSONB, TEXT, UUID) IS
  '現貨配單：店內現貨配給指定客人，狀態＝待取。先配「已下單未取」的品項、不足才補建；
開庫存減抵單當 coverage（取貨閘門 Path D 放行）。不自動結案 —— 客人到店取貨時才扣庫存。
20260805000230 拿掉自動取貨（原 20260805000210 會直接結案）。';

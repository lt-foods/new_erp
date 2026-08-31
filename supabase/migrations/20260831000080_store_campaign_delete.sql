-- ============================================================================
-- 店家自開團：admin 與店長可以直接刪掉自己的團（連同訂單）
-- ============================================================================
-- 需求（Alex 2026-08-31）：「自己開的團 admin 跟店長可以直接刪除。」
--
-- 為什麼不能沿用 rpc_delete_campaign：那支有兩道守衛擋著 ——
--   ① status='open' 不給刪
--   ② **有任何顧客訂單就不給刪**
-- 而店家自開團會被想刪掉的情境幾乎都有訂單（測試團、關錯的團、下錯商品的團），
-- 所以 ② 等於「永遠刪不掉」。線上那張 test 團就是 receiving + 1 張訂單。
--
-- 這支的守衛換成**「有沒有真的動到貨與錢」**，而不是「有沒有訂單」：
--   * 這團收過貨（stock_movements 掛在該團）           → 擋
--   * 有品項被取走（picked_up）                        → 擋
--   * 訂單被轉出／轉入過（transferred_from/to_order_id）→ 擋
--   * 訂單身上掛著調撥單，或品項被庫存減抵單指名        → 擋
-- 另外三個沒有 CASCADE 的參照（external_order_imports / mutual_aid_board 的
-- 來源訂單）刻意**不清**：那是別張單據的資料，不該被這裡順手刪掉；
-- 真的踩到就讓 FK 擋下來，轉成中文錯誤請使用者自己去處理。
-- 都沒有 = 這團從頭到尾只是「記了一筆需求」，刪掉不會讓任何庫存或金額憑空消失。
-- 反之只要沾到一點，一律擋下並回中文原因，請改用結算 / 取消那條路。
--
-- 刪訂單為什麼安全：customer_orders 的下游 customer_order_items /
-- customer_order_audit_log / order_pickup_events / customer_order_transfer_links
-- 都是 ON DELETE CASCADE，其餘沒有 CASCADE 而且屬於這張訂單自己的
-- （customer_order_sources / order_waitlist.promoted_order_id /
--  order_expiry_events / order_shortage_events）本檔明列清除；
-- 真的還有別的東西參照就會 foreign_key_violation，一律轉成看得懂的中文錯誤，
-- 不會刪一半。四張 append-only 表在交易內暫時停用保護，做完立刻打開
-- （做法與 rpc_delete_campaign 一致）。
--
-- 順手補一個既有的洞：rpc_delete_campaign **完全沒有角色 / 店家守衛**，
-- 任何登入者都刪得掉 draft/closed/cancelled 的總倉團（前端那顆「刪除」本來
-- 就沒有鎖 isAdmin）。本檔一併補上：自開團要過 _assert_own_store、
-- 總倉團要 HQ / 管理員角色。
--
-- 基底版本：rpc_delete_campaign = 20260630000020_rpc_delete_campaign_allow_non_open.sql
--   （逐字取自線上定義，只在最前面加守衛）
-- Rollback：
--   DROP FUNCTION public.rpc_delete_store_campaign(BIGINT, UUID);
--   rpc_delete_campaign CREATE OR REPLACE 回 20260630000020。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. rpc_delete_store_campaign — 刪掉自開團（連訂單）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_delete_store_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant  UUID := public._current_tenant_id();
  v_role    TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_owner   BIGINT;
  v_loc     BIGINT;
  v_no      TEXT;
  v_orders  BIGINT[];
  v_n_ord   INT := 0;
  v_qty     NUMERIC;
  v_cnt     INT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'insufficient_role: % 不能刪除開團', v_role;
  END IF;

  SELECT gc.owner_store_id, gc.campaign_no, st.location_id
    INTO v_owner, v_no, v_loc
    FROM group_buy_campaigns gc
    LEFT JOIN stores st ON st.id = gc.owner_store_id
   WHERE gc.id = p_campaign_id AND gc.tenant_id = v_tenant
   FOR UPDATE OF gc;

  IF v_no IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'campaign % 不是店家自開團，請用原本的刪除', p_campaign_id;
  END IF;
  PERFORM public._assert_own_store(v_owner);

  -- ── 守衛：只要真的動到貨或錢，就不給刪 ─────────────────────────────
  SELECT COALESCE(SUM(sm.quantity), 0) INTO v_qty
    FROM stock_movements sm
   WHERE sm.tenant_id       = v_tenant
     AND sm.location_id     = v_loc
     AND sm.source_doc_type = 'campaign'
     AND sm.source_doc_id   = p_campaign_id;
  IF v_qty <> 0 THEN
    RAISE EXCEPTION '這團已經收過貨（% 件），不能刪除。庫存已經進去了，請改用「結算」收尾', v_qty;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
   WHERE co.campaign_id = p_campaign_id
     AND coi.status = 'picked_up';
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '這團已經有 % 個品項被取走，不能刪除', v_cnt;
  END IF;

  SELECT ARRAY_AGG(co.id) INTO v_orders
    FROM customer_orders co
   WHERE co.tenant_id = v_tenant AND co.campaign_id = p_campaign_id;
  v_orders := COALESCE(v_orders, '{}');
  v_n_ord  := COALESCE(array_length(v_orders, 1), 0);

  IF v_n_ord > 0 THEN
    -- 轉單過的不給刪：貨已經記在別張單上，刪掉這邊會讓那張單失去來源
    SELECT COUNT(*) INTO v_cnt
      FROM customer_orders co
     WHERE co.id = ANY (v_orders)
       AND (co.transferred_from_order_id IS NOT NULL
            OR co.transferred_to_order_id IS NOT NULL);
    IF v_cnt = 0 THEN
      SELECT COUNT(*) INTO v_cnt
        FROM customer_orders co
       WHERE co.transferred_from_order_id = ANY (v_orders)
          OR co.transferred_to_order_id   = ANY (v_orders);
    END IF;
    IF v_cnt > 0 THEN
      RAISE EXCEPTION '這團的訂單有轉單記錄，不能刪除';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM transfers t WHERE t.customer_order_id = ANY (v_orders);
    IF v_cnt > 0 THEN
      RAISE EXCEPTION '這團的訂單掛著調撥單，不能刪除';
    END IF;

    SELECT COUNT(*) INTO v_cnt
      FROM inventory_deduction_note_items ni
      JOIN customer_order_items coi ON coi.id = ni.order_item_id
     WHERE coi.order_id = ANY (v_orders);
    IF v_cnt > 0 THEN
      RAISE EXCEPTION '這團的品項被庫存減抵單指名，不能刪除';
    END IF;
  END IF;

  -- ── 刪除 ────────────────────────────────────────────────────────────
  -- append-only 保護在交易內暫時停用（含 CASCADE 會觸發的那幾張）
  ALTER TABLE campaign_audit_log       DISABLE TRIGGER trg_no_mut_camp_audit;
  ALTER TABLE customer_order_sources   DISABLE TRIGGER trg_no_mut_cos;
  ALTER TABLE customer_order_audit_log DISABLE TRIGGER trg_no_mut_coa;
  ALTER TABLE order_pickup_events      DISABLE TRIGGER trg_no_mut_pickup_ev;
  BEGIN
    IF v_n_ord > 0 THEN
      -- 沒有 CASCADE 的下游，明列清除
      DELETE FROM customer_order_sources  WHERE order_id = ANY (v_orders);
      DELETE FROM order_waitlist          WHERE promoted_order_id = ANY (v_orders);
      DELETE FROM order_expiry_events     WHERE order_id = ANY (v_orders);
      DELETE FROM order_shortage_events   WHERE order_id = ANY (v_orders);
      -- items / audit_log / pickup_events / transfer_links 由 FK CASCADE 帶走
      DELETE FROM customer_orders WHERE id = ANY (v_orders);
    END IF;

    DELETE FROM campaign_audit_log     WHERE campaign_id = p_campaign_id;
    DELETE FROM customer_order_sources WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
    DELETE FROM order_waitlist         WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
    -- campaign_items / campaign_channels 由 FK CASCADE 連帶刪除
    DELETE FROM group_buy_campaigns    WHERE id = p_campaign_id AND tenant_id = v_tenant;
  EXCEPTION
    WHEN foreign_key_violation THEN
      ALTER TABLE campaign_audit_log       ENABLE TRIGGER trg_no_mut_camp_audit;
      ALTER TABLE customer_order_sources   ENABLE TRIGGER trg_no_mut_cos;
      ALTER TABLE customer_order_audit_log ENABLE TRIGGER trg_no_mut_coa;
      ALTER TABLE order_pickup_events      ENABLE TRIGGER trg_no_mut_pickup_ev;
      RAISE EXCEPTION '這團還被其他單據參照，不能刪除（%）', SQLERRM;
    WHEN OTHERS THEN
      ALTER TABLE campaign_audit_log       ENABLE TRIGGER trg_no_mut_camp_audit;
      ALTER TABLE customer_order_sources   ENABLE TRIGGER trg_no_mut_cos;
      ALTER TABLE customer_order_audit_log ENABLE TRIGGER trg_no_mut_coa;
      ALTER TABLE order_pickup_events      ENABLE TRIGGER trg_no_mut_pickup_ev;
      RAISE;
  END;
  ALTER TABLE campaign_audit_log       ENABLE TRIGGER trg_no_mut_camp_audit;
  ALTER TABLE customer_order_sources   ENABLE TRIGGER trg_no_mut_cos;
  ALTER TABLE customer_order_audit_log ENABLE TRIGGER trg_no_mut_coa;
  ALTER TABLE order_pickup_events      ENABLE TRIGGER trg_no_mut_pickup_ev;

  RETURN jsonb_build_object(
    'deleted', true,
    'campaign_no', v_no,
    'orders_deleted', v_n_ord
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_delete_store_campaign(BIGINT, UUID) IS
  '刪除店家自開團（連同它的顧客訂單）。守衛是「有沒有真的動到貨與錢」：'
  '收過貨 / 取過貨 / 轉過單 / 掛著調撥單或減抵單一律擋下。'
  '分店只能刪自己店的（_assert_own_store）。';

REVOKE ALL ON FUNCTION public.rpc_delete_store_campaign(BIGINT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delete_store_campaign(BIGINT, UUID) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. rpc_delete_campaign — 補上角色 / 店家守衛（原本完全沒有）
--    函式其餘部分逐字取自線上定義（基底 20260630000020），一字未動。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_delete_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $fn$

DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_status TEXT;
  v_orders INTEGER;
  v_owner  BIGINT;
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  -- 20260831：補上原本完全沒有的守衛。前端那顆「刪除」本來就沒有鎖 isAdmin，
  -- 所以在這之前任何登入者都刪得掉別人的 draft/closed/cancelled 開團。
  SELECT owner_store_id INTO v_owner
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant;

  IF v_owner IS NOT NULL THEN
    -- 店家自開團：分店只能刪自己店的（而且有訂單的請走 rpc_delete_store_campaign）
    PERFORM public._assert_own_store(v_owner);
  ELSIF v_role NOT IN ('owner','admin','hq_manager','assistant','') THEN
    -- 總倉團：只有總倉 / 管理層級能刪（'' 是 legacy admin，漏掉會擋死舊帳號）
    RAISE EXCEPTION 'insufficient_role: % 不能刪除總倉的開團', v_role;
  END IF;
  -- p_operator 為對齊 close/finalize 簽章而保留；刪除後 row + audit 皆不存在、
  -- 無處可記，故不使用（與 rpc_delete_picking_wave 一致）。

  SELECT status
    INTO v_status
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  -- 守門 1：開團中(上架)不可刪 — 顧客仍可下單
  IF v_status = 'open' THEN
    RAISE EXCEPTION 'campaign % is open, cannot delete', p_campaign_id;
  END IF;

  -- 守門 2：有顧客訂單不可刪
  SELECT COUNT(*) INTO v_orders
    FROM customer_orders
   WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
  IF v_orders > 0 THEN
    RAISE EXCEPTION 'campaign % has % orders, cannot delete', p_campaign_id, v_orders;
  END IF;

  -- 暫停兩個 append-only 保護（cascade / 手動清除都會觸發 BEFORE DELETE trigger）
  ALTER TABLE campaign_audit_log     DISABLE TRIGGER trg_no_mut_camp_audit;
  ALTER TABLE customer_order_sources DISABLE TRIGGER trg_no_mut_cos;
  BEGIN
    -- campaign_audit_log：雖為 ON DELETE CASCADE，但 append-only，先手動清
    DELETE FROM campaign_audit_log
     WHERE campaign_id = p_campaign_id;
    -- customer_order_sources：無 CASCADE + append-only；無訂單時可能仍有
    -- 上傳截圖／解析暫存（order_id 為 NULL），一併清除
    DELETE FROM customer_order_sources
     WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
    -- order_waitlist：無 CASCADE，候補名單一併清除
    DELETE FROM order_waitlist
     WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
    -- 刪開團本體：campaign_items / campaign_channels 由 FK CASCADE 連帶刪除
    DELETE FROM group_buy_campaigns
     WHERE id = p_campaign_id AND tenant_id = v_tenant;
  EXCEPTION
    WHEN foreign_key_violation THEN
      -- 仍被其他「無 CASCADE」的表參照（如採購單明細 / 撿貨波）
      ALTER TABLE campaign_audit_log     ENABLE TRIGGER trg_no_mut_camp_audit;
      ALTER TABLE customer_order_sources ENABLE TRIGGER trg_no_mut_cos;
      RAISE EXCEPTION 'campaign % still referenced by other records, cannot delete', p_campaign_id;
    WHEN OTHERS THEN
      ALTER TABLE campaign_audit_log     ENABLE TRIGGER trg_no_mut_camp_audit;
      ALTER TABLE customer_order_sources ENABLE TRIGGER trg_no_mut_cos;
      RAISE;
  END;
  ALTER TABLE campaign_audit_log     ENABLE TRIGGER trg_no_mut_camp_audit;
  ALTER TABLE customer_order_sources ENABLE TRIGGER trg_no_mut_cos;
END;

$fn$;

COMMENT ON FUNCTION public.rpc_delete_campaign(BIGINT, UUID) IS
  '刪除開團（沒有顧客訂單、且非 open 才給刪）。20260831 補上守衛：'
  '自開團要過 _assert_own_store，總倉團要 HQ / 管理員角色。基底 20260630000020。';

GRANT EXECUTE ON FUNCTION public.rpc_delete_campaign(BIGINT, UUID) TO authenticated;

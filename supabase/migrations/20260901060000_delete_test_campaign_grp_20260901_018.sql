-- ============================================================================
-- 一次性資料清理：刪掉測試團 GRP-20260901-018「test」整串
-- ============================================================================
-- 需求（Alex 2026-09-01）：「編輯開團 #GRP-20260901-018｜test 幫我整串刪掉」。
--
-- 這團是 2026-09-01 當天在正式庫上做的一輪端到端測試（松山店自開團）：
--   開團 → 下單 3 件 → 對團收貨 +3 → 取貨 −3 → 撤銷取貨 +3 → 取消配單
-- 結果留下 status='receiving' 的團、1 張 confirmed 訂單（品項 pending +
-- backorder_at），以及**松山店帳上憑空多出來的 3 件毛豆仁**（SKU 1062）。
-- 測試前松山店該 SKU 的 on_hand 是 0，這 3 件完全是測試收貨造出來的。
--
-- 為什麼不能直接走 rpc_delete_store_campaign（20260831000080）：
-- 那支的第一道守衛是「這團收過貨就擋」（source_doc_type='campaign' 的異動量
-- 不為 0），而這團正好收過。守衛本身是對的 —— 直接刪團會把那 3 件留在店裡
-- 變成無主庫存，店員會把它配給真的客人，之後庫存扣成負的。
-- 所以這裡先**沖銷那筆測試收貨**（stock_movements 是 append-only，只能補一筆
-- reversal，不能 DELETE），把松山店退回 0，再刪整串。
--
-- 刪除範圍與 rpc_delete_store_campaign 的刪除段一致：
--   customer_orders（items / audit_log / pickup_events / transfer_links 由 FK
--   CASCADE 帶走）、campaign_audit_log、customer_order_sources、order_waitlist，
--   最後 group_buy_campaigns（campaign_items / channels 由 FK CASCADE 帶走）。
--   四張 append-only 表在交易內暫時停用保護，做完立刻打開。
--
-- 刻意不動的：訂單那兩筆 sale(−3) / reversal(+3) 的 stock_movements。
--   帳本是 append-only，本來就刪不掉；兩筆互相沖銷、淨值為 0，留著只是
--   source_doc_id 指向一張已刪的訂單，不影響任何庫存或金額。
--
-- 守衛：只要這團沾到真的貨或錢（有品項被取走 / 轉過單 / 掛著調撥單 / 被庫存
--   減抵單指名 / 收貨異動已經被沖銷過以外的情況），就整支 RAISE 中止，不刪一半。
-- 冪等：團已經不在就直接跳過。
--
-- Rollback：沒有。實體刪除，資料不可回復（測試資料，刪掉即為目的）。
-- ============================================================================

DO $$
DECLARE
  v_tenant CONSTANT UUID := '00000000-0000-0000-0000-000000000001';
  v_no     CONSTANT TEXT := 'GRP-20260901-018';
  v_camp   BIGINT;
  v_orders BIGINT[];
  v_n_ord  INT := 0;
  v_cnt    INT;
  v_qty    NUMERIC;
  r        RECORD;
BEGIN
  SELECT id INTO v_camp
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant AND campaign_no = v_no AND name = 'test'
   FOR UPDATE;

  IF v_camp IS NULL THEN
    RAISE NOTICE '[skip] campaign % 不存在（已刪除或不是這一支）', v_no;
    RETURN;
  END IF;

  SELECT ARRAY_AGG(co.id) INTO v_orders
    FROM customer_orders co
   WHERE co.tenant_id = v_tenant AND co.campaign_id = v_camp;
  v_orders := COALESCE(v_orders, '{}');
  v_n_ord  := COALESCE(array_length(v_orders, 1), 0);

  -- ── 守衛：只要真的動到貨或錢就中止（同 rpc_delete_store_campaign） ──────
  SELECT COUNT(*) INTO v_cnt
    FROM customer_order_items coi
   WHERE coi.order_id = ANY (v_orders) AND coi.status = 'picked_up';
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '這團有 % 個品項還在已取貨狀態，不刪', v_cnt;
  END IF;

  IF v_n_ord > 0 THEN
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
    IF v_cnt > 0 THEN RAISE EXCEPTION '這團的訂單有轉單記錄，不刪'; END IF;

    SELECT COUNT(*) INTO v_cnt FROM transfers t WHERE t.customer_order_id = ANY (v_orders);
    IF v_cnt > 0 THEN RAISE EXCEPTION '這團的訂單掛著調撥單，不刪'; END IF;

    SELECT COUNT(*) INTO v_cnt
      FROM inventory_deduction_note_items ni
      JOIN customer_order_items coi ON coi.id = ni.order_item_id
     WHERE coi.order_id = ANY (v_orders);
    IF v_cnt > 0 THEN RAISE EXCEPTION '這團的品項被庫存減抵單指名，不刪'; END IF;

    -- 訂單身上的 sale 必須已經被沖銷乾淨（撤銷取貨）。沒沖乾淨就把收貨也沖掉，
    -- 會把庫存扣成負的。
    SELECT COALESCE(SUM(sm.quantity), 0) INTO v_qty
      FROM stock_movements sm
     WHERE sm.tenant_id = v_tenant
       AND sm.source_doc_type = 'customer_order'
       AND sm.source_doc_id = ANY (v_orders);
    IF v_qty <> 0 THEN
      RAISE EXCEPTION '這團的訂單還有沒沖銷完的庫存異動（淨 % 件），不刪', v_qty;
    END IF;
  END IF;

  -- ── 1. 沖銷測試收貨：把松山店那 3 件退回去 ──────────────────────────────
  FOR r IN
    SELECT sm.id, sm.tenant_id, sm.location_id, sm.sku_id, sm.quantity, sm.operator_id
      FROM stock_movements sm
     WHERE sm.tenant_id       = v_tenant
       AND sm.source_doc_type = 'campaign'
       AND sm.source_doc_id   = v_camp
       AND sm.movement_type   = 'purchase_receipt'
       AND NOT EXISTS (SELECT 1 FROM stock_movements rv WHERE rv.reverses = sm.id)
     ORDER BY sm.id
  LOOP
    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
      source_doc_type, source_doc_id, reverses, reason, operator_id
    ) VALUES (
      r.tenant_id, r.location_id, r.sku_id, -r.quantity, NULL, 'reversal',
      'campaign', v_camp, r.id,
      format('沖銷測試團 %s 的收貨 (movement %s)，整團刪除', v_no, r.id),
      r.operator_id
    );
  END LOOP;

  SELECT COALESCE(SUM(sm.quantity), 0) INTO v_qty
    FROM stock_movements sm
   WHERE sm.tenant_id = v_tenant
     AND sm.source_doc_type = 'campaign'
     AND sm.source_doc_id = v_camp;
  IF v_qty <> 0 THEN
    RAISE EXCEPTION '沖銷後這團的庫存異動淨值還有 % 件，中止', v_qty;
  END IF;

  -- ── 2. 刪整串 ───────────────────────────────────────────────────────────
  ALTER TABLE campaign_audit_log       DISABLE TRIGGER trg_no_mut_camp_audit;
  ALTER TABLE customer_order_sources   DISABLE TRIGGER trg_no_mut_cos;
  ALTER TABLE customer_order_audit_log DISABLE TRIGGER trg_no_mut_coa;
  ALTER TABLE order_pickup_events      DISABLE TRIGGER trg_no_mut_pickup_ev;
  BEGIN
    IF v_n_ord > 0 THEN
      DELETE FROM customer_order_sources WHERE order_id = ANY (v_orders);
      DELETE FROM order_waitlist         WHERE promoted_order_id = ANY (v_orders);
      DELETE FROM customer_orders        WHERE id = ANY (v_orders);
    END IF;

    DELETE FROM campaign_audit_log     WHERE campaign_id = v_camp;
    DELETE FROM customer_order_sources WHERE campaign_id = v_camp AND tenant_id = v_tenant;
    DELETE FROM order_waitlist         WHERE campaign_id = v_camp AND tenant_id = v_tenant;
    DELETE FROM group_buy_campaigns    WHERE id = v_camp AND tenant_id = v_tenant;
  EXCEPTION
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

  RAISE NOTICE '[done] campaign % (id=%) 已刪除，連同 % 張訂單', v_no, v_camp, v_n_ord;
END $$;

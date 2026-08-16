-- ============================================================
-- 一次性正式庫修正：把 SP-2-0001 拆成兩張單
--
-- 背景：現貨直配上線首日（2026-08-16），松山店對 Alex Chen11 連配兩次
--   （08:46 美魔女洗臉巾 $33、08:49 ins便携手腕包 $115），當時的
--   rpc_create_spot_sale 會 reuse-first 併進同一張單 → 會員端「待取貨」
--   只顯示 1 筆，店員無法分別取貨／取消。
--   20260816000060 已改成「一次配單一張單」，但**只對之後的配單生效**，
--   這張既有的單要手動拆。
--
-- 為什麼是「搬列」而不是「複製一份再刪」：
--   customer_order_items.id 被 inventory_deduction_note_items.order_item_id
--   指著（取貨閘門 Path D 的 coverage 對帳靠它）。複製會換 id、對應就斷了。
--   同 CLAUDE.md 斷貨拆單「UPDATE po_id 搬列、不要複製」的理由。
--
-- 這張單的狀態（動手前實查）：
--   order 77158 / ready / campaign 806 / channel 35 / member Alex Chen11
--   item 94817  洗臉巾 G01003-01  qty 1  $33   pending  → 留在 SP-2-0001
--   item 94820  手腕包 G01956-04  qty 1  $115  pending  → 搬到新單
--   兩個品項各自已有自己的 DN 減抵單（DN2608160032 / DN2608160033）
--   取貨紀錄 0 筆、audit_log 0 筆、customer_order_sources 0 列
--   → 沒有任何已交付/已對帳的東西會被動到。
--
-- 冪等：已經拆過（item 94820 不在 77158 上）就整支跳過，不會重複開單。
-- Rollback：
--   UPDATE customer_order_items SET order_id = 77158 WHERE id = 94820;
--   UPDATE inventory_deduction_note_items SET order_id = 77158 WHERE order_item_id = 94820;
--   DELETE FROM customer_orders WHERE order_no = 'SP-2-0002' AND tenant_id = <t>;
-- ============================================================

DO $$
DECLARE
  v_src        customer_orders%ROWTYPE;
  v_move_item  BIGINT := 94820;   -- 手腕包那一列
  v_new_id     BIGINT;
  v_new_no     TEXT;
  v_seq        INT;
  v_items      INT;
  v_picked     INT;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  SELECT * INTO v_src FROM customer_orders WHERE order_no = 'SP-2-0001';
  IF NOT FOUND THEN
    RAISE NOTICE '找不到 SP-2-0001，跳過';
    RETURN;
  END IF;

  -- 冪等守衛：已經拆過就不再動
  IF NOT EXISTS (SELECT 1 FROM customer_order_items
                  WHERE id = v_move_item AND order_id = v_src.id) THEN
    RAISE NOTICE '品項 % 已不在 SP-2-0001 上（可能已拆過），跳過', v_move_item;
    RETURN;
  END IF;

  -- 安全守衛：只處理「兩個品項、都還沒取貨」的原始狀態。
  -- 任何一項不符就中止 —— 拆一張已經動過的單風險太高，寧可人工看過再說。
  SELECT count(*) INTO v_items FROM customer_order_items WHERE order_id = v_src.id;
  SELECT count(*) INTO v_picked FROM customer_order_items
   WHERE order_id = v_src.id AND status NOT IN ('pending', 'reserved', 'ready');
  IF v_items <> 2 OR v_picked <> 0 THEN
    RAISE EXCEPTION '狀態與預期不符（品項 % 筆、已非待取 % 筆），中止拆單', v_items, v_picked;
  END IF;
  IF EXISTS (SELECT 1 FROM stock_movements
              WHERE source_doc_type = 'customer_order' AND source_doc_id = v_src.id) THEN
    RAISE EXCEPTION '這張單已有庫存異動（取過貨），中止拆單';
  END IF;

  -- 新單號：MAX-based，與 rpc_create_spot_sale 同一套規則
  SELECT COALESCE(MAX(substring(order_no FROM '^SP-' || v_src.pickup_store_id::TEXT || '-([0-9]+)$')::INT), 0) + 1
    INTO v_seq
    FROM customer_orders
   WHERE tenant_id = v_src.tenant_id
     AND order_no ~ ('^SP-' || v_src.pickup_store_id::TEXT || '-[0-9]+$');
  v_new_no := 'SP-' || v_src.pickup_store_id::TEXT || '-' ||
              LPAD(v_seq::TEXT, GREATEST(length(v_seq::TEXT), 4), '0');

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id,
    nickname_snapshot, pickup_store_id, status, ready_at,
    order_kind, order_type, notes,
    created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_src.tenant_id, v_new_no, v_src.campaign_id, v_src.channel_id, v_src.member_id,
    v_src.nickname_snapshot, v_src.pickup_store_id, 'ready', COALESCE(v_src.ready_at, v_now),
    'normal', 'regular',
    '【現貨直配】店內現貨直接配給客人（待取，取貨時才扣庫存收款）' ||
      E'\n[拆單] 自 ' || v_src.order_no || ' 拆出（上線首日兩次配貨被併成一張，' ||
      to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') || '）',
    v_src.created_by, v_src.updated_by, v_src.created_at, v_now
  ) RETURNING id INTO v_new_id;

  -- 搬列（不是複製）：item id 不變，DN coverage 的對應才不會斷
  UPDATE customer_order_items
     SET order_id = v_new_id, updated_at = v_now
   WHERE id = v_move_item;

  -- DN 減抵單明細跟著改掛新單（note 本身不動：它只綁 campaign/store/sku）
  UPDATE inventory_deduction_note_items
     SET order_id = v_new_id
   WHERE order_item_id = v_move_item;

  UPDATE customer_orders
     SET notes = COALESCE(notes, '') ||
                 E'\n[拆單] 已把品項 #' || v_move_item || ' 拆到 ' || v_new_no || '（' ||
                 to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') || '）',
         updated_at = v_now
   WHERE id = v_src.id;

  RAISE NOTICE '已拆出 %（order_id %）', v_new_no, v_new_id;
END $$;

-- 驗證
SELECT jsonb_pretty(jsonb_agg(x ORDER BY x->>'order_no')) AS r
  FROM (
    SELECT jsonb_build_object(
             'order_no', co.order_no,
             'status',   co.status,
             'member',   m.name,
             'items',    (SELECT jsonb_agg(jsonb_build_object(
                            'item_id', i.id, 'sku', s.sku_code,
                            'name', s.product_name, 'qty', i.qty,
                            'price', i.unit_price, 'status', i.status) ORDER BY i.id)
                            FROM customer_order_items i JOIN skus s ON s.id = i.sku_id
                           WHERE i.order_id = co.id),
             'dn_lines', (SELECT jsonb_agg(n.note_no ORDER BY n.note_no)
                            FROM inventory_deduction_note_items li
                            JOIN inventory_deduction_notes n ON n.id = li.note_id
                           WHERE li.order_id = co.id)
           ) AS x
      FROM customer_orders co
      LEFT JOIN members m ON m.id = co.member_id
     WHERE co.order_no LIKE 'SP-2-%'
  ) t;

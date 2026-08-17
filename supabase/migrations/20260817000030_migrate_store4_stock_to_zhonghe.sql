-- 四號店收攤（續 20260817000020 訂單/會員遷移）：店倉庫存整批移轉中和店。
-- 四號店倉 location_id=8 → 中和店倉 location_id=14。
--
-- 做法：不直接改 stock_balances（帳要靠 stock_movements 觸發器維護），
-- 而是開一張正式的店對店調撥單 MIG-S37-ZH-20260817，走既有機制：
--   1. transfers（store_to_store / shipped）＋逐 SKU rpc_outbound(transfer_out)
--      —— 比照 _air_ship_order_items：allow_negative + fallback 成本價。
--   2. rpc_receive_transfer 標準收貨 —— inbound 移動、qty_received，
--      並自然帶動邏輯 A0–E（解待補貨、推進中和身上那批 confirmed 遷移單、
--      自動配單、內部池收斂），跟總倉派貨到店走同一條路。
--   3. 月結：customer_order_id IS NULL 的店對店單走 free_in / free_out 口徑，
--      以 transfer_items.estimated_amount 計價 —— 這裡填 qty × 分店價
--      （缺分店價退回出庫成本），中和實拿貨入帳、四號店側貸記，帳才收得攏。
--
-- 遷移當下盤點：24 個 SKU、合計 59 件，全部 on_hand > 0、reserved = 0、無在途。
-- 冪等：transfer_no 已存在就整段跳過（tenant+transfer_no 唯一鍵）。
-- rollback：反向再開一張 14 → 8 的同品項調撥單（不要刪 movements，帳是 append-only）。

DO $$
DECLARE
  v_tenant      UUID   := '00000000-0000-0000-0000-000000000001';
  v_operator    UUID   := '39fd694d-3af6-4978-beab-6e826dff7246';  -- cktalex（admin）
  v_src         BIGINT := 8;    -- 四號店倉 WH-LELE-四號
  v_dst         BIGINT := 14;   -- 中和店倉 WH-LELE-中和
  v_no          TEXT   := 'MIG-S37-ZH-20260817';
  v_transfer_id BIGINT;
  v_mov_id      BIGINT;
  v_est         NUMERIC;
  v_desc        TEXT;
  v_lines       INT    := 0;
  v_leftover    INT;
  r             RECORD;
BEGIN
  IF EXISTS (SELECT 1 FROM transfers WHERE tenant_id = v_tenant AND transfer_no = v_no) THEN
    RAISE NOTICE 'store-4 stock migration already applied, skipping';
    RETURN;
  END IF;

  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, is_air_transfer,
    notes, shipped_by, shipped_at, created_by, updated_by
  ) VALUES (
    v_tenant, v_no, v_src, v_dst,
    'shipped', 'store_to_store', FALSE,
    '四號店收攤：店倉庫存整批移轉中和店（資料遷移，配合訂單/會員遷移 20260817000020）',
    v_operator, NOW(), v_operator, v_operator
  ) RETURNING id INTO v_transfer_id;

  FOR r IN
    SELECT sb.sku_id, sb.on_hand
      FROM stock_balances sb
     WHERE sb.tenant_id = v_tenant
       AND sb.location_id = v_src
       AND sb.on_hand > 0
     ORDER BY sb.sku_id
  LOOP
    -- 比照 _air_ship_order_items：allow_negative（reserved 殘值不擋收攤）、
    -- avg_cost 缺值退現行成本價，月結才不會記 0 元
    v_mov_id := rpc_outbound(
      p_tenant_id          => v_tenant,
      p_location_id        => v_src,
      p_sku_id             => r.sku_id,
      p_quantity           => r.on_hand,
      p_movement_type      => 'transfer_out',
      p_source_doc_type    => 'transfer',
      p_source_doc_id      => v_transfer_id,
      p_operator           => v_operator,
      p_allow_negative     => TRUE,
      p_fallback_unit_cost => public._current_cost_price(v_tenant, r.sku_id)
    );

    -- free_in / free_out 口徑用 estimated_amount：qty × 分店價，缺價退出庫成本。
    -- transfer_items 的 CHECK 要求 estimated_amount 與 description 成對，
    -- description 填 SKU 碼＋品名，月結明細才看得懂這批是什麼。
    SELECT r.on_hand * COALESCE(
             NULLIF(public._branch_price_at(v_tenant, r.sku_id, NOW()), 0),
             sm.unit_cost, 0)
      INTO v_est
      FROM stock_movements sm
     WHERE sm.id = v_mov_id;

    SELECT trim(k.sku_code || ' ' || COALESCE(k.product_name, '')
             || COALESCE(' ' || NULLIF(k.variant_name, ''), ''))
      INTO v_desc
      FROM skus k
     WHERE k.id = r.sku_id;

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped,
      out_movement_id, estimated_amount, description, created_by, updated_by
    ) VALUES (
      v_transfer_id, r.sku_id, r.on_hand, r.on_hand,
      v_mov_id, v_est, v_desc, v_operator, v_operator
    );
    v_lines := v_lines + 1;
  END LOOP;

  IF v_lines = 0 THEN
    DELETE FROM transfers WHERE id = v_transfer_id;
    RAISE NOTICE 'store-4 warehouse already empty, nothing to move';
    RETURN;
  END IF;

  -- 標準收貨：p_lines NULL = 全數照出貨量入帳；邏輯 A0–E 照跑
  -- （解待補貨、推進 confirmed 遷移單、自動配單、內部池收斂）
  PERFORM rpc_receive_transfer(
    v_transfer_id, NULL, v_operator,
    '四號店收攤移轉收貨（資料遷移）', TRUE
  );

  -- 自檢：四號店倉不應再有任何非零結餘
  SELECT count(*) INTO v_leftover
    FROM stock_balances
   WHERE tenant_id = v_tenant AND location_id = v_src AND on_hand <> 0;
  IF v_leftover > 0 THEN
    RAISE EXCEPTION 'store-4 stock migration incomplete: % non-zero balances left', v_leftover;
  END IF;

  RAISE NOTICE 'store-4 stock migration done: transfer % (% lines)', v_no, v_lines;
END $$;

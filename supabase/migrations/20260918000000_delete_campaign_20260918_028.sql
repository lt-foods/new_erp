-- ============================================================================
-- 一次性資料清理：刪除團 GRP-20260918-028「復古韓版針織寬邊髮箍」（id 5348）
-- ============================================================================
-- 需求（Alex 2026-09-18）：「GRP-20260918-028 幫我刪除」。
--
-- 5348 的狀態（套用前對正式庫查過）：總倉團（owner_store_id NULL）、status=cancelled、
--   5 個商品、1 張訂單 GRP-20260918-028-0001（cancelled，會員「Alex Chen11」
--   member_id 68340，自己的測試帳號）＋ 2 個訂單品項（都沒取貨）。
--   沒有庫存異動、調撥單、轉單、減抵單、撿貨波次、採購連結、記事本貼文、
--   稽核紀錄、候補；campaign_views 1 列（CASCADE）。
--
-- 為什麼兩支既有 RPC 都走不了：
--   - rpc_delete_campaign：有任何顧客訂單就擋。
--   - rpc_delete_store_campaign：只收店家自開團（owner_store_id NOT NULL）。
--   刪法照 rpc_delete_store_campaign（20260831000080）的刪除段：先明列清掉訂單那層
--   沒有 CASCADE 的下游、刪訂單（品項 / 稽核 / 取貨事件 / 轉單連結 CASCADE），
--   再刪團頭（campaign_items / channels / views / 記事本貼文 CASCADE）。
--   四張 append-only 表在交易內暫停保護，做完立刻打開。
--
-- 守衛（任一不成立就整支 RAISE，什麼都不刪）：
--   - id + campaign_no + name 三個都要對得上、status 是 cancelled
--   - 訂單只能是那一張、而且是 cancelled；品項沒有 picked_up
--   - 沒有掛在團／訂單上的庫存異動、調撥單、轉單記錄、減抵單、撿貨波次、採購連結
--   - 記事本貼文只能是「沒有 line_post_id」的（同 20260910040000 的理由）
--
-- 備份：刪之前把團頭、訂單、以及所有 FK 指向它們的列（含 CASCADE 下一層）以 jsonb
--   存進 public._backup_20260918_deleted_campaign_028（RLS 開、anon/authenticated 無權限）。
--   確認不需要還原後可直接 DROP TABLE。customer_order_items 會存兩次（從訂單 CASCADE
--   與從 campaign_items CASCADE 各掃到一次），還原時去重。
--
-- 冪等：團已經不存在 → NOTICE 跳過。
-- Rollback：依 src_table 從備份表 jsonb_populate_record 塞回去，順序
--   group_buy_campaigns → campaign_items → customer_orders → customer_order_items → 其餘。
-- ============================================================================

DO $$
DECLARE
  v_tenant CONSTANT UUID   := '00000000-0000-0000-0000-000000000001';
  v_id     CONSTANT BIGINT := 5348;
  v_no     CONSTANT TEXT   := 'GRP-20260918-028';
  v_name   CONSTANT TEXT   := '復古韓版針織寬邊髮箍';
  v_found  BIGINT;
  v_orders BIGINT[];
  v_cnt    INT;
  r        RECORD;
  r2       RECORD;
BEGIN
  SELECT id INTO v_found
    FROM group_buy_campaigns
   WHERE id = v_id AND tenant_id = v_tenant
     AND campaign_no = v_no AND name = v_name AND status = 'cancelled'
   FOR UPDATE;

  IF v_found IS NULL THEN
    IF EXISTS (SELECT 1 FROM group_buy_campaigns WHERE id = v_id) THEN
      RAISE EXCEPTION '團 id % 存在但團號／名稱／狀態對不上，中止', v_id;
    END IF;
    RAISE NOTICE '[skip] 團 %（id %「%」）不存在（已刪除）', v_no, v_id, v_name;
    RETURN;
  END IF;

  -- ── 守衛 ────────────────────────────────────────────────────────────────
  SELECT ARRAY_AGG(id) INTO v_orders FROM customer_orders WHERE campaign_id = v_id;
  v_orders := COALESCE(v_orders, '{}');

  IF array_length(v_orders, 1) IS DISTINCT FROM 1
     OR EXISTS (SELECT 1 FROM customer_orders WHERE id = ANY (v_orders) AND status <> 'cancelled') THEN
    RAISE EXCEPTION '團 % 的訂單不是「只有一張、而且已取消」，中止', v_no;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM customer_order_items
   WHERE order_id = ANY (v_orders) AND status = 'picked_up';
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 有 % 個品項已取貨，中止', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM stock_movements
   WHERE (source_doc_type = 'campaign' AND source_doc_id = v_id)
      OR (source_doc_type = 'customer_order' AND source_doc_id = ANY (v_orders));
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 身上掛著 % 筆庫存異動，中止', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM transfers WHERE customer_order_id = ANY (v_orders);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 的訂單掛著 % 張調撥單，中止', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM customer_orders
   WHERE (id = ANY (v_orders) AND (transferred_from_order_id IS NOT NULL OR transferred_to_order_id IS NOT NULL))
      OR transferred_from_order_id = ANY (v_orders)
      OR transferred_to_order_id   = ANY (v_orders);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 的訂單有轉單記錄，中止', v_no;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM inventory_deduction_note_items ni
    JOIN customer_order_items coi ON coi.id = ni.order_item_id
   WHERE coi.order_id = ANY (v_orders);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 的品項被庫存減抵單指名，中止', v_no;
  END IF;

  SELECT (SELECT COUNT(*) FROM picking_wave_items WHERE campaign_id = v_id)
       + (SELECT COUNT(*) FROM purchase_request_campaigns WHERE campaign_id = v_id)
       + (SELECT COUNT(*) FROM purchase_request_items WHERE source_campaign_id = v_id)
       + (SELECT COUNT(*) FROM purchase_requests WHERE source_campaign_id = v_id)
       + (SELECT COUNT(*) FROM backorders WHERE rollover_to_campaign_id = v_id)
    INTO v_cnt;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 掛著撿貨／採購／候補連結（% 筆），中止', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM line_note_posts
   WHERE campaign_id = v_id AND line_post_id IS NOT NULL;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 有 % 篇記事本貼文後台刪得到（有 LINE 貼文 id），先到開團的記事本彈窗刪貼文再刪團',
                    v_no, v_cnt;
  END IF;

  -- ── 備份 ────────────────────────────────────────────────────────────────
  CREATE TABLE IF NOT EXISTS public._backup_20260918_deleted_campaign_028 (
    id           BIGSERIAL PRIMARY KEY,
    src_table    TEXT        NOT NULL,
    row_data     JSONB       NOT NULL,
    backed_up_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  ALTER TABLE public._backup_20260918_deleted_campaign_028 ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON public._backup_20260918_deleted_campaign_028 FROM anon, authenticated;
  REVOKE ALL ON SEQUENCE public._backup_20260918_deleted_campaign_028_id_seq FROM anon, authenticated;

  INSERT INTO public._backup_20260918_deleted_campaign_028 (src_table, row_data)
  SELECT 'group_buy_campaigns', to_jsonb(g) FROM group_buy_campaigns g WHERE g.id = v_id;

  -- 每一條指向 group_buy_campaigns / customer_orders 的 FK；CASCADE 的再往下一層
  FOR r IN
    SELECT con.conrelid AS rel, a.attname AS col, con.confdeltype AS deltype,
           con.confrelid AS parent
      FROM pg_constraint con
      JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
     WHERE con.contype = 'f'
       AND con.confrelid IN ('public.group_buy_campaigns'::regclass, 'public.customer_orders'::regclass)
       AND array_length(con.conkey, 1) = 1
  LOOP
    IF r.parent = 'public.group_buy_campaigns'::regclass THEN
      EXECUTE format(
        'INSERT INTO public._backup_20260918_deleted_campaign_028 (src_table, row_data)
         SELECT %L, to_jsonb(t) FROM %s t WHERE t.%I = $1',
        r.rel::regclass::text, r.rel::regclass, r.col) USING v_id;
    ELSE
      EXECUTE format(
        'INSERT INTO public._backup_20260918_deleted_campaign_028 (src_table, row_data)
         SELECT %L, to_jsonb(t) FROM %s t WHERE t.%I = ANY ($1)',
        r.rel::regclass::text, r.rel::regclass, r.col) USING v_orders;
    END IF;

    CONTINUE WHEN r.deltype <> 'c' OR r.rel = 'public.customer_orders'::regclass;

    FOR r2 IN
      SELECT con2.conrelid AS rel, a2.attname AS col, af.attname AS ref_col
        FROM pg_constraint con2
        JOIN pg_attribute a2 ON a2.attrelid = con2.conrelid AND a2.attnum = con2.conkey[1]
        JOIN pg_attribute af ON af.attrelid = con2.confrelid AND af.attnum = con2.confkey[1]
       WHERE con2.contype = 'f'
         AND con2.confrelid = r.rel
         AND array_length(con2.conkey, 1) = 1
    LOOP
      IF r.parent = 'public.group_buy_campaigns'::regclass THEN
        EXECUTE format(
          'INSERT INTO public._backup_20260918_deleted_campaign_028 (src_table, row_data)
           SELECT %L, to_jsonb(g) FROM %s g
            WHERE g.%I IN (SELECT x.%I FROM %s x WHERE x.%I = $1)',
          r2.rel::regclass::text, r2.rel::regclass, r2.col,
          r2.ref_col, r.rel::regclass, r.col) USING v_id;
      ELSE
        EXECUTE format(
          'INSERT INTO public._backup_20260918_deleted_campaign_028 (src_table, row_data)
           SELECT %L, to_jsonb(g) FROM %s g
            WHERE g.%I IN (SELECT x.%I FROM %s x WHERE x.%I = ANY ($1))',
          r2.rel::regclass::text, r2.rel::regclass, r2.col,
          r2.ref_col, r.rel::regclass, r.col) USING v_orders;
      END IF;
    END LOOP;
  END LOOP;

  -- ── 刪除（照 rpc_delete_store_campaign 的順序） ─────────────────────────
  ALTER TABLE campaign_audit_log       DISABLE TRIGGER trg_no_mut_camp_audit;
  ALTER TABLE customer_order_sources   DISABLE TRIGGER trg_no_mut_cos;
  ALTER TABLE customer_order_audit_log DISABLE TRIGGER trg_no_mut_coa;
  ALTER TABLE order_pickup_events      DISABLE TRIGGER trg_no_mut_pickup_ev;
  BEGIN
    DELETE FROM customer_order_sources  WHERE order_id = ANY (v_orders);
    DELETE FROM order_waitlist          WHERE promoted_order_id = ANY (v_orders);
    DELETE FROM order_expiry_events     WHERE order_id = ANY (v_orders);
    DELETE FROM order_shortage_events   WHERE order_id = ANY (v_orders);
    DELETE FROM customer_orders         WHERE id = ANY (v_orders);

    DELETE FROM campaign_audit_log     WHERE campaign_id = v_id;
    DELETE FROM customer_order_sources WHERE campaign_id = v_id AND tenant_id = v_tenant;
    DELETE FROM order_waitlist         WHERE campaign_id = v_id AND tenant_id = v_tenant;
    DELETE FROM group_buy_campaigns    WHERE id = v_id AND tenant_id = v_tenant;
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

  IF EXISTS (SELECT 1 FROM group_buy_campaigns WHERE id = v_id)
     OR EXISTS (SELECT 1 FROM customer_orders WHERE id = ANY (v_orders)) THEN
    RAISE EXCEPTION '刪除後團 % 或它的訂單還在，中止', v_no;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM public._backup_20260918_deleted_campaign_028;
  RAISE NOTICE '完成：已刪除 %（id %「%」）＋ 1 張訂單，備份 % 列', v_no, v_id, v_name, v_cnt;
END $$;

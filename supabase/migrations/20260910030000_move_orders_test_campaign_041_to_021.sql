-- ============================================================================
-- 一次性資料搬移：把測試團 GRP-20260910-041 的訂單搬到正式團 GRP-20260910-021
-- ============================================================================
-- 需求（Alex 2026-09-10）：「幫我把第一張圖的團的人轉到第二張圖」。
--   來源 GRP-20260910-041「中華一番・中式職人料理 350克+-10%test」（id 5050，
--     09-10 17:50 開的測試團，兩分鐘後整團取消 → status='cancelled'）
--   目標 GRP-20260910-021「中華一番・中式職人料理 350克+-10%」（id 5030，
--     status='open'，收單到 09-15 23:59）
-- 兩團的商品完全一樣（product_id 3746，SKU 7120 / 7141，都是 $99），
-- 差別只在來源那團是誤開的測試團。
--
-- 搬的是**同一張訂單**（UPDATE campaign_id，不是複製一張新的）：
--   customer_order_items.campaign_item_id 是 PR → campaign 的 1:1 連結，
--   複製一份會多出一張孤兒訂單、而且客人在兩團各出現一次。
--
-- 每張訂單要動的四件事：
--   1. campaign_id → 目標團
--   2. order_no    → 目標團的 campaign_no + 下一個流水號。
--      序號規則跟 rpc 一致（20260814000010：該團訂單 COUNT(*) + 1，含已取消），
--      所以搬進去佔掉 -0003 之後，下一張新單自然拿到 -0004，不會撞號。
--   3. 品項的 campaign_item_id → 目標團**同一個 sku_id** 的那一列
--      （campaign_item_id 指向來源團的列，不改的話這張單會同時掛在兩個團上，
--       v_picking_demand_by_po / v_order_shortage 之類靠它對團的地方會錯亂）
--   4. status cancelled → pending：來源單是被「整團取消」連帶取消的（單頭
--      cancelled、品項還是 pending），搬到還開著的團就要恢復成正常待處理單，
--      否則畫面上人是進去了但訂單不算數。cancelled_at 一併清掉。
--
-- 守衛（任一不成立就整支 RAISE 中止，不搬一半）：
--   - 來源／目標團必須是這兩支（campaign_no + name 都比對）、目標團必須 open
--   - 來源訂單不能沾到實體流程：庫存異動 / 調撥單 / 轉單連結 / 撿貨波次 /
--     取貨・短少・逾期事件 / 減抵單。沾到就不是純測試單，要人工處理。
--   - 每個品項的 sku_id 在目標團都要找得到對應的 campaign_items 列
--   - 目標團不能已經有同一個 (channel_id, member_id, order_kind) 的有效單
--     （customer_orders_trio_kind_active_uniq，一團一人一單）
--   - 只搬「單頭 cancelled 但還有 active 品項」或本來就 active 的單；
--     品項也一起被取消的單不搬（那是真的取消，不是被整團連坐）
--
-- 冪等：來源團已經沒有訂單就直接跳過（NOTICE）。
-- Rollback：把該張單的 campaign_id / order_no / campaign_item_id / status 改回
--   5050 / 'GRP-20260910-041-0001' / 9812 / 'cancelled'，並還原 cancelled_at。
-- ============================================================================

DO $$
DECLARE
  v_tenant   CONSTANT UUID := '00000000-0000-0000-0000-000000000001';
  v_src_no   CONSTANT TEXT := 'GRP-20260910-041';
  v_dst_no   CONSTANT TEXT := 'GRP-20260910-021';
  v_src      BIGINT;
  v_dst      BIGINT;
  v_dst_stat TEXT;
  v_seq      INT;
  v_cnt      INT;
  v_moved    INT := 0;
  v_new_no   TEXT;
  r          RECORD;
BEGIN
  SELECT id INTO v_src
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant AND campaign_no = v_src_no
     AND name = '中華一番・中式職人料理 350克+-10%test'
   FOR UPDATE;

  SELECT id, status INTO v_dst, v_dst_stat
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant AND campaign_no = v_dst_no
     AND name = '中華一番・中式職人料理 350克+-10%'
   FOR UPDATE;

  IF v_src IS NULL THEN
    RAISE NOTICE '[skip] 來源團 % 不存在（可能已刪除或改名）', v_src_no;
    RETURN;
  END IF;
  IF v_dst IS NULL THEN
    RAISE EXCEPTION '目標團 % 不存在，中止', v_dst_no;
  END IF;
  IF v_dst_stat <> 'open' THEN
    RAISE EXCEPTION '目標團 % 不是 open（現在是 %），中止', v_dst_no, v_dst_stat;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM customer_orders WHERE tenant_id = v_tenant AND campaign_id = v_src;
  IF v_cnt = 0 THEN
    RAISE NOTICE '[skip] 來源團 % 已經沒有訂單，無事可做', v_src_no;
    RETURN;
  END IF;

  -- ── 守衛 1：來源訂單不能沾到實體流程 ────────────────────────────────────
  SELECT COUNT(*) INTO v_cnt
    FROM customer_orders co
   WHERE co.tenant_id = v_tenant AND co.campaign_id = v_src
     AND (
          EXISTS (SELECT 1 FROM stock_movements sm
                   WHERE sm.source_doc_type = 'customer_order' AND sm.source_doc_id = co.id)
       OR EXISTS (SELECT 1 FROM transfers t WHERE t.customer_order_id = co.id)
       OR EXISTS (SELECT 1 FROM customer_order_transfer_links l
                   WHERE l.source_order_id = co.id OR l.dest_order_id = co.id)
       OR EXISTS (SELECT 1 FROM order_pickup_events e   WHERE e.order_id = co.id)
       OR EXISTS (SELECT 1 FROM order_shortage_events e WHERE e.order_id = co.id)
       OR EXISTS (SELECT 1 FROM order_expiry_events e   WHERE e.order_id = co.id)
       OR co.transferred_from_order_id IS NOT NULL
       OR co.transferred_to_order_id   IS NOT NULL
     );
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '來源團有 % 張訂單已經沾到庫存／調撥／轉單，不是純測試單，中止', v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM picking_wave_items WHERE campaign_id = v_src;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '來源團有 % 筆撿貨波次明細，中止', v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM inventory_deduction_notes WHERE campaign_id = v_src AND cancelled_at IS NULL;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '來源團有 % 張未取消的庫存減抵單，中止', v_cnt;
  END IF;

  -- ── 守衛 2：每個品項的 SKU 在目標團都要有對應的 campaign_items 列 ────────
  SELECT COUNT(*) INTO v_cnt
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE co.tenant_id = v_tenant AND co.campaign_id = v_src
     AND NOT EXISTS (
           SELECT 1 FROM campaign_items ci
            WHERE ci.campaign_id = v_dst AND ci.sku_id = coi.sku_id);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '有 % 個品項的 SKU 在目標團 % 找不到對應商品，中止', v_cnt, v_dst_no;
  END IF;

  -- ── 守衛 3：目標團不能已經有同一人的有效單（一團一人一單唯一索引）────────
  SELECT COUNT(*) INTO v_cnt
    FROM customer_orders s
   WHERE s.tenant_id = v_tenant AND s.campaign_id = v_src
     AND EXISTS (
           SELECT 1 FROM customer_orders d
            WHERE d.tenant_id = v_tenant AND d.campaign_id = v_dst
              AND d.channel_id = s.channel_id
              AND d.member_id  = s.member_id
              AND COALESCE(d.order_kind, 'normal') = COALESCE(s.order_kind, 'normal')
              AND d.status NOT IN ('cancelled', 'expired', 'transferred_out')
              AND d.aid_board_id IS NULL);
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '目標團 % 已經有 % 位相同會員的有效訂單，會撞一團一人一單的唯一索引，中止',
                    v_dst_no, v_cnt;
  END IF;

  -- ── 搬移 ────────────────────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_seq FROM customer_orders WHERE tenant_id = v_tenant AND campaign_id = v_dst;

  FOR r IN
    SELECT co.id, co.order_no, co.status, co.member_id, co.nickname_snapshot
      FROM customer_orders co
     WHERE co.tenant_id = v_tenant AND co.campaign_id = v_src
     ORDER BY co.created_at, co.order_no
     FOR UPDATE
  LOOP
    -- 品項全被取消的單不搬（那是真的取消，不是被整團連坐）
    IF NOT EXISTS (
      SELECT 1 FROM customer_order_items coi
       WHERE coi.order_id = r.id
         AND coi.status IN ('pending', 'reserved', 'ready')
    ) THEN
      RAISE NOTICE '[skip] 訂單 % 沒有可搬的品項（全部已取消／已取貨），留在原團', r.order_no;
      CONTINUE;
    END IF;

    v_seq    := v_seq + 1;
    v_new_no := v_dst_no || '-' || LPAD(v_seq::TEXT, 4, '0');

    -- 品項改掛目標團的同 SKU 商品列
    UPDATE customer_order_items coi
       SET campaign_item_id = ci.id
      FROM campaign_items ci
     WHERE coi.order_id = r.id
       AND ci.campaign_id = v_dst
       AND ci.sku_id = coi.sku_id
       AND coi.campaign_item_id IS DISTINCT FROM ci.id;

    UPDATE customer_orders
       SET campaign_id  = v_dst,
           order_no     = v_new_no,
           status       = CASE WHEN status = 'cancelled' THEN 'pending' ELSE status END,
           cancelled_at = CASE WHEN status = 'cancelled' THEN NULL ELSE cancelled_at END,
           notes        = TRIM(BOTH E'\n' FROM COALESCE(notes || E'\n', '')
                          || '[' || TO_CHAR(NOW() AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI')
                          || '] 由測試團 ' || v_src_no || '（原單號 ' || r.order_no
                          || '）搬移至本團'),
           updated_at   = NOW()
     WHERE id = r.id;

    v_moved := v_moved + 1;
    RAISE NOTICE '[moved] % → %（%，原狀態 %）', r.order_no, v_new_no,
                 COALESCE(r.nickname_snapshot, r.member_id::TEXT), r.status;
  END LOOP;

  RAISE NOTICE '完成：% → %，共搬移 % 張訂單', v_src_no, v_dst_no, v_moved;
END $$;

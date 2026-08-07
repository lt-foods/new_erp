-- ============================================================
-- 2026-08-07: 同店互轉（換客人）開放「貨還沒到店」的訂單
--
-- 需求：同店互轉貨還是進同一間店、不影響總倉派貨量，因此不必等
--   status='ready'。跨店轉單維持原規則（貨到店才能轉）。
--
-- 一致性配套（不改就會違反「不影響派貨量」的前提）：
--   同店預轉會把原單標成 transferred_out、生出同店的衍生單
--   (transferred_from_order_id 指向同店原單)。以下位置原本用
--   `transferred_from_order_id IS NULL` 一刀排除所有衍生單，會讓
--   「原單排除＋衍生單也排除」→ 該店需求憑空消失、派貨/缺貨全失真。
--   一律改成「排除跨店衍生單、保留同店衍生單」：
--     1. v_picking_demand_by_po.campaign_demand（派貨工作台需求）
--     2. rpc_create_wave_from_po 第 6 步 campaign 解析守衛
--     3. v_order_shortage（需求彙總＋末端展開，共 2 處）
--     4. rpc_get_allocation_candidates.rows_all（少發配貨候選）
--     5. rpc_allocate_shortage 未配到標待補貨的掃描
--   同店衍生單的到貨推進不用改：rpc_mark_orders_shipping_for_wave 本來就
--   不排除衍生單（同 campaign＋同店就推 shipping）；is_order_item_pickup_ready
--   對「aid_transfer＋同店」走 Path B（同團波次到店即算），鏈路完整。
--
-- 同店預轉的排除名單（見 gate 內註解）：非 normal 單、有進行中調撥 FK
--   的單、自己是跨店轉入未到貨的單 — 這三種的到貨推進綁原單 id/order_no，
--   轉走會讓新單永遠等不到貨。
--
-- 另補：rpc_transfer_order_partial 補上「轉給自己」守衛（整單版
--   20260806000010 已有，partial 一直沒有；同店互轉後這個誤操作變容易）。
--
-- 基底版本：全部物件以 2026-08-07 線上 DB 現行定義為基底
--   （pg_get_functiondef / pg_get_viewdef 逐字取回）。注意兩處 repo 與
--   線上的既有 drift，本檔一併以線上為準收錄：
--   - v_order_shortage 線上 = 20260801000000_po_item_stockout 分支
--     （含 stockout_at 閘），不是 20260801000000_v_order_shortage_v4_forward_looking
--     （hq_on_hand/xfer_in_transit 版，線上並未部署）。
--   - rpc_create_wave_from_po 線上比 20260715000010 多一段「補貨分配
--     不可超過剩餘補貨需求」守衛（線上 hotfix，repo 原本沒有）。
-- Rollback：各物件 CREATE OR REPLACE 回本檔內文（把新增條件/分支移除
--   即為線上前一版；transfer gate 還原為單一 status='ready' 檢查）。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_transfer_order_to_store：同店互轉開放 pre-ready
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_transfer_order_to_store(p_order_id bigint, p_to_pickup_store_id bigint, p_to_member_id bigint, p_to_channel_id bigint, p_operator uuid, p_reason text DEFAULT NULL::text, p_is_air_transfer boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_orig             customer_orders%ROWTYPE;
  v_tenant_id        UUID;
  v_to_member_id     BIGINT;
  v_to_channel_id    BIGINT;
  v_new_order_id     BIGINT;
  v_new_order_no     TEXT;
  v_seq              INT;
  v_campaign_no      TEXT;
  v_item             RECORD;
  v_orig_mov         RECORD;
  v_rev_id           BIGINT;
  v_now              TIMESTAMPTZ := NOW();
  v_note_out         TEXT;
  v_note_in          TEXT;
  v_new_status       TEXT;
  v_src_is_internal  BOOLEAN := FALSE;
  v_dst_is_internal  BOOLEAN := FALSE;
  v_dup_order_id     BIGINT;
  v_dup_order_no     TEXT;
  v_appended         BOOLEAN := FALSE;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 #%', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  -- 跨店轉單維持「貨到店 (status='ready') 才能轉」；
  -- 同店互轉（換客人）貨進同一間店、不影響總倉派貨量，到貨前也可轉。
  -- 同店預轉仍排除三種「貨不走本店波次」的單（轉走會斷到貨推進鏈）：
  --   a. 非一般團購單（restock ride-along 靠 order_no='RR-x' 特判推 ready、offset 無實貨）
  --   b. 有進行中的調撥 FK 指著它（互助/空中轉/補貨直派 → 到貨判定綁原單 id）
  --   c. 自己就是跨店轉入、貨還沒到的單（到貨判定同樣綁 transfer FK）
  IF v_orig.status <> 'ready' THEN
    IF p_to_pickup_store_id <> v_orig.pickup_store_id THEN
      RAISE EXCEPTION '貨還沒到分店、訂單 % 不可跨店轉單 (status=%)；同店換客人不受此限',
                      p_order_id, v_orig.status;
    END IF;
    IF v_orig.status NOT IN ('pending','confirmed','reserved','shipping') THEN
      RAISE EXCEPTION '訂單 % 狀態（%）不可轉單', p_order_id, v_orig.status;
    END IF;
    IF COALESCE(v_orig.order_kind, 'normal') <> 'normal' THEN
      RAISE EXCEPTION '訂單 % 不是一般團購單（%），須等分店收貨後再轉單',
                      p_order_id, v_orig.order_kind;
    END IF;
    IF EXISTS (SELECT 1 FROM transfers t
                WHERE t.customer_order_id = p_order_id
                  AND t.tenant_id = v_tenant_id
                  AND t.status <> 'cancelled') THEN
      RAISE EXCEPTION '訂單 % 有進行中的調撥，請等分店收貨後再轉單', p_order_id;
    END IF;
    IF v_orig.transferred_from_order_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM customer_orders src
          WHERE src.id = v_orig.transferred_from_order_id
            AND src.pickup_store_id IS DISTINCT FROM v_orig.pickup_store_id) THEN
      RAISE EXCEPTION '訂單 % 是跨店轉入、貨還沒到，請等分店收貨後再轉單', p_order_id;
    END IF;
  END IF;

  IF v_orig.transferred_to_order_id IS NOT NULL THEN
    RAISE EXCEPTION '訂單 #% 已轉出至訂單 #%，不可重複轉出',
                    p_order_id, v_orig.transferred_to_order_id;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_to_pickup_store_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收店（ID %）不存在或不屬於目前商戶', p_to_pickup_store_id;
  END IF;

  v_to_member_id := COALESCE(
    p_to_member_id,
    rpc_get_or_create_store_member(p_to_pickup_store_id, p_operator)
  );

  PERFORM 1 FROM members WHERE id = v_to_member_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收會員（ID %）不存在或不屬於目前商戶', v_to_member_id;
  END IF;

  -- 內部單（【內部】xx店）轉給真會員 = 門市現貨銷售 → 轉出價改鎖現售價。
  -- 店↔店互助（目標也是 store_internal）維持原價不變。（同 20260714000090 partial 版規則）
  SELECT (m.member_type = 'store_internal') INTO v_src_is_internal
    FROM members m WHERE m.id = v_orig.member_id;
  v_src_is_internal := COALESCE(v_src_is_internal, FALSE);
  SELECT (m.member_type = 'store_internal') INTO v_dst_is_internal
    FROM members m WHERE m.id = v_to_member_id;
  v_dst_is_internal := COALESCE(v_dst_is_internal, FALSE);

  v_to_channel_id := p_to_channel_id;
  IF v_to_channel_id IS NULL THEN
    SELECT id INTO v_to_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id AND home_store_id = p_to_pickup_store_id
     LIMIT 1;
    IF v_to_channel_id IS NULL THEN
      SELECT id INTO v_to_channel_id
        FROM line_channels
       WHERE tenant_id = v_tenant_id
       LIMIT 1;
    END IF;
  END IF;
  IF v_to_channel_id IS NULL THEN
    RAISE EXCEPTION '接收店找不到可用的 LINE 頻道，無法建立轉入訂單';
  END IF;

  PERFORM 1 FROM line_channels
   WHERE id = v_to_channel_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'LINE 頻道（ID %）不屬於目前商戶', v_to_channel_id;
  END IF;

  -- 接收人在同一檔活動已有 active 單（對齊 customer_orders_trio_kind_active_uniq）
  -- → 不再擋下，改為「併入該張既有訂單」（與 rpc_transfer_order_partial 同語意）。
  SELECT id, order_no INTO v_dup_order_id, v_dup_order_no
    FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = v_orig.campaign_id
     AND channel_id  = v_to_channel_id
     AND member_id   = v_to_member_id
     AND status NOT IN ('transferred_out', 'expired', 'cancelled')
   LIMIT 1;

  -- 查到的既有單 = 來源單本身（轉給自己）→ 擋下，否則會把訂單併進它自己
  IF v_dup_order_id = p_order_id THEN
    RAISE EXCEPTION '這張訂單本來就掛在該接收人（同活動、同頻道）名下，不需要轉出';
  END IF;

  -- E2: 釋放 reserved_movement（無條件、跟以前一致；同店也走這條）
  FOR v_item IN
    SELECT id, reserved_movement_id FROM customer_order_items
     WHERE order_id = p_order_id AND reserved_movement_id IS NOT NULL
  LOOP
    SELECT * INTO v_orig_mov FROM stock_movements WHERE id = v_item.reserved_movement_id;
    IF FOUND THEN
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, reverses, reason, operator_id
      ) VALUES (
        v_orig_mov.tenant_id, v_orig_mov.location_id, v_orig_mov.sku_id,
        -v_orig_mov.quantity, v_orig_mov.unit_cost, 'reversal',
        'order_transfer', p_order_id, v_orig_mov.id,
        'order #' || p_order_id || ' transferred out, release allocation', p_operator
      ) RETURNING id INTO v_rev_id;

      UPDATE stock_movements SET reversed_by = v_rev_id WHERE id = v_orig_mov.id;
      UPDATE customer_order_items SET reserved_movement_id = NULL WHERE id = v_item.id;
    END IF;
  END LOOP;

  IF v_dup_order_id IS NOT NULL THEN
    -- 併入既有單：不另建新單、不改既有單 status / pickup_store / is_air_transfer
    -- （與 partial 追加分支一致；notes 格式同 partial 的「追加轉入」）
    v_appended     := TRUE;
    v_new_order_id := v_dup_order_id;
    v_new_order_no := v_dup_order_no;
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[追加轉入 (' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
                   ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') ||
                   COALESCE(' / ' || p_reason, ''),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_new_order_id;
  ELSE
    SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id AND campaign_id = v_orig.campaign_id;
    v_new_order_no := v_campaign_no || '-TF' || lpad(v_seq::text, 4, '0');

    v_note_in := COALESCE(p_reason, '') ||
                 E'\n[轉入 (' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
                 ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
                 to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

    -- 同店：mirror source.status；跨店空中轉：直接 confirmed（略過總倉確認 gate）；
    -- 跨店經總倉：'pending'（維持總倉確認 gate）
    v_new_status := CASE
      WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN v_orig.status
      WHEN p_is_air_transfer THEN 'confirmed'
      ELSE 'pending'
    END;

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, notes,
      transferred_from_order_id, is_air_transfer,
      created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
      v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status, v_note_in,
      p_order_id, p_is_air_transfer,
      p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_new_order_id;
  END IF;

  -- 內部單 → 真會員：轉出價鎖定當下 SKU 現售價（scope='retail' 最新生效版）；
  -- 查無現售價 fallback 來源價。其餘情境維持原價。
  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by
  )
  SELECT coi.tenant_id, v_new_order_id, coi.campaign_item_id, coi.sku_id, coi.qty,
         CASE WHEN v_src_is_internal AND NOT v_dst_is_internal
              THEN COALESCE(pr.price, coi.unit_price)
              ELSE coi.unit_price
         END,
         'pending', 'aid_transfer', coi.notes, p_operator, p_operator
    FROM customer_order_items coi
    LEFT JOIN LATERAL (
      SELECT p2.price
        FROM prices p2
       WHERE v_src_is_internal AND NOT v_dst_is_internal
         AND p2.tenant_id = v_tenant_id
         AND p2.sku_id    = coi.sku_id
         AND p2.scope     = 'retail'
         AND p2.effective_from <= v_now
         AND (p2.effective_to IS NULL OR p2.effective_to > v_now)
       ORDER BY p2.effective_from DESC
       LIMIT 1
    ) pr ON TRUE
   WHERE coi.order_id = p_order_id;

  v_note_out := COALESCE(p_reason, '') ||
                E'\n[轉出' || CASE WHEN v_appended THEN '（併入既有單）' ELSE '' END ||
                ' → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

  UPDATE customer_orders
     SET status                   = 'transferred_out',
         transferred_to_order_id  = v_new_order_id,
         notes                    = COALESCE(notes, '') || v_note_out,
         updated_by               = p_operator,
         updated_at               = v_now
   WHERE id = p_order_id;

  -- 併入的既有單若已 completed → 重開，否則追加品項會變幽靈：
  -- 待取清單看不到、is_order_item_pickup_ready 也擋著不給取（見 20260805000140）
  IF v_appended THEN
    PERFORM public._reopen_order_if_completed(
      v_new_order_id, p_operator,
      '追加轉入 ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')');
  END IF;

  RETURN v_new_order_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_transfer_order_to_store(
  BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, BOOLEAN
) TO authenticated;

COMMENT ON FUNCTION public.rpc_transfer_order_to_store(
  BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, BOOLEAN
) IS
  '整單轉出：跨店需 status=ready；同店互轉（換客人）pending/confirmed/reserved/shipping 也可轉，'
  '但排除非 normal 單、有進行中調撥、跨店轉入未到貨單。接收人已有 active 單則併入（completed 會重開）。'
  '跨店空中轉建 confirmed、經總倉建 pending、同店 mirror 原單 status。'
  '內部單轉真會員鎖現售價。錯誤訊息繁體中文。基底 20260806000010（線上版）。';

-- ----------------------------------------------------------------
-- 2. rpc_transfer_order_partial：同店互轉開放 pre-ready ＋ 轉給自己守衛
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_transfer_order_partial(p_order_id bigint, p_to_pickup_store_id bigint, p_to_member_id bigint, p_to_channel_id bigint, p_operator uuid, p_reason text, p_items jsonb, p_is_air_transfer boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_orig             customer_orders%ROWTYPE;
  v_tenant_id        UUID;
  v_to_member_id     BIGINT;
  v_to_channel_id    BIGINT;
  v_new_order_id     BIGINT;
  v_new_order_no     TEXT;
  v_seq              INT;
  v_campaign_no      TEXT;
  v_p_item           JSONB;
  v_p_sku_id         BIGINT;
  v_p_qty            NUMERIC;
  v_src_item_id      BIGINT;
  v_src_item_qty     NUMERIC;
  v_src_item_ci      BIGINT;
  v_src_item_price   NUMERIC;
  v_src_item_reserved BIGINT;
  v_remaining_count  INT;
  v_now              TIMESTAMPTZ := NOW();
  v_existing_order   BIGINT;
  v_appended         BOOLEAN := FALSE;
  v_new_status       TEXT;
  v_src_is_internal  BOOLEAN := FALSE;
  v_dst_is_internal  BOOLEAN := FALSE;
  v_retail_price     NUMERIC;
  v_item_price       NUMERIC;
  v_reopened         TEXT;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION '未指定任何要轉移的品項';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 #%', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  -- 跨店轉單維持「貨到店 (status='ready') 才能轉」；
  -- 同店互轉（換客人）貨進同一間店、不影響總倉派貨量，到貨前也可轉。
  -- 同店預轉仍排除三種「貨不走本店波次」的單（轉走會斷到貨推進鏈）：
  --   a. 非一般團購單（restock ride-along 靠 order_no='RR-x' 特判推 ready、offset 無實貨）
  --   b. 有進行中的調撥 FK 指著它（互助/空中轉/補貨直派 → 到貨判定綁原單 id）
  --   c. 自己就是跨店轉入、貨還沒到的單（到貨判定同樣綁 transfer FK）
  IF v_orig.status <> 'ready' THEN
    IF p_to_pickup_store_id <> v_orig.pickup_store_id THEN
      RAISE EXCEPTION '貨還沒到分店、訂單 % 不可跨店轉單 (status=%)；同店換客人不受此限',
                      p_order_id, v_orig.status;
    END IF;
    IF v_orig.status NOT IN ('pending','confirmed','reserved','shipping') THEN
      RAISE EXCEPTION '訂單 % 狀態（%）不可轉單', p_order_id, v_orig.status;
    END IF;
    IF COALESCE(v_orig.order_kind, 'normal') <> 'normal' THEN
      RAISE EXCEPTION '訂單 % 不是一般團購單（%），須等分店收貨後再轉單',
                      p_order_id, v_orig.order_kind;
    END IF;
    IF EXISTS (SELECT 1 FROM transfers t
                WHERE t.customer_order_id = p_order_id
                  AND t.tenant_id = v_tenant_id
                  AND t.status <> 'cancelled') THEN
      RAISE EXCEPTION '訂單 % 有進行中的調撥，請等分店收貨後再轉單', p_order_id;
    END IF;
    IF v_orig.transferred_from_order_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM customer_orders src
          WHERE src.id = v_orig.transferred_from_order_id
            AND src.pickup_store_id IS DISTINCT FROM v_orig.pickup_store_id) THEN
      RAISE EXCEPTION '訂單 % 是跨店轉入、貨還沒到，請等分店收貨後再轉單', p_order_id;
    END IF;
  END IF;

  IF v_orig.transferred_to_order_id IS NOT NULL THEN
    RAISE EXCEPTION '訂單 #% 已轉出至訂單 #%，不可重複轉出',
                    p_order_id, v_orig.transferred_to_order_id;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_to_pickup_store_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收店（ID %）不存在或不屬於目前商戶', p_to_pickup_store_id;
  END IF;

  v_to_member_id := COALESCE(
    p_to_member_id,
    rpc_get_or_create_store_member(p_to_pickup_store_id, p_operator)
  );

  PERFORM 1 FROM members WHERE id = v_to_member_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '接收會員（ID %）不存在或不屬於目前商戶', v_to_member_id;
  END IF;

  -- 內部單（【內部】xx店）轉給真會員 = 門市現貨銷售 → 轉出價改鎖現售價。
  -- 店↔店互助（目標也是 store_internal）維持原價不變。
  SELECT (m.member_type = 'store_internal') INTO v_src_is_internal
    FROM members m WHERE m.id = v_orig.member_id;
  v_src_is_internal := COALESCE(v_src_is_internal, FALSE);
  SELECT (m.member_type = 'store_internal') INTO v_dst_is_internal
    FROM members m WHERE m.id = v_to_member_id;
  v_dst_is_internal := COALESCE(v_dst_is_internal, FALSE);

  v_to_channel_id := p_to_channel_id;
  IF v_to_channel_id IS NULL THEN
    SELECT id INTO v_to_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id AND home_store_id = p_to_pickup_store_id
     LIMIT 1;
    IF v_to_channel_id IS NULL THEN
      SELECT id INTO v_to_channel_id
        FROM line_channels
       WHERE tenant_id = v_tenant_id
       LIMIT 1;
    END IF;
  END IF;
  IF v_to_channel_id IS NULL THEN
    RAISE EXCEPTION '接收店找不到可用的 LINE 頻道，無法建立轉入訂單';
  END IF;

  SELECT id INTO v_existing_order
    FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = v_orig.campaign_id
     AND channel_id  = v_to_channel_id
     AND member_id   = v_to_member_id
     AND status NOT IN ('expired','cancelled','transferred_out');

  -- 查到的既有單 = 來源單本身（同活動＋同頻道＋同會員轉給自己）→ 擋下，
  -- 否則會把品項「轉進」它自己（同 20260806000010 對整單轉的守衛）
  IF v_existing_order = p_order_id THEN
    RAISE EXCEPTION '這張訂單本來就掛在該接收人（同活動、同頻道）名下，不需要轉出';
  END IF;

  IF v_existing_order IS NOT NULL THEN
    v_new_order_id := v_existing_order;
    v_appended := TRUE;
    SELECT order_no INTO v_new_order_no FROM customer_orders WHERE id = v_existing_order;
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[追加轉入 (' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
                   ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') ||
                   COALESCE(' / ' || p_reason, ''),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_new_order_id;
  ELSE
    SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id AND campaign_id = v_orig.campaign_id;
    v_new_order_no := v_campaign_no || '-TF' || lpad(v_seq::text, 4, '0');

    -- 同店：mirror source.status；跨店空中轉：直接 confirmed（略過總倉確認 gate）；
    -- 跨店經總倉：'pending'（維持總倉確認 gate）
    v_new_status := CASE
      WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN v_orig.status
      WHEN p_is_air_transfer THEN 'confirmed'
      ELSE 'pending'
    END;

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, notes,
      transferred_from_order_id, is_air_transfer,
      created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
      v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status,
      COALESCE(p_reason, '') ||
        E'\n[轉入 (部分, ' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
        ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
        to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
      p_order_id, p_is_air_transfer,
      p_operator, p_operator, v_now, v_now
    ) RETURNING id INTO v_new_order_id;
  END IF;

  FOR v_p_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_p_sku_id := (v_p_item ->> 'sku_id')::BIGINT;
    v_p_qty    := (v_p_item ->> 'qty')::NUMERIC;
    IF v_p_qty IS NULL OR v_p_qty <= 0 THEN
      RAISE EXCEPTION '轉移數量必須大於 0';
    END IF;

    SELECT id, qty, campaign_item_id, unit_price, reserved_movement_id
      INTO v_src_item_id, v_src_item_qty, v_src_item_ci, v_src_item_price, v_src_item_reserved
      FROM customer_order_items
     WHERE order_id = p_order_id
       AND sku_id   = v_p_sku_id
       AND status   != 'cancelled'
     ORDER BY id
     LIMIT 1
     FOR UPDATE;
    IF v_src_item_id IS NULL THEN
      RAISE EXCEPTION 'SKU % 不在訂單 #% 內（或品項已取消），無法轉移', v_p_sku_id, p_order_id;
    END IF;
    IF v_src_item_reserved IS NOT NULL THEN
      RAISE EXCEPTION 'SKU % 已有庫存配貨紀錄（#%），請先釋放配貨再轉移',
                      v_p_sku_id, v_src_item_reserved;
    END IF;
    IF v_src_item_qty < v_p_qty THEN
      RAISE EXCEPTION 'SKU % 可轉數量不足：來源剩 %、要求轉出 %',
                      v_p_sku_id, v_src_item_qty, v_p_qty;
    END IF;

    -- 內部單 → 真會員：轉出價鎖定當下 SKU 現售價（scope='retail' 最新生效版）；
    -- 查無現售價 fallback 來源價。其餘情境維持原價。
    v_item_price := v_src_item_price;
    IF v_src_is_internal AND NOT v_dst_is_internal THEN
      SELECT price INTO v_retail_price
        FROM prices
       WHERE tenant_id = v_tenant_id
         AND sku_id    = v_p_sku_id
         AND scope     = 'retail'
         AND effective_from <= v_now
         AND (effective_to IS NULL OR effective_to > v_now)
       ORDER BY effective_from DESC
       LIMIT 1;
      v_item_price := COALESCE(v_retail_price, v_src_item_price);
    END IF;

    IF v_src_item_qty = v_p_qty THEN
      UPDATE customer_order_items
         SET status = 'cancelled', updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    ELSE
      UPDATE customer_order_items
         SET qty = qty - v_p_qty, updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_new_order_id, v_src_item_ci, v_p_sku_id, v_p_qty, v_item_price,
      'pending', 'aid_transfer', p_operator, p_operator
    );
  END LOOP;

  SELECT COUNT(*) INTO v_remaining_count
    FROM customer_order_items
   WHERE order_id = p_order_id AND status != 'cancelled';

  IF v_remaining_count = 0 THEN
    UPDATE customer_orders
       SET status = 'transferred_out',
           transferred_to_order_id = v_new_order_id,
           notes = COALESCE(notes, '') ||
                   E'\n[全部轉出 → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  ELSE
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[' || CASE WHEN v_appended THEN '部分追加' ELSE '部分轉出' END ||
                   ' → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  END IF;

  -- 追加到「已取貨完成」的既有單時，把它重開 —— 否則新品項會被埋在 completed
  -- 單裡：待取清單看不到、is_order_item_pickup_ready 也擋著不給取（見 20260805000140）。
  IF v_appended THEN
    v_reopened := public._reopen_order_if_completed(
      v_new_order_id, p_operator,
      '追加轉入 ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')');
  END IF;

  RETURN v_new_order_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_transfer_order_partial(
  BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN
) TO authenticated;

COMMENT ON FUNCTION public.rpc_transfer_order_partial(
  BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN
) IS
  '部分轉出：跨店需 status=ready；同店互轉（換客人）pending/confirmed/reserved/shipping 也可轉，'
  '排除名單同整單版。新增「轉給自己」守衛。追加到既有 active 單不改其 status（completed 會重開）。'
  '錯誤訊息繁體中文。基底 20260806000000（線上版）。';

-- ----------------------------------------------------------------
-- 3. v_picking_demand_by_po：同店衍生單算需求（跨店衍生單維持排除）
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_picking_demand_by_po AS
 WITH po_skus AS (
         SELECT po.id AS po_id,
            po.tenant_id,
            po.po_no,
            po.status AS po_status,
            po.supplier_id,
            poi.id AS po_item_id,
            poi.sku_id,
            poi.qty_ordered,
            (EXISTS ( SELECT 1
                   FROM purchase_request_items pri2
                     JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
                  WHERE pri2.po_item_id = poi.id)) AS is_restock_sourced
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text])
        ), gr_qty AS (
         SELECT gri.po_item_id,
            sum(gri.qty_received) AS gr_qty
           FROM goods_receipt_items gri
             JOIN goods_receipts gr ON gr.id = gri.gr_id
          WHERE gr.status = 'confirmed'::text
          GROUP BY gri.po_item_id
        ), po_campaigns AS (
         SELECT DISTINCT u.po_item_id,
            u.campaign_id
           FROM ( SELECT poi.id AS po_item_id,
                    prc.campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                     JOIN purchase_requests pr ON pr.id = pri.pr_id
                     JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
                UNION
                 SELECT poi.id AS po_item_id,
                    pri.source_campaign_id AS campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                  WHERE pri.source_campaign_id IS NOT NULL) u
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR EXISTS ( SELECT 1
                    FROM customer_orders src
                   WHERE src.id = co.transferred_from_order_id
                     AND src.pickup_store_id = co.pickup_store_id))
             JOIN customer_order_items coi ON coi.order_id = co.id AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
             JOIN purchase_order_items poi ON poi.id = pc.po_item_id AND poi.sku_id = coi.sku_id
          GROUP BY pc.po_item_id, co.pickup_store_id
        ), restock_demand AS (
         SELECT poi.id AS po_item_id,
            rr.requesting_store_id AS store_id,
            sum(rrl.qty) AS demand_qty
           FROM purchase_order_items poi
             JOIN purchase_request_items pri ON pri.po_item_id = poi.id
             JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id AND (rr.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text]))
             JOIN restock_request_lines rrl ON rrl.request_id = rr.id AND rrl.sku_id = poi.sku_id
          GROUP BY poi.id, rr.requesting_store_id
        ), store_demand AS (
         SELECT u.po_item_id,
            u.store_id,
            sum(u.demand_qty) AS demand_qty
           FROM ( SELECT campaign_demand.po_item_id,
                    campaign_demand.store_id,
                    campaign_demand.demand_qty
                   FROM campaign_demand
                UNION ALL
                 SELECT restock_demand.po_item_id,
                    restock_demand.store_id,
                    restock_demand.demand_qty
                   FROM restock_demand) u
          GROUP BY u.po_item_id, u.store_id
        ), wave_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty) AS wave_qty
           FROM ( SELECT pw.source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_requested
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        ), po_sku_already_wave AS (
         SELECT u.po_id,
            u.sku_id,
            sum(u.qty) AS already_wave
           FROM ( SELECT pw.source_po_id AS po_id,
                    pwi.sku_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id,
                    ti.sku_id,
                    ti.qty_requested AS qty
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text) u
          GROUP BY u.po_id, u.sku_id
        ), po_sku_demand_left AS (
         SELECT ps_1.po_id,
            ps_1.sku_id,
            sum(GREATEST(0::numeric, COALESCE(sd_1.demand_qty, 0::numeric) - COALESCE(wq_1.wave_qty, 0::numeric))) AS demand_left
           FROM po_skus ps_1
             JOIN store_demand sd_1 ON sd_1.po_item_id = ps_1.po_item_id
             LEFT JOIN wave_qty wq_1 ON wq_1.source_po_id = ps_1.po_id AND wq_1.sku_id = ps_1.sku_id AND wq_1.store_id = sd_1.store_id
          GROUP BY ps_1.po_id, ps_1.sku_id
        ), shipped_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty_received) AS shipped_qty
           FROM ( SELECT pw.source_po_id,
                    ti.sku_id,
                    "substring"(t.transfer_no, 'WAVE-\d+-S(\d+)'::text)::bigint AS store_id,
                    ti.qty_received
                   FROM transfers t
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN picking_waves pw ON t.transfer_no ~~ (('WAVE-'::text || pw.id) || '-S%'::text)
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text])) AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_received
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text]))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        )
 SELECT ps.tenant_id,
    ps.po_id,
    ps.po_no,
    ps.po_status,
    ps.supplier_id,
    ps.po_item_id,
    ps.sku_id,
    s.sku_code,
    COALESCE(s.product_name, ''::text) || COALESCE(' '::text || NULLIF(s.variant_name, ''::text), ''::text) AS sku_label,
    ps.qty_ordered,
    COALESCE(g.gr_qty, 0::numeric) AS gr_qty,
        CASE
            WHEN ps.po_status <> 'fully_received'::text THEN GREATEST(0::numeric, ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric))
            ELSE 0::numeric
        END AS qty_in_transit,
        CASE
            WHEN ps.po_status = 'fully_received'::text AND COALESCE(g.gr_qty, 0::numeric) < ps.qty_ordered THEN ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric)
            ELSE 0::numeric
        END AS qty_shortage,
    sd.store_id,
    st.code AS store_code,
    st.name AS store_name,
    COALESCE(sd.demand_qty, 0::numeric) AS demand_qty,
    COALESCE(wq.wave_qty, 0::numeric) AS wave_qty,
    COALESCE(sq.shipped_qty, 0::numeric) AS shipped_qty,
    ps.is_restock_sourced,
    COALESCE(psaw.already_wave, 0::numeric) AS po_sku_already_wave,
    COALESCE(g.gr_qty, 0::numeric) > COALESCE(psaw.already_wave, 0::numeric) AS has_stock_left,
    COALESCE(dl.demand_left, 0::numeric) > 0::numeric AS has_demand_left
   FROM po_skus ps
     JOIN skus s ON s.id = ps.sku_id
     LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
     LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
     LEFT JOIN stores st ON st.id = sd.store_id
     LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
     LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
     LEFT JOIN po_sku_already_wave psaw ON psaw.po_id = ps.po_id AND psaw.sku_id = ps.sku_id
     LEFT JOIN po_sku_demand_left dl ON dl.po_id = ps.po_id AND dl.sku_id = ps.sku_id
  WHERE COALESCE(sq.shipped_qty, 0::numeric) < GREATEST(COALESCE(g.gr_qty, 0::numeric), 1::numeric) AND (COALESCE(g.gr_qty, 0::numeric) > 0::numeric OR COALESCE(sd.demand_qty, 0::numeric) > 0::numeric);

GRANT SELECT ON public.v_picking_demand_by_po TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖：PO × SKU × store 矩陣。campaign_demand 排除「跨店」衍生單'
  '（貨走 transfer 路徑）、保留「同店」衍生單（同店互轉不減需求）。'
  'po_sku_already_wave/wave_qty/has_stock_left/has_demand_left 語意同 20260715000010。';

-- ----------------------------------------------------------------
-- 4. rpc_create_wave_from_po：campaign 解析守衛同步（同店衍生單算需求）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_wave_from_po(p_po_id bigint, p_wave_date date, p_allocations jsonb, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_po                purchase_orders%ROWTYPE;
  v_tenant            UUID;
  v_wave_id           BIGINT;
  v_wave_code         TEXT;
  v_alloc             JSONB;
  v_sku_id            BIGINT;
  v_store_id          BIGINT;
  v_qty               NUMERIC(18,3);
  v_line_campaign_id  BIGINT;
  v_total_qty         NUMERIC(18,3) := 0;
  v_item_count        INTEGER := 0;
  v_store_count       INTEGER := 0;
  v_over              RECORD;
  v_restock_demand    NUMERIC;
  v_restock_dispatched NUMERIC;
  v_restock_left      NUMERIC;
BEGIN
  -- 1. PO 守衛
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;
  IF v_po.status NOT IN ('sent','partially_received','fully_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可建撿貨單（需為「已發送」/「部分進貨」/「全部進貨」）', v_po.po_no, v_po.status;
  END IF;
  v_tenant := v_po.tenant_id;

  -- 2. allocations 守衛
  IF p_allocations IS NULL OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION '請先填寫各分店分配量、不可全為空';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('wave:po:' || p_po_id::text));

  -- 3. 守衛：每個分配 qty > 0
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_qty := (v_alloc->>'qty')::NUMERIC;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '分配數量必須 > 0';
    END IF;
  END LOOP;

  -- 4. 守衛：每 sku 的總分配量 ≤ (GR 量 − 已派量)
  --    已派量 = picking_wave_items ＋ 補貨直派 transfer（linked_transfer_id 路徑），
  --    與 v_picking_demand_by_po.po_sku_already_wave 對齊。
  WITH alloc_agg AS (
    SELECT
      (a->>'sku_id')::BIGINT  AS sku_id,
      SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  po_sku_state AS (
    SELECT
      poi.sku_id,
      COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status = 'confirmed'), 0) AS gr_qty,
      COALESCE((
        SELECT SUM(pwi.qty)
          FROM picking_wave_items pwi
          JOIN picking_waves pw ON pw.id = pwi.wave_id
         WHERE pw.source_po_id = p_po_id
           AND pwi.sku_id = poi.sku_id
           AND pw.status <> 'cancelled'
      ), 0)
      + COALESCE((
        SELECT SUM(ti.qty_requested)
          FROM restock_requests rr
          JOIN transfers t ON t.id = rr.linked_transfer_id
          JOIN transfer_items ti ON ti.transfer_id = t.id
          JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
          JOIN purchase_order_items poi2 ON poi2.id = pri.po_item_id AND poi2.sku_id = ti.sku_id
         WHERE poi2.po_id = p_po_id
           AND poi2.sku_id = poi.sku_id
           AND t.transfer_type = 'hq_to_store'
           AND t.status <> 'cancelled'
      ), 0) AS already_wave
    FROM purchase_order_items poi
    LEFT JOIN goods_receipt_items gri ON gri.po_item_id = poi.id
    LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id
    WHERE poi.po_id = p_po_id
    GROUP BY poi.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
    aa.total_alloc, ps.gr_qty, ps.already_wave,
    (ps.gr_qty - ps.already_wave) AS available
  INTO v_over
  FROM alloc_agg aa
  JOIN po_sku_state ps ON ps.sku_id = aa.sku_id
  JOIN skus s ON s.id = aa.sku_id
  WHERE aa.total_alloc > (ps.gr_qty - ps.already_wave)
  LIMIT 1;

  IF v_over.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」分配 % 超過可分配量 %（進貨 %、已派 %，含撿貨單與補貨直派）',
      v_over.sku_code, v_over.sku_label,
      v_over.total_alloc, v_over.available, v_over.gr_qty, v_over.already_wave;
  END IF;

  -- 5. wave header — 用 sequence 產 code,避免同秒撞單
  v_wave_code := 'WV'
              || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYMMDD')
              || LPAD(nextval('public.picking_wave_code_seq')::TEXT, 6, '0');

  INSERT INTO picking_waves (
    tenant_id, wave_code, wave_date, status, source_po_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_wave_code, p_wave_date, 'draft', p_po_id,
    p_operator, p_operator
  ) RETURNING id INTO v_wave_id;

  -- 6 + 7. 逐 (sku, store) 解析「實際有需求的那一團」當 campaign_id，並擋跨團誤撿
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_sku_id   := (v_alloc->>'sku_id')::BIGINT;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    v_qty      := (v_alloc->>'qty')::NUMERIC;

    -- 在「此 PO 對應的開團」裡，挑對該 (store, sku) 確實有訂單需求的一團。
    -- 涵蓋兩條 PO→campaign 路徑（purchase_request_campaigns 與 source_campaign_id），
    -- 與 v_picking_demand_by_po 的 po_campaigns 對齊。
    SELECT cand.campaign_id
      INTO v_line_campaign_id
      FROM (
        SELECT prc.campaign_id
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
         WHERE poi.po_id = p_po_id
        UNION
        SELECT pri.source_campaign_id AS campaign_id
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
         WHERE poi.po_id = p_po_id
           AND pri.source_campaign_id IS NOT NULL
      ) cand
     WHERE EXISTS (
       SELECT 1
         FROM customer_orders co
         JOIN customer_order_items coi ON coi.order_id = co.id
        WHERE co.campaign_id = cand.campaign_id
          AND co.pickup_store_id = v_store_id
          AND co.status NOT IN ('cancelled','expired','transferred_out')
          AND (co.transferred_from_order_id IS NULL OR EXISTS (
                SELECT 1 FROM customer_orders src
                 WHERE src.id = co.transferred_from_order_id
                   AND src.pickup_store_id = co.pickup_store_id))
          AND coi.sku_id = v_sku_id
          AND coi.status NOT IN ('cancelled','expired')
     )
     ORDER BY cand.campaign_id
     LIMIT 1;

    IF v_line_campaign_id IS NULL THEN
      -- 此 (store, sku) 在這張 PO 的開團都沒有需求。
      -- 只有「補貨 (restock) 來源」才允許（campaign_id 掛 NULL，沿用既有行為）。
      IF NOT EXISTS (
        SELECT 1
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                  AND rr.requesting_store_id = v_store_id
                                  AND rr.status NOT IN ('cancelled','rejected')
          JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                        AND rrl.sku_id = v_sku_id
         WHERE poi.po_id = p_po_id
           AND poi.sku_id = v_sku_id
      ) THEN
        RAISE EXCEPTION
          '分店「%」在採購單「%」對應的開團沒有 SKU「%」的訂單需求，不能撿到這批貨（這批屬於別團，請改用該店所屬開團的採購單撿貨）',
          COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
          v_po.po_no,
          COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id);
      END IF;

      -- 20260715 新增：補貨分配不可超過「剩餘補貨需求」= 申請量 − 已派量。
      -- 申請量：此 PO 對應補貨申請對該 (store, sku) 的 lines 加總。
      SELECT COALESCE(SUM(rrl.qty), 0) INTO v_restock_demand
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                AND rr.requesting_store_id = v_store_id
                                AND rr.status NOT IN ('cancelled','rejected')
        JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                      AND rrl.sku_id = v_sku_id
       WHERE poi.po_id = p_po_id
         AND poi.sku_id = v_sku_id;

      -- 已派量：此 PO 的 campaign NULL wave items（含本 wave 前面 loop 已插入的列，
      -- 同批重複 (sku,store) 會累計）＋ 補貨直派 transfer。
      SELECT
        COALESCE((
          SELECT SUM(pwi.qty)
            FROM picking_wave_items pwi
            JOIN picking_waves pw ON pw.id = pwi.wave_id
           WHERE pw.source_po_id = p_po_id
             AND pw.status <> 'cancelled'
             AND pwi.sku_id = v_sku_id
             AND pwi.store_id = v_store_id
             AND pwi.campaign_id IS NULL
        ), 0)
        + COALESCE((
          SELECT SUM(ti.qty_requested)
            FROM restock_requests rr
            JOIN transfers t ON t.id = rr.linked_transfer_id
            JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = v_sku_id
            JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
            JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = v_sku_id
           WHERE poi.po_id = p_po_id
             AND rr.requesting_store_id = v_store_id
             AND t.transfer_type = 'hq_to_store'
             AND t.status <> 'cancelled'
        ), 0)
      INTO v_restock_dispatched;

      v_restock_left := GREATEST(0, v_restock_demand - v_restock_dispatched);
      IF v_qty > v_restock_left THEN
        RAISE EXCEPTION
          '分店「%」SKU「%」的補貨需求只剩 % 件未派（申請 %、已派 %，含撿貨單與直派），本次分配 % 超過。若要額外補庫存給分店，請走內部調撥。',
          COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
          COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id),
          v_restock_left, v_restock_demand, v_restock_dispatched, v_qty;
      END IF;
    END IF;

    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, campaign_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_wave_id, v_sku_id, v_store_id, v_qty, v_line_campaign_id,
      p_operator, p_operator
    )
    ON CONFLICT (wave_id, sku_id, store_id) DO UPDATE
      SET qty = picking_wave_items.qty + EXCLUDED.qty,
          updated_by = p_operator,
          updated_at = NOW();
  END LOOP;

  -- 8. 統計 wave header
  SELECT COUNT(*), COUNT(DISTINCT store_id), COALESCE(SUM(qty), 0)
    INTO v_item_count, v_store_count, v_total_qty
    FROM picking_wave_items WHERE wave_id = v_wave_id;

  UPDATE picking_waves
     SET item_count = v_item_count,
         store_count = v_store_count,
         total_qty = v_total_qty,
         updated_at = NOW()
   WHERE id = v_wave_id;

  RETURN jsonb_build_object(
    'wave_id', v_wave_id,
    'wave_code', v_wave_code,
    'item_count', v_item_count,
    'store_count', v_store_count,
    'total_qty', v_total_qty
  );
END;
$function$;

-- ----------------------------------------------------------------
-- 5. v_order_shortage：同店衍生單算短缺需求（跨店衍生單維持排除）
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_order_shortage AS
 WITH settled_po_supply AS (
         SELECT poi.sku_id,
            sum(COALESCE(g.gr_qty, 0::numeric)) AS total_gr,
            sum(
                CASE
                    WHEN (po.status = ANY (ARRAY['sent'::text, 'partially_received'::text])) AND poi.stockout_at IS NULL THEN GREATEST(0::numeric, poi.qty_ordered - COALESCE(g.gr_qty, 0::numeric))
                    ELSE 0::numeric
                END) AS total_in_transit
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
             LEFT JOIN ( SELECT gri.po_item_id,
                    sum(gri.qty_received) AS gr_qty
                   FROM goods_receipt_items gri
                     JOIN goods_receipts gr ON gr.id = gri.gr_id
                  WHERE gr.status = 'confirmed'::text
                  GROUP BY gri.po_item_id) g ON g.po_item_id = poi.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text, 'closed'::text])
          GROUP BY poi.sku_id
        ), allocated_per_sku_store AS (
         SELECT v_picking_demand_by_po.sku_id,
            v_picking_demand_by_po.store_id,
            sum(v_picking_demand_by_po.wave_qty) AS total_wave,
            sum(v_picking_demand_by_po.shipped_qty) AS total_shipped
           FROM v_picking_demand_by_po
          WHERE v_picking_demand_by_po.store_id IS NOT NULL
          GROUP BY v_picking_demand_by_po.sku_id, v_picking_demand_by_po.store_id
        ), allocated_per_sku AS (
         SELECT allocated_per_sku_store.sku_id,
            sum(allocated_per_sku_store.total_wave) AS total_wave,
            sum(allocated_per_sku_store.total_shipped) AS total_shipped
           FROM allocated_per_sku_store
          GROUP BY allocated_per_sku_store.sku_id
        ), demand_per_sku_store AS (
         SELECT coi_1.sku_id,
            co_1.pickup_store_id AS store_id,
            sum(coi_1.qty) AS demand_qty
           FROM customer_orders co_1
             JOIN customer_order_items coi_1 ON coi_1.order_id = co_1.id
          WHERE (co_1.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text, 'completed'::text, 'partially_completed'::text])) AND (coi_1.status <> ALL (ARRAY['cancelled'::text, 'expired'::text])) AND (co_1.transferred_from_order_id IS NULL OR EXISTS ( SELECT 1
                 FROM customer_orders src
                WHERE src.id = co_1.transferred_from_order_id
                  AND src.pickup_store_id = co_1.pickup_store_id)) AND co_1.pickup_store_id IS NOT NULL
          GROUP BY coi_1.sku_id, co_1.pickup_store_id
        ), demand_per_sku AS (
         SELECT demand_per_sku_store.sku_id,
            sum(demand_per_sku_store.demand_qty) AS total_demand
           FROM demand_per_sku_store
          GROUP BY demand_per_sku_store.sku_id
        ), sku_shortage AS (
         SELECT d.sku_id,
            d.total_demand,
            COALESCE(s_1.total_gr, 0::numeric) AS total_gr,
            COALESCE(s_1.total_in_transit, 0::numeric) AS total_in_transit,
            COALESCE(a.total_wave, 0::numeric) AS total_wave,
            COALESCE(a.total_shipped, 0::numeric) AS total_shipped,
            GREATEST(0::numeric, d.total_demand - COALESCE(s_1.total_gr, 0::numeric) - COALESCE(s_1.total_in_transit, 0::numeric)) AS sku_shortage_qty
           FROM demand_per_sku d
             JOIN settled_po_supply s_1 ON s_1.sku_id = d.sku_id
             LEFT JOIN allocated_per_sku a ON a.sku_id = d.sku_id
          WHERE d.total_demand > (COALESCE(s_1.total_gr, 0::numeric) + COALESCE(s_1.total_in_transit, 0::numeric))
        )
 SELECT co.tenant_id,
    co.id AS order_id,
    co.order_no,
    co.member_id,
    co.pickup_store_id AS store_id,
    st.name AS store_name,
    co.status AS order_status,
    co.shortage_notified_at,
    co.shortage_resolution,
    co.shortage_resolution_at,
    coi.id AS order_item_id,
    coi.sku_id,
    s.sku_code,
    s.product_name,
    s.variant_name,
    coi.qty AS order_qty,
    ss.total_demand,
    ss.total_gr,
    ss.total_in_transit,
    ss.total_wave,
    ss.total_shipped,
    ss.sku_shortage_qty AS total_supplier_shortage,
    round(coi.qty::numeric * ss.sku_shortage_qty / NULLIF(ss.total_demand, 0::numeric), 2) AS demand_unfulfillable,
    co.created_at AS order_created_at,
    co.updated_at AS order_updated_at
   FROM customer_orders co
     JOIN customer_order_items coi ON coi.order_id = co.id
     JOIN sku_shortage ss ON ss.sku_id = coi.sku_id
     LEFT JOIN skus s ON s.id = coi.sku_id
     LEFT JOIN stores st ON st.id = co.pickup_store_id
  WHERE (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text, 'completed'::text, 'partially_completed'::text])) AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text])) AND (co.transferred_from_order_id IS NULL OR EXISTS ( SELECT 1
         FROM customer_orders src
        WHERE src.id = co.transferred_from_order_id
          AND src.pickup_store_id = co.pickup_store_id)) AND ss.sku_shortage_qty > 0::numeric;

GRANT SELECT ON public.v_order_shortage TO authenticated;

-- ----------------------------------------------------------------
-- 6. rpc_get_allocation_candidates：同店衍生單進配貨候選
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_allocation_candidates(p_transfer_id bigint, p_sku_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  WITH ctx AS (
    SELECT pwi.tenant_id, pwi.campaign_id, pwi.store_id, pwi.sku_id
      FROM picking_wave_items pwi
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND pwi.sku_id = p_sku_id
       AND pwi.campaign_id IS NOT NULL
     LIMIT 1
  ),
  supplied AS (
    -- 同一個 (團,店,品項) 可能分好幾批到，全部已收的實收量都算進可配額度
    SELECT COALESCE(SUM(ti.qty_received), 0) AS qty
      FROM ctx
      JOIN picking_wave_items pwi
        ON pwi.tenant_id = ctx.tenant_id AND pwi.campaign_id = ctx.campaign_id
       AND pwi.store_id  = ctx.store_id  AND pwi.sku_id      = ctx.sku_id
      JOIN transfers t      ON t.id = pwi.generated_transfer_id
                           AND t.status IN ('received', 'closed')
      JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = ctx.sku_id
  ),
  note_cov AS (
    SELECT COALESCE(SUM(n.qty), 0) AS qty
      FROM ctx
      JOIN inventory_deduction_notes n
        ON n.tenant_id = ctx.tenant_id AND n.campaign_id = ctx.campaign_id
       AND n.store_id  = ctx.store_id  AND n.sku_id      = ctx.sku_id
     WHERE n.cancelled_at IS NULL
  ),
  offset_cov AS (
    SELECT COALESCE(SUM(-oi.qty), 0) AS qty
      FROM ctx
      JOIN customer_orders oo
        ON oo.tenant_id       = ctx.tenant_id
       AND oo.campaign_id     = ctx.campaign_id
       AND oo.pickup_store_id = ctx.store_id
       AND oo.order_kind      = 'offset'
       AND oo.status NOT IN ('cancelled', 'expired', 'transferred_out')
      JOIN customer_order_items oi
        ON oi.order_id = oo.id
       AND oi.sku_id   = ctx.sku_id
       AND oi.qty < 0
       AND oi.status NOT IN ('cancelled', 'expired')
  ),
  rows_all AS (
    SELECT coi.id            AS item_id,
           co.id             AS order_id,
           co.order_no,
           COALESCE(m.name, co.nickname_snapshot) AS customer,
           co.status         AS order_status,
           coi.status        AS item_status,
           coi.qty,
           coi.backorder_at,
           co.created_at,
           COALESCE(sm.created_at, coi.updated_at) AS picked_at
      FROM ctx
      JOIN customer_orders co
        ON co.tenant_id        = ctx.tenant_id
       AND co.campaign_id      = ctx.campaign_id
       AND co.pickup_store_id  = ctx.store_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND (co.transferred_from_order_id IS NULL OR EXISTS (
             SELECT 1 FROM customer_orders src
              WHERE src.id = co.transferred_from_order_id
                AND src.pickup_store_id = co.pickup_store_id))
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
      JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.sku_id   = ctx.sku_id
       AND coi.status NOT IN ('cancelled', 'expired')
      LEFT JOIN members m ON m.id = co.member_id
      LEFT JOIN stock_movements sm ON sm.id = coi.pickup_movement_id
  ),
  picked AS (
    SELECT COALESCE(SUM(r.qty), 0) AS qty FROM rows_all r
     WHERE r.item_status IN ('picked_up', 'partially_picked_up')
  )
  SELECT jsonb_build_object(
    'store_id',    (SELECT store_id FROM ctx),
    'campaign_id', (SELECT campaign_id FROM ctx),
    'supplied',  (SELECT qty FROM supplied),
    'covered',   (SELECT qty FROM note_cov) + (SELECT qty FROM offset_cov),
    'picked',    (SELECT qty FROM picked),
    'available', GREATEST((SELECT qty FROM supplied) + (SELECT qty FROM note_cov)
                          + (SELECT qty FROM offset_cov) - (SELECT qty FROM picked), 0),
    -- 店倉帳上可用現貨（開減抵單前的參考與前端預檢；伺服端還會再檢查一次）
    'store_on_hand', COALESCE((
      SELECT sb.on_hand - sb.reserved
        FROM ctx
        JOIN stores st ON st.id = ctx.store_id
        JOIN stock_balances sb
          ON sb.tenant_id = ctx.tenant_id
         AND sb.location_id = st.location_id
         AND sb.sku_id = ctx.sku_id
    ), 0),
    'notes', COALESCE((
      SELECT jsonb_agg(u.e ORDER BY u.kind_ord, u.oid)
        FROM (
          SELECT 1 AS kind_ord, n.id AS oid,
                 jsonb_build_object('id', n.id, 'note_no', n.note_no, 'qty', n.qty,
                                    'reason', n.reason, 'created_at', n.created_at,
                                    'kind', 'note') AS e
            FROM ctx
            JOIN inventory_deduction_notes n
              ON n.tenant_id = ctx.tenant_id AND n.campaign_id = ctx.campaign_id
             AND n.store_id  = ctx.store_id  AND n.sku_id      = ctx.sku_id
           WHERE n.cancelled_at IS NULL
          UNION ALL
          SELECT 2, oo.id,
                 jsonb_build_object('id', oo.id, 'note_no', oo.order_no,
                                    'qty', SUM(-oi.qty), 'reason', oo.notes,
                                    'created_at', oo.created_at, 'kind', 'offset')
            FROM ctx
            JOIN customer_orders oo
              ON oo.tenant_id       = ctx.tenant_id
             AND oo.campaign_id     = ctx.campaign_id
             AND oo.pickup_store_id = ctx.store_id
             AND oo.order_kind      = 'offset'
             AND oo.status NOT IN ('cancelled', 'expired', 'transferred_out')
            JOIN customer_order_items oi
              ON oi.order_id = oo.id
             AND oi.sku_id   = ctx.sku_id
             AND oi.qty < 0
             AND oi.status NOT IN ('cancelled', 'expired')
           GROUP BY oo.id, oo.order_no, oo.notes, oo.created_at
        ) u
    ), '[]'::jsonb),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'item_id',      r.item_id,
               'order_id',     r.order_id,
               'order_no',     r.order_no,
               'customer',     r.customer,
               'order_status', r.order_status,
               'qty',          r.qty,
               'backorder',    r.backorder_at IS NOT NULL,
               'created_at',   r.created_at
             ) ORDER BY r.created_at, r.order_no)
        FROM rows_all r
       WHERE r.item_status IN ('pending', 'reserved', 'ready')
    ), '[]'::jsonb),
    -- 已領走的行：對帳用，前端唯讀顯示，不參與配貨
    'picked_items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'item_id',      r.item_id,
               'order_id',     r.order_id,
               'order_no',     r.order_no,
               'customer',     r.customer,
               'order_status', r.order_status,
               'item_status',  r.item_status,
               'qty',          r.qty,
               'picked_at',    r.picked_at,
               'created_at',   r.created_at
             ) ORDER BY r.picked_at, r.order_no)
        FROM rows_all r
       WHERE r.item_status IN ('picked_up', 'partially_picked_up')
    ), '[]'::jsonb)
  );
$function$;

-- ----------------------------------------------------------------
-- 7. rpc_allocate_shortage：同店衍生單也吃「未配到→待補貨」標記
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_allocate_shortage(p_transfer_id bigint, p_sku_id bigint, p_allocations jsonb, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_ctx        RECORD;
  r            RECORD;
  v_alloc      NUMERIC;
  v_freed      INT := 0;
  v_blocked    INT := 0;
  v_split      INT := 0;
  v_new_disc   NUMERIC;
BEGIN
  SELECT pwi.tenant_id, pwi.campaign_id, pwi.store_id, pwi.sku_id
    INTO v_ctx
    FROM picking_wave_items pwi
   WHERE pwi.generated_transfer_id = p_transfer_id
     AND pwi.sku_id = p_sku_id
     AND pwi.campaign_id IS NOT NULL
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION '這張派貨單的該品項查不到對應的撿貨波次（可能是補貨或自由轉貨），無法配貨';
  END IF;

  FOR r IN
    SELECT coi.id, coi.qty, coi.tenant_id, coi.order_id, coi.campaign_item_id,
           coi.sku_id, coi.unit_price, coi.status, coi.source, coi.notes,
           coi.discount_amount, coi.discount_percent, coi.backorder_at
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id AND coi.sku_id = v_ctx.sku_id
     WHERE co.tenant_id       = v_ctx.tenant_id
       AND co.campaign_id     = v_ctx.campaign_id
       AND co.pickup_store_id = v_ctx.store_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND (co.transferred_from_order_id IS NULL OR EXISTS (
             SELECT 1 FROM customer_orders src
              WHERE src.id = co.transferred_from_order_id
                AND src.pickup_store_id = co.pickup_store_id))
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND coi.status IN ('pending', 'reserved', 'ready')
     ORDER BY coi.id
     FOR UPDATE OF coi
  LOOP
    v_alloc := COALESCE((p_allocations ->> r.id::text)::numeric, 0);
    v_alloc := GREATEST(LEAST(v_alloc, r.qty), 0);

    IF v_alloc >= r.qty THEN
      -- 全部配到：解除待補貨
      IF r.backorder_at IS NOT NULL THEN
        UPDATE customer_order_items
           SET backorder_at = NULL, backorder_by = NULL,
               updated_by = p_operator, updated_at = NOW()
         WHERE id = r.id;
        v_freed := v_freed + 1;
      END IF;

    ELSIF v_alloc <= 0 THEN
      -- 完全沒配到：整行待補貨
      IF r.backorder_at IS NULL THEN
        UPDATE customer_order_items
           SET backorder_at = NOW(), backorder_by = p_operator,
               updated_by = p_operator, updated_at = NOW()
         WHERE id = r.id;
        v_blocked := v_blocked + 1;
      END IF;

    ELSE
      -- 部分配到 → 拆行：原行留可取的量，另開一行掛待補貨
      -- 折扣按數量比例分攤（與 rpc_record_pickup 拆行同一套算法）
      v_new_disc := COALESCE(r.discount_amount, 0)
                    - round(COALESCE(r.discount_amount, 0) * v_alloc / r.qty);

      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, notes, discount_amount, discount_percent,
        backorder_at, backorder_by,
        created_by, updated_by, created_at, updated_at
      ) VALUES (
        r.tenant_id, r.order_id, r.campaign_item_id, r.sku_id, r.qty - v_alloc, r.unit_price,
        r.status, r.source, r.notes, v_new_disc, r.discount_percent,
        NOW(), p_operator,
        p_operator, p_operator, NOW(), NOW()
      );

      UPDATE customer_order_items
         SET qty = v_alloc,
             discount_amount = COALESCE(r.discount_amount, 0)
                               - v_new_disc,
             backorder_at = NULL,
             backorder_by = NULL,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = r.id;

      v_split := v_split + 1;
      v_blocked := v_blocked + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('freed', v_freed, 'backordered', v_blocked, 'split', v_split);
END;
$function$;

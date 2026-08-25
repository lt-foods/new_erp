-- ============================================================
-- 2026-08-25: 撤銷「訂單頁轉單僅限同店」守衛（20260825010000），跨店轉單恢復
--
-- 老闆同日改指示：訂單頁轉單拿回來 —— 店轉店可以，維持既有「貨到店才能轉」
-- 的閘（整單需 ready、部分需 ready/partially_completed，同店換客人不受限）；
-- 跨店轉移改為整合呈現在互助頁的「我轉出／我接收」。
--
-- ⚠ 010000 的守衛已套上線、但配套的前端（鎖同店）從未部署（PR #838 未合併）
-- —— 期間線上前端開著跨店選項、DB 卻擋，店家跨店轉單會吃到錯誤。本檔把兩支
-- 函式還原成守衛前的基底版本，010000 與本檔一起進 main 留歷史。
--
-- 還原目標（＝各自的最新基底，逐字重放）：
--   rpc_transfer_order_to_store = 20260824000100（md5 131da719…）
--   rpc_transfer_order_partial  = 20260824060000（md5 d022f2fa…）
-- Rollback：重跑 20260825010000。
-- ============================================================

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
  v_active_count     INT;
  v_new_item_ids     BIGINT[];
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 #%', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  -- 部分取貨的單不可整單轉出：整單轉出會把來源單標 transferred_out
  -- （整張不入統計），已取走品項的營收會跟著被歸零。剩餘品項請走
  -- rpc_transfer_order_partial（來源列標 cancelled、單頭由
  -- _close_orders_all_items_settled 收尾），營收留在原單上。
  IF v_orig.status = 'partially_completed' THEN
    RAISE EXCEPTION '訂單 % 已有品項取走（部分取貨），不可整單轉出；請改用部分轉出（只轉剩餘品項）',
                    p_order_id;
  END IF;

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

  -- 整單轉出只帶 active（未取消、未取走）品項；一件都沒有就沒東西可轉
  SELECT COUNT(*) INTO v_active_count
    FROM customer_order_items
   WHERE order_id = p_order_id
     AND status IN ('pending','reserved','ready');
  IF v_active_count = 0 THEN
    RAISE EXCEPTION '訂單 #% 沒有可轉移的品項（未取消／未取走的品項為 0）', p_order_id;
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
    -- TF 序號 = 該團既有 -TF 尾碼最大值 + 1。
    -- COUNT(*)+1 在 RR- 單被硬刪（rpc_delete_restock_request）後會倒退、
    -- 重發已用過的號碼 → duplicate key（2026-08-13 湖口 RR-435 事故）。
    -- 團鎖：來源單鎖擋不住兩張不同來源單同時轉出算出同一號。
    PERFORM pg_advisory_xact_lock(hashtext('order_tf_seq:' || v_orig.campaign_id::text));
    SELECT COALESCE(MAX(substring(order_no FROM '-TF([0-9]+)$')::INT), 0) + 1
      INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id
       AND campaign_id = v_orig.campaign_id
       AND order_no ~ '-TF[0-9]+$';
    -- lpad 超寬會截斷（lpad('10001',4)='1000'），寬度要跟著位數長
    v_new_order_no := v_campaign_no || '-TF' ||
                      lpad(v_seq::text, GREATEST(length(v_seq::text), 4), '0');

    v_note_in := COALESCE(p_reason, '') ||
                 E'\n[轉入 (' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
                 ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
                 to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

    -- 同店：mirror source.status；跨店空中轉：confirmed（尾端 helper 會接著
    -- 建 AT- 單並推 shipping）；跨店經總倉：'pending'（維持總倉確認 gate）
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
  -- RETURNING：本次搬進去的品項 id 要留給空中轉出貨（helper 只出這一批）
  WITH ins AS (
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
     WHERE coi.order_id = p_order_id
       -- 只複製 active 品項。cancelled（含部分轉出後留下的殘骸）/ expired /
       -- picked_up（貨已交付）帶過去 = 無中生有的重複品項（2026-08-10 忠順事故）
       AND coi.status IN ('pending','reserved','ready')
    RETURNING id
  )
  SELECT COALESCE(array_agg(id), '{}'::BIGINT[]) INTO v_new_item_ids FROM ins;

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

  -- 這一趟轉移的 order↔order 連結。**兩條分支都要寫**（新建轉入單 / 追加併入
  -- 既有單）—— 只有前者會寫 transferred_from_order_id，追加分支以前什麼線索都
  -- 沒留下，轉出店的儀表板提醒、轉出記錄、隨貨單三個畫面同時查無此事
  -- （2026-08-24 松山→古華喜願蛋）。dest_item_ids 只放本次搬進去的品項，
  -- 轉出店才不會看到／印到別家店在同一張轉入單上的貨。
  INSERT INTO public.customer_order_transfer_links (
    tenant_id, source_order_id, dest_order_id, dest_item_ids,
    is_air_transfer, is_partial, appended, reason, transferred_at, created_by)
  VALUES (
    v_tenant_id, p_order_id, v_new_order_id, COALESCE(v_new_item_ids, '{}'::BIGINT[]),
    COALESCE(p_is_air_transfer, FALSE), FALSE, v_appended, p_reason, v_now, p_operator)
  ON CONFLICT (source_order_id, dest_order_id, transferred_at) DO NOTHING;

  -- 空中轉：貨當下就從轉出店出去 → 建 AT- 轉移單 + 出庫，轉入單進 shipping。
  -- 接收店在收貨頁收掉就可取貨，沒有「派貨」這一步。同店由 helper 判掉。
  IF COALESCE(p_is_air_transfer, FALSE) THEN
    PERFORM public._air_ship_order_items(
      v_new_order_id, v_orig.pickup_store_id, v_new_item_ids, p_operator, v_now);
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
  '整單轉出：跨店需 status=ready；同店互轉（換客人）pending/confirmed/reserved/shipping 也可轉。'
  '接收人已有 active 單則併入（completed 會重開）。品項只複製 active。'
  'TF 序號 = 該團既有 -TF 尾碼 MAX+1（campaign 級 advisory lock 序列化）。'
  '尾端寫 customer_order_transfer_links。錯誤訊息繁體中文。'
  '20260825020000 撤銷 010000 的同店限制、還原基底 20260824000100。';

CREATE OR REPLACE FUNCTION public.rpc_transfer_order_partial(
  p_order_id bigint,
  p_to_pickup_store_id bigint,
  p_to_member_id bigint,
  p_to_channel_id bigint,
  p_operator uuid,
  p_reason text,
  p_items jsonb,
  p_is_air_transfer boolean DEFAULT false,
  p_aid_board_id bigint DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$
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
  v_new_item_id      BIGINT;
  v_new_item_ids     BIGINT[] := '{}'::BIGINT[];
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

  -- 跨店轉單維持「貨到店才能轉」：ready 之外也放行 partially_completed ——
  -- 已取走過品項代表貨到過店，剩餘 active 品項物理上就在店裡（內部現貨池
  -- 臨櫃賣掉一件就進 partially_completed，不放行等於池子賣過一次就不能再轉，
  -- 2026-08-14 湖口 INT0116）。品項挑選本來就限 active，picked_up 不會被轉走。
  -- 同店互轉（換客人）貨進同一間店、不影響總倉派貨量，到貨前也可轉。
  -- 同店預轉仍排除三種「貨不走本店波次」的單（轉走會斷到貨推進鏈）：
  --   a. 非一般團購單（restock ride-along 靠 order_no='RR-x' 特判推 ready、offset 無實貨）
  --   b. 有進行中的調撥 FK 指著它（互助/空中轉/補貨直派 → 到貨判定綁原單 id）
  --   c. 自己就是跨店轉入、貨還沒到的單（到貨判定同樣綁 transfer FK）
  IF v_orig.status NOT IN ('ready','partially_completed') THEN
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

  -- 互助板的轉單一律開新單，不併進既有的容器單（20260824060000）。
  -- (團, 頻道, 會員) 這把併單 key 對互助來說是退化的：收件人固定是接收店的
  -- 「【內部】xx 店」、來源又常是 __INTERNAL_RESTOCK__ sentinel 團 —— 於是
  -- 同一家店所有的互助收貨永遠併成同一張。2026-08-24 平鎮店 TF0497 就堆了
  -- 4 家店、跨 4 天的 4 件不相干的貨（皮蛋醬／堅果／牛肉絲／雞腿排），
  -- 店員看不出哪一件是哪一次互助來的，也印不出只有自己那批貨的單。
  -- 新單身上會蓋 aid_board_id，而 customer_orders_trio_kind_active_uniq
  -- 的 predicate 已排除蓋過章的單，所以第二張開得出來。
  IF p_aid_board_id IS NOT NULL THEN
    v_existing_order := NULL;
  END IF;

  IF v_existing_order IS NOT NULL THEN
    v_new_order_id := v_existing_order;
    v_appended := TRUE;
    SELECT order_no INTO v_new_order_no FROM customer_orders WHERE id = v_existing_order;
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[追加轉入 (部分, ' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
                   ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS') ||
                   COALESCE(' / ' || p_reason, ''),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_new_order_id;
  ELSE
    SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
    -- TF 序號 = 該團既有 -TF 尾碼最大值 + 1。
    -- COUNT(*)+1 在 RR- 單被硬刪（rpc_delete_restock_request）後會倒退、
    -- 重發已用過的號碼 → duplicate key（2026-08-13 湖口 RR-435 事故）。
    -- 團鎖：來源單鎖擋不住兩張不同來源單同時轉出算出同一號。
    PERFORM pg_advisory_xact_lock(hashtext('order_tf_seq:' || v_orig.campaign_id::text));
    SELECT COALESCE(MAX(substring(order_no FROM '-TF([0-9]+)$')::INT), 0) + 1
      INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id
       AND campaign_id = v_orig.campaign_id
       AND order_no ~ '-TF[0-9]+$';
    -- lpad 超寬會截斷（lpad('10001',4)='1000'），寬度要跟著位數長
    v_new_order_no := v_campaign_no || '-TF' ||
                      lpad(v_seq::text, GREATEST(length(v_seq::text), 4), '0');

    -- 同店：mirror source.status，但 partially_completed 映成 'ready' ——
    -- 新單一件都還沒取走，掛「部分取貨」是錯的（取貨頁與收尾邏輯都會誤判）；
    -- 跨店空中轉：confirmed（尾端 helper 會接著建 AT- 單並推 shipping）；
    -- 跨店經總倉：'pending'（維持總倉確認 gate）
    v_new_status := CASE
      WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN
        CASE WHEN v_orig.status = 'partially_completed' THEN 'ready' ELSE v_orig.status END
      WHEN p_is_air_transfer THEN 'confirmed'
      ELSE 'pending'
    END;

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, notes,
      transferred_from_order_id, is_air_transfer, aid_board_id,
      created_by, updated_by, created_at, updated_at
    ) VALUES (
      v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
      v_orig.nickname_snapshot, p_to_pickup_store_id, v_new_status,
      COALESCE(p_reason, '') ||
        E'\n[轉入 (部分, ' || CASE WHEN p_is_air_transfer THEN '空中轉' ELSE '經總倉' END ||
        ') ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
        to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
      p_order_id, p_is_air_transfer, p_aid_board_id,
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
       -- 只挑 active 品項當轉出來源；picked_up（貨已交付）/ expired 的列
       -- 拿來轉會把已交付的貨再轉給別人（同 2026-08-10 整單轉出復活 cancelled 品項的事故類型）
       AND status   IN ('pending','reserved','ready')
     ORDER BY id
     LIMIT 1
     FOR UPDATE;
    IF v_src_item_id IS NULL THEN
      RAISE EXCEPTION 'SKU % 不在訂單 #% 內（或品項已取消／已取走），無法轉移', v_p_sku_id, p_order_id;
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
    ) RETURNING id INTO v_new_item_id;
    -- 本次搬進去的品項 id 留給空中轉出貨（helper 只出這一批，
    -- 不能整張單重出 —— 之前分次追加的品項已經有自己的 AT- 單了）
    v_new_item_ids := array_append(v_new_item_ids, v_new_item_id);
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

  -- 部分取貨的來源單把剩餘 active 全轉走後要收尾成 completed：
  -- remaining_count 算 status != 'cancelled' 會數到 picked_up 列，永遠走不到
  -- transferred_out 分支（這是對的 —— 已取走的營收要留在原單），但也因此
  -- 沒人關單頭。helper 自帶守衛（無 active + 至少一件 picked_up 才動作），
  -- 其餘情境呼叫等於 no-op。
  PERFORM public._close_orders_all_items_settled(ARRAY[p_order_id], p_operator, v_now);

  -- 追加到「已取貨完成」的既有單時，把它重開 —— 否則新品項會被埋在 completed
  -- 單裡：待取清單看不到、is_order_item_pickup_ready 也擋著不給取（見 20260805000140）。
  IF v_appended THEN
    v_reopened := public._reopen_order_if_completed(
      v_new_order_id, p_operator,
      '追加轉入 ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')');
  END IF;

  -- 這一趟轉移的 order↔order 連結。**兩條分支都要寫**（新建轉入單 / 追加併入
  -- 既有單）—— 只有前者會寫 transferred_from_order_id，追加分支以前什麼線索都
  -- 沒留下，轉出店的儀表板提醒、轉出記錄、隨貨單三個畫面同時查無此事
  -- （2026-08-24 松山→古華喜願蛋）。dest_item_ids 只放本次搬進去的品項，
  -- 轉出店才不會看到／印到別家店在同一張轉入單上的貨。
  INSERT INTO public.customer_order_transfer_links (
    tenant_id, source_order_id, dest_order_id, dest_item_ids,
    is_air_transfer, is_partial, appended, reason, transferred_at, created_by,
    aid_board_id)
  VALUES (
    v_tenant_id, p_order_id, v_new_order_id, COALESCE(v_new_item_ids, '{}'::BIGINT[]),
    COALESCE(p_is_air_transfer, FALSE), TRUE, v_appended, p_reason, v_now, p_operator,
    p_aid_board_id)
  ON CONFLICT (source_order_id, dest_order_id, transferred_at) DO NOTHING;

  -- 空中轉：貨當下就從轉出店出去 → 建 AT- 轉移單 + 出庫，轉入單進 shipping。
  -- 接收店在收貨頁收掉就可取貨，沒有「派貨」這一步。同店由 helper 判掉。
  IF COALESCE(p_is_air_transfer, FALSE) THEN
    PERFORM public._air_ship_order_items(
      v_new_order_id, v_orig.pickup_store_id, v_new_item_ids, p_operator, v_now);
  END IF;

  RETURN v_new_order_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.rpc_transfer_order_partial(
  bigint, bigint, bigint, bigint, uuid, text, jsonb, boolean, bigint)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.rpc_transfer_order_partial(
  bigint, bigint, bigint, bigint, uuid, text, jsonb, boolean, bigint) IS
  '部分轉單：跨店需 status=ready/partially_completed；同店換客人不受限。'
  'p_aid_board_id 非 NULL = 互助板轉單：一律開新單、貼文 id 蓋在轉入單與'
  ' customer_order_transfer_links 上。'
  '20260825020000 撤銷 010000 的同店限制、還原基底 20260824060000。';

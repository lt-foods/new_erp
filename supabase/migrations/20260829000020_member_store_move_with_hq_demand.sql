-- ============================================================
-- 會員換取貨店：訂單 + 總倉待出倉需求一次搬過去
--
-- 老闆 2026-08-29：「有辦法之後不擋，然後一次改過去嗎？連同總倉那邊的
-- 進貨要出倉的資料都連動一起改」。
--
-- 現況只有一道守衛（20260829000010 起只擋「還在別家店」的未取貨訂單），
-- 擋下之後沒有任何入口能把單搬過去 —— 店員只能一張一張手動轉單。
-- 本檔補上入口：先預覽、確認後一次執行。
--
-- ── 為什麼不能直接呼叫 rpc_transfer_order_to_store（空中轉）──────────
-- 那支是「轉給**別人**」。它用 (campaign_id, channel_id, member_id) 找接收人
-- 的既有單，查到的如果就是來源單本身 → RAISE「這張訂單本來就掛在該接收人
-- 名下，不需要轉出」。而本案的接收人**就是同一位會員**，且線上 78,251 張
-- 一般單裡有 76,665 張共用同一個 channel（__INTERNAL_RESTOCK_1__，橫跨 18 家店，
-- channel 根本不隨取貨店走）→ 同會員同團跨店轉單一定撞上那道守衛。
-- customer_orders_trio_kind_active_uniq 也是 (tenant,campaign,channel,member,kind)，
-- 不含 pickup_store_id，硬繞過去就是撞唯一索引。
--
-- 所以本檔**不建新訂單**：訂單號原地保留，只改 pickup_store_id，貨用
-- _air_ship_order_items（20260825000000）開一張 AT- 轉移單實際從舊店出庫。
-- 對帳、月結 air_in/air_out、收貨頁都沿用既有那一套，一行都不用改。
--
-- ── 三條路線（依「貨現在在哪」決定，單頭 status 與波次證據兩個都看）──
-- CLAUDE.md 已載明兩者會各走各的（confirmed 單的貨可能早就到店），所以
-- 缺一不可：
--   repoint  貨還沒出總倉 → 只改 pickup_store_id；波次已排未派的，
--            需求量同步從舊店那列搬到新店那列（＝老闆說的「總倉要出倉的資料」）。
--   air      貨已經在舊店（單頭 ready/partially_completed，或波次調撥已 received）
--            → 改 pickup_store_id ＋ 開 AT- 單從舊店出庫、單頭進 shipping；
--            新店在 /wms/inbound 收掉後 rpc_receive_transfer 邏輯 B 推回 ready。
--   blocked  貨在路上（單頭 shipping／調撥 shipped）、總倉已撿貨待出、
--            已開出貨單未出貨、品項沒綁 SKU → 不動，原因回報給店員。
--            貨在卡車上時改指會讓那批貨送到一間沒有這張單的店。
--
-- 刻意不做：
--   - **不搬 LINE 綁定。** store_line_followers 是各店 OA 的好友名冊
--     （line-webhook 寫入、admin-line-push 拿來推播），會員沒加新店的 OA
--     就是沒加，偽造一列只會把「尚未綁定」變成推播失敗。改回報
--     needs_line_rebind，讓店員引導會員綁新店。
--   - **不改已出貨波次的歷史 store_id**（同 20260817000020 的決定）：那是
--     派貨事實，改了對不上已建立的調撥單。貨的移動由 AT- 單表達。
--   - 歷史單（completed/cancelled/expired）不動。
--
-- 基底：本檔全新，不覆寫任何既有函式。
-- rollback：DROP 這三支即可（沒有任何既有呼叫點依賴它們）；已經搬過去的
--   資料不會自動回復，反向再跑一次可把單搬回舊店，但 AT- 單與出入庫是
--   實體事實、會留下。
-- ============================================================

-- ------------------------------------------------------------
-- 1. _member_store_move_plan — 分類器（預覽與執行共用同一份，避免兩邊走鐘）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._member_store_move_plan(
  p_tenant      UUID,
  p_member_id   BIGINT,
  p_to_store_id BIGINT
) RETURNS TABLE (
  order_id      BIGINT,
  order_no      TEXT,
  order_status  TEXT,
  from_store_id BIGINT,
  action        TEXT,
  reason        TEXT,
  air_item_ids  BIGINT[],
  wave_moves    JSONB
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH itm AS (
    SELECT co.id              AS order_id,
           co.order_no,
           co.status          AS order_status,
           co.campaign_id,
           co.pickup_store_id AS from_store_id,
           coi.id             AS item_id,
           coi.sku_id,
           coi.qty,
           COALESCE(co.order_kind, 'normal') AS order_kind,
           -- 已經有一趟調撥指著這張單（互助 / 空中轉 / 補貨直派），而且還沒收貨。
           -- 到貨判定綁在 transfer.customer_order_id 上，這時改店等於把那箱貨
           -- 送去一間跟這張單無關的店。守衛口徑同 rpc_transfer_order_to_store
           -- 的「訂單有進行中的調撥，請等分店收貨後再轉單」。
           EXISTS (SELECT 1 FROM transfers t
                    WHERE t.customer_order_id = co.id
                      AND t.tenant_id = co.tenant_id
                      AND t.status NOT IN ('cancelled','received')) AS has_inflight_transfer
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.tenant_id = p_tenant
       AND co.member_id = p_member_id
       -- 與全站「未取貨」同一套集合（含 transferred_out 排除：貨已在新單上）
       AND co.status NOT IN ('completed','cancelled','expired','transferred_out')
       -- active 品項集合同 rpc_record_pickup 的 v_active_remaining，
       -- 不寫 != 'cancelled'（會漏掉 picked_up）
       AND coi.status IN ('pending','reserved','ready')
       AND co.pickup_store_id IS DISTINCT FROM p_to_store_id
  ),
  cls AS (
    SELECT i.*,
           w.any_arrived,
           w.any_in_transit,
           w.any_pending_doc,
           w.any_picked_undispatched,
           w.movable_wave_item_id,
           w.movable_wave_id
      FROM itm i
      -- 同一組 (團,店,SKU) 可能出現在多個波次（分批派貨 / 每週重開的品），
      -- 所以要跨波次彙總，不能單挑一列 join —— 單挑會依挑到哪一列給出不同答案。
      LEFT JOIN LATERAL (
        SELECT
          COALESCE(bool_or(t.status = 'received'), FALSE)              AS any_arrived,
          COALESCE(bool_or(t.status = 'shipped'),  FALSE)              AS any_in_transit,
          COALESCE(bool_or(t.status IN ('draft','confirmed')), FALSE)  AS any_pending_doc,
          COALESCE(bool_or(pwi.generated_transfer_id IS NULL
                           AND pw.status <> 'cancelled'
                           AND COALESCE(pwi.picked_qty, 0) > 0), FALSE) AS any_picked_undispatched,
          (ARRAY_AGG(pwi.id ORDER BY pwi.id DESC) FILTER (
             WHERE pwi.generated_transfer_id IS NULL
               AND pw.status <> 'cancelled'
               AND COALESCE(pwi.picked_qty, 0) = 0))[1]                AS movable_wave_item_id,
          (ARRAY_AGG(pwi.wave_id ORDER BY pwi.id DESC) FILTER (
             WHERE pwi.generated_transfer_id IS NULL
               AND pw.status <> 'cancelled'
               AND COALESCE(pwi.picked_qty, 0) = 0))[1]                AS movable_wave_id
          FROM picking_wave_items pwi
          JOIN picking_waves pw ON pw.id = pwi.wave_id
          LEFT JOIN transfers t ON t.id = pwi.generated_transfer_id
         WHERE pwi.tenant_id   = p_tenant
           AND pwi.campaign_id = i.campaign_id
           AND pwi.store_id    = i.from_store_id
           AND pwi.sku_id      = i.sku_id
      ) w ON TRUE
  ),
  item_act AS (
    SELECT c.*,
           CASE
             WHEN c.sku_id IS NULL                                  THEN 'blocked'
             WHEN c.order_kind <> 'normal'                          THEN 'blocked'
             WHEN c.has_inflight_transfer                           THEN 'blocked'
             WHEN c.order_status = 'shipping'                       THEN 'blocked'
             WHEN c.any_in_transit                                  THEN 'blocked'
             WHEN c.any_pending_doc                                 THEN 'blocked'
             WHEN c.order_status IN ('ready','partially_completed')  THEN 'air'
             WHEN c.any_arrived                                     THEN 'air'
             WHEN c.movable_wave_item_id IS NOT NULL                THEN 'wave'
             WHEN c.any_picked_undispatched                         THEN 'blocked'
             ELSE 'free'
           END AS item_action,
           CASE
             WHEN c.sku_id IS NULL            THEN '品項沒有綁商品（純公告單），不能隨單搬移'
             WHEN c.order_kind <> 'normal'    THEN '不是一般團購單（' || c.order_kind || '），請個別處理'
             WHEN c.has_inflight_transfer     THEN '這張單有進行中的調撥，請等原店收貨後再搬'
             WHEN c.order_status = 'shipping' THEN '總倉已出貨、貨還在路上，請等原店收貨後再搬'
             WHEN c.any_in_transit            THEN '總倉已出貨、貨還在路上，請等原店收貨後再搬'
             WHEN c.any_pending_doc           THEN '總倉已開出貨單但尚未出貨，請先處理那張調撥單'
             WHEN c.any_picked_undispatched   THEN '總倉已撿貨待出，請先處理那個波次'
           END AS item_reason
      FROM cls c
  )
  SELECT
    a.order_id,
    a.order_no,
    a.order_status,
    a.from_store_id,
    CASE WHEN bool_or(a.item_action = 'blocked') THEN 'blocked'
         WHEN bool_or(a.item_action = 'air')     THEN 'air'
         ELSE 'repoint' END                                    AS action,
    (ARRAY_AGG(a.item_reason) FILTER (WHERE a.item_reason IS NOT NULL))[1] AS reason,
    COALESCE(ARRAY_AGG(a.item_id) FILTER (WHERE a.item_action = 'air'),
             '{}'::BIGINT[])                                   AS air_item_ids,
    COALESCE(jsonb_agg(jsonb_build_object(
               'wave_item_id', a.movable_wave_item_id,
               'wave_id',      a.movable_wave_id,
               'sku_id',       a.sku_id,
               'qty',          a.qty)
             ) FILTER (WHERE a.item_action = 'wave'), '[]'::jsonb) AS wave_moves
    FROM item_act a
   GROUP BY a.order_id, a.order_no, a.order_status, a.from_store_id
   ORDER BY a.order_id;
$$;

COMMENT ON FUNCTION public._member_store_move_plan(UUID, BIGINT, BIGINT) IS
  '會員換取貨店的搬移計畫：把未取貨訂單分成 repoint / air / blocked 三類。'
  '「貨在哪」同時看單頭 status 與波次調撥證據 —— 兩者會各走各的（confirmed 單的貨'
  '可能早就到店），只信一邊會誤判。預覽與執行共用本支。';

-- ------------------------------------------------------------
-- 2. rpc_preview_member_store_move — 唯讀預覽（前端按儲存先跳這個）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_preview_member_store_move(
  p_member_id   BIGINT,
  p_to_store_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_from     BIGINT;
  v_result   JSONB;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  -- 允許清單對齊 apps/admin/src/lib/role.ts：'' 是沒有顯式 role 的 legacy/dev admin，
  -- 漏掉它會把舊帳號全擋在外面。role 一律走 app_metadata（頂層永遠是 'authenticated'）。
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  SELECT home_store_id INTO v_from FROM members
   WHERE id = p_member_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;

  IF p_to_store_id IS NOT NULL THEN
    PERFORM 1 FROM stores WHERE id = p_to_store_id AND tenant_id = v_tenant AND is_active = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant or inactive', p_to_store_id; END IF;
  END IF;

  SELECT jsonb_build_object(
           'member_id',      p_member_id,
           'from_store_id',  v_from,
           'from_store',     (SELECT name FROM stores WHERE id = v_from),
           'to_store_id',    p_to_store_id,
           'to_store',       (SELECT name FROM stores WHERE id = p_to_store_id),
           'repoint',        COALESCE(jsonb_agg(jsonb_build_object(
                               'order_no', pl.order_no, 'status', pl.order_status,
                               'wave_lines', jsonb_array_length(pl.wave_moves)
                             ) ORDER BY pl.order_id) FILTER (WHERE pl.action = 'repoint'), '[]'::jsonb),
           'air',            COALESCE(jsonb_agg(jsonb_build_object(
                               'order_no', pl.order_no, 'status', pl.order_status,
                               'items', COALESCE(array_length(pl.air_item_ids, 1), 0)
                             ) ORDER BY pl.order_id) FILTER (WHERE pl.action = 'air'), '[]'::jsonb),
           'blocked',        COALESCE(jsonb_agg(jsonb_build_object(
                               'order_no', pl.order_no, 'status', pl.order_status,
                               'reason', pl.reason
                             ) ORDER BY pl.order_id) FILTER (WHERE pl.action = 'blocked'), '[]'::jsonb),
           'wave_lines',     COALESCE(SUM(jsonb_array_length(pl.wave_moves))
                               FILTER (WHERE pl.action <> 'blocked'), 0),
           'needs_line_rebind',
             p_to_store_id IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM store_line_followers f
                WHERE f.tenant_id = v_tenant AND f.store_id = p_to_store_id
                  AND f.member_id = p_member_id AND f.followed)
         )
    INTO v_result
    FROM public._member_store_move_plan(v_tenant, p_member_id, p_to_store_id) pl;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_preview_member_store_move(BIGINT, BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_preview_member_store_move(BIGINT, BIGINT) IS
  '唯讀預覽：改取貨店會搬走哪些單、動到幾列總倉派貨需求、哪些單搬不動。'
  '前端按「儲存」先跳這支的結果讓人確認，確認後才呼叫 rpc_move_member_to_store。';

-- ------------------------------------------------------------
-- 3. rpc_move_member_to_store — 真的執行
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_move_member_to_store(
  p_member_id   BIGINT,
  p_to_store_id BIGINT,
  p_operator    UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_role       TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_operator   UUID := COALESCE(p_operator, auth.uid());
  v_now        TIMESTAMPTZ := NOW();
  v_from       BIGINT;
  v_plan       JSONB;
  v_row        JSONB;
  v_move       JSONB;
  v_order_id   BIGINT;
  v_from_store BIGINT;
  v_wave_item  BIGINT;
  v_wave_id    BIGINT;
  v_sku_id     BIGINT;
  v_campaign   BIGINT;
  v_qty        NUMERIC;
  v_old_qty    NUMERIC;
  v_take       NUMERIC;
  v_new_item   BIGINT;
  v_dst_item   BIGINT;
  v_transfer   BIGINT;
  v_repointed  JSONB := '[]'::jsonb;
  v_aired      JSONB := '[]'::jsonb;
  v_blocked    JSONB := '[]'::jsonb;
  v_wave_lines INT := 0;
  v_wave_qty   NUMERIC := 0;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  -- 同一位會員不可並行搬兩次（兩次都讀到同一份計畫 → 波次量被扣兩遍）
  PERFORM pg_advisory_xact_lock(hashtext('member_store_move:' || p_member_id::text));

  SELECT home_store_id INTO v_from FROM members
   WHERE id = p_member_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;

  IF p_to_store_id IS NULL THEN
    RAISE EXCEPTION '請指定要改到哪一家店';
  END IF;
  PERFORM 1 FROM stores WHERE id = p_to_store_id AND tenant_id = v_tenant AND is_active = TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant or inactive', p_to_store_id; END IF;

  -- 計畫先整份 materialize 成 JSONB 再跑：邊算邊改會讓分類器讀到已被自己
  -- 改過的 pickup_store_id / 波次量。
  SELECT COALESCE(jsonb_agg(to_jsonb(pl) ORDER BY pl.order_id), '[]'::jsonb)
    INTO v_plan
    FROM public._member_store_move_plan(v_tenant, p_member_id, p_to_store_id) pl;

  -- 有 air 路線就一定會建 AT- 單，而 _air_ship_order_items 要求兩邊都有倉別。
  -- 先問一次、整筆擋下，不要等跑到一半才炸（前面的單已經改掉了）。
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_plan) e WHERE e ->> 'action' = 'air') THEN
    IF (SELECT location_id FROM stores WHERE id = p_to_store_id) IS NULL THEN
      RAISE EXCEPTION '接收店（#%）沒有對應倉庫，無法把已到貨的單搬過去', p_to_store_id;
    END IF;
    -- stock_movements.operator_id 是 NOT NULL，缺操作者會在 rpc_outbound 深處
    -- 炸成看不懂的 constraint 錯誤（實測）。在這裡先講清楚。
    IF v_operator IS NULL THEN
      RAISE EXCEPTION '找不到操作者，無法建立出庫紀錄；請重新登入後再試，或由呼叫端帶入 p_operator';
    END IF;
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(v_plan)
  LOOP
    v_order_id   := (v_row ->> 'order_id')::BIGINT;
    v_from_store := (v_row ->> 'from_store_id')::BIGINT;

    IF v_row ->> 'action' = 'blocked' THEN
      v_blocked := v_blocked || jsonb_build_array(jsonb_build_object(
        'order_no', v_row ->> 'order_no',
        'status',   v_row ->> 'order_status',
        'reason',   v_row ->> 'reason'));
      CONTINUE;
    END IF;

    -- ── 總倉待出倉需求改派：舊店那列扣量、新店那列補量 ──────────────
    FOR v_move IN SELECT * FROM jsonb_array_elements(v_row -> 'wave_moves')
    LOOP
      v_wave_item := (v_move ->> 'wave_item_id')::BIGINT;
      v_wave_id   := (v_move ->> 'wave_id')::BIGINT;
      v_sku_id    := (v_move ->> 'sku_id')::BIGINT;
      v_qty       := (v_move ->> 'qty')::NUMERIC;

      -- campaign_id 要在可能的 DELETE 之前一起讀出來，新店那列要沿用同一個團
      SELECT qty, campaign_id INTO v_old_qty, v_campaign
        FROM picking_wave_items WHERE id = v_wave_item FOR UPDATE;
      CONTINUE WHEN v_old_qty IS NULL;

      -- 波次那列是「該店該 SKU 全部客人的需求」，只能扣本會員這一筆；
      -- 夾在 qty 以內，避免同組多張單重複扣成負數（CHECK qty > 0 會擋）。
      v_take := LEAST(v_qty, v_old_qty);
      CONTINUE WHEN v_take <= 0;
      v_new_item := NULL;   -- 每一輪重置，否則上一輪的值會讓下面的分支判斷走錯

      SELECT id INTO v_dst_item
        FROM picking_wave_items
       WHERE wave_id = v_wave_id AND sku_id = v_sku_id AND store_id = p_to_store_id;

      IF v_take >= v_old_qty AND v_dst_item IS NULL THEN
        -- 整列都搬、而且新店還沒有同 SKU 那列 → 直接把這一列改掛新店。
        -- 這是最乾淨的路：不用刪列（picking_wave_audit_log.wave_item_id 的
        -- ON DELETE SET NULL 會撞上 append-only 觸發器 trg_no_mut_wave_audit），
        -- 稽核歷史也還指著同一列 —— 它本來就是同一筆需求，只是換一家店領。
        UPDATE picking_wave_items
           SET store_id   = p_to_store_id,
               note       = COALESCE(note || ' / ', '')
                            || '[改取貨店] 由門市 #' || v_from_store || ' 改派',
               updated_by = v_operator,
               updated_at = v_now
         WHERE id = v_wave_item;
        v_new_item := v_wave_item;
      ELSE
        IF v_take >= v_old_qty THEN
          -- 整列要搬、但新店已經有同 SKU 那列 → 併進去之後原列必須消失。
          -- 稽核表擋 DELETE 連動的 SET NULL，比照 rpc_delete_picking_wave
          -- （20260426000000）暫時停用觸發器；但**只把 FK 指標清成 NULL、
          -- 一列歷史都不刪** —— 那支是整個波次要消失才連歷史一起刪，
          -- 換店不該把稽核紀錄一起弄不見。
          -- DISABLE TRIGGER 取 ACCESS EXCLUSIVE lock，交易結束才釋放，
          -- 所以沒有「保護被關掉的空窗」。
          ALTER TABLE picking_wave_audit_log DISABLE TRIGGER trg_no_mut_wave_audit;
          UPDATE picking_wave_audit_log SET wave_item_id = NULL WHERE wave_item_id = v_wave_item;
          DELETE FROM picking_wave_items WHERE id = v_wave_item;
          ALTER TABLE picking_wave_audit_log ENABLE TRIGGER trg_no_mut_wave_audit;
        ELSE
          UPDATE picking_wave_items
             SET qty = qty - v_take, updated_by = v_operator, updated_at = v_now
           WHERE id = v_wave_item;
        END IF;
      END IF;

      INSERT INTO picking_wave_audit_log (
        tenant_id, wave_id, wave_item_id, action, before_value, after_value, note, created_by
      ) VALUES (
        v_tenant, v_wave_id, NULL, 'item_removed',
        jsonb_build_object('store_id', v_from_store, 'sku_id', v_sku_id, 'qty', v_old_qty),
        jsonb_build_object('store_id', v_from_store, 'sku_id', v_sku_id, 'qty', v_old_qty - v_take),
        '會員 #' || p_member_id || ' 改取貨店，需求改派至門市 #' || p_to_store_id, v_operator
      );

      IF v_new_item IS DISTINCT FROM v_wave_item THEN
      INSERT INTO picking_wave_items (
        tenant_id, wave_id, sku_id, store_id, qty, campaign_id, note, created_by, updated_by
      ) VALUES (
        v_tenant, v_wave_id, v_sku_id, p_to_store_id, v_take, v_campaign,
        '[改取貨店] 由門市 #' || v_from_store || ' 改派', v_operator, v_operator
      )
      ON CONFLICT (wave_id, sku_id, store_id) DO UPDATE
        SET qty        = picking_wave_items.qty + EXCLUDED.qty,
            updated_by = v_operator,
            updated_at = v_now
      RETURNING id INTO v_new_item;
      END IF;

      INSERT INTO picking_wave_audit_log (
        tenant_id, wave_id, wave_item_id, action, before_value, after_value, note, created_by
      ) VALUES (
        v_tenant, v_wave_id, v_new_item, 'item_added',
        NULL,
        jsonb_build_object('store_id', p_to_store_id, 'sku_id', v_sku_id, 'qty', v_take),
        '會員 #' || p_member_id || ' 改取貨店，需求由門市 #' || v_from_store || ' 改派過來', v_operator
      );

      -- cached aggregates（list 頁靠它顯示）；口徑同 20260502070000
      UPDATE picking_waves pw
         SET item_count  = agg.item_count,
             store_count = agg.store_count,
             total_qty   = agg.total_qty,
             updated_by  = v_operator,
             updated_at  = v_now
        FROM (
          SELECT COUNT(*)                                    AS item_count,
                 COUNT(DISTINCT store_id)                    AS store_count,
                 COALESCE(SUM(COALESCE(picked_qty, qty)), 0) AS total_qty
            FROM picking_wave_items WHERE wave_id = v_wave_id
        ) agg
       WHERE pw.id = v_wave_id;

      v_wave_lines := v_wave_lines + 1;
      v_wave_qty   := v_wave_qty + v_take;
    END LOOP;

    -- ── 訂單改指到新店 ───────────────────────────────────────────────
    UPDATE customer_orders
       SET pickup_store_id = p_to_store_id,
           notes = COALESCE(notes, '') || E'\n[改取貨店] 門市 #' || v_from_store
                   || ' → #' || p_to_store_id || '（' || to_char(v_now, 'YYYY-MM-DD HH24:MI') || '）',
           updated_by = v_operator,
           updated_at = v_now
     WHERE id = v_order_id AND tenant_id = v_tenant;

    IF v_row ->> 'action' = 'air' THEN
      -- 貨在舊店 → 開 AT- 單真的把貨從舊店出庫寄到新店。
      -- ⚠ pickup_store_id 必須**先**改好：helper 是拿 v_ord.pickup_store_id
      -- 當目的地倉的（20260825000000）。
      v_transfer := public._air_ship_order_items(
        v_order_id,
        v_from_store,
        ARRAY(SELECT jsonb_array_elements_text(v_row -> 'air_item_ids')::BIGINT),
        v_operator,
        v_now
      );

      IF v_transfer IS NOT NULL THEN
        -- shipping → 新店在 /wms/inbound 收掉後 rpc_receive_transfer 邏輯 B 推回 ready
        UPDATE customer_orders
           SET status = 'shipping', updated_by = v_operator, updated_at = v_now
         WHERE id = v_order_id AND tenant_id = v_tenant;
      END IF;

      v_aired := v_aired || jsonb_build_array(jsonb_build_object(
        'order_no',    v_row ->> 'order_no',
        'transfer_no', (SELECT transfer_no FROM transfers WHERE id = v_transfer)));
    ELSE
      v_repointed := v_repointed || jsonb_build_array(jsonb_build_object(
        'order_no', v_row ->> 'order_no'));
    END IF;
  END LOOP;

  -- 會員預設取貨店本身（未來的新訂單走這裡）。有搬不動的單也照改 ——
  -- 人已經換店了，那幾張留在舊店由店員照 blocked 清單收尾。
  UPDATE members
     SET home_store_id = p_to_store_id,
         updated_by    = v_operator,
         updated_at    = v_now
   WHERE id = p_member_id AND tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'ok',            TRUE,
    'member_id',     p_member_id,
    'from_store_id', v_from,
    'to_store_id',   p_to_store_id,
    'repointed',     v_repointed,
    'air_shipped',   v_aired,
    'blocked',       v_blocked,
    'wave_lines_moved', v_wave_lines,
    'wave_qty_moved',   v_wave_qty,
    -- 綁定不搬（見檔頭）：沒綁新店 OA 就推不到到貨通知，要引導會員重綁
    'needs_line_rebind', NOT EXISTS (
      SELECT 1 FROM store_line_followers f
       WHERE f.tenant_id = v_tenant AND f.store_id = p_to_store_id
         AND f.member_id = p_member_id AND f.followed)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_move_member_to_store(BIGINT, BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_move_member_to_store(BIGINT, BIGINT, UUID) IS
  '會員換取貨店：未取貨訂單與總倉待出倉需求一起搬。貨還沒出總倉的只改 pickup_store_id'
  '＋把波次需求量改派到新店；貨已在舊店的開 AT- 單實際出庫（訂單號不變，'
  '不走 rpc_transfer_order_to_store —— 同會員同團跨店會撞它的「轉給自己」守衛）；'
  '貨在路上的不動、回報原因。LINE 綁定刻意不搬。';

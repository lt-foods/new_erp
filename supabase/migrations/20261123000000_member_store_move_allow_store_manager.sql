-- ============================================================
-- 會員換取貨店：店長也能用（原本只給 owner / admin）
--
-- 2026-11-23 回報「店長不能轉店」：會員明細改取貨店按儲存 →
-- 「預覽失敗：insufficient_role」。當天 3 位店長（平鎮、松山、忠順/文山）被擋。
--
-- 原因：rpc_preview_member_store_move / rpc_move_member_to_store 的允許清單是
-- ('owner','admin','')。而前端從 #1154 起**不管有沒有未取貨訂單都先打預覽**，
-- 所以店長連「沒有任何訂單、單純改店」都改不了（那條原本走沒有角色限制的
-- rpc_set_member_home_store）。線上 23 個店長帳號全中。
--
-- 改法：
--   1. 允許清單加 hq_manager / store_manager（store_staff 不給，比照
--      rpc_unmerge_member 20260809000070）。
--   2. 店長多一層店別收斂：轉出店（會員現在的取貨店）或轉入店至少一邊是自己的店
--      （_jwt_store_ids()，app_metadata.stores 店名）。實際情形多半是客人到新店說
--      「以後來這裡拿」→ 由**轉入店**店長操作，所以兩邊都認。
--      ⚠ 這代表轉入店店長選「一起搬」時，貨已在原店的訂單會從**原店**開 AT- 單出庫
--      （p_allow_negative），原店要實際把貨送過去。彈窗本來就有寫給操作的人看。
--
-- 其餘邏輯一行沒動：兩支函式本體取自線上 pg_proc.prosrc（2026-11-23 比對，
-- 與 repo 基底逐字相同），只換角色檢查那一段。
--
-- 基底：rpc_preview_member_store_move → 20260829000020
--       rpc_move_member_to_store      → 20261118000000
-- rollback：重跑 20260829000020 第 2 段與 20261118000000。
-- ============================================================

BEGIN;

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
  -- 角色：管理員層級 + hq_manager + 店長（'' = 沒有顯式 role 的 legacy/dev admin）。
  -- role 一律走 app_metadata（頂層永遠是 'authenticated'）。店長另有店別收斂，見下。
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  SELECT home_store_id INTO v_from FROM members
   WHERE id = p_member_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;

  -- 店長只能動「轉出店或轉入店是自己店」的會員（身分 = app_metadata.stores 店名，
  -- 走 _jwt_store_ids()）。&& 對 NULL 元素不成立 → 會員沒有取貨店時只看轉入店。
  IF v_role = 'store_manager'
     AND NOT (public._jwt_store_ids() && ARRAY[v_from, p_to_store_id]::BIGINT[]) THEN
    RAISE EXCEPTION '店長只能把會員轉進或轉出自己的店';
  END IF;

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

CREATE OR REPLACE FUNCTION public.rpc_move_member_to_store(
  p_member_id   BIGINT,
  p_to_store_id BIGINT,
  p_operator    UUID DEFAULT NULL,
  p_move_orders BOOLEAN DEFAULT TRUE
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
  v_kept       JSONB := '[]'::jsonb;
  v_wave_lines INT := 0;
  v_wave_qty   NUMERIC := 0;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  -- 角色：管理員層級 + hq_manager + 店長（'' = 沒有顯式 role 的 legacy/dev admin）。
  -- role 一律走 app_metadata（頂層永遠是 'authenticated'）。店長另有店別收斂，見下。
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  -- 同一位會員不可並行搬兩次（兩次都讀到同一份計畫 → 波次量被扣兩遍）
  PERFORM pg_advisory_xact_lock(hashtext('member_store_move:' || p_member_id::text));

  SELECT home_store_id INTO v_from FROM members
   WHERE id = p_member_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;

  -- 店長只能動「轉出店或轉入店是自己店」的會員（身分 = app_metadata.stores 店名，
  -- 走 _jwt_store_ids()）。&& 對 NULL 元素不成立 → 會員沒有取貨店時只看轉入店。
  IF v_role = 'store_manager'
     AND NOT (public._jwt_store_ids() && ARRAY[v_from, p_to_store_id]::BIGINT[]) THEN
    RAISE EXCEPTION '店長只能把會員轉進或轉出自己的店';
  END IF;

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

  -- ── 訂單留原店（p_move_orders = FALSE）────────────────────────────
  -- 只改會員的預設取貨店，既有訂單一張都不動：把計畫清空，下面的迴圈
  -- 與 air 前置檢查自然全部跳過。留下來的單列在 kept 回給前端。
  IF NOT COALESCE(p_move_orders, TRUE) THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'order_no', e ->> 'order_no',
             'status',   e ->> 'order_status',
             'store',    (SELECT s.name FROM stores s
                           WHERE s.id = (e ->> 'from_store_id')::BIGINT))
             ORDER BY (e ->> 'order_id')::BIGINT), '[]'::jsonb)
      INTO v_kept
      FROM jsonb_array_elements(v_plan) e;
    v_plan := '[]'::jsonb;
  END IF;

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
    'orders_moved',  COALESCE(p_move_orders, TRUE),
    'kept',          v_kept,
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

GRANT EXECUTE ON FUNCTION public.rpc_move_member_to_store(BIGINT, BIGINT, UUID, BOOLEAN) TO authenticated;

COMMIT;

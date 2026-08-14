-- ============================================================
-- 2026-08-14：收貨·手動配 — 派貨中的訂單也列出來讓店家決定
--
-- 需求（Alex 2026-08-14，古華店回報「手動配裡面都沒有人」）：
--   走團購波次出的貨，訂單在總倉出貨時就被 rpc_mark_orders_shipping_for_wave
--   推成 shipping —— 收貨·手動配的候選只抓 confirmed，這批貨「命定的主人」
--   反而一張都不顯示，店家以為系統漏單。Alex 要的是：收貨時就是決定
--   「哪些客人配到貨」的時刻，可以被配單（confirmed）或被拉回（shipping）
--   的單都要顯示讓店家勾，並且每張單標出**客人目前看到的狀態**。
--
-- 語意：
--   * 派貨中（shipping）＝這批貨出貨時就配給他的單 → 預設勾選。
--     - 保持勾選 → 收貨後推「可取貨」（與自動模式邏輯 C 同結果、同樣
--       qty-blind —— 店家勾了就是決定，不再過可配量守衛）。
--     - 取消勾選 → **拉回 confirmed**（p_pullback_order_ids）：這批貨不配
--       給他，客人畫面從「運送中」變回「待到貨」，下一批貨到時可再配。
--       拉回必須在收貨**之前**做 —— 收貨邏輯 C 會把 shipping 單推 ready，
--       先退回才攔得住。
--   * 已確認（confirmed）＝照舊：勾選走 rpc_manual_allocate_confirmed_orders
--     （可配量、整單裝得下、閘門重驗、_trim_internal_pool 全部沿用）。
--
-- 內容：
--   1. rpc_get_transfer_allocation_preview：候選 status IN (confirmed, shipping)；
--      每張單多回 status（單頭）與 arrived（is_order_pickup_ready，前端據此
--      顯示會員端同款「待到貨／運送中／待取貨」標籤，判定對齊
--      apps/member OrderCard.orderPhase）。閘門只對候選陣列跑（先收陣列再
--      UNNEST，沿用 20260813020000 的防 planner 反排序手法）。
--      可配量的 promised **排除畫面上列出的 shipping 單** —— 它們的需求改成
--      「勾了才佔額度」，跟 confirmed 單同一套算法，前端把勾選需求逐 SKU
--      從上限扣掉即可；沒勾（＝會被拉回）就不佔。
--   2. rpc_receive_transfer_manual 加 p_pullback_order_ids BIGINT[] DEFAULT NULL
--      （簽名變了要 DROP 重建；PostgREST named-args 呼叫向下相容）。順序：
--      拉回 → 快照勾選中的 shipping 單 → 逐張收貨（p_auto_allocate=FALSE）→
--      勾選 shipping 單推 ready（多數已被邏輯 C 推掉，這裡收尾跨批次到貨、
--      閘門還沒開的 —— 店家勾了就是「這批貨給他」；比照邏輯 C 不做
--      _trim_internal_pool，池子收斂只屬於 confirmed 配單路徑）→
--      confirmed 勾選單交給 rpc_manual_allocate_confirmed_orders。
--      拉不回的（狀態已變，例如已經取貨）記在 pullback_skipped 回報、不擋收貨。
--
-- 基底版本（append-only，逐字保留所有 prior fix；已與線上
--   pg_get_functiondef 核對一致）：
--   rpc_get_transfer_allocation_preview = 20260813020000
--   rpc_receive_transfer_manual         = 20260813010000
--
-- Rollback：
--   DROP FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[]);
--   然後重跑 20260813010000 的 rpc_receive_transfer_manual、
--   20260813020000 的 rpc_get_transfer_allocation_preview。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_get_transfer_allocation_preview — 候選含 shipping + 客人狀態
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_transfer_allocation_preview(
  p_transfer_ids BIGINT[],
  p_lines        JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '60000'
AS $$
DECLARE
  v_ids        BIGINT[];
  v_tenant     UUID;
  v_dest       BIGINT;
  v_store      BIGINT;
  v_store_name TEXT;
  v_cnt        INT;
  v_incoming   JSONB;
  v_budget     JSONB;
  v_orders     JSONB;
  v_cand_ids   BIGINT[];
  v_ship_ids   BIGINT[];
BEGIN
  IF p_transfer_ids IS NULL OR cardinality(p_transfer_ids) = 0 THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;
  v_ids := ARRAY(SELECT DISTINCT UNNEST(p_transfer_ids));

  SELECT COUNT(*) INTO v_cnt FROM transfers WHERE id = ANY (v_ids);
  IF v_cnt <> cardinality(v_ids) THEN
    RAISE EXCEPTION '有調撥單不存在';
  END IF;
  IF EXISTS (SELECT 1 FROM transfers WHERE id = ANY (v_ids) AND status <> 'shipped') THEN
    RAISE EXCEPTION '只有待收貨（已派出）的調撥單可以邊收邊配';
  END IF;
  SELECT COUNT(*) INTO v_cnt
    FROM (SELECT DISTINCT tenant_id, dest_location
            FROM transfers WHERE id = ANY (v_ids)) x;
  IF v_cnt > 1 THEN
    RAISE EXCEPTION '跨分店的調撥單請分開處理';
  END IF;
  IF p_lines IS NOT NULL AND cardinality(v_ids) > 1 THEN
    RAISE EXCEPTION 'p_lines 只支援單張調撥單';
  END IF;

  SELECT tenant_id, dest_location INTO v_tenant, v_dest
    FROM transfers WHERE id = v_ids[1];

  -- 跨租戶守衛（讀頂層 tenant_id claim；沒有 claim 的 service 情境放行）
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'transfer not in current tenant';
  END IF;

  SELECT id, name INTO v_store, v_store_name
    FROM stores WHERE tenant_id = v_tenant AND location_id = v_dest
    LIMIT 1;
  IF v_store IS NULL THEN
    -- 目的地不是分店（例如退回總倉）→ 沒有顧客訂單可配
    RETURN jsonb_build_object(
      'store_id', NULL, 'store_name', NULL,
      'incoming', '[]'::jsonb, 'budget', '[]'::jsonb, 'orders', '[]'::jsonb);
  END IF;

  -- 本次到貨量：p_lines 有值的品項以實收為準，其餘 = 派出量（同 rpc_receive_transfer）
  WITH li AS (
    SELECT (l->>'transfer_item_id')::BIGINT AS tid,
           (l->>'qty_received')::NUMERIC    AS q
      FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) l
  ),
  inc AS (
    SELECT ti.sku_id, SUM(GREATEST(COALESCE(li.q, ti.qty_shipped), 0)) AS qty
      FROM transfer_items ti
      LEFT JOIN li ON li.tid = ti.id
     WHERE ti.transfer_id = ANY (v_ids)
     GROUP BY ti.sku_id
    HAVING SUM(GREATEST(COALESCE(li.q, ti.qty_shipped), 0)) > 0
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',   inc.sku_id,
           'sku_code', s.sku_code,
           'name',     TRIM(COALESCE(s.product_name, '')
                         || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                 THEN ' / ' || s.variant_name ELSE '' END),
           'qty',      inc.qty
         ) ORDER BY inc.sku_id), '[]'::jsonb)
    INTO v_incoming
    FROM inc JOIN skus s ON s.id = inc.sku_id;

  -- 對到的訂單：該店還在等貨的一般單（排除內部容器單），至少一個未取品項的
  -- SKU 在本次到貨清單裡。
  -- 20260814：confirmed（等貨中，可配）＋ shipping（波次出貨時已配給他，
  -- 可保留或拉回）都列。先收 id 陣列 —— 之後的訂單 JSON、閘門呼叫、
  -- promised 排除都以同一個集合為準。
  SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[]),
         COALESCE(ARRAY_AGG(co.id) FILTER (WHERE co.status = 'shipping'), '{}'::BIGINT[])
    INTO v_cand_ids, v_ship_ids
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = v_store
     AND co.status          IN ('confirmed', 'shipping')
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal'
     AND EXISTS (
       SELECT 1
         FROM customer_order_items coi
         JOIN transfer_items ti
           ON ti.transfer_id = ANY (v_ids)
          AND ti.sku_id      = coi.sku_id
        WHERE coi.order_id = co.id
          AND coi.status IN ('pending','reserved','ready')
     );

  -- 訂單 JSON：多回 status（單頭）與 arrived（取貨閘門）。閘門只對候選
  -- 陣列跑（20260813020000 的教訓：別讓 planner 有機會把閘門提前對全店跑）。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id',      co.id,
           'order_no',      co.order_no,
           'member_id',     co.member_id,
           'customer',      COALESCE(m.name, co.nickname_snapshot),
           'campaign_name', CASE WHEN LEFT(COALESCE(gbc.campaign_no, ''), 2) = '__'
                                 THEN NULL ELSE gbc.name END,
           'created_at',    co.created_at,
           'status',        co.status,
           'arrived',       public.is_order_pickup_ready(co.id),
           'items', (
             SELECT jsonb_agg(jsonb_build_object('sku_id', i.sku_id, 'qty', i.need)
                              ORDER BY i.sku_id)
               FROM (
                 SELECT coi.sku_id, SUM(coi.qty) AS need
                   FROM customer_order_items coi
                  WHERE coi.order_id = co.id
                    AND coi.status IN ('pending','reserved','ready')
                  GROUP BY coi.sku_id
               ) i
           )
         ) ORDER BY co.created_at, co.order_no), '[]'::jsonb)
    INTO v_orders
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN group_buy_campaigns gbc ON gbc.id = co.campaign_id
   WHERE co.id = ANY (v_cand_ids);

  -- 既有可配量（收貨前）：on_hand − 已承諾未取；promised 一次 GROUP BY 後 JOIN。
  -- 種子 = 到貨 SKU ∪ 候選單的全部未取 SKU（多品項單要每一項都有數字）。
  -- 20260814：promised 排除畫面上列出的 shipping 單（v_ship_ids）——
  -- 它們的需求改成「勾了才佔額度」，前端把勾選需求逐 SKU 從上限扣；
  -- 沒勾（會被拉回 confirmed）就不佔。畫面外的 shipping 單照舊預扣。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',    b.sku_id,
           'sku_code',  s.sku_code,
           'name',      TRIM(COALESCE(s.product_name, '')
                          || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                  THEN ' / ' || s.variant_name ELSE '' END),
           'available', b.avail
         ) ORDER BY b.sku_id), '[]'::jsonb)
    INTO v_budget
    FROM (
      SELECT sk.sku_id,
             COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0) AS avail
        FROM (
          SELECT DISTINCT ti.sku_id
            FROM transfer_items ti
           WHERE ti.transfer_id = ANY (v_ids)
          UNION
          SELECT DISTINCT coi.sku_id
            FROM customer_order_items coi
           WHERE coi.order_id = ANY (v_cand_ids)
             AND coi.status IN ('pending','reserved','ready')
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_dest
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN (
          SELECT coi2.sku_id, SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = v_store
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.status IN ('pending','reserved','ready')
             AND NOT (co2.id = ANY (v_ship_ids))
           GROUP BY coi2.sku_id
        ) pr ON pr.sku_id = sk.sku_id
    ) b
    JOIN skus s ON s.id = b.sku_id;

  RETURN jsonb_build_object(
    'store_id',   v_store,
    'store_name', v_store_name,
    'incoming',   v_incoming,
    'budget',     v_budget,
    'orders',     v_orders
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB) IS
  '收貨前的手動配單預覽：這批（同店）調撥單的到貨品項，對到該店 confirmed（等貨中）'
  '與 shipping（波次已配給他）的一般單，各附單頭 status 與 arrived（取貨閘門）。'
  '可配上限 = 既有可配（on_hand − 已承諾未取，排除畫面上的 shipping 單）＋ 本次到貨量。'
  '確認收貨走 rpc_receive_transfer_manual：沒勾的 shipping 單拉回 confirmed。';

GRANT EXECUTE ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 2. rpc_receive_transfer_manual — 加 p_pullback_order_ids（拉回派貨中訂單）
--    基底 20260813010000 逐字保留；加參數要先 DROP 舊簽名。
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB);

CREATE OR REPLACE FUNCTION public.rpc_receive_transfer_manual(
  p_transfer_ids       BIGINT[],
  p_operator           UUID,
  p_order_ids          BIGINT[] DEFAULT NULL,
  p_notes              TEXT     DEFAULT NULL,
  p_lines              JSONB    DEFAULT NULL,
  p_pullback_order_ids BIGINT[] DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '180000'
AS $$
DECLARE
  v_ids          BIGINT[];
  v_tenant       UUID;
  v_dest         BIGINT;
  v_store        BIGINT;
  v_cnt          INT;
  v_id           BIGINT;
  v_recv         JSONB;
  v_results      JSONB := '[]'::jsonb;
  v_alloc        JSONB := NULL;
  v_now          TIMESTAMPTZ := NOW();
  v_pulled       BIGINT[] := '{}'::BIGINT[];
  v_pull_skipped JSONB := '[]'::jsonb;
  v_chk_ship     BIGINT[] := '{}'::BIGINT[];
  v_ship_adv     INT := 0;
  v_conf         BIGINT[];
BEGIN
  IF p_transfer_ids IS NULL OR cardinality(p_transfer_ids) = 0 THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;
  v_ids := ARRAY(SELECT DISTINCT UNNEST(p_transfer_ids));

  SELECT COUNT(*) INTO v_cnt FROM transfers WHERE id = ANY (v_ids);
  IF v_cnt <> cardinality(v_ids) THEN
    RAISE EXCEPTION '有調撥單不存在';
  END IF;
  SELECT COUNT(*) INTO v_cnt
    FROM (SELECT DISTINCT tenant_id, dest_location
            FROM transfers WHERE id = ANY (v_ids)) x;
  IF v_cnt > 1 THEN
    RAISE EXCEPTION '跨分店的調撥單請分開處理';
  END IF;
  IF p_lines IS NOT NULL AND cardinality(v_ids) > 1 THEN
    RAISE EXCEPTION 'p_lines 只支援單張調撥單';
  END IF;
  -- 同一張單不能又配又拉 —— 一定是前端組參數組錯了，直接擋
  IF p_order_ids IS NOT NULL AND p_pullback_order_ids IS NOT NULL
     AND EXISTS (SELECT 1 FROM UNNEST(p_order_ids) o
                  WHERE o = ANY (p_pullback_order_ids)) THEN
    RAISE EXCEPTION '同一張訂單不能同時勾選配單又拉回';
  END IF;

  SELECT tenant_id, dest_location INTO v_tenant, v_dest
    FROM transfers WHERE id = v_ids[1];
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'transfer not in current tenant';
  END IF;

  SELECT id INTO v_store
    FROM stores WHERE tenant_id = v_tenant AND location_id = v_dest
    LIMIT 1;
  IF v_store IS NULL
     AND ((p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0)
       OR (p_pullback_order_ids IS NOT NULL AND cardinality(p_pullback_order_ids) > 0)) THEN
    RAISE EXCEPTION '目的地不是分店，無法配單';
  END IF;

  -- 拉回：沒勾的派貨中訂單退回 confirmed（這批貨不配給他，下批可再配）。
  -- **必須在收貨之前** —— 收貨邏輯 C 會把 shipping 單推 ready，先退回才攔得住。
  -- 拉不回的（狀態已變：已被收貨推進、已取貨…）記 pullback_skipped，不擋收貨。
  IF p_pullback_order_ids IS NOT NULL AND cardinality(p_pullback_order_ids) > 0 THEN
    WITH pulled AS (
      UPDATE customer_orders co
         SET status     = 'confirmed',
             updated_by = p_operator,
             updated_at = v_now
       WHERE co.id = ANY (p_pullback_order_ids)
         AND co.tenant_id       = v_tenant
         AND co.pickup_store_id = v_store
         AND co.status          = 'shipping'
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND NOT EXISTS (SELECT 1 FROM members m
                          WHERE m.id = co.member_id
                            AND m.member_type = 'store_internal')
      RETURNING co.id
    )
    SELECT COALESCE(ARRAY_AGG(id), '{}'::BIGINT[]) INTO v_pulled FROM pulled;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'order_id', u.oid,
             'order_no', co.order_no,
             'status',   COALESCE(co.status, 'not_found'))), '[]'::jsonb)
      INTO v_pull_skipped
      FROM (SELECT DISTINCT UNNEST(p_pullback_order_ids) AS oid) u
      LEFT JOIN customer_orders co ON co.id = u.oid
     WHERE NOT (u.oid = ANY (v_pulled));
  END IF;

  -- 勾選中的派貨中訂單快照（收貨前）：收完貨要推「可取貨」的集合
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[])
      INTO v_chk_ship
      FROM customer_orders co
      LEFT JOIN members m ON m.id = co.member_id
     WHERE co.id = ANY (p_order_ids)
       AND co.tenant_id       = v_tenant
       AND co.pickup_store_id = v_store
       AND co.status          = 'shipping'
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND COALESCE(m.member_type, '') <> 'store_internal';
  END IF;

  -- 逐張收貨（不自動配單）。**沒有 savepoint** —— 任何一張失敗整包回滾，
  -- 對應「按確認才完成收貨」：失敗＝什麼都沒發生，跟批次收貨的部分成功語意不同。
  FOREACH v_id IN ARRAY v_ids LOOP
    v_recv := public.rpc_receive_transfer(
      v_id,
      CASE WHEN cardinality(v_ids) = 1 THEN p_lines ELSE NULL END,
      p_operator, p_notes, FALSE);
    v_results := v_results || jsonb_build_array(v_recv);
  END LOOP;

  -- 勾選的派貨中訂單 → 可取貨。同波次到貨的多數已被收貨邏輯 C 推掉
  -- （閘門放行），這裡收尾跨批次到貨、閘門還沒開的 —— 店家勾了就是
  -- 「這批貨給他」，與邏輯 C 同樣 qty-blind、不做 _trim_internal_pool
  -- （波次貨不動現貨池；池子收斂只屬於 confirmed 配單路徑）。
  IF cardinality(v_chk_ship) > 0 THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = v_now,
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = ANY (v_chk_ship)
       AND status = 'shipping';

    SELECT COUNT(*) INTO v_ship_adv
      FROM customer_orders
     WHERE id = ANY (v_chk_ship) AND status = 'ready';
  END IF;

  -- 配單（confirmed 勾選單）：守衛全在 rpc_manual_allocate_confirmed_orders 裡
  -- （可配量、整單裝得下、閘門重驗、池子收斂；裝不下回報 skipped 不硬推）。
  -- 派貨中快照已在上面處理，剩下的照舊交給配單 RPC —— 狀態不符的它會
  -- 回報 not_eligible，跳過原因不遺失。
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    v_conf := ARRAY(SELECT DISTINCT UNNEST(p_order_ids)
                    EXCEPT SELECT UNNEST(v_chk_ship));
    IF cardinality(v_conf) > 0 THEN
      v_alloc := public.rpc_manual_allocate_confirmed_orders(v_store, v_conf, p_operator);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'transfers_received', cardinality(v_ids),
    'received',           v_results,
    'pulled_back',        COALESCE(cardinality(v_pulled), 0),
    'pullback_skipped',   v_pull_skipped,
    'shipping_advanced',  v_ship_adv,
    'allocation',         v_alloc
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[]) IS
  '手動配貨的一段式確認：單一交易內 拉回沒勾的派貨中訂單（shipping → confirmed，'
  '收貨前做，攔住邏輯 C）→ 逐張 rpc_receive_transfer(p_auto_allocate=FALSE) → '
  '勾選的派貨中訂單推可取貨（邏輯 C 同語意）→ confirmed 勾選單走 '
  'rpc_manual_allocate_confirmed_orders。無 savepoint —— 任何一步失敗整包回滾'
  '（確認才完成收貨；取消/失敗＝什麼都沒發生）。';

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[])
  TO authenticated, service_role;

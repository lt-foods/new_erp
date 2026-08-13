-- ============================================================
-- 2026-08-13 (2)：手動配貨改成「先勾單、確認才收貨」
--
-- Alex 對第一版流程的回饋：太複雜。要的很單純 ——
--   按「✋ 收貨·手動配」→ 直接跳出**這張到貨單對到的訂單** →
--   勾選要配的 → 按確認 → 這時才完成收貨＋配單（取消＝什麼都沒發生）。
--
-- 第一版是「先收貨（p_auto_allocate=false）→ 再開店家層級的配單視窗」，
-- 兩段式而且候選是全店範圍。本檔補兩支 RPC 讓流程變一段式、範圍縮到單張：
--
--   1. rpc_get_transfer_allocation_preview(p_transfer_ids, p_lines)
--      收貨**之前**的候選預覽：這批單（同店，可多張）的到貨品項，
--      對到該店還在等貨的 confirmed 一般單。因為貨還沒入庫，
--      不查 is_order_pickup_ready、不看 on_hand 前置篩 ——
--      可配量 = 既有可配（on_hand − 已承諾未取，與 _advance_arrived_confirmed_orders
--      同算法）＋ 本次到貨量（p_lines 有值時以實收為準，僅限單張）。
--
--   2. rpc_receive_transfer_manual(p_transfer_ids, p_operator, p_order_ids,
--      p_notes, p_lines)
--      單一交易內：逐張 rpc_receive_transfer(..., p_auto_allocate=FALSE)
--      → rpc_manual_allocate_confirmed_orders(店, 勾選的單)。
--      **刻意不做 savepoint**：任何一步失敗整包回滾，對應「確認才完成收貨」
--      的語意。配單側的守衛全部沿用（可配量、整單裝得下才推、閘門重驗、
--      池子收斂）—— 預覽算的量與確認時實際配的量同一套帳，
--      但以確認當下重算的為準，裝不下的單回報原因、不硬推。
--
-- 既有 RPC 一律不動（純新增）：
--   - 自動配路徑（p_auto_allocate=TRUE 預設）原樣。
--   - rpc_get_manual_allocation_candidates / rpc_manual_allocate_confirmed_orders
--     保留給「✋ 手動配單」常駐入口（收完貨之後想再配時用，全店範圍）。
--
-- Rollback：
--   DROP FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB);
--   DROP FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB);
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_get_transfer_allocation_preview — 收貨前的配單候選預覽
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_transfer_allocation_preview(
  p_transfer_ids BIGINT[],
  p_lines        JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
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

  -- 對到的訂單：該店還在等貨的 confirmed 一般單（排除內部容器單），
  -- 至少一個未取品項的 SKU 在本次到貨清單裡。貨還沒入庫，所以**不**查
  -- is_order_pickup_ready、也不做 on_hand 前置篩 —— 確認收貨後配單側會重驗。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id',      co.id,
           'order_no',      co.order_no,
           'member_id',     co.member_id,
           'customer',      COALESCE(m.name, co.nickname_snapshot),
           'campaign_name', CASE WHEN LEFT(COALESCE(gbc.campaign_no, ''), 2) = '__'
                                 THEN NULL ELSE gbc.name END,
           'created_at',    co.created_at,
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
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = v_store
     AND co.status          = 'confirmed'
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

  -- 既有可配量（收貨前）：on_hand − 已承諾未取，算法與
  -- _advance_arrived_confirmed_orders 逐字同一套；回原始值（可能為負），
  -- 前端把「既有 + 本次到貨」當上限即等於收貨後配單側會算出的預算。
  -- 種子 = 到貨 SKU ∪ 對到訂單的全部未取 SKU（多品項單要每一項都有數字）。
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
            FROM customer_orders co
            LEFT JOIN members m ON m.id = co.member_id
            JOIN customer_order_items coi ON coi.order_id = co.id
           WHERE co.tenant_id       = v_tenant
             AND co.pickup_store_id = v_store
             AND co.status          = 'confirmed'
             AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
             AND COALESCE(m.member_type, '') <> 'store_internal'
             AND coi.status IN ('pending','reserved','ready')
             AND EXISTS (
               SELECT 1 FROM customer_order_items coi2
                 JOIN transfer_items ti2
                   ON ti2.transfer_id = ANY (v_ids) AND ti2.sku_id = coi2.sku_id
                WHERE coi2.order_id = co.id
                  AND coi2.status IN ('pending','reserved','ready'))
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_dest
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN LATERAL (
          SELECT SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = v_store
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.sku_id = sk.sku_id
             AND coi2.status IN ('pending','reserved','ready')
        ) pr ON TRUE
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
  '收貨前的手動配單預覽：這批（同店）調撥單的到貨品項，對到該店還在等貨的 confirmed'
  '一般單。可配上限 = 既有可配（on_hand − 已承諾未取）＋ 本次到貨量。'
  '確認收貨時走 rpc_receive_transfer_manual，配單側會以當下重算的帳為準再驗一次。';

GRANT EXECUTE ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 2. rpc_receive_transfer_manual — 確認＝收貨＋配單，一個交易
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer_manual(
  p_transfer_ids BIGINT[],
  p_operator     UUID,
  p_order_ids    BIGINT[] DEFAULT NULL,
  p_notes        TEXT     DEFAULT NULL,
  p_lines        JSONB    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '180000'
AS $$
DECLARE
  v_ids     BIGINT[];
  v_tenant  UUID;
  v_dest    BIGINT;
  v_store   BIGINT;
  v_cnt     INT;
  v_id      BIGINT;
  v_recv    JSONB;
  v_results JSONB := '[]'::jsonb;
  v_alloc   JSONB := NULL;
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

  SELECT tenant_id, dest_location INTO v_tenant, v_dest
    FROM transfers WHERE id = v_ids[1];
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'transfer not in current tenant';
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

  -- 配單：守衛全在 rpc_manual_allocate_confirmed_orders 裡
  -- （可配量、整單裝得下、閘門重驗、池子收斂；裝不下回報 skipped 不硬推）
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    SELECT id INTO v_store
      FROM stores WHERE tenant_id = v_tenant AND location_id = v_dest
      LIMIT 1;
    IF v_store IS NULL THEN
      RAISE EXCEPTION '目的地不是分店，無法配單';
    END IF;
    v_alloc := public.rpc_manual_allocate_confirmed_orders(v_store, p_order_ids, p_operator);
  END IF;

  RETURN jsonb_build_object(
    'transfers_received', cardinality(v_ids),
    'received',           v_results,
    'allocation',         v_alloc
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB) IS
  '手動配貨的一段式確認：單一交易內逐張 rpc_receive_transfer(p_auto_allocate=FALSE) 後'
  '把勾選的訂單交給 rpc_manual_allocate_confirmed_orders 推可取貨。無 savepoint ——'
  '任何一步失敗整包回滾（確認才完成收貨；取消/失敗＝什麼都沒發生）。';

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB)
  TO authenticated, service_role;

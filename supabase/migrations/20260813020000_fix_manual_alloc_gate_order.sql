-- ============================================================
-- 2026-08-13 (3)：手動配單候選查詢 timeout — 強制先預篩再跑閘門
--
-- 災情（文山店倉，上線當天）：「✋ 手動配單」彈窗一開就
--   canceling statement due to statement timeout（PostgREST 預設 8s）。
--
-- 量測（store 46，confirmed 1,704 張、預篩後候選 27 張）：
--   整支 rpc_get_manual_allocation_candidates … 8,877 ms
--   同邏輯拆兩步跑：預篩 21 ms → 閘門×27 147 ms → 可配量 393 ms ≈ 0.6 s
--
-- 根因：候選查詢把「便宜的預篩 EXISTS」和「昂貴的 is_order_pickup_ready()」
--   放在同一個 WHERE，靠子句順序暗示先後 —— 但 planner 不吃這套，實際對
--   1,704 張單**每張**先跑了閘門（1,704 × ~5ms ≈ 8.5s）。註解寫「先擋掉
--   絕大多數候選才輪到昂貴的閘門」，執行計畫根本沒照做。
--
-- 修法（單純重排，語意完全不變）：
--   1. 預篩結果先 materialize（CTE MATERIALIZED / 先收進陣列），
--      閘門只對倖存者跑 —— planner 沒有機會再把閘門提前。
--   2. 可配量的 promised 從 per-SKU LATERAL 改成一次 GROUP BY 後 JOIN
--      （同一份帳算一次而不是 N 次；數值逐一相同）。
--   3. rpc_get_manual_allocation_candidates 的 budget 種子從「全店 confirmed
--      單的 SKU」縮成「候選單的 SKU」—— 彈窗只拿 budget 算候選單裝不裝得下
--      與顯示，非候選 SKU 的列從沒被用到；每 SKU 的數值不變，只是少算沒用的列。
--   4. 兩支查詢型 RPC 加 statement_timeout 60s 當保險（正常 <1s）。
--
-- 影響範圍：
--   - rpc_get_manual_allocation_candidates（手動配單彈窗 — 本次災情）
--   - _advance_arrived_confirmed_orders（收貨自動配單 — 同款寫法，
--     大店收貨同樣會被 planner 反排序拖到逾時邊緣，一併修）
--   - rpc_get_transfer_allocation_preview（收貨前預覽 — 沒有閘門呼叫，
--     只吃第 2 點的 promised 單趟化 + 保險 timeout）
--
-- 基底版本（append-only，逐字保留、只動上述四點）：
--   _advance_arrived_confirmed_orders      = 20260813000000（5 參數版）
--   rpc_get_manual_allocation_candidates   = 20260813000000
--   rpc_get_transfer_allocation_preview    = 20260813010000
-- Rollback：各函式 CREATE OR REPLACE 回上列基底版本。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _advance_arrived_confirmed_orders — 預篩 materialize + promised 單趟
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._advance_arrived_confirmed_orders(
  p_store_id  BIGINT,
  p_sku_ids   BIGINT[],
  p_operator  UUID,
  p_at        TIMESTAMPTZ DEFAULT NOW(),
  p_order_ids BIGINT[]    DEFAULT NULL
) RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_budget   JSONB   := '{}'::JSONB;   -- sku_id(text) → 尚可配數量
  v_alloc    JSONB   := '{}'::JSONB;   -- sku_id(text) → 本次實際配出去的量
  v_ord      RECORD;
  v_it       RECORD;
  v_fits     BOOLEAN;
  v_rem      NUMERIC;
  v_advanced INT := 0;
BEGIN
  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;

  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;   -- 沒設倉庫位置的店沒有 on_hand 可算，直接不動
  END IF;

  -- 可配量：本店現有庫存 − 已承諾未取量。
  -- 種子集合＝本店所有 confirmed 單的未取 SKU（不限 p_sku_ids）——
  -- 多品項的單要每一項都有預算才能推，所以預算表不能只放這次到貨的 SKU。
  -- 20260813(3)：promised 改成一次 GROUP BY 後 JOIN（原本 per-SKU LATERAL
  -- 對同一份帳掃 N 次，大店 ~500 SKU 要掃 500 趟）。
  SELECT COALESCE(jsonb_object_agg(b.sku_id::TEXT, b.avail), '{}'::JSONB)
    INTO v_budget
    FROM (
      SELECT sk.sku_id,
             COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0) AS avail
        FROM (
          SELECT DISTINCT coi.sku_id
            FROM customer_orders co
            JOIN customer_order_items coi ON coi.order_id = co.id
           WHERE co.tenant_id       = v_tenant
             AND co.pickup_store_id = p_store_id
             AND co.status          = 'confirmed'
             AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
             AND coi.status IN ('pending','reserved','ready')
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_loc
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN (
          -- 已經被承諾、貨還沒交出去的量。排除 store_internal 會員的單
          --（RR- / 【內部】xx 店是現貨池容器，不是對客人的承諾）。
          SELECT coi2.sku_id, SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = p_store_id
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.status IN ('pending','reserved','ready')
           GROUP BY coi2.sku_id
        ) pr ON pr.sku_id = sk.sku_id
    ) b;

  IF v_budget = '{}'::JSONB THEN
    RETURN 0;
  END IF;

  -- 依下單時間由早到晚（同時間用單號決勝，與 20260805000070 同規則）
  -- p_order_ids 有值時只考慮這些單（手動配單）。
  -- 20260813(3)：預篩結果 MATERIALIZED 再跑閘門 —— 原本同一個 WHERE，
  -- planner 會把昂貴的 is_order_pickup_ready() 提前對全部 confirmed 單跑
  -- （文山 1,704 張 × ~5ms ≈ 8.5s，PostgREST 8s 直接 timeout）。
  FOR v_ord IN
    WITH pre AS MATERIALIZED (
      SELECT co.id, co.created_at, co.order_no
        FROM customer_orders co
       WHERE co.tenant_id       = v_tenant
         AND co.pickup_store_id = p_store_id
         AND co.status          = 'confirmed'
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND (p_order_ids IS NULL OR co.id = ANY (p_order_ids))
         -- 便宜的前置篩：至少一項是這次到貨的 SKU、且店裡真的有帳上庫存
         AND EXISTS (
           SELECT 1
             FROM customer_order_items coi
             JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_loc
              AND sb.sku_id      = coi.sku_id
              AND sb.on_hand     > 0
            WHERE coi.order_id = co.id
              AND coi.status IN ('pending','reserved','ready')
              AND (p_sku_ids IS NULL OR coi.sku_id = ANY (p_sku_ids))
         )
    )
    SELECT pre.id
      FROM pre
     -- 整單閘門：所有未取品項都到貨（Path A~D'、qty_received > 0、backorder_at）
     WHERE public.is_order_pickup_ready(pre.id)
     ORDER BY pre.created_at, pre.order_no
  LOOP
    -- 裝得下才推：整單每一個 SKU 的需求都要在預算內（不拆行）
    v_fits := TRUE;
    FOR v_it IN
      SELECT coi.sku_id, SUM(coi.qty) AS need
        FROM customer_order_items coi
       WHERE coi.order_id = v_ord.id
         AND coi.status IN ('pending','reserved','ready')
       GROUP BY coi.sku_id
    LOOP
      IF COALESCE((v_budget ->> v_it.sku_id::TEXT)::NUMERIC, 0) < v_it.need THEN
        v_fits := FALSE;
        EXIT;
      END IF;
    END LOOP;

    IF NOT v_fits THEN
      CONTINUE;   -- 裝不下就跳過，繼續試後面的小單（維持 confirmed 等下批貨）
    END IF;

    FOR v_it IN
      SELECT coi.sku_id, SUM(coi.qty) AS need
        FROM customer_order_items coi
       WHERE coi.order_id = v_ord.id
         AND coi.status IN ('pending','reserved','ready')
       GROUP BY coi.sku_id
    LOOP
      v_rem := COALESCE((v_budget ->> v_it.sku_id::TEXT)::NUMERIC, 0) - v_it.need;
      v_budget := jsonb_set(v_budget, ARRAY[v_it.sku_id::TEXT], to_jsonb(v_rem));
      -- 20260811(4)：記下本次配出量，稍後用來收斂現貨池
      v_alloc := jsonb_set(
        v_alloc, ARRAY[v_it.sku_id::TEXT],
        to_jsonb(COALESCE((v_alloc ->> v_it.sku_id::TEXT)::NUMERIC, 0) + v_it.need));
    END LOOP;

    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = p_at,
           updated_by = p_operator,
           updated_at = p_at
     WHERE id = v_ord.id
       AND status = 'confirmed';

    v_advanced := v_advanced + 1;
  END LOOP;

  -- 20260811(4)：配出去的貨已經是客人的了，【內部】xx 店的池子不能再掛著同一批
  FOR v_it IN
    SELECT k.key::BIGINT AS sku_id, k.value::NUMERIC AS allocated
      FROM jsonb_each_text(v_alloc) k
  LOOP
    PERFORM public._trim_internal_pool(
      p_store_id, v_it.sku_id, v_it.allocated, p_operator, p_at);
  END LOOP;

  RETURN v_advanced;
END;
$$;

COMMENT ON FUNCTION public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ, BIGINT[]) IS
  '到貨後把該店 confirmed 的客人訂單依訂單時間推 ready。守衛：整單過 is_order_pickup_ready'
  ' + 可配量（on_hand − 已承諾未取，排除 store_internal 容器單）裝得下才推。'
  '配完呼叫 _trim_internal_pool 收斂現貨池。p_sku_ids = NULL → 該店所有 SKU；'
  'p_order_ids 有值 = 手動配單（只考慮這些單）。'
  '20260813(3)：預篩 MATERIALIZED 再跑閘門（防 planner 把閘門提前對全店跑）、promised 單趟化。';

GRANT EXECUTE ON FUNCTION public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ, BIGINT[])
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 2. rpc_get_manual_allocation_candidates — 兩步跑 + budget 縮到候選 SKU
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_manual_allocation_candidates(
  p_store_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '60000'
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_pre_ids  BIGINT[];
  v_cand_ids BIGINT[];
  v_total    INT := 0;
  v_budget   JSONB;
  v_orders   JSONB;
BEGIN
  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;
  -- 跨租戶守衛。直接讀頂層 tenant_id claim（hook 有拉，見 CLAUDE.md）；
  -- 不用 _current_tenant_id() —— 它在沒有 claim 時會 RAISE，service_role 會炸。
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'store % not in current tenant', p_store_id;
  END IF;
  IF v_loc IS NULL THEN
    -- 沒設倉庫位置的店算不出可配量（同 helper 直接不動）
    RETURN jsonb_build_object(
      'store_id', p_store_id, 'budget', '[]'::jsonb,
      'orders', '[]'::jsonb, 'waiting_count', 0);
  END IF;

  -- 20260813(3)：預篩先收進陣列、閘門只對倖存者跑。原本寫在同一個 WHERE，
  -- planner 把 is_order_pickup_ready() 提前對全部 confirmed 單跑
  -- （文山 1,704 張 ≈ 8.9s → PostgREST 8s timeout）。拆開後 ~0.2s。
  SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[])
    INTO v_pre_ids
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status          = 'confirmed'
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal'
     AND EXISTS (
       SELECT 1
         FROM customer_order_items coi
         JOIN stock_balances sb
           ON sb.tenant_id   = v_tenant
          AND sb.location_id = v_loc
          AND sb.sku_id      = coi.sku_id
          AND sb.on_hand     > 0
        WHERE coi.order_id = co.id
          AND coi.status IN ('pending','reserved','ready')
     );

  SELECT COALESCE(ARRAY_AGG(u), '{}'::BIGINT[])
    INTO v_cand_ids
    FROM UNNEST(v_pre_ids) u
   WHERE public.is_order_pickup_ready(u);

  -- 分母：本店全部 confirmed 一般單（排除內部容器）——
  -- 差額 = 貨還沒到齊 / 店裡沒庫存、目前配不了的張數，前端當註腳顯示。
  SELECT COUNT(*)
    INTO v_total
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status          = 'confirmed'
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal';

  -- 各 SKU 可配量：算法與 _advance_arrived_confirmed_orders 同一套。
  -- 20260813(3)：種子縮成**候選單**的未取 SKU（彈窗只拿 budget 算候選單
  -- 裝不裝得下與顯示，非候選 SKU 的列從沒被用到；每 SKU 數值不變）；
  -- promised 改一次 GROUP BY 後 JOIN。available 回原始值（可為負）。
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
          SELECT DISTINCT coi.sku_id
            FROM customer_order_items coi
           WHERE coi.order_id = ANY (v_cand_ids)
             AND coi.status IN ('pending','reserved','ready')
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_loc
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN (
          SELECT coi2.sku_id, SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = p_store_id
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.status IN ('pending','reserved','ready')
           GROUP BY coi2.sku_id
        ) pr ON pr.sku_id = sk.sku_id
    ) b
    JOIN skus s ON s.id = b.sku_id;

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
   WHERE co.id = ANY (v_cand_ids);

  RETURN jsonb_build_object(
    'store_id',      p_store_id,
    'budget',        v_budget,
    'orders',        v_orders,
    'waiting_count', GREATEST(v_total - COALESCE(cardinality(v_cand_ids), 0), 0)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_get_manual_allocation_candidates(BIGINT) IS
  '手動配單彈窗的候選清單：本店 confirmed 一般單（排除 store_internal 容器單）且'
  '貨已到齊（is_order_pickup_ready）者，附各 SKU 可配量（on_hand − 已承諾未取，'
  '算法對齊 _advance_arrived_confirmed_orders）。waiting_count = 其餘配不了的張數。'
  '20260813(3)：預篩先收陣列、閘門只對倖存者跑（防 planner 反排序造成 timeout）。';

GRANT EXECUTE ON FUNCTION public.rpc_get_manual_allocation_candidates(BIGINT)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 3. rpc_get_transfer_allocation_preview — promised 單趟化 + 保險 timeout
--    （沒有閘門呼叫，本來就不會踩 planner 反排序；純吃效能小改）
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

  -- 既有可配量（收貨前）：on_hand − 已承諾未取；promised 一次 GROUP BY 後 JOIN。
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
  '收貨前的手動配單預覽：這批（同店）調撥單的到貨品項，對到該店還在等貨的 confirmed'
  '一般單。可配上限 = 既有可配（on_hand − 已承諾未取）＋ 本次到貨量。'
  '20260813(3)：promised 單趟化 + statement_timeout 60s 保險。';

GRANT EXECUTE ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB)
  TO authenticated, service_role;

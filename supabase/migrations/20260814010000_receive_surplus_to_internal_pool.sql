-- ============================================================
-- 2026-08-14 (2)：收貨多給的量要跳出【內部】店（掛進現貨池）
--
-- 需求（Alex 2026-08-14，附三峽店截圖）：「多給的要跳出內部店」。
--   收貨·手動配到貨 5 件、對到 3 張客人單（各 ×1）→ 剩 2 件沒有訂單主人。
--   目前這 2 件收貨後只進 on_hand，**帳上沒有任何訂單載體** ——
--   【內部】xx 店現貨池（RR- / OV- 容器單）看不到它，店員就無法用
--   「轉單給客人」把它賣掉；盤點時也是一筆看不見的自由庫存
--   （實測三峽鹹檸糖：on_hand 5、承諾 3、池子 0 → 2 件隱形）。
--
-- 修法：
--   1. _grow_internal_pool(store, sku, max_grow, operator, at, tag)：
--      _trim_internal_pool（20260811000030）的鏡像 ——
--        grow = LEAST(p_max_grow,
--                     GREATEST(on_hand − 已承諾未取 − confirmed 未配需求 − 池子未取, 0))
--      比 trim 的目標水位多扣「confirmed 未配需求」：還沒配到貨的客人單
--      （含被拉回的派貨中單）下一批就要吃這批貨，先掛進池子會被轉走 ——
--      就是 20260811000030 檔頭那種「8 位團友撲空」災情的鏡像版。
--      LEAST(p_max_grow, ...) 同 trim：只掛本批造成的自由量，
--      不順手做全域收斂。
--   2. 容器單 _get_or_create_surplus_pool_order(store)：order_no='OV-<store>-<seq>'、
--      掛 restock sentinel trio（__INTERNAL_RESTOCK__ campaign ＋ 店 sentinel
--      channel ＋【內部】xx 店 member）、order_kind='restock'、單頭 ready。
--      * kind 沿用 'restock'（＝ RR- 現貨池那一套）：全站 42 處
--        order_kind='restock' 的消費者都另外用 order_no / external_order_no
--        = 'RR-<id>' 對帳（settle / unsettle / 刪申請連帶刪單），吃不到 OV-；
--        反過來若用 'normal'，這張掛在 sentinel 團的內部單會混進所有
--        「(order_kind='normal' OR IS NULL)」的顧客單口徑（金額、缺口、報表）。
--      * 每店同時一張 active 容器由 advisory lock + 查既有 OV- 保證
--        （restock 被 customer_orders_trio_kind_active_uniq 排除，靠索引擋不到）；
--        既有的就 append 品項，收尾成 completed / cancelled 之後才開新號。
--      * 單頭 ready = 貨就在店裡，馬上可轉單（rpc_transfer_order_partial 要求
--        來源 status='ready'）；_trim_internal_pool 也只吃 ready /
--        partially_completed 的池子（20260811000040），這張要吃得到。
--   3. rpc_receive_transfer_manual：收貨＋配單之後，逐 SKU 把
--      「本批實收 − 本次配掉（保留勾選的派貨中單＋本次推 ready 的 confirmed 單）」
--      交給 _grow_internal_pool，品項 notes 標 [收貨多給|TF#<ids>]，
--      回傳新增 'surplus'（前端顯示掛了幾件）。
--   4. rpc_get_transfer_allocation_preview：budget 每列多回 'pool'
--      （池子既有未取掛帳）—— 前端據此預估「內部店會拿到幾件」，
--      跟伺服端同一套帳。
--   5. rpc_unreceive_transfer 加反向邏輯 F：退回收貨時把 notes 帶
--      [收貨多給|TF#本單] 的池子列沖銷（cancelled 留痕）；貨已經退回在途，
--      池子繼續掛著＝店員會把不存在的貨轉出去（20260811000030 忠順同型）。
--      已被轉單吃掉的部分不處理 —— 重新收貨時 _grow_internal_pool 依當下
--      自由量重算，自然不會再掛回來。
--   6. rpc_receive_transfer 加邏輯 F：預設的「收貨·自動配」與批次收貨也走
--      同一支 helper 掛多給（多給是收貨的規則，不是手動配那顆按鈕的規則）。
--      **排在邏輯 B/C/E 之後** —— 先把貨配給客人（配掉的算已承諾未取），
--      剩下的才是沒有主人的量。
--   7. 回填：2026-08-13（收貨·手動配上線日）以來已收貨的 (店, SKU)，
--      依同一套公式補掛（實測 13 組容器 / 67 列 / 154 件、13 家店，
--      含三峽截圖那 2 件鹹檸糖）。更早的自由庫存是另一個題目
--      （20260811000030 檔頭：395 組歷史掛帳），不順手全域收斂。
--      回填列標 [收貨多給|補掛20260814]、不帶 TF# —— 它是多張調撥的加總，
--      對不到單一調撥，所以**不會**被退回收貨的反向邏輯 F 沖銷（要清請人工作廢）。
--
-- 基底版本（append-only，逐字保留所有 prior fix；已與線上
--   pg_get_functiondef 逐字 diff 確認一致）：
--   rpc_get_transfer_allocation_preview = 20260814000000
--   rpc_receive_transfer_manual         = 20260814000000
--   rpc_unreceive_transfer              = 20260810000000
--   rpc_receive_transfer                = 20260813000000
--
-- Rollback：
--   重跑 20260814000000 的兩支、20260810000000 的 rpc_unreceive_transfer、
--   20260813000000 的 rpc_receive_transfer；
--   DROP FUNCTION public._grow_internal_pool(BIGINT,BIGINT,NUMERIC,UUID,TIMESTAMPTZ,TEXT);
--   DROP FUNCTION public._get_or_create_surplus_pool_order(BIGINT,UUID,TIMESTAMPTZ);
--   回填還原（逐張確認）：
--     SELECT * FROM customer_order_items WHERE notes LIKE '%[收貨多給%';
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _get_or_create_surplus_pool_order — 每店一張 active 的多給容器單
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._get_or_create_surplus_pool_order(
  p_store_id BIGINT,
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID;
  v_store_name TEXT;
  v_member     BIGINT;
  v_campaign   BIGINT;
  v_channel    BIGINT;
  v_order_id   BIGINT;
  v_status     TEXT;
  v_seq        INT;
  v_order_no   TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('surplus_pool:' || p_store_id::TEXT));

  SELECT tenant_id, name INTO v_tenant, v_store_name
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;

  v_member   := public.rpc_get_or_create_store_member(p_store_id, p_operator);
  v_campaign := public._restock_sentinel_campaign(v_tenant);
  v_channel  := public._restock_sentinel_channel(v_tenant, p_store_id);

  -- 既有的 active 容器（收尾成 completed / cancelled 之後才開新號）。
  -- 只認 OV- —— 同 trio 的 RR- ride-along 單是另一套帳（按 order_no 對齊
  -- 實收、由 _settle_restock_ride_along 收尾），不可以把多給的貨混進去。
  SELECT id, status INTO v_order_id, v_status
    FROM customer_orders
   WHERE tenant_id       = v_tenant
     AND pickup_store_id = p_store_id
     AND member_id       = v_member
     AND order_kind      = 'restock'
     AND order_no LIKE 'OV-' || p_store_id::TEXT || '-%'
     AND status NOT IN ('transferred_out', 'expired', 'cancelled', 'completed')
   ORDER BY id
   LIMIT 1;

  IF v_order_id IS NOT NULL THEN
    -- 貨就在店裡：容器維持可轉單狀態（partially_completed 已取過一部分，不動）
    IF v_status <> 'partially_completed' THEN
      UPDATE customer_orders
         SET status     = 'ready',
             ready_at   = COALESCE(ready_at, p_at),
             updated_by = p_operator,
             updated_at = p_at
       WHERE id = v_order_id
         AND status <> 'ready';
    END IF;
    RETURN v_order_id;
  END IF;

  SELECT COUNT(*) + 1 INTO v_seq
    FROM customer_orders
   WHERE tenant_id = v_tenant
     AND order_no LIKE 'OV-' || p_store_id::TEXT || '-%';
  v_order_no := 'OV-' || p_store_id::TEXT || '-' || LPAD(v_seq::TEXT, 4, '0');

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id, pickup_store_id,
    status, ready_at, order_kind, order_type, notes,
    created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant, v_order_no, v_campaign, v_channel, v_member, p_store_id,
    'ready', p_at, 'restock', 'regular',
    '【內部】收貨多給現貨池 — 到貨超過訂單需求的量掛在這裡，可轉單給客人',
    p_operator, p_operator, p_at, p_at
  ) RETURNING id INTO v_order_id;

  RETURN v_order_id;
END;
$$;

COMMENT ON FUNCTION public._get_or_create_surplus_pool_order(BIGINT, UUID, TIMESTAMPTZ) IS
  '取得 / 建立該店的收貨多給容器單（order_no=OV-<store>-<seq>、restock sentinel trio、'
  'order_kind=restock、單頭 ready 以便轉單）。同店同時只留一張 active 容器'
  '（advisory lock + 查既有 OV-）；RR- ride-along 單另一套帳，不會被當成容器。';

GRANT EXECUTE ON FUNCTION public._get_or_create_surplus_pool_order(BIGINT, UUID, TIMESTAMPTZ)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 2. _grow_internal_pool — 把收貨多給的量掛進【內部】xx 店現貨池
--    _trim_internal_pool 的鏡像。回傳實際掛進去的數量。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._grow_internal_pool(
  p_store_id BIGINT,
  p_sku_id   BIGINT,
  p_max_grow NUMERIC,
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW(),
  p_tag      TEXT        DEFAULT '[收貨多給]'
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_pool_qty NUMERIC;
  v_on_hand  NUMERIC := 0;
  v_promised NUMERIC := 0;
  v_waiting  NUMERIC := 0;
  v_grow     NUMERIC;
  v_order_id BIGINT;
  v_campaign BIGINT;
  v_price    NUMERIC;
  v_ci       BIGINT;
BEGIN
  IF p_max_grow IS NULL OR p_max_grow <= 0 THEN
    RETURN 0;
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;
  END IF;

  -- 池子目前掛著的未取量（定義同 _trim_internal_pool）
  SELECT COALESCE(SUM(coi.qty), 0) INTO v_pool_qty
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status NOT IN ('cancelled','expired','transferred_out','completed')
     AND coi.sku_id = p_sku_id
     AND coi.status IN ('pending','reserved','ready');

  SELECT COALESCE(sb.on_hand, 0) INTO v_on_hand
    FROM stock_balances sb
   WHERE sb.tenant_id = v_tenant AND sb.location_id = v_loc AND sb.sku_id = p_sku_id;
  v_on_hand := COALESCE(v_on_hand, 0);

  -- 對客人的承諾（未取）；排除 store_internal 容器單與抵減單（同 _trim）
  SELECT COALESCE(SUM(coi2.qty), 0) INTO v_promised
    FROM customer_orders co2
    JOIN customer_order_items coi2 ON coi2.order_id = co2.id
    LEFT JOIN members m2 ON m2.id = co2.member_id
   WHERE co2.tenant_id       = v_tenant
     AND co2.pickup_store_id = p_store_id
     AND co2.status IN ('ready','partially_completed','shipping')
     AND COALESCE(co2.order_kind, 'normal') <> 'offset'
     AND COALESCE(m2.member_type, '') <> 'store_internal'
     AND coi2.sku_id = p_sku_id
     AND coi2.status IN ('pending','reserved','ready');

  -- 還在等貨的 confirmed 一般單需求 —— trim 沒有這一項，grow 要多扣：
  -- 這些客人下一批（或稍後手動配）就要吃這批貨，先掛進池子會被轉走。
  SELECT COALESCE(SUM(coi2.qty), 0) INTO v_waiting
    FROM customer_orders co2
    JOIN customer_order_items coi2 ON coi2.order_id = co2.id
    LEFT JOIN members m2 ON m2.id = co2.member_id
   WHERE co2.tenant_id       = v_tenant
     AND co2.pickup_store_id = p_store_id
     AND co2.status          = 'confirmed'
     AND (co2.order_kind = 'normal' OR co2.order_kind IS NULL)
     AND COALESCE(m2.member_type, '') <> 'store_internal'
     AND coi2.sku_id = p_sku_id
     AND coi2.status IN ('pending','reserved','ready');

  v_grow := LEAST(p_max_grow,
                  GREATEST(v_on_hand - v_promised - v_waiting - v_pool_qty, 0));
  IF v_grow <= 0 THEN
    RETURN 0;
  END IF;

  v_order_id := public._get_or_create_surplus_pool_order(p_store_id, p_operator, p_at);
  SELECT campaign_id INTO v_campaign FROM customer_orders WHERE id = v_order_id;

  -- 品項單價：分店價（branch）優先、退 retail、再退 0 —— 池子單價本來就只是
  -- 掛帳顯示，轉單給真會員時 rpc_transfer_order_partial 會改鎖當下現售價。
  SELECT price INTO v_price
    FROM prices
   WHERE tenant_id = v_tenant AND sku_id = p_sku_id AND scope = 'branch'
     AND effective_from <= p_at AND (effective_to IS NULL OR effective_to > p_at)
   ORDER BY effective_from DESC
   LIMIT 1;
  IF v_price IS NULL THEN
    SELECT price INTO v_price
      FROM prices
     WHERE tenant_id = v_tenant AND sku_id = p_sku_id AND scope = 'retail'
       AND effective_from <= p_at AND (effective_to IS NULL OR effective_to > p_at)
     ORDER BY effective_from DESC
     LIMIT 1;
  END IF;
  v_price := COALESCE(v_price, 0);

  v_ci := public._restock_sentinel_campaign_item(v_tenant, v_campaign, p_sku_id, v_price);

  -- 一批一列（notes 帶來源 tag），退回收貨才對得到帳；不跟既有列合併。
  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant, v_order_id, v_ci, p_sku_id, v_grow, v_price,
    'pending', 'store_internal', p_tag, p_operator, p_operator, p_at, p_at
  );

  UPDATE customer_orders
     SET updated_by = p_operator, updated_at = p_at
   WHERE id = v_order_id;

  RETURN v_grow;
END;
$$;

COMMENT ON FUNCTION public._grow_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT) IS
  '收貨多給掛進【內部】xx 店現貨池（_trim_internal_pool 的鏡像）：'
  'grow = LEAST(p_max_grow, GREATEST(on_hand − 已承諾未取 − confirmed 未配需求 − 池子未取, 0))。'
  '掛到 OV- 容器單（_get_or_create_surplus_pool_order），品項 notes 帶 p_tag。'
  '回傳實際掛進去的數量。';

GRANT EXECUTE ON FUNCTION public._grow_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 3. rpc_get_transfer_allocation_preview — budget 每列多回 'pool'
--    基底 20260814000000 逐字保留；只加 pool 子查詢與回傳欄位。
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
  -- 20260814(2)：每列多回 'pool'（池子既有未取掛帳）—— 前端預估
  -- 「多給的會掛幾件進內部店」要扣掉它，跟 _grow_internal_pool 同一套帳。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',    b.sku_id,
           'sku_code',  s.sku_code,
           'name',      TRIM(COALESCE(s.product_name, '')
                          || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                  THEN ' / ' || s.variant_name ELSE '' END),
           'available', b.avail,
           'pool',      b.pool_qty
         ) ORDER BY b.sku_id), '[]'::jsonb)
    INTO v_budget
    FROM (
      SELECT sk.sku_id,
             COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0) AS avail,
             COALESCE(pl.pool_qty, 0) AS pool_qty
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
        LEFT JOIN (
          SELECT coi3.sku_id, SUM(coi3.qty) AS pool_qty
            FROM customer_orders co3
            JOIN customer_order_items coi3 ON coi3.order_id = co3.id
            JOIN members m3 ON m3.id = co3.member_id AND m3.member_type = 'store_internal'
           WHERE co3.tenant_id       = v_tenant
             AND co3.pickup_store_id = v_store
             AND co3.status NOT IN ('cancelled','expired','transferred_out','completed')
             AND coi3.status IN ('pending','reserved','ready')
           GROUP BY coi3.sku_id
        ) pl ON pl.sku_id = sk.sku_id
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
  '可配上限 = 既有可配（on_hand − 已承諾未取，排除畫面上的 shipping 單）＋ 本次到貨量；'
  'budget 每列另回 pool（池子既有未取掛帳，前端預估多給量用）。'
  '確認收貨走 rpc_receive_transfer_manual：沒勾的 shipping 單拉回 confirmed、'
  '多給的量掛進【內部】店現貨池。';

GRANT EXECUTE ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 4. rpc_receive_transfer_manual — 多給的量掛進【內部】店現貨池
--    基底 20260814000000 逐字保留；只加 surplus 區塊與回傳欄位
--    （簽名不變，CREATE OR REPLACE 即可）。
-- ----------------------------------------------------------------
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
  v_tag          TEXT;
  v_sk           RECORD;
  v_grown        NUMERIC;
  v_surplus      JSONB := '[]'::jsonb;
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

  -- 20260814(2)：多給的要跳出內部店 —— 收貨＋配單之後，本批沒有訂單主人的
  -- 剩餘量掛進【內部】xx 店現貨池。逐 SKU：
  --   本批剩餘 = 本批實收 − 本次配掉（保留勾選的派貨中單 ＋ 本次推 ready 的
  --   confirmed 單，只算各自在該 SKU 上的未取需求）。
  -- 實際掛帳交給 _grow_internal_pool 夾兩層上限（本批剩餘 × 帳上自由量 ——
  -- 自由量已扣掉沒勾/拉回而還在等貨的 confirmed 單，不吃他們下一批要領的貨）。
  IF v_store IS NOT NULL THEN
    v_tag := '[收貨多給|TF#' || array_to_string(v_ids, ',') || ']';
    FOR v_sk IN
      WITH got AS (
        SELECT ti.sku_id, SUM(ti.qty_received) AS received
          FROM transfer_items ti
         WHERE ti.transfer_id = ANY (v_ids)
           AND ti.qty_received > 0
         GROUP BY ti.sku_id
      ),
      alloc AS (
        SELECT coi.sku_id, SUM(coi.qty) AS used
          FROM customer_order_items coi
         WHERE coi.status IN ('pending','reserved','ready')
           AND (coi.order_id = ANY (v_chk_ship)
                OR (v_conf IS NOT NULL AND coi.order_id IN (
                      SELECT co.id FROM customer_orders co
                       WHERE co.id = ANY (v_conf)
                         AND co.status = 'ready'
                         AND co.ready_at = v_now)))
         GROUP BY coi.sku_id
      )
      SELECT g.sku_id, GREATEST(g.received - COALESCE(a.used, 0), 0) AS leftover
        FROM got g
        LEFT JOIN alloc a ON a.sku_id = g.sku_id
       WHERE GREATEST(g.received - COALESCE(a.used, 0), 0) > 0
    LOOP
      v_grown := public._grow_internal_pool(
        v_store, v_sk.sku_id, v_sk.leftover, p_operator, v_now, v_tag);
      IF v_grown > 0 THEN
        v_surplus := v_surplus
          || jsonb_build_object('sku_id', v_sk.sku_id, 'qty', v_grown);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'transfers_received', cardinality(v_ids),
    'received',           v_results,
    'pulled_back',        COALESCE(cardinality(v_pulled), 0),
    'pullback_skipped',   v_pull_skipped,
    'shipping_advanced',  v_ship_adv,
    'allocation',         v_alloc,
    'surplus',            v_surplus
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[]) IS
  '手動配貨的一段式確認：單一交易內 拉回沒勾的派貨中訂單（shipping → confirmed，'
  '收貨前做，攔住邏輯 C）→ 逐張 rpc_receive_transfer(p_auto_allocate=FALSE) → '
  '勾選的派貨中訂單推可取貨（邏輯 C 同語意）→ confirmed 勾選單走 '
  'rpc_manual_allocate_confirmed_orders → 本批多給的剩餘量掛進【內部】店現貨池'
  '（_grow_internal_pool，notes 標 [收貨多給|TF#ids]，回傳 surplus）。'
  '無 savepoint —— 任何一步失敗整包回滾（確認才完成收貨；取消/失敗＝什麼都沒發生）。';

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[])
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 5. rpc_unreceive_transfer — 反向邏輯 F：收貨多給的池子列跟著沖銷
--    基底 20260810000000 逐字保留；只加反向邏輯 F 與回傳欄位。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_unreceive_transfer(
  p_transfer_id bigint,
  p_operator    uuid,
  p_notes       text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
-- 邏輯 C 需重掃該店所有 ready 訂單並逐張跑 is_order_pickup_ready，覆寫 PostgREST
-- 預設 statement_timeout，避免大店退回時中途被砍。
SET statement_timeout TO '60000'
AS $function$
DECLARE
  v_tenant_id         UUID;
  v_status            TEXT;
  v_transfer_type     TEXT;
  v_dest_location     BIGINT;
  v_existing_notes    TEXT;
  v_customer_order_id BIGINT;
  v_next_transfer_id  BIGINT;
  v_leg2_status       TEXT;
  v_item              RECORD;
  v_orig              stock_movements%ROWTYPE;
  v_on_hand           NUMERIC;
  v_rev_id            BIGINT;
  v_items_reversed    INTEGER := 0;
  v_total_qty         NUMERIC := 0;
  v_dest_store_id     BIGINT;
  v_orders_reverted   INTEGER := 0;
  v_ord               RECORD;
  v_restock_reverted  INTEGER := 0;
  v_rr                RECORD;
  v_prog              RECORD;
  v_surplus_orders    BIGINT[] := '{}'::BIGINT[];
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'received' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，僅「已收貨(received)」可退回取消收貨', p_transfer_id, v_status;
  END IF;

  -- 守衛：多段接力且後段已自動出貨（收貨時 ship 過），不允許直接退回本段
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT status INTO v_leg2_status FROM transfers WHERE id = v_next_transfer_id FOR UPDATE;
    IF v_leg2_status IS NOT NULL AND v_leg2_status <> 'draft' THEN
      RAISE EXCEPTION '此調撥為多段接力，後段調撥 %（狀態 %）已出貨，請先處理後段後再退回本段收貨',
        v_next_transfer_id, v_leg2_status;
    END IF;
  END IF;

  -- 逐項沖銷 transfer_in 入庫、並把 qty_received 歸零
  FOR v_item IN
    SELECT id, sku_id, qty_received, in_movement_id
      FROM transfer_items
     WHERE transfer_id = p_transfer_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.qty_received > 0 AND v_item.in_movement_id IS NOT NULL THEN
      SELECT * INTO v_orig FROM stock_movements WHERE id = v_item.in_movement_id;

      IF v_orig.id IS NULL
         OR v_orig.movement_type <> 'transfer_in'
         OR v_orig.source_doc_type <> 'transfer'
         OR v_orig.source_doc_id <> p_transfer_id THEN
        RAISE EXCEPTION 'transfer_item % 的 movement % 非本調撥入庫，無法退回收貨',
          v_item.id, v_item.in_movement_id;
      END IF;
      IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
        RAISE EXCEPTION 'movement % 已被沖銷過，不可重複退回收貨', v_orig.id;
      END IF;

      -- 物理守衛：入庫貨若已被取貨/售出使 on_hand 不足以沖銷 → 擋（避免庫存變負）
      SELECT on_hand INTO v_on_hand
        FROM stock_balances
       WHERE tenant_id   = v_orig.tenant_id
         AND location_id = v_orig.location_id
         AND sku_id      = v_orig.sku_id
       FOR UPDATE;
      IF COALESCE(v_on_hand, 0) < v_orig.quantity THEN
        RAISE EXCEPTION '分店庫存不足以退回收貨（SKU %：現有 %、需沖銷 %）：該批貨可能已被取貨/售出，無法退回',
          v_orig.sku_id, COALESCE(v_on_hand, 0), v_orig.quantity;
      END IF;

      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
      ) VALUES (
        v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
        -v_orig.quantity, v_orig.unit_cost, 'reversal',
        'transfer', p_transfer_id, v_item.id, v_orig.id,
        format('退回收貨 transfer=%s item=%s（沖銷 movement %s）%s',
               p_transfer_id, v_item.id, v_orig.id,
               COALESCE('：' || NULLIF(TRIM(p_notes), ''), '')),
        p_operator
      ) RETURNING id INTO v_rev_id;

      v_total_qty      := v_total_qty + v_orig.quantity;
      v_items_reversed := v_items_reversed + 1;
    END IF;

    UPDATE transfer_items
       SET qty_received   = 0,
           in_movement_id = NULL,
           updated_by     = p_operator,
           updated_at     = NOW()
     WHERE id = v_item.id;
  END LOOP;

  -- 調撥單退回 shipped
  UPDATE transfers
     SET status      = 'shipped',
         received_by = NULL,
         received_at = NULL,
         notes       = CASE
                         WHEN p_notes IS NULL OR TRIM(p_notes) = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN '退回收貨：' || p_notes
                         ELSE v_existing_notes || E'\n退回收貨：' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- 反向邏輯 B（aid 單 FK）/ 邏輯 C（hq_to_store）：
  -- 把因本次收貨被推到 ready、沖銷後已不再 pickup_ready 的訂單退回 shipping。
  -- 因其他已收波次而仍到貨的訂單維持 ready。已取貨(partially_completed/completed)不動。
  IF v_customer_order_id IS NOT NULL THEN
    FOR v_ord IN
      SELECT id FROM customer_orders
       WHERE id = v_customer_order_id AND status = 'ready'
       FOR UPDATE
    LOOP
      IF NOT public.is_order_pickup_ready(v_ord.id) THEN
        UPDATE customer_orders
           SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
         WHERE id = v_ord.id;
        PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
          format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
        v_orders_reverted := v_orders_reverted + 1;
      END IF;
    END LOOP;

  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      FOR v_ord IN
        SELECT id FROM customer_orders
         WHERE tenant_id       = v_tenant_id
           AND pickup_store_id = v_dest_store_id
           AND status          = 'ready'
         FOR UPDATE
      LOOP
        IF NOT public.is_order_pickup_ready(v_ord.id) THEN
          UPDATE customer_orders
             SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
           WHERE id = v_ord.id;
          PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
            format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
          v_orders_reverted := v_orders_reverted + 1;
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- ===== 反向邏輯 D：linked 補貨申請退回 shipped；ride-along 單退回 pending =====
  FOR v_rr IN
    SELECT id FROM restock_requests
     WHERE linked_transfer_id = p_transfer_id
       AND status = 'received'
  LOOP
    UPDATE restock_requests
       SET status = 'shipped', updated_by = p_operator
     WHERE id = v_rr.id;
    v_restock_reverted := v_restock_reverted + 1;

    -- 20260810：settle 的反向 —— 短收被取消/拆行的品項還原，整單短收取消的單重開
    PERFORM public._unsettle_restock_ride_along(v_rr.id, p_operator);
  END LOOP;

  UPDATE customer_orders co
     SET status     = 'pending',
         ready_at   = NULL,
         updated_by = p_operator,
         updated_at = NOW()
    FROM restock_requests rr
   WHERE rr.linked_transfer_id = p_transfer_id
     AND co.tenant_id  = rr.tenant_id
     AND co.order_no   = 'RR-' || rr.id::TEXT
     AND co.order_kind = 'restock'
     AND co.status = 'ready';

  -- ===== 反向邏輯 D2（20260717）：wave 路徑申請退回 shipped =====
  -- 本調撥退回在途後，歸屬的 received 申請若不再「全數出貨且全數到店」
  -- → 退回 shipped、ride-along 單 ready → pending。
  FOR v_rr IN
    SELECT DISTINCT rr.id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN restock_requests rr
        ON rr.tenant_id = v_tenant_id
       AND rr.requesting_store_id = pwi.store_id
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND rr.status = 'received'
       AND (pw.source_restock_request_id = rr.id
            OR (pwi.campaign_id IS NULL
                AND rr.linked_pr_id IS NOT NULL
                AND pw.source_po_id IN (
                  SELECT DISTINCT poi.po_id
                    FROM purchase_request_items pri
                    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
                   WHERE pri.pr_id = rr.linked_pr_id)))
       AND pwi.sku_id IN (SELECT sku_id FROM restock_request_lines
                           WHERE request_id = rr.id AND cancelled_at IS NULL)
  LOOP
    SELECT * INTO v_prog FROM public._restock_wave_progress(v_rr.id);
    IF NOT (v_prog.fully_dispatched AND v_prog.all_arrived) THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = p_operator
       WHERE id = v_rr.id AND status = 'received';
      v_restock_reverted := v_restock_reverted + 1;

      -- 20260810：settle 的反向（同反向邏輯 D）
      PERFORM public._unsettle_restock_ride_along(v_rr.id, p_operator);

      UPDATE customer_orders co
         SET status     = 'pending',
             ready_at   = NULL,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE co.tenant_id  = v_tenant_id
         AND co.order_no   = 'RR-' || v_rr.id::TEXT
         AND co.order_kind = 'restock'
         AND co.status = 'ready';
    END IF;
  END LOOP;

  -- ===== 反向邏輯 F（20260814(2)）：收貨多給掛進現貨池的列跟著沖銷 =====
  -- 手動收貨會把本批沒有訂單主人的剩餘量掛進【內部】xx 店現貨池
  -- （notes 標 [收貨多給|TF#<ids>]）。退回收貨後這批貨已不在店裡，
  -- 池子繼續掛著＝店員會把不存在的貨轉出去（20260811000030 忠順同型）。
  -- 已被轉單吃掉的部分（qty 遞減 / 整列 cancelled）不再處理 ——
  -- 重新收貨時 _grow_internal_pool 依當下自由量重算，不會重複掛回。
  WITH hit AS (
    UPDATE customer_order_items coi
       SET status     = 'cancelled',
           notes      = TRIM(BOTH E'\n' FROM COALESCE(coi.notes || E'\n', '')
                        || '[退回收貨沖銷|TF#' || p_transfer_id || ']'),
           updated_by = p_operator,
           updated_at = NOW()
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND co.tenant_id = v_tenant_id
       AND coi.status IN ('pending','reserved','ready')
       AND coi.notes ~ ('\[收貨多給\|TF#([0-9]+,)*' || p_transfer_id::TEXT || '(,[0-9]+)*\]')
    RETURNING coi.order_id
  )
  SELECT COALESCE(ARRAY_AGG(DISTINCT order_id), '{}'::BIGINT[])
    INTO v_surplus_orders FROM hit;

  IF cardinality(v_surplus_orders) > 0 THEN
    -- CLAUDE.md：品項改 cancelled 後接單頭收尾；OV- 容器整張被沖光且
    -- 一件都沒取過 → 整單 cancelled（不留空殼佔 trio 唯一索引 slot）。
    PERFORM public._close_orders_all_items_settled(v_surplus_orders, p_operator, NOW());

    UPDATE customer_orders co
       SET status     = 'cancelled',
           updated_by = p_operator,
           updated_at = NOW()
     WHERE co.id = ANY (v_surplus_orders)
       AND co.status IN ('pending','confirmed','ready','shipping')
       AND NOT EXISTS (SELECT 1 FROM customer_order_items x
                        WHERE x.order_id = co.id
                          AND x.status NOT IN ('cancelled','expired'));
  END IF;

  RETURN jsonb_build_object(
    'transfer_id',        p_transfer_id,
    'items_reversed',     v_items_reversed,
    'total_qty_reversed', v_total_qty,
    'orders_reverted',    v_orders_reverted,
    'restock_reverted',   v_restock_reverted,
    'surplus_reversed',   COALESCE(cardinality(v_surplus_orders), 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) IS
  '退回收貨：rpc_receive_transfer 的反向。沖銷 transfer_in 入庫(reversal movement)、'
  'qty_received 歸零、調撥單 received→shipped；沖銷後不再 pickup_ready 的訂單退回 shipping；'
  'linked / wave 路徑補貨申請 received→shipped；20260810 起同時反向還原短收結算'
  '（_unsettle_restock_ride_along：拆行併回、[短收未到] 還原 pending、短收取消單重開）；'
  '20260814(2) 起連帶沖銷本單掛進現貨池的 [收貨多給|TF#] 列。'
  '守衛：非 received / 後段已出貨 / movement 已沖銷 / on_hand 不足(貨已取用) 皆擋下。';

-- ----------------------------------------------------------------
-- 6. rpc_receive_transfer — 邏輯 F：自動配 / 批次收貨路徑也把多給掛進現貨池
--    「多給的要跳出內部店」是收貨的規則，不是某顆按鈕的規則：預設的
--    「收貨·自動配」與批次收貨走的是這一支，沒接上的話多數收貨仍然
--    看不到多給的量。基底 20260813000000 逐字保留（已與線上 pg_get_functiondef
--    逐字 diff 一致），只加變數宣告、邏輯 F 區塊與回傳 surplus。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(
  p_transfer_id   BIGINT,
  p_lines         JSONB,
  p_operator      UUID,
  p_notes         TEXT    DEFAULT NULL::TEXT,
  p_auto_allocate BOOLEAN DEFAULT TRUE
) RETURNS JSONB
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id            UUID;
  v_status               TEXT;
  v_transfer_type        TEXT;
  v_dest_location        BIGINT;
  v_existing_notes       TEXT;
  v_customer_order_id    BIGINT;
  v_next_transfer_id     BIGINT;
  v_item                 RECORD;
  v_qty_received         NUMERIC;
  v_unit_cost            NUMERIC;
  v_in_mov_id            BIGINT;
  v_total_qty            NUMERIC := 0;
  v_total_variance       NUMERIC := 0;
  v_items_received       INTEGER := 0;
  v_lines_consumed       INTEGER := 0;
  v_lines_count          INTEGER;
  v_orders_advanced      INTEGER := 0;
  v_next_shipped         BOOLEAN := FALSE;
  v_leg2                 transfers%ROWTYPE;
  v_leg2_item            RECORD;
  v_leg2_mov             BIGINT;
  v_dest_store_id        BIGINT;
  v_restock_received     INTEGER := 0;
  v_rr                   RECORD;
  v_prog                 RECORD;
  v_recv_skus            BIGINT[];   -- 20260811(3)：本次實收 > 0 的 SKU
  v_backorders_freed     INTEGER := 0;   -- 20260811(6)：本次到貨解除的待補貨列數
  v_sk                   RECORD;     -- 20260814(2)：逐 SKU 算本批多給
  v_grown                NUMERIC;
  v_surplus              JSONB := '[]'::jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is in status %, expected shipped', p_transfer_id, v_status;
  END IF;

  IF p_lines IS NOT NULL THEN
    v_lines_count := jsonb_array_length(p_lines);
    IF EXISTS (
      SELECT 1
        FROM jsonb_array_elements(p_lines) AS l
        LEFT JOIN transfer_items ti
          ON ti.id = (l->>'transfer_item_id')::BIGINT
         AND ti.transfer_id = p_transfer_id
       WHERE ti.id IS NULL
    ) THEN
      RAISE EXCEPTION 'p_lines contains transfer_item_id not belonging to transfer %', p_transfer_id;
    END IF;
  END IF;

  -- ===== 原有邏輯：寫 qty_received + dest_location inbound =====
  FOR v_item IN
    SELECT ti.id, ti.sku_id, ti.qty_shipped, sm.unit_cost AS out_cost
      FROM transfer_items ti
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE ti.transfer_id = p_transfer_id
     ORDER BY ti.id
  LOOP
    v_qty_received := v_item.qty_shipped;

    IF p_lines IS NOT NULL THEN
      SELECT (l->>'qty_received')::NUMERIC
        INTO v_qty_received
        FROM jsonb_array_elements(p_lines) AS l
       WHERE (l->>'transfer_item_id')::BIGINT = v_item.id
       LIMIT 1;

      IF FOUND THEN
        v_lines_consumed := v_lines_consumed + 1;
      ELSE
        v_qty_received := v_item.qty_shipped;
      END IF;
    END IF;

    IF v_qty_received IS NULL OR v_qty_received < 0 THEN
      RAISE EXCEPTION 'transfer_item % qty_received must be >= 0, got %', v_item.id, v_qty_received;
    END IF;
    IF v_qty_received > v_item.qty_shipped THEN
      RAISE EXCEPTION 'transfer_item % over-receipt: qty_received=% > qty_shipped=%',
        v_item.id, v_qty_received, v_item.qty_shipped;
    END IF;

    IF v_qty_received > 0 THEN
      v_unit_cost := COALESCE(ABS(v_item.out_cost), 0);

      v_in_mov_id := rpc_inbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_dest_location,
        p_sku_id          => v_item.sku_id,
        p_quantity        => v_qty_received,
        p_unit_cost       => v_unit_cost,
        p_movement_type   => 'transfer_in',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );

      UPDATE transfer_items
         SET qty_received   = v_qty_received,
             in_movement_id = v_in_mov_id,
             updated_by     = p_operator
       WHERE id = v_item.id;
    ELSE
      UPDATE transfer_items
         SET qty_received = 0,
             updated_by   = p_operator
       WHERE id = v_item.id;
    END IF;

    v_total_qty      := v_total_qty + v_qty_received;
    v_total_variance := v_total_variance + (v_qty_received - v_item.qty_shipped);
    v_items_received := v_items_received + 1;
  END LOOP;

  UPDATE transfers
     SET status      = 'received',
         received_by = p_operator,
         received_at = NOW(),
         notes       = CASE
                         WHEN p_notes IS NULL OR p_notes = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN p_notes
                         ELSE v_existing_notes || E'\n' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- ===== 邏輯 A0（20260811(6)）：本次到貨 → 解除待補貨 =====
  -- 少發配貨（rpc_allocate_shortage）把沒配到的品項標 backorder_at，取貨閘門
  -- 因此回 false。在這支之前，全 DB 沒有任何路徑會在「補的那批貨到店」時把它
  -- 清掉 —— 補出第二批、店家收了貨，品項還是掛「待補貨」，要有人記得回收貨頁
  -- 再點一次「⚖️ 配貨」才解得開。
  --
  -- **必須排在邏輯 A/B/C/E 之前**：邏輯 C 的 is_order_pickup_ready() 與
  -- 邏輯 E 的 _advance_arrived_confirmed_orders 都含 backorder_at IS NULL，
  -- 先解除才推得動單頭；順序反了這批單要等下一次收貨才會動。
  --
  -- 20260813：手動配單模式（p_auto_allocate = FALSE）**仍照跑** —— 這是
  -- 「先前⚖️配貨決定」的完成、有帳面+實體雙守衛，不是新的配單決策；
  -- 關掉會重演松山單卡 6 天災情。要重新決定配給誰請用 ⚖️ 配貨。
  IF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    SELECT ARRAY_AGG(DISTINCT ti.sku_id)
      INTO v_recv_skus
      FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id
       AND ti.qty_received > 0;

    IF v_dest_store_id IS NOT NULL AND v_recv_skus IS NOT NULL THEN
      v_backorders_freed := public._settle_arrived_backorders(
        v_dest_store_id, v_recv_skus, p_operator, NOW());
    END IF;
  END IF;

  -- ===== 邏輯 A：自動 ship 下一段（aid chain B 模型）=====
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_leg2 FROM transfers
     WHERE id = v_next_transfer_id FOR UPDATE;

    IF v_leg2.id IS NOT NULL AND v_leg2.status = 'draft' THEN
      FOR v_leg2_item IN
        SELECT ti.id AS leg2_item_id, ti.sku_id, ti2.qty_received
          FROM transfer_items ti
          JOIN transfer_items ti2
            ON ti2.transfer_id = p_transfer_id AND ti2.sku_id = ti.sku_id
         WHERE ti.transfer_id = v_leg2.id
      LOOP
        IF v_leg2_item.qty_received > 0 THEN
          v_leg2_mov := rpc_outbound(
            p_tenant_id       => v_leg2.tenant_id,
            p_location_id     => v_leg2.source_location,
            p_sku_id          => v_leg2_item.sku_id,
            p_quantity        => v_leg2_item.qty_received,
            p_movement_type   => 'transfer_out',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_leg2.id,
            p_operator        => p_operator
          );
          UPDATE transfer_items
             SET qty_shipped     = v_leg2_item.qty_received,
                 qty_requested   = v_leg2_item.qty_received,
                 out_movement_id = v_leg2_mov,
                 updated_by      = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        ELSE
          UPDATE transfer_items
             SET qty_shipped   = 0,
                 qty_requested = 0,
                 updated_by    = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        END IF;
      END LOOP;

      UPDATE transfers
         SET status      = 'shipped',
             shipped_by  = p_operator,
             shipped_at  = NOW(),
             updated_by  = p_operator
       WHERE id = v_leg2.id;
      v_next_shipped := TRUE;
    END IF;
  END IF;

  -- ===== 邏輯 B：aid 單 FK 直接推 customer_order → ready =====
  IF v_customer_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = NOW(),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_customer_order_id
       AND status = 'shipping';
    GET DIAGNOSTICS v_orders_advanced = ROW_COUNT;

  -- ===== 邏輯 C：hq_to_store wave transfer → 推該分店訂單 → ready =====
  -- 修：不再無條件推該店「所有」shipping 訂單；改成只推
  --     is_order_pickup_ready=true（依該訂單的團真的到齊、shortage-aware）的訂單，
  --     避免收到別團波次時把尚未出貨的團一起誤標為可取貨。
  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      WITH advanced AS (
        UPDATE customer_orders co
           SET status     = 'ready',
               ready_at   = NOW(),
               updated_by = p_operator,
               updated_at = NOW()
         WHERE co.tenant_id      = v_tenant_id
           AND co.pickup_store_id = v_dest_store_id
           AND co.status          = 'shipping'
           AND public.is_order_pickup_ready(co.id)
        RETURNING co.id
      )
      SELECT COUNT(*) INTO v_orders_advanced FROM advanced;
    END IF;
  END IF;

  -- ===== 邏輯 D：linked 補貨申請 → 已收貨；ride-along 單 → ready =====
  -- 店家收貨即補貨流程終點：把 linked_transfer_id 指向本單的補貨申請
  -- 推到 received。approved_transfer 為 legacy 防禦（現行直派皆直接 shipped）。
  FOR v_rr IN
    SELECT id FROM restock_requests
     WHERE linked_transfer_id = p_transfer_id
       AND status IN ('shipped', 'approved_transfer')
  LOOP
    UPDATE restock_requests
       SET status = 'received', updated_by = p_operator
     WHERE id = v_rr.id;
    v_restock_received := v_restock_received + 1;

    -- 20260810：ride-along 內部單改由 settle helper 收尾 —— 品項先對齊實收
    -- （短收 0 → cancelled、部分 → 拆行），再推 ready / 全未到自動取消。
    PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
  END LOOP;

  -- ===== 邏輯 D2（20260717）：wave 路徑補貨申請 → 已出貨/已收貨 =====
  -- 本調撥若為撿貨單產物（picking_wave_items.generated_transfer_id 指向本單），
  -- 歸屬的補貨申請（歸屬原則同 20260715000020）「全數出貨且全數到店」→ received、
  -- ride-along 單推 ready；已全數出貨但仍有他張在途 → 至少推 shipped。
  FOR v_rr IN
    SELECT DISTINCT rr.id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN restock_requests rr
        ON rr.tenant_id = v_tenant_id
       AND rr.requesting_store_id = pwi.store_id
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND rr.status IN ('approved_pr', 'approved_transfer', 'shipped')
       AND (pw.source_restock_request_id = rr.id
            OR (pwi.campaign_id IS NULL
                AND rr.linked_pr_id IS NOT NULL
                AND pw.source_po_id IN (
                  SELECT DISTINCT poi.po_id
                    FROM purchase_request_items pri
                    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
                   WHERE pri.pr_id = rr.linked_pr_id)))
       AND pwi.sku_id IN (SELECT sku_id FROM restock_request_lines
                           WHERE request_id = rr.id AND cancelled_at IS NULL)
  LOOP
    SELECT * INTO v_prog FROM public._restock_wave_progress(v_rr.id);
    IF v_prog.fully_dispatched AND v_prog.all_arrived THEN
      UPDATE restock_requests
         SET status = 'received', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer', 'shipped');
      v_restock_received := v_restock_received + 1;

      -- 20260810：ride-along 單交給 settle helper —— 短收品項對齊實收後
      -- 才推 ready；全未到則整單自動取消，不再掛在店身上。
      PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
    ELSIF v_prog.fully_dispatched THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer');
    END IF;
  END LOOP;

  -- ===== 邏輯 E（20260811(3)，20260811(5) 從邏輯 C 搬到這裡）=====
  -- 補貨路線發的團沒有 campaign 對齊波次，客人單從來沒被推到 'shipping'，
  -- 邏輯 C 接不到。這裡把「對得上本次到貨 SKU」的 confirmed 單依訂單時間、
  -- 在可配量內推 ready，並把【內部】xx 店現貨池扣掉相應的量。
  --
  -- **必須排在 D/D2 之後**：ride-along 單要先被 _settle_restock_ride_along
  -- 推成 ready（並對齊實收量）， _trim_internal_pool 才吃得到它 ——
  -- 那支只認已到貨的容器單（20260811000040）。
  --
  -- 20260813：p_auto_allocate = FALSE（手動配單模式）時跳過 —— 收貨只入庫，
  -- 配給哪些 confirmed 單由店家在收貨頁「手動配單」彈窗自己勾
  -- （rpc_manual_allocate_confirmed_orders，同一支 helper 推進）。
  IF p_auto_allocate AND v_customer_order_id IS NULL AND v_transfer_type = 'hq_to_store' THEN
    IF v_dest_store_id IS NOT NULL THEN
      SELECT ARRAY_AGG(DISTINCT ti.sku_id)
        INTO v_recv_skus
        FROM transfer_items ti
       WHERE ti.transfer_id = p_transfer_id
         AND ti.qty_received > 0;

      IF v_recv_skus IS NOT NULL THEN
        v_orders_advanced := v_orders_advanced
          + public._advance_arrived_confirmed_orders(
              v_dest_store_id, v_recv_skus, p_operator, NOW());
      END IF;
    END IF;
  END IF;

  -- ===== 邏輯 F（20260814(2)）：多給的跳出【內部】店 =====
  -- 本批實收扣掉「本店對這個 SKU 還沒交出去的帳」之後仍有剩 → 沒有訂單主人，
  -- 掛進【內部】xx 店現貨池，店員才轉得出去（在這之前只進 on_hand，
  -- 池子看不到 → 帳上等於隱形，只能靠人工開內部單）。
  --
  -- **必須排在邏輯 B/C/E 之後**：那些是把貨配給客人的路徑，配掉的量會變成
  -- 「已承諾未取」，_grow_internal_pool 的自由量才扣得到；順序反了會把
  -- 客人的貨掛進池子，重演 20260811000030 忠順那種「團友撲空」。
  -- 手動配單模式（p_auto_allocate=FALSE）在這裡通常算不出剩餘（沒配的單
  -- 還是 confirmed，自由量已扣掉它們），真正的結算在
  -- rpc_receive_transfer_manual 配完單之後再跑一次 —— 同一支 helper，
  -- 依當下自由量重算，不會重複掛。
  IF v_customer_order_id IS NULL AND v_transfer_type = 'hq_to_store'
     AND v_dest_store_id IS NOT NULL THEN
    FOR v_sk IN
      SELECT ti.sku_id, SUM(ti.qty_received) AS received
        FROM transfer_items ti
       WHERE ti.transfer_id = p_transfer_id
         AND ti.qty_received > 0
       GROUP BY ti.sku_id
       ORDER BY ti.sku_id
    LOOP
      v_grown := public._grow_internal_pool(
        v_dest_store_id, v_sk.sku_id, v_sk.received, p_operator, NOW(),
        '[收貨多給|TF#' || p_transfer_id::TEXT || ']');
      IF v_grown > 0 THEN
        v_surplus := v_surplus
          || jsonb_build_object('sku_id', v_sk.sku_id, 'qty', v_grown);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped,
    'restock_received',       v_restock_received,
    'backorders_freed',       v_backorders_freed,
    'auto_allocate',          p_auto_allocate,
    'surplus',                v_surplus
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT, BOOLEAN)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT, BOOLEAN) IS
  '調撥收貨：入庫 + 邏輯 A0(解除待補貨) / A(接力出貨) / B(aid 單) / C(波次推 ready) / '
  'D·D2(補貨申請 + ride-along) / E(自動配 confirmed 單，p_auto_allocate=TRUE 時) / '
  'F(20260814(2)：本批多給的量掛進【內部】店現貨池，_grow_internal_pool 以自由量夾住)。';

-- ----------------------------------------------------------------
-- 7. 回填：2026-08-13（收貨·手動配上線日）以來已收貨的 (店, SKU)
--    依同一套公式補掛（含三峽截圖那批的剩 2 件）。上限 = 期間實收量，
--    實際掛帳仍由 _grow_internal_pool 的自由量守衛夾住，
--    不會吃到已承諾 / 等貨中訂單的貨。
-- ----------------------------------------------------------------
DO $$
DECLARE
  r       RECORD;
  v_uid   UUID;
  v_done  NUMERIC;
  v_total NUMERIC := 0;
  v_combo INT := 0;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  FOR r IN
    SELECT s.id AS store_id, s.name AS store_name, ti.sku_id,
           SUM(ti.qty_received) AS received
      FROM transfers t
      JOIN stores s ON s.tenant_id = t.tenant_id AND s.location_id = t.dest_location
      JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.qty_received > 0
     WHERE t.status IN ('received', 'closed')
       AND t.received_at >= TIMESTAMPTZ '2026-08-13 00:00:00+08'
     GROUP BY 1, 2, 3
     ORDER BY 1, 3
  LOOP
    v_done := public._grow_internal_pool(
      r.store_id, r.sku_id, r.received, v_uid, NOW(), '[收貨多給|補掛20260814]');
    IF v_done > 0 THEN
      RAISE NOTICE '  % / sku %: 補掛 % 件（期間實收 %）',
        r.store_name, r.sku_id, v_done, r.received;
      v_combo := v_combo + 1;
      v_total := v_total + v_done;
    END IF;
  END LOOP;

  RAISE NOTICE '收貨多給補掛完成：% 組 (店, SKU)、共 % 件', v_combo, v_total;
END $$;

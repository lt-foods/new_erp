-- ============================================================
-- 2026-08-08: 召回模組 — RPC
--
-- 依賴 20260808000100_recall_schema.sql（表 / view / 欄位）。
-- PRD: docs/PRD-召回模組.md   TEST: docs/TEST-warehouse-recall.md
--
-- 全部是新函式，沒有改任何既有 RPC —— 這是刻意的：
--   rpc_receive_transfer / rpc_create_order_return / rpc_reject_transfer 都已經
--   被改過五到八次（見 migration 史），再往裡面塞召回副作用就是下一個事故源。
--   召回改用「掛 transfers.recall_id + view 推導進度」，總倉照既有 /wms/inbound
--   收貨，數字自己會動。唯一的包裝是 rpc_recall_customer_return，它呼叫既有
--   rpc_create_order_return 之後只補寫一個 recall_id 欄位。
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.rpc_recall_scan_wave(BIGINT);
--   DROP FUNCTION IF EXISTS public.rpc_recall_scan_orders(BIGINT, BIGINT, BIGINT);
--   DROP FUNCTION IF EXISTS public.rpc_create_recall(BIGINT, TEXT, TEXT, JSONB, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_update_recall_draft(BIGINT, JSONB, TEXT, TEXT, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_issue_recall(BIGINT, JSONB);
--   DROP FUNCTION IF EXISTS public.rpc_recall_intercept_transfer(BIGINT, BIGINT, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_recall_store_ship(BIGINT, BIGINT, JSONB, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_recall_customer_return(BIGINT, BIGINT, JSONB, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_recall_write_off(BIGINT, NUMERIC, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_close_recall(BIGINT);
--   DROP FUNCTION IF EXISTS public.rpc_cancel_recall(BIGINT, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_recall_detail(BIGINT);
--   DROP FUNCTION IF EXISTS public.rpc_recall_list(TEXT, INTEGER);
--   DROP FUNCTION IF EXISTS public._recall_assert_hq();
-- ============================================================

-- ------------------------------------------------------------
-- 0. 權限 helper
-- ------------------------------------------------------------
-- 角色一律讀 app_metadata：頂層 auth.jwt()->>'role' 永遠是 'authenticated'
-- （custom_access_token_hook 只把 tenant_id 拉到頂層）。這個坑踩過兩次，
-- 允許清單也要含 ''（沒有顯式 role 的 legacy / dev admin），見 CLAUDE.md。
CREATE OR REPLACE FUNCTION public._recall_assert_hq()
RETURNS VOID
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION '權限不足：% 不可操作召回單（需總倉管理角色）', v_role;
  END IF;
END;
$$;

-- ------------------------------------------------------------
-- 1. rpc_recall_scan_wave — 開單前掃描一張撿貨單
-- ------------------------------------------------------------
-- 回傳每一格 (店 × 品項) 的完整狀態分佈，是召回開單畫面的資料來源。
--
-- join 形狀沿用 rpc_get_orders_for_transfer（20260805000030）：
--   訂單與派貨單之間沒有分配表，唯一硬連結是
--   picking_wave_items.generated_transfer_id → transfers.id，
--   再靠 picking_wave_items 的 (campaign_id, store_id, sku_id) 對回訂單。
--   campaign_id 為 NULL（彙整請購）時退回「店 + 品項」比對，會多抓到別團的
--   訂單，回傳 order_match='store_sku' 讓前端標示為約略值。
CREATE OR REPLACE FUNCTION public.rpc_recall_scan_wave(p_wave_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_wave   picking_waves%ROWTYPE;
  v_cells  JSONB;
BEGIN
  PERFORM public._recall_assert_hq();

  SELECT * INTO v_wave FROM picking_waves WHERE id = p_wave_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到撿貨單 %', p_wave_id;
  END IF;

  WITH cell AS (
    -- 同一 (店, 品項) 可能有多列 pwi（不同團），合併成一格
    SELECT
      pwi.store_id,
      pwi.sku_id,
      MIN(pwi.campaign_id)                                   AS campaign_id,
      COUNT(DISTINCT pwi.campaign_id)                        AS campaign_count,
      MIN(pwi.generated_transfer_id)                         AS transfer_id,
      SUM(COALESCE(pwi.picked_qty, pwi.qty))                 AS wave_qty
      FROM picking_wave_items pwi
     WHERE pwi.wave_id = p_wave_id
     GROUP BY pwi.store_id, pwi.sku_id
  ),
  xfer AS (
    -- DISTINCT 是必要的：同一 (店, 品項) 可能有多列 pwi（不同團）指向**同一張**
    -- transfer，不去重的話 transfer_items 會被算兩次。
    SELECT DISTINCT pwi.store_id, pwi.sku_id, pwi.generated_transfer_id AS transfer_id
      FROM picking_wave_items pwi
     WHERE pwi.wave_id = p_wave_id
       AND pwi.generated_transfer_id IS NOT NULL
  ),
  dispatch AS (
    -- 實際派出 / 到店 / 在途，看 transfer 而不是 wave（短收、拒收都在這裡才看得到）
    SELECT
      x.store_id, x.sku_id,
      COALESCE(SUM(ti.qty_shipped), 0)                                                    AS qty_shipped,
      COALESCE(SUM(ti.qty_shipped) FILTER (WHERE t.status = 'shipped'), 0)                AS qty_in_transit,
      COALESCE(SUM(ti.qty_received) FILTER (WHERE t.status IN ('received','closed')), 0)  AS qty_received,
      COALESCE(SUM(ti.qty_shipped) FILTER (WHERE t.status = 'cancelled'), 0)              AS qty_cancelled
      FROM xfer x
      JOIN transfers t ON t.id = x.transfer_id
      JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = x.sku_id
     GROUP BY x.store_id, x.sku_id
  ),
  orders AS (
    -- 訂單側：未取 / 已取。campaign 對得上就鎖團，對不上退回店+品項
    SELECT
      c.store_id, c.sku_id,
      COALESCE(SUM(coi.qty) FILTER (WHERE coi.status IN ('pending','reserved','ready')), 0) AS qty_unpicked,
      COALESCE(SUM(coi.qty) FILTER (WHERE coi.status = 'picked_up'), 0)                     AS qty_picked_up,
      COUNT(DISTINCT co.id) FILTER (
        WHERE coi.status IN ('pending','reserved','ready','picked_up'))                     AS order_count,
      CASE WHEN c.campaign_id IS NOT NULL THEN 'wave' ELSE 'store_sku' END                  AS order_match
      FROM cell c
      LEFT JOIN customer_orders co
        ON co.tenant_id       = v_tenant
       AND co.pickup_store_id = c.store_id
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND co.transferred_from_order_id IS NULL
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND (c.campaign_id IS NULL OR co.campaign_id = c.campaign_id)
      LEFT JOIN customer_order_items coi
        ON coi.order_id = co.id
       AND coi.sku_id   = c.sku_id
     GROUP BY c.store_id, c.sku_id, c.campaign_id
  ),
  returned AS (
    -- 這批派出去之後已經退回總倉過的量，可召回量要扣掉。
    -- 時間下限用 wave_date：不設下限的話會把該店該品項**歷史上所有**退貨都算進來，
    -- 可召回量會被無關的舊退貨吃掉。
    SELECT c.store_id, c.sku_id,
           COALESCE(SUM(ti.qty_shipped), 0) AS qty_returned
      FROM cell c
      JOIN stores s ON s.id = c.store_id
      JOIN transfers t
        ON t.tenant_id       = v_tenant
       AND t.transfer_type   = 'return_to_hq'
       AND t.source_location = s.location_id
       AND t.status IN ('shipped','received','closed')
       AND (t.created_at AT TIME ZONE 'Asia/Taipei')::date >= v_wave.wave_date
      JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = c.sku_id
     GROUP BY c.store_id, c.sku_id
  ),
  pending_recall AS (
    -- 已被其他還沒結案的召回單占掉的量
    SELECT l.store_id, l.sku_id, COALESCE(SUM(l.qty_target), 0) AS qty_pending
      FROM product_recall_lines l
      JOIN product_recalls r ON r.id = l.recall_id
     WHERE r.tenant_id = v_tenant
       AND r.status IN ('draft','issued')
       AND r.source_wave_id = p_wave_id
     GROUP BY l.store_id, l.sku_id
  )
  SELECT jsonb_agg(x ORDER BY x->>'store_name', x->>'sku_code')
    INTO v_cells
    FROM (
      SELECT jsonb_build_object(
        'store_id',        c.store_id,
        'store_name',      s.name,
        'sku_id',          c.sku_id,
        'sku_code',        sk.sku_code,
        'sku_name',        COALESCE(sk.product_name, '') ||
                             CASE WHEN COALESCE(sk.variant_name,'') <> ''
                                  THEN ' ' || sk.variant_name ELSE '' END,
        'campaign_id',     c.campaign_id,
        'campaign_count',  c.campaign_count,
        'transfer_id',     c.transfer_id,
        'transfer_no',     t.transfer_no,
        'transfer_status', t.status,
        'wave_qty',        c.wave_qty,
        'qty_shipped',     COALESCE(d.qty_shipped, 0),
        'qty_in_transit',  COALESCE(d.qty_in_transit, 0),
        'qty_received',    COALESCE(d.qty_received, 0),
        'qty_cancelled',   COALESCE(d.qty_cancelled, 0),
        'qty_unpicked',    COALESCE(o.qty_unpicked, 0),
        'qty_picked_up',   COALESCE(o.qty_picked_up, 0),
        'order_count',     COALESCE(o.order_count, 0),
        'order_match',     o.order_match,
        'qty_returned',    COALESCE(rr.qty_returned, 0),
        'qty_pending_recall', COALESCE(pr.qty_pending, 0),
        'store_on_hand',   COALESCE(sb.on_hand, 0),
        -- 可召回量 = 派出 − 已退回 − 已被其他召回單占掉（不含被拒收作廢的量）
        'qty_recallable',  GREATEST(
                             COALESCE(d.qty_shipped, 0) - COALESCE(rr.qty_returned, 0)
                               - COALESCE(pr.qty_pending, 0) - COALESCE(d.qty_cancelled, 0),
                             0)
      ) AS x
        FROM cell c
        JOIN stores s  ON s.id  = c.store_id
        JOIN skus   sk ON sk.id = c.sku_id
        LEFT JOIN dispatch d ON d.store_id = c.store_id AND d.sku_id = c.sku_id
        LEFT JOIN orders   o ON o.store_id = c.store_id AND o.sku_id = c.sku_id
        LEFT JOIN transfers t ON t.id = c.transfer_id
        LEFT JOIN returned rr ON rr.store_id = c.store_id AND rr.sku_id = c.sku_id
        LEFT JOIN pending_recall pr ON pr.store_id = c.store_id AND pr.sku_id = c.sku_id
        LEFT JOIN stock_balances sb
          ON sb.tenant_id = v_tenant AND sb.location_id = s.location_id AND sb.sku_id = c.sku_id
    ) q;

  RETURN jsonb_build_object(
    'wave_id',    v_wave.id,
    'wave_code',  v_wave.wave_code,
    'wave_date',  v_wave.wave_date,
    'wave_status', v_wave.status,
    'cells',      COALESCE(v_cells, '[]'::jsonb)
  );
END;
$$;

-- SECURITY DEFINER 且吐出營運數字，不 REVOKE 拿 anon key 就查得到
REVOKE ALL ON FUNCTION public.rpc_recall_scan_wave(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_recall_scan_wave(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_recall_scan_wave IS
  '召回開單掃描：一張撿貨單每一格 (店 × 品項) 的派出 / 在途 / 已到店 / 未取 / 已取 / 已退 / 可召回量';

-- ------------------------------------------------------------
-- 2. rpc_recall_scan_orders — 某一格背後的顧客訂單明細（懶載入）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_recall_scan_orders(
  p_wave_id  BIGINT,
  p_store_id BIGINT,
  p_sku_id   BIGINT
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_campaign BIGINT;
  v_rows     JSONB;
BEGIN
  PERFORM public._recall_assert_hq();

  SELECT MIN(pwi.campaign_id) INTO v_campaign
    FROM picking_wave_items pwi
   WHERE pwi.wave_id = p_wave_id AND pwi.store_id = p_store_id AND pwi.sku_id = p_sku_id;

  SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'item_id',      coi.id,
        'order_id',     co.id,
        'order_no',     co.order_no,
        'customer',     COALESCE(m.name, co.nickname_snapshot),
        'order_status', co.status,
        'item_status',  coi.status,
        'qty',          coi.qty,
        'unit_price',   coi.unit_price,
        'campaign_id',  co.campaign_id,
        'wallet_paid',  COALESCE(co.wallet_paid_amount, 0),
        'created_at',   co.created_at
      ) AS x
        FROM customer_orders co
        JOIN customer_order_items coi
          ON coi.order_id = co.id
         AND coi.sku_id   = p_sku_id
         AND coi.status IN ('pending','reserved','ready','picked_up')
        LEFT JOIN members m ON m.id = co.member_id
       WHERE co.tenant_id       = v_tenant
         AND co.pickup_store_id = p_store_id
         AND co.status NOT IN ('cancelled','expired','transferred_out')
         AND co.transferred_from_order_id IS NULL
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND (v_campaign IS NULL OR co.campaign_id = v_campaign)
    ) q;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_recall_scan_orders(BIGINT, BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_recall_scan_orders(BIGINT, BIGINT, BIGINT) TO authenticated;

-- ------------------------------------------------------------
-- 3. rpc_create_recall — 建 draft 召回單
-- ------------------------------------------------------------
-- p_lines: [{ store_id, sku_id, qty }]
-- 三桶快照在這裡算：先攔在途、再拿店裡未取的、最後才是客人手上的
-- （由易到難的瀑布分配，也是實際回收的順序）。
CREATE OR REPLACE FUNCTION public.rpc_create_recall(
  p_wave_id     BIGINT,
  p_reason_code TEXT,
  p_reason      TEXT,
  p_lines       JSONB,
  p_notes       TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID := public._current_tenant_id();
  v_user      UUID := auth.uid();
  v_recall_id BIGINT;
  v_recall_no TEXT;
  v_scan      JSONB;
  v_line      JSONB;
  v_cell      JSONB;
  v_store     BIGINT;
  v_sku       BIGINT;
  v_qty       NUMERIC;
  v_left      NUMERIC;
  v_a         NUMERIC;
  v_b         NUMERIC;
  v_c         NUMERIC;
  v_count     INT := 0;
BEGIN
  PERFORM public._recall_assert_hq();

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '請至少選擇一個要召回的品項';
  END IF;

  -- 掃描結果當作驗證基準，避免前端傳來的量超過可召回量
  v_scan := public.rpc_recall_scan_wave(p_wave_id);

  v_recall_no := public._next_recall_no();
  INSERT INTO product_recalls (
    tenant_id, recall_no, source_wave_id, reason_code, reason, status,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_recall_no, p_wave_id, COALESCE(NULLIF(p_reason_code,''), 'other'),
    NULLIF(TRIM(COALESCE(p_reason,'')), ''), 'draft',
    NULLIF(TRIM(COALESCE(p_notes,'')), ''), v_user, v_user
  ) RETURNING id INTO v_recall_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_store := (v_line ->> 'store_id')::BIGINT;
    v_sku   := (v_line ->> 'sku_id')::BIGINT;
    v_qty   := (v_line ->> 'qty')::NUMERIC;

    IF v_store IS NULL OR v_sku IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '召回明細不合法：store_id=% sku_id=% qty=%', v_store, v_sku, v_qty;
    END IF;

    SELECT e.cell INTO v_cell
      FROM jsonb_array_elements(v_scan -> 'cells') AS e(cell)
     WHERE (e.cell ->> 'store_id')::BIGINT = v_store
       AND (e.cell ->> 'sku_id')::BIGINT   = v_sku
     LIMIT 1;

    IF v_cell IS NULL THEN
      RAISE EXCEPTION '撿貨單 % 沒有派過 店#% 品項#%', p_wave_id, v_store, v_sku;
    END IF;
    IF v_qty > (v_cell ->> 'qty_recallable')::NUMERIC THEN
      RAISE EXCEPTION '%（%）召回量 % 超過可召回量 %',
        v_cell ->> 'store_name', v_cell ->> 'sku_code', v_qty, v_cell ->> 'qty_recallable';
    END IF;

    -- 三桶瀑布：在途 → 店裡未取 → 客人已取
    v_left := v_qty;
    v_a := LEAST(v_left, (v_cell ->> 'qty_in_transit')::NUMERIC);
    v_left := v_left - v_a;
    v_b := LEAST(v_left, GREATEST((v_cell ->> 'qty_unpicked')::NUMERIC, 0));
    v_left := v_left - v_b;
    v_c := LEAST(v_left, GREATEST((v_cell ->> 'qty_picked_up')::NUMERIC, 0));
    v_left := v_left - v_c;
    -- 還有剩 = 派出去的量比訂單需求多（總倉多撿），這部分實體貨在店裡但沒有訂單
    -- 對應，一樣要退回來，併入 B 桶（店端出貨退回總倉）。
    IF v_left > 0 THEN
      v_b := v_b + v_left;
    END IF;

    INSERT INTO product_recall_lines (
      tenant_id, recall_id, store_id, sku_id, campaign_id, source_transfer_id,
      qty_dispatched, qty_target, snap_in_transit, snap_unpicked, snap_picked_up,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_recall_id, v_store, v_sku,
      NULLIF(v_cell ->> 'campaign_id','')::BIGINT,
      NULLIF(v_cell ->> 'transfer_id','')::BIGINT,
      (v_cell ->> 'qty_shipped')::NUMERIC, v_qty, v_a, v_b, v_c,
      v_user, v_user
    )
    ON CONFLICT (recall_id, store_id, sku_id) DO NOTHING;

    v_count := v_count + 1;
  END LOOP;

  INSERT INTO product_recall_events (tenant_id, recall_id, event_type, ref_type, ref_id, payload, created_by)
  VALUES (v_tenant, v_recall_id, 'created', 'wave', p_wave_id,
          jsonb_build_object('line_count', v_count), v_user);

  RETURN jsonb_build_object(
    'recall_id', v_recall_id,
    'recall_no', v_recall_no,
    'line_count', v_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_recall(BIGINT, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_recall(BIGINT, TEXT, TEXT, JSONB, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_recall IS
  '建立 draft 召回單。不動任何貨帳 / 訂單，可反覆修改。三桶快照（在途 / 店裡未取 / 客人已取）'
  '以「由易到難」的瀑布分配；派多於訂單需求的部分併入店裡未取桶。';

-- ------------------------------------------------------------
-- 4. rpc_update_recall_draft / rpc_cancel_recall
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_update_recall_draft(
  p_recall_id   BIGINT,
  p_lines       JSONB,
  p_reason_code TEXT DEFAULT NULL,
  p_reason      TEXT DEFAULT NULL,
  p_notes       TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_recall product_recalls%ROWTYPE;
  v_line    JSONB;
  v_qty     NUMERIC;
  v_count   INT := 0;
  v_touched INT := 0;
BEGIN
  PERFORM public._recall_assert_hq();

  SELECT * INTO v_recall FROM product_recalls
   WHERE id = p_recall_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到召回單 %', p_recall_id;
  END IF;
  IF v_recall.status <> 'draft' THEN
    RAISE EXCEPTION '召回單 % 已發布（%），不可改目標量；要調整請沖銷或另開一張',
      v_recall.recall_no, v_recall.status;
  END IF;

  UPDATE product_recalls
     SET reason_code = COALESCE(NULLIF(p_reason_code,''), reason_code),
         reason      = COALESCE(NULLIF(TRIM(COALESCE(p_reason,'')),''), reason),
         notes       = COALESCE(NULLIF(TRIM(COALESCE(p_notes,'')),''), notes),
         updated_by  = v_user
   WHERE id = p_recall_id;

  IF p_lines IS NOT NULL THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
      v_qty := (v_line ->> 'qty')::NUMERIC;
      IF v_qty IS NULL OR v_qty <= 0 THEN
        -- 0 / 負數 = 從草稿移除該格
        DELETE FROM product_recall_lines
         WHERE recall_id = p_recall_id
           AND store_id  = (v_line ->> 'store_id')::BIGINT
           AND sku_id    = (v_line ->> 'sku_id')::BIGINT;
      ELSE
        UPDATE product_recall_lines
           SET qty_target = v_qty, updated_by = v_user
         WHERE recall_id = p_recall_id
           AND store_id  = (v_line ->> 'store_id')::BIGINT
           AND sku_id    = (v_line ->> 'sku_id')::BIGINT;
        GET DIAGNOSTICS v_touched = ROW_COUNT;
        v_count := v_count + v_touched;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('recall_id', p_recall_id, 'updated', v_count);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_update_recall_draft(BIGINT, JSONB, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_recall_draft(BIGINT, JSONB, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_cancel_recall(
  p_recall_id BIGINT,
  p_reason    TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_recall product_recalls%ROWTYPE;
BEGIN
  PERFORM public._recall_assert_hq();

  SELECT * INTO v_recall FROM product_recalls
   WHERE id = p_recall_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到召回單 %', p_recall_id;
  END IF;

  -- 只有還沒動過任何貨帳 / 訂單的才可作廢。已發布的召回單背後已經取消過訂單
  -- 品項、可能已經有貨在路上，作廢會讓那些動作變成孤兒。
  IF v_recall.status = 'issued' THEN
    RAISE EXCEPTION '召回單 % 已發布，不可作廢：請把追不回的量「沖銷」後結案',
      v_recall.recall_no;
  END IF;
  IF v_recall.status <> 'draft' THEN
    RAISE EXCEPTION '召回單 % 狀態為 %，不可作廢', v_recall.recall_no, v_recall.status;
  END IF;

  UPDATE product_recalls
     SET status = 'cancelled', cancelled_at = NOW(), cancelled_by = v_user,
         notes = CASE WHEN NULLIF(TRIM(COALESCE(p_reason,'')),'') IS NULL THEN notes
                      WHEN notes IS NULL OR notes = '' THEN '[作廢] ' || TRIM(p_reason)
                      ELSE notes || E'\n[作廢] ' || TRIM(p_reason) END,
         updated_by = v_user
   WHERE id = p_recall_id;

  INSERT INTO product_recall_events (tenant_id, recall_id, event_type, note, created_by)
  VALUES (v_tenant, p_recall_id, 'cancelled', p_reason, v_user);

  RETURN jsonb_build_object('recall_id', p_recall_id, 'status', 'cancelled');
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_cancel_recall(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_recall(BIGINT, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 5. rpc_issue_recall — 發布：訂單連動（拆單）
-- ------------------------------------------------------------
-- p_item_overrides: {"<line_id>": [coi_id, ...]} — 指定要動哪幾筆訂單品項
--   （前端讓操作員挑，跟少發配貨 ShortageAllocateModal 同一套互動）。
--   沒指定時自動挑：建立時間 DESC、訂單編號 DESC（後下單的先被召回，
--   保護早下單的客人）。
--
-- 為什麼被召回的品項是 status='cancelled' 而不是新 status 值：見 schema 檔頭。
CREATE OR REPLACE FUNCTION public.rpc_issue_recall(
  p_recall_id      BIGINT,
  p_item_overrides JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_user       UUID := auth.uid();
  v_now        TIMESTAMPTZ := NOW();
  v_recall     product_recalls%ROWTYPE;
  v_line       RECORD;
  v_coi        RECORD;
  v_need       NUMERIC;
  v_take       NUMERIC;
  v_new_id     BIGINT;
  v_pinned     BIGINT[];
  v_order_ids  BIGINT[] := ARRAY[]::BIGINT[];
  v_cancelled  INT := 0;
  v_split      INT := 0;
  v_closed     INT := 0;
  v_completed  INT := 0;
BEGIN
  PERFORM public._recall_assert_hq();

  SELECT * INTO v_recall FROM product_recalls
   WHERE id = p_recall_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到召回單 %', p_recall_id;
  END IF;
  IF v_recall.status <> 'draft' THEN
    RAISE EXCEPTION '召回單 % 狀態為 %，只有 draft 可以發布', v_recall.recall_no, v_recall.status;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM product_recall_lines WHERE recall_id = p_recall_id) THEN
    RAISE EXCEPTION '召回單 % 沒有任何明細', v_recall.recall_no;
  END IF;

  FOR v_line IN
    SELECT * FROM product_recall_lines WHERE recall_id = p_recall_id ORDER BY store_id, sku_id
  LOOP
    -- 只有 B 桶（貨已到店、訂單還沒取）需要動訂單。
    -- A 桶貨還沒到店，訂單留在 shipping 等攔截後再處理；
    -- C 桶客人已經領走，訂單已經是 picked_up，不能動。
    v_need := v_line.snap_unpicked;
    CONTINUE WHEN v_need <= 0;

    v_pinned := NULL;
    IF p_item_overrides IS NOT NULL AND p_item_overrides ? v_line.id::TEXT THEN
      SELECT array_agg(e::TEXT::BIGINT)
        INTO v_pinned
        FROM jsonb_array_elements(p_item_overrides -> v_line.id::TEXT) e;
    END IF;

    FOR v_coi IN
      SELECT coi.*, co.created_at AS co_created_at, co.order_no AS co_order_no
        FROM customer_order_items coi
        JOIN customer_orders co ON co.id = coi.order_id
       WHERE coi.tenant_id       = v_tenant
         AND co.pickup_store_id  = v_line.store_id
         AND coi.sku_id          = v_line.sku_id
         AND coi.status IN ('pending','reserved','ready')
         AND co.status NOT IN ('cancelled','expired','completed','transferred_out')
         AND co.transferred_from_order_id IS NULL
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND (v_line.campaign_id IS NULL OR co.campaign_id = v_line.campaign_id)
         AND (v_pinned IS NULL OR coi.id = ANY (v_pinned))
       ORDER BY co.created_at DESC, co.order_no DESC, coi.id DESC
       FOR UPDATE OF coi
    LOOP
      EXIT WHEN v_need <= 0;
      v_take := LEAST(v_coi.qty, v_need);

      IF v_take < v_coi.qty THEN
        -- 拆單：新開一行放被召回的量，原行留下客人還拿得到的量。
        -- 拆行法沿用 rpc_record_pickup 的部分取貨（20260630000010）：拆完每一行
        -- 都仍是「整行」語義，收據 / 退貨 / 金額 view 全都不用改。
        INSERT INTO customer_order_items (
          tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
          status, source, notes, discount_amount, discount_percent,
          recall_id, recalled_at, created_by, updated_by, created_at, updated_at
        ) VALUES (
          v_coi.tenant_id, v_coi.order_id, v_coi.campaign_item_id, v_coi.sku_id,
          v_take, v_coi.unit_price, 'cancelled', v_coi.source, v_coi.notes,
          -- 折扣按比例帶過去，剩下的留在原行（金額 view 只看 active 行）
          ROUND(COALESCE(v_coi.discount_amount, 0) * v_take / v_coi.qty, 4),
          v_coi.discount_percent,
          p_recall_id, v_now, v_coi.created_by, v_user, v_now, v_now
        ) RETURNING id INTO v_new_id;

        UPDATE customer_order_items
           SET qty             = qty - v_take,
               discount_amount = COALESCE(discount_amount, 0)
                                 - ROUND(COALESCE(discount_amount, 0) * v_take / v_coi.qty, 4),
               updated_by      = v_user,
               updated_at      = v_now
         WHERE id = v_coi.id;

        v_split := v_split + 1;
        INSERT INTO product_recall_events
          (tenant_id, recall_id, line_id, event_type, qty, ref_type, ref_id, payload, created_by)
        VALUES (v_tenant, p_recall_id, v_line.id, 'order_split', v_take,
                'customer_order_item', v_new_id,
                jsonb_build_object('split_from', v_coi.id, 'order_id', v_coi.order_id,
                                   'order_no', v_coi.co_order_no, 'remaining', v_coi.qty - v_take),
                v_user);
      ELSE
        UPDATE customer_order_items
           SET status      = 'cancelled',
               recall_id   = p_recall_id,
               recalled_at = v_now,
               updated_by  = v_user,
               updated_at  = v_now
         WHERE id = v_coi.id;

        v_cancelled := v_cancelled + 1;
        INSERT INTO product_recall_events
          (tenant_id, recall_id, line_id, event_type, qty, ref_type, ref_id, payload, created_by)
        VALUES (v_tenant, p_recall_id, v_line.id, 'order_cancelled', v_take,
                'customer_order_item', v_coi.id,
                jsonb_build_object('order_id', v_coi.order_id, 'order_no', v_coi.co_order_no),
                v_user);
      END IF;

      v_need := v_need - v_take;
      IF NOT (v_coi.order_id = ANY (v_order_ids)) THEN
        v_order_ids := v_order_ids || v_coi.order_id;
      END IF;
    END LOOP;

    -- 訂單側湊不滿 snap_unpicked（例如客人剛好在開單後把貨取走）：
    -- 差額不是錯誤，實體貨還在店裡就是要退回來，B 桶量不動、記一筆事件備查。
    IF v_need > 0 THEN
      INSERT INTO product_recall_events
        (tenant_id, recall_id, line_id, event_type, qty, note, created_by)
      VALUES (v_tenant, p_recall_id, v_line.id, 'note', v_need,
              '發布時訂單側可取消量不足（差 ' || v_need || '），該量以店端實體庫存退回',
              v_user);
    END IF;
  END LOOP;

  -- ── 訂單收尾 ──
  -- (a) 全部品項都 cancelled/expired、且沒收過錢 → 整單取消（召回標記）。
  --     有付款 / 用過儲值金的單不自動取消，留給人工退款（對帳頁會標「需退款」）。
  IF array_length(v_order_ids, 1) IS NOT NULL THEN
    WITH closed AS (
      UPDATE customer_orders co
         SET status       = 'cancelled',
             cancelled_at = v_now,
             recalled_at  = v_now,
             updated_by   = v_user,
             updated_at   = v_now
       WHERE co.id = ANY (v_order_ids)
         AND co.status NOT IN ('cancelled','completed','expired')
         AND COALESCE(co.payment_status, 'unpaid') <> 'paid'
         AND COALESCE(co.wallet_paid_amount, 0) = 0
         AND NOT EXISTS (
               SELECT 1 FROM customer_order_items x
                WHERE x.order_id = co.id AND x.status NOT IN ('cancelled','expired')
             )
      RETURNING co.id
    )
    SELECT COUNT(*) INTO v_closed FROM closed;

    -- (b) 沒有待取品項 + 取過貨 → completed。CLAUDE.md：任何把品項改成
    --     cancelled 的路徑都要接這一段，否則訂單永遠卡在 partially_completed。
    v_completed := public._close_orders_all_items_settled(v_order_ids, v_user, v_now);
  END IF;

  UPDATE product_recalls
     SET status = 'issued', issued_at = v_now, issued_by = v_user, updated_by = v_user
   WHERE id = p_recall_id;

  INSERT INTO product_recall_events (tenant_id, recall_id, event_type, payload, created_by)
  VALUES (v_tenant, p_recall_id, 'issued',
          jsonb_build_object('items_cancelled', v_cancelled, 'items_split', v_split,
                             'orders_cancelled', v_closed, 'orders_completed', v_completed),
          v_user);

  RETURN jsonb_build_object(
    'recall_id',        p_recall_id,
    'status',           'issued',
    'items_cancelled',  v_cancelled,
    'items_split',      v_split,
    'orders_cancelled', v_closed,
    'orders_completed', v_completed,
    'orders_touched',   COALESCE(array_length(v_order_ids, 1), 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_issue_recall(BIGINT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_issue_recall(BIGINT, JSONB) TO authenticated;

COMMENT ON FUNCTION public.rpc_issue_recall IS
  '發布召回單：B 桶（已到店未取）的顧客訂單品項取消 / 拆單（status=cancelled + recalled_at），'
  '接 _close_orders_all_items_settled 收尾。A 桶等總倉攔截、C 桶等客人拿回來。'
  'p_item_overrides={"<line_id>":[coi_id,...]} 可指定要動哪幾筆訂單。';

-- ------------------------------------------------------------
-- 6. rpc_recall_intercept_transfer — A 桶：攔截還沒收貨的派貨單
-- ------------------------------------------------------------
-- 刻意只允許「整張派貨單的所有品項數量都在召回範圍內」才攔截：
--   派貨單是整張 transfer，部分攔截等於改已發生的庫存異動。部分召回請店家
--   照常收貨、收完走 B 桶。
-- 另外不走 rpc_reject_transfer：那支對波次派貨單有守衛（分店拒收會讓訂單卡在
--   shipping、庫存虛回總倉），而且它的訂單連動是為互助鏈設計的。這裡自己
--   處理訂單side（把該店該品項未取的訂單品項取消），語義才對得上。
CREATE OR REPLACE FUNCTION public.rpc_recall_intercept_transfer(
  p_recall_id   BIGINT,
  p_transfer_id BIGINT,
  p_reason      TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_user     UUID := auth.uid();
  v_now      TIMESTAMPTZ := NOW();
  v_recall   product_recalls%ROWTYPE;
  v_xfer     transfers%ROWTYPE;
  v_store_id BIGINT;
  v_ti       RECORD;
  v_line     product_recall_lines%ROWTYPE;
  v_total    NUMERIC := 0;
  v_items    INT := 0;
BEGIN
  PERFORM public._recall_assert_hq();

  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT * INTO v_recall FROM product_recalls
   WHERE id = p_recall_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到召回單 %', p_recall_id;
  END IF;
  IF v_recall.status <> 'issued' THEN
    RAISE EXCEPTION '召回單 % 狀態為 %，發布後才能攔截', v_recall.recall_no, v_recall.status;
  END IF;

  SELECT * INTO v_xfer FROM transfers
   WHERE id = p_transfer_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到派貨單 %', p_transfer_id;
  END IF;
  IF v_xfer.status <> 'shipped' THEN
    RAISE EXCEPTION '派貨單 % 狀態為 %，只有「運送中」可以攔截（已收貨請走店端退回）',
      v_xfer.transfer_no, v_xfer.status;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM picking_wave_items pwi
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND pwi.wave_id = v_recall.source_wave_id
  ) THEN
    RAISE EXCEPTION '派貨單 % 不屬於本召回單的撿貨單', v_xfer.transfer_no;
  END IF;

  SELECT id INTO v_store_id FROM stores
   WHERE tenant_id = v_tenant AND location_id = v_xfer.dest_location;
  IF v_store_id IS NULL THEN
    RAISE EXCEPTION '派貨單 % 的收貨端不是分店', v_xfer.transfer_no;
  END IF;

  -- 全部品項都要在召回範圍內，而且量要蓋得住
  FOR v_ti IN
    SELECT ti.sku_id, SUM(ti.qty_shipped) AS qty
      FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id AND ti.qty_shipped > 0
     GROUP BY ti.sku_id
  LOOP
    SELECT * INTO v_line FROM product_recall_lines
     WHERE recall_id = p_recall_id AND store_id = v_store_id AND sku_id = v_ti.sku_id;
    IF NOT FOUND OR v_line.qty_target < v_ti.qty THEN
      RAISE EXCEPTION
        '派貨單 % 不能整張攔截：品項 #% 出貨 %，但召回目標只有 %。'
        '部分召回請讓店家照常收貨，收完再由店端退回總倉。',
        v_xfer.transfer_no, v_ti.sku_id, v_ti.qty, COALESCE(v_line.qty_target, 0);
    END IF;
  END LOOP;

  -- 貨帳退回總倉（與 rpc_reject_transfer 同一個 movement_type，對帳看得懂）
  FOR v_ti IN
    SELECT ti.id, ti.sku_id, ti.qty_shipped
      FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id AND ti.qty_shipped > 0
  LOOP
    PERFORM rpc_inbound(
      p_tenant_id       => v_tenant,
      p_location_id     => v_xfer.source_location,
      p_sku_id          => v_ti.sku_id,
      p_quantity        => v_ti.qty_shipped,
      p_unit_cost       => 0,
      p_movement_type   => 'transfer_reject',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => p_transfer_id,
      p_operator        => v_user
    );

    SELECT * INTO v_line FROM product_recall_lines
     WHERE recall_id = p_recall_id AND store_id = v_store_id AND sku_id = v_ti.sku_id;

    INSERT INTO product_recall_events
      (tenant_id, recall_id, line_id, event_type, qty, ref_type, ref_id, payload, created_by)
    VALUES (v_tenant, p_recall_id, v_line.id, 'intercepted', v_ti.qty_shipped,
            'transfer', p_transfer_id,
            jsonb_build_object('transfer_no', v_xfer.transfer_no, 'store_id', v_store_id),
            v_user);

    v_total := v_total + v_ti.qty_shipped;
    v_items := v_items + 1;
  END LOOP;

  UPDATE transfers
     SET status     = 'cancelled',
         recall_id  = p_recall_id,
         notes      = CASE
                        WHEN notes IS NULL OR notes = ''
                        THEN '[召回攔截 ' || v_recall.recall_no || ': ' || COALESCE(p_reason,'') || ']'
                        ELSE notes || E'\n[召回攔截 ' || v_recall.recall_no || ': '
                             || COALESCE(p_reason,'') || ']'
                      END,
         updated_by = v_user
   WHERE id = p_transfer_id;

  -- 訂單側：這批貨永遠不會到店，該店該品項還沒取的訂單品項一併取消。
  -- （rpc_issue_recall 只處理 B 桶，A 桶的訂單要等攔截真的發生才動。）
  PERFORM public._recall_cancel_unpicked_for_intercept(
    p_recall_id, v_store_id, p_transfer_id, v_user, v_now);

  RETURN jsonb_build_object(
    'recall_id',   p_recall_id,
    'transfer_id', p_transfer_id,
    'transfer_no', v_xfer.transfer_no,
    'items',       v_items,
    'total_qty',   v_total
  );
END;
$$;

-- 攔截後的訂單連動（獨立成 helper，讓攔截主流程好讀）
CREATE OR REPLACE FUNCTION public._recall_cancel_unpicked_for_intercept(
  p_recall_id   BIGINT,
  p_store_id    BIGINT,
  p_transfer_id BIGINT,
  p_operator    UUID,
  p_at          TIMESTAMPTZ
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID := public._current_tenant_id();
  v_ti        RECORD;
  v_line      product_recall_lines%ROWTYPE;
  v_coi       RECORD;
  v_need      NUMERIC;
  v_take      NUMERIC;
  v_new_id    BIGINT;
  v_order_ids BIGINT[] := ARRAY[]::BIGINT[];
  v_count     INT := 0;
BEGIN
  FOR v_ti IN
    SELECT ti.sku_id, SUM(ti.qty_shipped) AS qty
      FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id AND ti.qty_shipped > 0
     GROUP BY ti.sku_id
  LOOP
    SELECT * INTO v_line FROM product_recall_lines
     WHERE recall_id = p_recall_id AND store_id = p_store_id AND sku_id = v_ti.sku_id;
    CONTINUE WHEN NOT FOUND;

    v_need := v_ti.qty;
    FOR v_coi IN
      SELECT coi.*, co.order_no AS co_order_no
        FROM customer_order_items coi
        JOIN customer_orders co ON co.id = coi.order_id
       WHERE coi.tenant_id      = v_tenant
         AND co.pickup_store_id = p_store_id
         AND coi.sku_id         = v_ti.sku_id
         AND coi.status IN ('pending','reserved','ready')
         AND co.status NOT IN ('cancelled','expired','completed','transferred_out')
         AND co.transferred_from_order_id IS NULL
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND (v_line.campaign_id IS NULL OR co.campaign_id = v_line.campaign_id)
       ORDER BY co.created_at DESC, co.order_no DESC, coi.id DESC
       FOR UPDATE OF coi
    LOOP
      EXIT WHEN v_need <= 0;
      v_take := LEAST(v_coi.qty, v_need);

      IF v_take < v_coi.qty THEN
        INSERT INTO customer_order_items (
          tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
          status, source, notes, discount_amount, discount_percent,
          recall_id, recalled_at, created_by, updated_by, created_at, updated_at
        ) VALUES (
          v_coi.tenant_id, v_coi.order_id, v_coi.campaign_item_id, v_coi.sku_id,
          v_take, v_coi.unit_price, 'cancelled', v_coi.source, v_coi.notes,
          ROUND(COALESCE(v_coi.discount_amount, 0) * v_take / v_coi.qty, 4),
          v_coi.discount_percent, p_recall_id, p_at, v_coi.created_by, p_operator, p_at, p_at
        ) RETURNING id INTO v_new_id;

        UPDATE customer_order_items
           SET qty             = qty - v_take,
               discount_amount = COALESCE(discount_amount, 0)
                                 - ROUND(COALESCE(discount_amount, 0) * v_take / v_coi.qty, 4),
               updated_by      = p_operator, updated_at = p_at
         WHERE id = v_coi.id;
      ELSE
        UPDATE customer_order_items
           SET status = 'cancelled', recall_id = p_recall_id, recalled_at = p_at,
               updated_by = p_operator, updated_at = p_at
         WHERE id = v_coi.id;
        v_new_id := v_coi.id;
      END IF;

      INSERT INTO product_recall_events
        (tenant_id, recall_id, line_id, event_type, qty, ref_type, ref_id, payload, created_by)
      VALUES (v_tenant, p_recall_id, v_line.id, 'order_cancelled', v_take,
              'customer_order_item', v_new_id,
              jsonb_build_object('order_id', v_coi.order_id, 'order_no', v_coi.co_order_no,
                                 'via', 'intercept'),
              p_operator);

      v_need  := v_need - v_take;
      v_count := v_count + 1;
      IF NOT (v_coi.order_id = ANY (v_order_ids)) THEN
        v_order_ids := v_order_ids || v_coi.order_id;
      END IF;
    END LOOP;
  END LOOP;

  IF array_length(v_order_ids, 1) IS NOT NULL THEN
    UPDATE customer_orders co
       SET status = 'cancelled', cancelled_at = p_at, recalled_at = p_at,
           updated_by = p_operator, updated_at = NOW()
     WHERE co.id = ANY (v_order_ids)
       AND co.status NOT IN ('cancelled','completed','expired')
       AND COALESCE(co.payment_status, 'unpaid') <> 'paid'
       AND COALESCE(co.wallet_paid_amount, 0) = 0
       AND NOT EXISTS (
             SELECT 1 FROM customer_order_items x
              WHERE x.order_id = co.id AND x.status NOT IN ('cancelled','expired')
           );
    PERFORM public._close_orders_all_items_settled(v_order_ids, p_operator, p_at);
  END IF;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_recall_intercept_transfer(BIGINT, BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_recall_intercept_transfer(BIGINT, BIGINT, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 7. rpc_recall_store_ship — B 桶：店端把召回的貨出庫退回總倉
-- ------------------------------------------------------------
-- p_lines: [{ sku_id, qty }]
-- 建一張 return_to_hq transfer 掛 recall_id，之後總倉照既有 /wms/inbound
-- 收貨（rpc_receive_transfer），對帳的「已回收」自己會動。
-- 月結的 return_out 分錄（20260714000100）也會自動沖回分店應付。
CREATE OR REPLACE FUNCTION public.rpc_recall_store_ship(
  p_recall_id BIGINT,
  p_store_id  BIGINT,
  p_lines     JSONB,
  p_notes     TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_user        UUID := auth.uid();
  v_role        TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_recall      product_recalls%ROWTYPE;
  v_store_loc   BIGINT;
  v_hq_loc      BIGINT;
  v_transfer_id BIGINT;
  v_transfer_no TEXT;
  v_line        JSONB;
  v_sku         BIGINT;
  v_qty         NUMERIC;
  v_line_row    product_recall_lines%ROWTYPE;
  v_progress    RECORD;
  v_remaining   NUMERIC;
  v_mov_id      BIGINT;
  v_count       INT := 0;
  v_total       NUMERIC := 0;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','clerk','') THEN
    RAISE EXCEPTION '權限不足：% 不可執行召回退貨', v_role;
  END IF;
  -- 店端只能退自家店。本系統 JWT 沒有 store_id claim，自己店由
  -- app_metadata.stores 店名經 _jwt_store_ids() 推導（CLAUDE.md）。
  IF v_role IN ('store_manager','store_staff','clerk') THEN
    IF NOT (p_store_id = ANY (public._jwt_store_ids())) THEN
      RAISE EXCEPTION '分店帳號只能處理自己店的召回';
    END IF;
  END IF;

  SELECT * INTO v_recall FROM product_recalls
   WHERE id = p_recall_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到召回單 %', p_recall_id;
  END IF;
  IF v_recall.status <> 'issued' THEN
    RAISE EXCEPTION '召回單 % 狀態為 %，發布後才能退貨', v_recall.recall_no, v_recall.status;
  END IF;

  SELECT location_id INTO v_store_loc FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
  IF v_store_loc IS NULL THEN
    RAISE EXCEPTION '分店 % 沒有對應的庫存地點', p_store_id;
  END IF;

  SELECT id INTO v_hq_loc FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN
    RAISE EXCEPTION '找不到啟用中的總倉地點';
  END IF;
  IF v_hq_loc = v_store_loc THEN
    RAISE EXCEPTION '該店的地點就是總倉，無法退回自己';
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '請至少填一個要退回的品項';
  END IF;

  v_transfer_no := public._next_transfer_no();
  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, recall_id,
    requested_by, shipped_by, shipped_at, notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_transfer_no, v_store_loc, v_hq_loc,
    'shipped', 'return_to_hq', p_recall_id,
    v_user, v_user, NOW(),
    '[召回 ' || v_recall.recall_no || COALESCE(': ' || NULLIF(TRIM(COALESCE(p_notes,'')),''), '') || ']',
    v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku := (v_line ->> 'sku_id')::BIGINT;
    v_qty := (v_line ->> 'qty')::NUMERIC;
    CONTINUE WHEN v_qty IS NULL OR v_qty <= 0;

    SELECT * INTO v_line_row FROM product_recall_lines
     WHERE recall_id = p_recall_id AND store_id = p_store_id AND sku_id = v_sku;
    IF NOT FOUND THEN
      RAISE EXCEPTION '召回單 % 沒有 店#% 品項#% 這一格', v_recall.recall_no, p_store_id, v_sku;
    END IF;

    -- 上限：目標 − 已回收 − 沖銷 − 這張單以外的在途回程
    SELECT * INTO v_progress FROM v_recall_line_progress WHERE line_id = v_line_row.id;
    v_remaining := v_line_row.qty_target - COALESCE(v_progress.qty_recovered, 0)
                   - v_line_row.qty_written_off - COALESCE(v_progress.qty_in_return, 0);
    IF v_qty > v_remaining THEN
      RAISE EXCEPTION '品項 % 退回量 % 超過尚待回收量 %（目標 %、已回收 %、在途 %、沖銷 %）',
        v_sku, v_qty, GREATEST(v_remaining, 0), v_line_row.qty_target,
        COALESCE(v_progress.qty_recovered, 0), COALESCE(v_progress.qty_in_return, 0),
        v_line_row.qty_written_off;
    END IF;

    -- 店端出庫 → 在途回總倉。庫存不夠時由 rpc_outbound 擋（Insufficient stock）。
    v_mov_id := rpc_outbound(
      p_tenant_id       => v_tenant,
      p_location_id     => v_store_loc,
      p_sku_id          => v_sku,
      p_quantity        => v_qty,
      p_movement_type   => 'customer_return',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_transfer_id,
      p_operator        => v_user
    );

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped, out_movement_id,
      notes, created_by, updated_by
    ) VALUES (
      v_transfer_id, v_sku, v_qty, v_qty, v_mov_id,
      v_line ->> 'notes', v_user, v_user
    );

    INSERT INTO product_recall_events
      (tenant_id, recall_id, line_id, event_type, qty, ref_type, ref_id, payload, created_by)
    VALUES (v_tenant, p_recall_id, v_line_row.id, 'store_shipped', v_qty,
            'transfer', v_transfer_id,
            jsonb_build_object('transfer_no', v_transfer_no, 'store_id', p_store_id), v_user);

    v_count := v_count + 1;
    v_total := v_total + v_qty;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION '請至少填一個要退回的品項';
  END IF;

  RETURN jsonb_build_object(
    'recall_id',   p_recall_id,
    'transfer_id', v_transfer_id,
    'transfer_no', v_transfer_no,
    'lines',       v_count,
    'total_qty',   v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_recall_store_ship(BIGINT, BIGINT, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_recall_store_ship(BIGINT, BIGINT, JSONB, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_recall_store_ship IS
  '召回 B 桶：分店把店裡的召回品出庫、建 return_to_hq transfer 掛 recall_id。'
  '總倉照既有 /wms/inbound 收貨即可，對帳的「已回收」由 v_recall_line_progress 推導。';

-- ------------------------------------------------------------
-- 8. rpc_recall_customer_return — C 桶：客人拿回來的貨
-- ------------------------------------------------------------
-- 薄包裝：呼叫既有 rpc_create_order_return(restock_first=true)（先把貨入庫店端
-- 再出庫回總倉，上限是客人已取量），完成後只補寫 recall_id 讓它算進召回進度。
-- 不改 rpc_create_order_return 本體 —— 那支已經被改過六次。
CREATE OR REPLACE FUNCTION public.rpc_recall_customer_return(
  p_recall_id BIGINT,
  p_order_id  BIGINT,
  p_lines     JSONB,        -- [{sku_id, qty}]
  p_reason    TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_user     UUID := auth.uid();
  v_recall   product_recalls%ROWTYPE;
  v_store_id BIGINT;
  v_result   JSONB;
  v_xfer_id  BIGINT;
  v_line     JSONB;
  v_line_row product_recall_lines%ROWTYPE;
BEGIN
  SELECT * INTO v_recall FROM product_recalls
   WHERE id = p_recall_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到召回單 %', p_recall_id;
  END IF;
  IF v_recall.status <> 'issued' THEN
    RAISE EXCEPTION '召回單 % 狀態為 %，發布後才能登記客戶歸還', v_recall.recall_no, v_recall.status;
  END IF;

  SELECT pickup_store_id INTO v_store_id FROM customer_orders
   WHERE id = p_order_id AND tenant_id = v_tenant;
  IF v_store_id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 %', p_order_id;
  END IF;

  -- 角色 / 自家店檢查、可退上限、庫存分錄全部由既有退貨 RPC 負責
  v_result := public.rpc_create_order_return(
    p_order_id      => p_order_id,
    p_lines         => p_lines,
    p_reason        => COALESCE(NULLIF(TRIM(COALESCE(p_reason,'')),''), '總倉召回')
                       || '（召回單 ' || v_recall.recall_no || '）',
    p_operator      => v_user,
    p_movement_type => 'customer_return',
    p_restock_first => TRUE
  );

  v_xfer_id := (v_result ->> 'return_transfer_id')::BIGINT;
  UPDATE transfers SET recall_id = p_recall_id WHERE id = v_xfer_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    SELECT * INTO v_line_row FROM product_recall_lines
     WHERE recall_id = p_recall_id AND store_id = v_store_id
       AND sku_id = (v_line ->> 'sku_id')::BIGINT;
    CONTINUE WHEN NOT FOUND;

    INSERT INTO product_recall_events
      (tenant_id, recall_id, line_id, event_type, qty, ref_type, ref_id, payload, created_by)
    VALUES (v_tenant, p_recall_id, v_line_row.id, 'customer_return',
            (v_line ->> 'qty')::NUMERIC, 'transfer', v_xfer_id,
            jsonb_build_object('order_id', p_order_id,
                               'transfer_no', v_result ->> 'transfer_no'), v_user);
  END LOOP;

  RETURN v_result || jsonb_build_object('recall_id', p_recall_id);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_recall_customer_return(BIGINT, BIGINT, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_recall_customer_return(BIGINT, BIGINT, JSONB, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 9. rpc_recall_write_off — 追不回，人工沖銷
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_recall_write_off(
  p_line_id BIGINT,
  p_qty     NUMERIC,
  p_reason  TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_user     UUID := auth.uid();
  v_line     product_recall_lines%ROWTYPE;
  v_progress RECORD;
  v_max      NUMERIC;
BEGIN
  PERFORM public._recall_assert_hq();

  IF NULLIF(TRIM(COALESCE(p_reason,'')),'') IS NULL THEN
    RAISE EXCEPTION '沖銷必須填原因';
  END IF;

  SELECT * INTO v_line FROM product_recall_lines
   WHERE id = p_line_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到召回明細 %', p_line_id;
  END IF;

  SELECT * INTO v_progress FROM v_recall_line_progress WHERE line_id = p_line_id;
  v_max := v_line.qty_target - COALESCE(v_progress.qty_recovered, 0);
  IF p_qty IS NULL OR p_qty <= 0 OR p_qty > v_max THEN
    RAISE EXCEPTION '沖銷量必須介於 0 與 %（目標 % − 已回收 %）之間',
      GREATEST(v_max, 0), v_line.qty_target, COALESCE(v_progress.qty_recovered, 0);
  END IF;

  UPDATE product_recall_lines
     SET qty_written_off    = p_qty,
         written_off_reason = TRIM(p_reason),
         settled_at         = NOW(),
         settled_by         = v_user,
         updated_by         = v_user
   WHERE id = p_line_id;

  INSERT INTO product_recall_events
    (tenant_id, recall_id, line_id, event_type, qty, note, created_by)
  VALUES (v_tenant, v_line.recall_id, p_line_id, 'written_off', p_qty, TRIM(p_reason), v_user);

  RETURN jsonb_build_object('line_id', p_line_id, 'qty_written_off', p_qty);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_recall_write_off(BIGINT, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_recall_write_off(BIGINT, NUMERIC, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 10. rpc_close_recall — 全部回收完成才可結案
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_close_recall(p_recall_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_recall product_recalls%ROWTYPE;
  v_open   INT;
  v_intr   INT;
BEGIN
  PERFORM public._recall_assert_hq();

  SELECT * INTO v_recall FROM product_recalls
   WHERE id = p_recall_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到召回單 %', p_recall_id;
  END IF;
  IF v_recall.status <> 'issued' THEN
    RAISE EXCEPTION '召回單 % 狀態為 %，只有已發布的可以結案', v_recall.recall_no, v_recall.status;
  END IF;

  SELECT COUNT(*) INTO v_open
    FROM v_recall_line_progress WHERE recall_id = p_recall_id AND qty_diff < 0;
  IF v_open > 0 THEN
    RAISE EXCEPTION '還有 % 格沒回收完成，請先回收或沖銷後再結案', v_open;
  END IF;

  -- 還有在途回程就結案，數字會在結案後才進來，對帳會對不上
  SELECT COUNT(*) INTO v_intr
    FROM v_recall_line_progress WHERE recall_id = p_recall_id AND qty_in_return > 0;
  IF v_intr > 0 THEN
    RAISE EXCEPTION '還有 % 格的退貨在途、總倉尚未收貨，請先完成收貨再結案', v_intr;
  END IF;

  UPDATE product_recalls
     SET status = 'completed', completed_at = NOW(), completed_by = v_user, updated_by = v_user
   WHERE id = p_recall_id;

  INSERT INTO product_recall_events (tenant_id, recall_id, event_type, created_by)
  VALUES (v_tenant, p_recall_id, 'completed', v_user);

  RETURN jsonb_build_object('recall_id', p_recall_id, 'status', 'completed');
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_close_recall(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_close_recall(BIGINT) TO authenticated;

-- ------------------------------------------------------------
-- 11. 讀取用 RPC（對帳頁 / 列表頁）
-- ------------------------------------------------------------
-- 為什麼不讓前端直接讀 view：v_recall_line_progress 的 LATERAL 會 join
-- transfers / transfer_items / customer_order_items，這些表的 RLS 對分店帳號
-- 是「只看自己那家」。view 設了 security_invoker=on，分店直接讀會拿到被 RLS
-- 過濾後「少算」的彙總數字（不是被擋，是靜靜地算錯）。走 SECURITY DEFINER
-- RPC 讓彙總以完整資料計算，再由 RPC 自己按角色決定回哪幾格。
CREATE OR REPLACE FUNCTION public.rpc_recall_detail(p_recall_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID := public._current_tenant_id();
  v_role      TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_is_store  BOOLEAN := v_role IN ('store_manager','store_staff','clerk');
  v_stores    BIGINT[] := public._jwt_store_ids();
  v_header    JSONB;
  v_lines     JSONB;
  v_events    JSONB;
  v_orders    JSONB;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant','assistant','',
                    'store_manager','store_staff','clerk') THEN
    RAISE EXCEPTION '權限不足：% 不可檢視召回單', v_role;
  END IF;

  SELECT to_jsonb(s) INTO v_header FROM v_recall_summary s
   WHERE s.recall_id = p_recall_id AND s.tenant_id = v_tenant;
  IF v_header IS NULL THEN
    RAISE EXCEPTION '找不到召回單 %', p_recall_id;
  END IF;

  SELECT jsonb_agg(to_jsonb(p) ORDER BY p.store_name, p.sku_code)
    INTO v_lines
    FROM v_recall_line_progress p
   WHERE p.recall_id = p_recall_id
     AND (NOT v_is_store OR p.store_id = ANY (v_stores));

  IF v_is_store AND v_lines IS NULL THEN
    RAISE EXCEPTION '這張召回單沒有你負責的分店';
  END IF;

  SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC)
    INTO v_events
    FROM (
      SELECT jsonb_build_object(
        'id', e.id, 'line_id', e.line_id, 'event_type', e.event_type,
        'qty', e.qty, 'ref_type', e.ref_type, 'ref_id', e.ref_id,
        'payload', e.payload, 'note', e.note, 'created_at', e.created_at
      ) AS x
        FROM product_recall_events e
        LEFT JOIN product_recall_lines l ON l.id = e.line_id
       WHERE e.recall_id = p_recall_id
         AND (NOT v_is_store OR l.store_id = ANY (v_stores))
       ORDER BY e.created_at DESC
       LIMIT 300
    ) q;

  -- 受影響的訂單：被本次召回動過的品項 + 客人已取待追回的品項。
  -- needs_refund：客人付過錢 / 用過儲值金但品項被召回 → 對帳頁標紅，不自動退。
  SELECT jsonb_agg(x ORDER BY x->>'order_no')
    INTO v_orders
    FROM (
      SELECT jsonb_build_object(
        'order_id',      co.id,
        'order_no',      co.order_no,
        'store_id',      co.pickup_store_id,
        'store_name',    st.name,
        'customer',      COALESCE(m.name, co.nickname_snapshot),
        'order_status',  co.status,
        'recalled_qty',  SUM(coi.qty),
        'sku_codes',     string_agg(DISTINCT sk.sku_code, ', '),
        'wallet_paid',   COALESCE(co.wallet_paid_amount, 0),
        'payment_status', COALESCE(co.payment_status, 'unpaid'),
        'needs_refund',  (COALESCE(co.wallet_paid_amount, 0) > 0
                          OR COALESCE(co.payment_status,'unpaid') = 'paid')
      ) AS x
        FROM customer_order_items coi
        JOIN customer_orders co ON co.id = coi.order_id
        JOIN stores st ON st.id = co.pickup_store_id
        JOIN skus sk ON sk.id = coi.sku_id
        LEFT JOIN members m ON m.id = co.member_id
       WHERE coi.recall_id = p_recall_id
         AND (NOT v_is_store OR co.pickup_store_id = ANY (v_stores))
       GROUP BY co.id, co.order_no, co.pickup_store_id, st.name, m.name,
                co.nickname_snapshot, co.status, co.wallet_paid_amount, co.payment_status
    ) q;

  RETURN jsonb_build_object(
    'header',   v_header,
    'lines',    COALESCE(v_lines, '[]'::jsonb),
    'events',   COALESCE(v_events, '[]'::jsonb),
    'orders',   COALESCE(v_orders, '[]'::jsonb),
    'is_store', v_is_store
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_recall_detail(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_recall_detail(BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_recall_list(
  p_status TEXT DEFAULT NULL,
  p_limit  INTEGER DEFAULT 100
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_is_store BOOLEAN := v_role IN ('store_manager','store_staff','clerk');
  v_stores   BIGINT[] := public._jwt_store_ids();
  v_rows     JSONB;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant','assistant','',
                    'store_manager','store_staff','clerk') THEN
    RAISE EXCEPTION '權限不足：% 不可檢視召回單', v_role;
  END IF;

  SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC)
    INTO v_rows
    FROM (
      SELECT * FROM v_recall_summary s
       WHERE s.tenant_id = v_tenant
         AND (p_status IS NULL OR p_status = '' OR s.status = p_status)
         AND (NOT v_is_store OR EXISTS (
               SELECT 1 FROM product_recall_lines l
                WHERE l.recall_id = s.recall_id AND l.store_id = ANY (v_stores)))
       ORDER BY s.created_at DESC
       LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    ) s;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_recall_list(TEXT, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_recall_list(TEXT, INTEGER) TO authenticated;

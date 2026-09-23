-- ============================================================================
-- 2026-09-23: 派貨工作台一般 PO 建單加總倉庫存封頂
--
-- 症狀：
--   同一團同商品若曾被舊入口重複開出 PO，派貨工作台會把兩張 PO 的到貨量加總，
--   造成畫面可分配量大於總倉真正帳上可派量。
--
-- 修法：
--   rpc_create_wave_from_po 在建立撿貨單前，額外檢查：
--     本次分配量 + 尚未出倉撿貨單保留量 <= stock_balances.on_hand - reserved。
--   已出倉 wave 不重複保留，因為出倉流程已經扣總倉實體庫存。
--
-- Rollback：
--   CREATE OR REPLACE 回 20260908000000_release_short_picked_wave_qty.sql 的
--   rpc_create_wave_from_po。
-- ============================================================================

DO $$
DECLARE
  v_sql TEXT;
  v_decl_pattern TEXT := E'(\\n\\s*v_borrow\\s+RECORD;)';
  v_guard_pattern TEXT := E'(\\n\\s*-- 4\\.5 借調守衛)';
  v_guard_sql TEXT := $guard$
  -- 4.2 守衛：跨 PO / 舊 PO 殘留時，總分配不可超過總倉真正可派量。
  --     open wave 只算 draft / picking / picked；shipped 已經由出倉流程扣 on_hand，
  --     若再算一次會把同一批貨重複保留。
  SELECT id INTO v_hq_location_id
    FROM public.locations
   WHERE tenant_id = v_tenant
     AND type = 'central_warehouse'
     AND is_active = TRUE
   ORDER BY id
   LIMIT 1;

  IF v_hq_location_id IS NULL THEN
    RAISE EXCEPTION '找不到總倉 location(type=central_warehouse)';
  END IF;

  -- 與退回貨 reserved / 其他派貨建單共用同一 balance 鎖；SKU 升冪避免死鎖。
  FOR v_sku_id IN
    SELECT DISTINCT (a->>'sku_id')::BIGINT
      FROM jsonb_array_elements(p_allocations) a
     ORDER BY 1
  LOOP
    PERFORM 1
      FROM public.stock_balances
     WHERE tenant_id = v_tenant
       AND location_id = v_hq_location_id
       AND sku_id = v_sku_id
     FOR UPDATE;
  END LOOP;

  WITH alloc_agg AS (
    SELECT
      (a->>'sku_id')::BIGINT AS sku_id,
      SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  open_wave_reserved AS (
    SELECT pwi.sku_id, SUM(pwi.qty) AS qty
      FROM public.picking_wave_items pwi
      JOIN public.picking_waves pw ON pw.id = pwi.wave_id
     WHERE pw.tenant_id = v_tenant
       AND pw.status IN ('draft','picking','picked')
       AND pwi.sku_id IN (SELECT sku_id FROM alloc_agg)
     GROUP BY pwi.sku_id
  ),
  hq_state AS (
    SELECT
      aa.sku_id,
      aa.total_alloc,
      GREATEST(COALESCE(sb.on_hand, 0) - COALESCE(sb.reserved, 0), 0) AS hq_available_qty,
      COALESCE(ow.qty, 0) AS open_wave_qty
    FROM alloc_agg aa
    LEFT JOIN public.stock_balances sb
      ON sb.tenant_id = v_tenant
     AND sb.location_id = v_hq_location_id
     AND sb.sku_id = aa.sku_id
    LEFT JOIN open_wave_reserved ow ON ow.sku_id = aa.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
    hs.total_alloc,
    hs.hq_available_qty,
    hs.open_wave_qty,
    GREATEST(hs.hq_available_qty - hs.open_wave_qty, 0) AS hq_left
  INTO v_stock_over
  FROM hq_state hs
  JOIN public.skus s ON s.id = hs.sku_id AND s.tenant_id = v_tenant
  WHERE hs.total_alloc > GREATEST(hs.hq_available_qty - hs.open_wave_qty, 0)
  LIMIT 1;

  IF v_stock_over.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」分配 % 超過總倉可派量 %（帳上可派 %、未出倉撿貨單已保留 %）',
      v_stock_over.sku_code, v_stock_over.sku_label,
      v_stock_over.total_alloc, v_stock_over.hq_left,
      v_stock_over.hq_available_qty, v_stock_over.open_wave_qty;
  END IF;
$guard$;
BEGIN
  SELECT pg_get_functiondef('public.rpc_create_wave_from_po(bigint, date, jsonb, uuid)'::regprocedure)
    INTO v_sql;

  IF v_sql IS NULL THEN
    RAISE EXCEPTION '找不到 public.rpc_create_wave_from_po(bigint, date, jsonb, uuid)';
  END IF;

  IF POSITION('v_hq_location_id' IN v_sql) = 0 THEN
    IF v_sql !~ v_decl_pattern THEN
      RAISE EXCEPTION 'rpc_create_wave_from_po 結構已變更：找不到變數插入點 v_borrow RECORD';
    END IF;
    IF v_sql !~ v_guard_pattern THEN
      RAISE EXCEPTION 'rpc_create_wave_from_po 結構已變更：找不到守衛插入點 -- 4.5 借調守衛';
    END IF;

    v_sql := regexp_replace(
      v_sql,
      v_decl_pattern,
      E'\\1\n  v_hq_location_id  BIGINT;\n  v_stock_over      RECORD;'
    );
    v_sql := regexp_replace(v_sql, v_guard_pattern, v_guard_sql || E'\n\\1');
    EXECUTE v_sql;
  ELSE
    RAISE NOTICE 'rpc_create_wave_from_po 已有總倉庫存封頂守衛，略過重複插入';
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_create_wave_from_po(BIGINT, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_wave_from_po(BIGINT, DATE, JSONB, UUID) IS
  '由派貨工作台建撿貨單。跨團守衛：本單開團有需求 → 標該團；補貨來源 → NULL + 補貨 cap；'
  '都沒有 → 跨團借調（標「實際被服務的團」，總量 ≤ 本單餘量 = 可分配 − 自己未派需求，'
  '步驟 4.5 守衛）。新增總倉庫存封頂：本次分配 + 未出倉 wave 保留量 ≤ on_hand - reserved。';

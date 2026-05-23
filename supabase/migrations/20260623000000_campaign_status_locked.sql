-- ============================================================
-- 開團新增 `locked` 狀態 + 連帶調整
--
-- 變更背景:
--   原本 closed 同時代表「App 不顯示」+「不能加單 + 可開 PR」。
--   實務上門市結團後仍需要補加單窗口,因此語意拆分:
--     closed = App 不顯示,HQ/店家仍可補加單、改 qty
--     locked = 請購單已建,需求鎖定,不可加單/改 qty
--   locked 由 Stage 4 的 PR RPC 自動推進,不開放手動切。
--
-- 本 migration 內容:
--   1. CHECK constraint 加入 'locked'
--   2. RLS policy gbc_store_read 白名單加 'locked'
--   3. rpc_finalize_campaign 接受從 'locked' 結案
--   4. rpc_orders_pivot 的 closed-only filter 加 'locked'
--   5. v_po_demand_by_store view 的 JOIN clause 加 'locked'
--   6. 順手修 rpc_advance_order_status 從未設 confirmed_at 的 bug
--
-- 故意不動的:
--   - rpc_bulk_set_campaign_status:維持只允許 draft/open/closed/cancelled
--   - rpc_pr_from_campaigns:守衛保留,locked campaign 被拒(不能重複建 PR)
-- ============================================================

-- ----------------------------------------------------------------
-- 1. CHECK constraint 擴充
-- ----------------------------------------------------------------
ALTER TABLE group_buy_campaigns
  DROP CONSTRAINT group_buy_campaigns_status_check;

ALTER TABLE group_buy_campaigns
  ADD CONSTRAINT group_buy_campaigns_status_check
  CHECK (status IN (
    'draft','open','closed',
    'locked',
    'ordered','receiving','ready','completed','cancelled'
  ));

COMMENT ON COLUMN group_buy_campaigns.status IS
  'draft → open → closed → locked → ordered → receiving → ready → completed; '
  'closed = App 不顯示,HQ/店家仍可補加單/改 qty; '
  'locked = 請購單已建,所有訂單自動 confirmed,不可加單/改 qty; '
  'ordered 以後 = 採購進行中(目前無 RPC 自動推進)';

-- ----------------------------------------------------------------
-- 2. RLS policy gbc_store_read 加 'locked'(店家可看到自家鎖定中的團)
-- ----------------------------------------------------------------
DROP POLICY IF EXISTS gbc_store_read ON group_buy_campaigns;

CREATE POLICY gbc_store_read ON group_buy_campaigns
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND status IN ('open','closed','locked','ordered','receiving','ready','completed')
  );

-- ----------------------------------------------------------------
-- 3. rpc_finalize_campaign:可結案的狀態集加 'locked'
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_finalize_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_status      TEXT;
  v_open_orders INTEGER;
BEGIN
  SELECT status INTO v_status
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_status NOT IN ('closed','locked','ordered','receiving','ready') THEN
    RAISE EXCEPTION 'campaign % not in finalizable status (current: %)', p_campaign_id, v_status;
  END IF;

  -- 守衛:仍有未結案的顧客訂單
  SELECT COUNT(*) INTO v_open_orders
    FROM customer_orders
   WHERE campaign_id = p_campaign_id
     AND status NOT IN ('completed','expired','cancelled');

  IF v_open_orders > 0 THEN
    RAISE EXCEPTION 'campaign % has % unfinished customer orders', p_campaign_id, v_open_orders;
  END IF;

  UPDATE group_buy_campaigns
     SET status = 'completed',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_campaign_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_finalize_campaign IS
  '整單結算:所有顧客訂單結案後 campaign 轉 completed(可從 closed/locked/ordered/receiving/ready 進入)';

-- ----------------------------------------------------------------
-- 4. rpc_orders_pivot:closed-only filter 加 'locked'
--    (locked campaign 也屬於「post-收單」階段)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_orders_pivot(
  p_view_by      text,
  p_date_from    date,
  p_date_to      date,
  p_campaign_ids bigint[],
  p_store_id     bigint,
  p_statuses     text[],
  p_closed_only  boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH filtered AS (
    SELECT o.*
    FROM customer_orders o
    LEFT JOIN group_buy_campaigns c ON c.id = o.campaign_id
    WHERE o.status = ANY(p_statuses)
      AND (p_store_id IS NULL OR o.pickup_store_id = p_store_id)
      AND (
        p_campaign_ids IS NULL
        OR cardinality(p_campaign_ids) = 0
        OR o.campaign_id = ANY(p_campaign_ids)
      )
      AND (
        p_closed_only IS NULL
        OR (p_closed_only IS TRUE
            AND c.status IN ('closed','locked','ordered','receiving','ready','completed'))
        OR (p_closed_only IS FALSE
            AND c.status NOT IN ('closed','locked','ordered','receiving','ready','completed'))
      )
      AND CASE p_view_by
        WHEN 'pickup_date' THEN
          (p_date_from IS NULL OR o.pickup_deadline >= p_date_from)
          AND (p_date_to IS NULL OR o.pickup_deadline <  p_date_to)
        WHEN 'order_date' THEN
          (p_date_from IS NULL OR o.created_at >= p_date_from::timestamptz)
          AND (p_date_to IS NULL OR o.created_at <  p_date_to::timestamptz)
        WHEN 'campaign' THEN
          c.end_at IS NULL
          OR (
            (p_date_from IS NULL OR c.end_at >= p_date_from::timestamptz)
            AND (p_date_to IS NULL OR c.end_at <  p_date_to::timestamptz)
          )
        ELSE TRUE
      END
  ),
  base AS (
    SELECT
      CASE p_view_by
        WHEN 'campaign'    THEN 'c' || f.campaign_id::text
        WHEN 'pickup_date' THEN 'd' || to_char(COALESCE(f.pickup_deadline, f.created_at::date), 'YYYY-MM-DD')
        WHEN 'order_date'  THEN 'd' || to_char(f.created_at::date, 'YYYY-MM-DD')
      END                                              AS group_key,
      CASE WHEN p_view_by = 'campaign' THEN f.campaign_id ELSE NULL::bigint END
                                                       AS group_id,
      i.sku_id,
      s.product_name                                   AS sku_product_name,
      s.variant_name                                   AS sku_variant_name,
      f.pickup_store_id,
      f.id                                             AS order_id,
      f.status,
      i.qty,
      i.unit_price
    FROM filtered f
    JOIN customer_order_items i ON i.order_id = f.id
    LEFT JOIN skus s ON s.id = i.sku_id
  ),
  agg AS (
    SELECT
      b.group_key,
      b.group_id,
      b.sku_id,
      b.sku_product_name,
      b.sku_variant_name,
      b.pickup_store_id,
      SUM(CASE WHEN b.status IN ('cancelled','expired','transferred_out')
               THEN 0 ELSE b.qty END)::numeric                            AS qty_sum,
      SUM(CASE WHEN b.status IN ('cancelled','expired','transferred_out')
               THEN 0 ELSE b.qty * b.unit_price END)::numeric             AS amount,
      SUM(CASE WHEN b.status IN ('cancelled','expired','transferred_out')
               THEN b.qty ELSE 0 END)::numeric                            AS neg_qty_sum,
      SUM(CASE WHEN b.status IN ('cancelled','expired','transferred_out')
               THEN b.qty * b.unit_price ELSE 0 END)::numeric             AS neg_amount,
      COALESCE(
        ARRAY_AGG(DISTINCT b.order_id)
          FILTER (WHERE b.status NOT IN ('cancelled','expired','transferred_out')),
        '{}'::bigint[]
      )                                                                   AS pos_order_ids,
      COALESCE(
        ARRAY_AGG(DISTINCT b.order_id)
          FILTER (WHERE b.status IN ('cancelled','expired','transferred_out')),
        '{}'::bigint[]
      )                                                                   AS neg_order_ids
    FROM base b
    GROUP BY
      b.group_key,
      b.group_id,
      b.sku_id,
      b.sku_product_name,
      b.sku_variant_name,
      b.pickup_store_id
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(agg.*)), '[]'::jsonb)
  FROM agg;
$$;

-- ----------------------------------------------------------------
-- 5. v_po_demand_by_store view:JOIN clause 加 'locked'
--    (locked campaign 的訂單仍需被分配揀貨)
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW v_po_demand_by_store AS
SELECT
  po.id              AS po_id,
  po.tenant_id,
  poi.id             AS po_item_id,
  poi.sku_id,
  pr.source_close_date AS close_date,
  co.pickup_store_id AS store_id,
  s.code             AS store_code,
  s.name             AS store_name,
  SUM(coi.qty)       AS demand_qty
FROM purchase_orders po
JOIN purchase_order_items poi ON poi.po_id = po.id
JOIN purchase_request_items pri ON pri.po_item_id = poi.id
JOIN purchase_requests pr ON pr.id = pri.pr_id AND pr.source_close_date IS NOT NULL
JOIN group_buy_campaigns gbc
  ON gbc.tenant_id = po.tenant_id
 AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = pr.source_close_date
 AND gbc.status IN ('closed','locked','ordered','receiving','ready','completed')
JOIN customer_orders co ON co.campaign_id = gbc.id AND co.status NOT IN ('cancelled','expired')
JOIN customer_order_items coi ON coi.order_id = co.id
                              AND coi.sku_id = poi.sku_id
                              AND coi.status NOT IN ('cancelled','expired')
JOIN stores s ON s.id = co.pickup_store_id
GROUP BY po.id, po.tenant_id, poi.id, poi.sku_id, pr.source_close_date,
         co.pickup_store_id, s.code, s.name;

COMMENT ON VIEW v_po_demand_by_store IS
  '從 PO 反查同 close_date 各分店對該 PO SKU 的訂單需求量(撿貨分配參考);涵蓋 closed/locked/ordered/receiving/ready/completed 開團';

-- ----------------------------------------------------------------
-- 6. 順手修 rpc_advance_order_status:補 confirmed_at 設值
--    歷史 bug — schema 有 confirmed_at 欄位但 RPC 從未設值
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_advance_order_status(
  p_order_id   BIGINT,
  p_new_status TEXT,
  p_operator   UUID
) RETURNS customer_orders
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_orig customer_orders%ROWTYPE;
  v_ok   BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;

  -- 驗合法 forward 轉移
  v_ok := (v_orig.status = 'pending'   AND p_new_status = 'confirmed')
       OR (v_orig.status = 'confirmed' AND p_new_status = 'shipping')
       OR (v_orig.status = 'shipping'  AND p_new_status = 'ready')
       OR (v_orig.status = 'ready'     AND p_new_status = 'completed');
  IF NOT v_ok THEN
    RAISE EXCEPTION 'invalid status transition: % → %', v_orig.status, p_new_status;
  END IF;

  UPDATE customer_orders
     SET status = p_new_status,
         updated_by = p_operator,
         updated_at = NOW(),
         confirmed_at = CASE
           WHEN p_new_status = 'confirmed' AND confirmed_at IS NULL THEN NOW()
           ELSE confirmed_at
         END
   WHERE id = p_order_id
   RETURNING * INTO v_orig;

  RETURN v_orig;
END;
$$;

COMMENT ON FUNCTION rpc_advance_order_status IS
  '訂單狀態 forward 推進(pending→confirmed→shipping→ready→completed),bypass RLS、驗合法轉移;'
  '推進到 confirmed 會補 confirmed_at(若為 NULL)';

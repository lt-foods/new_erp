-- ============================================================
-- 2026-08-08: 會員端「已售出 / 剩餘 N 份」不再重複計算轉出的量
--
-- 延續 20260808000000（後台統計）：同一個根因也打到**顧客看得到的**
--   數字。轉單是「複製 + 標記」不是「搬移」：
--     整單轉出 → 來源單 status='transferred_out'，品項原封不動；
--     部分轉出 → 來源品項 status='cancelled' 但留在來源單上。
--   這三支 RPC 都只濾了 ('cancelled','expired')：
--     - 訂單層級漏掉 'transferred_out'
--     - 品項層級完全沒濾
--   ⇒ 已售出被灌水。線上受影響：106 個團、合計虛增 518 件。
--
-- 為什麼比後台統計嚴重：ordered_qty 會拿去跟 cap_qty / total_cap_qty
--   相減算「剩 N 份」「搶購一空」（apps/member/src/components/CampaignCard.tsx
--   remaining()/soldOut()）。虛增的量會吃掉限量名額，把還有貨的團顯示成
--   售完、把真的想買的會員擋在外面。（目前線上還沒有品項被誤判售完，
--   是運氣，不是設計。）
--
-- 修法：三支一律改成
--     co.status NOT IN ('cancelled','expired','transferred_out')
--     coi.status NOT IN ('cancelled','expired')          -- 有 join 品項的才需要
--   與 lib/orderStatus.ts 的 orderCountsInTotals / orderItemCountsInTotals
--   同一套規則。
--
-- 同批一起改（同一個 commit）：supabase/functions/liff-api/index.ts
--   的 listActiveCampaigns.orderedMap 與開團詳情 itemOrderedMap —— 顧客端
--   實際顯示的數字是走那兩段 PostgREST 查詢，不是這裡的 RPC。
--
-- 基底版本：三支都以 2026-08-08 線上 pg_get_functiondef 逐字取回為基底。
--   注意 drift：rpc_member_campaign_aggregates / rpc_member_campaign_detail
--   在 supabase/migrations/ 裡**完全沒有對應檔案**（線上手動建的），
--   本檔一併把它們收編進 migration 歷史。三支都是 anon 可呼叫。
-- Rollback：CREATE OR REPLACE 回本檔內文，把 'transferred_out' 與
--   coi.status 條件移除即為前一版。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_member_campaign_order_counts：訂單筆數（最熱銷 / 近期售出排序）
--    轉出的來源單與轉入單會各算一筆 → 排除 transferred_out
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_member_campaign_order_counts(
  p_tenant uuid,
  p_recent_days integer DEFAULT 7
)
RETURNS TABLE(campaign_id bigint, order_count bigint, recent_order_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    co.campaign_id,
    COUNT(*) AS order_count,
    COUNT(*) FILTER (
      WHERE co.created_at >= now() - make_interval(days => GREATEST(p_recent_days, 0))
    ) AS recent_order_count
  FROM customer_orders co
  WHERE co.tenant_id = p_tenant
    AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
    AND COALESCE(co.order_kind, 'normal') = 'normal'
  GROUP BY co.campaign_id;
$function$;

-- ----------------------------------------------------------------
-- 2. rpc_member_campaign_aggregates：每團訂單數 + 已下單總量
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_member_campaign_aggregates(
  p_tenant uuid,
  p_recent_days integer DEFAULT 7
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH
  filtered_orders AS (
    SELECT co.id, co.campaign_id, co.created_at
    FROM customer_orders co
    WHERE co.tenant_id = p_tenant
      AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
  ),
  counts AS (
    SELECT
      fo.campaign_id,
      COUNT(*)::bigint AS order_count,
      COUNT(*) FILTER (
        WHERE fo.created_at >= now() - make_interval(days => GREATEST(p_recent_days, 0))
      )::bigint AS recent_order_count
    FROM filtered_orders fo
    GROUP BY fo.campaign_id
  ),
  qtys AS (
    SELECT
      fo.campaign_id,
      SUM(coi.qty)::numeric AS ordered_qty
    FROM filtered_orders fo
    JOIN customer_order_items coi ON coi.order_id = fo.id
    -- 部分轉出把整項轉走的來源品項標 cancelled 留在原單上
    WHERE coi.status NOT IN ('cancelled', 'expired')
    GROUP BY fo.campaign_id
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'campaign_id',         c.campaign_id,
        'order_count',         c.order_count,
        'recent_order_count',  c.recent_order_count,
        'ordered_qty',         COALESCE(q.ordered_qty, 0)
      )
    ),
    '[]'::jsonb
  )
  FROM counts c
  LEFT JOIN qtys q ON q.campaign_id = c.campaign_id;
$function$;

-- ----------------------------------------------------------------
-- 3. rpc_member_campaign_detail：開團詳情（每個 campaign_item 的已售出）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_member_campaign_detail(
  p_tenant uuid,
  p_campaign_id bigint
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH
  c AS (
    SELECT
      gbc.id,
      gbc.campaign_no,
      gbc.name,
      gbc.description,
      gbc.cover_image_url,
      gbc.status,
      gbc.end_at,
      gbc.pickup_deadline
    FROM group_buy_campaigns gbc
    WHERE gbc.tenant_id = p_tenant
      AND gbc.id = p_campaign_id
  ),
  items AS (
    SELECT
      ci.id,
      ci.unit_price,
      ci.cap_qty,
      ci.sort_order,
      sku.id           AS sku_id,
      sku.sku_code     AS sku_code,
      sku.product_name AS sku_product_name,
      sku.variant_name AS sku_variant_name,
      p.name           AS product_name,
      p.images         AS product_images
    FROM campaign_items ci
    JOIN skus sku ON sku.id = ci.sku_id
    LEFT JOIN products p ON p.id = sku.product_id
    WHERE ci.tenant_id = p_tenant
      AND ci.campaign_id = p_campaign_id
  ),
  -- 訂單筆數 (含品項一筆訂單只算一次)
  order_count AS (
    SELECT COUNT(*)::bigint AS n
    FROM customer_orders co
    WHERE co.tenant_id = p_tenant
      AND co.campaign_id = p_campaign_id
      AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
  ),
  -- 每個 campaign_item 累計已下單數量
  -- (排除取消/逾期/轉出的單、排除非 normal 訂單、排除已取消的品項)
  ordered_qty_per_item AS (
    SELECT
      coi.campaign_item_id,
      SUM(coi.qty)::numeric AS total_qty
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    WHERE coi.tenant_id = p_tenant
      AND co.campaign_id = p_campaign_id
      AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND coi.status NOT IN ('cancelled', 'expired')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
    GROUP BY coi.campaign_item_id
  )
  SELECT jsonb_build_object(
    'campaign', (
      SELECT to_jsonb(c) || jsonb_build_object(
        'order_count', (SELECT n FROM order_count)
      )
      FROM c
    ),
    'items', COALESCE((
      SELECT jsonb_agg(
        to_jsonb(items) || jsonb_build_object(
          'ordered_qty', COALESCE(oq.total_qty, 0)
        )
        ORDER BY items.sort_order ASC, items.id ASC
      )
      FROM items
      LEFT JOIN ordered_qty_per_item oq ON oq.campaign_item_id = items.id
    ), '[]'::jsonb)
  )
  FROM c;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_order_counts(uuid, integer) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_aggregates(uuid, integer)   TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_detail(uuid, bigint)        TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.rpc_member_campaign_order_counts(uuid, integer) IS
  '會員端每團訂單筆數（最熱銷 / 近期售出排序用）。排除 cancelled/expired/transferred_out —— '
  '轉出的來源單與轉入單否則會各算一筆。基底：2026-08-08 線上版。';
COMMENT ON FUNCTION public.rpc_member_campaign_aggregates(uuid, integer) IS
  '會員端每團訂單數 + 已下單總量。訂單層級排除 cancelled/expired/transferred_out、'
  '品項層級排除 cancelled/expired（部分轉出的來源品項留在原單），否則已售出會虛增。'
  '基底：2026-08-08 線上版（此函式原本不在 migrations 內，本檔收編）。';
COMMENT ON FUNCTION public.rpc_member_campaign_detail(uuid, bigint) IS
  '會員端開團詳情：每個 campaign_item 的已售出。過濾規則同 rpc_member_campaign_aggregates。'
  'ordered_qty 會拿去跟 cap_qty 相減算「剩 N 份」，虛增會把還有貨的品項顯示成售完。'
  '基底：2026-08-08 線上版（此函式原本不在 migrations 內，本檔收編）。';

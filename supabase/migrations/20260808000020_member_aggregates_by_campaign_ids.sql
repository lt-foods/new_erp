-- ============================================================
-- 2026-08-08: 會員端「已售出 / N 人下單」改走單一聚合 RPC，修掉 1000 列截斷
--
-- 延續 20260808000010_member_sold_qty_exclude_transferred。修完重複計數後
-- 實測顧客端列表，發現同一批數字
-- 還有兩個更大的洞（都是 PostgREST 的 1000 列上限，靜默截斷、沒有錯誤）：
--
--   1. ordered_qty（已售出 / 剩 N 份）
--      liff-api listActiveCampaigns 是「撈出所有訂單再在 JS 加總」：
--        .from("customer_orders").select("campaign_id, customer_order_items(qty)")
--      目前 84 個上架中的團底下有 1616 筆訂單 > 1000 ⇒ 後面的整批被丟掉，
--      已售出少算。（程式碼裡 order_count 那段的註解早就寫過這個坑，
--      但 ordered_qty 這段沒跟著改。）
--
--   2. order_count / recent_order_count（已有 N 人下單、最熱銷排序）
--      改用 rpc_member_campaign_order_counts 之後仍會踩到 —— 它
--      RETURNS TABLE，一個團一列，全租戶有 1595 個團有訂單 > 1000，
--      而且順序是 campaign_id ASC ⇒ **被截掉的正好是 id 最大的新團**。
--      實測目前 open 且上架的團裡有 83 個落在截斷區，通通顯示 0 人下單。
--
-- 修法：rpc_member_campaign_aggregates 加上 p_campaign_ids 參數，讓
--   liff-api 一次只問「這一頁要顯示的團」。它 RETURNS jsonb（單列單值），
--   本身就不受 1000 列上限影響，order_count / recent_order_count /
--   ordered_qty 三個數字也收斂到同一支、同一套過濾規則，不會再各自漂移。
--
-- 參數是加在既有函式上，不能用 CREATE OR REPLACE（多一個帶 DEFAULT 的
--   參數會變成新的 overload，2 參數呼叫就會 "function is not unique"），
--   所以先 DROP 舊簽章。新簽章對舊的 2 參數具名呼叫仍相容（走 DEFAULT）。
--
-- rpc_member_campaign_order_counts 保留不動（20260808000010_member_sold_qty_… 已修過過濾
--   規則），但 liff-api 不再使用；COMMENT 標註它有 1000 列上限、新程式
--   請改用本函式，避免下次有人再踩。
--
-- 基底版本：rpc_member_campaign_aggregates = 20260808000010_member_sold_qty_
--   exclude_transferred 版。（注意 20260808000010 這個編號同時有三個檔案：
--   另兩支 account_link_invite / payable_exclude_cancelled_items 來自 main，
--   動到的物件與本檔不重疊，套用順序無關。）
-- Rollback：DROP 三參數版，CREATE 回 20260808000010_member_sold_qty_exclude_
--   transferred 的兩參數版。
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_member_campaign_aggregates(uuid, integer);

CREATE OR REPLACE FUNCTION public.rpc_member_campaign_aggregates(
  p_tenant       uuid,
  p_recent_days  integer  DEFAULT 7,
  p_campaign_ids bigint[] DEFAULT NULL
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
      -- 轉單是「複製 + 標記」不是「搬移」：來源單留著 transferred_out，
      -- 不排除的話一張單會連同轉入單被算兩次（見 20260808000010_member_sold_qty_exclude_transferred）
      AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
      AND (
        p_campaign_ids IS NULL
        OR cardinality(p_campaign_ids) = 0
        OR co.campaign_id = ANY(p_campaign_ids)
      )
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

GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_aggregates(uuid, integer, bigint[])
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.rpc_member_campaign_aggregates(uuid, integer, bigint[]) IS
  '會員端每團 order_count / recent_order_count / ordered_qty。RETURNS jsonb（單列單值），'
  '不受 PostgREST 1000 列上限影響；p_campaign_ids 限定只算這一頁要顯示的團。'
  '訂單層級排除 cancelled/expired/transferred_out、品項層級排除 cancelled/expired，'
  '否則轉出的量會被算兩次、吃掉 cap_qty 名額。基底：20260808000010_member_sold_qty_exclude_transferred。';

COMMENT ON FUNCTION public.rpc_member_campaign_order_counts(uuid, integer) IS
  '會員端每團訂單筆數。⚠️ RETURNS TABLE、一團一列且無 campaign 篩選 —— 團數超過 '
  'PostgREST 的 1000 列上限時會被靜默截斷（截掉的是 campaign_id 最大的新團）。'
  '新程式請改用 rpc_member_campaign_aggregates(p_campaign_ids => ...)。'
  '保留僅為相容舊呼叫端。';

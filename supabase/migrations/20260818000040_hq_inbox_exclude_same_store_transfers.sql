-- ============================================================
-- 2026-08-18: 同店轉單不進總倉收件匣（不用總倉確認、也不用派貨）
--
-- 現象（使用者回報）：/hq/inbox「互助訂單」列出一堆標著
--   「（同店轉單・貨沒有移動）」的單，掛在「待處理」而且長著
--   「派貨 / 取消 / → 已確認」三顆鈕。
--
-- 這三顆對同店轉單全部沒有意義：
--   - 派貨（rpc_ship_aid_order）自己就擋：
--       IF v_src_location = v_dst_location THEN
--         RAISE EXCEPTION 'source and dest store share location_id %, cannot ship'
--     → 按下去只會拿到錯誤訊息，是一顆死鈕。
--   - 「總倉確認」(pending → confirmed) 的語意是「總倉收到貨了」
--     （見 CLAUDE.md「經總倉的轉入單一開始是 pending」），同店轉單
--     的貨從頭到尾沒離開那家店，總倉根本不會收到。
--   - 同店轉單建單時 status 是 mirror 來源單（20260629000020），
--     之後的推進完全走該店自己的團購流程：
--       pending/confirmed → shipping：rpc_mark_orders_shipping_for_wave
--         （同 campaign + 同店即推，不排除衍生單）
--       confirmed → ready：rpc_receive_transfer 邏輯 E
--         （_advance_arrived_confirmed_orders）
--       shipping → ready：rpc_receive_transfer 邏輯 C
--     → 沒有任何一步需要總倉，隱藏這些列不會讓狀態機卡住
--       （CLAUDE.md「把某個角色的動作按鈕拿掉之前，先確認狀態機還有別人推得動」）。
--   - 取消入口也不會消失：訂單明細頁本來就有（rpc_cancel_aid_order）。
--
-- 線上母體（2026-08-18）：375 張轉入單裡 359 張是同店轉單，其中
--   10 張落在「待處理」、3 張落在「配送中」——總倉每天看到的就是這些。
--
-- 改動：
--   1. v_hq_inbox 的 aid 分支排除同店轉單
--      → rpc_inbox_counts（badge 數字）與「全部」分頁一起乾淨。
--   2. 新增 v_hq_inbox_aid：收件匣「互助訂單 / 空中轉」分頁專用的列來源，
--      同樣排除同店轉單，並把轉出端（來源單／轉出店）直接查好。
--      前端原本用 PostgREST 直查 customer_orders，沒辦法做
--      「來源單.pickup_store_id = 本單.pickup_store_id」這種欄位對欄位比較，
--      所以把這段收進 view，順便省掉一趟反查來源單的 round trip。
--
-- 基底：v_hq_inbox ← 20260722000020_restock_standby_zone.sql
--       （逐字保留 restock standby / transfer return_to_hq / shortage 三段，
--         只動 aid 分支的 WHERE；已與線上 pg_get_viewdef 對過）。
-- Rollback：v_hq_inbox CREATE OR REPLACE 回 20260722000020 的版本；
--           DROP VIEW public.v_hq_inbox_aid（前端要一起還原成直查 customer_orders）。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. v_hq_inbox — aid 分支排除同店轉單
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_hq_inbox AS
SELECT
  'restock-' || id::text                                AS row_key,
  'restock'::text                                       AS source,
  CASE
    WHEN status = 'pending' AND standby_at IS NOT NULL                          THEN 'standby'
    WHEN status = 'pending'                                                     THEN 'pending'
    WHEN status IN ('approved_transfer','approved_pr','shipped')                THEN 'in_transit'
    WHEN status = 'received'                                                    THEN 'done'
    ELSE 'rejected'
  END                                                   AS stage,
  requested_at                                          AS ts,
  id                                                    AS source_id
FROM public.restock_requests

UNION ALL

SELECT
  'transfer-' || id::text,
  'transfer',
  CASE
    WHEN status IN ('draft','confirmed')                       THEN 'pending'
    WHEN status = 'shipped' AND transfer_type = 'return_to_hq' THEN 'pending'
    WHEN status = 'shipped'                                    THEN 'in_transit'
    WHEN status = 'received'                                   THEN 'done'
    ELSE 'rejected'
  END,
  created_at,
  id
FROM public.transfers

UNION ALL

SELECT
  'aid-' || co.id::text,
  'aid',
  CASE
    WHEN co.status IN ('pending','confirmed')                     THEN 'pending'
    WHEN co.status = 'shipping'                                   THEN 'in_transit'
    WHEN co.status IN ('ready','completed','partially_completed') THEN 'done'
    ELSE 'rejected'
  END,
  co.updated_at,
  co.id
FROM public.customer_orders co
WHERE EXISTS (
  SELECT 1 FROM public.customer_order_items coi
  WHERE coi.order_id = co.id AND coi.source = 'aid_transfer'
)
-- 同店轉單（換客人／併單）貨沒有離開本店，總倉全程不參與 → 不是收件匣的事
AND NOT EXISTS (
  SELECT 1 FROM public.customer_orders src
  WHERE src.id = co.transferred_from_order_id
    AND src.pickup_store_id = co.pickup_store_id
)

UNION ALL

SELECT DISTINCT
  'shortage-' || order_id::text,
  'shortage',
  CASE
    WHEN shortage_resolution IS NULL                              THEN 'pending'
    WHEN shortage_resolution IN ('notified','waiting_next_po')    THEN 'in_transit'
    WHEN shortage_resolution IN ('cancelled','reallocated')       THEN 'done'
    ELSE 'pending'
  END,
  order_updated_at,
  order_id
FROM public.v_order_shortage;

COMMENT ON VIEW public.v_hq_inbox IS
  'HQ 收件匣的列鍵來源（restock / transfer / aid / shortage）。aid 只收跨店轉入單：'
  '同店轉單貨沒有移動、總倉不經手，推進全由該店自己的團購流程負責（20260818000040）。';

-- ----------------------------------------------------------------
-- 2. v_hq_inbox_aid — 收件匣「互助訂單 / 空中轉」分頁的列
--    security_invoker = true：RLS 套用 caller（同 v_admin_orders 慣例）
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_hq_inbox_aid
WITH (security_invoker = true) AS
SELECT
  co.id,
  co.order_no,
  co.status,
  COALESCE(co.is_air_transfer, FALSE)          AS is_air_transfer,
  co.pickup_store_id,
  co.transferred_from_order_id,
  co.updated_at,
  c.campaign_no,
  st.name                                      AS store_name,
  src.order_no                                 AS from_order_no,
  src.pickup_store_id                          AS from_store_id,
  fst.name                                     AS from_store_name,
  (SELECT COUNT(*) FROM public.customer_order_items coi2
    WHERE coi2.order_id = co.id AND coi2.source = 'aid_transfer')::int AS line_count
FROM public.customer_orders co
LEFT JOIN public.group_buy_campaigns c ON c.id  = co.campaign_id
LEFT JOIN public.stores st              ON st.id = co.pickup_store_id
LEFT JOIN public.customer_orders src    ON src.id = co.transferred_from_order_id
LEFT JOIN public.stores fst             ON fst.id = src.pickup_store_id
WHERE EXISTS (
  SELECT 1 FROM public.customer_order_items coi
  WHERE coi.order_id = co.id AND coi.source = 'aid_transfer'
)
AND (src.id IS NULL OR src.pickup_store_id IS NULL
     OR src.pickup_store_id <> co.pickup_store_id);

GRANT SELECT ON public.v_hq_inbox_aid TO authenticated;

COMMENT ON VIEW public.v_hq_inbox_aid IS
  '收件匣「互助訂單 / 空中轉」分頁的列：轉入單 + 轉出端（來源單／轉出店）。'
  '排除同店轉單（貨沒有移動、總倉不經手），與 v_hq_inbox 的 aid 分支同一套口徑。';

-- ============================================================
-- 2026-08-14: 收貨頁的來源類型加 'air' —— 訂單轉移單不要再被當成「自由轉貨」
--
-- 背景：
--   rpc_get_transfer_source_kinds 只看撿貨波次：沒有波次行 → 'free'，
--   收貨頁因此把空中轉／互助的 AT- 單標成「↔ 轉貨」、tooltip 寫
--   「沒有撿貨波次也沒掛訂單的單（自由轉貨 / 店對店），沒有可對應的單據」，
--   數量也不給點（srcKind === 'free' 就不給連結）。
--
--   但這種單**有**掛訂單（transfers.customer_order_id），
--   rpc_get_orders_for_transfer 的 from_aid 分支查得到是哪一張、哪位客人。
--   空中轉自 20260814030000 起變成「轉單當下就出貨、接收店直接收」的主要
--   動線，接收店打開收貨頁看到「沒有可對應的單據」會不知道這批貨是誰的。
--
-- 改動：kind 判定在 'free' 之前插一條
--   customer_order_id IS NOT NULL → 'air'（訂單轉移單：空中轉 / 互助 / 經總倉的第二段）。
--   campaign / restock 判定完全不變（有波次的單走原路）。
--   前端 srcKind !== 'free' 的地方（數量可點看訂單）因此自動對 'air' 生效。
--
-- 基底版本：20260805000080（v1，無前版）
-- Rollback：重跑 20260805000080。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_get_transfer_source_kinds(
  p_transfer_ids BIGINT[]
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH k AS (
    SELECT t.id AS tid,
           CASE
             WHEN COUNT(pwi.id) > 0 AND COUNT(pwi.campaign_id) > 0 THEN 'campaign'
             WHEN COUNT(pwi.id) > 0                                THEN 'restock'
             -- 沒有波次但掛著顧客訂單 = 訂單轉移單（空中轉 / 互助 / 經總倉第二段）：
             -- from_aid 查得到訂單，畫面要給「看訂單」入口
             WHEN t.customer_order_id IS NOT NULL                  THEN 'air'
             ELSE 'free'
           END AS kind
      FROM transfers t
      LEFT JOIN picking_wave_items pwi ON pwi.generated_transfer_id = t.id
     WHERE t.id = ANY(p_transfer_ids)
     GROUP BY t.id, t.customer_order_id
  )
  SELECT COALESCE(jsonb_object_agg(k.tid::text, k.kind), '{}'::jsonb) FROM k;
$$;

COMMENT ON FUNCTION public.rpc_get_transfer_source_kinds(BIGINT[]) IS
  '收貨頁每張單的來源類型：campaign（開團派貨，有波次帶開團）/ restock（補貨波次）/ '
  'air（無波次但掛顧客訂單＝訂單轉移單，空中轉・互助）/ free（自由轉貨，什麼都沒掛）。'
  '基底 20260805000080。';

REVOKE ALL ON FUNCTION public.rpc_get_transfer_source_kinds(BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_transfer_source_kinds(BIGINT[]) TO authenticated;

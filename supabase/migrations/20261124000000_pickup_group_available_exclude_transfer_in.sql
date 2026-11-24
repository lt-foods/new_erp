-- ============================================================
-- 2026-11-24：取貨閘門剩餘量 —— 已取量不再吃掉「別店調貨進來」那幾件
--
-- 症狀（永和，GRP-20261025-011-0081 湯圓 1 盒）：
--   貨已經交給客人，取貨頁卻顯示「店裡沒貨，無法取貨」，✅ 取貨 按不下去、
--   單銷不掉、錢進不了帳。該 (團,店,SKU)：
--     * 總倉 hq_to_store 實收 7
--     * 已取走 10 —— 其中 6 是一般單，4 是掛【內部】永和店的 TF 單
--       （別店調貨進來，各有自己的 store_to_store 調撥單送進永和並已實收）
--     * _pickup_group_available = 7 − 10 = −3 → 數量守衛（第 3 關）擋下
--
-- 成因：20260814060000_pickup_gate_qty_aware.sql 檔頭 :64-65 的本意是
--   「有自己 transfer 收貨的單（Path A）的貨走 store_to_store，不吃 hq_to_store
--   這份預算」。排隊（需求側累計）那邊有照做（NOT EXISTS transfers t2 ...），
--   但扣「已取走量」這邊沒有排除 —— 調貨單自己帶進來的貨被取走時，
--   又從總倉那份預算再扣一次，等於重複扣。
--
-- 修法（只改本函式）：
--   剩餘 = _pickup_group_supplied(...)
--        − Σ_每張已取單 GREATEST( 該單該 SKU picked_up 量
--                                − 該單自己調撥單「送進這家店」的實收量, 0 )
--
--   * 母體與舊版相同：同 tenant / campaign / pickup_store / sku、
--     coi.status = 'picked_up'、排除 order_kind = 'offset'。
--   * 「自己調撥單送進這家店」= transfers.customer_order_id = 該單、同 tenant、
--     status IN ('received','closed')、dest_location = 取貨店 stores.location_id、
--     transfer_items.sku_id = 該 SKU 的 qty_received 合計。
--     dest_location 條件是為了排除經總倉轉的第一段（AT-O…-L1，店 → 總倉），
--     只認第二段（AT-O…-L2，總倉 → 取貨店），不然同一件會被加回兩次
--     （兩段式調撥單的產生見 20260825000000_transfer_links_transfer_id.sql:327-328）。
--   * 沒有自己調撥單送進這家店的單 → 逐字沿用舊版（直接扣 picked_up 量，
--     連 GREATEST 都不套，確保結果與舊版完全相同）。
--
-- 為什麼只加回「實際調進來的量」、不整張排除：
--   中和 GRP-20260805-016-TF0002 從文山調來 5、卻取走 10 —— 多取的 5 件吃的
--   確實是總倉那份貨。整張排除會讓總倉預算憑空多出 5，把真的沒貨的行放出去。
--   每張單最多加回到 0（GREATEST），調進來比取走多也不會倒灌預算。
--
-- 影響方向：本函式只會比舊版「大或相等」→ is_order_item_pickup_ready 只可能
--   false → true，不會讓原本可取的變不可取。門市實體 on_hand 守衛
--   （20260818000010 起的第 4 關）完全不動，帳上沒貨的仍然擋得住。
--
-- 不動：is_order_item_pickup_ready、_pickup_group_supplied、
--   v_order_item_pickup_ready、前端、任何其他函式。簽名／LANGUAGE sql／STABLE／
--   SECURITY DEFINER／search_path 全部照舊。
--
-- 基底版本：20260814060000_pickup_gate_qty_aware.sql:135（本函式唯一的前一版定義）
--
-- Rollback：重跑 20260814060000_pickup_gate_qty_aware.sql:135 那段
--   CREATE OR REPLACE FUNCTION public._pickup_group_available(...) 與其 COMMENT 即可。
-- ============================================================

CREATE OR REPLACE FUNCTION public._pickup_group_available(
  p_tenant      UUID,
  p_campaign_id BIGINT,
  p_store_id    BIGINT,
  p_sku_id      BIGINT
) RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public._pickup_group_supplied(p_tenant, p_campaign_id, p_store_id, p_sku_id)
    - COALESCE((
      SELECT SUM(
               CASE
                 -- 沒有自己調撥單送進這家店 → 跟舊版一樣整單扣
                 WHEN r.transfer_in_qty IS NULL THEN p.picked_qty
                 -- 有 → 只扣「取走量超出自己調進來的量」那部分，最少 0
                 ELSE GREATEST(p.picked_qty - r.transfer_in_qty, 0)
               END
             )
        FROM (
          -- 母體與舊版逐字相同，只是先依單彙總
          SELECT co.id AS order_id, SUM(coi.qty) AS picked_qty
            FROM customer_orders co
            JOIN customer_order_items coi ON coi.order_id = co.id
           WHERE co.tenant_id       = p_tenant
             AND co.campaign_id     = p_campaign_id
             AND co.pickup_store_id = p_store_id
             AND coi.sku_id         = p_sku_id
             AND coi.status         = 'picked_up'
             AND COALESCE(co.order_kind, 'normal') <> 'offset'
           GROUP BY co.id
        ) p
        LEFT JOIN LATERAL (
          -- 這張單自己的調撥單「送進這家店」的實收量（兩段式只認第二段）
          SELECT SUM(ti.qty_received) AS transfer_in_qty
            FROM stores st
            JOIN transfers t ON t.customer_order_id = p.order_id
                            AND t.tenant_id         = p_tenant
                            AND t.status IN ('received','closed')
                            AND t.dest_location     = st.location_id
            JOIN transfer_items ti ON ti.transfer_id = t.id
                                  AND ti.sku_id      = p_sku_id
           WHERE st.id = p_store_id
        ) r ON TRUE
    ), 0);
$$;

COMMENT ON FUNCTION public._pickup_group_available(UUID,BIGINT,BIGINT,BIGINT) IS
  '該 (團,店,SKU) 還能配出去的量 = 開團後實收 − 該組已取走量。'
  '2026-11-24：已取走量逐單扣掉「該單自己調撥單送進這家店的實收量」（最少扣到 0）——'
  '調貨進店的貨走 store_to_store，不吃總倉那份預算。'
  '取貨閘門 is_order_item_pickup_ready 的數量守衛用。';

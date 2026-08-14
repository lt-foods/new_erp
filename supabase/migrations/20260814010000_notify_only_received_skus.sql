-- ============================================================
-- 2026-08-14：到貨推播只通知「這次真的有到貨」的商品（平鎮店事故）
--
-- 事故（平鎮 2026-08-14）：店家誤按收貨後，用「✎ 調整」把沒到貨的
--   萬用膏實收改成 0 再重收（正確操作），系統卻跳「📩 已推播 1 位顧客」
--   —— 把「您的商品到貨」推給了那位貨根本沒到的客人（Sabrina）。
--   客人會照通知跑一趟門市，到店才發現沒東西可領。
--
-- 根因：rpc_get_members_to_notify_for_transfer 的 skus CTE 是 qty-blind：
--     SELECT DISTINCT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id
--   撈的是**這張派貨單的所有 SKU，不管實收多少**。實收 0 的品項一樣留在
--   名單裡，訂到它的客人就被通知。
--   20260813000000 加的 co.status IN (ready/partially_completed/shipping)
--   守衛擋的是「訂單狀態不對」（沒配到貨的 confirmed 單），擋不住這一種：
--   單子本來就 ready（同單其他品項早已到貨、或先前誤收已推 ready），
--   status 過關，但這次收貨那個品項實收是 0。
--
-- 修法：skus CTE 加上 qty_received > 0 —— 只通知「這次真的有貨進來」的
--   商品對應的客人。一張單有的到有的沒到時，到的那些商品的客人照常通知、
--   沒到的不通知；同一位客人若同時訂了到與沒到的商品仍會被通知
--   （他確實有東西可領），這是正確的。
--   ⚠ 同一支 rpc_receive_transfer 內部早就用同一條守衛取「本次到貨 SKU」
--   （20260813000000:411-415 的 _settle_arrived_backorders 種子、
--     :584-588 的 _advance_arrived_confirmed_orders 種子都是
--     `AND ti.qty_received > 0`）—— 只有推播名單這條漏掉，本檔補齊對齊。
--   transfer_items.qty_received 是 NOT NULL DEFAULT 0
--   （20260422120003_inventory_schema.sql:113），無 NULL 陷阱；
--   全收路徑 qty_received := qty_shipped（20260813000000:323）照樣 > 0，
--   且前端是收貨 RPC 回來後才呼叫本函式
--   （TransferReceiveModal.tsx:200-229），讀到的是寫入後的值。
--
-- 基底版本（append-only，逐字保留所有 prior fix，只動 skus CTE 兩行）：
--   rpc_get_members_to_notify_for_transfer = 20260813000000
--
-- Rollback：重跑 20260813000000_receive_manual_allocation_mode.sql 裡
--   rpc_get_members_to_notify_for_transfer 的區塊（該檔 :678-721）。
--   簽名與回傳型別皆未變動，CREATE OR REPLACE 即可來回，不需 DROP。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_get_members_to_notify_for_transfer(
  p_transfer_id BIGINT
) RETURNS TABLE(
  member_id              BIGINT,
  order_id               BIGINT,
  order_no               TEXT,
  last_notify_pickup_at  TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH dest AS (
    SELECT t.dest_location, t.tenant_id, s.id AS store_id
      FROM transfers t
      LEFT JOIN stores s ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
     WHERE t.id = p_transfer_id
  ),
  skus AS (
    -- 20260814：只取**這次真的有貨進來**的品項。原本無數量條件（qty-blind），
    -- 短收 / 實收 0 的 SKU 也留在名單裡 → 貨沒到的客人照樣收到「您的商品到貨」
    -- 白跑一趟（平鎮事故）。與收貨流程內部取「本次到貨 SKU」的守衛一致。
    SELECT DISTINCT sku_id FROM transfer_items
     WHERE transfer_id = p_transfer_id AND qty_received > 0
  )
  SELECT DISTINCT co.member_id, co.id, co.order_no, co.last_notify_pickup_at
    FROM customer_orders co
    JOIN dest d
      ON d.store_id = co.pickup_store_id
     AND d.tenant_id = co.tenant_id
    JOIN customer_order_items coi
      ON coi.order_id = co.id
    JOIN members m
      ON m.id = co.member_id
   WHERE coi.sku_id IN (SELECT sku_id FROM skus)
     AND co.member_id IS NOT NULL
     -- 20260813：只通知**真的能來領**的單（與 /pickup 放行的集合一致）。
     -- 原本是 NOT IN (cancelled/expired/transferred_out/completed)，等於把
     -- confirmed / pending 也通知 —— 但那些單取貨閘門根本沒開：
     --   * 手動配單模式：收貨後 confirmed 單全數未配，通知了客人來就是撲空；
     --   * 自動配單模式：可配量裝不下被跳過的單一樣還不能領。
     -- （CLAUDE.md：拿閘門/收貨當「到貨通知」觸發條件要自己加數量守衛 ——
     --   這裡直接看單頭 status，配到才通知。）
     AND co.status IN ('ready', 'partially_completed', 'shipping')
     AND COALESCE(co.order_kind, 'normal') = 'normal'
     AND COALESCE(m.no_notify_pickup, FALSE) = FALSE  -- 黑名單跳過
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_members_to_notify_for_transfer(BIGINT) TO authenticated;

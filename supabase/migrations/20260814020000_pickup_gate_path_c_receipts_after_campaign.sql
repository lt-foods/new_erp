-- ============================================================
-- 2026-08-14 (2)：取貨閘門 Path C 只認「開團之後」的實收，別拿上一團的舊貨開門
--
-- 災情（GRP-20260807-001 土雞蛋 / GRP-20260806-007 生煎包 / GRP-20260810-016 鮭魚菲力）：
--   這三團 PR 還在 draft、完全沒轉採購單、沒開過撿貨波次、一張 transfer 都沒有，
--   訂單卻在 /pickup 取貨頁被店家勾得到 → 8/13-8/14 兩天內 7 張單被按了取貨
--   （5 張 completed、2 張店家自己發現按錯又撤銷），古華店 sku 2261 庫存被扣到 -5、
--   sku 875 到 -3，文山 / 三峽也扣成負的 —— 店裡根本沒進這批貨。
--
-- 根因：is_order_item_pickup_ready 的 Path C（該 (campaign,store,sku) 完全無對齊
--   波次 → 退用「本店該 SKU 有 hq_to_store 實收」）**不看時間**。同一個 SKU 只要
--   上一團（例：雞蛋 GRP-20260717 走 PO 740 / WV260730000899、生煎包走
--   WV260714000674，都是 7 月的波次）到過店，8 月新開的團即使一顆貨都沒採購，
--   Path C 也照樣回 true。/pickup 對 pending / confirmed 單的放行條件是
--   「閘門明確 true」（20260805000230 為現貨配單開的口），於是未採購新團的
--   confirmed 單直接變成可取貨。
--
-- 影響範圍（修之前線上實測，active 品項 × 該店該 SKU 最後實收 < 開團時間）：
--   12 個團 / 141 組 (團,店,SKU) / 565 個品項 / 804 件 靠「上一團的舊實收」開著門。
--
-- 修法：Path C 的實收加時間下限 —— 只認 t.received_at >= 該團 group_buy_campaigns
--   .created_at 的收貨。這一團的貨只可能在開團之後到店；開團前的實收一定是
--   別團 / 補貨的貨。qty-blind 的既有語意刻意不動（數量守衛是
--   _advance_arrived_confirmed_orders 的職責，見 20260811000020），
--   Path A / B / D / D' 與 aid 分支逐字不動：
--   * Path B 本來就要求 campaign 對齊波次，無此問題。
--   * 沒有 campaign 的單（co.campaign_id IS NULL，例如部分內部單）沒有
--     「開團時間」可比，維持舊行為。
--   * 現貨團（貨比開團先到店）走的是減抵單 / offset 單（Path D / D'），不受影響。
--
-- 已知殘餘（qty-blind 語意保留的代價）：開團「之後」若有同 SKU 的補貨
--   （campaign_id NULL 的波次）到店，Path C 仍會開門 —— 例：經國店 8/10 收了
--   RR-261 的 2 包生煎包，GRP-20260806-007 在經國的單就仍放行。這類要靠
--   數量守衛的自動配單（20260811000020）與人工配貨把關，本檔不處理。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   is_order_item_pickup_ready = 20260805000180_offset_orders_count_as_coverage.sql
--   （＝線上現行版；Path D' 為該版加入）
--
-- Rollback：重跑 20260805000180 內的 CREATE OR REPLACE FUNCTION 即回舊閘門。
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_order_item_pickup_ready(p_item_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE coi.id = p_item_id
       AND co.status NOT IN ('completed','expired','cancelled','transferred_out')
       -- 只有未取的 active item 才有「可取貨」可言
       AND coi.status IN ('pending','reserved','ready')
       -- 少發配貨：沒配到的品項標成待補貨，在補到之前不可取
       --（rpc_allocate_shortage 寫入 / 清除；沒有缺貨的單這欄永遠是 NULL，行為不變）
       AND coi.backorder_at IS NULL
       AND CASE
         -- aid_transfer + 跨店：只認自己的 transfer 被收貨 (Path A)
         WHEN EXISTS (
                SELECT 1 FROM customer_order_items x
                 WHERE x.order_id = co.id AND x.source = 'aid_transfer'
              )
              AND co.transferred_from_order_id IS NOT NULL
              AND (
                SELECT src.pickup_store_id FROM customer_orders src
                 WHERE src.id = co.transferred_from_order_id
              ) IS DISTINCT FROM co.pickup_store_id
         THEN EXISTS (
           SELECT 1 FROM transfers t
            WHERE t.customer_order_id = co.id
              AND t.tenant_id = co.tenant_id
              AND t.status IN ('received','closed')
         )
         ELSE (
           -- Path A：aid 單 transfer FK 收貨
           EXISTS (
             SELECT 1 FROM transfers t
              WHERE t.customer_order_id = co.id
                AND t.tenant_id = co.tenant_id
                AND t.status IN ('received','closed')
           )
           OR
           -- Path B：campaign 對齊且該波次該 SKU 實收 qty>0
           EXISTS (
             SELECT 1
               FROM picking_wave_items pwi
               JOIN transfers t ON t.id = pwi.generated_transfer_id
               JOIN transfer_items ti ON ti.transfer_id = t.id
                                     AND ti.sku_id = coi.sku_id
              WHERE pwi.tenant_id   = co.tenant_id
                AND pwi.campaign_id = co.campaign_id
                AND pwi.store_id    = co.pickup_store_id
                AND pwi.sku_id      = coi.sku_id
                AND t.status IN ('received','closed')
                AND ti.qty_received > 0
           )
           OR
           -- Path C：該 (campaign,store,sku) 完全無對齊波次（彙整 PR）才退用 store+sku 實收。
           -- 2026-08-14：實收加時間下限 —— 只認「開團之後」收的貨。開團前的實收一定是
           -- 上一團 / 補貨的貨，拿來開門會讓完全沒採購的新團在取貨頁放行（GRP-20260807-001 災情）。
           (
             NOT EXISTS (
               SELECT 1 FROM picking_wave_items pwi
                WHERE pwi.tenant_id   = co.tenant_id
                  AND pwi.campaign_id = co.campaign_id
                  AND pwi.store_id    = co.pickup_store_id
                  AND pwi.sku_id      = coi.sku_id
             )
             AND EXISTS (
               SELECT 1
                 FROM stores st
                 JOIN transfers t ON t.transfer_type = 'hq_to_store'
                                 AND t.dest_location = st.location_id
                                 AND t.tenant_id     = co.tenant_id
                                 AND t.status IN ('received','closed')
                 JOIN transfer_items ti ON ti.transfer_id = t.id
                                       AND ti.sku_id = coi.sku_id
                                       AND ti.qty_received > 0
                WHERE st.id = co.pickup_store_id
                  AND (
                    co.campaign_id IS NULL   -- 無團的單沒有「開團時間」可比，維持舊行為
                    OR t.received_at >= (
                         SELECT gc.created_at FROM group_buy_campaigns gc
                          WHERE gc.id = co.campaign_id
                       )
                  )
             )
           )
           OR
           -- Path D：庫存減抵單 — 店家用店內現貨吸收這組缺口
           EXISTS (
             SELECT 1 FROM inventory_deduction_notes n
              WHERE n.tenant_id   = co.tenant_id
                AND n.campaign_id = co.campaign_id
                AND n.store_id    = co.pickup_store_id
                AND n.sku_id      = coi.sku_id
                AND n.cancelled_at IS NULL
           )
           OR
           -- Path D'：抵減單（order_kind='offset' 負數訂單）— 開團時就宣告
           -- 這組有店內現貨吸收，等同貨到（哪些行可取仍由 backorder_at 控管）
           EXISTS (
             SELECT 1
               FROM customer_orders oo
               JOIN customer_order_items oi
                 ON oi.order_id = oo.id
                AND oi.sku_id   = coi.sku_id
                AND oi.qty < 0
                AND oi.status NOT IN ('cancelled','expired')
              WHERE oo.tenant_id       = co.tenant_id
                AND oo.campaign_id     = co.campaign_id
                AND oo.pickup_store_id = co.pickup_store_id
                AND oo.order_kind      = 'offset'
                AND oo.status NOT IN ('cancelled','expired','transferred_out')
           )
         )
       END
  );
$function$;

COMMENT ON FUNCTION public.is_order_item_pickup_ready(bigint) IS
  '品項層級取貨閘門。Path A: aid transfer FK 收貨 / Path B: campaign 對齊波次實收 / '
  'Path C: 無對齊波次時退用本店該 SKU「開團之後」的實收（2026-08-14 加時間下限，'
  '開團前的舊實收不再開門）/ Path D: 減抵單 / Path D'': offset 抵減單。'
  'qty-blind：數量守衛由 _advance_arrived_confirmed_orders 負責。';

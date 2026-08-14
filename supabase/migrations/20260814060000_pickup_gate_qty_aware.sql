-- ============================================================
-- 2026-08-14 (6)：取貨閘門加數量守衛 —— 短收的那一件不可以還掛在取貨頁上
--
-- 災情（忠順店回報，GRP-20260805-006「夜玫瑰」紅肉李 #32 / sku 4141）：
--   總倉派 2 件（WAVE-1278-S51 qty_shipped = 2），忠順只實收 1 件
--   （ti.qty_received = 1，收貨頁確實標了短少）。客人 JoJo瑛550827 這張單
--   剛好有兩行同 SKU（8/12 一行、8/14 追加一行），8/14 17:58 取走一件之後：
--     * 訂單 → partially_completed
--     * 剩下那一行 is_order_item_pickup_ready 仍回 true
--     * /pickup 顯示「1 項可取」、✅ 取貨 鈕亮著
--   但那一件貨**根本沒進店**（stock_balances.on_hand = 0）。店員照著畫面按下去
--   就是庫存扣成 -1、客人白跑一趟。
--
-- 根因：閘門是 qty-blind 的。Path B 的條件是「該 (campaign,store,sku) 對齊波次
--   且 ti.qty_received > 0」—— 只問「有沒有收到」，不問「收了幾件、夠不夠分」。
--   同理 Path C 只問「本店該 SKU 有沒有開團後的實收」。所以一組貨只要**到過一件**，
--   該組**所有**未取品項都會被放行。
--
--   這個 qty-blind 語意本來是刻意的（20260814020000 註解裡列為已知殘餘），
--   當時的想法是「數量守衛由 _advance_arrived_confirmed_orders 負責」。
--   但那支只管 confirmed → ready 的推進；**取貨頁對 ready /
--   partially_completed 的單是直接吃閘門的**（pickableItems()），
--   於是數量守衛在真正會出貨的那條路上從來沒有生效過。
--
--   短收的資訊全程都在（transfer_items.qty_variance = -1、收貨頁標了短少），
--   只是沒有任何東西把它接到訂單品項上 —— 少發配貨（rpc_allocate_shortage）
--   是唯一的接法，而它要店員手動點。沒點就等於沒守衛。
--
-- 影響範圍（修之前線上實測，閘門現在回 true、加了守衛會變 false 的品項）：
--   84 個品項 / 143 件 / 82 張單。都是該 (團,店,SKU) 「實收 − 已取」已經
--   蓋不住剩餘未取量的組，例：
--     * GB20260518-C000154-0071：實收 10、已取 21、on_hand -11
--     * GRP-20260609-004-0018：實收 2、已取 10、on_hand -8
--   換句話說這 84 件現在按下去一律是負庫存 + 客人撲空。
--
-- 修法：閘門在既有 Path A~D' **全部逐字保留**之後，追加一道數量守衛：
--
--     可配量 = 該 (團,店,SKU) 開團後的 hq_to_store 實收 − 該組已取走量
--     這一行排在同組第幾位（依 created_at, order_no, item_id 累加）
--     累計量 ≤ 可配量 → 放行；超過 → 這一行還沒輪到，回 false
--
--   排序規則跟既有的「依訂單時間自動配」完全同一套
--   （20260805000070 / ShortageAllocateModal / _advance_arrived_confirmed_orders），
--   所以自動配、少發配貨、取貨閘門三邊看到的順序一致。
--
-- 刻意的設計取捨：
--
--   1. **只在 Path B / C 生效**。Path A（這張單自己的 transfer 被收貨）、
--      Path D（庫存減抵單）、Path D'（offset 抵減單）都是「這一組明確被宣告覆蓋」
--      的路徑，量的問題在那些單據上自己管，守衛跳過不動。
--      → 也就是說 HQ 想放行一組帳面不足的貨，開一張**庫存減抵單**就是既有的正解，
--        不必回頭改閘門。
--
--   2. **供給側刻意算寬（只認開團後、但不限對齊波次）**：算的是「該店該 SKU
--      在開團之後的所有 hq_to_store 實收」，不是只算對齊波次的量。補貨路線
--      （campaign_id IS NULL 的波次）送到店的貨也算數 —— 這一票在 Path C 本來就
--      放行，供給側漏算會讓走補貨路線的團整批被誤擋。寧可寬一點：
--      **false negative（貨在店裡卻不給發）比 false positive 難收拾** ——
--      店員發不出貨只能改走轉單，那會開一張新單、原單永遠留在原狀態，
--      就是 CLAUDE.md 記過的重複單災情。
--
--   3. **需求側刻意算窄**：排除 store_internal 會員的單（RR- /【內部】xx 店是
--      現貨池容器，不是對客人的承諾，比照 _advance_arrived_confirmed_orders）、
--      排除 offset 抵減單（負數行）、排除已經有自己 transfer 收貨的單（Path A
--      的貨走 store_to_store，不吃 hq_to_store 這份預算）、排除掛著 backorder_at
--      的行（它們已經被少發配貨擋掉了，再算進來會自己擋自己 ——
--      這是 20260811000050 踩過的坑）。
--
--   4. **不寫任何欄位、不標 backorder_at**。守衛是純推導的：下一批貨收進來
--      supplied 變大，這一行自己就會重新放行，不需要人工解除。
--      （CLAUDE.md：「不要順手改成寫 backorder_at」。）
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   is_order_item_pickup_ready = 20260814020000_pickup_gate_path_c_receipts_after_campaign.sql
--   （＝線上現行版；Path C 的「開團後實收」時間下限為該版加入）
--   v_order_item_pickup_ready  = 20260704000000_item_level_pickup_gate.sql
--
-- Rollback：
--   重跑 20260814020000 內的 CREATE OR REPLACE FUNCTION 即回舊閘門；
--   CREATE OR REPLACE VIEW public.v_order_item_pickup_ready AS
--     SELECT coi.id AS item_id, coi.order_id, coi.tenant_id,
--            public.is_order_item_pickup_ready(coi.id) AS pickup_ready
--       FROM customer_order_items coi;
--   DROP FUNCTION IF EXISTS public._pickup_group_available(UUID,BIGINT,BIGINT,BIGINT);
--   DROP FUNCTION IF EXISTS public._pickup_group_supplied(UUID,BIGINT,BIGINT,BIGINT);
-- ============================================================

-- ----------------------------------------------------------------
-- 1a. _pickup_group_supplied — 該 (團,店,SKU) 開團後總共實收幾件
--
--     供給側不限對齊波次（補貨路線送到店的也算），時間下限沿用
--     20260814020000 的判準：開團前的實收一定是上一團 / 別團的貨。
--
--     單獨拆一支是為了讓 view 分得出「到過貨但不夠分」與「根本沒到過」——
--     available 已經扣掉已取量，短收又剛好取光時會是 0，兩種情形分不出來。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pickup_group_supplied(
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
  SELECT COALESCE((
    SELECT SUM(ti.qty_received)
      FROM stores st
      JOIN transfers t ON t.transfer_type = 'hq_to_store'
                      AND t.dest_location = st.location_id
                      AND t.tenant_id     = p_tenant
                      AND t.status IN ('received','closed')
      JOIN transfer_items ti ON ti.transfer_id = t.id
                            AND ti.sku_id      = p_sku_id
                            AND ti.qty_received > 0
     WHERE st.id = p_store_id
       AND t.received_at >= (
             SELECT gc.created_at FROM group_buy_campaigns gc WHERE gc.id = p_campaign_id
           )
  ), 0);
$$;

COMMENT ON FUNCTION public._pickup_group_supplied(UUID,BIGINT,BIGINT,BIGINT) IS
  '該 (團,店,SKU) 開團後該店該 SKU 的 hq_to_store 實收合計。'
  '刻意不限對齊波次（補貨路線送到店的也算，比照取貨閘門 Path C）。';

-- ----------------------------------------------------------------
-- 1b. _pickup_group_available — 該 (團,店,SKU) 現在還能配出去幾件
--
--     = 開團後實收 − 該組已經被取走的量
--     「已取走」排除 offset 單（負數行會把可配量灌大）。
-- ----------------------------------------------------------------
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
      SELECT SUM(coi.qty)
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id
       WHERE co.tenant_id       = p_tenant
         AND co.campaign_id     = p_campaign_id
         AND co.pickup_store_id = p_store_id
         AND coi.sku_id         = p_sku_id
         AND coi.status         = 'picked_up'
         AND COALESCE(co.order_kind, 'normal') <> 'offset'
    ), 0);
$$;

COMMENT ON FUNCTION public._pickup_group_available(UUID,BIGINT,BIGINT,BIGINT) IS
  '該 (團,店,SKU) 還能配出去的量 = 開團後實收 − 該組已取走量。'
  '取貨閘門 is_order_item_pickup_ready 的數量守衛用。';

-- ----------------------------------------------------------------
-- 2. is_order_item_pickup_ready — Path A~D' 逐字保留，末端追加數量守衛
-- ----------------------------------------------------------------
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
       -- ------------------------------------------------------------------
       -- 2026-08-14：數量守衛（新增）。上面的 Path B / C 是 qty-blind 的
       -- ——「該組到過貨」就整組放行 —— 短收時會讓沒進店的那幾件也亮著可取。
       -- 這裡再問一次「這一行輪得到嗎」：同組依 (下單時間, 單號, 行 id) 累加，
       -- 累計量超過可配量的行回 false。
       --
       -- 只作用在 Path B / C。Path A / D / D' 是「這一組明確被宣告覆蓋」的路徑，
       -- 量由那些單據自己管，一律跳過守衛（HQ 要放行帳面不足的組 → 開庫存減抵單）。
       -- ------------------------------------------------------------------
       AND (
         co.campaign_id IS NULL   -- 無團的單沒有「同組」可算，維持舊行為
         -- Path A：這張單有自己的 transfer 被收貨（含 aid 跨店分支）
         OR EXISTS (
           SELECT 1 FROM transfers t
            WHERE t.customer_order_id = co.id
              AND t.tenant_id = co.tenant_id
              AND t.status IN ('received','closed')
         )
         -- Path D：庫存減抵單
         OR EXISTS (
           SELECT 1 FROM inventory_deduction_notes n
            WHERE n.tenant_id   = co.tenant_id
              AND n.campaign_id = co.campaign_id
              AND n.store_id    = co.pickup_store_id
              AND n.sku_id      = coi.sku_id
              AND n.cancelled_at IS NULL
         )
         -- Path D'：offset 抵減單
         OR EXISTS (
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
         -- 數量守衛本體：這一行的累計需求 ≤ 該組可配量
         OR (
           SELECT COALESCE(SUM(x.qty), 0)
             FROM customer_order_items x
             JOIN customer_orders xo ON xo.id = x.order_id
             LEFT JOIN members xm ON xm.id = xo.member_id
            WHERE xo.tenant_id       = co.tenant_id
              AND xo.campaign_id     = co.campaign_id
              AND xo.pickup_store_id = co.pickup_store_id
              AND x.sku_id           = coi.sku_id
              AND x.status IN ('pending','reserved','ready')
              -- 掛著待補貨的行已經被少發配貨擋掉了，不佔預算
              --（算進來會自己擋自己，20260811000050 踩過）
              AND x.backorder_at IS NULL
              AND xo.status NOT IN ('completed','expired','cancelled','transferred_out')
              -- 現貨池容器（RR- /【內部】xx 店）不是對客人的承諾，不佔預算
              AND COALESCE(xm.member_type, '') <> 'store_internal'
              -- offset 抵減單是負數行，不是需求
              AND COALESCE(xo.order_kind, 'normal') <> 'offset'
              -- 有自己 transfer 的單（Path A）走 store_to_store 供給，不吃這份 hq 預算
              AND NOT EXISTS (
                SELECT 1 FROM transfers t2
                 WHERE t2.customer_order_id = xo.id
                   AND t2.tenant_id = xo.tenant_id
                   AND t2.status IN ('received','closed')
              )
              -- 排在自己前面（含自己）的行才計入累計
              AND (xo.created_at, xo.order_no, x.id) <= (co.created_at, co.order_no, coi.id)
         ) <= public._pickup_group_available(
                co.tenant_id, co.campaign_id, co.pickup_store_id, coi.sku_id
              )
       )
  );
$function$;

COMMENT ON FUNCTION public.is_order_item_pickup_ready(bigint) IS
  '品項層級取貨閘門。Path A: aid transfer FK 收貨 / Path B: campaign 對齊波次實收 / '
  'Path C: 無對齊波次時退用本店該 SKU「開團之後」的實收（2026-08-14 加時間下限）/ '
  'Path D: 減抵單 / Path D'': offset 抵減單。'
  '2026-08-14 追加數量守衛：Path B / C 不再 qty-blind —— 同組依 (下單時間, 單號, 行 id) '
  '累加，累計量超過「開團後實收 − 已取走」的行回 false（短收時沒進店的那幾件不放行）。'
  'Path A / D / D'' 跳過守衛，量由那些單據自己管。';

-- ----------------------------------------------------------------
-- 3. v_order_item_pickup_ready — 加 qty_short，讓前端分得出「為什麼不能取」
--
--    pickup_ready = false 的原因有三種，畫面上要講不一樣的話：
--      * backorder_at 有值        → 少發配貨沒配到，「⏳ 待補貨」（要人工配貨）
--      * qty_short = true         → 路徑到貨了但量不夠，「⏳ 未到貨」（等下一批）
--      * 兩者皆否                 → 這批根本還沒到店
--    欄位往後加，既有 select 不受影響。
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_order_item_pickup_ready AS
SELECT
  coi.id AS item_id,
  coi.order_id,
  coi.tenant_id,
  public.is_order_item_pickup_ready(coi.id) AS pickup_ready,
  -- 「這組到過貨，只是不夠分到這一行」：不可取、沒掛待補貨，但該組開團後確實有實收。
  -- 用 supplied（非 available）判斷 —— available 已扣掉已取量，短收又剛好取光時是 0，
  -- 會跟「根本沒到過」混在一起（本次災情 GRP-20260805-006 就是 supplied 1 / picked 1）。
  (
    coi.status IN ('pending','reserved','ready')
    AND coi.backorder_at IS NULL
    AND NOT public.is_order_item_pickup_ready(coi.id)
    AND EXISTS (
      SELECT 1 FROM customer_orders co
       WHERE co.id = coi.order_id
         AND co.campaign_id IS NOT NULL
         AND public._pickup_group_supplied(
               co.tenant_id, co.campaign_id, co.pickup_store_id, coi.sku_id
             ) > 0
    )
  ) AS qty_short
FROM customer_order_items coi;

GRANT SELECT ON public.v_order_item_pickup_ready TO authenticated;

COMMENT ON VIEW public.v_order_item_pickup_ready IS
  '品項可取貨判斷 view（item_id, order_id, pickup_ready, qty_short）。'
  'qty_short = 該組到貨量蓋不住這一行（等下一批，不是要人工配貨），'
  '前端用來把「⏳ 未到貨」跟「⏳ 待補貨」講清楚。';

-- ============================================================================
-- 店家自開團 (3/5)：取貨閘門認得自開團收到的貨
-- ============================================================================
-- 沒有這一支，前兩支等於白做：閘門的 Path A~D' 沒有一條對得上自開團 ——
--   Path A  要 transfers.customer_order_id（自開團根本沒有 transfer）
--   Path B  要對齊撿貨波次（自開團不撿貨）
--   Path C  要 hq_to_store 實收，而且 20260814020000 特地加了「開團之後才算」
--           的下限，就是為了讓「完全沒採購的團」不會在取貨頁自己放行
--   Path D/D' 要庫存減抵單 / offset 抵減單（那是另一件事）
-- → 貨都收進店裡了，取貨頁還是不給發，店員只能改走轉單 = CLAUDE.md 記過的
--   重複單災情。
--
-- 兩處要一起改（只改一處都會壞）：
--   1. is_order_item_pickup_ready 加 Path S（「到貨了沒」）
--   2. _pickup_group_supplied 把該團的入庫異動算成供給（「夠不夠分」）
--      —— 只加 1 不加 2 的話，campaign-local 數量守衛算出 supplied = 0、
--      available 為負，Path S 開了門也會被守衛整組擋回去。
--
-- 兩處都以「掛在該團身上的入庫異動」為憑據
-- （stock_movements.source_doc_type='campaign' / source_doc_id=團 id），
-- 那就是 rpc_receive_store_campaign 收貨時寫的那一筆。全流程沒有任何單據。
--
-- Path S **不進任何豁免清單**：自開團一樣要過 campaign-local 供給守衛與
-- 門市實體 on_hand 守衛。理由同 20260818000010 檔頭 —— 記帳側的供給不等於
-- 貨還在架上，自開團的貨一樣會被別的通路（現貨直配 SP-、互助認領）領走。
--
-- 基底版本（逐字抽出後只加一條 OR / 一段加總）：
--   is_order_item_pickup_ready = 20260827030000_pickup_gate_dn_per_item.sql
--   _pickup_group_supplied     = 20260814060000_pickup_gate_qty_aware.sql
-- Rollback：兩支各 CREATE OR REPLACE 回上列基底版本。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. _pickup_group_supplied — 供給側加上「這一團自己收到的貨」
-- ----------------------------------------------------------------------------
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
  SELECT
    -- 總倉派貨（基底 20260814060000，一字未動）
    COALESCE((
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
    ), 0)
    -- 20260831：店家自開團收貨時寫的入庫異動。
    -- 條件同時綁 campaign_id 與主辦店，所以不會把別團 / 別店的貨算進來
    -- （這比 hq_to_store 那一段還準 —— 那段刻意只用時間下界，沒有依團切分）。
    + COALESCE((
      SELECT SUM(sm.quantity)
        FROM group_buy_campaigns gc
        JOIN stores st ON st.id = gc.owner_store_id
        JOIN stock_movements sm ON sm.tenant_id       = p_tenant
                               AND sm.location_id     = st.location_id
                               AND sm.source_doc_type = 'campaign'
                               AND sm.source_doc_id   = gc.id
                               AND sm.sku_id          = p_sku_id
       WHERE gc.id             = p_campaign_id
         AND gc.owner_store_id = p_store_id
    ), 0);
$$;

COMMENT ON FUNCTION public._pickup_group_supplied(UUID,BIGINT,BIGINT,BIGINT) IS
  '該 (團,店,SKU) 開團後該店該 SKU 的 hq_to_store 實收合計（刻意不限對齊波次，'
  '補貨路線送到店的也算，比照取貨閘門 Path C），'
  '加上店家自開團收貨寫的入庫異動（source_doc_type=campaign，依團 + 主辦店切分）。'
  '基底 20260814060000。';

-- ----------------------------------------------------------------------------
-- 2. is_order_item_pickup_ready — 加 Path S
--    以下為 20260827030000 的定義逐字抽出，只在 Path D' 之後插入 Path S。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_order_item_pickup_ready(p_item_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
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
           -- 2026-08-27：改成**逐品項**（只放行 DN 指名的那一行）。
           -- 整組放行會讓「配給一位客人」等於「同組每個人都可取」。
           public._pickup_dn_covers_item(
             coi.id, co.tenant_id, co.campaign_id, co.pickup_store_id, coi.sku_id
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
           OR
           -- Path S（20260831）：店家自開團 —— 這一團自己收過這個 SKU 的貨。
           -- 自開團完全不經總倉，也**不開任何單據**：沒有撿貨波次、沒有
           -- hq_to_store 實收、連 transfer 都沒有，所以 Path A / B / C 結構上
           -- 永遠不成立（Path C 的「開團後實收」下限本來就是為了擋住
           -- 「完全沒採購的團」而加的 20260814020000，不可以為了自開團放寬 ——
           -- 那會把災情原樣放回來）。
           -- 到貨的唯一憑據就是收貨當下寫的那筆入庫異動
           -- （source_doc_type='campaign'、source_doc_id=團 id），
           -- 認團又認店，別團 / 別店的貨開不了這扇門。
           -- ⚠ 刻意不進下面兩道守衛的豁免清單：自開團一樣要受
           --   campaign-local 供給（_pickup_group_supplied 已把這筆算進去）
           --   與門市實體 on_hand 兩道數量守衛。
           EXISTS (
             SELECT 1
               FROM group_buy_campaigns gc
               JOIN stores st ON st.id = gc.owner_store_id
               JOIN stock_movements sm
                 ON sm.tenant_id       = co.tenant_id
                AND sm.location_id     = st.location_id
                AND sm.source_doc_type = 'campaign'
                AND sm.source_doc_id   = gc.id
                AND sm.sku_id          = coi.sku_id
                AND sm.quantity        > 0
              WHERE gc.id             = co.campaign_id
                AND gc.owner_store_id = co.pickup_store_id
           )
         )
       END
       -- ------------------------------------------------------------------
       -- 2026-08-14：數量守衛（campaign-local）。上面的 Path B / C 是 qty-blind 的
       -- ——「該組到過貨」就整組放行 —— 短收時會讓沒進店的那幾件也亮著可取。
       -- 這裡再問一次「這一行輪得到嗎」：同組依 (下單時間, 單號, 行 id) 累加，
       -- 累計量超過可配量的行回 false。
       --
       -- 只作用在 Path B / C。Path A / D / D' 是「這一組明確被宣告覆蓋」的路徑，
       -- 量由那些單據自己管，一律跳過守衛（HQ 要放行帳面不足的組 → 開庫存減抵單）。
       -- 2026-08-27：Path D 的豁免跟著改成逐品項 —— 別人的 DN 不能豁免我這一行，
       -- 否則量守衛等於對整組失效。
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
         -- Path D：庫存減抵單（逐品項）
         OR public._pickup_dn_covers_item(
              coi.id, co.tenant_id, co.campaign_id, co.pickup_store_id, coi.sku_id
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
       -- ------------------------------------------------------------------
       -- 2026-08-18：門市實體庫存守衛。上面那道的帳本是 campaign-local，
       -- 但實體庫存是**整間店共用**的 —— 同一批貨會被多個團各自當成自己的供給
       -- （_pickup_group_supplied 沒有依 campaign 切分），而別團 / 現貨直配 SP- /
       -- 池子轉單把貨領走時也不會扣到本團的 available。結果就是「貨發完了，
       -- 單還亮著已到貨」（松山 #16360812）。
       --
       -- 這裡改問實體：本行的累計承諾（跨所有團、依 (下單時間, 單號, 行 id) 排序）
       -- 有沒有超過該店該 SKU 的 on_hand。口徑對齊
       -- _advance_arrived_confirmed_orders 的可配量（on_hand − 已承諾未取）
       -- ＝ _sku_commitment 的 promised_active。
       --
       -- 豁免：容器單與 offset 單本身（它們被排除在「已承諾」母體外，再要它們
       -- 自己過守衛會被 on_hand 擋死）。Path A / D / D' **不**豁免。
       -- ------------------------------------------------------------------
       AND (
         -- 沒有取貨店 / 店沒綁倉別 → 算不出 on_hand，維持舊行為
         --（比照 _advance_arrived_confirmed_orders「沒設倉庫位置的店直接不動」）
         NOT EXISTS (
           SELECT 1 FROM stores st
            WHERE st.id = co.pickup_store_id
              AND st.location_id IS NOT NULL
         )
         -- 容器單（RR- / OV- / AB- /【內部】xx 店）與 offset 抵減單不是對客人的
         -- 承諾，也不在下面的母體裡；它們的取貨 / 轉單不受實體守衛影響
         OR COALESCE(co.order_kind, 'normal') = 'offset'
         OR EXISTS (
           SELECT 1 FROM members m
            WHERE m.id = co.member_id
              AND COALESCE(m.member_type, '') = 'store_internal'
         )
         -- ⚠ Path A / D / D' **刻意不在這裡豁免**（與上面那道守衛不同）。
         --   那三條回答的是「這批貨算不算到過店」，屬於**到貨**問題；本守衛問的是
         --   「現在還在不在架上」，是**當下**的問題 —— 任何單據都不能宣告一批
         --   已經被領走的貨還在。
         --   減抵單尤其不行：rpc_create_inventory_deduction 開單時就強制
         --   `on_hand - reserved >= qty`，錯誤訊息還寫「請先到『庫存總覽』對該商品
         --   新增庫存，再開減抵單」——「貨在架上但帳沒入」根本不是它的使用情境，
         --   帳早就被要求先補正了。拿它豁免 on_hand 檢查等於讓同一批貨無限次交付。
         --
         -- 帳面不足但貨真的在架上時的正解 = **到庫存總覽把庫存補上**（＋新增庫存 /
         -- 盤點），不是開減抵單繞過去 —— 減抵單自己也是這樣要求的。
         --
         -- 實體守衛本體：跨團累計承諾 ≤ on_hand
         --
         -- 2026-08-27：母體多算「還在等貨但已被 DN 指名覆蓋」的行。
         --   原本只算單頭已承諾（ready/partially_completed/shipping）的行，於是
         --   兩張都還 pending 的單各自只算到自己 1 件 ≤ on_hand 1，一件貨兩個人過。
         --   口徑對齊 _order_item_stock_budget 的 others（開單那端早就這樣算了，
         --   所以這是把閘門補齊到跟預算同一套，不是新規則）。
         --   ⚠ 仍然**不算**沒有 DN 的 pending/confirmed 行 —— 那些是還在等貨的需求，
         --     算進來會讓舊的等貨單擋掉新的已到貨單（20260818000010 的原始理由）。
         OR (
           SELECT COALESCE(SUM(
                    CASE WHEN yo.status IN ('ready','partially_completed','shipping')
                              OR y.id = coi.id
                         THEN y.qty
                         ELSE LEAST(y.qty, COALESCE(cov.q, 0)) END), 0)
             FROM customer_order_items y
             JOIN customer_orders yo ON yo.id = y.order_id
             LEFT JOIN members ym ON ym.id = yo.member_id
             LEFT JOIN LATERAL (
               SELECT SUM(GREATEST(ni.qty - COALESCE(ni.released_qty, 0), 0)) AS q
                 FROM inventory_deduction_note_items ni
                 JOIN inventory_deduction_notes n ON n.id = ni.note_id
                                                 AND n.cancelled_at IS NULL
                WHERE ni.order_item_id = y.id
             ) cov ON TRUE
            WHERE yo.tenant_id       = co.tenant_id
              AND yo.pickup_store_id = co.pickup_store_id
              AND y.sku_id           = coi.sku_id
              AND y.status IN ('pending','reserved','ready')
              AND y.qty > 0
              -- 待補貨的行已被少發配貨擋掉，不佔預算（同上一道）
              AND y.backorder_at IS NULL
              AND yo.status NOT IN ('completed','expired','cancelled','transferred_out')
              -- 現貨池容器不是對客人的承諾
              AND COALESCE(ym.member_type, '') <> 'store_internal'
              -- offset 抵減單是負數行，不是需求
              AND COALESCE(yo.order_kind, 'normal') <> 'offset'
              -- 排在自己前面（含自己）的行才計入累計 —— on_hand 不夠時
              -- 讓最早下單的人先拿，不是整組一起關掉
              AND (yo.created_at, yo.order_no, y.id) <= (co.created_at, co.order_no, coi.id)
         ) <= COALESCE((
             SELECT sb.on_hand
               FROM stores st
               JOIN stock_balances sb
                 ON sb.tenant_id   = st.tenant_id
                AND sb.location_id = st.location_id
                AND sb.sku_id      = coi.sku_id
              WHERE st.id = co.pickup_store_id
           ), 0)
       )
  );
$$;

COMMENT ON FUNCTION public.is_order_item_pickup_ready(BIGINT) IS
  '取貨閘門（逐品項）：Path A 自己的 transfer 收貨 / B 對齊波次實收 / C 本店實收退路 / '
  'D 庫存減抵單（**逐品項**，2026-08-27 起）/ D'' offset 抵減單 / '
  'S 店家自開團該團的入庫異動（2026-08-31 起），'
  '外加兩道數量守衛：campaign-local 供給、門市實體 on_hand（後者含 DN 覆蓋的等貨行）。'
  'Path S 不豁免任何一道守衛。';

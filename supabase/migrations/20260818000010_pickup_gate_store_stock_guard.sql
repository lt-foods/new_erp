-- ============================================================
-- 2026-08-18：取貨閘門加「門市實體庫存」守衛 —— 貨已經配給別人了就不可以還亮著可取
--
-- 災情（松山店回報 2026-08-18）：
--   訂單 #16360812（【黃惠美】M034663，頂級挪威鮭魚腹條500g/包 ×1）在 /pickup
--   顯示「✅ 已到貨・1 項可取」，但該店該 SKU 的 stock_balances.on_hand 是 0。
--   店員原話：「我庫存檢底的都給完客人了，但是它還可以取貨，但我庫存已經沒了」。
--   —— 貨確實到過店、也確實已經全部交給別的客人，畫面卻還在對這位客人承諾。
--
-- 根因：20260814060000 的數量守衛帳本是**campaign-local**，而實體庫存是**店共用**的。
--   兩邊的母體不一樣，於是同一批貨會被重複承諾：
--
--     供給 _pickup_group_supplied(團,店,SKU)
--         = 該店該 SKU **開團之後**所有 hq_to_store 實收（刻意不限對齊波次）
--     可配 _pickup_group_available
--         = 供給 − **同一個 campaign_id** 已取走量
--     需求  = **同一個 campaign_id** 的未取行累加
--
--   ① 跨團重複計算（本次主因）。供給側完全沒有依 campaign 切分 —— 只要收貨時間
--      晚於開團時間就整批算進來。鮭魚腹條這種每週重開的品，8/12 收的 10 件會
--      同時被 8/01、8/05、8/12 三個團各自當成「自己的 10 件」；而 A 團客人取走
--      之後只扣 A 團的 available，B / C 團的帳一動也不動 → 貨發完了，B / C 團的
--      單還一路亮著「已到貨」。
--   ② 非團購通路的出貨完全不在帳上。現貨直配 SP-（rpc_create_spot_sale，8/16 上線）、
--      池子轉單給客人、自由轉貨轉出、盤點調整 —— 這些都會壓低 on_hand，但因為
--      它們掛在別的 campaign_id（或根本不是訂單），一律不會扣到本團的 available。
--
--   ③ 而且上面兩道漏洞其實還輪不到 —— **實際放行松山那兩張的是 Path D 的無條件
--      豁免**。線上實測（2026-08-18，campaign 3613 / 松山店 / sku 1981）：
--        _pickup_group_supplied  = 0
--        _pickup_group_available = -4   ← campaign-local 守衛本來擋得住
--        on_hand                 = 0
--        is_order_item_pickup_ready = true
--      因為該組有 3 張 qty=1 的減抵單（DN2608100025/26/27，reason「加單頁現貨配單」），
--      而 Path D 只比對 (tenant, campaign, store, sku) **完全不看數量也不看時間**，
--      一張就讓整組跳過到貨判斷與數量守衛。該組已經取走 4 件、on_hand 歸零，
--      剩下的 2 張（GRP-20260809-001-0028 黃淑芳、-TF0001 Peggy）照樣亮「已到貨」。
--      回報那位客人（M034663 黃惠美）的 GRP-20260809-001-0024 已經被改走轉單
--      （status = transferred_out）—— 就是 CLAUDE.md 記過的「發不出貨只好轉單 →
--      重複單」那條繞路。
--
--   換句話說：舊守衛擋得住「總倉少發」（同團同批的短收），擋不住「貨到了但被別團 /
--   別通路領走」，更擋不住「有減抵單就無限放行」。松山這張是第三種。
--   ⇒ 所以本守衛**不沿用 Path A / D / D' 的豁免**，理由見下方取捨 1。
--
-- 修法：在既有守衛之後**再加一道**以 stock_balances.on_hand 為準的實體庫存守衛。
--   兩道都要過才放行（只會變嚴、不會變鬆），既有 Path A~D' 與 campaign-local
--   守衛全部逐字保留。
--
--     本行的累計承諾 ≤ 該店該 SKU 的 on_hand
--
--   累計承諾 = 該店該 SKU **跨所有團**、排在本行之前（含本行）的「已承諾未取」量，
--   排序沿用全站同一套 (下單時間, 單號, 行 id)。
--
--   口徑刻意對齊 _advance_arrived_confirmed_orders（20260813020000）的可配量
--   ＝ on_hand − 已承諾未取，也就是 _sku_commitment 的 promised_active：
--     * 只算單頭 ready / partially_completed / shipping 的行（＝已經對客人承諾的）。
--       **confirmed / pending 不算**：那些是還在等貨的需求，不是已到貨的承諾；
--       算進來會讓「舊的等貨單」擋掉「新的已到貨單」（貨明明在架上卻發不出去）。
--     * 排除 store_internal 容器單（RR- / OV- / AB- /【內部】xx 店是現貨池，
--       不是對客人的承諾；不排除的話可配量會被歸零，整支等於沒作用）。
--     * 排除 offset 抵減單（負數行）與 qty <= 0 的行。
--     * 排除掛著 backorder_at 的行（已經被少發配貨擋掉，不佔預算 ——
--       算進來會自己擋自己，20260811000050 踩過）。
--
-- 為什麼不是改寫既有的 campaign-local 守衛而是再加一道：
--   兩道擋的是不同的洞，而且**都不能單獨用**。
--     * campaign-local 擋得住「同團同批短收」——「這批只到 1 件卻有 2 個人在等」，
--       這種情形 on_hand 可能因為別團的貨而看起來夠，實體守衛放行、它擋得住。
--     * 實體守衛擋得住「貨被別團 / 別通路領走」，這種情形 campaign-local 的帳看
--       起來永遠是夠的。
--   AND 起來才兩邊都蓋到，而且對既有行為是**單調收緊**：原本 false 的維持 false，
--   原本 true 的只有在「店裡真的沒貨」時才變 false。
--
-- 刻意的設計取捨：
--
--   1. **Path A / D / D' 在這道守衛「不」豁免** —— 與 20260814060000 那道刻意不同。
--      那三條回答的是「這批貨算不算到過店」（到貨問題），本守衛問的是「現在還在
--      不在架上」（當下問題）。一張一個月前的減抵單不能證明貨今天還在。
--      減抵單尤其不能豁免：rpc_create_inventory_deduction 開單時就強制
--      `on_hand - reserved >= v_total`，錯誤訊息是「請先到『庫存總覽』對該商品新增
--      庫存，再開減抵單」——「貨在架上但帳沒入」根本不是它的使用情境。
--      → 帳面不足但貨真的在架上的正解改成**到庫存總覽補庫存**（＋新增庫存 / 盤點），
--        跟開減抵單本來就要求的前置動作是同一件事，不是新增的負擔。
--   2. **豁免容器單與 offset 單本身**（store_internal 會員 / order_kind='offset'）。
--      它們被排除在「已承諾」母體之外，若又要它們自己過守衛就會被 on_hand 擋掉，
--      而池子單的「轉單給客人」「短收收尾」都不該被取貨閘門影響。
--   3. **沒綁倉別（或沒有取貨店）的店不套守衛**。算不出 on_hand 就維持舊行為，
--      比照 _advance_arrived_confirmed_orders「沒設倉庫位置的店直接不動」。
--      漏了這條會把那些店的單整批擋死。
--   4. **不寫任何欄位、不標 backorder_at**。守衛是純推導的：下一批貨收進來
--      on_hand 變大，排在後面的行自己就會重新放行，不需要人工解除。
--      （CLAUDE.md：「不要順手改成寫 backorder_at」。）
--   5. **排序讓前面的人先拿**。on_hand = 5 而有 8 個人在等時，最早下單的 5 位
--      照常可取，只有多出來的 3 位被擋 —— 不是整組一起關掉。
--
-- 已知的連帶影響（都是預期中的改善，不是 regression）：
--   * rpc_record_pickup 逐品項擋板走同一支閘門（20260815000000 第 279 行），
--     所以直接打 RPC 也擋得住。但它的錯誤訊息寫死「分店尚未實收到貨」，
--     本次不改那支（改動面過大），前端已經不會讓店員勾到這些品項。
--   * is_order_pickup_ready(order) ＝ 全部 active 品項都過閘門，所以
--     rpc_receive_transfer 邏輯 B/C（shipping → ready）會變成「只推得動
--     on_hand 蓋得住的單」。這正是 CLAUDE.md 要求的「拿閘門當到貨通知的觸發
--     條件時一定要自己加數量守衛」—— 現在守衛長在閘門裡，不會再出現
--     「補 2 包、團購欠 8 包 → 8 位團友都收到到貨通知卻撲空」。
--     順序上安全：rpc_receive_transfer 先跑 rpc_inbound 寫 on_hand，
--     才輪到邏輯 A0/A/B/C/E，同交易內讀得到剛加上去的量。
--   * _advance_arrived_confirmed_orders（confirmed → ready）不會因此少推單：
--     它的預算是 on_hand − **全部** promised，本守衛只算「排在本行之前的」
--     promised，恆 ≤ 前者，所以預算過得了的一定也過得了守衛。
--   * rpc_mark_orders_shipping_for_wave（confirmed → shipping）**沒有**呼叫閘門
--     （20260614000050 裡那個呼叫在一次性 backfill 的 DO 區塊內），
--     所以不會重演「105 張單全卡 confirmed」。
--
-- 已知殘留（本支**沒有**修掉的，寫下來免得下次以為蓋全了）：
--   * Path A / D / D' 在 **20260814060000 那道 campaign-local 守衛裡依然完全豁免、
--     依然不比數量**（本支不動它）。也就是說減抵單仍然能讓一組貨跳過「開團後實收 −
--     已取」那本帳；只是現在跳不過實體庫存那一關了。這樣的分工是刻意的：
--     現貨配單（rpc_create_offset_sale）的貨本來就不是總倉發的，記帳側算不到它，
--     硬要它過 campaign-local 守衛會把正常的現貨配單整批擋死。
--   * 減抵單的 qty 仍然沒有被任何一道守衛讀取。要讓「這張 DN 只蓋 3 件」真正生效，
--     得把 qty 接進 campaign-local 那本帳的供給側，那是另一個題目。
--   * 母體只算「已承諾」（ready / partially_completed / shipping），所以兩張都還沒被
--     推上來的 confirmed / pending 單彼此不佔預算 —— on_hand = 1 而有兩張 confirmed
--     時可能同時放行。刻意如此：把 confirmed 算進母體會讓「舊的等貨單」擋掉
--     「新的已到貨單」，而線上長期卡 confirmed 的單很多（CLAUDE.md 記過 265 張）。
--     正規路徑 _advance_arrived_confirmed_orders 有自己的 FIFO 預算會逐張扣，
--     這個殘留只在店員直接從取貨頁對 confirmed 單出貨時才碰得到。
--   * campaign-local 那本帳的供給側依然會被灌大（跨團共用同一批實收、互助 Leg-2 的
--     hq_to_store 供給算進來但需求被 Path A 排除、拒收回流複用 hq_to_store）。
--     本支不去動它 —— 實體守衛已經從另一邊把結果蓋住了，改供給側等於重寫
--     20260814060000 的核心，風險不對稱。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   is_order_item_pickup_ready = 20260814060000_pickup_gate_qty_aware.sql（＝線上現行版）
--   v_order_item_pickup_ready  = 20260814060000（本次不動）
--   _pickup_group_supplied / _pickup_group_available = 20260814060000（本次不動）
--
-- Rollback：
--   重跑 20260814060000 內的 CREATE OR REPLACE FUNCTION public.is_order_item_pickup_ready
--   即退回只有 campaign-local 守衛的版本（本支沒有新增任何函式或欄位）。
--
-- 上線前後要跑的驗證見檔尾 §2（兩支 scripts/verify-pickup-stock-guard-*.sql）。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. is_order_item_pickup_ready — Path A~D' 與 campaign-local 數量守衛逐字保留，
--    末端再追加一道「門市實體庫存」守衛
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
       -- 2026-08-14：數量守衛（campaign-local）。上面的 Path B / C 是 qty-blind 的
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
       -- ------------------------------------------------------------------
       -- 2026-08-18：門市實體庫存守衛（新增）。上面那道的帳本是 campaign-local，
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
       -- 豁免與上一道相同（Path A / D / D'），另外豁免容器單與 offset 單本身
       -- ——它們被排除在「已承諾」母體外，再要它們自己過守衛會被 on_hand 擋死。
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
         --   線上實證（2026-08-18 松山 GRP-20260809-001 / sku 1981）：3 張 qty=1 的
         --   減抵單（「加單頁現貨配單」）→ 該組已取 4 件、on_hand 0，還有 2 張單
         --   因為 Path D 豁免而一路亮著「已到貨」。那就是本次回報的災情本體。
         --
         -- 帳面不足但貨真的在架上時的正解 = **到庫存總覽把庫存補上**（＋新增庫存 /
         -- 盤點），不是開減抵單繞過去 —— 減抵單自己也是這樣要求的。
         --
         -- 實體守衛本體：跨團累計承諾 ≤ on_hand
         OR (
           SELECT COALESCE(SUM(y.qty), 0)
             FROM customer_order_items y
             JOIN customer_orders yo ON yo.id = y.order_id
             LEFT JOIN members ym ON ym.id = yo.member_id
            WHERE yo.tenant_id       = co.tenant_id
              AND yo.pickup_store_id = co.pickup_store_id
              AND y.sku_id           = coi.sku_id
              AND y.status IN ('pending','reserved','ready')
              AND y.qty > 0
              -- 待補貨的行已被少發配貨擋掉，不佔預算（同上一道）
              AND y.backorder_at IS NULL
              -- 只算「已經對客人承諾」的單頭；confirmed / pending 是還在等貨的
              -- 需求，算進來會讓舊的等貨單擋掉新的已到貨單。本行一律計入自己。
              AND (
                yo.status IN ('ready','partially_completed','shipping')
                OR y.id = coi.id
              )
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
$function$;

COMMENT ON FUNCTION public.is_order_item_pickup_ready(bigint) IS
  '品項層級取貨閘門。Path A: aid transfer FK 收貨 / Path B: campaign 對齊波次實收 / '
  'Path C: 無對齊波次時退用本店該 SKU「開團之後」的實收（2026-08-14 加時間下限）/ '
  'Path D: 減抵單 / Path D'': offset 抵減單。'
  '2026-08-14 數量守衛（campaign-local）：同團依 (下單時間, 單號, 行 id) 累加，'
  '累計量超過「開團後實收 − 已取走」的行回 false（擋總倉短收）。'
  '2026-08-18 實體庫存守衛：跨團依同一套排序累加「已承諾未取」（單頭 ready / '
  'partially_completed / shipping，排除容器單 / offset / 待補貨），'
  '累計量超過該店該 SKU 的 stock_balances.on_hand 的行回 false '
  '（擋「貨到了但被別團／現貨配單領走」與「有減抵單就無限放行」）。'
  '這道守衛**不**豁免 Path A / D / D'' —— 那三條答的是「到過店沒」，這道問的是'
  '「現在還在不在架上」；減抵單開單時本來就要求 on_hand 先夠（rpc_create_inventory_'
  'deduction），不能拿來繞過 on_hand。只豁免容器單（store_internal）、offset 單本身、'
  '未綁倉別的店。帳面不足但貨在架上 → 到庫存總覽補庫存，不是開減抵單。';

-- ============================================================
-- 2. 上線前後要跑的驗證（不放進 migration 交易，手動跑）
--
--   影響範圍 / 驗收：scripts/verify-pickup-stock-guard-impact.sql
--     套用前 → 完整的超賣清單（＝本支要擋掉的量）；
--     套用後 → 應該只剩 exempt_reason 非 NULL 的列（Path A / D / D' / 容器單 /
--     offset / 沒綁倉別的店，都是刻意豁免）。還有 exempt_reason IS NULL 的列
--     就是守衛沒生效，回頭查。
--
--   誤擋檢查：scripts/verify-pickup-stock-guard-regression.sql
--     店裡帳上有貨（on_hand > 0）卻被擋的行，依 backorder / stock_guard / other
--     分類。重點看 first_in_line_but_blocked —— 前面沒人排隊卻被擋，代表 on_hand
--     低於實際（到貨沒入帳 / 重複扣帳），該補收貨或盤點，不是守衛寫錯。
--
--   ⚠ 兩支檔案裡的 cum 算式與本檔守衛逐字對齊。改守衛時要一起改，否則對不上。
-- ============================================================

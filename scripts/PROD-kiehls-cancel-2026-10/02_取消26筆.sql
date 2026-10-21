-- ============================================================================
--  02 取消 26 筆（✅ 會改資料）
--  契爾氏 kiehl's 金盞花植物精華化妝水 40ml（商品 G02596-01）叫錯款式、廠商沒有正確款
--  ⇒ 團 GRP-20260910-027 裡「等貨中」的客人品項 26 筆（32 件）一次取消
--     （10/21 早上查是 27 筆 33 件；松山 1 筆已由老闆 10/21 中午在後台手動「刪除品項」（整單已一併取消），不在這次範圍）
--  日期：2026-10-21　阿寫寫、⛔ 阿審（Codex）審過之前不要貼
--  依據：公司\01_進行中\需求暨計畫_NEW-ERP契爾氏化妝水27筆客人品項批次取消_2026-10-21.md（老闆 10/21「好 做」）
--  程式出處：工地 git origin/main 1343df73（線上 main 10/15）supabase/migrations/（行號寫在各段）
-- ============================================================================
--  ★ 這份在做什麼（整份只有一個 DO 區塊＝同一次；任何一步不對就整筆取消、什麼都沒改）
--    ① 先檢查（任何寫入之前）：對象＝商品 G02596-01 ＋ 團 GRP-20260910-027 ＋ 品項「等貨中」(pending)；
--       筆數必須 26、件數必須 32；這 26 筆不能已經有斷貨標記；這幾張單的單頭狀態只能是
--       待確認／已確認／出貨中／可取貨／部分取貨；單上不能有少見的品項狀態（例如「部分領走」）。
--       不對 → 紅字【停】，什麼都沒改。
--    ② 每一筆：有從店內庫存配過貨的先還回（跟店家「刪除品項」同一支
--       _release_order_item_stock_assignment，rpc_delete_order_item 第 6 步 20260831000090:797-800）。
--       沒配過貨的（預期全部）這一步什麼都不做。
--    ③ 品項改「已取消」＋蓋斷貨時間 stockout_at（欄位跟斷貨取消一樣：_stockout_po_items (b) 段
--       20260902000010:318-336）→ 後台訂單頁、會員 App 這一項會顯示「斷貨」。
--    ④ 每一筆寫一列編輯歷史 customer_order_audit_log（格式同刪除品項第 8 步 20260831000090:809-815），
--       原因固定寫「契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消」——
--       04 確認、05 還原、03 通知、重貼判斷，都靠這一句認出「這一次」做的事，⛔ 不要改字。
--    ⑤ 訂單收尾，照刪除品項第 9 步（20260831000090:817-853）：
--       ・單上已經沒有待取品項、而且取過貨 → _close_orders_all_items_settled 收尾成「已完成」
--       ・單上已經沒有待取品項、一件都沒取、沒付款、沒用儲值金 → 整單取消，單頭也蓋斷貨時間
--         （單頭蓋斷貨照斷貨 (c) 段 20260902000010:337-363 的做法；2026-10-21 CEO 裁決：客人 App 要看到
--          「⛔ 供應商斷貨，本筆訂單已取消」。原本就有斷貨時間的單頭不覆蓋。）
--         （出貨中／可取貨／已確認都一樣：狀態檢查只看「沒有待取品項」，見下方開工前四問 Q1-j）
--       ・收尾成已完成、單子留著、付過錢的單：單頭都不蓋斷貨時間
--       ・付過錢或用過儲值金 → 單子不動、不退錢（品項照樣取消），結尾列出來給人工處理
--       ・單上還有別的待取品項 → 單子留著，只少這一項
--       ⇒ 整單取消、收尾完成這兩種也各寫一列編輯歷史（05 還原要用）
--    ⑥ 自我驗算（同一個 DO 區塊裡、寫完再讀；不對就整筆取消）
--  ★ ⛔ 不動：派車單、庫存異動、採購單、月結、店家退回單、開團商品設定（campaign_items）、會員通知（要發另貼 03）
--    （② 那支只動「庫存減抵單」與【內部】現貨池那兩樣，而且只在有配過貨時才動；它不寫庫存異動，
--      見它自己的說明 20260827040000:191-196「不動 stock_balances」）
--  ★ 要填的一行：下面 DECLARE 裡的 p_operator（操作人＝老闆本人的使用者 UUID，01 第⑨段列出，
--    CEO 在老闆確認後填）。⛔ 交件時刻意留空；空的、或不是包子媽總部帳號，會直接【停】。
--  ★ 重貼：已經做過的（這一團這商品有「這一次」取消的品項還是取消狀態）會顯示
--    （只認 02 自己寫的那一句原因＋品項斷貨時間＝那一刻；松山那筆是刪除品項取消的，原因不同、沒有斷貨時間，不會被誤認）
--    「已經做過，這次什麼都沒改」然後結束，不會報筆數不對、不會重做。
--  ★ 看到什麼要停：
--    ・紅字開頭【停】→ 什麼都沒改，截圖給 CEO（紅字會寫是哪一項不對）；⛔ 不要重貼
--    ・紅字寫 lock timeout／有人正在操作 → 什麼都沒改，過幾分鐘再貼一次；連續兩三次都這樣，截圖給 CEO
--    ・Supabase 可能只顯示「Success. No rows returned」（它不一定顯示下面那行白話總結）→ 正常，接著貼 04
--  ★ 做錯了怎麼辦：05（還原，備用）。
-- ============================================================================
--  開工前四問（2026-10-21 阿寫查；證據都是工地 git origin/main 1343df73 的檔:行）
--  Q1 這件事系統有沒有現成的做法？改狀態會連動什麼？
--    ・現成做法有兩支，但都叫不動這 26 筆：
--      斷貨 rpc_stockout_po_item 只給還沒全到貨的採購單（20260801000000:274 起）；
--      刪除品項 rpc_delete_order_item 只准 待確認／可取貨／部分取貨（20260831000090:759-768），
--      而且要登入者權限（:749 _check_order_edit_qty_perm），SQL Editor 叫不動。
--      ⇒ 這份不另發明規則：品項欄位照斷貨 (b)、還庫存照刪除品項第 6 步、收尾照刪除品項第 9 步。
--    ・兩張表上的觸發器，全部 migration 掃過（逐檔找 CREATE TRIGGER … ON …）只有這 5 支：
--      a. trg_touch_coi／trg_touch_corders（20260423120000:329-332，函式最新 20260611000010:12-21）：
--         改到的列「最後修改時間」變成這次執行時間。04、05 用這個時間判斷後來有沒有人再動過。
--      b. trg_coi_backorder_source_clear（20260902030000:185-191）：只在「待補貨時間是空、來源標記還在」
--         時清掉兩個標記欄。這份不碰待補貨欄位 → 不會觸發。
--      c. trg_release_idn_coverage（20260813002000:173-179，函式 :83-148、:160-170，都只有一版）：
--         單頭變成已取消時，把綁在這張單上的庫存減抵單覆蓋釋放。整單取消的單會觸發它；
--         但 ② 已先把這幾筆的覆蓋還掉，它再跑是 0（只釋放 qty > released_qty 的部分 :117、:127）。
--         整單取消的單上沒有其他待取品項（條件就是這個）→ 不會誤放別人的貨。
--      d. trg_no_mut_coa（20260605000001:27-28）：編輯歷史只能新增、不能改刪。本份與 05 都只新增。
--      e. 通知表 notifications 上沒有任何觸發器（見 03 檔頭）。
--      ⇒ 正式庫如果有人從後台另外加過觸發器，程式碼紀錄看不到；01 第⑤段會把正式庫實際掛的列出來比對。
--    ・不是觸發器、但會讀這些狀態的：
--      f. 請購草稿同步（#1049，20261001000000）：是請購單編輯頁的按鈕，不是觸發器（檔頭 :27-31
--         「0 個觸發器」），而且只改「草稿、還沒建採購單」的列（:451、:637）。這團這商品已經叫貨
--         → 取消後不會自動改任何請購單；01 第⑥段列出還有沒有草稿列。
--      g. 派貨需求 v_picking_demand_by_po（正式現行版＝#1084 20261016000000:932 起）：只算單頭不是
--         取消／過期／轉出、品項不是取消／過期的（:981、:984）→ 這 32 件從需求拿掉（松山那 1 件刪除時已經拿掉）。採購單這一項
--         已收 33、已出 33，沒有剩貨 → 派貨工作台不會多出要派的；已派出去的 9 張派車單不動。
--      h. #1084「叫貨後才取消、照派原店」：只收「採購單品項建立時間 ≥ 分界」的
--         （v_picking_po_rule_items :806；分界 _picking_po_rule_cutover() :731-738 ＝ '2026-10-16 00:00:00+08'）。
--         本採購單 9/16 成立 → 不在裡面。就算在裡面，v_picking_post_po_cancelled 兩段都要求品項沒有
--         斷貨標記（:848、:877）、單頭沒有斷貨標記（:844、:883），這份會蓋品項斷貨時間 → 雙重不會被
--         算成照派原店。這支 view 不在 1343df73，在分支 claude/post-po-cancel-frontend-20261015
--         （git show 讀的）；01 第⓪段會印出正式庫裡分界時間的原文對照。
--      i. 取貨閘門 is_order_item_pickup_ready（最新 20260907000000:51）逐品項判斷，已取消的品項不會出現在可取清單。
--      j. 店家收貨 rpc_receive_transfer（最新 20260904020010:101，邏輯 C :505-548）：還沒收貨的
--         中和、古華、文山、永和收這批錯貨時，只把「單頭出貨中、而且單上還有這個商品待取品項」的單
--         推成可取貨（:528-529）→ 這 26 筆已取消，不會因為這批錯貨被推成可取貨；整單取消的單也不會被動。
--         ⇒ 整單取消對「已確認／出貨中／可取貨」都適用：取消那句只要求單頭還是原狀態（防同時有人改），
--           之後所有推進狀態的地方都只認特定狀態（例：:528、:541），不會把已取消的單推回來。
--      k. ⚠ 收貨後推播「您的商品到貨」rpc_get_members_to_notify_for_transfer（最新 20260814010000:40-82）
--         看「單頭 可取貨／部分取貨／出貨中」＋「單上有這個商品」，不看品項狀態（:62-82）。
--         ⇒ 整單取消的客人不會收到；但「單上還有別的品項、單子留著」的客人，店家收這批錯貨時
--           仍可能收到一則「您的商品到貨」。這是既有行為（斷貨、刪除品項一樣），本份不改；01 第③段列出張數。
--      l. LINE 記事本：觸發器全掛在開團表與貼文表（例：20260927000000:78-80），這份不動開團 → 不會發文、不會改文。
--      m. 會員 App：「進行中」不顯示一般取消的單、只顯示單頭有斷貨標記的取消單（supabase/functions/liff-api/index.ts:618-624）。
--         這份整單取消時單頭蓋斷貨時間 ⇒ 客人「進行中」看得到那張單，上面寫「⛔ 供應商斷貨，本筆訂單已取消」
--         （apps/member/src/components/OrderCard.tsx:296-308）；後台訂單頁單頭有「⛔ 斷貨」標籤（OrderDetail.tsx:1336-1343）；
--         單子留著的，這一項顯示「斷貨」、劃線、不算錢（20261002010000:102-104、apps/member/src/components/OrderCard.tsx:340-363）。
--      n. 後台訂單頁「復原取消」鈕：單頭有斷貨標記 → 鈕不顯示（apps/admin/src/components/OrderDetail.tsx:815-819 要 !head.stockout_at）；
--         直接呼叫 rpc_restore_cancelled_order（最新 20261013000000:1480）也會被守衛 2 擋下（:1516-1520，叫人去採購單按「回復斷貨」），
--         而採購單的「回復斷貨」只認 stockout_po_id（這份不寫，見 05 檔頭）→ 兩條路都救不回、也不會弄壞；要救回只能用 05。
--         單子留著的單：品項有斷貨標記，復原取消也不會還它（:1587-1599 只還沒有斷貨標記的品項）。
--      o. 單頭斷貨時間還有誰在讀（全 repo 查 co.stockout_at 等寫法）：會員 App／後台的顯示、訂單摘要 view 帶出這一欄、
--         rpc_restore_cancelled_order 守衛 2、#1084 叫貨後取消照派原店（排除有標記的，見 h）、回復斷貨（只認 stockout_po_id，
--         20260812000000）。沒有任何會因為它改帳、改庫存、改派貨的地方。
--  Q2 用到的每支既有程式，最新版是哪一支（查法：git grep -nE "CREATE (OR REPLACE )?FUNCTION (public\.)?<名>" origin/main -- supabase/migrations | sort）
--    ・_release_order_item_stock_assignment：只有 1 支 20260827040000:60
--      └ 它裡面用的 _order_item_stock_budget 只有 1 支 20260824070000:76；_restore_internal_pool 只有 1 支 20260825020000:132
--    ・_close_orders_all_items_settled：只有 1 支 20260808000000:62（接受 待確認／已確認／可取貨／出貨中／部分取貨 :83）
--    ・參考：rpc_delete_order_item 3 支，最新 20260831000090:732；_stockout_po_items 4 支，最新 20260902000010:232；
--      rpc_restore_cancelled_order 2 支，最新 20261013000000:1480
--    ・編輯歷史欄位白名單 customer_order_audit_log_field_check 最新 20260902040000:58-63（含 'status'）
--    ・單頭狀態白名單 customer_orders_status_check 最新 20260606000021:10-15（含 'cancelled'）
--  Q3 還有誰在用：這份不改任何函式／表／觸發器，只「呼叫」上面兩支、改資料。
--    _release_order_item_stock_assignment 現在只有 rpc_delete_order_item 在用；_close_orders_all_items_settled
--    有斷貨、取消待補貨、刪除品項在用 —— 都不受影響（沒有改它們）。
--  Q4 撞車：只新增 scripts/PROD-kiehls-cancel-2026-10/ 底下的檔，不改任何既有檔。
--    開著的 PR 有沒有動到同一批資料／檔案：阿寫不准連 GitHub，⚠ 沒查，送出去之前由 CEO 查。
-- ============================================================================

DO $kiehls$
DECLARE
  -- ╔════════ 要填的一行（CEO 在老闆確認後填）════════╗
  p_operator      uuid := NULL;   -- ⬅ 操作人：01 第⑨段列出、老闆確認過的本人 UUID，例如 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'；⛔ 空的會直接停
  -- ╚════════════════════════════════════════════════╝
  c_campaign_no   CONSTANT text    := 'GRP-20260910-027';
  c_sku_code      CONSTANT text    := 'G02596-01';
  c_expect_rows   CONSTANT int     := 26;      -- 10/21 早上 27 筆；松山 1 筆老闆中午已手動刪除品項
  c_expect_qty    CONSTANT numeric := 32;      -- 10/21 早上 33 件；同上少 1 件
  -- ⛔ 下面四句是「這一次」的身分證，01／03／04／05 逐字相同，不要改字
  c_tag_item      CONSTANT text := '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消';
  c_tag_cancel    CONSTANT text := '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消（這張單沒有其他待取品項，整單取消）';
  c_tag_done      CONSTANT text := '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消（其他品項都取過了，訂單收尾為完成）';
  c_tag_release   CONSTANT text := '契爾氏叫錯款式批次取消';
  v_now           timestamptz := now();
  v_tenant        uuid;
  v_campaign      bigint;
  v_sku           bigint;
  v_cnt           int;
  v_qty           numeric;
  v_bad           int;
  v_items         bigint[];
  v_orders        bigint[];
  v_rel           jsonb;
  v_rel_rows      int := 0;
  v_rel_qty       numeric := 0;
  v_rel_pool      numeric := 0;
  v_open          int;
  v_picked        boolean;
  n_cancel        int := 0;
  n_done          int := 0;
  n_paid          int := 0;
  n_keep          int := 0;
  v_paid_list     text := '';
  r               record;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  -- ── 0. 操作人 ──
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '【停】操作人 p_operator 是空的。要由 CEO 把老闆確認過的本人 UUID 填進去再貼。什麼都沒改。';
  END IF;

  -- ── 1. 對象：團、商品各要剛好一個 ──
  SELECT count(*) INTO v_cnt FROM public.group_buy_campaigns WHERE campaign_no = c_campaign_no;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】團號 % 在系統裡查到 % 個（要剛好 1 個）。什麼都沒改，請截圖給 CEO。', c_campaign_no, v_cnt;
  END IF;
  SELECT id, tenant_id INTO v_campaign, v_tenant FROM public.group_buy_campaigns WHERE campaign_no = c_campaign_no;

  SELECT count(*) INTO v_cnt FROM public.skus WHERE sku_code = c_sku_code AND tenant_id = v_tenant;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】商品碼 % 在這家公司查到 % 個（要剛好 1 個）。什麼都沒改，請截圖給 CEO。', c_sku_code, v_cnt;
  END IF;
  SELECT id INTO v_sku FROM public.skus WHERE sku_code = c_sku_code AND tenant_id = v_tenant;

  -- 操作人要是這家公司的總部帳號（認法同 scripts/PROD-fix-branch-price-batch2-2026-10/2_fix_WRITES.sql:228-235：
  -- 公司看登入帳號 app_metadata.tenant_id；總部角色＝空白／owner／admin／hq_manager／hq_accountant）
  IF NOT EXISTS (SELECT 1 FROM auth.users u
                  WHERE u.id = p_operator
                    AND (u.raw_app_meta_data ->> 'tenant_id') = v_tenant::text
                    AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')) THEN
    RAISE EXCEPTION '【停】操作人 % 不是這家公司的總部帳號（或根本不是登入帳號）。請用 01 第⑨段列出、老闆確認過的本人 UUID。什麼都沒改。', p_operator;
  END IF;

  -- ── 2. 上鎖：這一團裡有這個商品的訂單，先鎖單頭、再鎖這些單的全部品項（順序同刪除品項：先單頭後品項）──
  BEGIN
    PERFORM 1
       FROM public.customer_orders co
      WHERE co.campaign_id = v_campaign
        AND EXISTS (SELECT 1 FROM public.customer_order_items x WHERE x.order_id = co.id AND x.sku_id = v_sku)
      ORDER BY co.id
        FOR UPDATE;
    PERFORM 1
       FROM public.customer_order_items x
      WHERE x.order_id IN (SELECT co.id FROM public.customer_orders co
                            WHERE co.campaign_id = v_campaign
                              AND EXISTS (SELECT 1 FROM public.customer_order_items y
                                           WHERE y.order_id = co.id AND y.sku_id = v_sku))
      ORDER BY x.id
        FOR UPDATE;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION '【停】有人正在操作這幾張訂單（例如店家正在取貨、改單、收貨），等了 15 秒還拿不到。什麼都沒改，請過幾分鐘再貼一次。';
  END;

  -- ── 3. 做過了沒（重貼安全）：這一團這商品，有「這一次」取消、而且現在還是取消的品項 → 已經做過 ──
  SELECT count(*) INTO v_cnt
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
   WHERE co.campaign_id = v_campaign
     AND i.sku_id = v_sku
     AND i.status = 'cancelled'
     AND i.stockout_at IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.customer_order_audit_log a
                  WHERE a.order_id = i.order_id AND a.entity_type = 'item' AND a.entity_id = i.id
                    AND a.field = 'status' AND a.edit_reason = c_tag_item
                    AND a.created_at = i.stockout_at);
  IF v_cnt > 0 THEN
    RAISE NOTICE '已經做過（這一團這個商品，目前有 % 筆是這份取消的），這次什麼都沒改。%', v_cnt,
      CASE WHEN v_cnt = c_expect_rows THEN '請接著貼 04 確認。'
           ELSE '⚠ 應該是 26 筆，請截圖給 CEO。' END;
    RETURN;
  END IF;

  -- ── 4. 前置檢查（任何寫入之前）──
  SELECT array_agg(i.id ORDER BY i.id), count(*), COALESCE(sum(i.qty), 0),
         count(*) FILTER (WHERE i.stockout_at IS NOT NULL)
    INTO v_items, v_cnt, v_qty, v_bad
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
   WHERE co.campaign_id = v_campaign
     AND i.sku_id = v_sku
     AND i.status = 'pending';
  IF v_cnt <> c_expect_rows OR v_qty <> c_expect_qty THEN
    RAISE EXCEPTION '【停】這一團這個商品「等貨中」的客人品項現在是 % 筆、% 件，跟預期的 26 筆、32 件對不上（10/21 早上 27 筆 33 件、松山 1 筆老闆已手動刪除；其他的可能剛好有店家取貨、刪單或改數量）。什麼都沒改，請截圖給 CEO。',
      v_cnt, trim_scale(v_qty);
  END IF;
  IF v_bad > 0 THEN
    RAISE EXCEPTION '【停】這 26 筆裡有 % 筆已經帶著斷貨標記，跟預期不同。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  SELECT array_agg(DISTINCT x.order_id ORDER BY x.order_id) INTO v_orders
    FROM public.customer_order_items x WHERE x.id = ANY (v_items);

  SELECT count(*) INTO v_bad
    FROM public.customer_orders co
   WHERE co.id = ANY (v_orders)
     AND co.status NOT IN ('pending', 'confirmed', 'shipping', 'ready', 'partially_completed');
  IF v_bad > 0 THEN
    RAISE EXCEPTION '【停】有 % 張訂單的單頭狀態不是 待確認／已確認／出貨中／可取貨／部分取貨，跟預期不同。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
    FROM public.customer_order_items x
   WHERE x.order_id = ANY (v_orders)
     AND x.status NOT IN ('pending', 'reserved', 'ready', 'picked_up', 'cancelled', 'expired');
  IF v_bad > 0 THEN
    RAISE EXCEPTION '【停】這幾張單上有 % 筆品項的狀態不常見（例如「部分領走」），收尾規則對不上。什麼都沒改，請截圖給 CEO。', v_bad;
  END IF;

  -- ════════ 以下開始寫入 ════════

  -- ── 5. 有從店內庫存配過貨的先還回（刪除品項第 6 步同一支；沒配過貨的是 0、什麼都不做）──
  FOR r IN SELECT x.id FROM public.customer_order_items x WHERE x.id = ANY (v_items) ORDER BY x.id LOOP
    v_rel := public._release_order_item_stock_assignment(r.id, NULL, p_operator, c_tag_release, v_now);
    IF COALESCE((v_rel ->> 'qty')::numeric, 0) > 0 THEN
      v_rel_rows := v_rel_rows + 1;
      v_rel_qty  := v_rel_qty  + (v_rel ->> 'qty')::numeric;
      v_rel_pool := v_rel_pool + COALESCE((v_rel ->> 'to_pool')::numeric, 0);
    END IF;
  END LOOP;

  -- ── 6. 品項改已取消＋斷貨時間（欄位同斷貨 (b) 段 20260902000010:320-327）──
  UPDATE public.customer_order_items
     SET status      = 'cancelled',
         stockout_at = v_now,
         updated_by  = p_operator,
         updated_at  = v_now
   WHERE id = ANY (v_items)
     AND status = 'pending';
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  IF v_cnt <> c_expect_rows THEN
    RAISE EXCEPTION '【停】品項只改到 % 筆（應為 26），整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;

  -- ── 7. 編輯歷史：每一筆一列（格式同刪除品項第 8 步 20260831000090:809-815）──
  INSERT INTO public.customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  SELECT co.tenant_id, x.order_id, 'item', x.id, 'status',
         to_jsonb('pending'::text), to_jsonb('cancelled'::text), c_tag_item, p_operator
    FROM public.customer_order_items x
    JOIN public.customer_orders co ON co.id = x.order_id
   WHERE x.id = ANY (v_items);
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  IF v_cnt <> c_expect_rows THEN
    RAISE EXCEPTION '【停】編輯歷史只寫到 % 筆（應為 26），整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;

  -- ── 8. 訂單收尾（照刪除品項第 9 步 20260831000090:817-853）──
  FOR r IN
    SELECT co.id, co.tenant_id, co.order_no, co.status, co.payment_status, co.wallet_paid_amount,
           COALESCE(st.name, '?') AS store_name
      FROM public.customer_orders co
      LEFT JOIN public.stores st ON st.id = co.pickup_store_id
     WHERE co.id = ANY (v_orders)
     ORDER BY co.id
  LOOP
    SELECT count(*) FILTER (WHERE x.status IN ('pending', 'reserved', 'ready')),
           COALESCE(bool_or(x.status = 'picked_up'), FALSE)
      INTO v_open, v_picked
      FROM public.customer_order_items x
     WHERE x.order_id = r.id;

    IF v_open > 0 THEN
      n_keep := n_keep + 1;                       -- 單上還有別的待取品項 → 單子留著
    ELSIF v_picked THEN
      -- 取過貨、已沒有待取品項 → 收尾成已完成（跟斷貨、刪除品項同一支）
      IF public._close_orders_all_items_settled(ARRAY[r.id], p_operator, v_now) <> 1 THEN
        RAISE EXCEPTION '【停】有一張單（%）收尾成已完成沒有成功，整筆取消、什麼都沒改，請截圖給 CEO。', r.store_name;
      END IF;
      INSERT INTO public.customer_order_audit_log
        (tenant_id, order_id, entity_type, entity_id, field,
         before_value, after_value, edit_reason, operator_id)
      VALUES
        (r.tenant_id, r.id, 'order', r.id, 'status',
         to_jsonb(r.status), to_jsonb('completed'::text), c_tag_done, p_operator);
      n_done := n_done + 1;
    ELSIF COALESCE(r.payment_status, 'unpaid') <> 'paid'
          AND COALESCE(r.wallet_paid_amount, 0) = 0 THEN
      -- 一件都沒取過、也沒收過錢 → 整單取消（刪除品項第 9 步）＋單頭蓋斷貨時間（斷貨 (c) 段 20260902000010:340-346）
      -- 原本就有斷貨時間的不覆蓋（COALESCE）；05 只清「等於 02 那一刻」的
      UPDATE public.customer_orders
         SET status       = 'cancelled',
             cancelled_at = v_now,
             stockout_at  = COALESCE(stockout_at, v_now),
             updated_by   = p_operator,
             updated_at   = v_now
       WHERE id = r.id
         AND status = r.status;
      GET DIAGNOSTICS v_cnt = ROW_COUNT;
      IF v_cnt <> 1 THEN
        RAISE EXCEPTION '【停】有一張單（%）整單取消沒有成功，整筆取消、什麼都沒改，請截圖給 CEO。', r.store_name;
      END IF;
      INSERT INTO public.customer_order_audit_log
        (tenant_id, order_id, entity_type, entity_id, field,
         before_value, after_value, edit_reason, operator_id)
      VALUES
        (r.tenant_id, r.id, 'order', r.id, 'status',
         to_jsonb(r.status), to_jsonb('cancelled'::text), c_tag_cancel, p_operator);
      n_cancel := n_cancel + 1;
    ELSE
      -- 付過錢／用過儲值金 → 不自動取消、不動錢，列出來給人工處理
      n_paid := n_paid + 1;
      v_paid_list := v_paid_list || CASE WHEN v_paid_list = '' THEN '' ELSE '、' END
                     || r.store_name || ' ' || r.order_no;
    END IF;
  END LOOP;

  -- ── 9. 自我驗算（同一個 DO 區塊裡的下一句，看得到上面寫的；不對就整筆取消）──
  SELECT count(*) INTO v_cnt
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
   WHERE co.campaign_id = v_campaign AND i.sku_id = v_sku
     AND i.status = 'cancelled' AND i.stockout_at = v_now;
  IF v_cnt <> c_expect_rows THEN
    RAISE EXCEPTION '【停】自我驗算沒過：這一次取消的品項查到 % 筆（應為 26）。整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;

  SELECT count(*) INTO v_cnt
    FROM public.customer_order_items i
    JOIN public.customer_orders co ON co.id = i.order_id
   WHERE co.campaign_id = v_campaign AND i.sku_id = v_sku AND i.status = 'pending';
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '【停】自我驗算沒過：這一團這個商品還有 % 筆等貨中。整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;

  SELECT count(*) INTO v_cnt
    FROM public.customer_order_audit_log a
   WHERE a.created_at = v_now
     AND a.edit_reason IN (c_tag_item, c_tag_cancel, c_tag_done);
  IF v_cnt <> c_expect_rows + n_cancel + n_done THEN
    RAISE EXCEPTION '【停】自我驗算沒過：這一次的編輯歷史有 % 列（應為 %）。整筆取消、什麼都沒改，請截圖給 CEO。',
      v_cnt, c_expect_rows + n_cancel + n_done;
  END IF;

  SELECT count(*) INTO v_cnt
    FROM public.customer_orders co
   WHERE co.id = ANY (v_orders) AND co.status = 'cancelled' AND co.cancelled_at = v_now;
  IF v_cnt <> n_cancel THEN
    RAISE EXCEPTION '【停】自我驗算沒過：整單取消的單查到 % 張（應為 %）。整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt, n_cancel;
  END IF;

  -- 整單取消的單頭都有斷貨時間；斷貨時間＝02 這一刻的單頭，只能是整單取消的那幾張
  SELECT count(*) INTO v_cnt
    FROM public.customer_orders co
   WHERE co.id = ANY (v_orders) AND co.status = 'cancelled' AND co.cancelled_at = v_now AND co.stockout_at IS NULL;
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '【停】自我驗算沒過：有 % 張整單取消的單頭沒有斷貨時間。整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;
  SELECT count(*) INTO v_cnt
    FROM public.customer_orders co
   WHERE co.stockout_at = v_now
     AND NOT (co.id = ANY (v_orders) AND co.status = 'cancelled' AND co.cancelled_at = v_now);
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '【停】自我驗算沒過：有 % 張不是整單取消的單頭被蓋了斷貨時間。整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt;
  END IF;

  -- 沒有多動到別的：這一次改到的品項只能是這 26 筆、改到的單頭只能是整單取消＋收尾完成那幾張。
  -- 例外：② 有把貨還回【內部】現貨池時，那支會改到池子的容器單（20260825020000:200-251），這兩項就不算。
  IF v_rel_pool = 0 THEN
    SELECT count(*) INTO v_cnt
      FROM public.customer_order_items x
     WHERE x.updated_at = v_now AND NOT (x.id = ANY (v_items));
    IF v_cnt <> 0 THEN
      RAISE EXCEPTION '【停】自我驗算沒過：多改到 % 筆別的品項。整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt;
    END IF;
    SELECT count(*) INTO v_cnt
      FROM public.customer_orders co
     WHERE co.updated_at = v_now;
    IF v_cnt <> n_cancel + n_done THEN
      RAISE EXCEPTION '【停】自我驗算沒過：這一次改到 % 張單頭（應為 %）。整筆取消、什麼都沒改，請截圖給 CEO。', v_cnt, n_cancel + n_done;
    END IF;
  END IF;

  RAISE NOTICE '✅ 完成：取消 % 筆（% 件）；整單取消 % 張（單頭也標斷貨）；收尾成已完成 % 張；單上還有別的品項、單子留著 % 張；付過錢／用過儲值金、單子沒動 % 張%；從店內庫存配過貨、已還回 % 筆（% 件，其中回【內部】現貨池 % 件）。請接著貼 04 確認。',
    c_expect_rows, trim_scale(c_expect_qty), n_cancel, n_done, n_keep, n_paid,
    CASE WHEN n_paid > 0 THEN '（' || v_paid_list || '，要人工處理退款）' ELSE '' END,
    v_rel_rows, trim_scale(v_rel_qty), trim_scale(v_rel_pool);
END $kiehls$;

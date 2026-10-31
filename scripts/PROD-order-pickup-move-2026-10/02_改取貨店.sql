-- ============================================================================
--  02 改取貨店（✅ 會改資料）：客人 4 張還沒取的訂單，取貨店 萬華 → 中和
--  日期：2026-10-31（10/31 第 2 版：補並行上鎖、重貼只認備註最後一行）　⛔ 審查問題清空之前不要貼
--  程式出處：工地 origin/main 3248064c（#1093）supabase/migrations/（行號寫在下面）
-- ============================================================================
--  ★ 整份只有一個 DO 區塊＝同一次；任何一步不對就整筆退回、一張都沒改。
--    ① 先全部檢查（任何寫入之前），4 張都要過：
--       訂單號存在、屬於這位會員（或合併進來的舊編號）、狀態仍是 待確認／已確認、取貨店仍是萬華、
--       一般團購單、不是門市團、不是轉入單、不是空中轉／互助單、品項全部「等貨中」且跟 10/31 確認的一模一樣、
--       沒有任何沒取消的派車單綁著這張單、下單後也沒有沒取消的派車單派往萬華且含這些商品、
--       總倉撿貨單上這一團這商品沒有萬華那一列（沒取消的撿貨單）。
--       萬華、中和用店名查，各要剛好 1 家；中和要是啟用中；會員綁定店要已經是中和。
--       不對 → 紅字【停】，什麼都沒改。
--    ② 4 張單：取貨店改中和；備註最後加一行（格式照後台「會員換取貨店」
--       rpc_move_member_to_store 20260829000020:464-471：「[改取貨店] 門市 #舊 → #新（時間）」，後面加本次原因）。
--    ③ 自我驗算：剛好 4 張、取貨店都是中和、除了 取貨店／備註／修改時間 以外整列一字不差、
--       品項整列一字不差、這一刻沒有改到別張單。不對 → 整筆退回。
--  ★ 不動：品項、派車單、撿貨單、派貨草稿、庫存、採購單、請購單、月結、會員資料、LINE 綁定、頻道(channel_id)。
--  ★ 重貼：4 張都已經在中和、而且備註**最後一行**就是本次那一行 → 顯示「已經做過」，什麼都不改。
--    （04 還原過之後再貼 02，會再改一次，備註再加一行。）
--  ★ 並行（同時有人在建撿貨單／派車／改撿貨單）：**先上鎖，拿到鎖之後才做 ① 的所有檢查，再寫入**。
--    鎖跟既有程式拿的是同一把（所以它們會排隊等這份做完，這份也會等它們做完）：
--      0. 會員：照後台會員換取貨店 rpc_move_member_to_store 的鎖序（20260829000020:313-316）
--         先 advisory 'member_store_move:<會員id>'、再鎖會員那一列；綁定店在拿到鎖之後才讀，寫入前再確認一次。
--      a. 建撿貨單 rpc_create_wave_from_po（最新 20261016000000:1160）：先鎖採購單那一列（:1187 FOR UPDATE），
--         再拿 advisory 'wave:po:<採購單id>'（:1201）。⇒ 這份對「這 4 團叫貨的每一張採購單」照同一順序拿這兩把。
--      b. 派車 generate_transfer_from_wave（最新 20260717000000:126）：advisory(撿貨單id)＋撿貨單那一列 FOR UPDATE（:149-152）；
--         撿貨單加品項 rpc_add_wave_item（最新 20260817000020:69）、改撿貨量 rpc_update_picked_qty（最新 20260502070000:5）、
--         取消撿貨單 都鎖撿貨單那一列（20260817000020:90-110 的盤點）。
--         ⇒ 這份把**所有還沒出貨、沒取消的撿貨單**那一列 FOR UPDATE（這份只跑幾毫秒）。
--      c. 4 張單本身、單上品項：FOR UPDATE。
--    ⚠ 殘餘（鎖不到的，寫明讓人知道）：
--      ・別張採購單建撿貨單時「跨團借調」拿這幾團的需求（20260816000050 借調分支）：它拿的是那張採購單的鎖，這份鎖不到。
--      ・不經撿貨單、直接開的派往萬華派車單（萬華停業，正常不會有）。
--      ⇒ README 寫明：請在總倉沒在排撿貨／派車的時候貼（老闆排半夜貼）。
--    鎖等超過 15 秒 → 紅字 lock timeout，什麼都沒改，過幾分鐘再貼。
-- ============================================================================
--  開工前四問（2026-10-31 查；證據是工地 origin/main 3248064c 的檔:行）
--  Q1 改 customer_orders.pickup_store_id 會觸發什麼？
--    ・customer_orders 上的觸發器（全部 migration 掃 CREATE TRIGGER … ON customer_orders）只有兩支：
--      a. trg_touch_corders（20260423120000:329-330；函式最新 20260611000010:12-21）：修改時間＝這次交易時間。
--      b. trg_release_idn_coverage（20260813002000:173-179）：只在單頭變成 已取消／過期 時跑。
--         這份不改狀態 → 不會觸發。
--    ・不寫品項、不寫庫存異動、不發通知（通知是收貨／到貨時另外發，不是觸發器）。
--  Q2 有沒有「已經按店算好、存起來」的數量？
--    ・派貨需求 v_picking_demand_by_po（最新 20261016000000:932）是「即時」依 co.pickup_store_id 加總
--      （campaign_demand :978-986），不存數字 ⇒ 改完這 4 張的需求自動從萬華消失、出現在中和。
--    ・請購／採購品項沒有分店欄（purchase_request_items 20260422120004:131-145；PO 品項同），不用動。
--    ・分店追加紀錄 purchase_request_store_additions（20260923120000:17）有 store_id，但它是「追加了多少」的
--      歷史帳，派貨需求不讀它的分店（只用來算總量 20261016000000:1749-1758）⇒ 不用動。
--    ・⚠ 會留在萬華的「存起來」只有兩種，這份都先查：
--      - 總倉撿貨單 picking_wave_items（store_id 存死；後台改店那支會把它搬過去 20260829000020:357-462）
--        ⇒ CEO 10/31 確認沒有派往萬華的派車單；這份再查一次「撿貨單上有沒有萬華那一列」，有就【停】（不在這份搬）。
--      - 派貨草稿 picking_draft_items（20260817000000:99-，每店一格、樓下手改的快照）⇒ 01／03 只提醒，不擋不改。
--  Q3 唯一約束：customer_orders_trio_kind_active_uniq（最新 20261013000000:252-259）＝
--    (tenant, campaign, channel, member, order_kind)，沒有店 ⇒ 改取貨店不可能撞。
--    channel_id 不動：線上一般單大多共用同一個頻道、頻道不跟取貨店走（20260829000020:13-17），
--    後台改店那支也不動 channel_id（20260829000020:464-471）。
--  Q4 稽核：customer_order_audit_log 的欄位白名單（最新 20260902040000:58-63）沒有 pickup_store_id，
--    寫不進去（要寫得先改表規則＝改結構，不在這份範圍）。既有改取貨店的程式
--    rpc_move_member_to_store 的留痕方式是「備註加一行」（20260829000020:466-469）⇒ 照抄。
--    updated_by 不改（SQL 視窗沒有登入者；也不在檔案裡寫任何帳號編號）。
-- ============================================================================

DO $pickup_move$
DECLARE
  c_member_no CONSTANT text := 'M20260810082311747';
  -- ⛔ 這一句是「這一次」的身分證，01／03／04 逐字相同，不要改字
  c_tag       CONSTANT text := '萬華店停業，2026-10-31 老闆核准改中和取貨';
  c_want      CONSTANT jsonb := '[
    {"order_no":"GRP-20261007-053-0030","sku_code":"G03109-01","qty":4},
    {"order_no":"GRP-20261007-063-0034","sku_code":"G03119-01","qty":1},
    {"order_no":"GRP-20261008-018-0038","sku_code":"G03131-03","qty":2},
    {"order_no":"GRP-20261011-043-0010","sku_code":"G03177-01","qty":12}
  ]';
  v_now       timestamptz := now();
  v_tenant    uuid;
  v_member    bigint;
  v_home      bigint;
  v_old       bigint;
  v_new       bigint;
  v_old_loc   bigint;
  v_cnt       int;
  v_nos       text[];
  v_ids       bigint[];
  v_at_old    int;
  v_at_new    int;
  v_before    jsonb;
  v_items_b   jsonb;
  v_after     jsonb;
  v_items_a   jsonb;
  v_line      text;
  v_pos       bigint[];
  v_po        bigint;
  r           record;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  v_nos := ARRAY(SELECT DISTINCT e ->> 'order_no' FROM jsonb_array_elements(c_want) e ORDER BY 1);

  -- ── 1. 會員：剛好 1 位 ──
  v_cnt := (SELECT count(*) FROM public.members WHERE member_no = c_member_no);
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】會員編號 % 查到 % 位（要剛好 1 位）。什麼都沒改。', c_member_no, v_cnt;
  END IF;
  v_member := (SELECT id            FROM public.members WHERE member_no = c_member_no);
  -- 會員列上鎖：鎖序照後台會員換取貨店 rpc_move_member_to_store（20260829000020:313-316：
  -- 先 advisory 'member_store_move:<會員id>'、再鎖會員那一列）。綁定店等鎖拿到之後才讀。
  PERFORM pg_advisory_xact_lock(hashtext('member_store_move:' || v_member::text));
  PERFORM 1 FROM public.members WHERE id = v_member FOR UPDATE;
  v_tenant := (SELECT tenant_id     FROM public.members WHERE id = v_member);
  v_home   := (SELECT home_store_id FROM public.members WHERE id = v_member);

  -- ── 1b. 上鎖（說明見檔頭「並行」），之後的檢查全部在拿到鎖之後跑 ──
  --   這 4 團叫貨的採購單：口徑同派貨需求表 po_campaigns（20261016000000:956-972）
  v_pos := ARRAY(
    SELECT DISTINCT poi.po_id
      FROM public.customer_orders co
      JOIN public.purchase_request_campaigns prc ON prc.campaign_id = co.campaign_id
      JOIN public.purchase_request_items pri     ON pri.pr_id = prc.pr_id
      JOIN public.purchase_order_items poi       ON poi.id = pri.po_item_id
     WHERE co.tenant_id = v_tenant AND co.order_no = ANY (v_nos)
    UNION
    SELECT DISTINCT poi.po_id
      FROM public.customer_orders co
      JOIN public.purchase_request_items pri ON pri.source_campaign_id = co.campaign_id
      JOIN public.purchase_order_items poi   ON poi.id = pri.po_item_id
     WHERE co.tenant_id = v_tenant AND co.order_no = ANY (v_nos)
     ORDER BY 1);
  PERFORM 1 FROM public.purchase_orders WHERE id = ANY (v_pos) ORDER BY id FOR UPDATE;   -- 同建撿貨單 :1187
  FOREACH v_po IN ARRAY v_pos LOOP
    PERFORM pg_advisory_xact_lock(hashtext('wave:po:' || v_po::text));                   -- 同建撿貨單 :1201
  END LOOP;
  PERFORM 1 FROM public.picking_waves
   WHERE tenant_id = v_tenant AND status NOT IN ('shipped', 'cancelled')
   ORDER BY id FOR UPDATE;                                                                -- 同派車／加品項／改撿貨量

  -- ── 2. 萬華、中和：店名各剛好 1 家 ──
  v_cnt := (SELECT count(*) FROM public.stores WHERE tenant_id = v_tenant AND name LIKE '%萬華%');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】店名含「萬華」的店查到 % 家（要剛好 1 家）。什麼都沒改。', v_cnt;
  END IF;
  v_cnt := (SELECT count(*) FROM public.stores WHERE tenant_id = v_tenant AND name LIKE '%中和%');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】店名含「中和」的店查到 % 家（要剛好 1 家）。什麼都沒改。', v_cnt;
  END IF;
  v_old     := (SELECT id FROM public.stores WHERE tenant_id = v_tenant AND name LIKE '%萬華%');
  v_old_loc := (SELECT location_id FROM public.stores WHERE id = v_old);
  v_new     := (SELECT id FROM public.stores WHERE tenant_id = v_tenant AND name LIKE '%中和%');
  IF NOT EXISTS (SELECT 1 FROM public.stores WHERE id = v_new AND is_active) THEN
    RAISE EXCEPTION '【停】中和店不是啟用中。什麼都沒改。';
  END IF;
  IF v_home IS DISTINCT FROM v_new THEN
    RAISE EXCEPTION '【停】這位會員的綁定店不是中和（請先確認會員資料）。什麼都沒改。';
  END IF;

  -- ── 3. 4 張單鎖住（防同時有人在改），並確認都找得到 ──
  v_ids := ARRAY(
    SELECT co.id FROM public.customer_orders co
     WHERE co.tenant_id = v_tenant AND co.order_no = ANY (v_nos)
     ORDER BY co.id
       FOR UPDATE);
  IF coalesce(array_length(v_ids, 1), 0) <> array_length(v_nos, 1) THEN
    RAISE EXCEPTION '【停】% 張訂單只找到 % 張。什麼都沒改。', array_length(v_nos, 1), coalesce(array_length(v_ids, 1), 0);
  END IF;
  PERFORM 1 FROM public.customer_order_items WHERE order_id = ANY (v_ids) ORDER BY id FOR UPDATE;

  -- ── 4. 重貼判斷 ──
  v_at_old := (SELECT count(*) FROM public.customer_orders
                WHERE id = ANY (v_ids) AND pickup_store_id = v_old);
  -- 「已經做過」只認：取貨店是中和、而且備註最後一行就是 02 寫的那一行（萬華 → 中和＋本次那句）
  v_at_new := (SELECT count(*) FROM public.customer_orders
                WHERE id = ANY (v_ids) AND pickup_store_id = v_new
                  AND substring(coalesce(notes, '') FROM '[^\n]*$')
                      ~ ('^\[改取貨店\] 門市 #' || v_old || ' → #' || v_new
                         || '（\d{4}-\d{2}-\d{2} \d{2}:\d{2}）' || c_tag || '$'));
  IF v_at_new = array_length(v_ids, 1) THEN
    RAISE NOTICE '已經做過：% 張都已經在中和取貨，這次什麼都沒改。', v_at_new;
    RETURN;
  END IF;
  IF v_at_old <> array_length(v_ids, 1) THEN
    RAISE EXCEPTION '【停】% 張裡只有 % 張取貨店還是萬華（% 張已是本次改過的中和），狀態不一致。什麼都沒改，請截圖給 CEO。',
      array_length(v_ids, 1), v_at_old, v_at_new;
  END IF;

  -- ── 5. 逐張檢查 ──
  FOR r IN
    SELECT co.*, g.owner_store_id
      FROM public.customer_orders co
      JOIN public.group_buy_campaigns g ON g.id = co.campaign_id
     WHERE co.id = ANY (v_ids)
     ORDER BY co.order_no
  LOOP
    IF r.member_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM public.members m
          WHERE m.id = r.member_id AND (m.id = v_member OR m.merged_into_member_id = v_member)) THEN
      RAISE EXCEPTION '【停】訂單 % 不是這位會員（或他合併進來的舊編號）的。什麼都沒改。', r.order_no;
    END IF;
    IF r.status NOT IN ('pending', 'confirmed') THEN
      RAISE EXCEPTION '【停】訂單 % 狀態是 %（要 待確認 pending／已確認 confirmed）。什麼都沒改。', r.order_no, r.status;
    END IF;
    IF coalesce(r.order_kind, 'normal') <> 'normal' THEN
      RAISE EXCEPTION '【停】訂單 % 不是一般團購單（%）。什麼都沒改。', r.order_no, r.order_kind;
    END IF;
    IF r.owner_store_id IS NOT NULL THEN
      RAISE EXCEPTION '【停】訂單 % 是門市自己開的團。什麼都沒改。', r.order_no;
    END IF;
    IF r.transferred_from_order_id IS NOT NULL THEN
      RAISE EXCEPTION '【停】訂單 % 是別張單轉來的。什麼都沒改。', r.order_no;
    END IF;
    IF r.is_air_transfer OR r.aid_board_id IS NOT NULL THEN
      RAISE EXCEPTION '【停】訂單 % 是空中轉／互助單。什麼都沒改。', r.order_no;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.customer_order_items WHERE order_id = r.id)
       OR EXISTS (SELECT 1 FROM public.customer_order_items WHERE order_id = r.id AND status <> 'pending') THEN
      RAISE EXCEPTION '【停】訂單 % 的品項不是全部「等貨中」。什麼都沒改。', r.order_no;
    END IF;
    IF (SELECT string_agg((e ->> 'sku_code') || '×' || ((e ->> 'qty')::numeric)::numeric(18,1), '；'
                          ORDER BY e ->> 'sku_code', (e ->> 'qty')::numeric)
          FROM jsonb_array_elements(c_want) e WHERE e ->> 'order_no' = r.order_no)
       IS DISTINCT FROM
       (SELECT string_agg(s.sku_code || '×' || x.qty::numeric(18,1), '；' ORDER BY s.sku_code, x.qty)
          FROM public.customer_order_items x JOIN public.skus s ON s.id = x.sku_id
         WHERE x.order_id = r.id) THEN
      RAISE EXCEPTION '【停】訂單 % 的品項跟 10/31 確認的不一樣。什麼都沒改。', r.order_no;
    END IF;
    IF EXISTS (
         SELECT 1 FROM public.transfers t
          WHERE t.tenant_id = r.tenant_id AND t.status <> 'cancelled'
            AND (t.customer_order_id = r.id
                 OR (t.dest_location = v_old_loc
                     AND t.created_at >= r.created_at
                     AND EXISTS (SELECT 1 FROM public.transfer_items ti
                                  JOIN public.customer_order_items x ON x.sku_id = ti.sku_id AND x.order_id = r.id
                                 WHERE ti.transfer_id = t.id)))) THEN
      RAISE EXCEPTION '【停】訂單 % 有派車單（綁這張單、或下單後派往萬華含同商品，沒取消的）。什麼都沒改。', r.order_no;
    END IF;
    IF EXISTS (
         SELECT 1 FROM public.picking_wave_items pwi
           JOIN public.picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
           JOIN public.customer_order_items x ON x.sku_id = pwi.sku_id AND x.order_id = r.id
          WHERE pwi.tenant_id = r.tenant_id
            AND pwi.campaign_id = r.campaign_id
            AND pwi.store_id = v_old) THEN
      RAISE EXCEPTION '【停】訂單 % 這一團這商品，總倉撿貨單上已經排了萬華那一列。什麼都沒改，請截圖給 CEO。', r.order_no;
    END IF;
  END LOOP;

  -- ── 6. 改之前先記下整列（驗算用）──
  v_before  := (SELECT jsonb_object_agg(id, to_jsonb(co) - 'pickup_store_id' - 'notes' - 'updated_at')
                  FROM public.customer_orders co WHERE id = ANY (v_ids));
  v_items_b := (SELECT jsonb_object_agg(id, to_jsonb(x))
                  FROM public.customer_order_items x WHERE order_id = ANY (v_ids));

  -- 寫入前再確認一次：會員綁定店仍是中和（會員列已鎖，正常不會變）
  IF (SELECT home_store_id FROM public.members WHERE id = v_member) IS DISTINCT FROM v_new THEN
    RAISE EXCEPTION '【停】這位會員的綁定店已經不是中和。什麼都沒改。';
  END IF;

  -- ── 7. 改取貨店＋備註留痕（格式同 20260829000020:466-469）──
  v_line := E'\n[改取貨店] 門市 #' || v_old || ' → #' || v_new
            || '（' || to_char(v_now AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI') || '）' || c_tag;
  UPDATE public.customer_orders
     SET pickup_store_id = v_new,
         notes           = coalesce(notes, '') || v_line,
         updated_at      = v_now
   WHERE id = ANY (v_ids)
     AND pickup_store_id = v_old
     AND status IN ('pending', 'confirmed');
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  IF v_cnt <> array_length(v_ids, 1) THEN
    RAISE EXCEPTION '【停】只改到 % 張（要 % 張），整筆退回、什麼都沒改。', v_cnt, array_length(v_ids, 1);
  END IF;

  -- ── 8. 自我驗算 ──
  v_after   := (SELECT jsonb_object_agg(id, to_jsonb(co) - 'pickup_store_id' - 'notes' - 'updated_at')
                  FROM public.customer_orders co WHERE id = ANY (v_ids));
  v_items_a := (SELECT jsonb_object_agg(id, to_jsonb(x))
                  FROM public.customer_order_items x WHERE order_id = ANY (v_ids));
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION '【停】驗算不過：訂單除了取貨店／備註／修改時間，還有別的欄位變了。整筆退回。';
  END IF;
  IF v_items_a IS DISTINCT FROM v_items_b THEN
    RAISE EXCEPTION '【停】驗算不過：品項有變動。整筆退回。';
  END IF;
  v_cnt := (SELECT count(*) FROM public.customer_orders
             WHERE id = ANY (v_ids) AND pickup_store_id = v_new AND right(notes, length(v_line)) = v_line);
  IF v_cnt <> 4 OR array_length(v_ids, 1) <> 4 THEN
    RAISE EXCEPTION '【停】驗算不過：改到中和的只有 % 張（要剛好 4 張）。整筆退回。', v_cnt;
  END IF;
  v_cnt := (SELECT count(*) FROM public.customer_orders
             WHERE updated_at = v_now AND NOT (id = ANY (v_ids)) AND tenant_id = v_tenant);
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '【停】驗算不過：這一刻還有 % 張別的單被改到。整筆退回。', v_cnt;
  END IF;

  RAISE NOTICE '完成：4 張訂單取貨店 萬華 → 中和（備註已加一行）。接著貼 03 確認。';
END
$pickup_move$;

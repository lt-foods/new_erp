-- ============================================================================
--  03 通知客人（可選；✅ 會寫入：在會員 App 通知中心留一則訊息）
--  契爾氏化妝水（G02596-01）被 02 取消的品項，對每位會員發一則「商品斷貨通知」（同一位會員只發一則）
--  日期：2026-10-21　阿寫寫、⛔ 阿審（Codex）審過之前不要貼
--  要不要貼由老闆決定（需求暨計畫第 4 節）；⛔ 一定要在 02 之後
-- ============================================================================
--  ★ 這份在做什麼（整份只有一個 DO 區塊＝同一次）
--    ① 先檢查：02 做過、而且那 26 筆現在都還是 02 取消的樣子（沒被還原、沒被別人改）；不然【停】，一則都不發
--    ② 已經發過（這一批會員在 02 之後已經收過這一則）→ 顯示「已經發過，這次什麼都沒發」然後結束；重貼不會重發
--    ⇒ 只發給「02 取消的品項」的會員：認法是 02 寫的那一句原因＋品項斷貨時間＝02 那一刻；
--      松山那筆是老闆 10/21 手動刪除品項取消的（原因不同、沒有斷貨時間）→ 不會發給那位客人
--    ③ 照斷貨 (d) 段（_stockout_po_items 20260902000010:377-396）逐字同一種寫法發：
--       類別 stockout、標題「商品斷貨通知」、
--       內容「您訂購的「<商品名-規格>」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。」、
--       點了開「我的訂單」(/orders)；同一位會員一則；沒綁會員的訂單發不了（同 (d) 段 :392）
--  ★ 會不會推 LINE？—— 不會（程式碼紀錄查證；正式系統另由 01 第⑤段實查）
--    ・notifications 這張表只有表本身、兩個索引、權限規則，⛔ 沒有任何觸發器：
--      supabase/migrations/20260604000000_notifications.sql:8-47（全檔）；
--      全部 migration 逐檔找 CREATE TRIGGER … ON notifications ＝ 0 支。
--    ・會推到手機的只有 Edge Function admin-notify：它自己先寫一筆通知、再自己對
--      push_subscriptions 發網頁推播（supabase/functions/admin-notify/index.ts:81-125、:139-165），
--      那是後台按鈕呼叫的；這份直接寫表，不會經過它 ⇒ 不推播、也不是 LINE 訊息。
--    ・會員 App 只是讀這張表（supabase/functions/liff-api/index.ts:1576-1586 列表、:1866 入口）。
--    ・斷貨本來的 (d) 段也是直接寫表（20260902000010:378-395），客人看到的跟平常斷貨完全一樣。
--    ⇒ 結論：這份只會在會員 App 的「通知」頁多一則、未讀數 +1；不會發 LINE、不會推手機。
--      ⚠ 正式系統若有人從後台另外掛過觸發器／資料庫 webhook，程式碼紀錄看不到 → 貼之前先看 01 第⑤段那一列是 ✅。
--  ★ ⛔ 不動：訂單、品項、庫存、派車單、採購單、月結（這份只新增通知）
--  ★ 發出去就收不回來（05 還原也不會刪通知）。
--  ★ 看到什麼要停：紅字【停】→ 一則都沒發，截圖給 CEO；⛔ 不要重貼
-- ============================================================================

DO $kiehls_notify$
DECLARE
  c_campaign_no   CONSTANT text := 'GRP-20260910-027';
  c_sku_code      CONSTANT text := 'G02596-01';
  -- ⛔ 跟 02 逐字相同，不要改字
  c_tag_item      CONSTANT text := '契爾氏化妝水叫錯款式、廠商沒有正確款：2026-10-21 老闆核准批次取消';
  c_title         CONSTANT text := '商品斷貨通知';
  v_tenant        uuid;
  v_campaign      bigint;
  v_sku           bigint;
  v_t0            timestamptz;
  v_items         bigint[];
  v_cnt           int;
  v_marked        int;
  v_body          text;
  v_sent          int;
  v_no_member     int;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  -- ── 1. 對象 ──
  SELECT count(*) INTO v_cnt FROM public.group_buy_campaigns WHERE campaign_no = c_campaign_no;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】團號 % 在系統裡查到 % 個（要剛好 1 個）。一則都沒發，請截圖給 CEO。', c_campaign_no, v_cnt;
  END IF;
  SELECT id, tenant_id INTO v_campaign, v_tenant FROM public.group_buy_campaigns WHERE campaign_no = c_campaign_no;
  SELECT count(*) INTO v_cnt FROM public.skus WHERE sku_code = c_sku_code AND tenant_id = v_tenant;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】商品碼 % 在這家公司查到 % 個（要剛好 1 個）。一則都沒發，請截圖給 CEO。', c_sku_code, v_cnt;
  END IF;
  SELECT id INTO v_sku FROM public.skus WHERE sku_code = c_sku_code AND tenant_id = v_tenant;

  -- ── 2. 02 做過了沒：取最近一次 02 的時間 ──
  SELECT max(a.created_at) INTO v_t0
    FROM public.customer_order_audit_log a
    JOIN public.customer_order_items i ON i.id = a.entity_id
    JOIN public.customer_orders co ON co.id = i.order_id
   WHERE a.entity_type = 'item' AND a.field = 'status' AND a.edit_reason = c_tag_item
     AND co.campaign_id = v_campaign AND i.sku_id = v_sku;
  IF v_t0 IS NULL THEN
    RAISE EXCEPTION '【停】還沒貼 02（找不到 02 留下的編輯歷史），不能發通知。一則都沒發。';
  END IF;

  SELECT count(*) INTO v_marked
    FROM public.customer_order_audit_log a
    JOIN public.customer_order_items i ON i.id = a.entity_id
    JOIN public.customer_orders co ON co.id = i.order_id
   WHERE a.entity_type = 'item' AND a.field = 'status' AND a.edit_reason = c_tag_item AND a.created_at = v_t0
     AND co.campaign_id = v_campaign AND i.sku_id = v_sku;

  -- 那一次取消的品項，現在還是那一次取消的樣子（已取消、斷貨時間＝那一次）；鎖住避免同時有人還原
  BEGIN
    SELECT array_agg(i.id ORDER BY i.id) INTO v_items
      FROM (SELECT x.id
              FROM public.customer_order_items x
              JOIN public.customer_orders co ON co.id = x.order_id
             WHERE co.campaign_id = v_campaign AND x.sku_id = v_sku
               AND x.status = 'cancelled' AND x.stockout_at = v_t0
               AND EXISTS (SELECT 1 FROM public.customer_order_audit_log a
                            WHERE a.order_id = x.order_id AND a.entity_type = 'item' AND a.entity_id = x.id
                              AND a.field = 'status' AND a.edit_reason = c_tag_item AND a.created_at = v_t0)
             ORDER BY x.id
               FOR SHARE OF x) i;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION '【停】有人正在操作這幾張訂單，等了 15 秒還拿不到。一則都沒發，請過幾分鐘再貼一次。';
  END;
  v_cnt := COALESCE(array_length(v_items, 1), 0);
  IF v_cnt = 0 THEN
    RAISE EXCEPTION '【停】02 取消的品項現在都不是取消狀態了（可能已經用 05 還原）。一則都沒發，請截圖給 CEO。';
  END IF;
  IF v_cnt <> v_marked THEN
    RAISE EXCEPTION '【停】02 那一次取消了 % 筆，現在只剩 % 筆還是那時候的樣子（有人動過）。一則都沒發，請截圖給 CEO。', v_marked, v_cnt;
  END IF;

  -- ── 3. 通知內容（寫法逐字同斷貨 (d) 段 20260902000010:383-388）──
  SELECT '您訂購的「' || string_agg(DISTINCT COALESCE(sk.product_name, sk.sku_code)
                                     || COALESCE('-' || sk.variant_name, ''), '、')
         || '」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。'
    INTO v_body
    FROM public.customer_order_items x
    JOIN public.skus sk ON sk.id = x.sku_id
   WHERE x.id = ANY (v_items);

  -- ── 4. 發過了沒（重貼不重發）：這批會員在 02 之後已經有這一則 ──
  SELECT count(*) INTO v_sent
    FROM public.notifications n
   WHERE n.tenant_id = v_tenant
     AND n.category = 'stockout' AND n.title = c_title AND n.body = v_body
     AND n.created_at >= v_t0
     AND n.member_id IN (SELECT co.member_id
                           FROM public.customer_order_items x
                           JOIN public.customer_orders co ON co.id = x.order_id
                          WHERE x.id = ANY (v_items) AND co.member_id IS NOT NULL);
  IF v_sent > 0 THEN
    RAISE NOTICE '已經發過（02 之後這批會員已經有 % 則同樣的通知），這次什麼都沒發。', v_sent;
    RETURN;
  END IF;

  -- ── 5. 發（同斷貨 (d) 段：一位會員一則、只發綁了會員的訂單）──
  INSERT INTO public.notifications (tenant_id, member_id, category, title, body, url)
  SELECT co.tenant_id,
         co.member_id,
         'stockout',
         c_title,
         '您訂購的「' || string_agg(DISTINCT COALESCE(sk.product_name, sk.sku_code)
                                     || COALESCE('-' || sk.variant_name, ''), '、')
           || '」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。',
         '/orders'
    FROM public.customer_order_items x
    JOIN public.customer_orders co ON co.id = x.order_id
    JOIN public.skus sk ON sk.id = x.sku_id
   WHERE x.id = ANY (v_items)
     AND co.member_id IS NOT NULL
   GROUP BY co.tenant_id, co.member_id;
  GET DIAGNOSTICS v_sent = ROW_COUNT;

  SELECT count(*) INTO v_no_member
    FROM public.customer_order_items x
    JOIN public.customer_orders co ON co.id = x.order_id
   WHERE x.id = ANY (v_items) AND co.member_id IS NULL;

  RAISE NOTICE '✅ 完成：發了 % 則通知（一位會員一則）；沒綁會員、發不到的品項 % 筆。請接著貼 04 看「通知」那一列。', v_sent, v_no_member;
END $kiehls_notify$;

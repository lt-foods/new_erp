-- ============================================================================
-- 2026-10-16: 派車照「採購單成立時」各店數量派 —— 叫貨後才取消的件數照派原店
--             （丙／輕量做法；記號 post_po_cancel_to_store:20261016000000）
--
-- 問題：派貨工作台每家店要派幾件，是照「客人現在還有效的訂單」算。叫貨（採購單成立）之後
--   才被取消的件數，貨到了會留在總倉，工作台也不會提醒。
--   實例：2026-10-14 某團某商品採購 133、工作台只帶 132（一張單在叫貨後 10 小時才被取消）。
--
-- 規則（2026-10-15 老闆定案）：
--   叫貨後才取消的件數，派車時照樣派回原本那家店（到店後多的會自動進該店【內部】，月結照算）。
--   停用的店不帶，那幾件留在工作台讓總倉決定。
--   只對「上線當天起才成立」的採購單品項套用（分界時間＝_picking_po_rule_cutover()），
--   舊採購單一個數字都不變。
--
-- 什麼叫「叫貨後才取消」（v_picking_post_po_cancelled，一列＝一個訂單品項）：
--   1. 這一團、這樣商品剛好只連到 **1 個** 有效採購單品項（已發送／部分到貨／全部到貨；
--      連法逐字照派貨表的 po_skus／po_campaigns）。2 個以上＝#1082 管的「一團多張」，不套。
--   2. 那個採購單品項的建立時間（＝叫貨那一刻）≥ 分界時間。
--   3. 訂單品項在叫貨前就有（品項建立時間 ≤ 叫貨時間）。
--   4. 不是轉入單（transferred_from_order_id IS NULL；轉入單被取消會還原來源單）、
--      訂單與品項都沒有斷貨標記（stockout_at）。
--   5. （整張取消、取消時間晚於叫貨、品項本身沒有取消／過期）
--      或（品項被刪、編輯歷史有一筆「狀態→取消」晚於叫貨、訂單不是轉出）。
--   6. 這張訂單在叫貨之後沒有「復原取消」過（rpc_restore_cancelled_order 寫的編輯歷史：
--      單頭、狀態、cancelled → 有效）。有的話照今天、不照派（保守：取消時間會被覆寫，
--      分不出第一次取消是在叫貨前還是叫貨後，寧可少派、不多派）。
--
-- 本檔改了什麼（照實作計畫第五節 A1～A10）：
--   A1  purchase_request_store_additions 加一欄 po_delta_qty（採購單實際加幾件；舊列空著）
--   A2  新增 _picking_po_rule_cutover()：分界時間（一鍵關掉＝改成回 'infinity'）
--   A3  新增 view v_picking_po_rule_items：哪些（採購單品項, 團, 商品）套新規則
--   A4  新增 view v_picking_post_po_cancelled：叫貨後才取消的訂單品項
--   A5  重建 v_picking_demand_by_po（派貨工作台那張表）
--   A6  重建 rpc_create_wave_from_po（建撿貨單）
--   A7  重建 rpc_add_po_store_demands（採購單頁「分店／批發追加」寫入）
--   A8  新增唯讀 rpc_preview_po_store_addition_extra(p_po_id)：分店追加預估要用的 R、E、rule_applies（A7 也讀它）
--   A9  新增唯讀 rpc_order_cancel_po_notice(p_order_id, p_item_id)
--   A14 新增唯讀 rpc_picking_post_po_cancelled_by_sku(p_sku_ids)：派貨工作台（B1）要顯示的叫貨後取消件數
--   A10 權限（寫在每一組裡，見「安全性」）
--
-- ⚠️ 三支重建都以「正式庫現在那一版」逐字為底（2026-10-15 CEO 核對查詢 31 列全 ✅），
--    **不是**程式碼紀錄最新那一版：
--   A5 派貨表：以 20260818000030:61-267 逐字為底，只在 store_demand 的 UNION ALL
--      多一段（叫貨後才取消、店沒停用的件數）。欄位、順序、型別完全不變
--      （v_hq_exceptions 依賴它，所以用 CREATE OR REPLACE，不 DROP）。
--   A6 建撿貨單：以 20260816000050:268 再套 20260923110000 的總倉封頂（動態插入）後的內文
--      逐字為底（內文指紋 ea371af8434804c43a043334602f4205），只加兩處：
--        ① 4.5 借調判斷：叫貨後取消照派的店不算借調；
--        ② 第 6 步挑團：原本那句完全不動，它找不到團時，才用叫貨後取消的那一團。
--      停用店兩處都不放行 ⇒ 照樣被「不能撿到這批貨」擋下。
--   A7 分店追加：以 20261002000000:794 逐字為底（內文指紋 220befc9d94d5e1c0aab37f41b627612）：
--        請購 +X（X＝max(差額, 0)，跟改前一模一樣）；
--        採購單：套新規則的採購單品項 +max(0, 差額 + R − E)（R＝叫貨後才取消的件數，
--        E＝以前追加時採購單比請購多加的件數；⚠️ 可能比請購加得少），不套的 +X（同改前）；
--        套不套＝A8 回的 rule_applies（畫面預估讀同一欄）；差額、R、E、套不套在同一句讀（同一個時間點）。
--   ⚠️ 程式碼紀錄裡派貨表與建撿貨單最新是 20260908000000（#917「短撿只扣實撿」），
--      但正式庫從來沒套上那一版。本檔以正式庫為底重建 ⇒ **等於在程式碼紀錄上把 #917 這兩支退回**。
--      #917 要上請另案，而且要以本檔為底（直接重貼 20260908000000 會把本檔蓋掉）。
--   ⚠️ 重貼 20260816000050／20260818000030／20260908000000／20261002000000 都會把本檔改的那支蓋回去，
--      貼完確認查詢的指紋會變 ❌。
--
-- 不改：v_picking_multi_po_campaigns（#1082）、rpc_preview_po_store_additions、
--   _po_item_store_add_block_reason、_store_add_internal_order_item、
--   _pr_campaign_sku_remaining_rows（差額）、請購防重守衛、rpc_cancel_aid_order、
--   rpc_delete_order_item、斷貨／確定斷貨、撿貨草稿與前端算法。
--
-- 已知限制（丙做不到、照今天）：
--   叫貨後新開的單、加在既有品項上的叫貨後加量、叫貨後改少數量；一團多張採購單；
--   請購草稿到轉採購之間取消的；取消路徑沒寫取消時間的；
--   叫貨後取消過又復原、之後再取消的（條件 6：照今天留總倉）。
--
-- 安全性：
--   - 0 段前置檢查放在所有改動之前、只讀（只建暫存 view 比對、用完就丟），
--     任何一項不符整份停下、一行都不改。整份可以重貼（第二次結果一樣）。
--   - 中途斷線也能重貼：每一組永久改動（建立／改欄位＋說明＋權限）各包在自己的小交易
--     （BEGIN … COMMIT）裡。斷在一組中間＝那一組整組沒做；做完的組都帶本檔記號，
--     前置檢查認得，整份重貼就會接著做完，結果跟一次貼完一樣。
--   - 兩支新 view 不給任何前端角色讀（收回 PUBLIC／anon／authenticated，不另外授權）：
--     派貨表、建撿貨單、分店追加、兩支只讀查詢都是用擁有者身分讀它們，登入後台的人讀派貨表照常。
--     前端要顯示的資料走 A14（有 _current_tenant_id() 租戶檢查，只回自己公司的、只到「採購單品項 × 店」）。
--   - _picking_po_rule_cutover()：收回 PUBLIC／anon，只給 authenticated 執行。
--     ⚠️ authenticated 不能收回：view 裡呼叫的函式是用「讀 view 的人」的權限執行的，
--     收回會讓派貨工作台整個讀不出來。它只回一個時間。
--   - 新函式一律收回 PUBLIC／anon、只給 authenticated；建立和收回在同一個交易裡，
--     不會有「建好了但還沒收回權限」的空檔。
--
-- 上線順序：先貼本檔 → 貼確認查詢全 ✅（含「舊數字不變」0 筆）→ 再合併前端。
-- 還原：scripts/PROD-post-po-cancel-2026-10/rollback_20261016000000.sql
-- 一鍵關掉：scripts/PROD-post-po-cancel-2026-10/kill_switch_20261016000000.sql
-- 確認：scripts/PROD-post-po-cancel-2026-10/postcheck_readonly.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有改動之前、只讀。任何一項不符就整份停下，一行都不會執行。
--    （SQL Editor 是自動提交、沒有交易保護，所以一定要先查完再動。）
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  l_missing   TEXT[] := ARRAY[]::TEXT[];
  l_bad       TEXT[] := ARRAY[]::TEXT[];
  l_name      TEXT;
  l_rec       RECORD;
  l_oid       REGCLASS;
  l_kind      "char";
  l_note      TEXT;
  l_live      TEXT;
  l_def_0818  TEXT;
  l_def_new   TEXT;
  l_sig       TEXT;
  l_type      TEXT;
BEGIN
  -- (a) 新規則與三支重建會讀到的欄位
  FOREACH l_name IN ARRAY ARRAY[
    'purchase_orders.id', 'purchase_orders.tenant_id', 'purchase_orders.po_no', 'purchase_orders.status',
    'purchase_order_items.id', 'purchase_order_items.po_id', 'purchase_order_items.sku_id',
    'purchase_order_items.created_at',
    'purchase_request_items.id', 'purchase_request_items.po_item_id', 'purchase_request_items.pr_id',
    'purchase_request_items.source_campaign_id',
    'purchase_request_campaigns.pr_id', 'purchase_request_campaigns.campaign_id',
    'purchase_request_store_additions.tenant_id', 'purchase_request_store_additions.pr_item_id',
    'purchase_request_store_additions.campaign_id', 'purchase_request_store_additions.request_key',
    'purchase_request_store_additions.pr_delta_qty',
    'customer_orders.id', 'customer_orders.tenant_id', 'customer_orders.campaign_id',
    'customer_orders.pickup_store_id', 'customer_orders.status', 'customer_orders.cancelled_at',
    'customer_orders.stockout_at', 'customer_orders.transferred_from_order_id',
    'customer_order_items.id', 'customer_order_items.tenant_id', 'customer_order_items.order_id', 'customer_order_items.sku_id',
    'customer_order_items.qty', 'customer_order_items.status', 'customer_order_items.stockout_at',
    'customer_order_items.created_at',
    'customer_order_audit_log.order_id', 'customer_order_audit_log.entity_type',
    'customer_order_audit_log.entity_id', 'customer_order_audit_log.field',
    'customer_order_audit_log.before_value', 'customer_order_audit_log.after_value',
    'customer_order_audit_log.created_at',
    'stores.id', 'stores.is_active', 'stores.deleted_at',
    'skus.id', 'skus.sku_code', 'skus.product_name', 'skus.variant_name'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_attribute a
       WHERE a.attrelid = to_regclass('public.' || split_part(l_name, '.', 1))
         AND a.attname = split_part(l_name, '.', 2)
         AND a.attnum > 0
         AND NOT a.attisdropped
    ) THEN
      l_missing := l_missing || ('欄位 public.' || l_name);
    END IF;
  END LOOP;

  -- 編輯歷史表要能記「狀態」（刪品項靠它判斷叫貨前還是叫貨後刪的）
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = to_regclass('public.customer_order_audit_log')
       AND con.contype = 'c'
       AND position('''status''' IN pg_get_constraintdef(con.oid)) > 0
  ) THEN
    l_missing := l_missing || '編輯歷史表 customer_order_audit_log 不能記 status'::TEXT;
  END IF;

  -- 依賴的既有函式（只呼叫、不改）
  FOREACH l_name IN ARRAY ARRAY['_current_tenant_id', '_pr_qty_sync_assert_perm',
                                '_pr_campaign_sku_remaining_rows'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
                    WHERE ns.nspname = 'public' AND p.proname = l_name) THEN
      l_missing := l_missing || ('函式 public.' || l_name);
    END IF;
  END LOOP;

  IF array_length(l_missing, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。缺少：\n%', array_to_string(l_missing, E'\n');
  END IF;

  -- (b) 依賴、不改的東西必須還是 2026-10-15 核對時那一版（內文指紋＝去掉 \r 後的 md5）
  FOR l_rec IN
    SELECT *
      FROM (VALUES
        ('_pr_campaign_sku_remaining_rows',         '4aaf0580a56116103f4e9d9b9007f3aa', '請購差額共用算法'),
        ('trg_guard_pr_cross_close_date_duplicate', 'b7fa7cc5000eb6402e9828d0f4aa1907', '請購防重守衛'),
        ('rpc_cancel_aid_order',                    '1a0c16fd1487ee73f5bcec9180d6d899', '整張取消訂單'),
        ('rpc_delete_order_item',                   '863fce5a95cfff155a576cdb245c22c3', '刪除單一品項'),
        ('_stockout_po_items',                      '4cb2e5d5402f3dfd4e64bcd24c345eae', '斷貨'),
        ('rpc_cancel_backorder_items',              '4ba8264266bb6a482c8d9707ac92b7d1', '確定斷貨並通知')
      ) AS x(fn, sig, label)
  LOOP
    l_sig := (SELECT string_agg(md5(replace(p.prosrc, chr(13), '')), ',' ORDER BY p.oid)
                FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
               WHERE ns.nspname = 'public' AND p.proname = l_rec.fn);
    IF l_sig IS DISTINCT FROM l_rec.sig THEN
      l_bad := l_bad || (l_rec.label || '（' || l_rec.fn || '）指紋 ' || COALESCE(l_sig, '找不到')
                         || '，核對時是 ' || l_rec.sig);
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM pg_trigger
       WHERE NOT tgisinternal
         AND tgname IN ('trg_pri_cross_close_date_duplicate_guard', 'trg_prc_cross_close_date_duplicate_guard',
                        'trg_pric_cross_close_date_duplicate_guard')) <> 3 THEN
    l_bad := l_bad || '請購防重守衛的三個觸發器沒有全部掛著'::TEXT;
  END IF;

  l_oid := to_regclass('public.v_picking_multi_po_campaigns');
  IF l_oid IS NULL
     OR position('picking_multi_po_campaigns:20261015000000' IN COALESCE(obj_description(l_oid, 'pg_class'), '')) = 0 THEN
    l_bad := l_bad || '#1082 的檢查表 v_picking_multi_po_campaigns 不在、或不是 #1082 那一版'::TEXT;
  END IF;

  -- (c) 三支要重建的：現況必須是「改前（正式庫 10/15 那一版）」或「本檔新版」（重貼）
  l_sig := (SELECT string_agg(md5(replace(p.prosrc, chr(13), '')), ',' ORDER BY p.oid)
              FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public' AND p.proname = 'rpc_create_wave_from_po');
  IF l_sig IS NULL OR l_sig NOT IN ('ea371af8434804c43a043334602f4205', 'cb6be9654963d06a9a4e06ca12ca471a') THEN
    l_bad := l_bad || ('建撿貨單 rpc_create_wave_from_po 不是改前也不是本檔新版：' || COALESCE(l_sig, '找不到'));
  END IF;

  l_sig := (SELECT string_agg(md5(replace(p.prosrc, chr(13), '')), ',' ORDER BY p.oid)
              FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public' AND p.proname = 'rpc_add_po_store_demands');
  IF l_sig IS NULL OR l_sig NOT IN ('220befc9d94d5e1c0aab37f41b627612', '99cbf151f1d46e251dca72ca28e71a6c') THEN
    l_bad := l_bad || ('分店追加 rpc_add_po_store_demands 不是改前也不是本檔新版：' || COALESCE(l_sig, '找不到'));
  END IF;

  -- 派貨表：在這一台資料庫上用暫存 view 把「改前原文」「本檔新版原文」各建一次，
  -- 拿正式的 pg_get_viewdef 跟兩者逐字比（同一台的印法一致）。暫存 view 用完就丟。
  l_live := pg_get_viewdef(to_regclass('public.v_picking_demand_by_po'), true);
  EXECUTE $ppc0818$CREATE TEMP VIEW ppc_chk_demand_0818 AS
WITH po_skus AS (
         SELECT po.id AS po_id,
            po.tenant_id,
            po.po_no,
            po.status AS po_status,
            po.supplier_id,
            poi.id AS po_item_id,
            poi.sku_id,
            poi.qty_ordered,
            (EXISTS ( SELECT 1
                   FROM purchase_request_items pri2
                     JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
                  WHERE pri2.po_item_id = poi.id)) AS is_restock_sourced
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text])
        ), gr_qty AS (
         SELECT gri.po_item_id,
            sum(gri.qty_received) AS gr_qty
           FROM goods_receipt_items gri
             JOIN goods_receipts gr ON gr.id = gri.gr_id
          WHERE gr.status = 'confirmed'::text
          GROUP BY gri.po_item_id
        ), po_campaigns AS (
         SELECT DISTINCT u.po_item_id,
            u.campaign_id
           FROM ( SELECT poi.id AS po_item_id,
                    prc.campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                     JOIN purchase_requests pr ON pr.id = pri.pr_id
                     JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
                UNION
                 SELECT poi.id AS po_item_id,
                    pri.source_campaign_id AS campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                  WHERE pri.source_campaign_id IS NOT NULL) u
        ), po_campaign_po AS (
         SELECT DISTINCT poi.po_id,
            pc0.campaign_id
           FROM po_campaigns pc0
             JOIN purchase_order_items poi ON poi.id = pc0.po_item_id
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR (EXISTS ( SELECT 1
                   FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id AND src.pickup_store_id = co.pickup_store_id)))
             JOIN customer_order_items coi ON coi.order_id = co.id AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
             JOIN purchase_order_items poi ON poi.id = pc.po_item_id AND poi.sku_id = coi.sku_id
          GROUP BY pc.po_item_id, co.pickup_store_id
        ), restock_demand AS (
         SELECT poi.id AS po_item_id,
            rr.requesting_store_id AS store_id,
            sum(rrl.qty) AS demand_qty
           FROM purchase_order_items poi
             JOIN purchase_request_items pri ON pri.po_item_id = poi.id
             JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id AND (rr.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text]))
             JOIN restock_request_lines rrl ON rrl.request_id = rr.id AND rrl.sku_id = poi.sku_id
          GROUP BY poi.id, rr.requesting_store_id
        ), store_demand AS (
         SELECT u.po_item_id,
            u.store_id,
            sum(u.demand_qty) AS demand_qty
           FROM ( SELECT campaign_demand.po_item_id,
                    campaign_demand.store_id,
                    campaign_demand.demand_qty
                   FROM campaign_demand
                UNION ALL
                 SELECT restock_demand.po_item_id,
                    restock_demand.store_id,
                    restock_demand.demand_qty
                   FROM restock_demand) u
          GROUP BY u.po_item_id, u.store_id
        ), wave_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty) AS wave_qty
           FROM ( SELECT pw.source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_requested
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text
                UNION ALL
                 SELECT pcp.po_id AS source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                     JOIN po_campaign_po pcp ON pcp.campaign_id = pwi.campaign_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL AND pwi.campaign_id IS NOT NULL AND pcp.po_id <> pw.source_po_id AND NOT (EXISTS ( SELECT 1
                           FROM po_campaign_po own
                          WHERE own.po_id = pw.source_po_id AND own.campaign_id = pwi.campaign_id))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        ), po_sku_already_wave AS (
         SELECT u.po_id,
            u.sku_id,
            sum(u.qty) AS already_wave
           FROM ( SELECT pw.source_po_id AS po_id,
                    pwi.sku_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id,
                    ti.sku_id,
                    ti.qty_requested AS qty
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text) u
          GROUP BY u.po_id, u.sku_id
        ), po_sku_demand_left AS (
         SELECT ps_1.po_id,
            ps_1.sku_id,
            sum(GREATEST(0::numeric, COALESCE(sd_1.demand_qty, 0::numeric) - COALESCE(wq_1.wave_qty, 0::numeric))) AS demand_left
           FROM po_skus ps_1
             JOIN store_demand sd_1 ON sd_1.po_item_id = ps_1.po_item_id
             LEFT JOIN wave_qty wq_1 ON wq_1.source_po_id = ps_1.po_id AND wq_1.sku_id = ps_1.sku_id AND wq_1.store_id = sd_1.store_id
          GROUP BY ps_1.po_id, ps_1.sku_id
        ), shipped_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty_received) AS shipped_qty
           FROM ( SELECT pw.source_po_id,
                    ti.sku_id,
                    "substring"(t.transfer_no, 'WAVE-\d+-S(\d+)'::text)::bigint AS store_id,
                    ti.qty_received
                   FROM transfers t
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN picking_waves pw ON pw.id = ("substring"(t.transfer_no, '^WAVE-(\d+)-S'::text))::bigint
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text])) AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_received
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text]))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        )
 SELECT ps.tenant_id,
    ps.po_id,
    ps.po_no,
    ps.po_status,
    ps.supplier_id,
    ps.po_item_id,
    ps.sku_id,
    s.sku_code,
    COALESCE(s.product_name, ''::text) || COALESCE(' '::text || NULLIF(s.variant_name, ''::text), ''::text) AS sku_label,
    ps.qty_ordered,
    COALESCE(g.gr_qty, 0::numeric) AS gr_qty,
        CASE
            WHEN ps.po_status <> 'fully_received'::text THEN GREATEST(0::numeric, ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric))
            ELSE 0::numeric
        END AS qty_in_transit,
        CASE
            WHEN ps.po_status = 'fully_received'::text AND COALESCE(g.gr_qty, 0::numeric) < ps.qty_ordered THEN ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric)
            ELSE 0::numeric
        END AS qty_shortage,
    sd.store_id,
    st.code AS store_code,
    st.name AS store_name,
    COALESCE(sd.demand_qty, 0::numeric) AS demand_qty,
    COALESCE(wq.wave_qty, 0::numeric) AS wave_qty,
    COALESCE(sq.shipped_qty, 0::numeric) AS shipped_qty,
    ps.is_restock_sourced,
    COALESCE(psaw.already_wave, 0::numeric) AS po_sku_already_wave,
    COALESCE(g.gr_qty, 0::numeric) > COALESCE(psaw.already_wave, 0::numeric) AS has_stock_left,
    COALESCE(dl.demand_left, 0::numeric) > 0::numeric AS has_demand_left
   FROM po_skus ps
     JOIN skus s ON s.id = ps.sku_id
     LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
     LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
     LEFT JOIN stores st ON st.id = sd.store_id
     LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
     LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
     LEFT JOIN po_sku_already_wave psaw ON psaw.po_id = ps.po_id AND psaw.sku_id = ps.sku_id
     LEFT JOIN po_sku_demand_left dl ON dl.po_id = ps.po_id AND dl.sku_id = ps.sku_id
  WHERE COALESCE(sq.shipped_qty, 0::numeric) < GREATEST(COALESCE(g.gr_qty, 0::numeric), 1::numeric) AND (COALESCE(g.gr_qty, 0::numeric) > 0::numeric OR COALESCE(sd.demand_qty, 0::numeric) > 0::numeric)$ppc0818$;
  l_def_0818 := pg_get_viewdef(to_regclass('pg_temp.ppc_chk_demand_0818'), true);
  EXECUTE 'DROP VIEW pg_temp.ppc_chk_demand_0818';
  l_def_new := NULL;
  IF to_regclass('public.v_picking_post_po_cancelled') IS NOT NULL THEN
    EXECUTE $ppcnew$CREATE TEMP VIEW ppc_chk_demand_new AS
WITH po_skus AS (
         SELECT po.id AS po_id,
            po.tenant_id,
            po.po_no,
            po.status AS po_status,
            po.supplier_id,
            poi.id AS po_item_id,
            poi.sku_id,
            poi.qty_ordered,
            (EXISTS ( SELECT 1
                   FROM purchase_request_items pri2
                     JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
                  WHERE pri2.po_item_id = poi.id)) AS is_restock_sourced
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text])
        ), gr_qty AS (
         SELECT gri.po_item_id,
            sum(gri.qty_received) AS gr_qty
           FROM goods_receipt_items gri
             JOIN goods_receipts gr ON gr.id = gri.gr_id
          WHERE gr.status = 'confirmed'::text
          GROUP BY gri.po_item_id
        ), po_campaigns AS (
         SELECT DISTINCT u.po_item_id,
            u.campaign_id
           FROM ( SELECT poi.id AS po_item_id,
                    prc.campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                     JOIN purchase_requests pr ON pr.id = pri.pr_id
                     JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
                UNION
                 SELECT poi.id AS po_item_id,
                    pri.source_campaign_id AS campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                  WHERE pri.source_campaign_id IS NOT NULL) u
        ), po_campaign_po AS (
         SELECT DISTINCT poi.po_id,
            pc0.campaign_id
           FROM po_campaigns pc0
             JOIN purchase_order_items poi ON poi.id = pc0.po_item_id
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR (EXISTS ( SELECT 1
                   FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id AND src.pickup_store_id = co.pickup_store_id)))
             JOIN customer_order_items coi ON coi.order_id = co.id AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
             JOIN purchase_order_items poi ON poi.id = pc.po_item_id AND poi.sku_id = coi.sku_id
          GROUP BY pc.po_item_id, co.pickup_store_id
        ), restock_demand AS (
         SELECT poi.id AS po_item_id,
            rr.requesting_store_id AS store_id,
            sum(rrl.qty) AS demand_qty
           FROM purchase_order_items poi
             JOIN purchase_request_items pri ON pri.po_item_id = poi.id
             JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id AND (rr.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text]))
             JOIN restock_request_lines rrl ON rrl.request_id = rr.id AND rrl.sku_id = poi.sku_id
          GROUP BY poi.id, rr.requesting_store_id
        ), store_demand AS (
         SELECT u.po_item_id,
            u.store_id,
            sum(u.demand_qty) AS demand_qty
           FROM ( SELECT campaign_demand.po_item_id,
                    campaign_demand.store_id,
                    campaign_demand.demand_qty
                   FROM campaign_demand
                UNION ALL
                 SELECT restock_demand.po_item_id,
                    restock_demand.store_id,
                    restock_demand.demand_qty
                   FROM restock_demand
                UNION ALL
                 SELECT ppc.po_item_id,
                    ppc.store_id,
                    ppc.qty AS demand_qty
                   FROM v_picking_post_po_cancelled ppc
                  WHERE ppc.store_active) u
          GROUP BY u.po_item_id, u.store_id
        ), wave_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty) AS wave_qty
           FROM ( SELECT pw.source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_requested
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text
                UNION ALL
                 SELECT pcp.po_id AS source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                     JOIN po_campaign_po pcp ON pcp.campaign_id = pwi.campaign_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL AND pwi.campaign_id IS NOT NULL AND pcp.po_id <> pw.source_po_id AND NOT (EXISTS ( SELECT 1
                           FROM po_campaign_po own
                          WHERE own.po_id = pw.source_po_id AND own.campaign_id = pwi.campaign_id))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        ), po_sku_already_wave AS (
         SELECT u.po_id,
            u.sku_id,
            sum(u.qty) AS already_wave
           FROM ( SELECT pw.source_po_id AS po_id,
                    pwi.sku_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id,
                    ti.sku_id,
                    ti.qty_requested AS qty
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text) u
          GROUP BY u.po_id, u.sku_id
        ), po_sku_demand_left AS (
         SELECT ps_1.po_id,
            ps_1.sku_id,
            sum(GREATEST(0::numeric, COALESCE(sd_1.demand_qty, 0::numeric) - COALESCE(wq_1.wave_qty, 0::numeric))) AS demand_left
           FROM po_skus ps_1
             JOIN store_demand sd_1 ON sd_1.po_item_id = ps_1.po_item_id
             LEFT JOIN wave_qty wq_1 ON wq_1.source_po_id = ps_1.po_id AND wq_1.sku_id = ps_1.sku_id AND wq_1.store_id = sd_1.store_id
          GROUP BY ps_1.po_id, ps_1.sku_id
        ), shipped_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty_received) AS shipped_qty
           FROM ( SELECT pw.source_po_id,
                    ti.sku_id,
                    "substring"(t.transfer_no, 'WAVE-\d+-S(\d+)'::text)::bigint AS store_id,
                    ti.qty_received
                   FROM transfers t
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN picking_waves pw ON pw.id = ("substring"(t.transfer_no, '^WAVE-(\d+)-S'::text))::bigint
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text])) AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_received
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text]))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        )
 SELECT ps.tenant_id,
    ps.po_id,
    ps.po_no,
    ps.po_status,
    ps.supplier_id,
    ps.po_item_id,
    ps.sku_id,
    s.sku_code,
    COALESCE(s.product_name, ''::text) || COALESCE(' '::text || NULLIF(s.variant_name, ''::text), ''::text) AS sku_label,
    ps.qty_ordered,
    COALESCE(g.gr_qty, 0::numeric) AS gr_qty,
        CASE
            WHEN ps.po_status <> 'fully_received'::text THEN GREATEST(0::numeric, ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric))
            ELSE 0::numeric
        END AS qty_in_transit,
        CASE
            WHEN ps.po_status = 'fully_received'::text AND COALESCE(g.gr_qty, 0::numeric) < ps.qty_ordered THEN ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric)
            ELSE 0::numeric
        END AS qty_shortage,
    sd.store_id,
    st.code AS store_code,
    st.name AS store_name,
    COALESCE(sd.demand_qty, 0::numeric) AS demand_qty,
    COALESCE(wq.wave_qty, 0::numeric) AS wave_qty,
    COALESCE(sq.shipped_qty, 0::numeric) AS shipped_qty,
    ps.is_restock_sourced,
    COALESCE(psaw.already_wave, 0::numeric) AS po_sku_already_wave,
    COALESCE(g.gr_qty, 0::numeric) > COALESCE(psaw.already_wave, 0::numeric) AS has_stock_left,
    COALESCE(dl.demand_left, 0::numeric) > 0::numeric AS has_demand_left
   FROM po_skus ps
     JOIN skus s ON s.id = ps.sku_id
     LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
     LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
     LEFT JOIN stores st ON st.id = sd.store_id
     LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
     LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
     LEFT JOIN po_sku_already_wave psaw ON psaw.po_id = ps.po_id AND psaw.sku_id = ps.sku_id
     LEFT JOIN po_sku_demand_left dl ON dl.po_id = ps.po_id AND dl.sku_id = ps.sku_id
  WHERE COALESCE(sq.shipped_qty, 0::numeric) < GREATEST(COALESCE(g.gr_qty, 0::numeric), 1::numeric) AND (COALESCE(g.gr_qty, 0::numeric) > 0::numeric OR COALESCE(sd.demand_qty, 0::numeric) > 0::numeric)$ppcnew$;
    l_def_new := pg_get_viewdef(to_regclass('pg_temp.ppc_chk_demand_new'), true);
    EXECUTE 'DROP VIEW pg_temp.ppc_chk_demand_new';
  END IF;
  IF l_live IS NULL THEN
    l_bad := l_bad || '找不到派貨表 v_picking_demand_by_po'::TEXT;
  ELSIF l_live IS DISTINCT FROM l_def_0818 AND l_live IS DISTINCT FROM l_def_new THEN
    l_bad := l_bad || ('派貨表 v_picking_demand_by_po 不是 8/18 版、也不是本檔新版（md5 去空白 '
                       || md5(regexp_replace(l_live, '\s+', '', 'g')) || '）')::TEXT;
  END IF;

  -- (d) 新名字：沒有＝第一次貼；有＝必須是本檔建的（重貼），否則停下
  FOR l_rec IN
    SELECT * FROM (VALUES ('v_picking_po_rule_items'), ('v_picking_post_po_cancelled')) AS x(n)
  LOOP
    l_oid := to_regclass('public.' || l_rec.n);
    IF l_oid IS NOT NULL THEN
      l_kind := (SELECT c.relkind FROM pg_class c WHERE c.oid = l_oid);
      l_note := obj_description(l_oid, 'pg_class');
      IF l_kind <> 'v' OR position('post_po_cancel_to_store:20261016000000' IN COALESCE(l_note, '')) = 0 THEN
        l_bad := l_bad || ('public.' || l_rec.n || ' 已經存在，但不是本檔的版本（說明裡沒有本檔記號）');
      END IF;
    END IF;
  END LOOP;

  FOR l_rec IN
    SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
           position('post_po_cancel_to_store:20261016000000' IN p.prosrc) > 0 AS ours
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public'
       AND p.proname IN ('_picking_po_rule_cutover', 'rpc_preview_po_store_addition_extra',
                         'rpc_order_cancel_po_notice', 'rpc_picking_post_po_cancelled_by_sku')
  LOOP
    IF NOT l_rec.ours OR l_rec.args IS DISTINCT FROM (CASE l_rec.proname
         WHEN '_picking_po_rule_cutover' THEN ''
         WHEN 'rpc_preview_po_store_addition_extra' THEN 'p_po_id bigint'
         WHEN 'rpc_order_cancel_po_notice' THEN 'p_order_id bigint, p_item_id bigint'
         WHEN 'rpc_picking_post_po_cancelled_by_sku' THEN 'p_sku_ids bigint[]'
       END) THEN
      l_bad := l_bad || ('public.' || l_rec.proname || '(' || l_rec.args || ') 已經存在，但不是本檔的版本');
    END IF;
  END LOOP;

  -- 新欄位：沒有＝第一次貼；有＝必須是本檔加的（型別 numeric(18,3)、欄位說明有本檔記號）
  l_type := (SELECT format_type(a.atttypid, a.atttypmod)
               FROM pg_attribute a
              WHERE a.attrelid = to_regclass('public.purchase_request_store_additions')
                AND a.attname = 'po_delta_qty' AND a.attnum > 0 AND NOT a.attisdropped);
  IF l_type IS NOT NULL
     AND (l_type <> 'numeric(18,3)'
          OR position('post_po_cancel_to_store:20261016000000' IN COALESCE(
               (SELECT col_description(a.attrelid, a.attnum)
                  FROM pg_attribute a
                 WHERE a.attrelid = to_regclass('public.purchase_request_store_additions')
                   AND a.attname = 'po_delta_qty'), '')) = 0) THEN
    l_bad := l_bad || ('purchase_request_store_additions.po_delta_qty 已經存在，但不是本檔加的（' || l_type || '）');
  END IF;

  IF array_length(l_bad, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。請先找工程師確認：\n%', array_to_string(l_bad, E'\n');
  END IF;
END
$precheck$;

-- ----------------------------------------------------------------------------
-- A1. 分店加單紀錄表加一欄：採購單實際加幾件（可空；舊列空著＝跟請購加的一樣）
--     （改欄位＋欄位說明同一個交易：說明裡的記號是前置檢查認「本檔加的」的依據）
-- ----------------------------------------------------------------------------
BEGIN;

ALTER TABLE public.purchase_request_store_additions
  ADD COLUMN IF NOT EXISTS po_delta_qty NUMERIC(18,3) CHECK (po_delta_qty >= 0);

COMMENT ON COLUMN public.purchase_request_store_additions.po_delta_qty IS
  '採購單實際加幾件（post_po_cancel_to_store:20261016000000）。空的＝本檔上線前的紀錄或請購單草稿頁的追加，當作跟 pr_delta_qty 一樣。同一次追加（同一個 request_key）每家店一列、數字相同。';

COMMIT;

-- ----------------------------------------------------------------------------
-- A2. 分界時間：這個時間（含）之後才成立的採購單品項，才套「叫貨後取消照派原店」。
--     一鍵關掉＝把它改成回 'infinity'（scripts/PROD-post-po-cancel-2026-10/kill_switch_…）。
--     權限：收回 PUBLIC／anon，只給 authenticated（派貨表會用到它，見檔頭「安全性」）。
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE FUNCTION public._picking_po_rule_cutover()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
  -- post_po_cancel_to_store:20261016000000
  SELECT '2026-10-16 00:00:00+08'::TIMESTAMPTZ  -- ⚠️ 上線日：老闆貼之前 CEO 會改成實際上線當天
$$;

COMMENT ON FUNCTION public._picking_po_rule_cutover() IS
  '派車照採購單數量（post_po_cancel_to_store:20261016000000）：這個時間（含）之後成立的採購單品項，叫貨後才取消的件數照派原店。回 infinity＝關掉。';

REVOKE ALL ON FUNCTION public._picking_po_rule_cutover() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._picking_po_rule_cutover() TO authenticated;

COMMIT;

-- ----------------------------------------------------------------------------
-- A3. 哪些（採購單品項, 團, 商品）套新規則
--     po_skus／po_campaigns 兩段逐字照抄派貨表（20260818000030:62-77、:85-99），
--     跟 #1082 檢查表（20261015000000:130-160）也是同一條連法、同一組狀態。
--     權限：不給任何前端角色（派貨表等以擁有者身分讀它）。
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE VIEW public.v_picking_po_rule_items AS
WITH po_skus AS (
         SELECT po.id AS po_id,
            po.tenant_id,
            po.po_no,
            po.status AS po_status,
            po.supplier_id,
            poi.id AS po_item_id,
            poi.sku_id,
            poi.qty_ordered,
            (EXISTS ( SELECT 1
                   FROM purchase_request_items pri2
                     JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
                  WHERE pri2.po_item_id = poi.id)) AS is_restock_sourced
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text])
        ), po_campaigns AS (
         SELECT DISTINCT u.po_item_id,
            u.campaign_id
           FROM ( SELECT poi.id AS po_item_id,
                    prc.campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                     JOIN purchase_requests pr ON pr.id = pri.pr_id
                     JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
                UNION
                 SELECT poi.id AS po_item_id,
                    pri.source_campaign_id AS campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                  WHERE pri.source_campaign_id IS NOT NULL) u
        ), linked AS (
         SELECT ps.tenant_id,
            ps.po_id,
            ps.po_item_id,
            ps.sku_id,
            pc.campaign_id,
            count(*) OVER (PARTITION BY pc.campaign_id, ps.sku_id) AS n_po_items
           FROM po_campaigns pc
             JOIN po_skus ps ON ps.po_item_id = pc.po_item_id
        )
 SELECT l.tenant_id,
    l.po_id,
    l.po_item_id,
    l.sku_id,
    l.campaign_id,
    poi.created_at AS ordered_at
   FROM linked l
     JOIN purchase_order_items poi ON poi.id = l.po_item_id
  WHERE l.n_po_items = 1 AND poi.created_at >= _picking_po_rule_cutover();
-- ⓘ po_campaigns 是 DISTINCT (採購單品項, 團)、po_skus 一個採購單品項一列 ⇒
--   count(*) OVER (團, 商品) ＝ 這一團這樣商品連到幾個有效採購單品項（同 #1082 的 count(DISTINCT)）。
--   #1082 多一個「這一團還有有效訂單」的條件；訂單全取消、兩張採購單時 #1082 不標，這裡也不套（2 個），
--   兩邊都照今天，不會打架。

COMMENT ON VIEW public.v_picking_po_rule_items IS
  '派車照採購單數量（post_po_cancel_to_store:20261016000000）：一列＝套新規則的（採購單品項, 團, 商品）。條件：這一團這樣商品剛好只連到 1 個有效採購單品項（連法同 v_picking_demand_by_po），而且那個採購單品項在分界時間 _picking_po_rule_cutover() 之後成立。ordered_at＝採購單品項建立時間（叫貨那一刻）。只讀；不給前端角色直接讀。';

REVOKE ALL ON public.v_picking_po_rule_items FROM PUBLIC, anon, authenticated;

COMMIT;

-- ----------------------------------------------------------------------------
-- A4. 叫貨後才取消的訂單品項（條件見檔頭 1～6）
--     權限：不給任何前端角色（裡面有訂單層資料、而且不分公司；前端走 A14）。
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE VIEW public.v_picking_post_po_cancelled AS
-- (1) 整張取消：訂單取消時間晚於叫貨、品項本身沒有取消／過期
 SELECT r.tenant_id,
    r.po_id,
    r.po_item_id,
    r.sku_id,
    r.campaign_id,
    co.pickup_store_id AS store_id,
    co.id AS order_id,
    coi.id AS order_item_id,
    coi.qty,
    co.cancelled_at,
    COALESCE(st.is_active AND st.deleted_at IS NULL, false) AS store_active
   FROM v_picking_po_rule_items r
     JOIN customer_orders co ON co.tenant_id = r.tenant_id
                             AND co.campaign_id = r.campaign_id
                             AND co.status = 'cancelled'::text
                             AND co.cancelled_at > r.ordered_at
                             AND co.transferred_from_order_id IS NULL
                             AND co.stockout_at IS NULL
     JOIN customer_order_items coi ON coi.order_id = co.id
                                  AND coi.sku_id = r.sku_id
                                  AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
                                  AND coi.stockout_at IS NULL
                                  AND coi.created_at <= r.ordered_at
     LEFT JOIN stores st ON st.id = co.pickup_store_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM customer_order_audit_log ra
          WHERE ra.order_id = co.id
            AND ra.entity_type = 'order'::text
            AND ra.entity_id = co.id
            AND ra.field = 'status'::text
            AND ra.before_value = to_jsonb('cancelled'::text)
            AND ra.after_value <> to_jsonb('cancelled'::text)
            AND ra.created_at > r.ordered_at))
UNION ALL
-- (2) 刪單一品項：品項取消、編輯歷史有一筆「狀態→取消」晚於叫貨、訂單不是轉出
 SELECT r.tenant_id,
    r.po_id,
    r.po_item_id,
    r.sku_id,
    r.campaign_id,
    co.pickup_store_id AS store_id,
    co.id AS order_id,
    coi.id AS order_item_id,
    coi.qty,
    ia.cancelled_at,
    COALESCE(st.is_active AND st.deleted_at IS NULL, false) AS store_active
   FROM v_picking_po_rule_items r
     JOIN customer_order_items coi ON coi.tenant_id = r.tenant_id
                                  AND coi.sku_id = r.sku_id
                                  AND coi.status = 'cancelled'::text
                                  AND coi.stockout_at IS NULL
                                  AND coi.created_at <= r.ordered_at
     JOIN customer_orders co ON co.id = coi.order_id
                             AND co.campaign_id = r.campaign_id
                             AND co.status <> 'transferred_out'::text
                             AND co.transferred_from_order_id IS NULL
                             AND co.stockout_at IS NULL
     JOIN LATERAL ( SELECT min(l.created_at) AS cancelled_at
           FROM customer_order_audit_log l
          WHERE l.order_id = co.id
            AND l.entity_type = 'item'::text
            AND l.entity_id = coi.id
            AND l.field = 'status'::text
            AND l.after_value = to_jsonb('cancelled'::text)
            AND l.created_at > r.ordered_at) ia ON ia.cancelled_at IS NOT NULL
     LEFT JOIN stores st ON st.id = co.pickup_store_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM customer_order_audit_log ra
          WHERE ra.order_id = co.id
            AND ra.entity_type = 'order'::text
            AND ra.entity_id = co.id
            AND ra.field = 'status'::text
            AND ra.before_value = to_jsonb('cancelled'::text)
            AND ra.after_value <> to_jsonb('cancelled'::text)
            AND ra.created_at > r.ordered_at));
-- ⓘ 兩段互斥（(1) 品項沒取消、(2) 品項已取消），UNION ALL 不會重複。
-- ⓘ 分兩段寫是為了速度：只從「已取消的訂單」「已取消的品項」找，不必掃這一團所有有效訂單
--   （(1) 用 idx_corders_campaign (tenant_id, campaign_id, status)；(2) 用 idx_coi_sku_status
--   (tenant_id, sku_id, status)）。co／coi 的 tenant_id = r.tenant_id 是同一家公司本來就成立的條件，
--   多寫是讓查詢用得到這兩個索引。上線幾個月後所有採購單都在分界之後，掃全部有效訂單會越來越慢。
-- ⓘ 刪品項的編輯歷史只有 rpc_delete_order_item 會寫「→ cancelled」（20260831000090:810-815）；
--   復原取消寫的是「cancelled →」（after_value 不是 cancelled），不會被當成取消。
-- ⓘ 條件 6（兩段都有）：「復原取消」的編輯歷史是 rpc_restore_cancelled_order 寫的
--   （20261013000000:1690-1703：entity_type 'order'、entity_id＝訂單、field 'status'、
--   before_value to_jsonb('cancelled')、after_value＝復原後的狀態）。叫貨之後有這一筆 ⇒ 不算：
--   rpc_cancel_aid_order 會覆寫 cancelled_at、復原會清掉它，看不出第一次取消是在叫貨前還是叫貨後。
--   代價：叫貨後取消→復原→再取消的，也照今天留總倉（少派、不會多派）。
--   用 idx_coa_entity (order_id, entity_type, entity_id) 查，只對已取消的那幾張單查。

COMMENT ON VIEW public.v_picking_post_po_cancelled IS
  '派車照採購單數量（post_po_cancel_to_store:20261016000000）：一列＝一個叫貨後才取消的訂單品項（只看 v_picking_po_rule_items 的採購單品項；叫貨前就有、不是轉入單、沒有斷貨標記；整張取消晚於叫貨或刪品項歷史晚於叫貨；叫貨後沒有復原取消過）。store_active＝門市啟用且沒刪除；派貨表只帶 store_active 的列，停用店留給總倉決定。只讀；不給前端角色直接讀（前端用 rpc_picking_post_po_cancelled_by_sku）。';

REVOKE ALL ON public.v_picking_post_po_cancelled FROM PUBLIC, anon, authenticated;

COMMIT;

-- ----------------------------------------------------------------------------
-- A5. 派貨工作台那張表：以 20260818000030:61-267 逐字為底，
--     只在 store_demand 的 UNION ALL 多一段（叫貨後才取消、店沒停用的件數）。
--     每個（採購單品項, 店）在 store_demand 仍只有一列（外面那層 GROUP BY 會加總），
--     v_order_shortage 讀的 wave_qty／shipped_qty 不會被重複算。
--     ⛔ 沒有帶入 #917（20260908000000）那三行。權限：CREATE OR REPLACE 保留原本的，不動。
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE VIEW public.v_picking_demand_by_po AS
WITH po_skus AS (
         SELECT po.id AS po_id,
            po.tenant_id,
            po.po_no,
            po.status AS po_status,
            po.supplier_id,
            poi.id AS po_item_id,
            poi.sku_id,
            poi.qty_ordered,
            (EXISTS ( SELECT 1
                   FROM purchase_request_items pri2
                     JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
                  WHERE pri2.po_item_id = poi.id)) AS is_restock_sourced
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text])
        ), gr_qty AS (
         SELECT gri.po_item_id,
            sum(gri.qty_received) AS gr_qty
           FROM goods_receipt_items gri
             JOIN goods_receipts gr ON gr.id = gri.gr_id
          WHERE gr.status = 'confirmed'::text
          GROUP BY gri.po_item_id
        ), po_campaigns AS (
         SELECT DISTINCT u.po_item_id,
            u.campaign_id
           FROM ( SELECT poi.id AS po_item_id,
                    prc.campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                     JOIN purchase_requests pr ON pr.id = pri.pr_id
                     JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
                UNION
                 SELECT poi.id AS po_item_id,
                    pri.source_campaign_id AS campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                  WHERE pri.source_campaign_id IS NOT NULL) u
        ), po_campaign_po AS (
         SELECT DISTINCT poi.po_id,
            pc0.campaign_id
           FROM po_campaigns pc0
             JOIN purchase_order_items poi ON poi.id = pc0.po_item_id
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR (EXISTS ( SELECT 1
                   FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id AND src.pickup_store_id = co.pickup_store_id)))
             JOIN customer_order_items coi ON coi.order_id = co.id AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
             JOIN purchase_order_items poi ON poi.id = pc.po_item_id AND poi.sku_id = coi.sku_id
          GROUP BY pc.po_item_id, co.pickup_store_id
        ), restock_demand AS (
         SELECT poi.id AS po_item_id,
            rr.requesting_store_id AS store_id,
            sum(rrl.qty) AS demand_qty
           FROM purchase_order_items poi
             JOIN purchase_request_items pri ON pri.po_item_id = poi.id
             JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id AND (rr.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text]))
             JOIN restock_request_lines rrl ON rrl.request_id = rr.id AND rrl.sku_id = poi.sku_id
          GROUP BY poi.id, rr.requesting_store_id
        ), store_demand AS (
         SELECT u.po_item_id,
            u.store_id,
            sum(u.demand_qty) AS demand_qty
           FROM ( SELECT campaign_demand.po_item_id,
                    campaign_demand.store_id,
                    campaign_demand.demand_qty
                   FROM campaign_demand
                UNION ALL
                 SELECT restock_demand.po_item_id,
                    restock_demand.store_id,
                    restock_demand.demand_qty
                   FROM restock_demand
                UNION ALL
                 SELECT ppc.po_item_id,
                    ppc.store_id,
                    ppc.qty AS demand_qty
                   FROM v_picking_post_po_cancelled ppc
                  WHERE ppc.store_active) u
          GROUP BY u.po_item_id, u.store_id
        ), wave_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty) AS wave_qty
           FROM ( SELECT pw.source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_requested
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text
                UNION ALL
                 SELECT pcp.po_id AS source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                     JOIN po_campaign_po pcp ON pcp.campaign_id = pwi.campaign_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL AND pwi.campaign_id IS NOT NULL AND pcp.po_id <> pw.source_po_id AND NOT (EXISTS ( SELECT 1
                           FROM po_campaign_po own
                          WHERE own.po_id = pw.source_po_id AND own.campaign_id = pwi.campaign_id))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        ), po_sku_already_wave AS (
         SELECT u.po_id,
            u.sku_id,
            sum(u.qty) AS already_wave
           FROM ( SELECT pw.source_po_id AS po_id,
                    pwi.sku_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id,
                    ti.sku_id,
                    ti.qty_requested AS qty
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text) u
          GROUP BY u.po_id, u.sku_id
        ), po_sku_demand_left AS (
         SELECT ps_1.po_id,
            ps_1.sku_id,
            sum(GREATEST(0::numeric, COALESCE(sd_1.demand_qty, 0::numeric) - COALESCE(wq_1.wave_qty, 0::numeric))) AS demand_left
           FROM po_skus ps_1
             JOIN store_demand sd_1 ON sd_1.po_item_id = ps_1.po_item_id
             LEFT JOIN wave_qty wq_1 ON wq_1.source_po_id = ps_1.po_id AND wq_1.sku_id = ps_1.sku_id AND wq_1.store_id = sd_1.store_id
          GROUP BY ps_1.po_id, ps_1.sku_id
        ), shipped_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty_received) AS shipped_qty
           FROM ( SELECT pw.source_po_id,
                    ti.sku_id,
                    "substring"(t.transfer_no, 'WAVE-\d+-S(\d+)'::text)::bigint AS store_id,
                    ti.qty_received
                   FROM transfers t
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN picking_waves pw ON pw.id = ("substring"(t.transfer_no, '^WAVE-(\d+)-S'::text))::bigint
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text])) AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_received
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text]))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        )
 SELECT ps.tenant_id,
    ps.po_id,
    ps.po_no,
    ps.po_status,
    ps.supplier_id,
    ps.po_item_id,
    ps.sku_id,
    s.sku_code,
    COALESCE(s.product_name, ''::text) || COALESCE(' '::text || NULLIF(s.variant_name, ''::text), ''::text) AS sku_label,
    ps.qty_ordered,
    COALESCE(g.gr_qty, 0::numeric) AS gr_qty,
        CASE
            WHEN ps.po_status <> 'fully_received'::text THEN GREATEST(0::numeric, ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric))
            ELSE 0::numeric
        END AS qty_in_transit,
        CASE
            WHEN ps.po_status = 'fully_received'::text AND COALESCE(g.gr_qty, 0::numeric) < ps.qty_ordered THEN ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric)
            ELSE 0::numeric
        END AS qty_shortage,
    sd.store_id,
    st.code AS store_code,
    st.name AS store_name,
    COALESCE(sd.demand_qty, 0::numeric) AS demand_qty,
    COALESCE(wq.wave_qty, 0::numeric) AS wave_qty,
    COALESCE(sq.shipped_qty, 0::numeric) AS shipped_qty,
    ps.is_restock_sourced,
    COALESCE(psaw.already_wave, 0::numeric) AS po_sku_already_wave,
    COALESCE(g.gr_qty, 0::numeric) > COALESCE(psaw.already_wave, 0::numeric) AS has_stock_left,
    COALESCE(dl.demand_left, 0::numeric) > 0::numeric AS has_demand_left
   FROM po_skus ps
     JOIN skus s ON s.id = ps.sku_id
     LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
     LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
     LEFT JOIN stores st ON st.id = sd.store_id
     LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
     LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
     LEFT JOIN po_sku_already_wave psaw ON psaw.po_id = ps.po_id AND psaw.sku_id = ps.sku_id
     LEFT JOIN po_sku_demand_left dl ON dl.po_id = ps.po_id AND dl.sku_id = ps.sku_id
  WHERE COALESCE(sq.shipped_qty, 0::numeric) < GREATEST(COALESCE(g.gr_qty, 0::numeric), 1::numeric) AND (COALESCE(g.gr_qty, 0::numeric) > 0::numeric OR COALESCE(sd.demand_qty, 0::numeric) > 0::numeric);

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖：PO × SKU × store 矩陣。campaign_demand 排除「跨店」衍生單、保留「同店」衍生單。'
  'wave_qty 含跨團借調歸屬分支（campaign 標記不屬於來源 PO 的 wave item，需求歸屬跟著標記走）；'
  'po_sku_already_wave/has_stock_left 維持跟著來源 PO。其餘語意同 20260807000000。'
  '（post_po_cancel_to_store:20261016000000）以 20260818000030 為底，store_demand 多一段：叫貨後才取消、門市沒停用的件數照派原店（v_picking_post_po_cancelled）；沒有 20260908000000（#917）。';

COMMIT;

-- ----------------------------------------------------------------------------
-- A6. 建撿貨單：以「20260816000050:268 ＋ 20260923110000 總倉封頂」逐字為底，只加兩處（見檔頭）
--     權限：CREATE OR REPLACE 保留原本的，不動。
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_create_wave_from_po(p_po_id bigint, p_wave_date date, p_allocations jsonb, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_po                purchase_orders%ROWTYPE;
  v_tenant            UUID;
  v_wave_id           BIGINT;
  v_wave_code         TEXT;
  v_alloc             JSONB;
  v_sku_id            BIGINT;
  v_store_id          BIGINT;
  v_qty               NUMERIC(18,3);
  v_line_campaign_id  BIGINT;
  v_total_qty         NUMERIC(18,3) := 0;
  v_item_count        INTEGER := 0;
  v_store_count       INTEGER := 0;
  v_over              RECORD;
  v_restock_demand    NUMERIC;
  v_restock_dispatched NUMERIC;
  v_restock_left      NUMERIC;
  v_borrow            RECORD;
  v_hq_location_id  BIGINT;
  v_stock_over      RECORD;
BEGIN
  -- 1. PO 守衛
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;
  IF v_po.status NOT IN ('sent','partially_received','fully_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可建撿貨單（需為「已發送」/「部分進貨」/「全部進貨」）', v_po.po_no, v_po.status;
  END IF;
  v_tenant := v_po.tenant_id;

  -- 2. allocations 守衛
  IF p_allocations IS NULL OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION '請先填寫各分店分配量、不可全為空';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('wave:po:' || p_po_id::text));

  -- 3. 守衛：每個分配 qty > 0
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_qty := (v_alloc->>'qty')::NUMERIC;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '分配數量必須 > 0';
    END IF;
  END LOOP;

  -- 4. 守衛：每 sku 的總分配量 ≤ (GR 量 − 已派量)
  --    已派量 = picking_wave_items ＋ 補貨直派 transfer（linked_transfer_id 路徑），
  --    與 v_picking_demand_by_po.po_sku_already_wave 對齊。
  WITH alloc_agg AS (
    SELECT
      (a->>'sku_id')::BIGINT  AS sku_id,
      SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  po_sku_state AS (
    SELECT
      poi.sku_id,
      COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status = 'confirmed'), 0) AS gr_qty,
      COALESCE((
        SELECT SUM(pwi.qty)
          FROM picking_wave_items pwi
          JOIN picking_waves pw ON pw.id = pwi.wave_id
         WHERE pw.source_po_id = p_po_id
           AND pwi.sku_id = poi.sku_id
           AND pw.status <> 'cancelled'
      ), 0)
      + COALESCE((
        SELECT SUM(ti.qty_requested)
          FROM restock_requests rr
          JOIN transfers t ON t.id = rr.linked_transfer_id
          JOIN transfer_items ti ON ti.transfer_id = t.id
          JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
          JOIN purchase_order_items poi2 ON poi2.id = pri.po_item_id AND poi2.sku_id = ti.sku_id
         WHERE poi2.po_id = p_po_id
           AND poi2.sku_id = poi.sku_id
           AND t.transfer_type = 'hq_to_store'
           AND t.status <> 'cancelled'
      ), 0) AS already_wave
    FROM purchase_order_items poi
    LEFT JOIN goods_receipt_items gri ON gri.po_item_id = poi.id
    LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id
    WHERE poi.po_id = p_po_id
    GROUP BY poi.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
    aa.total_alloc, ps.gr_qty, ps.already_wave,
    (ps.gr_qty - ps.already_wave) AS available
  INTO v_over
  FROM alloc_agg aa
  JOIN po_sku_state ps ON ps.sku_id = aa.sku_id
  JOIN skus s ON s.id = aa.sku_id
  WHERE aa.total_alloc > (ps.gr_qty - ps.already_wave)
  LIMIT 1;

  IF v_over.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」分配 % 超過可分配量 %（進貨 %、已派 %，含撿貨單與補貨直派）',
      v_over.sku_code, v_over.sku_label,
      v_over.total_alloc, v_over.available, v_over.gr_qty, v_over.already_wave;
  END IF;
  -- 4.2 守衛：跨 PO / 舊 PO 殘留時，總分配不可超過總倉真正可派量。
  --     open wave 只算 draft / picking / picked；shipped 已經由出倉流程扣 on_hand，
  --     若再算一次會把同一批貨重複保留。
  SELECT id INTO v_hq_location_id
    FROM public.locations
   WHERE tenant_id = v_tenant
     AND type = 'central_warehouse'
     AND is_active = TRUE
   ORDER BY id
   LIMIT 1;

  IF v_hq_location_id IS NULL THEN
    RAISE EXCEPTION '找不到總倉 location(type=central_warehouse)';
  END IF;

  -- 與退回貨 reserved / 其他派貨建單共用同一 balance 鎖；SKU 升冪避免死鎖。
  FOR v_sku_id IN
    SELECT DISTINCT (a->>'sku_id')::BIGINT
      FROM jsonb_array_elements(p_allocations) a
     ORDER BY 1
  LOOP
    PERFORM 1
      FROM public.stock_balances
     WHERE tenant_id = v_tenant
       AND location_id = v_hq_location_id
       AND sku_id = v_sku_id
     FOR UPDATE;
  END LOOP;

  WITH alloc_agg AS (
    SELECT
      (a->>'sku_id')::BIGINT AS sku_id,
      SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  open_wave_reserved AS (
    SELECT pwi.sku_id, SUM(pwi.qty) AS qty
      FROM public.picking_wave_items pwi
      JOIN public.picking_waves pw ON pw.id = pwi.wave_id
     WHERE pw.tenant_id = v_tenant
       AND pw.status IN ('draft','picking','picked')
       AND pwi.sku_id IN (SELECT sku_id FROM alloc_agg)
     GROUP BY pwi.sku_id
  ),
  hq_state AS (
    SELECT
      aa.sku_id,
      aa.total_alloc,
      GREATEST(COALESCE(sb.on_hand, 0) - COALESCE(sb.reserved, 0), 0) AS hq_available_qty,
      COALESCE(ow.qty, 0) AS open_wave_qty
    FROM alloc_agg aa
    LEFT JOIN public.stock_balances sb
      ON sb.tenant_id = v_tenant
     AND sb.location_id = v_hq_location_id
     AND sb.sku_id = aa.sku_id
    LEFT JOIN open_wave_reserved ow ON ow.sku_id = aa.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
    hs.total_alloc,
    hs.hq_available_qty,
    hs.open_wave_qty,
    GREATEST(hs.hq_available_qty - hs.open_wave_qty, 0) AS hq_left
  INTO v_stock_over
  FROM hq_state hs
  JOIN public.skus s ON s.id = hs.sku_id AND s.tenant_id = v_tenant
  WHERE hs.total_alloc > GREATEST(hs.hq_available_qty - hs.open_wave_qty, 0)
  LIMIT 1;

  IF v_stock_over.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」分配 % 超過總倉可派量 %（帳上可派 %、未出倉撿貨單已保留 %）',
      v_stock_over.sku_code, v_stock_over.sku_label,
      v_stock_over.total_alloc, v_stock_over.hq_left,
      v_stock_over.hq_available_qty, v_stock_over.open_wave_qty;
  END IF;



  -- 4.5 借調守衛（20260816000050）：分配到「本單開團 / 補貨都沒需求」的 (store, sku)
  --     ＝ 跨團借調。借調總量（per SKU）不可超過本單餘量
  --       餘量 = (GR − 已派) − 本單自己的未派需求
  --     否則會吃掉本單自己團的客人還沒拿到的貨。「未派需求」對齊
  --     v_picking_demand_by_po 的 demand_left 口徑（Σ GREATEST(0, demand − wave)；
  --     wave_qty 的借調歸屬分支已含在內）。此守衛在建 wave 之前跑，view 不含本次分配。
  WITH post_po_cancelled AS MATERIALIZED (   -- 20261016000000：本單叫貨後才取消、門市沒停用的（團, 店, 商品），只算一次
    SELECT DISTINCT ppc.campaign_id, ppc.store_id, ppc.sku_id
      FROM public.v_picking_post_po_cancelled ppc
     WHERE ppc.po_id = p_po_id
       AND ppc.store_active
  ),
  alloc_rows AS (
    SELECT
      (a->>'sku_id')::BIGINT  AS sku_id,
      (a->>'store_id')::BIGINT AS store_id,
      SUM((a->>'qty')::NUMERIC) AS qty
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT, (a->>'store_id')::BIGINT
  ),
  borrow_alloc AS (
    SELECT ar.sku_id, SUM(ar.qty) AS borrow_qty
      FROM alloc_rows ar
     WHERE NOT EXISTS (               -- 本單開團對該 (store, sku) 沒有訂單需求（鏡射步驟 6 的解析條件）
             SELECT 1
               FROM ( SELECT prc.campaign_id
                        FROM purchase_order_items poi
                        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                        JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
                       WHERE poi.po_id = p_po_id
                      UNION
                      SELECT pri.source_campaign_id AS campaign_id
                        FROM purchase_order_items poi
                        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                       WHERE poi.po_id = p_po_id
                         AND pri.source_campaign_id IS NOT NULL) cand
              WHERE EXISTS (
                SELECT 1
                  FROM customer_orders co
                  JOIN customer_order_items coi ON coi.order_id = co.id
                 WHERE co.campaign_id = cand.campaign_id
                   AND co.pickup_store_id = ar.store_id
                   AND co.status NOT IN ('cancelled','expired','transferred_out')
                   AND (co.transferred_from_order_id IS NULL OR EXISTS (
                         SELECT 1 FROM customer_orders src
                          WHERE src.id = co.transferred_from_order_id
                            AND src.pickup_store_id = co.pickup_store_id))
                   AND coi.sku_id = ar.sku_id
                   AND coi.status NOT IN ('cancelled','expired'))
                 OR EXISTS (      -- 20261016000000：叫貨後才取消、照派原店的店（停用店不算）不是借調
                SELECT 1
                  FROM post_po_cancelled ppc
                 WHERE ppc.campaign_id = cand.campaign_id
                   AND ppc.store_id = ar.store_id
                   AND ppc.sku_id = ar.sku_id))
       AND NOT EXISTS (               -- 也不是補貨來源（鏡射步驟 6）
             SELECT 1
               FROM purchase_order_items poi
               JOIN purchase_request_items pri ON pri.po_item_id = poi.id
               JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                       AND rr.requesting_store_id = ar.store_id
                                       AND rr.status NOT IN ('cancelled','rejected')
               JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                             AND rrl.sku_id = ar.sku_id
              WHERE poi.po_id = p_po_id
                AND poi.sku_id = ar.sku_id)
     GROUP BY ar.sku_id
  ),
  own_unmet AS (
    SELECT v.sku_id, SUM(GREATEST(0, v.demand_qty - v.wave_qty)) AS unmet
      FROM public.v_picking_demand_by_po v
     WHERE v.po_id = p_po_id AND v.store_id IS NOT NULL
     GROUP BY v.sku_id
  ),
  po_sku_state2 AS (
    SELECT
      poi.sku_id,
      COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status = 'confirmed'), 0) AS gr_qty,
      COALESCE((
        SELECT SUM(pwi.qty)
          FROM picking_wave_items pwi
          JOIN picking_waves pw ON pw.id = pwi.wave_id
         WHERE pw.source_po_id = p_po_id
           AND pwi.sku_id = poi.sku_id
           AND pw.status <> 'cancelled'
      ), 0)
      + COALESCE((
        SELECT SUM(ti.qty_requested)
          FROM restock_requests rr
          JOIN transfers t ON t.id = rr.linked_transfer_id
          JOIN transfer_items ti ON ti.transfer_id = t.id
          JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
          JOIN purchase_order_items poi2 ON poi2.id = pri.po_item_id AND poi2.sku_id = ti.sku_id
         WHERE poi2.po_id = p_po_id
           AND poi2.sku_id = poi.sku_id
           AND t.transfer_type = 'hq_to_store'
           AND t.status <> 'cancelled'
      ), 0) AS already_wave
    FROM purchase_order_items poi
    LEFT JOIN goods_receipt_items gri ON gri.po_item_id = poi.id
    LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id
    WHERE poi.po_id = p_po_id
    GROUP BY poi.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
    b.borrow_qty,
    COALESCE(u.unmet, 0) AS own_unmet,
    GREATEST(0, GREATEST(0, ps.gr_qty - ps.already_wave) - COALESCE(u.unmet, 0)) AS surplus
  INTO v_borrow
  FROM borrow_alloc b
  JOIN po_sku_state2 ps ON ps.sku_id = b.sku_id
  LEFT JOIN own_unmet u ON u.sku_id = b.sku_id
  JOIN skus s ON s.id = b.sku_id
  WHERE b.borrow_qty > GREATEST(0, GREATEST(0, ps.gr_qty - ps.already_wave) - COALESCE(u.unmet, 0))
  LIMIT 1;

  IF v_borrow.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」跨團借調 % 件超過本單餘量 %（本單自己的團還缺 % 件未派，借調只能動「蓋掉自己需求後剩下的量」）',
      v_borrow.sku_code, v_borrow.sku_label,
      v_borrow.borrow_qty, v_borrow.surplus, v_borrow.own_unmet;
  END IF;

  -- 5. wave header — 用 sequence 產 code,避免同秒撞單
  v_wave_code := 'WV'
              || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYMMDD')
              || LPAD(nextval('public.picking_wave_code_seq')::TEXT, 6, '0');

  INSERT INTO picking_waves (
    tenant_id, wave_code, wave_date, status, source_po_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_wave_code, p_wave_date, 'draft', p_po_id,
    p_operator, p_operator
  ) RETURNING id INTO v_wave_id;

  -- 6 + 7. 逐 (sku, store) 解析「實際有需求的那一團」當 campaign_id，並擋跨團誤撿
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_sku_id   := (v_alloc->>'sku_id')::BIGINT;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    v_qty      := (v_alloc->>'qty')::NUMERIC;

    -- 在「此 PO 對應的開團」裡，挑對該 (store, sku) 確實有訂單需求的一團。
    -- 涵蓋兩條 PO→campaign 路徑（purchase_request_campaigns 與 source_campaign_id），
    -- 與 v_picking_demand_by_po 的 po_campaigns 對齊。
    SELECT cand.campaign_id
      INTO v_line_campaign_id
      FROM (
        SELECT prc.campaign_id
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
         WHERE poi.po_id = p_po_id
        UNION
        SELECT pri.source_campaign_id AS campaign_id
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
         WHERE poi.po_id = p_po_id
           AND pri.source_campaign_id IS NOT NULL
      ) cand
     WHERE EXISTS (
       SELECT 1
         FROM customer_orders co
         JOIN customer_order_items coi ON coi.order_id = co.id
        WHERE co.campaign_id = cand.campaign_id
          AND co.pickup_store_id = v_store_id
          AND co.status NOT IN ('cancelled','expired','transferred_out')
          AND (co.transferred_from_order_id IS NULL OR EXISTS (
                SELECT 1 FROM customer_orders src
                 WHERE src.id = co.transferred_from_order_id
                   AND src.pickup_store_id = co.pickup_store_id))
          AND coi.sku_id = v_sku_id
          AND coi.status NOT IN ('cancelled','expired')
     )
     ORDER BY cand.campaign_id
     LIMIT 1;

    -- 20261016000000（post_po_cancel_to_store）：本單開團在該店沒有有效訂單，但有「叫貨後才取消、
    --   照派原店」的件數（門市沒停用）→ 標那一團。上面那句一個字都沒改、而且先跑：
    --   有有效訂單的團優先（不然那一團的單推不到出貨中），一般情況結果跟改前一樣。
    IF v_line_campaign_id IS NULL THEN
      v_line_campaign_id := (
        SELECT ppc.campaign_id
          FROM public.v_picking_post_po_cancelled ppc
         WHERE ppc.po_id = p_po_id
           AND ppc.store_id = v_store_id
           AND ppc.sku_id = v_sku_id
           AND ppc.store_active
         ORDER BY ppc.campaign_id
         LIMIT 1);
    END IF;

    IF v_line_campaign_id IS NULL THEN
      -- 此 (store, sku) 在這張 PO 的開團都沒有需求。兩條出路：
      --   a) 補貨 (restock) 來源 → campaign_id 掛 NULL ＋ 補貨 cap（沿用既有行為，優先）。
      --   b) 跨團借調（20260816000050）→ 別的團在該店有客人在等 → 標「被服務的那一團」。
      IF NOT EXISTS (
        SELECT 1
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                  AND rr.requesting_store_id = v_store_id
                                  AND rr.status NOT IN ('cancelled','rejected')
          JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                        AND rrl.sku_id = v_sku_id
         WHERE poi.po_id = p_po_id
           AND poi.sku_id = v_sku_id
      ) THEN
        -- 跨團借調：wave item 的 campaign_id 一律標「實際被服務的那一團」，
        -- 出貨時 rpc_mark_orders_shipping_for_wave（pwi.campaign_id = co.campaign_id）
        -- 才推得動該團的單頭。標成貨來源的團 = 貨到店、單卡 confirmed
        -- （忠順 2026-08-11 全卡 105 張的翻版），絕對不要。
        -- 解析規則：該店該 SKU「還在等貨」（pending/reserved/ready）的活訂單裡，
        -- 挑最早開始等的那一團；內部現貨池（store_internal）不是借調對象。
        -- 借調總量已由步驟 4.5 擋在本單餘量內。
        SELECT co.campaign_id
          INTO v_line_campaign_id
          FROM customer_orders co
          JOIN customer_order_items coi ON coi.order_id = co.id
          LEFT JOIN members m ON m.id = co.member_id
         WHERE co.pickup_store_id = v_store_id
           AND co.campaign_id IS NOT NULL
           AND co.status NOT IN ('cancelled','expired','transferred_out')
           AND (co.transferred_from_order_id IS NULL OR EXISTS (
                 SELECT 1 FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id
                    AND src.pickup_store_id = co.pickup_store_id))
           AND coi.sku_id = v_sku_id
           AND coi.status IN ('pending','reserved','ready')
           AND COALESCE(m.member_type, '') <> 'store_internal'
         GROUP BY co.campaign_id
         ORDER BY MIN(co.created_at)
         LIMIT 1;

        IF v_line_campaign_id IS NULL THEN
          RAISE EXCEPTION
            '分店「%」在採購單「%」對應的開團沒有 SKU「%」的訂單需求，也沒有別團的客人在該店等這個商品，不能撿到這批貨（若要額外補庫存給分店，請走內部調撥）',
            COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
            v_po.po_no,
            COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id);
        END IF;
      ELSE

      -- 20260715 新增：補貨分配不可超過「剩餘補貨需求」= 申請量 − 已派量。
      -- 申請量：此 PO 對應補貨申請對該 (store, sku) 的 lines 加總。
      SELECT COALESCE(SUM(rrl.qty), 0) INTO v_restock_demand
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                AND rr.requesting_store_id = v_store_id
                                AND rr.status NOT IN ('cancelled','rejected')
        JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                      AND rrl.sku_id = v_sku_id
       WHERE poi.po_id = p_po_id
         AND poi.sku_id = v_sku_id;

      -- 已派量：此 PO 的 campaign NULL wave items（含本 wave 前面 loop 已插入的列，
      -- 同批重複 (sku,store) 會累計）＋ 補貨直派 transfer。
      SELECT
        COALESCE((
          SELECT SUM(pwi.qty)
            FROM picking_wave_items pwi
            JOIN picking_waves pw ON pw.id = pwi.wave_id
           WHERE pw.source_po_id = p_po_id
             AND pw.status <> 'cancelled'
             AND pwi.sku_id = v_sku_id
             AND pwi.store_id = v_store_id
             AND pwi.campaign_id IS NULL
        ), 0)
        + COALESCE((
          SELECT SUM(ti.qty_requested)
            FROM restock_requests rr
            JOIN transfers t ON t.id = rr.linked_transfer_id
            JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = v_sku_id
            JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
            JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = v_sku_id
           WHERE poi.po_id = p_po_id
             AND rr.requesting_store_id = v_store_id
             AND t.transfer_type = 'hq_to_store'
             AND t.status <> 'cancelled'
        ), 0)
      INTO v_restock_dispatched;

      v_restock_left := GREATEST(0, v_restock_demand - v_restock_dispatched);
      IF v_qty > v_restock_left THEN
        RAISE EXCEPTION
          '分店「%」SKU「%」的補貨需求只剩 % 件未派（申請 %、已派 %，含撿貨單與直派），本次分配 % 超過。若要額外補庫存給分店，請走內部調撥。',
          COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
          COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id),
          v_restock_left, v_restock_demand, v_restock_dispatched, v_qty;
      END IF;
      END IF;  -- a) restock / b) 借調 分流
    END IF;

    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, campaign_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_wave_id, v_sku_id, v_store_id, v_qty, v_line_campaign_id,
      p_operator, p_operator
    )
    ON CONFLICT (wave_id, sku_id, store_id) DO UPDATE
      SET qty = picking_wave_items.qty + EXCLUDED.qty,
          updated_by = p_operator,
          updated_at = NOW();
  END LOOP;

  -- 8. 統計 wave header
  SELECT COUNT(*), COUNT(DISTINCT store_id), COALESCE(SUM(qty), 0)
    INTO v_item_count, v_store_count, v_total_qty
    FROM picking_wave_items WHERE wave_id = v_wave_id;

  UPDATE picking_waves
     SET item_count = v_item_count,
         store_count = v_store_count,
         total_qty = v_total_qty,
         updated_at = NOW()
   WHERE id = v_wave_id;

  RETURN jsonb_build_object(
    'wave_id', v_wave_id,
    'wave_code', v_wave_code,
    'item_count', v_item_count,
    'store_count', v_store_count,
    'total_qty', v_total_qty
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_create_wave_from_po(BIGINT, DATE, JSONB, UUID) IS
  '由派貨工作台建撿貨單。跨團守衛：本單開團有需求 → 標該團；補貨來源 → NULL + 補貨 cap；'
  '都沒有 → 跨團借調（標「實際被服務的團」，總量 ≤ 本單餘量 = 可分配 − 自己未派需求，'
  '步驟 4.5 守衛）。新增總倉庫存封頂：本次分配 + 未出倉 wave 保留量 ≤ on_hand - reserved。'
  '（post_po_cancel_to_store:20261016000000）叫貨後才取消、照派原店的店（門市沒停用）：步驟 4.5 不算借調；步驟 6 本單開團沒有有效訂單時標那一團。以 20260816000050＋20260923110000 為底，沒有 20260908000000（#917）。';

COMMIT;

-- ----------------------------------------------------------------------------
-- A8. 唯讀：分店追加視窗算「採購單會加幾件」要用的 R、E、rule_applies（A7 寫入也用這一支，同一份算法）
--     一列＝這張採購單的一個（採購單品項, 團）：
--       post_po_cancelled_qty（R）＝叫貨後才取消的件數（含停用店：那幾件留給總倉決定，不拿去抵）
--       prior_po_extra_qty（E）  ＝以前追加時採購單比請購多加的件數合計（每次追加算一次；可能是負的＝那次少加）
--       rule_applies             ＝這個（採購單品項, 團）套不套新規則（在 v_picking_po_rule_items 裡）。
--                                  A7 寫入就是讀這一欄決定套不套，不另外判斷 ⇒ 畫面預估和寫入同一條。
--     兩個都是 0 的（採購單品項, 團）不回：沒有列＝R、E 都是 0，套不套算出來都一樣（max(差額+N, 0)），
--     畫面和 A7 都當「不套」。權限同預覽（_pr_qty_sync_assert_perm）。
--     ⓘ 放在 A7 前面：A7 會呼叫它。
--     ⓘ 建立前先 DROP（同一個交易裡）：本檔較早的版本回傳 4 欄（沒有 rule_applies），CREATE OR REPLACE
--       不能改回傳欄位 ⇒ 停在「A8 是舊版、A7 還沒換」的庫，整份重貼會在這裡報錯。前置檢查已確認同名的
--       一定是本檔建的；DROP 用預設 RESTRICT（有別的東西依賴它就報錯、不會連帶刪掉別的）；
--       DROP 後立刻重建、補說明、收回／授權，都在這一組交易裡，不會有「沒有權限設定」的空檔。
-- ----------------------------------------------------------------------------
BEGIN;

DROP FUNCTION IF EXISTS public.rpc_preview_po_store_addition_extra(BIGINT);

CREATE OR REPLACE FUNCTION public.rpc_preview_po_store_addition_extra(
  p_po_id BIGINT
) RETURNS TABLE(
  po_item_id            BIGINT,
  campaign_id           BIGINT,
  post_po_cancelled_qty NUMERIC,
  prior_po_extra_qty    NUMERIC,
  rule_applies          BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
-- post_po_cancel_to_store:20261016000000
#variable_conflict use_column
DECLARE
  v_tenant UUID;
BEGIN
  PERFORM public._pr_qty_sync_assert_perm();

  v_tenant := public._current_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  RETURN QUERY
  WITH items AS (
    SELECT poi.id AS po_item_id
      FROM public.purchase_order_items poi
      JOIN public.purchase_orders po
        ON po.id = poi.po_id
     WHERE po.id = p_po_id
       AND po.tenant_id = v_tenant
  ),
  r AS (
    SELECT ppc.po_item_id, ppc.campaign_id, SUM(ppc.qty) AS qty
      FROM public.v_picking_post_po_cancelled ppc
      JOIN items it
        ON it.po_item_id = ppc.po_item_id
     WHERE ppc.po_id = p_po_id
     GROUP BY ppc.po_item_id, ppc.campaign_id
  ),
  -- 同一次追加（同一個 request_key）每家店各一列、數字一樣 ⇒ 每次追加只算一次
  e_per_request AS (
    SELECT pri.po_item_id, a.campaign_id, a.request_key,
           MAX(COALESCE(a.po_delta_qty - a.pr_delta_qty, 0)) AS qty
      FROM public.purchase_request_store_additions a
      JOIN public.purchase_request_items pri
        ON pri.id = a.pr_item_id
      JOIN items it
        ON it.po_item_id = pri.po_item_id
     WHERE a.tenant_id = v_tenant
     GROUP BY pri.po_item_id, a.campaign_id, a.request_key
  ),
  e AS (
    SELECT x.po_item_id, x.campaign_id, SUM(x.qty) AS qty
      FROM e_per_request x
     GROUP BY x.po_item_id, x.campaign_id
  ),
  -- 套新規則的（採購單品項, 團）：A7 寫入讀的就是這裡算出來的 rule_applies，條件只寫這一處
  ru AS (
    SELECT DISTINCT ri.po_item_id, ri.campaign_id
      FROM public.v_picking_po_rule_items ri
      JOIN items it
        ON it.po_item_id = ri.po_item_id
     WHERE ri.po_id = p_po_id
  )
  SELECT COALESCE(r.po_item_id, e.po_item_id),
         COALESCE(r.campaign_id, e.campaign_id),
         COALESCE(r.qty, 0),
         COALESCE(e.qty, 0),
         EXISTS (SELECT 1
                   FROM ru
                  WHERE ru.po_item_id = COALESCE(r.po_item_id, e.po_item_id)
                    AND ru.campaign_id = COALESCE(r.campaign_id, e.campaign_id))
    FROM r
    FULL JOIN e
      ON e.po_item_id = r.po_item_id
     AND e.campaign_id = r.campaign_id
   WHERE COALESCE(r.qty, 0) <> 0 OR COALESCE(e.qty, 0) <> 0
   ORDER BY 1, 2;
END;
$$;

COMMENT ON FUNCTION public.rpc_preview_po_store_addition_extra(BIGINT) IS
  '採購單頁「分店／批發追加」用（post_po_cancel_to_store:20261016000000）：每個（採購單品項, 團）叫貨後才取消的件數 R（含停用店）與以前追加時採購單比請購多加的件數 E。rule_applies＝這個（採購單品項, 團）套不套新規則（A7 寫入讀同一欄）：true 時採購單會加 max(0, 差額+N+R−E)（N＝這次追加件數），false 或沒有列時跟請購一樣 max(差額+N, 0)。唯讀。';

REVOKE ALL ON FUNCTION public.rpc_preview_po_store_addition_extra(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_preview_po_store_addition_extra(BIGINT) TO authenticated;

COMMIT;

-- ----------------------------------------------------------------------------
-- A7. 分店追加寫入：以 20261002000000:794 逐字為底（改的地方標「20261016000000」）
--     權限：CREATE OR REPLACE 保留原本的（20261002000000 收回 PUBLIC、只給 authenticated），不動。
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_add_po_store_demands(
  p_po_id        BIGINT,
  p_po_item_id   BIGINT,
  p_campaign_id  BIGINT,
  p_additions    JSONB,
  p_operator     UUID,
  p_request_key  UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- po_store_additions:20261002000000
-- post_po_cancel_to_store:20261016000000（以 20261002000000:794 逐字為底；改的地方標「20261016000000」）
DECLARE
  v_tenant            UUID;
  v_reason            TEXT;
  v_existing          RECORD;
  v_existing_po_item  BIGINT;
  v_po_qty_now        NUMERIC;
  v_po                RECORD;
  v_poi               RECORD;
  v_pr                RECORD;
  v_campaign          RECORD;
  v_ci                RECORD;
  v_res               RECORD;
  v_bad_count         INTEGER := 0;
  v_missing_store_ids TEXT;
  v_store_count       INTEGER := 0;
  v_store_added_qty   NUMERIC := 0;
  v_order_count       INTEGER := 0;
  v_delta             NUMERIC;
  v_demand            NUMERIC;
  v_already           NUMERIC;
  v_x                 NUMERIC := 0;
  v_x_po              NUMERIC := 0;   -- 20261016000000：採購單實際加幾件（請購仍是 v_x）
  v_r                 NUMERIC := 0;   -- 20261016000000：叫貨後才取消、照派原店的件數（含停用店）
  v_e                 NUMERIC := 0;   -- 20261016000000：以前追加時採購單比請購多加的件數（可能是負的）
  v_rule              BOOLEAN := FALSE;   -- 20261016000000：這個採購單品項、這一團套不套新規則
  v_pr_qty_after      NUMERIC;
  v_po_qty_after      NUMERIC;
  v_stores            JSONB;
  v_same_payload      BOOLEAN;
  r                   RECORD;
BEGIN
  PERFORM public._pr_qty_sync_assert_perm();

  v_tenant := public._current_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;

  IF p_operator IS NULL THEN
    RAISE EXCEPTION 'operator is required';
  END IF;

  IF auth.uid() IS NOT NULL AND p_operator <> auth.uid() THEN
    RAISE EXCEPTION 'operator must match current user';
  END IF;

  IF p_request_key IS NULL THEN
    RAISE EXCEPTION 'request key is required';
  END IF;

  -- ── 防重送（比照 #995）────────────────────────────────────────────────────
  -- 跟 #995 用**同一個前綴**的鎖：兩支共用 purchase_request_store_additions 與它的
  -- (tenant_id, request_key, store_id) 唯一索引，同一把 key 不管從哪一支進來都會排隊。
  PERFORM pg_advisory_xact_lock(hashtext('pr_store_add:' || p_request_key::TEXT));

  SELECT COUNT(*)                                     AS store_count,
         COUNT(DISTINCT a.pr_item_id)                 AS item_cnt,
         COUNT(DISTINCT a.campaign_id)                AS camp_cnt,
         MIN(a.pr_id)                                 AS pr_id,
         MIN(a.pr_item_id)                            AS pr_item_id,
         MIN(a.campaign_id)                           AS campaign_id,
         bool_and(a.created_by IS NOT DISTINCT FROM p_operator) AS same_operator,
         COALESCE(SUM(a.qty_added), 0)                AS store_added_qty,
         COALESCE(MAX(a.pr_delta_qty), 0)             AS pr_delta_qty,
         COALESCE(MAX(COALESCE(a.po_delta_qty, a.pr_delta_qty)), 0) AS po_delta_qty,  -- 20261016000000
         MAX(a.pr_qty_after)                          AS pr_qty_after,
         jsonb_agg(jsonb_build_object(
           'store_id', a.store_id,
           'qty', a.qty_added,
           'order_id', a.order_id,
           'order_item_id', a.order_item_id
         ) ORDER BY a.store_id)                       AS stores
    INTO v_existing
    FROM public.purchase_request_store_additions a
   WHERE a.tenant_id = v_tenant
     AND a.request_key = p_request_key;

  IF v_existing.store_count > 0 THEN
    SELECT pri.po_item_id
      INTO v_existing_po_item
      FROM public.purchase_request_items pri
     WHERE pri.id = v_existing.pr_item_id;

    SELECT poi.qty_ordered
      INTO v_po_qty_now
      FROM public.purchase_order_items poi
     WHERE poi.id = p_po_item_id
       AND poi.po_id = p_po_id;

    IF v_existing.item_cnt <> 1
       OR v_existing.camp_cnt <> 1
       OR NOT v_existing.same_operator
       OR v_existing_po_item IS DISTINCT FROM p_po_item_id
       OR v_po_qty_now IS NULL THEN
      RAISE EXCEPTION 'request key already used by another store-addition request';
    END IF;

    -- 同一個視窗重送：團、各店數量都要跟第一次**完全一樣**才回上次結果。
    -- 不一樣＝第一次可能其實已經寫進去（例：網路斷了沒收到回應），使用者又改了內容再送；
    -- 照舊回「上次結果」會讓畫面以為改過的內容生效了 → 擋下，請他重新整理看實際狀況。
    -- 各店數量的算法跟第一次寫紀錄時一樣（同一家店加總、取到小數三位，見下面 _po_store_add_input），
    -- 比對的是紀錄表上每列的 store_id／qty_added（表不加欄位）。
    IF v_existing.campaign_id <> p_campaign_id
       OR p_additions IS NULL
       OR jsonb_typeof(p_additions) <> 'array' THEN
      v_same_payload := FALSE;
    ELSE
      WITH sent_now AS (
        SELECT x.store_id::BIGINT AS store_id, SUM(x.qty)::NUMERIC(18,3) AS qty
          FROM jsonb_to_recordset(p_additions) AS x(store_id BIGINT, qty NUMERIC)
         GROUP BY x.store_id
      ),
      sent_before AS (
        SELECT a.store_id, a.qty_added AS qty
          FROM public.purchase_request_store_additions a
         WHERE a.tenant_id = v_tenant
           AND a.request_key = p_request_key
      )
      SELECT NOT EXISTS (SELECT store_id, qty FROM sent_now EXCEPT SELECT store_id, qty FROM sent_before)
         AND NOT EXISTS (SELECT store_id, qty FROM sent_before EXCEPT SELECT store_id, qty FROM sent_now)
        INTO v_same_payload;
    END IF;

    IF NOT v_same_payload THEN
      RAISE EXCEPTION '這個視窗之前已經送出過不同的團或數量（可能已經寫進去了），請關掉視窗、重新整理頁面確認後再操作；這次什麼都沒有改';
    END IF;

    -- 上次已經做完：照紀錄回傳，不重做。
    -- ⚠️ 採購單「改之前是多少」紀錄表沒有存（表不加欄位），所以 po_qty_before 回 NULL、
    --    po_qty_after 回**現值**（之後若有人再改過，就不是當時的數字）。
    RETURN jsonb_build_object(
      'po_id', p_po_id,
      'po_item_id', p_po_item_id,
      'campaign_id', p_campaign_id,
      'request_key', p_request_key,
      'pr_id', v_existing.pr_id,
      'pr_item_id', v_existing.pr_item_id,
      'stores', v_existing.stores,
      'store_count', v_existing.store_count,
      'store_added_qty', v_existing.store_added_qty,
      'po_added_qty', v_existing.po_delta_qty,   -- 20261016000000：舊紀錄沒有這一欄＝跟請購一樣
      'pr_added_qty', v_existing.pr_delta_qty,   -- 20261016000000
      'po_qty_before', NULL,
      'po_qty_after', v_po_qty_now,
      'pr_qty_after', v_existing.pr_qty_after,
      'idempotent', TRUE
    );
  END IF;

  -- ── 先檢查一次（還沒上鎖；不行就早點停，不必去搶鎖）──────────────────────
  v_reason := public._po_item_store_add_block_reason(p_po_item_id, p_campaign_id);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION '%', v_reason;
  END IF;

  -- ── 輸入（解析與分店檢查照抄 #995；數量檢查比 #995 嚴，見下）──────────────────
  IF p_additions IS NULL OR jsonb_typeof(p_additions) <> 'array' OR jsonb_array_length(p_additions) = 0 THEN
    RAISE EXCEPTION '請至少選一間分店或批發與數量';
  END IF;

  DROP TABLE IF EXISTS pg_temp._po_store_add_raw;
  CREATE TEMP TABLE _po_store_add_raw ON COMMIT DROP AS
  SELECT
    x.store_id::BIGINT AS store_id,
    x.qty::NUMERIC AS qty
  FROM jsonb_to_recordset(p_additions) AS x(store_id BIGINT, qty NUMERIC);

  -- 數量檢查（審查第三輪 P1）：每一列原始輸入、同一家店加總後，各查一次。
  --   ・NaN／Infinity：直接打 RPC 傳字串 "NaN"、"Infinity" 會被轉成 numeric 的特殊值；
  --     NaN 在 Postgres 裡比任何數字都大，光寫 `qty <= 0` 擋不住，會一路寫進採購單、請購單的數量與金額。
  --   ・寫入欄位只到小數三位（NUMERIC(18,3)）：0.0004 這種取到三位後變 0 的值，
  --     要在這裡用白話擋下，不要拖到資料表 CHECK 才報技術錯誤。
  --   ⇒ 最終條件：不是 NaN／±Infinity，而且取到小數三位後 > 0。
  --   （#995 rpc_add_pr_store_demands 有同樣的缺口，本檔沒動它。）
  SELECT COUNT(*)
    INTO v_bad_count
    FROM pg_temp._po_store_add_raw
   WHERE store_id IS NULL
      OR qty IS NULL
      OR qty::TEXT IN ('NaN', 'Infinity', '-Infinity')
      OR round(qty, 3) <= 0;

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION '分店／批發追加數量必須是大於 0 的數字（最多三位小數）';
  END IF;

  DROP TABLE IF EXISTS pg_temp._po_store_add_input;
  CREATE TEMP TABLE _po_store_add_input ON COMMIT DROP AS
  SELECT store_id, SUM(qty)::NUMERIC(18,3) AS qty
    FROM pg_temp._po_store_add_raw
   GROUP BY store_id;

  -- 同一家店拆成好幾列時，加總（取到小數三位）後再查一次同一個條件
  SELECT COUNT(*)
    INTO v_bad_count
    FROM pg_temp._po_store_add_input
   WHERE qty IS NULL
      OR qty::TEXT IN ('NaN', 'Infinity', '-Infinity')
      OR qty <= 0;

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION '分店／批發追加數量必須是大於 0 的數字（最多三位小數）';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(qty), 0)
    INTO v_store_count, v_store_added_qty
    FROM pg_temp._po_store_add_input;

  SELECT string_agg(i.store_id::TEXT, ',')
    INTO v_missing_store_ids
    FROM pg_temp._po_store_add_input i
    LEFT JOIN public.stores s
      ON s.id = i.store_id
     AND s.tenant_id = v_tenant
     AND s.is_active = TRUE
     AND s.deleted_at IS NULL
     AND COALESCE(s.store_kind, 'branch') IN ('branch', 'wholesale')
   WHERE s.id IS NULL;

  IF v_missing_store_ids IS NOT NULL THEN
    RAISE EXCEPTION '有分店／批發不存在、停用或已刪除：%', v_missing_store_ids;
  END IF;

  -- ── 上鎖＋寫入（包在內層區塊裡：被判死結／拿不到品項鎖時整筆不寫、改回白話訊息）────
  -- 上鎖順序：採購單（排隊等）→ 採購單品項（NOWAIT）→ 請購單與品項 → 團 → (團, 商品)。
  -- 為什麼這樣排、品項為什麼 NOWAIT：見檔頭「上鎖順序」。
  BEGIN
    SELECT po.id, po.po_no, po.status
      INTO v_po
      FROM public.purchase_orders po
     WHERE po.id = p_po_id
       AND po.tenant_id = v_tenant
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION '找不到這張採購單';
    END IF;

    SELECT poi.id, poi.sku_id, poi.qty_ordered
      INTO v_poi
      FROM public.purchase_order_items poi
     WHERE poi.id = p_po_item_id
       AND poi.po_id = p_po_id
     FOR UPDATE NOWAIT;

    IF NOT FOUND THEN
      RAISE EXCEPTION '這個商品不在這張採購單上';
    END IF;

    PERFORM 1
       FROM public.purchase_request_items pri
       JOIN public.purchase_requests pr
         ON pr.id = pri.pr_id
      WHERE pri.po_item_id = p_po_item_id
        AND pri.sku_id = v_poi.sku_id
        AND pr.tenant_id = v_tenant
      ORDER BY pri.id
      FOR UPDATE OF pr, pri;

    SELECT gbc.id, gbc.campaign_no, gbc.name, gbc.status
      INTO v_campaign
      FROM public.group_buy_campaigns gbc
     WHERE gbc.id = p_campaign_id
       AND gbc.tenant_id = v_tenant
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION '找不到這個團 %', p_campaign_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(p_campaign_id::TEXT), hashtext(v_poi.sku_id::TEXT));

    -- >>> RECHECK BEGIN（鎖完再跑一次同一套檢查 —— 不可拿掉）
    -- 第一次檢查到上鎖之間，可能有人開了進貨單、撿貨單、按了斷貨或改了團的狀態。
    -- 那些動作都會碰到我們剛鎖的列（UPDATE 或外鍵），所以這時候再查一次一定看得到。
    v_reason := public._po_item_store_add_block_reason(p_po_item_id, p_campaign_id);
    IF v_reason IS NOT NULL THEN
      RAISE EXCEPTION '%', v_reason;
    END IF;
    -- <<< RECHECK END

    -- 要改的那一列請購品項（檢查已保證：剛好一列、總數 = 各團明細加總）
    SELECT pr.id AS pr_id, pr.pr_no, pri.id AS pr_item_id, pri.qty_requested
      INTO v_pr
      FROM public.purchase_request_items pri
      JOIN public.purchase_requests pr
        ON pr.id = pri.pr_id
      JOIN public.purchase_request_item_campaigns pric
        ON pric.pr_item_id = pri.id
       AND pric.campaign_id = p_campaign_id
       AND pric.tenant_id = v_tenant
     WHERE pri.po_item_id = p_po_item_id
       AND pri.sku_id = v_poi.sku_id
       AND pr.tenant_id = v_tenant
       AND pr.status <> 'cancelled';

    IF NOT FOUND THEN
      RAISE EXCEPTION '內部錯誤：找不到要改的請購品項（po_item_id=%）', p_po_item_id;
    END IF;

    SELECT ci.id, ci.unit_price
      INTO v_ci
      FROM public.campaign_items ci
     WHERE ci.tenant_id = v_tenant
       AND ci.campaign_id = p_campaign_id
       AND ci.sku_id = v_poi.sku_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION '此品項不屬於指定原團';
    END IF;

    DROP TABLE IF EXISTS pg_temp._po_store_add_done;
    CREATE TEMP TABLE _po_store_add_done (
      store_id      BIGINT,
      qty           NUMERIC,
      order_id      BIGINT,
      order_item_id BIGINT,
      order_created BOOLEAN
    ) ON COMMIT DROP;

    -- >>> STEP1 BEGIN（第 1 步：每家店建店家內部單 +N）
    FOR r IN SELECT store_id, qty FROM pg_temp._po_store_add_input ORDER BY store_id
    LOOP
      SELECT o.o_order_id, o.o_order_item_id, o.o_order_created
        INTO v_res
        FROM public._store_add_internal_order_item(
               v_tenant, p_campaign_id, v_campaign.campaign_no, v_ci.id, v_poi.sku_id,
               v_ci.unit_price, r.store_id, r.qty, p_operator,
               format('【採購單分店／批發追加】%s', v_po.po_no),
               format('採購單 %s 分店／批發追加', v_po.po_no)
             ) o;

      INSERT INTO pg_temp._po_store_add_done (store_id, qty, order_id, order_item_id, order_created)
      VALUES (r.store_id, r.qty, v_res.o_order_id, v_res.o_order_item_id, v_res.o_order_created);

      IF v_res.o_order_created THEN
        v_order_count := v_order_count + 1;
      END IF;
    END LOOP;
    -- <<< STEP1 END

    -- 第 2 步：差額（加完店家單之後）。X = max(差額, 0)
    --   20261016000000（post_po_cancel_to_store）：差額、R、E、這個採購單品項這一團套不套新規則，
    --   **同一句**讀（同一個時間點的資料；裡面呼叫的都是 STABLE 函式，跟這一句用同一份快照）。
    --   分兩句讀的話，中間剛好有人把叫貨前就有的單取消：差額沒看到、R 看到了 ⇒ 同一件算兩次、採購單多加。
    --     R＝這個採購單品項、這一團叫貨後才取消的件數（含停用店：留給總倉決定，不拿去抵）
    --     E＝以前追加時採購單比請購多加的件數（可能是負的：那一次比請購少加）
    --   R、E、套不套（rule_applies）都讀 rpc_preview_po_store_addition_extra（畫面預估也讀它，同一份算法、
    --   同一條「套不套」）。它沒回這一列＝R、E 都是 0，套不套算出來都一樣 ⇒ 當不套。
    SELECT d.delta_qty, d.demand_qty, d.already_qty,
           COALESCE(re.r_qty, 0), COALESCE(re.e_qty, 0), COALESCE(re.rule_applies, FALSE)
      INTO v_delta, v_demand, v_already, v_r, v_e, v_rule
      FROM (SELECT 1) one
      LEFT JOIN public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id]) d
        ON d.campaign_id = p_campaign_id
       AND d.sku_id = v_poi.sku_id
      CROSS JOIN LATERAL (
        SELECT SUM(x.post_po_cancelled_qty) AS r_qty, SUM(x.prior_po_extra_qty) AS e_qty,
               bool_or(x.rule_applies) AS rule_applies
          FROM public.rpc_preview_po_store_addition_extra(p_po_id) x
         WHERE x.po_item_id = p_po_item_id
           AND x.campaign_id = p_campaign_id
      ) re;

    v_x := GREATEST(COALESCE(v_delta, 0), 0);

    -- 20261016000000：採購單要加幾件（請購仍是 +v_x，跟改前一模一樣）
    --   套新規則：max(0, 差額 + R − E) ⇒ 採購單加完＝現在有效的需求＋叫貨後取消照派的件數（不會往下減）。
    --     ⚠️ 可能比請購加得少（例：以前追加時多加過、後來那張單又復原；或叫貨後取消的是抵減單，R 是負的）。
    --   不套（分界前、一團兩張、一鍵關掉）：跟改前一樣＝v_x。
    v_x_po := CASE WHEN v_rule THEN GREATEST(0, COALESCE(v_delta, 0) + v_r - v_e) ELSE v_x END;

    -- >>> STEP3 BEGIN（第 3 步：請購單 +X，先各團明細、後總數 —— 順序反了 #982 守衛會擋）
    IF v_x > 0 THEN
      UPDATE public.purchase_request_item_campaigns
         SET qty_requested = qty_requested + v_x
       WHERE pr_item_id = v_pr.pr_item_id
         AND campaign_id = p_campaign_id
         AND tenant_id = v_tenant;

      IF NOT FOUND THEN
        RAISE EXCEPTION '內部錯誤：請購品項的這一團明細在途中消失了（pr_item_id=%）', v_pr.pr_item_id;
      END IF;

      UPDATE public.purchase_request_items
         SET qty_requested = qty_requested + v_x,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = v_pr.pr_item_id;

      -- 請購單總金額：跟 #995（20260924010000:372-380）同一個算法；line_subtotal 是 generated column
      UPDATE public.purchase_requests pr
         SET total_amount = COALESCE((
               SELECT SUM(pri.line_subtotal)
                 FROM public.purchase_request_items pri
                WHERE pri.pr_id = v_pr.pr_id
             ), 0),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE pr.id = v_pr.pr_id;
    END IF;
    -- <<< STEP3 END

    SELECT pri.qty_requested
      INTO v_pr_qty_after
      FROM public.purchase_request_items pri
     WHERE pri.id = v_pr.pr_item_id;

    -- 第 4 步：採購單 +X，再重算表頭（算法見檔頭：subtotal = SUM(qty_ordered * unit_cost)、
    --          total = subtotal、tax 不動 —— 跟 rpc_split_pr_to_pos 20260428120000:396-405 相同）
    IF v_x_po > 0 THEN   -- 20261016000000：採購單加 v_x_po（請購加 v_x）
      UPDATE public.purchase_order_items
         SET qty_ordered = qty_ordered + v_x_po,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = p_po_item_id;

      UPDATE public.purchase_orders po
         SET subtotal   = COALESCE((SELECT SUM(qty_ordered * unit_cost)
                                      FROM public.purchase_order_items WHERE po_id = po.id), 0),
             total      = COALESCE((SELECT SUM(qty_ordered * unit_cost)
                                      FROM public.purchase_order_items WHERE po_id = po.id), 0),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE po.id = p_po_id;
    END IF;

    SELECT poi.qty_ordered
      INTO v_po_qty_after
      FROM public.purchase_order_items poi
     WHERE poi.id = p_po_item_id;

    -- 第 5 步：每家店一列追加紀錄（表不加欄位；採購單從 pr_item_id → po_item_id 查得到）
    INSERT INTO public.purchase_request_store_additions (
      tenant_id, pr_id, pr_item_id, campaign_id, store_id,
      order_id, order_item_id, sku_id, qty_added, request_key, created_by,
      pr_delta_qty, pr_qty_after, po_delta_qty   -- 20261016000000：po_delta_qty
    )
    SELECT v_tenant, v_pr.pr_id, v_pr.pr_item_id, p_campaign_id, d.store_id,
           d.order_id, d.order_item_id, v_poi.sku_id, d.qty, p_request_key, p_operator,
           v_x, v_pr_qty_after, v_x_po
      FROM pg_temp._po_store_add_done d
     ORDER BY d.store_id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'store_id', d.store_id,
             'qty', d.qty,
             'order_id', d.order_id,
             'order_item_id', d.order_item_id,
             'order_created', d.order_created
           ) ORDER BY d.store_id), '[]'::JSONB)
      INTO v_stores
      FROM pg_temp._po_store_add_done d;

    RETURN jsonb_build_object(
      'po_id', p_po_id,
      'po_no', v_po.po_no,
      'po_item_id', p_po_item_id,
      'campaign_id', p_campaign_id,
      'campaign_no', v_campaign.campaign_no,
      'request_key', p_request_key,
      'pr_id', v_pr.pr_id,
      'pr_no', v_pr.pr_no,
      'pr_item_id', v_pr.pr_item_id,
      'stores', v_stores,
      'store_count', v_store_count,
      'store_added_qty', v_store_added_qty,
      'po_added_qty', v_x_po,                -- 20261016000000：採購單實際加幾件
      'pr_added_qty', v_x,                   -- 20261016000000：請購加幾件
      'post_po_cancelled_qty', v_r,          -- 20261016000000
      'prior_po_extra_qty', v_e,             -- 20261016000000
      'po_qty_before', v_poi.qty_ordered,
      'po_qty_after', v_po_qty_after,
      'pr_qty_before', v_pr.qty_requested,
      'pr_qty_after', v_pr_qty_after,
      'demand_qty', v_demand,
      'already_qty_before_sync', v_already,
      'delta_qty', v_delta,
      'created_order_count', v_order_count,
      'idempotent', FALSE
    );
  EXCEPTION
    -- >>> LOCKMSG BEGIN
    WHEN lock_not_available THEN
      -- 採購單品項被別人鎖著（例：同時有人按斷貨、調整已收量 —— 它們先鎖品項再鎖採購單）。
      -- 不等：等的話會跟對方互等（死結），Postgres 可能挑對方當犧牲者。
      RAISE EXCEPTION '有人同時在操作這張採購單的這個商品（例如按斷貨、調整已收量），請稍後再按一次；這次什麼都沒有改'
        USING DETAIL = 'lock_not_available: ' || SQLERRM;
    WHEN deadlock_detected THEN
      RAISE EXCEPTION '有人同時在操作這張採購單，請稍後再按一次；這次什麼都沒有改'
        USING DETAIL = 'deadlock_detected: ' || SQLERRM;
    -- <<< LOCKMSG END
  END;
END;
$$;

COMMENT ON FUNCTION public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) IS
  '採購單頁「分店／批發追加」：替分店／批發在原團加店家內部單（+N），再用 _pr_campaign_sku_remaining_rows 算出 X = max(差額, 0)，請購單（先各團明細後總數）+X。不重開團、不通知廠商。同一 request_key 重送：團與各店數量都一樣才回上次結果，不一樣就擋。採購單品項被別人鎖著或被判死結時整筆不寫、回白話訊息。（post_po_cancel_to_store:20261016000000）套新規則的採購單品項：採購單 +max(0, 差額 + R − E)（R＝叫貨後才取消、照派原店的件數，E＝以前追加時採購單比請購多加的件數；可能比請購加得少）；不套時採購單 +X（同改前）；套不套讀 rpc_preview_po_store_addition_extra 的 rule_applies（畫面預估讀同一欄）；差額、R、E、套不套同一句讀。紀錄表 po_delta_qty 記採購單實際加幾件。以 20261002000000 為底。';

COMMIT;

-- ----------------------------------------------------------------------------
-- A9. 唯讀：店家按取消前問「這張單（或這一項）現在取消，會不會照派原店」
--     回「取消後會照派原店」的品項、件數、採購單號、門市是否停用；沒有列＝不用提醒。
--     條件跟 v_picking_post_po_cancelled 同一套（套新規則的採購單品項、叫貨前就有、
--     不是轉入單、沒有斷貨標記、叫貨後沒有復原取消過），再加「現在還有效」。
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_order_cancel_po_notice(
  p_order_id BIGINT,
  p_item_id  BIGINT DEFAULT NULL
) RETURNS TABLE(
  order_item_id BIGINT,
  sku_id        BIGINT,
  sku_label     TEXT,
  qty           NUMERIC,
  po_id         BIGINT,
  po_no         TEXT,
  store_active  BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
-- post_po_cancel_to_store:20261016000000
#variable_conflict use_column
DECLARE
  v_tenant       UUID;
  v_order_tenant UUID;
BEGIN
  v_tenant := public._current_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  v_order_tenant := (SELECT co.tenant_id FROM public.customer_orders co WHERE co.id = p_order_id);
  IF v_order_tenant IS NULL OR v_order_tenant <> v_tenant THEN
    RAISE EXCEPTION '找不到這張訂單';
  END IF;

  RETURN QUERY
  SELECT coi.id,
         coi.sku_id,
         COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name, ''), ''),
         coi.qty,
         r.po_id,
         po.po_no,
         COALESCE(st.is_active AND st.deleted_at IS NULL, FALSE)
    FROM public.customer_orders co
    JOIN public.customer_order_items coi
      ON coi.order_id = co.id
    JOIN public.v_picking_po_rule_items r
      ON r.tenant_id = co.tenant_id
     AND r.campaign_id = co.campaign_id
     AND r.sku_id = coi.sku_id
    JOIN public.purchase_orders po
      ON po.id = r.po_id
    LEFT JOIN public.skus s
      ON s.id = coi.sku_id
    LEFT JOIN public.stores st
      ON st.id = co.pickup_store_id
   WHERE co.id = p_order_id
     AND (p_item_id IS NULL OR coi.id = p_item_id)
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND co.transferred_from_order_id IS NULL
     AND co.stockout_at IS NULL
     AND coi.status NOT IN ('cancelled', 'expired')
     AND coi.stockout_at IS NULL
     AND coi.created_at <= r.ordered_at
     -- 叫貨後復原取消過的單，再取消也不照派（v_picking_post_po_cancelled 條件 6）⇒ 不提醒
     AND NOT EXISTS (
           SELECT 1
             FROM public.customer_order_audit_log ra
            WHERE ra.order_id = co.id
              AND ra.entity_type = 'order'
              AND ra.entity_id = co.id
              AND ra.field = 'status'
              AND ra.before_value = to_jsonb('cancelled'::TEXT)
              AND ra.after_value <> to_jsonb('cancelled'::TEXT)
              AND ra.created_at > r.ordered_at)
   ORDER BY coi.id;
END;
$$;

COMMENT ON FUNCTION public.rpc_order_cancel_po_notice(BIGINT, BIGINT) IS
  '取消前提醒用（post_po_cancel_to_store:20261016000000）：這張單（或這一項）現在取消，哪些品項會照派原店（總倉已叫貨）。沒有列＝不用提醒（叫貨後復原取消過的單也不提醒：再取消照今天留總倉）。只讀、租戶檢查。';

REVOKE ALL ON FUNCTION public.rpc_order_cancel_po_notice(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_order_cancel_po_notice(BIGINT, BIGINT) TO authenticated;

COMMIT;

-- ----------------------------------------------------------------------------
-- A14. 唯讀：派貨工作台（B1）要顯示的「叫貨後取消照派原店／停用店沒帶」件數
--     輸入：一批商品 id（跟工作台讀 #1082 檢查表同一種分法：每批最多 100 個，各批同時發）。
--     輸出：一列＝（採購單, 採購單品項, 商品, 店）：件數合計、門市是否停用。
--       store_active＝true ：已經照派原店（派貨表裡已經算進那家店）
--       store_active＝false：停用店，沒帶進派貨表，留給總倉決定
--     只回自己公司的（_current_tenant_id()）；只到「採購單品項 × 店」，不回訂單、客人。
--     不另外檢查角色：能讀派貨表的人（登入後台的）都能用，範圍比派貨表窄（派貨表不分公司）。
-- ----------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_picking_post_po_cancelled_by_sku(
  p_sku_ids BIGINT[]
) RETURNS TABLE(
  po_id        BIGINT,
  po_item_id   BIGINT,
  sku_id       BIGINT,
  store_id     BIGINT,
  qty          NUMERIC,
  store_active BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
-- post_po_cancel_to_store:20261016000000
#variable_conflict use_column
DECLARE
  v_tenant UUID;
BEGIN
  v_tenant := public._current_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  IF COALESCE(cardinality(p_sku_ids), 0) > 100 THEN
    RAISE EXCEPTION '一次最多查 100 個商品，請分批';
  END IF;

  RETURN QUERY
  SELECT ppc.po_id,
         ppc.po_item_id,
         ppc.sku_id,
         ppc.store_id,
         SUM(ppc.qty),
         ppc.store_active
    FROM public.v_picking_post_po_cancelled ppc
   WHERE ppc.tenant_id = v_tenant
     AND ppc.sku_id = ANY (p_sku_ids)
   GROUP BY ppc.po_id, ppc.po_item_id, ppc.sku_id, ppc.store_id, ppc.store_active
   ORDER BY ppc.po_item_id, ppc.store_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_picking_post_po_cancelled_by_sku(BIGINT[]) IS
  '派貨工作台用（post_po_cancel_to_store:20261016000000）：這批商品（最多 100 個）在自己公司裡，叫貨後才取消的件數，按（採購單品項, 店）加總。store_active＝true 已照派原店、false 停用店沒帶（留給總倉決定）。只讀、租戶檢查。';

REVOKE ALL ON FUNCTION public.rpc_picking_post_po_cancelled_by_sku(BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_picking_post_po_cancelled_by_sku(BIGINT[]) TO authenticated;

COMMIT;

-- ----------------------------------------------------------------------------
-- A10. 權限：都寫在上面各組的交易裡（建立和收回同一個交易）。總整理：
--   兩支新 view：收回 PUBLIC／anon／authenticated，不給任何前端角色。
--   rpc_preview_po_store_addition_extra、rpc_order_cancel_po_notice、rpc_picking_post_po_cancelled_by_sku：
--     收回 PUBLIC／anon，只給 authenticated。
--   _picking_po_rule_cutover()：收回 PUBLIC／anon，只給 authenticated（不能再收：見檔頭「安全性」）。
--   三支重建：CREATE OR REPLACE 會保留原本的權限，不動。
-- ----------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';

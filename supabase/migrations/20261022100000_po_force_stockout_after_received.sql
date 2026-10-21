-- ============================================================================
-- 2026-10-22: 採購單「已到貨也能斷貨」（po_force_stockout:20261022100000）
--
-- 要解決什麼
--   貨已經到總倉、甚至已經派車到店，才發現這個商品不能賣（叫錯款式、品質有問題、廠商沒有正確款），
--   訂了這個商品、還沒取貨的客人要一次取消。現有兩顆鈕都按不動：
--     · 採購單「⛔ 斷貨」rpc_stockout_po_item（20260801000000_po_item_stockout.sql:274，只有這一版）
--       只准採購單「已發送／部分到貨」而且這一項還沒全到（:292-298）；就算部分到貨按得下去，
--       核心 _stockout_po_items（最新 20260902000010:232）也只有 qty_received = 0 才取消客人（:290-293）。
--     · 店家「刪除品項」rpc_delete_order_item（最新 20260831000090:732）擋「已確認／出貨中」（:759-768），
--       客人大多停在這兩種狀態。
--   ⇒ 10/21～22 契爾氏那次只能寫 SQL、審三輪（PR #1087 scripts/PROD-kiehls-cancel-2026-10/02_取消25筆.sql）。
--   這一檔把那份已審過的取消規則做成函式，給採購單編輯頁的新按鈕用。
--
-- 本檔新增（不改任何既有的表、函式、觸發器、資料）：
--   1. po_force_stockout_operators：誰能按（名單，tenant＋user_id）。
--      RLS 開著、一條政策都沒有、收回 PUBLIC／anon／authenticated／service_role 的權限
--      ⇒ 畫面、任何登入帳號都讀不到也改不到，只有在 Supabase SQL 視窗貼 SQL 才改得到。
--      （老闆 10/22 選甲：只限老闆與 Alex；不用 app_metadata.perms，因為任何管理員都能經
--        rpc_update_staff_perms 20260803000000:68 開給別人或自己。）
--   2. _force_stockout_plan(採購單品項, 公司)：內部用，算「會取消哪幾筆、每張單怎麼收尾、擋不擋、為什麼」。
--      預覽與執行都叫這一支 ⇒ 兩邊的範圍、擋下條件一定一致。前端不能叫。
--   3. rpc_can_force_stockout()：目前登入的人在不在名單（畫面用來決定要不要顯示按鈕）。
--   4. rpc_preview_force_stockout(採購單品項)：確認視窗用，只讀；不回客人姓名、電話。
--   5. rpc_force_stockout_po_item(採購單品項, 輸入的商品代碼, 要不要通知, 原因)：真的取消。
--
-- 取消的範圍（照斷貨核心找團的方法，20260902000010:295-301）：
--   這一項 → 請購單品項（pri.po_item_id）→ 那張請購單連到的所有團（purchase_request_campaigns）
--   × 這個商品 × 品項還沒取貨（pending／reserved／ready）× 單頭不是 已取消／已過期／已轉出。
--   ⚠ 是「那張請購單涵蓋的全部團」（機制索引「連帶二」）；預覽會列出每一團、每家店的件數給人核對。
--
-- 每一筆做的事（照 #1087 02 已審三輪的規則）：
--   ① 有從店內庫存配過貨的先還回（_release_order_item_stock_assignment，只有一版 20260827040000:60；
--      跟店家「刪除品項」第 6 步同一支 20260831000090:797-800）。沒配過貨的這一步什麼都不做。
--   ② 品項改「已取消」＋蓋斷貨時間 stockout_at（欄位同斷貨 (b) 段 20260902000010:318-336）。
--      ⇒ 後台、會員 App 這一項顯示「斷貨」；#1084「叫貨後才取消、照派原店」兩段都要求品項／單頭
--        沒有斷貨標記（20261016000000:844、:848、:877、:883），所以這些件數不會被再派出去。
--   ③ 每一筆寫一列編輯歷史（格式同刪除品項第 8 步 20260831000090:809-815），原因寫
--      「已到貨斷貨（採購單品項 #N）：<按的人填的原因>」，誰按的記在 operator_id。
--   ④ 訂單收尾照刪除品項第 9 步（20260831000090:817-853）：
--      ・單上還有別的待取品項 → 單子留著，只少這一項
--      ・取過貨、已沒有待取品項 → _close_orders_all_items_settled（只有一版 20260808000000:62）收尾成已完成
--      ・一件都沒取、沒付款、沒用儲值金 → 整單取消，單頭也蓋斷貨時間（照斷貨 (c) 段 20260902000010:337-363；
--        原本就有斷貨時間的不覆蓋）⇒ 客人 App「進行中」看得到「⛔ 供應商斷貨，本筆訂單已取消」
--        （supabase/functions/liff-api/index.ts:618-624、apps/member/src/components/OrderCard.tsx:307）
--      ・付過錢或用過儲值金 → 品項照樣取消，單子跟錢都不動，回傳清單給人工處理
--   ⑤ 勾了「通知」才寫 notifications（文字同斷貨 (d) 段 20260902000010:377-395；一位會員一則；
--      這一項之前按過、已經發過同一則的會員不再發）。notifications 表上沒有觸發器、不推 LINE。
--   ⑥ 寫完自我驗算：取消筆數、編輯歷史筆數、整單取消張數、斷貨時間、通知則數都要對；
--      這一刻被改到的品項／單頭只能是這一批（加上 ① 還回【內部】現貨池時那支改到的池子列）；
--      開團商品、採購單品項一列都不能被改。任何一項不對 → 整筆退回、什麼都沒改。
--   ⛔ 不動：採購單那一項（老闆 10/22 第 3 題：不標斷貨）、開團商品、派車單、庫存異動、月結、退回單。
--
-- 擋下（任何一項成立就不能按；預覽列出原因，執行時在任何寫入之前檢查）：
--   不在名單／不是這家公司／這一項還沒收過貨（請用原本的斷貨）／這一項已標斷貨或是斷貨拆出來的單／
--   採購單是草稿或已取消／找不到對應的團／同一團同一商品還有別張沒取消的採購單品項（一按會連那邊的客人
--   一起取消）／資料不正常（公司不一致、要取消的品項已帶斷貨標記、單頭狀態或單上品項狀態不常見、
--   會被整單取消的單原本就有取消時間）。
--   執行時另外要：輸入的商品代碼跟這一項的商品代碼逐字相同、原因不是空的。
--   已經沒有可取消的（例：按過一次）→ 回「已經做過／沒有可取消的」，什麼都不改。
--
-- 開工前四問（2026-10-22 阿寫查；工地 git 3fd9bdf0，線上 main 10/21）
--   Q1 現成機制：見上面「要解決什麼」。兩張訂單表上的觸發器（全部 migration 逐檔找 CREATE TRIGGER … ON …）：
--      trg_touch_corders／trg_touch_coi（20260423120000:329-332，函式最新 20260611000010:12）：修改時間＝這次交易時間；
--      trg_coi_backorder_source_clear（20260902030000:185-191）：本檔不碰待補貨欄位 → 不會觸發；
--      trg_release_idn_coverage（20260813002000:173-179）：整單取消時釋放綁在單上的減抵單覆蓋
--        （① 已先還掉；它可能順便收斂同一張減抵單上其他死單的殘留覆蓋，不動庫存、不動訂單，只回報張數）；
--      trg_no_mut_coa（20260605000001:27）：編輯歷史只能新增，本檔只新增。notifications 沒有觸發器。
--      開團商品、採購單品項本檔不改；兩張表的修改時間觸發器（20260423120000:323、20260422120004:255）
--      讓自我驗算看得出「有沒有被別的東西順手改到」。
--   Q2 用到的既有函式最新版：_release_order_item_stock_assignment 20260827040000:60（唯一）；
--      _close_orders_all_items_settled 20260808000000:62（唯一）；_current_tenant_id 20260707000020:25（最新）；
--      參考 _stockout_po_items 20260902000010:232、rpc_delete_order_item 20260831000090:732、
--      #1084 v_picking_post_po_cancelled 20261016000000:825（唯一）。
--   Q3 誰在用：新函式名全 repo 0 筆，沒撞名；採購單編輯頁是唯一呼叫點（新增）。
--   Q4 撞車：本檔只新增；阿寫不連 GitHub，開著的 PR 由 CEO 送出前查。
--
-- 安全性：
--   - 三支 rpc 都是 SECURITY DEFINER＋固定 search_path，函式內自己擋名單與公司（不靠 RLS）；
--     只 GRANT EXECUTE 給 authenticated（先收回 PUBLIC／anon／service_role）。
--   - _force_stockout_plan 不給任何前端角色。
--   - 名單表不給任何前端角色；只有 SQL 視窗（擁有者）改得到。
--   - 整份可以重貼：前置檢查認得本檔建的版本（說明／函式內文裡的記號）。
--
-- 上線順序：先貼本檔 → 貼開權限範本（scripts/PROD-force-stockout-2026-10/）→ 跑確認查詢全 ✅ → 才合併前端。
--   反過來的話：前端叫不到 rpc_can_force_stockout ⇒ 當成「不能按」，按鈕不出現；其他功能照常。
-- 一鍵關掉（清空名單、按鈕消失）、還原（拿掉本檔新物件）：scripts/PROD-force-stockout-2026-10/
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有 DDL 之前、只讀。任何一項不符就整份停下，一行都不會執行。
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing TEXT[] := ARRAY[]::TEXT[];
  v_name    TEXT;
  v_oid     REGCLASS;
  v_comment TEXT;
  v_def     TEXT;
  v_bad     TEXT;
BEGIN
  -- 本檔讀寫到的每一個欄位
  FOREACH v_name IN ARRAY ARRAY[
    'purchase_orders.id', 'purchase_orders.tenant_id', 'purchase_orders.po_no', 'purchase_orders.status',
    'purchase_orders.stockout_split_from_po_id',
    'purchase_order_items.id', 'purchase_order_items.po_id', 'purchase_order_items.sku_id',
    'purchase_order_items.qty_ordered', 'purchase_order_items.qty_received', 'purchase_order_items.stockout_at',
    'purchase_order_items.updated_at',
    'purchase_request_items.pr_id', 'purchase_request_items.po_item_id', 'purchase_request_items.source_campaign_id',
    'purchase_request_campaigns.pr_id', 'purchase_request_campaigns.campaign_id',
    'restock_requests.linked_pr_id', 'restock_requests.status',
    'skus.id', 'skus.tenant_id', 'skus.sku_code', 'skus.product_name', 'skus.variant_name',
    'group_buy_campaigns.id', 'group_buy_campaigns.tenant_id', 'group_buy_campaigns.campaign_no', 'group_buy_campaigns.name',
    'campaign_items.updated_at',
    'customer_orders.id', 'customer_orders.tenant_id', 'customer_orders.order_no', 'customer_orders.campaign_id',
    'customer_orders.pickup_store_id', 'customer_orders.member_id', 'customer_orders.status',
    'customer_orders.payment_status', 'customer_orders.wallet_paid_amount', 'customer_orders.cancelled_at',
    'customer_orders.stockout_at', 'customer_orders.updated_at', 'customer_orders.updated_by',
    'customer_order_items.id', 'customer_order_items.tenant_id', 'customer_order_items.order_id',
    'customer_order_items.sku_id', 'customer_order_items.qty', 'customer_order_items.status',
    'customer_order_items.stockout_at', 'customer_order_items.updated_at', 'customer_order_items.updated_by',
    'customer_order_audit_log.tenant_id', 'customer_order_audit_log.order_id', 'customer_order_audit_log.entity_type',
    'customer_order_audit_log.entity_id', 'customer_order_audit_log.field', 'customer_order_audit_log.before_value',
    'customer_order_audit_log.after_value', 'customer_order_audit_log.edit_reason',
    'customer_order_audit_log.operator_id', 'customer_order_audit_log.created_at',
    'notifications.tenant_id', 'notifications.member_id', 'notifications.category', 'notifications.title',
    'notifications.body', 'notifications.url', 'notifications.created_at',
    'inventory_deduction_notes.tenant_id', 'inventory_deduction_notes.cancelled_at',
    'members.id', 'members.member_type',
    'stores.id', 'stores.name',
    'picking_waves.id', 'picking_waves.tenant_id', 'picking_waves.wave_code', 'picking_waves.status',
    'picking_waves.source_po_id',
    'picking_wave_items.wave_id', 'picking_wave_items.sku_id', 'picking_wave_items.store_id',
    'picking_wave_items.qty', 'picking_wave_items.picked_qty', 'picking_wave_items.generated_transfer_id',
    'transfers.id', 'transfers.transfer_no', 'transfers.status', 'transfers.received_at',
    'transfer_items.transfer_id', 'transfer_items.sku_id', 'transfer_items.qty_shipped', 'transfer_items.qty_received'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_attribute a
       WHERE a.attrelid = to_regclass('public.' || split_part(v_name, '.', 1))
         AND a.attname = split_part(v_name, '.', 2)
         AND a.attnum > 0
         AND NOT a.attisdropped
    ) THEN
      v_missing := v_missing || ('public.' || v_name);
    END IF;
  END LOOP;

  -- 本檔會呼叫的既有函式（簽章要一模一樣）
  FOREACH v_name IN ARRAY ARRAY[
    'public._release_order_item_stock_assignment(bigint,numeric,uuid,text,timestamp with time zone)',
    'public._close_orders_all_items_settled(bigint[],uuid,timestamp with time zone)',
    'public._current_tenant_id()',
    'auth.uid()',
    'auth.jwt()'
  ] LOOP
    IF to_regprocedure(v_name) IS NULL THEN
      v_missing := v_missing || v_name;
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。缺少：\n%', array_to_string(v_missing, E'\n');
  END IF;

  -- 編輯歷史的欄位白名單要有 status（最新 20260902040000:58-63）
  v_def := (SELECT pg_get_constraintdef(c.oid)
              FROM pg_constraint c
             WHERE c.conrelid = 'public.customer_order_audit_log'::regclass
               AND c.conname = 'customer_order_audit_log_field_check');
  IF v_def IS NULL OR position('''status''' IN v_def) = 0 THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。customer_order_audit_log 的欄位白名單沒有 status（%）', coalesce(v_def, '找不到');
  END IF;

  -- 同名的東西：沒有＝第一次貼；有＝必須是本檔建的（重貼），否則停下。
  -- ⓘ 用指定（:=）而不是 SELECT … 進變數的寫法：Supabase 視窗會把那個字誤判成建表。
  v_oid := to_regclass('public.po_force_stockout_operators');
  IF v_oid IS NOT NULL THEN
    v_comment := obj_description(v_oid, 'pg_class');
    IF position('po_force_stockout:20261022100000' IN coalesce(v_comment, '')) = 0 THEN
      RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。public.po_force_stockout_operators 已經存在，但不是本檔建的（說明裡沒有本檔的記號），請先找工程師確認是誰的';
    END IF;
  END IF;

  v_bad := (SELECT string_agg(p.oid::regprocedure::text, '、')
              FROM pg_proc p
              JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public'
               AND p.proname IN ('_force_stockout_plan', 'rpc_can_force_stockout',
                                 'rpc_preview_force_stockout', 'rpc_force_stockout_po_item')
               AND position('po_force_stockout:20261022100000' IN p.prosrc) = 0);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。已經有同名、但不是本檔建的函式：%，請先找工程師確認是誰的', v_bad;
  END IF;
END
$precheck$;

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. 名單：誰能按「已到貨也能斷貨」
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.po_force_stockout_operators (
  tenant_id  UUID        NOT NULL,
  user_id    UUID        NOT NULL,
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, user_id)
);

COMMENT ON TABLE public.po_force_stockout_operators IS
  '採購單「已到貨也能斷貨」能按的帳號（po_force_stockout:20261022100000）。一列＝一家公司的一個登入帳號。RLS 開著、沒有任何政策、前端角色沒有權限 ⇒ 只有 SQL 視窗改得到。清空＝按鈕全部消失。';

ALTER TABLE public.po_force_stockout_operators ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.po_force_stockout_operators FROM PUBLIC, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. _force_stockout_plan：算範圍、每張單怎麼收尾、擋下原因（預覽與執行共用）
--    回傳 JSONB：
--      found, po_item_id, po_id, po_no, po_status, sku_id, sku_code, sku_label, qty_ordered, qty_received,
--      campaigns[{id,campaign_no,name}], other_po_items[{po_no,po_status,campaign_no}], restock_requests,
--      block_reasons[text],
--      targets[{item_id,order_id,order_no,order_status,campaign_id,store_id,member_key,item_status,qty,outcome,paid}]
--        outcome：keep（單上還有別的待取品項）／complete（取過貨→收尾完成）／cancel（整單取消）／paid（付過錢、單子不動）
--      untouched{picked_items,picked_qty,picked_orders,dead_items,dead_qty,dead_orders}
--      prior{items,qty,last_at}：這一項之前按過、現在還是取消的品項
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._force_stockout_plan(
  p_po_item_id BIGINT,
  p_tenant     UUID
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
-- po_force_stockout:20261022100000
DECLARE
  v_prefix    TEXT := '已到貨斷貨（採購單品項 #' || p_po_item_id || '）';
  v_poi       RECORD;
  v_sku       RECORD;
  v_blocks    TEXT[] := ARRAY[]::TEXT[];
  v_campaigns BIGINT[];
  v_camp_json JSONB;
  v_camp_bad  INTEGER;
  v_other     JSONB;
  v_restock   INTEGER;
  v_s         JSONB;
BEGIN
  SELECT poi.id, poi.po_id, poi.sku_id, poi.qty_ordered, poi.qty_received, poi.stockout_at,
         po.tenant_id, po.po_no, po.status AS po_status, po.stockout_split_from_po_id
    INTO v_poi
    FROM purchase_order_items poi
    JOIN purchase_orders po ON po.id = poi.po_id
   WHERE poi.id = p_po_item_id;

  IF NOT FOUND OR p_tenant IS NULL OR v_poi.tenant_id IS DISTINCT FROM p_tenant THEN
    RETURN jsonb_build_object(
      'found', FALSE,
      'po_item_id', p_po_item_id,
      'block_reasons', jsonb_build_array('找不到這個採購單品項（或不是這家公司的）'),
      'targets', '[]'::jsonb);
  END IF;

  SELECT sk.sku_code, sk.tenant_id,
         COALESCE(sk.product_name, sk.sku_code) || COALESCE('-' || sk.variant_name, '') AS label
    INTO v_sku
    FROM skus sk
   WHERE sk.id = v_poi.sku_id;
  IF NOT FOUND OR v_sku.tenant_id IS DISTINCT FROM p_tenant THEN
    v_blocks := array_append(v_blocks, '資料不正常：這一項的商品找不到，或不是這家公司的');
  END IF;

  -- ── 這一項本身 ──
  IF COALESCE(v_poi.qty_received, 0) <= 0 THEN
    v_blocks := array_append(v_blocks, '這一項還沒收過貨（已收 0）：請用原本的「⛔ 斷貨」');
  END IF;
  IF v_poi.stockout_at IS NOT NULL THEN
    v_blocks := array_append(v_blocks, ('這一項已經標過斷貨（'
      || to_char(v_poi.stockout_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI') || '）'));
  END IF;
  IF v_poi.stockout_split_from_po_id IS NOT NULL THEN
    v_blocks := array_append(v_blocks, '這張是斷貨拆出來的單，不能用這顆鈕');
  END IF;
  IF v_poi.po_status NOT IN ('sent', 'partially_received', 'fully_received', 'closed') THEN
    v_blocks := array_append(v_blocks, ('採購單狀態是「'
      || CASE v_poi.po_status WHEN 'draft' THEN '草稿' WHEN 'cancelled' THEN '已取消' ELSE v_poi.po_status END
      || '」，不能用這顆鈕'));
  END IF;

  -- ── 受影響的團：同斷貨核心 20260902000010:295-301（這一項 → 請購單品項 → 那張請購單連到的團）──
  SELECT COALESCE(array_agg(DISTINCT prc.campaign_id), '{}'::BIGINT[])
    INTO v_campaigns
    FROM purchase_order_items poi
    JOIN purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
   WHERE poi.id = p_po_item_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', gc.id, 'campaign_no', gc.campaign_no, 'name', gc.name)
                            ORDER BY gc.campaign_no, gc.id), '[]'::jsonb),
         count(*) FILTER (WHERE gc.tenant_id IS DISTINCT FROM p_tenant)
    INTO v_camp_json, v_camp_bad
    FROM group_buy_campaigns gc
   WHERE gc.id = ANY (v_campaigns);

  IF cardinality(v_campaigns) = 0 THEN
    v_blocks := array_append(v_blocks, '找不到這一項對應的團（請購單沒有連到任何團）');
  END IF;
  IF v_camp_bad > 0 THEN
    v_blocks := array_append(v_blocks, format('資料不正常：對應的團有 %s 個不是這家公司的', v_camp_bad));
  END IF;

  -- ── 同一團、同一商品，還有別張沒取消的採購單品項？（連法＝派貨需求表的 po_campaigns：
  --    請購單連到的團 ∪ 請購單品項的 source_campaign_id，20261016000000:775-790）──
  SELECT COALESCE(jsonb_agg(jsonb_build_object('po_no', o.po_no, 'po_status', o.po_status, 'campaign_no', o.campaign_no)
                            ORDER BY o.po_no, o.campaign_no), '[]'::jsonb)
    INTO v_other
    FROM (
      SELECT DISTINCT po2.po_no, po2.status AS po_status, gc.campaign_no
        FROM (
               SELECT pri.po_item_id, prc.campaign_id
                 FROM purchase_request_items pri
                 JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
                WHERE pri.po_item_id IS NOT NULL
                  AND prc.campaign_id = ANY (v_campaigns)
               UNION
               SELECT pri.po_item_id, pri.source_campaign_id
                 FROM purchase_request_items pri
                WHERE pri.po_item_id IS NOT NULL
                  AND pri.source_campaign_id = ANY (v_campaigns)
             ) l
        JOIN purchase_order_items poi2 ON poi2.id = l.po_item_id
        JOIN purchase_orders po2 ON po2.id = poi2.po_id
        LEFT JOIN group_buy_campaigns gc ON gc.id = l.campaign_id
       WHERE poi2.sku_id = v_poi.sku_id
         AND poi2.id <> p_po_item_id
         AND po2.status <> 'cancelled'
    ) o;
  IF jsonb_array_length(v_other) > 0 THEN
    v_blocks := array_append(v_blocks, ('同一團、同一個商品還有別張採購單（'
      || (SELECT string_agg(x ->> 'po_no' || '／' || COALESCE(x ->> 'campaign_no', '?'), '、')
            FROM jsonb_array_elements(v_other) x)
      || '）：按下去會連那張單要供貨的客人一起取消，請找工程師人工處理'));
  END IF;

  -- 補貨申請（不擋、只告知：這顆鈕不處理補貨申請的店家內部單）
  v_restock := (SELECT count(DISTINCT rr.id)
                  FROM purchase_request_items pri
                  JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                 WHERE pri.po_item_id = p_po_item_id
                   AND rr.status NOT IN ('cancelled', 'rejected'));

  -- ── 訂單面：範圍內的每一筆品項，分成「要取消」「不動」，並算每張單的收尾 ──
  WITH scope AS (
    SELECT coi.id AS item_id, coi.order_id, coi.tenant_id AS item_tenant, coi.qty,
           coi.status AS item_status, coi.stockout_at AS item_stockout_at,
           co.tenant_id AS order_tenant, co.order_no, co.status AS order_status, co.campaign_id,
           co.pickup_store_id AS store_id, co.member_id, co.payment_status, co.wallet_paid_amount,
           co.cancelled_at AS order_cancelled_at
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE co.campaign_id = ANY (v_campaigns)
       AND coi.sku_id = v_poi.sku_id
  ), tgt AS (
    SELECT s.*
      FROM scope s
     WHERE s.item_status IN ('pending', 'reserved', 'ready')
       AND s.order_status NOT IN ('cancelled', 'expired', 'transferred_out')
  ), tgt_o AS (
    SELECT o.order_id, o.order_status, o.order_cancelled_at,
           EXISTS (SELECT 1 FROM customer_order_items x
                    WHERE x.order_id = o.order_id
                      AND x.status IN ('pending', 'reserved', 'ready')
                      AND NOT EXISTS (SELECT 1 FROM tgt t2 WHERE t2.item_id = x.id)) AS has_open_left,
           EXISTS (SELECT 1 FROM customer_order_items x
                    WHERE x.order_id = o.order_id AND x.status = 'picked_up') AS has_picked,
           EXISTS (SELECT 1 FROM customer_order_items x
                    WHERE x.order_id = o.order_id
                      AND x.status NOT IN ('pending', 'reserved', 'ready', 'picked_up', 'cancelled', 'expired')) AS odd_item,
           (COALESCE(o.payment_status, 'unpaid') = 'paid' OR COALESCE(o.wallet_paid_amount, 0) <> 0) AS paid
      FROM (SELECT DISTINCT ON (t.order_id) t.order_id, t.order_status, t.order_cancelled_at,
                   t.payment_status, t.wallet_paid_amount
              FROM tgt t ORDER BY t.order_id) o
  ), tgt_o2 AS (
    SELECT o.*,
           CASE WHEN o.has_open_left THEN 'keep'
                WHEN o.has_picked    THEN 'complete'
                WHEN NOT o.paid      THEN 'cancel'
                ELSE 'paid' END AS outcome
      FROM tgt_o o
  ), prior AS (
    SELECT s.*
      FROM scope s
     WHERE s.item_status = 'cancelled'
       AND EXISTS (SELECT 1 FROM customer_order_audit_log a
                    WHERE a.order_id = s.order_id
                      AND a.entity_type = 'item'
                      AND a.entity_id = s.item_id
                      AND a.field = 'status'
                      AND left(a.edit_reason, length(v_prefix)) = v_prefix)
  )
  SELECT jsonb_build_object(
    'targets', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'item_id', t.item_id, 'order_id', t.order_id, 'order_no', t.order_no,
                 'order_status', t.order_status, 'campaign_id', t.campaign_id, 'store_id', t.store_id,
                 'member_key', COALESCE('m' || t.member_id::text, 'o' || t.order_id::text),
                 'item_status', t.item_status, 'qty', t.qty,
                 'outcome', o.outcome, 'paid', o.paid) ORDER BY t.item_id)
          FROM tgt t JOIN tgt_o2 o ON o.order_id = t.order_id), '[]'::jsonb),
    'bad_tenant',  (SELECT count(*) FROM scope s
                     WHERE s.order_tenant IS DISTINCT FROM p_tenant OR s.item_tenant IS DISTINCT FROM p_tenant),
    'bad_stockout', (SELECT count(*) FROM tgt WHERE tgt.item_stockout_at IS NOT NULL),
    'bad_head',    (SELECT count(*) FROM tgt_o2
                     WHERE tgt_o2.order_status NOT IN ('pending', 'confirmed', 'shipping', 'ready', 'partially_completed')),
    'bad_item',    (SELECT count(*) FROM tgt_o2 WHERE tgt_o2.odd_item),
    'bad_cancelled_at', (SELECT count(*) FROM tgt_o2
                          WHERE tgt_o2.outcome = 'cancel' AND tgt_o2.order_cancelled_at IS NOT NULL),
    'untouched', jsonb_build_object(
        'picked_items',  (SELECT count(*) FROM scope s WHERE s.item_status IN ('picked_up', 'partially_picked_up')),
        'picked_qty',    (SELECT COALESCE(sum(s.qty), 0) FROM scope s WHERE s.item_status IN ('picked_up', 'partially_picked_up')),
        'picked_orders', (SELECT count(DISTINCT s.order_id) FROM scope s WHERE s.item_status IN ('picked_up', 'partially_picked_up')),
        'dead_items',    (SELECT count(*) FROM scope s
                           WHERE s.item_status IN ('pending', 'reserved', 'ready')
                             AND s.order_status IN ('cancelled', 'expired', 'transferred_out')),
        'dead_qty',      (SELECT COALESCE(sum(s.qty), 0) FROM scope s
                           WHERE s.item_status IN ('pending', 'reserved', 'ready')
                             AND s.order_status IN ('cancelled', 'expired', 'transferred_out')),
        'dead_orders',   (SELECT count(DISTINCT s.order_id) FROM scope s
                           WHERE s.item_status IN ('pending', 'reserved', 'ready')
                             AND s.order_status IN ('cancelled', 'expired', 'transferred_out'))),
    'prior', jsonb_build_object(
        'items',   (SELECT count(*) FROM prior),
        'qty',     (SELECT COALESCE(sum(prior.qty), 0) FROM prior),
        'last_at', (SELECT max(a.created_at)
                      FROM customer_order_audit_log a
                     WHERE a.order_id IN (SELECT s.order_id FROM scope s)
                       AND a.entity_type = 'item'
                       AND a.field = 'status'
                       AND left(a.edit_reason, length(v_prefix)) = v_prefix))
  ) INTO v_s;

  IF (v_s ->> 'bad_tenant')::int > 0 THEN
    v_blocks := array_append(v_blocks, format('資料不正常：這些團裡有 %s 筆品項的公司跟這張採購單不一致', v_s ->> 'bad_tenant'));
  END IF;
  IF (v_s ->> 'bad_stockout')::int > 0 THEN
    v_blocks := array_append(v_blocks, format('資料不正常：要取消的品項裡有 %s 筆已經帶著斷貨標記', v_s ->> 'bad_stockout'));
  END IF;
  IF (v_s ->> 'bad_head')::int > 0 THEN
    v_blocks := array_append(v_blocks, format('資料不正常：有 %s 張單的單頭狀態不是 待確認／已確認／出貨中／可取貨／部分取貨，但還有等貨的品項', v_s ->> 'bad_head'));
  END IF;
  IF (v_s ->> 'bad_item')::int > 0 THEN
    v_blocks := array_append(v_blocks, format('資料不正常：有 %s 張單上有不常見的品項狀態（例如「部分領走」），收尾規則對不上', v_s ->> 'bad_item'));
  END IF;
  IF (v_s ->> 'bad_cancelled_at')::int > 0 THEN
    v_blocks := array_append(v_blocks, format('有 %s 張會被整單取消的單原本就有取消時間（以前取消過又被救回），請找工程師人工處理', v_s ->> 'bad_cancelled_at'));
  END IF;

  RETURN jsonb_build_object(
    'found',           TRUE,
    'po_item_id',      v_poi.id,
    'po_id',           v_poi.po_id,
    'po_no',           v_poi.po_no,
    'po_status',       v_poi.po_status,
    'sku_id',          v_poi.sku_id,
    'sku_code',        v_sku.sku_code,
    'sku_label',       v_sku.label,
    'qty_ordered',     v_poi.qty_ordered,
    'qty_received',    v_poi.qty_received,
    'campaigns',       v_camp_json,
    'other_po_items',  v_other,
    'restock_requests', v_restock,
    'block_reasons',   to_jsonb(v_blocks),
    'targets',         v_s -> 'targets',
    'untouched',       v_s -> 'untouched',
    'prior',           v_s -> 'prior');
END;
$$;

COMMENT ON FUNCTION public._force_stockout_plan(BIGINT, UUID) IS
  '已到貨也能斷貨（po_force_stockout:20261022100000）內部用：算會取消哪幾筆客人品項、每張單怎麼收尾、擋下原因。預覽與執行共用，前端不能叫。只讀。';

REVOKE ALL ON FUNCTION public._force_stockout_plan(BIGINT, UUID) FROM PUBLIC, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. rpc_can_force_stockout：目前登入的人在不在名單（同一家公司）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_can_force_stockout()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- po_force_stockout:20261022100000
  SELECT auth.uid() IS NOT NULL
     AND COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND EXISTS (SELECT 1
                   FROM public.po_force_stockout_operators o
                  WHERE o.user_id = auth.uid()
                    AND o.tenant_id::text = auth.jwt() ->> 'tenant_id')
$$;

COMMENT ON FUNCTION public.rpc_can_force_stockout() IS
  '已到貨也能斷貨（po_force_stockout:20261022100000）：目前登入的人在不在名單 po_force_stockout_operators（同一家公司）。畫面用來決定要不要顯示按鈕；真正的擋在預覽與執行裡。';

REVOKE ALL ON FUNCTION public.rpc_can_force_stockout() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_can_force_stockout() TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. rpc_preview_force_stockout：確認視窗用（只讀；不回客人姓名、電話）
--    回傳 _force_stockout_plan 的內容（targets 換成彙總）＋
--      summary{items,qty,offset_items,members,orders,orders_cancel,orders_complete,orders_keep,orders_paid,
--              by_store[{store_id,store_name,items,qty,members,orders}],
--              by_campaign[{campaign_id,campaign_no,items,qty}],
--              paid_orders[{store_name,order_no,outcome}]}
--      return_todo[{store_id,store_name,wave_code,wave_status,qty,transfer_no,transfer_status,
--                   qty_shipped,qty_received,received_at,stage}]
--        stage：received（店家已收貨）／in_transit（派出去了、店家還沒收）／not_shipped（撿貨單還沒派車）／
--               transfer_cancelled（派車單已取消）
--      can_execute, already_done, nothing_to_do
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_preview_force_stockout(
  p_po_item_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
-- po_force_stockout:20261022100000
DECLARE
  v_uid     UUID := auth.uid();
  v_tenant  UUID;
  v_plan    JSONB;
  v_sum     JSONB;
  v_todo    JSONB;
  v_n       INTEGER;
  v_blocked BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '請先登入' USING ERRCODE = '42501';
  END IF;
  v_tenant := public._current_tenant_id();
  IF NOT EXISTS (SELECT 1 FROM po_force_stockout_operators o
                  WHERE o.tenant_id = v_tenant AND o.user_id = v_uid) THEN
    RAISE EXCEPTION '沒有權限：「已到貨也能斷貨」只開給指定的帳號' USING ERRCODE = '42501';
  END IF;

  v_plan := public._force_stockout_plan(p_po_item_id, v_tenant);
  IF NOT COALESCE((v_plan ->> 'found')::boolean, FALSE) THEN
    RETURN (v_plan - 'targets') || jsonb_build_object(
      'can_execute', FALSE, 'already_done', FALSE, 'nothing_to_do', FALSE);
  END IF;

  WITH t AS (
    SELECT *
      FROM jsonb_to_recordset(v_plan -> 'targets')
        AS x(item_id BIGINT, order_id BIGINT, order_no TEXT, campaign_id BIGINT, store_id BIGINT,
             member_key TEXT, qty NUMERIC, outcome TEXT, paid BOOLEAN)
  ), o AS (
    SELECT DISTINCT t.order_id, t.order_no, t.store_id, t.outcome, t.paid FROM t
  )
  SELECT jsonb_build_object(
    'items',           (SELECT count(*) FROM t),
    'qty',             (SELECT COALESCE(sum(t.qty) FILTER (WHERE t.qty > 0), 0) FROM t),
    'offset_items',    (SELECT count(*) FROM t WHERE t.qty < 0),
    'members',         (SELECT count(DISTINCT t.member_key) FROM t),
    'orders',          (SELECT count(*) FROM o),
    'orders_cancel',   (SELECT count(*) FROM o WHERE o.outcome = 'cancel'),
    'orders_complete', (SELECT count(*) FROM o WHERE o.outcome = 'complete'),
    'orders_keep',     (SELECT count(*) FROM o WHERE o.outcome = 'keep'),
    'orders_paid',     (SELECT count(*) FROM o WHERE o.outcome = 'paid'),
    'by_store', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'store_id', g.store_id, 'store_name', COALESCE(st.name, '?'),
                 'items', g.items, 'qty', g.qty, 'members', g.members, 'orders', g.orders)
                 ORDER BY COALESCE(st.name, '?'), g.store_id)
          FROM (SELECT t.store_id, count(*) AS items,
                       COALESCE(sum(t.qty) FILTER (WHERE t.qty > 0), 0) AS qty,
                       count(DISTINCT t.member_key) AS members, count(DISTINCT t.order_id) AS orders
                  FROM t GROUP BY t.store_id) g
          LEFT JOIN stores st ON st.id = g.store_id), '[]'::jsonb),
    'by_campaign', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'campaign_id', g.campaign_id, 'campaign_no', gc.campaign_no,
                 'items', g.items, 'qty', g.qty)
                 ORDER BY gc.campaign_no, g.campaign_id)
          FROM (SELECT t.campaign_id, count(*) AS items,
                       COALESCE(sum(t.qty) FILTER (WHERE t.qty > 0), 0) AS qty
                  FROM t GROUP BY t.campaign_id) g
          LEFT JOIN group_buy_campaigns gc ON gc.id = g.campaign_id), '[]'::jsonb),
    -- 付過錢或用過儲值金的單：品項照樣取消、錢不動，要人工確認退款（單號＋店，不含客人資料）
    'paid_orders', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'store_name', COALESCE(st.name, '?'), 'order_no', o.order_no, 'outcome', o.outcome)
                 ORDER BY COALESCE(st.name, '?'), o.order_no)
          FROM o LEFT JOIN stores st ON st.id = o.store_id
         WHERE o.paid), '[]'::jsonb)
  ) INTO v_sum;

  -- 回收貨的待辦：這一項（同一張採購單、同一個商品）撿貨派出去到哪幾家店、收了沒
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'store_id', pwi.store_id,
           'store_name', COALESCE(st.name, '?'),
           'wave_code', pw.wave_code,
           'wave_status', pw.status,
           'qty', CASE WHEN pw.status = 'shipped' THEN COALESCE(pwi.picked_qty, pwi.qty) ELSE pwi.qty END,
           'transfer_no', t.transfer_no,
           'transfer_status', t.status,
           'qty_shipped', tq.qty_shipped,
           'qty_received', tq.qty_received,
           'received_at', t.received_at,
           'stage', CASE WHEN t.id IS NULL THEN 'not_shipped'
                         WHEN t.status IN ('received', 'closed') THEN 'received'
                         WHEN t.status = 'cancelled' THEN 'transfer_cancelled'
                         ELSE 'in_transit' END)
           ORDER BY COALESCE(st.name, '?'), pw.id), '[]'::jsonb)
    INTO v_todo
    FROM picking_waves pw
    JOIN picking_wave_items pwi ON pwi.wave_id = pw.id AND pwi.sku_id = (v_plan ->> 'sku_id')::BIGINT
    LEFT JOIN stores st ON st.id = pwi.store_id
    LEFT JOIN transfers t ON t.id = pwi.generated_transfer_id
    LEFT JOIN LATERAL (
      SELECT sum(ti.qty_shipped) AS qty_shipped, sum(ti.qty_received) AS qty_received
        FROM transfer_items ti
       WHERE ti.transfer_id = t.id
         AND ti.sku_id = (v_plan ->> 'sku_id')::BIGINT
    ) tq ON TRUE
   WHERE pw.source_po_id = (v_plan ->> 'po_id')::BIGINT
     AND pw.tenant_id = v_tenant
     AND pw.status <> 'cancelled';

  v_n := (v_sum ->> 'items')::int;
  v_blocked := jsonb_array_length(v_plan -> 'block_reasons') > 0;

  RETURN (v_plan - 'targets') || jsonb_build_object(
    'summary',       v_sum,
    'return_todo',   v_todo,
    'can_execute',   NOT v_blocked AND v_n > 0,
    'already_done',  v_n = 0 AND COALESCE((v_plan -> 'prior' ->> 'items')::int, 0) > 0,
    'nothing_to_do', v_n = 0);
END;
$$;

COMMENT ON FUNCTION public.rpc_preview_force_stockout(BIGINT) IS
  '已到貨也能斷貨（po_force_stockout:20261022100000）確認視窗：會取消幾筆／幾件／幾位（依店、依團）、每張單怎麼收尾、不動的、擋下原因、回收貨待辦。只讀；只給名單內的人；不回客人姓名電話。';

REVOKE ALL ON FUNCTION public.rpc_preview_force_stockout(BIGINT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_preview_force_stockout(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. rpc_force_stockout_po_item：真的取消（一個交易；任何一步不對就整筆退回）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_force_stockout_po_item(
  p_po_item_id       BIGINT,
  p_sku_code_confirm TEXT,
  p_notify           BOOLEAN,
  p_reason           TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- po_force_stockout:20261022100000
DECLARE
  v_uid         UUID := auth.uid();
  v_now         TIMESTAMPTZ := now();
  v_tenant      UUID;
  v_reason      TEXT := btrim(COALESCE(p_reason, ''));
  v_prefix      TEXT := '已到貨斷貨（採購單品項 #' || p_po_item_id || '）';
  v_tag_item    TEXT;
  v_tag_cancel  TEXT;
  v_tag_done    TEXT;
  c_tag_release CONSTANT TEXT := '已到貨斷貨';
  c_title       CONSTANT TEXT := '商品斷貨通知';
  v_body        TEXT;
  v_sku_id      BIGINT;
  v_campaigns   BIGINT[];
  v_plan        JSONB;
  v_items       BIGINT[];
  v_old_status  TEXT[];
  v_orders      BIGINT[];
  v_members     BIGINT[];
  v_prior_times TIMESTAMPTZ[];
  v_n_items     INTEGER;
  v_qty         NUMERIC;   -- 件數只算正數（抵減單是負數量，另外算筆數）
  v_n_offset    INTEGER;
  v_cnt         INTEGER;
  v_bad         INTEGER;
  v_open        INTEGER;
  v_picked      BOOLEAN;
  v_rel         JSONB;
  v_rel_rows    INTEGER := 0;
  v_rel_qty     NUMERIC := 0;
  v_rel_pool    NUMERIC := 0;
  v_pool_items  BIGINT[] := '{}';
  v_pool_orders BIGINT[] := '{}';
  v_cancel_ids  BIGINT[] := '{}';
  v_done_ids    BIGINT[] := '{}';
  v_keep_n      INTEGER := 0;
  v_paid_list   JSONB := '[]'::jsonb;
  v_notified    INTEGER := 0;
  v_mem_n       INTEGER;
  v_dn_void     INTEGER;
  r             RECORD;
BEGIN
  -- ════════ 檢查（任何寫入之前）════════

  -- 1. 名單＋公司
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '請先登入' USING ERRCODE = '42501';
  END IF;
  v_tenant := public._current_tenant_id();
  IF NOT EXISTS (SELECT 1 FROM po_force_stockout_operators o
                  WHERE o.tenant_id = v_tenant AND o.user_id = v_uid) THEN
    RAISE EXCEPTION '沒有權限：「已到貨也能斷貨」只開給指定的帳號' USING ERRCODE = '42501';
  END IF;

  -- 2. 原因、商品代碼、要不要通知
  IF v_reason = '' THEN
    RAISE EXCEPTION '請填原因（會寫進每一筆的編輯歷史）';
  END IF;
  IF char_length(v_reason) > 200 THEN
    RAISE EXCEPTION '原因太長（% 字），請精簡到 200 字以內', char_length(v_reason);
  END IF;
  IF COALESCE(p_sku_code_confirm, '') = '' THEN
    RAISE EXCEPTION '請輸入商品代碼確認';
  END IF;
  IF p_notify IS NULL THEN
    RAISE EXCEPTION '沒有指定要不要通知客人';
  END IF;

  -- 3. 上鎖：這一項（共用鎖，防有人同時改已收量／按斷貨）→ 範圍內有這個商品的訂單單頭 → 這些單的全部品項
  --    順序同刪除品項（先單頭後品項）；等 5 秒拿不到就停。
  PERFORM set_config('lock_timeout', '5s', true);
  BEGIN
    SELECT poi.sku_id INTO v_sku_id
      FROM purchase_order_items poi
      JOIN purchase_orders po ON po.id = poi.po_id
     WHERE poi.id = p_po_item_id
       AND po.tenant_id = v_tenant
       FOR SHARE OF poi;
    IF NOT FOUND THEN
      RAISE EXCEPTION '找不到這個採購單品項（或不是這家公司的）';
    END IF;

    SELECT COALESCE(array_agg(DISTINCT prc.campaign_id), '{}'::BIGINT[])
      INTO v_campaigns
      FROM purchase_request_items pri
      JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
     WHERE pri.po_item_id = p_po_item_id;

    PERFORM 1
       FROM customer_orders co
      WHERE co.campaign_id = ANY (v_campaigns)
        AND EXISTS (SELECT 1 FROM customer_order_items x WHERE x.order_id = co.id AND x.sku_id = v_sku_id)
      ORDER BY co.id
        FOR UPDATE;
    PERFORM 1
       FROM customer_order_items x
      WHERE x.order_id IN (SELECT co.id FROM customer_orders co
                            WHERE co.campaign_id = ANY (v_campaigns)
                              AND EXISTS (SELECT 1 FROM customer_order_items y
                                           WHERE y.order_id = co.id AND y.sku_id = v_sku_id))
      ORDER BY x.id
        FOR UPDATE;
  EXCEPTION
    WHEN lock_not_available OR deadlock_detected THEN
      RAISE EXCEPTION '有人正在操作這幾張訂單或這張採購單（例如店家正在取貨、改單、收貨），等了 5 秒還拿不到。什麼都沒改，請過幾分鐘再按一次。';
  END;

  -- 4. 算範圍與擋下原因（跟預覽同一支）
  v_plan := public._force_stockout_plan(p_po_item_id, v_tenant);
  IF jsonb_array_length(v_plan -> 'block_reasons') > 0 THEN
    RAISE EXCEPTION '不能執行，什麼都沒改：%',
      (SELECT string_agg(x, '；') FROM jsonb_array_elements_text(v_plan -> 'block_reasons') x);
  END IF;
  IF p_sku_code_confirm IS DISTINCT FROM (v_plan ->> 'sku_code') THEN
    RAISE EXCEPTION '輸入的商品代碼「%」跟這一項的商品代碼不一樣，什麼都沒改', p_sku_code_confirm;
  END IF;

  SELECT COALESCE(array_agg(t.item_id ORDER BY t.item_id), '{}'),
         COALESCE(array_agg(t.item_status ORDER BY t.item_id), '{}'),
         count(*), COALESCE(sum(t.qty) FILTER (WHERE t.qty > 0), 0), count(*) FILTER (WHERE t.qty < 0)
    INTO v_items, v_old_status, v_n_items, v_qty, v_n_offset
    FROM jsonb_to_recordset(v_plan -> 'targets') AS t(item_id BIGINT, item_status TEXT, qty NUMERIC);

  -- 5. 已經沒有可取消的 → 不重做
  IF v_n_items = 0 THEN
    RETURN jsonb_build_object(
      'ok', TRUE,
      'already_done', COALESCE((v_plan -> 'prior' ->> 'items')::int, 0) > 0,
      'nothing_to_do', TRUE,
      'items_cancelled', 0,
      'prior', v_plan -> 'prior');
  END IF;

  SELECT array_agg(DISTINCT t.order_id ORDER BY t.order_id)
    INTO v_orders
    FROM jsonb_to_recordset(v_plan -> 'targets') AS t(order_id BIGINT);

  -- 之前按過（同一個採購單品項）的時間：通知不重發用
  SELECT COALESCE(array_agg(DISTINCT a.created_at), '{}')
    INTO v_prior_times
    FROM customer_order_audit_log a
   WHERE a.tenant_id = v_tenant
     AND a.order_id IN (SELECT co.id FROM customer_orders co WHERE co.campaign_id = ANY (v_campaigns))
     AND a.entity_type = 'item'
     AND a.field = 'status'
     AND left(a.edit_reason, length(v_prefix)) = v_prefix;

  v_tag_item   := v_prefix || '：' || v_reason;
  v_tag_cancel := v_tag_item || '（這張單沒有其他待取品項，整單取消）';
  v_tag_done   := v_tag_item || '（其他品項都取過了，訂單收尾為完成）';

  -- ════════ 以下開始寫入 ════════

  -- 6. 有從店內庫存配過貨的先還回（刪除品項第 6 步同一支；沒配過貨的是 0、什麼都不做）
  FOR r IN SELECT unnest(v_items) AS id ORDER BY 1 LOOP
    v_rel := public._release_order_item_stock_assignment(r.id, NULL, v_uid, c_tag_release, v_now);
    IF COALESCE((v_rel ->> 'qty')::NUMERIC, 0) > 0 THEN
      v_rel_rows := v_rel_rows + 1;
      v_rel_qty  := v_rel_qty  + (v_rel ->> 'qty')::NUMERIC;
      v_rel_pool := v_rel_pool + COALESCE((v_rel ->> 'to_pool')::NUMERIC, 0);
    END IF;
  END LOOP;

  -- 6-1. 記下上面那支實際改到的【內部】現貨池列（越界檢查的允許清單）。到這裡為止，除了上面那支
  --      還回配貨，本函式還沒改任何品項／單頭；所以「修改時間＝這一刻」的列只可能是那支改的
  --      （_restore_internal_pool 20260825020000:194-246：池子品項改回待取或拆一列新的、被收尾的容器單開回來）。
  SELECT COALESCE(array_agg(x.id), '{}') INTO v_pool_items
    FROM customer_order_items x WHERE x.updated_at = v_now;
  SELECT COALESCE(array_agg(co.id), '{}') INTO v_pool_orders
    FROM customer_orders co WHERE co.updated_at = v_now;
  -- 它們只能是這家公司的【內部】現貨池容器（會員類型 store_internal 的單），而且不能是這次的目標訂單
  SELECT count(*) INTO v_bad
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE (co.id = ANY (v_pool_orders)
          OR co.id IN (SELECT x.order_id FROM customer_order_items x WHERE x.id = ANY (v_pool_items)))
     AND (COALESCE(m.member_type, '') <> 'store_internal' OR co.id = ANY (v_orders) OR co.tenant_id <> v_tenant);
  IF v_bad > 0 OR (v_rel_pool = 0 AND (cardinality(v_pool_items) > 0 OR cardinality(v_pool_orders) > 0)) THEN
    RAISE EXCEPTION '還回店內庫存配貨時改到了不是【內部】現貨池的單（% 張），跟預期不同。整筆退回、什麼都沒改，請截圖給工程師。', v_bad;
  END IF;

  -- 7. 品項改已取消＋斷貨時間（欄位同斷貨 (b) 段 20260902000010:320-327）；狀態要跟算範圍時一樣
  UPDATE customer_order_items x
     SET status      = 'cancelled',
         stockout_at = v_now,
         updated_by  = v_uid,
         updated_at  = v_now
    FROM unnest(v_items, v_old_status) AS t(id, st)
   WHERE x.id = t.id
     AND x.status = t.st;
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  IF v_cnt <> v_n_items THEN
    RAISE EXCEPTION '品項只改到 % 筆（應為 %），整筆退回、什麼都沒改，請重新整理再試。', v_cnt, v_n_items;
  END IF;

  -- 8. 編輯歷史：每一筆一列（格式同刪除品項第 8 步 20260831000090:809-815；before 照實際狀態）
  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  SELECT co.tenant_id, x.order_id, 'item', x.id, 'status',
         to_jsonb(t.st), to_jsonb('cancelled'::TEXT), v_tag_item, v_uid
    FROM unnest(v_items, v_old_status) AS t(id, st)
    JOIN customer_order_items x ON x.id = t.id
    JOIN customer_orders co ON co.id = x.order_id;
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  IF v_cnt <> v_n_items THEN
    RAISE EXCEPTION '編輯歷史只寫到 % 筆（應為 %），整筆退回、什麼都沒改。', v_cnt, v_n_items;
  END IF;

  -- 9. 訂單收尾（照刪除品項第 9 步 20260831000090:817-853）；結果要跟算範圍時一樣
  FOR r IN
    SELECT co.id, co.tenant_id, co.order_no, co.status, co.payment_status, co.wallet_paid_amount,
           COALESCE(st.name, '?') AS store_name,
           (SELECT DISTINCT t.outcome
              FROM jsonb_to_recordset(v_plan -> 'targets') AS t(order_id BIGINT, outcome TEXT)
             WHERE t.order_id = co.id) AS planned
      FROM customer_orders co
      LEFT JOIN stores st ON st.id = co.pickup_store_id
     WHERE co.id = ANY (v_orders)
     ORDER BY co.id
  LOOP
    SELECT count(*) FILTER (WHERE x.status IN ('pending', 'reserved', 'ready')),
           COALESCE(bool_or(x.status = 'picked_up'), FALSE)
      INTO v_open, v_picked
      FROM customer_order_items x
     WHERE x.order_id = r.id;

    IF v_open > 0 THEN
      IF r.planned <> 'keep' THEN
        RAISE EXCEPTION '有一張單（%）的收尾跟預覽算的不一樣，整筆退回、什麼都沒改，請重新整理再試。', r.store_name;
      END IF;
      v_keep_n := v_keep_n + 1;                  -- 單上還有別的待取品項 → 單子留著
    ELSIF v_picked THEN
      IF r.planned <> 'complete' THEN
        RAISE EXCEPTION '有一張單（%）的收尾跟預覽算的不一樣，整筆退回、什麼都沒改，請重新整理再試。', r.store_name;
      END IF;
      -- 取過貨、已沒有待取品項 → 收尾成已完成（跟斷貨、刪除品項同一支）
      IF public._close_orders_all_items_settled(ARRAY[r.id], v_uid, v_now) <> 1 THEN
        RAISE EXCEPTION '有一張單（%）收尾成已完成沒有成功，整筆退回、什麼都沒改。', r.store_name;
      END IF;
      INSERT INTO customer_order_audit_log
        (tenant_id, order_id, entity_type, entity_id, field,
         before_value, after_value, edit_reason, operator_id)
      VALUES
        (r.tenant_id, r.id, 'order', r.id, 'status',
         to_jsonb(r.status), to_jsonb('completed'::TEXT), v_tag_done, v_uid);
      v_done_ids := v_done_ids || r.id;
    ELSIF COALESCE(r.payment_status, 'unpaid') <> 'paid'
          AND COALESCE(r.wallet_paid_amount, 0) = 0 THEN
      IF r.planned <> 'cancel' THEN
        RAISE EXCEPTION '有一張單（%）的收尾跟預覽算的不一樣，整筆退回、什麼都沒改，請重新整理再試。', r.store_name;
      END IF;
      -- 一件都沒取過、也沒收過錢 → 整單取消＋單頭蓋斷貨時間（原本就有斷貨時間的不覆蓋）
      UPDATE customer_orders
         SET status       = 'cancelled',
             cancelled_at = v_now,
             stockout_at  = COALESCE(stockout_at, v_now),
             updated_by   = v_uid,
             updated_at   = v_now
       WHERE id = r.id
         AND status = r.status
         AND cancelled_at IS NULL;
      GET DIAGNOSTICS v_cnt = ROW_COUNT;
      IF v_cnt <> 1 THEN
        RAISE EXCEPTION '有一張單（%）整單取消沒有成功，整筆退回、什麼都沒改。', r.store_name;
      END IF;
      INSERT INTO customer_order_audit_log
        (tenant_id, order_id, entity_type, entity_id, field,
         before_value, after_value, edit_reason, operator_id)
      VALUES
        (r.tenant_id, r.id, 'order', r.id, 'status',
         to_jsonb(r.status), to_jsonb('cancelled'::TEXT), v_tag_cancel, v_uid);
      v_cancel_ids := v_cancel_ids || r.id;
    ELSE
      IF r.planned <> 'paid' THEN
        RAISE EXCEPTION '有一張單（%）的收尾跟預覽算的不一樣，整筆退回、什麼都沒改，請重新整理再試。', r.store_name;
      END IF;
      -- 付過錢／用過儲值金 → 單子與錢都不動，列出來給人工處理
    END IF;

    IF COALESCE(r.payment_status, 'unpaid') = 'paid' OR COALESCE(r.wallet_paid_amount, 0) <> 0 THEN
      v_paid_list := v_paid_list || jsonb_build_array(jsonb_build_object(
        'store_name', r.store_name, 'order_no', r.order_no,
        'outcome', CASE WHEN r.id = ANY (v_done_ids) THEN 'complete'
                        WHEN v_open > 0 THEN 'keep' ELSE 'paid' END));
    END IF;
  END LOOP;

  -- 10. 通知（勾了才發）：一位會員一則；這一項之前按過、已經發過同一則的會員不再發
  SELECT '您訂購的「' || COALESCE(sk.product_name, sk.sku_code) || COALESCE('-' || sk.variant_name, '')
         || '」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。'
    INTO v_body
    FROM skus sk WHERE sk.id = v_sku_id;

  SELECT COALESCE(array_agg(DISTINCT co.member_id), '{}')
    INTO v_members
    FROM customer_orders co
   WHERE co.id = ANY (v_orders) AND co.member_id IS NOT NULL;

  IF p_notify THEN
    INSERT INTO notifications (tenant_id, member_id, category, title, body, url)
    SELECT co.tenant_id, co.member_id, 'stockout', c_title, v_body, '/orders'
      FROM customer_orders co
     WHERE co.id = ANY (v_orders)
       AND co.member_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM notifications n
                        WHERE n.tenant_id = co.tenant_id
                          AND n.member_id = co.member_id
                          AND n.category = 'stockout'
                          AND n.title = c_title
                          AND n.body = v_body
                          AND n.created_at = ANY (v_prior_times))
     GROUP BY co.tenant_id, co.member_id;
    GET DIAGNOSTICS v_notified = ROW_COUNT;
  END IF;

  -- ════════ 11. 自我驗算（同一個交易裡、寫完再讀；不對就整筆退回）════════
  SELECT count(*) INTO v_cnt
    FROM customer_order_items i
    JOIN customer_orders co ON co.id = i.order_id
   WHERE co.campaign_id = ANY (v_campaigns) AND i.sku_id = v_sku_id
     AND i.status = 'cancelled' AND i.stockout_at = v_now;
  IF v_cnt <> v_n_items THEN
    RAISE EXCEPTION '自我驗算沒過：這一次取消的品項查到 % 筆（應為 %）。整筆退回、什麼都沒改。', v_cnt, v_n_items;
  END IF;

  SELECT count(*) INTO v_cnt
    FROM customer_order_items i
    JOIN customer_orders co ON co.id = i.order_id
   WHERE co.campaign_id = ANY (v_campaigns) AND i.sku_id = v_sku_id
     AND i.status IN ('pending', 'reserved', 'ready')
     AND (co.status NOT IN ('cancelled', 'expired', 'transferred_out') OR co.id = ANY (v_cancel_ids));
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '自我驗算沒過：這些團這個商品還有 % 筆沒取貨、也沒取消。整筆退回、什麼都沒改。', v_cnt;
  END IF;

  SELECT count(*) INTO v_cnt
    FROM customer_order_audit_log a
   WHERE a.tenant_id = v_tenant
     AND a.created_at = v_now
     AND a.edit_reason IN (v_tag_item, v_tag_cancel, v_tag_done);
  IF v_cnt <> v_n_items + cardinality(v_cancel_ids) + cardinality(v_done_ids) THEN
    RAISE EXCEPTION '自我驗算沒過：這一次的編輯歷史有 % 列（應為 %）。整筆退回、什麼都沒改。',
      v_cnt, v_n_items + cardinality(v_cancel_ids) + cardinality(v_done_ids);
  END IF;

  SELECT count(*) INTO v_cnt
    FROM customer_orders co
   WHERE co.id = ANY (v_orders) AND co.status = 'cancelled' AND co.cancelled_at = v_now
     AND co.stockout_at IS NOT NULL;
  IF v_cnt <> cardinality(v_cancel_ids) THEN
    RAISE EXCEPTION '自我驗算沒過：整單取消（而且單頭有斷貨時間）的單查到 % 張（應為 %）。整筆退回、什麼都沒改。',
      v_cnt, cardinality(v_cancel_ids);
  END IF;

  -- 斷貨時間＝這一刻的單頭，只能是整單取消的那幾張
  SELECT count(*) INTO v_cnt
    FROM customer_orders co
   WHERE co.stockout_at = v_now
     AND NOT (co.id = ANY (v_cancel_ids));
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '自我驗算沒過：有 % 張不是整單取消的單頭被蓋了斷貨時間。整筆退回、什麼都沒改。', v_cnt;
  END IF;

  -- 沒有多動到別的：這一刻改到的品項只能是這一批＋6-1 的池子品項；
  -- 改到的單頭只能是整單取消＋收尾完成＋6-1 的池子容器單
  SELECT count(*) INTO v_cnt
    FROM customer_order_items x
   WHERE x.updated_at = v_now
     AND NOT (x.id = ANY (v_items) OR x.id = ANY (v_pool_items));
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '自我驗算沒過：多改到 % 筆別的品項。整筆退回、什麼都沒改，請截圖給工程師。', v_cnt;
  END IF;
  SELECT count(*) INTO v_cnt
    FROM customer_orders co
   WHERE co.updated_at = v_now
     AND NOT (co.id = ANY (v_cancel_ids) OR co.id = ANY (v_done_ids) OR co.id = ANY (v_pool_orders));
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '自我驗算沒過：多改到 % 張別的單頭。整筆退回、什麼都沒改，請截圖給工程師。', v_cnt;
  END IF;
  SELECT count(*) INTO v_cnt
    FROM customer_orders co
   WHERE co.updated_at = v_now AND (co.id = ANY (v_cancel_ids) OR co.id = ANY (v_done_ids));
  IF v_cnt <> cardinality(v_cancel_ids) + cardinality(v_done_ids) THEN
    RAISE EXCEPTION '自我驗算沒過：整單取消＋收尾完成的單頭只改到 % 張（應為 %）。整筆退回、什麼都沒改。',
      v_cnt, cardinality(v_cancel_ids) + cardinality(v_done_ids);
  END IF;

  -- 開團商品、採購單品項一列都不能被改（老闆 10/22：採購單那一項不標斷貨）。兩張表都掛著修改時間觸發器
  -- （trg_touch_campaign_items 20260423120000:323、trg_touch_purchase_order_items 20260422120004:255）
  -- ⇒ 這個交易裡被改到的列，修改時間一定＝這一刻。
  SELECT (SELECT count(*) FROM campaign_items ci WHERE ci.updated_at = v_now)
       + (SELECT count(*) FROM purchase_order_items poi WHERE poi.updated_at = v_now)
    INTO v_cnt;
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '自我驗算沒過：開團商品或採購單品項被改到 % 列。整筆退回、什麼都沒改，請截圖給工程師。', v_cnt;
  END IF;

  -- 通知：勾了＝一位會員最多一則、只發給這一批的會員、則數對；沒勾＝一則都沒有
  SELECT count(*), count(DISTINCT n.member_id),
         count(*) FILTER (WHERE NOT (n.member_id = ANY (v_members)))
    INTO v_cnt, v_mem_n, v_bad
    FROM notifications n
   WHERE n.tenant_id = v_tenant
     AND n.created_at = v_now
     AND n.category = 'stockout';
  IF v_cnt <> v_notified OR v_mem_n <> v_cnt OR v_bad <> 0 OR (NOT p_notify AND v_cnt <> 0) THEN
    RAISE EXCEPTION '自我驗算沒過：這一刻的斷貨通知有 % 則（應為 %，會員 % 位、不在這一批的 % 則）。整筆退回、什麼都沒改。',
      v_cnt, v_notified, v_mem_n, v_bad;
  END IF;

  -- 這一刻被作廢的庫存減抵單（還回配貨那支＋整單取消時的觸發器，含順便收斂別張死單的；釋放不可逆，只回報）
  SELECT count(*) INTO v_dn_void
    FROM inventory_deduction_notes n
   WHERE n.tenant_id = v_tenant AND n.cancelled_at = v_now;

  RETURN jsonb_build_object(
    'ok',               TRUE,
    'already_done',     FALSE,
    'nothing_to_do',    FALSE,
    'at',               v_now,
    'po_item_id',       p_po_item_id,
    'sku_code',         v_plan ->> 'sku_code',
    'items_cancelled',  v_n_items,
    'qty_cancelled',    v_qty,
    'offset_items_cancelled', v_n_offset,
    'orders_cancelled', cardinality(v_cancel_ids),
    'orders_completed', cardinality(v_done_ids),
    'orders_kept',      v_keep_n,
    'paid_orders',      v_paid_list,
    'members_notified', v_notified,
    'released_rows',    v_rel_rows,
    'released_qty',     v_rel_qty,
    'released_to_pool', v_rel_pool,
    'dn_voided',        v_dn_void);
END;
$$;

COMMENT ON FUNCTION public.rpc_force_stockout_po_item(BIGINT, TEXT, BOOLEAN, TEXT) IS
  '已到貨也能斷貨（po_force_stockout:20261022100000）：取消這一項對應請購單涵蓋的團裡、這個商品、還沒取貨的客人品項（品項取消＋斷貨時間、配貨還回、編輯歷史、整單收尾、付過錢不動錢），勾了才發斷貨通知。不動採購單、開團商品、派車單、庫存、月結、退回單。只給名單內的人；要輸入商品代碼、填原因。一個交易，寫完自我驗算，不對整筆退回。';

REVOKE ALL ON FUNCTION public.rpc_force_stockout_po_item(BIGINT, TEXT, BOOLEAN, TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_force_stockout_po_item(BIGINT, TEXT, BOOLEAN, TEXT) TO authenticated;

COMMIT;

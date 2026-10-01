-- ============================================================================
-- ⛔⛔ 只可在【測試庫】跑，絕對不可在正式庫跑 ⛔⛔
--    整份雖然包在 BEGIN … ROLLBACK 裡、不留任何測試資料，
--    但「關團自動建請購單」會呼叫 rpc_next_pr_no()，請購單序號被用掉就回不來
--    （nextval 不受 ROLLBACK 回補）。正式庫會因此跳號。
--    下面第一段有硬擋：資料庫看起來像正式庫就直接停，一行測試都不會跑。
-- ----------------------------------------------------------------------------
-- 驗證腳本：請購還是草稿時可以重開＋關團只補差額
-- 對應 migration：supabase/migrations/20261001020000_reopen_draft_pr_and_delta_append.sql
-- 規格：公司\01_進行中\需求暨計畫_NEW-ERP請購草稿階段可重開與關團只補差額_2026-10-01.md（T4）
--
-- 前提：測試庫已經套用 #982（20260921001000、20260923090000）、#1049（20261001000000）
--       與本案 migration（20261001020000）。沒套會在第 0 段停下並寫明缺什麼。
--
-- 怎麼看結果：最後一個查詢每列一條檢查，「結果」欄 ✅ 通過／❌ 沒過，「說明」欄寫實際數字。
--
-- 情境（照真實操作順序走，全部呼叫線上同一批函式）
--   A、B 兩團同一天結單；C 先是草稿、晚一點才開。
--   1. 關 A（B 還開著）→ 先不建請購（deferred）
--   2. 關 B（當天最後一團）→ 自動建請購草稿，A、B 鎖定，訂單自動確認
--   3. 開 C、下單、關 C → 併進同一張草稿（第一次併入：結果要跟舊版「整團量」一樣）
--   4. 重開已鎖定的 A → 收單中；之前已確認的訂單維持已確認（Q1 A）
--   5. A 再下單（含一個請購單上原本沒有的商品）→ 關 A → 只補差額
--      → 每個商品「請購量 = 三團有效訂單總量」，各團明細有記
--   6. 再重開 A、不下單直接關 → 差額 0：不報錯、數量不變、照樣鎖定
--   7. #1049「同步最新開團數量」預覽 → 0 列要同步
--   8. 有品項轉成採購單 → 重開被擋，訊息中文、含請購單號
--   9. 請購單送出（submitted）→ 重開被擋，訊息中文、含請購單號
--  10. 已鎖定的團只延長（不重開）→ 被擋，訊息中文
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 第一段：硬擋 —— 看起來像正式庫就停
--   判斷依據：正式庫是真的在營運的資料庫，客人訂單數以萬計、請購單上千張
--   （正式庫訂單編號已經到 3 萬多，例：scripts/PROD-fix-order-37587-…）。
--   測試庫是 2026-08-12 只用 migration 建起來的空庫，幾乎沒有營運資料。
--   ⇒ 訂單 ≥ 2000 筆或請購單 ≥ 200 張，一律當成正式庫，停。
--   ⚠️ 這是「寧可擋錯」的保守判斷：若測試庫日後灌了大量資料，這裡也會擋下來，
--      那時請找工程師改門檻，不要把這段刪掉。
-- ----------------------------------------------------------------------------
DO $guard$
DECLARE
  v_orders BIGINT;
  v_prs    BIGINT;
BEGIN
  SELECT COUNT(*) INTO v_orders FROM public.customer_orders;
  SELECT COUNT(*) INTO v_prs FROM public.purchase_requests;

  IF v_orders >= 2000 OR v_prs >= 200 THEN
    RAISE EXCEPTION '⛔ 這個資料庫看起來是正式庫（客人訂單 % 筆、請購單 % 張），本驗證只可在測試庫跑。已停止，什麼都沒做。',
      v_orders, v_prs;
  END IF;
END
$guard$;


-- ----------------------------------------------------------------------------
-- 第 0 段：確認要驗的版本已經套上去
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF to_regclass('public.purchase_request_item_campaigns') IS NULL THEN
    v_missing := v_missing || '#982 的 purchase_request_item_campaigns 表（20260921001000）';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'rpc_preview_pr_qty_sync'
  ) THEN
    v_missing := v_missing || '#1049 的 rpc_preview_pr_qty_sync（20261001000000）';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'rpc_append_campaign_to_pr'
       AND p.prosrc LIKE '%_pr_campaign_sku_remaining_rows%'
  ) THEN
    v_missing := v_missing || '本案新版 rpc_append_campaign_to_pr（20261001020000）';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'rpc_quick_update_campaign_control'
       AND p.prosrc LIKE '%已送出，不能重開%'
  ) THEN
    v_missing := v_missing || '本案新版 rpc_quick_update_campaign_control（20261001020000）';
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'測試庫還沒套好，請先套用：\n%', array_to_string(v_missing, E'\n');
  END IF;
END
$precheck$;


SET LOCAL request.jwt.claim  = '{"tenant_id":"feed0000-0000-4000-8000-000000000041","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}';
SET LOCAL request.jwt.claims = '{"tenant_id":"feed0000-0000-4000-8000-000000000041","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}';

CREATE TEMP TABLE _t_env ON COMMIT DROP AS
SELECT
  'feed0000-0000-4000-8000-000000000041'::UUID AS tenant,
  'feed0000-0000-4000-8000-0000000000fe'::UUID AS operator,
  (CURRENT_DATE + 3)::DATE AS close_date;   -- 未來的日子：重開要未來的收單時間，且要留在同一天（Q2 A）

CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_txt(k TEXT PRIMARY KEY, v TEXT) ON COMMIT DROP;
CREATE TEMP TABLE _t_result(seq INT, item TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;


-- ----------------------------------------------------------------------------
-- 夾具：三個商品、三個團（同一天結單）
--   團  狀態   商品            一開始的訂單（全部 pending）
--   A   open   sku1 sku2 sku3  sku1×3、sku2×2
--   B   open   sku1            sku1×5
--   C   draft  sku1 sku2       （第 3 步才開團、才下單）
-- ----------------------------------------------------------------------------
DO $fixture$
DECLARE
  v_tenant  UUID := (SELECT tenant FROM _t_env);
  v_op      UUID := (SELECT operator FROM _t_env);
  v_date    DATE := (SELECT close_date FROM _t_env);
  v_end     TIMESTAMPTZ;
  v_loc     BIGINT;
  v_store   BIGINT;
  v_channel BIGINT;
  v_supplier BIGINT;
  v_product BIGINT;
  v_sku     BIGINT[] := ARRAY[]::BIGINT[];
  v_id      BIGINT;
  v_camp    BIGINT;
  v_order   BIGINT;
  i         INTEGER;
BEGIN
  v_end := (v_date + TIME '12:00') AT TIME ZONE 'Asia/Taipei';

  INSERT INTO locations (tenant_id, code, name, type)
  VALUES (v_tenant, 'ZZREOPEN-LOC', '【測試】重開總倉', 'central_warehouse')
  RETURNING id INTO v_loc;

  INSERT INTO stores (tenant_id, code, name, location_id)
  VALUES (v_tenant, 'ZZREOPEN-STORE', '【測試】重開門市', v_loc)
  RETURNING id INTO v_store;

  INSERT INTO line_channels (tenant_id, code, name, home_store_id)
  VALUES (v_tenant, 'ZZREOPEN-CH', '【測試】重開頻道', v_store)
  RETURNING id INTO v_channel;

  INSERT INTO suppliers (tenant_id, code, name)
  VALUES (v_tenant, 'ZZREOPEN-SUP', '【測試】重開供應商')
  RETURNING id INTO v_supplier;

  INSERT INTO _t_ctx(k, v) VALUES ('loc', v_loc), ('store', v_store), ('channel', v_channel), ('supplier', v_supplier);

  FOR i IN 1..3 LOOP
    INSERT INTO products (tenant_id, product_code, name, status)
    VALUES (v_tenant, 'ZZREOPEN-P' || i::TEXT, '【測試】重開商品' || i::TEXT, 'active')
    RETURNING id INTO v_product;

    INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
    VALUES (v_tenant, v_product, 'ZZREOPEN-SKU' || i::TEXT, '一包', 'active', '【測試】重開商品' || i::TEXT)
    RETURNING id INTO v_id;

    v_sku := v_sku || v_id;
    INSERT INTO _t_ctx(k, v) VALUES ('sku' || i::TEXT, v_id);
  END LOOP;

  -- 團 A、B、C
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, close_type, end_at)
  VALUES (v_tenant, 'ZZREOPEN-A', '【測試】重開團 A', 'open', 'fast', v_end)
  RETURNING id INTO v_camp;
  INSERT INTO _t_ctx(k, v) VALUES ('campA', v_camp);
  FOR i IN 1..3 LOOP
    INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
    VALUES (v_tenant, v_camp, v_sku[i], 100) RETURNING id INTO v_id;
    INSERT INTO _t_ctx(k, v) VALUES ('ciA' || i::TEXT, v_id);
  END LOOP;

  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, close_type, end_at)
  VALUES (v_tenant, 'ZZREOPEN-B', '【測試】重開團 B', 'open', 'fast', v_end)
  RETURNING id INTO v_camp;
  INSERT INTO _t_ctx(k, v) VALUES ('campB', v_camp);
  INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
  VALUES (v_tenant, v_camp, v_sku[1], 100) RETURNING id INTO v_id;
  INSERT INTO _t_ctx(k, v) VALUES ('ciB1', v_id);

  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, close_type, end_at)
  VALUES (v_tenant, 'ZZREOPEN-C', '【測試】重開團 C', 'draft', 'fast', v_end)
  RETURNING id INTO v_camp;
  INSERT INTO _t_ctx(k, v) VALUES ('campC', v_camp);
  FOR i IN 1..2 LOOP
    INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
    VALUES (v_tenant, v_camp, v_sku[i], 100) RETURNING id INTO v_id;
    INSERT INTO _t_ctx(k, v) VALUES ('ciC' || i::TEXT, v_id);
  END LOOP;

  -- 一開始的訂單
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZREOPEN-ORD-A1', (SELECT v FROM _t_ctx WHERE k = 'campA'), v_channel, v_store, 'pending', v_op, v_op)
  RETURNING id INTO v_order;
  INSERT INTO _t_ctx(k, v) VALUES ('ordA1', v_order);
  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  VALUES (v_tenant, v_order, (SELECT v FROM _t_ctx WHERE k = 'ciA1'), v_sku[1], 3, 100, 'pending'),
         (v_tenant, v_order, (SELECT v FROM _t_ctx WHERE k = 'ciA2'), v_sku[2], 2, 100, 'pending');

  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZREOPEN-ORD-B1', (SELECT v FROM _t_ctx WHERE k = 'campB'), v_channel, v_store, 'pending', v_op, v_op)
  RETURNING id INTO v_order;
  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  VALUES (v_tenant, v_order, (SELECT v FROM _t_ctx WHERE k = 'ciB1'), v_sku[1], 5, 100, 'pending');
END
$fixture$;


-- 共用小工具：這張請購單某商品的品項總數、某團某商品的明細數、某商品三團有效訂單總量
CREATE OR REPLACE FUNCTION pg_temp._t_item_qty(p_pr BIGINT, p_sku BIGINT) RETURNS NUMERIC
LANGUAGE sql AS $$
  SELECT COALESCE(SUM(qty_requested), 0) FROM public.purchase_request_items WHERE pr_id = p_pr AND sku_id = p_sku;
$$;

CREATE OR REPLACE FUNCTION pg_temp._t_attr_qty(p_pr BIGINT, p_sku BIGINT, p_camp BIGINT) RETURNS NUMERIC
LANGUAGE sql AS $$
  SELECT COALESCE(SUM(pric.qty_requested), 0)
    FROM public.purchase_request_item_campaigns pric
    JOIN public.purchase_request_items pri ON pri.id = pric.pr_item_id
   WHERE pri.pr_id = p_pr AND pri.sku_id = p_sku AND pric.campaign_id = p_camp;
$$;

CREATE OR REPLACE FUNCTION pg_temp._t_demand(p_sku BIGINT) RETURNS NUMERIC
LANGUAGE sql AS $$
  SELECT COALESCE(SUM(coi.qty), 0)
    FROM public.customer_orders co
    JOIN public.customer_order_items coi ON coi.order_id = co.id
   WHERE co.tenant_id = 'feed0000-0000-4000-8000-000000000041'::UUID
     AND co.order_no LIKE 'ZZREOPEN-%'
     AND co.status NOT IN ('cancelled','expired','transferred_out')
     AND coi.status NOT IN ('cancelled','expired')
     AND coi.sku_id = p_sku;
$$;

CREATE OR REPLACE FUNCTION pg_temp._t_ctx(p_k TEXT) RETURNS BIGINT
LANGUAGE sql AS $$ SELECT v FROM _t_ctx WHERE k = p_k; $$;


-- ----------------------------------------------------------------------------
-- 第 1～2 步：關 A（deferred）→ 關 B（自動建請購草稿、鎖 A B）
-- ----------------------------------------------------------------------------
DO $step12$
DECLARE
  v_op  UUID := (SELECT operator FROM _t_env);
  v_res JSONB;
  v_pr  BIGINT;
  v_pr_no TEXT;
  v_a   BIGINT := pg_temp._t_ctx('campA');
  v_b   BIGINT := pg_temp._t_ctx('campB');
BEGIN
  v_res := public.rpc_close_campaign(v_a, v_op);
  INSERT INTO _t_result VALUES (1, '關 A（B 還開著）→ 先不建請購',
    v_res->>'action' = 'deferred', 'action=' || COALESCE(v_res->>'action', 'NULL'));

  v_res := public.rpc_close_campaign(v_b, v_op);
  v_pr := NULLIF(v_res->>'pr_id', '')::BIGINT;
  INSERT INTO _t_result VALUES (2, '關 B（當天最後一團）→ 自動建請購草稿',
    v_res->>'action' = 'created' AND v_pr IS NOT NULL,
    'action=' || COALESCE(v_res->>'action', 'NULL') || '，reason=' || COALESCE(v_res->>'reason', '-'));

  IF v_pr IS NULL THEN
    RAISE EXCEPTION '第 2 步沒有建出請購單，後面無法繼續：%', v_res;
  END IF;

  SELECT pr_no INTO v_pr_no FROM public.purchase_requests WHERE id = v_pr;
  INSERT INTO _t_ctx(k, v) VALUES ('pr', v_pr);
  INSERT INTO _t_txt(k, v) VALUES ('pr_no', v_pr_no);

  INSERT INTO _t_result
  SELECT 3, 'A、B 都鎖定、請購單是草稿',
    (SELECT COUNT(*) FROM public.group_buy_campaigns WHERE id IN (v_a, v_b) AND status = 'locked') = 2
    AND (SELECT status FROM public.purchase_requests WHERE id = v_pr) = 'draft',
    'A=' || (SELECT status FROM public.group_buy_campaigns WHERE id = v_a)
    || '，B=' || (SELECT status FROM public.group_buy_campaigns WHERE id = v_b)
    || '，請購單=' || (SELECT status FROM public.purchase_requests WHERE id = v_pr);

  INSERT INTO _t_result
  SELECT 4, '建單後請購量 sku1=8、sku2=2',
    pg_temp._t_item_qty(v_pr, pg_temp._t_ctx('sku1')) = 8 AND pg_temp._t_item_qty(v_pr, pg_temp._t_ctx('sku2')) = 2,
    'sku1=' || pg_temp._t_item_qty(v_pr, pg_temp._t_ctx('sku1')) || '，sku2=' || pg_temp._t_item_qty(v_pr, pg_temp._t_ctx('sku2'));
END
$step12$;


-- ----------------------------------------------------------------------------
-- 第 3 步：開 C、下單、關 C → 第一次併入草稿（要跟舊版「整團量」結果一樣）
-- ----------------------------------------------------------------------------
DO $step3$
DECLARE
  v_tenant UUID := (SELECT tenant FROM _t_env);
  v_op  UUID := (SELECT operator FROM _t_env);
  v_end TIMESTAMPTZ := ((SELECT close_date FROM _t_env) + TIME '12:00') AT TIME ZONE 'Asia/Taipei';
  v_pr  BIGINT := pg_temp._t_ctx('pr');
  v_c   BIGINT := pg_temp._t_ctx('campC');
  v_s1  BIGINT := pg_temp._t_ctx('sku1');
  v_s2  BIGINT := pg_temp._t_ctx('sku2');
  v_order BIGINT;
  v_res JSONB;
  v_old1 NUMERIC;
  v_old2 NUMERIC;
BEGIN
  PERFORM * FROM public.rpc_quick_update_campaign_control(v_c, 'open', v_end, NULL);

  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZREOPEN-ORD-C1', v_c, pg_temp._t_ctx('channel'), pg_temp._t_ctx('store'), 'pending', v_op, v_op)
  RETURNING id INTO v_order;
  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  VALUES (v_tenant, v_order, pg_temp._t_ctx('ciC1'), v_s1, 1, 100, 'pending'),
         (v_tenant, v_order, pg_temp._t_ctx('ciC2'), v_s2, 4, 100, 'pending');

  -- 舊版「整團量」會得到的答案：原量 + C 整團量
  v_old1 := pg_temp._t_item_qty(v_pr, v_s1) + 1;
  v_old2 := pg_temp._t_item_qty(v_pr, v_s2) + 4;

  v_res := public.rpc_close_campaign(v_c, v_op);
  INSERT INTO _t_result VALUES (5, '關 C → 併進同一張草稿（appended）',
    v_res->>'action' = 'appended' AND (v_res->>'pr_id')::BIGINT = v_pr,
    'action=' || COALESCE(v_res->>'action', 'NULL') || '，reason=' || COALESCE(v_res->>'reason', '-'));

  INSERT INTO _t_result VALUES (6, '第一次併入：結果與舊版整團量相同（sku1=9、sku2=6）',
    pg_temp._t_item_qty(v_pr, v_s1) = v_old1 AND pg_temp._t_item_qty(v_pr, v_s2) = v_old2
    AND v_old1 = 9 AND v_old2 = 6,
    'sku1=' || pg_temp._t_item_qty(v_pr, v_s1) || '（舊版應為 ' || v_old1 || '），sku2='
    || pg_temp._t_item_qty(v_pr, v_s2) || '（舊版應為 ' || v_old2 || '）');

  INSERT INTO _t_result VALUES (7, '第一次併入：C 的來源團明細有記（sku1=1、sku2=4）',
    pg_temp._t_attr_qty(v_pr, v_s1, v_c) = 1 AND pg_temp._t_attr_qty(v_pr, v_s2, v_c) = 4,
    'sku1=' || pg_temp._t_attr_qty(v_pr, v_s1, v_c) || '，sku2=' || pg_temp._t_attr_qty(v_pr, v_s2, v_c));

  INSERT INTO _t_result VALUES (8, 'C 已鎖定、C 的訂單自動確認',
    (SELECT status FROM public.group_buy_campaigns WHERE id = v_c) = 'locked'
    AND (SELECT status FROM public.customer_orders WHERE id = v_order) = 'confirmed',
    '團=' || (SELECT status FROM public.group_buy_campaigns WHERE id = v_c)
    || '，訂單=' || (SELECT status FROM public.customer_orders WHERE id = v_order));
END
$step3$;


-- ----------------------------------------------------------------------------
-- 第 4 步：重開已鎖定的 A（請購單還是草稿）→ 可以；已確認的訂單維持已確認（Q1 A）
-- ----------------------------------------------------------------------------
DO $step4$
DECLARE
  v_a   BIGINT := pg_temp._t_ctx('campA');
  v_end TIMESTAMPTZ := ((SELECT close_date FROM _t_env) + TIME '20:00') AT TIME ZONE 'Asia/Taipei';
  v_err TEXT;
BEGIN
  BEGIN
    PERFORM * FROM public.rpc_quick_update_campaign_control(v_a, 'open', v_end, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  INSERT INTO _t_result VALUES (9, '重開已鎖定的 A（請購單還是草稿）→ 可以，狀態回收單中',
    v_err IS NULL AND (SELECT status FROM public.group_buy_campaigns WHERE id = v_a) = 'open',
    COALESCE('錯誤：' || v_err, '狀態=' || (SELECT status FROM public.group_buy_campaigns WHERE id = v_a)));

  INSERT INTO _t_result VALUES (10, '重開後 A 原本的訂單維持已確認（Q1 A）',
    (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_ctx('ordA1')) = 'confirmed',
    '訂單=' || (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_ctx('ordA1')));
END
$step4$;


-- ----------------------------------------------------------------------------
-- 第 5 步：A 再下單（sku1×4、新商品 sku3×2）→ 關 A → 只補差額
-- ----------------------------------------------------------------------------
DO $step5$
DECLARE
  v_tenant UUID := (SELECT tenant FROM _t_env);
  v_op  UUID := (SELECT operator FROM _t_env);
  v_pr  BIGINT := pg_temp._t_ctx('pr');
  v_a   BIGINT := pg_temp._t_ctx('campA');
  v_s1  BIGINT := pg_temp._t_ctx('sku1');
  v_s2  BIGINT := pg_temp._t_ctx('sku2');
  v_s3  BIGINT := pg_temp._t_ctx('sku3');
  v_order BIGINT;
  v_res JSONB;
  v_bad TEXT;
BEGIN
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZREOPEN-ORD-A2', v_a, pg_temp._t_ctx('channel'), pg_temp._t_ctx('store'), 'pending', v_op, v_op)
  RETURNING id INTO v_order;
  INSERT INTO _t_ctx(k, v) VALUES ('ordA2', v_order);
  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  VALUES (v_tenant, v_order, pg_temp._t_ctx('ciA1'), v_s1, 4, 100, 'pending'),
         (v_tenant, v_order, pg_temp._t_ctx('ciA3'), v_s3, 2, 100, 'pending');

  v_res := public.rpc_close_campaign(v_a, v_op);
  INSERT INTO _t_result VALUES (11, '重開後再關 A → 併進同一張草稿（appended）',
    v_res->>'action' = 'appended' AND (v_res->>'pr_id')::BIGINT = v_pr,
    'action=' || COALESCE(v_res->>'action', 'NULL') || '，reason=' || COALESCE(v_res->>'reason', '-')
    || '，append=' || COALESCE(v_res->>'append', '-'));

  INSERT INTO _t_result VALUES (12, '只補差額：sku1=13（不是 16）、sku2=6 不變、sku3=2（新列）',
    pg_temp._t_item_qty(v_pr, v_s1) = 13 AND pg_temp._t_item_qty(v_pr, v_s2) = 6 AND pg_temp._t_item_qty(v_pr, v_s3) = 2,
    'sku1=' || pg_temp._t_item_qty(v_pr, v_s1) || '，sku2=' || pg_temp._t_item_qty(v_pr, v_s2)
    || '，sku3=' || pg_temp._t_item_qty(v_pr, v_s3));

  -- 每個商品：請購量 = 三團有效訂單總量
  SELECT string_agg(format('sku%s 請購 %s ≠ 訂單 %s', i, pg_temp._t_item_qty(v_pr, s), pg_temp._t_demand(s)), '；')
    INTO v_bad
    FROM (VALUES (1, v_s1), (2, v_s2), (3, v_s3)) x(i, s)
   WHERE pg_temp._t_item_qty(v_pr, s) <> pg_temp._t_demand(s);
  INSERT INTO _t_result VALUES (13, '每個商品：請購量 = 總訂單量', v_bad IS NULL,
    COALESCE(v_bad, format('sku1=%s、sku2=%s、sku3=%s，全部等於訂單量',
      pg_temp._t_demand(v_s1), pg_temp._t_demand(v_s2), pg_temp._t_demand(v_s3))));

  INSERT INTO _t_result VALUES (14, 'A 的來源團明細：sku1=7、sku2=2、sku3=2',
    pg_temp._t_attr_qty(v_pr, v_s1, v_a) = 7 AND pg_temp._t_attr_qty(v_pr, v_s2, v_a) = 2
    AND pg_temp._t_attr_qty(v_pr, v_s3, v_a) = 2,
    'sku1=' || pg_temp._t_attr_qty(v_pr, v_s1, v_a) || '，sku2=' || pg_temp._t_attr_qty(v_pr, v_s2, v_a)
    || '，sku3=' || pg_temp._t_attr_qty(v_pr, v_s3, v_a));

  -- 每一列：品項總數 = 各團明細加總（#982 守衛的不變式）
  SELECT string_agg(format('品項 %s：總數 %s、明細 %s', pri.id, pri.qty_requested,
           COALESCE((SELECT SUM(qty_requested) FROM public.purchase_request_item_campaigns WHERE pr_item_id = pri.id), 0)), '；')
    INTO v_bad
    FROM public.purchase_request_items pri
   WHERE pri.pr_id = v_pr
     AND pri.qty_requested IS DISTINCT FROM
         (SELECT SUM(qty_requested) FROM public.purchase_request_item_campaigns WHERE pr_item_id = pri.id);
  INSERT INTO _t_result VALUES (15, '每一列：品項總數 = 各團明細加總', v_bad IS NULL, COALESCE(v_bad, '全部相等'));

  INSERT INTO _t_result VALUES (16, '同商品沒有被拆成兩列',
    NOT EXISTS (SELECT 1 FROM public.purchase_request_items WHERE pr_id = v_pr GROUP BY sku_id HAVING COUNT(*) > 1),
    (SELECT COUNT(*)::TEXT FROM public.purchase_request_items WHERE pr_id = v_pr) || ' 列');

  INSERT INTO _t_result VALUES (17, 'A 又鎖定、A 新下的訂單自動確認',
    (SELECT status FROM public.group_buy_campaigns WHERE id = v_a) = 'locked'
    AND (SELECT status FROM public.customer_orders WHERE id = v_order) = 'confirmed',
    '團=' || (SELECT status FROM public.group_buy_campaigns WHERE id = v_a)
    || '，訂單=' || (SELECT status FROM public.customer_orders WHERE id = v_order));

  INSERT INTO _t_result VALUES (18, '請購單總金額 = 品項小計加總',
    (SELECT total_amount FROM public.purchase_requests WHERE id = v_pr)
      = (SELECT COALESCE(SUM(line_subtotal), 0) FROM public.purchase_request_items WHERE pr_id = v_pr),
    '表頭=' || (SELECT total_amount FROM public.purchase_requests WHERE id = v_pr)
    || '，品項加總=' || (SELECT COALESCE(SUM(line_subtotal), 0) FROM public.purchase_request_items WHERE pr_id = v_pr));
END
$step5$;


-- ----------------------------------------------------------------------------
-- 第 6 步：再重開 A、不下單直接關 → 差額 0：不報錯、數量不變、照樣鎖定
-- ----------------------------------------------------------------------------
DO $step6$
DECLARE
  v_op  UUID := (SELECT operator FROM _t_env);
  v_pr  BIGINT := pg_temp._t_ctx('pr');
  v_a   BIGINT := pg_temp._t_ctx('campA');
  v_end TIMESTAMPTZ := ((SELECT close_date FROM _t_env) + TIME '21:00') AT TIME ZONE 'Asia/Taipei';
  v_before TEXT;
  v_after  TEXT;
  v_res JSONB;
  v_err TEXT;
BEGIN
  SELECT string_agg(sku_id || ':' || qty_requested, ',' ORDER BY sku_id) INTO v_before
    FROM public.purchase_request_items WHERE pr_id = v_pr;

  BEGIN
    PERFORM * FROM public.rpc_quick_update_campaign_control(v_a, 'open', v_end, NULL);
    v_res := public.rpc_close_campaign(v_a, v_op);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  SELECT string_agg(sku_id || ':' || qty_requested, ',' ORDER BY sku_id) INTO v_after
    FROM public.purchase_request_items WHERE pr_id = v_pr;

  INSERT INTO _t_result VALUES (19, '差額 0 再關團：不報錯（appended，新增 0、更新 0）',
    v_err IS NULL AND v_res->>'action' = 'appended'
    AND (v_res->'append'->>'inserted')::INT = 0 AND (v_res->'append'->>'updated')::INT = 0,
    COALESCE('錯誤：' || v_err, 'action=' || COALESCE(v_res->>'action', 'NULL') || '，append=' || COALESCE(v_res->>'append', '-')
      || '，reason=' || COALESCE(v_res->>'reason', '-')));

  INSERT INTO _t_result VALUES (20, '差額 0 再關團：請購量完全不變、A 照樣鎖定',
    v_before = v_after AND (SELECT status FROM public.group_buy_campaigns WHERE id = v_a) = 'locked',
    '前=' || COALESCE(v_before, '-') || '，後=' || COALESCE(v_after, '-')
    || '，團=' || (SELECT status FROM public.group_buy_campaigns WHERE id = v_a));
END
$step6$;


-- ----------------------------------------------------------------------------
-- 第 7 步：#1049「同步最新開團數量」預覽 → 0 列要同步
-- ----------------------------------------------------------------------------
INSERT INTO _t_result
SELECT 21, '「同步最新開團數量」預覽：沒有任何列要同步',
  COUNT(*) FILTER (WHERE needs_sync) = 0,
  COUNT(*) FILTER (WHERE needs_sync) || ' 列要同步（共 ' || COUNT(*) || ' 列）'
  FROM public.rpc_preview_pr_qty_sync(pg_temp._t_ctx('pr'));


-- ----------------------------------------------------------------------------
-- 第 8 步：有品項轉成採購單 → 重開被擋（中文、含請購單號）
-- ----------------------------------------------------------------------------
DO $step8$
DECLARE
  v_tenant UUID := (SELECT tenant FROM _t_env);
  v_op  UUID := (SELECT operator FROM _t_env);
  v_pr  BIGINT := pg_temp._t_ctx('pr');
  v_pr_no TEXT := (SELECT v FROM _t_txt WHERE k = 'pr_no');
  v_a   BIGINT := pg_temp._t_ctx('campA');
  v_end TIMESTAMPTZ := ((SELECT close_date FROM _t_env) + TIME '22:00') AT TIME ZONE 'Asia/Taipei';
  v_po  BIGINT;
  v_poi BIGINT;
  v_item BIGINT;
  v_err TEXT;
BEGIN
  INSERT INTO purchase_orders (tenant_id, po_no, supplier_id, dest_location_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZREOPEN-PO-1', pg_temp._t_ctx('supplier'), pg_temp._t_ctx('loc'), 'draft', v_op, v_op)
  RETURNING id INTO v_po;

  INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by)
  VALUES (v_po, pg_temp._t_ctx('sku3'), 2, 100, v_op, v_op)
  RETURNING id INTO v_poi;

  SELECT id INTO v_item FROM public.purchase_request_items WHERE pr_id = v_pr AND sku_id = pg_temp._t_ctx('sku3');
  UPDATE public.purchase_request_items SET po_item_id = v_poi WHERE id = v_item;

  BEGIN
    PERFORM * FROM public.rpc_quick_update_campaign_control(v_a, 'open', v_end, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  INSERT INTO _t_result VALUES (22, '請購單還是草稿但有品項轉採購單 → 重開被擋，中文且含請購單號',
    v_err IS NOT NULL AND v_err LIKE '%轉成採購單%' AND v_err LIKE '%' || v_pr_no || '%'
    AND (SELECT status FROM public.group_buy_campaigns WHERE id = v_a) = 'locked',
    COALESCE('訊息：' || v_err, '沒有被擋！狀態=' || (SELECT status FROM public.group_buy_campaigns WHERE id = v_a)));

  -- 還原，給下一步用
  UPDATE public.purchase_request_items SET po_item_id = NULL WHERE id = v_item;
END
$step8$;


-- ----------------------------------------------------------------------------
-- 第 9～10 步：請購單送出 → 重開被擋；已鎖定的團只延長 → 被擋
-- ----------------------------------------------------------------------------
DO $step9$
DECLARE
  v_pr  BIGINT := pg_temp._t_ctx('pr');
  v_pr_no TEXT := (SELECT v FROM _t_txt WHERE k = 'pr_no');
  v_a   BIGINT := pg_temp._t_ctx('campA');
  v_b   BIGINT := pg_temp._t_ctx('campB');
  v_end TIMESTAMPTZ := ((SELECT close_date FROM _t_env) + TIME '22:00') AT TIME ZONE 'Asia/Taipei';
  v_err TEXT;
BEGIN
  -- 10：已鎖定只延長（請購單仍是草稿時也一樣不放行）
  BEGIN
    PERFORM * FROM public.rpc_quick_update_campaign_control(v_a, NULL, v_end, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  INSERT INTO _t_result VALUES (23, '已鎖定的團只延長（不重開）→ 被擋，中文',
    v_err IS NOT NULL AND v_err LIKE '%已鎖定%',
    COALESCE('訊息：' || v_err, '沒有被擋！'));

  -- 9：送出請購單（模擬送審後的狀態）
  UPDATE public.purchase_requests SET status = 'submitted' WHERE id = v_pr;

  v_err := NULL;
  BEGIN
    PERFORM * FROM public.rpc_quick_update_campaign_control(v_a, 'open', v_end, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  INSERT INTO _t_result VALUES (24, '請購單已送出 → 重開已鎖定的 A 被擋，中文且含請購單號',
    v_err IS NOT NULL AND v_err LIKE '%已送出，不能重開%' AND v_err LIKE '%' || v_pr_no || '%'
    AND (SELECT status FROM public.group_buy_campaigns WHERE id = v_a) = 'locked',
    COALESCE('訊息：' || v_err, '沒有被擋！狀態=' || (SELECT status FROM public.group_buy_campaigns WHERE id = v_a)));

  v_err := NULL;
  BEGIN
    PERFORM * FROM public.rpc_quick_update_campaign_control(v_b, 'open', v_end, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  INSERT INTO _t_result VALUES (25, '請購單已送出 → 重開 B 也被擋',
    v_err IS NOT NULL AND v_err LIKE '%已送出，不能重開%',
    COALESCE('訊息：' || v_err, '沒有被擋！'));
END
$step9$;


-- ----------------------------------------------------------------------------
-- 結果
-- ----------------------------------------------------------------------------
SELECT
  seq AS "編號",
  CASE WHEN pass THEN '✅' ELSE '❌' END AS "結果",
  item AS "檢查",
  detail AS "說明"
FROM _t_result
UNION ALL
SELECT
  999,
  CASE WHEN COUNT(*) = 25 AND bool_and(pass) THEN '✅' ELSE '❌' END,
  '總結：25 條全部通過',
  COUNT(*) FILTER (WHERE pass) || ' / ' || COUNT(*) || ' 條通過'
FROM _t_result
ORDER BY 1;

ROLLBACK;

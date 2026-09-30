-- ============================================================================
-- 驗證腳本：請購草稿「同步最新開團數量」（精簡版）
-- 對應 migration：supabase/migrations/20261001000000_pr_qty_sync_minimal.sql
-- ----------------------------------------------------------------------------
-- ⛔ 只在本機 / 測試庫執行。整份包在交易裡，跑完 ROLLBACK 不留測資。
--
-- 2026-10-01 老闆裁示「砍到最小」，只留四條：
--   1. 原本 10、取消 1、沒有再加單 → 同步後變 9。（這是根因，一定要留）
--   2. 原本 10、取消 1、再加 2 → 11（並斷言不等於 12），連按第二次不重複加。
--   3. 已送審／品項已轉採購單 → 一律跳過不偷改。
--   4. 對照組：把共用零件換回「只處理正差額」的舊版 → 第 1 條必須紅。
-- ⛔ 其餘情境（需求歸零、合併多團、同團落在多張草稿、#982 守衛、權限、
--    寫入順序對照組）已按裁示刪除，不是註解掉。
--
-- 需求歸零不在本功能範圍內（老闆 2026-10-01：「需求歸零跟這個功能無關，
-- 沒有需求我就用斷貨處理就好」），所以這份驗證也不測它。
-- ============================================================================

BEGIN;

SET LOCAL request.jwt.claim  = '{"tenant_id":"feed0000-0000-4000-8000-000000000031","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}';
SET LOCAL request.jwt.claims = '{"tenant_id":"feed0000-0000-4000-8000-000000000031","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}';

CREATE TEMP TABLE _t_env ON COMMIT DROP AS
SELECT
  'feed0000-0000-4000-8000-000000000031'::UUID AS tenant,
  'feed0000-0000-4000-8000-0000000000fe'::UUID AS operator,
  (CURRENT_DATE - 1)::DATE AS close_date;

CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_result(seq INT, item TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;


-- ----------------------------------------------------------------------------
-- 夾具：一個商品、四個團、四張請購單
--   camp1 需求 9（原本 10 取消 1）      · pr1 草稿 pric=10        → 測 1
--   camp2 需求 11（10 取消 1 再加 2）   · pr2 草稿 pric=10        → 測 2
--   camp3 需求 9（10 取消 1）           · pr3 已送審 pric=10      → 測 3(a)
--   camp4 需求 9（10 取消 1）           · pr4 草稿、品項已轉 PO   → 測 3(b)
--                                          走 source_campaign_id 舊路徑 pri=3
--   camp5 需求 9（10 取消 1）           · pr5 草稿 pric=10        → 測 4 專用
--                                          ⛔ 前三條測試都不碰它，要保留「過期草稿 10
--                                             ／有效需求 9」這個負差額狀態給對照組用。
--
-- 🔴 造資料的順序必須跟真實世界一樣，不可以直接把終局狀態寫進 INSERT
--   `trg_pri_cross_close_date_duplicate_guard`（#982，20260921001000:534-604）
--   在 purchase_request_item_campaigns 的 AFTER INSERT 就會算
--   「這個團＋SKU 的未取消請購總量 > 目前有效需求」→ 直接 RAISE EXCEPTION。
--   ⇒ 若一開始就把取消掉的那筆訂單寫成 status='cancelled'，
--      建 pric（requested 10 vs demand 9）當場被退回，整份驗證第一圈就炸、
--      四條測試一條都跑不到。
--   ⇒ 所以分三段走：
--      ① 先把客人訂單建成「全額有效」（含日後會被取消的那筆，先給有效狀態）
--      ② 再建請購單草稿與明細（此時 demand ≥ requested，守衛過）
--      ③ 最後才把該取消的那筆 UPDATE 成 cancelled、把事後追加的量插進來
--      —— 這樣才會形成真實的「過期草稿 10／有效需求 9」。
-- ----------------------------------------------------------------------------
DO $fixture$
DECLARE
  v_tenant   UUID := (SELECT tenant FROM _t_env);
  v_op       UUID := (SELECT operator FROM _t_env);
  v_date     DATE := (SELECT close_date FROM _t_env);
  v_loc      BIGINT;
  v_store    BIGINT;
  v_channel  BIGINT;
  v_supplier BIGINT;
  v_product  BIGINT;
  v_sku      BIGINT;
  v_camp     BIGINT;
  v_ci       BIGINT;
  v_order    BIGINT;
  v_pr       BIGINT;
  v_item     BIGINT;
  v_po       BIGINT;
  v_po_item  BIGINT;
  v_camps    BIGINT[] := ARRAY[]::BIGINT[];
  i          INTEGER;

  -- ⭐ 三段式造資料（順序＝真實世界的順序，理由見上方紅字）
  --   v_orig   ＝ 建請購單「當下」的需求。必須 ≥ 該團在草稿裡的請購量，
  --              否則 #982 守衛會在 pric INSERT 當場退回。
  --   v_cancel ＝ 事後被客人取消掉的量。先以有效訂單插入，第 ③ 段才 UPDATE 成 cancelled。
  --   v_add    ＝ 事後才追加的量。第 ③ 段才插入新訂單。
  v_orig     NUMERIC[] := ARRAY[10, 10, 10, 10, 10];
  v_cancel   NUMERIC[] := ARRAY[ 1,  1,  1,  1,  1];
  v_add      NUMERIC[] := ARRAY[ 0,  2,  0,  0,  0];
  --  最後的有效需求 = orig - cancel + add = 9 / 11 / 9 / 9 / 9
BEGIN
  INSERT INTO locations (tenant_id, code, name, type)
  VALUES (v_tenant, 'ZZQSYNC-LOC', '【測試】數量同步總倉', 'central_warehouse')
  RETURNING id INTO v_loc;

  INSERT INTO stores (tenant_id, code, name, location_id)
  VALUES (v_tenant, 'ZZQSYNC-STORE', '【測試】數量同步門市', v_loc)
  RETURNING id INTO v_store;

  INSERT INTO line_channels (tenant_id, code, name, home_store_id)
  VALUES (v_tenant, 'ZZQSYNC-CH', '【測試】數量同步頻道', v_store)
  RETURNING id INTO v_channel;

  INSERT INTO suppliers (tenant_id, code, name)
  VALUES (v_tenant, 'ZZQSYNC-SUP', '【測試】數量同步供應商')
  RETURNING id INTO v_supplier;

  INSERT INTO products (tenant_id, product_code, name, status)
  VALUES (v_tenant, 'ZZQSYNC-P', '【測試】栗子地瓜', 'active')
  RETURNING id INTO v_product;

  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
  VALUES (v_tenant, v_product, 'ZZQSYNC-SKU', '1000g', 'active', '【測試】栗子地瓜')
  RETURNING id INTO v_sku;

  INSERT INTO _t_ctx(k, v) VALUES ('sku', v_sku), ('loc', v_loc), ('supplier', v_supplier);

  -- ---- ① 五個團 + 客人訂單（全部先建成有效）----
  FOR i IN 1..5 LOOP
    INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, end_at)
    VALUES (
      v_tenant, 'ZZQSYNC-CAMP-' || i::TEXT, '【測試】同步團 ' || i::TEXT, 'locked',
      ((v_date + TIME '12:00') AT TIME ZONE 'Asia/Taipei')
    )
    RETURNING id INTO v_camp;

    v_camps := v_camps || v_camp;
    INSERT INTO _t_ctx(k, v) VALUES ('camp' || i::TEXT, v_camp);

    INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
    VALUES (v_tenant, v_camp, v_sku, 180)
    RETURNING id INTO v_ci;

    INSERT INTO _t_ctx(k, v) VALUES ('ci' || i::TEXT, v_ci);

    -- 一直都有效的那部分（orig - cancel）
    IF v_orig[i] - v_cancel[i] > 0 THEN
      INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
      VALUES (v_tenant, 'ZZQSYNC-ORD-A' || i::TEXT, v_camp, v_channel, v_store, 'confirmed', v_op, v_op)
      RETURNING id INTO v_order;

      INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
      VALUES (v_tenant, v_order, v_ci, v_sku, v_orig[i] - v_cancel[i], 180, 'pending');
    END IF;

    -- 日後會被客人取消的那部分 —— ⚠️ 現在先給「有效」狀態，
    -- 等請購單草稿建好（demand ≥ requested、守衛過）才在第 ③ 段改成 cancelled。
    -- ⛔ 不要在這裡就寫 'cancelled'，那會讓 pric INSERT 被 #982 守衛當場退回。
    IF v_cancel[i] > 0 THEN
      INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
      VALUES (v_tenant, 'ZZQSYNC-ORD-X' || i::TEXT, v_camp, v_channel, v_store, 'confirmed', v_op, v_op)
      RETURNING id INTO v_order;

      INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
      VALUES (v_tenant, v_order, v_ci, v_sku, v_cancel[i], 180, 'pending');
    END IF;
  END LOOP;

  -- ---- ② pr1 / pr2 / pr3：一列一個團、pric 都是 10。pr3 是已送審 ----
  FOR i IN 1..3 LOOP
    INSERT INTO purchase_requests (
      tenant_id, pr_no, source_type, source_close_date, source_location_id,
      status, total_amount, created_by, updated_by
    ) VALUES (
      v_tenant, 'ZZQSYNC-PR-' || i::TEXT, 'close_date', v_date, v_loc,
      CASE WHEN i = 3 THEN 'submitted' ELSE 'draft' END, 0, v_op, v_op
    ) RETURNING id INTO v_pr;

    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
    ) VALUES (v_pr, v_sku, 10, v_supplier, 100, v_op, v_op)
    RETURNING id INTO v_item;

    INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
    VALUES (v_item, v_camps[i], v_tenant, 10);

    INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
    VALUES (v_pr, v_camps[i], v_tenant);

    UPDATE purchase_requests pr
       SET total_amount = COALESCE((SELECT SUM(pri.line_subtotal) FROM purchase_request_items pri WHERE pri.pr_id = v_pr), 0)
     WHERE pr.id = v_pr;

    INSERT INTO _t_ctx(k, v) VALUES ('pr' || i::TEXT, v_pr), ('item' || i::TEXT, v_item);
  END LOOP;

  -- ---- ② pr4：草稿，但品項已建立採購單（po_item_id 非空），掛 camp4 ----
  --   刻意用 source_campaign_id（沒有明細列）＝ 順便蓋到舊資料那條 legacy 路徑。
  INSERT INTO purchase_orders (
    tenant_id, po_no, supplier_id, dest_location_id, status, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PO-1', v_supplier, v_loc, 'sent', v_op, v_op)
  RETURNING id INTO v_po;

  INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by)
  VALUES (v_po, v_sku, 3, 100, v_op, v_op)
  RETURNING id INTO v_po_item;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-4', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, po_item_id,
    source_campaign_id, created_by, updated_by
  ) VALUES (v_pr, v_sku, 3, v_supplier, 100, v_po_item, v_camps[4], v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO _t_ctx(k, v) VALUES ('pr4', v_pr), ('item4', v_item), ('po_item', v_po_item);

  -- ---- ② pr5：草稿、pric=10，掛 camp5。⛔ 對照組專用，前三條測試都不准碰 ----
  --   測 4 需要一個「還沒同步過」的負差額（草稿 10 / 需求 9）。
  --   ⚠️ 不能在測 4 當場把別張單改回 10 —— #982 守衛會擋（requested 10 > demand 9），
  --      那正是這份夾具要分三段走的原因。所以留一張乾淨的單給它。
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-5', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
  ) VALUES (v_pr, v_sku, 10, v_supplier, 100, v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
  VALUES (v_item, v_camps[5], v_tenant, 10);

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr, v_camps[5], v_tenant);

  INSERT INTO _t_ctx(k, v) VALUES ('pr5', v_pr), ('item5', v_item);
END
$fixture$;


-- ----------------------------------------------------------------------------
-- 第 ③ 段：請購單都建好之後，才真的「取消訂單」與「追加訂單」
--   到這一行為止，草稿數字都還跟需求一致（守衛才過得去）；跑完這一段，
--   草稿就變成老闆看到的「過期數字」，測試才有東西可以同步。
--   ⛔ 這段一定要在 $fixture$ 之後、所有測試之前，順序不可調動。
-- ----------------------------------------------------------------------------
DO $mutate$
DECLARE
  v_tenant  UUID := (SELECT tenant FROM _t_env);
  v_op      UUID := (SELECT operator FROM _t_env);
  v_sku     BIGINT := (SELECT v FROM _t_ctx WHERE k = 'sku');
  v_channel BIGINT;
  v_store   BIGINT;
  v_camp    BIGINT;
  v_ci      BIGINT;
  v_order   BIGINT;
  v_add     NUMERIC[] := ARRAY[0, 2, 0, 0, 0];
  i         INTEGER;
BEGIN
  SELECT id INTO v_channel FROM line_channels
   WHERE tenant_id = v_tenant AND code = 'ZZQSYNC-CH';
  SELECT id INTO v_store FROM stores
   WHERE tenant_id = v_tenant AND code = 'ZZQSYNC-STORE';

  -- ③-1 客人取消：ORD-X 那幾筆整筆作廢（訂單層與明細層都要，需求算式兩層都濾）
  UPDATE customer_order_items coi
     SET status = 'cancelled', updated_by = v_op
    FROM customer_orders co
   WHERE co.id = coi.order_id
     AND co.tenant_id = v_tenant
     AND co.order_no LIKE 'ZZQSYNC-ORD-X%';

  UPDATE customer_orders
     SET status = 'cancelled', updated_by = v_op
   WHERE tenant_id = v_tenant
     AND order_no LIKE 'ZZQSYNC-ORD-X%';

  -- ③-2 事後追加（只有 camp2 追加 2 件 ⇒ 10 - 1 + 2 = 11）
  FOR i IN 1..5 LOOP
    CONTINUE WHEN v_add[i] <= 0;

    SELECT v INTO v_camp FROM _t_ctx WHERE k = 'camp' || i::TEXT;
    SELECT v INTO v_ci   FROM _t_ctx WHERE k = 'ci'   || i::TEXT;

    INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
    VALUES (v_tenant, 'ZZQSYNC-ORD-B' || i::TEXT, v_camp, v_channel, v_store, 'confirmed', v_op, v_op)
    RETURNING id INTO v_order;

    INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
    VALUES (v_tenant, v_order, v_ci, v_sku, v_add[i], 180, 'pending');
  END LOOP;
END
$mutate$;


-- ----------------------------------------------------------------------------
-- 測 0：夾具前提 —— 五個團的有效需求要剛好是 9 / 11 / 9 / 9 / 9
--   ⭐ 這條存在的理由：夾具本身寫錯（例如又把 cancelled 寫回 INSERT）時，
--      後面三條會用錯的前提「綠」給你看。前提先驗，才輪到結論。
-- ----------------------------------------------------------------------------
DO $t0$
DECLARE
  v_tenant UUID := (SELECT tenant FROM _t_env);
  v_sku    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'sku');
  v_expect NUMERIC[] := ARRAY[9, 11, 9, 9, 9];
  v_bad    TEXT := '';
  v_demand NUMERIC;
  i        INTEGER;
BEGIN
  FOR i IN 1..5 LOOP
    SELECT COALESCE(SUM(coi.qty), 0) INTO v_demand
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.tenant_id = v_tenant
       AND co.campaign_id = (SELECT v FROM _t_ctx WHERE k = 'camp' || i::TEXT)
       AND coi.sku_id = v_sku
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired');

    IF v_demand <> v_expect[i] THEN
      v_bad := v_bad || format('camp%s 需求=%s（應為 %s）; ', i, v_demand, v_expect[i]);
    END IF;
  END LOOP;

  INSERT INTO _t_result VALUES (
    0, '夾具前提：五個團的有效需求 = 9 / 11 / 9 / 9 / 9',
    (v_bad = ''),
    CASE WHEN v_bad = '' THEN '五個團需求全部符合' ELSE v_bad END
  );
END
$t0$;


-- ============================================================================
-- 測 1（根因）：原本 10、取消 1、沒有再加單 → 同步後草稿變 9
-- ============================================================================
DO $t1$
DECLARE
  v_pr     BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr1');
  v_item   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item1');
  v_op     UUID   := (SELECT operator FROM _t_env);
  v_res    JSONB;
  v_pric   NUMERIC;
  v_pri    NUMERIC;
  v_total  NUMERIC;
BEGIN
  v_res := public.rpc_sync_pr_qty(v_pr, v_op);

  SELECT qty_requested INTO v_pric
    FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  SELECT qty_requested INTO v_pri
    FROM purchase_request_items WHERE id = v_item;
  SELECT total_amount INTO v_total FROM purchase_requests WHERE id = v_pr;

  INSERT INTO _t_result VALUES (
    1, '取消 1、沒再加單 → 草稿 10 變 9（父層與明細一致、總金額 900）',
    (v_pric = 9 AND v_pri = 9 AND v_total = 900
     AND (v_res ->> 'synced_count')::INT = 1
     AND (v_res ->> 'blocked_count')::INT = 0),
    format('pric=%s, pri=%s, total=%s, res=%s', v_pric, v_pri, v_total, v_res)
  );
END
$t1$;


-- ============================================================================
-- 測 2：原本 10、取消 1、再加 2 → 11（⛔ 不是 12，也不可重複加）
-- ============================================================================
DO $t2$
DECLARE
  v_pr   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr2');
  v_item BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item2');
  v_op   UUID   := (SELECT operator FROM _t_env);
  v_res  JSONB;
  v_pric NUMERIC;
  v_pri  NUMERIC;
  v_again JSONB;
  v_pric2 NUMERIC;
BEGIN
  v_res := public.rpc_sync_pr_qty(v_pr, v_op);

  SELECT qty_requested INTO v_pric FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  SELECT qty_requested INTO v_pri  FROM purchase_request_items WHERE id = v_item;

  -- 連按第二次不可以再加（冪等）
  v_again := public.rpc_sync_pr_qty(v_pr, v_op);
  SELECT qty_requested INTO v_pric2 FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;

  INSERT INTO _t_result VALUES (
    2, '取消 1 再加 2 → 11（不是 12）；再按一次不會重複加',
    (v_pric = 11 AND v_pri = 11 AND v_pric <> 12
     AND v_pric2 = 11
     AND (v_again ->> 'synced_count')::INT = 0),
    format('pric=%s, pri=%s, 再按後 pric=%s, res=%s, again=%s', v_pric, v_pri, v_pric2, v_res, v_again)
  );
END
$t2$;


-- ============================================================================
-- 測 3：已送審 → rpc 直接擋；品項已轉採購單 → 跳過並回報需人工確認
--   兩種都要「一個字都不能改」。
-- ============================================================================
DO $t3$
DECLARE
  v_pr3   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr3');
  v_item3 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item3');
  v_pr4   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr4');
  v_item4 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item4');
  v_op    UUID   := (SELECT operator FROM _t_env);
  v_raised BOOLEAN := FALSE;
  v_q3    NUMERIC;
  v_res4  JSONB;
  v_q4    NUMERIC;
  v_reason4 TEXT;
BEGIN
  -- (a) 已送審的整張單：rpc 要擋，而且一個字都不能改
  BEGIN
    PERFORM public.rpc_sync_pr_qty(v_pr3, v_op);
  EXCEPTION WHEN OTHERS THEN
    v_raised := TRUE;
  END;
  SELECT qty_requested INTO v_q3
    FROM purchase_request_item_campaigns WHERE pr_item_id = v_item3;

  -- (b) 草稿單但品項已轉 PO：跳過、回報原因、不偷改
  SELECT block_reason INTO v_reason4
    FROM public._pr_qty_sync_preview(v_pr4) WHERE pr_item_id = v_item4;
  v_res4 := public.rpc_sync_pr_qty(v_pr4, v_op);
  SELECT qty_requested INTO v_q4 FROM purchase_request_items WHERE id = v_item4;

  INSERT INTO _t_result VALUES (
    3, '已送審 → rpc 擋且不改；已轉採購單的品項 → 跳過並回報需人工確認',
    (v_raised AND v_q3 = 10
     AND v_q4 = 3
     AND (v_res4 ->> 'synced_count')::INT = 0
     AND (v_res4 ->> 'blocked_count')::INT = 1
     AND v_reason4 IS NOT NULL
     AND v_reason4 LIKE '%已建立採購單%'),
    format('raised=%s, pr3_pric=%s, pr4_pri=%s, reason4=%s, res4=%s',
           v_raised, v_q3, v_q4, v_reason4, v_res4)
  );
END
$t3$;


-- ============================================================================
-- 測 4（對照組，刻意放最後）：把共用零件換回「只處理正差額」的舊版
--   → 測 1 的斷言必須紅（pass 的條件是「壞版本真的被抓出來」）。
--
--   ⚠️ 誠實說明壞在哪一半（施工時實際推過一遍）：
--      舊版的 LEFT JOIN **只**在需求歸零時讓整列消失。測 1 的需求是 9（>0），
--      光是 LEFT JOIN 照樣回得到 delta = -1 那一列 ——
--      真正把「純取消」擋掉的是**所有既有補單入口共有的 `WHERE delta_qty > 0`**。
--      所以這個壞版本把兩半都裝回去（LEFT JOIN ＋ 正差額過濾），
--      這才是修之前線上真正的行為。
--
--   ⚠️ 放最後是刻意的：這樣就不需要把正確版本再抄一份回來。
--      抄回來那份會跟 migration 慢慢對不上，變成「假綠」。
--      整份包在 ROLLBACK 裡，壞版本不會留在資料庫。
-- ============================================================================
CREATE OR REPLACE FUNCTION public._pr_campaign_sku_remaining_rows(
  p_campaign_ids BIGINT[]
) RETURNS TABLE(
  campaign_id BIGINT, sku_id BIGINT,
  demand_qty NUMERIC, already_qty NUMERIC, delta_qty NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $broken$
  WITH t AS (SELECT public._current_tenant_id() AS tid),
  sel AS (SELECT DISTINCT unnest(p_campaign_ids) AS campaign_id),
  demand AS (
    SELECT co.campaign_id, coi.sku_id, SUM(coi.qty) AS qty
      FROM sel
      JOIN public.customer_orders co ON co.campaign_id = sel.campaign_id
      JOIN public.customer_order_items coi ON coi.order_id = co.id
      CROSS JOIN t
     WHERE co.tenant_id = t.tid
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY co.campaign_id, coi.sku_id
  ),
  already AS (
    SELECT pric.campaign_id, pri.sku_id, SUM(pric.qty_requested) AS qty
      FROM public.purchase_request_item_campaigns pric
      JOIN public.purchase_request_items pri ON pri.id = pric.pr_item_id
      JOIN public.purchase_requests pr ON pr.id = pri.pr_id
      JOIN sel ON sel.campaign_id = pric.campaign_id
      CROSS JOIN t
     WHERE pr.tenant_id = t.tid AND pric.tenant_id = t.tid AND pr.status <> 'cancelled'
     GROUP BY pric.campaign_id, pri.sku_id
  )
  -- ⬇⬇ 修之前的行為：① LEFT JOIN（需求歸零整列消失）② 只留正差額
  SELECT d.campaign_id, d.sku_id, d.qty, COALESCE(a.qty, 0),
         d.qty - COALESCE(a.qty, 0)
    FROM demand d
    LEFT JOIN already a ON a.campaign_id = d.campaign_id AND a.sku_id = d.sku_id
   WHERE d.qty - COALESCE(a.qty, 0) > 0;
$broken$;

DO $t4$
DECLARE
  v_camp5 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp5');
  v_pr5   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr5');
  v_rows_broken  INTEGER;
  v_needs_broken INTEGER;
BEGIN
  -- camp5／pr5 = 跟測 1 完全一樣的情境（草稿 10、有效需求 9、負差額 -1），
  -- 只是刻意沒被同步過。正確版本：回 1 列、preview 標 1 筆待同步。
  SELECT COUNT(*) INTO v_rows_broken
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[v_camp5]);

  SELECT COUNT(*) INTO v_needs_broken
    FROM public._pr_qty_sync_preview(v_pr5) WHERE needs_sync;

  INSERT INTO _t_result VALUES (
    4,
    '對照組：裝回「只處理正差額」的舊零件 → 測 1 那個情境（草稿 10 / 需求 9）整列消失、不會被標成待同步（確認測試真的會紅）',
    (v_rows_broken = 0 AND v_needs_broken = 0),
    format('壞版本回傳列數=%s（應為 0，正確版本是 1），待同步筆數=%s（應為 0，正確版本是 1）',
           v_rows_broken, v_needs_broken)
  );
END
$t4$;


TABLE _t_result ORDER BY seq;

DO $$
DECLARE
  v_bad TEXT;
BEGIN
  SELECT string_agg(seq || ' ' || item || ' :: ' || detail, E'\n')
    INTO v_bad
    FROM _t_result
   WHERE NOT pass OR pass IS NULL;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'pr_qty_sync_minimal_verification failed:%', E'\n' || v_bad;
  END IF;
END $$;

ROLLBACK;

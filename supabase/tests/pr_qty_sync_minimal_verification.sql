-- ============================================================================
-- 驗證腳本：請購草稿「同步最新開團數量」（精簡版）
-- 對應 migration：supabase/migrations/20261001000000_pr_qty_sync_minimal.sql
-- 規格：公司\01_進行中\實作計畫_取消訂單同步請購草稿_精簡版_Claude_2026-10-01.md（v2 §7）
-- ----------------------------------------------------------------------------
-- ⛔ 只在本機 / 測試庫執行。整份包在交易裡，跑完 ROLLBACK 不留測資。
--
-- ⚠️ 執行身分：測 7（對照組）會用 pg_get_functiondef 複製現行的
--    `_pr_campaign_sku_remaining_rows`，再 CREATE OR REPLACE 一支壞版本蓋上去。
--    這需要以**該函式的擁有者或超級使用者**身分執行（例如 postgres），
--    一般 authenticated 角色會在測 7 失敗。整份在 ROLLBACK 裡，壞版本不會留下。
--
-- 只測 v2 §7 這七條（加一條夾具前提自我檢查）：
--   1. 原本 10、取消 1 → 同步後 9（根因，必留）
--   2. 原本 10、取消 1、再加 2 → 11，並斷言 ≠ 12；連按第二次不重複加、也不碰表頭
--   3. 已送審／已有採購單 → 不改
--   4. 同一張單兩列同團同商品 → 兩列都不改、回報需人工確認（防重複扣）
--   5. 同步 0 筆 → 表頭總額／修改人／修改時間完全不變（先快照再比對）
--   6. 舊資料／歸屬資料不完整 → 不改、回報需人工確認
--      (a) 這一列本身是舊資料（沒有各團明細）
--      (b) 別張單上的舊資料混進這個團的已請購量
--      (c) 品項總數跟各團明細加總對不起來
--   7. 對照組：裝回「只處理正差額」→ 第 1 條的情境必須紅
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
  'feed0000-0000-4000-8000-0000000000fe'::UUID AS operator,      -- 按同步的人
  'feed0000-0000-4000-8000-0000000000fa'::UUID AS fixture_user,  -- 造資料的人（故意不同，測 5 靠它分辨）
  (CURRENT_DATE - 1)::DATE AS close_date;

CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_result(seq INT, item TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;


-- ----------------------------------------------------------------------------
-- 夾具：一個商品、九個團、十張請購單
--   團     最後需求              請購單                                   給哪條測試
--   camp1  9（10 取消 1）        pr1  草稿 一列 明細 10                    測 1
--   camp2  11（10 取消 1 加 2）  pr2  草稿 一列 明細 10                    測 2
--   camp3  9                     pr3  已送審 一列 明細 10                  測 3(a)
--   camp4  9                     pr4  草稿 一列 明細 10、已建採購單        測 3(b)
--   camp5  9                     pr5  草稿 **兩列**同團同商品 各 5         測 4
--   camp6  9                     pr6  草稿 一列 **舊資料** 10（無明細）    測 6(a)
--   camp7  9                     pr7a 已送審 一列舊資料 4（記在 camp7）    測 6(b)
--                                pr7b 草稿 一列 明細 6
--   camp8  8（10 取消 2）        pr8  草稿 一列 總數 10、明細只有 9        測 6(c)
--   camp9  9                     pr9  草稿 一列 明細 10                    測 7 專用
--   測 5 不另造資料：比對 3／4／6 那些「同步 0 筆」的單，呼叫前後的表頭。
--
-- 🔴 造資料的順序必須跟真實世界一樣，不可以直接把終局狀態寫進 INSERT
--   `trg_pri_cross_close_date_duplicate_guard`（#982，20260921001000:534-604）
--   在 purchase_request_item_campaigns 的 AFTER INSERT 就會算
--   「這個團＋SKU 的未取消請購總量 > 目前有效需求」→ 直接 RAISE EXCEPTION。
--   ⇒ 若一開始就把取消掉的那筆訂單寫成 status='cancelled'，
--      建明細（requested 10 vs demand 9）當場被退回，整份驗證第一圈就炸。
--   ⇒ 所以分三段走：
--      ① 先把客人訂單建成「全額有效」（含日後會被取消的那筆，先給有效狀態）
--      ② 再建請購單與明細（此時 demand ≥ requested，守衛過）
--      ③ 最後才把該取消的那筆 UPDATE 成 cancelled、把事後追加的量插進來
--
-- 🔴 表頭 total_amount 一律照真實算法（品項 line_subtotal 加總）給值，**不可寫 0**。
--   寫 0 的話，「同步 0 筆卻重算表頭」那個 bug 會把 0 改成正確值，
--   而測試只看品項數量就會假綠（阿審 2026-10-01 抓到的就是 0 → 300）。
-- ----------------------------------------------------------------------------
DO $fixture$
DECLARE
  v_tenant   UUID := (SELECT tenant FROM _t_env);
  v_op       UUID := (SELECT operator FROM _t_env);
  v_fixture  UUID := (SELECT fixture_user FROM _t_env);
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
  --   v_orig   ＝ 建請購單「當下」的需求。必須 ≥ 該團的請購量，否則 #982 當場退回。
  --   v_cancel ＝ 事後被客人取消掉的量。先以有效訂單插入，第 ③ 段才 UPDATE 成 cancelled。
  --   v_add    ＝ 事後才追加的量。第 ③ 段才插入新訂單。
  v_orig     NUMERIC[] := ARRAY[10, 10, 10, 10, 10, 10, 10, 10, 10];
  v_cancel   NUMERIC[] := ARRAY[ 1,  1,  1,  1,  1,  1,  1,  2,  1];
  v_add      NUMERIC[] := ARRAY[ 0,  2,  0,  0,  0,  0,  0,  0,  0];
  --  最後的有效需求 = orig - cancel + add = 9 / 11 / 9 / 9 / 9 / 9 / 9 / 8 / 9
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

  -- ---- ① 九個團 + 客人訂單（全部先建成有效）----
  FOR i IN 1..9 LOOP
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

    -- 日後會被客人取消的那部分 —— ⚠️ 現在先給「有效」狀態。
    -- ⛔ 不要在這裡就寫 'cancelled'，那會讓明細 INSERT 被 #982 守衛當場退回。
    IF v_cancel[i] > 0 THEN
      INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
      VALUES (v_tenant, 'ZZQSYNC-ORD-X' || i::TEXT, v_camp, v_channel, v_store, 'confirmed', v_op, v_op)
      RETURNING id INTO v_order;

      INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
      VALUES (v_tenant, v_order, v_ci, v_sku, v_cancel[i], 180, 'pending');
    END IF;
  END LOOP;

  -- ---- ② 請購單 ----
  -- 一律先建品項（不帶 source_campaign_id → #982 放行）、再建明細（此時 requested ≤ demand）。

  -- pr1 / pr2 / pr3 / pr9：一列一個團、明細 10。pr3 是已送審。
  FOREACH i IN ARRAY ARRAY[1, 2, 3, 9] LOOP
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

    INSERT INTO _t_ctx(k, v) VALUES ('pr' || i::TEXT, v_pr), ('item' || i::TEXT, v_item);
  END LOOP;

  -- pr4：草稿、明細 10，但品項已建立採購單（po_item_id 非空）
  INSERT INTO purchase_orders (
    tenant_id, po_no, supplier_id, dest_location_id, status, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PO-1', v_supplier, v_loc, 'sent', v_op, v_op)
  RETURNING id INTO v_po;

  INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by)
  VALUES (v_po, v_sku, 10, 100, v_op, v_op)
  RETURNING id INTO v_po_item;

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-4', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, po_item_id, created_by, updated_by
  ) VALUES (v_pr, v_sku, 10, v_supplier, 100, v_po_item, v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
  VALUES (v_item, v_camps[4], v_tenant, 10);

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr, v_camps[4], v_tenant);

  INSERT INTO _t_ctx(k, v) VALUES ('pr4', v_pr), ('item4', v_item);

  -- pr5：同一張單、**兩列**同團同商品，各 5（合計 10）
  --   主線沒有 UNIQUE(pr_id, sku_id)（20260812020000:199-200 明寫），所以這種資料真的會有。
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-5', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr, v_camps[5], v_tenant);
  INSERT INTO _t_ctx(k, v) VALUES ('pr5', v_pr);

  FOR i IN 1..2 LOOP
    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
    ) VALUES (v_pr, v_sku, 5, v_supplier, 100, v_op, v_op)
    RETURNING id INTO v_item;

    INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
    VALUES (v_item, v_camps[5], v_tenant, 5);

    INSERT INTO _t_ctx(k, v) VALUES ('item5' || CASE WHEN i = 1 THEN 'a' ELSE 'b' END, v_item);
  END LOOP;

  -- pr6：草稿、一列**舊資料**：只有 source_campaign_id、沒有各團明細，數量 10
  --   #982 對它走 direct_legacy：requested 10 ≤ demand 10，放行。
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-6', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
    source_campaign_id, created_by, updated_by
  ) VALUES (v_pr, v_sku, 10, v_supplier, 100, v_camps[6], v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr, v_camps[6], v_tenant);

  INSERT INTO _t_ctx(k, v) VALUES ('pr6', v_pr), ('item6', v_item);

  -- pr7a：**已送審**、一列舊資料 4，記在 camp7 名下（沒有各團明細）
  -- pr7b：草稿、一列明細 6（camp7）
  --   ⇒ camp7 的已請購量 = 6 + 4 = 10，其中 4 是舊資料 → helper 的差額不能信。
  --   pr7a 是已送審，所以「可改草稿列數」只有 pr7b 一列 —— 這樣測 6(b) 擋下來的
  --   **只會是**「舊資料混進已請購量」那條，不是「多列」那條。
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-7A', 'close_date', v_date, v_loc, 'submitted', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
    source_campaign_id, created_by, updated_by
  ) VALUES (v_pr, v_sku, 4, v_supplier, 100, v_camps[7], v_op, v_op);

  INSERT INTO _t_ctx(k, v) VALUES ('pr7a', v_pr);

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-7B', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
  ) VALUES (v_pr, v_sku, 6, v_supplier, 100, v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
  VALUES (v_item, v_camps[7], v_tenant, 6);

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr, v_camps[7], v_tenant);

  INSERT INTO _t_ctx(k, v) VALUES ('pr7b', v_pr), ('item7b', v_item);

  -- pr8：草稿、品項總數 10，但各團明細只有 9（歸屬資料不完整）
  --   真實世界有這種資料：#982 回填舊資料時按需求比例分配、存到小數三位，
  --   加總會跟品項總數差一點點（20260921001000:186-225）。
  --   #982 的「總數 = 明細加總」只在**改品項**時檢查，建明細時不檢查，所以造得出來。
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, created_by, updated_by
  ) VALUES (v_tenant, 'ZZQSYNC-PR-8', 'close_date', v_date, v_loc, 'draft', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
  ) VALUES (v_pr, v_sku, 10, v_supplier, 100, v_op, v_op)
  RETURNING id INTO v_item;

  INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
  VALUES (v_item, v_camps[8], v_tenant, 9);

  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr, v_camps[8], v_tenant);

  INSERT INTO _t_ctx(k, v) VALUES ('pr8', v_pr), ('item8', v_item);

  -- 表頭：照真實算法給總額（不可留 0），修改人改成「造資料的人」
  --   → 測 5 就能分辨「表頭有沒有被同步改過」（同步會把修改人寫成按鈕的人）。
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(pri.line_subtotal)
             FROM purchase_request_items pri
            WHERE pri.pr_id = pr.id
         ), 0),
         updated_by = v_fixture
   WHERE pr.tenant_id = v_tenant
     AND pr.pr_no LIKE 'ZZQSYNC-PR-%';
END
$fixture$;


-- ----------------------------------------------------------------------------
-- 第 ③ 段：請購單都建好之後，才真的「取消訂單」與「追加訂單」
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
  v_add     NUMERIC[] := ARRAY[0, 2, 0, 0, 0, 0, 0, 0, 0];
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
  FOR i IN 1..9 LOOP
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
-- 表頭快照（給測 5）—— 一定要在任何同步之前拍
--   ⚠️ 為什麼要比 ctid，不能只比 updated_at：
--      整份測試在**同一個交易**裡，NOW() 從頭到尾是同一個時間；
--      而 purchase_requests 有 BEFORE UPDATE 的 touch_updated_at（20260422120004:257），
--      會把 updated_at 設成 NOW()。所以就算同步偷改了表頭，updated_at 看起來也「沒變」
--      —— 只比 updated_at 一定假綠。
--      ctid 是資料列的實體位置，**任何 UPDATE 都會產生新版本、換一個 ctid**，
--      連「改成一樣的值」都抓得到。修改人則靠夾具故意用不同的人來分辨。
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _t_snap ON COMMIT DROP AS
SELECT pr.id AS pr_id, pr.pr_no, pr.total_amount, pr.updated_by, pr.updated_at, pr.ctid::TEXT AS row_ver
  FROM purchase_requests pr
 WHERE pr.tenant_id = (SELECT tenant FROM _t_env)
   AND pr.pr_no LIKE 'ZZQSYNC-PR-%';


-- ----------------------------------------------------------------------------
-- 測 0：夾具前提 —— 九個團的有效需求要剛好是預期值、表頭總額不是 0
--   ⭐ 夾具本身寫錯時，後面的測試會用錯的前提「綠」給你看。前提先驗，才輪到結論。
-- ----------------------------------------------------------------------------
DO $t0$
DECLARE
  v_tenant UUID := (SELECT tenant FROM _t_env);
  v_sku    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'sku');
  v_expect NUMERIC[] := ARRAY[9, 11, 9, 9, 9, 9, 9, 8, 9];
  v_bad    TEXT := '';
  v_demand NUMERIC;
  v_zero_total INTEGER;
  i        INTEGER;
BEGIN
  FOR i IN 1..9 LOOP
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

  SELECT COUNT(*) INTO v_zero_total FROM _t_snap WHERE total_amount = 0;
  IF v_zero_total > 0 THEN
    v_bad := v_bad || format('有 %s 張表頭總額是 0（測 5 會假綠）; ', v_zero_total);
  END IF;

  INSERT INTO _t_result VALUES (
    0, '夾具前提：九個團的有效需求 = 9/11/9/9/9/9/9/8/9，表頭總額都不是 0',
    (v_bad = ''),
    CASE WHEN v_bad = '' THEN '全部符合' ELSE v_bad END
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
     AND (v_res ->> 'blocked_count')::INT = 0
     AND (v_res ->> 'total_amount')::NUMERIC = 900),
    format('pric=%s, pri=%s, total=%s, res=%s', v_pric, v_pri, v_total, v_res)
  );
END
$t1$;


-- ============================================================================
-- 測 2：原本 10、取消 1、再加 2 → 11（⛔ 不是 12）；連按第二次不重複加、不碰表頭
-- ============================================================================
DO $t2$
DECLARE
  v_pr    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr2');
  v_item  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item2');
  v_op    UUID   := (SELECT operator FROM _t_env);
  v_res   JSONB;
  v_pric  NUMERIC;
  v_pri   NUMERIC;
  v_ver1  TEXT;
  v_again JSONB;
  v_pric2 NUMERIC;
  v_ver2  TEXT;
BEGIN
  v_res := public.rpc_sync_pr_qty(v_pr, v_op);

  SELECT qty_requested INTO v_pric FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  SELECT qty_requested INTO v_pri  FROM purchase_request_items WHERE id = v_item;
  SELECT ctid::TEXT INTO v_ver1 FROM purchase_requests WHERE id = v_pr;

  -- 連按第二次：不可以再加，而且「同步 0 筆」不可以再碰表頭（ctid 不可以變）
  v_again := public.rpc_sync_pr_qty(v_pr, v_op);
  SELECT qty_requested INTO v_pric2 FROM purchase_request_item_campaigns WHERE pr_item_id = v_item;
  SELECT ctid::TEXT INTO v_ver2 FROM purchase_requests WHERE id = v_pr;

  INSERT INTO _t_result VALUES (
    2, '取消 1 再加 2 → 11（不是 12）；再按一次不重複加、也不碰表頭',
    (v_pric = 11 AND v_pri = 11 AND v_pric <> 12
     AND v_pric2 = 11
     AND (v_again ->> 'synced_count')::INT = 0
     AND v_ver1 = v_ver2),
    format('pric=%s, pri=%s, 再按後 pric=%s, 表頭版本 %s → %s, res=%s, again=%s',
           v_pric, v_pri, v_pric2, v_ver1, v_ver2, v_res, v_again)
  );
END
$t2$;


-- ============================================================================
-- 測 3：已送審 → rpc 直接擋；已有採購單的品項 → 跳過並回報需人工確認
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
  v_pri4  NUMERIC;
  v_pric4 NUMERIC;
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

  -- (b) 草稿單但品項已轉採購單：跳過、回報原因、不偷改
  SELECT block_reason INTO v_reason4
    FROM public._pr_qty_sync_preview(v_pr4) WHERE pr_item_id = v_item4;
  v_res4 := public.rpc_sync_pr_qty(v_pr4, v_op);
  SELECT qty_requested INTO v_pri4  FROM purchase_request_items WHERE id = v_item4;
  SELECT qty_requested INTO v_pric4 FROM purchase_request_item_campaigns WHERE pr_item_id = v_item4;

  INSERT INTO _t_result VALUES (
    3, '已送審 → rpc 擋且不改；已建採購單的品項 → 跳過並回報需人工確認',
    (v_raised AND v_q3 = 10
     AND v_pri4 = 10 AND v_pric4 = 10
     AND (v_res4 ->> 'synced_count')::INT = 0
     AND (v_res4 ->> 'blocked_count')::INT = 1
     AND v_reason4 LIKE '%已建立採購單%'),
    format('raised=%s, pr3_pric=%s, pr4_pri=%s, pr4_pric=%s, reason4=%s, res4=%s',
           v_raised, v_q3, v_pri4, v_pric4, v_reason4, v_res4)
  );
END
$t3$;


-- ============================================================================
-- 測 4：同一張單兩列同團同商品 → 兩列都不改（防重複扣）
--   沒有這條防線時：helper 的差額 -1 會被兩列各扣一次 → 5+5 變 4+4=8，少買 1，
--   而 8 < 需求 9，#982 只擋多買，攔不住。
-- ============================================================================
DO $t4$
DECLARE
  v_pr    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr5');
  v_ia    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item5a');
  v_ib    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item5b');
  v_op    UUID   := (SELECT operator FROM _t_env);
  v_ra    TEXT;
  v_rb    TEXT;
  v_res   JSONB;
  v_qa    NUMERIC;
  v_qb    NUMERIC;
  v_pa    NUMERIC;
  v_pb    NUMERIC;
BEGIN
  SELECT block_reason INTO v_ra FROM public._pr_qty_sync_preview(v_pr) WHERE pr_item_id = v_ia;
  SELECT block_reason INTO v_rb FROM public._pr_qty_sync_preview(v_pr) WHERE pr_item_id = v_ib;

  v_res := public.rpc_sync_pr_qty(v_pr, v_op);

  SELECT qty_requested INTO v_qa FROM purchase_request_item_campaigns WHERE pr_item_id = v_ia;
  SELECT qty_requested INTO v_qb FROM purchase_request_item_campaigns WHERE pr_item_id = v_ib;
  SELECT qty_requested INTO v_pa FROM purchase_request_items WHERE id = v_ia;
  SELECT qty_requested INTO v_pb FROM purchase_request_items WHERE id = v_ib;

  INSERT INTO _t_result VALUES (
    4, '同單兩列同團同商品 → 兩列都標需人工確認（2 列），按同步一列都不改',
    (v_ra LIKE '%2 列%' AND v_rb LIKE '%2 列%'
     AND v_qa = 5 AND v_qb = 5 AND v_pa = 5 AND v_pb = 5
     AND (v_res ->> 'synced_count')::INT = 0
     AND (v_res ->> 'blocked_count')::INT = 2),
    format('reason_a=%s, reason_b=%s, 明細 %s/%s, 品項 %s/%s, res=%s',
           v_ra, v_rb, v_qa, v_qb, v_pa, v_pb, v_res)
  );
END
$t4$;


-- ============================================================================
-- 測 6：舊資料／歸屬資料不完整 → 不改、回報需人工確認
--   ⚠️ 刻意排在測 5 前面：測 5 要比對「這幾張也按過同步之後」的表頭。
-- ============================================================================
DO $t6$
DECLARE
  v_op     UUID   := (SELECT operator FROM _t_env);
  v_pr6    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr6');
  v_item6  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item6');
  v_pr7b   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr7b');
  v_item7b BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item7b');
  v_pr8    BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr8');
  v_item8  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item8');
  v_r6  TEXT; v_a6 TEXT; v_c6 BOOLEAN; v_res6 JSONB; v_q6 NUMERIC;
  v_r7  TEXT; v_res7 JSONB; v_pric7 NUMERIC; v_pri7 NUMERIC;
  v_r8  TEXT; v_res8 JSONB; v_pric8 NUMERIC; v_pri8 NUMERIC;
BEGIN
  -- (a) 這一列本身是舊資料：要列出來（不是默默略過），但不可同步
  SELECT block_reason, attribution, can_sync INTO v_r6, v_a6, v_c6
    FROM public._pr_qty_sync_preview(v_pr6) WHERE pr_item_id = v_item6;
  v_res6 := public.rpc_sync_pr_qty(v_pr6, v_op);
  SELECT qty_requested INTO v_q6 FROM purchase_request_items WHERE id = v_item6;

  -- (b) 別張（已送審）單上的舊資料記在同一個團 → 已請購量算不準
  SELECT block_reason INTO v_r7
    FROM public._pr_qty_sync_preview(v_pr7b) WHERE pr_item_id = v_item7b;
  v_res7 := public.rpc_sync_pr_qty(v_pr7b, v_op);
  SELECT qty_requested INTO v_pric7 FROM purchase_request_item_campaigns WHERE pr_item_id = v_item7b;
  SELECT qty_requested INTO v_pri7  FROM purchase_request_items WHERE id = v_item7b;

  -- (c) 品項總數 10、明細只有 9 → 歸屬不完整
  --     沒有這條防線時：明細 9 → 8，再用明細加總重算品項 → 品項 10 → 8，
  --     一次少買 2 件，而需求只降了 1。
  SELECT block_reason INTO v_r8
    FROM public._pr_qty_sync_preview(v_pr8) WHERE pr_item_id = v_item8;
  v_res8 := public.rpc_sync_pr_qty(v_pr8, v_op);
  SELECT qty_requested INTO v_pric8 FROM purchase_request_item_campaigns WHERE pr_item_id = v_item8;
  SELECT qty_requested INTO v_pri8  FROM purchase_request_items WHERE id = v_item8;

  INSERT INTO _t_result VALUES (
    6, '舊資料／歸屬不完整 → 列出來、標需人工確認、一個字都不改（a 本列舊資料／b 已請購量混舊資料／c 總數≠明細）',
    (    v_a6 = 'legacy' AND NOT v_c6 AND v_r6 LIKE '舊資料：%'
     AND v_q6 = 10 AND (v_res6 ->> 'synced_count')::INT = 0
     AND v_r7 LIKE '%已請購量算不準%'
     AND v_pric7 = 6 AND v_pri7 = 6 AND (v_res7 ->> 'synced_count')::INT = 0
     AND v_r8 LIKE '%對不起來%'
     AND v_pric8 = 9 AND v_pri8 = 10 AND (v_res8 ->> 'synced_count')::INT = 0),
    format('a: attr=%s can_sync=%s reason=%s qty=%s | b: reason=%s 明細=%s 品項=%s | c: reason=%s 明細=%s 品項=%s',
           v_a6, v_c6, v_r6, v_q6, v_r7, v_pric7, v_pri7, v_r8, v_pric8, v_pri8)
  );
END
$t6$;


-- ============================================================================
-- 測 5：同步 0 筆 → 表頭總額／修改人／修改時間完全不變
--   對象：測 3／4／6 按過同步、但一筆都沒同步的單（pr3 是 rpc 直接擋）。
--   比對的是「任何同步之前」拍的快照（見 _t_snap 那段為什麼要比 ctid）。
--   ⭐ 正向對照：pr1 真的同步了 1 筆，它的表頭**必須**變 ——
--      證明這個比對方法不是瞎的（不然「全部沒變」也可能只是偵測不到）。
-- ============================================================================
DO $t5$
DECLARE
  v_bad      TEXT := '';
  v_fixture  UUID := (SELECT fixture_user FROM _t_env);
  v_op       UUID := (SELECT operator FROM _t_env);
  r          RECORD;
  v_pr1_changed BOOLEAN;
  v_pr4_snap_total NUMERIC;
BEGIN
  FOR r IN
    SELECT s.pr_no, s.total_amount AS t0, s.updated_by AS b0, s.updated_at AS a0, s.row_ver AS v0,
           pr.total_amount AS t1, pr.updated_by AS b1, pr.updated_at AS a1, pr.ctid::TEXT AS v1
      FROM _t_snap s
      JOIN purchase_requests pr ON pr.id = s.pr_id
     WHERE s.pr_no IN ('ZZQSYNC-PR-3', 'ZZQSYNC-PR-4', 'ZZQSYNC-PR-5',
                       'ZZQSYNC-PR-6', 'ZZQSYNC-PR-7B', 'ZZQSYNC-PR-8')
  LOOP
    IF r.t0 IS DISTINCT FROM r.t1
       OR r.b0 IS DISTINCT FROM r.b1
       OR r.a0 IS DISTINCT FROM r.a1
       OR r.v0 IS DISTINCT FROM r.v1 THEN
      v_bad := v_bad || format('%s 總額 %s→%s 修改人 %s→%s 版本 %s→%s; ',
                               r.pr_no, r.t0, r.t1, r.b0, r.b1, r.v0, r.v1);
    END IF;
  END LOOP;

  -- 正向對照：pr1 有同步 → 版本要換、總額 1000→900、修改人要變成按鈕的人
  SELECT (s.row_ver <> pr.ctid::TEXT AND s.total_amount = 1000 AND pr.total_amount = 900
          AND s.updated_by = v_fixture AND pr.updated_by = v_op)
    INTO v_pr1_changed
    FROM _t_snap s JOIN purchase_requests pr ON pr.id = s.pr_id
   WHERE s.pr_no = 'ZZQSYNC-PR-1';

  -- 夾具沒有把表頭寫成 0（否則「0 → 正確值」這種偷改會被掩蓋）
  SELECT total_amount INTO v_pr4_snap_total FROM _t_snap WHERE pr_no = 'ZZQSYNC-PR-4';

  INSERT INTO _t_result VALUES (
    5, '同步 0 筆 → 六張單的表頭（總額／修改人／修改時間／資料列版本）完全沒動；對照：有同步的 pr1 表頭確實變了',
    (v_bad = '' AND v_pr1_changed AND v_pr4_snap_total = 1000),
    format('被偷改=%s | pr1 正向對照=%s | pr4 快照總額=%s（應為 1000）',
           CASE WHEN v_bad = '' THEN '無' ELSE v_bad END, v_pr1_changed, v_pr4_snap_total)
  );
END
$t5$;


-- ============================================================================
-- 測 7（對照組，刻意放最後）：裝回「只處理正差額」那一行 → 測 1 的情境必須紅
--
--   ⚠️ 壞在哪一半，講清楚：
--      本案**完全沒有動**共用 helper `_pr_campaign_sku_remaining_rows`
--      （現行唯一版本 20260921001000:240）。它的 LEFT JOIN 只在**需求歸零**時
--      讓整列消失，而測 1 的需求是 9（> 0）—— 現行版本本來就回得到 delta = -1。
--      真正把「純取消」擋掉的，是**所有既有補單入口共有的 `WHERE delta_qty > 0`**。
--      所以修的是「加一個不過濾正負的新入口」，對照組要裝回去的也只有那一行。
--
--   ⚠️ 需以函式擁有者／超級使用者身分執行（見檔頭）。
--   ⚠️ 整份包在 ROLLBACK 裡，壞版本不會留在資料庫。
-- ============================================================================

-- ⛔ 不可以在這裡手抄一份 helper 的 body：它不在本案的 migration 裡（是別人的檔），
--    抄一份一定會慢慢對不上，變成「假綠」。所以用 pg_get_functiondef 把**線上現行
--    那一支**原封不動複製成 _zz_orig_remaining_rows，壞版本只是包一層 `WHERE delta_qty > 0`。
--    前提：這支 helper 不是遞迴函式（body 裡沒有自己的名字），所以只換名字是安全的。
DO $clone$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_def
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = '_pr_campaign_sku_remaining_rows'
     AND pg_get_function_identity_arguments(p.oid) = 'p_campaign_ids bigint[]';

  IF v_def IS NULL THEN
    RAISE EXCEPTION '找不到 public._pr_campaign_sku_remaining_rows(bigint[])，對照組無法建立';
  END IF;

  EXECUTE replace(v_def,
    '_pr_campaign_sku_remaining_rows',
    '_zz_orig_remaining_rows');
END
$clone$;

-- 壞版本：呼叫原封不動的那一支，只把負差額濾掉（＝修之前的全站行為）
CREATE OR REPLACE FUNCTION public._pr_campaign_sku_remaining_rows(
  p_campaign_ids BIGINT[]
) RETURNS TABLE(
  campaign_id BIGINT, sku_id BIGINT,
  demand_qty NUMERIC, already_qty NUMERIC, delta_qty NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $broken$
  SELECT r.campaign_id, r.sku_id, r.demand_qty, r.already_qty, r.delta_qty
    FROM public._zz_orig_remaining_rows(p_campaign_ids) r
   WHERE r.delta_qty > 0;       -- ⬅⬅ 這就是修之前每個補單入口都有的那一行
$broken$;

DO $t7$
DECLARE
  v_camp9 BIGINT := (SELECT v FROM _t_ctx WHERE k = 'camp9');
  v_pr9   BIGINT := (SELECT v FROM _t_ctx WHERE k = 'pr9');
  v_rows_ok      INTEGER;
  v_rows_broken  INTEGER;
  v_needs_broken INTEGER;
BEGIN
  -- camp9／pr9 = 跟測 1 完全一樣的情境（草稿 10、有效需求 9、負差額 -1），只是刻意沒被同步過。
  -- 先證明「原封不動那一支」確實回得到那一列（＝我們沒有靠改 helper 過關），
  -- 再證明加上正差額過濾之後它就消失了。
  SELECT COUNT(*) INTO v_rows_ok
    FROM public._zz_orig_remaining_rows(ARRAY[v_camp9]) WHERE delta_qty = -1;

  SELECT COUNT(*) INTO v_rows_broken
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[v_camp9]);

  SELECT COUNT(*) INTO v_needs_broken
    FROM public._pr_qty_sync_preview(v_pr9) WHERE needs_sync;

  INSERT INTO _t_result VALUES (
    7,
    '對照組：現行 helper 本來就回得到 delta=-1（我們沒改它）；加回「只處理正差額」那一行 → 測 1 的情境整列消失、不會被標成待同步（確認測試真的會紅）',
    (v_rows_ok = 1 AND v_rows_broken = 0 AND v_needs_broken = 0),
    format('現行 helper 的 -1 列數=%s（應為 1），壞版本回傳列數=%s（應為 0），待同步筆數=%s（應為 0，正確版本是 1）',
           v_rows_ok, v_rows_broken, v_needs_broken)
  );
END
$t7$;


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

  IF (SELECT COUNT(*) FROM _t_result) <> 8 THEN
    RAISE EXCEPTION 'pr_qty_sync_minimal_verification：應該有 8 條結果（測 0～7），實際 %',
      (SELECT COUNT(*) FROM _t_result);
  END IF;
END $$;

ROLLBACK;

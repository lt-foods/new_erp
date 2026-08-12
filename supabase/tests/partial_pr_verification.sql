-- ============================================================================
-- 驗證腳本：rpc_create_partial_pr_from_items（請購單「部分轉採購」）
-- 對應 migration：supabase/migrations/20260812000000_rpc_create_partial_pr_from_items.sql
-- ----------------------------------------------------------------------------
-- ⚠️ 這支只在「本機 / 測試庫」跑，不要對正式庫執行。
--    ・整份腳本包在 BEGIN; ... ROLLBACK; 裡，跑完不留任何資料（測資自己建、自己滾掉）。
--    ・唯一不會被 rollback 回補的是 pr_no_seq 的 nextval（sequence 本來就不受交易回滾影響），
--      也就是跑一次會燒掉幾個請購單號 —— 這正是不要拿正式庫跑的理由之一。
--
-- 怎麼跑（本機 supabase）：
--   supabase db reset            # 或任何已套用全部 migration 的測試庫
--   psql "<本機連線字串>" -f supabase/tests/partial_pr_verification.sql
--   ※ 以 postgres / service_role 身分執行（要能寫測資、且不被 RLS 擋）。
--
-- 身分模擬：本 RPC 走 auth.jwt()（tenant_id + app_metadata.role），
--   腳本用 SET LOCAL request.jwt.claims 灌進去 —— 這就是 Supabase 的 auth.jwt() 取值來源。
--
-- 驗什麼（規格 §5 切片 4 的 7 項 + 阿審第一輪要求補的項目）：
--   ① 新 PR 1 項        ② 原 PR 2 項        ③ 兩張 total_amount 正確
--   ④ join 表關聯不斷
--   ⑤-0 前提斷言：搬移前確實有 delta 可比對 ← 沒有這條，⑤-a 會變成「0 筆 vs 0 筆」的假通過
--   ⑤-a/⑤-b 補單 delta 搬移前後完全相同（本案最關鍵）
--   ⑥ 全選被擋          ⑦ 跨 PR 的 item_id 被擋
--   ⑧ 搬過去的欄位值逐欄一致（供應商 / 成本 / 售價 / 來源團 / 備註…）
--   ⑨ p_item_ids = NULL 被擋          ⑩ 空陣列被擋
--   ⑪ 重複 id 去重後正常成功且只搬 1 筆   ⑫ 不存在的 id 被擋
--   ⑬ 已拆 PO（po_item_id 非空）的品項被擋
--
-- 假通過防線（教訓：測試全綠 ≠ 測試有在保護你）：
--   ・⑤-0 明確斷言 before 快照非空且數值就是預期值，紅了就代表後面的綠燈不算數。
--   ・⑤-a / ⑤-b 各自的 pass 條件也內建「筆數必須符合預期」，就算日後有人刪掉 ⑤-0，
--     這兩條自己也擋得住「兩邊都空 → 沒差異 → ✅」。
--
-- 測資設計（刻意讓 delta > 0，這樣 ⑤ 才是真的在比對，不是 0=0 的假通過）：
--   訂單需求：A=10、B=20、C=30
--   原 PR   ：A=10、B=20、C=25   → delta 只剩 C=5
--   搬 A 這一項到新 PR → already 加總不變（A 10 + B 20 + C 25）→ delta 必須還是 C=5
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. 測試身分（tenant + role）
-- ---------------------------------------------------------------------------
-- auth.jwt() = coalesce(request.jwt.claim, request.jwt.claims)，兩個參數名都灌，
-- 免得因 Supabase 版本差異拿到 NULL、_current_tenant_id() 直接 RAISE。
SET LOCAL request.jwt.claim  = '{"tenant_id":"deadbeef-0000-4000-8000-000000000001","app_metadata":{"role":"owner"},"sub":"deadbeef-0000-4000-8000-0000000000ff"}';
SET LOCAL request.jwt.claims = '{"tenant_id":"deadbeef-0000-4000-8000-000000000001","app_metadata":{"role":"owner"},"sub":"deadbeef-0000-4000-8000-0000000000ff"}';

CREATE TEMP TABLE _t_env ON COMMIT DROP AS
SELECT
  'deadbeef-0000-4000-8000-000000000001'::UUID AS tenant,
  'deadbeef-0000-4000-8000-0000000000ff'::UUID AS operator,
  (CURRENT_DATE - 3)::DATE                     AS close_date;

CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_json(k TEXT PRIMARY KEY, v JSONB)  ON COMMIT DROP;
CREATE TEMP TABLE _t_result(
  seq    INT,
  item   TEXT,
  pass   BOOLEAN,
  detail TEXT
) ON COMMIT DROP;

-- ---------------------------------------------------------------------------
-- 1. 建測資（全部掛在測試 tenant 底下，名稱一律【測試】/ ZZTEST- 前綴，一眼可辨）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant   UUID := (SELECT tenant     FROM _t_env);
  v_op       UUID := (SELECT operator   FROM _t_env);
  v_date     DATE := (SELECT close_date FROM _t_env);
  v_loc      BIGINT;
  v_store    BIGINT;
  v_channel  BIGINT;
  v_supplier BIGINT;
  v_product  BIGINT;
  v_sku_a    BIGINT;
  v_sku_b    BIGINT;
  v_sku_c    BIGINT;
  v_camp     BIGINT;
  v_ci_a     BIGINT;
  v_ci_b     BIGINT;
  v_ci_c     BIGINT;
  v_order    BIGINT;
  v_pr       BIGINT;
  v_decoy    BIGINT;
BEGIN
  INSERT INTO locations (tenant_id, code, name, type)
  VALUES (v_tenant, 'ZZTEST-LOC', '【測試】部分轉採購總倉', 'central_warehouse')
  RETURNING id INTO v_loc;

  INSERT INTO stores (tenant_id, code, name, location_id)
  VALUES (v_tenant, 'ZZTEST-STORE', '【測試】部分轉採購門市', v_loc)
  RETURNING id INTO v_store;

  INSERT INTO line_channels (tenant_id, code, name, home_store_id)
  VALUES (v_tenant, 'ZZTEST-CH', '【測試】部分轉採購頻道', v_store)
  RETURNING id INTO v_channel;

  INSERT INTO suppliers (tenant_id, code, name)
  VALUES (v_tenant, 'ZZTEST-SUP', '【測試】部分轉採購供應商')
  RETURNING id INTO v_supplier;

  INSERT INTO products (tenant_id, product_code, name, status)
  VALUES (v_tenant, 'ZZTEST-P1', '【測試】部分轉採購商品', 'active')
  RETURNING id INTO v_product;

  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
  VALUES (v_tenant, v_product, 'ZZTEST-SKU-A', 'A 規格', 'active', '【測試】部分轉採購商品')
  RETURNING id INTO v_sku_a;

  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
  VALUES (v_tenant, v_product, 'ZZTEST-SKU-B', 'B 規格', 'active', '【測試】部分轉採購商品')
  RETURNING id INTO v_sku_b;

  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
  VALUES (v_tenant, v_product, 'ZZTEST-SKU-C', 'C 規格', 'active', '【測試】部分轉採購商品')
  RETURNING id INTO v_sku_c;

  -- 開團：end_at 換算成台北時區的日期要等於 close_date（補單 SQL 就是這樣切日的）。
  -- status 用 'locked' —— 原 PR 建立時就已鎖團，本案是「搬移」不是「新彙總」。
  -- product_id 故意留 NULL，藉此略過 campaign_items 的 1-campaign-1-product 防呆 trigger。
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, end_at)
  VALUES (v_tenant, 'ZZTEST-CAMP', '【測試】部分轉採購團', 'locked',
          ((v_date + TIME '12:00') AT TIME ZONE 'Asia/Taipei'))
  RETURNING id INTO v_camp;

  INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
  VALUES (v_tenant, v_camp, v_sku_a, 150) RETURNING id INTO v_ci_a;
  INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
  VALUES (v_tenant, v_camp, v_sku_b, 80)  RETURNING id INTO v_ci_b;
  INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
  VALUES (v_tenant, v_camp, v_sku_c, 40)  RETURNING id INTO v_ci_c;

  -- 顧客訂單：A=10 / B=20 / C=30（這就是 demand）
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status)
  VALUES (v_tenant, 'ZZTEST-ORD-1', v_camp, v_channel, v_store, 'confirmed')
  RETURNING id INTO v_order;

  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  VALUES
    (v_tenant, v_order, v_ci_a, v_sku_a, 10, 150, 'pending'),
    (v_tenant, v_order, v_ci_b, v_sku_b, 20,  80, 'pending'),
    (v_tenant, v_order, v_ci_c, v_sku_c, 30,  40, 'pending');

  -- 原 PR（close_date）：A=10 / B=20 / C=25 → 故意少請購 C 5 個，讓 delta 保持 > 0
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_location_id,
    status, total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-SRC', 'close_date', v_date, v_loc,
    'draft', 0, '【測試】原始請購單備註', v_op, v_op
  ) RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
    retail_price, franchise_price, source_campaign_id, raw_line, notes,
    parse_confidence, created_by, updated_by
  ) VALUES
    (v_pr, v_sku_a, 10, v_supplier, 100, 150, 130, v_camp, 'A 原始文字', 'A 行備註', 0.900, v_op, v_op),
    (v_pr, v_sku_b, 20, v_supplier,  50,  80,  70, v_camp, 'B 原始文字', 'B 行備註', 0.800, v_op, v_op),
    (v_pr, v_sku_c, 25, v_supplier,  20,  40,  35, v_camp, 'C 原始文字', 'C 行備註', 0.700, v_op, v_op);

  -- join 表（trigger 其實已經補了，這裡照建單 RPC 的慣例再顯式寫一次）
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr, v_camp, v_tenant)
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  -- total_amount 沒有 trigger，比照建單 RPC 手算：10*100 + 20*50 + 25*20 = 2500
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(pri.line_subtotal) FROM purchase_request_items pri WHERE pri.pr_id = pr.id
         ), 0)
   WHERE pr.id = v_pr;

  -- 另一張單（⑦ 跨 PR 守衛用）。刻意用 source_type='manual'：
  -- 補單的 already 只算 source_type='close_date' 的單，這張不會污染 delta 比對。
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_location_id,
    status, total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, 'ZZTEST-PR-OTHER', 'manual', v_loc,
    'draft', 0, '【測試】另一張單（跨單守衛用）', v_op, v_op
  ) RETURNING id INTO v_decoy;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, created_by, updated_by
  ) VALUES (v_decoy, v_sku_a, 1, v_supplier, 100, v_op, v_op);

  INSERT INTO _t_ctx(k, v) VALUES
    ('campaign',   v_camp),
    ('supplier',   v_supplier),
    ('location',   v_loc),
    ('sku_a',      v_sku_a),
    ('sku_b',      v_sku_b),
    ('sku_c',      v_sku_c),
    ('src_pr',     v_pr),
    ('decoy_pr',   v_decoy),
    ('item_a',     (SELECT id FROM purchase_request_items WHERE pr_id = v_pr   AND sku_id = v_sku_a)),
    ('item_b',     (SELECT id FROM purchase_request_items WHERE pr_id = v_pr   AND sku_id = v_sku_b)),
    ('decoy_item', (SELECT id FROM purchase_request_items WHERE pr_id = v_decoy AND sku_id = v_sku_a));
END $$;

-- ---------------------------------------------------------------------------
-- 2. 搬移「前」快照 —— ⑤ 的基準線，一定要在呼叫 RPC 之前抓
-- ---------------------------------------------------------------------------

-- 2a. 補單卡片的真實資料源（正式函式，不是自己重寫一份邏輯）
CREATE TEMP TABLE _t_delta_before ON COMMIT DROP AS
SELECT * FROM public.rpc_list_supplementable_close_dates();

-- 2b. 逐 SKU 的「已請購量」（= 20260714000060:102-111 的 already CTE，本案根因所在）
CREATE TEMP TABLE _t_already_before ON COMMIT DROP AS
SELECT pri.sku_id, SUM(pri.qty_requested) AS qty
  FROM purchase_requests pr
  JOIN purchase_request_items pri ON pri.pr_id = pr.id
 WHERE pr.tenant_id        = (SELECT tenant     FROM _t_env)
   AND pr.source_type      = 'close_date'
   AND pr.source_close_date = (SELECT close_date FROM _t_env)
   AND pr.status <> 'cancelled'
 GROUP BY pri.sku_id;

-- 2c. 原 PR 的 total_amount，與被搬那一列的完整欄位值
CREATE TEMP TABLE _t_total_before ON COMMIT DROP AS
SELECT total_amount FROM purchase_requests WHERE id = (SELECT v FROM _t_ctx WHERE k = 'src_pr');

CREATE TEMP TABLE _t_item_before ON COMMIT DROP AS
SELECT sku_id, qty_requested, suggested_supplier_id, unit_cost,
       retail_price, franchise_price, source_campaign_id,
       raw_line, notes, parse_confidence
  FROM purchase_request_items
 WHERE id = (SELECT v FROM _t_ctx WHERE k = 'item_a');

-- ---------------------------------------------------------------------------
-- 3. 執行搬移：把 SKU A 那一項搬到新單
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := public.rpc_create_partial_pr_from_items(
             (SELECT v FROM _t_ctx WHERE k = 'src_pr'),
             ARRAY[(SELECT v FROM _t_ctx WHERE k = 'item_a')],
             (SELECT operator FROM _t_env)
           );
  INSERT INTO _t_json(k, v) VALUES ('rpc_result', v_res);
  INSERT INTO _t_ctx(k, v)  VALUES ('new_pr', (v_res ->> 'new_pr_id')::BIGINT);
END $$;

-- ---------------------------------------------------------------------------
-- 4. 搬移「後」快照
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _t_delta_after ON COMMIT DROP AS
SELECT * FROM public.rpc_list_supplementable_close_dates();

CREATE TEMP TABLE _t_already_after ON COMMIT DROP AS
SELECT pri.sku_id, SUM(pri.qty_requested) AS qty
  FROM purchase_requests pr
  JOIN purchase_request_items pri ON pri.pr_id = pr.id
 WHERE pr.tenant_id        = (SELECT tenant     FROM _t_env)
   AND pr.source_type      = 'close_date'
   AND pr.source_close_date = (SELECT close_date FROM _t_env)
   AND pr.status <> 'cancelled'
 GROUP BY pri.sku_id;

-- ---------------------------------------------------------------------------
-- 5. 驗證項目
-- ---------------------------------------------------------------------------

-- ① 新 PR 1 項
INSERT INTO _t_result(seq, item, pass, detail)
SELECT 10, '① 新 PR 品項數 = 1', (n = 1), format('實際 %s 項（新單號 %s）', n, new_no)
  FROM (
    SELECT (SELECT COUNT(*)::INT FROM purchase_request_items
             WHERE pr_id = (SELECT v FROM _t_ctx WHERE k = 'new_pr')) AS n,
           (SELECT v ->> 'new_pr_no' FROM _t_json WHERE k = 'rpc_result') AS new_no
  ) t;

-- ② 原 PR 2 項
INSERT INTO _t_result(seq, item, pass, detail)
SELECT 20, '② 原 PR 剩餘品項數 = 2', (n = 2), format('實際 %s 項', n)
  FROM (
    SELECT (SELECT COUNT(*)::INT FROM purchase_request_items
             WHERE pr_id = (SELECT v FROM _t_ctx WHERE k = 'src_pr')) AS n
  ) t;

-- ③ 兩張 total_amount 正確（新 1000 / 原 1500；且合計 = 搬移前的 2500，金額不憑空生滅）
INSERT INTO _t_result(seq, item, pass, detail)
SELECT 30,
       '③ 兩張 total_amount 正確（新 1000 / 原 1500 / 合計 = 搬移前 2500）',
       (new_total = 1000 AND src_total = 1500 AND new_total + src_total = before_total),
       format('新 %s ＋ 原 %s ＝ %s；搬移前 %s',
              new_total, src_total, new_total + src_total, before_total)
  FROM (
    SELECT (SELECT total_amount FROM purchase_requests
             WHERE id = (SELECT v FROM _t_ctx WHERE k = 'new_pr')) AS new_total,
           (SELECT total_amount FROM purchase_requests
             WHERE id = (SELECT v FROM _t_ctx WHERE k = 'src_pr')) AS src_total,
           (SELECT total_amount FROM _t_total_before)              AS before_total
  ) t;

-- ④ join 表關聯不斷：
--    (a) 一致性檢查（本案兩張 PR 範圍內）0 筆 —— 只看自己的單，避免測試庫既有髒資料誤判
--    (b) 新 PR 有掛到該團
--    (c) 原 PR 的關聯沒有被清掉（決策 C：一律不動）
INSERT INTO _t_result(seq, item, pass, detail)
SELECT 40,
       '④ join 表關聯不斷（一致性 0 筆 / 新 PR 有關聯 / 原 PR 關聯未被清）',
       (orphans = 0 AND new_link = 1 AND src_link = 1),
       format('孤兒 %s 筆；新 PR 關聯 %s 筆；原 PR 關聯 %s 筆', orphans, new_link, src_link)
  FROM (
    SELECT
      (SELECT COUNT(*)::INT FROM public.fn_check_pr_campaigns_consistency() c
        WHERE c.pr_id IN ((SELECT v FROM _t_ctx WHERE k = 'src_pr'),
                          (SELECT v FROM _t_ctx WHERE k = 'new_pr'))) AS orphans,
      (SELECT COUNT(*)::INT FROM purchase_request_campaigns
        WHERE pr_id = (SELECT v FROM _t_ctx WHERE k = 'new_pr')
          AND campaign_id = (SELECT v FROM _t_ctx WHERE k = 'campaign')) AS new_link,
      (SELECT COUNT(*)::INT FROM purchase_request_campaigns
        WHERE pr_id = (SELECT v FROM _t_ctx WHERE k = 'src_pr')
          AND campaign_id = (SELECT v FROM _t_ctx WHERE k = 'campaign')) AS src_link
  ) t;

-- ⑤-0 ★前提斷言★ —— 搬移「前」必須真的有東西可比對。
--   沒有這條，⑤-a 就退化成「0 筆 EXCEPT 0 筆 = 沒差異 → ✅」的假通過：
--   JWT 模擬失敗、結單日掉出 60 天窗口、測資條件跑掉，任何一個都會讓 before 直接是空的，
--   然後亮一個完全沒有保護力的綠燈。
--   預期值就寫死在這裡：delta = 該結單日 1 個 SKU（C）/ 共 5 個；already 快照 3 個 SKU。
--   ★ 這條若 ❌，⑤-a / ⑤-b 的綠燈一律不算數。
INSERT INTO _t_result(seq, item, pass, detail)
SELECT 45,
       '⑤-0 前提：搬移前確實有 delta 可比對（本條 ❌ 時，⑤-a/⑤-b 的綠燈一律不算數）',
       (delta_ok AND already_rows = 3),
       format('delta 命中預期（%s：1 個 SKU / 共 5）= %s；delta 快照 %s 筆；already 快照 %s 筆（預期 3）',
              (SELECT close_date FROM _t_env), delta_ok, delta_rows, already_rows)
  FROM (
    SELECT
      EXISTS (SELECT 1 FROM _t_delta_before
               WHERE close_date     = (SELECT close_date FROM _t_env)
                 AND remaining_skus = 1
                 AND remaining_qty  = 5)            AS delta_ok,
      (SELECT COUNT(*)::INT FROM _t_delta_before)   AS delta_rows,
      (SELECT COUNT(*)::INT FROM _t_already_before) AS already_rows
  ) t;

-- ⑤-a ★本案核心★ 補單 delta 前後完全相同（直接比 rpc_list_supplementable_close_dates 的輸出）
--   pass 條件除了「無差異」，還要求 before_rows > 0 —— 就算日後有人拿掉 ⑤-0，
--   這條自己也不會在「兩邊都空」時假通過。
INSERT INTO _t_result(seq, item, pass, detail)
SELECT 50,
       '⑤-a 補單 delta 搬移前後完全相同（rpc_list_supplementable_close_dates 全欄位比對）',
       (lost = 0 AND gained = 0 AND before_rows > 0),
       format('前後差異：少 %s 筆 / 多 %s 筆；搬移前 %s 筆 = [%s]；搬移後 %s 筆 = [%s]',
              lost, gained,
              before_rows, COALESCE(before_txt, '(無)'),
              after_rows,  COALESCE(after_txt,  '(無)'))
  FROM (
    SELECT
      (SELECT COUNT(*)::INT FROM (
         SELECT * FROM _t_delta_before EXCEPT ALL SELECT * FROM _t_delta_after) x) AS lost,
      (SELECT COUNT(*)::INT FROM (
         SELECT * FROM _t_delta_after  EXCEPT ALL SELECT * FROM _t_delta_before) y) AS gained,
      (SELECT COUNT(*)::INT FROM _t_delta_before) AS before_rows,
      (SELECT COUNT(*)::INT FROM _t_delta_after)  AS after_rows,
      (SELECT string_agg(format('%s: %s 個 SKU / 共 %s', close_date, remaining_skus, remaining_qty), ' | ')
         FROM _t_delta_before) AS before_txt,
      (SELECT string_agg(format('%s: %s 個 SKU / 共 %s', close_date, remaining_skus, remaining_qty), ' | ')
         FROM _t_delta_after)  AS after_txt
  ) t;

-- ⑤-b 已請購量（already）逐 SKU 前後完全相同 —— delta = demand − already，
--     demand 沒被動過，所以 already 守恆就是 delta 守恆的根本原因
--   同樣內建筆數斷言（前後都必須是 3 個 SKU），避免「兩邊都空 → 沒差異 → ✅」。
INSERT INTO _t_result(seq, item, pass, detail)
SELECT 60,
       '⑤-b 已請購量（already）逐 SKU 前後完全相同（前後都必須是 3 個 SKU）',
       (lost = 0 AND gained = 0 AND before_rows = 3 AND after_rows = 3),
       format('前後差異：少 %s 筆 / 多 %s 筆；筆數 前 %s / 後 %s（預期各 3）；搬移後 = [%s]',
              lost, gained, before_rows, after_rows, COALESCE(after_txt, '(無)'))
  FROM (
    SELECT
      (SELECT COUNT(*)::INT FROM (
         SELECT * FROM _t_already_before EXCEPT ALL SELECT * FROM _t_already_after) x) AS lost,
      (SELECT COUNT(*)::INT FROM (
         SELECT * FROM _t_already_after  EXCEPT ALL SELECT * FROM _t_already_before) y) AS gained,
      (SELECT COUNT(*)::INT FROM _t_already_before) AS before_rows,
      (SELECT COUNT(*)::INT FROM _t_already_after)  AS after_rows,
      (SELECT string_agg(format('sku %s = %s', sku_id, qty), ' | ' ORDER BY sku_id)
         FROM _t_already_after) AS after_txt
  ) t;

-- ⑧（附加）搬過去的那一列，欄位值與原本逐欄一致
--    ③ 只保證金額對，這條才保證供應商 / 售價 / 來源團 / 備註沒有在搬移途中被洗掉。
--    ※ 執行順序刻意排在 ⑥⑦ 之前（顯示順序仍照編號）：⑥⑦ 是負向測試，
--      萬一守衛失效、RPC 真的動了資料，也不會污染這條正向比對。
INSERT INTO _t_result(seq, item, pass, detail)
SELECT 90,
       '⑧ 搬移後的品項欄位逐欄一致（供應商/成本/售價/來源團/原始文字/備註/信心值）',
       (diff = 0),
       CASE WHEN diff = 0 THEN '10 個欄位全部相同' ELSE format('有 %s 欄不一致', diff) END
  FROM (
    SELECT (SELECT COUNT(*)::INT FROM (
              SELECT * FROM _t_item_before
              EXCEPT
              SELECT sku_id, qty_requested, suggested_supplier_id, unit_cost,
                     retail_price, franchise_price, source_campaign_id,
                     raw_line, notes, parse_confidence
                FROM purchase_request_items
               WHERE pr_id = (SELECT v FROM _t_ctx WHERE k = 'new_pr')
            ) d) AS diff
  ) t;

-- ⑥ 全選搬移被擋（決策 F：原 PR 不可被搬空）
DO $$
DECLARE
  v_all BIGINT[];
  v_msg TEXT;
BEGIN
  SELECT array_agg(id ORDER BY id) INTO v_all
    FROM purchase_request_items
   WHERE pr_id = (SELECT v FROM _t_ctx WHERE k = 'src_pr');

  BEGIN
    PERFORM public.rpc_create_partial_pr_from_items(
      (SELECT v FROM _t_ctx WHERE k = 'src_pr'), v_all, (SELECT operator FROM _t_env));
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (70, '⑥ 全選搬移被擋', FALSE, '沒擋住 —— RPC 竟然成功回傳（原單會被搬空）');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (70, '⑥ 全選搬移被擋', (v_msg LIKE '%全部轉出%'), format('RAISE：%s', v_msg));
  END;
END $$;

-- ⑦ 跨 PR 的 item_id 被擋（勾選清單裡混一個別張單的品項）
DO $$
DECLARE
  v_msg TEXT;
BEGIN
  BEGIN
    PERFORM public.rpc_create_partial_pr_from_items(
      (SELECT v FROM _t_ctx WHERE k = 'src_pr'),
      ARRAY[(SELECT v FROM _t_ctx WHERE k = 'item_b'),
            (SELECT v FROM _t_ctx WHERE k = 'decoy_item')],
      (SELECT operator FROM _t_env));
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (80, '⑦ 跨 PR 的 item_id 被擋', FALSE, '沒擋住 —— RPC 竟然成功回傳（別張單的品項被搬走）');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (80, '⑦ 跨 PR 的 item_id 被擋', (v_msg LIKE '%不屬於本請購單%'), format('RAISE：%s', v_msg));
  END;
END $$;

-- ⑨ p_item_ids 傳 NULL 被擋（COALESCE 成空陣列後應走「請先勾選」那條）
DO $$
DECLARE
  v_msg TEXT;
BEGIN
  BEGIN
    PERFORM public.rpc_create_partial_pr_from_items(
      (SELECT v FROM _t_ctx WHERE k = 'src_pr'), NULL::BIGINT[], (SELECT operator FROM _t_env));
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (100, '⑨ p_item_ids = NULL 被擋', FALSE, '沒擋住 —— RPC 竟然成功回傳');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (100, '⑨ p_item_ids = NULL 被擋', (v_msg LIKE '%請先勾選%'), format('RAISE：%s', v_msg));
  END;
END $$;

-- ⑩ p_item_ids 傳空陣列被擋
DO $$
DECLARE
  v_msg TEXT;
BEGIN
  BEGIN
    PERFORM public.rpc_create_partial_pr_from_items(
      (SELECT v FROM _t_ctx WHERE k = 'src_pr'), '{}'::BIGINT[], (SELECT operator FROM _t_env));
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (110, '⑩ p_item_ids = 空陣列被擋', FALSE, '沒擋住 —— RPC 竟然成功回傳');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (110, '⑩ p_item_ids = 空陣列被擋', (v_msg LIKE '%請先勾選%'), format('RAISE：%s', v_msg));
  END;
END $$;

-- ⑪ 重複 id：這條是「預期成功」的測試 —— 去重後應該正常搬移，而且只搬 1 筆（不是 3 筆）。
--    因為它會真的建單、真的搬東西，用「子交易 + 故意 RAISE」整包滾掉，
--    才不會污染前面已經驗完的狀態。訊息當作回傳通道把 moved_count 帶出來。
--    （唯一留下的副作用是燒掉一個 pr_no 序號 —— nextval 不受 rollback 回補，檔頭已註明。）
--    若去重壞了：ARRAY[b,b,b] 會讓 want=3 但 matched=1 → 守衛 7 RAISE → 本條判 ❌。
DO $$
DECLARE
  v_item  BIGINT := (SELECT v FROM _t_ctx WHERE k = 'item_b');
  v_msg   TEXT;
  v_moved TEXT;
BEGIN
  BEGIN
    SELECT (public.rpc_create_partial_pr_from_items(
              (SELECT v FROM _t_ctx WHERE k = 'src_pr'),
              ARRAY[v_item, v_item, v_item],
              (SELECT operator FROM _t_env)) ->> 'moved_count')
      INTO v_moved;
    RAISE EXCEPTION 'PROBE_OK moved=%', v_moved;
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
  END;

  IF v_msg LIKE 'PROBE_OK moved=%' THEN
    v_moved := replace(v_msg, 'PROBE_OK moved=', '');
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (120, '⑪ 重複 id 去重後正常成功，且只搬 1 筆', (v_moved = '1'),
            format('moved_count = %s（預期 1；若為 3 表示沒去重）', v_moved));
  ELSE
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (120, '⑪ 重複 id 去重後正常成功，且只搬 1 筆', FALSE,
            format('預期成功卻 RAISE：%s', v_msg));
  END IF;
END $$;

-- ⑫ 含不存在的 id 被擋（守衛 7：命中筆數 ≠ 去重後勾選數）
DO $$
DECLARE
  v_msg TEXT;
BEGIN
  BEGIN
    PERFORM public.rpc_create_partial_pr_from_items(
      (SELECT v FROM _t_ctx WHERE k = 'src_pr'),
      ARRAY[(SELECT v FROM _t_ctx WHERE k = 'item_b'), 9223372036854775807::BIGINT],
      (SELECT operator FROM _t_env));
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (130, '⑫ 含不存在的 id 被擋', FALSE, '沒擋住 —— RPC 竟然成功回傳');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _t_result(seq, item, pass, detail)
    VALUES (130, '⑫ 含不存在的 id 被擋', (v_msg LIKE '%不屬於本請購單%'), format('RAISE：%s', v_msg));
  END;
END $$;

-- ⑬ 已拆 PO（po_item_id 非空）的品項被擋（守衛 8 的雙重保險）。
--    原 PR 目前沒有已拆 PO 的品項，所以在子交易裡臨時造一張 PO + 一筆掛上去的請購品項，
--    測完連同 PO 一起滾掉 —— 不論擋住與否都會回滾，不會污染前面的驗證結果。
DO $$
DECLARE
  v_tenant UUID   := (SELECT tenant   FROM _t_env);
  v_op     UUID   := (SELECT operator FROM _t_env);
  v_po     BIGINT;
  v_poi    BIGINT;
  v_pri    BIGINT;
  v_msg    TEXT;
BEGIN
  BEGIN
    INSERT INTO purchase_orders (
      tenant_id, po_no, supplier_id, dest_location_id, status, created_by, updated_by
    ) VALUES (
      v_tenant, 'ZZTEST-PO-1',
      (SELECT v FROM _t_ctx WHERE k = 'supplier'),
      (SELECT v FROM _t_ctx WHERE k = 'location'),
      'draft', v_op, v_op
    ) RETURNING id INTO v_po;

    INSERT INTO purchase_order_items (
      po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by
    ) VALUES (
      v_po, (SELECT v FROM _t_ctx WHERE k = 'sku_c'), 5, 20, v_op, v_op
    ) RETURNING id INTO v_poi;

    INSERT INTO purchase_request_items (
      pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
      source_campaign_id, po_item_id, created_by, updated_by
    ) VALUES (
      (SELECT v FROM _t_ctx WHERE k = 'src_pr'),
      (SELECT v FROM _t_ctx WHERE k = 'sku_c'), 5,
      (SELECT v FROM _t_ctx WHERE k = 'supplier'), 20,
      (SELECT v FROM _t_ctx WHERE k = 'campaign'), v_poi, v_op, v_op
    ) RETURNING id INTO v_pri;

    PERFORM public.rpc_create_partial_pr_from_items(
      (SELECT v FROM _t_ctx WHERE k = 'src_pr'), ARRAY[v_pri], v_op);

    -- 走到這裡代表守衛 8 沒擋住
    RAISE EXCEPTION 'PROBE_NOT_BLOCKED';
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
  END;

  INSERT INTO _t_result(seq, item, pass, detail)
  VALUES (140, '⑬ 已拆 PO（po_item_id 非空）的品項被擋',
          (v_msg LIKE '%已拆成採購單%'),
          CASE WHEN v_msg = 'PROBE_NOT_BLOCKED'
               THEN '沒擋住 —— RPC 竟然成功搬走已拆 PO 的品項'
               ELSE format('RAISE：%s', v_msg) END);
END $$;

-- ---------------------------------------------------------------------------
-- 6. 結果輸出（貼上就跑，✅ / ❌ 一眼可辨）
-- ---------------------------------------------------------------------------
SELECT 序, 結果, 驗證項目, 實際值
  FROM (
    SELECT seq AS 序,
           CASE WHEN COALESCE(pass, FALSE) THEN '✅ PASS' ELSE '❌ FAIL' END AS 結果,
           item   AS 驗證項目,
           detail AS 實際值
      FROM _t_result
    UNION ALL
    SELECT 999,
           CASE WHEN COUNT(*) FILTER (WHERE NOT COALESCE(pass, FALSE)) = 0
                THEN '✅ 全部通過' ELSE '❌ 有項目未通過' END,
           '=== 總結 ===',
           format('通過 %s / %s 項%s',
                  COUNT(*) FILTER (WHERE COALESCE(pass, FALSE)),
                  COUNT(*),
                  -- 前提斷言掛掉的話一定要講白：後面那些綠燈不能當證據
                  CASE WHEN COUNT(*) FILTER (WHERE seq = 45 AND COALESCE(pass, FALSE)) = 0
                       THEN '　⚠️ ⑤-0 前提未成立 → ⑤-a/⑤-b 就算 ✅ 也不算數，請先修測資或 JWT 模擬'
                       ELSE '' END)
      FROM _t_result
  ) x
 ORDER BY 序;

-- RPC 實際回傳值（人工對照用）
SELECT '(參考) RPC 回傳' AS 說明, v AS 內容 FROM _t_json WHERE k = 'rpc_result';

-- ---------------------------------------------------------------------------
-- 7. 一律回滾 —— 上面建的測資、兩張測試 PR、新單全部不落地
-- ---------------------------------------------------------------------------
ROLLBACK;

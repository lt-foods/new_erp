-- ============================================================================
-- 驗證腳本：採購單頁「分店／批發追加」
-- 對應 migration：supabase/migrations/20261002000000_po_store_additions.sql
-- 規格：公司\01_進行中\實作計畫_NEW-ERP採購單頁分店批發追加_2026-10-01.md（第二部分 §3）
-- ----------------------------------------------------------------------------
-- ⛔ 只在**本機臨時庫**執行。整份包在交易裡，跑完 ROLLBACK 不留測資。
--    （不要在測試庫／正式庫跑：夾具會建團、訂單、請購單、採購單。）
--
-- ⚠️ 執行身分：測 13／14（對照組）會用 pg_get_functiondef 複製
--    rpc_add_po_store_demands、拿掉一段後另存成別的名字。需要函式擁有者或超級使用者。
--
-- 測試清單（計畫 §3 的 1～14，加 0、15～24；22～24 是第二輪審查補的）
--    0. 夾具前提＋預覽：店B 派貨 10、補單差額 0、表頭金額；預覽列出可加的團與對不出團的品項
--    1. 30 件、未到未派，店B +1 → 採購單 31、請購單 31、派貨店B 11、補單差額 0
--    2. 一次三家：店B +1、店A +2（店A 已有店家單→併進去）、批發A +1 → 採購單 34、紀錄 3 列
--    3. 原本多叫（需求 29／採購 30），店B +1 → 採購單、請購單都不動、派貨店B +1、X=0
--    4. 已收過貨／有未取消進貨單 → 擋（已取消的進貨單不擋）
--    5. 已開撿貨單 → 擋（已取消的撿貨單不擋）
--    6. 已斷貨 → 擋
--    7. 採購單不是已送出（草稿、部分到貨）→ 擋
--    8. 店家自開團 → 擋
--    9. 合併建單（一列採購對兩列請購，兩列都有這團）→ 擋
--   10. 舊資料（請購品項沒有各團明細）→ 擋
--   11. 店長帳號 → 擋（預覽與寫入都擋）
--   12. 同一 request_key 重送：內容一樣（含順序不同、同一家店拆兩筆）→ 不重複加、回上次結果；
--       團或各店數量不一樣 → 擋（白話）、一個字都沒寫；拿去別的品項用 → 擋
--   13. 對照組：拿掉第 3 步（不改請購單）→ 補單差額變 1 → 測 1 的檢查必須紅
--   14. 對照組：拿掉第 1 步（不加店家單）→ 派貨店B 還是 10 → 測 1 的檢查必須紅
--   15. 同一請購品項有兩團 → 只改指定那團的明細
--   16. 表頭金額：採購單 subtotal／total 照既有算法重算（含同單其他品項）、tax 不動；請購單總額重算
--   17. 這個團原本就有還沒叫貨的量（需求 31／採購 30），店B +1 → X=2（回傳與紀錄正確）
--   18. 輸入防呆：停用的店、數量 0、空清單、店家單已在後段狀態 → 擋，一個字都不寫
--   19. 團不是已結單／已鎖（已完成）→ 擋
--   20. 權限：兩支內部函式 anon／authenticated 都不能執行；兩支 rpc_* 只有 authenticated
--   21. 請購品項總數 ≠ 各團明細加總（歸屬不完整）→ 擋（不然第 3 步改總數會被 #982 守衛擋成技術錯誤）
--   22. 目標列完整、但**別張**舊請購單有一列沒有各團明細、記在這團名下（會少買）→ 擋
--   23. 目標列完整、但**別張**舊請購單用 purchase_request_campaigns 連到這團、那一列記的是別團（會多買）→ 擋
--   24. 廠商已確認短少（confirmed_shortfall > 0）→ 擋；（對照）confirmed_shortfall = 0 → 不擋
--   ⇒ 22／23 的對照組（拿掉 migration 裡的 LEGACY 段）由本機測試工具負責：兩條都必須變紅。
--
-- 「鎖完再檢查一次」「追加 vs 斷貨／調整已收量 不互卡」需要兩個連線同時跑，單一交易測不到 ——
--   由本機測試工具的「併發測試」那一段負責（見施工回報）。
--
-- 測試資料一律用「店A／店B／店C／批發A」這種一般名稱，不用真實門市。
-- ============================================================================

BEGIN;

SET LOCAL request.jwt.claim  = '{"tenant_id":"feed0000-0000-4000-8000-000000000032","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}';
SET LOCAL request.jwt.claims = '{"tenant_id":"feed0000-0000-4000-8000-000000000032","app_metadata":{"role":"owner"},"sub":"feed0000-0000-4000-8000-0000000000fe"}';

CREATE TEMP TABLE _t_env ON COMMIT DROP AS
SELECT
  'feed0000-0000-4000-8000-000000000032'::UUID AS tenant,
  'feed0000-0000-4000-8000-0000000000fe'::UUID AS operator,
  'feed0000-0000-4000-8000-0000000000fd'::UUID AS manager,     -- 店長（測 11）
  (CURRENT_DATE - 1)::DATE AS close_date;

CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_result(seq INT, item TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;
CREATE TEMP TABLE _t_snap(k TEXT PRIMARY KEY, v NUMERIC) ON COMMIT DROP;


-- ----------------------------------------------------------------------------
-- 共用小工具
-- ----------------------------------------------------------------------------
CREATE FUNCTION pg_temp._t_id(p_k TEXT) RETURNS BIGINT
LANGUAGE plpgsql AS $f$
DECLARE v BIGINT;
BEGIN
  SELECT c.v INTO v FROM _t_ctx c WHERE c.k = p_k;
  IF v IS NULL THEN
    RAISE EXCEPTION '夾具找不到 %', p_k;
  END IF;
  RETURN v;
END $f$;

-- 一筆追加輸入：{store_id, qty}
CREATE FUNCTION pg_temp._t_add(p_store TEXT, p_qty NUMERIC) RETURNS JSONB
LANGUAGE sql AS $f$
  SELECT jsonb_build_object('store_id', pg_temp._t_id(p_store), 'qty', p_qty)
$f$;

-- 呼叫寫入函式（p_fn 讓對照組可以換成拿掉一段的版本）
CREATE FUNCTION pg_temp._t_call(
  p_fn TEXT, p_key TEXT, p_additions JSONB, p_rk UUID, p_camp TEXT DEFAULT '.camp'
) RETURNS JSONB
LANGUAGE plpgsql AS $f$
DECLARE v JSONB;
BEGIN
  EXECUTE format('SELECT public.%I($1, $2, $3, $4, $5, $6)', p_fn)
     INTO v
    USING pg_temp._t_id(p_key || '.po'), pg_temp._t_id(p_key || '.poi'),
          pg_temp._t_id(p_key || p_camp), p_additions,
          (SELECT operator FROM _t_env), p_rk;
  RETURN v;
END $f$;

-- 派貨工作台（v_picking_demand_by_po，線上現行版本）裡這家店要幾件
CREATE FUNCTION pg_temp._t_dispatch(p_key TEXT, p_store TEXT) RETURNS NUMERIC
LANGUAGE sql AS $f$
  SELECT COALESCE(SUM(v.demand_qty), 0)
    FROM public.v_picking_demand_by_po v
   WHERE v.po_item_id = pg_temp._t_id(p_key || '.poi')
     AND v.store_id = pg_temp._t_id(p_store)
$f$;

-- 補單差額（既有 helper）
CREATE FUNCTION pg_temp._t_delta(p_key TEXT, p_camp TEXT DEFAULT '.camp') RETURNS NUMERIC
LANGUAGE sql AS $f$
  SELECT COALESCE((
    SELECT d.delta_qty
      FROM public._pr_campaign_sku_remaining_rows(ARRAY[pg_temp._t_id(p_key || p_camp)]) d
     WHERE d.sku_id = pg_temp._t_id(p_key || '.sku')
  ), 0)
$f$;

-- 這個團裡由「分店／批發追加」建出來的店家單品項有幾筆
CREATE FUNCTION pg_temp._t_internal_items(p_key TEXT, p_camp TEXT DEFAULT '.camp') RETURNS BIGINT
LANGUAGE sql AS $f$
  SELECT COUNT(*)
    FROM public.customer_order_items coi
    JOIN public.customer_orders co ON co.id = coi.order_id
   WHERE co.campaign_id = pg_temp._t_id(p_key || p_camp)
     AND coi.source = 'store_internal'
$f$;


-- ----------------------------------------------------------------------------
-- 共用夾具：一個租戶、四家店、頻道
--   店A／店B／店C = 分店，批發A = 批發，停用店 = 已停用（測 18）
--   頻道：一個沒綁店的「總頻道」（最先建，批發A 沒有自己的頻道會退回用它）＋ 店A／B／C 各一
-- ----------------------------------------------------------------------------
DO $base$
DECLARE
  v_tenant UUID := (SELECT tenant FROM _t_env);
  v_loc    BIGINT;
  v_sup    BIGINT;
  v_prod   BIGINT;
  v_store  BIGINT;
  v_ch     BIGINT;
  r        RECORD;
BEGIN
  INSERT INTO locations (tenant_id, code, name, type)
  VALUES (v_tenant, 'ZZPOADD-LOC', '【測試】追加總倉', 'central_warehouse')
  RETURNING id INTO v_loc;

  INSERT INTO suppliers (tenant_id, code, name)
  VALUES (v_tenant, 'ZZPOADD-SUP', '【測試】追加供應商')
  RETURNING id INTO v_sup;

  INSERT INTO products (tenant_id, product_code, name, status)
  VALUES (v_tenant, 'ZZPOADD-P', '【測試】追加商品', 'active')
  RETURNING id INTO v_prod;

  INSERT INTO _t_ctx(k, v) VALUES ('loc', v_loc), ('sup', v_sup), ('prod', v_prod);

  INSERT INTO line_channels (tenant_id, code, name, home_store_id)
  VALUES (v_tenant, 'ZZPOADD-CH-GEN', '【測試】總頻道', NULL)
  RETURNING id INTO v_ch;
  INSERT INTO _t_ctx(k, v) VALUES ('chGEN', v_ch);

  FOR r IN
    SELECT * FROM (VALUES
      ('storeA', 'ZZPOADD-A', '【測試】店A',   'branch',    TRUE,  TRUE),
      ('storeB', 'ZZPOADD-B', '【測試】店B',   'branch',    TRUE,  TRUE),
      ('storeC', 'ZZPOADD-C', '【測試】店C',   'branch',    TRUE,  TRUE),
      ('storeW', 'ZZPOADD-W', '【測試】批發A', 'wholesale', TRUE,  FALSE),
      ('storeX', 'ZZPOADD-X', '【測試】停用店', 'branch',   FALSE, FALSE)
    ) AS x(k, code, name, kind, active, has_channel)
  LOOP
    INSERT INTO stores (tenant_id, code, name, location_id, store_kind, is_active)
    VALUES (v_tenant, r.code, r.name, v_loc, r.kind, r.active)
    RETURNING id INTO v_store;
    INSERT INTO _t_ctx(k, v) VALUES (r.k, v_store);

    IF r.has_channel THEN
      INSERT INTO line_channels (tenant_id, code, name, home_store_id)
      VALUES (v_tenant, r.code || '-CH', r.name || ' 頻道', v_store)
      RETURNING id INTO v_ch;
      INSERT INTO _t_ctx(k, v) VALUES ('ch_' || r.k, v_ch);
    END IF;
  END LOOP;
END
$base$;


-- ----------------------------------------------------------------------------
-- 夾具產生器：一個「已鎖、已轉採購、貨未到未派」的情境（一個 key 一套，互不干擾）
--
--   每個團：店A 10、店B 10、店C 9 + 1（那 1 件是獨立一張單，測 3 會取消它）→ 需求 30
--   請購單（已轉採購 fully_ordered）一列 = 30 × 團數，各團明細各 30
--   採購單（已送出）：這個商品 30 × 團數 @100，加一個沒有請購連結的無關品項 5 @50
--   p_a_internal：店A 那 10 件改成「店A 的店家內部單」（測 2：已有店家單要併進去）
--   p_camp_status / p_owner_store：建團當下就給（⛔ 不事後 UPDATE 團的 status，
--   避免任何掛在團狀態上的觸發器被叫醒）
--
-- 🔴 順序跟真實世界一樣：先有訂單 → 再建採購單、請購單與各團明細（此時需求 ≥ 請購量，
--   #982 守衛放行）。直接寫終局狀態會被守衛當場退回。
-- ----------------------------------------------------------------------------
CREATE FUNCTION pg_temp._t_case(
  p_key          TEXT,
  p_two_camps    BOOLEAN DEFAULT FALSE,
  p_a_internal   BOOLEAN DEFAULT FALSE,
  p_camp_status  TEXT    DEFAULT 'locked',
  p_owner_store  TEXT    DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql AS $f$
DECLARE
  v_tenant UUID   := (SELECT tenant FROM _t_env);
  v_op     UUID   := (SELECT operator FROM _t_env);
  v_date   DATE   := (SELECT close_date FROM _t_env);
  v_loc    BIGINT := pg_temp._t_id('loc');
  v_sup    BIGINT := pg_temp._t_id('sup');
  v_prod   BIGINT := pg_temp._t_id('prod');
  v_n      INTEGER := CASE WHEN p_two_camps THEN 2 ELSE 1 END;
  v_sku    BIGINT;
  v_sku2   BIGINT;
  v_camp   BIGINT;
  v_camps  BIGINT[] := ARRAY[]::BIGINT[];
  v_ci     BIGINT;
  v_order  BIGINT;
  v_member BIGINT;
  v_po     BIGINT;
  v_poi    BIGINT;
  v_poi2   BIGINT;
  v_pr     BIGINT;
  v_pri    BIGINT;
  i        INTEGER;
  r        RECORD;
BEGIN
  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
  VALUES (v_tenant, v_prod, 'ZZPOADD-' || p_key, '1包', 'active', '【測試】追加商品 ' || p_key)
  RETURNING id INTO v_sku;

  INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, status, product_name)
  VALUES (v_tenant, v_prod, 'ZZPOADD-' || p_key || '-OTHER', '1包', 'active', '【測試】無關商品 ' || p_key)
  RETURNING id INTO v_sku2;

  FOR i IN 1..v_n LOOP
    INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, owner_store_id, end_at)
    VALUES (
      v_tenant, 'ZZPOADD-' || p_key || '-G' || i::TEXT, '【測試】追加團 ' || p_key || '-' || i::TEXT,
      p_camp_status,
      CASE WHEN p_owner_store IS NULL THEN NULL ELSE pg_temp._t_id(p_owner_store) END,
      ((v_date + TIME '12:00') AT TIME ZONE 'Asia/Taipei')
    )
    RETURNING id INTO v_camp;
    v_camps := v_camps || v_camp;

    INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
    VALUES (v_tenant, v_camp, v_sku, 180)
    RETURNING id INTO v_ci;

    FOR r IN
      SELECT * FROM (VALUES
        ('A',  'storeA', 10::NUMERIC),
        ('B',  'storeB', 10::NUMERIC),
        ('C1', 'storeC',  9::NUMERIC),
        ('C2', 'storeC',  1::NUMERIC)
      ) AS x(tag, store_k, qty)
    LOOP
      IF r.tag = 'A' AND p_a_internal THEN
        -- 店A 的店家內部單（跟 rpc_get_or_create_store_member 建出來的同一個內部會員）
        v_member := public.rpc_get_or_create_store_member(pg_temp._t_id('storeA'), v_op);
        INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, member_id,
                                     pickup_store_id, status, order_kind, created_by, updated_by)
        VALUES (v_tenant, 'ZZPOADD-' || p_key || '-' || i::TEXT || '-AINT', v_camp,
                pg_temp._t_id('ch_storeA'), v_member, pg_temp._t_id('storeA'),
                'confirmed', 'normal', v_op, v_op)
        RETURNING id INTO v_order;
        INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty,
                                          unit_price, status, source)
        VALUES (v_tenant, v_order, v_ci, v_sku, r.qty, 180, 'pending', 'store_internal');
      ELSE
        INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id,
                                     pickup_store_id, status, created_by, updated_by)
        VALUES (v_tenant, 'ZZPOADD-' || p_key || '-' || i::TEXT || '-' || r.tag, v_camp,
                pg_temp._t_id('ch_' || r.store_k), pg_temp._t_id(r.store_k),
                'confirmed', v_op, v_op)
        RETURNING id INTO v_order;
        INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty,
                                          unit_price, status)
        VALUES (v_tenant, v_order, v_ci, v_sku, r.qty, 180, 'pending');
      END IF;
    END LOOP;
  END LOOP;

  -- 採購單（已送出）＋ 一個沒有請購連結的無關品項（表頭金額要把它也算進去）
  INSERT INTO purchase_orders (tenant_id, po_no, supplier_id, dest_location_id, status,
                               subtotal, tax, total, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-PO-' || p_key, v_sup, v_loc, 'sent', 0, 0, 0, v_op, v_op)
  RETURNING id INTO v_po;

  INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by)
  VALUES (v_po, v_sku, 30 * v_n, 100, v_op, v_op)
  RETURNING id INTO v_poi;

  INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by)
  VALUES (v_po, v_sku2, 5, 50, v_op, v_op)
  RETURNING id INTO v_poi2;

  -- 表頭照真實算法給值（rpc_split_pr_to_pos），不留 0
  UPDATE purchase_orders po
     SET subtotal = (SELECT SUM(qty_ordered * unit_cost) FROM purchase_order_items WHERE po_id = po.id),
         total    = (SELECT SUM(qty_ordered * unit_cost) FROM purchase_order_items WHERE po_id = po.id)
   WHERE po.id = v_po;

  -- 請購單（已轉採購）
  INSERT INTO purchase_requests (tenant_id, pr_no, source_type, source_close_date, source_location_id,
                                 status, total_amount, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-PR-' || p_key, 'close_date', v_date, v_loc,
          'fully_ordered', 0, v_op, v_op)
  RETURNING id INTO v_pr;

  INSERT INTO purchase_request_items (pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
                                      po_item_id, created_by, updated_by)
  VALUES (v_pr, v_sku, 30 * v_n, v_sup, 100, v_poi, v_op, v_op)
  RETURNING id INTO v_pri;

  FOREACH v_camp IN ARRAY v_camps LOOP
    INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
    VALUES (v_pri, v_camp, v_tenant, 30);
    INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
    VALUES (v_pr, v_camp, v_tenant);
  END LOOP;

  UPDATE purchase_requests pr
     SET total_amount = (SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = pr.id)
   WHERE pr.id = v_pr;

  INSERT INTO _t_ctx(k, v) VALUES
    (p_key || '.sku', v_sku), (p_key || '.sku2', v_sku2),
    (p_key || '.camp', v_camps[1]),
    (p_key || '.po', v_po), (p_key || '.poi', v_poi), (p_key || '.poi2', v_poi2),
    (p_key || '.pr', v_pr), (p_key || '.pri', v_pri);
  IF v_n = 2 THEN
    INSERT INTO _t_ctx(k, v) VALUES (p_key || '.camp2', v_camps[2]);
  END IF;
END $f$;


-- ----------------------------------------------------------------------------
-- 測 1 的檢查（測 1 本身與對照組 13／14 共用同一份，對照組才算是「讓測 1 變紅」）
--   情境：店B +1
--   應該：採購單 30→31、請購單 30→31（品項與各團明細）、派貨店B 11（店A／店C 不變）、
--         補單差額 0、這個商品只有 1 張採購單、紀錄 1 列（X=1）、店B 有一張 confirmed 店家單、
--         採購單表頭 3250→3350（含無關品項 250）、tax 不動、請購單總額 3000→3100
-- ----------------------------------------------------------------------------
CREATE FUNCTION pg_temp._t_check1(
  p_key TEXT, p_fn TEXT,
  OUT o_pass BOOLEAN, OUT o_detail TEXT, OUT o_store_b NUMERIC, OUT o_delta NUMERIC
)
LANGUAGE plpgsql AS $f$
DECLARE
  v_res     JSONB;
  v_poi     NUMERIC;
  v_pri     NUMERIC;
  v_pric    NUMERIC;
  v_a       NUMERIC;
  v_c       NUMERIC;
  v_po_cnt  INTEGER;
  v_add_cnt INTEGER;
  v_add_ok  BOOLEAN;
  v_int_ok  BOOLEAN;
  v_sub     NUMERIC;
  v_tot     NUMERIC;
  v_tax     NUMERIC;
  v_prtot   NUMERIC;
BEGIN
  v_res := pg_temp._t_call(p_fn, p_key, jsonb_build_array(pg_temp._t_add('storeB', 1)), gen_random_uuid());

  SELECT qty_ordered INTO v_poi FROM purchase_order_items WHERE id = pg_temp._t_id(p_key || '.poi');
  SELECT qty_requested INTO v_pri FROM purchase_request_items WHERE id = pg_temp._t_id(p_key || '.pri');
  SELECT qty_requested INTO v_pric FROM purchase_request_item_campaigns
   WHERE pr_item_id = pg_temp._t_id(p_key || '.pri') AND campaign_id = pg_temp._t_id(p_key || '.camp');

  v_a := pg_temp._t_dispatch(p_key, 'storeA');
  o_store_b := pg_temp._t_dispatch(p_key, 'storeB');
  v_c := pg_temp._t_dispatch(p_key, 'storeC');
  o_delta := pg_temp._t_delta(p_key);

  SELECT COUNT(DISTINCT v.po_id) INTO v_po_cnt
    FROM public.v_picking_demand_by_po v
   WHERE v.sku_id = pg_temp._t_id(p_key || '.sku');

  SELECT COUNT(*),
         COALESCE(bool_and(a.qty_added = 1 AND a.pr_delta_qty = 1 AND a.pr_qty_after = 31
                           AND a.store_id = pg_temp._t_id('storeB')), FALSE)
    INTO v_add_cnt, v_add_ok
    FROM purchase_request_store_additions a
   WHERE a.pr_item_id = pg_temp._t_id(p_key || '.pri');

  SELECT EXISTS (
    SELECT 1
      FROM customer_orders co
      JOIN members m ON m.id = co.member_id
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.campaign_id = pg_temp._t_id(p_key || '.camp')
       AND co.pickup_store_id = pg_temp._t_id('storeB')
       AND m.member_type = 'store_internal'
       AND co.status = 'confirmed'
       AND co.order_kind = 'normal'
       AND coi.qty = 1
       AND coi.source = 'store_internal'
  ) INTO v_int_ok;

  SELECT subtotal, total, tax INTO v_sub, v_tot, v_tax
    FROM purchase_orders WHERE id = pg_temp._t_id(p_key || '.po');
  SELECT total_amount INTO v_prtot FROM purchase_requests WHERE id = pg_temp._t_id(p_key || '.pr');

  o_pass := COALESCE(
        v_poi = 31 AND v_pri = 31 AND v_pric = 31
    AND v_a = 10 AND o_store_b = 11 AND v_c = 10
    AND o_delta = 0
    AND v_po_cnt = 1
    AND v_add_cnt = 1 AND v_add_ok
    AND v_int_ok
    AND v_sub = 3350 AND v_tot = 3350 AND v_tax = 0
    AND v_prtot = 3100
    AND (v_res ->> 'po_added_qty')::NUMERIC = 1
    AND (v_res ->> 'store_added_qty')::NUMERIC = 1
    AND (v_res ->> 'po_qty_before')::NUMERIC = 30
    AND (v_res ->> 'po_qty_after')::NUMERIC = 31
    AND (v_res ->> 'pr_qty_after')::NUMERIC = 31
    AND (v_res ->> 'idempotent')::BOOLEAN = FALSE, FALSE);

  o_detail := format(
    '採購單 %s、請購品項 %s、這團明細 %s、派貨 店A %s／店B %s／店C %s、補單差額 %s、採購單張數 %s、'
    '紀錄 %s 列(內容對=%s)、店B 店家單=%s、表頭 subtotal %s total %s tax %s、請購總額 %s、回傳 %s',
    v_poi, v_pri, v_pric, v_a, o_store_b, v_c, o_delta, v_po_cnt,
    v_add_cnt, v_add_ok, v_int_ok, v_sub, v_tot, v_tax, v_prtot, v_res);
END $f$;


-- ----------------------------------------------------------------------------
-- 「應該被擋」的共用檢查：預覽要寫出原因、寫入要擋下、而且一個字都沒寫
-- ----------------------------------------------------------------------------
CREATE FUNCTION pg_temp._t_expect_block(
  p_key TEXT, p_like TEXT, OUT o_pass BOOLEAN, OUT o_detail TEXT
)
LANGUAGE plpgsql AS $f$
DECLARE
  v_reason TEXT;
  v_can    BOOLEAN;
  v_err    TEXT;
  v_po0 NUMERIC; v_po1 NUMERIC;
  v_pr0 NUMERIC; v_pr1 NUMERIC;
  v_in0 BIGINT;  v_in1 BIGINT;
  v_ad0 BIGINT;  v_ad1 BIGINT;
BEGIN
  SELECT qty_ordered INTO v_po0 FROM purchase_order_items WHERE id = pg_temp._t_id(p_key || '.poi');
  SELECT SUM(qty_requested) INTO v_pr0 FROM purchase_request_items WHERE po_item_id = pg_temp._t_id(p_key || '.poi');
  v_in0 := pg_temp._t_internal_items(p_key);
  SELECT COUNT(*) INTO v_ad0 FROM purchase_request_store_additions WHERE campaign_id = pg_temp._t_id(p_key || '.camp');

  SELECT p.can_add, p.block_reason INTO v_can, v_reason
    FROM public.rpc_preview_po_store_additions(pg_temp._t_id(p_key || '.po')) p
   WHERE p.po_item_id = pg_temp._t_id(p_key || '.poi')
     AND p.campaign_id = pg_temp._t_id(p_key || '.camp');

  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', p_key,
                            jsonb_build_array(pg_temp._t_add('storeB', 1)), gen_random_uuid());
    v_err := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  SELECT qty_ordered INTO v_po1 FROM purchase_order_items WHERE id = pg_temp._t_id(p_key || '.poi');
  SELECT SUM(qty_requested) INTO v_pr1 FROM purchase_request_items WHERE po_item_id = pg_temp._t_id(p_key || '.poi');
  v_in1 := pg_temp._t_internal_items(p_key);
  SELECT COUNT(*) INTO v_ad1 FROM purchase_request_store_additions WHERE campaign_id = pg_temp._t_id(p_key || '.camp');

  o_pass := COALESCE(
        v_can = FALSE AND v_reason LIKE p_like
    AND v_err LIKE p_like
    AND v_po1 = v_po0 AND v_pr1 = v_pr0 AND v_in1 = v_in0 AND v_ad1 = v_ad0, FALSE);
  o_detail := format('預覽 can_add=%s 原因=%s｜寫入=%s｜採購 %s→%s 請購 %s→%s 店家單品項 %s→%s 紀錄 %s→%s',
                     v_can, v_reason, v_err, v_po0, v_po1, v_pr0, v_pr1, v_in0, v_in1, v_ad0, v_ad1);
END $f$;


-- 對照組：把 rpc_add_po_store_demands 拿掉 `-- >>> 標記 BEGIN` ～ `-- <<< 標記 END` 那一段，
-- 另存成 p_new_name。⛔ 不手抄函式本體（會慢慢對不上變成假綠），一律從現行定義切。
-- 找不到標記就大聲失敗 —— 不然對照組會「什麼都沒拿掉」卻顯示綠。
CREATE FUNCTION pg_temp._t_make_mutant(p_marker TEXT, p_new_name TEXT) RETURNS VOID
LANGUAGE plpgsql AS $f$
DECLARE
  v_def TEXT;
  v_s   INTEGER;
  v_e   INTEGER;
  v_end TEXT := '-- <<< ' || p_marker || ' END';
BEGIN
  v_def := pg_get_functiondef(
    'public.rpc_add_po_store_demands(bigint, bigint, bigint, jsonb, uuid, uuid)'::regprocedure);
  v_s := strpos(v_def, '-- >>> ' || p_marker || ' BEGIN');
  v_e := strpos(v_def, v_end);
  IF v_s = 0 OR v_e = 0 OR v_e < v_s THEN
    RAISE EXCEPTION '對照組做不出來：rpc_add_po_store_demands 裡找不到 % 的標記', p_marker;
  END IF;
  v_def := left(v_def, v_s - 1)
        || '-- （對照組：' || p_marker || ' 這一段已拿掉）'
        || substr(v_def, v_e + length(v_end));
  v_def := replace(v_def, 'FUNCTION public.rpc_add_po_store_demands(', 'FUNCTION public.' || p_new_name || '(');
  IF strpos(v_def, p_new_name) = 0 THEN
    RAISE EXCEPTION '對照組做不出來：改名失敗';
  END IF;
  EXECUTE v_def;
END $f$;


-- ============================================================================
-- 建所有情境（都在任何追加之前建好）
-- ============================================================================
DO $cases$
BEGIN
  PERFORM pg_temp._t_case('c1');
  PERFORM pg_temp._t_case('c2', p_a_internal => TRUE);
  PERFORM pg_temp._t_case('c3');
  PERFORM pg_temp._t_case('c4a');
  PERFORM pg_temp._t_case('c4b');
  PERFORM pg_temp._t_case('c4c');
  PERFORM pg_temp._t_case('c5a');
  PERFORM pg_temp._t_case('c5b');
  PERFORM pg_temp._t_case('c6');
  PERFORM pg_temp._t_case('c7a');
  PERFORM pg_temp._t_case('c7b');
  PERFORM pg_temp._t_case('c8', p_owner_store => 'storeA');
  PERFORM pg_temp._t_case('c9');
  PERFORM pg_temp._t_case('c10');
  PERFORM pg_temp._t_case('c11');
  PERFORM pg_temp._t_case('c12');
  PERFORM pg_temp._t_case('c12b');
  PERFORM pg_temp._t_case('c12c', p_two_camps => TRUE);
  PERFORM pg_temp._t_case('m13');
  PERFORM pg_temp._t_case('m14');
  PERFORM pg_temp._t_case('c15', p_two_camps => TRUE);
  PERFORM pg_temp._t_case('c17');
  PERFORM pg_temp._t_case('c18', p_a_internal => TRUE);
  PERFORM pg_temp._t_case('c19', p_camp_status => 'completed');
  PERFORM pg_temp._t_case('c21');
  PERFORM pg_temp._t_case('c22');
  PERFORM pg_temp._t_case('c23');
  PERFORM pg_temp._t_case('c24');
  PERFORM pg_temp._t_case('c24b');
END
$cases$;

-- 各情境的「建好之後才發生的事」（照真實順序：採購單已經送出，之後才有這些事）
DO $mutate$
DECLARE
  v_tenant UUID := (SELECT tenant FROM _t_env);
  v_op     UUID := (SELECT operator FROM _t_env);
  v_gr     BIGINT;
  v_wave   BIGINT;
  v_pr2    BIGINT;
  v_pri2   BIGINT;
  v_order  BIGINT;
  v_other  BIGINT;
  v_ci     BIGINT;
BEGIN
  -- c3：店C 那 1 件被客人取消 → 需求 29、採購 30（原本多叫 1）
  UPDATE customer_order_items coi SET status = 'cancelled'
    FROM customer_orders co
   WHERE co.id = coi.order_id AND co.order_no = 'ZZPOADD-c3-1-C2';
  UPDATE customer_orders SET status = 'cancelled' WHERE order_no = 'ZZPOADD-c3-1-C2';

  -- c4a：已收過貨
  UPDATE purchase_order_items SET qty_received = 5 WHERE id = pg_temp._t_id('c4a.poi');

  -- c4b：有一張還沒確認的進貨單（已收量還是 0）
  INSERT INTO goods_receipts (tenant_id, gr_no, po_id, supplier_id, dest_location_id, status, received_by)
  VALUES (v_tenant, 'ZZPOADD-GR-c4b', pg_temp._t_id('c4b.po'), pg_temp._t_id('sup'), pg_temp._t_id('loc'), 'draft', v_op)
  RETURNING id INTO v_gr;
  INSERT INTO goods_receipt_items (gr_id, po_item_id, sku_id, qty_received, unit_cost)
  VALUES (v_gr, pg_temp._t_id('c4b.poi'), pg_temp._t_id('c4b.sku'), 3, 100);

  -- c4c：進貨單已取消 → 不擋（反向對照）
  INSERT INTO goods_receipts (tenant_id, gr_no, po_id, supplier_id, dest_location_id, status, received_by)
  VALUES (v_tenant, 'ZZPOADD-GR-c4c', pg_temp._t_id('c4c.po'), pg_temp._t_id('sup'), pg_temp._t_id('loc'), 'cancelled', v_op)
  RETURNING id INTO v_gr;
  INSERT INTO goods_receipt_items (gr_id, po_item_id, sku_id, qty_received, unit_cost)
  VALUES (v_gr, pg_temp._t_id('c4c.poi'), pg_temp._t_id('c4c.sku'), 3, 100);

  -- c5a：開了撿貨單（草稿）
  INSERT INTO picking_waves (tenant_id, wave_code, wave_date, status, source_po_id)
  VALUES (v_tenant, 'ZZPOADD-WV-c5a', CURRENT_DATE, 'draft', pg_temp._t_id('c5a.po'))
  RETURNING id INTO v_wave;
  INSERT INTO picking_wave_items (tenant_id, wave_id, sku_id, store_id, qty, campaign_id)
  VALUES (v_tenant, v_wave, pg_temp._t_id('c5a.sku'), pg_temp._t_id('storeA'), 10, pg_temp._t_id('c5a.camp'));

  -- c5b：撿貨單已取消 → 不擋（反向對照）
  INSERT INTO picking_waves (tenant_id, wave_code, wave_date, status, source_po_id)
  VALUES (v_tenant, 'ZZPOADD-WV-c5b', CURRENT_DATE, 'cancelled', pg_temp._t_id('c5b.po'))
  RETURNING id INTO v_wave;
  INSERT INTO picking_wave_items (tenant_id, wave_id, sku_id, store_id, qty, campaign_id)
  VALUES (v_tenant, v_wave, pg_temp._t_id('c5b.sku'), pg_temp._t_id('storeA'), 10, pg_temp._t_id('c5b.camp'));

  -- c6：按過斷貨
  UPDATE purchase_order_items SET stockout_at = NOW() WHERE id = pg_temp._t_id('c6.poi');

  -- c7a：採購單還是草稿；c7b：部分到貨
  UPDATE purchase_orders SET status = 'draft' WHERE id = pg_temp._t_id('c7a.po');
  UPDATE purchase_orders SET status = 'partially_received' WHERE id = pg_temp._t_id('c7b.po');

  -- c9：合併建單 —— 原請購單那列改成 15，另一張請購單也有一列 15（同一團），兩列都接到同一列採購品項
  --     先改各團明細、再改總數（#982 守衛的順序）
  UPDATE purchase_request_item_campaigns SET qty_requested = 15
   WHERE pr_item_id = pg_temp._t_id('c9.pri');
  UPDATE purchase_request_items SET qty_requested = 15 WHERE id = pg_temp._t_id('c9.pri');
  INSERT INTO purchase_requests (tenant_id, pr_no, source_type, source_close_date, source_location_id,
                                 status, total_amount, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-PR-c9-2', 'close_date', (SELECT close_date FROM _t_env), pg_temp._t_id('loc'),
          'fully_ordered', 1500, v_op, v_op)
  RETURNING id INTO v_pr2;
  INSERT INTO purchase_request_items (pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
                                      po_item_id, created_by, updated_by)
  VALUES (v_pr2, pg_temp._t_id('c9.sku'), 15, pg_temp._t_id('sup'), 100, pg_temp._t_id('c9.poi'), v_op, v_op)
  RETURNING id INTO v_pri2;
  INSERT INTO purchase_request_item_campaigns (pr_item_id, campaign_id, tenant_id, qty_requested)
  VALUES (v_pri2, pg_temp._t_id('c9.camp'), v_tenant, 15);
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr2, pg_temp._t_id('c9.camp'), v_tenant);

  -- c10：舊資料 —— 沒有各團明細、只有 source_campaign_id
  DELETE FROM purchase_request_item_campaigns WHERE pr_item_id = pg_temp._t_id('c10.pri');
  UPDATE purchase_request_items SET source_campaign_id = pg_temp._t_id('c10.camp')
   WHERE id = pg_temp._t_id('c10.pri');

  -- c17：採購單送出之後，店C 又多 1 件、一直沒補單 → 需求 31、採購 30
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-c17-1-C3', pg_temp._t_id('c17.camp'), pg_temp._t_id('ch_storeC'),
          pg_temp._t_id('storeC'), 'confirmed', v_op, v_op)
  RETURNING id INTO v_order;
  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  SELECT v_tenant, v_order, ci.id, ci.sku_id, 1, 180, 'pending'
    FROM campaign_items ci WHERE ci.campaign_id = pg_temp._t_id('c17.camp');

  -- c18：店A 的店家單已經進入後段狀態（出貨中）
  UPDATE customer_orders SET status = 'shipping' WHERE order_no = 'ZZPOADD-c18-1-AINT';

  -- c21：請購品項總數 30、各團明細只剩 29（歸屬不完整；#982 只在改品項時比對，改明細時不比對，所以造得出來）
  UPDATE purchase_request_item_campaigns SET qty_requested = 29
   WHERE pr_item_id = pg_temp._t_id('c21.pri');

  -- c22（會少買）：目標那一列完整（有各團明細 30）；**另一張**還沒取消的舊請購單上，
  --   有一列「沒有各團明細、source_campaign_id 記這團」5 件 → helper 把 5 件整列算成這團的
  --   → 已請購 35／需求 30、差額 -5 → 照算的話店B +1 時採購單 +0（少買）。
  --   照真實順序造：舊列是 #982 守衛上線前就有的。守衛只在改請購時檢查需求，
  --   所以夾具先多 5 件訂單 → 建舊列（守衛看到需求 35 ≥ 35 放行）→ 那 5 件取消（守衛不回頭查）。
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-c22-1-TMP', pg_temp._t_id('c22.camp'), pg_temp._t_id('ch_storeC'),
          pg_temp._t_id('storeC'), 'confirmed', v_op, v_op)
  RETURNING id INTO v_order;
  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  SELECT v_tenant, v_order, ci.id, ci.sku_id, 5, 180, 'pending'
    FROM campaign_items ci WHERE ci.campaign_id = pg_temp._t_id('c22.camp');
  INSERT INTO purchase_requests (tenant_id, pr_no, source_type, source_close_date, source_location_id,
                                 status, total_amount, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-PR-c22-OLD', 'close_date', (SELECT close_date FROM _t_env) - 7, pg_temp._t_id('loc'),
          'submitted', 500, v_op, v_op)
  RETURNING id INTO v_pr2;
  INSERT INTO purchase_request_items (pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
                                      source_campaign_id, created_by, updated_by)
  VALUES (v_pr2, pg_temp._t_id('c22.sku'), 5, pg_temp._t_id('sup'), 100, pg_temp._t_id('c22.camp'), v_op, v_op);
  UPDATE customer_order_items SET status = 'cancelled' WHERE order_id = v_order;
  UPDATE customer_orders SET status = 'cancelled' WHERE id = v_order;

  -- c23（會多買）：目標那一列完整（有各團明細 30）；**另一張**舊請購單用 purchase_request_campaigns
  --   連到這團和「別團」，它那一列 5 件沒有各團明細、source_campaign_id 記的是別團（只記第一個團的舊缺陷）
  --   → helper 把 5 件算給別團，這團一件都沒算到。這團之後的 5 件訂單其實已經包在那 5 件裡，
  --   但 helper 看到需求 35／已請購 30、差額 +5 → 照算的話店B +1 時採購單 +6（多買 5）。
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, end_at)
  VALUES (v_tenant, 'ZZPOADD-c23-OTHER', '【測試】追加團 c23 別團', 'locked',
          (((SELECT close_date FROM _t_env) + TIME '12:00') AT TIME ZONE 'Asia/Taipei'))
  RETURNING id INTO v_other;
  INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price)
  VALUES (v_tenant, v_other, pg_temp._t_id('c23.sku'), 180)
  RETURNING id INTO v_ci;
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-c23-OTHER-A', v_other, pg_temp._t_id('ch_storeA'),
          pg_temp._t_id('storeA'), 'confirmed', v_op, v_op)
  RETURNING id INTO v_order;
  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  VALUES (v_tenant, v_order, v_ci, pg_temp._t_id('c23.sku'), 5, 180, 'pending');
  INSERT INTO purchase_requests (tenant_id, pr_no, source_type, source_close_date, source_location_id,
                                 status, total_amount, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-PR-c23-OLD', 'close_date', (SELECT close_date FROM _t_env) - 7, pg_temp._t_id('loc'),
          'submitted', 500, v_op, v_op)
  RETURNING id INTO v_pr2;
  INSERT INTO purchase_request_items (pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
                                      source_campaign_id, created_by, updated_by)
  VALUES (v_pr2, pg_temp._t_id('c23.sku'), 5, pg_temp._t_id('sup'), 100, v_other, v_op, v_op);
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (v_pr2, pg_temp._t_id('c23.camp'), v_tenant), (v_pr2, v_other, v_tenant);
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_by, updated_by)
  VALUES (v_tenant, 'ZZPOADD-c23-1-C3', pg_temp._t_id('c23.camp'), pg_temp._t_id('ch_storeC'),
          pg_temp._t_id('storeC'), 'confirmed', v_op, v_op)
  RETURNING id INTO v_order;
  INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status)
  SELECT v_tenant, v_order, ci.id, ci.sku_id, 5, 180, 'pending'
    FROM campaign_items ci WHERE ci.campaign_id = pg_temp._t_id('c23.camp');
  INSERT INTO _t_ctx(k, v) VALUES ('c23.other', v_other);

  -- c24：廠商已確認短少 3 件（rpc_set_confirmed_shortfall 寫的欄位）；c24b：0（不算短少，對照用）
  UPDATE purchase_order_items SET confirmed_shortfall = 3 WHERE id = pg_temp._t_id('c24.poi');
  UPDATE purchase_order_items SET confirmed_shortfall = 0 WHERE id = pg_temp._t_id('c24b.poi');
END
$mutate$;


-- ============================================================================
-- 測 0：夾具前提＋預覽
--   ⭐ 夾具本身寫錯時，後面的測試會用錯的前提「綠」給你看。前提先驗，才輪到結論。
-- ============================================================================
DO $t0$
DECLARE
  v_b      NUMERIC;
  v_delta  NUMERIC;
  v_sub    NUMERIC;
  v_prtot  NUMERIC;
  v_d3     NUMERIC;
  v_d17    NUMERIC;
  v_rows   INTEGER;
  v_ok_row BOOLEAN;
  v_null_row BOOLEAN;
  v_d15    INTEGER;
BEGIN
  v_b := pg_temp._t_dispatch('c1', 'storeB');
  v_delta := pg_temp._t_delta('c1');
  SELECT subtotal INTO v_sub FROM purchase_orders WHERE id = pg_temp._t_id('c1.po');
  SELECT total_amount INTO v_prtot FROM purchase_requests WHERE id = pg_temp._t_id('c1.pr');
  v_d3 := pg_temp._t_delta('c3');
  v_d17 := pg_temp._t_delta('c17');

  INSERT INTO _t_snap VALUES ('c1.subtotal', v_sub), ('c1.prtotal', v_prtot);

  -- 預覽：c1 兩個品項 → 一列可加（有團、差額 0、需求 30、已請購 30）＋ 一列對不出團
  SELECT COUNT(*) INTO v_rows FROM public.rpc_preview_po_store_additions(pg_temp._t_id('c1.po'));
  SELECT EXISTS (
    SELECT 1 FROM public.rpc_preview_po_store_additions(pg_temp._t_id('c1.po')) p
     WHERE p.po_item_id = pg_temp._t_id('c1.poi') AND p.campaign_id = pg_temp._t_id('c1.camp')
       AND p.can_add AND p.block_reason IS NULL
       AND p.qty_ordered = 30 AND p.demand_qty = 30 AND p.already_qty = 30 AND p.delta_qty = 0
       AND p.campaign_no = 'ZZPOADD-c1-G1'
  ) INTO v_ok_row;
  SELECT EXISTS (
    SELECT 1 FROM public.rpc_preview_po_store_additions(pg_temp._t_id('c1.po')) p
     WHERE p.po_item_id = pg_temp._t_id('c1.poi2') AND p.campaign_id IS NULL
       AND NOT p.can_add AND p.block_reason LIKE '%對不出%'
  ) INTO v_null_row;
  SELECT COUNT(*) INTO v_d15
    FROM public.rpc_preview_po_store_additions(pg_temp._t_id('c15.po')) p
   WHERE p.po_item_id = pg_temp._t_id('c15.poi') AND p.can_add;

  INSERT INTO _t_result VALUES (
    0, '夾具前提＋預覽：店B 派貨 10、補單差額 0／c3 差額 -1／c17 差額 +1、表頭 3250、請購總額 3000；預覽 c1 兩列（一列可加、一列對不出團）、c15 兩團都可加',
    COALESCE(v_b = 10 AND v_delta = 0 AND v_d3 = -1 AND v_d17 = 1 AND v_sub = 3250 AND v_prtot = 3000
             AND v_rows = 2 AND v_ok_row AND v_null_row AND v_d15 = 2, FALSE),
    format('店B=%s 差額=%s c3差額=%s c17差額=%s 表頭=%s 請購總額=%s 預覽列數=%s 可加列對=%s 對不出團列對=%s c15可加團數=%s',
           v_b, v_delta, v_d3, v_d17, v_sub, v_prtot, v_rows, v_ok_row, v_null_row, v_d15)
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (0, '夾具前提＋預覽', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t0$;


-- ============================================================================
-- 測 20：權限（Supabase 預設會把新函式給 anon／authenticated，migration 要收回）
-- ============================================================================
DO $t20$
DECLARE
  v_bad TEXT := '';
  r     RECORD;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public._po_item_store_add_block_reason(bigint, bigint)', FALSE, FALSE),
      ('public._store_add_internal_order_item(uuid, bigint, text, bigint, bigint, numeric, bigint, numeric, uuid, text, text)', FALSE, FALSE),
      ('public.rpc_preview_po_store_additions(bigint)', FALSE, TRUE),
      ('public.rpc_add_po_store_demands(bigint, bigint, bigint, jsonb, uuid, uuid)', FALSE, TRUE)
    ) AS x(fn, want_anon, want_auth)
  LOOP
    IF has_function_privilege('anon', r.fn, 'EXECUTE') <> r.want_anon THEN
      v_bad := v_bad || format('anon %s 應為 %s; ', r.fn, r.want_anon);
    END IF;
    IF has_function_privilege('authenticated', r.fn, 'EXECUTE') <> r.want_auth THEN
      v_bad := v_bad || format('authenticated %s 應為 %s; ', r.fn, r.want_auth);
    END IF;
  END LOOP;

  INSERT INTO _t_result VALUES (
    20, '權限：兩支內部函式 anon／authenticated 都不能執行；兩支 rpc_* 只有 authenticated 能執行',
    v_bad = '', CASE WHEN v_bad = '' THEN '全部符合' ELSE v_bad END
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (20, '權限', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t20$;


-- ============================================================================
-- 測 1：30 件、未到未派，店B +1
-- ============================================================================
DO $t1$
DECLARE
  r RECORD;
BEGIN
  SELECT * INTO r FROM pg_temp._t_check1('c1', 'rpc_add_po_store_demands');
  INSERT INTO _t_result VALUES (
    1, '店B +1 → 採購單 31、請購單 31、派貨店B 11、補單差額 0（只有 1 張採購單、紀錄 1 列、店B 店家單 confirmed）',
    r.o_pass, r.o_detail);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (1, '店B +1', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t1$;


-- ============================================================================
-- 測 16：表頭金額（接著測 1 的 c1）
--   採購單：subtotal = SUM(qty_ordered * unit_cost)（含無關品項 5×50）、total = subtotal、tax 不動
--   請購單：total_amount = SUM(line_subtotal)
-- ============================================================================
DO $t16$
DECLARE
  v_sub NUMERIC; v_tot NUMERIC; v_tax NUMERIC; v_prtot NUMERIC;
  v_sub0 NUMERIC := (SELECT v FROM _t_snap WHERE k = 'c1.subtotal');
  v_pr0  NUMERIC := (SELECT v FROM _t_snap WHERE k = 'c1.prtotal');
BEGIN
  SELECT subtotal, total, tax INTO v_sub, v_tot, v_tax FROM purchase_orders WHERE id = pg_temp._t_id('c1.po');
  SELECT total_amount INTO v_prtot FROM purchase_requests WHERE id = pg_temp._t_id('c1.pr');
  INSERT INTO _t_result VALUES (
    16, '表頭金額：採購單 3250→3350（31×100＋無關品項 5×50）、total=subtotal、tax 不動；請購總額 3000→3100',
    COALESCE(v_sub0 = 3250 AND v_sub = 3350 AND v_tot = 3350 AND v_tax = 0 AND v_pr0 = 3000 AND v_prtot = 3100, FALSE),
    format('採購 subtotal %s→%s total %s tax %s｜請購總額 %s→%s', v_sub0, v_sub, v_tot, v_tax, v_pr0, v_prtot));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (16, '表頭金額', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t16$;


-- ============================================================================
-- 測 2：一次三家（店A 已經有店家單 → 併進那張；店B、批發A 新開）
-- ============================================================================
DO $t2$
DECLARE
  v_res   JSONB;
  v_poi   NUMERIC; v_pri NUMERIC; v_pric NUMERIC;
  v_a NUMERIC; v_b NUMERIC; v_c NUMERIC; v_w NUMERIC; v_delta NUMERIC;
  v_add   INTEGER; v_add_ok BOOLEAN;
  v_a_orders INTEGER; v_a_items INTEGER;
  v_w_ok  BOOLEAN;
BEGIN
  v_res := pg_temp._t_call('rpc_add_po_store_demands', 'c2',
             jsonb_build_array(pg_temp._t_add('storeB', 1), pg_temp._t_add('storeA', 2),
                               pg_temp._t_add('storeW', 1)),
             gen_random_uuid());

  SELECT qty_ordered INTO v_poi FROM purchase_order_items WHERE id = pg_temp._t_id('c2.poi');
  SELECT qty_requested INTO v_pri FROM purchase_request_items WHERE id = pg_temp._t_id('c2.pri');
  SELECT qty_requested INTO v_pric FROM purchase_request_item_campaigns WHERE pr_item_id = pg_temp._t_id('c2.pri');
  v_a := pg_temp._t_dispatch('c2', 'storeA');
  v_b := pg_temp._t_dispatch('c2', 'storeB');
  v_c := pg_temp._t_dispatch('c2', 'storeC');
  v_w := pg_temp._t_dispatch('c2', 'storeW');
  v_delta := pg_temp._t_delta('c2');

  SELECT COUNT(*),
         COALESCE(bool_and(a.pr_delta_qty = 4 AND a.pr_qty_after = 34
                           AND a.qty_added = CASE a.store_id WHEN pg_temp._t_id('storeA') THEN 2 ELSE 1 END
                           AND a.order_id IS NOT NULL AND a.order_item_id IS NOT NULL), FALSE)
    INTO v_add, v_add_ok
    FROM purchase_request_store_additions a WHERE a.pr_item_id = pg_temp._t_id('c2.pri');

  -- 店A：原本那張店家單被沿用（還是 1 張），上面多一個品項
  SELECT COUNT(DISTINCT co.id), COUNT(coi.id) INTO v_a_orders, v_a_items
    FROM customer_orders co
    JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
    JOIN customer_order_items coi ON coi.order_id = co.id
   WHERE co.campaign_id = pg_temp._t_id('c2.camp') AND co.pickup_store_id = pg_temp._t_id('storeA');

  -- 批發A：沒有自己的頻道 → 退回用總頻道，新開一張 confirmed 店家單
  SELECT EXISTS (
    SELECT 1 FROM customer_orders co
     WHERE co.campaign_id = pg_temp._t_id('c2.camp') AND co.pickup_store_id = pg_temp._t_id('storeW')
       AND co.channel_id = pg_temp._t_id('chGEN') AND co.status = 'confirmed'
  ) INTO v_w_ok;

  INSERT INTO _t_result VALUES (
    2, '一次三家：店B +1、店A +2、批發A +1 → 採購單 34、各店各自 +、紀錄 3 列；店A 併進既有店家單、批發A 用總頻道新開',
    COALESCE(v_poi = 34 AND v_pri = 34 AND v_pric = 34
             AND v_a = 12 AND v_b = 11 AND v_c = 10 AND v_w = 1 AND v_delta = 0
             AND v_add = 3 AND v_add_ok
             AND v_a_orders = 1 AND v_a_items = 2 AND v_w_ok
             AND (v_res ->> 'store_count')::INT = 3
             AND (v_res ->> 'store_added_qty')::NUMERIC = 4
             AND (v_res ->> 'po_added_qty')::NUMERIC = 4
             AND (v_res ->> 'created_order_count')::INT = 2, FALSE),
    format('採購 %s 請購 %s 明細 %s｜派貨 A %s B %s C %s 批發A %s｜差額 %s｜紀錄 %s 列(對=%s)｜店A 店家單 %s 張 %s 品項｜批發A 用總頻道=%s｜回傳 %s',
           v_poi, v_pri, v_pric, v_a, v_b, v_c, v_w, v_delta, v_add, v_add_ok, v_a_orders, v_a_items, v_w_ok, v_res));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (2, '一次三家', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t2$;


-- ============================================================================
-- 測 3：原本多叫（需求 29／採購 30），店B +1 → 採購單、請購單一個字都不動、X=0
-- ============================================================================
DO $t3$
DECLARE
  v_res JSONB;
  v_poi_ver0 TEXT; v_poi_ver1 TEXT;
  v_po_ver0  TEXT; v_po_ver1  TEXT;
  v_pri_ver0 TEXT; v_pri_ver1 TEXT;
  v_pr_ver0  TEXT; v_pr_ver1  TEXT;
  v_poi NUMERIC; v_pri NUMERIC; v_b NUMERIC; v_c NUMERIC; v_delta NUMERIC;
  v_add INTEGER; v_add_ok BOOLEAN;
BEGIN
  -- ctid ＝ 資料列版本：任何 UPDATE（就算改成一樣的值）都會換。只比數字會漏掉「偷改了又改回來」。
  SELECT ctid::TEXT INTO v_poi_ver0 FROM purchase_order_items WHERE id = pg_temp._t_id('c3.poi');
  SELECT ctid::TEXT INTO v_po_ver0  FROM purchase_orders WHERE id = pg_temp._t_id('c3.po');
  SELECT ctid::TEXT INTO v_pri_ver0 FROM purchase_request_items WHERE id = pg_temp._t_id('c3.pri');
  SELECT ctid::TEXT INTO v_pr_ver0  FROM purchase_requests WHERE id = pg_temp._t_id('c3.pr');

  v_res := pg_temp._t_call('rpc_add_po_store_demands', 'c3',
             jsonb_build_array(pg_temp._t_add('storeB', 1)), gen_random_uuid());

  SELECT ctid::TEXT, qty_ordered INTO v_poi_ver1, v_poi FROM purchase_order_items WHERE id = pg_temp._t_id('c3.poi');
  SELECT ctid::TEXT INTO v_po_ver1 FROM purchase_orders WHERE id = pg_temp._t_id('c3.po');
  SELECT ctid::TEXT, qty_requested INTO v_pri_ver1, v_pri FROM purchase_request_items WHERE id = pg_temp._t_id('c3.pri');
  SELECT ctid::TEXT INTO v_pr_ver1 FROM purchase_requests WHERE id = pg_temp._t_id('c3.pr');
  v_b := pg_temp._t_dispatch('c3', 'storeB');
  v_c := pg_temp._t_dispatch('c3', 'storeC');
  v_delta := pg_temp._t_delta('c3');

  SELECT COUNT(*), COALESCE(bool_and(a.qty_added = 1 AND a.pr_delta_qty = 0 AND a.pr_qty_after = 30), FALSE)
    INTO v_add, v_add_ok
    FROM purchase_request_store_additions a WHERE a.pr_item_id = pg_temp._t_id('c3.pri');

  INSERT INTO _t_result VALUES (
    3, '原本多叫（需求 29／採購 30），店B +1 → 採購單、請購單都不動（資料列版本不變）、派貨店B 11、X=0、紀錄 pr_delta_qty=0',
    COALESCE(v_poi = 30 AND v_pri = 30 AND v_b = 11 AND v_c = 9 AND v_delta = 0
             AND v_poi_ver0 = v_poi_ver1 AND v_po_ver0 = v_po_ver1
             AND v_pri_ver0 = v_pri_ver1 AND v_pr_ver0 = v_pr_ver1
             AND v_add = 1 AND v_add_ok
             AND (v_res ->> 'po_added_qty')::NUMERIC = 0
             AND (v_res ->> 'store_added_qty')::NUMERIC = 1
             AND (v_res ->> 'po_qty_before')::NUMERIC = 30
             AND (v_res ->> 'po_qty_after')::NUMERIC = 30
             AND (v_res ->> 'pr_qty_after')::NUMERIC = 30, FALSE),
    format('採購 %s 請購 %s 派貨 B %s C %s 差額 %s｜版本 採購品項 %s→%s 採購單 %s→%s 請購品項 %s→%s 請購單 %s→%s｜紀錄 %s 列(對=%s)｜回傳 %s',
           v_poi, v_pri, v_b, v_c, v_delta, v_poi_ver0, v_poi_ver1, v_po_ver0, v_po_ver1,
           v_pri_ver0, v_pri_ver1, v_pr_ver0, v_pr_ver1, v_add, v_add_ok, v_res));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (3, '原本多叫', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t3$;


-- ============================================================================
-- 測 4～10、19：各種「應該擋」
-- ============================================================================
DO $t4$
DECLARE a RECORD; b RECORD; v_c_can BOOLEAN;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c4a', '%已經收過貨%');
  SELECT * INTO b FROM pg_temp._t_expect_block('c4b', '%進貨單%');
  -- 反向對照：已取消的進貨單不擋
  SELECT p.can_add INTO v_c_can FROM public.rpc_preview_po_store_additions(pg_temp._t_id('c4c.po')) p
   WHERE p.po_item_id = pg_temp._t_id('c4c.poi') AND p.campaign_id = pg_temp._t_id('c4c.camp');
  INSERT INTO _t_result VALUES (
    4, '已收過貨 → 擋；有未取消的進貨單（已收 0）→ 擋；（對照）進貨單已取消 → 不擋',
    COALESCE(a.o_pass AND b.o_pass AND v_c_can, FALSE),
    format('已收過貨：%s ‖ 未取消進貨單：%s ‖ 已取消進貨單 can_add=%s', a.o_detail, b.o_detail, v_c_can));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (4, '已收過貨', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t4$;

DO $t5$
DECLARE a RECORD; v_b_can BOOLEAN;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c5a', '%撿貨單%');
  SELECT p.can_add INTO v_b_can FROM public.rpc_preview_po_store_additions(pg_temp._t_id('c5b.po')) p
   WHERE p.po_item_id = pg_temp._t_id('c5b.poi') AND p.campaign_id = pg_temp._t_id('c5b.camp');
  INSERT INTO _t_result VALUES (
    5, '已開撿貨單 → 擋；（對照）撿貨單已取消 → 不擋',
    COALESCE(a.o_pass AND v_b_can, FALSE),
    format('%s ‖ 已取消撿貨單 can_add=%s', a.o_detail, v_b_can));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (5, '已開撿貨單', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t5$;

DO $t6$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c6', '%斷貨%');
  INSERT INTO _t_result VALUES (6, '已斷貨 → 擋', a.o_pass, a.o_detail);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (6, '已斷貨', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t6$;

DO $t7$
DECLARE a RECORD; b RECORD;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c7a', '%草稿%');
  SELECT * INTO b FROM pg_temp._t_expect_block('c7b', '%部分到貨%');
  INSERT INTO _t_result VALUES (7, '採購單不是已送出（草稿、部分到貨）→ 擋',
    COALESCE(a.o_pass AND b.o_pass, FALSE), format('草稿：%s ‖ 部分到貨：%s', a.o_detail, b.o_detail));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (7, '採購單不是已送出', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t7$;

DO $t8$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c8', '%店家自己開%');
  INSERT INTO _t_result VALUES (8, '店家自開團 → 擋', a.o_pass, a.o_detail);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (8, '店家自開團', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t8$;

DO $t9$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c9', '%合併建單%2 列%');
  INSERT INTO _t_result VALUES (9, '合併建單（一列採購對兩列請購，兩列都有這團）→ 擋', a.o_pass, a.o_detail);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (9, '合併建單', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t9$;

DO $t10$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c10', '%舊資料%');
  INSERT INTO _t_result VALUES (10, '舊資料（請購品項沒有各團明細）→ 擋', a.o_pass, a.o_detail);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (10, '舊資料', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t10$;

DO $t21$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c21', '%總數 30%明細加總 29%對不起來%');
  INSERT INTO _t_result VALUES (21, '請購品項總數 30 ≠ 各團明細加總 29 → 擋（原因寫出兩個數字），一個字都沒寫', a.o_pass, a.o_detail);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (21, '總數≠明細加總', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t21$;

DO $t19$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c19', '%已完成%已結單／已鎖定%');
  INSERT INTO _t_result VALUES (19, '團不是已結單／已鎖（已完成）→ 擋（不重開團）', a.o_pass, a.o_detail);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (19, '團狀態', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t19$;

-- 測 22／23：目標列完整，但**別張**舊請購單（沒有各團明細）污染了這個 (團, 商品) 的已請購量
--   前提先驗（目標列完整、差額真的被帶歪），才輪到「擋下」這個結論。
--   對照組（拿掉 migration 的 LEGACY 段）時這兩條必須紅，紅的時候 detail 會寫出照算的結果：
--   測 22 採購單 30→30（店家 +1、採購單 +0 ＝ 少買）、測 23 採購單 30→36（多買 5）。
DO $t22$
DECLARE a RECORD; v_d NUMERIC; v_item NUMERIC; v_attr NUMERIC;
BEGIN
  v_d := pg_temp._t_delta('c22');
  SELECT qty_requested INTO v_item FROM purchase_request_items WHERE id = pg_temp._t_id('c22.pri');
  SELECT SUM(qty_requested) INTO v_attr FROM purchase_request_item_campaigns WHERE pr_item_id = pg_temp._t_id('c22.pri');
  SELECT * INTO a FROM pg_temp._t_expect_block('c22', '%舊格式%已請購量算不準%');
  INSERT INTO _t_result VALUES (
    22, '別張舊請購單有一列沒有各團明細、記在這團名下（照算會少買）→ 擋，一個字都沒寫',
    COALESCE(v_item = 30 AND v_attr = 30 AND v_d = -5 AND a.o_pass, FALSE),
    format('前提：目標列 %s／這團明細 %s、差額 %s（應為 -5：舊列 5 件被整列算成這團的）｜%s', v_item, v_attr, v_d, a.o_detail));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (22, '別張舊資料（少買）', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t22$;

DO $t23$
DECLARE a RECORD; v_d NUMERIC; v_d_other NUMERIC; v_item NUMERIC; v_attr NUMERIC;
BEGIN
  v_d := pg_temp._t_delta('c23');
  SELECT COALESCE((SELECT d.delta_qty FROM public._pr_campaign_sku_remaining_rows(ARRAY[pg_temp._t_id('c23.other')]) d
                    WHERE d.sku_id = pg_temp._t_id('c23.sku')), 0) INTO v_d_other;
  SELECT qty_requested INTO v_item FROM purchase_request_items WHERE id = pg_temp._t_id('c23.pri');
  SELECT SUM(qty_requested) INTO v_attr FROM purchase_request_item_campaigns WHERE pr_item_id = pg_temp._t_id('c23.pri');
  SELECT * INTO a FROM pg_temp._t_expect_block('c23', '%舊格式%已請購量算不準%');
  INSERT INTO _t_result VALUES (
    23, '別張舊請購單用 purchase_request_campaigns 連到這團、那一列記別團（照算會多買）→ 擋，一個字都沒寫',
    COALESCE(v_item = 30 AND v_attr = 30 AND v_d = 5 AND v_d_other = 0 AND a.o_pass, FALSE),
    format('前提：目標列 %s／這團明細 %s、這團差額 %s（應為 +5：舊列 5 件被算給別團）、別團差額 %s｜%s',
           v_item, v_attr, v_d, v_d_other, a.o_detail));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (23, '別張舊資料（多買）', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t23$;

-- 測 24：確定短少（#896）
DO $t24$
DECLARE a RECORD; v_b_can BOOLEAN; v_b_reason TEXT;
BEGIN
  SELECT * INTO a FROM pg_temp._t_expect_block('c24', '%會短少 3 件%確定短少%');
  SELECT p.can_add, p.block_reason INTO v_b_can, v_b_reason
    FROM public.rpc_preview_po_store_additions(pg_temp._t_id('c24b.po')) p
   WHERE p.po_item_id = pg_temp._t_id('c24b.poi') AND p.campaign_id = pg_temp._t_id('c24b.camp');
  INSERT INTO _t_result VALUES (
    24, '廠商已確認短少 3 件 → 擋（預覽與寫入），一個字都沒寫；（對照）確定短少 0 → 不擋',
    COALESCE(a.o_pass AND v_b_can, FALSE),
    format('%s ‖ 確定短少 0：can_add=%s 原因=%s', a.o_detail, v_b_can, v_b_reason));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (24, '確定短少', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t24$;


-- ============================================================================
-- 測 11：店長帳號 → 預覽與寫入都擋，一個字都沒寫
-- ============================================================================
DO $t11$
DECLARE
  v_owner TEXT := current_setting('request.jwt.claims', true);
  v_mgr   UUID := (SELECT manager FROM _t_env);
  v_err_w TEXT;
  v_err_p TEXT;
  v_poi   NUMERIC;
  v_in    BIGINT;
BEGIN
  PERFORM set_config('request.jwt.claims',
    format('{"tenant_id":"%s","app_metadata":{"role":"store_manager"},"sub":"%s"}',
           (SELECT tenant FROM _t_env), v_mgr), true);
  PERFORM set_config('request.jwt.claim', current_setting('request.jwt.claims'), true);

  BEGIN
    PERFORM public.rpc_add_po_store_demands(
      pg_temp._t_id('c11.po'), pg_temp._t_id('c11.poi'), pg_temp._t_id('c11.camp'),
      jsonb_build_array(pg_temp._t_add('storeB', 1)), v_mgr, gen_random_uuid());
    v_err_w := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN
    v_err_w := SQLERRM;
  END;

  BEGIN
    PERFORM * FROM public.rpc_preview_po_store_additions(pg_temp._t_id('c11.po'));
    v_err_p := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN
    v_err_p := SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims', v_owner, true);
  PERFORM set_config('request.jwt.claim', v_owner, true);

  SELECT qty_ordered INTO v_poi FROM purchase_order_items WHERE id = pg_temp._t_id('c11.poi');
  v_in := pg_temp._t_internal_items('c11');

  INSERT INTO _t_result VALUES (
    11, '店長帳號 → 寫入擋、預覽也擋；採購單沒動、沒有店家單',
    COALESCE(v_err_w = 'permission denied' AND v_err_p = 'permission denied' AND v_poi = 30 AND v_in = 0, FALSE),
    format('寫入=%s 預覽=%s 採購=%s 店家單品項=%s', v_err_w, v_err_p, v_poi, v_in));
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', v_owner, true);
  PERFORM set_config('request.jwt.claim', v_owner, true);
  INSERT INTO _t_result VALUES (11, '店長帳號', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t11$;


-- ============================================================================
-- 測 12：同一 request_key 重送
--   內容一樣（順序不同、同一家店拆兩筆也算一樣：比的是「每家店加總後」的集合）→ 不重複加、回上次結果
--   團或各店數量不一樣 → 擋下（白話），一個字都沒寫 —— 第一次可能其實已經寫進去，不能假裝改過的內容生效
--   拿去別的品項用 → 擋
-- ============================================================================
DO $t12$
DECLARE
  v_key     UUID := gen_random_uuid();
  v_key2    UUID := gen_random_uuid();
  v_first   JSONB;
  v_again   JSONB;
  v_split   JSONB;
  v_diff    TEXT;
  v_fewer   TEXT;
  v_camp2   TEXT;
  v_other   TEXT;
  v_c_first JSONB;
  v_poi     NUMERIC;
  v_pri     NUMERIC;
  v_add     INTEGER;
  v_in      BIGINT;
  v_poi_b   NUMERIC;
  v_poi_c   NUMERIC;
  v_add2    INTEGER;
  v_in_c    BIGINT;
BEGIN
  v_first := pg_temp._t_call('rpc_add_po_store_demands', 'c12',
               jsonb_build_array(pg_temp._t_add('storeB', 1), pg_temp._t_add('storeA', 2)), v_key);
  -- 同一把 key、同樣內容但順序不同 → 回上次結果
  v_again := pg_temp._t_call('rpc_add_po_store_demands', 'c12',
               jsonb_build_array(pg_temp._t_add('storeA', 2), pg_temp._t_add('storeB', 1)), v_key);
  -- 同一把 key、店B 拆成兩筆 0.5 + 0.5（加總後一樣）→ 回上次結果
  v_split := pg_temp._t_call('rpc_add_po_store_demands', 'c12',
               jsonb_build_array(pg_temp._t_add('storeB', 0.5), pg_temp._t_add('storeA', 2),
                                 pg_temp._t_add('storeB', 0.5)), v_key);
  -- 同一把 key、店B 改成 5（例：網路斷了、畫面上又改了數字才重按）→ 擋
  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', 'c12',
              jsonb_build_array(pg_temp._t_add('storeB', 5), pg_temp._t_add('storeA', 2)), v_key);
    v_diff := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN
    v_diff := SQLERRM;
  END;
  -- 同一把 key、少了一家店 → 擋
  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', 'c12',
              jsonb_build_array(pg_temp._t_add('storeB', 1)), v_key);
    v_fewer := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN
    v_fewer := SQLERRM;
  END;
  -- 同一把 key 拿去別張採購單的品項 → 擋
  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', 'c12b',
              jsonb_build_array(pg_temp._t_add('storeB', 1), pg_temp._t_add('storeA', 2)), v_key);
    v_other := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN
    v_other := SQLERRM;
  END;
  -- 另一把 key：同一個品項、第一次選第 1 團，重送時改選第 2 團 → 擋
  v_c_first := pg_temp._t_call('rpc_add_po_store_demands', 'c12c',
                 jsonb_build_array(pg_temp._t_add('storeB', 1)), v_key2, '.camp');
  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', 'c12c',
              jsonb_build_array(pg_temp._t_add('storeB', 1)), v_key2, '.camp2');
    v_camp2 := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN
    v_camp2 := SQLERRM;
  END;

  SELECT qty_ordered INTO v_poi FROM purchase_order_items WHERE id = pg_temp._t_id('c12.poi');
  SELECT qty_requested INTO v_pri FROM purchase_request_items WHERE id = pg_temp._t_id('c12.pri');
  SELECT COUNT(*) INTO v_add FROM purchase_request_store_additions WHERE request_key = v_key;
  v_in := pg_temp._t_internal_items('c12');
  SELECT qty_ordered INTO v_poi_b FROM purchase_order_items WHERE id = pg_temp._t_id('c12b.poi');
  SELECT qty_ordered INTO v_poi_c FROM purchase_order_items WHERE id = pg_temp._t_id('c12c.poi');
  SELECT COUNT(*) INTO v_add2 FROM purchase_request_store_additions WHERE request_key = v_key2;
  v_in_c := pg_temp._t_internal_items('c12c', '.camp') + pg_temp._t_internal_items('c12c', '.camp2');

  INSERT INTO _t_result VALUES (
    12, '同一 request_key 重送：內容一樣（含順序不同、同店拆兩筆）→ 回上次結果；團或各店數量不同 → 擋（白話）、沒寫；拿去別的品項 → 擋',
    COALESCE(v_poi = 33 AND v_pri = 33 AND v_add = 2 AND v_in = 2 AND v_poi_b = 30
             AND (v_first ->> 'idempotent')::BOOLEAN = FALSE
             AND (v_first ->> 'po_added_qty')::NUMERIC = 3
             AND (v_again ->> 'idempotent')::BOOLEAN = TRUE
             AND (v_again ->> 'store_added_qty')::NUMERIC = 3
             AND (v_again ->> 'po_added_qty')::NUMERIC = 3
             AND (v_again ->> 'po_qty_after')::NUMERIC = 33
             AND (v_split ->> 'idempotent')::BOOLEAN = TRUE
             AND v_diff LIKE '%之前已經送出過不同的團或數量%這次什麼都沒有改%'
             AND v_fewer LIKE '%之前已經送出過不同的團或數量%'
             AND v_other LIKE '%request key already used%'
             AND (v_c_first ->> 'idempotent')::BOOLEAN = FALSE
             AND v_camp2 LIKE '%之前已經送出過不同的團或數量%'
             AND v_poi_c = 61 AND v_add2 = 1 AND v_in_c = 1, FALSE),
    format('採購 %s 請購 %s 紀錄 %s 列 店家單品項 %s 別張採購 %s｜換順序重送=%s｜拆兩筆重送=%s｜改數量=%s｜少一家=%s｜別品項=%s｜'
           '兩團那張：第一次加 %s 件、改選第 2 團=%s、採購 %s 紀錄 %s 列 店家單品項 %s',
           v_poi, v_pri, v_add, v_in, v_poi_b, v_again, v_split, v_diff, v_fewer, v_other,
           v_c_first ->> 'po_added_qty', v_camp2, v_poi_c, v_add2, v_in_c));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (12, '同一 request_key 重送', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t12$;


-- ============================================================================
-- 測 15：同一請購品項有兩團（各 30）→ 只改指定那團的明細
-- ============================================================================
DO $t15$
DECLARE
  v_res JSONB;
  v_p1 NUMERIC; v_p2 NUMERIC; v_pri NUMERIC; v_poi NUMERIC; v_b NUMERIC; v_d1 NUMERIC; v_d2 NUMERIC;
BEGIN
  v_res := pg_temp._t_call('rpc_add_po_store_demands', 'c15',
             jsonb_build_array(pg_temp._t_add('storeB', 1)), gen_random_uuid(), '.camp');

  SELECT qty_requested INTO v_p1 FROM purchase_request_item_campaigns
   WHERE pr_item_id = pg_temp._t_id('c15.pri') AND campaign_id = pg_temp._t_id('c15.camp');
  SELECT qty_requested INTO v_p2 FROM purchase_request_item_campaigns
   WHERE pr_item_id = pg_temp._t_id('c15.pri') AND campaign_id = pg_temp._t_id('c15.camp2');
  SELECT qty_requested INTO v_pri FROM purchase_request_items WHERE id = pg_temp._t_id('c15.pri');
  SELECT qty_ordered INTO v_poi FROM purchase_order_items WHERE id = pg_temp._t_id('c15.poi');
  v_b := pg_temp._t_dispatch('c15', 'storeB');
  v_d1 := pg_temp._t_delta('c15', '.camp');
  v_d2 := pg_temp._t_delta('c15', '.camp2');

  INSERT INTO _t_result VALUES (
    15, '同一請購品項有兩團（各 30）→ 指定團明細 31、另一團維持 30、品項 61、採購單 61、派貨店B 21（兩團加總）',
    COALESCE(v_p1 = 31 AND v_p2 = 30 AND v_pri = 61 AND v_poi = 61 AND v_b = 21 AND v_d1 = 0 AND v_d2 = 0, FALSE),
    format('指定團 %s 另一團 %s 品項 %s 採購 %s 派貨B %s 差額 %s/%s 回傳 %s', v_p1, v_p2, v_pri, v_poi, v_b, v_d1, v_d2, v_res));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (15, '兩團只改指定團', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t15$;


-- ============================================================================
-- 測 17：這個團原本就有還沒叫貨的量（需求 31／採購 30），店B +1 → X = 2
--   跟 #995 同一套算法：差額全部補進來（不然那 1 件之後還是會被「結單日補單」另開一張）
-- ============================================================================
DO $t17$
DECLARE
  v_res JSONB; v_poi NUMERIC; v_pri NUMERIC; v_b NUMERIC; v_c NUMERIC; v_delta NUMERIC;
  v_add INTEGER; v_add_ok BOOLEAN;
BEGIN
  v_res := pg_temp._t_call('rpc_add_po_store_demands', 'c17',
             jsonb_build_array(pg_temp._t_add('storeB', 1)), gen_random_uuid());
  SELECT qty_ordered INTO v_poi FROM purchase_order_items WHERE id = pg_temp._t_id('c17.poi');
  SELECT qty_requested INTO v_pri FROM purchase_request_items WHERE id = pg_temp._t_id('c17.pri');
  v_b := pg_temp._t_dispatch('c17', 'storeB');
  v_c := pg_temp._t_dispatch('c17', 'storeC');
  v_delta := pg_temp._t_delta('c17');
  SELECT COUNT(*), COALESCE(bool_and(a.qty_added = 1 AND a.pr_delta_qty = 2 AND a.pr_qty_after = 32), FALSE)
    INTO v_add, v_add_ok
    FROM purchase_request_store_additions a WHERE a.pr_item_id = pg_temp._t_id('c17.pri');

  INSERT INTO _t_result VALUES (
    17, '原本就少叫 1（需求 31／採購 30），店B +1 → 採購單 32（X=2，N=1）、補單差額 0、紀錄 pr_delta_qty=2',
    COALESCE(v_poi = 32 AND v_pri = 32 AND v_b = 11 AND v_c = 11 AND v_delta = 0
             AND v_add = 1 AND v_add_ok
             AND (v_res ->> 'po_added_qty')::NUMERIC = 2
             AND (v_res ->> 'store_added_qty')::NUMERIC = 1, FALSE),
    format('採購 %s 請購 %s 派貨 B %s C %s 差額 %s 紀錄 %s(對=%s) 回傳 %s', v_poi, v_pri, v_b, v_c, v_delta, v_add, v_add_ok, v_res));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (17, 'X>N', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t17$;


-- ============================================================================
-- 測 18：輸入防呆 —— 擋下而且一個字都沒寫
-- ============================================================================
DO $t18$
DECLARE
  v_e1 TEXT; v_e2 TEXT; v_e3 TEXT; v_e4 TEXT;
  v_poi NUMERIC; v_add BIGINT; v_in BIGINT;
BEGIN
  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', 'c18',
      jsonb_build_array(pg_temp._t_add('storeB', 1), pg_temp._t_add('storeX', 1)), gen_random_uuid());
    v_e1 := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN v_e1 := SQLERRM;
  END;
  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', 'c18',
      jsonb_build_array(pg_temp._t_add('storeB', 0)), gen_random_uuid());
    v_e2 := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN v_e2 := SQLERRM;
  END;
  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', 'c18', '[]'::JSONB, gen_random_uuid());
    v_e3 := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN v_e3 := SQLERRM;
  END;
  -- 店A 的店家單已在出貨中 → 整筆退回（同一包裡的店B 也不能留下任何東西）
  BEGIN
    PERFORM pg_temp._t_call('rpc_add_po_store_demands', 'c18',
      jsonb_build_array(pg_temp._t_add('storeB', 1), pg_temp._t_add('storeA', 1)), gen_random_uuid());
    v_e4 := '（沒有擋下來）';
  EXCEPTION WHEN OTHERS THEN v_e4 := SQLERRM;
  END;

  SELECT qty_ordered INTO v_poi FROM purchase_order_items WHERE id = pg_temp._t_id('c18.poi');
  SELECT COUNT(*) INTO v_add FROM purchase_request_store_additions WHERE campaign_id = pg_temp._t_id('c18.camp');
  v_in := pg_temp._t_internal_items('c18');   -- 夾具本來就有店A 那 1 筆

  INSERT INTO _t_result VALUES (
    18, '輸入防呆：停用的店、數量 0、空清單、店家單已在後段狀態 → 擋；採購單沒動、沒有新紀錄、沒有新店家單品項',
    COALESCE(v_e1 LIKE '%停用%' AND v_e2 LIKE '%大於 0%' AND v_e3 LIKE '%至少%' AND v_e4 LIKE '%後段狀態%'
             AND v_poi = 30 AND v_add = 0 AND v_in = 1, FALSE),
    format('停用店=%s｜數量0=%s｜空清單=%s｜後段狀態=%s｜採購 %s 紀錄 %s 店家單品項 %s', v_e1, v_e2, v_e3, v_e4, v_poi, v_add, v_in));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (18, '輸入防呆', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t18$;


-- ============================================================================
-- 測 13／14（對照組，刻意放最後）：用**測 1 那一份檢查**去跑拿掉一段的版本，必須紅
-- ============================================================================
DO $t13$
DECLARE r RECORD;
BEGIN
  PERFORM pg_temp._t_make_mutant('STEP3', '_zz_mut_no_step3');
  SELECT * INTO r FROM pg_temp._t_check1('m13', '_zz_mut_no_step3');
  INSERT INTO _t_result VALUES (
    13, '對照組：拿掉第 3 步（不改請購單）→ 補單差額變 1 → 測 1 的檢查必須紅',
    COALESCE(NOT r.o_pass AND r.o_delta = 1, FALSE),
    format('測 1 檢查結果=%s（應為 false）補單差額=%s（應為 1）｜%s', r.o_pass, r.o_delta, r.o_detail));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (13, '對照組：拿掉第 3 步', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t13$;

DO $t14$
DECLARE r RECORD;
BEGIN
  PERFORM pg_temp._t_make_mutant('STEP1', '_zz_mut_no_step1');
  SELECT * INTO r FROM pg_temp._t_check1('m14', '_zz_mut_no_step1');
  INSERT INTO _t_result VALUES (
    14, '對照組：拿掉第 1 步（不加店家單）→ 派貨店B 還是 10 → 測 1 的檢查必須紅',
    COALESCE(NOT r.o_pass AND r.o_store_b = 10, FALSE),
    format('測 1 檢查結果=%s（應為 false）派貨店B=%s（應為 10）｜%s', r.o_pass, r.o_store_b, r.o_detail));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (14, '對照組：拿掉第 1 步', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t14$;


TABLE _t_result ORDER BY seq;

DO $$
DECLARE
  v_bad TEXT;
  v_n   INTEGER;
BEGIN
  SELECT string_agg(seq || ' ' || item || ' :: ' || detail, E'\n' ORDER BY seq)
    INTO v_bad
    FROM _t_result
   WHERE NOT pass OR pass IS NULL;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'po_store_additions_verification failed:%', E'\n' || v_bad;
  END IF;

  -- 結果必須剛好 25 條（測 0～24）；少一條就算失敗，防止某條測試被跳過還顯示綠
  SELECT COUNT(DISTINCT seq) INTO v_n FROM _t_result;
  IF v_n <> 25 OR (SELECT COUNT(*) FROM _t_result) <> 25 THEN
    RAISE EXCEPTION 'po_store_additions_verification：應該有 25 條結果（測 0～24），實際 % 條', v_n;
  END IF;

  RAISE NOTICE 'po_store_additions_verification: 25/25 PASS';
END $$;

ROLLBACK;

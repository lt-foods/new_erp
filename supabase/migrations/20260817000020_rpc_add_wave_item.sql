-- ============================================================
-- rpc_add_wave_item — 在既有撿貨單裡「補一列」給原本沒叫貨的分店
--
-- 由來（老闆 2026-08-17）：
--   「修正數量，要一次把所有分店都秀出來，因為我入庫的會是原本沒叫貨的店家」
--
--   這套系統是團購邏輯：先收單 → 再進貨 → 照單分貨，
--   所以「沒人叫貨的店」在撿貨矩陣裡連一列都不會有（需求鏈見
--   v_picking_demand_by_po）。老闆要的是 ERP 邏輯：貨進來了，想給誰就給誰。
--
-- ⭐ 資料層本來就支援，這支 RPC 只是把缺的入口補上：
--   picking_wave_items.campaign_id 可為 NULL（20260423120002:56），
--   整張表沒有任何欄位指向客人訂單 →「一定要先有人叫貨」是介面的限制，不是資料的。
--   （同一個模式：採購單本來就不依賴請購單。）
--
-- ⛔ 下游一行都不用改，逐項查證過：
--   generate_transfer_from_wave（最新 20260717000000:126）
--       只認 picked_qty > 0，不看 campaign_id → 照樣出貨
--   rpc_mark_orders_shipping_for_wave（最新 20260614000050）
--       用 pwi.campaign_id = co.campaign_id 比對，SQL 裡 NULL 比不上任何值
--       → 新增列被安全跳過，不會誤推別人的訂單
--   月結 rpc_generate_hq_to_store_settlement（最新 20260807000000）
--       只看 transfers 的 hq_to_store + received/closed，不管那張單怎麼來的
--
-- ⚠ 已知但不在本案範圍（既有行為，非本檔造成）：
--   新增的 SKU 若缺成本價／分店價，派貨時會被 _missing_dispatch_prices
--   （20260705000000:42）**整張擋下**。那是價格守衛本來的行為。
--
-- 基底 house style：逐條對齊 rpc_update_picked_qty（最新版
--   20260502070000_update_picked_qty_recompute_aggregates.sql）——
--   同樣的 FOR UPDATE、同樣擋 shipped/cancelled、同樣寫 picking_wave_audit_log、
--   同樣重算表頭 aggregates、同樣 draft → picking。
--   ⭐ 但**不比照它沒有 GRANT/REVOKE 這件事**：那三個版本都沒寫權限語句，
--     依 PostgreSQL 預設 EXECUTE 是開給 PUBLIC 的。本檔明確寫死
--     （寫法對齊 20260816000050 的 rpc_add_stock_by_product）。
--
-- rollback：DROP FUNCTION public.rpc_add_wave_item(BIGINT,BIGINT,BIGINT,NUMERIC,UUID,TEXT);
--           本檔只新增函式，沒有改任何既有函式／表／view。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_add_wave_item(
  p_wave_id  BIGINT,
  p_sku_id   BIGINT,
  p_store_id BIGINT,
  p_qty      NUMERIC,
  p_operator UUID,
  p_note     TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_role    TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores   JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_tenant      UUID;
  v_status      TEXT;
  v_wave_code   TEXT;
  v_source_po   BIGINT;
  v_store_name  TEXT;
  v_sku_label   TEXT;
  v_new_item_id BIGINT;
  v_avail       RECORD;
BEGIN
  -- 1. wave 存在，FOR UPDATE 鎖住（對齊 rpc_update_picked_qty）
  --    ⭐ 這道鎖同時讓下面的「已經有這一列」檢查對同一張 wave 是安全的：
  --      並行的第二筆會卡在這裡，等第一筆 commit 之後才看得到它插進去的列。
  SELECT pw.tenant_id, pw.status, pw.wave_code, pw.source_po_id
    INTO v_tenant, v_status, v_wave_code, v_source_po
    FROM picking_waves pw
   WHERE pw.id = p_wave_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到撿貨單 #%（可能已被刪除）', p_wave_id;
  END IF;

  -- 2. 擋 shipped / cancelled（逐字對齊 rpc_update_picked_qty 的擋法）
  IF v_status IN ('shipped', 'cancelled') THEN
    RAISE EXCEPTION '撿貨單 % 目前是「%」狀態，不能再新增分店品項',
      v_wave_code,
      CASE v_status WHEN 'shipped' THEN '已派貨' ELSE '已取消' END;
  END IF;

  -- 3. 數量守衛。picking_wave_items 表上是 CHECK (qty > 0)，
  --    自己先擋才給得出「填 0 要怎麼辦」這種老闆看得懂的話，
  --    ⛔ 不要讓它去撞 CHECK 噴一句英文的 constraint 名字。
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION '新增分店的數量必須大於 0（不需要就把格子留空，不要填 0）';
  END IF;

  -- 4. 品項與分店要存在、且屬於同一個 tenant。
  --    FK 也會擋，但噴出來的是英文 constraint 名字。
  SELECT COALESCE(s.sku_code, '#' || s.id::TEXT)
         || COALESCE(' ' || NULLIF(s.product_name, ''), '')
    INTO v_sku_label
    FROM skus s
   WHERE s.id = p_sku_id AND s.tenant_id = v_tenant;
  IF v_sku_label IS NULL THEN
    RAISE EXCEPTION '找不到品項 #%（或不屬於這個 tenant）', p_sku_id;
  END IF;

  SELECT st.name INTO v_store_name
    FROM stores st
   WHERE st.id = p_store_id AND st.tenant_id = v_tenant;
  IF v_store_name IS NULL THEN
    RAISE EXCEPTION '找不到分店 #%（或不屬於這個 tenant）', p_store_id;
  END IF;

  -- 5. 店家守衛：分店角色只能動自己店。
  --    ⭐ 逐字對齊 20260816000050 的 rpc_add_stock_by_product（Alex 2026-08-16 的寫法），
  --      ⛔ 不是另創一套判斷。用 app_metadata.stores（**店名字串陣列**），
  --      不可以用 store_id —— 線上 33 個分店帳號沒有任何一個有 store_id
  --      （見 20260808000020）。
  --    為什麼這支需要而 rpc_update_picked_qty 沒有：這支是「憑空生出一列給某家店」，
  --    是這個彈窗以前不存在的能力；HQ 層級（owner/admin/hq_manager/hq_accountant/''）、
  --    service_role、以及沒有 stores 的 legacy 分店帳號都不受影響。
  IF v_jwt_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉') THEN
    IF NOT (v_my_stores ? v_store_name) THEN
      RAISE EXCEPTION 'wrong_store: 「%」不是你的店，分店帳號只能替自己店新增撿貨品項', v_store_name;
    END IF;
  END IF;

  -- 6. UNIQUE (wave_id, sku_id, store_id) 衝突 → 報清楚的話，⛔ 不 UPSERT。
  --    那一格已經有列 = 那是真實存在的叫貨需求（可能只是數量 0 或 NULL），
  --    靜默覆蓋會蓋掉真資料。引導使用者「直接改那一格」。
  IF EXISTS (
    SELECT 1 FROM picking_wave_items
     WHERE wave_id = p_wave_id AND sku_id = p_sku_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION '撿貨單 % 裡「%」已經有「%」這一列了，請直接修改那一格的數量，不要新增一列',
      v_wave_code, v_store_name, v_sku_label;
  END IF;

  -- 7. 可分配量守衛（CEO 2026-08-17 拍板要做在 RPC 內）。
  --    判準是「漏的時候往哪邊倒」：不做的話要等按下「派貨出倉」才整張爆掉、
  --    而且整張 rollback；做了最多是當下擋住、而且訊息講得清楚。
  --
  --    口徑逐條對齊 rpc_create_wave_from_po 步驟 4（最新版 20260816000050:325-372）：
  --      可分配量 = GR 實收（只認 confirmed 的驗收單）
  --               − 已派（該 PO 的所有非 cancelled wave items ＋ 補貨直派 transfer）
  --    ⚠ 新列自己的 qty 也會計入下一次的「已派」，所以連按兩次不會各自過關。
  --
  --    ⛔ 只在 wave 有 source_po_id 時檢查：補貨來源的 wave
  --      （rpc_create_wave_from_restock，20260715000020:609）只填
  --      source_restock_request_id、source_po_id 是 NULL，根本沒有 PO 這個池子可以量。
  --      那種情況底線仍在：派貨時 rpc_outbound(p_allow_negative => FALSE) 會擋，
  --      不會產生負庫存。
  --
  --    ⚠⚠ 已知的取捨（施工時提報，待 Alex／老闆確認）：
  --      這道守衛量的是「這張 PO 進了多少貨」，不是「總倉現在有多少貨」。
  --      老闆用彈窗裡的「＋ 補庫存」把總倉庫存補上去，**不會**讓這個數字變大
  --      （補庫存寫的是 stock_movements.manual_adjust，不是 goods_receipt_items）。
  --      所以「這張 PO 的貨已經分光了、但總倉還有別的貨」時，這裡會擋住。
  --      正解是走補貨申請（見 docs/PRD-WMS §13 的 B 類）。
  IF v_source_po IS NOT NULL THEN
    -- ⚠⚠ 這一段**必須**在下面的聚合之前單獨做，不能靠「算出來是 NULL」去偵測。
    --   下面那個 SELECT 沒有 GROUP BY ＝ 對零列做聚合，Postgres 照樣回**一列**，
    --   而 gr_qty 已經被 COALESCE 成 0 → 「這張 PO 裡根本沒有這樣商品」與
    --   「有這樣商品但剛好剩 0」會算出一模一樣的結果。
    --   兩者都該擋，但**要講不同的話**：前者是選錯商品／選錯撿貨單，
    --   叫他去看「進貨 0、已派 0」只會讓人以為是貨還沒到。
    --   （2026-08-17 用 pglite 實跑才發現，原本寫的 `IS NULL` 判斷是永遠不會成立的死碼。）
    IF NOT EXISTS (
      SELECT 1 FROM purchase_order_items
       WHERE po_id = v_source_po AND sku_id = p_sku_id
    ) THEN
      RAISE EXCEPTION
        '撿貨單 % 對應的採購單裡沒有「%」這樣商品，無法判斷可分配量。'
        '要額外補庫存給分店請走「補貨申請」',
        v_wave_code, v_sku_label;
    END IF;

    WITH po_sku_state AS (
      SELECT
        COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status = 'confirmed'), 0) AS gr_qty,
        COALESCE((
          SELECT SUM(pwi.qty)
            FROM picking_wave_items pwi
            JOIN picking_waves pw ON pw.id = pwi.wave_id
           WHERE pw.source_po_id = v_source_po
             AND pwi.sku_id = p_sku_id
             AND pw.status <> 'cancelled'
        ), 0)
        + COALESCE((
          SELECT SUM(ti.qty_requested)
            FROM restock_requests rr
            JOIN transfers t ON t.id = rr.linked_transfer_id
            JOIN transfer_items ti ON ti.transfer_id = t.id
            JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
            JOIN purchase_order_items poi2 ON poi2.id = pri.po_item_id AND poi2.sku_id = ti.sku_id
           WHERE poi2.po_id = v_source_po
             AND poi2.sku_id = p_sku_id
             AND t.transfer_type = 'hq_to_store'
             AND t.status <> 'cancelled'
        ), 0) AS already_wave
      FROM purchase_order_items poi
      LEFT JOIN goods_receipt_items gri ON gri.po_item_id = poi.id
      LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id
      WHERE poi.po_id = v_source_po
        AND poi.sku_id = p_sku_id
    )
    SELECT ps.gr_qty, ps.already_wave, (ps.gr_qty - ps.already_wave) AS available
      INTO v_avail
      FROM po_sku_state ps;

    IF p_qty > v_avail.available THEN
      RAISE EXCEPTION
        '「%」只剩可分配 % 件（這張採購單進貨 %、已派 %），這次要給「%」% 件、超過了。'
        '要額外補庫存給分店請走「補貨申請」',
        v_sku_label, v_avail.available, v_avail.gr_qty, v_avail.already_wave,
        v_store_name, p_qty;
    END IF;
  END IF;

  -- 8. 寫入。
  --    campaign_id 明確寫 NULL：這批貨本來就沒有團，
  --    ⛔ 不自作聰明去猜一個團塞進去（猜錯會讓 rpc_mark_orders_shipping_for_wave
  --      去推別人的客人訂單）。
  --    qty 與 picked_qty **都**設成 p_qty（老闆 2026-08-17 拍板）：
  --    picked_qty 留 NULL 的話 generate_transfer_from_wave 會自動補成 qty
  --    （20260717000000:126 那段），結果一樣但看起來像「沒人動過」，容易誤解。
  BEGIN
    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, picked_qty, campaign_id,
      note, created_by, updated_by
    ) VALUES (
      v_tenant, p_wave_id, p_sku_id, p_store_id, p_qty, p_qty, NULL,
      p_note, p_operator, p_operator
    )
    RETURNING id INTO v_new_item_id;
  EXCEPTION WHEN unique_violation THEN
    -- 第 6 點已經先查過一次；這裡是萬一有別的路徑同時插進來的保險，
    -- 目的只有一個：⛔ 絕對不讓原始的 DB 英文錯誤直接噴到老闆臉上。
    RAISE EXCEPTION '撿貨單 % 裡「%」已經有「%」這一列了，請重新開啟視窗後直接修改那一格的數量',
      v_wave_code, v_store_name, v_sku_label;
  END;

  -- 9. 稽核（對齊 rpc_update_picked_qty；action 用建表時就允許的 'item_added'，
  --    見 20260423120002:74-77 的 CHECK 清單）。
  --    before_value 是 NULL ＝ 這一格本來不存在，與 picked_qty_changed 的語意分得開。
  INSERT INTO picking_wave_audit_log (
    tenant_id, wave_id, wave_item_id, action, before_value, after_value, note, created_by
  ) VALUES (
    v_tenant, p_wave_id, v_new_item_id, 'item_added',
    NULL,
    jsonb_build_object(
      'sku_id', p_sku_id, 'store_id', p_store_id,
      'qty', p_qty, 'picked_qty', p_qty, 'campaign_id', NULL
    ),
    p_note, p_operator
  );

  -- 10. 重算表頭 cached aggregates。⛔ 少了這一段，列表上的件數／店數就跟彈窗裡對不上
  --     （算式逐字照抄 rpc_update_picked_qty，包含 total_qty 以 picked_qty 為準）。
  UPDATE picking_waves pw
     SET item_count  = agg.item_count,
         store_count = agg.store_count,
         total_qty   = agg.total_qty,
         updated_by  = p_operator
    FROM (
      SELECT COUNT(*)                                       AS item_count,
             COUNT(DISTINCT store_id)                       AS store_count,
             COALESCE(SUM(COALESCE(picked_qty, qty)), 0)    AS total_qty
        FROM picking_wave_items
       WHERE wave_id = p_wave_id
    ) agg
   WHERE pw.id = p_wave_id;

  -- 11. draft → picking（對齊 rpc_update_picked_qty：動過就不是草稿了）
  IF v_status = 'draft' THEN
    UPDATE picking_waves SET status = 'picking', updated_by = p_operator WHERE id = p_wave_id;
  END IF;

  RETURN v_new_item_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_add_wave_item(BIGINT, BIGINT, BIGINT, NUMERIC, UUID, TEXT) IS
  '在既有撿貨單裡替「原本沒叫貨的分店」補一列（campaign_id 一律 NULL、qty = picked_qty = p_qty）。'
  '總倉收件匣「✎ 修正數量」彈窗專用。守衛：狀態、數量 > 0、品項/分店存在、分店角色只能動自己店、'
  '同一格不重複新增（報錯不 UPSERT）、可分配量（僅 source_po_id 不為 NULL 時）。';

-- ⭐ 明確寫權限，⛔ 不比照 rpc_update_picked_qty 三個版本都沒寫的壞習慣
--   （沒寫 = 依 PostgreSQL 預設 EXECUTE 開給 PUBLIC）。寫法對齊 20260816000050。
REVOKE ALL ON FUNCTION public.rpc_add_wave_item(BIGINT, BIGINT, BIGINT, NUMERIC, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_add_wave_item(BIGINT, BIGINT, BIGINT, NUMERIC, UUID, TEXT)
  TO authenticated;

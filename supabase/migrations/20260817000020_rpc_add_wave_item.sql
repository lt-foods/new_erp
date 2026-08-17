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
-- ⛔⛔ 這一支**刻意沒有「採購單可分配量」守衛**（老闆 2026-08-17 親自裁示）。
--   施工中途曾加過一版（GR 實收 − 已派，口徑抄 rpc_create_wave_from_po 步驟 4），
--   老闆看到就打回來了。原話：
--     「不能列出所有店家然後在那店家直接增加數量嗎？一定要走補貨申請嗎！！！！」
--     「我就不想要還要再按什麼派貨…就一般的 ERP：進貨單、銷貨單、月結單。」
--   那道守衛是**團購邏輯**的產物（「這張採購單進的貨只能給有訂那張單的人」），
--   而這個案子的主線正是要離開團購邏輯：**先進貨 → 有貨就能賣，想給誰就給誰。**
--   它同時也是「補庫存等於白按」的根因 —— 補庫存寫 stock_movements.manual_adjust，
--   不會讓 GR 實收變大，所以補了也還是被擋。拿掉它，三件事才自洽。
--
--   ⭐ 真正的限制留在**物理上有沒有貨**那一關，而且本來就存在：
--     派貨時 generate_transfer_from_wave → rpc_outbound(p_allow_negative => FALSE)
--     檢查 stock_balances.on_hand − reserved（20260705000000:24,37），
--     不足就 RAISE，**不會產生負庫存**。前端另外在矩陣上即時顯示同一個數字，
--     讓人在填的當下就看得到超了，而不是按下派貨才整張爆。
--
--   ⚠⚠ 刻意接受的後果（**這是取捨，不是 bug**，Alex 請看這裡）：
--     總倉是**一個共同的池子**、先來後到，所以拿掉 PO 配額之後
--     **同一張採購單可能派出比它進的還多**（吃到別張單進的貨）。
--     帳是對的：庫存不會變負、月結照 transfers 算，一毛都不會少或多。
--     但**採購單維度的報表**（例如「這張 PO 進 100 卻派了 120」）看起來會怪。
--     老闆明確要這個行為。⛔ 不要「順手修正」把配額加回來。
--
--   ⓘ 連帶：本支**沒有任何 advisory lock**。曾經為了保護上述配額的
--     read-modify-write 加過一把（key 抄 rpc_create_wave_from_po 的
--     'wave:po:' || po_id），配額拿掉後那把鎖已經沒有要保護的東西 → 一併移除。
--     現有的併發保護只靠第 1 點那行 FOR UPDATE，理由與盤點證據寫在該處。
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
  v_store_name  TEXT;
  v_sku_label   TEXT;
  v_new_item_id BIGINT;
BEGIN
  -- 1. wave 存在，FOR UPDATE 鎖住（對齊 rpc_update_picked_qty）
  --
  --    ⭐⭐ 這一支的併發保護**全部**靠這一行，沒有別的鎖（刻意的，見檔頭）。
  --    盤過所有會動到同一張 wave 的寫入者，每一支都在同一列上 FOR UPDATE，
  --    所以對同一張 wave 的操作是互斥的：
  --      rpc_update_picked_qty        `FOR UPDATE OF pwi, pw`（20260502070000:22）
  --      generate_transfer_from_wave  advisory(p_wave_id) ＋ FOR UPDATE（20260717000000:24,27）
  --      rpc_cancel_picking_wave      FOR UPDATE（20260609000002:32）
  --      本支                          這一行
  --    建單那幾支（rpc_create_wave_from_po / _from_restock）都是**自己新建一張 wave**
  --    再往裡面塞列，那張 wave 在 commit 前別的交易看不到 → 不會跟這裡爭用。
  --    ⇒ 下面第 6 點的「已經有這一列」檢查因此是安全的：並行的第二筆會卡在這裡，
  --      等第一筆 commit 之後才跑，看得到它插進去的列。
  --    ⇒ 第 10 點重算表頭 aggregates 同理，不會兩邊互相蓋掉。
  --    （真的還是有未知路徑繞過的話，UNIQUE 約束＋第 8 點的 unique_violation
  --      例外處理是最後一道網，結果是一句看得懂的錯誤，不會寫出壞資料。）
  SELECT pw.tenant_id, pw.status, pw.wave_code
    INTO v_tenant, v_status, v_wave_code
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

  -- 7. 寫入。
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

  -- 8. 稽核（對齊 rpc_update_picked_qty；action 用建表時就允許的 'item_added'，
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

  -- 9. 重算表頭 cached aggregates。⛔ 少了這一段，列表上的件數／店數就跟彈窗裡對不上
  --    （算式逐字照抄 rpc_update_picked_qty，包含 total_qty 以 picked_qty 為準）。
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

  -- 10. draft → picking（對齊 rpc_update_picked_qty：動過就不是草稿了）
  IF v_status = 'draft' THEN
    UPDATE picking_waves SET status = 'picking', updated_by = p_operator WHERE id = p_wave_id;
  END IF;

  RETURN v_new_item_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_add_wave_item(BIGINT, BIGINT, BIGINT, NUMERIC, UUID, TEXT) IS
  '在既有撿貨單裡替「原本沒叫貨的分店」補一列（campaign_id 一律 NULL、qty = picked_qty = p_qty）。'
  '總倉收件匣「✎ 修正數量」彈窗專用。守衛：狀態、數量 > 0、品項/分店存在、分店角色只能動自己店、'
  '同一格不重複新增（報錯不 UPSERT）。'
  '⛔ 刻意沒有採購單可分配量守衛（老闆 2026-08-17 裁示：先進貨→有貨就能賣、想給誰就給誰）；'
  '真正的限制是派貨時 rpc_outbound 檢查的總倉實際庫存。詳見本檔檔頭。';

-- ⭐ 明確寫權限，⛔ 不比照 rpc_update_picked_qty 三個版本都沒寫的壞習慣
--   （沒寫 = 依 PostgreSQL 預設 EXECUTE 開給 PUBLIC）。寫法對齊 20260816000050。
REVOKE ALL ON FUNCTION public.rpc_add_wave_item(BIGINT, BIGINT, BIGINT, NUMERIC, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_add_wave_item(BIGINT, BIGINT, BIGINT, NUMERIC, UUID, TEXT)
  TO authenticated;

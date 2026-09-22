-- ============================================================
-- 2026-09-22: 門市管理加「客人看得到」勾選框 —— rpc_upsert_store 多收 p_is_visible_to_customers
--
-- 由來：stores.is_visible_to_customers（20260902020000）管客人端「選擇取貨門市」的選單列不列
--   這家店（liff-api listStores，supabase/functions/liff-api/index.ts:254），但後台一直沒有開關，
--   9/02、9/08 兩次藏店都是貼 SQL 改的。門市「類型」（store_kind，
--   20260922000000）跟它無關 —— 改成批發，客人照樣看得到。
--
-- 本檔只重建 rpc_upsert_store；⛔ 不改任何門市的資料
-- （已經是批發、客人還看得到的店，由老闆在門市管理頁自己取消勾選）。
--
-- ── rpc_upsert_store 的 p_is_visible_to_customers ──────────────
-- 預設 NULL ＝「沒帶」：
--   新增門市 沒帶 → TRUE（跟欄位預設 DEFAULT TRUE 一致）
--   更新門市 沒帶 → 維持原值（COALESCE(p_is_visible_to_customers, is_visible_to_customers)）
-- ⚠ 為什麼更新時不能「沒帶就當 TRUE」：本檔貼上之後、新畫面上線之前，線上的門市管理頁
--   （#983 版）只送 10 個參數。沒帶就當 TRUE 的話，存一次那些藏起來的店，就會把它們公開給客人。
--
-- 基底版本：20260922000000_store_kind_for_picking_columns.sql
--   （CREATE ... FUNCTION 前綴 grep supabase/migrations/ 確認：本檔之前共 4 支定義，
--     20260425120000 → 20260801000020 → 20260805000010 → 20260922000000，最後一支即現行版本。）
--   函式本體除了標「p_is_visible_to_customers」的幾行，其餘（含註解）與它逐字相同。
--
-- 前提：20260902020000（is_visible_to_customers 欄位）與 20260922000000（store_kind 欄位）都已貼過。
--   函式本體到執行時才認欄位，沒貼的話建函式不會報錯，存門市時才會找不到欄位。
--
-- ── 重貼安全（兩種情況都可以直接整份貼上執行）───────────────
--   ① 還沒貼過本檔：線上是 20260922000000 的 10 參數版。
--      先 CREATE OR REPLACE 11 參數版（與 10 參數版不同簽名 → 是新建，兩支暫時並存），
--      再 DROP 10 參數版（9 參數版也一起 DROP IF EXISTS，照理早就不在了）。
--      順序刻意是「先建新、再拆舊」：任何時刻都有一支 rpc_upsert_store 在，不會出現「函式不存在」的空窗。
--      10 參數版一定要拆：留著的話，只送 10 個具名參數的呼叫（#983 版畫面）會同時對上兩支 → function is not unique。
--      拆掉之後，那種呼叫由 11 參數版接住（第 11 個參數有預設值），照常成功、不動「客人看得到」。
--   ② 已經貼過本檔：同簽名 CREATE OR REPLACE 直接換掉函式本體，兩個 DROP 都是 IF EXISTS、什麼都不做。
--   ⚠ GRANT / COMMENT ON FUNCTION 沒寫參數列，只在「同名函式只剩一支」時成立 → 一定要排在 DROP 之後。
--
-- Rollback（回到 20260922000000）：同一批執行
--   DROP FUNCTION IF EXISTS public.rpc_upsert_store(
--     BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB, BOOLEAN, TEXT, TEXT, TEXT, BOOLEAN);
--   再貼 20260922000000_store_kind_for_picking_columns.sql 全文。
--   ⚠ 新的門市管理頁會送 p_is_visible_to_customers，rollback 之後要一起退回前端，否則存門市會找不到函式。
-- ============================================================

-- 參數簽名 10 → 11（多 p_is_visible_to_customers）。先建新簽名、再拆舊的，理由見檔頭「重貼安全」。
CREATE OR REPLACE FUNCTION public.rpc_upsert_store(
  p_id                      BIGINT,
  p_code                    TEXT,
  p_name                    TEXT,
  p_location_id             BIGINT  DEFAULT NULL,
  p_pickup_window_days      INTEGER DEFAULT 5,
  p_allowed_payment_methods JSONB   DEFAULT '["cash"]'::jsonb,
  p_is_active               BOOLEAN DEFAULT TRUE,
  p_notes                   TEXT    DEFAULT NULL,
  p_line_oa_basic_id        TEXT    DEFAULT NULL,
  p_store_kind              TEXT    DEFAULT NULL,
  p_is_visible_to_customers BOOLEAN DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
  -- 空字串一律收斂成 NULL，前端清空欄位才不會存進 '' 讓「有沒有設定」難判斷
  v_line_oa TEXT := NULLIF(btrim(COALESCE(p_line_oa_basic_id, '')), '');
  -- p_store_kind：NULL ＝ 沒帶（空字串同樣收斂成 NULL）。新增時當 branch、更新時維持原值
  v_store_kind TEXT := NULLIF(btrim(COALESCE(p_store_kind, '')), '');
  -- 呼叫端指定值優先；為 NULL 時（新增分支）才自動建門市倉別後回填
  v_location_id BIGINT := p_location_id;
  v_wh_code     TEXT;
  v_loc_type    TEXT;   -- 綁既有 WH- 倉別前，用來確認它確實是門市倉（type='store'）
BEGIN
  -- p_store_kind：有帶值才檢查
  IF v_store_kind IS NOT NULL AND v_store_kind NOT IN ('branch', 'wholesale') THEN
    RAISE EXCEPTION 'p_store_kind（門市類型）只能是 branch 或 wholesale，目前是 %', p_store_kind;
  END IF;

  IF p_id IS NULL THEN
    -- 新增門市：代碼／名稱 btrim 後不可為空，否則會建出 'WH-'、'倉' 這種垃圾資料
    IF btrim(COALESCE(p_code, '')) = '' THEN
      RAISE EXCEPTION 'p_code（門市代碼）不可為空';
    END IF;
    IF btrim(COALESCE(p_name, '')) = '' THEN
      RAISE EXCEPTION 'p_name（門市名稱）不可為空';
    END IF;

    -- 未指定倉別時，自動建立對應門市倉別並綁定
    IF v_location_id IS NULL THEN
      v_wh_code := 'WH-' || p_code;
      -- 先查同代碼倉別（連 type 取回）：已存在就綁既有（不重複建、不動它）
      SELECT id, type INTO v_location_id, v_loc_type
        FROM locations
       WHERE tenant_id = v_tenant AND code = v_wh_code;
      IF v_location_id IS NULL THEN
        -- 不存在才建；ON CONFLICT DO NOTHING 擋並發雙插（不改既有那筆）
        INSERT INTO locations (tenant_id, code, name, type, is_active, created_by, updated_by)
        VALUES (v_tenant, v_wh_code, p_name || '倉', 'store', TRUE, auth.uid(), auth.uid())
        ON CONFLICT (tenant_id, code) DO NOTHING
        RETURNING id, type INTO v_location_id, v_loc_type;
        -- 若被並發交易搶先插入，RETURNING 無值 → 再查補綁既有那筆（一樣連 type 取回）
        IF v_location_id IS NULL THEN
          SELECT id, type INTO v_location_id, v_loc_type
            FROM locations
           WHERE tenant_id = v_tenant AND code = v_wh_code;
        END IF;
      END IF;

      -- 綁定前把關：走到這裡 v_location_id 必須拿到、且必是門市倉，否則寧可報錯不亂綁。
      -- 本次自動建的必是 'store'；此把關擋兩種：
      --   (a) WH-代碼 被 central_warehouse 等非門市倉占用 → 不亂綁，交人工處理；
      --   (b) 並發極端下補查落空、v_location_id 仍為 NULL → 不讓它漏配（location_id 留空）。
      -- is_active 不納入判斷：倉別啟用狀態由倉別自身管理，停用的 store 倉照樣綁
      --   （身份對應＝門市↔WH-代碼，與倉是否啟用是兩回事；不綁反而會撞 UNIQUE 或造成漏配）。
      IF v_location_id IS NULL THEN
        RAISE EXCEPTION 'WH 代碼 % 倉別建立/取得失敗（並發競爭），請重試', v_wh_code;
      END IF;
      IF v_loc_type <> 'store' THEN
        RAISE EXCEPTION 'WH 代碼 % 已被非門市倉（type=%）占用，需人工確認後處理', v_wh_code, v_loc_type;
      END IF;
    END IF;

    -- p_is_visible_to_customers：沒帶（NULL）→ TRUE，跟欄位預設一致
    INSERT INTO stores (tenant_id, code, name, location_id,
                        pickup_window_days, allowed_payment_methods,
                        is_active, notes, line_oa_basic_id, store_kind, is_visible_to_customers, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, v_location_id,
            COALESCE(p_pickup_window_days,5), COALESCE(p_allowed_payment_methods,'["cash"]'::jsonb),
            COALESCE(p_is_active,TRUE), p_notes, v_line_oa, COALESCE(v_store_kind, 'branch'), COALESCE(p_is_visible_to_customers, TRUE), auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    -- 更新門市：維持原樣（不碰 location_id 自動建立邏輯）
    UPDATE stores SET
      code = COALESCE(p_code, code),
      name = COALESCE(p_name, name),
      location_id = p_location_id,
      pickup_window_days = COALESCE(p_pickup_window_days, pickup_window_days),
      allowed_payment_methods = COALESCE(p_allowed_payment_methods, allowed_payment_methods),
      is_active = COALESCE(p_is_active, is_active),
      notes = p_notes,
      line_oa_basic_id = v_line_oa,
      -- p_store_kind：沒帶就維持原值（舊門市管理頁只送 9 個參數，⛔ 不可以把批發打回 branch）
      store_kind = COALESCE(v_store_kind, store_kind),
      -- p_is_visible_to_customers：沒帶就維持原值（#983 版門市管理頁只送 10 個參數，⛔ 不可以把藏起來的店打回看得到）
      is_visible_to_customers = COALESCE(p_is_visible_to_customers, is_visible_to_customers),
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'store % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

-- 拆掉舊的 10 參數簽名（線上還是 20260922000000 那一版時才有東西可拆，否則 IF EXISTS 什麼都不做）。
-- 9 參數簽名（20260805000010）照理 #983 已經拆掉，這裡再保險一次。
-- ⚠ 一定要排在 CREATE 之後（任何時刻都有函式可叫）、GRANT／COMMENT 之前（它們沒寫參數列，
--   同名函式只剩一支才成立）。留著不拆的話，只送 10 個具名參數的呼叫會同時對上兩支 → function is not unique。
DROP FUNCTION IF EXISTS public.rpc_upsert_store(
  BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB, BOOLEAN, TEXT, TEXT, TEXT
);
DROP FUNCTION IF EXISTS public.rpc_upsert_store(
  BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB, BOOLEAN, TEXT, TEXT
);

GRANT EXECUTE ON FUNCTION public.rpc_upsert_store TO authenticated;

COMMENT ON FUNCTION public.rpc_upsert_store IS
  '門市 upsert。2026-08-01 加 p_line_oa_basic_id（會員端現貨專區「LINE 詢問」'
  '要把訊息帶到會員所在店的 LINE@；空字串收斂成 NULL）。'
  '2026-08-05 新增門市未指定倉別時，自動建 WH-<代碼>/<門市名>倉/store 倉別並綁定'
  '（同代碼已存在則綁既有、不重複建；全在單一交易內確保原子性）。'
  '2026-09-22 新增 p_store_kind：branch=包子媽分店、wholesale=批發；'
  '沒帶（NULL 或空字串）時，新增門市當 branch、更新門市維持原值。'
  '2026-09-22 新增 p_is_visible_to_customers：客人端取貨門市選單列不列這家店；'
  '沒帶（NULL）時，新增門市當 TRUE（客人看得到）、更新門市維持原值。';

-- 叫 PostgREST 重新認一次函式（同 20260922000000 檔尾）：
-- 免得「SQL 貼了、新畫面存門市還是說找不到 p_is_visible_to_customers」。
-- 整份一次貼上時，這個通知在整批成功送出後才發出去。
NOTIFY pgrst, 'reload schema';

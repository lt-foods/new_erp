-- ============================================================
-- 2026-09-22: 門市新增類型，供撿貨矩陣判斷欄位顯示
--
-- branch    = 包子媽分店：啟用中就算沒量也顯示欄位
-- wholesale = 批發：撿貨草稿要本草稿有量才顯示；派貨工作台（預設）要還有未派需求或已填擬分量才顯示；
--             總倉收件匣「修正數量」要本單有列、這次填了新數量、或勾「顯示批發店」才顯示
--
-- 本檔只加 stores 欄位與重建 rpc_upsert_store；不改既有門市的任何資料
-- （既有門市一律帶欄位預設值 branch，要改成批發到門市管理頁改）。
--
-- ── rpc_upsert_store 的 p_store_kind ──────────────────────────
-- 預設 NULL ＝「沒帶」：
--   新增門市 沒帶 → branch
--   更新門市 沒帶 → 維持原值（COALESCE(v_store_kind, store_kind)）
--   空字串或全空白 → 當成沒帶（同本函式 p_line_oa_basic_id 的空字串收斂）
--   有帶值才檢查只能是 branch / wholesale，其他一律 RAISE
-- ⚠ 為什麼更新時不能「沒帶就當 branch」：上線前就開著、沒重新整理的舊門市管理頁
--   只會送 9 個參數，存一次就會把批發店打回包子媽分店（#983 審查 P2-1）。
--
-- 基底版本：20260805000010_rpc_upsert_store_auto_location.sql
--   （CREATE ... FUNCTION 前綴 grep supabase/migrations/ 確認：本檔之前共 3 支定義，
--     20260425120000 → 20260801000020 → 20260805000010，最後一支即現行版本。）
--   自動建倉別、並發保護、空字串收斂、更新分支的其餘欄位 —— 一字未改，
--   只多了 p_store_kind 參數、它的檢查，以及新增／更新時寫入 store_kind。
--
-- ── 重貼安全（兩種情況都可以直接整份貼上執行）───────────────
--   ① 還沒貼過本檔：線上是 20260805000010 的 9 參數版。
--      先 CREATE OR REPLACE 10 參數版（與 9 參數版不同簽名 → 是新建，兩支暫時並存），
--      再 DROP 9 參數版。順序刻意是「先建新、再拆舊」：任何時刻都有一支 rpc_upsert_store 在，
--      不會出現「函式不存在」的空窗（整份一次貼上時本來就是同一個交易，別人看不到中間狀態；
--      萬一被逐句執行，最多是舊畫面短暫撞到兩支並存，不會有人叫不到函式）。
--      9 參數版一定要拆：留著的話，只送 9 個具名參數的呼叫會同時對上兩支 → function is not unique。
--   ② 已經貼過本檔的舊版（10 參數、p_store_kind 預設 'branch'）：
--      同簽名 CREATE OR REPLACE 直接換掉函式本體與預設值。PostgreSQL 允許這樣改預設值
--      （限制只有「不能拿掉既有預設值」與「預設值型別不能變」：'branch' 與 NULL 在這裡都是 TEXT），
--      DROP 9 參數版則是 IF EXISTS、什麼都不做。
--   ADD COLUMN IF NOT EXISTS、CHECK 限制的 DO 區塊本來就可以重跑。
--   ⚠ GRANT / COMMENT ON FUNCTION 沒寫參數列，只在「同名函式只剩一支」時成立 → 一定要排在 DROP 之後。
--
-- Rollback（回到 20260805000010）：同一批執行
--   DROP FUNCTION IF EXISTS public.rpc_upsert_store(
--     BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB, BOOLEAN, TEXT, TEXT, TEXT);
--   再貼 20260805000010_rpc_upsert_store_auto_location.sql 全文。
--   ⚠ 前端門市管理頁會送 p_store_kind，rollback 之後要一起退回前端，否則存門市會找不到函式。
--   stores.store_kind 欄位可以留著（舊函式不寫它，新增的門市會拿到預設值 branch）。
-- ============================================================

ALTER TABLE stores
  ADD COLUMN IF NOT EXISTS store_kind TEXT NOT NULL DEFAULT 'branch';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conrelid = 'public.stores'::regclass
       AND conname = 'stores_store_kind_check'
  ) THEN
    ALTER TABLE stores
      ADD CONSTRAINT stores_store_kind_check
      CHECK (store_kind IN ('branch', 'wholesale'));
  END IF;
END;
$$;

COMMENT ON COLUMN stores.store_kind IS
  '門市類型：branch=包子媽分店；wholesale=批發。撿貨矩陣用來決定零量欄位是否顯示。';

-- 參數簽名 9 → 10（多 p_store_kind）。先建新簽名、再拆舊的 9 參數簽名，理由見檔頭「重貼安全」。
-- 函式本體以 20260805000010 為底：除了標「p_store_kind」的幾行，其餘（含註解）與它逐字相同。
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
  p_store_kind              TEXT    DEFAULT NULL
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

    INSERT INTO stores (tenant_id, code, name, location_id,
                        pickup_window_days, allowed_payment_methods,
                        is_active, notes, line_oa_basic_id, store_kind, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, v_location_id,
            COALESCE(p_pickup_window_days,5), COALESCE(p_allowed_payment_methods,'["cash"]'::jsonb),
            COALESCE(p_is_active,TRUE), p_notes, v_line_oa, COALESCE(v_store_kind, 'branch'), auth.uid(), auth.uid())
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
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'store % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

-- 拆掉舊的 9 參數簽名（線上還是 20260805000010 那一版時才有東西可拆，否則 IF EXISTS 什麼都不做）。
-- ⚠ 一定要排在 CREATE 之後（任何時刻都有函式可叫）、GRANT／COMMENT 之前（它們沒寫參數列，
--   同名函式只剩一支才成立）。留著不拆的話，只送 9 個具名參數的呼叫會同時對上兩支 → function is not unique。
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
  '沒帶（NULL 或空字串）時，新增門市當 branch、更新門市維持原值。';

-- 叫 PostgREST 重新認一次欄位與函式（團隊 #788 部署後用過同一招：
--   公司\01_進行中\NEW-ERP_PR788_部署後_PostgREST快取重載.sql）。
-- 平常 Supabase 會自己重新認，這一行是保險：免得「SQL 貼了、畫面還是說找不到 store_kind／p_store_kind」。
-- 整份一次貼上時，這個通知在整批成功送出後才發出去。
NOTIFY pgrst, 'reload schema';

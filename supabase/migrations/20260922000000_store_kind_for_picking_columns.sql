-- ============================================================
-- 2026-09-22: 門市新增類型，供撿貨矩陣判斷欄位顯示
--
-- branch    = 包子媽分店：啟用中就算沒量也顯示欄位
-- wholesale = 批發：只有本草稿 / 本次建單範圍 / 本 wave 有量才顯示
--
-- 本檔只加 stores 欄位與重建 rpc_upsert_store；不改既有門市資料、不碰正式庫資料。
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

-- 參數簽名新增 p_store_kind，先 drop 舊 9 參數簽名，避免留下同名 overload。
DROP FUNCTION IF EXISTS public.rpc_upsert_store(
  BIGINT,
  TEXT,
  TEXT,
  BIGINT,
  INTEGER,
  JSONB,
  BOOLEAN,
  TEXT,
  TEXT
);

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
  p_store_kind              TEXT    DEFAULT 'branch'
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
  -- 空字串一律收斂成 NULL，前端清空欄位才不會存進 '' 讓「有沒有設定」難判斷
  v_line_oa TEXT := NULLIF(btrim(COALESCE(p_line_oa_basic_id, '')), '');
  v_store_kind TEXT := COALESCE(NULLIF(btrim(COALESCE(p_store_kind, '')), ''), 'branch');
  -- 呼叫端指定值優先；為 NULL 時（新增分支）才自動建門市倉別後回填
  v_location_id BIGINT := p_location_id;
  v_wh_code     TEXT;
  v_loc_type    TEXT;   -- 綁既有 WH- 倉別前，用來確認它確實是門市倉（type='store'）
BEGIN
  IF v_store_kind NOT IN ('branch', 'wholesale') THEN
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
      -- is_active 不納入判斷：倉別啟用狀態由倉別自身管理，停用的 store 倉照樣綁。
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
            COALESCE(p_is_active,TRUE), p_notes, v_line_oa, v_store_kind, auth.uid(), auth.uid())
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
      store_kind = v_store_kind,
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'store % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_store TO authenticated;

COMMENT ON FUNCTION public.rpc_upsert_store IS
  '門市 upsert。2026-08-01 加 p_line_oa_basic_id（會員端現貨專區「LINE 詢問」'
  '要把訊息帶到會員所在店的 LINE@；空字串收斂成 NULL）。'
  '2026-08-05 新增門市未指定倉別時，自動建 WH-<代碼>/<門市名>倉/store 倉別並綁定。'
  '2026-09-22 新增 p_store_kind：branch=包子媽分店、wholesale=批發。';

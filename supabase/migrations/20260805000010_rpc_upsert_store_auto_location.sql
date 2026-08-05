-- ============================================================
-- 2026-08-05: rpc_upsert_store 新增門市時自動建立對應門市倉別並綁定
--
-- 需求：建門市走 rpc_upsert_store，「對應倉別（location）」原本選填、不會
--       自動生成 → 門市可能漏配倉別（全民、頭份都靠手動補）。漏配的下場：
--       派貨「產生總倉→分店調撥」會被擋、月結只算有倉別的店 → 一路進不了帳。
--       → 新增門市（p_id IS NULL）且未指定倉別（p_location_id IS NULL）時，
--         自動建一筆對應門市倉別、綁上 stores.location_id，杜絕「門市有、倉別漏」。
--
-- 命名規則（老闆已確認）：
--   代碼 = 'WH-' || 門市代碼（例 S006 → WH-S006）
--   名稱 = 門市名 || '倉'（例 頭份店 → 頭份店倉）
--   類型 = 'store'（locations.type CHECK 允許 'central_warehouse' / 'store'）
--   狀態 = is_active TRUE；租戶 = 該門市 tenant
--
-- 防呆（WH-代碼 已存在，極少見）：先查同代碼倉別 → 有就綁既有那筆
--   （不重複建、不改動它）；先查後綁與 INSERT 之間的並發窗口再以
--   ON CONFLICT (tenant_id, code) DO NOTHING + 補查兜底，避免撞 UNIQUE 讓
--   整支 rpc RAISE 失敗。全程在單一 rpc 交易內 → 門市與倉別同生共滅，原子性成立。
--   綁既有前一律確認 type='store'：若 WH-代碼 被 central_warehouse 等非門市倉占用
--   → RAISE 交人工處理，不亂綁、也不讓 location_id 留 NULL 漏配（Codex P1）。
--   is_active 不納入判斷：停用的 store 倉照樣綁，倉的啟用狀態由倉別自身管理。
--
-- 空字串防呆（Codex P2）：新增分支開頭先擋 p_code / p_name btrim 後為空，
--   避免建出 'WH-'、'倉' 這種垃圾資料。
--
-- 呼叫端有給 p_location_id → 尊重指定值、不自動建（與原行為一致）。
-- 「更新門市」（p_id 有值）分支：一字未改，完全維持原樣。
--
-- 基底版本：20260801000020_rpc_upsert_store_line_oa.sql
--   （已 grep supabase/migrations/ 確認：那是動過本函式的兩支 migration 中
--     時間最新者，含 p_line_oa_basic_id 與空字串收斂 prior fix；本檔基於它
--     擴寫，line_oa 邏輯與更新分支 guard 一字未改。）
--
-- 為何純 CREATE OR REPLACE（不像上一版要先 DROP）：
--   本次參數簽名不變（維持 9 個參數），CREATE OR REPLACE 直接替換函式體、
--   不會產生 overload，故不需 DROP。
--
-- Rollback（回到 20260801000020 的版本）：
--   重跑 20260801000020_rpc_upsert_store_line_oa.sql 全文即可
--   （同簽名 CREATE OR REPLACE 會蓋回舊版函式體）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_upsert_store(
  p_id                      BIGINT,
  p_code                    TEXT,
  p_name                    TEXT,
  p_location_id             BIGINT  DEFAULT NULL,
  p_pickup_window_days      INTEGER DEFAULT 5,
  p_allowed_payment_methods JSONB   DEFAULT '["cash"]'::jsonb,
  p_is_active               BOOLEAN DEFAULT TRUE,
  p_notes                   TEXT    DEFAULT NULL,
  p_line_oa_basic_id        TEXT    DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
  -- 空字串一律收斂成 NULL，前端清空欄位才不會存進 '' 讓「有沒有設定」難判斷
  v_line_oa TEXT := NULLIF(btrim(COALESCE(p_line_oa_basic_id, '')), '');
  -- 呼叫端指定值優先；為 NULL 時（新增分支）才自動建門市倉別後回填
  v_location_id BIGINT := p_location_id;
  v_wh_code     TEXT;
  v_loc_type    TEXT;   -- 綁既有 WH- 倉別前，用來確認它確實是門市倉（type='store'）
BEGIN
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
                        is_active, notes, line_oa_basic_id, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, v_location_id,
            COALESCE(p_pickup_window_days,5), COALESCE(p_allowed_payment_methods,'["cash"]'::jsonb),
            COALESCE(p_is_active,TRUE), p_notes, v_line_oa, auth.uid(), auth.uid())
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
  '2026-08-05 新增門市未指定倉別時，自動建 WH-<代碼>/<門市名>倉/store 倉別並綁定'
  '（同代碼已存在則綁既有、不重複建；全在單一交易內確保原子性）。';

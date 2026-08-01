-- ============================================================
-- 2026-08-01: rpc_upsert_store 加 p_line_oa_basic_id
--
-- 需求：會員 App「現貨專區」的「LINE 詢問」要把訊息帶到「會員所在店」的
--       LINE 官方帳號。stores.line_oa_basic_id 欄位早就存在
--       （20260423120000_stores_order_schema.sql），但 admin /stores 表單
--       一直沒有這個欄位、線上 23 間店全是 NULL，等於沒人填得進去。
--       → 讓門市表單可以編輯它。
--
-- 基底版本：20260425120000_core_crud_rpcs.sql 的 rpc_upsert_store
--           （已 grep supabase/migrations/ 確認：那是唯一動過此函式的
--             migration，本檔即基於它擴寫，原有邏輯一字未改）
--
-- 為何 DROP 再 CREATE 而不是純 CREATE OR REPLACE：
--   參數個數變了（8 → 9）。CREATE OR REPLACE 只會多出一個 overload，
--   之後用 8 個具名參數呼叫會撞 "function is not unique"。
--   DROP + CREATE 在同一個 statement batch 內（單一 implicit transaction）。
--
-- 部署順序安全：新版第 9 個參數有 DEFAULT NULL，PostgREST 具名呼叫時
--   舊前端只送 8 個參數仍然解得到 → 先套 migration 再上前端不會有空窗。
--
-- Rollback（回到 20260425120000 的版本）：
--   DROP FUNCTION IF EXISTS public.rpc_upsert_store(
--     BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB, BOOLEAN, TEXT, TEXT);
--   -- 然後重跑 20260425120000_core_crud_rpcs.sql 的 C4 段落
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_upsert_store(
  BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB, BOOLEAN, TEXT);

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
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO stores (tenant_id, code, name, location_id,
                        pickup_window_days, allowed_payment_methods,
                        is_active, notes, line_oa_basic_id, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, p_location_id,
            COALESCE(p_pickup_window_days,5), COALESCE(p_allowed_payment_methods,'["cash"]'::jsonb),
            COALESCE(p_is_active,TRUE), p_notes, v_line_oa, auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
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
  '要把訊息帶到會員所在店的 LINE@；空字串收斂成 NULL）。';

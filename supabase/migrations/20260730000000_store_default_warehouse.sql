-- ============================================================
-- 建門市自動配預設倉 + 補建「全民」店倉
--
-- 背景:
--   分店新建「全民」店(stores.id=63, code=QM-全民)時沒有可選的
--   對應倉(locations 下拉只有既有店倉),location_id 一直是 NULL,
--   導致補貨核准(rpc_approve_restock_to_transfer 需 store.location_id)
--   等流程走不下去。既有店倉命名慣例(線上核對 2026-07-30):
--   code='WH-'||stores.code、name=stores.name||'倉'
--   (例: S001/平鎮店 → WH-S001/平鎮店倉、LELE-萬華/萬華店 → WH-LELE-萬華/萬華店倉)。
--
-- 變更:
--   1. 新 helper _ensure_store_location(store_id, uid):門市沒 location 時
--      依上述慣例建 type='store' 倉並回填 stores.location_id。
--      同 code 舊倉若沒被任何門市占用(門市軟刪後重建同 code 的情境)直接沿用
--      並重新啟用;code 被別家門市占用則加 epoch 尾碼避開 UNIQUE(tenant_id,code)。
--   2. rpc_upsert_store:新增門市且未指定 p_location_id 時自動配倉。
--      基底: 20260425120000_core_crud_rpcs.sql(唯一動過此函式的版本);
--      UPDATE 分支不變。rollback 指回 20260425120000 版本。
--   3. _resolve_or_create_takeout_store(樂樂匯入自動建店):自動建店後同樣配倉。
--      基底: 20260613000030_member_import_auto_create_store.sql(唯一定義版本);
--      rollback 指回 20260613000030 版本。
--   4. 資料補建:對現存 is_active 且未軟刪、location_id IS NULL 的門市補倉
--      (目前線上僅 stores.id=63「全民」→ 建 WH-QM-全民/全民倉)。
--
-- Rollback:
--   函式部分見上;資料部分 UPDATE stores SET location_id=NULL WHERE id=63;
--   DELETE FROM locations WHERE code='WH-QM-全民';
--   DROP FUNCTION public._ensure_store_location(BIGINT, UUID);
-- ============================================================

-- ----------------------------------------------------------------
-- 1. helper:確保門市有對應倉,沒有就建並回填
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._ensure_store_location(
  p_store_id BIGINT,
  p_uid      UUID DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_store RECORD;
  v_uid   UUID := COALESCE(p_uid, auth.uid());
  v_code  TEXT;
  v_loc   BIGINT;
BEGIN
  SELECT id, tenant_id, code, name, location_id INTO v_store
    FROM stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '_ensure_store_location: store % not found', p_store_id;
  END IF;
  IF v_store.location_id IS NOT NULL THEN
    RETURN v_store.location_id;
  END IF;

  v_code := 'WH-' || v_store.code;

  -- 同 code 舊店倉沒被任何門市占用(含軟刪門市) → 沿用並重新啟用
  SELECT l.id INTO v_loc
    FROM locations l
   WHERE l.tenant_id = v_store.tenant_id
     AND l.code = v_code
     AND l.type = 'store'
     AND NOT EXISTS (
       SELECT 1 FROM stores s
        WHERE s.tenant_id = l.tenant_id AND s.location_id = l.id
     );

  IF v_loc IS NOT NULL THEN
    UPDATE locations SET is_active = TRUE, updated_by = COALESCE(v_uid, updated_by)
     WHERE id = v_loc AND NOT is_active;
  ELSE
    IF EXISTS (
      SELECT 1 FROM locations
       WHERE tenant_id = v_store.tenant_id AND code = v_code
    ) THEN
      v_code := v_code || '-' || extract(epoch from now())::bigint::text;
    END IF;

    INSERT INTO locations (tenant_id, code, name, type, is_active, created_by, updated_by)
    VALUES (v_store.tenant_id, v_code, v_store.name || '倉', 'store', TRUE, v_uid, v_uid)
    RETURNING id INTO v_loc;
  END IF;

  UPDATE stores
     SET location_id = v_loc, updated_by = COALESCE(v_uid, updated_by)
   WHERE id = v_store.id;

  RETURN v_loc;
END;
$$;

COMMENT ON FUNCTION public._ensure_store_location(BIGINT, UUID) IS
  '門市沒對應倉時依慣例(code=WH-{store.code}, name={store.name}倉)建 store 倉並回填 stores.location_id';

-- ----------------------------------------------------------------
-- 2. rpc_upsert_store:新增未指定倉 → 自動配倉
--    (基底 20260425120000;僅 INSERT 分支加自動配倉,其餘不變)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_store(
  p_id                      BIGINT,
  p_code                    TEXT,
  p_name                    TEXT,
  p_location_id             BIGINT  DEFAULT NULL,
  p_pickup_window_days      INTEGER DEFAULT 5,
  p_allowed_payment_methods JSONB   DEFAULT '["cash"]'::jsonb,
  p_is_active               BOOLEAN DEFAULT TRUE,
  p_notes                   TEXT    DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO stores (tenant_id, code, name, location_id,
                        pickup_window_days, allowed_payment_methods,
                        is_active, notes, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, p_location_id,
            COALESCE(p_pickup_window_days,5), COALESCE(p_allowed_payment_methods,'["cash"]'::jsonb),
            COALESCE(p_is_active,TRUE), p_notes, auth.uid(), auth.uid())
    RETURNING id INTO v_id;

    -- 未指定對應倉 → 自動建「{門市名}倉」並回填
    IF p_location_id IS NULL THEN
      PERFORM public._ensure_store_location(v_id, auth.uid());
    END IF;
  ELSE
    UPDATE stores SET
      code = COALESCE(p_code, code),
      name = COALESCE(p_name, name),
      location_id = p_location_id,
      pickup_window_days = COALESCE(p_pickup_window_days, pickup_window_days),
      allowed_payment_methods = COALESCE(p_allowed_payment_methods, allowed_payment_methods),
      is_active = COALESCE(p_is_active, is_active),
      notes = p_notes,
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'store % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_store TO authenticated;

-- ----------------------------------------------------------------
-- 3. _resolve_or_create_takeout_store:自動建店後配倉
--    (基底 20260613000030;僅在自動建店 INSERT 後加一行,其餘不變)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._resolve_or_create_takeout_store(
  p_tenant UUID,
  p_hint   TEXT,
  p_uid    UUID
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
  v_id    BIGINT;
  v_count INT;
  v_code  TEXT;
  v_name  TEXT;
BEGIN
  IF p_hint IS NULL OR TRIM(p_hint) = '' OR p_hint = '—' THEN
    RETURN NULL;
  END IF;

  -- 1) 精確 match:name = hint+'店' 或 name = hint
  SELECT id INTO v_id
    FROM stores
   WHERE tenant_id = p_tenant
     AND is_active = TRUE
     AND name IN (p_hint || '店', p_hint)
   LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- 2) 模糊 match:name LIKE 'hint%' 唯一
  SELECT COUNT(*), MIN(id) INTO v_count, v_id
    FROM stores
   WHERE tenant_id = p_tenant
     AND is_active = TRUE
     AND name ILIKE p_hint || '%';
  IF v_count = 1 THEN RETURN v_id; END IF;
  -- v_count > 1 也走自動建,避免「平鎮」對到「平鎮舊店」+「平鎮新店」時卡住;
  -- 反正自動建出來的「平鎮店」有獨立 LELE-平鎮 code,事後 admin 可手動合併

  -- 3) 自動建:name = hint+'店';code = 'LELE-'+hint (衝突 append seq)
  v_name := p_hint || '店';
  v_code := 'LELE-' || p_hint;
  IF EXISTS (
    SELECT 1 FROM stores WHERE tenant_id = p_tenant AND code = v_code
  ) THEN
    v_code := v_code || '-' || extract(epoch from now())::bigint::text;
  END IF;

  INSERT INTO stores (
    tenant_id, code, name, is_active, notes,
    created_by, updated_by
  ) VALUES (
    p_tenant, v_code, v_name, TRUE,
    '(auto) 樂樂 CSV 匯入時依顧客「標籤=' || p_hint || '」自動建立',
    p_uid, p_uid
  ) RETURNING id INTO v_id;

  -- 自動建的門市同樣配預設倉({門市名}倉)
  PERFORM public._ensure_store_location(v_id, p_uid);

  RETURN v_id;
END;
$$;

-- ----------------------------------------------------------------
-- 4. 資料補建:現存缺倉門市(線上目前僅 QM-全民)
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_s   RECORD;
  v_loc BIGINT;
  v_n   INT := 0;
BEGIN
  FOR v_s IN
    SELECT id, code, name FROM stores
     WHERE location_id IS NULL AND deleted_at IS NULL AND is_active
     ORDER BY id
  LOOP
    v_loc := public._ensure_store_location(v_s.id, NULL);
    v_n := v_n + 1;
    RAISE NOTICE '補建門市倉: store %(%) → location %', v_s.code, v_s.name, v_loc;
  END LOOP;
  RAISE NOTICE '共補建 % 間門市倉', v_n;
END $$;

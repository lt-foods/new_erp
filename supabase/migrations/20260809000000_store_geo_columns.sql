-- ============================================================================
-- 2026-08-09: stores 加地址 / 經緯度，供首頁「門市熱賣地圖」定位
--
-- 為什麼要加欄位：全庫翻過一遍（grep latitude/longitude/address 於
--   supabase/migrations/）—— stores 沒有任何地理欄位，locations.address 24 筆
--   全 NULL。首頁要畫「哪家店賣得好、賣什麼」的地圖，沒有座標畫不出來。
--
-- 為什麼是 numeric 不是 PostGIS geography：
--   只需要「把點畫在自繪 SVG 上」+「未來或許算個店距」，不做空間索引 / 範圍查詢，
--   為此開 PostGIS extension 不划算。要升級時 numeric → geography 是一句
--   ST_MakePoint(longitude, latitude)，不會被這個決定綁死。
--
-- 為什麼另開 rpc_set_store_geo 而不是擴 rpc_upsert_store：
--   已 grep —— rpc_upsert_store 被 20260425120000 / 20260801000020 /
--   20260805000010 三支動過，參數個數改過一次（8→9，當時必須 DROP+CREATE 才
--   避開 overload 撞名）。同 20260807000050（line_liff_id）的判斷：為獨立欄位
--   再冒一次那個風險不划算，改用單一用途小 RPC。
--
-- 種子座標（本檔下半段）只填「店名＝行政區名」而能確定位置的 17 家，
--   給的是**行政區概略中心點**、不是門市門牌座標 —— 地圖上看得出分佈與遠近，
--   但不是導航等級精度，之後在門市頁逐家校正。
--   店名看不出所在地的 7 家（四號 / 古華 / 南平 / 經國 / 忠順 / 環球 / 全民）
--   一律留 NULL，寧可不畫也不亂猜；首頁會把它們列成「尚未設定座標」清單。
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.rpc_set_store_geo(BIGINT, TEXT, NUMERIC, NUMERIC);
--   ALTER TABLE stores DROP COLUMN IF EXISTS address,
--                      DROP COLUMN IF EXISTS latitude,
--                      DROP COLUMN IF EXISTS longitude;
-- ============================================================================

ALTER TABLE stores
  ADD COLUMN IF NOT EXISTS address   TEXT,
  ADD COLUMN IF NOT EXISTS latitude  NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS longitude NUMERIC(9,6);

COMMENT ON COLUMN stores.address   IS '門市地址（顯示 / 之後地理編碼用）';
COMMENT ON COLUMN stores.latitude  IS '緯度 WGS84（-90~90）。NULL = 未設定，不會出現在首頁熱賣地圖上';
COMMENT ON COLUMN stores.longitude IS '經度 WGS84（-180~180）。NULL = 未設定，不會出現在首頁熱賣地圖上';

-- 值域把關：打錯成「經緯度顛倒」或多打一位數會讓地圖整張爆掉，在寫入這關擋。
-- NOT VALID：只約束之後的寫入，不掃既有列（既有列全是 NULL，本來就過）。
ALTER TABLE stores
  DROP CONSTRAINT IF EXISTS stores_latitude_range,
  DROP CONSTRAINT IF EXISTS stores_longitude_range;
ALTER TABLE stores
  ADD CONSTRAINT stores_latitude_range
    CHECK (latitude  IS NULL OR (latitude  >= -90  AND latitude  <= 90))  NOT VALID,
  ADD CONSTRAINT stores_longitude_range
    CHECK (longitude IS NULL OR (longitude >= -180 AND longitude <= 180)) NOT VALID;

-- ============================================================================
-- 種子座標：行政區概略中心點（WGS84）
--   只填店名能確定行政區的店；ON CONFLICT 語意用 latitude IS NULL 守住，
--   重跑不會覆蓋人工校正過的值。
--   tenant 明寫 DEFAULT_TENANT_ID（線上 stores 24 筆全屬此租戶）：
--   之後有第二個租戶用相同 code 時，不會被這支歷史 migration 波及。
-- ============================================================================
WITH seed(code, address, lat, lng) AS (
  VALUES
    ('S001',       '桃園市平鎮區',   24.918600, 121.216800),
    ('S002',       '臺北市松山區',   25.049700, 121.574600),
    ('S003',       '臺北市北投區',   25.132400, 121.498600),
    ('S004',       '臺北市內湖區',   25.069700, 121.594300),
    ('S005',       '臺北市信義區',   25.033000, 121.565400),
    ('S006',       '苗栗縣頭份市',   24.687900, 120.908800),
    ('LELE-萬華',  '臺北市萬華區',   25.032400, 121.499700),
    ('LELE-文山',  '臺北市文山區',   24.988700, 121.570500),
    ('LELE-永和',  '新北市永和區',   25.009300, 121.514000),
    ('LELE-中和',  '新北市中和區',   24.999300, 121.498600),
    ('LELE-板橋',  '新北市板橋區',   25.014300, 121.467200),
    ('LELE-泰山',  '新北市泰山區',   25.058700, 121.431000),
    ('LELE-林口',  '新北市林口區',   25.077600, 121.391700),
    ('LELE-淡水',  '新北市淡水區',   25.167700, 121.440600),
    ('LELE-三峽',  '新北市三峽區',   24.934300, 121.368900),
    ('LELE-龍潭',  '桃園市龍潭區',   24.863500, 121.216600),
    ('LELE-湖口',  '新竹縣湖口鄉',   24.896100, 121.043900)
)
UPDATE stores s
   SET latitude  = seed.lat,
       longitude = seed.lng,
       address   = COALESCE(s.address, seed.address)
  FROM seed
 WHERE s.code = seed.code
   AND s.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
   AND s.latitude IS NULL
   AND s.longitude IS NULL;

-- ============================================================================
-- rpc_set_store_geo：門市頁「地址 / 座標」欄位的寫入端
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_set_store_geo(
  p_store_id  BIGINT,
  p_address   TEXT    DEFAULT NULL,
  p_latitude  NUMERIC DEFAULT NULL,
  p_longitude NUMERIC DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  -- ⚠ 應用角色一定要走 app_metadata；頂層 'role' 永遠是 'authenticated'
  --   （見 CLAUDE.md、20260807000040）。'' = 沒有顯式 role 的 legacy admin。
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_addr   TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF v_role NOT IN ('owner', 'admin', '') THEN
    RAISE EXCEPTION 'insufficient_role: 只有負責人 / 管理員可以設定門市座標';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'store_not_found';
  END IF;

  -- 經緯度要嘛都給、要嘛都清（只有一半的點畫不出來，留著只會讓人以為設定好了）
  IF (p_latitude IS NULL) <> (p_longitude IS NULL) THEN
    RAISE EXCEPTION 'invalid_geo: 經度與緯度要一起填或一起留空';
  END IF;

  IF p_latitude IS NOT NULL AND (p_latitude < -90 OR p_latitude > 90) THEN
    RAISE EXCEPTION 'invalid_geo: 緯度應介於 -90 ~ 90（台灣約 21.9 ~ 25.3）';
  END IF;
  IF p_longitude IS NOT NULL AND (p_longitude < -180 OR p_longitude > 180) THEN
    RAISE EXCEPTION 'invalid_geo: 經度應介於 -180 ~ 180（台灣約 118 ~ 122）';
  END IF;

  UPDATE stores
     SET address    = v_addr,
         latitude   = p_latitude,
         longitude  = p_longitude,
         updated_by = auth.uid(),
         updated_at = NOW()
   WHERE id = p_store_id AND tenant_id = v_tenant;
END;
$$;

COMMENT ON FUNCTION public.rpc_set_store_geo(BIGINT, TEXT, NUMERIC, NUMERIC) IS
  '設定門市地址與經緯度（owner/admin）。經緯度必須成對填或成對留空；'
  '留空 = 該店不出現在首頁熱賣地圖上。';

GRANT EXECUTE ON FUNCTION public.rpc_set_store_geo(BIGINT, TEXT, NUMERIC, NUMERIC) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_set_store_geo(BIGINT, TEXT, NUMERIC, NUMERIC) FROM anon;

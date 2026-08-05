-- ============================================================
-- 分店帳號看不到庫存異動紀錄 — stock_movements 的 store_read_own 還是初版 RLS
--
-- 現象：2026-08-06 松山店帳號在庫存總覽點開「近 50 筆庫存異動」永遠顯示
--   「無異動紀錄」，但餘額看得到（例：阿猴鮮奶在庫 1、最後異動 8/5，
--   點開卻空白）— 對不了帳，店家會以為庫存是憑空冒出來的。
--
-- 根因：20260707000070 把 stock_balances 的 store_read_own 改成用
--   _jwt_store_location_ids()（app_metadata.stores 店名 → location_id），
--   但 stock_movements 漏了 — 它還是 20260422120003 的初版，要求 JWT 有
--   location_id claim；這個 claim 在本專案的 JWT 裡從來不存在，
--   所以分店帳號對 stock_movements 的直接查詢永遠回空集合。
--
-- 修法：把 stock_movements 的 store_read_own 換成與 stock_balances 相同的
--   判定（同一支 helper、同一組角色）。HQ 端的 hq_full_read 本來就涵蓋
--   admin/hq_manager，不動。
--
-- 基底版本：20260422120003_inventory_schema 的 store_read_own（唯一版本）
-- rollback：DROP POLICY store_read_own ON stock_movements; 重建 20260422 版
--   （USING tenant + role IN (store_manager,clerk) + location_id = jwt location_id）。
-- ============================================================

DROP POLICY IF EXISTS store_read_own ON stock_movements;

CREATE POLICY store_read_own ON stock_movements
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(
          (auth.jwt() -> 'app_metadata') ->> 'role',
          auth.jwt() ->> 'role', ''
        ) IN ('store_manager', 'store_staff', 'clerk')
    AND location_id = ANY (_jwt_store_location_ids())
  );

COMMENT ON POLICY store_read_own ON stock_movements IS
  '分店帳號可讀自己店（app_metadata.stores 對應倉別）的庫存異動。'
  '20260805000240 對齊 stock_balances 的判定（原版要求不存在的 location_id claim，永遠回空）。';

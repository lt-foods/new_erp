-- ============================================================
-- 2026-08-26：OFF 抵減單不再被波次推進 shipping / ready
--
-- 災情（平鎮 GRP-20260730-014，2026-08-26 回報）：
--   取貨頁上出現一張「全部品項 × -1、$0」的單，標著
--   「到貨：2026/8/26 下午2:07」＋「↩ 已全數退回總倉，無可取貨項目」。
--   店家以為系統把客人的貨判成未到貨、退回了總倉 —— 實際上
--   transfers 裡一筆退貨單都沒有。那張是 GRP-20260730-014-OFF0001
--   庫存抵減單（order_kind='offset'，rpc_create_offset_order 建的
--   負數帳務單，讓採購聚合扣掉店內已有的量），本來就永遠停在
--   confirmed；取貨頁把負數行畫出來後 remainingQty 全部歸 0，
--   就長成「已全數退回總倉」的樣子。
--
-- 根因：rpc_mark_orders_shipping_for_wave 對 (campaign, store) 的
--   pending/confirmed/reserved 單整批推 shipping，完全沒濾 order_kind
--   —— OFF 單也被推進 shipping；rpc_receive_transfer 邏輯 C 再對
--   shipping 單跑 is_order_pickup_ready，而取貨閘門對 offset 單
--   全面豁免（Path D' 自我滿足＋實體庫存守衛豁免 offset），於是
--   收貨當下 OFF 單被推成 ready、蓋上 ready_at，在取貨頁浮出來。
--   全站已有 17 張 OFF 單這樣被推成 ready（最早 6 月起）。
--
--   同場加映（資料面，本檔不處理、由店家操作）：這張 OFF 單抵掉的
--   SKU 裡，3931/3933 平鎮從未入過庫存帳（貨直接交給客人），實體
--   庫存守衛（20260818000010）因此把客人單的取貨擋成「未到貨」——
--   正解照該守衛的設計：到庫存總覽補庫存後自動放行，不需改碼。
--
-- 本檔兩件事：
--   A. rpc_mark_orders_shipping_for_wave 排除 order_kind='offset'。
--      OFF 單的生命週期只有 confirmed / cancelled
--      （rpc_create_offset_order / rpc_cancel_offset_order），
--      不跟波次狀態機走。_advance_arrived_confirmed_orders 與
--      收貨配單各入口本來就都濾掉 offset，這是唯一漏的推進點。
--   B. 資料治理（冪等）：把已被推成 shipping / ready 的 OFF 單
--      退回 confirmed、清 ready_at。線上 17 張、全數無 picked_up
--      行。取貨閘門 Path D' 只要求 offset 單 status NOT IN
--      ('cancelled','expired','transferred_out')，confirmed 照樣
--      成立，客人單的可取判定不受影響。
--
-- 基底版本：rpc_mark_orders_shipping_for_wave =
--   20260614000050_fix_mark_orders_shipping_use_campaign_id.sql
--   （已 grep 全部 migration、並比對線上 pg_proc.prosrc 一致；
--    僅加一行 order_kind 過濾）。
-- 前端同 PR：取貨頁搜尋結果排除 order_kind='offset'
--   （apps/admin/src/app/(protected)/pickup/page.tsx）。
-- Rollback：重跑 20260614000050 的 CREATE OR REPLACE；資料治理
--   不自動回滾（被退回的單可依本檔清單重推，但沒有理由這麼做）。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_mark_orders_shipping_for_wave(
  p_wave_id  BIGINT,
  p_operator UUID
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id UUID;
  v_updated   INTEGER;
BEGIN
  SELECT tenant_id INTO v_tenant_id FROM picking_waves WHERE id = p_wave_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;

  WITH affected AS (
    UPDATE customer_orders co
       SET status     = 'shipping',
           updated_at = NOW(),
           updated_by = p_operator
     WHERE co.tenant_id = v_tenant_id
       AND co.status IN ('pending','confirmed','reserved')
       -- 20260826：OFF 抵減單（order_kind='offset'）是純帳務單（負數行），
       -- 生命週期只有 confirmed / cancelled；被推進 shipping 後會被收貨
       -- 邏輯 C 推成 ready（閘門對 offset 全豁免），在取貨頁浮出來變成
       -- 「已全數退回總倉」的假訊息。
       AND COALESCE(co.order_kind, 'normal') <> 'offset'
       AND EXISTS (
         SELECT 1 FROM picking_wave_items pwi
          WHERE pwi.wave_id    = p_wave_id
            AND pwi.picked_qty > 0
            AND pwi.campaign_id  = co.campaign_id
            AND pwi.store_id     = co.pickup_store_id
       )
    RETURNING co.id
  )
  SELECT COUNT(*) INTO v_updated FROM affected;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_mark_orders_shipping_for_wave(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_mark_orders_shipping_for_wave IS
  '把 wave 涉及的訂單（同 campaign + 同 store）從 pending/confirmed/reserved 推到 shipping。'
  '改用 picking_wave_items.campaign_id 直接對齊，不再依賴 wave_date = end_at 日。'
  '20260826：排除 order_kind=''offset''（抵減單只有 confirmed / cancelled 兩態）。';

-- ----------------------------------------------------------------
-- 資料治理（冪等）：被誤推的 OFF 單退回 confirmed
-- ----------------------------------------------------------------
DO $heal$
DECLARE
  v_fixed INT;
BEGIN
  WITH fixed AS (
    UPDATE customer_orders
       SET status     = 'confirmed',
           ready_at   = NULL,
           updated_at = NOW()
     WHERE order_kind = 'offset'
       AND status IN ('shipping','ready')
    RETURNING id, order_no
  )
  SELECT COUNT(*) INTO v_fixed FROM fixed;
  RAISE NOTICE '資料治理：% 張 OFF 抵減單退回 confirmed（清 ready_at）', v_fixed;
END;
$heal$;

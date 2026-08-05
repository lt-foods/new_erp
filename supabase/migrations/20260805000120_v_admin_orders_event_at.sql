-- ============================================================
-- v_admin_orders — 訂單清單用的檢視，多一欄「事件日」event_at
--
-- 動機：/orders 的日期區間原本一律套 created_at（訂單日）。團購下單到取貨隔
--   好幾天到好幾週，所以在「已完成 / 取消 / 轉出」這些終態分頁用訂單日篩最近
--   幾天永遠是 0 筆 —— 使用者要問的是「這幾天*發生*了什麼」：這幾天交出去哪些
--   貨、這幾天取消了哪些單。
--
-- 為什麼不是 updated_at：
--   customer_orders 有 touch_updated_at trigger，任何後續寫入都會把它往後推。
--   線上實測 15532 張 completed 單，有 4049 張（26%）的 updated_at 與「最後一次
--   取貨時間」差超過 1 小時，最大偏差 62 天，且偏差方向 100% 是「updated_at 比較
--   晚」—— 1504 張被 8/4 的批次寫入沖到 8/4、1413 張沖到 8/3。拿 updated_at 篩
--   「8/3~8/5 取貨」會把 5~7 月取的舊單全撈進來。它只適合當排序鍵，不能當事件日。
--
-- event_at 的來源（每個 status 取它自己的事件時間戳；線上覆蓋率）：
--   ready               → ready_at      18371/18400 (99.8%)  到貨可取的時間
--   completed           → completed_at  15532/15532 (100%)   取貨完成；與「最後一
--                         次 picked_up 明細的 updated_at」15531 筆同秒、1 筆差 <1h
--   partially_completed → 最後一次 picked_up 明細的 updated_at（此 status 沒有
--                         completed_at；線上 87 筆）。定義取「最後一次取貨」，
--                         分批跨日取的單以最後那次為準。
--   cancelled           → cancelled_at  917/917 (100%)
--   expired             → COALESCE(cancelled_at, ready_at)；此 status 已停用、
--                         線上 0 筆，且沒有專屬時間戳，故為 best-effort
--   transferred_out     → 接手單的 created_at（轉出＝當下開一張新單給接手人）。
--                         線上 83 張全部都有 transferred_to_order_id 且目標存在，
--                         79/83 與舊單 updated_at 相差 <1 分鐘（其餘 4 張是舊單
--                         後來又被 touch，正說明不能用 updated_at）。
--   其餘 (pending/confirmed/shipping) → 尚無終態事件，落回 created_at
--
--   最後一律 COALESCE(..., created_at)：來源為 NULL 時（例：29 張沒有 ready_at 的
--   ready 單）不讓該筆從日期篩選中憑空消失，寧可退回訂單日。
--
-- 用途：/orders 列表直接查這張 view 並對 event_at 下區間（PostgREST 單欄過濾），
--   tab 數量走 rpc_order_overview（同樣以本 view 為來源，見 20260805000130）。
--   兩邊同一個 event_at 定義 = 列表與 tab 數字不會對不起來。
--
-- security_invoker = true：RLS 套用 caller，與 v_admin_member_list 同慣例。
-- 加欄位：CREATE OR REPLACE VIEW 只能在尾端追加，不能改既有欄位順序/型別。
-- rollback：DROP VIEW v_admin_orders;（並把 orders/page.tsx 改回查 customer_orders）
-- ============================================================

CREATE OR REPLACE VIEW v_admin_orders
WITH (security_invoker = true) AS
SELECT
  o.id,
  o.tenant_id,
  o.order_no,
  o.campaign_id,
  o.member_id,
  o.nickname_snapshot,
  o.pickup_store_id,
  o.pickup_deadline,
  o.status,
  o.transferred_from_order_id,
  o.transferred_to_order_id,
  o.created_at,
  o.updated_at,
  o.ready_at,
  o.completed_at,
  o.cancelled_at,
  COALESCE(
    CASE o.status
      WHEN 'ready'               THEN o.ready_at
      WHEN 'completed'           THEN o.completed_at
      WHEN 'partially_completed' THEN (
        SELECT max(i.updated_at)
        FROM customer_order_items i
        WHERE i.order_id = o.id AND i.status = 'picked_up'
      )
      WHEN 'cancelled'           THEN o.cancelled_at
      WHEN 'expired'             THEN COALESCE(o.cancelled_at, o.ready_at)
      WHEN 'transferred_out'     THEN (
        SELECT t.created_at FROM customer_orders t WHERE t.id = o.transferred_to_order_id
      )
      ELSE NULL
    END,
    o.created_at
  ) AS event_at
FROM customer_orders o;

COMMENT ON VIEW v_admin_orders IS
  '訂單清單用檢視：customer_orders + event_at（該訂單「這個狀態是哪天發生的」）。'
  'ready→ready_at、completed→completed_at、partially_completed→最後一次取貨、'
  'cancelled→cancelled_at、transferred_out→接手單的 created_at，其餘/NULL→created_at。'
  '不要用 updated_at 當事件日：它會被之後任何寫入 touch 掉（線上 26% 的 completed 單偏差 >1h）。';

GRANT SELECT ON v_admin_orders TO authenticated;

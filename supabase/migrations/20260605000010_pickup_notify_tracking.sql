-- ============================================================
-- 取貨通知追蹤：customer_orders 加 last_notify_pickup_at + 次數
--   讓 /pickup 顯示「📨 已通知 N 次（上次 時間）」避免重複轟炸
-- ============================================================

ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS last_notify_pickup_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS notify_pickup_count   INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN customer_orders.last_notify_pickup_at IS '上一次發送「您訂單已到貨」通知的時點';
COMMENT ON COLUMN customer_orders.notify_pickup_count   IS '已發送的取貨通知次數（避免轟炸）';

-- RPC: 在 admin-notify 推播完成後 client 呼叫此 RPC 更新時間/次數
--      會檢查黑名單；若會員為 no_notify_pickup → 不更新 + 不報錯（讓 UI 流暢）
CREATE OR REPLACE FUNCTION rpc_mark_pickup_notified(
  p_order_id BIGINT,
  p_operator UUID DEFAULT NULL
) RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role     TEXT := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                       NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                       ''
                     );
  v_store    BIGINT := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'store_id', '')::bigint,
                       NULLIF(auth.jwt() ->> 'store_id','')::bigint
                     );
  v_order    customer_orders%ROWTYPE;
  v_blocked  BOOLEAN;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant_id missing'; END IF;

  SELECT * INTO v_order FROM customer_orders
   WHERE id = p_order_id AND tenant_id = v_tenant FOR UPDATE;
  IF v_order.id IS NULL THEN RAISE EXCEPTION 'order % not found', p_order_id; END IF;

  -- 權限：HQ tier OR 店家自店
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant','')
     AND (v_store IS NULL OR v_order.pickup_store_id <> v_store) THEN
    RAISE EXCEPTION 'permission denied to notify order %', p_order_id;
  END IF;

  -- 會員黑名單 → 略過（不報錯，client UI 應已先擋；此處最後安全網）
  SELECT no_notify_pickup INTO v_blocked
    FROM members WHERE id = v_order.member_id;
  IF COALESCE(v_blocked, FALSE) THEN
    RETURN v_order;  -- 不更新時間
  END IF;

  UPDATE customer_orders
     SET last_notify_pickup_at = NOW(),
         notify_pickup_count   = notify_pickup_count + 1,
         updated_by            = COALESCE(p_operator, auth.uid()),
         updated_at            = NOW()
   WHERE id = p_order_id
   RETURNING * INTO v_order;
  RETURN v_order;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_mark_pickup_notified(BIGINT, UUID) TO authenticated;

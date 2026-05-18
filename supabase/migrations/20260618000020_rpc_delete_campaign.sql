-- ============================================================
-- 2026-06-18: rpc_delete_campaign — 開團刪除（草稿限定，實體刪除）
-- ------------------------------------------------------------
-- 開團狀態機嚴格單向（draft→open→closed→cancelled）；cancelled 為軟取消終態。
-- customer_orders / order_waitlist / customer_order_sources /
-- purchase_request_items 皆以「無 CASCADE」FK 參照開團 → 任何曾有訂單/PR
-- 的開團實體刪除會被 RESTRICT 擋下。故 **只允許刪除 draft 開團**
-- （draft 必無 orders / PR / waitlist）；其他狀態請走「批次取消」。
--
-- campaign_items / campaign_channels / campaign_audit_log 為 ON DELETE
-- CASCADE；但 campaign_audit_log 有 trg_no_mut_camp_audit append-only
-- BEFORE DELETE trigger，cascade 仍會觸發 → 仿 rpc_delete_picking_wave
-- 暫時 DISABLE 該 trigger 再刪、確保任何路徑都 ENABLE 回去。
--
-- 走 SECURITY DEFINER：admin JWT 無 role claim 也可刪；限同 tenant。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_delete_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_status TEXT;
  v_orders INTEGER;
BEGIN
  -- p_operator 為呼叫端對齊 close/finalize 簽章而保留；刪除後 row + audit
  -- 皆不存在、無處可記，故不使用（與 rpc_delete_picking_wave 一致）。

  SELECT status
    INTO v_status
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  -- 守門 1：只有草稿可刪
  IF v_status <> 'draft' THEN
    RAISE EXCEPTION 'campaign % is %, only draft can be deleted', p_campaign_id, v_status;
  END IF;

  -- 守門 2：防禦 — 草稿理論上無訂單，仍 belt-and-suspenders
  SELECT COUNT(*) INTO v_orders
    FROM customer_orders
   WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
  IF v_orders > 0 THEN
    RAISE EXCEPTION 'campaign % has % orders, cannot delete', p_campaign_id, v_orders;
  END IF;

  -- 暫停 campaign_audit_log 的 append-only 保護（cascade 會觸發它）
  ALTER TABLE campaign_audit_log DISABLE TRIGGER trg_no_mut_camp_audit;
  BEGIN
    DELETE FROM campaign_audit_log WHERE campaign_id = p_campaign_id;
    -- order_waitlist 無 CASCADE，草稿應為 0 筆，仍防禦性清除
    DELETE FROM order_waitlist
     WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
    -- 刪開團本體：campaign_items / campaign_channels 由 FK CASCADE 連帶刪除
    DELETE FROM group_buy_campaigns
     WHERE id = p_campaign_id AND tenant_id = v_tenant;
  EXCEPTION WHEN OTHERS THEN
    ALTER TABLE campaign_audit_log ENABLE TRIGGER trg_no_mut_camp_audit;
    RAISE;
  END;
  ALTER TABLE campaign_audit_log ENABLE TRIGGER trg_no_mut_camp_audit;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_campaign(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_campaign(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_campaign(BIGINT, UUID) IS
  '開團刪除：限 draft 且無訂單；實體刪除（campaign_items/channels/audit 連帶 CASCADE），暫停 audit append-only trigger；同 tenant。';

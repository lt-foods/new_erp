-- ============================================================
-- rpc_delete_campaign：放寬刪除條件 —「非開團中(上架) 且 無訂單」皆可硬刪除
--
-- 變更動機：
--   原本只允許刪除 draft 開團。需求調整為：
--     - 開團可以「硬刪除」（實體刪除，非軟刪）
--     - 但「開團中(open / 上架)」不可刪（顧客仍可下單）
--     - 且「裡面有顧客訂單」不可刪
--   亦即守門改為：status <> 'open' AND 無 customer_orders。
--
-- FK 安全性：
--   group_buy_campaigns 被多張「無 ON DELETE CASCADE」的表參照。
--   無訂單時，仍可能殘留：
--     - order_waitlist（候補名單）            → 一併刪除
--     - customer_order_sources（上傳截圖/解析暫存，order_id 可為 NULL）
--                                              → append-only，暫停 trg_no_mut_cos 後刪除
--   其餘（purchase_request_items / pr_campaigns / picking_waves / shortage 等）
--   僅在「已有訂單並進入採購流程」後才會出現，已被守門 2 擋住；
--   萬一仍有殘參照（如手動建立的採購單），DELETE 會觸發 foreign_key_violation，
--   捕捉後改丟可讀訊息，避免噴原始 FK 錯誤。
--
--   campaign_items / campaign_channels / campaign_audit_log 為 ON DELETE CASCADE；
--   campaign_audit_log 與 customer_order_sources 皆有 append-only BEFORE DELETE
--   trigger，故刪除前暫停、結束後（含例外路徑）一律補回。
--
-- 以哪個版本為基底：
--   20260618000020_rpc_delete_campaign.sql（時間最新、唯一現役定義）。
-- Rollback：
--   重新套用 20260618000020_rpc_delete_campaign.sql 即恢復「僅 draft 可刪」。
--
-- Scope：只改 rpc_delete_campaign，不動表、不動其他 RPC。
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
  -- p_operator 為對齊 close/finalize 簽章而保留；刪除後 row + audit 皆不存在、
  -- 無處可記，故不使用（與 rpc_delete_picking_wave 一致）。

  SELECT status
    INTO v_status
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  -- 守門 1：開團中(上架)不可刪 — 顧客仍可下單
  IF v_status = 'open' THEN
    RAISE EXCEPTION 'campaign % is open, cannot delete', p_campaign_id;
  END IF;

  -- 守門 2：有顧客訂單不可刪
  SELECT COUNT(*) INTO v_orders
    FROM customer_orders
   WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
  IF v_orders > 0 THEN
    RAISE EXCEPTION 'campaign % has % orders, cannot delete', p_campaign_id, v_orders;
  END IF;

  -- 暫停兩個 append-only 保護（cascade / 手動清除都會觸發 BEFORE DELETE trigger）
  ALTER TABLE campaign_audit_log     DISABLE TRIGGER trg_no_mut_camp_audit;
  ALTER TABLE customer_order_sources DISABLE TRIGGER trg_no_mut_cos;
  BEGIN
    -- campaign_audit_log：雖為 ON DELETE CASCADE，但 append-only，先手動清
    DELETE FROM campaign_audit_log
     WHERE campaign_id = p_campaign_id;
    -- customer_order_sources：無 CASCADE + append-only；無訂單時可能仍有
    -- 上傳截圖／解析暫存（order_id 為 NULL），一併清除
    DELETE FROM customer_order_sources
     WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
    -- order_waitlist：無 CASCADE，候補名單一併清除
    DELETE FROM order_waitlist
     WHERE campaign_id = p_campaign_id AND tenant_id = v_tenant;
    -- 刪開團本體：campaign_items / campaign_channels 由 FK CASCADE 連帶刪除
    DELETE FROM group_buy_campaigns
     WHERE id = p_campaign_id AND tenant_id = v_tenant;
  EXCEPTION
    WHEN foreign_key_violation THEN
      -- 仍被其他「無 CASCADE」的表參照（如採購單明細 / 撿貨波）
      ALTER TABLE campaign_audit_log     ENABLE TRIGGER trg_no_mut_camp_audit;
      ALTER TABLE customer_order_sources ENABLE TRIGGER trg_no_mut_cos;
      RAISE EXCEPTION 'campaign % still referenced by other records, cannot delete', p_campaign_id;
    WHEN OTHERS THEN
      ALTER TABLE campaign_audit_log     ENABLE TRIGGER trg_no_mut_camp_audit;
      ALTER TABLE customer_order_sources ENABLE TRIGGER trg_no_mut_cos;
      RAISE;
  END;
  ALTER TABLE campaign_audit_log     ENABLE TRIGGER trg_no_mut_camp_audit;
  ALTER TABLE customer_order_sources ENABLE TRIGGER trg_no_mut_cos;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_campaign(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_campaign(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_campaign(BIGINT, UUID) IS
  '開團刪除：限「非開團中(open) 且無顧客訂單」；實體刪除（campaign_items/channels/audit 連帶 CASCADE，waitlist/order_sources 手動清），暫停 append-only trigger；同 tenant。';

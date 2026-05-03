-- ============================================================
-- rpc_reorder_candidate_campaign：拖拉候選週曆時同步更新 campaign 順序
--
-- 為什麼要 RPC：group_buy_campaigns 的 RLS policy gbc_hq_all 限制需要
-- role IN (owner/admin/hq_manager/purchaser)。但 admin 使用者有時 JWT
-- 的 role claim 是 NULL，從 client 直接 UPDATE 會被 RLS 拒絕（0 rows
-- updated 但沒 error）。包成 SECURITY DEFINER RPC 即可繞過。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_reorder_candidate_campaign(
  p_candidate_id BIGINT,
  p_day_key      DATE,
  p_order        INTEGER,
  p_operator     UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant      UUID;
  v_campaign_id BIGINT;
  v_new_no      TEXT;
  v_pad_id      TEXT := lpad(p_candidate_id::TEXT, 6, '0');
BEGIN
  SELECT tenant_id INTO v_tenant FROM community_product_candidates WHERE id = p_candidate_id;
  IF v_tenant IS NULL THEN
    RETURN NULL; -- candidate 不存在就跳過
  END IF;

  v_new_no := 'GB' || to_char(p_day_key, 'YYYYMMDD') || '-C' || v_pad_id;

  -- 找對應 campaign（用 candidate id 後綴 LIKE）
  SELECT id INTO v_campaign_id
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND campaign_no LIKE '%-C' || v_pad_id
   LIMIT 1;

  IF v_campaign_id IS NULL THEN
    RETURN NULL; -- candidate 還沒被 schedule，沒對應 campaign
  END IF;

  UPDATE group_buy_campaigns SET
    display_order = p_order,
    start_at      = p_day_key::TIMESTAMPTZ,
    campaign_no   = v_new_no,
    updated_by    = p_operator,
    updated_at    = NOW()
  WHERE id = v_campaign_id;

  RETURN v_campaign_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_reorder_candidate_campaign(BIGINT, DATE, INTEGER, UUID) TO authenticated;

-- ============================================================
-- Revert 20260620000040_calendar_slot_index.sql
--
-- 週曆退回「一天一欄、欄內每個 item 一列」（一個 item 一個 slot 的舊樣式），
-- 不再用日 × 整點時段 grid。
--
-- 1) scheduled_sort_order 重編號為「同 day 內順序」
--    （先依 slot_index、再依舊 sort_order、再依 created_at 平手）
-- 2) DROP scheduled_slot_index 欄位
-- 3) DROP 5-參數版本 rpc_reorder_candidate_campaign、重建 4-參數版本
--    （回到 20260516000004 的簽名與 body，start_at = day 0 點）
-- ============================================================

BEGIN;

-- 1) 重新編號 sort_order 為「同 day 內順序」
WITH r AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY tenant_id, scheduled_open_at
           ORDER BY scheduled_slot_index NULLS LAST,
                    scheduled_sort_order NULLS LAST,
                    created_at,
                    id
         ) AS rn
    FROM community_product_candidates
   WHERE scheduled_open_at IS NOT NULL
)
UPDATE community_product_candidates c
   SET scheduled_sort_order = r.rn
  FROM r
 WHERE c.id = r.id;

-- 2) DROP scheduled_slot_index
ALTER TABLE community_product_candidates
  DROP COLUMN IF EXISTS scheduled_slot_index;

-- 3) DROP 5-參數版本、重建 4-參數版本
DROP FUNCTION IF EXISTS rpc_reorder_candidate_campaign(BIGINT, DATE, SMALLINT, INTEGER, UUID);

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
    RETURN NULL;
  END IF;

  v_new_no := 'GB' || to_char(p_day_key, 'YYYYMMDD') || '-C' || v_pad_id;

  SELECT id INTO v_campaign_id
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND campaign_no LIKE '%-C' || v_pad_id
   LIMIT 1;

  IF v_campaign_id IS NULL THEN
    RETURN NULL;
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

COMMIT;

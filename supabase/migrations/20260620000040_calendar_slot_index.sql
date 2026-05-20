-- ============================================================
-- 週曆從「一日一條清單、時間=index 推算」改成「日 × 時段 grid」
--
-- 新增 scheduled_slot_index：0 = 09:00、1 = 10:00、…、12 = 21:00
--   - 同日同 slot 可以有多筆（同時段多商品並列）
--   - slot 可以跳號（中間時段不塞商品）
--   - scheduled_sort_order 變成「同 day + slot 內的順序」
--
-- 既有資料 best-effort migration：以前 30 分一格，現在 1 小時一格 =
-- 2 個舊格塞進 1 個新格 → slot_index = floor((sort_order - 1) / 2)
-- ============================================================

ALTER TABLE community_product_candidates
  ADD COLUMN IF NOT EXISTS scheduled_slot_index SMALLINT;

COMMENT ON COLUMN community_product_candidates.scheduled_slot_index IS
'排程時段索引：0 = 09:00、1 = 10:00、…、12 = 21:00。NULL 表示未排程或未指定時段。';

-- 1) 既有資料 best-effort：把 30 分鐘 idx 壓縮成小時 slot
UPDATE community_product_candidates
   SET scheduled_slot_index = LEAST(
         GREATEST(((COALESCE(scheduled_sort_order, 1) - 1) / 2)::SMALLINT, 0::SMALLINT),
         12::SMALLINT
       )
 WHERE scheduled_open_at IS NOT NULL
   AND scheduled_slot_index IS NULL;

-- 2) 把 scheduled_sort_order 重新編號為「同 day + slot 內的順序」
WITH r AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY tenant_id, scheduled_open_at, scheduled_slot_index
           ORDER BY scheduled_sort_order NULLS LAST, created_at
         ) AS rn
    FROM community_product_candidates
   WHERE scheduled_open_at IS NOT NULL
)
UPDATE community_product_candidates c
   SET scheduled_sort_order = r.rn
  FROM r
 WHERE c.id = r.id;

-- 3) RPC 簽名變更：rpc_reorder_candidate_campaign 加 p_slot_index
--    start_at = day_key + (slot_index + 9) 小時，跟 UI 上顯示的時段對齊
DROP FUNCTION IF EXISTS rpc_reorder_candidate_campaign(BIGINT, DATE, INTEGER, UUID);

CREATE OR REPLACE FUNCTION rpc_reorder_candidate_campaign(
  p_candidate_id BIGINT,
  p_day_key      DATE,
  p_slot_index   SMALLINT,
  p_order        INTEGER,
  p_operator     UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant      UUID;
  v_campaign_id BIGINT;
  v_new_no      TEXT;
  v_pad_id      TEXT := lpad(p_candidate_id::TEXT, 6, '0');
  v_start_at    TIMESTAMPTZ;
BEGIN
  SELECT tenant_id INTO v_tenant FROM community_product_candidates WHERE id = p_candidate_id;
  IF v_tenant IS NULL THEN
    RETURN NULL;
  END IF;

  v_new_no := 'GB' || to_char(p_day_key, 'YYYYMMDD') || '-C' || v_pad_id;
  v_start_at := (p_day_key::TIMESTAMP + ((COALESCE(p_slot_index, 0::SMALLINT) + 9) || ' hours')::INTERVAL)::TIMESTAMPTZ;

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
    start_at      = v_start_at,
    campaign_no   = v_new_no,
    updated_by    = p_operator,
    updated_at    = NOW()
  WHERE id = v_campaign_id;

  RETURN v_campaign_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_reorder_candidate_campaign(BIGINT, DATE, SMALLINT, INTEGER, UUID) TO authenticated;

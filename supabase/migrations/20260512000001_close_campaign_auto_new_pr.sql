-- ============================================================
-- rpc_close_campaign 升級：同日 PR 已鎖時自動為當前 campaign 建 campaign-type PR
--
-- 既有行為：
--   - 唯一 open close → auto-create close_date PR
--   - 同日多 open → deferred
--   - 同日已有 close_date PR + draft → append 到該 PR
--   - 同日已有 close_date PR + locked（submitted / partially_ordered / fully_ordered）
--     → 回 action='skipped_pr_locked'，要求人工處理（× 已不適用）
--
-- 新行為（差異點）：
--   - 同日已有 close_date PR + locked → 自動呼叫 rpc_create_pr_from_campaign
--     為當前 campaign 建獨立 campaign-type PR；
--     成功 → action='created_secondary'，回新 PR id；
--     失敗 → action='create_failed'，reason 帶錯誤訊息。
--
-- 為何：操作者把 close_date PR 送出 / 下 PO 後，後到的 campaign 仍會結單；
--   原本要求人工處理，導致流程卡住。獨立 campaign-type PR 與既有 close_date PR
--   的訂單需求互不重疊（campaign-type 只蓋自己的 campaign），合理共存。
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_close_campaign(BIGINT, UUID);

CREATE OR REPLACE FUNCTION public.rpc_close_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant             UUID;
  v_status             TEXT;
  v_close_date         DATE;
  v_other_open_count   INTEGER;
  v_existing_pr_id     BIGINT;
  v_existing_pr_status TEXT;
  v_new_pr_id          BIGINT;
  v_new_pr_no          TEXT;
  v_append_result      JSONB;
BEGIN
  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei')
    INTO v_tenant, v_status, v_close_date
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'campaign % not in open status (current: %)', p_campaign_id, v_status;
  END IF;

  -- 1. 切 status
  UPDATE group_buy_campaigns
     SET status = 'closed',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_campaign_id;

  -- 2. 找該 close_date 是否已有 close_date 型 PR（campaign-type 不影響此判斷）
  SELECT id, status INTO v_existing_pr_id, v_existing_pr_status
    FROM purchase_requests
   WHERE tenant_id = v_tenant
     AND source_type = 'close_date'
     AND source_close_date = v_close_date
     AND status <> 'cancelled'
   LIMIT 1;

  IF v_existing_pr_id IS NOT NULL THEN
    -- 2a. PR 在 draft → 自動 append 此 campaign 商品（既有行為）
    IF v_existing_pr_status = 'draft' THEN
      BEGIN
        v_append_result := public.rpc_append_campaign_to_pr(
          v_existing_pr_id, p_campaign_id, p_operator
        );
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', v_existing_pr_id,
          'action', 'appended',
          'append', v_append_result
        );
      EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', v_existing_pr_id,
          'action', 'append_failed',
          'reason', SQLERRM
        );
      END;
    ELSE
      -- 2b. PR 已鎖（submitted / partially_ordered / fully_ordered）
      --     → 自動為當前 campaign 建 campaign-type PR（新行為）
      BEGIN
        v_new_pr_id := public.rpc_create_pr_from_campaign(p_campaign_id, p_operator);
        SELECT pr_no INTO v_new_pr_no FROM purchase_requests WHERE id = v_new_pr_id;
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', v_new_pr_id,
          'pr_no', v_new_pr_no,
          'action', 'created_secondary',
          'reason', format('既有 close_date PR id=%s 已鎖（%s）；改為此 campaign 建獨立 PR',
                            v_existing_pr_id, v_existing_pr_status),
          'locked_pr_id', v_existing_pr_id,
          'locked_pr_status', v_existing_pr_status
        );
      EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', NULL,
          'action', 'create_failed',
          'reason', SQLERRM,
          'locked_pr_id', v_existing_pr_id,
          'locked_pr_status', v_existing_pr_status
        );
      END;
    END IF;
  END IF;

  -- 3. 還有其他 open campaign 在同 close_date → 先不建 PR
  SELECT COUNT(*) INTO v_other_open_count
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status = 'open'
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = v_close_date
     AND id <> p_campaign_id;

  IF v_other_open_count > 0 OR v_close_date IS NULL THEN
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', NULL, 'action', 'deferred',
      'reason', 'other open campaigns exist on close_date'
    );
  END IF;

  -- 4. auto-create close_date PR（同日全結 + 從未建過 PR）
  BEGIN
    v_new_pr_id := public.rpc_create_pr_from_close_date(v_close_date, p_operator);
    SELECT pr_no INTO v_new_pr_no FROM purchase_requests WHERE id = v_new_pr_id;
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', v_new_pr_id, 'pr_no', v_new_pr_no, 'action', 'created'
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', NULL, 'action', 'create_failed', 'reason', SQLERRM
    );
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_close_campaign TO authenticated;

COMMENT ON FUNCTION public.rpc_close_campaign IS
  '結單：切 closed；同日已有 PR 且 draft → append；已鎖 → 為當前 campaign 建獨立 campaign-type PR；無 PR + 該日全結 → auto-create close_date PR';

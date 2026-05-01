-- ============================================================
-- 候選池排日期 → 一次建立 draft product + draft sku + draft campaign + campaign_items
--
-- 取代 rpc_adopt_candidate 的舊流程（後者保留為 legacy / idempotent 補救）。
-- 流程：
--   1. role check (owner/admin/hq_manager/assistant) — 同 rpc_adopt_candidate
--   2. 鎖 candidate row
--   3. 已 scheduled (adopted_product_id NOT NULL) → idempotent 回傳既有資料
--   4. 否則：
--      a. rpc_next_product_code() → 建 product (status='draft')
--      b. rpc_next_sku_code() → 建 sku (status='draft')
--      c. 若 candidate.adopted_sale_price NOT NULL → rpc_set_retail_price 預填
--      d. 產生 campaign_no = 'GB' + YYYYMMDD + '-C' + zeropad6(candidate_id)
--      e. rpc_upsert_campaign → 建 campaign (status='draft', start_at = scheduled_date 00:00 UTC)
--      f. rpc_upsert_campaign_item → 連 campaign ↔ sku（unit_price = adopted_sale_price 或 0）
--      g. update candidate: adopted_product_id / owner_action='scheduled' /
--         scheduled_open_at / scheduled_by / scheduled_at
--
-- 不直接寫 cost：候選 cost 留在 candidate.adopted_cost；HQ 角色之後在商品編輯頁手動套用。
-- (rpc_set_cost_price 的 role check 會擋掉 assistant)
--
-- Scope: 只新增此 RPC、不動既有表/RPC
-- Rollback: DROP FUNCTION IF EXISTS public.rpc_schedule_candidate(BIGINT, DATE, TEXT);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_schedule_candidate(
  p_candidate_id    BIGINT,
  p_scheduled_date  DATE,
  p_product_name    TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_user           UUID := auth.uid();
  v_role           TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_cand           RECORD;
  v_product_code   TEXT;
  v_product_id     BIGINT;
  v_sku_code       TEXT;
  v_sku_id         BIGINT;
  v_campaign_no    TEXT;
  v_campaign_id    BIGINT;
  v_unit_price     NUMERIC;
  v_existing_camp  RECORD;
BEGIN
  -- 1. role check
  IF v_role NOT IN ('owner','admin','hq_manager','assistant') THEN
    RAISE EXCEPTION 'permission denied: role % cannot schedule candidate', v_role;
  END IF;

  -- 2. input validation
  IF TRIM(COALESCE(p_product_name, '')) = '' THEN
    RAISE EXCEPTION 'product_name must not be blank';
  END IF;

  IF p_scheduled_date IS NULL THEN
    RAISE EXCEPTION 'scheduled_date must not be null';
  END IF;

  -- 3. 鎖 candidate row 防並行雙建
  SELECT id, owner_action, adopted_product_id, adopted_sale_price, raw_text
    INTO v_cand
    FROM community_product_candidates
   WHERE id = p_candidate_id
     AND tenant_id = v_tenant
     FOR UPDATE;

  IF v_cand.id IS NULL THEN
    RAISE EXCEPTION 'candidate % not found or cross-tenant', p_candidate_id;
  END IF;

  -- 4. idempotent：已有 adopted_product_id → 找既有 campaign 回傳
  IF v_cand.adopted_product_id IS NOT NULL THEN
    SELECT c.id AS campaign_id, c.campaign_no, p.product_code,
           (SELECT id FROM skus WHERE product_id = v_cand.adopted_product_id
              AND tenant_id = v_tenant ORDER BY id LIMIT 1) AS sku_id
      INTO v_existing_camp
      FROM products p
      LEFT JOIN skus s ON s.product_id = p.id AND s.tenant_id = v_tenant
      LEFT JOIN campaign_items ci ON ci.sku_id = s.id AND ci.tenant_id = v_tenant
      LEFT JOIN group_buy_campaigns c ON c.id = ci.campaign_id AND c.tenant_id = v_tenant
     WHERE p.id = v_cand.adopted_product_id
       AND p.tenant_id = v_tenant
     ORDER BY c.created_at ASC NULLS LAST
     LIMIT 1;

    -- 若 product 存在但無 campaign（例如舊 rpc_adopt_candidate 採用過）→ 補建 campaign
    IF v_existing_camp.campaign_id IS NULL THEN
      v_product_id  := v_cand.adopted_product_id;
      v_sku_id      := v_existing_camp.sku_id;
      v_product_code:= v_existing_camp.product_code;
      -- 跳到 step 7 建 campaign（不用重建 product/sku）
    ELSE
      RETURN jsonb_build_object(
        'product_id',         v_cand.adopted_product_id,
        'product_code',       v_existing_camp.product_code,
        'sku_id',             v_existing_camp.sku_id,
        'campaign_id',        v_existing_camp.campaign_id,
        'campaign_no',        v_existing_camp.campaign_no,
        'already_scheduled',  TRUE
      );
    END IF;
  ELSE
    -- 5. 建 product (status='draft')
    v_product_code := public.rpc_next_product_code();

    v_product_id := public.rpc_upsert_product(
      p_id           := NULL,
      p_product_code := v_product_code,
      p_name         := TRIM(p_product_name),
      p_short_name   := NULL,
      p_brand_id     := NULL,
      p_category_id  := NULL,
      p_description  := v_cand.raw_text,
      p_status       := 'draft',
      p_reason       := 'schedule candidate #' || p_candidate_id::TEXT
    );

    -- 6. 建 sku (status='draft')
    v_sku_code := public.rpc_next_sku_code(v_product_id);

    v_sku_id := public.rpc_upsert_sku(
      p_id           := NULL,
      p_product_id   := v_product_id,
      p_sku_code     := v_sku_code,
      p_variant_name := NULL,
      p_spec         := '{}'::jsonb,
      p_base_unit    := NULL,
      p_weight_g     := NULL,
      p_tax_rate     := NULL,
      p_status       := 'draft',
      p_reason       := 'schedule candidate #' || p_candidate_id::TEXT
    );

    -- 6.1 若 candidate 已補 adopted_sale_price → 預填零售價
    IF v_cand.adopted_sale_price IS NOT NULL THEN
      PERFORM public.rpc_set_retail_price(
        v_sku_id,
        v_cand.adopted_sale_price,
        NOW(),
        'schedule candidate #' || p_candidate_id::TEXT
      );
    END IF;
  END IF;

  -- 7. 建 campaign (status='draft')
  -- campaign_no = GB{YYYYMMDD}-C{padded candidate_id} 保證 per-candidate 唯一
  v_campaign_no := 'GB' || to_char(p_scheduled_date, 'YYYYMMDD')
                 || '-C' || lpad(p_candidate_id::TEXT, 6, '0');

  v_campaign_id := public.rpc_upsert_campaign(
    p_id              := NULL,
    p_campaign_no     := v_campaign_no,
    p_name            := TRIM(p_product_name),
    p_description     := v_cand.raw_text,
    p_cover_image_url := NULL,
    p_status          := 'draft',
    p_close_type      := 'regular',
    p_start_at        := p_scheduled_date::TIMESTAMPTZ,
    p_end_at          := NULL,
    p_pickup_deadline := NULL,
    p_pickup_days     := NULL,
    p_total_cap_qty   := NULL,
    p_notes           := 'schedule candidate #' || p_candidate_id::TEXT
  );

  -- 8. 建 campaign_items (campaign ↔ sku)
  -- unit_price 預填 candidate.adopted_sale_price，否則 0；後續編輯頁可改
  v_unit_price := COALESCE(v_cand.adopted_sale_price, 0);

  PERFORM public.rpc_upsert_campaign_item(
    p_id          := NULL,
    p_campaign_id := v_campaign_id,
    p_sku_id      := v_sku_id,
    p_unit_price  := v_unit_price,
    p_cap_qty     := NULL,
    p_sort_order  := 0,
    p_notes       := NULL
  );

  -- 9. 標 candidate scheduled
  UPDATE community_product_candidates
     SET adopted_product_id = v_product_id,
         owner_action       = 'scheduled',
         scheduled_open_at  = p_scheduled_date,
         scheduled_by       = v_user,
         scheduled_at       = NOW(),
         updated_at         = NOW(),
         updated_by         = v_user
   WHERE id = p_candidate_id
     AND tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'product_id',         v_product_id,
    'product_code',       v_product_code,
    'sku_id',             v_sku_id,
    'campaign_id',        v_campaign_id,
    'campaign_no',        v_campaign_no,
    'already_scheduled',  FALSE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_schedule_candidate(BIGINT, DATE, TEXT)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_schedule_candidate(BIGINT, DATE, TEXT) IS
  'Schedule a candidate: creates draft product + draft sku + draft campaign + campaign_items, optionally pre-populates retail price from candidate.adopted_sale_price. Idempotent on re-call. Replaces the manual rpc_adopt_candidate flow.';

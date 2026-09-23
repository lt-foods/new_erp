-- ============================================================
-- PR draft store additions
--
-- Purpose:
--   On a draft purchase request, add extra demand for one existing PR item to
--   one or more pickup stores, then sync the PR item/source-campaign quantity.
--
-- Safety:
--   * Only draft PR items that have not been split to PO can be changed.
--   * This does not call the close-date/campaign PR creation RPCs.
--   * Remaining quantity is calculated by the existing readonly helper
--     _pr_campaign_sku_remaining_rows; the delta formula is not copied here.
--   * Write order is store demand -> source-campaign detail -> PR item qty.
--   * Pending orders are confirmed only after every active item on that order
--     is covered by PR quantity; never call the broad whole-campaign lock helper.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.purchase_request_store_additions (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  pr_id          BIGINT REFERENCES public.purchase_requests(id) ON DELETE SET NULL,
  pr_item_id     BIGINT REFERENCES public.purchase_request_items(id) ON DELETE SET NULL,
  campaign_id    BIGINT NOT NULL REFERENCES public.group_buy_campaigns(id),
  store_id       BIGINT NOT NULL REFERENCES public.stores(id),
  order_id       BIGINT REFERENCES public.customer_orders(id) ON DELETE SET NULL,
  order_item_id  BIGINT REFERENCES public.customer_order_items(id) ON DELETE SET NULL,
  sku_id         BIGINT NOT NULL REFERENCES public.skus(id),
  qty_added      NUMERIC(18,3) NOT NULL CHECK (qty_added > 0),
  request_key    UUID NOT NULL,
  pr_delta_qty   NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (pr_delta_qty >= 0),
  pr_qty_after   NUMERIC(18,3),
  created_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  cancelled_at   TIMESTAMPTZ,
  cancelled_by   UUID,
  cancel_reason  TEXT
);

ALTER TABLE public.purchase_request_store_additions
  ADD COLUMN IF NOT EXISTS request_key UUID,
  ADD COLUMN IF NOT EXISTS pr_delta_qty NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (pr_delta_qty >= 0),
  ADD COLUMN IF NOT EXISTS pr_qty_after NUMERIC(18,3);

UPDATE public.purchase_request_store_additions
   SET request_key = gen_random_uuid()
 WHERE request_key IS NULL;

ALTER TABLE public.purchase_request_store_additions
  ALTER COLUMN request_key SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_pr_store_additions_pr_item
  ON public.purchase_request_store_additions (tenant_id, pr_item_id);

CREATE INDEX IF NOT EXISTS idx_pr_store_additions_campaign_store
  ON public.purchase_request_store_additions (tenant_id, campaign_id, store_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pr_store_additions_request_store
  ON public.purchase_request_store_additions (tenant_id, request_key, store_id);

ALTER TABLE public.purchase_request_store_additions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auth_read_pr_store_additions ON public.purchase_request_store_additions;
CREATE POLICY auth_read_pr_store_additions ON public.purchase_request_store_additions
  FOR SELECT USING (tenant_id = public._current_tenant_id());

DROP POLICY IF EXISTS auth_write_pr_store_additions ON public.purchase_request_store_additions;

REVOKE ALL ON public.purchase_request_store_additions FROM authenticated;
GRANT SELECT ON public.purchase_request_store_additions TO authenticated;

COMMENT ON TABLE public.purchase_request_store_additions IS
  '請購單草稿頁的分店加單紀錄。第一版只新增，不提供修改/刪除。';

COMMENT ON COLUMN public.purchase_request_store_additions.qty_added IS
  '本次替該分店新增的原團需求數量；請購單實際補進量另由 _pr_campaign_sku_remaining_rows 計算。';

COMMENT ON COLUMN public.purchase_request_store_additions.request_key IS
  '前端每次送出分店加單產生的 UUID。用來讓同一包重送不會重複加單。';

DROP FUNCTION IF EXISTS public.rpc_add_pr_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID);

CREATE OR REPLACE FUNCTION public.rpc_add_pr_store_demands(
  p_pr_id        BIGINT,
  p_pr_item_id   BIGINT,
  p_campaign_id  BIGINT,
  p_additions    JSONB,
  p_operator     UUID,
  p_request_key  UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant                 UUID := public._current_tenant_id();
  v_role                   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_pr                     RECORD;
  v_campaign               RECORD;
  v_campaign_item_id        BIGINT;
  v_campaign_unit_price     NUMERIC;
  v_attr_count              INTEGER := 0;
  v_current_campaign_qty    NUMERIC := 0;
  v_store_added_qty         NUMERIC := 0;
  v_pr_delta_qty            NUMERIC := 0;
  v_demand_qty              NUMERIC := 0;
  v_already_qty             NUMERIC := 0;
  v_store_count             INTEGER := 0;
  v_order_count             INTEGER := 0;
  v_bad_count               INTEGER := 0;
  v_missing_store_ids       TEXT;
  v_member_id               BIGINT;
  v_channel_id              BIGINT;
  v_order_id                BIGINT;
  v_order_item_id           BIGINT;
  v_order_status            TEXT;
  v_pending_order_nos        TEXT;
  v_seq                     INTEGER;
  v_order_no                TEXT;
  v_existing                RECORD;
  r                         RECORD;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  IF v_role IN ('store_manager','store_staff') THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  IF v_role NOT IN ('owner','admin','hq_manager','purchaser','assistant','') THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;

  IF p_operator IS NULL THEN
    RAISE EXCEPTION 'operator is required';
  END IF;

  IF auth.uid() IS NOT NULL AND p_operator <> auth.uid() THEN
    RAISE EXCEPTION 'operator must match current user';
  END IF;

  IF p_request_key IS NULL THEN
    RAISE EXCEPTION 'request key is required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('pr_store_add:' || p_request_key::TEXT));

  SELECT
      pr_id,
      pr_item_id,
      campaign_id,
      created_by,
      COUNT(*) AS store_count,
      COALESCE(SUM(qty_added), 0) AS store_added_qty,
      COALESCE(MAX(pr_delta_qty), 0) AS pr_delta_qty,
      MAX(pr_qty_after) AS pr_qty_after
    INTO v_existing
    FROM public.purchase_request_store_additions
   WHERE tenant_id = v_tenant
     AND request_key = p_request_key
   GROUP BY pr_id, pr_item_id, campaign_id, created_by;

  IF FOUND THEN
    IF v_existing.pr_id <> p_pr_id
       OR v_existing.pr_item_id <> p_pr_item_id
       OR v_existing.campaign_id <> p_campaign_id
       OR v_existing.created_by <> p_operator THEN
      RAISE EXCEPTION 'request key already used by another store-addition request';
    END IF;

    RETURN jsonb_build_object(
      'pr_id', p_pr_id,
      'pr_item_id', p_pr_item_id,
      'campaign_id', p_campaign_id,
      'request_key', p_request_key,
      'store_count', v_existing.store_count,
      'store_added_qty', v_existing.store_added_qty,
      'pr_delta_qty', v_existing.pr_delta_qty,
      'new_pr_qty', v_existing.pr_qty_after,
      'idempotent', TRUE
    );
  END IF;

  IF p_additions IS NULL OR jsonb_typeof(p_additions) <> 'array' OR jsonb_array_length(p_additions) = 0 THEN
    RAISE EXCEPTION '請至少選一間分店與數量';
  END IF;

  SELECT
      pr.id AS pr_id,
      pr.pr_no,
      pr.tenant_id,
      pr.status AS pr_status,
      pr.total_amount,
      pri.id AS pr_item_id,
      pri.sku_id,
      pri.qty_requested,
      pri.unit_cost,
      pri.source_campaign_id,
      pri.po_item_id
    INTO v_pr
    FROM public.purchase_requests pr
    JOIN public.purchase_request_items pri
      ON pri.pr_id = pr.id
   WHERE pr.id = p_pr_id
     AND pri.id = p_pr_item_id
     AND pr.tenant_id = v_tenant
   FOR UPDATE OF pr, pri;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到這張請購單品項';
  END IF;

  IF v_pr.pr_status <> 'draft' THEN
    RAISE EXCEPTION '只有草稿請購單可以分店加單，目前狀態=%', v_pr.pr_status;
  END IF;

  IF v_pr.po_item_id IS NOT NULL THEN
    RAISE EXCEPTION '此品項已經建立採購單，不能在草稿頁追加分店需求';
  END IF;

  SELECT id, campaign_no, name, status
    INTO v_campaign
    FROM public.group_buy_campaigns
   WHERE id = p_campaign_id
     AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到原團 %', p_campaign_id;
  END IF;

  IF v_campaign.status NOT IN ('closed','locked') THEN
    RAISE EXCEPTION '只有已結單/已鎖定的原團可以從請購單追加，目前狀態=%', v_campaign.status;
  END IF;

  SELECT ci.id, ci.unit_price
    INTO v_campaign_item_id, v_campaign_unit_price
    FROM public.campaign_items ci
   WHERE ci.tenant_id = v_tenant
     AND ci.campaign_id = p_campaign_id
     AND ci.sku_id = v_pr.sku_id;

  IF v_campaign_item_id IS NULL THEN
    RAISE EXCEPTION '此品項不屬於指定原團';
  END IF;

  SELECT COUNT(*)
    INTO v_attr_count
    FROM public.purchase_request_item_campaigns
   WHERE pr_item_id = p_pr_item_id;

  IF v_attr_count > 0 THEN
    SELECT qty_requested
      INTO v_current_campaign_qty
      FROM public.purchase_request_item_campaigns
     WHERE pr_item_id = p_pr_item_id
       AND campaign_id = p_campaign_id
       AND tenant_id = v_tenant;

    IF v_current_campaign_qty IS NULL THEN
      RAISE EXCEPTION '這個原團沒有綁在此請購品項上，請選正確原團';
    END IF;
  ELSE
    IF v_pr.source_campaign_id IS NULL THEN
      RAISE EXCEPTION '此品項缺少原團明細，不能用分店加單';
    END IF;
    IF v_pr.source_campaign_id <> p_campaign_id THEN
      RAISE EXCEPTION '此品項的原團不符，不能用分店加單';
    END IF;
    v_current_campaign_qty := v_pr.qty_requested;
  END IF;

  DROP TABLE IF EXISTS _pr_store_add_raw;
  CREATE TEMP TABLE _pr_store_add_raw ON COMMIT DROP AS
  SELECT
    x.store_id::BIGINT AS store_id,
    x.qty::NUMERIC AS qty
  FROM jsonb_to_recordset(p_additions) AS x(store_id BIGINT, qty NUMERIC);

  SELECT COUNT(*)
    INTO v_bad_count
    FROM _pr_store_add_raw
   WHERE store_id IS NULL
      OR qty IS NULL
      OR qty <= 0;

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION '分店加單數量必須大於 0';
  END IF;

  DROP TABLE IF EXISTS _pr_store_add_input;
  CREATE TEMP TABLE _pr_store_add_input ON COMMIT DROP AS
  SELECT store_id, SUM(qty)::NUMERIC(18,3) AS qty
    FROM _pr_store_add_raw
   GROUP BY store_id;

  SELECT COUNT(*), COALESCE(SUM(qty), 0)
    INTO v_store_count, v_store_added_qty
    FROM _pr_store_add_input;

  SELECT string_agg(i.store_id::TEXT, ',')
    INTO v_missing_store_ids
    FROM _pr_store_add_input i
    LEFT JOIN public.stores s
      ON s.id = i.store_id
     AND s.tenant_id = v_tenant
     AND s.is_active = TRUE
     AND s.deleted_at IS NULL
     AND COALESCE(s.store_kind, 'branch') = 'branch'
   WHERE s.id IS NULL;

  IF v_missing_store_ids IS NOT NULL THEN
    RAISE EXCEPTION '有分店不存在、停用、已刪除或不是包子媽分店：%', v_missing_store_ids;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_campaign_id::TEXT), hashtext(v_pr.sku_id::TEXT));

  FOR r IN SELECT store_id, qty FROM _pr_store_add_input ORDER BY store_id
  LOOP
    v_member_id := public.rpc_get_or_create_store_member(r.store_id, p_operator);

    SELECT id
      INTO v_channel_id
      FROM public.line_channels
     WHERE tenant_id = v_tenant
       AND home_store_id = r.store_id
       AND is_active = TRUE
     ORDER BY id
     LIMIT 1;

    IF v_channel_id IS NULL THEN
      SELECT id
        INTO v_channel_id
        FROM public.line_channels
       WHERE tenant_id = v_tenant
         AND is_active = TRUE
       ORDER BY id
       LIMIT 1;
    END IF;

    IF v_channel_id IS NULL THEN
      RAISE EXCEPTION '此公司沒有可用的 LINE 頻道，不能建立店內單';
    END IF;

    SELECT id, status
      INTO v_order_id, v_order_status
      FROM public.customer_orders
     WHERE tenant_id = v_tenant
       AND campaign_id = p_campaign_id
       AND channel_id = v_channel_id
       AND member_id = v_member_id
       AND order_kind = 'normal'
       AND status NOT IN ('transferred_out','expired','cancelled')
       AND aid_board_id IS NULL
       AND order_no NOT LIKE 'SP-%'
       AND order_no NOT LIKE 'WS-%'
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF v_order_id IS NULL THEN
      SELECT COUNT(*) + 1
        INTO v_seq
        FROM public.customer_orders
       WHERE tenant_id = v_tenant
         AND campaign_id = p_campaign_id;

      LOOP
        v_order_no := v_campaign.campaign_no || '-INT' || lpad(v_seq::TEXT, 4, '0');

        BEGIN
          INSERT INTO public.customer_orders (
            tenant_id, order_no, campaign_id, channel_id, member_id,
            pickup_store_id, status, confirmed_at, order_kind, notes,
            created_by, updated_by
          ) VALUES (
            v_tenant, v_order_no, p_campaign_id, v_channel_id, v_member_id,
            r.store_id, 'confirmed', NOW(), 'normal',
            format('【請購單草稿分店加單】%s', v_pr.pr_no),
            p_operator, p_operator
          )
          RETURNING id INTO v_order_id;

          v_order_count := v_order_count + 1;
          EXIT;
        EXCEPTION WHEN unique_violation THEN
          v_seq := v_seq + 1;
        END;
      END LOOP;
    ELSE
      IF v_order_status NOT IN ('pending','confirmed') THEN
        RAISE EXCEPTION '此分店在原團的店內單已進入後段狀態，不能從請購單草稿追加：order_id=%, status=%',
          v_order_id, v_order_status;
      END IF;

    END IF;

    INSERT INTO public.customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, notes, created_by, updated_by
    ) VALUES (
      v_tenant, v_order_id, v_campaign_item_id, v_pr.sku_id, r.qty, v_campaign_unit_price,
      'pending', 'store_internal', format('請購單 %s 草稿分店加單', v_pr.pr_no),
      p_operator, p_operator
    )
    RETURNING id INTO v_order_item_id;

    INSERT INTO public.purchase_request_store_additions (
      tenant_id, pr_id, pr_item_id, campaign_id, store_id,
      order_id, order_item_id, sku_id, qty_added, request_key, created_by
    ) VALUES (
      v_tenant, p_pr_id, p_pr_item_id, p_campaign_id, r.store_id,
      v_order_id, v_order_item_id, v_pr.sku_id, r.qty, p_request_key, p_operator
    );
  END LOOP;

  SELECT d.delta_qty, d.demand_qty, d.already_qty
    INTO v_pr_delta_qty, v_demand_qty, v_already_qty
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id]) d
   WHERE d.campaign_id = p_campaign_id
     AND d.sku_id = v_pr.sku_id;

  v_pr_delta_qty := COALESCE(v_pr_delta_qty, 0);
  v_demand_qty := COALESCE(v_demand_qty, 0);
  v_already_qty := COALESCE(v_already_qty, 0);

  IF v_pr_delta_qty > 0 THEN
    INSERT INTO public.purchase_request_item_campaigns (
      pr_item_id, campaign_id, tenant_id, qty_requested
    ) VALUES (
      p_pr_item_id, p_campaign_id, v_tenant, v_current_campaign_qty + v_pr_delta_qty
    )
    ON CONFLICT (pr_item_id, campaign_id) DO UPDATE
       SET qty_requested = EXCLUDED.qty_requested;

    UPDATE public.purchase_request_items
       SET qty_requested = qty_requested + v_pr_delta_qty,
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = p_pr_item_id;

    INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
    VALUES (p_pr_id, p_campaign_id, v_tenant)
    ON CONFLICT (pr_id, campaign_id) DO NOTHING;

    UPDATE public.purchase_requests pr
       SET total_amount = COALESCE((
             SELECT SUM(pri.line_subtotal)
               FROM public.purchase_request_items pri
              WHERE pri.pr_id = p_pr_id
           ), 0),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE pr.id = p_pr_id;

  END IF;

  DROP TABLE IF EXISTS _pr_store_add_remaining;
  CREATE TEMP TABLE _pr_store_add_remaining ON COMMIT DROP AS
  SELECT d.sku_id, GREATEST(d.delta_qty, 0)::NUMERIC AS delta_qty
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id]) d
   WHERE d.campaign_id = p_campaign_id
     AND d.delta_qty > 0;

  WITH candidate_orders AS (
    SELECT DISTINCT co.id
      FROM public.customer_orders co
      JOIN public.customer_order_items coi
        ON coi.order_id = co.id
     WHERE co.tenant_id = v_tenant
       AND co.campaign_id = p_campaign_id
       AND co.status = 'pending'
       AND coi.sku_id = v_pr.sku_id
       AND coi.status NOT IN ('cancelled','expired')
  ),
  safe_orders AS (
    SELECT co.id
      FROM public.customer_orders co
      JOIN candidate_orders cand
        ON cand.id = co.id
     WHERE NOT EXISTS (
       SELECT 1
         FROM public.customer_order_items oi
         JOIN _pr_store_add_remaining rem
           ON rem.sku_id = oi.sku_id
          AND rem.delta_qty > 0
        WHERE oi.order_id = co.id
          AND oi.status NOT IN ('cancelled','expired')
     )
  ),
  updated_orders AS (
    UPDATE public.customer_orders co
       SET status = 'confirmed',
           confirmed_at = COALESCE(co.confirmed_at, NOW()),
           updated_by = p_operator,
           updated_at = NOW()
      FROM safe_orders so
     WHERE co.id = so.id
       AND co.status = 'pending'
    RETURNING co.id
  )
  INSERT INTO public.customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  )
  SELECT
    v_tenant, id, 'order', NULL, 'status',
    to_jsonb('pending'::TEXT), to_jsonb('confirmed'::TEXT),
    format('auto-confirmed by PR store addition #%s', p_pr_id),
    p_operator
  FROM updated_orders;

  SELECT string_agg(DISTINCT co.order_no, ', ' ORDER BY co.order_no)
    INTO v_pending_order_nos
    FROM public.customer_orders co
    JOIN public.customer_order_items coi
      ON coi.order_id = co.id
   WHERE co.tenant_id = v_tenant
     AND co.campaign_id = p_campaign_id
     AND co.status = 'pending'
     AND coi.sku_id = v_pr.sku_id
     AND coi.status NOT IN ('cancelled','expired');

  IF v_pending_order_nos IS NOT NULL THEN
    RAISE EXCEPTION '原團仍有同品項的未確認店內單，且同單其他品項還沒補進請購；請先處理舊待確認店內單或對原團補請購後再加單：%',
      v_pending_order_nos;
  END IF;

  UPDATE public.purchase_request_store_additions
     SET pr_delta_qty = v_pr_delta_qty,
         pr_qty_after = v_pr.qty_requested + v_pr_delta_qty
   WHERE tenant_id = v_tenant
     AND request_key = p_request_key;

  RETURN jsonb_build_object(
    'pr_id', p_pr_id,
    'pr_item_id', p_pr_item_id,
    'campaign_id', p_campaign_id,
    'request_key', p_request_key,
    'store_count', v_store_count,
    'store_added_qty', v_store_added_qty,
    'pr_delta_qty', v_pr_delta_qty,
    'demand_qty', v_demand_qty,
    'already_qty_before_sync', v_already_qty,
    'new_pr_qty', v_pr.qty_requested + v_pr_delta_qty,
    'created_order_count', v_order_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_add_pr_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_add_pr_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_add_pr_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) IS
  '請購單草稿頁分店加單：建立 confirmed 店內單，並用 _pr_campaign_sku_remaining_rows 補 PR item 差額。';

NOTIFY pgrst, 'reload schema';

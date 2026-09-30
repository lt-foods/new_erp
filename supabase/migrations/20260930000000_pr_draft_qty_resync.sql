-- 2026-09-30: 客單需求變更先記待同步；請購草稿只在人工同步／送審時重算。
-- 不回填舊資料、不在客單 trigger 內鎖或修改請購單。
-- 部署規則：只可由 migration runner 依版本執行一次，不可直接在 SQL Editor 重貼。
-- runner 應以單一交易執行本檔；任一句失敗就回滾整檔，不留半套函式／trigger。
-- rollback 順序：先下架新前端，再以「新的 append-only migration」重建舊 RPC/helper，
-- 然後移除 dirty triggers/新函式/policy/table。若已有 qty=0 或 sync audit，先盤點，不得直接還原 >0 或刪 audit。

CREATE TABLE public.purchase_request_qty_dirty (
  tenant_id      UUID NOT NULL,
  campaign_id    BIGINT NOT NULL REFERENCES public.group_buy_campaigns(id) ON DELETE CASCADE,
  sku_id         BIGINT NOT NULL REFERENCES public.skus(id) ON DELETE CASCADE,
  dirty_since    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reason         TEXT NOT NULL,
  last_error     TEXT,
  revision       BIGINT NOT NULL DEFAULT 1,
  PRIMARY KEY (tenant_id, campaign_id, sku_id)
);

ALTER TABLE public.purchase_request_qty_dirty ENABLE ROW LEVEL SECURITY;

CREATE POLICY purchase_request_qty_dirty_read
  ON public.purchase_request_qty_dirty
  FOR SELECT
  USING (tenant_id = public._current_tenant_id());

GRANT SELECT ON public.purchase_request_qty_dirty TO authenticated;

-- 沒有現成可容納 PR 數量變更的共用 audit table；用最小 append-only 紀錄保留舊/新量。
CREATE TABLE public.purchase_request_qty_sync_log (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  pr_id           BIGINT NOT NULL,
  pr_item_id      BIGINT NOT NULL,
  campaign_id     BIGINT NOT NULL,
  sku_id          BIGINT NOT NULL,
  old_qty         NUMERIC(18,3) NOT NULL,
  new_qty         NUMERIC(18,3) NOT NULL,
  changed_by      UUID,
  changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_pr_qty_sync_log_pr
  ON public.purchase_request_qty_sync_log (tenant_id, pr_id, changed_at DESC);

ALTER TABLE public.purchase_request_qty_sync_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY purchase_request_qty_sync_log_read
  ON public.purchase_request_qty_sync_log
  FOR SELECT
  USING (tenant_id = public._current_tenant_id());

GRANT SELECT ON public.purchase_request_qty_sync_log TO authenticated;

-- 數量降到 0 仍保留來源團明細與分店追加紀錄的 pr_item_id 追溯。
ALTER TABLE public.purchase_request_item_campaigns
  DROP CONSTRAINT IF EXISTS purchase_request_item_campaigns_qty_requested_check;
ALTER TABLE public.purchase_request_item_campaigns
  ADD CONSTRAINT purchase_request_item_campaigns_qty_requested_check
  CHECK (qty_requested >= 0);

ALTER TABLE public.purchase_request_items
  DROP CONSTRAINT IF EXISTS purchase_request_items_qty_requested_check;
ALTER TABLE public.purchase_request_items
  ADD CONSTRAINT purchase_request_items_qty_requested_check
  CHECK (qty_requested >= 0);

-- ---------------------------------------------------------------------------
-- 客單變動只批次記 dirty；任何記號錯誤都吞掉，不能回滾取消／斷貨。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pr_mark_dirty_from_customer_orders()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.purchase_request_qty_dirty (
    tenant_id, campaign_id, sku_id, dirty_since, last_seen_at, reason, last_error
  )
  WITH changed AS (
    SELECT
      o.id,
      o.tenant_id AS old_tenant_id,
      o.campaign_id AS old_campaign_id,
      n.tenant_id AS new_tenant_id,
      n.campaign_id AS new_campaign_id
    FROM old_rows o
    JOIN new_rows n USING (id)
    WHERE (o.status IN ('cancelled','expired','transferred_out'))
          IS DISTINCT FROM
          (n.status IN ('cancelled','expired','transferred_out'))
       OR o.tenant_id IS DISTINCT FROM n.tenant_id
       OR o.campaign_id IS DISTINCT FROM n.campaign_id
  ), affected AS (
    SELECT c.old_tenant_id AS tenant_id, c.old_campaign_id AS campaign_id, coi.sku_id
      FROM changed c
      JOIN public.customer_order_items coi ON coi.order_id = c.id
    UNION
    SELECT c.new_tenant_id, c.new_campaign_id, coi.sku_id
      FROM changed c
      JOIN public.customer_order_items coi ON coi.order_id = c.id
  )
  SELECT tenant_id, campaign_id, sku_id, NOW(), NOW(), 'customer_orders UPDATE', NULL
    FROM affected
   WHERE tenant_id IS NOT NULL AND campaign_id IS NOT NULL AND sku_id IS NOT NULL
  ON CONFLICT (tenant_id, campaign_id, sku_id) DO UPDATE
    SET last_seen_at = EXCLUDED.last_seen_at,
        reason = EXCLUDED.reason,
        last_error = NULL,
        revision = public.purchase_request_qty_dirty.revision + 1;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '請購待同步記號失敗（customer_orders UPDATE）：%', SQLERRM;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public._pr_mark_dirty_from_customer_order_items()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.purchase_request_qty_dirty (
      tenant_id, campaign_id, sku_id, dirty_since, last_seen_at, reason, last_error
    )
    SELECT DISTINCT n.tenant_id, ci.campaign_id, n.sku_id,
           NOW(), NOW(), 'customer_order_items INSERT', NULL
      FROM new_rows n
      JOIN public.campaign_items ci ON ci.id = n.campaign_item_id
     WHERE n.tenant_id IS NOT NULL AND ci.campaign_id IS NOT NULL AND n.sku_id IS NOT NULL
    ON CONFLICT (tenant_id, campaign_id, sku_id) DO UPDATE
      SET last_seen_at = EXCLUDED.last_seen_at,
          reason = EXCLUDED.reason,
          last_error = NULL,
          revision = public.purchase_request_qty_dirty.revision + 1;

  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.purchase_request_qty_dirty (
      tenant_id, campaign_id, sku_id, dirty_since, last_seen_at, reason, last_error
    )
    SELECT DISTINCT o.tenant_id, ci.campaign_id, o.sku_id,
           NOW(), NOW(), 'customer_order_items DELETE', NULL
      FROM old_rows o
      JOIN public.campaign_items ci ON ci.id = o.campaign_item_id
     WHERE o.tenant_id IS NOT NULL AND ci.campaign_id IS NOT NULL AND o.sku_id IS NOT NULL
    ON CONFLICT (tenant_id, campaign_id, sku_id) DO UPDATE
      SET last_seen_at = EXCLUDED.last_seen_at,
          reason = EXCLUDED.reason,
          last_error = NULL,
          revision = public.purchase_request_qty_dirty.revision + 1;

  ELSE
    INSERT INTO public.purchase_request_qty_dirty (
      tenant_id, campaign_id, sku_id, dirty_since, last_seen_at, reason, last_error
    )
    WITH changed AS (
      SELECT
        o.tenant_id AS old_tenant_id,
        o.campaign_item_id AS old_campaign_item_id,
        o.sku_id AS old_sku_id,
        n.tenant_id AS new_tenant_id,
        n.campaign_item_id AS new_campaign_item_id,
        n.sku_id AS new_sku_id
        FROM old_rows o
        JOIN new_rows n USING (id)
       WHERE o.tenant_id IS DISTINCT FROM n.tenant_id
          OR o.order_id IS DISTINCT FROM n.order_id
          OR o.campaign_item_id IS DISTINCT FROM n.campaign_item_id
          OR o.sku_id IS DISTINCT FROM n.sku_id
          OR o.qty IS DISTINCT FROM n.qty
          OR (o.status IN ('cancelled','expired'))
             IS DISTINCT FROM
             (n.status IN ('cancelled','expired'))
    ), affected AS (
      SELECT old_tenant_id AS tenant_id, ci.campaign_id, old_sku_id AS sku_id
        FROM changed c
        JOIN public.campaign_items ci ON ci.id = c.old_campaign_item_id
      UNION
      SELECT new_tenant_id, ci.campaign_id, new_sku_id
        FROM changed c
        JOIN public.campaign_items ci ON ci.id = c.new_campaign_item_id
    )
    SELECT tenant_id, campaign_id, sku_id, NOW(), NOW(), 'customer_order_items UPDATE', NULL
      FROM affected
     WHERE tenant_id IS NOT NULL AND campaign_id IS NOT NULL AND sku_id IS NOT NULL
    ON CONFLICT (tenant_id, campaign_id, sku_id) DO UPDATE
      SET last_seen_at = EXCLUDED.last_seen_at,
          reason = EXCLUDED.reason,
          last_error = NULL,
          revision = public.purchase_request_qty_dirty.revision + 1;
  END IF;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '請購待同步記號失敗（customer_order_items %）：%', TG_OP, SQLERRM;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_pr_qty_dirty_orders_update ON public.customer_orders;
CREATE TRIGGER trg_pr_qty_dirty_orders_update
AFTER UPDATE ON public.customer_orders
REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
FOR EACH STATEMENT
EXECUTE FUNCTION public._pr_mark_dirty_from_customer_orders();

DROP TRIGGER IF EXISTS trg_pr_qty_dirty_items_insert ON public.customer_order_items;
CREATE TRIGGER trg_pr_qty_dirty_items_insert
AFTER INSERT ON public.customer_order_items
REFERENCING NEW TABLE AS new_rows
FOR EACH STATEMENT
EXECUTE FUNCTION public._pr_mark_dirty_from_customer_order_items();

DROP TRIGGER IF EXISTS trg_pr_qty_dirty_items_update ON public.customer_order_items;
CREATE TRIGGER trg_pr_qty_dirty_items_update
AFTER UPDATE ON public.customer_order_items
REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
FOR EACH STATEMENT
EXECUTE FUNCTION public._pr_mark_dirty_from_customer_order_items();

DROP TRIGGER IF EXISTS trg_pr_qty_dirty_items_delete ON public.customer_order_items;
CREATE TRIGGER trg_pr_qty_dirty_items_delete
AFTER DELETE ON public.customer_order_items
REFERENCING OLD TABLE AS old_rows
FOR EACH STATEMENT
EXECUTE FUNCTION public._pr_mark_dirty_from_customer_order_items();

REVOKE ALL ON FUNCTION public._pr_mark_dirty_from_customer_orders() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pr_mark_dirty_from_customer_order_items() FROM PUBLIC;

-- 現有 helper 原本只從「仍有需求」出發，需求歸零時沒有 row；改為需求或已請購任一存在
-- 都回傳。既有補差額呼叫仍用 delta_qty > 0，行為不變；本功能可看見負差額與 0 需求。
CREATE OR REPLACE FUNCTION public._pr_campaign_sku_remaining_rows(
  p_campaign_ids BIGINT[]
) RETURNS TABLE(
  campaign_id BIGINT,
  sku_id      BIGINT,
  demand_qty  NUMERIC,
  already_qty NUMERIC,
  delta_qty   NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH t AS (
    SELECT public._current_tenant_id() AS tid
  ),
  sel AS (
    SELECT DISTINCT unnest(p_campaign_ids) AS campaign_id
  ),
  demand AS (
    SELECT co.campaign_id, coi.sku_id, SUM(coi.qty) AS qty
      FROM sel
      JOIN public.customer_orders co ON co.campaign_id = sel.campaign_id
      JOIN public.customer_order_items coi ON coi.order_id = co.id
      CROSS JOIN t
     WHERE co.tenant_id = t.tid
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY co.campaign_id, coi.sku_id
  ),
  attributed AS (
    SELECT pric.campaign_id, pri.sku_id, SUM(pric.qty_requested) AS qty
      FROM public.purchase_request_item_campaigns pric
      JOIN public.purchase_request_items pri ON pri.id = pric.pr_item_id
      JOIN public.purchase_requests pr ON pr.id = pri.pr_id
      JOIN sel ON sel.campaign_id = pric.campaign_id
      CROSS JOIN t
     WHERE pr.tenant_id = t.tid
       AND pric.tenant_id = t.tid
       AND pr.status <> 'cancelled'
     GROUP BY pric.campaign_id, pri.sku_id
  ),
  direct_legacy AS (
    SELECT pri.source_campaign_id AS campaign_id, pri.sku_id, SUM(pri.qty_requested) AS qty
      FROM public.purchase_requests pr
      JOIN public.purchase_request_items pri ON pri.pr_id = pr.id
      JOIN sel ON sel.campaign_id = pri.source_campaign_id
      CROSS JOIN t
     WHERE pr.tenant_id = t.tid
       AND pr.status <> 'cancelled'
       AND pri.source_campaign_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM public.purchase_request_item_campaigns pric
          WHERE pric.pr_item_id = pri.id
       )
     GROUP BY pri.source_campaign_id, pri.sku_id
  ),
  already AS (
    SELECT x.campaign_id, x.sku_id, SUM(x.qty) AS qty
      FROM (
        SELECT * FROM attributed
        UNION ALL
        SELECT * FROM direct_legacy
      ) x
     GROUP BY x.campaign_id, x.sku_id
  ),
  keys AS (
    SELECT d.campaign_id, d.sku_id FROM demand d
    UNION
    SELECT a.campaign_id, a.sku_id FROM already a
  )
  SELECT k.campaign_id,
         k.sku_id,
         COALESCE(d.qty, 0) AS demand_qty,
         COALESCE(a.qty, 0) AS already_qty,
         COALESCE(d.qty, 0) - COALESCE(a.qty, 0) AS delta_qty
    FROM keys k
    LEFT JOIN demand d USING (campaign_id, sku_id)
    LEFT JOIN already a USING (campaign_id, sku_id);
$$;

REVOKE ALL ON FUNCTION public._pr_campaign_sku_remaining_rows(BIGINT[]) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 共用預覽：同一團+SKU 只能有一個「draft、未綁 PO」歸屬才可改。
-- target = 現在有效需求 - 其他不可修改的已請購量，最低為 0。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pr_qty_sync_preview(
  p_pr_id BIGINT
) RETURNS TABLE(
  campaign_id       BIGINT,
  campaign_label    TEXT,
  sku_id            BIGINT,
  sku_label         TEXT,
  pr_item_id        BIGINT,
  demand_qty        NUMERIC,
  already_qty       NUMERIC,
  current_qty       NUMERIC,
  target_qty        NUMERIC,
  delta_qty         NUMERIC,
  candidate_count   INTEGER,
  target_pr_id      BIGINT,
  target_pr_item_id BIGINT,
  action_code       TEXT,
  action_label      TEXT,
  is_dirty          BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH t AS (
    SELECT public._current_tenant_id() AS tid
  ),
  pr_campaigns AS (
    SELECT prc.campaign_id
      FROM public.purchase_request_campaigns prc
      JOIN public.purchase_requests pr ON pr.id = prc.pr_id
      CROSS JOIN t
     WHERE prc.pr_id = p_pr_id
       AND pr.tenant_id = t.tid
       AND prc.tenant_id = t.tid
    UNION
    SELECT pric.campaign_id
      FROM public.purchase_request_items pri
      JOIN public.purchase_request_item_campaigns pric ON pric.pr_item_id = pri.id
      JOIN public.purchase_requests pr ON pr.id = pri.pr_id
      CROSS JOIN t
     WHERE pri.pr_id = p_pr_id
       AND pr.tenant_id = t.tid
       AND pric.tenant_id = t.tid
    UNION
    SELECT pri.source_campaign_id
      FROM public.purchase_request_items pri
      JOIN public.purchase_requests pr ON pr.id = pri.pr_id
      CROSS JOIN t
     WHERE pri.pr_id = p_pr_id
       AND pr.tenant_id = t.tid
       AND pri.source_campaign_id IS NOT NULL
  ),
  remaining AS (
    SELECT r.*
      FROM public._pr_campaign_sku_remaining_rows(
        ARRAY(SELECT pc.campaign_id FROM pr_campaigns pc ORDER BY pc.campaign_id)
      ) r
  ),
  current_pairs AS (
    SELECT pric.campaign_id,
           pri.sku_id,
           MIN(pri.id) AS pr_item_id,
           SUM(pric.qty_requested) AS current_qty
      FROM public.purchase_requests pr
      JOIN public.purchase_request_items pri ON pri.pr_id = pr.id
      JOIN public.purchase_request_item_campaigns pric ON pric.pr_item_id = pri.id
      CROSS JOIN t
     WHERE pr.id = p_pr_id
       AND pr.tenant_id = t.tid
       AND pric.tenant_id = t.tid
      GROUP BY pric.campaign_id, pri.sku_id
  ),
  pairs AS (
    SELECT r.campaign_id,
           r.sku_id,
           cp.pr_item_id,
           COALESCE(cp.current_qty, 0) AS current_qty
      FROM remaining r
      LEFT JOIN current_pairs cp USING (campaign_id, sku_id)
  ),
  candidates AS (
    SELECT pric.campaign_id,
           pri.sku_id,
           pri.pr_id,
           pri.id AS pr_item_id,
           pric.qty_requested
      FROM pairs p
      JOIN public.purchase_request_item_campaigns pric
        ON pric.campaign_id = p.campaign_id
      JOIN public.purchase_request_items pri
        ON pri.id = pric.pr_item_id
       AND pri.sku_id = p.sku_id
       AND pri.po_item_id IS NULL
      JOIN public.purchase_requests pr
        ON pr.id = pri.pr_id
       AND pr.status = 'draft'
      CROSS JOIN t
     WHERE pr.tenant_id = t.tid
       AND pric.tenant_id = t.tid
  ),
  candidate_rollup AS (
    SELECT c.campaign_id,
           c.sku_id,
           COUNT(*)::INTEGER AS candidate_count,
           MIN(c.pr_id) AS target_pr_id,
           MIN(c.pr_item_id) AS target_pr_item_id,
           SUM(c.qty_requested) AS candidate_qty
      FROM candidates c
     GROUP BY c.campaign_id, c.sku_id
  ),
  plan AS (
    SELECT p.campaign_id,
           p.sku_id,
           p.pr_item_id,
           p.current_qty,
           COALESCE(r.demand_qty, 0) AS demand_qty,
           COALESCE(r.already_qty, 0) AS already_qty,
           COALESCE(c.candidate_count, 0) AS candidate_count,
           c.target_pr_id,
           c.target_pr_item_id,
           CASE WHEN COALESCE(c.candidate_count, 0) = 1 THEN
             GREATEST(
               COALESCE(r.demand_qty, 0)
                 - (COALESCE(r.already_qty, 0) - COALESCE(c.candidate_qty, 0)),
               0
             )
           END AS target_qty,
           COALESCE(r.demand_qty, 0) - COALESCE(r.already_qty, 0) AS delta_qty
      FROM pairs p
      LEFT JOIN remaining r USING (campaign_id, sku_id)
      LEFT JOIN candidate_rollup c USING (campaign_id, sku_id)
  )
  SELECT plan.campaign_id,
         COALESCE(NULLIF(gbc.campaign_no, ''), gbc.name, '#' || plan.campaign_id::TEXT),
         plan.sku_id,
         COALESCE(
           NULLIF(TRIM(COALESCE(s.product_name, '')
             || COALESCE(' / ' || NULLIF(s.variant_name, ''), '')), ''),
           s.sku_code,
           '品項#' || plan.sku_id::TEXT
         ),
         plan.pr_item_id,
         plan.demand_qty,
         plan.already_qty,
         plan.current_qty,
         plan.target_qty,
         plan.delta_qty,
         plan.candidate_count,
         plan.target_pr_id,
         plan.target_pr_item_id,
          CASE
            WHEN plan.candidate_count > 1 THEN 'ambiguous'
            WHEN plan.pr_item_id IS NULL AND plan.delta_qty <> 0 THEN 'missing_item'
            WHEN plan.candidate_count = 0 AND plan.delta_qty <> 0 THEN 'locked_mismatch'
           WHEN plan.candidate_count = 0 THEN 'locked_current'
           WHEN plan.target_pr_id <> p_pr_id THEN 'other_draft'
           WHEN plan.already_qty - plan.current_qty > plan.demand_qty THEN 'locked_overage'
           WHEN plan.target_qty IS DISTINCT FROM plan.current_qty THEN 'sync'
           ELSE 'current'
         END,
          CASE
            WHEN plan.candidate_count > 1 THEN '同團同商品有多張可改草稿，不能猜要改哪張'
            WHEN plan.pr_item_id IS NULL AND plan.delta_qty <> 0 THEN '這個團有新需求商品，本請購單沒有對應品項；請人工補齊後再同步'
            WHEN plan.candidate_count = 0 AND plan.delta_qty <> 0 THEN '已送審或已轉採購；請先退回草稿再同步'
           WHEN plan.candidate_count = 0 THEN '數量一致，且目前不可修改'
           WHEN plan.target_pr_id <> p_pr_id THEN '可修改的歸屬在另一張草稿，請人工確認'
           WHEN plan.already_qty - plan.current_qty > plan.demand_qty THEN '不可修改的既有請購已超過需求，請人工確認'
           WHEN plan.target_qty IS DISTINCT FROM plan.current_qty THEN '可同步最新開團數量'
           ELSE '已是最新數量'
         END,
         EXISTS (
           SELECT 1
             FROM public.purchase_request_qty_dirty d
            WHERE d.tenant_id = t.tid
              AND d.campaign_id = plan.campaign_id
              AND d.sku_id = plan.sku_id
         )
    FROM plan
    CROSS JOIN t
    LEFT JOIN public.group_buy_campaigns gbc ON gbc.id = plan.campaign_id
    LEFT JOIN public.skus s ON s.id = plan.sku_id
   ORDER BY 2, 4;
$$;

REVOKE ALL ON FUNCTION public._pr_qty_sync_preview(BIGINT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.rpc_preview_pr_qty_sync(
  p_pr_id BIGINT
) RETURNS TABLE(
  campaign_id       BIGINT,
  campaign_label    TEXT,
  sku_id            BIGINT,
  sku_label         TEXT,
  pr_item_id        BIGINT,
  demand_qty        NUMERIC,
  already_qty       NUMERIC,
  current_qty       NUMERIC,
  target_qty        NUMERIC,
  delta_qty         NUMERIC,
  candidate_count   INTEGER,
  target_pr_id      BIGINT,
  target_pr_item_id BIGINT,
  action_code       TEXT,
  action_label      TEXT,
  is_dirty          BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_tenant IS NULL OR v_role NOT IN ('owner','admin','hq_manager','hq_accountant','purchaser','assistant','') THEN
    RAISE EXCEPTION '權限不足，無法查看請購同步狀態';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.purchase_requests
     WHERE id = p_pr_id AND tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION '找不到這張請購單';
  END IF;

  RETURN QUERY SELECT * FROM public._pr_qty_sync_preview(p_pr_id);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_preview_pr_qty_sync(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_preview_pr_qty_sync(BIGINT) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_preview_pr_qty_sync(BIGINT) TO authenticated;

-- #995 lock order: campaign -> #982 advisory key -> PR/item.
ALTER FUNCTION public.rpc_add_pr_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID)
  RENAME TO _rpc_add_pr_store_demands_20260930_inner;

REVOKE ALL ON FUNCTION public._rpc_add_pr_store_demands_20260930_inner(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._rpc_add_pr_store_demands_20260930_inner(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION public._rpc_add_pr_store_demands_20260930_inner(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM authenticated;

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
  v_tenant UUID := public._current_tenant_id();
  v_sku_id BIGINT;
BEGIN
  SELECT pri.sku_id
    INTO v_sku_id
    FROM public.purchase_request_items pri
    JOIN public.purchase_requests pr ON pr.id = pri.pr_id
   WHERE pri.id = p_pr_item_id
     AND pri.pr_id = p_pr_id
     AND pr.tenant_id = v_tenant;

  IF v_sku_id IS NULL THEN
    RAISE EXCEPTION '找不到這張請購單品項';
  END IF;

  -- NO KEY UPDATE is compatible with partial's FK KEY SHARE and conflicts with PO FOR UPDATE.
  PERFORM 1
    FROM public.group_buy_campaigns gbc
   WHERE gbc.id = p_campaign_id
     AND gbc.tenant_id = v_tenant
   FOR NO KEY UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到原團 %', p_campaign_id;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext(p_campaign_id::TEXT),
    hashtext(v_sku_id::TEXT)
  );

  RETURN public._rpc_add_pr_store_demands_20260930_inner(
    p_pr_id, p_pr_item_id, p_campaign_id, p_additions, p_operator, p_request_key
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_add_pr_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_add_pr_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_add_pr_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public._pr_apply_qty_sync(
  p_pr_id    BIGINT,
  p_operator UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_pr            RECORD;
  v_dirty_seen    JSONB := '{}'::JSONB;
  v_synced_count  INTEGER := 0;
  v_blocked_count INTEGER := 0;
  v_error         TEXT;
  r               RECORD;
BEGIN
  IF v_tenant IS NULL OR v_role NOT IN ('owner','admin','hq_manager','purchaser','assistant','') THEN
    RAISE EXCEPTION '權限不足，無法同步請購數量';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;
  IF p_operator IS NULL OR (auth.uid() IS NOT NULL AND p_operator <> auth.uid()) THEN
    RAISE EXCEPTION '操作人員不符，無法同步請購數量';
  END IF;

  -- 所有可能異動的團+SKU 先依固定順序取 #982 同一把鎖，
  -- 再鎖 PR/item。#995 的外層 wrapper 也是同一順序，避免 item↔advisory 反向。
  FOR r IN
    SELECT q.campaign_id, q.sku_id
      FROM public._pr_qty_sync_preview(p_pr_id) q
     ORDER BY q.campaign_id, q.sku_id
  LOOP
    PERFORM pg_advisory_xact_lock(
      hashtext(r.campaign_id::TEXT),
      hashtext(r.sku_id::TEXT)
    );
  END LOOP;

  SELECT pr.id, pr.pr_no, pr.status
    INTO v_pr
    FROM public.purchase_requests pr
   WHERE pr.id = p_pr_id AND pr.tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到這張請購單';
  END IF;
  IF v_pr.status <> 'draft' THEN
    RAISE EXCEPTION '只有草稿請購單可以同步最新開團數量；請先退回草稿';
  END IF;

  -- advisory 已經取得，才鎖請購品項。
  PERFORM 1
    FROM public.purchase_request_items pri
   WHERE pri.pr_id = p_pr_id
   ORDER BY pri.id
   FOR UPDATE;

  -- 只記住同步開始時「已看見」的 dirty 版本；同期才 commit 的取消／加單不會被誤清。
  SELECT COALESCE(
           jsonb_object_agg(d.campaign_id::TEXT || ':' || d.sku_id::TEXT, d.revision),
           '{}'::JSONB
         )
    INTO v_dirty_seen
    FROM public.purchase_request_qty_dirty d
   WHERE d.tenant_id = v_tenant
      AND EXISTS (
        SELECT 1
          FROM public._pr_qty_sync_preview(p_pr_id) q
         WHERE q.campaign_id = d.campaign_id
           AND q.sku_id = d.sku_id
      );

  FOR r IN SELECT * FROM public._pr_qty_sync_preview(p_pr_id)
  LOOP
    v_error := NULL;
    IF r.candidate_count > 1 THEN
      v_error := '同團同商品有多張可改草稿，不能猜要改哪張';
    ELSIF r.pr_item_id IS NULL AND r.delta_qty <> 0 THEN
      v_error := '原請購單沒有這個新商品，不能自動猜要放哪一列';
    ELSIF r.candidate_count = 0 AND r.delta_qty <> 0 THEN
      v_error := '已送審或已轉採購，數量已變；請先退回草稿再同步';
    ELSIF r.candidate_count = 1 AND r.target_pr_id <> p_pr_id THEN
      v_error := '可修改的歸屬在另一張草稿，請人工確認';
    ELSIF r.candidate_count = 1 AND r.already_qty - r.current_qty > r.demand_qty THEN
      v_error := '不可修改的既有請購已超過需求，不能用草稿抵成負數';
    END IF;

    IF v_error IS NOT NULL THEN
      v_blocked_count := v_blocked_count + 1;
      INSERT INTO public.purchase_request_qty_dirty (
        tenant_id, campaign_id, sku_id, dirty_since, last_seen_at, reason, last_error
      ) VALUES (
        v_tenant, r.campaign_id, r.sku_id, NOW(), NOW(), 'sync blocked', v_error
      )
      ON CONFLICT (tenant_id, campaign_id, sku_id) DO UPDATE
        SET last_seen_at = EXCLUDED.last_seen_at,
            reason = EXCLUDED.reason,
            last_error = EXCLUDED.last_error,
            revision = public.purchase_request_qty_dirty.revision + 1;
      CONTINUE;
    END IF;

    IF r.candidate_count = 1 THEN
      IF r.target_qty IS DISTINCT FROM r.current_qty THEN
        INSERT INTO public.purchase_request_qty_sync_log (
          tenant_id, pr_id, pr_item_id, campaign_id, sku_id,
          old_qty, new_qty, changed_by
        ) VALUES (
          v_tenant, p_pr_id, r.target_pr_item_id, r.campaign_id, r.sku_id,
          r.current_qty, r.target_qty, p_operator
        );
      END IF;

      UPDATE public.purchase_request_item_campaigns
         SET qty_requested = r.target_qty
       WHERE pr_item_id = r.target_pr_item_id
         AND campaign_id = r.campaign_id
         AND tenant_id = v_tenant;

      UPDATE public.purchase_request_items pri
         SET qty_requested = (
               SELECT COALESCE(SUM(pric.qty_requested), 0)
                 FROM public.purchase_request_item_campaigns pric
                WHERE pric.pr_item_id = pri.id
             ),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE pri.id = r.target_pr_item_id;

      IF r.target_qty IS DISTINCT FROM r.current_qty THEN
        v_synced_count := v_synced_count + 1;
      END IF;
    END IF;

    -- 只清掉同步開始時看見的同一版本；同期才發生的取消／加單會留下新版 revision。
    DELETE FROM public.purchase_request_qty_dirty
     WHERE tenant_id = v_tenant
       AND campaign_id = r.campaign_id
       AND sku_id = r.sku_id
       AND revision = COALESCE(
         (v_dirty_seen ->> (r.campaign_id::TEXT || ':' || r.sku_id::TEXT))::BIGINT,
         -1
       );
  END LOOP;

  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(pri.line_subtotal)
             FROM public.purchase_request_items pri
            WHERE pri.pr_id = pr.id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id = p_pr_id;

  RETURN jsonb_build_object(
    'synced_count', v_synced_count,
    'blocked_count', v_blocked_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public._pr_apply_qty_sync(BIGINT, UUID) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.rpc_sync_pr_qty(
  p_pr_id    BIGINT,
  p_operator UUID
) RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public._pr_apply_qty_sync(p_pr_id, p_operator);
$$;

REVOKE ALL ON FUNCTION public.rpc_sync_pr_qty(BIGINT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_sync_pr_qty(BIGINT, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_sync_pr_qty(BIGINT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public._pr_validate_qty_current(
  p_pr_ids BIGINT[]
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_missing      INTEGER;
  v_bad_count    INTEGER;
  v_bad_examples TEXT;
  v_campaign_ids BIGINT[];
BEGIN
  SELECT COUNT(*)
    INTO v_missing
    FROM public.purchase_requests pr
    JOIN public.purchase_request_items pri ON pri.pr_id = pr.id
   WHERE pr.id = ANY(COALESCE(p_pr_ids, ARRAY[]::BIGINT[]))
     AND pr.tenant_id = v_tenant
     AND pr.source_type = 'close_date'
     AND pri.qty_requested > 0
     AND NOT EXISTS (
       SELECT 1 FROM public.purchase_request_item_campaigns pric
        WHERE pric.pr_item_id = pri.id
     );

  IF v_missing > 0 THEN
    RAISE EXCEPTION '有 % 個請購品項缺少原團明細，不能確認最新需求；請退回草稿補齊後重新送審', v_missing;
  END IF;

  SELECT ARRAY_AGG(DISTINCT x.campaign_id ORDER BY x.campaign_id)
    INTO v_campaign_ids
    FROM (
      SELECT prc.campaign_id
        FROM public.purchase_requests pr
        JOIN public.purchase_request_campaigns prc ON prc.pr_id = pr.id
       WHERE pr.id = ANY(COALESCE(p_pr_ids, ARRAY[]::BIGINT[]))
         AND pr.tenant_id = v_tenant
         AND prc.tenant_id = v_tenant
      UNION
      SELECT pric.campaign_id
        FROM public.purchase_requests pr
        JOIN public.purchase_request_items pri ON pri.pr_id = pr.id
        JOIN public.purchase_request_item_campaigns pric ON pric.pr_item_id = pri.id
       WHERE pr.id = ANY(COALESCE(p_pr_ids, ARRAY[]::BIGINT[]))
         AND pr.tenant_id = v_tenant
         AND pric.tenant_id = v_tenant
      UNION
      SELECT pri.source_campaign_id
        FROM public.purchase_requests pr
        JOIN public.purchase_request_items pri ON pri.pr_id = pr.id
       WHERE pr.id = ANY(COALESCE(p_pr_ids, ARRAY[]::BIGINT[]))
         AND pr.tenant_id = v_tenant
         AND pri.source_campaign_id IS NOT NULL
    ) x;

  IF COALESCE(array_length(v_campaign_ids, 1), 0) = 0 THEN
    RETURN;
  END IF;

  -- 用 PR 涵蓋的全部團做邊界；helper 會同時列出「現行需求的 key」與
  -- 「已歸屬過的 key」。不再用目標 PR 現有 attribution 過濾，否則新 SKU 會漏過。
  WITH bad AS (
    SELECT r.*
      FROM public._pr_campaign_sku_remaining_rows(v_campaign_ids) r
     WHERE r.delta_qty <> 0
  )
  SELECT COUNT(*),
         STRING_AGG(
           format('團%s/品項%s：有效需求%s、已請購%s', campaign_id, sku_id, demand_qty, already_qty),
           '；' ORDER BY campaign_id, sku_id
         )
    INTO v_bad_count, v_bad_examples
    FROM (SELECT * FROM bad ORDER BY campaign_id, sku_id LIMIT 5) x;

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION '請購數量已和最新開團需求不同（%）。請先退回草稿，按「同步最新開團數量」，再重新送審。', v_bad_examples;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._pr_validate_qty_current(BIGINT[]) FROM PUBLIC;

-- PO snapshot: campaign -> campaign item -> order -> order item, all FOR UPDATE.
CREATE OR REPLACE FUNCTION public._pr_lock_demand_snapshot(
  p_pr_ids BIGINT[]
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_campaign_ids BIGINT[];
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION '缺少租戶資訊，無法鎖定開團需求';
  END IF;

  SELECT ARRAY_AGG(DISTINCT x.campaign_id ORDER BY x.campaign_id)
    INTO v_campaign_ids
    FROM (
      SELECT prc.campaign_id
        FROM public.purchase_requests pr
        JOIN public.purchase_request_campaigns prc ON prc.pr_id = pr.id
       WHERE pr.id = ANY(COALESCE(p_pr_ids, ARRAY[]::BIGINT[]))
         AND pr.tenant_id = v_tenant
         AND prc.tenant_id = v_tenant
      UNION
      SELECT pric.campaign_id
        FROM public.purchase_requests pr
        JOIN public.purchase_request_items pri ON pri.pr_id = pr.id
        JOIN public.purchase_request_item_campaigns pric ON pric.pr_item_id = pri.id
       WHERE pr.id = ANY(COALESCE(p_pr_ids, ARRAY[]::BIGINT[]))
         AND pr.tenant_id = v_tenant
         AND pric.tenant_id = v_tenant
      UNION
      SELECT pri.source_campaign_id
        FROM public.purchase_requests pr
        JOIN public.purchase_request_items pri ON pri.pr_id = pr.id
       WHERE pr.id = ANY(COALESCE(p_pr_ids, ARRAY[]::BIGINT[]))
         AND pr.tenant_id = v_tenant
         AND pri.source_campaign_id IS NOT NULL
    ) x;

  IF COALESCE(array_length(v_campaign_ids, 1), 0) = 0 THEN
    RETURN;
  END IF;

  PERFORM 1
    FROM public.group_buy_campaigns gbc
   WHERE gbc.tenant_id = v_tenant
     AND gbc.id = ANY(v_campaign_ids)
   ORDER BY gbc.id
   FOR UPDATE;

  PERFORM 1
    FROM public.campaign_items ci
   WHERE ci.tenant_id = v_tenant
     AND ci.campaign_id = ANY(v_campaign_ids)
   ORDER BY ci.campaign_id, ci.id
   FOR UPDATE;

  PERFORM 1
    FROM public.customer_orders co
   WHERE co.tenant_id = v_tenant
     AND co.campaign_id = ANY(v_campaign_ids)
   ORDER BY co.campaign_id, co.id
   FOR UPDATE;

  PERFORM 1
    FROM public.customer_order_items coi
    JOIN public.customer_orders co ON co.id = coi.order_id
   WHERE co.tenant_id = v_tenant
     AND co.campaign_id = ANY(v_campaign_ids)
   ORDER BY co.campaign_id, co.id, coi.id
   FOR UPDATE OF coi;
END;
$$;

REVOKE ALL ON FUNCTION public._pr_lock_demand_snapshot(BIGINT[]) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public._pr_delete_campaign_ids(BIGINT)
RETURNS BIGINT[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
SELECT ARRAY(SELECT campaign_id FROM (
  SELECT campaign_id FROM purchase_request_campaigns WHERE pr_id = $1
  UNION SELECT pric.campaign_id FROM purchase_request_items pri
    JOIN purchase_request_item_campaigns pric ON pric.pr_item_id = pri.id WHERE pri.pr_id = $1
  UNION SELECT source_campaign_id FROM purchase_request_items WHERE pr_id = $1 AND source_campaign_id IS NOT NULL
  UNION SELECT source_campaign_id FROM purchase_requests WHERE id = $1 AND source_campaign_id IS NOT NULL
) x ORDER BY campaign_id)
$$;

REVOKE ALL ON FUNCTION public._pr_delete_campaign_ids(BIGINT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.rpc_delete_pr(
  p_pr_id    BIGINT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_status   TEXT;
  v_po_items INTEGER;
  v_restock  INTEGER;
  v_campaign_ids BIGINT[];
  v_current_campaign_ids BIGINT[];
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION '權限不足：角色 % 無法刪除請購單', v_role;
  END IF;

  v_campaign_ids := public._pr_delete_campaign_ids(p_pr_id);

  PERFORM 1
    FROM public.group_buy_campaigns gbc
   WHERE gbc.tenant_id = v_tenant
     AND gbc.id = ANY(v_campaign_ids)
   ORDER BY gbc.id
   FOR NO KEY UPDATE;

  SELECT status INTO v_status
    FROM purchase_requests
   WHERE id = p_pr_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION '找不到請購單 %', p_pr_id;
  END IF;

  v_current_campaign_ids := public._pr_delete_campaign_ids(p_pr_id);
  IF v_current_campaign_ids IS DISTINCT FROM v_campaign_ids THEN
    RAISE EXCEPTION '請購單的關聯團剛剛有變動，請重試刪除';
  END IF;

  IF v_status IN ('partially_ordered','fully_ordered') THEN
    RAISE EXCEPTION '請購單 % 已拆採購單(PO)，不可刪除（狀態：%）。請改在採購單端處理。', p_pr_id, v_status;
  END IF;

  SELECT COUNT(*) INTO v_po_items
    FROM purchase_request_items
   WHERE pr_id = p_pr_id AND po_item_id IS NOT NULL;
  IF v_po_items > 0 THEN
    RAISE EXCEPTION '請購單 % 已有品項拆成採購單，不可刪除', p_pr_id;
  END IF;

  SELECT COUNT(*) INTO v_restock
    FROM restock_requests
   WHERE linked_pr_id = p_pr_id AND tenant_id = v_tenant;
  IF v_restock > 0 THEN
    RAISE EXCEPTION '請購單 % 來自補貨申請，請從補貨流程處理，不可在此刪除', p_pr_id;
  END IF;

  UPDATE group_buy_campaigns gbc
     SET status     = 'closed',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE gbc.tenant_id = v_tenant
     AND gbc.status = 'locked'
     AND gbc.id IN (
       SELECT prc.campaign_id
         FROM purchase_request_campaigns prc
        WHERE prc.pr_id = p_pr_id
       UNION
       SELECT pr.source_campaign_id
         FROM purchase_requests pr
        WHERE pr.id = p_pr_id AND pr.source_campaign_id IS NOT NULL
     );

  BEGIN
    DELETE FROM purchase_requests
     WHERE id = p_pr_id AND tenant_id = v_tenant;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION '請購單 % 仍被其他紀錄參照，無法刪除', p_pr_id;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_pr(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_pr(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_pr(BIGINT, UUID) IS
  '刪除未拆 PO 的請購單；先鎖關聯團，再照原守門解鎖團與硬刪。';

-- ---------------------------------------------------------------------------
-- 送審：仍是 draft 時先強制同步，再跑既有品項／供應商／門檻守衛。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_submit_pr(
  p_pr_id    BIGINT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID;
  v_status         TEXT;
  v_review         TEXT;
  v_item_count     INTEGER;
  v_positive_count INTEGER;
  v_unassigned     INTEGER;
  v_total          NUMERIC(18,4);
  v_threshold      NUMERIC(18,4);
  v_new_review     TEXT;
  v_sync           JSONB;
BEGIN
  SELECT tenant_id, status, review_status
    INTO v_tenant, v_status, v_review
    FROM public.purchase_requests
   WHERE id = p_pr_id
     AND tenant_id = public._current_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到請購單 %', p_pr_id;
  END IF;
  IF v_status <> 'draft' THEN
    RAISE EXCEPTION '請購單已送審（目前狀態：%）', v_status;
  END IF;

  -- _pr_apply_qty_sync 會先取團+SKU advisory，再鎖 PR/item；這裡不可先鎖 PR header，
  -- 否則會和已統一成 advisory -> PR/item 的 #995 反向。apply 回來時 PR 鎖仍持有。
  v_sync := public._pr_apply_qty_sync(p_pr_id, p_operator);
  IF COALESCE((v_sync ->> 'blocked_count')::INTEGER, 0) > 0 THEN
    RAISE EXCEPTION '有品項無法安全同步：同團同商品有多張草稿或歸屬不明，請先人工確認';
  END IF;

  PERFORM public._pr_validate_qty_current(ARRAY[p_pr_id]);

  SELECT COUNT(*),
         COUNT(*) FILTER (WHERE qty_requested > 0),
         COUNT(*) FILTER (WHERE qty_requested > 0 AND suggested_supplier_id IS NULL)
    INTO v_item_count, v_positive_count, v_unassigned
    FROM public.purchase_request_items
   WHERE pr_id = p_pr_id;

  IF v_item_count = 0 OR v_positive_count = 0 THEN
    RAISE EXCEPTION '請購單沒有仍需採購的品項，無法送審；數量歸零的列會保留作追溯';
  END IF;
  IF v_unassigned > 0 THEN
    RAISE EXCEPTION '有 % 個品項未指派供應商，無法送審；請先指派供應商', v_unassigned;
  END IF;

  SELECT COALESCE(SUM(line_subtotal), 0)
    INTO v_total
    FROM public.purchase_request_items
   WHERE pr_id = p_pr_id;

  SELECT MIN(threshold_amount)
    INTO v_threshold
    FROM public.purchase_approval_thresholds
   WHERE tenant_id = v_tenant
     AND active = TRUE
     AND scope = 'global'
     AND scope_id IS NULL;

  IF v_threshold IS NOT NULL AND v_total >= v_threshold THEN
    v_new_review := 'pending_review';
  ELSE
    v_new_review := 'approved';
  END IF;

  UPDATE public.purchase_requests
     SET status = 'submitted',
         submitted_at = NOW(),
         total_amount = v_total,
         review_status = v_new_review,
         review_threshold_amount = v_threshold,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_pr_id;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_submit_pr(BIGINT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_submit_pr(BIGINT, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_submit_pr(BIGINT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 建 PO 前最後守門：已送審後若需求變動，只擋、不偷改核准單。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_split_pr_to_pos(
  p_pr_id            BIGINT,
  p_dest_location_id BIGINT,
  p_operator         UUID
) RETURNS BIGINT[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_role           TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_status         TEXT;
  v_review         TEXT;
  v_unassigned     INTEGER;
  v_positive_count INTEGER;
  v_supplier_rec   RECORD;
  v_po_id          BIGINT;
  v_po_no          TEXT;
  v_po_ids          BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  IF v_tenant IS NULL OR v_role NOT IN ('owner','admin','hq_manager','purchaser','assistant','') THEN
    RAISE EXCEPTION '權限不足，無法建立採購單';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;
  IF p_operator IS NULL OR (auth.uid() IS NOT NULL AND p_operator <> auth.uid()) THEN
    RAISE EXCEPTION '操作人員不符，無法建立採購單';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.locations l
     WHERE l.id = p_dest_location_id AND l.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION '送貨地點不屬於本租戶';
  END IF;

  SELECT status, review_status
    INTO v_status, v_review
    FROM public.purchase_requests
   WHERE id = p_pr_id
     AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到請購單 %', p_pr_id;
  END IF;
  IF v_review <> 'approved' THEN
    RAISE EXCEPTION '請購單尚未核准（目前：%）', v_review;
  END IF;
  IF v_status <> 'submitted' THEN
    RAISE EXCEPTION '請購單不是已送審待採購狀態（目前：%）', v_status;
  END IF;

  SELECT COUNT(*) FILTER (WHERE qty_requested > 0 AND suggested_supplier_id IS NULL),
         COUNT(*) FILTER (WHERE qty_requested > 0)
    INTO v_unassigned, v_positive_count
    FROM public.purchase_request_items
   WHERE pr_id = p_pr_id;

  IF v_positive_count = 0 THEN
    RAISE EXCEPTION '這張請購單已沒有仍需採購的數量；請退回草稿確認';
  END IF;
  IF v_unassigned > 0 THEN
    RAISE EXCEPTION '有 % 個品項未指派供應商，無法建立採購單', v_unassigned;
  END IF;

  PERFORM public._pr_lock_demand_snapshot(ARRAY[p_pr_id]);

  SELECT status, review_status
    INTO v_status, v_review
    FROM public.purchase_requests
   WHERE id = p_pr_id
     AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到請購單 %', p_pr_id;
  END IF;
  IF v_review <> 'approved' THEN
    RAISE EXCEPTION '請購單尚未核准（目前：%）', v_review;
  END IF;
  IF v_status <> 'submitted' THEN
    RAISE EXCEPTION '請購單不是已送審待採購狀態（目前：%）', v_status;
  END IF;

  PERFORM public._pr_validate_qty_current(ARRAY[p_pr_id]);

  SELECT COUNT(*) FILTER (WHERE qty_requested > 0 AND suggested_supplier_id IS NULL),
         COUNT(*) FILTER (WHERE qty_requested > 0)
    INTO v_unassigned, v_positive_count
    FROM public.purchase_request_items
   WHERE pr_id = p_pr_id;

  IF v_positive_count = 0 THEN
    RAISE EXCEPTION '這張請購單已沒有仍需採購的數量；請退回草稿確認';
  END IF;
  IF v_unassigned > 0 THEN
    RAISE EXCEPTION '有 % 個品項未指派供應商，無法建立採購單', v_unassigned;
  END IF;

  FOR v_supplier_rec IN
    SELECT DISTINCT suggested_supplier_id AS supplier_id
      FROM public.purchase_request_items
     WHERE pr_id = p_pr_id
       AND qty_requested > 0
  LOOP
    v_po_no := public.rpc_next_po_no();

    INSERT INTO public.purchase_orders (
      tenant_id, po_no, supplier_id, dest_location_id, status,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_po_no, v_supplier_rec.supplier_id, p_dest_location_id, 'draft',
      p_operator, p_operator
    ) RETURNING id INTO v_po_id;

    WITH inserted AS (
      INSERT INTO public.purchase_order_items (
        po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by
      )
      SELECT v_po_id, pri.sku_id, pri.qty_requested, pri.unit_cost, p_operator, p_operator
        FROM public.purchase_request_items pri
       WHERE pri.pr_id = p_pr_id
         AND pri.suggested_supplier_id = v_supplier_rec.supplier_id
         AND pri.qty_requested > 0
      RETURNING id, sku_id
    )
    UPDATE public.purchase_request_items pri
       SET po_item_id = i.id,
           updated_by = p_operator
      FROM inserted i
     WHERE pri.pr_id = p_pr_id
       AND pri.suggested_supplier_id = v_supplier_rec.supplier_id
       AND pri.qty_requested > 0
       AND pri.sku_id = i.sku_id;

    UPDATE public.purchase_orders po
       SET subtotal = sub.subtotal,
           total = sub.subtotal,
           updated_at = NOW()
      FROM (
        SELECT po_id, SUM(qty_ordered * unit_cost) AS subtotal
          FROM public.purchase_order_items
         WHERE po_id = v_po_id
         GROUP BY po_id
      ) sub
     WHERE po.id = sub.po_id;

    v_po_ids := v_po_ids || v_po_id;
  END LOOP;

  UPDATE public.purchase_requests
     SET status = 'fully_ordered',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_pr_id;

  RETURN v_po_ids;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_split_pr_to_pos(BIGINT, BIGINT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_split_pr_to_pos(BIGINT, BIGINT, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_split_pr_to_pos(BIGINT, BIGINT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_merge_prs_to_po(
  p_tenant_id     UUID,
  p_pr_item_ids   BIGINT[],
  p_supplier_id   BIGINT,
  p_dest_location BIGINT,
  p_po_no         TEXT,
  p_operator      UUID
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_po_id     BIGINT;
  v_pr_ids    BIGINT[];
  v_snapshot_pr_ids BIGINT[];
  v_valid_ids BIGINT[];
  v_want      INTEGER;
  v_matched   INTEGER;
  v_role      TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF p_tenant_id IS DISTINCT FROM public._current_tenant_id() THEN
    RAISE EXCEPTION '權限不足，租戶不符';
  END IF;

  IF v_role NOT IN ('owner','admin','hq_manager','purchaser','assistant','') THEN
    RAISE EXCEPTION '權限不足，無法合併請購品項';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;
  IF p_operator IS NULL OR (auth.uid() IS NOT NULL AND p_operator <> auth.uid()) THEN
    RAISE EXCEPTION '操作人員不符，無法建立採購單';
  END IF;

  IF EXISTS (SELECT 1 FROM unnest(COALESCE(p_pr_item_ids, ARRAY[]::BIGINT[])) x WHERE x IS NULL) THEN
    RAISE EXCEPTION '請購品項編號不可為空';
  END IF;

  v_valid_ids := ARRAY(
    SELECT DISTINCT x
      FROM unnest(COALESCE(p_pr_item_ids, ARRAY[]::BIGINT[])) u(x)
     ORDER BY x
  );
  v_want := COALESCE(array_length(v_valid_ids, 1), 0);
  IF v_want = 0 THEN
    RAISE EXCEPTION '沒有可建立採購單的請購品項';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.suppliers s
     WHERE s.id = p_supplier_id AND s.tenant_id = p_tenant_id
  ) OR NOT EXISTS (
    SELECT 1 FROM public.locations l
     WHERE l.id = p_dest_location AND l.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION '供應商或送貨地點不屬於本租戶';
  END IF;

  SELECT COUNT(*),
         ARRAY_AGG(pri.id ORDER BY pri.id),
         ARRAY_AGG(DISTINCT pri.pr_id ORDER BY pri.pr_id)
    INTO v_matched, v_valid_ids, v_snapshot_pr_ids
    FROM public.purchase_request_items pri
    JOIN public.purchase_requests pr ON pr.id = pri.pr_id
   WHERE pri.id = ANY(v_valid_ids)
     AND pri.qty_requested > 0
     AND pri.po_item_id IS NULL
     AND pri.suggested_supplier_id = p_supplier_id
     AND pr.tenant_id = p_tenant_id
     AND pr.status = 'submitted'
     AND pr.review_status = 'approved';

  IF v_matched <> v_want THEN
    RAISE EXCEPTION '請購品項有不屬本租戶、未核准、已轉採購或供應商不符；整筆未建立（傳入 % 項，合法 % 項）',
      v_want, v_matched;
  END IF;

  PERFORM public._pr_lock_demand_snapshot(v_snapshot_pr_ids);

  PERFORM 1
    FROM public.purchase_request_items pri
    JOIN public.purchase_requests pr ON pr.id = pri.pr_id
   WHERE pri.id = ANY(v_valid_ids)
      AND pri.qty_requested > 0
      AND pri.po_item_id IS NULL
      AND pri.suggested_supplier_id = p_supplier_id
      AND pr.tenant_id = p_tenant_id
      AND pr.status = 'submitted'
      AND pr.review_status = 'approved'
   ORDER BY pr.id, pri.id
   FOR UPDATE OF pr, pri;

  SELECT COUNT(*),
         ARRAY_AGG(pri.id ORDER BY pri.id),
         ARRAY_AGG(DISTINCT pri.pr_id ORDER BY pri.pr_id)
    INTO v_matched, v_valid_ids, v_pr_ids
    FROM public.purchase_request_items pri
    JOIN public.purchase_requests pr ON pr.id = pri.pr_id
   WHERE pri.id = ANY(v_valid_ids)
     AND pri.qty_requested > 0
     AND pri.po_item_id IS NULL
     AND pri.suggested_supplier_id = p_supplier_id
     AND pr.tenant_id = p_tenant_id
     AND pr.status = 'submitted'
     AND pr.review_status = 'approved';

  IF v_matched <> v_want THEN
    RAISE EXCEPTION '請購品項有不屬本租戶、未核准、已轉採購或供應商不符；整筆未建立（傳入 % 項，合法 % 項）',
      v_want, v_matched;
  END IF;

  IF v_pr_ids IS DISTINCT FROM v_snapshot_pr_ids THEN
    RAISE EXCEPTION '請購品項在建單前已被搬到其他請購單；整筆未建立，請重試';
  END IF;

  PERFORM public._pr_validate_qty_current(v_pr_ids);

  INSERT INTO public.purchase_orders (tenant_id, po_no, supplier_id, dest_location_id, created_by)
  VALUES (p_tenant_id, p_po_no, p_supplier_id, p_dest_location, p_operator)
  RETURNING id INTO v_po_id;

  WITH grouped AS (
    SELECT pri.sku_id,
           SUM(pri.qty_requested) AS qty,
           COALESCE(MAX(ss.default_unit_cost), 0) AS unit_cost
      FROM public.purchase_request_items pri
      LEFT JOIN public.supplier_skus ss
        ON ss.tenant_id = p_tenant_id
       AND ss.supplier_id = p_supplier_id
       AND ss.sku_id = pri.sku_id
     WHERE pri.id = ANY(v_valid_ids)
       AND pri.qty_requested > 0
       AND pri.po_item_id IS NULL
     GROUP BY pri.sku_id
  ), inserted AS (
    INSERT INTO public.purchase_order_items (po_id, sku_id, qty_ordered, unit_cost)
    SELECT v_po_id, sku_id, qty, unit_cost FROM grouped
    RETURNING id, sku_id
  )
  UPDATE public.purchase_request_items pri
     SET po_item_id = i.id
    FROM inserted i
   WHERE pri.id = ANY(v_valid_ids)
     AND pri.qty_requested > 0
     AND pri.po_item_id IS NULL
     AND pri.sku_id = i.sku_id;

  UPDATE public.purchase_requests pr
     SET status = CASE
       WHEN NOT EXISTS (
         SELECT 1 FROM public.purchase_request_items pri
          WHERE pri.pr_id = pr.id
            AND pri.po_item_id IS NULL
            AND pri.qty_requested > 0
       ) THEN 'fully_ordered' ELSE 'partially_ordered'
     END
   WHERE pr.id = ANY(v_pr_ids);

  RETURN v_po_id;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_merge_prs_to_po(UUID, BIGINT[], BIGINT, BIGINT, TEXT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_merge_prs_to_po(UUID, BIGINT[], BIGINT, BIGINT, TEXT, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_merge_prs_to_po(UUID, BIGINT[], BIGINT, BIGINT, TEXT, UUID) TO authenticated;

-- 部分轉採購仍只是搬 draft；改成 UPDATE pr_id，保留原 item id、來源團明細、
-- purchase_request_store_additions.pr_item_id 與 dirty queue 的團+SKU 對應。
CREATE OR REPLACE FUNCTION public.rpc_create_partial_pr_from_items(
  p_source_pr_id BIGINT,
  p_item_ids     BIGINT[],
  p_operator     UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_role       TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_ids        BIGINT[];
  v_want       INTEGER;
  v_matched    INTEGER := 0;
  v_po_linked  INTEGER := 0;
  v_restock    INTEGER;
  v_total      INTEGER;
  v_remaining  INTEGER;
  v_moved      INTEGER;
  v_src        RECORD;
  v_new_pr_id  BIGINT;
  v_new_pr_no  TEXT;
  v_notes      TEXT;
  r            RECORD;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION '權限不足：角色 % 無法執行部分轉採購', v_role;
  END IF;

  v_ids := ARRAY(
    SELECT DISTINCT x
      FROM unnest(COALESCE(p_item_ids, ARRAY[]::BIGINT[])) AS u(x)
     WHERE x IS NOT NULL
     ORDER BY x
  );
  v_want := COALESCE(array_length(v_ids, 1), 0);
  IF v_want = 0 THEN
    RAISE EXCEPTION '請先勾選要轉出的品項';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;
  IF p_operator IS NULL OR (auth.uid() IS NOT NULL AND p_operator <> auth.uid()) THEN
    RAISE EXCEPTION '操作人員不符，無法建立新請購單';
  END IF;

  SELECT pr.pr_no, pr.status, pr.source_type, pr.source_close_date,
         pr.source_campaign_id, pr.source_location_id, pr.notes
    INTO v_src
    FROM public.purchase_requests pr
   WHERE pr.id = p_source_pr_id
     AND pr.tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到請購單 %', p_source_pr_id;
  END IF;
  IF v_src.status <> 'draft' THEN
    RAISE EXCEPTION '請購單 % 不是草稿（目前狀態：%），不可部分轉採購', v_src.pr_no, v_src.status;
  END IF;

  SELECT COUNT(*) INTO v_restock
    FROM public.restock_requests
   WHERE linked_pr_id = p_source_pr_id AND tenant_id = v_tenant;
  IF v_restock > 0 THEN
    RAISE EXCEPTION '請購單 % 來自補貨申請，請從補貨流程處理', v_src.pr_no;
  END IF;

  FOR r IN
    SELECT pri.id, pri.po_item_id
      FROM public.purchase_request_items pri
     WHERE pri.pr_id = p_source_pr_id
       AND pri.id = ANY(v_ids)
     ORDER BY pri.id
     FOR UPDATE
  LOOP
    v_matched := v_matched + 1;
    IF r.po_item_id IS NOT NULL THEN
      v_po_linked := v_po_linked + 1;
    END IF;
  END LOOP;

  IF v_matched <> v_want THEN
    RAISE EXCEPTION '有品項不屬於本請購單 %（勾選 % 項，實際命中 % 項）',
      v_src.pr_no, v_want, v_matched;
  END IF;
  IF v_po_linked > 0 THEN
    RAISE EXCEPTION '勾選的品項有 % 項已拆成採購單，不可搬移', v_po_linked;
  END IF;

  SELECT COUNT(*) INTO v_total
    FROM public.purchase_request_items
   WHERE pr_id = p_source_pr_id;
  IF v_total - v_matched <= 0 THEN
    RAISE EXCEPTION '不可把請購單 % 的品項全部轉出；要全部採購請直接送審本單', v_src.pr_no;
  END IF;

  v_new_pr_no := public.rpc_next_pr_no();
  v_notes := format('分批採購：自 %s 轉出 %s 項', v_src.pr_no, v_matched);
  IF COALESCE(btrim(v_src.notes), '') <> '' THEN
    v_notes := v_src.notes || E'\n' || v_notes;
  END IF;

  INSERT INTO public.purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_campaign_id,
    source_location_id, status, total_amount, notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_new_pr_no, v_src.source_type, v_src.source_close_date, v_src.source_campaign_id,
    v_src.source_location_id, 'draft', 0, v_notes, p_operator, p_operator
  ) RETURNING id INTO v_new_pr_id;

  INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_new_pr_id, prc.campaign_id, v_tenant
    FROM public.purchase_request_campaigns prc
   WHERE prc.pr_id = p_source_pr_id
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE public.purchase_request_items
     SET pr_id = v_new_pr_id,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr_id = p_source_pr_id
     AND id = ANY(v_ids);
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  -- addition 同時存 pr_id/pr_item_id；item 保留原 id 搬單後，頭部 id 也必須一起移動。
  UPDATE public.purchase_request_store_additions
     SET pr_id = v_new_pr_id
   WHERE tenant_id = v_tenant
     AND pr_id = p_source_pr_id
     AND pr_item_id = ANY(v_ids);

  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(pri.line_subtotal)
             FROM public.purchase_request_items pri
            WHERE pri.pr_id = pr.id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id IN (p_source_pr_id, v_new_pr_id);

  SELECT COUNT(*) INTO v_remaining
    FROM public.purchase_request_items
   WHERE pr_id = p_source_pr_id;

  RETURN jsonb_build_object(
    'new_pr_id', v_new_pr_id,
    'new_pr_no', v_new_pr_no,
    'moved_count', v_moved,
    'remaining_count', v_remaining
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) TO authenticated;

COMMENT ON TABLE public.purchase_request_qty_dirty IS
  '客單需求已變、請購尚未同步的去重清單；客單 trigger 只寫這裡，不回寫請購。';
COMMENT ON TABLE public.purchase_request_qty_sync_log IS
  '請購草稿同步成功的 append-only 舊/新數量追溯。';
COMMENT ON FUNCTION public.rpc_sync_pr_qty(BIGINT, UUID) IS
  '人工同步草稿請購：只改唯一歸屬、未綁 PO 的來源團明細，數量可降為 0 並保留追溯。';

-- ============================================================================
-- 2026-09-21: 請購防重第二刀
-- ----------------------------------------------------------------------------
-- 老闆要解的問題：
--   同一個團先在錯的結單日建過請購快照，後來把原團延長讓店家追加。
--   重新請購時不能再整包開一張全量新單，否則採購會看成 116 + 153。
--
-- 本刀只碰兩個建單入口：
--   1. 結單日補單
--   2. 針對團購建單
--
-- 修法：
--   * 以「同一團 + 同一 SKU」扣掉所有未取消 PR 已請購量，只補差額。
--   * 舊請購品項仍是草稿、且尚未拆 PO 時，優先更新舊草稿數量；
--     只有舊單不可改時，才新增差額 PR。
--   * PR item 仍維持每張 PR 每 SKU 一列，避免撞到後面依供應商拆 PO 的假設。
--   * 新增 purchase_request_item_campaigns 記錄「這一列來自哪幾個團、各幾件」。
--   * 取代 PR #972 的防重 guard：不是看到不同結單日就擋，而是總請購量超過
--     該團目前需求才擋。116 + 37 可以；116 + 153 會擋。
--
-- 不做：
--   * 不自動作廢舊單。
--   * 不改建立採購單 / 收貨 / 派貨流程。
--   * 不處理「已經拆成 PO 的舊單要改數量」。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. PR item ↔ campaign 數量明細
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.purchase_request_item_campaigns (
  pr_item_id    BIGINT NOT NULL REFERENCES public.purchase_request_items(id) ON DELETE CASCADE,
  campaign_id   BIGINT NOT NULL REFERENCES public.group_buy_campaigns(id),
  tenant_id     UUID NOT NULL,
  qty_requested NUMERIC(18,3) NOT NULL CHECK (qty_requested > 0),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (pr_item_id, campaign_id)
);

CREATE INDEX IF NOT EXISTS idx_pric_campaign
  ON public.purchase_request_item_campaigns (campaign_id);

CREATE INDEX IF NOT EXISTS idx_pric_tenant_campaign
  ON public.purchase_request_item_campaigns (tenant_id, campaign_id);

ALTER TABLE public.purchase_request_item_campaigns ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auth_read_pric ON public.purchase_request_item_campaigns;
CREATE POLICY auth_read_pric ON public.purchase_request_item_campaigns
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

DROP POLICY IF EXISTS auth_write_pric ON public.purchase_request_item_campaigns;
CREATE POLICY auth_write_pric ON public.purchase_request_item_campaigns
  FOR ALL USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid)
        WITH CHECK (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.purchase_request_item_campaigns TO authenticated;

COMMENT ON TABLE public.purchase_request_item_campaigns IS
  'PR item 的來源團數量明細；同 SKU 合併成一列時，靠這張表保留各團各自請購量。';

COMMENT ON COLUMN public.purchase_request_item_campaigns.qty_requested IS
  '此 PR item 歸屬於該 campaign 的請購數量。';

-- Backfill legacy PR items so old requests are protected by the new delta logic.
WITH legacy_items AS (
  SELECT
    pri.id AS pr_item_id,
    pri.pr_id,
    pr.tenant_id,
    pri.qty_requested,
    pri.source_campaign_id
  FROM public.purchase_request_items pri
  JOIN public.purchase_requests pr
    ON pr.id = pri.pr_id
  WHERE pr.status <> 'cancelled'
    AND NOT EXISTS (
      SELECT 1
        FROM public.purchase_request_item_campaigns pric
       WHERE pric.pr_item_id = pri.id
    )
),
links AS (
  SELECT
    li.pr_item_id,
    li.tenant_id,
    li.qty_requested,
    li.source_campaign_id,
    prc.campaign_id,
    COUNT(prc.campaign_id) OVER (PARTITION BY li.pr_item_id) AS link_count
  FROM legacy_items li
  LEFT JOIN public.purchase_request_campaigns prc
    ON prc.pr_id = li.pr_id
   AND prc.tenant_id = li.tenant_id
),
picked AS (
  SELECT
    pr_item_id,
    tenant_id,
    CASE
      WHEN MAX(link_count) = 1 THEN MIN(campaign_id)
      ELSE MAX(source_campaign_id)
    END AS campaign_id,
    MAX(qty_requested) AS qty_requested
  FROM links
  GROUP BY pr_item_id, tenant_id
  HAVING MAX(link_count) <= 1
     AND CASE
           WHEN MAX(link_count) = 1 THEN MIN(campaign_id)
           ELSE MAX(source_campaign_id)
         END IS NOT NULL
)
INSERT INTO public.purchase_request_item_campaigns (
  pr_item_id, campaign_id, tenant_id, qty_requested
)
SELECT pr_item_id, campaign_id, tenant_id, qty_requested
FROM picked
ON CONFLICT (pr_item_id, campaign_id) DO NOTHING;

WITH legacy_items AS (
  SELECT
    pri.id AS pr_item_id,
    pri.pr_id,
    pr.tenant_id,
    pri.sku_id,
    pri.qty_requested,
    pri.source_campaign_id
  FROM public.purchase_request_items pri
  JOIN public.purchase_requests pr
    ON pr.id = pri.pr_id
  WHERE pr.status <> 'cancelled'
    AND NOT EXISTS (
      SELECT 1
        FROM public.purchase_request_item_campaigns pric
       WHERE pric.pr_item_id = pri.id
    )
),
multi_links AS (
  SELECT
    li.pr_item_id,
    li.tenant_id,
    li.sku_id,
    li.qty_requested,
    li.source_campaign_id,
    prc.campaign_id,
    COUNT(*) OVER (PARTITION BY li.pr_item_id) AS link_count
  FROM legacy_items li
  JOIN public.purchase_request_campaigns prc
    ON prc.pr_id = li.pr_id
   AND prc.tenant_id = li.tenant_id
),
demand AS (
  SELECT
    ml.pr_item_id,
    ml.tenant_id,
    ml.sku_id,
    ml.qty_requested AS item_qty,
    ml.source_campaign_id,
    ml.campaign_id,
    COALESCE(SUM(coi.qty), 0) AS demand_qty
  FROM multi_links ml
  LEFT JOIN public.customer_orders co
    ON co.tenant_id = ml.tenant_id
   AND co.campaign_id = ml.campaign_id
   AND co.status NOT IN ('cancelled','expired','transferred_out')
  LEFT JOIN public.customer_order_items coi
    ON coi.order_id = co.id
   AND coi.sku_id = ml.sku_id
   AND coi.status NOT IN ('cancelled','expired')
  WHERE ml.link_count > 1
  GROUP BY ml.pr_item_id, ml.tenant_id, ml.sku_id, ml.qty_requested, ml.source_campaign_id, ml.campaign_id
),
need AS (
  SELECT
    d.*,
    GREATEST(
      d.demand_qty - COALESCE((
        SELECT SUM(pric.qty_requested)
          FROM public.purchase_request_item_campaigns pric
          JOIN public.purchase_request_items pri2
            ON pri2.id = pric.pr_item_id
         WHERE pric.tenant_id = d.tenant_id
           AND pric.campaign_id = d.campaign_id
           AND pri2.sku_id = d.sku_id
      ), 0),
      0
    ) AS need_qty
  FROM demand d
),
weighted AS (
  SELECT
    n.*,
    SUM(n.need_qty) OVER (PARTITION BY n.pr_item_id) AS total_need_qty,
    ROW_NUMBER() OVER (
      PARTITION BY n.pr_item_id
      ORDER BY (n.campaign_id = n.source_campaign_id) DESC, n.campaign_id
    ) AS fallback_rank
  FROM need n
),
base_allocated AS (
  SELECT
    pr_item_id,
    campaign_id,
    tenant_id,
    item_qty,
    fallback_rank,
    CASE
      WHEN total_need_qty > 0
        THEN LEAST(need_qty, item_qty * need_qty / total_need_qty)
      ELSE 0
    END AS base_qty
  FROM weighted
),
allocated AS (
  SELECT
    pr_item_id,
    campaign_id,
    tenant_id,
    base_qty
      + CASE
          WHEN fallback_rank = 1
            THEN GREATEST(
              item_qty - SUM(base_qty) OVER (PARTITION BY pr_item_id),
              0
            )
          ELSE 0
        END AS qty_requested
  FROM base_allocated
)
INSERT INTO public.purchase_request_item_campaigns (
  pr_item_id, campaign_id, tenant_id, qty_requested
)
SELECT pr_item_id, campaign_id, tenant_id, qty_requested
FROM allocated
WHERE qty_requested > 0
ON CONFLICT (pr_item_id, campaign_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 1. 共用 helper：同團 + SKU 剩餘未請購量
-- ----------------------------------------------------------------------------
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
    SELECT
      co.campaign_id,
      coi.sku_id,
      SUM(coi.qty) AS qty
    FROM sel
    JOIN public.customer_orders co
      ON co.campaign_id = sel.campaign_id
    JOIN public.customer_order_items coi
      ON coi.order_id = co.id
    CROSS JOIN t
    WHERE co.tenant_id = t.tid
      AND co.status NOT IN ('cancelled','expired','transferred_out')
      AND coi.status NOT IN ('cancelled','expired')
    GROUP BY co.campaign_id, coi.sku_id
  ),
  attributed AS (
    SELECT
      pric.campaign_id,
      pri.sku_id,
      SUM(pric.qty_requested) AS qty
    FROM public.purchase_request_item_campaigns pric
    JOIN public.purchase_request_items pri
      ON pri.id = pric.pr_item_id
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    JOIN sel
      ON sel.campaign_id = pric.campaign_id
    CROSS JOIN t
    WHERE pr.tenant_id = t.tid
      AND pric.tenant_id = t.tid
      AND pr.status <> 'cancelled'
    GROUP BY pric.campaign_id, pri.sku_id
  ),
  direct_legacy AS (
    SELECT
      pri.source_campaign_id AS campaign_id,
      pri.sku_id,
      SUM(pri.qty_requested) AS qty
    FROM public.purchase_requests pr
    JOIN public.purchase_request_items pri
      ON pri.pr_id = pr.id
    JOIN sel
      ON sel.campaign_id = pri.source_campaign_id
    CROSS JOIN t
    WHERE pr.tenant_id = t.tid
      AND pr.status <> 'cancelled'
      AND pri.source_campaign_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
          FROM public.purchase_request_item_campaigns pric
         WHERE pric.pr_item_id = pri.id
      )
    GROUP BY pri.source_campaign_id, pri.sku_id
  ),
  already AS (
    SELECT campaign_id, sku_id, SUM(qty) AS qty
      FROM (
        SELECT * FROM attributed
        UNION ALL
        SELECT * FROM direct_legacy
      ) x
     GROUP BY campaign_id, sku_id
  )
  SELECT
    d.campaign_id,
    d.sku_id,
    d.qty AS demand_qty,
    COALESCE(a.qty, 0) AS already_qty,
    d.qty - COALESCE(a.qty, 0) AS delta_qty
  FROM demand d
  LEFT JOIN already a
    ON a.campaign_id = d.campaign_id
   AND a.sku_id = d.sku_id;
$$;

REVOKE ALL ON FUNCTION public._pr_campaign_sku_remaining_rows(BIGINT[]) FROM PUBLIC;

COMMENT ON FUNCTION public._pr_campaign_sku_remaining_rows(BIGINT[]) IS
  '內部 helper：以同團+SKU 計算目前需求、已請購量與剩餘差額；新資料看 purchase_request_item_campaigns，舊資料 fallback 看 source_campaign_id。';

CREATE OR REPLACE FUNCTION public.rpc_preview_pr_campaign_sku_delta(
  p_close_date   DATE DEFAULT NULL,
  p_campaign_ids BIGINT[] DEFAULT NULL
) RETURNS TABLE(
  campaign_id      BIGINT,
  campaign_name    TEXT,
  sku_id           BIGINT,
  sku_label        TEXT,
  demand_qty       NUMERIC,
  already_qty      NUMERIC,
  delta_qty        NUMERIC,
  draft_pr_id      BIGINT,
  draft_pr_no      TEXT,
  action_code      TEXT,
  action_label     TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH t AS (
    SELECT public._current_tenant_id() AS tid
  ),
  selected AS (
    SELECT DISTINCT gbc.id AS campaign_id
      FROM public.group_buy_campaigns gbc
      CROSS JOIN t
     WHERE gbc.tenant_id = t.tid
       AND (
         (p_close_date IS NOT NULL
          AND gbc.status IN ('closed','locked')
          AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date)
         OR
         (p_campaign_ids IS NOT NULL
          AND gbc.id = ANY(p_campaign_ids))
       )
  ),
  delta AS (
    SELECT r.*
      FROM public._pr_campaign_sku_remaining_rows(
             ARRAY(SELECT campaign_id FROM selected ORDER BY campaign_id)
           ) r
     WHERE r.delta_qty > 0
  ),
  candidates AS (
    SELECT
      d.campaign_id,
      d.sku_id,
      pri.pr_id,
      pr.pr_no,
      0 AS priority,
      pr.updated_at,
      pri.id AS pr_item_id
    FROM delta d
    JOIN public.purchase_request_item_campaigns pric
      ON pric.campaign_id = d.campaign_id
    JOIN public.purchase_request_items pri
      ON pri.id = pric.pr_item_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    CROSS JOIN t
    WHERE pr.tenant_id = t.tid
      AND pric.tenant_id = t.tid
      AND pr.status = 'draft'

    UNION ALL

    SELECT
      d.campaign_id,
      d.sku_id,
      pri.pr_id,
      pr.pr_no,
      1 AS priority,
      pr.updated_at,
      pri.id AS pr_item_id
    FROM delta d
    JOIN public.purchase_request_items pri
      ON pri.source_campaign_id = d.campaign_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    CROSS JOIN t
    WHERE pr.tenant_id = t.tid
      AND pr.status = 'draft'
      AND NOT EXISTS (
        SELECT 1
          FROM public.purchase_request_item_campaigns pric
         WHERE pric.pr_item_id = pri.id
           AND pric.campaign_id = d.campaign_id
      )
  ),
  target AS (
    SELECT DISTINCT ON (campaign_id, sku_id)
      campaign_id,
      sku_id,
      pr_id,
      pr_no
    FROM candidates
    ORDER BY campaign_id, sku_id, priority, updated_at DESC, pr_item_id DESC
  )
  SELECT
    d.campaign_id,
    gbc.name AS campaign_name,
    d.sku_id,
    COALESCE(
      NULLIF(TRIM(COALESCE(s.product_name, '')
        || COALESCE(' / ' || NULLIF(s.variant_name, ''), '')), ''),
      s.sku_code,
      '品項#' || d.sku_id::TEXT
    ) AS sku_label,
    d.demand_qty,
    d.already_qty,
    d.delta_qty,
    target.pr_id AS draft_pr_id,
    target.pr_no AS draft_pr_no,
    CASE WHEN target.pr_id IS NULL THEN 'create_delta' ELSE 'update_draft' END AS action_code,
    CASE
      WHEN target.pr_id IS NULL THEN '舊單已轉採購或不可改，另開差額'
      ELSE '更新原草稿成新總數'
    END AS action_label
  FROM delta d
  JOIN public.group_buy_campaigns gbc
    ON gbc.id = d.campaign_id
  LEFT JOIN public.skus s
    ON s.id = d.sku_id
  LEFT JOIN target
    ON target.campaign_id = d.campaign_id
   AND target.sku_id = d.sku_id
  ORDER BY gbc.end_at DESC NULLS LAST, gbc.id, sku_label;
$$;

REVOKE ALL ON FUNCTION public.rpc_preview_pr_campaign_sku_delta(DATE, BIGINT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_preview_pr_campaign_sku_delta(DATE, BIGINT[]) TO authenticated;

COMMENT ON FUNCTION public.rpc_preview_pr_campaign_sku_delta(DATE, BIGINT[]) IS
  '請購補差額預覽：列出同團+SKU 目前需求、已請購、差額，以及會更新舊草稿或另開差額。';

-- ----------------------------------------------------------------------------
-- 2. Guard v2：同團 + SKU 總請購量不可超過目前需求
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_guard_pr_cross_close_date_duplicate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pr_id        BIGINT;
  v_campaign_id  BIGINT;
  v_sku_id       BIGINT;
  v_tenant       UUID;
  v_source_type  TEXT;
  v_pr_status    TEXT;
  v_demand       NUMERIC;
  v_requested    NUMERIC;
  v_attr_count   INTEGER;
  v_attr_total   NUMERIC;
BEGIN
  IF TG_TABLE_NAME = 'purchase_request_campaigns' THEN
    RETURN NEW;
  ELSIF TG_TABLE_NAME = 'purchase_request_items' THEN
    v_pr_id := NEW.pr_id;
    v_campaign_id := NEW.source_campaign_id;
    v_sku_id := NEW.sku_id;
  ELSIF TG_TABLE_NAME = 'purchase_request_item_campaigns' THEN
    v_campaign_id := NEW.campaign_id;

    SELECT pri.pr_id, pri.sku_id
      INTO v_pr_id, v_sku_id
      FROM public.purchase_request_items pri
     WHERE pri.id = NEW.pr_item_id;

    IF v_pr_id IS NULL THEN
      RETURN NEW;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  SELECT pr.tenant_id, pr.source_type, pr.status
    INTO v_tenant, v_source_type, v_pr_status
    FROM public.purchase_requests pr
   WHERE pr.id = v_pr_id;

  IF v_tenant IS NULL
     OR v_source_type <> 'close_date'
     OR v_pr_status = 'cancelled' THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'purchase_request_items' THEN
    SELECT COUNT(*), COALESCE(SUM(qty_requested), 0)
      INTO v_attr_count, v_attr_total
      FROM public.purchase_request_item_campaigns
     WHERE pr_item_id = NEW.id;

    IF v_attr_count > 0 THEN
      IF v_attr_total <> NEW.qty_requested THEN
        RAISE EXCEPTION '此請購品項已綁定原團明細，總數不可直接改成和明細不同：pr_item_id=%, item_qty=%, detail_qty=%',
          NEW.id, NEW.qty_requested, v_attr_total
          USING HINT = '請回原團追加後重算請購，或先拆清楚歸屬明細再調整。';
      END IF;

      RETURN NEW;
    END IF;

    IF v_campaign_id IS NULL THEN
      RETURN NEW;
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_campaign_id::TEXT), hashtext(v_sku_id::TEXT));

  SELECT COALESCE(SUM(coi.qty), 0)
    INTO v_demand
    FROM public.customer_orders co
    JOIN public.customer_order_items coi
      ON coi.order_id = co.id
   WHERE co.tenant_id = v_tenant
     AND co.campaign_id = v_campaign_id
     AND coi.sku_id = v_sku_id
     AND co.status NOT IN ('cancelled','expired','transferred_out')
     AND coi.status NOT IN ('cancelled','expired');

  WITH attributed AS (
    SELECT SUM(pric.qty_requested) AS qty
      FROM public.purchase_request_item_campaigns pric
      JOIN public.purchase_request_items pri
        ON pri.id = pric.pr_item_id
      JOIN public.purchase_requests pr
        ON pr.id = pri.pr_id
     WHERE pr.tenant_id = v_tenant
       AND pric.tenant_id = v_tenant
       AND pr.status <> 'cancelled'
       AND pric.campaign_id = v_campaign_id
       AND pri.sku_id = v_sku_id
  ),
  direct_legacy AS (
    SELECT SUM(pri.qty_requested) AS qty
      FROM public.purchase_requests pr
      JOIN public.purchase_request_items pri
        ON pri.pr_id = pr.id
     WHERE pr.tenant_id = v_tenant
       AND pr.status <> 'cancelled'
       AND pri.source_campaign_id = v_campaign_id
       AND pri.sku_id = v_sku_id
       AND NOT EXISTS (
         SELECT 1
           FROM public.purchase_request_item_campaigns pric
          WHERE pric.pr_item_id = pri.id
       )
  )
  SELECT COALESCE((SELECT qty FROM attributed), 0)
       + COALESCE((SELECT qty FROM direct_legacy), 0)
    INTO v_requested;

  IF v_requested > v_demand THEN
    RAISE EXCEPTION '同一團同商品請購量超過目前需求：campaign_id=%, sku_id=%, demand=%, requested=%',
      v_campaign_id, v_sku_id, v_demand, v_requested
      USING HINT = '請用補單/針對團購建單補差額，或先取消錯誤草稿。';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.trg_guard_pr_cross_close_date_duplicate() IS
  '請購防重 guard v2：允許同團跨結單日補差額，但禁止同團+SKU 的未取消 PR 總請購量超過目前訂單需求。';

DROP TRIGGER IF EXISTS trg_pri_cross_close_date_duplicate_guard ON public.purchase_request_items;
CREATE TRIGGER trg_pri_cross_close_date_duplicate_guard
AFTER INSERT OR UPDATE OF pr_id, sku_id, source_campaign_id, qty_requested
ON public.purchase_request_items
FOR EACH ROW
EXECUTE FUNCTION public.trg_guard_pr_cross_close_date_duplicate();

DROP TRIGGER IF EXISTS trg_prc_cross_close_date_duplicate_guard ON public.purchase_request_campaigns;
CREATE TRIGGER trg_prc_cross_close_date_duplicate_guard
AFTER INSERT OR UPDATE OF pr_id, campaign_id
ON public.purchase_request_campaigns
FOR EACH ROW
EXECUTE FUNCTION public.trg_guard_pr_cross_close_date_duplicate();

DROP TRIGGER IF EXISTS trg_pric_cross_close_date_duplicate_guard ON public.purchase_request_item_campaigns;
CREATE TRIGGER trg_pric_cross_close_date_duplicate_guard
AFTER INSERT OR UPDATE OF pr_item_id, campaign_id, qty_requested
ON public.purchase_request_item_campaigns
FOR EACH ROW
EXECUTE FUNCTION public.trg_guard_pr_cross_close_date_duplicate();

-- ----------------------------------------------------------------------------
-- 3. 結單日補單：只新增同團 + SKU 差額
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_supplementary_pr_from_close_date(
  p_close_date DATE,
  p_operator   UUID
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_pr_id          BIGINT;
  v_pr_no          TEXT;
  v_dest_loc       BIGINT;
  v_campaign_count INTEGER;
  v_delta_count    INTEGER;
  v_campaign_ids   BIGINT[];
  v_touched_count  INTEGER;
  v_touched_pr_id  BIGINT;
BEGIN
  SELECT array_agg(id ORDER BY id), COUNT(*)
    INTO v_campaign_ids, v_campaign_count
    FROM public.group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status IN ('closed','locked')
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = p_close_date;

  IF v_campaign_count = 0 THEN
    RAISE EXCEPTION 'no closed/locked campaigns on date %', p_close_date;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.purchase_requests pr
     WHERE pr.tenant_id = v_tenant
       AND pr.source_type = 'close_date'
       AND pr.source_close_date = p_close_date
       AND pr.status <> 'cancelled'
  ) AND NOT EXISTS (
    SELECT 1
      FROM public.purchase_requests pr
      JOIN public.purchase_request_items pri
        ON pri.pr_id = pr.id
     WHERE pr.tenant_id = v_tenant
       AND pr.status <> 'cancelled'
       AND pri.source_campaign_id = ANY(v_campaign_ids)
  ) AND NOT EXISTS (
    SELECT 1
      FROM public.purchase_requests pr
      JOIN public.purchase_request_items pri
        ON pri.pr_id = pr.id
      JOIN public.purchase_request_item_campaigns pric
        ON pric.pr_item_id = pri.id
     WHERE pr.tenant_id = v_tenant
       AND pric.tenant_id = v_tenant
       AND pr.status <> 'cancelled'
       AND pric.campaign_id = ANY(v_campaign_ids)
  ) THEN
    RAISE EXCEPTION 'no existing PR for close_date % — use rpc_create_pr_from_close_date instead', p_close_date;
  END IF;

  SELECT id INTO v_dest_loc
    FROM public.locations
   WHERE tenant_id = v_tenant
   ORDER BY id
   LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined for tenant %', v_tenant;
  END IF;

  PERFORM 1
    FROM public.group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND id = ANY(v_campaign_ids)
   ORDER BY id
   FOR UPDATE;

  DROP TABLE IF EXISTS _supp_delta;
  CREATE TEMP TABLE _supp_delta ON COMMIT DROP AS
  SELECT *
    FROM public._pr_campaign_sku_remaining_rows(v_campaign_ids)
   WHERE delta_qty > 0;

  SELECT COUNT(*) INTO v_delta_count FROM _supp_delta;

  IF v_delta_count = 0 THEN
    RAISE EXCEPTION 'no remaining demand to supplement for close_date % (前次請購已涵蓋全部需求)', p_close_date;
  END IF;

  -- 草稿可改就改舊草稿，避免同一團同商品在採購前被拆成兩張 PR。
  DROP TABLE IF EXISTS _supp_target;
  CREATE TEMP TABLE _supp_target ON COMMIT DROP AS
  WITH candidates AS (
    SELECT
      d.campaign_id,
      d.sku_id,
      d.delta_qty,
      pri.id AS pr_item_id,
      pri.pr_id,
      pric.qty_requested AS current_campaign_qty,
      0 AS priority,
      pr.updated_at
    FROM _supp_delta d
    JOIN public.purchase_request_item_campaigns pric
      ON pric.campaign_id = d.campaign_id
    JOIN public.purchase_request_items pri
      ON pri.id = pric.pr_item_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    WHERE pr.tenant_id = v_tenant
      AND pric.tenant_id = v_tenant
      AND pr.status = 'draft'

    UNION ALL

    SELECT
      d.campaign_id,
      d.sku_id,
      d.delta_qty,
      pri.id AS pr_item_id,
      pri.pr_id,
      pri.qty_requested AS current_campaign_qty,
      1 AS priority,
      pr.updated_at
    FROM _supp_delta d
    JOIN public.purchase_request_items pri
      ON pri.source_campaign_id = d.campaign_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    WHERE pr.tenant_id = v_tenant
      AND pr.status = 'draft'
      AND NOT EXISTS (
        SELECT 1
          FROM public.purchase_request_item_campaigns pric
         WHERE pric.pr_item_id = pri.id
           AND pric.campaign_id = d.campaign_id
      )
  ),
  target AS (
    SELECT DISTINCT ON (d.campaign_id, d.sku_id)
      d.campaign_id,
      d.sku_id,
      d.delta_qty,
      d.pr_item_id,
      d.pr_id,
      d.current_campaign_qty
    FROM candidates d
    ORDER BY d.campaign_id, d.sku_id, d.priority, d.updated_at DESC, d.pr_item_id DESC
  )
  SELECT
    campaign_id,
    sku_id,
    delta_qty,
    pr_item_id,
    pr_id,
    current_campaign_qty
  FROM target;

  INSERT INTO public.purchase_request_item_campaigns (
    pr_item_id, campaign_id, tenant_id, qty_requested
  )
  SELECT
    pr_item_id,
    campaign_id,
    v_tenant,
    current_campaign_qty + delta_qty
    FROM _supp_target
  ON CONFLICT (pr_item_id, campaign_id) DO UPDATE
     SET qty_requested = EXCLUDED.qty_requested;

  WITH item_delta AS (
    SELECT pr_item_id, pr_id, SUM(delta_qty) AS delta_qty
      FROM _supp_target
     GROUP BY pr_item_id, pr_id
  )
  UPDATE public.purchase_request_items pri
     SET qty_requested = pri.qty_requested + item_delta.delta_qty,
         updated_by = p_operator,
         updated_at = NOW()
    FROM item_delta
   WHERE pri.id = item_delta.pr_item_id;

  DROP TABLE IF EXISTS _supp_applied;
  CREATE TEMP TABLE _supp_applied ON COMMIT DROP AS
  SELECT
    campaign_id,
    sku_id,
    pr_item_id,
    pr_id,
    current_campaign_qty + delta_qty AS qty_requested
  FROM _supp_target;

  INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT pr_id, campaign_id, v_tenant
    FROM _supp_applied
   GROUP BY pr_id, campaign_id
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM public.purchase_request_items WHERE pr_id = pr.id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id IN (SELECT pr_id FROM _supp_applied);

  DELETE FROM _supp_delta d
    USING _supp_applied a
   WHERE a.campaign_id = d.campaign_id
     AND a.sku_id = d.sku_id;

  SELECT COUNT(DISTINCT pr_id), MIN(pr_id)
    INTO v_touched_count, v_touched_pr_id
    FROM _supp_applied;

  SELECT COUNT(*) INTO v_delta_count FROM _supp_delta;

  IF v_delta_count = 0 THEN
    SELECT array_agg(DISTINCT campaign_id ORDER BY campaign_id)
      INTO v_campaign_ids
      FROM _supp_applied;

    UPDATE public.group_buy_campaigns
       SET status = 'locked',
           updated_by = p_operator,
           updated_at = NOW()
     WHERE tenant_id = v_tenant
       AND status = 'closed'
       AND id = ANY(v_campaign_ids);

    PERFORM public._lock_orders_after_pr_aggregation(v_campaign_ids, p_operator, v_touched_pr_id);

    RETURN v_touched_pr_id;
  END IF;

  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO public.purchase_requests (
    tenant_id, pr_no, source_type, source_close_date,
    source_location_id, status, total_amount, notes,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'close_date', p_close_date,
    v_dest_loc, 'draft', 0,
    format('補單：結單日 %s（同團+SKU 只補未請購差額）', p_close_date),
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  WITH inserted AS (
    INSERT INTO public.purchase_request_items (
      pr_id, sku_id, qty_requested,
      suggested_supplier_id, unit_cost, source_campaign_id,
      created_by, updated_by
    )
    SELECT
      v_pr_id,
      d.sku_id,
      SUM(d.delta_qty) AS qty_requested,
      ss.supplier_id,
      COALESCE(ss.default_unit_cost, 0),
      CASE WHEN COUNT(DISTINCT d.campaign_id) = 1 THEN MIN(d.campaign_id) ELSE NULL::BIGINT END,
      p_operator,
      p_operator
    FROM _supp_delta d
    LEFT JOIN LATERAL (
      SELECT supplier_id, default_unit_cost
        FROM public.supplier_skus
       WHERE tenant_id = v_tenant
         AND sku_id = d.sku_id
         AND is_preferred = TRUE
       LIMIT 1
    ) ss ON TRUE
    GROUP BY d.sku_id, ss.supplier_id, ss.default_unit_cost
    RETURNING id, sku_id
  )
  INSERT INTO public.purchase_request_item_campaigns (
    pr_item_id, campaign_id, tenant_id, qty_requested
  )
  SELECT
    i.id,
    d.campaign_id,
    v_tenant,
    d.delta_qty
  FROM inserted i
  JOIN _supp_delta d
    ON d.sku_id = i.sku_id;

  INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_pr_id, d.campaign_id, v_tenant
    FROM _supp_delta d
   GROUP BY d.campaign_id
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM public.purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  SELECT array_agg(DISTINCT campaign_id ORDER BY campaign_id)
    INTO v_campaign_ids
    FROM _supp_delta;

  UPDATE public.group_buy_campaigns
     SET status = 'locked',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE tenant_id = v_tenant
     AND status = 'closed'
     AND id = ANY(v_campaign_ids);

  PERFORM public._lock_orders_after_pr_aggregation(v_campaign_ids, p_operator, v_pr_id);

  RETURN v_pr_id;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_supplementary_pr_from_close_date(DATE, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_supplementary_pr_from_close_date(DATE, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_supplementary_pr_from_close_date(DATE, UUID) IS
  '結單日補單：以同團+SKU 扣掉未取消 PR 已請購量；舊品項仍是草稿且未拆 PO 時先更新舊草稿，否則新增差額 PR。';

-- ----------------------------------------------------------------------------
-- 4. 補單列表：remaining_qty 不再因結單日改變重列全量
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_list_supplementable_close_dates()
RETURNS TABLE(
  close_date     DATE,
  campaign_count INTEGER,
  remaining_skus INTEGER,
  remaining_qty  NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH t AS (
    SELECT public._current_tenant_id() AS tid
  ),
  recent_campaigns AS (
    SELECT
      gbc.id,
      DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') AS close_date
    FROM public.group_buy_campaigns gbc
    CROSS JOIN t
    WHERE gbc.tenant_id = t.tid
      AND gbc.status IN ('closed','locked')
      AND gbc.end_at >= NOW() - INTERVAL '60 days'
  ),
  eligible_campaigns AS (
    SELECT rc.id, rc.close_date
      FROM recent_campaigns rc
      CROSS JOIN t
     WHERE EXISTS (
       SELECT 1
         FROM public.purchase_requests pr
        WHERE pr.tenant_id = t.tid
          AND pr.source_type = 'close_date'
          AND pr.source_close_date = rc.close_date
          AND pr.status <> 'cancelled'
     )
     OR EXISTS (
       SELECT 1
         FROM public.purchase_requests pr
         JOIN public.purchase_request_items pri
           ON pri.pr_id = pr.id
        WHERE pr.tenant_id = t.tid
          AND pr.status <> 'cancelled'
          AND pri.source_campaign_id = rc.id
     )
     OR EXISTS (
       SELECT 1
         FROM public.purchase_requests pr
         JOIN public.purchase_request_items pri
           ON pri.pr_id = pr.id
         JOIN public.purchase_request_item_campaigns pric
           ON pric.pr_item_id = pri.id
        WHERE pr.tenant_id = t.tid
          AND pric.tenant_id = t.tid
          AND pr.status <> 'cancelled'
          AND pric.campaign_id = rc.id
     )
  ),
  delta AS (
    SELECT
      ec.close_date,
      d.campaign_id,
      d.sku_id,
      d.delta_qty
    FROM eligible_campaigns ec
    CROSS JOIN LATERAL public._pr_campaign_sku_remaining_rows(ARRAY[ec.id]) d
    WHERE d.delta_qty > 0
  )
  SELECT
    del.close_date,
    (SELECT COUNT(*)::INTEGER
       FROM recent_campaigns rc
      WHERE rc.close_date = del.close_date) AS campaign_count,
    COUNT(DISTINCT del.sku_id)::INTEGER AS remaining_skus,
    COALESCE(SUM(del.delta_qty), 0) AS remaining_qty
  FROM delta del
  GROUP BY del.close_date
  ORDER BY del.close_date DESC;
$$;

REVOKE ALL ON FUNCTION public.rpc_list_supplementable_close_dates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_list_supplementable_close_dates() TO authenticated;

COMMENT ON FUNCTION public.rpc_list_supplementable_close_dates() IS
  '列近 60 天可補請購日期；remaining_qty 改用同團+SKU 剩餘差額，避免延長結單日後重列全量。';

-- ----------------------------------------------------------------------------
-- 5. 針對團購建單：只新增同團 + SKU 差額
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_campaigns(
  p_campaign_ids BIGINT[],
  p_operator     UUID
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_pr_id          BIGINT;
  v_pr_no          TEXT;
  v_dest_loc       BIGINT;
  v_delta_count    INTEGER;
  v_min_close_date DATE;
  v_campaign_ids   BIGINT[];
  v_touched_count  INTEGER;
  v_touched_pr_id  BIGINT;
BEGIN
  IF p_campaign_ids IS NULL OR array_length(p_campaign_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_campaign_ids is empty';
  END IF;

  SELECT array_agg(DISTINCT cid ORDER BY cid)
    INTO v_campaign_ids
    FROM unnest(p_campaign_ids) AS ids(cid);

  IF EXISTS (
    SELECT 1
      FROM public.group_buy_campaigns
     WHERE id = ANY(v_campaign_ids)
       AND (tenant_id <> v_tenant
            OR status NOT IN ('closed','locked','ordered','receiving','ready','completed'))
  ) THEN
    RAISE EXCEPTION 'some campaigns not in tenant or not closed yet';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.group_buy_campaigns
     WHERE id = ANY(v_campaign_ids)
       AND owner_store_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '店家自開團不能併進總倉請購單（該團的貨由店家自行採購）';
  END IF;

  SELECT MIN(DATE(end_at AT TIME ZONE 'Asia/Taipei')) INTO v_min_close_date
    FROM public.group_buy_campaigns
   WHERE id = ANY(v_campaign_ids);

  SELECT id INTO v_dest_loc
    FROM public.locations
   WHERE tenant_id = v_tenant
   ORDER BY id
   LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined';
  END IF;

  PERFORM 1
    FROM public.group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND id = ANY(v_campaign_ids)
   ORDER BY id
   FOR UPDATE;

  DROP TABLE IF EXISTS _camp_pr_delta;
  CREATE TEMP TABLE _camp_pr_delta ON COMMIT DROP AS
  SELECT *
    FROM public._pr_campaign_sku_remaining_rows(v_campaign_ids)
   WHERE delta_qty > 0;

  SELECT COUNT(*) INTO v_delta_count FROM _camp_pr_delta;

  IF v_delta_count = 0 THEN
    RAISE EXCEPTION '所選團購的需求已全數納入既有請購單，沒有可補的請購量';
  END IF;

  -- 草稿可改就改舊草稿，避免追加後又多一張只差 37 的 PR。
  DROP TABLE IF EXISTS _camp_pr_target;
  CREATE TEMP TABLE _camp_pr_target ON COMMIT DROP AS
  WITH candidates AS (
    SELECT
      d.campaign_id,
      d.sku_id,
      d.delta_qty,
      pri.id AS pr_item_id,
      pri.pr_id,
      pric.qty_requested AS current_campaign_qty,
      0 AS priority,
      pr.updated_at
    FROM _camp_pr_delta d
    JOIN public.purchase_request_item_campaigns pric
      ON pric.campaign_id = d.campaign_id
    JOIN public.purchase_request_items pri
      ON pri.id = pric.pr_item_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    WHERE pr.tenant_id = v_tenant
      AND pric.tenant_id = v_tenant
      AND pr.status = 'draft'

    UNION ALL

    SELECT
      d.campaign_id,
      d.sku_id,
      d.delta_qty,
      pri.id AS pr_item_id,
      pri.pr_id,
      pri.qty_requested AS current_campaign_qty,
      1 AS priority,
      pr.updated_at
    FROM _camp_pr_delta d
    JOIN public.purchase_request_items pri
      ON pri.source_campaign_id = d.campaign_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    WHERE pr.tenant_id = v_tenant
      AND pr.status = 'draft'
      AND NOT EXISTS (
        SELECT 1
          FROM public.purchase_request_item_campaigns pric
         WHERE pric.pr_item_id = pri.id
           AND pric.campaign_id = d.campaign_id
      )
  ),
  target AS (
    SELECT DISTINCT ON (d.campaign_id, d.sku_id)
      d.campaign_id,
      d.sku_id,
      d.delta_qty,
      d.pr_item_id,
      d.pr_id,
      d.current_campaign_qty
    FROM candidates d
    ORDER BY d.campaign_id, d.sku_id, d.priority, d.updated_at DESC, d.pr_item_id DESC
  )
  SELECT
    campaign_id,
    sku_id,
    delta_qty,
    pr_item_id,
    pr_id,
    current_campaign_qty
  FROM target;

  INSERT INTO public.purchase_request_item_campaigns (
    pr_item_id, campaign_id, tenant_id, qty_requested
  )
  SELECT
    pr_item_id,
    campaign_id,
    v_tenant,
    current_campaign_qty + delta_qty
    FROM _camp_pr_target
  ON CONFLICT (pr_item_id, campaign_id) DO UPDATE
     SET qty_requested = EXCLUDED.qty_requested;

  WITH item_delta AS (
    SELECT pr_item_id, pr_id, SUM(delta_qty) AS delta_qty
      FROM _camp_pr_target
     GROUP BY pr_item_id, pr_id
  )
  UPDATE public.purchase_request_items pri
     SET qty_requested = pri.qty_requested + item_delta.delta_qty,
         updated_by = p_operator,
         updated_at = NOW()
    FROM item_delta
   WHERE pri.id = item_delta.pr_item_id;

  DROP TABLE IF EXISTS _camp_pr_applied;
  CREATE TEMP TABLE _camp_pr_applied ON COMMIT DROP AS
  SELECT
    campaign_id,
    sku_id,
    pr_item_id,
    pr_id,
    current_campaign_qty + delta_qty AS qty_requested
  FROM _camp_pr_target;

  INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT pr_id, campaign_id, v_tenant
    FROM _camp_pr_applied
   GROUP BY pr_id, campaign_id
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM public.purchase_request_items WHERE pr_id = pr.id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id IN (SELECT pr_id FROM _camp_pr_applied);

  DELETE FROM _camp_pr_delta d
    USING _camp_pr_applied a
   WHERE a.campaign_id = d.campaign_id
     AND a.sku_id = d.sku_id;

  SELECT COUNT(DISTINCT pr_id), MIN(pr_id)
    INTO v_touched_count, v_touched_pr_id
    FROM _camp_pr_applied;

  SELECT COUNT(*) INTO v_delta_count FROM _camp_pr_delta;

  IF v_delta_count = 0 THEN
    RETURN v_touched_pr_id;
  END IF;

  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO public.purchase_requests (
    tenant_id, pr_no, source_type, source_close_date,
    source_location_id, status, total_amount, notes,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'close_date', v_min_close_date,
    v_dest_loc, 'draft', 0,
    '針對團購建單（同團+SKU 只帶尚未請購的差額）',
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_pr_id, unnest(v_campaign_ids), v_tenant
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  WITH inserted AS (
    INSERT INTO public.purchase_request_items (
      pr_id, sku_id, qty_requested,
      suggested_supplier_id, unit_cost,
      retail_price, franchise_price,
      source_campaign_id,
      created_by, updated_by
    )
    SELECT
      v_pr_id,
      d.sku_id,
      SUM(d.delta_qty) AS qty_requested,
      ss.supplier_id,
      COALESCE(ss.default_unit_cost, 0),
      pr_retail.price,
      pr_franchise.price,
      CASE WHEN COUNT(DISTINCT d.campaign_id) = 1 THEN MIN(d.campaign_id) ELSE NULL::BIGINT END,
      p_operator,
      p_operator
    FROM _camp_pr_delta d
    LEFT JOIN LATERAL (
      SELECT supplier_id, default_unit_cost
        FROM public.supplier_skus
       WHERE tenant_id = v_tenant
         AND sku_id = d.sku_id
         AND is_preferred = TRUE
       LIMIT 1
    ) ss ON TRUE
    LEFT JOIN LATERAL (
      SELECT price
        FROM public.prices
       WHERE sku_id = d.sku_id
         AND scope = 'retail'
       ORDER BY effective_from DESC NULLS LAST
       LIMIT 1
    ) pr_retail ON TRUE
    LEFT JOIN LATERAL (
      SELECT price
        FROM public.prices
       WHERE sku_id = d.sku_id
         AND scope = 'franchise'
       ORDER BY effective_from DESC NULLS LAST
       LIMIT 1
    ) pr_franchise ON TRUE
    GROUP BY d.sku_id, ss.supplier_id, ss.default_unit_cost, pr_retail.price, pr_franchise.price
    RETURNING id, sku_id
  )
  INSERT INTO public.purchase_request_item_campaigns (
    pr_item_id, campaign_id, tenant_id, qty_requested
  )
  SELECT
    i.id,
    d.campaign_id,
    v_tenant,
    d.delta_qty
  FROM inserted i
  JOIN _camp_pr_delta d
    ON d.sku_id = i.sku_id;

  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM public.purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  RETURN v_pr_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_pr_from_campaigns(BIGINT[], UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_pr_from_campaigns(BIGINT[], UUID) IS
  '從多選 campaigns 建 PR：以同團+SKU 扣掉未取消 PR 已請購量；舊品項仍是草稿且未拆 PO 時先更新舊草稿，否則新增差額 PR；不改團狀態。';

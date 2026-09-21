-- ============================================================================
-- Guard: stop close_date PRs from re-purchasing the same campaign + SKU under
-- another close date.
--
-- Why:
--   A campaign can move from one close date to another after an old PR draft
--   already exists. Date-based PR logic then sees a fresh close_date bucket and
--   may create a second full PR, for example old 9/17 qty 116 + new 9/18 qty
--   153. This first guard does not update 116->153 and does not auto-create
--   the 37 delta; it stops the suspicious write and asks for manual review.
--
-- Scope:
--   - Append-only guard only.
--   - No production data repair SQL.
--   - No frontend change.
--   - No Alex helper-add/order-qty entry point change.
--
-- Conservative detection:
--   A close_date PR can be linked to campaigns by either
--   purchase_request_items.source_campaign_id or purchase_request_campaigns.
--   Item-level source_campaign_id is direct evidence. Header-level
--   purchase_request_campaigns is only evidence when customer orders prove that
--   campaign had this SKU before the campaign was linked to the existing PR.
--   This keeps the guard from blocking "same SKU, different campaign" by
--   header link alone while still covering rpc_append_campaign_to_pr.
--
-- Rollback:
--   If this guard blocks a legitimate emergency operation and the previous
--   function definitions are hard to redeploy immediately, disable only these
--   triggers first:
--     ALTER TABLE public.purchase_request_items
--       DISABLE TRIGGER trg_pri_cross_close_date_duplicate_guard;
--     ALTER TABLE public.purchase_request_campaigns
--       DISABLE TRIGGER trg_prc_cross_close_date_duplicate_guard;
--   To fully remove this migration's behavior:
--     DROP TRIGGER IF EXISTS trg_pri_cross_close_date_duplicate_guard
--       ON public.purchase_request_items;
--     DROP TRIGGER IF EXISTS trg_prc_cross_close_date_duplicate_guard
--       ON public.purchase_request_campaigns;
--     DROP FUNCTION IF EXISTS public.trg_guard_pr_cross_close_date_duplicate();
--   Do not run data-fix SQL as rollback for this migration.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.trg_guard_pr_cross_close_date_duplicate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_hit RECORD;
  v_has_hit BOOLEAN := FALSE;
BEGIN
  IF TG_TABLE_NAME = 'purchase_request_items' THEN
    WITH new_lines AS (
      SELECT DISTINCT
        pr.tenant_id,
        pr.id AS pr_id,
        pr.pr_no,
        pr.source_close_date,
        NEW.sku_id,
        NEW.qty_requested AS qty_requested,
        linked.campaign_id
      FROM purchase_requests pr
      JOIN LATERAL (
        SELECT NEW.source_campaign_id AS campaign_id
         WHERE NEW.source_campaign_id IS NOT NULL
        UNION
        SELECT prc.campaign_id
          FROM purchase_request_campaigns prc
         WHERE prc.pr_id = NEW.pr_id
           AND EXISTS (
             SELECT 1
               FROM customer_orders co
               JOIN customer_order_items coi ON coi.order_id = co.id
              WHERE co.campaign_id = prc.campaign_id
                AND co.tenant_id = pr.tenant_id
                AND co.status NOT IN ('cancelled','expired','transferred_out')
                AND coi.status NOT IN ('cancelled','expired')
                AND coi.sku_id = NEW.sku_id
           )
      ) linked ON TRUE
      WHERE pr.id = NEW.pr_id
        AND pr.source_type = 'close_date'
        AND pr.source_close_date IS NOT NULL
        AND pr.status <> 'cancelled'
    )
    SELECT
      nl.pr_no AS new_pr_no,
      nl.source_close_date AS new_close_date,
      nl.qty_requested AS new_qty,
      other_pr.pr_no AS existing_pr_no,
      other_pr.source_close_date AS existing_close_date,
      other_pri.qty_requested AS existing_qty,
      nl.campaign_id,
      gbc.campaign_no,
      nl.sku_id
    INTO v_hit
    FROM new_lines nl
    JOIN purchase_requests other_pr
      ON other_pr.tenant_id = nl.tenant_id
     AND other_pr.id <> nl.pr_id
     AND other_pr.source_type = 'close_date'
     AND other_pr.source_close_date IS NOT NULL
     AND other_pr.source_close_date <> nl.source_close_date
     AND other_pr.status <> 'cancelled'
    JOIN purchase_request_items other_pri
      ON other_pri.pr_id = other_pr.id
     AND other_pri.sku_id = nl.sku_id
    LEFT JOIN purchase_request_campaigns other_prc
      ON other_prc.pr_id = other_pr.id
     AND other_prc.campaign_id = nl.campaign_id
    LEFT JOIN group_buy_campaigns gbc
      ON gbc.id = nl.campaign_id
    WHERE other_pri.source_campaign_id = nl.campaign_id
       OR (
         other_prc.campaign_id IS NOT NULL
         AND EXISTS (
           SELECT 1
             FROM customer_orders co
             JOIN customer_order_items coi ON coi.order_id = co.id
            WHERE co.campaign_id = nl.campaign_id
              AND co.tenant_id = nl.tenant_id
              AND co.status NOT IN ('cancelled','expired','transferred_out')
              AND coi.status NOT IN ('cancelled','expired')
              AND coi.sku_id = nl.sku_id
              AND co.created_at <= other_prc.created_at
              AND coi.created_at <= other_prc.created_at
         )
       )
    ORDER BY other_pr.source_close_date, other_pr.id
    LIMIT 1;
    v_has_hit := FOUND;

  ELSIF TG_TABLE_NAME = 'purchase_request_campaigns' THEN
    WITH new_lines AS (
      SELECT DISTINCT
        pr.tenant_id,
        pr.id AS pr_id,
        pr.pr_no,
        pr.source_close_date,
        pri.sku_id,
        pri.qty_requested,
        NEW.campaign_id
      FROM purchase_requests pr
      JOIN purchase_request_items pri
        ON pri.pr_id = pr.id
      WHERE pr.id = NEW.pr_id
        AND pr.source_type = 'close_date'
        AND pr.source_close_date IS NOT NULL
        AND pr.status <> 'cancelled'
        AND EXISTS (
          SELECT 1
            FROM customer_orders co
            JOIN customer_order_items coi ON coi.order_id = co.id
           WHERE co.campaign_id = NEW.campaign_id
             AND co.tenant_id = pr.tenant_id
             AND co.status NOT IN ('cancelled','expired','transferred_out')
             AND coi.status NOT IN ('cancelled','expired')
             AND coi.sku_id = pri.sku_id
        )
    )
    SELECT
      nl.pr_no AS new_pr_no,
      nl.source_close_date AS new_close_date,
      nl.qty_requested AS new_qty,
      other_pr.pr_no AS existing_pr_no,
      other_pr.source_close_date AS existing_close_date,
      other_pri.qty_requested AS existing_qty,
      nl.campaign_id,
      gbc.campaign_no,
      nl.sku_id
    INTO v_hit
    FROM new_lines nl
    JOIN purchase_requests other_pr
      ON other_pr.tenant_id = nl.tenant_id
     AND other_pr.id <> nl.pr_id
     AND other_pr.source_type = 'close_date'
     AND other_pr.source_close_date IS NOT NULL
     AND other_pr.source_close_date <> nl.source_close_date
     AND other_pr.status <> 'cancelled'
    JOIN purchase_request_items other_pri
      ON other_pri.pr_id = other_pr.id
     AND other_pri.sku_id = nl.sku_id
    LEFT JOIN purchase_request_campaigns other_prc
      ON other_prc.pr_id = other_pr.id
     AND other_prc.campaign_id = nl.campaign_id
    LEFT JOIN group_buy_campaigns gbc
      ON gbc.id = nl.campaign_id
    WHERE other_pri.source_campaign_id = nl.campaign_id
       OR (
         other_prc.campaign_id IS NOT NULL
         AND EXISTS (
           SELECT 1
             FROM customer_orders co
             JOIN customer_order_items coi ON coi.order_id = co.id
            WHERE co.campaign_id = nl.campaign_id
              AND co.tenant_id = nl.tenant_id
              AND co.status NOT IN ('cancelled','expired','transferred_out')
              AND coi.status NOT IN ('cancelled','expired')
              AND coi.sku_id = nl.sku_id
              AND co.created_at <= other_prc.created_at
              AND coi.created_at <= other_prc.created_at
         )
       )
    ORDER BY other_pr.source_close_date, other_pr.id
    LIMIT 1;
    v_has_hit := FOUND;
  END IF;

  IF v_has_hit THEN
    RAISE EXCEPTION
      '同一團同商品已在其他結單日請購過。團 %, 商品 SKU %, 舊 PR %（結單日 %, 數量 %）, 本次 PR %（結單日 %, 數量 %）。為避免重複請購已停止；請人工確認舊 PR 要作廢、更新，或另外只補差額。',
      COALESCE(v_hit.campaign_no, v_hit.campaign_id::TEXT),
      v_hit.sku_id,
      v_hit.existing_pr_no,
      v_hit.existing_close_date,
      v_hit.existing_qty,
      v_hit.new_pr_no,
      v_hit.new_close_date,
      v_hit.new_qty;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.trg_guard_pr_cross_close_date_duplicate() IS
  '防止同一 campaign + sku 被寫進不同 close_date 的未取消 PR，避免改結單日後又建立第二張全量請購單。';

DROP TRIGGER IF EXISTS trg_pri_cross_close_date_duplicate_guard
  ON public.purchase_request_items;
CREATE TRIGGER trg_pri_cross_close_date_duplicate_guard
AFTER INSERT OR UPDATE OF pr_id, sku_id, source_campaign_id, qty_requested
ON public.purchase_request_items
FOR EACH ROW
EXECUTE FUNCTION public.trg_guard_pr_cross_close_date_duplicate();

DROP TRIGGER IF EXISTS trg_prc_cross_close_date_duplicate_guard
  ON public.purchase_request_campaigns;
CREATE TRIGGER trg_prc_cross_close_date_duplicate_guard
AFTER INSERT OR UPDATE OF pr_id, campaign_id
ON public.purchase_request_campaigns
FOR EACH ROW
EXECUTE FUNCTION public.trg_guard_pr_cross_close_date_duplicate();

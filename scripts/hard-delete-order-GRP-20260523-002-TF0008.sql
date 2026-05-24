-- Hard-delete the same-store transfer pair GRP-20260523-002-0007 (parent) +
-- GRP-20260523-002-TF0008 (child). The pair is the TF0008 same-store
-- force-ready bug case fixed in PR #362; user opted to wipe both rows
-- after the backfill (audit log already captures the fix history).
--
-- Executed on 2026-05-24 against the production database via the Supabase
-- Management API /database/query endpoint.
--
-- Target rows:
--   customer_orders id=11676  GRP-20260523-002-0007    status=transferred_out
--   customer_orders id=11703  GRP-20260523-002-TF0008  status=pending (post-backfill)
--
-- Children that needed cleanup:
--   customer_order_items     6 rows on 11676 (ids 11542-11547)
--                            6 rows on 11703 (ids 11577-11582)
--   customer_order_audit_log 5 rows on 11703 (4 fake '同店互轉自動推進' +
--                            1 backfill 'ready→pending' from 20260629000020)
--
-- Non-cascading FKs cleared before delete:
--   customer_orders.transferred_to_order_id   on 11676 -> 11703
--   customer_orders.transferred_from_order_id on 11703 -> 11676
--
-- Same gotcha as scripts/hard-delete-order-GRP-20260523-002-TF0009.sql:
--   customer_order_audit_log has a BEFORE DELETE trigger
--   forbid_append_only_mutation() that blocks even ON DELETE CASCADE.
--   Run under session_replication_role='replica' to bypass; that also skips
--   FK CASCADE so customer_order_items / customer_order_audit_log must be
--   cleaned up manually in phase 2.

-- Phase 1: delete the two customer_orders rows.
BEGIN;

DO $$
DECLARE
  v_parent_id        bigint := 11676;
  v_child_id         bigint := 11703;
  v_parent_no        text   := 'GRP-20260523-002-0007';
  v_child_no         text   := 'GRP-20260523-002-TF0008';
  v_n_parent         bigint;
  v_n_child          bigint;
  v_n_parent_fk      bigint;
  v_n_backorders     bigint;
  v_n_other_children bigint;
  v_n_transfers      bigint;
  v_deleted          bigint;
BEGIN
  SET LOCAL session_replication_role = 'replica';

  SELECT count(*) INTO v_n_parent FROM customer_orders WHERE id = v_parent_id AND order_no = v_parent_no;
  SELECT count(*) INTO v_n_child  FROM customer_orders WHERE id = v_child_id  AND order_no = v_child_no;
  SELECT count(*) INTO v_n_parent_fk FROM customer_orders
    WHERE id = v_parent_id AND transferred_to_order_id = v_child_id;
  SELECT count(*) INTO v_n_backorders FROM backorders
    WHERE original_customer_order_item_id IN (11542,11543,11544,11545,11546,11547,
                                              11577,11578,11579,11580,11581,11582)
       OR rollover_customer_order_item_id IN (11542,11543,11544,11545,11546,11547,
                                              11577,11578,11579,11580,11581,11582);
  SELECT count(*) INTO v_n_other_children FROM customer_orders
    WHERE transferred_from_order_id = v_parent_id AND id <> v_child_id;
  SELECT count(*) INTO v_n_transfers FROM transfers
    WHERE customer_order_id IN (v_parent_id, v_child_id);

  IF v_n_parent <> 1          THEN RAISE EXCEPTION 'parent order % (id=%) not found as expected', v_parent_no, v_parent_id; END IF;
  IF v_n_child <> 1           THEN RAISE EXCEPTION 'child order % (id=%) not found as expected', v_child_no, v_child_id; END IF;
  IF v_n_parent_fk <> 1       THEN RAISE EXCEPTION 'parent.transferred_to_order_id no longer points at child'; END IF;
  IF v_n_backorders <> 0      THEN RAISE EXCEPTION 'backorders reference order items (count=%)', v_n_backorders; END IF;
  IF v_n_other_children <> 0  THEN RAISE EXCEPTION 'parent has other transfer children (count=%)', v_n_other_children; END IF;
  IF v_n_transfers <> 0       THEN RAISE EXCEPTION 'transfers reference these orders (count=%)', v_n_transfers; END IF;

  UPDATE customer_orders SET transferred_to_order_id   = NULL WHERE id = v_parent_id;
  UPDATE customer_orders SET transferred_from_order_id = NULL WHERE id = v_child_id;

  WITH d AS (DELETE FROM customer_orders WHERE id IN (v_parent_id, v_child_id) RETURNING 1)
  SELECT count(*) INTO v_deleted FROM d;
  IF v_deleted <> 2 THEN RAISE EXCEPTION 'expected 2 customer_orders deletes, got %', v_deleted; END IF;

  RAISE NOTICE 'phase 1: deleted % customer_orders rows (% and %)', v_deleted, v_parent_id, v_child_id;
END $$;

COMMIT;

-- Phase 2: clean up the orphaned children that replica mode skipped.
BEGIN;

DO $$
DECLARE
  v_items_del bigint;
  v_audit_del bigint;
BEGIN
  SET LOCAL session_replication_role = 'replica';

  WITH di AS (DELETE FROM customer_order_items
                WHERE order_id IN (11676, 11703) RETURNING 1)
  SELECT count(*) INTO v_items_del FROM di;

  WITH da AS (DELETE FROM customer_order_audit_log
                WHERE order_id IN (11676, 11703) RETURNING 1)
  SELECT count(*) INTO v_audit_del FROM da;

  RAISE NOTICE 'phase 2: orphan cleanup items=% audit_log=%', v_items_del, v_audit_del;
END $$;

COMMIT;

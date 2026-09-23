import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function read(path) {
  return readFileSync(resolve(root, path), "utf8");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const migration = read("supabase/migrations/20260923120000_pr_draft_store_additions.sql");
const page = read("apps/admin/src/app/(protected)/purchase/requests/edit/page.tsx");
const migrationWithoutComments = migration.replace(/--.*$/gm, "");

assert(
  migration.includes("CREATE OR REPLACE FUNCTION public.rpc_add_pr_store_demands"),
  "migration must add the draft PR store-addition RPC",
);
assert(
  migration.includes("public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id])"),
  "RPC must reuse the existing readonly campaign/SKU delta helper",
);
assert(
  migration.includes("p_request_key  UUID") &&
    migration.includes("pg_advisory_xact_lock(hashtext('pr_store_add:'") &&
    migration.includes("request key already used"),
  "RPC must have a request key and idempotency guard",
);
assert(
  !migrationWithoutComments.includes("rpc_create_pr_from_close_date(") &&
    !migrationWithoutComments.includes("rpc_create_supplementary_pr_from_close_date(") &&
    !migrationWithoutComments.includes("rpc_create_pr_from_campaigns(") &&
    !migrationWithoutComments.includes("rpc_append_campaign_to_pr("),
  "store additions must not call the broad PR creation/rebuild RPCs",
);
assert(
  migration.includes("v_pr.po_item_id IS NOT NULL"),
  "RPC must block PR items that were already split to PO",
);
assert(
  migration.includes("r.store_id, 'confirmed', NOW(), 'normal'"),
  "new internal store orders must be confirmed, not pending",
);
assert(
  !migration.includes("_lock_orders_after_pr_aggregation") &&
    migration.includes("_pr_store_add_remaining") &&
    migration.includes("safe_orders") &&
    migration.includes("coi.sku_id = v_pr.sku_id") &&
    migration.includes("_pr_store_add_touched_pending_orders") &&
    migration.includes("不能安全加單"),
  "RPC must avoid broad whole-campaign confirmation and only confirm safely covered pending orders",
);
assert(
  migration.includes("COALESCE(s.store_kind, 'branch') = 'branch'") &&
    page.includes('.eq("store_kind", "branch")'),
  "store additions must only allow branch stores, not wholesale stores",
);
assert(
  migration.includes("REVOKE ALL ON public.purchase_request_store_additions FROM authenticated") &&
    migration.includes("GRANT SELECT ON public.purchase_request_store_additions TO authenticated") &&
    !migration.includes("GRANT SELECT, INSERT, UPDATE ON public.purchase_request_store_additions"),
  "audit table must not be directly writable by authenticated clients",
);
assert(
  migration.includes("purchase_request_item_campaigns") &&
    migration.includes("qty_requested = qty_requested + v_pr_delta_qty"),
  "RPC must sync both source-campaign detail and PR item quantity",
);

assert(
  page.includes("分店加單") && page.includes("rpc_add_pr_store_demands") && page.includes("p_request_key: storeAddModal.requestKey"),
  "PR edit page must expose the store-addition action and pass the request key",
);
assert(
  page.includes("store_added_qty") && page.includes("pr_delta_qty"),
  "UI must report store-added quantity separately from PR delta quantity",
);

console.log("PR store additions check passed.");

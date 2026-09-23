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
const allowedStoreAdditionRoles = new Set(["owner", "admin", "hq_manager", "purchaser", "assistant", ""]);

function canCallStoreAdditionRpc(claims) {
  const role = claims.app_metadata?.role ?? "";
  if (role === "store_manager" || role === "store_staff") return false;
  return allowedStoreAdditionRoles.has(role);
}

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
    migration.includes("SELECT string_agg(DISTINCT co.order_no") &&
    migration.includes("請先處理舊待確認店內單或對原團補請購後再加單"),
  "RPC must avoid broad whole-campaign confirmation and only confirm safely covered pending orders",
);
assert(
  migration.includes("COALESCE(s.store_kind, 'branch') = 'branch'") &&
    page.includes('.eq("store_kind", "branch")'),
  "store additions must only allow branch stores, not wholesale stores",
);
assert(
  migration.includes("AND aid_board_id IS NULL") &&
    migration.includes("AND order_no NOT LIKE 'SP-%'") &&
    migration.includes("AND order_no NOT LIKE 'WS-%'") &&
    migration.includes("ORDER BY id") &&
    migration.includes("LIMIT 1"),
  "existing internal order lookup must match customer_orders_trio_kind_active_uniq and be deterministic",
);
assert(
  migration.includes("SELECT SUM(pri.line_subtotal)") &&
    !migration.includes("SELECT SUM(pri.qty_requested * pri.unit_cost)"),
  "PR total must use line_subtotal, matching the rest of the purchase flow",
);
assert(
  migration.includes("v_role                   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')") &&
    migration.includes("IF v_role IN ('store_manager','store_staff') THEN") &&
    migration.includes("IF v_role NOT IN ('owner','admin','hq_manager','purchaser','assistant','') THEN"),
  "RPC must match purchase-module legacy admin role behavior while explicitly blocking store roles",
);
assert(canCallStoreAdditionRpc({ app_metadata: { role: "" }, role: "authenticated" }), "explicit legacy empty app role must be allowed");
assert(canCallStoreAdditionRpc({ app_metadata: {}, role: "authenticated" }), "missing app role must follow purchase-module legacy admin behavior");
assert(canCallStoreAdditionRpc({ role: "authenticated" }), "missing app_metadata must follow purchase-module legacy admin behavior");
assert(!canCallStoreAdditionRpc({ app_metadata: { role: "store_manager" }, role: "authenticated" }), "store_manager must be blocked");
assert(!canCallStoreAdditionRpc({ app_metadata: { role: "store_staff" }, role: "authenticated" }), "store_staff must be blocked");
assert(canCallStoreAdditionRpc({ app_metadata: { role: "purchaser" }, role: "authenticated" }), "purchaser must be allowed");
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

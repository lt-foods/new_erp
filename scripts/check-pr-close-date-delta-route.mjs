import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function read(path) {
  return readFileSync(resolve(root, path), "utf8");
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const page = read("apps/admin/src/app/(protected)/purchase/requests/page.tsx");
const migration = read(
  "supabase/migrations/20260923090000_pr_close_date_entry_uses_delta.sql",
);

assert(
  page.includes('{ kind: "closeDate"; closeDate: string }'),
  "close-date cards must have their own preview intent",
);
assert(
  page.includes("async function handleImport(group: CloseDateGroup)"),
  "pending close-date cards must pass their campaign group into preview",
);
assert(
  page.includes('kind: "closeDate"') && page.includes("executeImport(previewIntent.closeDate)"),
  "close-date confirmation must call the close-date RPC after preview",
);
assert(
  page.includes('intent.kind === "supplement" || intent.kind === "closeDate"') &&
    page.includes('p_campaign_ids: intent.kind === "campaigns"'),
  "close-date previews must use the same close-date scope as close-date confirmation",
);

assert(
  migration.includes("CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_close_date"),
  "migration must rebuild rpc_create_pr_from_close_date",
);
assert(
  migration.includes("public._pr_campaign_sku_remaining_rows(v_campaign_ids)"),
  "close-date RPC must calculate remaining demand by campaign and SKU",
);
assert(
  migration.includes("current_campaign_qty + delta_qty"),
  "close-date RPC must update editable old draft quantities instead of duplicating them",
);
assert(
  migration.includes("public._lock_orders_after_pr_aggregation(v_all_campaign_ids"),
  "close-date RPC must still lock the affected campaigns and orders",
);
assert(
  !migration.includes("SUM(coi.qty) AS qty_total"),
  "close-date RPC must not use the old full-quantity aggregation",
);

console.log("PR close-date delta route check passed.");

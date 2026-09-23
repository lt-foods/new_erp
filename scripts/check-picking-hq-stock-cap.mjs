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

const page = read("apps/admin/src/app/(protected)/wms/picking/page.tsx");
const migration = read("supabase/migrations/20260923110000_wave_from_po_hq_stock_cap.sql");

assert(
  page.includes(".select(\"sku_id, on_hand, reserved\")"),
  "picking workbench must read reserved together with on_hand",
);
assert(
  page.includes("Math.max(0, Number(r.on_hand) - Number(r.reserved ?? 0))"),
  "picking workbench must calculate HQ available as on_hand - reserved",
);
assert(
  page.includes("sb.from(\"picking_waves\")") &&
    page.includes(".in(\"status\", [\"draft\", \"picking\", \"picked\"])") &&
    page.includes("sb.from(\"picking_wave_items\")"),
  "picking workbench must subtract existing unshipped picking waves from HQ available stock",
);
assert(
  page.includes("Math.max(0, (hq.get(skuId) ?? 0) - qty)"),
  "picking workbench HQ cap must subtract open-wave reserved quantity",
);
assert(
  page.includes("capSkuAvailable(s.sku_id, s.poAvailable, hqAvailable)"),
  "SKU totalAvailable must be capped by HQ available stock",
);
assert(
  page.includes("庫存封頂") && page.includes("cappedByHq"),
  "picking UI must disclose when HQ stock caps the PO quantity",
);

assert(
  migration.includes("rpc_create_wave_from_po") &&
    migration.includes("stock_balances") &&
    migration.includes("on_hand") &&
    migration.includes("reserved"),
  "migration must add an HQ stock guard to rpc_create_wave_from_po",
);
assert(
  migration.includes("open_wave_reserved") &&
    migration.includes("pw.status IN ('draft','picking','picked')"),
  "HQ stock guard must reserve existing unshipped picking waves",
);
assert(
  migration.includes("本次分配 + 未出倉 wave 保留量"),
  "migration comment must document the new backend cap",
);

console.log("Picking HQ stock cap check passed.");

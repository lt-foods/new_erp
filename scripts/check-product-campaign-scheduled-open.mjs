import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(resolve(root, path), "utf8");
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const modal = read("apps/admin/src/components/CreateCampaignModal.tsx");
const importer = read("apps/admin/src/app/(protected)/campaigns/import/page.tsx");
const migration = read("supabase/migrations/20260925000000_campaign_from_product_scheduled_open.sql");

assert(modal.includes("p_start_at:") && modal.includes("p_auto_open:"), "商品頁必須同時傳開團時間與自動開團");
assert(modal.includes("startTime >= customerEndTime"), "畫面必須擋下開團時間不早於客人收單");
assert(migration.includes("p_start_at        TIMESTAMPTZ DEFAULT NULL") && migration.includes("p_auto_open       BOOLEAN DEFAULT FALSE"), "新參數必須有預設值，保留舊呼叫相容");
assert(migration.includes("v_start_at := COALESCE(p_start_at, NOW())"), "未傳開團時間時必須維持立即開團");
assert(migration.includes("CASE WHEN v_is_future THEN 'draft' ELSE 'open' END"), "未來開團必須建成草稿");
assert(migration.includes("COALESCE(p_auto_open, FALSE) AND v_is_future"), "自動開團只能套用於未來草稿");
assert(migration.includes("v_start_at >= p_customer_end_at") && migration.includes("v_start_at >= p_end_at"), "後端必須檢查開團時間早於收單");
assert(!importer.includes("p_start_at:") && !importer.includes("p_auto_open:"), "舊匯入入口不應被改為新參數的強制呼叫");

console.log("Product campaign scheduled-open check passed.");

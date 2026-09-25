import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(resolve(root, path), "utf8");
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

function missingChecks(source, checks) {
  return checks.filter(([pattern]) => !pattern.test(source)).map(([, name]) => name);
}

function modalErrors(source) {
  return missingChecks(source, [
    [/p_start_at:\s*new Date\(startAt\)\.toISOString\(\)/, "UI 開團參數必須來自 startAt"],
    [/p_auto_open:\s*startTime\s*>\s*Date\.now\(\)\s*&&\s*autoOpen/, "UI 自動開團必須同時檢查未來時間與勾選值"],
    [/startTime\s*>=\s*customerEndTime/, "UI 必須擋下開團時間不早於客人收單"],
  ]);
}

function migrationErrors(source) {
  return missingChecks(source, [
    [/p_start_at\s+TIMESTAMPTZ\s+DEFAULT NULL/, "DB p_start_at 必須保留舊呼叫預設值"],
    [/p_auto_open\s+BOOLEAN\s+DEFAULT FALSE/, "DB p_auto_open 必須預設關閉"],
    [/v_start_at\s*:=\s*COALESCE\(p_start_at,\s*NOW\(\)\)\s*;/, "DB 未傳開團時間時必須使用現在"],
    [/v_is_future\s*:=\s*v_start_at\s*>\s*NOW\(\)\s*;/, "DB 未來判斷必須來自實際開團時間"],
    [/CASE\s+WHEN\s+v_is_future\s+THEN\s+'draft'\s+ELSE\s+'open'\s+END/, "DB 未來開團必須建成草稿"],
    [/COALESCE\(p_auto_open,\s*FALSE\)\s+AND\s+v_is_future/, "DB 自動開團只能套用於未來草稿"],
    [/v_start_at\s*>=\s*p_customer_end_at/, "DB 必須檢查開團早於客人收單"],
    [/v_start_at\s*>=\s*p_end_at/, "DB 必須檢查開團早於店家收單"],
  ]);
}

function mutate(source, from, to, name) {
  const mutated = source.replace(from, to);
  assert(mutated !== source, `無法建立錯誤突變：${name}`);
  return mutated;
}

const modal = read("apps/admin/src/components/CreateCampaignModal.tsx");
const importer = read("apps/admin/src/app/(protected)/campaigns/import/page.tsx");
const migration = read("supabase/migrations/20260925000000_campaign_from_product_scheduled_open.sql");

const errors = [...modalErrors(modal), ...migrationErrors(migration)];
assert(errors.length === 0, errors.join("\n"));
assert(!importer.includes("p_start_at:") && !importer.includes("p_auto_open:"), "舊匯入入口不應被改為新參數的強制呼叫");

const dbAlwaysFalse = mutate(migration, "v_is_future := v_start_at > NOW();", "v_is_future := FALSE;", "DB 未來判斷恒假");
assert(migrationErrors(dbAlwaysFalse).includes("DB 未來判斷必須來自實際開團時間"), "檢查未擋下 DB 未來判斷恒假的錯版");

const uiAlwaysFalse = mutate(modal, "p_auto_open: startTime > Date.now() && autoOpen,", "p_auto_open: false,", "UI 自動開團恒假");
assert(modalErrors(uiAlwaysFalse).includes("UI 自動開團必須同時檢查未來時間與勾選值"), "檢查未擋下 UI 自動開團恒假的錯版");

console.log("Product campaign scheduled-open check passed, including 2 mutation counterexamples.");

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
  const errors = missingChecks(source, [
    [/p_start_at:\s*new Date\(startAt\)\.toISOString\(\)/, "UI 開團參數必須來自 startAt"],
    [/p_auto_open:\s*true\b/, "UI 建立開團必須固定傳 p_auto_open=true 相容舊庫"],
    [/startTime\s*>=\s*customerEndTime/, "UI 必須擋下開團時間不早於客人收單"],
    [/未來時間[^<\r\n]*先建成草稿[^<\r\n]*時間到自動開團/, "UI 必須說明未來團先草稿、時間到自動開團"],
  ]);
  if (/\b(?:autoOpen|setAutoOpen)\b|type\s*=\s*"checkbox"|預設不勾/.test(source)) {
    errors.push("UI 不得保留自動開團勾選與狀態");
  }
  return errors;
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

let oldCheckboxVersion = mutate(modal, "p_auto_open: true,", "p_auto_open: false,", "UI 自動開團傳 false");
oldCheckboxVersion = mutate(
  oldCheckboxVersion,
  "const [startAt, setStartAt] = useState(defaultStartAtValue);",
  "const [startAt, setStartAt] = useState(defaultStartAtValue);\n  const [autoOpen, setAutoOpen] = useState(false);",
  "UI 舊勾選狀態",
);
oldCheckboxVersion = mutate(
  oldCheckboxVersion,
  '<span className="text-xs text-zinc-400">未來時間會先建成草稿、不會提前出現在商城，時間到自動開團</span>',
  '<label><input type="checkbox" checked={autoOpen} onChange={(e) => setAutoOpen(e.target.checked)} />時間到自動開團（預設不勾）</label>',
  "UI 舊勾選畫面",
);
const oldCheckboxErrors = modalErrors(oldCheckboxVersion);
assert(oldCheckboxErrors.includes("UI 建立開團必須固定傳 p_auto_open=true 相容舊庫"), "檢查未擋下 UI 傳 false 的錯版");
assert(oldCheckboxErrors.includes("UI 不得保留自動開團勾選與狀態"), "檢查未擋下 UI 恢復舊勾選的錯版");

console.log("Product campaign scheduled-open check passed, including 2 mutation counterexamples.");

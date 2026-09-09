const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "../..");
const relFile = "apps/admin/src/components/StoreReturnCreateModal.tsx";
const file = path.join(repoRoot, relFile);
const baseline = process.argv.includes("--baseline");
const src = baseline
  ? execFileSync("git", ["-c", `safe.directory=${repoRoot}`, "show", `cf10338c:${relFile}`], {
      cwd: repoRoot,
      encoding: "utf8",
    })
  : fs.readFileSync(file, "utf8");

const submitStart = src.indexOf("async function submit()");
assert.notEqual(submitStart, -1, "找不到 submit()");
const submitEnd = src.indexOf("const summary =", submitStart);
assert.notEqual(submitEnd, -1, "找不到 submit() 送出摘要位置");
const submitGuardBlock = src.slice(submitStart, submitEnd);

const shortageGuard = submitGuardBlock.indexOf('if (reason === "少收") return;');
const canSubmitGuard = submitGuardBlock.indexOf("if (!canSubmit) return;");
assert(shortageGuard >= 0, "submit() 必須明確擋少收");
assert(canSubmitGuard >= 0, "submit() 必須保留 canSubmit 防線");
assert(shortageGuard < canSubmitGuard, "少收防線要放在 canSubmit 前，避免 TypeScript 窄化成永假");

assert(src.includes('reason !== "少收"'), "canSubmit 必須擋少收，讓按鈕不能送出");
assert(src.includes('href="/wms/inbound"'), "少收導路必須去收貨頁 /wms/inbound");
assert(src.includes('target="_blank"'), "少收導路要新分頁，避免退貨草稿被切頁弄丟");
assert(src.includes('rel="noopener noreferrer"'), "新分頁 Link 必須有 noopener noreferrer");
assert(src.includes("已收") && src.includes("明細 / 改實收"), "文案必須告訴店家到已收分頁按明細 / 改實收");
assert(src.includes("尚未收貨") && src.includes("原單核對實收"), "文案必須補尚未收貨走原單核對實收");
assert(src.includes("依總倉回覆與月結規則算帳"), "錢的文案不能承諾立刻自動算完");
assert(!src.includes("錢也會自動跟著算"), "不得保留過度承諾的錢文案");

console.log(`shortage-ui-check ok (${baseline ? "baseline" : "working tree"})`);

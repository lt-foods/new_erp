#!/usr/bin/env node
import { execFileSync } from "node:child_process";

const base = process.env.BASE_SHA || process.argv[2] || "origin/main";
const head = process.env.HEAD_SHA || process.argv[3] || "HEAD";
const prBody = stripComments(process.env.PR_BODY || "");

const watchedPaths = [
  "supabase/config.toml",
  "supabase/functions",
  "apps",
  ".github/workflows",
  ".env.example",
];

// 基準一律用「共同祖先」（merge-base），不要拿 base 分支的最新版硬比：
// 分支落後 main 時，兩點 diff 會把「main 後來刪掉的東西」當成這條分支新加的 → 假警報。
// （2026-08-21 實測：這支守門拿自己當 PR 檢查，誤報了一個 main 已改掉的 process.env。）
let from = base;
try {
  from = git(["merge-base", base, head]).trim() || base;
} catch {
  from = base;
}

const diff = git([
  "diff",
  "--unified=0",
  "--no-ext-diff",
  from,
  head,
  "--",
  ...watchedPaths,
]);

const findings = collectFindings(diff);

if (findings.length === 0) {
  console.log("No sensitive gateway or environment changes detected.");
  process.exit(0);
}

if (hasPrReview(prBody)) {
  console.log("Sensitive gateway/environment changes were found and the PR body contains an explicit review note:");
  for (const finding of findings) console.log(`- ${finding}`);
  process.exit(0);
}

console.error("Sensitive gateway/environment changes were found.");
console.error("Add a checked PR note that explains: purpose, impact, doing risk, not-doing risk, and rollback.");
console.error("");
for (const finding of findings) console.error(`- ${finding}`);
process.exit(1);

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" });
}

function collectFindings(patch) {
  const out = [];
  let file = "";
  for (const line of patch.split(/\r?\n/)) {
    if (line.startsWith("+++ b/")) {
      file = line.slice("+++ b/".length);
      continue;
    }
    if (!line.startsWith("+") || line.startsWith("+++")) continue;
    const text = line.slice(1);
    const trimmed = text.trim();
    if (!trimmed || trimmed.startsWith("#") || trimmed.startsWith("//")) continue;

    if (file === "supabase/config.toml" && /\bverify_jwt\s*=\s*false\b/i.test(text)) {
      out.push(`${file}:新增 verify_jwt = false`);
      continue;
    }
    if (file === "supabase/config.toml" && /\benv\([^)]+\)/i.test(text)) {
      out.push(`${file}:新增 env(...) 設定`);
      continue;
    }
    if (file.startsWith("supabase/functions/") && /\b(?:Deno\.env\.get|requireEnv|mustEnv)\s*\(/.test(text)) {
      out.push(`${file}:新增後端環境值讀取`);
      continue;
    }
    if (file.startsWith("apps/") && /\bprocess\.env\./.test(text)) {
      out.push(`${file}:新增前端環境值讀取`);
      continue;
    }
    if (/\.env\.example$/.test(file) && /^[A-Z][A-Z0-9_]*\s*=/.test(trimmed)) {
      out.push(`${file}:新增環境變數範例 ${trimmed.split("=")[0]}`);
      continue;
    }
    if (file.endsWith("vercel.json")) {
      out.push(`${file}:修改 Vercel 部署設定`);
      continue;
    }
    if (file.startsWith(".github/workflows/") && /(?:\bsecrets\.|\bvars\.|^\s*environment:|^\s*env:)/i.test(text)) {
      out.push(`${file}:修改 GitHub Actions 環境或密鑰設定`);
    }
  }
  return [...new Set(out)];
}

function stripComments(value) {
  return value.replace(/<!--[\s\S]*?-->/g, "").trim();
}

function hasPrReview(body) {
  if (!body) return false;
  // 只認「有新增或修改」那一格；勾「沒有碰」那格不算（2026-08-21 實測：原本勾錯格也會放行）。
  const hasCheckedSensitiveItem = /[-*]\s*\[[xX]\]\s+(?!.*沒有)(?=.*(?:敏感設定|門禁|環境|verify_jwt))/m.test(body);
  // 危險欄位要真的有寫字：「做了：」「不做：」「回退：」後面至少一欄非空。
  // 範本標題本身就含這些字，所以不能只看「有沒有出現」。
  const hasRiskWords = /(?:做了|不做|回退|rollback|危險|風險|影響)[ \t]*[:：][ \t]*\S/.test(body);
  return hasCheckedSensitiveItem && hasRiskWords;
}

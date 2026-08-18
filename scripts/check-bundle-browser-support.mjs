// 檢查 build 出來的 JS 有沒有舊 iOS 解析不了的語法。
//
//   node scripts/check-bundle-browser-support.mjs apps/member   # 預設就是 apps/member
//   node scripts/check-bundle-browser-support.mjs apps/admin
//
// 要先 build 過（讀的是 `.next/static/chunks`）。
//
// 為什麼需要：Next.js 16 預設把 JS 編到 `safari 16.4`（見
// node_modules/next/dist/shared/lib/modern-browserslist-target.js），而 iPhone 7
// 最高只能升到 iOS 15.8 / Safari 15.6。差這一階的後果不是「畫面跑版」而是
// **整個 app 靜悄悄地不會動**：chunk 一個 SyntaxError，React 完全沒接手，
// 使用者看到的是 SSR 那張 `loading=true` 的骨架 —— 轉圈轉到天荒地老，沒有任何
// 錯誤訊息。2026-08-18 忠順 992831 就是這樣，只能靠店家拍照才發現。
//
// 各 app 的 package.json 已經設了 browserslist 把自家程式碼壓回舊語法，但
// **browserslist 管不到 node_modules 裡已經編好的 dist**（Next 預設不轉譯它們），
// 所以真正的底線是相依套件給什麼就是什麼 —— 只能事後檢查，這支就是幹這個的。
// 升級 next / react / @serwist 之後跑一次。
//
// 判準：以 ES2022 解析（Safari 15.6 吃得下絕大多數 ES2022），再用 AST 精準揪出
// 那幾個 Safari 15 沒有、而且一出現就是整支 chunk 解析失敗的語法。用 AST 而不是
// grep —— 字串常數裡出現 `static {` 不該算數。

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, relative } from "node:path";
import * as acorn from "acorn";

/** 我們要守住的下限。iPhone 7 / iPhone 6s 的天花板是 iOS 15.8 = Safari 15.6 */
const TARGET = "Safari 15.6 (iOS 15.8 — iPhone 7 的天花板)";

const appDir = process.argv[2] ?? "apps/member";
const chunkDir = join(appDir, ".next", "static", "chunks");

if (!existsSync(chunkDir)) {
  console.error(`找不到 ${chunkDir} —— 請先 build：cd ${appDir} && npx next build --webpack`);
  process.exit(2);
}

function jsFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...jsFiles(p));
    else if (e.name.endsWith(".js")) out.push(p);
  }
  return out;
}

/** 走遍 AST 的每個節點（不裝 acorn-walk，這裡只需要「每個節點都看一眼」） */
function walk(node, visit) {
  if (node === null || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (const n of node) walk(n, visit);
    return;
  }
  if (typeof node.type === "string") visit(node);
  for (const k of Object.keys(node)) {
    if (k === "type" || k === "start" || k === "end" || k === "loc") continue;
    walk(node[k], visit);
  }
}

const findings = [];

for (const file of jsFiles(chunkDir)) {
  const src = readFileSync(file, "utf8");
  const rel = relative(appDir, file);

  let ast;
  try {
    ast = acorn.parse(src, { ecmaVersion: 2022, sourceType: "script", locations: true });
  } catch (e) {
    findings.push({ file: rel, what: `連 ES2022 都解析不了：${e.message}`, need: "更新的瀏覽器" });
    continue;
  }

  walk(ast, (node) => {
    // class 裡的 static 初始化區塊 —— Safari 16.4 才有。這就是 iPhone 7 那次的兇手。
    if (node.type === "StaticBlock") {
      findings.push({ file: rel, what: `class static block（${where(node)}）`, need: "Safari 16.4" });
      return;
    }
    if (node.type === "Literal" && node.regex) {
      const { pattern, flags } = node.regex;
      if (pattern.includes("(?<=") || pattern.includes("(?<!")) {
        findings.push({ file: rel, what: `正規表示式 lookbehind：/${cut(pattern)}/`, need: "Safari 16.4" });
      }
      if (flags.includes("d")) {
        findings.push({ file: rel, what: `正規表示式 d flag：/${cut(pattern)}/${flags}`, need: "Safari 17" });
      }
      if (flags.includes("v")) {
        findings.push({ file: rel, what: `正規表示式 v flag：/${cut(pattern)}/${flags}`, need: "Safari 17" });
      }
    }
  });
}

function cut(s) {
  return s.length > 60 ? s.slice(0, 60) + "…" : s;
}
/** chunk 是壓過的，一行幾十萬字元 —— 行號沒用，要給欄位才找得到 */
function where(node) {
  return node.loc ? `第 ${node.loc.start.line} 行第 ${node.loc.start.column} 欄` : `位移 ${node.start}`;
}

if (findings.length) {
  console.error(`❌ ${appDir} 的 bundle 有 ${findings.length} 處語法，${TARGET} 解析不了：\n`);
  for (const f of findings.slice(0, 20)) {
    console.error(`   ${f.file}\n     ${f.what}  → 需要 ${f.need}`);
  }
  if (findings.length > 20) console.error(`   …另外還有 ${findings.length - 20} 處`);
  console.error(
    "\n這不會讓畫面跑版，而是讓整個 app 在那些手機上**完全不動**（永遠停在轉圈的骨架）。",
  );
  console.error("先確認 package.json 的 browserslist 還在；還是有的話，兇手多半是某個相依套件的 dist。");
  process.exit(1);
}

console.log(`✅ ${appDir}：${jsFiles(chunkDir).length} 支 chunk 都能被 ${TARGET} 解析`);

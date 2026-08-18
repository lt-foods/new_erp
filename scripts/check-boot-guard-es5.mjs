// 驗「開機守門員」那段內嵌腳本真的是 ES5。
//
//   node scripts/check-boot-guard-es5.mjs
//
// 為什麼要有這支：bootGuard 的存在意義就是「在**跑不動新語法的舊瀏覽器**上還能
// 動」（見 apps/member/src/lib/bootGuard.ts 開頭）。它自己只要不小心用了箭頭函式
// 或樣板字串，就會跟它要救的那包 bundle 一起 SyntaxError —— 而且那一刻畫面上
// 什麼都不會發生，永遠不會有人發現它壞了。所以改完一定要跑這支。
//
// 用 acorn 以 ecmaVersion 5 解析：過得了就是 ES5，過不了會直接指出哪一行。

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import * as acorn from "acorn";
import { bootGuardScript } from "../apps/member/src/lib/bootGuard.ts";

const here = dirname(fileURLToPath(import.meta.url));
const src = bootGuardScript("https://example.supabase.co");

try {
  acorn.parse(src, { ecmaVersion: 5 });
} catch (e) {
  const line = String(src).split("\n")[(e.loc?.line ?? 1) - 1] ?? "";
  console.error(`❌ bootGuard 不是 ES5：${e.message}`);
  console.error(`   ${line.trim().slice(0, 120)}`);
  process.exit(1);
}

// 順手擋掉「解析得過但舊瀏覽器沒有」的內建 API。守門員只能用 ES5 那一套。
const BANNED = [
  [/\bfetch\s*\(/, "fetch（用 XMLHttpRequest）"],
  [/\bPromise\b/, "Promise"],
  [/\bObject\.assign\b/, "Object.assign"],
  [/\.forEach\s*\(/, "Array.prototype.forEach 的 callback 容易夾帶新語法，改用 for"],
  [/\bJSON\.parse\s*\(\s*JSON\.stringify/, "深拷貝請直接寫"],
];
const hits = BANNED.filter(([re]) => re.test(src)).map(([, why]) => why);
if (hits.length) {
  console.error("❌ bootGuard 用到不該用的東西：\n   - " + hits.join("\n   - "));
  process.exit(1);
}

// 內嵌進 HTML 的腳本不能出現 </script>，否則會提早關閉標籤
if (/<\/script/i.test(src)) {
  console.error("❌ bootGuard 內含 </script>，內嵌進 HTML 會提早關閉標籤");
  process.exit(1);
}

// layout 必須真的把它掛上去，不然改了半天等於沒接
const layout = readFileSync(resolve(here, "../apps/member/src/app/layout.tsx"), "utf8");
if (!/bootGuardScript\(/.test(layout) || !/dangerouslySetInnerHTML/.test(layout)) {
  console.error("❌ apps/member/src/app/layout.tsx 沒有內嵌 bootGuardScript()");
  process.exit(1);
}

console.log(`✅ bootGuard 是 ES5（${src.length} bytes），且已掛進 layout`);

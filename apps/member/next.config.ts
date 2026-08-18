import type { NextConfig } from "next";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import withSerwistInit from "@serwist/next";

const withSerwist = withSerwistInit({
  swSrc: "src/sw.ts",
  swDest: "public/sw.js",
});

/**
 * 把 browserslist 折進 webpack 的 cache version。
 *
 * Next.js **沒有**把編譯目標算進 filesystem cache 的 key —— 所以改了
 * package.json 的 `browserslist`，已經在 cache 裡的模組會被原封不動拿來用，
 * 產出的 chunk 還是舊目標編的。本機看不出來（多半會先 `rm -rf .next`），
 * 但 Vercel 每次部署都會還原 `.next/cache`，於是**修改在線上等於沒發生**。
 *
 * 2026-08-18 就是這樣：iPhone 7 的修法（設 browserslist）合併上線後，線上
 * `239-*.js` 的檔名雜湊跟修之前一模一樣、class static block 還在，舊手機照樣
 * 開不了 —— 只是這次畫面上出現了守門員的錯誤訊息，才知道沒修好。
 *
 * 用 `cache.version` 而不是 `buildDependencies`：webpack 會把 version 存進
 * cache pack，下次對不上就整包丟掉 —— **舊 cache 沒追蹤過這個檔案也一樣有效**。
 * buildDependencies 只對「上一次 build 就已經在追蹤」的檔案有用，第一次加上去
 * 的那一次還是會吃到舊 cache，也就是修不到已經壞掉的那次部署。
 *
 * apps/admin 不需要這段：它走 Turbopack（`next build`，沒有 `--webpack`），
 * 實測「保留 cache 改 browserslist 再 build」產出是正確的。這段只對 webpack 有效，
 * 硬加到 Turbopack 的設定裡只會多一個沒人呼叫的 webpack hook。
 */
function pinCacheToBrowserslist(config: {
  context?: string;
  cache?: unknown;
}): void {
  const cache = config.cache as { type?: string; version?: string } | undefined;
  if (!cache || cache.type !== "filesystem") return;
  const dir = config.context ?? process.cwd();
  let browserslist = "";
  try {
    browserslist = JSON.stringify(
      JSON.parse(readFileSync(join(dir, "package.json"), "utf8")).browserslist ?? null,
    );
  } catch {
    // 讀不到就用空字串 —— 這裡失敗不該讓整個 build 掛掉
  }
  cache.version = `${cache.version ?? ""}|browserslist:${browserslist}`;
}

const nextConfig: NextConfig = {
  images: { unoptimized: true },
  // 解決 Next.js 16+ Turbopack 與 Serwist (Webpack) 的衝突
  // 透過設定空物件來告訴 Next.js 即使有自定義 webpack 配置也要繼續建置
  // 在某些版本中這會讓建置退回到 Webpack，這對 Serwist 是必要的
  // @ts-ignore
  turbopack: {},
  webpack(config) {
    pinCacheToBrowserslist(config);
    return config;
  },
};

export default withSerwist(nextConfig);

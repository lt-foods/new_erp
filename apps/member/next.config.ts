import type { NextConfig } from "next";
import withSerwistInit from "@serwist/next";

const withSerwist = withSerwistInit({
  swSrc: "src/sw.ts",
  swDest: "public/sw.js",
});

const nextConfig: NextConfig = {
  images: { unoptimized: true },
  // 解決 Next.js 16+ Turbopack 與 Serwist (Webpack) 的衝突
  // 透過設定空物件來告訴 Next.js 即使有自定義 webpack 配置也要繼續建置
  // 在某些版本中這會讓建置退回到 Webpack，這對 Serwist 是必要的
  // @ts-ignore
  turbopack: {},
};

export default withSerwist(nextConfig);


import type { NextConfig } from "next";
import withSerwistInit from "@serwist/next";

const withSerwist = withSerwistInit({
  swSrc: "src/sw.ts",
  swDest: "public/sw.js",
});

const nextConfig: NextConfig = {
  images: { unoptimized: true },
  // 進商品詳情頁再返回時，列表頁（/shop、/orders 等 client 端 fetch 的頁）
  // 不要整頁重抓 + 捲動歸零。Next 15+ 把 client cache 的 staleTimes.dynamic
  // 預設改成 0（一離開該頁 segment 就丟棄），返回時 component remount→
  // useEffect 重抓→skeleton→scroll reset，就是使用者看到的「又 reload 一次」。
  // 設成正值 → 返回時沿用 client cache 內「已渲染的頁面」（含 React state
  // 與捲動位置），不再 reload。資料新鮮度交給下拉刷新 / 詳情頁自身 fetch。
  experimental: {
    staleTimes: { dynamic: 300, static: 300 },
  },
  // 解決 Next.js 16+ Turbopack 與 Serwist (Webpack) 的衝突
  // 透過設定空物件來告訴 Next.js 即使有自定義 webpack 配置也要繼續建置
  // 在某些版本中這會讓建置退回到 Webpack，這對 Serwist 是必要的
  // @ts-ignore
  turbopack: {},
};

export default withSerwist(nextConfig);


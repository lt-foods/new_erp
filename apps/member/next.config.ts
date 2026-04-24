import type { NextConfig } from "next";

// apps/member 部署到 Vercel，走原生 Next.js（非 static export）
// 需要走 static export（例如移到 GitHub Pages）時再加回：
//   output: "export", trailingSlash: true, basePath, assetPrefix
const nextConfig: NextConfig = {
  images: { unoptimized: true },
};

export default nextConfig;

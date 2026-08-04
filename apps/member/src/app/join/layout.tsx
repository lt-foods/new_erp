import type { Metadata } from "next";

/**
 * /join 的分享預覽卡。
 *
 * 這頁存在的意義就是被貼到 Facebook 社團 / LINE 群 / IG，而那些地方顯示的是
 * OG tag 抓到的標題、說明與圖 —— 沒設就只會出現一行光禿禿的網址，點擊率天差地遠。
 * 圖用店家 banner（1800×600），LINE 與 FB 都吃得下。
 *
 * metadataBase 一定要是絕對網址：OG 圖不能用相對路徑，爬蟲沒有「當前網域」的概念。
 * 網址從 NEXT_PUBLIC_SITE_URL 讀，沒設就用線上的 member app 網域
 * （Vercel project 名字叫 new-erp-admin，但部署的其實是會員站，見 HANDOFF-2026-04-24）。
 */
const SITE_URL = (
  process.env.NEXT_PUBLIC_SITE_URL ?? "https://new-erp-admin.vercel.app"
).replace(/\/$/, "");

const TITLE = "加入包子媽生鮮小舖 — 用 LINE 一鍵註冊";
const DESCRIPTION =
  "每日開團的產地生鮮，直送你家附近的門市。不用填帳號密碼，用 LINE 登入即完成註冊，開團第一時間就收到通知。";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: TITLE,
  description: DESCRIPTION,
  alternates: { canonical: "/join" },
  openGraph: {
    type: "website",
    siteName: "包子媽生鮮小舖",
    title: TITLE,
    description: DESCRIPTION,
    url: "/join",
    locale: "zh_TW",
    images: [
      {
        url: "/brand/banner.jpg",
        width: 1800,
        height: 600,
        alt: "包子媽生鮮小舖 — 新鮮直送・社區團購",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: TITLE,
    description: DESCRIPTION,
    images: ["/brand/banner.jpg"],
  },
};

export default function JoinLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return children;
}

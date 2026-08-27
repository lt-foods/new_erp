import type { Metadata, Viewport } from "next";
import "./globals.css";
import ServiceWorkerRegister from "@/components/ServiceWorkerRegister";
import ErrorLogger from "@/components/ErrorLogger";
import PresenceHeartbeat from "@/components/PresenceHeartbeat";
import { bootGuardScript } from "@/lib/bootGuard";
import { SITE_NAME, SITE_OG_IMAGE, SITE_URL } from "@/lib/site";

const DESCRIPTION = "包子媽生鮮小舖 — LINE 團購會員 App";

const BOOT_GUARD = bootGuardScript(process.env.NEXT_PUBLIC_SUPABASE_URL);

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: SITE_NAME,
  description: DESCRIPTION,
  manifest: "/manifest.json",
  // 站台預設的分享預覽卡。沒有這段時，貼到 LINE 只會抓到 apple-touch-icon
  // （店家 logo 小方圖）；各頁要更好的卡就自己覆寫 openGraph（例：
  // /shop/c/[id] 換成該團的商品圖，/join 換成 banner）。
  openGraph: {
    type: "website",
    siteName: SITE_NAME,
    title: SITE_NAME,
    description: DESCRIPTION,
    locale: "zh_TW",
    images: [{ url: SITE_OG_IMAGE, width: 1800, height: 600, alt: SITE_NAME }],
  },
  icons: {
    icon: [
      { url: "/icons/android/launchericon-192x192.png", sizes: "192x192", type: "image/png" },
      { url: "/icons/android/launchericon-512x512.png", sizes: "512x512", type: "image/png" },
    ],
    apple: [
      { url: "/icons/ios/120.png", sizes: "120x120" },
      { url: "/icons/ios/152.png", sizes: "152x152" },
      { url: "/icons/ios/167.png", sizes: "167x167" },
      { url: "/icons/ios/180.png", sizes: "180x180" },
    ],
  },
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "包子媽生鮮小舖",
  },
  other: {
    "apple-mobile-web-app-capable": "yes",
  },
};

export const viewport: Viewport = {
  themeColor: "#fbf0f2",
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-Hant" className="h-full antialiased">
      <body className="min-h-full flex flex-col">
        {/* 開機守門員：內嵌、不屬於任何 chunk，所以 bundle 整包掛掉時它照樣會跑。
            沒等到 hydration 就把「永遠轉圈的骨架」換成看得懂的訊息並回報一筆
            client_error_logs（見 lib/bootGuard.ts —— 那是 2026-08-18 iPhone 7
            事件的產物：舊 iOS 上 JS 全滅，畫面跟「還在載入」一模一樣）。

            放 <body> 第一個而不是 <head>：Next 把框架 chunk 的 <script> 釘在 head
            最前面，插不進它們前面（自己開一層 <head> 只會多出第二個 head，實測
            腳本還是排在後面；`next/script` 的 beforeInteractive 也一樣排到這裡）。
            所以「誰先跑」是條件競爭，error 事件本來就可能漏接 —— bootGuard 因此
            不靠它判斷，另外備了兩條路：load 之後還沒 hydration 就放棄，
            並事後把 chunk 抓回來重新解析拿現場。 */}
        <script dangerouslySetInnerHTML={{ __html: BOOT_GUARD }} />
        <ErrorLogger />
        <ServiceWorkerRegister />
        <PresenceHeartbeat />
        {children}
      </body>
    </html>
  );
}

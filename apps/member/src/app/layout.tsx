import type { Metadata, Viewport } from "next";
import "./globals.css";
import ServiceWorkerRegister from "@/components/ServiceWorkerRegister";
import ErrorLogger from "@/components/ErrorLogger";
import { SITE_NAME, SITE_OG_IMAGE, SITE_URL } from "@/lib/site";

const DESCRIPTION = "包子媽生鮮小舖 — LINE 團購會員 App";

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
        <ErrorLogger />
        <ServiceWorkerRegister />
        {children}
      </body>
    </html>
  );
}

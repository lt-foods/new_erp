import type { Metadata } from "next";
import { Geist, Geist_Mono, Caveat } from "next/font/google";
import { AuthProvider } from "@/components/AuthProvider";
import { themeInitScript } from "@/lib/theme";
import { getAdminTitle, getTenantName } from "@/lib/tenant";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

// 手寫字標用（Groupo wordmark）— 見 components/Brand.tsx
const handScript = Caveat({
  variable: "--font-script",
  subsets: ["latin"],
  weight: ["700"],
});

// Next 不會自動把 basePath 補到 metadata.icons 的字串 URL。只要站台不是掛在網址根目錄
// （NEXT_PUBLIC_BASE_PATH 有值），這裡就會變成 /icons/... → 404 → 分頁退回預設黑 icon。
// 一律手動補 prefix，掛在根目錄或子路徑都會對。
// （2026-09-12 起改用自訂網域 erp.www161616.com，線上 basePath 是空的；曾經是 /new_erp，
//   這段就是那時候加的 —— 不要因為現在補的是空字串就把它拿掉。）
const bp = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

export const metadata: Metadata = {
  title: getAdminTitle(),
  description: `${getTenantName()} 管理後台`,
  icons: {
    icon: [
      { url: `${bp}/icons/ios/32.png`, sizes: "32x32", type: "image/png" },
      { url: `${bp}/icons/ios/16.png`, sizes: "16x16", type: "image/png" },
      { url: `${bp}/icons/android/launchericon-192x192.png`, sizes: "192x192", type: "image/png" },
      { url: `${bp}/icons/android/launchericon-512x512.png`, sizes: "512x512", type: "image/png" },
    ],
    apple: [
      { url: `${bp}/icons/ios/120.png`, sizes: "120x120" },
      { url: `${bp}/icons/ios/152.png`, sizes: "152x152" },
      { url: `${bp}/icons/ios/167.png`, sizes: "167x167" },
      { url: `${bp}/icons/ios/180.png`, sizes: "180x180" },
    ],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="zh-Hant"
      className={`${geistSans.variable} ${geistMono.variable} ${handScript.variable} h-full antialiased`}
      suppressHydrationWarning
    >
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
      </head>
      <body className="min-h-full flex flex-col">
        <AuthProvider>{children}</AuthProvider>
      </body>
    </html>
  );
}

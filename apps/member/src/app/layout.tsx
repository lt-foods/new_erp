import type { Metadata, Viewport } from "next";
import "./globals.css";
import ServiceWorkerRegister from "@/components/ServiceWorkerRegister";
import ErrorLogger from "@/components/ErrorLogger";

export const metadata: Metadata = {
  title: "包子媽生鮮小舖",
  description: "包子媽生鮮小舖 — LINE 團購會員 App",
  manifest: "/manifest.json",
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

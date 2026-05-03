import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
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

export const metadata: Metadata = {
  title: getAdminTitle(),
  description: `${getTenantName()} 管理後台`,
  icons: {
    icon: [
      { url: "/icons/ios/32.png", sizes: "32x32", type: "image/png" },
      { url: "/icons/ios/16.png", sizes: "16x16", type: "image/png" },
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
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="zh-Hant"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
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

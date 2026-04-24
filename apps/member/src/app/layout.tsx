import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "會員中心",
  description: "團購店 LINE 會員註冊 / 登入",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-Hant" className="h-full antialiased">
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}

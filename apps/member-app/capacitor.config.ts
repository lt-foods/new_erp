import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "com.baozima.member",
  appName: "包子媽生鮮小舖",
  // 前端靜態輸出（apps/member 的 `npm run build:export` 產物）。
  // 不用 server.url 指遠端網站 —— Apple App Review 4.2 會把純網站殼退件。
  webDir: "../member/out",
  ios: {
    contentInset: "always",
  },
  android: {
    // 允許混合內容前先確認；正式上線僅走 https
    allowMixedContent: false,
  },
  plugins: {
    PushNotifications: {
      // iOS 前景收到推播時也顯示橫幅 + 紅點 + 聲音
      presentationOptions: ["badge", "sound", "alert"],
    },
    SplashScreen: {
      launchShowDuration: 800,
      backgroundColor: "#ffffff",
      showSpinner: false,
    },
  },
};

export default config;

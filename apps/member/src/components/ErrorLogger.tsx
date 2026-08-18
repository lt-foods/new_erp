"use client";

import { useEffect } from "react";
import { installGlobalErrorLogging } from "@/lib/clientLog";
import { BOOT_OK_FLAG } from "@/lib/bootGuard";

/**
 * 掛全域錯誤攔截（未 catch 的例外 / promise rejection → client_error_logs），
 * 並對開機守門員報平安。只做這兩件事，不 render 任何東西。放在 layout 最上層。
 */
export default function ErrorLogger() {
  useEffect(() => {
    installGlobalErrorLogging();

    // 這個 effect 有跑到 = React 真的接手了。內嵌的開機守門員在等這個旗標；
    // 沒等到就會判定 bundle 掛掉，把畫面換成錯誤訊息（見 lib/bootGuard.ts）。
    // 掛在 layout 的元件上，所以每一頁都算數，不用每頁自己記得報平安。
    (window as unknown as Record<string, unknown>)[BOOT_OK_FLAG] = true;
  }, []);

  return null;
}

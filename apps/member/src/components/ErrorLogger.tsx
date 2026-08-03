"use client";

import { useEffect } from "react";
import { installGlobalErrorLogging } from "@/lib/clientLog";

/**
 * 掛全域錯誤攔截（未 catch 的例外 / promise rejection → client_error_logs）。
 * 只負責掛 listener，不 render 任何東西。放在 layout 最上層。
 */
export default function ErrorLogger() {
  useEffect(() => {
    installGlobalErrorLogging();
  }, []);

  return null;
}

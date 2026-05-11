"use client";

// 異常處理已整合進總倉收件匣 → ⚠️ 異常 tab。此頁僅保留以 redirect 兼容舊書籤。

import { useEffect } from "react";
import { useRouter } from "next/navigation";

export default function ExceptionsRedirect() {
  const router = useRouter();
  useEffect(() => {
    router.replace("/hq/inbox?source=exception");
  }, [router]);
  return (
    <div className="p-6 text-sm text-zinc-500">
      異常處理已整合進「總倉收件匣 → ⚠️ 異常」。轉跳中…
    </div>
  );
}

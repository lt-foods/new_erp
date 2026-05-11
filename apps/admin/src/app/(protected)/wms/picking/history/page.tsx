"use client";

// 撿貨歷史已併入「總倉收件匣 → 撿貨單」tab。此頁僅保留以 redirect 兼容舊書籤 / 連結。

import { Suspense, useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";

export default function PickingHistoryRedirect() {
  return (
    <Suspense fallback={null}>
      <RedirectInner />
    </Suspense>
  );
}

function RedirectInner() {
  const router = useRouter();
  const sp = useSearchParams();
  const wave = sp.get("wave");

  useEffect(() => {
    const target = wave
      ? `/hq/inbox?source=picking&wave=${encodeURIComponent(wave)}`
      : "/hq/inbox?source=picking";
    router.replace(target);
  }, [router, wave]);

  return (
    <div className="p-6 text-sm text-zinc-500">
      撿貨歷史已併入「總倉收件匣 → 撿貨單」tab。轉跳中…
    </div>
  );
}

"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

// 已搬到 /hq/inbox?source=aid
export default function TransfersAidRedirect() {
  const router = useRouter();
  useEffect(() => {
    router.replace("/hq/inbox?source=aid");
  }, [router]);
  return (
    <div className="p-6 text-sm text-zinc-500">
      互助轉移單已整合到 <a className="text-blue-600 underline" href="/hq/inbox?source=aid">總倉收件匣</a>,自動跳轉中…
    </div>
  );
}

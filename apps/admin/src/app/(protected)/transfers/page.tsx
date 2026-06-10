"use client";

import { Suspense, useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { LoadingBlock } from "@/components/Spinner";

// 已整合到 /wms/transfers + /hq/inbox — 此頁僅做 redirect
export default function TransfersListRedirect() {
  return (
    <Suspense fallback={<LoadingBlock />}>
      <RedirectInner />
    </Suspense>
  );
}

function RedirectInner() {
  const router = useRouter();
  const searchParams = useSearchParams();
  useEffect(() => {
    const id = searchParams.get("id");
    // 有 id 走收件匣轉貨單 tab(可批次操作);純列表去 /wms/transfers
    const target = id ? `/hq/inbox?source=transfer&id=${id}` : "/wms/transfers";
    router.replace(target);
  }, [router, searchParams]);
  return (
    <div className="p-6 text-sm text-zinc-500">
      頁面已搬到 <a className="text-blue-600 underline" href="/wms/transfers/">/wms/transfers</a>,自動跳轉中…
    </div>
  );
}

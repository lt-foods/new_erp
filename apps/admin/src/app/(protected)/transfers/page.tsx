"use client";

import { Suspense, useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";

// 已整合到 /wms/outbound — 此頁僅做 redirect,?id= 帶過去自動開明細 modal
export default function TransfersListRedirect() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <RedirectInner />
    </Suspense>
  );
}

function RedirectInner() {
  const router = useRouter();
  const searchParams = useSearchParams();
  useEffect(() => {
    const id = searchParams.get("id");
    const target = id ? `/wms/outbound?id=${id}` : "/wms/outbound";
    router.replace(target);
  }, [router, searchParams]);
  return (
    <div className="p-6 text-sm text-zinc-500">
      頁面已搬到 <a className="text-blue-600 underline" href="/wms/outbound/">/wms/outbound</a>,自動跳轉中…
    </div>
  );
}

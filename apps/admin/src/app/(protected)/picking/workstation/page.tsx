"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

// 已搬到 /wms/picking — 此頁僅做 client-side 重導
export default function PickingWorkstationRedirect() {
  const router = useRouter();
  useEffect(() => {
    router.replace("/wms/picking/");
  }, [router]);
  return (
    <div className="p-6 text-sm text-zinc-500">
      頁面已搬到 <a className="text-blue-600 underline" href="/wms/picking/">/wms/picking</a>,自動跳轉中…
    </div>
  );
}

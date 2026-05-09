"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

export default function TransfersInboxRedirect() {
  const router = useRouter();
  useEffect(() => {
    router.replace("/wms/inbound/");
  }, [router]);
  return (
    <div className="p-6 text-sm text-zinc-500">
      頁面已搬到 <a className="text-blue-600 underline" href="/wms/inbound/">/wms/inbound</a>,自動跳轉中…
    </div>
  );
}

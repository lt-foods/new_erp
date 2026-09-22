"use client";

// 小幫手加單的整頁版。畫面本體在 @/components/OrderEntryView —— LINE 記事本的
// 留言列點「團」會用同一個元件開彈窗，兩邊共用一份（不要再抄一份到彈窗去）。

import { Suspense } from "react";
import { useSearchParams } from "next/navigation";
import { OrderEntryView } from "@/components/OrderEntryView";

export default function OrderEntryPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PageContent />
    </Suspense>
  );
}

function PageContent() {
  const searchParams = useSearchParams();
  return <OrderEntryView campaignId={Number(searchParams.get("id"))} />;
}

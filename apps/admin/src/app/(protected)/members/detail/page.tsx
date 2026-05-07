"use client";

// /members/detail 已棄用 — 一律用 /members?id=N 在主列表頁開 modal
// 保留此 route 是為了相容舊書籤 / 舊 link，自動導回 /members?id=N
import { Suspense, useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";

export default function MemberDetailRedirect() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const id = useSearchParams().get("id");
  const router = useRouter();
  useEffect(() => {
    router.replace(id ? `/members?id=${id}` : "/members");
  }, [id, router]);
  return <div className="p-6 text-sm text-zinc-500">轉址中…</div>;
}

"use client";

import { useEffect, useState } from "react";
import { consumeFragmentToSession, getSession } from "@/lib/session";

export default function MePage() {
  const [memberId, setMemberId] = useState<number | null>(null);
  const [storeId, setStoreId] = useState<string | null>(null);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (s) {
      setMemberId(s.memberId);
      setStoreId(s.storeId);
    }
    // 若 URL 有 member_id（從 register 頁導過來）
    const sp = new URLSearchParams(window.location.search);
    const mid = sp.get("member_id");
    if (mid && !memberId) setMemberId(Number(mid));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (!memberId) {
    return (
      <main className="mx-auto max-w-md p-6 pt-16 text-center">
        <p className="text-sm text-zinc-500">尚未登入，請回首頁。</p>
        <a href="/" className="mt-4 inline-block text-sm text-blue-600 hover:underline">回首頁</a>
      </main>
    );
  }

  return (
    <main className="mx-auto flex w-full max-w-md flex-col gap-5 p-6 pt-10">
      <h1 className="text-xl font-semibold">會員中心</h1>
      <div className="rounded-md border border-green-300 bg-green-50 p-4 text-sm text-green-900">
        <p className="font-medium">✅ 已綁定 LINE</p>
        <p className="mt-1">會員 ID：{memberId}</p>
        <p>門市：{storeId ?? "—"}</p>
      </div>
      <p className="text-xs text-zinc-400">
        會員卡 QR、點數、訂單等功能尚未上線（MVP-1）。
      </p>
    </main>
  );
}

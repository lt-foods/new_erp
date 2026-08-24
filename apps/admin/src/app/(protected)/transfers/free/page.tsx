"use client";

// 自由轉貨建單頁 — 2026-08-14 曾停用，2026-08-16 重新開放
// （見 20260816000040_reenable_free_transfer；RPC 的 EXECUTE 也已還原）。
import { useRouter } from "next/navigation";
import FreeTransferCreateForm from "@/components/FreeTransferCreateForm";

export default function FreeTransferPage() {
  const router = useRouter();
  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">自由轉貨</h1>
      </header>
      <FreeTransferCreateForm
        onCreated={(id) => router.push(`/wms/transfers?open=${id}`)}
        onCancel={() => router.back()}
      />
    </div>
  );
}

"use client";

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
        onCreated={(id) => router.push(`/wms/outbound?id=${id}`)}
        onCancel={() => router.back()}
      />
    </div>
  );
}

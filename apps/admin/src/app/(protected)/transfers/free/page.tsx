"use client";

// 自由轉貨建單頁 — 2026-10-01 再次停用（8/14 停用 → 8/16 重開 → 10/1 再停，
// 見 20261001010000_disable_free_transfer_again）。表單移除、RPC 的 EXECUTE 也已收回，
// 留這頁只為了讓舊連結／書籤有話可說，並把人導到現在該走的路。
import Link from "next/link";

export default function FreeTransferPage() {
  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">自由轉貨（已停用）</h1>
      </header>

      <div className="max-w-2xl rounded-md border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-200">
        <p className="font-medium">自由轉貨（店對店）已於 2026-10-01 停用，不能再建新單。</p>
        <p className="mt-2">
          之前建的單照常可以在「內部調撥」頁查看、收貨，還是草稿的單可以刪除。
        </p>
        <p className="mt-2">貨要在店之間移動，請改走下面的路：</p>
        <ul className="mt-2 list-disc space-y-1 pl-5">
          <li>
            <span className="font-medium">貨要給別店的客人</span>：在該店的訂單上按「轉給別人」、
            勾「空中轉」。系統會自動從轉出店出貨，接收店在「收貨」頁收掉就能交貨。
          </li>
          <li>
            <span className="font-medium">店裡要補貨</span>：走
            <Link href="/restock/new" className="mx-1 text-blue-600 underline hover:text-blue-800 dark:text-blue-400">
              補貨申請
            </Link>
            由總倉派貨。
          </li>
          <li>
            <span className="font-medium">其他店與店之間互給的東西</span>：由店家自行處理，系統不再記錄。
          </li>
        </ul>
      </div>

      <div className="flex flex-wrap gap-2">
        <Link
          href="/wms/transfers"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          ← 回內部調撥
        </Link>
        <Link
          href="/restock/new"
          className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700"
        >
          前往補貨申請
        </Link>
      </div>
    </div>
  );
}

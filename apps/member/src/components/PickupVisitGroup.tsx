import { formatVisitWhen, type PickupVisit } from "@/lib/pickups";

// 「已完成」分頁裡，一次到店結單的外框：標題（時間 / 門市 / 幾筆幾件 / 本次金額）
// ＋把那一次拿走的訂單卡整個包起來。
//
// 為什麼要做成「容器」而不只是一張標題卡：第一版標題與訂單卡同樣是粉底、同樣的
// 圓角層級，一路捲下去就是一排長得一樣的卡片，看不出哪幾張屬於同一次
// （2026-08-18 回報）。外框 + 淡底把整組圈起來、裡面的卡改成白底，界線才看得出來。
//
// 措辭刻意避開「結單」兩個字：同一頁的訂單卡上「結單日」是**開團收單日**，
// 兩種意思擺在一起客人一定誤讀。這裡一律講「取貨」。

function fmtAmount(n: number): string {
  return Number(n ?? 0).toLocaleString();
}

export default function PickupVisitGroup({
  visit,
  children,
}: {
  visit: PickupVisit;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-[1.25rem] border border-[var(--brand-strong)]/25 bg-[var(--brand-soft)]/45 p-1.5">
      <header className="flex items-start justify-between gap-3 px-2.5 pt-1.5 pb-2.5">
        <div className="min-w-0">
          <div className="text-[15px] font-bold text-[var(--brand-strong)]">
            <span aria-hidden className="mr-1">🧾</span>
            {formatVisitWhen(visit.pickedAt)} 取貨
          </div>
          <div className="mt-0.5 text-[12px] text-[var(--secondary-label)]">
            {visit.storeName && (
              <>
                {visit.storeName}
                <span className="mx-1 text-[var(--tertiary-label)]">·</span>
              </>
            )}
            {visit.orderCount} 筆訂單
            <span className="mx-1 text-[var(--tertiary-label)]">·</span>
            {visit.qty} 件
          </div>
        </div>
        <div className="flex-shrink-0 text-right">
          <div className="text-[11px] text-[var(--secondary-label)]">本次取貨金額</div>
          <div className="text-[21px] font-bold leading-tight tabular-nums text-[var(--brand-strong)]">
            ${fmtAmount(visit.amount)}
          </div>
        </div>
      </header>
      {/* 裡面的卡片是白底（OrderCard 的 inGroup），跟這層淡粉底對比出界線 */}
      <div className="space-y-1.5">{children}</div>
    </section>
  );
}

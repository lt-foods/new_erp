import type { PickupVisit } from "@/lib/pickups";

// 「已完成」分頁裡，一次到店結單的標題卡：時間 / 門市 / 這次拿了幾筆幾件 / 金額。
// 底下緊接著的訂單卡就是這一次拿走的東西（見 lib/pickups.ts）。
//
// 措辭刻意避開「結單」兩個字：同一頁的訂單卡上「結單日」是**開團收單日**，
// 兩種意思擺在一起客人一定誤讀。這裡一律講「取貨」。

const WEEKDAY = ["日", "一", "二", "三", "四", "五", "六"];

function fmtWhen(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  // 今年不印年份（一行塞得下、也是團友講日期的方式）
  const y = d.getFullYear() === new Date().getFullYear() ? "" : `${d.getFullYear()}/`;
  return `${y}${d.getMonth() + 1}/${d.getDate()}（${WEEKDAY[d.getDay()]}）${hh}:${mm}`;
}

function fmtAmount(n: number): string {
  return Number(n ?? 0).toLocaleString();
}

export default function PickupVisitHeader({ visit }: { visit: PickupVisit }) {
  return (
    <div className="card flex items-center justify-between gap-3 bg-[var(--brand-soft)]/45 px-4 py-3">
      <div className="min-w-0">
        <div className="text-[16px] font-semibold text-[var(--foreground)]">
          <span aria-hidden className="mr-1">🧾</span>
          {fmtWhen(visit.pickedAt)} 取貨
        </div>
        <div className="mt-0.5 text-[13px] text-[var(--secondary-label)]">
          {visit.storeName && (
            <>
              {visit.storeName}
              <span className="mx-1.5 text-[var(--tertiary-label)]">·</span>
            </>
          )}
          {visit.orderCount} 筆訂單
          <span className="mx-1.5 text-[var(--tertiary-label)]">·</span>
          {visit.qty} 件
        </div>
      </div>
      <div className="flex-shrink-0 text-right">
        <div className="text-[12px] text-[var(--tertiary-label)]">本次取貨金額</div>
        <div className="text-[22px] font-semibold tabular-nums text-[var(--brand-strong)]">
          ${fmtAmount(visit.amount)}
        </div>
      </div>
    </div>
  );
}

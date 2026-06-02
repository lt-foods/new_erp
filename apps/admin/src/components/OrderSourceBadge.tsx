"use client";

import { itemSourceMeta, type OrderSourceSummary } from "@/lib/orderSource";

const BADGE_CLS =
  "inline-flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[10px] font-medium whitespace-nowrap";

/** 整單來源 badge（訂單列表用）— 吃 summarizeOrderSource() 的結果。 */
export function OrderSourceBadge({
  summary,
  className = "",
}: {
  summary: OrderSourceSummary;
  className?: string;
}) {
  if (summary.kind === "none") return <span className="text-zinc-400">—</span>;
  return (
    <span title={summary.label} className={`${BADGE_CLS} ${summary.cls} ${className}`}>
      {summary.icon && <span aria-hidden>{summary.icon}</span>}
      {summary.short}
    </span>
  );
}

/** 單一品項來源 badge（訂單明細的品項列用）。 */
export function ItemSourceBadge({
  source,
  className = "",
}: {
  source: string | null | undefined;
  className?: string;
}) {
  const meta = itemSourceMeta(source);
  return (
    <span title={meta.label} className={`${BADGE_CLS} ${meta.cls} ${className}`}>
      {meta.icon && <span aria-hidden>{meta.icon}</span>}
      {meta.short}
    </span>
  );
}

"use client";

// 折扣 1 欄（金額/百分比二擇一）— 用於 OrderDetail 的 draft state
// 不直接 RPC，由 parent 蒐集後一次儲存。

export type DiscountKind = "percent" | "amount";
export type DiscountValue = { kind: DiscountKind; value: number };

export function deriveDiscount(percent: number, amount: number): DiscountValue {
  if (Number(percent) > 0) return { kind: "percent", value: Number(percent) };
  return { kind: "amount", value: Number(amount) };
}

export function discountLabel(d: DiscountValue): string {
  if (!d.value || d.value === 0) return "—";
  return d.kind === "percent" ? `${d.value}%` : `$${d.value}`;
}

// 把 DiscountValue 轉成金額（依 referenceAmount）
export function discountToAmount(d: DiscountValue, referenceAmount: number): number {
  if (d.value <= 0) return 0;
  if (d.kind === "percent") return Math.round(referenceAmount * Number(d.value)) / 100;
  return Number(d.value);
}

export function EditableDiscount({
  value,
  onChange,
  disabled,
  compact,
  referenceAmount,
}: {
  value: DiscountValue;
  onChange: (v: DiscountValue) => void;
  disabled?: boolean;
  compact?: boolean;
  // 用於 % → $ 換算提示
  referenceAmount?: number;
}) {
  const equivAmount = referenceAmount != null && value.kind === "percent" && value.value > 0
    ? Math.round(referenceAmount * Number(value.value)) / 100
    : null;

  if (disabled) {
    return (
      <span className="font-mono">
        {discountLabel(value)}
        {equivAmount != null && <span className="ml-1 text-zinc-500">(= ${equivAmount})</span>}
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1">
      <span className="inline-flex overflow-hidden rounded border border-zinc-300 dark:border-zinc-700" role="radiogroup" aria-label="折扣類型">
        <button
          type="button"
          role="radio"
          aria-checked={value.kind === "amount"}
          onClick={() => onChange({ kind: "amount", value: value.value })}
          className={`px-2 py-0.5 text-xs font-medium ${
            value.kind === "amount"
              ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
              : "bg-white text-zinc-700 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
          }`}
        >$</button>
        <button
          type="button"
          role="radio"
          aria-checked={value.kind === "percent"}
          onClick={() => onChange({ kind: "percent", value: value.value })}
          className={`border-l border-zinc-300 px-2 py-0.5 text-xs font-medium dark:border-zinc-700 ${
            value.kind === "percent"
              ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
              : "bg-white text-zinc-700 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
          }`}
        >%</button>
      </span>
      <input
        type="number"
        value={value.value === 0 ? "" : String(value.value)}
        placeholder="0"
        min={0}
        max={value.kind === "percent" ? 100 : undefined}
        step="any"
        onChange={(e) => {
          const raw = e.target.value === "" ? 0 : Number(e.target.value);
          onChange({ kind: value.kind, value: Number.isNaN(raw) ? 0 : raw });
        }}
        className={`${compact ? "w-14" : "w-20"} rounded border border-zinc-300 bg-white px-1 py-0.5 text-right font-mono text-xs dark:border-zinc-700 dark:bg-zinc-900`}
      />
      {equivAmount != null && (
        <span className="text-[10px] text-zinc-500">= ${equivAmount}</span>
      )}
    </span>
  );
}

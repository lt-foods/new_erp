"use client";

type StepState = "done" | "current" | "pending" | "rejected" | "skipped";

type StepEvent = {
  actor?: string | null; // 短碼 e.g. cktalex / 8c7af869
  time?: string | null; // ISO 或 'YYYY-MM-DD HH:mm'
  detail?: string | null;
};

export type PrStepEvents = {
  create?: StepEvent;
  draft?: StepEvent;
  submit?: StepEvent;
  review?: StepEvent;
  split?: StepEvent;
};

export function PrPipelineStepper({
  status,
  reviewStatus,
  events,
  compact = false,
}: {
  status: string;
  reviewStatus: string;
  events?: PrStepEvents;
  compact?: boolean;
}) {
  const isCancelled = status === "cancelled";
  const isRejected = reviewStatus === "rejected";

  const steps: { key: keyof PrStepEvents; label: string; state: StepState }[] = [];

  // S1 建立
  steps.push({ key: "create", label: "建立", state: "done" });

  // S2 編輯草稿
  if (status === "draft") steps.push({ key: "draft", label: "編輯草稿", state: "current" });
  else if (isCancelled) steps.push({ key: "draft", label: "編輯草稿", state: "skipped" });
  else steps.push({ key: "draft", label: "編輯草稿", state: "done" });

  // S3 送審
  if (status === "draft") steps.push({ key: "submit", label: "送出審核", state: "pending" });
  else if (status === "submitted" && reviewStatus === "pending_review")
    steps.push({ key: "submit", label: "送審中", state: "current" });
  else if (isCancelled) steps.push({ key: "submit", label: "送出審核", state: "skipped" });
  else steps.push({ key: "submit", label: "送出審核", state: "done" });

  // S4 審核完成
  if (status === "draft" || (status === "submitted" && reviewStatus === "pending_review"))
    steps.push({ key: "review", label: "審核完成", state: "pending" });
  else if (isRejected) steps.push({ key: "review", label: "已退回", state: "rejected" });
  else if (isCancelled) steps.push({ key: "review", label: "審核完成", state: "skipped" });
  else steps.push({ key: "review", label: "審核通過", state: "done" });

  // S5 建立採購訂單
  if (status === "fully_ordered")
    steps.push({ key: "split", label: "建立採購訂單", state: "done" });
  else if (status === "partially_ordered")
    steps.push({ key: "split", label: "部分建立", state: "current" });
  else if (isRejected || isCancelled)
    steps.push({ key: "split", label: "建立採購訂單", state: "skipped" });
  else steps.push({ key: "split", label: "建立採購訂單", state: "pending" });

  return (
    <ol className="flex items-start gap-1 sm:gap-2">
      {steps.map((s, i) => {
        const evt = events?.[s.key];
        const tooltip =
          evt && (evt.actor || evt.time)
            ? `${evt.actor ?? "—"}${evt.time ? `\n${evt.time}` : ""}${evt.detail ? `\n${evt.detail}` : ""}`
            : undefined;
        return (
          <li key={s.key} className="flex flex-1 items-start">
            <div
              className="flex flex-col items-center"
              title={tooltip}
            >
              <StepCircle state={s.state} index={i + 1} compact={compact} />
              {!compact && (
                <span
                  className={`mt-1.5 text-[11px] sm:text-xs ${labelCls(s.state)}`}
                >
                  {s.label}
                </span>
              )}
              {compact && (
                <span className={`mt-0.5 text-[10px] leading-tight ${labelCls(s.state)}`}>
                  {s.label}
                </span>
              )}
            </div>
            {i < steps.length - 1 && (
              <div
                className={`mt-3 h-0.5 flex-1 ${
                  s.state === "done"
                    ? "bg-emerald-500"
                    : s.state === "rejected"
                      ? "bg-red-400"
                      : "bg-zinc-200 dark:bg-zinc-700"
                } ${compact ? "mx-0.5" : "mx-1 sm:mx-2"}`}
              />
            )}
          </li>
        );
      })}
    </ol>
  );
}

function labelCls(state: StepState) {
  if (state === "current") return "font-semibold text-blue-600 dark:text-blue-400";
  if (state === "rejected") return "font-semibold text-red-600 dark:text-red-400";
  if (state === "done") return "text-zinc-700 dark:text-zinc-300";
  return "text-zinc-400 dark:text-zinc-500";
}

function StepCircle({
  state,
  index,
  compact,
}: {
  state: StepState;
  index: number;
  compact: boolean;
}) {
  const size = compact ? "h-5 w-5 text-[10px]" : "h-7 w-7 text-xs sm:h-8 sm:w-8";
  const base = `flex items-center justify-center rounded-full border-2 font-semibold ${size}`;
  if (state === "done")
    return <div className={`${base} border-emerald-500 bg-emerald-500 text-white`}>✓</div>;
  if (state === "current")
    return (
      <div
        className={`${base} border-blue-500 bg-blue-50 text-blue-600 ring-2 ring-blue-200 dark:bg-blue-950 dark:text-blue-300 dark:ring-blue-900`}
      >
        {index}
      </div>
    );
  if (state === "rejected")
    return <div className={`${base} border-red-500 bg-red-500 text-white`}>✕</div>;
  return (
    <div
      className={`${base} border-zinc-300 bg-white text-zinc-400 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-500`}
    >
      {index}
    </div>
  );
}

"use client";

type StepState = "done" | "current" | "pending" | "rejected" | "skipped";

type StepEvent = {
  actor?: string | null; // e.g. cktalex
  time?: string | null;
  detail?: string | null;
  href?: string | null; // 可選：step 點擊跳轉
};

export type PrStepEvents = {
  create?: StepEvent;
  draft?: StepEvent;
  submit?: StepEvent;
  review?: StepEvent;
  split?: StepEvent;
  send?: StepEvent;
  receive?: StepEvent;
  ship?: StepEvent;
  delivered?: StepEvent;
  finalize?: StepEvent;
};

export type POSummary = {
  total: number; // 該 PR 拆出多少張 PO
  sent: number; // status IN sent / partially_received / fully_received / closed
  receivedFully: number; // status IN fully_received / closed
};

export type TransferSummary = {
  total: number; // 該 PR 撿出多少張 transfer (hq_to_store)
  shipped: number; // transfer.status >= shipped
  delivered: number; // transfer.status = received
};

export function PrPipelineStepper({
  status,
  reviewStatus,
  events,
  poSummary,
  transferSummary,
  campaignFinalized,
  compact = false,
}: {
  status: string;
  reviewStatus: string;
  events?: PrStepEvents;
  poSummary?: POSummary;
  transferSummary?: TransferSummary;
  campaignFinalized?: boolean;
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

  // S6 發送供應商
  if (isRejected || isCancelled)
    steps.push({ key: "send", label: "發送供應商", state: "skipped" });
  else if (!poSummary || poSummary.total === 0 || poSummary.sent === 0)
    steps.push({ key: "send", label: "發送供應商", state: "pending" });
  else if (poSummary.sent < poSummary.total)
    steps.push({ key: "send", label: "部分發送", state: "current" });
  else steps.push({ key: "send", label: "已發送供應商", state: "done" });

  // S7 收貨（總倉收供應商貨）
  if (isRejected || isCancelled)
    steps.push({ key: "receive", label: "收貨", state: "skipped" });
  else if (!poSummary || poSummary.total === 0 || poSummary.receivedFully === 0)
    steps.push({ key: "receive", label: "收貨", state: "pending" });
  else if (poSummary.receivedFully < poSummary.total)
    steps.push({ key: "receive", label: "部分到貨", state: "current" });
  else steps.push({ key: "receive", label: "全部到貨", state: "done" });

  // S8 正在派貨（撿完出庫到分店、transfer.shipped）
  if (isRejected || isCancelled)
    steps.push({ key: "ship", label: "派貨", state: "skipped" });
  else if (!transferSummary || transferSummary.total === 0 || transferSummary.shipped === 0)
    steps.push({ key: "ship", label: "派貨", state: "pending" });
  else if (transferSummary.shipped < transferSummary.total)
    steps.push({ key: "ship", label: "部分派貨", state: "current" });
  else if (transferSummary.delivered < transferSummary.total)
    steps.push({ key: "ship", label: "派貨中", state: "current" });
  else steps.push({ key: "ship", label: "已派貨", state: "done" });

  // S9 分店收到確認（transfer.received）
  if (isRejected || isCancelled)
    steps.push({ key: "delivered", label: "分店確認", state: "skipped" });
  else if (!transferSummary || transferSummary.total === 0 || transferSummary.delivered === 0)
    steps.push({ key: "delivered", label: "分店確認", state: "pending" });
  else if (transferSummary.delivered < transferSummary.total)
    steps.push({ key: "delivered", label: "部分簽收", state: "current" });
  else steps.push({ key: "delivered", label: "全部簽收", state: "done" });

  // S10 結算
  if (isCancelled)
    steps.push({ key: "finalize", label: "結算", state: "skipped" });
  else if (campaignFinalized)
    steps.push({ key: "finalize", label: "已結算", state: "done" });
  else steps.push({ key: "finalize", label: "結算", state: "pending" });

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
            <StepInner
              href={evt?.href ?? undefined}
              tooltip={tooltip}
              clickable={!!evt?.href}
            >
              <StepCircle state={s.state} index={i + 1} compact={compact} />
              <span
                className={`mt-1.5 ${compact ? "text-[10px] leading-tight" : "text-[11px] sm:text-xs"} ${labelCls(s.state)}`}
              >
                {s.label}
              </span>
              {!compact && evt?.actor && s.state === "done" && (
                <span className="mt-0.5 text-[10px] text-zinc-500 dark:text-zinc-500">
                  {evt.actor}
                </span>
              )}
              {!compact && evt?.time && s.state === "done" && (
                <span className="text-[10px] text-zinc-400 dark:text-zinc-600">
                  {evt.time.replace(/\s.*/, "")}
                </span>
              )}
              {!compact && evt?.detail && (s.state === "current" || s.state === "done") && (
                <span className="text-[10px] text-zinc-500 dark:text-zinc-400">
                  {evt.detail}
                </span>
              )}
            </StepInner>
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

function StepInner({
  href,
  tooltip,
  clickable,
  children,
}: {
  href?: string;
  tooltip?: string;
  clickable: boolean;
  children: React.ReactNode;
}) {
  const baseCls = "flex flex-col items-center text-center";
  const interactiveCls = clickable
    ? "cursor-pointer rounded-md px-1 py-1 transition hover:bg-zinc-100 dark:hover:bg-zinc-800"
    : "";
  if (href) {
    return (
      <a href={href} title={tooltip} className={`${baseCls} ${interactiveCls}`}>
        {children}
      </a>
    );
  }
  return (
    <div title={tooltip} className={baseCls}>
      {children}
    </div>
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

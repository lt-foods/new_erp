"use client";

type Option = { value: string; label: string; count?: number };

/**
 * iOS-style segmented control。
 * 整體放在 #767680 ~12% alpha 的灰色 track 上，選中項是白色帶 shadow。
 *
 * variant="scroll"：蝦皮式底線分頁（可橫向捲動），給 4 個以上分頁用 ——
 * segmented control 塞 5 個在小螢幕會擠爆。
 */
export default function SubTabs({
  value,
  onChange,
  options,
  variant = "segment",
}: {
  value: string;
  onChange: (v: string) => void;
  options: Option[];
  variant?: "segment" | "scroll";
}) {
  if (variant === "scroll") {
    return (
      <div className="overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <div className="flex min-w-max gap-1 border-b border-[var(--separator)] px-2">
          {options.map((o) => {
            const active = value === o.value;
            return (
              <button
                key={o.value}
                onClick={() => onChange(o.value)}
                className={`relative whitespace-nowrap px-3 py-2.5 text-[15px] transition-colors duration-150 ${
                  active
                    ? "font-bold text-[var(--brand-strong)]"
                    : "font-medium text-[var(--ios-gray)]"
                }`}
              >
                {o.label}
                {o.count !== undefined && o.count > 0 && (
                  <span className={`ml-0.5 text-[13px] ${active ? "text-[var(--brand-strong)]/70" : "text-[var(--ios-gray)]/70"}`}>
                    {o.count}
                  </span>
                )}
                {active && (
                  <span className="absolute inset-x-3 bottom-0 h-[2.5px] rounded-full bg-[var(--brand-strong)]" />
                )}
              </button>
            );
          })}
        </div>
      </div>
    );
  }

  return (
    <div className="px-4 pt-3">
      <div className="flex rounded-[10px] bg-[#7676801f] p-[2px]">
        {options.map((o) => {
          const active = value === o.value;
          return (
            <button
              key={o.value}
              onClick={() => onChange(o.value)}
              className={`flex-1 rounded-[8px] px-3 py-2 text-[15px] transition-all duration-200 ${
                active
                  ? "bg-white font-bold text-[var(--brand-strong)] shadow-[0_3px_10px_-2px_rgba(158,47,80,0.18),0_1px_2px_rgba(0,0,0,0.04)]"
                  : "bg-transparent font-medium text-[var(--ios-gray)]"
              }`}
            >
              {o.label}
              {o.count !== undefined && (
                <span className={`ml-1 ${active ? "text-[var(--ios-gray)]" : "text-[var(--ios-gray)]/70"}`}>
                  ({o.count})
                </span>
              )}
            </button>
          );
        })}
      </div>
    </div>
  );
}

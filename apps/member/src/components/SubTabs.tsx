"use client";

type Option = { value: string; label: string; count?: number | string };

/**
 * iOS-style segmented control。
 * 整體放在 #767680 ~12% alpha 的灰色 track 上，選中項是白色帶 shadow。
 */
export default function SubTabs({
  value,
  onChange,
  options,
}: {
  value: string;
  onChange: (v: string) => void;
  options: Option[];
}) {
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

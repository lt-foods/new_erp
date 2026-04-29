"use client";

type Option = { value: string; label: string; count?: number };

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
    <div className="flex gap-2 border-b border-zinc-200 px-2">
      {options.map((o) => {
        const active = value === o.value;
        return (
          <button
            key={o.value}
            onClick={() => onChange(o.value)}
            className={`relative px-3 py-2.5 text-sm transition-colors ${
              active
                ? "font-medium text-pink-600"
                : "text-zinc-500 hover:text-zinc-700"
            }`}
          >
            {o.label}
            {o.count !== undefined && (
              <span className="ml-1 text-xs text-zinc-400">({o.count})</span>
            )}
            {active && (
              <span className="absolute inset-x-3 -bottom-px h-0.5 bg-pink-600" />
            )}
          </button>
        );
      })}
    </div>
  );
}

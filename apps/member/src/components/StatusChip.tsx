type Tone = "ok" | "muted";

export default function StatusChip({
  tone,
  label,
}: {
  tone: Tone;
  label: string;
}) {
  if (tone === "ok") {
    return (
      <span className="inline-flex items-center gap-0.5 rounded-full bg-pink-100 px-2 py-0.5 text-xs font-medium text-pink-700">
        ✓ {label}
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-0.5 rounded-full bg-zinc-100 px-2 py-0.5 text-xs text-zinc-500">
      ! {label}
    </span>
  );
}

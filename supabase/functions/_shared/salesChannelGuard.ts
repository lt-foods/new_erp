export function isMissingSalesChannelColumn(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const e = error as { code?: unknown; message?: unknown; details?: unknown; hint?: unknown };
  return e.code === "42703"
    && [e.message, e.details, e.hint].some((v) => typeof v === "string" && /\bsales_channel\b/i.test(v));
}

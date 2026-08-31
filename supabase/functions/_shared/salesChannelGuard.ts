export function isMissingSalesChannelColumn(error: unknown): boolean {
  return isMissingColumn(error, "sales_channel");
}

/** 店家自開團的欄位（20260831000000）。migration 尚未套用時退回舊查法。 */
export function isMissingOwnerStoreColumn(error: unknown): boolean {
  return isMissingColumn(error, "owner_store_id");
}

function isMissingColumn(error: unknown, column: string): boolean {
  if (!error || typeof error !== "object") return false;
  const e = error as { code?: unknown; message?: unknown; details?: unknown; hint?: unknown };
  return e.code === "42703"
    && [e.message, e.details, e.hint].some(
      (v) => typeof v === "string" && new RegExp(`\\b${column}\\b`, "i").test(v),
    );
}

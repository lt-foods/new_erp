export function normalizePiaopiaoLoginId(value: unknown): string | null {
  const id = typeof value === "string" ? value.trim().toLowerCase() : "";
  return /^[a-z0-9][a-z0-9._-]{2,31}$/.test(id) ? id : null;
}

export function piaopiaoLoginEmail(loginId: string): string {
  return `${loginId}@piaopiao.local`;
}

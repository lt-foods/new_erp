// Map known Postgres RAISE EXCEPTION messages → Chinese.
// Add patterns as more surface in production.

type Rule = { pattern: RegExp; render: (m: RegExpMatchArray) => string };

const RULES: Rule[] = [
  {
    pattern: /Insufficient stock:\s*available=([\d.]+),\s*required=([\d.]+)/i,
    render: (m) => `庫存不足：總倉只剩 ${fmt(m[1])} 件，本次需要 ${fmt(m[2])} 件`,
  },
  {
    pattern: /Insufficient points:\s*available=([\d.]+),\s*required=([\d.]+)/i,
    render: (m) => `點數不足：可用 ${fmt(m[1])} 點，本次需要 ${fmt(m[2])} 點`,
  },
  {
    pattern: /Insufficient wallet:\s*available=([\d.]+),\s*required=([\d.]+)/i,
    render: (m) => `儲值金不足：可用 $${fmt(m[1])}，本次需要 $${fmt(m[2])}`,
  },
  { pattern: /Outbound quantity must be positive/i, render: () => "出庫數量必須大於 0" },
  { pattern: /Inbound quantity must be positive/i, render: () => "入庫數量必須大於 0" },
];

function fmt(s: string): string {
  const n = Number(s);
  if (!Number.isFinite(n)) return s;
  return Number.isInteger(n) ? String(n) : String(n);
}

export function translateRpcError(raw: unknown): string {
  const msg = raw instanceof Error ? raw.message : String(raw);
  for (const r of RULES) {
    const m = msg.match(r.pattern);
    if (m) return r.render(m);
  }
  return msg;
}

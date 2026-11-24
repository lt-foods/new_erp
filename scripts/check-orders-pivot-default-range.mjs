import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const page = readFileSync(
  resolve(root, "apps/admin/src/app/(protected)/orders/pivot/page.tsx"),
  "utf8",
).replace(/\r\n/g, "\n");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// 1) 日期不再從 localStorage 還原；網址 from/to 仍有讀
assert(!/saved\.dateFrom|saved\.dateTo/.test(page), "date must not be restored from localStorage");
assert(
  /searchParams\.get\("from"\)/.test(page) && /searchParams\.get\("to"\)/.test(page),
  "URL from/to must still be read",
);
assert(/saved\.campaignIds/.test(page) && /saved\.viewBy/.test(page), "other filters must still restore");

// 2) 抽出 page.tsx 裡真正的函式本體來跑（去掉型別標註）
function extract(name) {
  const re = new RegExp(String.raw`function ${name}\([^)]*\)[^{]*\{[\s\S]*?\n\}\n`);
  const m = page.match(re);
  assert(m, `cannot find ${name} in page.tsx`);
  return m[0]
    .replace(/\(d: Date, n: number\): Date/, "(d, n)")
    .replace(/\(d: Date\): string/, "(d)")
    .replace(/\(\): \{ from: string; to: string \}/, "()");
}
const code = ["fmtDateInput", "shiftMonthsClamped", "defaultDateRange"].map(extract).join("\n");
const factory = new Function("RealDate", `
  let NOW = null;
  const Date = class extends RealDate {
    constructor(...a) { if (a.length === 0) return new RealDate(NOW); return new RealDate(...a); }
  };
  ${code}
  return { setNow(s) { NOW = s; }, defaultDateRange, shiftMonthsClamped, fmtDateInput };
`);
const api = factory(Date);

const cases = [
  ["2026-11-24T10:00:00", "2026-10-24", "2026-12-24"],
  ["2026-03-31T10:00:00", "2026-02-28", "2026-04-30"],
  ["2024-03-31T10:00:00", "2024-02-29", "2024-04-30"],
  ["2026-01-31T10:00:00", "2025-12-31", "2026-02-28"],
  ["2026-12-15T10:00:00", "2026-11-15", "2027-01-15"],
];
for (const [now, from, to] of cases) {
  api.setNow(now);
  const r = api.defaultDateRange();
  assert(r.from === from && r.to === to, `${now}: got ${r.from}~${r.to}, want ${from}~${to}`);
}
console.log("check-orders-pivot-default-range: ok");

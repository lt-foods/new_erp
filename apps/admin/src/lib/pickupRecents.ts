// 取貨櫃台「常用顧客」快選：紀錄在 localStorage，每個取貨終端各自累積
// （單店單櫃台 → 天然 per-store，不需 schema / 跨裝置同步）。
// 「使用」訊號 = 實際取貨成功，避免誤搜污染。

const KEY = "pickup_recents_v1";
const MAX_STORED = 100;       // 超過就淘汰最舊的
const MAX_RETURNED = 10;      // 快選列最多顯示幾顆
const TTL_MS = 60 * 24 * 60 * 60 * 1000; // 60 天內才算「最近」

export type RecentCustomer = {
  id: number;
  name: string | null;
  member_no: string;
  phone: string | null;
  count: number;
  lastAt: number; // epoch ms
};

function read(): RecentCustomer[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(KEY);
    if (!raw) return [];
    const arr = JSON.parse(raw) as RecentCustomer[];
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

function write(list: RecentCustomer[]) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(KEY, JSON.stringify(list));
  } catch {
    // localStorage 滿 / 隱私模式 → 靜默忽略，不影響取貨主流程
  }
}

// count desc → lastAt desc：較常用且較近者在前
function sortRecents(a: RecentCustomer, b: RecentCustomer): number {
  if (a.count !== b.count) return b.count - a.count;
  return b.lastAt - a.lastAt;
}

export function getPickupRecents(): RecentCustomer[] {
  const cutoff = Date.now() - TTL_MS;
  return read()
    .filter((r) => r.lastAt >= cutoff)
    .sort(sortRecents)
    .slice(0, MAX_RETURNED);
}

export function recordPickupRecent(m: {
  id: number;
  name: string | null;
  member_no: string;
  phone: string | null;
}): void {
  const now = Date.now();
  const list = read();
  const existing = list.find((r) => r.id === m.id);
  if (existing) {
    existing.count += 1;
    existing.lastAt = now;
    existing.name = m.name;
    existing.member_no = m.member_no;
    existing.phone = m.phone;
  } else {
    list.push({ id: m.id, name: m.name, member_no: m.member_no, phone: m.phone, count: 1, lastAt: now });
  }
  // 淘汰：先依排序，截斷到 MAX_STORED
  const trimmed = list.sort(sortRecents).slice(0, MAX_STORED);
  write(trimmed);
}

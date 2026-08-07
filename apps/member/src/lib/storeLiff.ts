/**
 * 「這家店該用哪支 LIFF 登入」的查表。
 *
 * 為什麼要分店查表：LINE 的 user ID 是**綁 Provider** 的。本租戶 14 家店的
 * 官方帳號各自在自己的 Provider 底下，會員必須用「所屬分店那支 Login channel
 * 的 LIFF」登入，拿到的 line_user_id 才跟該店 OA 通用 —— 用錯的 LIFF 登入，
 * ID 存進資料庫也推不動訊息（2026-08-07 實測：取樣 12 位松山店會員，
 * 用舊 ID 查該店 OA 的 profile 全數 404）。
 *
 * 沒設定該店 LIFF ID 時退回 `NEXT_PUBLIC_LIFF_ID`（租戶層預設），
 * 也就是維持這個欄位出現之前的行為，不會讓既有的店突然登不進去。
 *
 * ⚠ 快取存在 localStorage 是**必要的**，不是效能優化：
 *   在 LINE 內冷啟動時，`liff.init()` 必須用「當初開啟這個 app 的那支 LIFF ID」，
 *   而那時門市清單還沒抓回來。有快取才不會退回錯的預設值。
 */

import { callLiffApi } from "./supabase";

const CACHE_KEY = "store_liff_ids";

export type StoreLiffMap = Record<string, string>;  // store code → liff id

function envLiffId(): string | undefined {
  return process.env.NEXT_PUBLIC_LIFF_ID || undefined;
}

function readCache(): StoreLiffMap {
  if (typeof window === "undefined") return {};
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    return raw ? (JSON.parse(raw) as StoreLiffMap) : {};
  } catch {
    return {};
  }
}

/** 門市清單載回來時呼叫，把 code → liff id 的對照存起來 */
export function cacheStoreLiffIds(
  stores: { code: string; line_liff_id?: string | null }[],
): void {
  if (typeof window === "undefined") return;
  const map: StoreLiffMap = {};
  for (const s of stores) {
    if (s.code && s.line_liff_id) map[s.code] = s.line_liff_id;
  }
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(map));
  } catch { /* 隱私模式寫不進去就算了，退回預設值仍可運作 */ }
}

/** 只讀快取，不發網路請求。給 render / callback 這種不能 await 的地方用。 */
export function resolveLiffIdSync(storeCode: string | null): string | undefined {
  if (!storeCode) return envLiffId();
  return readCache()[storeCode] ?? envLiffId();
}

/**
 * 解析該店的 LIFF ID；快取沒有就抓一次門市清單。
 *
 * 抓清單有 timeout —— 這條路擋在 `liff.init()` 前面，網路慢的話不能把整個
 * 登入流程押在它身上（對齊 useLineLogin 裡 liff.init 也包 timeout 的做法）。
 */
export async function resolveLiffId(
  storeCode: string | null,
  timeoutMs = 3000,
): Promise<string | undefined> {
  if (!storeCode) return envLiffId();

  const cached = readCache()[storeCode];
  if (cached) return cached;

  try {
    const r = await Promise.race([
      callLiffApi<{ stores: { code: string; line_liff_id?: string | null }[] }>(
        "", { action: "list_stores" },
      ),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("list_stores timeout")), timeoutMs),
      ),
    ]);
    cacheStoreLiffIds(r.stores ?? []);
    return readCache()[storeCode] ?? envLiffId();
  } catch {
    // 抓不到就用預設值 —— 跟這個功能出現之前的行為一致
    return envLiffId();
  }
}

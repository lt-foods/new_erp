// 前端錯誤 log —— 會員手機上的 console 我們看不到，所以「使用者會卡住」的分支
// 一律呼叫 logClientError()，一份寫進 DB（liff-api → client_error_logs），
// 一份留在本機 ring buffer（/debug 可以當場看，網路不通時也還在）。
//
// 三個硬規則：
//   1. 永遠不 throw、不 await 卡住呼叫端 —— log 失敗不能變成新的錯誤。
//   2. 有節流 —— 進到 render loop 時不能把自己的 DB 灌爆。
//   3. 不記 token、不記完整個資 —— detail 裡只放除錯需要的東西。

const LOCAL_KEY = "client_error_log";
const LOCAL_MAX = 50;
/** 同一則訊息的最短重送間隔 */
const DEDUPE_MS = 30_000;
/** 單次瀏覽最多送幾筆到後端 */
const SESSION_MAX = 30;

export type ClientLogLevel = "error" | "warn" | "info";

export type ClientLogEntry = {
  at: string;
  level: ClientLogLevel;
  source: string;
  message: string;
  detail?: unknown;
};

const sentAt = new Map<string, number>();
let sentCount = 0;

/** Error / 任意 throw 值 → 可讀訊息 */
export function errMessage(e: unknown): string {
  if (e instanceof Error) return e.message || e.name;
  if (typeof e === "string") return e;
  try { return JSON.stringify(e); } catch { return String(e); }
}

function errDetail(e: unknown): Record<string, unknown> | undefined {
  if (e instanceof Error) {
    return { name: e.name, stack: e.stack?.slice(0, 2000) };
  }
  return undefined;
}

/** 當下的執行環境 —— 判斷 LIFF / PWA 相關問題幾乎都要看這幾個值 */
function env(): Record<string, unknown> {
  if (typeof window === "undefined") return {};
  const nav = window.navigator as Navigator & { standalone?: boolean };
  return {
    in_line: / Line\//i.test(nav.userAgent),
    in_liff: typeof window.liff?.isInClient === "function"
      ? safeBool(() => window.liff!.isInClient())
      : null,
    standalone:
      nav.standalone === true ||
      window.matchMedia("(display-mode: standalone)").matches,
    has_liff_id: Boolean(process.env.NEXT_PUBLIC_LIFF_ID),
    lang: nav.language,
    screen: `${window.screen?.width ?? 0}x${window.screen?.height ?? 0}`,
  };
}

function safeBool(fn: () => boolean): boolean | null {
  try { return fn(); } catch { return null; }
}

/** 本機 ring buffer —— /debug 讀這個 */
function pushLocal(entry: ClientLogEntry) {
  try {
    const raw = localStorage.getItem(LOCAL_KEY);
    const list: ClientLogEntry[] = raw ? JSON.parse(raw) : [];
    list.push(entry);
    localStorage.setItem(
      LOCAL_KEY,
      JSON.stringify(list.slice(-LOCAL_MAX)),
    );
  } catch { /* 存不進去就算了，不能因為 log 再壞一次 */ }
}

export function getLocalLogs(): ClientLogEntry[] {
  try {
    const raw = localStorage.getItem(LOCAL_KEY);
    return raw ? JSON.parse(raw) as ClientLogEntry[] : [];
  } catch { return []; }
}

export function clearLocalLogs() {
  try { localStorage.removeItem(LOCAL_KEY); } catch { /* noop */ }
}

/**
 * 記一筆前端錯誤。fire-and-forget，呼叫端不需要 await。
 *
 * @param source 發生位置代號（例：`liff_auto_login_failed`），查 log 時用這個分群
 */
export function logClientError(
  source: string,
  message: string,
  detail?: unknown,
  level: ClientLogLevel = "error",
): void {
  const entry: ClientLogEntry = {
    at: new Date().toISOString(),
    level,
    source,
    message,
    detail,
  };

  if (level === "error") console.error(`[${source}]`, message, detail ?? "");
  else console.warn(`[${source}]`, message, detail ?? "");

  pushLocal(entry);
  void sendRemote(entry);
}

/** 直接吃 catch 到的東西，自動抽 message / stack */
export function logCaught(source: string, e: unknown, extra?: Record<string, unknown>): void {
  logClientError(source, errMessage(e), { ...errDetail(e), ...extra });
}

async function sendRemote(entry: ClientLogEntry): Promise<void> {
  try {
    if (typeof window === "undefined") return;
    const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
    if (!base) return;

    // 節流：同訊息 30 秒內只送一次、單次瀏覽最多 30 筆
    const key = `${entry.source}|${entry.message}`;
    const now = Date.now();
    const last = sentAt.get(key);
    if (last && now - last < DEDUPE_MS) return;
    if (sentCount >= SESSION_MAX) return;
    sentAt.set(key, now);
    sentCount += 1;

    const token = localStorage.getItem("member_jwt");
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;

    await fetch(`${base}/functions/v1/liff-api`, {
      method: "POST",
      headers,
      // keepalive：使用者當下常常正要跳頁（登入失敗、導去 LIFF），
      // 沒有 keepalive 這筆 log 會跟著 navigation 一起被取消。
      keepalive: true,
      body: JSON.stringify({
        action: "log_client_error",
        level: entry.level,
        source: entry.source,
        message: entry.message,
        detail: entry.detail ?? null,
        store_code: localStorage.getItem("member_store_id"),
        line_user_id: localStorage.getItem("line_user_id"),
        page_url: window.location.href.slice(0, 500),
        user_agent: navigator.userAgent,
        env: env(),
      }),
    });
  } catch {
    // 送不出去就只留本機那份 —— 這裡絕對不能再拋
  }
}

let pageUnloading = false;
if (typeof window !== "undefined") {
  window.addEventListener("pagehide", () => { pageUnloading = true; });
}

/**
 * 頁面正在離開嗎？
 *
 * 跳頁時所有 in-flight 的 fetch 都會被瀏覽器取消，變成 TypeError（Safari 是
 * "Load failed"），看起來跟真的網路故障一模一樣。這種不是錯誤，不要記 —
 * 不然真的故障會被淹在雜訊裡。
 */
export function isPageUnloading(): boolean {
  return pageUnloading;
}

let handlersInstalled = false;

/**
 * 掛全域攔截器（未被 catch 的錯誤 / promise rejection）。
 * 在 layout 掛一次就好，重複呼叫是 no-op。
 */
export function installGlobalErrorLogging(): void {
  if (typeof window === "undefined" || handlersInstalled) return;
  handlersInstalled = true;

  window.addEventListener("error", (ev) => {
    // 圖片 / script 載入失敗也會走 error event，但沒有 ev.error
    const where = ev.filename
      ? `${ev.filename}:${ev.lineno}:${ev.colno}`
      : undefined;
    logClientError(
      "window_error",
      ev.message || errMessage(ev.error),
      { where, ...errDetail(ev.error) },
    );
  });

  window.addEventListener("unhandledrejection", (ev) => {
    logClientError(
      "unhandled_rejection",
      errMessage(ev.reason),
      errDetail(ev.reason),
    );
  });
}

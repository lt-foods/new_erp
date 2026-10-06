// 月結列表「一次全選送出給店家核對」的純函式（不碰 React、不碰資料庫），單獨測試：
//   node --test "apps/admin/src/app/(protected)/transfers/settlement/bulkSend.test.mjs"
//
// 送出本身照舊走 rpc_send_settlement_to_store（一次一張），這裡只決定「哪幾張能勾」。
// ⚠️ 這些擋法只在畫面上；RPC 本身只收 draft／爭議已處理的 disputed，不看月份。

/**
 * 能送店家核對的第一個月份。
 * 8 月以前的月結不進系統（老闆用系統外臨時帳收），草稿留著不要送：
 * supabase/migrations/20260901000000_settlement_dispatch_basis.sql:11
 */
export const BULK_SEND_FIRST_MONTH = "2026-09";

/** 台北時間（UTC+8，台灣不實施夏令時間）的「YYYY-MM」；不依賴瀏覽器所在時區 */
export function taipeiMonth(now: Date): string {
  const t = new Date(now.getTime() + 8 * 60 * 60 * 1000);
  return `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}`;
}

/** "2026-10" → "2026-11-01"；"2026-12" → "2027-01-01" */
export function nextMonthFirstDay(month: string): string {
  const [y, m] = month.split("-").map(Number);
  return m === 12 ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, "0")}-01`;
}

/**
 * 整個月份能不能批次送；能 → null，不能 → 白話原因（批次列與每列滑鼠提示共用）。
 * monthFilter：畫面「月份篩選」的值（"YYYY-MM"，沒選是 ""）。
 *
 * 「月份已結束」＝台北時間今天 ≥ 下個月 1 號。月份還沒過完就送，店家一按同意就鎖住，
 * 之後重算會整店跳過，下半月派出去的貨就收不到錢。
 */
export function bulkSendMonthBlockReason(monthFilter: string, now: Date): string | null {
  if (!monthFilter) return "先選月份";
  if (monthFilter < BULK_SEND_FIRST_MONTH) return "8 月（含）以前的月結不送店家核對";
  if (taipeiMonth(now) <= monthFilter) {
    return `${monthFilter} 還沒結束，要到 ${nextMonthFirstDay(monthFilter)}（台北時間）才能送`;
  }
  return null;
}

export type BulkSendRow = { status: string; settlement_month: string | null };

/** 這一列能不能勾；能 → null，不能 → 白話原因（給勾選框的滑鼠提示） */
export function bulkSendBlockReason(row: BulkSendRow, monthFilter: string, now: Date): string | null {
  const monthReason = bulkSendMonthBlockReason(monthFilter, now);
  if (monthReason) return monthReason;
  // 換篩選月份、列表還沒重新載入的那一瞬間，畫面上會是上一個月份的列
  if ((row.settlement_month ?? "").slice(0, 7) !== monthFilter) return "不是目前篩選的月份";
  if (row.status === "disputed") return "店家有異議：請進明細頁處理完，再一張一張重新送";
  if (row.status !== "draft") return "只有草稿能一次送出";
  return null;
}

export type SendOutcome = { ok: number; fails: { label: string; message: string }[] };

/**
 * 把逐張送出的結果彙總成「成功幾家／失敗哪幾家、為什麼」。
 * labels 與 settles 依同一順序一一對應（labels[i] 是第 i 張的店名）。
 */
export function collectSendResults(
  labels: string[],
  settles: PromiseSettledResult<{ error: { message: string } | null }>[],
): SendOutcome {
  let ok = 0;
  const fails: SendOutcome["fails"] = [];
  settles.forEach((s, i) => {
    if (s.status === "fulfilled" && !s.value.error) {
      ok += 1;
      return;
    }
    const message =
      s.status === "rejected"
        ? s.reason instanceof Error ? s.reason.message : String(s.reason)
        : s.value.error?.message ?? "不明錯誤";
    fails.push({ label: labels[i] ?? `第 ${i + 1} 張`, message });
  });
  return { ok, fails };
}

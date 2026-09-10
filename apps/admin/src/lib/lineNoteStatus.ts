// LINE 記事本的狀態文字與留言統計，一份。
//
// 同一套東西現在有兩個入口在畫：LINE 記事本頁的「貼文」分頁（全站，含未認出團的）
// 與開團列表每一團的「LINE 記事本」彈窗（LineNotePostsModal，只看那一團）。
// 兩邊各寫一份的話，同一則留言會在兩個畫面上被算成不同狀態 —— 徽章數字對不起來
// 就沒人敢相信它。
//
// ⚠ isTodoComment 的判定 DB 也有一份：public._line_note_comment_is_todo
// （20260910020000，rpc_line_note_campaign_targets 的統計用它），改這裡記得改那支。

export type LineNotePostStatus = "queued" | "posted" | "failed" | "closed" | "unlinked";
export type LineNoteCommentStatus =
  | "pending" | "ordered" | "unmatched" | "no_order" | "error" | "ignored" | "resolved" | "duplicate";

export const POST_STATUS_LABEL: Record<LineNotePostStatus, string> = {
  queued: "排隊中", posted: "已發文", failed: "失敗", closed: "已結束", unlinked: "未認出團",
};

export const COMMENT_STATUS_LABEL: Record<LineNoteCommentStatus, string> = {
  pending: "待處理", ordered: "已加單", unmatched: "找不到會員", no_order: "非下單",
  error: "錯誤", ignored: "忽略", resolved: "已解決", duplicate: "已有訂單",
};

export const HOME_KIND_LABEL: Record<string, string> = {
  group: "群組", square: "社群", square_chat: "社群聊天室",
};

/**
 * 這則留言還要人看嗎？
 * no_order（解析不出訂單）本來不算，但**留言裡有 6 碼會員編號**就算 ——
 * 那是「客人想下單、我們看不懂他寫什麼」，放掉就是漏單。
 */
export function isTodoComment(c: { status: string; member_no_hint?: string | null }): boolean {
  return ["pending", "unmatched", "error"].includes(c.status)
    || (c.status === "no_order" && !!c.member_no_hint);
}

export type CommentStat = { total: number; ordered: number; duplicate: number; todo: number };

export function commentStats(rows: { status: string; member_no_hint?: string | null }[]): CommentStat {
  const st: CommentStat = { total: 0, ordered: 0, duplicate: 0, todo: 0 };
  for (const c of rows) {
    st.total++;
    if (c.status === "ordered") st.ordered++;
    else if (c.status === "duplicate") st.duplicate++;
    else if (isTodoComment(c)) st.todo++;
  }
  return st;
}

/** 台北時間的短格式（月/日 時:分）；記事本相關畫面都用這個 */
export function fmtNoteTime(iso: string | null | undefined): string {
  return iso
    ? new Date(iso).toLocaleString("zh-TW", { hour12: false, month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })
    : "—";
}

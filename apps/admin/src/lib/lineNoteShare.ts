// 手動把已經在記事本上的貼文分享到聊天室，或把分享出去的卡片收回（老闆 9/27：「有手動分享貼文的功能嗎」「還有回收」）。
// 兩個入口共用：LINE 記事本頁的「貼文」分頁、開團的「LINE 記事本」彈窗。
//
// 走 Edge Function 的 share_post / unshare_post（同 delete_post，後台直接呼叫、當場回結果）。
// 分享用社群自己記住的聊天室（子群走母社群那篇）；收回只收得回後台記得住訊息 id 的那幾則
// （9/25 之前分享的沒記 id，收不回，worker 會直接講）。記事本貼文本身兩個動作都不碰。

import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import type { LineNotePostRef } from "@/lib/lineNoteDelete";

export type ShareOutcome =
  | { kind: "cancelled" }
  | { kind: "done"; message: string }
  | { kind: "failed"; error: string };

async function callWorker(action: "share_post" | "unshare_post" | "recall_post", postId: number) {
  const { data, error } = await getSupabase().functions
    .invoke("line-note-worker", { body: { action, post_id: postId } });
  const res = (data ?? {}) as { ok?: boolean; error?: string; unsent?: number; failed?: number };
  // supabase-js 把非 2xx 包成 FunctionsHttpError，訊息看不出原因，優先用函式自己回的
  return { ok: !error && !!res.ok, res, error: res.error ?? (error ? translateRpcError(error) : "未知錯誤") };
}

export async function shareLineNotePost(post: LineNotePostRef, alreadyShared: boolean): Promise<ShareOutcome> {
  if (!post.line_post_id) return { kind: "failed", error: "這篇還沒發到 LINE，沒有東西可以分享" };
  if (!window.confirm(
    `把「${post.label}」這篇貼文分享到聊天室？\n\n` +
    (alreadyShared ? "這篇已經分享過了，會**再貼一張**分享卡片到聊天室。\n" : "") +
    `會用 LINE 原生的「分享貼文」卡片貼到這個社群的聊天室，成員在聊天裡就點得到。`)) return { kind: "cancelled" };
  const r = await callWorker("share_post", post.id);
  return r.ok ? { kind: "done", message: "已分享到聊天室" } : { kind: "failed", error: r.error };
}

export async function recallLineNoteShare(post: LineNotePostRef): Promise<ShareOutcome> {
  if (!window.confirm(
    `收回「${post.label}」分享到聊天室的卡片？\n\n` +
    `只收回聊天室裡的分享訊息，記事本上的貼文與留言都不動。\n` +
    `（只收得回後台記得住的那幾則；收回之後這篇會變回「未分享」，可以再分享一次。）`)) return { kind: "cancelled" };
  const r = await callWorker("unshare_post", post.id);
  if (!r.ok) return { kind: "failed", error: r.error };
  const n = r.res.unsent ?? 0, f = r.res.failed ?? 0;
  return { kind: "done", message: f ? `收回 ${n} 則、${f} 則收不回（LINE 不讓小幫手收回）` : `已收回分享（${n} 則）` };
}

/** 回收貼文：LINE 上那篇刪掉、分享卡片收回，後台紀錄留著（留言、已加的單都在），這個社群可以再發一次。 */
export async function recallLineNotePost(post: LineNotePostRef): Promise<ShareOutcome> {
  if (!post.line_post_id) return { kind: "failed", error: "這篇還沒發到 LINE，沒有東西可以回收" };
  if (!window.confirm(
    `回收「${post.label}」這篇貼文？\n\n` +
    `會從 LINE 記事本把這篇**刪掉**（分享到聊天室的卡片也一起收回），社群成員就看不到了。\n` +
    `後台的貼文、留言紀錄與已經加出來的訂單都留著；回收之後這個社群可以重新發一次。\n\n` +
    `（要連後台紀錄一起清掉請用「刪除貼文」。）`)) return { kind: "cancelled" };
  const r = await callWorker("recall_post", post.id);
  if (!r.ok) return { kind: "failed", error: r.error };
  const f = r.res.failed ?? 0;
  return { kind: "done", message: f ? `已回收貼文；${f} 則分享卡片收不回` : "已回收貼文，這個社群可以重新發一次" };
}

// 刪掉一篇記事本貼文。兩個入口共用：LINE 記事本頁的「貼文」分頁、開團的「LINE 記事本」彈窗。
//
// 「刪除」以前只清後台紀錄，貼文還躺在社群裡 —— 貼錯團、貼錯價格的時候等於沒救，
// 只能拿備用帳號的手機自己進 LINE 刪。現在預設**連 LINE 上那篇一起刪掉**。
//
// 刪不掉的時候（帳號掉線最常見）不會硬清紀錄，而是問要不要只清後台的 ——
// 靜靜清掉的話貼文會繼續收留言，而且下次讀取又會被 discoverPosts 當成新貼文認一次。

import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

export type LineNotePostRef = {
  id: number;
  line_post_id: string | null;
  /** 顯示用的名字（團名 / 貼文第一行），只進確認視窗的文字 */
  label: string;
};

export type DeleteOutcome =
  | { kind: "cancelled" }
  | { kind: "deleted" }            // LINE 上那篇也刪掉了，後台紀錄一併清除
  | { kind: "record_only" }        // 只清了後台紀錄，LINE 上那篇還在（或本來就沒發出去）
  | { kind: "failed"; error: string };

const RECORD_ONLY_NOTE =
  "只清掉後台的貼文與留言紀錄。已經加出來的訂單不會動（要退單請到訂單那邊）。";

/** 只清後台紀錄，不碰 LINE */
async function deleteRecord(postId: number): Promise<DeleteOutcome> {
  const { error } = await getSupabase().rpc("rpc_line_note_post_delete", { p_id: postId });
  return error ? { kind: "failed", error: translateRpcError(error) } : { kind: "record_only" };
}

export async function deleteLineNotePost(post: LineNotePostRef): Promise<DeleteOutcome> {
  // 沒發到 LINE 過（排隊中 / 發文失敗 / 未認出團但抓不到 id）→ 沒東西可刪，就是清紀錄
  if (!post.line_post_id) {
    if (!window.confirm(`刪除「${post.label}」的貼文紀錄？\n\n${RECORD_ONLY_NOTE}`)) return { kind: "cancelled" };
    return await deleteRecord(post.id);
  }

  if (!window.confirm(
    `刪除「${post.label}」這篇貼文？\n\n` +
    `會從 LINE 記事本把這篇**刪掉**，社群成員就看不到了，底下的留言也會跟著消失。\n` +
    `後台的貼文與留言紀錄一併清除；已經加出來的訂單不會動（要退單請到訂單那邊）。\n\n` +
    `刪掉之後這個團可以重新發一次。`)) return { kind: "cancelled" };

  const { data, error } = await getSupabase().functions
    .invoke("line-note-worker", { body: { action: "delete_post", post_id: post.id } });
  const res = (data ?? {}) as { ok?: boolean; error?: string; noLinePost?: boolean };
  if (!error && res.ok) return { kind: "deleted" };

  // supabase-js 把非 2xx 包成 FunctionsHttpError，訊息看不出原因，優先用函式自己回的
  const why = res.error ?? (error ? translateRpcError(error) : "未知錯誤");
  if (!window.confirm(
    `LINE 上那篇刪不掉：${why}\n\n` +
    `（帳號掉線的話，到「LINE 記事本 → 帳號」重新登入再刪一次就好。）\n\n` +
    `要改成只清後台紀錄嗎？\n貼文會**繼續留在社群裡**，之後讀取還可能把它重新認回來。`)) {
    return { kind: "failed", error: why };
  }
  return await deleteRecord(post.id);
}

// 把 LINE 記事本上已經發出去的那篇改成現在的內容（品項 / 金額打錯，開團那邊改好之後按這個）。
// 兩個入口共用：LINE 記事本頁的「貼文」分頁、開團的「LINE 記事本」彈窗。
//
// 走 Edge Function 的 update_post（同 delete_post，後台直接呼叫、當場回結果）。
// 只改貼文本體：LINE 貼文 id 不變，底下留言、已加出來的訂單都不會動。

import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import type { LineNotePostRef } from "@/lib/lineNoteDelete";

export type UpdateOutcome =
  | { kind: "cancelled" }
  | { kind: "updated" }
  | { kind: "failed"; error: string };

export async function updateLineNotePost(post: LineNotePostRef): Promise<UpdateOutcome> {
  if (!post.line_post_id) return { kind: "failed", error: "這篇還沒發到 LINE，沒有東西可以更新" };
  if (!window.confirm(
    `把「${post.label}」這篇貼文更新成現在的內容？\n\n` +
    `會用開團目前的品項 / 價格 / 結單時間重新產生貼文，並覆蓋 LINE 記事本上那一篇（圖片也會重傳）。\n` +
    `貼文底下的留言、已經加出來的訂單都不會動。`)) return { kind: "cancelled" };

  const { data, error } = await getSupabase().functions
    .invoke("line-note-worker", { body: { action: "update_post", post_id: post.id } });
  const res = (data ?? {}) as { ok?: boolean; error?: string };
  if (!error && res.ok) return { kind: "updated" };
  // supabase-js 把非 2xx 包成 FunctionsHttpError，訊息看不出原因，優先用函式自己回的
  return { kind: "failed", error: res.error ?? (error ? translateRpcError(error) : "未知錯誤") };
}

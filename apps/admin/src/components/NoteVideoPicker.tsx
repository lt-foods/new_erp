"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { invokeEdge } from "@/lib/edgeInvoke";
import SpinButton from "@/components/SpinButton";
import { lineNoteVideoUrl } from "@/lib/videoEmbed";

/**
 * 商品編輯頁：從 LINE 記事本挑一支影片當介紹影片（line_note_videos，20261122000010）。
 *
 * 清單是 line-note-worker 平常讀留言時順手記下來的「哪個社群的哪一篇貼文有影片」；
 * 剛貼的影片還沒被讀到時，按「去 LINE 再讀一次」叫 worker 把各社群的記事本列一遍。
 * 影片貼文常常沒有文字，所以沒辦法自動對商品，只能看畫面挑。
 *
 * 預覽直接播 LINE CDN 上的檔案（不用登入的 mp4）。只抓前面一小段拿第一格畫面（preload="metadata"），
 * 滑過去／點一下才真的播。
 *
 * 做成欄位下方展開的一塊，不另外開彈窗：商品編輯本身已經在彈窗裡，而且這一塊在 <form> 裡面，
 * 所有按鈕都要是 type="button"，不然會把整張商品表單送出去。
 */
type Row = {
  id: number;
  line_post_id: string;
  object_id: string;
  service_name: string;
  obs_namespace: string;
  width: number | null;
  height: number | null;
  author_name: string | null;
  text: string | null;
  posted_at: string | null;
  community: { home_name: string | null } | null;
};

function when(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleString("zh-TW", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
}

export function NoteVideoPicker({ current, onPick }: { current: string; onPick: (url: string) => void }) {
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [syncing, setSyncing] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    const { data, error: err } = await getSupabase()
      .from("line_note_videos")
      .select("id, line_post_id, object_id, service_name, obs_namespace, width, height, author_name, text, posted_at, community:line_note_communities(home_name)")
      .order("posted_at", { ascending: false, nullsFirst: false })
      .limit(24);
    if (err) { setError(`讀不到記事本影片清單：${err.message}`); setRows([]); return; }
    setRows((data ?? []) as unknown as Row[]);
  }, []);

  useEffect(() => {
    if (!open || rows !== null) return;
    void (async () => { await load(); })();
  }, [open, rows, load]);

  const sync = async () => {
    setSyncing(true); setNote(null); setError(null);
    const { data, error: err } = await invokeEdge<{ ok?: boolean; read?: number; communities?: number; videos?: number; errors?: string[]; error?: string }>(
      getSupabase(), "line-note-worker", { action: "sync_note_videos" }, "去 LINE 讀取失敗",
    );
    setSyncing(false);
    if (err || data?.error) { setError(err ?? data?.error ?? "去 LINE 讀取失敗"); return; }
    const failed = data?.errors?.length ?? 0;
    setNote(`讀了 ${data?.read ?? 0}／${data?.communities ?? 0} 個社群，最近 3 天有 ${data?.videos ?? 0} 支影片${failed ? `（${failed} 個社群沒讀到，稍後再試）` : ""}。`);
    await load();
  };

  return (
    <div className="mt-2">
      <SpinButton
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="rounded-md border border-zinc-300 px-2.5 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
      >
        {open ? "收起" : "從 LINE 記事本挑影片"}
      </SpinButton>

      {open && (
        <div className="mt-2 space-y-2 rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-xs text-zinc-500">各社群記事本最近貼的影片（新的在前）。挑一支，再按下方「儲存」才會生效。</span>
            <SpinButton
              type="button"
              onClick={sync}
              disabled={syncing}
              className="ml-auto rounded-md border border-zinc-300 px-2.5 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              {syncing ? "讀取中（約半分鐘）…" : "去 LINE 再讀一次"}
            </SpinButton>
          </div>
          {note && <p className="text-xs text-emerald-700 dark:text-emerald-400">{note}</p>}
          {error && <p className="text-xs text-red-600">{error}</p>}
          {rows === null && <div className="h-24 animate-pulse rounded-md bg-zinc-100 dark:bg-zinc-800" />}
          {rows !== null && rows.length === 0 && !error && (
            <p className="rounded-md border border-dashed border-zinc-300 px-3 py-5 text-center text-xs text-zinc-500 dark:border-zinc-700">
              還沒有記到影片。剛在記事本貼了影片的話，按右上角「去 LINE 再讀一次」。
            </p>
          )}
          {rows !== null && rows.length > 0 && (
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {rows.map((r) => {
                const url = lineNoteVideoUrl(r);
                if (!url) return null;
                const picked = current.trim() === url;
                return (
                  <div
                    key={r.id}
                    className={`overflow-hidden rounded-md border ${picked ? "border-emerald-500 ring-2 ring-emerald-300" : "border-zinc-200 dark:border-zinc-800"}`}
                  >
                    {/* #t=0.1：iOS 要指定時間點才會畫出第一格，不然是一片黑 */}
                    <video
                      src={`${url.replace(/#.*$/, "")}#t=0.1`}
                      muted
                      playsInline
                      controls
                      preload="metadata"
                      className="aspect-[9/16] w-full bg-black object-contain"
                    />
                    <div className="space-y-1 p-2">
                      <div className="truncate text-xs font-medium text-zinc-800 dark:text-zinc-200" title={r.community?.home_name ?? ""}>
                        {r.community?.home_name ?? "（社群）"}
                      </div>
                      <div className="truncate text-[11px] text-zinc-500">
                        {when(r.posted_at)}{r.author_name ? `・${r.author_name}` : ""}
                      </div>
                      {r.text && <div className="line-clamp-2 text-[11px] text-zinc-500">{r.text}</div>}
                      <SpinButton
                        type="button"
                        onClick={() => onPick(url)}
                        disabled={picked}
                        className={`w-full rounded px-2 py-1 text-xs font-medium ${picked
                          ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                          : "bg-zinc-900 text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900"}`}
                      >
                        {picked ? "✓ 已選這支" : "用這支影片"}
                      </SpinButton>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

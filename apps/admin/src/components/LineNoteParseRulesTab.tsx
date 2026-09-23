"use client";

// LINE 記事本 →「解析規則」分頁：留言怎樣算下單，總部自己調。
//
// 規則本體（解析器）只有一份，在 supabase/functions/_shared/lineNoteParse.ts；這頁不抄一份，
// 試算一律丟給 line-note-worker 的 parse_preview（跟真的在加單的是同一支）。
// 設定存在 line_note_parse_settings（20260923130000），worker 每篇讀留言時現查。

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";

export type ParseConfig = {
  units: string[];
  cancelWords: string[];
  plusWords: string[];
  allowNoCode: boolean;
  allowQtyFirst: boolean;
  allowTimes: boolean;
  fixTypos: boolean;
  rejectBareCode: boolean;
};

type Order = { code: string | null; qty: number; cancel: boolean; line: string };
type Result = { text: string; memberNo: string | null; orders: Order[] };

const SWITCHES: ReadonlyArray<{ key: keyof ParseConfig; label: string; on: string; off: string }> = [
  { key: "rejectBareCode", label: "有品項沒寫數量，整則不加", on: "A, B+1 → 整則不加、進待處理（不會只加 B）", off: "A, B+1 → 只加 B，A 跳過" },
  { key: "allowNoCode", label: "沒寫品項也收", on: "+1、加1、2份 → 加（只有一個品項的團）", off: "一定要寫品項代碼" },
  { key: "allowQtyFirst", label: "數量寫在前面", on: "+1 A、+2 B2 → 加", off: "只收 A+1 這種順序" },
  { key: "allowTimes", label: "乘號／單位", on: "A x2、A*2、A 2份 → 加", off: "只收 +數字" },
  { key: "fixTypos", label: "常見錯字", on: "A+I、A十1、A+1. → 當 A+1", off: "錯字就不收" },
];

const LISTS: ReadonlyArray<{ key: "units" | "cancelWords" | "plusWords"; label: string; hint: string }> = [
  { key: "plusWords", label: "當「+」用的字", hint: "後面緊接數字才算：「加1」「打1」「加一」。只收單一個中文字或符號。" },
  { key: "units", label: "數量單位", hint: "「A 2份」「2份」認得的單位。" },
  { key: "cancelWords", label: "取消用字", hint: "留言裡有這些字＝取消。" },
];

const DEFAULT_SAMPLES = "A+1\nA, B+1\nA+1, B+1\n+1\n加1\nA x2\nA 2份\n取消 A+1\nA+I\n請問還有嗎";

const btn = "rounded border border-zinc-300 px-2.5 py-1 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800";
const btnPrimary = "rounded bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900";
const input = "w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900";

async function preview(config: unknown, texts: string[]): Promise<{ config: ParseConfig; results: Result[] }> {
  const { data, error } = await getSupabase().functions.invoke("line-note-worker", {
    body: { action: "parse_preview", config, texts },
  });
  if (error) throw error;
  if (data?.error) throw new Error(data.error);
  return data;
}

// 存的設定 + 預設值，都經 worker 補齊成完整格式
async function fetchSettings(): Promise<[ParseConfig, ParseConfig, string | null]> {
  const { data, error } = await getSupabase().from("line_note_parse_settings").select("config,updated_at").maybeSingle();
  if (error) throw error;
  const [cur, def] = await Promise.all([preview(data?.config ?? null, []), preview(null, [])]);
  return [cur.config, def.config, data?.updated_at ?? null];
}

const fmtOrders = (os: Order[]) =>
  os.length === 0 ? "不加單" : os.map((o) => `${o.code ?? "（沒寫品項）"} ${o.cancel ? "取消 " : ""}×${o.qty}`).join("、");
const splitWords = (s: string) => s.split(/[\s,，、]+/).map((w) => w.trim()).filter(Boolean);

export function LineNoteParseRulesTab({ notify, fail }: { notify: (m: string) => void; fail: (e: unknown) => void }) {
  const [saved, setSaved] = useState<ParseConfig | null>(null);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  const [defaults, setDefaults] = useState<ParseConfig | null>(null);
  const [draft, setDraft] = useState<ParseConfig | null>(null);
  const [listText, setListText] = useState<Record<string, string>>({});
  const [samples, setSamples] = useState(DEFAULT_SAMPLES);
  const [results, setResults] = useState<Result[] | null>(null);
  const [diff, setDiff] = useState<{ text: string; before: Order[]; after: Order[] }[] | null>(null);
  const [busy, setBusy] = useState<"" | "save" | "try" | "diff">("");

  const apply = useCallback((cur: ParseConfig, def: ParseConfig, at: string | null) => {
    setSaved(cur); setDefaults(def); setSavedAt(at);
    setDraft(cur);
    setListText(Object.fromEntries(LISTS.map((l) => [l.key, cur[l.key].join(" ")])));
  }, []);
  const reload = useCallback(async () => {
    try { apply(...(await fetchSettings())); } catch (e) { fail(e); }
  }, [apply, fail]);
  useEffect(() => {
    let dead = false;
    fetchSettings().then((r) => { if (!dead) apply(...r); }, (e) => { if (!dead) fail(e); });
    return () => { dead = true; };
  }, [apply, fail]);

  // 清單欄位邊打邊寫回草稿（存檔前 worker 會再濾一次壞值）
  const draftFull = useMemo(() => draft && ({
    ...draft, ...Object.fromEntries(LISTS.map((l) => [l.key, splitWords(listText[l.key] ?? "")])),
  }) as ParseConfig, [draft, listText]);
  const dirty = !!draftFull && !!saved && JSON.stringify(draftFull) !== JSON.stringify(saved);

  const tryIt = async () => {
    if (!draftFull) return;
    setBusy("try");
    try { setResults((await preview(draftFull, samples.split(/\n/).filter((l) => l.trim()))).results); }
    catch (e) { fail(e); } finally { setBusy(""); }
  };

  // 拿最近的真實留言，比「現在的規則」跟「草稿」會有哪些不一樣
  const compare = async () => {
    if (!draftFull || !saved) return;
    setBusy("diff");
    try {
      const { data, error } = await getSupabase().from("line_note_comments")
        .select("text").order("commented_at", { ascending: false }).limit(200);
      if (error) throw error;
      const texts = [...new Set((data ?? []).map((r: { text: string | null }) => r.text ?? "").filter(Boolean))];
      const [a, b] = await Promise.all([preview(saved, texts), preview(draftFull, texts)]);
      const out: { text: string; before: Order[]; after: Order[] }[] = [];
      a.results.forEach((r, i) => {
        const after = b.results[i].orders;
        if (fmtOrders(r.orders) !== fmtOrders(after)) out.push({ text: r.text, before: r.orders, after });
      });
      setDiff(out);
    } catch (e) { fail(e); } finally { setBusy(""); }
  };

  const save = async () => {
    if (!draftFull) return;
    if (!confirm("存檔後，之後讀到的留言都用新規則自動加單（已經加過的單不會動）。確定？")) return;
    setBusy("save");
    try {
      const norm = (await preview(draftFull, [])).config;
      const { error } = await getSupabase().rpc("rpc_line_note_parse_settings_save", { p_config: norm });
      if (error) throw new Error(translateRpcError(error));
      notify("解析規則已存檔");
      setDiff(null);
      await reload();
    } catch (e) { fail(e); } finally { setBusy(""); }
  };

  const resetDefaults = () => {
    if (!defaults) return;
    setDraft(defaults);
    setListText(Object.fromEntries(LISTS.map((l) => [l.key, defaults[l.key].join(" ")])));
  };

  if (!draft || !draftFull) return <div className="py-8 text-center text-sm text-zinc-400">讀取中…</div>;

  return (
    <div className="space-y-4">
      <p className="text-sm text-zinc-500">
        留言要寫成什麼樣子，機器人才會自動加單。改完先在下面「試算」看結果，再按存檔；
        存檔後<b>之後讀到的留言</b>才會用新規則（已經加過的單不會動，之前被判「非下單」的留言下次讀取時會用新規則重判一次）。
        {savedAt && <> 上次存檔：{new Date(savedAt).toLocaleString("zh-TW", { hour12: false })}</>}
      </p>

      <section className="rounded border border-zinc-200 p-3 dark:border-zinc-800">
        <h2 className="mb-2 font-medium">規則開關</h2>
        <ul className="space-y-2">
          {SWITCHES.map((s) => {
            const on = draft[s.key] as boolean;
            return (
              <li key={s.key}>
                <label className="flex cursor-pointer items-start gap-2 text-sm">
                  <input type="checkbox" className="mt-1" checked={on}
                    onChange={(e) => setDraft({ ...draft, [s.key]: e.target.checked })} />
                  <span>
                    <span className="font-medium">{s.label}</span>
                    <span className="ml-2 text-zinc-500">{on ? s.on : s.off}</span>
                  </span>
                </label>
              </li>
            );
          })}
        </ul>
        <p className="mt-2 text-xs text-zinc-500">永遠不收：只寫數字（2）、分不清品號還是數量（A2）、聊天內容。</p>
      </section>

      <section className="grid gap-3 md:grid-cols-3">
        {LISTS.map((l) => (
          <div key={l.key} className="rounded border border-zinc-200 p-3 dark:border-zinc-800">
            <h2 className="font-medium">{l.label}</h2>
            <p className="mb-1.5 text-xs text-zinc-500">{l.hint} 用空白分開。</p>
            <textarea className={`${input} font-mono`} rows={3} value={listText[l.key] ?? ""}
              onChange={(e) => setListText({ ...listText, [l.key]: e.target.value })} />
          </div>
        ))}
      </section>

      <section className="rounded border border-zinc-200 p-3 dark:border-zinc-800">
        <h2 className="mb-1 font-medium">試算</h2>
        <p className="mb-1.5 text-xs text-zinc-500">一行一則留言，用上面（還沒存檔的）規則解析。</p>
        <div className="grid gap-3 md:grid-cols-2">
          <textarea className={`${input} font-mono`} rows={10} value={samples} onChange={(e) => setSamples(e.target.value)} />
          <div className="text-sm">
            {results === null ? <span className="text-zinc-400">按「試算」看結果</span> : (
              <table className="w-full">
                <tbody>
                  {results.map((r, i) => (
                    <tr key={i} className="border-t border-zinc-200 dark:border-zinc-800">
                      <td className="py-1 pr-3 font-mono">{r.text}</td>
                      <td className={`py-1 ${r.orders.length ? "text-emerald-700 dark:text-emerald-400" : "text-zinc-400"}`}>{fmtOrders(r.orders)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </div>
        <div className="mt-2 flex flex-wrap gap-2">
          <SpinButton type="button" className={btn} loading={busy === "try"} onClick={() => void tryIt()}>試算</SpinButton>
          <SpinButton type="button" className={btn} loading={busy === "diff"} disabled={!dirty} onClick={() => void compare()}>
            拿最近 200 則留言比對新舊規則
          </SpinButton>
        </div>
        {diff && (
          <div className="mt-3 text-sm">
            {diff.length === 0 ? <span className="text-zinc-500">最近的留言用新規則解析，結果都一樣。</span> : (
              <>
                <div className="mb-1 text-zinc-600 dark:text-zinc-300">有 {diff.length} 則結果會不一樣：</div>
                <table className="w-full">
                  <thead><tr className="text-left text-xs text-zinc-500"><th className="py-1 pr-3">留言</th><th className="pr-3">現在</th><th>改完</th></tr></thead>
                  <tbody>
                    {diff.map((d, i) => (
                      <tr key={i} className="border-t border-zinc-200 dark:border-zinc-800">
                        <td className="py-1 pr-3 font-mono whitespace-pre-wrap">{d.text}</td>
                        <td className="py-1 pr-3 text-zinc-500">{fmtOrders(d.before)}</td>
                        <td className="py-1 font-medium">{fmtOrders(d.after)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </>
            )}
          </div>
        )}
      </section>

      <div className="flex flex-wrap items-center gap-2">
        <SpinButton type="button" className={btnPrimary} loading={busy === "save"} disabled={!dirty} onClick={() => void save()}>存檔</SpinButton>
        <button type="button" className={btn} disabled={!dirty} onClick={() => { if (saved) { setDraft(saved); setListText(Object.fromEntries(LISTS.map((l) => [l.key, saved[l.key].join(" ")]))); } }}>放棄修改</button>
        <button type="button" className={btn} onClick={resetDefaults}>還原成預設規則</button>
        {dirty && <span className="text-sm text-amber-700 dark:text-amber-400">有還沒存檔的修改</span>}
      </div>
    </div>
  );
}

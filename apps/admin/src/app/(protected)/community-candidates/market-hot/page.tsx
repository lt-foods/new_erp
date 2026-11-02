"use client";

// 市場熱門 —— 匯入蝦皮助手（或 1688 等）匯出的熱銷榜，看「外面正在熱賣的」→「廠商有沒有在賣」→「我們賣過沒有」。
// 對上廠商品項的候選，週曆系統預選會排前面一點（×1.2）。定義見 migration 20261102000010。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import ConfidenceChevrons, { confidenceTextColor } from "@/components/ConfidenceChevrons";

type Level = "high" | "mid" | "low";
type SupplierMatch = {
  candidate_id: number; name: string; price: number | null; owner_action: string; cos: number | null;
  predicted: number | null; confidence: Level | null; low: number | null; high: number | null; supplier: string | null;
};
type HotRow = {
  id: number; source: string; captured_at: string; name: string; price: number | null; sales_30d: number | null;
  revenue: number | null; growth: number | null; category: string | null; shop: string | null; url: string | null;
  kind: string | null; ready: boolean; supplier_matches: SupplierMatch[]; sold: { name: string; cos: number; buyers: number | null; campaigns: number } | null;
};
type Batch = { id: number; source: string; file_name: string | null; captured_at: string; rows: number; created_at: string };

// 匯入時要對的欄位；pattern 用來自動猜欄位（蝦皮助手、1688、店雷達的匯出檔表頭）
const FIELDS: { key: string; label: string; required?: boolean; pattern: RegExp }[] = [
  { key: "name", label: "品名", required: true, pattern: /商品名稱|品名|商品標題|標題|商品$|product|title|name/i },
  { key: "price", label: "價格", pattern: /價格|售價|單價|price/i },
  { key: "sales_30d", label: "月銷量", pattern: /月銷|30\s*天.*銷量|近30|銷量|sold|sales/i },
  { key: "revenue", label: "銷售額", pattern: /銷售額|營業額|營收|GMV|revenue/i },
  { key: "growth", label: "成長率", pattern: /成長|增長|growth/i },
  { key: "category", label: "類目", pattern: /類目|分類|category/i },
  { key: "shop", label: "店鋪", pattern: /店鋪|店家|賣家|店名|shop|seller/i },
  { key: "url", label: "連結", pattern: /連結|網址|鏈接|link|url/i },
  { key: "rank", label: "排名", pattern: /排名|名次|rank/i },
];
const SOURCE_LABEL: Record<string, string> = { shopee: "蝦皮", "1688": "1688", other: "其他" };

const todayStr = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};
const md = (s: string) => `${Number(s.slice(5, 7))}/${Number(s.slice(8, 10))}`;
const n0 = (v: number | null | undefined) => (v == null ? "—" : Number(v).toLocaleString("zh-TW"));

/** 第一列有 2 格以上對得上欄位關鍵字的，當表頭；都沒有就用第一列 */
function findHeaderRow(rows: unknown[][]): number {
  for (let i = 0; i < Math.min(rows.length, 15); i++) {
    const hits = (rows[i] ?? []).filter((c) => FIELDS.some((f) => f.pattern.test(String(c ?? "")))).length;
    if (hits >= 2) return i;
  }
  return 0;
}

export default function MarketHotPage() {
  const [rows, setRows] = useState<HotRow[] | null>(null);
  const [batches, setBatches] = useState<Batch[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [onlySupplier, setOnlySupplier] = useState(false);

  // 匯入
  const [source, setSource] = useState("shopee");
  const [captured, setCaptured] = useState(todayStr());
  const [fileName, setFileName] = useState<string | null>(null);
  const [table, setTable] = useState<unknown[][] | null>(null);
  const [header, setHeader] = useState<string[]>([]);
  const [mapping, setMapping] = useState<Record<string, number>>({});
  const [msg, setMsg] = useState<string | null>(null);

  const reload = async () => {
    const sb = getSupabase();
    const [l, b] = await Promise.all([
      sb.rpc("rpc_market_hot_list", { p_days: 45 }),
      sb.from("market_hot_batches").select("id, source, file_name, captured_at, rows, created_at").order("created_at", { ascending: false }).limit(10),
    ]);
    if (l.error) setError(l.error.message);
    else setError(null);
    setRows((l.data as HotRow[]) ?? []);
    setBatches((b.data as Batch[]) ?? []);
  };

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    reload();
  }, []);

  const onFile = async (file: File) => {
    setMsg(null);
    setFileName(file.name);
    try {
      const XLSX = await import("xlsx");
      const wb = XLSX.read(await file.arrayBuffer(), { type: "array" });
      const ws = wb.Sheets[wb.SheetNames[0]];
      const all = XLSX.utils.sheet_to_json<unknown[]>(ws, { header: 1, blankrows: false, defval: "" });
      const h = findHeaderRow(all);
      const head = (all[h] ?? []).map((c) => String(c ?? "").trim());
      const m: Record<string, number> = {};
      for (const f of FIELDS) {
        const idx = head.findIndex((c, i) => f.pattern.test(c) && !Object.values(m).includes(i));
        if (idx >= 0) m[f.key] = idx;
      }
      setHeader(head);
      setMapping(m);
      setTable(all.slice(h + 1).filter((r) => r.some((c) => String(c ?? "").trim() !== "")));
    } catch (e) {
      setError(`讀不了這個檔案：${e instanceof Error ? e.message : String(e)}`);
      setTable(null);
    }
  };

  const mapped = useMemo(() => {
    if (!table) return [];
    return table.map((r, i) => {
      const o: Record<string, unknown> = {};
      for (const f of FIELDS) if (mapping[f.key] != null) o[f.key] = String(r[mapping[f.key]] ?? "").trim();
      if (mapping.rank == null) o.rank = String(i + 1);
      o.raw = Object.fromEntries(header.map((h, j) => [h || `欄${j + 1}`, r[j] ?? ""]));
      return o;
    }).filter((o) => String(o.name ?? "") !== "");
  }, [table, mapping, header]);

  const doImport = async () => {
    if (!mapped.length) return;
    const { data, error: err } = await getSupabase().rpc("rpc_market_hot_import", {
      p_source: source, p_captured_at: captured, p_file_name: fileName, p_rows: mapped,
    });
    if (err) { setError(err.message); return; }
    setMsg(`已匯入 ${(data as { rows: number })?.rows ?? mapped.length} 筆，幾分鐘內 AI 會算好向量和品類，對上廠商品項`);
    setTable(null); setFileName(null);
    await reload();
  };

  const delBatch = async (b: Batch) => {
    if (!window.confirm(`刪除 ${md(b.captured_at)} 匯入的 ${b.rows} 筆？`)) return;
    const { error: err } = await getSupabase().rpc("rpc_market_hot_delete_batch", { p_batch_id: b.id });
    if (err) setError(err.message);
    await reload();
  };

  const shown = (rows ?? []).filter((r) => !onlySupplier || r.supplier_matches.length > 0);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h1 className="text-xl font-semibold">市場熱門</h1>
          <p className="mt-0.5 text-sm text-zinc-500">
            匯入蝦皮助手的熱銷榜 → 看廠商有沒有在賣、我們賣過沒有。對上廠商品項的，週曆系統預選會排前面
          </p>
        </div>
        <Link href="/community-candidates/calendar"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900">
          週曆
        </Link>
      </header>

      {error && <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</div>}
      {msg && <div className="rounded-md bg-emerald-50 p-3 text-sm text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300">{msg}</div>}

      {/* 匯入 */}
      <section className="rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mb-3 text-sm font-medium">匯入熱銷榜</div>
        <div className="flex flex-wrap items-center gap-2 text-sm">
          <select value={source} onChange={(e) => setSource(e.target.value)}
            className="rounded-md border border-zinc-300 px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-900">
            <option value="shopee">蝦皮</option>
            <option value="1688">1688</option>
            <option value="other">其他</option>
          </select>
          <label className="flex items-center gap-1 text-zinc-500">
            資料日期
            <input type="date" value={captured} onChange={(e) => setCaptured(e.target.value)}
              className="rounded-md border border-zinc-300 px-2 py-1 dark:border-zinc-700 dark:bg-zinc-900" />
          </label>
          <input type="file" accept=".xlsx,.xls,.csv"
            onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ""; }}
            className="text-sm file:mr-2 file:rounded-md file:border file:border-zinc-300 file:bg-white file:px-3 file:py-1.5 dark:file:border-zinc-700 dark:file:bg-zinc-900" />
        </div>

        {table && (
          <div className="mt-3 space-y-3">
            <div className="text-xs text-zinc-500">{fileName}：{table.length} 列。確認每個欄位對到哪一欄（自動猜的，可以改）</div>
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-5">
              {FIELDS.map((f) => (
                <label key={f.key} className="flex flex-col gap-0.5 text-xs text-zinc-500">
                  {f.label}{f.required ? "（必填）" : ""}
                  <select
                    value={mapping[f.key] ?? ""}
                    onChange={(e) => setMapping((m) => {
                      const next = { ...m };
                      if (e.target.value === "") delete next[f.key]; else next[f.key] = Number(e.target.value);
                      return next;
                    })}
                    className="rounded-md border border-zinc-300 px-2 py-1 text-sm text-zinc-800 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
                  >
                    <option value="">（沒有）</option>
                    {header.map((h, i) => <option key={i} value={i}>{h || `第 ${i + 1} 欄`}</option>)}
                  </select>
                </label>
              ))}
            </div>
            <div className="overflow-x-auto rounded border border-zinc-100 dark:border-zinc-800">
              <table className="w-full whitespace-nowrap text-xs">
                <thead className="bg-zinc-50 text-zinc-500 dark:bg-zinc-900">
                  <tr>{FIELDS.filter((f) => mapping[f.key] != null).map((f) => <th key={f.key} className="px-2 py-1 text-left font-medium">{f.label}</th>)}</tr>
                </thead>
                <tbody>
                  {mapped.slice(0, 5).map((o, i) => (
                    <tr key={i} className="border-t border-zinc-100 dark:border-zinc-800">
                      {FIELDS.filter((f) => mapping[f.key] != null).map((f) => (
                        <td key={f.key} className="max-w-[16rem] truncate px-2 py-1">{String(o[f.key] ?? "")}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="flex items-center gap-2">
              <SpinButton onClick={doImport} disabled={mapping.name == null || mapped.length === 0}
                className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm text-white disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900">
                匯入 {mapped.length} 筆
              </SpinButton>
              <button onClick={() => { setTable(null); setFileName(null); }} className="text-sm text-zinc-500 hover:underline">取消</button>
            </div>
          </div>
        )}

        {batches.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-2 text-xs text-zinc-500">
            {batches.map((b) => (
              <span key={b.id} className="inline-flex items-center gap-1 rounded border border-zinc-200 px-2 py-0.5 dark:border-zinc-700">
                {SOURCE_LABEL[b.source] ?? b.source} {md(b.captured_at)}・{b.rows} 筆{b.file_name ? `・${b.file_name}` : ""}
                <button onClick={() => delBatch(b)} className="text-red-500 hover:underline" title="刪除這一批">×</button>
              </span>
            ))}
          </div>
        )}
      </section>

      {/* 熱銷品 → 廠商 → 我們 */}
      <section className="rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 px-4 py-2.5 text-sm dark:border-zinc-800">
          <span className="font-medium">近 45 天的熱銷品</span>
          <label className="flex items-center gap-1 text-xs text-zinc-500">
            <input type="checkbox" checked={onlySupplier} onChange={(e) => setOnlySupplier(e.target.checked)} />
            只看廠商有在賣的
          </label>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-zinc-50 text-xs text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
              <tr>
                <th className="px-3 py-2 text-left font-medium">熱銷品</th>
                <th className="whitespace-nowrap px-3 py-2 text-right font-medium">月銷</th>
                <th className="whitespace-nowrap px-3 py-2 text-right font-medium">價格</th>
                <th className="px-3 py-2 text-left font-medium">廠商有在賣</th>
                <th className="px-3 py-2 text-left font-medium">我們賣過</th>
              </tr>
            </thead>
            <tbody>
              {rows === null ? (
                <tr><td colSpan={5} className="px-3 py-6 text-center text-zinc-400">載入中…</td></tr>
              ) : shown.length === 0 ? (
                <tr><td colSpan={5} className="px-3 py-6 text-center text-zinc-400">
                  {rows.length === 0 ? "還沒有匯入熱銷榜，從上面上傳蝦皮助手匯出的檔案" : "沒有廠商在賣的熱銷品"}
                </td></tr>
              ) : shown.map((r) => (
                <tr key={r.id} className="border-t border-zinc-100 align-top dark:border-zinc-800">
                  <td className="min-w-[14rem] px-3 py-2">
                    {r.url ? (
                      <a href={r.url} target="_blank" rel="noreferrer" className="hover:underline">{r.name}</a>
                    ) : r.name}
                    <div className="mt-0.5 flex flex-wrap gap-1.5 text-[11px] text-zinc-400">
                      <span>{SOURCE_LABEL[r.source] ?? r.source} {md(r.captured_at)}</span>
                      {r.kind && <span className="rounded bg-zinc-100 px-1 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">{r.kind}</span>}
                      {r.shop && <span>{r.shop}</span>}
                      {!r.ready && <span className="text-sky-600">AI 比對中</span>}
                    </div>
                  </td>
                  <td className="whitespace-nowrap px-3 py-2 text-right font-semibold">{n0(r.sales_30d)}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-right">{r.price != null ? `$${n0(r.price)}` : "—"}</td>
                  <td className="min-w-[16rem] px-3 py-2">
                    {r.supplier_matches.length === 0 ? (
                      <span className="text-xs text-zinc-400">{r.ready ? "沒有廠商在賣" : "—"}</span>
                    ) : (
                      <ul className="space-y-1">
                        {r.supplier_matches.map((m) => (
                          <li key={m.candidate_id} className="flex flex-wrap items-center gap-1.5 text-xs">
                            <Link href={`/community-candidates?highlight=${m.candidate_id}`} className="text-zinc-800 hover:underline dark:text-zinc-100">
                              {m.name}
                            </Link>
                            <span className="text-zinc-400">{m.supplier ?? ""}{m.price != null ? ` $${n0(m.price)}` : ""}</span>
                            {m.predicted != null && (
                              <span className="inline-flex items-center gap-0.5" title={`預估約 ${m.predicted} 位買家`}>
                                <ConfidenceChevrons level={m.confidence} />
                                <span className={`font-bold ${confidenceTextColor(m.confidence)}`}>{m.predicted}</span>
                              </span>
                            )}
                            {m.owner_action === "scheduled" && (
                              <span className="rounded bg-amber-50 px-1 text-[10px] text-amber-700 dark:bg-amber-950/40 dark:text-amber-300">已排程</span>
                            )}
                          </li>
                        ))}
                      </ul>
                    )}
                  </td>
                  <td className="min-w-[10rem] px-3 py-2 text-xs">
                    {r.sold ? (
                      <>
                        <div className="text-zinc-700 dark:text-zinc-300">{r.sold.name}</div>
                        <div className="text-zinc-400">{r.sold.campaigns} 團{r.sold.buyers != null ? `・每團 ${r.sold.buyers} 人` : ""}</div>
                      </>
                    ) : (
                      <span className="text-zinc-400">{r.ready ? "沒賣過" : "—"}</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

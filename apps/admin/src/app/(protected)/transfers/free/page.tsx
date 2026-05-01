"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

type Location = { id: number; code: string; name: string; type: string };

type Line = {
  description: string;
  qty: string;
  estimated_amount: string;
  notes: string;
};

const emptyLine = (): Line => ({ description: "", qty: "1", estimated_amount: "0", notes: "" });

export default function FreeTransferPage() {
  const router = useRouter();
  const [locations, setLocations] = useState<Location[] | null>(null);
  const [sourceId, setSourceId] = useState<number | null>(null);
  const [destId, setDestId] = useState<number | null>(null);
  const [lines, setLines] = useState<Line[]>([emptyLine()]);
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data } = await getSupabase()
        .from("locations")
        .select("id, code, name, type")
        .eq("is_active", true)
        .order("type")
        .order("code");
      setLocations((data ?? []) as Location[]);
    })();
  }, []);

  const setLine = <K extends keyof Line>(idx: number, key: K, value: Line[K]) => {
    setLines((arr) => arr.map((l, i) => (i === idx ? { ...l, [key]: value } : l)));
  };

  const addLine = () => setLines((arr) => [...arr, emptyLine()]);
  const removeLine = (idx: number) => setLines((arr) => arr.filter((_, i) => i !== idx));

  const valid =
    sourceId !== null &&
    destId !== null &&
    sourceId !== destId &&
    lines.length > 0 &&
    lines.every((l) => l.description.trim() && Number(l.qty) > 0 && Number(l.estimated_amount) >= 0);

  async function handleSubmit() {
    setError(null);
    if (!valid || sourceId === null || destId === null) {
      setError("請填妥來源 / 目的店、每行需有描述 / 數量 / 估價");
      return;
    }
    setBusy(true);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_create_free_transfer", {
        p_source_location: sourceId,
        p_dest_location: destId,
        p_lines: lines.map((l) => ({
          description: l.description.trim(),
          qty: Number(l.qty),
          estimated_amount: Number(l.estimated_amount),
          notes: l.notes.trim() || null,
        })),
        p_notes: notes.trim() || null,
      });
      if (err) throw err;
      router.push(`/transfers?id=${Number(data)}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  if (locations === null) {
    return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  }

  const inputCls =
    "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">自由轉貨</h1>
        <p className="text-sm text-zinc-500">沒 catalog 的東西跨店搬貨；用備註描述實際品名 / 規格</p>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* 來源 / 目的 */}
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">來源 *</span>
          <select value={sourceId ?? ""} onChange={(e) => setSourceId(Number(e.target.value) || null)} className={inputCls}>
            <option value="">— 請選 —</option>
            {locations.map((l) => (
              <option key={l.id} value={l.id}>{l.code} {l.name}（{l.type === "central_warehouse" ? "總倉" : "分店"}）</option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">目的 *</span>
          <select value={destId ?? ""} onChange={(e) => setDestId(Number(e.target.value) || null)} className={inputCls}>
            <option value="">— 請選 —</option>
            {locations.filter((l) => l.id !== sourceId).map((l) => (
              <option key={l.id} value={l.id}>{l.code} {l.name}（{l.type === "central_warehouse" ? "總倉" : "分店"}）</option>
            ))}
          </select>
        </label>
      </div>

      {/* lines */}
      <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="w-full text-sm">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">描述 *</th>
              <th className="px-3 py-2 text-right">數量 *</th>
              <th className="px-3 py-2 text-right">估價（總額）*</th>
              <th className="px-3 py-2">備註</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
            {lines.map((l, i) => (
              <tr key={i}>
                <td className="px-3 py-2">
                  <input
                    placeholder="例：醬油 10 瓶 ½ 箱"
                    value={l.description}
                    onChange={(e) => setLine(i, "description", e.target.value)}
                    className={`w-full ${inputCls}`}
                  />
                </td>
                <td className="px-3 py-2">
                  <input
                    type="number"
                    min="0"
                    step="0.001"
                    value={l.qty}
                    onChange={(e) => setLine(i, "qty", e.target.value)}
                    className={`w-24 text-right ${inputCls}`}
                  />
                </td>
                <td className="px-3 py-2">
                  <input
                    type="number"
                    min="0"
                    step="0.01"
                    value={l.estimated_amount}
                    onChange={(e) => setLine(i, "estimated_amount", e.target.value)}
                    className={`w-28 text-right ${inputCls}`}
                  />
                </td>
                <td className="px-3 py-2">
                  <input
                    placeholder="（選填）"
                    value={l.notes}
                    onChange={(e) => setLine(i, "notes", e.target.value)}
                    className={`w-full ${inputCls}`}
                  />
                </td>
                <td className="px-3 py-2">
                  {lines.length > 1 && (
                    <button
                      onClick={() => removeLine(i)}
                      className="rounded border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-400"
                    >
                      移除
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="border-t border-zinc-200 p-2 dark:border-zinc-800">
          <button
            onClick={addLine}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            + 新增一行
          </button>
        </div>
      </div>

      {/* notes */}
      <label className="flex flex-col gap-1 text-sm">
        <span className="text-zinc-600 dark:text-zinc-400">整單備註</span>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          className={`${inputCls} min-h-16`}
          placeholder="（選填）"
        />
      </label>

      <div className="flex gap-2">
        <button
          onClick={handleSubmit}
          disabled={busy || !valid}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
        >
          {busy ? "建立中…" : "建立轉貨單"}
        </button>
        <button
          onClick={() => router.back()}
          disabled={busy}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700"
        >
          取消
        </button>
      </div>
    </div>
  );
}

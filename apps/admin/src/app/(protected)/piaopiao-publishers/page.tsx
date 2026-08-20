"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type Request = { id: number; display_name: string | null; line_user_id: string; requested_at: string };
type Publisher = { id: number; display_name: string; lane: "tong" | "chao"; is_active: boolean };

export default function PiaopiaoPublishersPage() {
  const [requests, setRequests] = useState<Request[]>([]);
  const [publishers, setPublishers] = useState<Publisher[]>([]);
  const [chaoReady, setChaoReady] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState<number | null>(null);
  const load = async () => {
    const { data, error: e } = await getSupabase().rpc("rpc_piaopiao_publisher_overview");
    if (e) { setError(e.message); return; }
    setRequests(data?.requests ?? []); setPublishers(data?.publishers ?? []); setChaoReady(Boolean(data?.chao_supplier_ready));
  };
  useEffect(() => { void load(); }, []);
  const approve = async (request: Request, lane: "tong" | "chao") => {
    setBusy(request.id); setError("");
    const { error: e } = await getSupabase().rpc("rpc_approve_piaopiao_publisher", { p_request_id: request.id, p_display_name: request.display_name || (lane === "tong" ? "漂漂彤" : "漂漂潮"), p_lane: lane });
    setBusy(null); if (e) setError(e.message); else void load();
  };
  const toggle = async (publisher: Publisher) => {
    setBusy(publisher.id); setError("");
    const { error: e } = await getSupabase().rpc("rpc_set_piaopiao_publisher_active", { p_publisher_id: publisher.id, p_is_active: !publisher.is_active });
    setBusy(null); if (e) setError(e.message); else void load();
  };
  return <div className="p-5 md:p-8"><h1 className="text-2xl font-bold">漂漂館上架員</h1><p className="mt-2 text-sm text-zinc-600">外部人員只用 LINE 登入漂漂館後台，不會取得 ERP 帳號或其他後台權限。</p>{error && <p className="mt-4 rounded-lg bg-red-50 p-3 text-red-700">{error}</p>}<div className={`mt-5 rounded-xl p-4 ${chaoReady ? "bg-emerald-50 text-emerald-800" : "bg-amber-50 text-amber-900"}`}>{chaoReady ? "✓ 漂漂潮固定供應商「潮包子」已可用。" : "⚠ 漂漂潮尚不能發佈：請先到既有供應商頁建立／啟用「潮包子」。"}</div><section className="mt-6 rounded-2xl border bg-white p-5"><h2 className="font-bold">等待開通</h2>{requests.length === 0 ? <p className="mt-3 text-sm text-zinc-500">目前沒有新的 LINE 登入申請。</p> : <div className="mt-3 space-y-3">{requests.map((r) => <div key={r.id} className="rounded-xl bg-zinc-50 p-4"><p className="font-semibold">{r.display_name || "未提供名稱"}</p><p className="mt-1 break-all text-xs text-zinc-500">LINE：{r.line_user_id}</p><div className="mt-3 flex gap-2"><button disabled={busy === r.id} onClick={() => void approve(r, "tong")} className="min-h-11 rounded-lg bg-rose-600 px-3 text-sm font-semibold text-white">開通為漂漂彤</button><button disabled={busy === r.id || !chaoReady} onClick={() => void approve(r, "chao")} className="min-h-11 rounded-lg bg-sky-600 px-3 text-sm font-semibold text-white">開通為漂漂潮</button></div></div>)}</div>}</section><section className="mt-6 rounded-2xl border bg-white p-5"><h2 className="font-bold">已開通</h2><div className="mt-3 space-y-2">{publishers.map((p) => <div key={p.id} className="flex items-center justify-between rounded-xl bg-zinc-50 p-3"><div><p className="font-semibold">{p.display_name}</p><p className="text-sm text-zinc-500">{p.lane === "tong" ? "漂漂彤" : "漂漂潮"}・{p.is_active ? "可上架" : "已停用"}</p></div><button disabled={busy === p.id} onClick={() => void toggle(p)} className="min-h-11 rounded-lg border px-3 text-sm font-semibold">{p.is_active ? "停用" : "重新開通"}</button></div>)}</div></section></div>;
}

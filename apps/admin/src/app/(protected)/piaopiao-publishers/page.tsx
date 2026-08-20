"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type Publisher = { id: number; login_id: string; display_name: string; lane: "tong" | "chao"; is_active: boolean };

export default function PiaopiaoPublishersPage() {
  const [publishers, setPublishers] = useState<Publisher[]>([]);
  const [chaoReady, setChaoReady] = useState(false);
  const [loginId, setLoginId] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [lane, setLane] = useState<"tong" | "chao">("tong");
  const [password, setPassword] = useState("");
  const [resetFor, setResetFor] = useState<number | null>(null);
  const [newPassword, setNewPassword] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);

  const load = async () => {
    const { data, error: loadError } = await getSupabase().rpc("rpc_piaopiao_publisher_overview");
    if (loadError) return setError(loadError.message);
    setPublishers(data?.publishers ?? []);
    setChaoReady(Boolean(data?.chao_supplier_ready));
  };
  useEffect(() => { void load(); }, []);

  async function callAdmin(body: Record<string, unknown>) {
    const { data: { session } } = await getSupabase().auth.getSession();
    const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
    if (!base || !session?.access_token) throw new Error("總部登入已失效，請重新登入");
    const response = await fetch(`${base}/functions/v1/piaopiao-publisher-admin`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.access_token}` }, body: JSON.stringify(body),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || "操作失敗");
    return data;
  }

  async function create() {
    setError(""); setNotice(""); setBusy(true);
    try {
      await callAdmin({ action: "create", login_id: loginId, display_name: displayName, lane, password });
      setLoginId(""); setDisplayName(""); setPassword(""); setNotice("上架帳號已建立；請用安全方式把帳號與密碼交給該員工。");
      await load();
    } catch (e) { setError(e instanceof Error ? e.message : "建立失敗"); } finally { setBusy(false); }
  }

  async function resetPassword() {
    if (!resetFor) return;
    setError(""); setNotice(""); setBusy(true);
    try {
      await callAdmin({ action: "reset_password", publisher_id: resetFor, password: newPassword });
      setNewPassword(""); setResetFor(null); setNotice("密碼已重設；舊密碼立即不能再用。");
    } catch (e) { setError(e instanceof Error ? e.message : "重設失敗"); } finally { setBusy(false); }
  }

  async function toggle(publisher: Publisher) {
    setError(""); setNotice(""); setBusy(true);
    try {
      await callAdmin({ action: "set_active", publisher_id: publisher.id, is_active: !publisher.is_active });
      setNotice(publisher.is_active ? "已停用：此人立刻不能登入或上架。" : "已重新開通上架資格。");
      await load();
    } catch (e) { setError(e instanceof Error ? e.message : "更新失敗"); } finally { setBusy(false); }
  }

  return <div className="max-w-3xl space-y-6 p-5 md:p-8"><header><h1 className="text-2xl font-bold">漂漂館上架員</h1><p className="mt-2 text-sm text-zinc-600">每人一組漂漂館專用帳號，只能進上架後台；不是 ERP 帳號，也不綁私人 LINE。</p></header>
    {error && <p className="rounded-lg bg-red-50 p-3 text-red-700">{error}</p>}{notice && <p className="rounded-lg bg-emerald-50 p-3 text-emerald-800">{notice}</p>}
    <div className={`rounded-xl p-4 ${chaoReady ? "bg-emerald-50 text-emerald-800" : "bg-amber-50 text-amber-900"}`}>{chaoReady ? "✓ 漂漂潮固定供應商「潮包子」已可用。" : "⚠ 漂漂潮尚不能發佈：請先到既有供應商頁建立／啟用「潮包子」。"}</div>
    <section className="rounded-2xl border bg-white p-5"><h2 className="font-bold">新增上架帳號</h2><p className="mt-1 text-sm text-zinc-500">帳號限英文小寫、數字、點、底線或減號；密碼至少 6 碼。</p><div className="mt-4 grid gap-3 sm:grid-cols-2"><Field label="上架帳號"><input value={loginId} onChange={(e) => setLoginId(e.target.value)} placeholder="piao.tong" /></Field><Field label="顯示名稱"><input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="漂漂彤" /></Field><Field label="分線"><select value={lane} onChange={(e) => setLane(e.target.value as "tong" | "chao")}><option value="tong">漂漂彤</option><option value="chao">漂漂潮</option></select></Field><Field label="初始密碼"><input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} /></Field></div><button disabled={busy} onClick={() => void create()} className="mt-4 min-h-11 rounded-lg bg-rose-600 px-4 font-semibold text-white disabled:opacity-50">建立上架帳號</button></section>
    <section className="rounded-2xl border bg-white p-5"><h2 className="font-bold">已開通</h2><div className="mt-3 space-y-2">{publishers.length === 0 ? <p className="text-sm text-zinc-500">尚未建立上架帳號。</p> : publishers.map((publisher) => <div key={publisher.id} className="rounded-xl bg-zinc-50 p-4"><div className="flex flex-wrap items-center justify-between gap-3"><div><p className="font-semibold">{publisher.display_name}</p><p className="text-sm text-zinc-500">帳號：{publisher.login_id} ・ {publisher.lane === "tong" ? "漂漂彤" : "漂漂潮"} ・ {publisher.is_active ? "可上架" : "已停用"}</p></div><div className="flex gap-2"><button disabled={busy} onClick={() => setResetFor(publisher.id)} className="min-h-11 rounded-lg border px-3 text-sm font-semibold">重設密碼</button><button disabled={busy} onClick={() => void toggle(publisher)} className="min-h-11 rounded-lg border px-3 text-sm font-semibold">{publisher.is_active ? "停用" : "重新開通"}</button></div></div>{resetFor === publisher.id && <div className="mt-3 flex flex-wrap gap-2"><input className="min-h-11 rounded-lg border px-3" type="password" autoComplete="new-password" placeholder="新密碼，至少 6 碼" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} /><button disabled={busy} onClick={() => void resetPassword()} className="min-h-11 rounded-lg bg-zinc-900 px-3 text-sm font-semibold text-white">確認重設</button><button onClick={() => { setResetFor(null); setNewPassword(""); }} className="min-h-11 px-2 text-sm">取消</button></div>}</div>)}</div></section>
  </div>;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block text-sm font-semibold">{label}<div className="mt-1.5 [&_input]:min-h-11 [&_input]:w-full [&_input]:rounded-lg [&_input]:border [&_input]:px-3 [&_select]:min-h-11 [&_select]:w-full [&_select]:rounded-lg [&_select]:border [&_select]:px-3">{children}</div></label>; }

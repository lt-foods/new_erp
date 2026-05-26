"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";

const PAGE_SIZE = 20;

type FbPage = {
  id: number;
  page_id: string;
  name: string;
  sort_order: number;
  is_active: boolean;
  updated_at: string;
  token_invalid_at: string | null;
  token_last_error: string | null;
};

type FormValues = {
  id: number | null;
  page_id: string;
  name: string;
  access_token: string;
  sort_order: number;
  is_active: boolean;
};

const EMPTY: FormValues = {
  id: null,
  page_id: "",
  name: "",
  access_token: "",
  sort_order: 0,
  is_active: true,
};

export default function FbPagesPage() {
  const [rows, setRows] = useState<FbPage[] | null>(null);
  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [showActive, setShowActive] = useState<"all" | "active">("active");
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<FbPage | null>(null);
  const [creating, setCreating] = useState(false);
  const [page, setPage] = useState(1);

  useEffect(() => {
    const t = setTimeout(() => setQuery(queryDraft), 250);
    return () => clearTimeout(t);
  }, [queryDraft]);

  useEffect(() => { setPage(1); }, [query, showActive]);

  const totalPages = Math.max(1, Math.ceil((rows?.length ?? 0) / PAGE_SIZE));
  const paginated = useMemo(
    () => (rows ?? []).slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE),
    [rows, page],
  );

  const reload = async () => {
    let q = getSupabase()
      .from("fb_pages")
      .select("id, page_id, name, sort_order, is_active, updated_at, token_invalid_at, token_last_error")
      .order("sort_order", { ascending: true })
      .order("updated_at", { ascending: false })
      .limit(200);
    if (query.trim()) {
      const safe = query.replace(/[%,()]/g, " ").trim();
      q = q.or(`page_id.ilike.%${safe}%,name.ilike.%${safe}%`);
    }
    if (showActive === "active") q = q.eq("is_active", true);
    const { data, error: err } = await q;
    if (err) setError(err.message);
    else { setError(null); setRows((data as FbPage[]) ?? []); }
  };
  useEffect(() => { reload(); }, [query, showActive]);

  async function save(v: FormValues) {
    try {
      const { error: err } = await getSupabase().rpc("rpc_upsert_fb_page", {
        p_id: v.id ?? null,
        p_page_id: v.page_id.trim(),
        p_name: v.name.trim(),
        p_access_token: v.access_token.trim() || null,
        p_sort_order: v.sort_order,
        p_is_active: v.is_active,
      });
      if (err) throw err;
      setEditing(null); setCreating(false); setError(null);
      await reload();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">FB 粉絲團</h1>
          <p className="text-sm text-zinc-500">
            共 {rows?.length ?? 0} 筆 · 用於同步上架到 Facebook
          </p>
        </div>
        {!creating && !editing && (
          <SpinButton
            onClick={() => setCreating(true)}
            className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            新增粉絲團
          </SpinButton>
        )}
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {(() => {
        const invalid = (rows ?? []).filter((r) => r.token_invalid_at);
        if (invalid.length === 0) return null;
        return (
          <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">
            <div className="font-medium">
              ⚠ 偵測到 {invalid.length} 個粉專 token 已失效，需要更新：
            </div>
            <ul className="mt-1 list-disc pl-5">
              {invalid.map((r) => (
                <li key={r.id}>
                  <button
                    onClick={() => setEditing(r)}
                    className="text-amber-900 underline hover:text-amber-700 dark:text-amber-200 dark:hover:text-amber-100"
                  >
                    {r.name}
                  </button>
                  {r.token_last_error && (
                    <span className="ml-2 text-xs text-amber-700 dark:text-amber-400">
                      ({r.token_last_error})
                    </span>
                  )}
                </li>
              ))}
            </ul>
            <div className="mt-2 text-xs text-amber-800 dark:text-amber-300">
              點上方名稱進編輯畫面，用「自動換永久 token」功能修復。
            </div>
          </div>
        );
      })()}

      {creating && (
        <FbPageForm
          initial={EMPTY}
          title="新增"
          isNew
          onCancel={() => setCreating(false)}
          onSave={(v) => save({ ...v, id: null })}
        />
      )}

      <div className="grid gap-3 sm:grid-cols-2">
        <input
          type="search" value={queryDraft} onChange={(e) => setQueryDraft(e.target.value)}
          placeholder="搜尋 page_id / 名稱"
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
        <select value={showActive} onChange={(e) => setShowActive(e.target.value as "all" | "active")}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="active">僅啟用中</option>
          <option value="all">全部</option>
        </select>
      </div>

      <Table>
        <THead>
          <Th>名稱</Th>
          <Th>Page ID</Th>
          <Th>排序</Th>
          <Th>狀態</Th>
          <Th>{""}</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={5} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={5}>尚無粉絲團設定</EmptyRow>
          ) : paginated.map((r) => editing?.id === r.id ? (
            <tr key={r.id}>
              <td colSpan={5} className="p-0">
                <FbPageForm
                  initial={{
                    id: r.id,
                    page_id: r.page_id,
                    name: r.name,
                    access_token: "",
                    sort_order: r.sort_order,
                    is_active: r.is_active,
                  }}
                  title="編輯"
                  isNew={false}
                  onCancel={() => setEditing(null)}
                  onSave={(v) => save({ ...v, id: r.id })}
                  onAfterExchange={async () => { await reload(); setEditing(null); }}
                />
              </td>
            </tr>
          ) : (
            <Tr key={r.id}>
              <Td>{r.name}</Td>
              <Td className="font-mono text-xs">{r.page_id}</Td>
              <Td className="text-xs">{r.sort_order}</Td>
              <Td>
                <span className={`inline-block rounded px-2 py-0.5 text-xs ${r.is_active ? "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300" : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"}`}>
                  {r.is_active ? "啟用" : "停用"}
                </span>
                {r.token_invalid_at && (
                  <span
                    title={r.token_last_error ?? ""}
                    className="ml-1 inline-block rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                  >
                    Token 失效
                  </span>
                )}
              </Td>
              <Td>
                <SpinButton onClick={() => setEditing(r)} className="text-xs text-blue-600 hover:underline dark:text-blue-400">編輯</SpinButton>
              </Td>
            </Tr>
          ))}
        </TBody>
      </Table>

      {(rows?.length ?? 0) > PAGE_SIZE && (
        <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
          <span className="text-xs text-zinc-500">
            共 {rows?.length ?? 0} 筆 · 顯示 {(page - 1) * PAGE_SIZE + 1} - {Math.min(page * PAGE_SIZE, rows?.length ?? 0)}
          </span>
          <SpinButton onClick={() => setPage(1)} disabled={page === 1} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">« 第一頁</SpinButton>
          <SpinButton onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={page === 1} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">‹ 上頁</SpinButton>
          <span className="text-xs text-zinc-500">{page} / {totalPages}</span>
          <SpinButton onClick={() => setPage((p) => Math.min(totalPages, p + 1))} disabled={page === totalPages} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">下頁 ›</SpinButton>
          <SpinButton onClick={() => setPage(totalPages)} disabled={page === totalPages} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">最末頁 »</SpinButton>
        </div>
      )}

      <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
        <div className="mb-1 font-medium text-zinc-700 dark:text-zinc-300">
          如何取得「永不過期」的 Page Access Token？
        </div>
        <ol className="list-decimal space-y-0.5 pl-4">
          <li>
            到 <a href="https://developers.facebook.com/tools/explorer/" target="_blank" rel="noreferrer" className="text-blue-600 hover:underline dark:text-blue-400">Graph API Explorer</a>
          </li>
          <li>選擇 App、按「Get User Access Token」勾 <code>pages_manage_posts</code>、<code>pages_read_engagement</code>、<code>pages_show_list</code></li>
          <li>複製介面上方的 User Access Token（不是 Page Token！）</li>
          <li>到下方對應粉專按「編輯」，貼進「自動換永久 Token」欄位送出 — 系統會自動換成永不過期的 page token 存進來。</li>
          <li>page_id 在 Page 設定的「關於」分頁底，新增粉專時要先填這個。</li>
        </ol>
        <div className="mt-2 text-amber-700 dark:text-amber-400">
          ⚠ 如果不走「自動換永久 token」直接貼 token，會拿到短期 token，過一兩天就失效。
        </div>
      </div>
    </div>
  );
}

function FbPageForm({
  initial, title, isNew, onSave, onCancel, onAfterExchange,
}: {
  initial: FormValues;
  title: string;
  isNew: boolean;
  onSave: (v: FormValues) => void;
  onCancel: () => void;
  onAfterExchange?: () => void | Promise<void>;
}) {
  const [v, setV] = useState(initial);
  const [userToken, setUserToken] = useState("");
  const [exchanging, setExchanging] = useState(false);
  const [exchangeMsg, setExchangeMsg] = useState<{ kind: "ok" | "err"; text: string } | null>(null);
  function up<K extends keyof typeof v>(k: K, val: typeof v[K]) { setV({ ...v, [k]: val }); }

  async function doExchange() {
    if (!v.id) {
      setExchangeMsg({ kind: "err", text: "新建粉專請先填好基本資料、貼任意 token 後儲存，再進編輯換永久 token" });
      return;
    }
    const t = userToken.trim();
    if (!t) {
      setExchangeMsg({ kind: "err", text: "請貼入 User Access Token" });
      return;
    }
    setExchanging(true);
    setExchangeMsg(null);
    try {
      const sb = getSupabase();
      const { data: { session } } = await sb.auth.getSession();
      if (!session) throw new Error("尚未登入");
      const url = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/fb-exchange-token`;
      const resp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({ fb_page_db_id: v.id, user_token: t }),
      });
      const data = await resp.json();
      if (!resp.ok) {
        const detail = data?.hint ? `${data?.error}：${data?.hint}` : (data?.error || data?.detail || `HTTP ${resp.status}`);
        throw new Error(detail);
      }
      setUserToken("");
      const tag = data?.never_expire ? "永不過期" : `預計 ${data?.expires_at ? new Date(data.expires_at * 1000).toLocaleString() : "未知"} 到期`;
      setExchangeMsg({ kind: "ok", text: `已換取新 page token（${tag}）。儲存中...` });
      await onAfterExchange?.();
    } catch (e) {
      setExchangeMsg({ kind: "err", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setExchanging(false);
    }
  }

  return (
    <form
      onSubmit={(e) => { e.preventDefault(); onSave(v); }}
      className="space-y-3 border-l-4 border-blue-400 bg-blue-50/40 p-4 dark:bg-blue-950/20"
    >
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold">{title}</h3>
      </div>
      <div className="grid gap-3 sm:grid-cols-4">
        <F label="名稱 *" className="sm:col-span-2">
          <input value={v.name} onChange={(e) => up("name", e.target.value)} required className={inputCls} placeholder="樂樂團購 - 永和店" />
        </F>
        <F label="Page ID *">
          <input value={v.page_id} onChange={(e) => up("page_id", e.target.value)} required className={inputCls} placeholder="100012345678901" />
        </F>
        <F label="排序">
          <input
            type="number" value={v.sort_order}
            onChange={(e) => up("sort_order", Number(e.target.value) || 0)}
            className={inputCls}
          />
        </F>

        <F label={isNew ? "Page Access Token *" : "Page Access Token（留空＝保留現值）"} className="sm:col-span-4">
          <input
            type="password"
            value={v.access_token}
            onChange={(e) => up("access_token", e.target.value)}
            required={isNew}
            className={inputCls}
            placeholder={isNew ? "EAAB...（長字串）" : "留空表示沿用現有 token"}
            autoComplete="off"
          />
        </F>

        <F label="啟用">
          <label className="flex items-center gap-2 pt-1.5 text-sm">
            <input type="checkbox" checked={v.is_active} onChange={(e) => up("is_active", e.target.checked)} />
            <span>{v.is_active ? "啟用中" : "停用"}</span>
          </label>
        </F>
      </div>

      {!isNew && (
        <div className="mt-2 space-y-2 rounded-md border border-emerald-200 bg-emerald-50/50 p-3 dark:border-emerald-900 dark:bg-emerald-950/30">
          <div className="text-sm font-semibold text-emerald-900 dark:text-emerald-200">
            自動換永久 Page Token（推薦）
          </div>
          <div className="text-xs text-emerald-800 dark:text-emerald-300">
            貼入 <strong>User Access Token</strong>（不是 Page Token），系統會自動 exchange 成 long-lived user token 再取出對應 Page 的永不過期 token。
            到 <a href="https://developers.facebook.com/tools/explorer/" target="_blank" rel="noreferrer" className="underline">Graph API Explorer</a> 取 User Token，需要 scopes：
            <code className="ml-1">pages_show_list, pages_manage_posts, pages_read_engagement</code>
          </div>
          <textarea
            value={userToken}
            onChange={(e) => setUserToken(e.target.value)}
            placeholder="EAAB...（貼入 User Access Token）"
            rows={3}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono text-xs focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
            autoComplete="off"
          />
          <div className="flex items-center gap-2">
            <SpinButton
              type="button"
              onClick={doExchange}
              disabled={exchanging || !userToken.trim()}
              className="rounded-md bg-emerald-600 px-3 py-1.5 text-sm text-white transition-colors hover:bg-emerald-700 disabled:opacity-50 dark:bg-emerald-700 dark:hover:bg-emerald-600"
            >
              {exchanging ? "換取中..." : "換取永久 Token"}
            </SpinButton>
            {exchangeMsg && (
              <span className={`text-xs ${exchangeMsg.kind === "ok" ? "text-emerald-700 dark:text-emerald-300" : "text-red-700 dark:text-red-300"}`}>
                {exchangeMsg.text}
              </span>
            )}
          </div>
        </div>
      )}

      <div className="flex items-center gap-2">
        <SpinButton type="submit" className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm text-white transition-colors hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200">儲存</SpinButton>
        <SpinButton type="button" onClick={onCancel} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm transition-colors hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</SpinButton>
      </div>
    </form>
  );
}

function F({ label, children, className = "" }: { label: string; children: React.ReactNode; className?: string }) {
  return (
    <label className={`flex flex-col gap-1 text-sm ${className}`}>
      <span className="text-xs text-zinc-500">{label}</span>
      {children}
    </label>
  );
}
const inputCls =
  "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

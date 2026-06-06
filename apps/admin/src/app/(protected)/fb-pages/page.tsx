"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";

const PAGE_SIZE = 20;

type FbPage = {
  id: number;
  page_id: string;
  name: string;
  sort_order: number;
  is_active: boolean;
  updated_at: string;
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
  const [searching, setSearching] = useState(false);
  const [showActive, setShowActive] = useState<"all" | "active">("active");
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<FbPage | null>(null);
  const [creating, setCreating] = useState(false);
  const [page, setPage] = useState(1);

  useEffect(() => {
    // 打字內容與已送出的 query 不同 → 有一筆 reload 待觸發，轉圈圈到 reload 結束才停
    if (queryDraft !== query) setSearching(true);
    const t = setTimeout(() => setQuery(queryDraft), 250);
    return () => clearTimeout(t);
  }, [queryDraft, query]);

  useEffect(() => { setPage(1); }, [query, showActive]);

  const totalPages = Math.max(1, Math.ceil((rows?.length ?? 0) / PAGE_SIZE));
  const paginated = useMemo(
    () => (rows ?? []).slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE),
    [rows, page],
  );

  const reload = async () => {
    let q = getSupabase()
      .from("fb_pages")
      .select("id, page_id, name, sort_order, is_active, updated_at")
      .order("sort_order", { ascending: true })
      .order("updated_at", { ascending: false })
      .limit(200);
    if (query.trim()) {
      const safe = query.replace(/[%,()]/g, " ").trim();
      q = q.or(`page_id.ilike.%${safe}%,name.ilike.%${safe}%`);
    }
    if (showActive === "active") q = q.eq("is_active", true);
    try {
      const { data, error: err } = await q;
      if (err) setError(err.message);
      else { setError(null); setRows((data as FbPage[]) ?? []); }
    } finally {
      setSearching(false);
    }
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
        <div className="relative">
          <input
            type="search" value={queryDraft} onChange={(e) => setQueryDraft(e.target.value)}
            placeholder="搜尋 page_id / 名稱"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 pr-8 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
          />
          <SearchSpinner active={searching} />
        </div>
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
        <div className="mb-1 font-medium text-zinc-700 dark:text-zinc-300">如何取得 Page Access Token？</div>
        <ol className="list-decimal space-y-0.5 pl-4">
          <li>到 <a href="https://developers.facebook.com/tools/explorer/" target="_blank" rel="noreferrer" className="text-blue-600 hover:underline dark:text-blue-400">Graph API Explorer</a></li>
          <li>選擇 App、按「Get User Access Token」勾 `pages_manage_posts`、`pages_read_engagement`</li>
          <li>用 user token 呼叫 `GET /me/accounts`，取得對應 Page 的 long-lived page token</li>
          <li>page_id 在 Page 設定的「關於」分頁底</li>
        </ol>
      </div>
    </div>
  );
}

function FbPageForm({
  initial, title, isNew, onSave, onCancel,
}: {
  initial: FormValues;
  title: string;
  isNew: boolean;
  onSave: (v: FormValues) => void;
  onCancel: () => void;
}) {
  const [v, setV] = useState(initial);
  function up<K extends keyof typeof v>(k: K, val: typeof v[K]) { setV({ ...v, [k]: val }); }

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

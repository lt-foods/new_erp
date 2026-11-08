"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { useRole, isAdmin } from "@/lib/role";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import SourceTabs from "../SourceTabs";

/**
 * 廠商網站清單（vendor_sites，20261108000000）：爬蟲（tools/vendor-scraper）照這張表登入廠商網站抓商品進候選池。
 * 只有 owner / admin 看得到（RLS），密碼預設遮住、按一下才顯示。
 * 跑爬蟲：node scripts/vendor-sites-run.mjs（README 在 tools/vendor-scraper）。
 */
type VendorSite = {
  id: number;
  key: string;
  name: string;
  supplier_id: number | null;
  platform: string;
  urls: string[];
  email: string | null;
  password: string | null;
  is_active: boolean;
  notes: string | null;
  last_scraped_at: string | null;
  last_count: number | null;
  last_error: string | null;
  updated_at: string;
};
type Supplier = { id: number; name: string };

const PLATFORMS = [{ value: "shop2000", label: "shop2000（www.shop2000.com.tw 與其自訂網域）" }];

const EMPTY: FormValues = {
  id: null, key: "", name: "", supplier_id: null, platform: "shop2000", urls: "", email: "", password: "", is_active: true, notes: "",
};

export default function VendorSitesPage() {
  const role = useRole();
  const [rows, setRows] = useState<VendorSite[] | null>(null);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<VendorSite | null>(null);
  const [creating, setCreating] = useState(false);
  const [showAll, setShowAll] = useState(false);
  const [revealed, setRevealed] = useState<Set<number>>(new Set());

  const reload = async () => {
    const sb = getSupabase();
    const [v, s] = await Promise.all([
      sb.from("vendor_sites").select("*").order("is_active", { ascending: false }).order("name"),
      sb.from("suppliers").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (v.error) setError(v.error.message);
    else { setError(null); setRows((v.data as VendorSite[]) ?? []); }
    if (!s.error) setSuppliers((s.data as Supplier[]) ?? []);
  };
  useEffect(() => { reload(); }, []);

  async function save(v: FormValues) {
    try {
      const urls = v.urls.split(/\r?\n/).map((u) => u.trim()).filter(Boolean);
      const { error: err } = await getSupabase().rpc("rpc_upsert_vendor_site", {
        p_id: v.id,
        p_key: v.key.trim().toLowerCase(),
        p_name: v.name.trim(),
        p_supplier_id: v.supplier_id,
        p_platform: v.platform,
        p_urls: urls,
        p_email: v.email.trim() || null,
        // 編輯時沒動密碼欄 → 送 null（不改）；新增時空的就是沒密碼
        p_password: v.id != null && v.password === "" ? null : v.password,
        p_is_active: v.is_active,
        p_notes: v.notes.trim() || null,
      });
      if (err) throw err;
      setEditing(null); setCreating(false); setError(null);
      await reload();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  }

  const supplierName = (id: number | null) => suppliers.find((s) => s.id === id)?.name ?? (id != null ? `#${id}` : null);
  const visible = (rows ?? []).filter((r) => showAll || r.is_active);
  const admin = isAdmin(role);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <SourceTabs />
      <header className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h1 className="text-xl font-semibold">廠商網站</h1>
          <p className="mt-0.5 text-sm text-zinc-500">
            爬蟲照這份清單登入廠商網站抓商品進候選池。網址可以是店家首頁（抓全部分類）、分類頁或單一商品頁；
            一列可以放多個網址。已下架、待處理、已過收單日的分類會自動跳過。
          </p>
        </div>
        {admin && !creating && !editing && (
          <SpinButton
            onClick={() => setCreating(true)}
            className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            新增廠商網站
          </SpinButton>
        )}
      </header>

      {role !== null && !admin && (
        <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300">
          這一頁有廠商網站的會員帳密，只有負責人 / 管理員看得到。
        </div>
      )}
      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {creating && (
        <VendorSiteForm initial={EMPTY} title="新增" suppliers={suppliers} onCancel={() => setCreating(false)} onSave={save} />
      )}

      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={showAll} onChange={(e) => setShowAll(e.target.checked)} />
        <span>顯示停用的</span>
      </label>

      <Table>
        <THead>
          <Th>廠商</Th><Th>供應商</Th><Th>網址</Th><Th>帳號</Th><Th>密碼</Th><Th>上次抓取</Th><Th>狀態</Th><Th>{""}</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={8} />
          ) : visible.length === 0 ? (
            <EmptyRow colSpan={8}>還沒有廠商網站</EmptyRow>
          ) : visible.map((r) => editing?.id === r.id ? (
            <tr key={r.id}>
              <td colSpan={8} className="p-0">
                <VendorSiteForm
                  initial={{ id: r.id, key: r.key, name: r.name, supplier_id: r.supplier_id, platform: r.platform,
                             urls: r.urls.join("\n"), email: r.email ?? "", password: "", is_active: r.is_active, notes: r.notes ?? "" }}
                  title="編輯"
                  hasPassword={!!r.password}
                  suppliers={suppliers}
                  onCancel={() => setEditing(null)}
                  onSave={save}
                />
              </td>
            </tr>
          ) : (
            <Tr key={r.id}>
              <Td>
                <div className="font-medium">{r.name}</div>
                <div className="font-mono text-[11px] text-zinc-400">{r.key}・{r.platform}</div>
              </Td>
              <Td className="text-xs">
                {r.supplier_id != null ? supplierName(r.supplier_id)
                  : <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[11px] text-amber-700 dark:bg-amber-900/30 dark:text-amber-300" title="沒對到供應商的不會跑">沒對到</span>}
              </Td>
              <Td className="max-w-xs text-xs">
                {r.urls.map((u) => (
                  <div key={u} className="truncate" title={u}>
                    <a href={u} target="_blank" rel="noreferrer" className="text-blue-600 hover:underline dark:text-blue-400">{decodeURI(u)}</a>
                  </div>
                ))}
              </Td>
              <Td className="font-mono text-xs">{r.email ?? <span className="text-amber-600">沒帳號</span>}</Td>
              <Td className="font-mono text-xs">
                {!r.password ? <span className="text-amber-600">沒密碼</span>
                  : revealed.has(r.id) ? (
                    <button type="button" className="hover:underline" title="點一下遮回去"
                            onClick={() => setRevealed((s) => { const n = new Set(s); n.delete(r.id); return n; })}>{r.password}</button>
                  ) : (
                    <button type="button" className="tracking-widest text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200" title="點一下顯示"
                            onClick={() => setRevealed((s) => new Set(s).add(r.id))}>••••••••</button>
                  )}
              </Td>
              <Td className="text-xs">
                {r.last_scraped_at ? (
                  <>
                    <div>{new Date(r.last_scraped_at).toLocaleString("zh-TW", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })}</div>
                    <div className="text-zinc-400">{r.last_count != null ? `${r.last_count} 筆` : ""}</div>
                  </>
                ) : <span className="text-zinc-400">還沒抓過</span>}
                {r.last_error && <div className="mt-0.5 max-w-xs truncate text-red-600" title={r.last_error}>{r.last_error}</div>}
              </Td>
              <Td>
                <span className={`inline-block rounded px-2 py-0.5 text-xs ${r.is_active ? "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300" : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"}`}>
                  {r.is_active ? "啟用" : "停用"}
                </span>
              </Td>
              <Td>
                {admin && <SpinButton onClick={() => setEditing(r)} className="text-xs text-blue-600 hover:underline dark:text-blue-400">編輯</SpinButton>}
              </Td>
            </Tr>
          ))}
        </TBody>
      </Table>

      <p className="text-xs text-zinc-400">
        跑爬蟲：在有資料庫權限的電腦上執行 <code className="rounded bg-zinc-100 px-1 dark:bg-zinc-800">node scripts/vendor-sites-run.mjs</code>（全部啟用中的）或接代號只跑幾家。
      </p>
    </div>
  );
}

type FormValues = {
  id: number | null;
  key: string;
  name: string;
  supplier_id: number | null;
  platform: string;
  /** 一行一個網址 */
  urls: string;
  email: string;
  /** 編輯時留空 = 不改 */
  password: string;
  is_active: boolean;
  notes: string;
};

function VendorSiteForm({
  initial, title, suppliers, hasPassword = false, onSave, onCancel,
}: {
  initial: FormValues;
  title: string;
  suppliers: Supplier[];
  hasPassword?: boolean;
  onSave: (v: FormValues) => void;
  onCancel: () => void;
}) {
  const [v, setV] = useState(initial);
  const [showPw, setShowPw] = useState(false);
  const isNew = v.id == null;
  function up<K extends keyof FormValues>(k: K, val: FormValues[K]) { setV({ ...v, [k]: val }); }

  return (
    <form
      onSubmit={(e) => { e.preventDefault(); onSave(v); }}
      className="space-y-3 border-l-4 border-blue-400 bg-blue-50/40 p-4 dark:bg-blue-950/20"
    >
      <h3 className="text-sm font-semibold">{title}</h3>
      <div className="grid gap-3 sm:grid-cols-4">
        <F label="廠商名稱 *"><input value={v.name} onChange={(e) => up("name", e.target.value)} required className={inputCls} /></F>
        <F label={isNew ? "代號 *（小寫英數，建立後不能改）" : "代號"}>
          <input value={v.key} onChange={(e) => up("key", e.target.value)} required disabled={!isNew} pattern="[a-z0-9_-]{1,40}"
                 placeholder="youxian" className={`${inputCls} font-mono disabled:opacity-60`} />
        </F>
        <F label="供應商 *（候選池掛在誰名下）">
          <select value={v.supplier_id ?? ""} onChange={(e) => up("supplier_id", e.target.value ? Number(e.target.value) : null)} required className={inputCls}>
            <option value="">— 選供應商 —</option>
            {suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </F>
        <F label="平台">
          <select value={v.platform} onChange={(e) => up("platform", e.target.value)} className={inputCls}>
            {PLATFORMS.map((p) => <option key={p.value} value={p.value}>{p.label}</option>)}
          </select>
        </F>

        <F label="網址 *（一行一個：店家首頁 / 分類頁 / 商品頁）" className="sm:col-span-4">
          <textarea value={v.urls} onChange={(e) => up("urls", e.target.value)} required className={`${inputCls} min-h-20 font-mono text-xs`}
                    placeholder={"https://www.shop2000.com.tw/店名\nhttps://www.shop2000.com.tw/店名/product/123456"} />
        </F>

        <F label="帳號（Email / 手機）" className="sm:col-span-2">
          <input value={v.email} onChange={(e) => up("email", e.target.value)} autoComplete="off" className={`${inputCls} font-mono`} />
        </F>
        <F label={isNew ? "密碼" : hasPassword ? "密碼（留空 = 不改）" : "密碼（目前沒有）"} className="sm:col-span-2">
          <div className="flex gap-1">
            <input type={showPw ? "text" : "password"} value={v.password} onChange={(e) => up("password", e.target.value)} autoComplete="new-password"
                   className={`${inputCls} flex-1 font-mono`} />
            <button type="button" onClick={() => setShowPw((x) => !x)}
                    className="rounded-md border border-zinc-300 px-2 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800">
              {showPw ? "遮住" : "顯示"}
            </button>
          </div>
        </F>

        <F label="備註" className="sm:col-span-3"><input value={v.notes} onChange={(e) => up("notes", e.target.value)} className={inputCls} placeholder="會員等級、要跳過的分類…" /></F>
        <F label="啟用">
          <label className="flex items-center gap-2 pt-1.5 text-sm">
            <input type="checkbox" checked={v.is_active} onChange={(e) => up("is_active", e.target.checked)} />
            <span>{v.is_active ? "啟用中（會跑）" : "停用（不跑）"}</span>
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

"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";

type Supplier = {
  id: number;
  code: string;
  name: string;
  tax_id: string | null;
  contact_name: string | null;
  phone: string | null;
  email: string | null;
  address: string | null;
  payment_terms: string | null;
  lead_time_days: number | null;
  is_active: boolean;
  notes: string | null;
  updated_at: string;
};

const EMPTY: Omit<Supplier, "id" | "updated_at"> = {
  code: "", name: "", tax_id: null, contact_name: null, phone: null, email: null,
  address: null, payment_terms: null, lead_time_days: null, is_active: true, notes: null,
};

export default function SuppliersPage() {
  const [rows, setRows] = useState<Supplier[] | null>(null);
  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [showActive, setShowActive] = useState<"all" | "active">("active");
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Supplier | null>(null);
  const [creating, setCreating] = useState(false);

  useEffect(() => {
    const t = setTimeout(() => setQuery(queryDraft), 250);
    return () => clearTimeout(t);
  }, [queryDraft]);

  const reload = async () => {
    let q = getSupabase()
      .from("suppliers")
      .select("id, code, name, tax_id, contact_name, phone, email, address, payment_terms, lead_time_days, is_active, notes, updated_at")
      .order("updated_at", { ascending: false })
      .limit(200);
    if (query.trim()) {
      const safe = query.replace(/[%,()]/g, " ").trim();
      q = q.or(`code.ilike.%${safe}%,name.ilike.%${safe}%`);
    }
    if (showActive === "active") q = q.eq("is_active", true);
    const { data, error: err } = await q;
    if (err) setError(err.message);
    else { setError(null); setRows((data as Supplier[]) ?? []); }
  };
  useEffect(() => { reload(); }, [query, showActive]);

  async function save(v: SupplierFormValues) {
    try {
      const { error: err } = await getSupabase().rpc("rpc_upsert_supplier", {
        p_id: v.id ?? null,
        p_code: v.code.trim(),
        p_name: v.name.trim(),
        p_tax_id: v.tax_id, p_contact_name: v.contact_name,
        p_phone: v.phone, p_email: v.email, p_address: v.address,
        p_payment_terms: v.payment_terms, p_lead_time_days: v.lead_time_days,
        p_is_active: v.is_active, p_notes: v.notes,
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
          <h1 className="text-xl font-semibold">供應商</h1>
          <p className="text-sm text-zinc-500">共 {rows?.length ?? 0} 筆</p>
        </div>
        {!creating && !editing && (
          <button
            onClick={() => setCreating(true)}
            className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            新增供應商
          </button>
        )}
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {creating && (
        <SupplierForm
          initial={{ ...EMPTY, id: null }}
          title="新增"
          onCancel={() => setCreating(false)}
          onSave={(v) => save({ ...v, id: null })}
        />
      )}

      <div className="grid gap-3 sm:grid-cols-2">
        <input
          type="search" value={queryDraft} onChange={(e) => setQueryDraft(e.target.value)}
          placeholder="搜尋 code / 名稱"
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
        <select value={showActive} onChange={(e) => setShowActive(e.target.value as "all" | "active")}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="active">僅啟用中</option>
          <option value="all">全部</option>
        </select>
      </div>

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>代碼</Th><Th>名稱</Th><Th>聯絡人</Th><Th>電話</Th><Th>Email</Th><Th>付款</Th><Th>交期(天)</Th><Th>狀態</Th><Th>{""}</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={9} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">尚無供應商</td></tr>
            ) : rows.map((r) => editing?.id === r.id ? (
              <tr key={r.id}>
                <td colSpan={9} className="p-0">
                  <SupplierForm
                    initial={{ ...r, id: r.id }}
                    title="編輯"
                    onCancel={() => setEditing(null)}
                    onSave={(v) => save({ ...v, id: r.id })}
                  />
                </td>
              </tr>
            ) : (
              <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                <Td className="font-mono">{r.code}</Td>
                <Td>{r.name}</Td>
                <Td className="text-xs">{r.contact_name ?? "—"}</Td>
                <Td className="font-mono text-xs">{r.phone ?? "—"}</Td>
                <Td className="text-xs">{r.email ?? "—"}</Td>
                <Td className="text-xs">{r.payment_terms ?? "—"}</Td>
                <Td className="text-xs">{r.lead_time_days ?? "—"}</Td>
                <Td>
                  <span className={`inline-block rounded px-2 py-0.5 text-xs ${r.is_active ? "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300" : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"}`}>
                    {r.is_active ? "啟用" : "停用"}
                  </span>
                </Td>
                <Td>
                  <button onClick={() => setEditing(r)} className="text-xs text-blue-600 hover:underline dark:text-blue-400">編輯</button>
                </Td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

type SupplierFormValues = Omit<Supplier, "id" | "updated_at"> & { id: number | null };

function SupplierForm({
  initial, title, onSave, onCancel,
}: {
  initial: SupplierFormValues;
  title: string;
  onSave: (v: SupplierFormValues) => void;
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
        <F label="代碼 *"><input value={v.code} onChange={(e) => up("code", e.target.value)} required className={inputCls} /></F>
        <F label="名稱 *"><input value={v.name} onChange={(e) => up("name", e.target.value)} required className={inputCls} /></F>
        <F label="統編"><input value={v.tax_id ?? ""} onChange={(e) => up("tax_id", e.target.value || null)} className={inputCls} /></F>
        <F label="啟用">
          <label className="flex items-center gap-2 pt-1.5 text-sm">
            <input type="checkbox" checked={v.is_active} onChange={(e) => up("is_active", e.target.checked)} />
            <span>{v.is_active ? "啟用中" : "停用"}</span>
          </label>
        </F>

        <F label="聯絡人"><input value={v.contact_name ?? ""} onChange={(e) => up("contact_name", e.target.value || null)} className={inputCls} /></F>
        <F label="電話"><input value={v.phone ?? ""} onChange={(e) => up("phone", e.target.value || null)} className={inputCls} /></F>
        <F label="Email"><input type="email" value={v.email ?? ""} onChange={(e) => up("email", e.target.value || null)} className={inputCls} /></F>
        <F label="交期(天)"><input type="number" min="0" value={v.lead_time_days ?? ""} onChange={(e) => up("lead_time_days", e.target.value ? Number(e.target.value) : null)} className={inputCls} /></F>

        <F label="地址" className="sm:col-span-2"><input value={v.address ?? ""} onChange={(e) => up("address", e.target.value || null)} className={inputCls} /></F>
        <F label="付款條件" className="sm:col-span-2"><input value={v.payment_terms ?? ""} onChange={(e) => up("payment_terms", e.target.value || null)} className={inputCls} placeholder="月結30天 / 貨到付款…" /></F>

        <F label="備註" className="sm:col-span-4"><textarea value={v.notes ?? ""} onChange={(e) => up("notes", e.target.value || null)} className={`${inputCls} min-h-16`} /></F>
      </div>
      <div className="flex items-center gap-2">
        <button type="submit" className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm text-white transition-colors hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200">儲存</button>
        <button type="button" onClick={onCancel} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm transition-colors hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</button>
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
function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-3 py-2 ${className}`}>{children}</td>;
}

const inputCls =
  "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

export type CampaignStatus =
  | "draft" | "open" | "closed" | "ordered" | "receiving" | "ready" | "completed" | "cancelled";
export type CloseType = "regular" | "fast" | "limited";

export type CampaignFormValues = {
  id: number | null;
  campaign_no: string;
  name: string;
  description: string | null;
  status: CampaignStatus;
  close_type: CloseType;
  start_at: string | null;
  end_at: string | null;
  pickup_deadline: string | null;
  pickup_days: number | null;
  total_cap_qty: number | null;
  notes: string | null;
};

export const emptyCampaignValues: CampaignFormValues = {
  id: null,
  campaign_no: "",
  name: "",
  description: null,
  status: "draft",
  close_type: "regular",
  start_at: null,
  end_at: null,
  pickup_deadline: null,
  pickup_days: null,
  total_cap_qty: null,
  notes: null,
};

const STATUS_OPT: { v: CampaignStatus; label: string }[] = [
  { v: "draft", label: "草稿" },
  { v: "open", label: "開團中" },
  { v: "closed", label: "已收單" },
  { v: "ordered", label: "已下訂" },
  { v: "receiving", label: "到貨中" },
  { v: "ready", label: "可取貨" },
  { v: "completed", label: "已完成" },
  { v: "cancelled", label: "已取消" },
];

export function CampaignForm({ initial }: { initial?: CampaignFormValues }) {
  const router = useRouter();
  const [v, setV] = useState<CampaignFormValues>(initial ?? emptyCampaignValues);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function update<K extends keyof CampaignFormValues>(k: K, val: CampaignFormValues[K]) {
    setV((prev) => ({ ...prev, [k]: val }));
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!v.campaign_no || !v.name) { setError("團號與名稱必填"); return; }
    setSaving(true); setError(null);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_upsert_campaign", {
        p_id: v.id,
        p_campaign_no: v.campaign_no.trim(),
        p_name: v.name.trim(),
        p_description: v.description,
        p_status: v.status,
        p_close_type: v.close_type,
        p_start_at: v.start_at,
        p_end_at: v.end_at,
        p_pickup_deadline: v.pickup_deadline,
        p_pickup_days: v.pickup_days,
        p_total_cap_qty: v.total_cap_qty,
        p_notes: v.notes,
      });
      if (err) throw err;
      router.replace(`/campaigns/edit?id=${Number(data)}&saved=1`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="團號 *">
          <input value={v.campaign_no} onChange={(e) => update("campaign_no", e.target.value)} className={inputCls} required />
        </Field>
        <Field label="狀態">
          <select value={v.status} onChange={(e) => update("status", e.target.value as CampaignStatus)} className={inputCls}>
            {STATUS_OPT.map((o) => <option key={o.v} value={o.v}>{o.label}</option>)}
          </select>
        </Field>

        <Field label="名稱 *" className="sm:col-span-2">
          <input value={v.name} onChange={(e) => update("name", e.target.value)} className={inputCls} required />
        </Field>

        <Field label="收單類型">
          <select value={v.close_type} onChange={(e) => update("close_type", e.target.value as CloseType)} className={inputCls}>
            <option value="regular">常規</option>
            <option value="fast">快團</option>
            <option value="limited">限量</option>
          </select>
        </Field>
        <Field label="總量上限">
          <input type="number" step="0.001" value={v.total_cap_qty ?? ""} onChange={(e) => update("total_cap_qty", e.target.value ? Number(e.target.value) : null)} className={inputCls} />
        </Field>

        <Field label="開團時間">
          <input type="datetime-local" value={toDtLocal(v.start_at)} onChange={(e) => update("start_at", e.target.value ? new Date(e.target.value).toISOString() : null)} className={inputCls} />
        </Field>
        <Field label="收單時間">
          <input type="datetime-local" value={toDtLocal(v.end_at)} onChange={(e) => update("end_at", e.target.value ? new Date(e.target.value).toISOString() : null)} className={inputCls} />
        </Field>

        <Field label="取貨截止">
          <input type="date" value={v.pickup_deadline ?? ""} onChange={(e) => update("pickup_deadline", e.target.value || null)} className={inputCls} />
        </Field>
        <Field label="取貨天數">
          <input type="number" min="0" value={v.pickup_days ?? ""} onChange={(e) => update("pickup_days", e.target.value ? Number(e.target.value) : null)} className={inputCls} />
        </Field>
      </div>

      <Field label="描述">
        <textarea value={v.description ?? ""} onChange={(e) => update("description", e.target.value || null)} className={`${inputCls} min-h-16`} />
      </Field>
      <Field label="備註">
        <textarea value={v.notes ?? ""} onChange={(e) => update("notes", e.target.value || null)} className={`${inputCls} min-h-16`} />
      </Field>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>
      )}

      <div className="flex items-center gap-3">
        <button type="submit" disabled={saving} className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200">
          {saving ? "儲存中…" : v.id ? "儲存" : "建立開團"}
        </button>
        <button type="button" onClick={() => router.push("/campaigns")} className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</button>
      </div>
    </form>
  );
}

function toDtLocal(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function Field({ label, children, className = "" }: { label: string; children: React.ReactNode; className?: string }) {
  return (
    <label className={`flex flex-col gap-1 text-sm ${className}`}>
      <span className="text-zinc-600 dark:text-zinc-400">{label}</span>
      {children}
    </label>
  );
}

const inputCls =
  "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

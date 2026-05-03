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

// 使用者可手動切換的狀態僅 3 個；ordered / receiving / ready / completed / cancelled
// 由下游 RPC（建 PR / 收貨 / finalize / cancel）自動推進，不在 UI 下拉中
const STATUS_OPT: { v: CampaignStatus; label: string }[] = [
  { v: "draft", label: "草稿" },
  { v: "open", label: "開團中" },
  { v: "closed", label: "已收單" },
];

const DOWNSTREAM_LABEL: Record<string, string> = {
  ordered: "已下訂",
  receiving: "到貨中",
  ready: "可取貨",
  completed: "已完成",
  cancelled: "已取消",
};

export function CampaignForm({
  initial,
  onSaved,
  onCancel,
  submitLabel,
}: {
  initial?: CampaignFormValues;
  onSaved?: (id: number) => void;
  onCancel?: () => void;
  submitLabel?: string;
}) {
  const router = useRouter();
  const [v, setV] = useState<CampaignFormValues>(initial ?? emptyCampaignValues);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function update<K extends keyof CampaignFormValues>(k: K, val: CampaignFormValues[K]) {
    setV((prev) => ({ ...prev, [k]: val }));
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true); setError(null);
    try {
      // 開團驗證：status='open' 時、所有關聯商品需為 'active'（不可有 draft 商品）
      if (v.status === "open" && v.id != null) {
        const sb = getSupabase();
        const { data: items } = await sb
          .from("campaign_items")
          .select("sku_id")
          .eq("campaign_id", v.id);
        const skuIds = (items ?? []).map((it) => it.sku_id);
        if (skuIds.length === 0) {
          throw new Error("開團前需至少有一個商品（規格）");
        }
        const { data: skus } = await sb.from("skus").select("product_id").in("id", skuIds);
        const productIds = [...new Set((skus ?? []).map((s) => s.product_id))];
        const { data: products } = await sb
          .from("products")
          .select("id, product_code, name, status")
          .in("id", productIds);
        const drafts = (products ?? []).filter((p) => p.status !== "active");
        if (drafts.length > 0) {
          const list = drafts.map((p) => `${p.product_code} ${p.name}（${p.status}）`).join("、");
          throw new Error(`下列商品尚未上架，無法開團：${list}`);
        }
      }

      // 名稱 / 描述 / 收單時間 / 取貨截止 / 取貨天數 / 總量上限 / 備註
      // 都從商品 / RPC 自動帶入；UI 不可編輯，保留原值送回。
      const { data, error: err } = await getSupabase().rpc("rpc_upsert_campaign", {
        p_id: v.id,
        p_campaign_no: v.campaign_no.trim(),
        p_name: (v.name || "(open campaign)").trim(),
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
      const newId = Number(data);
      if (onSaved) onSaved(newId);
      else router.replace(`/campaigns`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="團號">
          <div className={`${inputCls} bg-zinc-50 text-zinc-500 dark:bg-zinc-900 select-all`}>{v.campaign_no || "（自動產生）"}</div>
        </Field>
        <Field label="狀態">
          <select value={v.status} onChange={(e) => update("status", e.target.value as CampaignStatus)} className={inputCls}>
            {STATUS_OPT.map((o) => <option key={o.v} value={o.v}>{o.label}</option>)}
            {/* 若 campaign 已被下游推進到 ordered/... 也保留現值在選單中（disabled），避免顯示空白 */}
            {!STATUS_OPT.some((o) => o.v === v.status) && (
              <option value={v.status} disabled>
                {DOWNSTREAM_LABEL[v.status] ?? v.status}（系統推進中）
              </option>
            )}
          </select>
        </Field>

        <Field label="開團時間">
          <input type="datetime-local" value={toDtLocal(v.start_at)} onChange={(e) => update("start_at", e.target.value ? new Date(e.target.value).toISOString() : null)} className={inputCls} />
        </Field>
        <Field label="收單類型">
          <select value={v.close_type} onChange={(e) => update("close_type", e.target.value as CloseType)} className={inputCls}>
            <option value="regular">常規</option>
            <option value="fast">快團</option>
            <option value="limited">限量</option>
          </select>
        </Field>
        {(v.close_type === "limited" || v.close_type === "fast") && (
          <Field
            label={v.close_type === "fast" ? "總量上限（快團，可選）" : "總量上限（限量團）"}
            className="sm:col-span-2"
          >
            <input
              type="number"
              min="0"
              step="1"
              placeholder={
                v.close_type === "fast"
                  ? "留空則不限數量；填數字則達標自動關團"
                  : "整團總量上限數字"
              }
              value={v.total_cap_qty ?? ""}
              onChange={(e) => update("total_cap_qty", e.target.value ? Number(e.target.value) : null)}
              className={inputCls}
            />
          </Field>
        )}
      </div>

      <p className="text-xs text-zinc-500 dark:text-zinc-400">
        其他資訊（名稱、描述、收單時間、取貨截止 / 天數、總量上限）依商品自動帶入；如需調整請至商品編輯頁。
      </p>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>
      )}

      <div className="flex items-center gap-3">
        <button type="submit" disabled={saving} className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200">
          {saving ? "儲存中…" : submitLabel ?? (v.id ? "儲存" : "建立開團")}
        </button>
        <button type="button" onClick={() => onCancel ? onCancel() : router.push("/campaigns")} className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</button>
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

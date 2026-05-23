"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { useRole, isAdmin } from "@/lib/role";
import { CAMPAIGN_STATUS_LABEL, type CampaignStatus } from "@/lib/campaignStatus";

export type { CampaignStatus };
export type CloseType = "regular" | "fast" | "limited" | "food_train";

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

// 下游(系統推進)狀態的中文 label — 復用共用字典
const DOWNSTREAM_LABEL = CAMPAIGN_STATUS_LABEL;

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
  const role = useRole();
  const admin = isAdmin(role);
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
      // 快團一定要有 end_at,否則 PWA /shop/flash 顯示不出來
      if (v.close_type === "fast" && !v.end_at) {
        throw new Error("快團必須設定「收單時間」(在下方欄位輸入)");
      }

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

      // 團名由此表單直接編輯；描述 / 取貨截止 / 取貨天數 / 備註
      // 仍從商品 / RPC 自動帶入，UI 不編輯、保留原值送回。
      const wasOpen = (initial?.status ?? null) === "open";
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

      // 美食列車且 status 從非 open → open 時, 廣播推播給全 tenant 顧客
      // (失敗不阻擋儲存; 顯示警告但仍視為成功)
      if (v.close_type === "food_train" && v.status === "open" && !wasOpen) {
        try {
          await broadcastFoodTrainOpen({
            campaignId: newId,
            campaignName: (v.name || "美食列車").trim(),
          });
        } catch (broadcastErr) {
          console.error("food_train broadcast failed:", broadcastErr);
          setError(
            `儲存成功；但推播廣播失敗：${broadcastErr instanceof Error ? broadcastErr.message : String(broadcastErr)}`,
          );
        }
      }

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
        <Field label="團名" className="sm:col-span-2">
          <input
            type="text"
            value={v.name}
            onChange={(e) => update("name", e.target.value)}
            placeholder="顧客在 LIFF /shop 看到的開團標題"
            className={inputCls}
          />
        </Field>
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

        <Field label="收單類型">
          <select value={v.close_type} onChange={(e) => update("close_type", e.target.value as CloseType)} className={inputCls}>
            <option value="regular">常規</option>
            <option value="fast">快團</option>
            <option value="limited">限量</option>
            <option value="food_train">美食列車</option>
          </select>
          {v.close_type === "food_train" && v.status === "open" && (initial?.status ?? null) !== "open" && (
            <p className="mt-1 text-[11px] text-zinc-500 dark:text-zinc-400">
              儲存後將推播給所有未取消通知的顧客。
            </p>
          )}
        </Field>
        <Field
          label={v.close_type === "fast" ? "開團期間（開團 → 收單，快團必填收單）" : "開團期間（開團 → 收單）"}
          className="sm:col-span-2"
        >
          <div className="flex flex-col gap-2 sm:flex-row sm:items-start">
            <div className="flex flex-1 flex-col gap-1">
              <input
                type="datetime-local"
                value={toDtLocal(v.start_at)}
                onChange={(e) => {
                  const startIso = e.target.value ? new Date(e.target.value).toISOString() : null;
                  setV((prev) => {
                    const next: CampaignFormValues = { ...prev, start_at: startIso };
                    if (startIso && prev.end_at && new Date(prev.end_at) <= new Date(startIso)) {
                      next.end_at = null;
                    }
                    return next;
                  });
                }}
                className={inputCls}
                aria-label="開團時間"
              />
              <TimeSnapRow field="start_at" setV={setV} />
            </div>
            <span className="text-center text-xs text-zinc-400 sm:px-1 sm:pt-2">→</span>
            <div className="flex flex-1 flex-col gap-1">
              <input
                type="datetime-local"
                required={v.close_type === "fast"}
                value={toDtLocal(v.end_at)}
                min={toDtLocal(v.start_at) || undefined}
                onChange={(e) => update("end_at", e.target.value ? new Date(e.target.value).toISOString() : null)}
                className={inputCls}
                aria-label="收單時間"
              />
              <TimeSnapRow field="end_at" setV={setV} />
            </div>
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-1.5 text-[11px] text-zinc-500">
            <span>快速：</span>
            {QUICK_RANGES.map((q) => (
              <SpinButton
                key={q.label}
                type="button"
                onClick={() => applyQuickRange(setV, q.startOffsetH, q.durationH)}
                className="rounded-md border border-zinc-200 px-2 py-0.5 text-[11px] hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                {q.label}
              </SpinButton>
            ))}
            {v.start_at && v.end_at && (
              <span className="ml-2 text-zinc-400">
                時長 {formatDuration(v.start_at, v.end_at)}
              </span>
            )}
          </div>
          {v.close_type === "fast" && (
            <p className="mt-1 text-[11px] text-zinc-500 dark:text-zinc-400">
              快團需有明確收單時間，PWA 限時專區會顯示倒數計時。
            </p>
          )}
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
        描述、取貨截止 / 天數 在商品多選開團時設定；如需調整請至商品編輯頁。
        單一商品開團的團名會跟著商品名稱自動更新；多商品開團則以此處填的為準。
      </p>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>
      )}

      <div className="flex items-center gap-3">
        {admin && (
          <SpinButton type="submit" disabled={saving} className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200">
            {saving ? "儲存中…" : submitLabel ?? (v.id ? "儲存" : "建立開團")}
          </SpinButton>
        )}
        {role !== null && !admin && (
          <span className="text-xs text-zinc-500">僅管理員可儲存開團</span>
        )}
        <SpinButton type="button" onClick={() => onCancel ? onCancel() : router.push("/campaigns")} className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</SpinButton>
      </div>
    </form>
  );
}

const TIME_PRESETS: { label: string; hh: number; mm: number }[] = [
  { label: "00:00", hh: 0, mm: 0 },
  { label: "08:00", hh: 8, mm: 0 },
  { label: "12:00", hh: 12, mm: 0 },
  { label: "20:00", hh: 20, mm: 0 },
  { label: "23:59", hh: 23, mm: 59 },
];

function snapTime(
  setV: React.Dispatch<React.SetStateAction<CampaignFormValues>>,
  field: "start_at" | "end_at",
  hh: number,
  mm: number,
) {
  setV((prev) => {
    const base = prev[field] ? new Date(prev[field]!) : new Date();
    base.setHours(hh, mm, 0, 0);
    const iso = base.toISOString();
    const next: CampaignFormValues = { ...prev, [field]: iso };
    if (field === "start_at" && prev.end_at && new Date(prev.end_at) <= new Date(iso)) {
      next.end_at = null;
    }
    return next;
  });
}

function TimeSnapRow({
  field,
  setV,
}: {
  field: "start_at" | "end_at";
  setV: React.Dispatch<React.SetStateAction<CampaignFormValues>>;
}) {
  return (
    <div className="flex flex-wrap items-center gap-1">
      {TIME_PRESETS.map((t) => (
        <SpinButton
          key={t.label}
          type="button"
          onClick={() => snapTime(setV, field, t.hh, t.mm)}
          className="rounded border border-zinc-200 px-1.5 py-0.5 font-mono text-[11px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          {t.label}
        </SpinButton>
      ))}
    </div>
  );
}

function toDtLocal(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// 快速設定開團期間
// startOffsetH = 從現在偏移幾小時起算（0 = 立刻、24 = 明天）
// durationH    = 收單時間 = 開團時間 + N 小時
type QuickRange = { label: string; startOffsetH: number; durationH: number };
const QUICK_RANGES: QuickRange[] = [
  { label: "立即→3 天", startOffsetH: 0, durationH: 72 },
  { label: "立即→7 天", startOffsetH: 0, durationH: 168 },
  { label: "明早 8 點→3 天", startOffsetH: -1, durationH: 72 },
  { label: "明早 8 點→7 天", startOffsetH: -1, durationH: 168 },
];

function applyQuickRange(
  setV: React.Dispatch<React.SetStateAction<CampaignFormValues>>,
  startOffsetH: number,
  durationH: number,
) {
  let start: Date;
  if (startOffsetH === -1) {
    // 明早 8 點
    start = new Date();
    start.setDate(start.getDate() + 1);
    start.setHours(8, 0, 0, 0);
  } else {
    start = new Date();
    start.setMinutes(0, 0, 0);
    start.setHours(start.getHours() + startOffsetH);
  }
  const end = new Date(start.getTime() + durationH * 3600 * 1000);
  setV((prev) => ({ ...prev, start_at: start.toISOString(), end_at: end.toISOString() }));
}

function formatDuration(startIso: string, endIso: string): string {
  const ms = new Date(endIso).getTime() - new Date(startIso).getTime();
  if (ms <= 0) return "—";
  const hours = Math.round(ms / 3600 / 1000);
  if (hours < 24) return `${hours} 小時`;
  const days = Math.round(hours / 24);
  if (days <= 14) return `${days} 天`;
  return `${days} 天（約 ${Math.round(days / 7)} 週）`;
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

// 美食列車開團上架時, 廣播給全 tenant 顧客
async function broadcastFoodTrainOpen({
  campaignId,
  campaignName,
}: {
  campaignId: number;
  campaignName: string;
}): Promise<void> {
  const sb = getSupabase();
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error("尚未登入");
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!supabaseUrl) throw new Error("NEXT_PUBLIC_SUPABASE_URL 未設定");
  const resp = await fetch(`${supabaseUrl}/functions/v1/admin-notify`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
      broadcast: true,
      category: "food_train",
      title: "美食列車新團上架",
      message: campaignName,
      url: `/shop/c/${campaignId}`,
    }),
  });
  if (!resp.ok) {
    const detail = await resp.text().catch(() => "");
    throw new Error(`HTTP ${resp.status} ${detail}`.trim());
  }
}

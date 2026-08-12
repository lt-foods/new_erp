"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { CampaignThumb } from "@/components/CampaignThumb";
import { campaignCoverUrl, type CampaignCoverItem } from "@/lib/campaignCover";
import { useRole, isAdmin, type Role } from "@/lib/role";

type QuickStatus = "draft" | "open" | "closed" | "locked";
type CloseType = "regular" | "fast" | "limited" | "food_train";

type CampaignRow = {
  id: number;
  campaign_no: string;
  name: string;
  status: QuickStatus;
  close_type: CloseType;
  end_at: string | null;
  total_cap_qty: number | null;
  updated_at: string;
  cover_image_url: string | null;
  campaign_items: (CampaignCoverItem & { cap_qty?: number | string | null })[] | null;
};

type OrderRow = {
  campaign_id: number;
  status: string;
  order_kind: string | null;
  customer_order_items?: { qty: number | string; status: string }[];
};

const STATUS_LABEL: Record<QuickStatus, string> = {
  draft: "草稿",
  open: "開團中",
  closed: "已關團",
  locked: "已進採購",
};

const TYPE_LABEL: Record<CloseType, string> = {
  regular: "一般",
  fast: "限時",
  limited: "限量",
  food_train: "美食列車",
};

function canQuickControl(role: Role | null) {
  return isAdmin(role) || role === "hq_manager" || role === "assistant";
}

function toLocalInput(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function fromLocalInput(v: string): string | null {
  return v ? new Date(v).toISOString() : null;
}

function defaultEndAt(): string {
  const d = new Date();
  d.setHours(d.getHours() + 24, 0, 0, 0);
  return toLocalInput(d.toISOString());
}

function editableEndAt(iso: string | null): string {
  if (iso && new Date(iso).getTime() > Date.now()) return toLocalInput(iso);
  return defaultEndAt();
}

function formatDateTime(iso: string | null): string {
  if (!iso) return "未設定";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "未設定";
  return new Intl.DateTimeFormat("zh-TW", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(d);
}

function statusClass(status: QuickStatus): string {
  if (status === "open") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (status === "closed") return "bg-amber-50 text-amber-700 ring-amber-200";
  if (status === "locked") return "bg-rose-50 text-rose-700 ring-rose-200";
  return "bg-zinc-100 text-zinc-700 ring-zinc-200";
}

export default function QuickCampaignControlPage() {
  const role = useRole();
  const allowed = canQuickControl(role);
  const [rows, setRows] = useState<CampaignRow[]>([]);
  const [soldMap, setSoldMap] = useState<Map<number, number>>(new Map());
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [endAtDraft, setEndAtDraft] = useState<Record<number, string>>({});
  const [deltaDraft, setDeltaDraft] = useState<Record<number, string>>({});

  const visibleRows = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) =>
      `${r.campaign_no} ${r.name} ${TYPE_LABEL[r.close_type]}`.toLowerCase().includes(q),
    );
  }, [query, rows]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data, error: campaignErr } = await sb
        .from("group_buy_campaigns")
        .select("id, campaign_no, name, status, close_type, end_at, total_cap_qty, updated_at, cover_image_url, campaign_items(cap_qty, sort_order, sku:skus(product:products(images)))")
        .in("status", ["draft", "open", "closed", "locked"])
        .order("updated_at", { ascending: false })
        .limit(160);

      if (campaignErr) throw campaignErr;
      const campaigns = ((data ?? []) as unknown as CampaignRow[])
        .filter((r) =>
          r.close_type === "food_train"
          || r.close_type === "fast"
          || r.close_type === "limited"
          || Number(r.total_cap_qty ?? 0) > 0
          || (r.campaign_items ?? []).some((item) => Number(item.cap_qty ?? 0) > 0)
        )
        .slice(0, 80);
      const ids = campaigns.map((r) => r.id);
      const nextSold = new Map<number, number>();

      if (ids.length > 0) {
        const { data: orderRows, error: orderErr } = await sb
          .from("customer_orders")
          .select("campaign_id, status, order_kind, customer_order_items(qty, status)")
          .in("campaign_id", ids);
        if (orderErr) throw orderErr;

        for (const order of ((orderRows ?? []) as OrderRow[])) {
          if (["cancelled", "expired", "transferred_out"].includes(order.status)) continue;
          if ((order.order_kind ?? "normal") !== "normal") continue;
          const qty = (order.customer_order_items ?? [])
            .filter((item) => !["cancelled", "expired"].includes(item.status))
            .reduce((sum, item) => sum + Number(item.qty ?? 0), 0);
          nextSold.set(order.campaign_id, (nextSold.get(order.campaign_id) ?? 0) + qty);
        }
      }

      setRows(campaigns);
      setSoldMap(nextSold);
      setEndAtDraft(Object.fromEntries(campaigns.map((r) => [r.id, editableEndAt(r.end_at)])));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => { void load(); }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function quickUpdate(
    row: CampaignRow,
    patch: { status?: "open"; endAt?: string | null; delta?: number | null },
    successText: string,
  ) {
    if (!allowed || busyId) return;
    setBusyId(row.id);
    setError(null);
    setNotice(null);
    try {
      const { data, error: rpcErr } = await getSupabase().rpc("rpc_quick_update_campaign_control", {
        p_campaign_id: row.id,
        p_status: patch.status ?? null,
        p_end_at: patch.endAt ?? null,
        p_total_cap_qty_delta: patch.delta ?? null,
      });
      if (rpcErr) throw rpcErr;
      const updated = Array.isArray(data) ? data[0] : data;
      setRows((cur) =>
        cur.map((r) =>
          r.id === row.id
            ? {
                ...r,
                status: (updated?.status ?? r.status) as QuickStatus,
                end_at: updated?.end_at ?? r.end_at,
                total_cap_qty:
                  updated?.total_cap_qty != null ? Number(updated.total_cap_qty) : r.total_cap_qty,
              }
            : r,
        ),
      );
      if (updated?.sold_qty != null) {
        setSoldMap((cur) => new Map(cur).set(row.id, Number(updated.sold_qty)));
      }
      setDeltaDraft((cur) => ({ ...cur, [row.id]: "" }));
      setNotice(successText);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyId(null);
    }
  }

  async function closeCampaign(row: CampaignRow) {
    if (!allowed || busyId) return;
    if (!confirm(`確定結單「${row.name}」？`)) return;
    setBusyId(row.id);
    setError(null);
    setNotice(null);
    try {
      const sb = getSupabase();
      const { data: userData } = await sb.auth.getUser();
      const { error: rpcErr } = await sb.rpc("rpc_close_campaign", {
        p_campaign_id: row.id,
        p_operator: userData.user?.id ?? null,
      });
      if (rpcErr) throw rpcErr;
      setRows((cur) => cur.map((r) => (r.id === row.id ? { ...r, status: "closed" } : r)));
      setNotice(`${row.name} 已結單`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyId(null);
    }
  }

  function setEndAt(row: CampaignRow, hours: number) {
    const base = row.end_at && new Date(row.end_at).getTime() > new Date().getTime()
      ? new Date(row.end_at)
      : new Date();
    base.setHours(base.getHours() + hours, 0, 0, 0);
    const local = toLocalInput(base.toISOString());
    setEndAtDraft((cur) => ({ ...cur, [row.id]: local }));
    return fromLocalInput(local);
  }

  return (
    <div className="min-h-full bg-zinc-50 px-3 py-4 dark:bg-zinc-950 sm:px-6">
      <div className="mx-auto flex max-w-3xl flex-col gap-4">
        <header className="flex flex-col gap-3 rounded-md border border-zinc-200 bg-white p-4 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex items-start justify-between gap-3">
            <div>
              <p className="text-xs font-medium text-zinc-500">手機快速入口</p>
              <h1 className="text-xl font-semibold text-zinc-950 dark:text-zinc-50">
                美食列車 / 限時限量
              </h1>
            </div>
            <Link
              href="/campaigns"
              className="shrink-0 rounded-md border border-zinc-300 px-3 py-2 text-sm text-zinc-700 dark:border-zinc-700 dark:text-zinc-200"
            >
              回團購
            </Link>
          </div>
          <div className="flex gap-2">
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="搜尋團名"
              className="min-h-11 flex-1 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-zinc-900 dark:border-zinc-700 dark:bg-zinc-950"
            />
            <SpinButton
              type="button"
              onClick={load}
              loading={loading}
              className="min-h-11 rounded-md bg-zinc-900 px-4 text-sm font-medium text-white dark:bg-zinc-100 dark:text-zinc-950"
            >
              重整
            </SpinButton>
          </div>
        </header>

        {!allowed && role !== null && (
          <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
            這個入口限總部、管理員與開團助理使用。
          </div>
        )}

        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
            {error}
          </div>
        )}

        {notice && (
          <div className="rounded-md border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-700 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200">
            {notice}
          </div>
        )}

        {loading && rows.length === 0 ? (
          <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            載入中...
          </div>
        ) : visibleRows.length === 0 ? (
          <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            沒有可快速控制的團。
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            {visibleRows.map((row) => {
              const sold = soldMap.get(row.id) ?? 0;
              const cap = row.total_cap_qty;
              const remain = cap == null ? null : Math.max(0, cap - sold);
              const locked = row.status === "locked";
              const endInput = endAtDraft[row.id] ?? toLocalInput(row.end_at) ?? defaultEndAt();
              const delta = Number(deltaDraft[row.id] ?? 0);

              return (
                <section
                  key={row.id}
                  className="rounded-md border border-zinc-200 bg-white p-4 shadow-sm dark:border-zinc-800 dark:bg-zinc-900"
                >
                  <div className="flex gap-3">
                    <CampaignThumb
                      url={campaignCoverUrl(row.cover_image_url, row.campaign_items)}
                      name={row.name}
                    />
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className={`rounded-full px-2 py-1 text-xs ring-1 ${statusClass(row.status)}`}>
                          {STATUS_LABEL[row.status]}
                        </span>
                        <span className="rounded-full bg-zinc-100 px-2 py-1 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                          {TYPE_LABEL[row.close_type]}
                        </span>
                      </div>
                      <h2 className="mt-2 break-words text-lg font-semibold leading-snug text-zinc-950 dark:text-zinc-50">
                        {row.name}
                      </h2>
                      <p className="mt-1 text-sm text-zinc-500">
                        結束 {formatDateTime(row.end_at)} ・ 已訂 {sold}
                        {cap != null ? ` / 上限 ${cap} / 剩 ${remain}` : " / 不限量"}
                      </p>
                    </div>
                  </div>

                  <div className="mt-4 grid gap-3">
                    <label className="grid gap-1 text-sm">
                      <span className="font-medium text-zinc-700 dark:text-zinc-200">結束時間</span>
                      <input
                        type="datetime-local"
                        value={endInput}
                        onChange={(e) => setEndAtDraft((cur) => ({ ...cur, [row.id]: e.target.value }))}
                        disabled={locked || !allowed}
                        className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-zinc-900 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                      />
                    </label>

                    <div className="grid grid-cols-3 gap-2">
                      {[
                        ["+1小時", 1],
                        ["+3小時", 3],
                        ["+1天", 24],
                      ].map(([label, hours]) => (
                        <SpinButton
                          key={String(label)}
                          type="button"
                          disabled={locked || !allowed || busyId === row.id}
                          onClick={async () => {
                            const iso = setEndAt(row, Number(hours));
                            if (row.status === "closed") {
                              setNotice(`${row.name} 已調整重開時間，按重開才會開團`);
                              return;
                            }
                            await quickUpdate(row, { endAt: iso }, `${row.name} 已延長`);
                          }}
                          className="min-h-11 rounded-md border border-zinc-300 text-sm font-medium disabled:opacity-50 dark:border-zinc-700"
                        >
                          {label}
                        </SpinButton>
                      ))}
                    </div>

                    <div className="grid grid-cols-[1fr_auto] gap-2">
                      <input
                        type="number"
                        min="1"
                        step="1"
                        value={deltaDraft[row.id] ?? ""}
                        onChange={(e) => setDeltaDraft((cur) => ({ ...cur, [row.id]: e.target.value }))}
                        placeholder="增加數量"
                        disabled={locked || !allowed}
                        className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-zinc-900 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                      />
                      <SpinButton
                        type="button"
                        disabled={locked || !allowed || busyId === row.id || !Number.isFinite(delta) || delta <= 0}
                        onClick={() => quickUpdate(row, { delta }, `${row.name} 已加量 ${delta}`)}
                        className="min-h-11 rounded-md bg-zinc-900 px-4 text-sm font-medium text-white disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-950"
                      >
                        加量
                      </SpinButton>
                    </div>

                    <div className="grid grid-cols-2 gap-2">
                      {row.status === "open" ? (
                        <SpinButton
                          type="button"
                          disabled={!allowed || busyId === row.id}
                          onClick={() => closeCampaign(row)}
                          className="min-h-12 rounded-md border border-amber-300 bg-amber-50 text-base font-semibold text-amber-800 disabled:opacity-50 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200"
                        >
                          結單
                        </SpinButton>
                      ) : (
                        <SpinButton
                          type="button"
                          disabled={locked || !allowed || busyId === row.id}
                          onClick={() =>
                            quickUpdate(row, { status: "open", endAt: fromLocalInput(endInput) }, `${row.name} 已開團`)
                          }
                          className="min-h-12 rounded-md bg-emerald-600 text-base font-semibold text-white disabled:opacity-50"
                        >
                          {row.status === "closed" ? "重開" : "開團"}
                        </SpinButton>
                      )}
                      <Link
                        href={`/campaigns/order-entry?id=${row.id}`}
                        aria-disabled={locked}
                        className={`flex min-h-12 items-center justify-center rounded-md border border-zinc-300 text-base font-semibold dark:border-zinc-700 ${
                          locked
                            ? "pointer-events-none text-zinc-400 opacity-50 dark:text-zinc-600"
                            : "text-zinc-700 dark:text-zinc-200"
                        }`}
                      >
                        補單
                      </Link>
                    </div>
                  </div>
                </section>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

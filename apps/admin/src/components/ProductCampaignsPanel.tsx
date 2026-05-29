"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { Modal } from "@/components/Modal";
import { CreateCampaignModal, type SelectedProduct } from "@/components/CreateCampaignModal";
import {
  CAMPAIGN_STATUS_LABEL,
  CAMPAIGN_STATUS_BADGE,
  type CampaignStatus,
} from "@/lib/campaignStatus";

type CampaignRow = {
  id: number;
  campaign_no: string;
  name: string;
  status: CampaignStatus;
  start_at: string | null;
  end_at: string | null;
};

const STATUS_LABEL = CAMPAIGN_STATUS_LABEL;
const STATUS_BADGE = CAMPAIGN_STATUS_BADGE;

function fmtDate(s: string | null) {
  return s ? new Date(s).toLocaleDateString("zh-TW") : "—";
}

// 開團狀態機是單向的（draft →open→ closed →cancelled，無 open→draft / closed→open）。
// 故 switch 僅 draft / open 可切：draft(關)→開團(open)、open(開)→收單(closed)。
// 其餘狀態鎖定（已收單不可逆、已取消、或已進採購/到貨流程）。
type ToggleInfo =
  | { kind: "off" }
  | { kind: "on" }
  | { kind: "locked"; checked: boolean; reason: string };

function toggleInfo(status: CampaignStatus): ToggleInfo {
  if (status === "open") return { kind: "on" };
  if (status === "draft") return { kind: "off" };
  if (status === "closed") return { kind: "locked", checked: false, reason: "已收單，無法切回開團中" };
  if (status === "cancelled") return { kind: "locked", checked: false, reason: "已取消" };
  return { kind: "locked", checked: true, reason: "已進入採購／到貨流程，無法切換" };
}

export function ProductCampaignsPanel({ productId }: { productId: number }) {
  const [rows, setRows] = useState<CampaignRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [product, setProduct] = useState<SelectedProduct | null>(null);
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    setError(null);
    const sb = getSupabase();
    const { data: skuRows, error: skuErr } = await sb
      .from("skus").select("id").eq("product_id", productId);
    if (skuErr) { setError(skuErr.message); setRows([]); return; }
    const skuIds = (skuRows ?? []).map((s) => s.id as number);
    if (skuIds.length === 0) { setRows([]); return; }

    const { data: ciRows, error: ciErr } = await sb
      .from("campaign_items").select("campaign_id").in("sku_id", skuIds);
    if (ciErr) { setError(ciErr.message); setRows([]); return; }
    const campaignIds = Array.from(
      new Set((ciRows ?? []).map((c) => c.campaign_id as number))
    );
    if (campaignIds.length === 0) { setRows([]); return; }

    const { data: cRows, error: cErr } = await sb
      .from("group_buy_campaigns")
      .select("id, campaign_no, name, status, start_at, end_at")
      .in("id", campaignIds)
      .neq("campaign_no", "__INTERNAL_RESTOCK__")
      .order("start_at", { ascending: false, nullsFirst: false })
      .order("id", { ascending: false });
    if (cErr) { setError(cErr.message); setRows([]); return; }
    setRows((cRows ?? []) as CampaignRow[]);
  }, [productId]);

  useEffect(() => { setRows(null); load(); }, [load]);

  // 撈商品基本資料（團名稱預設值、依溫層算取貨天數）給建團 modal 用
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await getSupabase()
        .from("products")
        .select("id, name, storage_type")
        .eq("id", productId)
        .maybeSingle();
      if (cancelled || !data) return;
      const d = data as { id: number; name: string; storage_type: SelectedProduct["storage_type"] };
      setProduct({ id: d.id, name: d.name, storage_type: d.storage_type });
    })();
    return () => { cancelled = true; };
  }, [productId]);

  async function setStatus(row: CampaignRow, target: "open" | "closed") {
    setError(null);
    setNote(null);
    const confirmMsg =
      target === "open"
        ? `確定要開團「${row.name}」？開團後顧客即可下單。`
        : `確定要將「${row.name}」收單？收單後無法再轉回開團中。`;
    if (!window.confirm(confirmMsg)) return;
    const { data, error: err } = await getSupabase().rpc("rpc_bulk_set_campaign_status", {
      p_ids: [row.id],
      p_status: target,
    });
    if (err) { setError(err.message); return; }
    const changed = typeof data === "number" ? data : 0;
    if (changed === 0) {
      setNote(
        target === "open"
          ? `「${row.name}」未開團（可能尚無商品品項或不允許的狀態轉換）`
          : `「${row.name}」狀態未變更`,
      );
    }
    await load();
  }

  return (
    <section className="space-y-2">
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-sm font-semibold">關聯開團</h3>
        <SpinButton
          type="button"
          onClick={() => setCreating(true)}
          disabled={!product}
          className="rounded-md bg-green-700 px-3 py-1.5 text-xs font-medium text-white hover:bg-green-600 disabled:opacity-50"
        >
          建立新開團
        </SpinButton>
      </div>
      <p className="text-xs text-zinc-500">
        含此商品任一規格的開團。開關：開＝開團中（顧客可下單），關＝收單（不可逆）。
      </p>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}
      {note && (
        <div className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300">
          {note}
        </div>
      )}

      {rows === null ? (
        <div className="flex justify-center py-6 text-zinc-400">
          <svg className="h-5 w-5 animate-spin" viewBox="0 0 24 24" fill="none" aria-hidden>
            <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" className="opacity-25" />
            <path d="M4 12a8 8 0 0 1 8-8" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
          </svg>
        </div>
      ) : rows.length === 0 ? (
        <div className="rounded-md border border-dashed border-zinc-300 px-3 py-6 text-center text-sm text-zinc-500 dark:border-zinc-700">
          此商品尚無關聯開團
        </div>
      ) : (
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr className="text-left text-xs font-medium uppercase tracking-wide text-zinc-500">
                <th className="px-3 py-2">團名</th>
                <th className="px-3 py-2">狀態</th>
                <th className="px-3 py-2">開團 / 收單</th>
                <th className="px-3 py-2 text-right">開團開關</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {rows.map((r) => {
                const info = toggleInfo(r.status);
                const checked =
                  info.kind === "on" ? true : info.kind === "off" ? false : info.checked;
                const locked = info.kind === "locked";
                return (
                  <tr key={r.id}>
                    <td className="px-3 py-2">{r.name}</td>
                    <td className="px-3 py-2">
                      <span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_BADGE[r.status]}`}>
                        {STATUS_LABEL[r.status]}
                      </span>
                    </td>
                    <td className="px-3 py-2 text-xs text-zinc-500">
                      {fmtDate(r.start_at)} → {fmtDate(r.end_at)}
                    </td>
                    <td className="px-3 py-2 text-right">
                      <SwitchToggle
                        checked={checked}
                        disabled={locked}
                        title={locked ? info.reason : checked ? "點擊收單" : "點擊開團"}
                        onToggle={() => setStatus(r, info.kind === "off" ? "open" : "closed")}
                      />
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <Modal
        open={creating && !!product}
        onClose={() => setCreating(false)}
        title="建立開團"
        maxWidth="max-w-2xl"
      >
        {product && (
          <CreateCampaignModal
            products={[product]}
            onClose={() => setCreating(false)}
            onCreated={() => {
              setCreating(false);
              setNote(null);
              load();
            }}
          />
        )}
      </Modal>
    </section>
  );
}

function SwitchToggle({
  checked, disabled, title, onToggle,
}: {
  checked: boolean;
  disabled?: boolean;
  title?: string;
  onToggle: () => unknown;
}) {
  return (
    <SpinButton
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      title={title}
      onClick={onToggle}
      className={`inline-flex h-6 w-11 items-center rounded-full align-middle transition-colors disabled:cursor-not-allowed disabled:opacity-50 ${
        checked ? "bg-green-600" : "bg-zinc-300 dark:bg-zinc-700"
      }`}
    >
      <span
        className={`inline-block h-5 w-5 transform rounded-full bg-white shadow transition-transform ${
          checked ? "translate-x-[22px]" : "translate-x-[2px]"
        }`}
      />
    </SpinButton>
  );
}

"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

// 庫存總覽「依商品新增庫存」：對某倉別某品項寫 manual_adjust(+N)。
// 主要用途：店內現貨是帳外的（自購 / 贈品 / 盤盈沒入帳）時先把帳補上，
// 才能開「庫存減抵單」把待補貨的訂單用現貨交貨。見 20260805000170 migration。

type SkuHit = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  base_unit: string | null;
};

export function AddStockModal({
  locations,
  defaultLocationId,
  locked,
  onClose,
  onSaved,
}: {
  locations: { id: number; label: string }[];
  defaultLocationId: string; // 預設倉別（"" = 未選）
  locked: boolean; // 分店帳號鎖定：不能換倉別
  onClose: () => void;
  onSaved: () => void;
}) {
  // 分店帳號：清單已被呼叫端過濾成只有自己店，直接選它（免得停在「請選倉別」）
  const [locationId, setLocationId] = useState<string>(
    defaultLocationId || (locations.length === 1 ? String(locations[0].id) : ""),
  );
  const [search, setSearch] = useState("");
  const [hits, setHits] = useState<SkuHit[]>([]);
  const [searching, setSearching] = useState(false);
  const [sku, setSku] = useState<SkuHit | null>(null);
  const [qty, setQty] = useState(1);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // 商品搜尋（sku_code / 品名 / 規格），debounce 300ms
  useEffect(() => {
    const q = search.replace(/[,()%*]/g, " ").trim();
    if (!q || sku) {
      setHits([]);
      return;
    }
    let cancelled = false;
    setSearching(true);
    const t = setTimeout(async () => {
      const { data } = await getSupabase()
        .from("skus")
        .select("id, sku_code, product_name, variant_name, base_unit")
        .or(`sku_code.ilike.%${q}%,product_name.ilike.%${q}%,variant_name.ilike.%${q}%`)
        .order("id", { ascending: false })
        .limit(20);
      if (!cancelled) {
        setHits((data as SkuHit[]) ?? []);
        setSearching(false);
      }
    }, 300);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [search, sku]);

  const skuLabel = (s: SkuHit) =>
    `${s.product_name ?? ""}${s.variant_name ? ` / ${s.variant_name}` : ""}`.trim() || `#${s.id}`;

  async function save() {
    if (!sku || !locationId || qty <= 0) return;
    const locName = locations.find((l) => String(l.id) === locationId)?.label ?? locationId;
    if (
      !confirm(
        `在「${locName}」新增庫存？\n\n${skuLabel(sku)}\n數量 +${qty}\n\n` +
          `會寫一筆「手動調整」庫存異動（不影響均成本）。`,
      )
    )
      return;
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { data: res, error: e } = await sb.rpc("rpc_add_stock_by_product", {
        p_location_id: Number(locationId),
        p_sku_id: sku.id,
        p_qty: qty,
        p_reason: reason.trim() || null,
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as { on_hand?: number };
      alert(`✅ 已新增庫存 +${qty}。${skuLabel(sku)} 目前在庫 ${Number(r.on_hand ?? 0)} 件。`);
      onSaved();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open onClose={onClose} title="＋ 新增庫存（依商品）" maxWidth="max-w-lg">
      <div className="space-y-3 text-sm">
        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">倉別</span>
          <select
            value={locationId}
            onChange={(e) => setLocationId(e.target.value)}
            disabled={locked}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 disabled:opacity-70 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 請選倉別 —</option>
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.label}
              </option>
            ))}
          </select>
        </label>

        <div>
          <span className="mb-1 block text-xs text-zinc-500">商品</span>
          {sku ? (
            <div className="flex items-center gap-2 rounded-md border border-emerald-300 bg-emerald-50 px-3 py-2 dark:border-emerald-800 dark:bg-emerald-950/40">
              <span className="min-w-0 flex-1">
                <span className="font-mono text-xs text-zinc-500">{sku.sku_code}</span>{" "}
                {skuLabel(sku)}
              </span>
              <SpinButton
                onClick={() => {
                  setSku(null);
                  setSearch("");
                }}
                className="shrink-0 text-xs text-zinc-500 underline"
              >
                重選
              </SpinButton>
            </div>
          ) : (
            <>
              <input
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder="🔍 搜尋 商品名 / 編號 / 規格…"
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
              />
              {(hits.length > 0 || searching) && (
                <div className="mt-1 max-h-56 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-700">
                  {searching && hits.length === 0 && (
                    <div className="px-3 py-2 text-xs text-zinc-500">搜尋中…</div>
                  )}
                  {hits.map((s) => (
                    <SpinButton
                      key={s.id}
                      onClick={() => setSku(s)}
                      className="block w-full border-b border-zinc-100 px-3 py-2 text-left last:border-b-0 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
                    >
                      <span className="font-mono text-xs text-zinc-500">{s.sku_code}</span>{" "}
                      {skuLabel(s)}
                    </SpinButton>
                  ))}
                </div>
              )}
            </>
          )}
        </div>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">數量</span>
          <input
            type="number"
            min={1}
            value={qty}
            onChange={(e) => {
              const v = Math.floor(Number(e.target.value));
              setQty(Number.isFinite(v) ? Math.max(0, v) : 0);
            }}
            className="w-28 rounded-md border border-zinc-300 bg-white px-3 py-2 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">原因（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="例：店內現貨入帳、盤盈…"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="flex items-center justify-end gap-2 pt-1">
          <SpinButton
            onClick={onClose}
            className="rounded-md border border-zinc-300 px-4 py-2 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={save}
            disabled={busy || !sku || !locationId || qty <= 0}
            className="rounded-md bg-emerald-600 px-5 py-2 font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            {busy ? "處理中…" : "新增庫存"}
          </SpinButton>
        </div>
        <p className="text-[11px] text-zinc-500">
          用途：店內現貨還沒入帳（自購、贈品、盤盈）時先補帳，才能開「庫存減抵單」
          把待補貨的訂單用現貨交貨。會寫一筆可追溯的「手動調整」異動。
        </p>
      </div>
    </Modal>
  );
}

export default AddStockModal;

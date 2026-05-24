"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { fetchAllPaginated } from "@/lib/fetchAllPaginated";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";
import { useRole, isAdmin } from "@/lib/role";

type Row = {
  id: number;
  sku_id: number;
  sku_code: string;
  sku_status: string;
  product_id: number;
  product_name: string | null;
  variant_name: string | null;
  unit_price: number;
  cap_qty: number | null;
  sort_order: number;
  notes: string | null;
  locked_at: string | null;
};

type ResyncPreview = {
  campaign_no: string;
  name_before: string;
  name_after: string;
  name_changed: boolean;
  items: { sku_id: number; sku_code: string; old_price: number; new_price: number }[];
  items_repriced: number;
  skus_added: number;
  pending_orders: number;
  pending_order_lines: number;
  amount_before: number;
  amount_after: number;
};

export function CampaignItemsTable({
  campaignId,
  status,
  onResynced,
}: {
  campaignId: number;
  status?: string;
  onResynced?: () => void;
}) {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<ResyncPreview | null>(null);
  const [resyncErr, setResyncErr] = useState<string | null>(null);
  const role = useRole();
  // 僅管理員（owner/admin）可重新同步：對齊 RPC server-side gate
  const canResync = (status === "draft" || status === "open") && isAdmin(role);
  // 店長/店員不能跳轉到商品編輯頁
  const isStoreLevel = role === "store_manager" || role === "store_staff";

  const reload = async () => {
    // products.name 是 source of truth；skus.product_name 是 denorm 可能過期、不用它
    // 過濾 sku.status='discontinued'：已下架的規格不該在開團裡（draft 由 trigger 清掉，
    // open / closed 留 row 不破壞訂單，但 UI 不顯示）
    // AUDIT #26: 防禦性改 fetchAllPaginated。實務上單一團 SKU <100,
    // 但若業務改變(批發、套組)突破 1000 也不會被截。safetyCap 2000 撞到 throw。
    try {
      const data = await fetchAllPaginated<{
        id: number; sku_id: number; unit_price: number; cap_qty: number | null;
        sort_order: number; notes: string | null; locked_at: string | null;
        skus: { id: number; sku_code: string; status: string; product_id: number; variant_name: string | null;
          products: { id: number; name: string };
        };
      }>(({ from, to }) =>
        getSupabase()
          .from("campaign_items")
          .select("id, sku_id, unit_price, cap_qty, sort_order, notes, locked_at, skus!inner(id, sku_code, status, product_id, variant_name, products!inner(id, name))")
          .eq("campaign_id", campaignId)
          .order("sort_order", { ascending: true })
          .order("id", { ascending: true })
          .range(from, to),
        { label: "CampaignItemsTable", safetyCap: 2000 },
      );
      setRows(
        (data as unknown as Array<{
        id: number; sku_id: number; unit_price: number; cap_qty: number | null;
        sort_order: number; notes: string | null; locked_at: string | null;
        skus: { id: number; sku_code: string; status: string; product_id: number; variant_name: string | null;
          products: { id: number; name: string };
        };
      }>)
        // 已下架（discontinued）規格不該顯示在開團裡。draft 開團由 trigger 清掉、
        // open/closed 仍保留 row（避免破壞既有訂單），但 UI 不顯示。
        .filter((r) => r.skus.status !== "discontinued")
        .map((r) => ({
          id: r.id, sku_id: r.sku_id, sku_code: r.skus.sku_code,
          sku_status: r.skus.status,
          product_id: r.skus.product_id,
          product_name: r.skus.products?.name ?? null,
          variant_name: r.skus.variant_name,
          unit_price: Number(r.unit_price), cap_qty: r.cap_qty != null ? Number(r.cap_qty) : null,
          sort_order: r.sort_order, notes: r.notes, locked_at: r.locked_at,
        }))
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  useEffect(() => { reload(); }, [campaignId]);

  const runPreview = async () => {
    setResyncErr(null);
    const { data, error: err } = await getSupabase().rpc(
      "rpc_resync_campaign_from_product",
      { p_campaign_id: campaignId, p_dry_run: true },
    );
    if (err) { setResyncErr(translateRpcError(err)); return; }
    setPreview(data as ResyncPreview);
  };

  const runApply = async () => {
    setResyncErr(null);
    const { error: err } = await getSupabase().rpc(
      "rpc_resync_campaign_from_product",
      { p_campaign_id: campaignId, p_dry_run: false },
    );
    if (err) { setResyncErr(translateRpcError(err)); return; }
    setPreview(null);
    await reload();
    onResynced?.();
  };

  const hasChanges = !!preview && (
    preview.name_changed ||
    preview.items_repriced > 0 ||
    preview.skus_added > 0 ||
    preview.pending_order_lines > 0
  );

  const anyLocked = (rows ?? []).some((r) => !!r.locked_at);
  const earliestLock = (rows ?? [])
    .map((r) => r.locked_at)
    .filter((t): t is string => !!t)
    .sort()[0];

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-baseline gap-2">
          <h2 className="text-base font-semibold">商品明細</h2>
          {anyLocked && earliestLock && (
            <span
              title="開團（status=open）後活動單價已 snapshot 鎖定，零售價變動不再影響此團"
              className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-900 dark:text-amber-200"
            >
              🔒 已鎖定 {new Date(earliestLock).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
            </span>
          )}
        </div>
        <div className="flex items-center gap-3">
          {canResync && (
            <SpinButton
              onClick={runPreview}
              title="從商品現行零售價重新同步開團名稱、單價，並回填本團『待確認』訂單金額"
              className="rounded-md border border-blue-300 px-2.5 py-1 text-xs font-medium text-blue-700 hover:bg-blue-50 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950"
            >
              重新同步商品/價格
            </SpinButton>
          )}
          <span className="text-xs text-zinc-500">{rows?.length ?? 0} 項</span>
        </div>
      </div>

      {resyncErr && (
        <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{resyncErr}</div>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>規格</Th><Th>名稱</Th><Th className="text-right">單價</Th><Th className="text-right">量上限</Th><Th>鎖定時間</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={5} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">尚無商品</td></tr>
            ) : rows.map((r) => (
              <tr key={r.id}>
                <Td className="font-mono">
                  {isStoreLevel ? (
                    <span>{r.sku_code}</span>
                  ) : (
                    <Link
                      href={`/products?id=${r.product_id}`}
                      className="text-blue-600 hover:underline dark:text-blue-400"
                      title="點此跳轉到商品編輯頁"
                    >
                      {r.sku_code}
                    </Link>
                  )}
                </Td>
                <Td>
                  <div className="text-xs text-zinc-500">{r.product_name ?? "—"}</div>
                  {r.variant_name && (
                    <div className="text-base font-bold text-zinc-900 dark:text-zinc-100">
                      {r.variant_name}
                    </div>
                  )}
                </Td>
                <Td className="text-right font-mono">${r.unit_price}</Td>
                <Td className="text-right text-xs text-zinc-500">{r.cap_qty ?? "—"}</Td>
                <Td className="text-xs text-zinc-500">
                  {r.locked_at ? new Date(r.locked_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" }) : "—"}
                </Td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <Modal
        open={!!preview}
        onClose={() => setPreview(null)}
        title="重新同步商品/價格 — 預覽"
        maxWidth="max-w-2xl"
      >
        {preview && (
          <div className="space-y-4 text-sm">
            {resyncErr && (
              <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{resyncErr}</div>
            )}
            <p className="text-xs text-zinc-500">
              從商品現行零售價同步開團 #{preview.campaign_no}。確認前不會寫入任何資料。
            </p>

            {preview.name_changed && (
              <div className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                <div className="mb-1 text-xs font-medium text-zinc-500">開團名稱</div>
                <div className="line-through text-zinc-400">{preview.name_before}</div>
                <div className="font-semibold">{preview.name_after}</div>
              </div>
            )}

            {preview.items.length > 0 && (
              <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
                <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                  <thead className="bg-zinc-50 dark:bg-zinc-900">
                    <tr>
                      <Th>規格</Th>
                      <Th className="text-right">原單價</Th>
                      <Th className="text-right">新單價</Th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                    {preview.items.map((it) => (
                      <tr key={it.sku_id}>
                        <Td className="font-mono">{it.sku_code}</Td>
                        <Td className="text-right font-mono text-zinc-400 line-through">
                          ${Number(it.old_price)}
                        </Td>
                        <Td className="text-right font-mono font-semibold">
                          ${Number(it.new_price)}
                        </Td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}

            <ul className="space-y-1 text-xs text-zinc-600 dark:text-zinc-300">
              <li>商品明細重新定價：<b>{preview.items_repriced}</b> 項</li>
              <li>補上缺漏的 active 規格：<b>{preview.skus_added}</b> 項</li>
              <li>
                回填「待確認」訂單：<b>{preview.pending_orders}</b> 筆訂單／
                <b>{preview.pending_order_lines}</b> 項明細
              </li>
              <li>
                待確認訂單金額：
                <span className="font-mono text-zinc-400 line-through">
                  ${Number(preview.amount_before).toLocaleString()}
                </span>
                {" → "}
                <span className="font-mono font-semibold">
                  ${Number(preview.amount_after).toLocaleString()}
                </span>
              </li>
            </ul>

            {!hasChanges && (
              <div className="rounded-md border border-emerald-200 bg-emerald-50 p-2 text-xs text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
                已是最新，無需變更。
              </div>
            )}

            <div className="flex justify-end gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
              <SpinButton
                onClick={() => setPreview(null)}
                className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                取消
              </SpinButton>
              {hasChanges && (
                <SpinButton
                  onClick={runApply}
                  className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700"
                >
                  確認同步
                </SpinButton>
              )}
            </div>
          </div>
        )}
      </Modal>
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-2 ${className}`}>{children}</td>;
}

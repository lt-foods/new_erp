"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
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
  stockout_at: string | null;
  // 贈品（20260819000000）：促銷活動送的東西，單價 0 是刻意的 →
  // 該團所有 $0 訂單品項免除取貨零元守衛，且不會被「重新同步商品/價格」蓋回零售價
  is_gift: boolean;
  gift_reason: string | null;
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
  // 贈品設定不看開團狀態：促銷團結單之後才開始取貨，被零元守衛擋下時多半已經
  // closed/ordered —— 只放行 draft/open 等於這個功能在最需要的時候用不了。
  const canSetGift = isAdmin(role);
  // 店長/店員不能跳轉到商品編輯頁
  const isStoreLevel = role === "store_manager" || role === "store_staff";

  const reload = async () => {
    // products.name 是 source of truth；skus.product_name 是 denorm 可能過期、不用它
    // 過濾 sku.status='discontinued'：已下架的規格不該在開團裡（draft 由 trigger 清掉，
    // open / closed 留 row 不破壞訂單，但 UI 不顯示）
    const { data, error: err } = await getSupabase()
      .from("campaign_items")
      .select("id, sku_id, unit_price, cap_qty, sort_order, notes, locked_at, stockout_at, is_gift, gift_reason, skus!inner(id, sku_code, status, product_id, variant_name, products!inner(id, name))")
      .eq("campaign_id", campaignId)
      .order("sort_order");
    if (err) { setError(err.message); return; }
    setRows(
      (data as unknown as Array<{
        id: number; sku_id: number; unit_price: number; cap_qty: number | null;
        sort_order: number; notes: string | null; locked_at: string | null;
        stockout_at: string | null; is_gift: boolean | null; gift_reason: string | null;
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
          stockout_at: r.stockout_at,
          is_gift: !!r.is_gift, gift_reason: r.gift_reason,
        }))
    );
  };

  useEffect(() => { reload(); }, [campaignId]);

  // 把開團商品標成／取消標成贈品。**只適用「這一項所有人都是送的」**：
  // 標下去單價會設成 0，之後新建的訂單那一項全部是 $0。
  // 買二送一那種「有人買、有人送」要從訂單那邊標（訂單明細 / 訂單列表批次），
  // 後端也會擋（該商品還有有金額的未取貨品項就 raise campaign_gift）。
  const toggleGift = async (r: Row) => {
    const label = r.variant_name || r.product_name || r.sku_code;
    let reason: string | null = null;
    if (!r.is_gift) {
      reason = prompt(
        `標記為贈品：${label}\n\n`
        + `⚠️ 只適用「這一項所有人都是送的」：\n`
        + `• 這個開團商品的單價會設為 $0，之後建立的訂單那一項全部不收錢\n`
        + `• 本團所有 $0 的訂單品項（含已建立的）取貨時不再被擋\n`
        + `• 「重新同步商品/價格」不會再把它改回零售價\n\n`
        + `只有部分客人要送（買二送一）→ 改到訂單那邊標，不要用這個。\n\n`
        + `請輸入原因（例：週年慶滿額贈）：`,
      );
      if (reason === null) return;
      if (!reason.trim()) { setError("請填寫贈品原因"); return; }
    } else if (!confirm(
      `取消贈品設定：${label}\n\n單價會維持 $0（要恢復售價請按「重新同步商品/價格」），`
      + `但這些 $0 品項取貨時會重新被零元守衛擋下。確定嗎？`,
    )) {
      return;
    }
    setError(null);
    const { error: err } = await getSupabase().rpc("rpc_set_campaign_item_gift", {
      p_campaign_item_id: r.id,
      p_is_gift: !r.is_gift,
      p_reason: reason?.trim() ?? null,
    });
    if (err) { setError(translateRpcError(err)); return; }
    await reload();
    onResynced?.();
  };

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
              <Th>規格</Th><Th>名稱</Th><Th className="text-right">單價</Th><Th className="text-right">量上限</Th><Th>鎖定時間</Th><Th>贈品</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={6} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={6} className="p-6 text-center text-zinc-500">尚無商品</td></tr>
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
                  <div className="flex items-center gap-1.5">
                    {r.variant_name && (
                      <span className="text-base font-bold text-zinc-900 dark:text-zinc-100">
                        {r.variant_name}
                      </span>
                    )}
                    {r.stockout_at && (
                      <span
                        title={`供應商斷貨於 ${new Date(r.stockout_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}`}
                        className="rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-medium text-red-800 dark:bg-red-950 dark:text-red-300"
                      >
                        ⛔ 斷貨
                      </span>
                    )}
                    {r.is_gift && (
                      <span
                        title={r.gift_reason ? `贈品：${r.gift_reason}` : "贈品（單價 $0，取貨不受零元守衛限制）"}
                        className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                      >
                        🎁 贈品
                      </span>
                    )}
                  </div>
                </Td>
                <Td className="text-right font-mono">${r.unit_price}</Td>
                <Td className="text-right text-xs text-zinc-500">{r.cap_qty ?? "—"}</Td>
                <Td className="text-xs text-zinc-500">
                  {r.locked_at ? new Date(r.locked_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" }) : "—"}
                </Td>
                <Td className="text-xs">
                  {canSetGift ? (
                    <SpinButton
                      onClick={() => toggleGift(r)}
                      title={r.is_gift
                        ? "取消贈品設定（單價維持 $0，但取貨會重新被零元守衛擋下）"
                        : "只適用「這一項所有人都是送的」：單價會設成 $0，之後的訂單那一項全部不收錢。買二送一那種請到訂單那邊標贈品。"}
                      className={r.is_gift
                        ? "rounded-md bg-amber-500 px-2 py-1 text-[11px] font-medium text-white hover:bg-amber-600"
                        : "rounded-md border border-zinc-300 px-2 py-1 text-[11px] font-medium text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"}
                    >
                      {r.is_gift ? "🎁 贈品" : "設為贈品"}
                    </SpinButton>
                  ) : (
                    <span className="text-zinc-400">{r.is_gift ? "🎁" : "—"}</span>
                  )}
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

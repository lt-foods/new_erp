"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { useRole, isHqRole } from "@/lib/role";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import RestockDetailModal from "@/components/RestockDetailModal";
import Spinner from "@/components/Spinner";

const PAGE_SIZE = 20;

type Status = "pending" | "approved_transfer" | "approved_pr" | "shipped" | "received" | "rejected" | "cancelled";

// 一個商品底下可有多個品項（規格），品項各自帶數量
type ItemGroup = { productName: string; variants: string[] };

type Row = {
  id: number;
  requesting_store_id: number;
  store_name: string | null;
  status: Status;
  notes: string | null;
  rejected_reason: string | null;
  linked_transfer_id: number | null;
  linked_pr_id: number | null;
  linked_transfer_no: string | null;
  linked_pr_no: string | null;
  created_at: string;
  line_count: number;
  total_amount: number;
  item_groups: ItemGroup[];
};

const STATUS_LABEL: Record<Status, string> = {
  pending: "待處理",
  approved_transfer: "已派貨",
  approved_pr: "已轉採購",
  shipped: "已出貨",
  received: "已收貨",
  rejected: "已拒絕",
  cancelled: "已取消",
};

const STATUS_COLOR: Record<Status, string> = {
  pending: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  approved_transfer: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  approved_pr: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  shipped: "bg-cyan-100 text-cyan-800 dark:bg-cyan-950 dark:text-cyan-300",
  received: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  rejected: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  cancelled: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
};

type Tab = "all" | "pending" | "approved" | "received" | "rejected";

export default function RestockListPage() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("pending");
  const [page, setPage] = useState(1);
  const [detailId, setDetailId] = useState<number | null>(null);
  const role = useRole();
  // 分店角色（店長 / 店員）不可點 TR / PR 連結進總倉頁面，只顯示純文字編號
  const canFollowLinks = isHqRole(role);

  useEffect(() => { setPage(1); }, [tab]);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const { data, error: err } = await sb
        .from("restock_requests")
        .select("id, requesting_store_id, status, notes, rejected_reason, linked_transfer_id, linked_pr_id, created_at, stores!inner(name)")
        .order("created_at", { ascending: false })
        .limit(100);
      if (err) { setError(err.message); return; }
      const reqRows = (data ?? []) as unknown as Array<Row & { stores?: { name: string } }>;
      const ids = reqRows.map((r) => r.id);
      // 取 line count + total；品項依商品分組（一個商品可帶多個品項/規格）
      const lineMap = new Map<number, { count: number; total: number }>();
      const groupMap = new Map<number, ItemGroup[]>();
      if (ids.length > 0) {
        const { data: lineData } = await sb
          .from("restock_request_lines")
          .select("request_id, sku_id, qty, unit_price")
          .in("request_id", ids);
        const lines = (lineData ?? []) as { request_id: number; sku_id: number; qty: number; unit_price: number }[];

        // 撈 SKU + 商品名（restock_request_lines.sku_id 有 FK 但兩階段 fetch 較穩）
        const skuIds = Array.from(new Set(lines.map((l) => l.sku_id))).filter((x) => x != null);
        let skuInfoMap = new Map<number, { productKey: string; productName: string; variantName: string | null; skuCode: string }>();
        if (skuIds.length > 0) {
          const { data: skus } = await sb
            .from("skus")
            .select("id, sku_code, variant_name, product_id")
            .in("id", skuIds);
          const skuArr = (skus ?? []) as { id: number; sku_code: string; variant_name: string | null; product_id: number | null }[];
          const prodIds = Array.from(new Set(skuArr.map((s) => s.product_id).filter((x): x is number => x != null)));
          let prodNameMap = new Map<number, string>();
          if (prodIds.length > 0) {
            const { data: prods } = await sb.from("products").select("id, name").in("id", prodIds);
            prodNameMap = new Map(((prods ?? []) as { id: number; name: string }[]).map((p) => [p.id, p.name]));
          }
          skuInfoMap = new Map(
            skuArr.map((s) => {
              const prodName = s.product_id != null ? prodNameMap.get(s.product_id) ?? null : null;
              return [s.id, {
                productKey: s.product_id != null ? `p${s.product_id}` : `s${s.id}`,
                productName: prodName ?? s.sku_code,
                variantName: s.variant_name,
                skuCode: s.sku_code,
              }];
            })
          );
        }

        // 每張申請：依商品 key 分組，同商品的多個品項收在一起
        const grpTmp = new Map<number, Map<string, ItemGroup>>();
        for (const l of lines) {
          const slot = lineMap.get(l.request_id) ?? { count: 0, total: 0 };
          slot.count += 1;
          slot.total += Number(l.qty) * Number(l.unit_price);
          lineMap.set(l.request_id, slot);

          const info = skuInfoMap.get(l.sku_id);
          const productName = info?.productName ?? `#${l.sku_id}`;
          const productKey = info?.productKey ?? `s${l.sku_id}`;
          // 品項標籤：品相有值用品相，無則退回 sku_code
          const variantLabel = `${info?.variantName ?? info?.skuCode ?? `#${l.sku_id}`}×${Number(l.qty)}`;

          const g = grpTmp.get(l.request_id) ?? new Map<string, ItemGroup>();
          const existing = g.get(productKey);
          if (existing) existing.variants.push(variantLabel);
          else g.set(productKey, { productName, variants: [variantLabel] });
          grpTmp.set(l.request_id, g);
        }
        for (const [rid, g] of grpTmp) groupMap.set(rid, Array.from(g.values()));
      }
      // 取 transfer / pr 編號
      const transferIds = reqRows.map((r) => r.linked_transfer_id).filter((x): x is number => !!x);
      const prIds = reqRows.map((r) => r.linked_pr_id).filter((x): x is number => !!x);
      const xferMap = new Map<number, string>();
      const prMap = new Map<number, string>();
      if (transferIds.length > 0) {
        const { data: xfer } = await sb.from("transfers").select("id, transfer_no").in("id", transferIds);
        for (const t of (xfer ?? []) as { id: number; transfer_no: string }[]) xferMap.set(t.id, t.transfer_no);
      }
      if (prIds.length > 0) {
        const { data: pr } = await sb.from("purchase_requests").select("id, pr_no").in("id", prIds);
        for (const p of (pr ?? []) as { id: number; pr_no: string }[]) prMap.set(p.id, p.pr_no);
      }

      setRows(reqRows.map((r) => ({
        ...r,
        store_name: r.stores?.name ?? null,
        line_count: lineMap.get(r.id)?.count ?? 0,
        total_amount: lineMap.get(r.id)?.total ?? 0,
        item_groups: groupMap.get(r.id) ?? [],
        linked_transfer_no: r.linked_transfer_id ? xferMap.get(r.linked_transfer_id) ?? null : null,
        linked_pr_no: r.linked_pr_id ? prMap.get(r.linked_pr_id) ?? null : null,
      })));
    })();
  }, []);

  const filtered = useMemo(() => (rows ?? []).filter((r) => {
    if (tab === "all") return true;
    if (tab === "pending") return r.status === "pending";
    if (tab === "approved") return r.status === "approved_transfer" || r.status === "approved_pr" || r.status === "shipped";
    if (tab === "received") return r.status === "received";
    if (tab === "rejected") return r.status === "rejected" || r.status === "cancelled";
    return true;
  }), [rows, tab]);

  const totalPages = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const paginated = useMemo(
    () => filtered.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE),
    [filtered, page],
  );

  async function handleDelete(r: Row) {
    const ok = window.confirm(
      `確定刪除補貨申請 #${r.id}（${r.store_name ?? "—"}）？\n\n` +
      `共 ${r.line_count} 個品項、$${r.total_amount.toFixed(0)}。\n` +
      `刪除後無法復原；只有「待處理」的申請可以刪除。`,
    );
    if (!ok) return;
    try {
      const { error: err } = await getSupabase().rpc("rpc_delete_restock_request", { p_request_id: r.id });
      if (err) throw err;
      setError(null);
      setRows((prev) => (prev ?? []).filter((x) => x.id !== r.id));
    } catch (e) {
      setError(translateRpcError(e));
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">補貨申請</h1>
          <p className="text-sm text-zinc-500">{rows === null ? <Spinner size={14} className="inline-block align-[-2px]" /> : `共 ${rows.length} 筆`}</p>
        </div>
        <Link href="/restock/new" className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900">
          + 建立申請
        </Link>
      </header>

      {error && <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</div>}

      <div className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["pending", "approved", "received", "rejected", "all"] as Tab[]).map((v) => (
          <SpinButton
            key={v}
            onClick={() => setTab(v)}
            className={tab === v
              ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
              : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {v === "pending" ? "待處理" : v === "approved" ? "處理中" : v === "received" ? "已收貨" : v === "rejected" ? "已拒絕 / 取消" : "全部"}
          </SpinButton>
        ))}
      </div>

      <Table>
        <THead>
          <Th>日期</Th>
          <Th>店</Th>
          <Th align="right">商品數</Th>
          <Th>商品</Th>
          <Th>品項</Th>
          <Th align="right">總金額</Th>
          <Th>狀態</Th>
          <Th>連結 / 拒絕原因</Th>
          <Th>備註</Th>
          <Th align="right">操作</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={10} />
          ) : filtered.length === 0 ? (
            <EmptyRow colSpan={10}>沒有符合條件的申請</EmptyRow>
          ) : paginated.map((r) => (
            <Tr
              key={r.id}
              onClick={() => setDetailId(r.id)}
              className="cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-950"
            >
              <Td className="whitespace-nowrap text-xs text-zinc-500">{new Date(r.created_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}</Td>
              <Td>{r.store_name ?? "—"}</Td>
              <Td align="right" className="font-mono">{r.line_count}</Td>
              <Td className="max-w-[14rem] text-xs text-zinc-700 dark:text-zinc-200">
                {r.item_groups.length === 0 ? "—" : (
                  <div className="flex flex-col gap-1.5">
                    {r.item_groups.map((g, i) => (
                      <div key={i} className="break-words font-medium">{g.productName}</div>
                    ))}
                  </div>
                )}
              </Td>
              <Td className="max-w-[16rem] text-xs text-zinc-600 dark:text-zinc-300">
                {r.item_groups.length === 0 ? "—" : (
                  <div className="flex flex-col gap-1.5">
                    {r.item_groups.map((g, i) => (
                      <div key={i} className="break-words">{g.variants.join("、")}</div>
                    ))}
                  </div>
                )}
              </Td>
              <Td align="right" className="font-mono">${r.total_amount.toFixed(0)}</Td>
              <Td>
                <span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${STATUS_COLOR[r.status]}`}>
                  {STATUS_LABEL[r.status]}
                </span>
              </Td>
              <Td className="text-xs">
                {r.linked_transfer_no && (
                  canFollowLinks ? (
                    <Link
                      href={`/hq/inbox?source=transfer&id=${r.linked_transfer_id}`}
                      onClick={(e) => e.stopPropagation()}
                      className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                    >
                      → {r.linked_transfer_no}
                    </Link>
                  ) : (
                    <span className="font-mono text-zinc-600 dark:text-zinc-300">→ {r.linked_transfer_no}</span>
                  )
                )}
                {r.linked_pr_no && (
                  canFollowLinks ? (
                    <Link
                      href={`/purchase/requests/edit?id=${r.linked_pr_id}`}
                      onClick={(e) => e.stopPropagation()}
                      className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                    >
                      → {r.linked_pr_no}
                    </Link>
                  ) : (
                    <span className="font-mono text-zinc-600 dark:text-zinc-300">→ {r.linked_pr_no}</span>
                  )
                )}
                {r.status === "rejected" && r.rejected_reason && <span className="text-red-600">拒絕：{r.rejected_reason}</span>}
              </Td>
              <Td className="max-w-xs text-xs text-zinc-500">
                <span title={r.notes ?? ""}>{r.notes ? r.notes.slice(0, 30) + (r.notes.length > 30 ? "…" : "") : "—"}</span>
              </Td>
              <Td align="right">
                {r.status === "pending" && (
                  <SpinButton
                    onClick={(e) => { e.stopPropagation(); return handleDelete(r); }}
                    className="rounded-md border border-red-300 px-2 py-1 text-xs text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950"
                  >
                    刪除
                  </SpinButton>
                )}
              </Td>
            </Tr>
          ))}
        </TBody>
      </Table>

      <RestockDetailModal
        open={detailId !== null}
        restockId={detailId}
        onClose={() => setDetailId(null)}
      />

      {filtered.length > PAGE_SIZE && (
        <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
          <span className="text-xs text-zinc-500">
            共 {filtered.length} 筆 · 顯示 {(page - 1) * PAGE_SIZE + 1} - {Math.min(page * PAGE_SIZE, filtered.length)}
          </span>
          <SpinButton onClick={() => setPage(1)} disabled={page === 1} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">« 第一頁</SpinButton>
          <SpinButton onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={page === 1} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">‹ 上頁</SpinButton>
          <span className="text-xs text-zinc-500">{page} / {totalPages}</span>
          <SpinButton onClick={() => setPage((p) => Math.min(totalPages, p + 1))} disabled={page === totalPages} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">下頁 ›</SpinButton>
          <SpinButton onClick={() => setPage(totalPages)} disabled={page === totalPages} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">最末頁 »</SpinButton>
        </div>
      )}
    </div>
  );
}

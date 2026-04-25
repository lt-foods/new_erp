"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { PrPipelineStepper } from "@/components/PrPipelineStepper";

type POStatus =
  | "draft"
  | "sent"
  | "partially_received"
  | "fully_received"
  | "closed"
  | "cancelled";

type PO = {
  id: number;
  po_no: string;
  supplier_id: number;
  supplier_name: string | null;
  status: POStatus;
  total: number;
  expected_date: string | null;
  sent_at: string | null;
  sent_channel: string | null;
  updated_at: string;
};

type PRGroup = {
  pr_id: number | null; // null = 手動建立 / 找不到來源 PR
  pr_no: string | null;
  pr_status: string | null;
  pr_review_status: string | null;
  pr_source_close_date: string | null;
  pos: PO[];
};

type PRProgress = {
  po_total: number;
  po_sent: number;
  po_received_fully: number;
  transfer_total: number;
  transfer_shipped: number;
  transfer_delivered: number;
  all_campaigns_finalized: boolean;
};

const STATUS_LABEL: Record<POStatus, string> = {
  draft: "草稿",
  sent: "已發送",
  partially_received: "部分到貨",
  fully_received: "全部到貨",
  closed: "已結案",
  cancelled: "已取消",
};

const PR_STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  submitted: "已送審",
  partially_ordered: "部分轉單",
  fully_ordered: "全部轉單",
  cancelled: "已取消",
};

export default function PurchaseOrdersListPage() {
  const [groups, setGroups] = useState<PRGroup[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState("");
  const [openPRs, setOpenPRs] = useState<Set<string>>(new Set()); // 'null' or pr_id 字串
  const [progressById, setProgressById] = useState<Map<number, PRProgress>>(new Map());

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const supabase = getSupabase();

        // 1. 撈 POs
        let q = supabase
          .from("purchase_orders")
          .select(
            "id, po_no, supplier_id, status, total, expected_date, sent_at, sent_channel, updated_at, suppliers(name)",
          )
          .order("updated_at", { ascending: false })
          .limit(200);
        if (statusFilter) q = q.eq("status", statusFilter);
        const { data: poData, error: poErr } = await q;
        if (poErr) throw new Error(poErr.message);
        if (cancelled) return;

        type RawPO = {
          id: number;
          po_no: string;
          supplier_id: number;
          status: POStatus;
          total: number;
          expected_date: string | null;
          sent_at: string | null;
          sent_channel: string | null;
          updated_at: string;
          suppliers: { name: string } | { name: string }[] | null;
        };
        const pos: PO[] = ((poData as RawPO[] | null) ?? []).map((r) => {
          const sup = Array.isArray(r.suppliers) ? r.suppliers[0] : r.suppliers;
          return {
            id: r.id,
            po_no: r.po_no,
            supplier_id: r.supplier_id,
            supplier_name: sup?.name ?? null,
            status: r.status,
            total: Number(r.total),
            expected_date: r.expected_date,
            sent_at: r.sent_at,
            sent_channel: r.sent_channel,
            updated_at: r.updated_at,
          };
        });
        const poIds = pos.map((p) => p.id);

        // 2. 透過 purchase_order_items + purchase_request_items 找來源 PR
        const poToPR = new Map<number, number>();
        if (poIds.length) {
          const { data: poiRows } = await supabase
            .from("purchase_order_items")
            .select("id, po_id")
            .in("po_id", poIds);
          const poiIds = (poiRows ?? []).map((r) => r.id);
          const poiToPo = new Map<number, number>();
          for (const r of poiRows ?? []) poiToPo.set(r.id, r.po_id);

          if (poiIds.length) {
            const { data: priRows } = await supabase
              .from("purchase_request_items")
              .select("po_item_id, pr_id")
              .in("po_item_id", poiIds);
            for (const r of priRows ?? []) {
              const po = r.po_item_id ? poiToPo.get(r.po_item_id) : null;
              if (po && r.pr_id) poToPR.set(po, r.pr_id);
            }
          }
        }

        // 3. 撈 PR 細節
        const prIds = Array.from(new Set(Array.from(poToPR.values())));
        const prMap = new Map<
          number,
          { pr_no: string; status: string; review_status: string; source_close_date: string | null }
        >();
        if (prIds.length) {
          const { data: prRows } = await supabase
            .from("purchase_requests")
            .select("id, pr_no, status, review_status, source_close_date")
            .in("id", prIds);
          for (const r of prRows ?? []) {
            prMap.set(r.id, {
              pr_no: r.pr_no,
              status: r.status,
              review_status: r.review_status,
              source_close_date: r.source_close_date,
            });
          }

          const { data: prog } = await supabase
            .from("v_pr_progress")
            .select("pr_id, po_total, po_sent, po_received_fully, transfer_total, transfer_shipped, transfer_delivered, all_campaigns_finalized")
            .in("pr_id", prIds);
          const m = new Map<number, PRProgress>();
          type ProgRow = {
            pr_id: number;
            po_total: number;
            po_sent: number;
            po_received_fully: number;
            transfer_total: number;
            transfer_shipped: number;
            transfer_delivered: number;
            all_campaigns_finalized: boolean;
          };
          for (const p of (prog as ProgRow[] | null) ?? []) {
            m.set(p.pr_id, {
              po_total: Number(p.po_total),
              po_sent: Number(p.po_sent),
              po_received_fully: Number(p.po_received_fully),
              transfer_total: Number(p.transfer_total),
              transfer_shipped: Number(p.transfer_shipped),
              transfer_delivered: Number(p.transfer_delivered),
              all_campaigns_finalized: !!p.all_campaigns_finalized,
            });
          }
          if (!cancelled) setProgressById(m);
        }

        // 4. 按 PR 分組
        const groupMap = new Map<string, PRGroup>();
        for (const po of pos) {
          const prId = poToPR.get(po.id) ?? null;
          const key = prId === null ? "null" : String(prId);
          if (!groupMap.has(key)) {
            const prInfo = prId !== null ? prMap.get(prId) : null;
            groupMap.set(key, {
              pr_id: prId,
              pr_no: prInfo?.pr_no ?? null,
              pr_status: prInfo?.status ?? null,
              pr_review_status: prInfo?.review_status ?? null,
              pr_source_close_date: prInfo?.source_close_date ?? null,
              pos: [],
            });
          }
          groupMap.get(key)!.pos.push(po);
        }

        const result = Array.from(groupMap.values()).sort((a, b) => {
          // null 群放最後
          if (a.pr_id === null && b.pr_id !== null) return 1;
          if (b.pr_id === null && a.pr_id !== null) return -1;
          // 依結單日 desc
          const ad = a.pr_source_close_date ?? "";
          const bd = b.pr_source_close_date ?? "";
          if (ad !== bd) return bd.localeCompare(ad);
          return (b.pr_id ?? 0) - (a.pr_id ?? 0);
        });

        if (!cancelled) {
          setGroups(result);
          setError(null);
          // 預設展開全部
          setOpenPRs(new Set(result.map((g) => (g.pr_id === null ? "null" : String(g.pr_id)))));
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [statusFilter]);

  function togglePR(key: string) {
    setOpenPRs((cur) => {
      const next = new Set(cur);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">採購訂單（PO）</h1>
        <p className="text-sm text-zinc-500">
          {groups === null
            ? "載入中…"
            : `共 ${groups.reduce((s, g) => s + g.pos.length, 0)} 張 PO，依採購單分組`}
        </p>
      </header>

      <div>
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部狀態</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {groups !== null && groups.length === 0 && (
        <div className="rounded-md border border-zinc-200 bg-zinc-50 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          尚無採購訂單。請至「採購單」頁面建立後產生。
        </div>
      )}

      <div className="flex flex-col gap-3">
        {groups?.map((g) => {
          const key = g.pr_id === null ? "null" : String(g.pr_id);
          const open = openPRs.has(key);
          const totalAmount = g.pos.reduce((s, p) => s + p.total, 0);
          return (
            <div
              key={key}
              className="overflow-hidden rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
            >
              <div className="flex flex-col gap-2 border-b border-zinc-200 bg-zinc-50 px-4 py-3 dark:border-zinc-800 dark:bg-zinc-900">
              <button
                onClick={() => togglePR(key)}
                className="-mx-4 -my-3 flex w-[calc(100%+2rem)] items-center justify-between gap-3 px-4 py-3 text-left hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                <div className="flex items-center gap-3">
                  <span className="text-zinc-400">{open ? "▼" : "▶"}</span>
                  <div>
                    <div className="font-semibold">
                      {g.pr_id !== null ? (
                        <>
                          採購單 <span className="font-mono">{g.pr_no}</span>
                          {g.pr_source_close_date && (
                            <span className="ml-2 text-xs text-zinc-500">
                              結單日 {g.pr_source_close_date}
                            </span>
                          )}
                          {g.pr_status && (
                            <span className="ml-2 inline-block rounded bg-zinc-100 px-2 py-0.5 text-xs font-normal dark:bg-zinc-800">
                              {PR_STATUS_LABEL[g.pr_status] ?? g.pr_status}
                            </span>
                          )}
                        </>
                      ) : (
                        <span className="text-zinc-500">手動建立 / 無來源採購單</span>
                      )}
                    </div>
                    <div className="text-xs text-zinc-500">
                      {g.pos.length} 張採購訂單 · 總金額 ${totalAmount.toFixed(0)}
                    </div>
                  </div>
                </div>
                {g.pr_id !== null && (
                  <a
                    href={`/purchase/requests/edit?id=${g.pr_id}`}
                    onClick={(e) => e.stopPropagation()}
                    className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-white dark:border-zinc-700 dark:hover:bg-zinc-700"
                  >
                    查看採購單 →
                  </a>
                )}
              </button>
              {g.pr_id !== null && g.pr_status && (
                <div className="px-1">
                  <PrPipelineStepper
                    status={g.pr_status}
                    reviewStatus={g.pr_review_status ?? "approved"}
                    compact
                    poSummary={(() => {
                      const p = progressById.get(g.pr_id);
                      return p
                        ? { total: p.po_total, sent: p.po_sent, receivedFully: p.po_received_fully }
                        : { total: g.pos.length, sent: 0, receivedFully: 0 };
                    })()}
                    transferSummary={(() => {
                      const p = progressById.get(g.pr_id);
                      return p
                        ? { total: p.transfer_total, shipped: p.transfer_shipped, delivered: p.transfer_delivered }
                        : undefined;
                    })()}
                    campaignFinalized={progressById.get(g.pr_id)?.all_campaigns_finalized}
                    events={{
                      create: { href: `/purchase/requests/edit?id=${g.pr_id}` },
                      draft: { href: `/purchase/requests/edit?id=${g.pr_id}` },
                      submit: { href: `/purchase/requests/edit?id=${g.pr_id}` },
                      review: { href: `/purchase/requests/edit?id=${g.pr_id}` },
                    }}
                  />
                </div>
              )}
              </div>

              {open && (
                <div className="overflow-x-auto">
                  <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                    <thead className="bg-white dark:bg-zinc-900">
                      <tr>
                        <Th>單號</Th>
                        <Th>供應商</Th>
                        <Th>狀態</Th>
                        <Th className="text-right">金額</Th>
                        <Th>預計到貨</Th>
                        <Th>發送</Th>
                        <Th className="text-right">更新</Th>
                        <Th></Th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                      {g.pos.map((p) => (
                        <tr key={p.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                          <Td className="font-mono">
                            <a
                              href={`/purchase/orders/edit?id=${p.id}`}
                              className="hover:underline"
                            >
                              {p.po_no}
                            </a>
                          </Td>
                          <Td>{p.supplier_name ?? "—"}</Td>
                          <Td>
                            <POStatusBadge status={p.status} />
                          </Td>
                          <Td className="text-right font-mono">${p.total.toFixed(0)}</Td>
                          <Td className="text-xs">{p.expected_date ?? "—"}</Td>
                          <Td className="text-xs text-zinc-500">
                            {p.sent_at ? (
                              <>
                                <div>{new Date(p.sent_at).toLocaleString("zh-TW")}</div>
                                {p.sent_channel && (
                                  <div className="text-zinc-400">via {p.sent_channel}</div>
                                )}
                              </>
                            ) : (
                              "—"
                            )}
                          </Td>
                          <Td className="text-right text-xs text-zinc-500">
                            {new Date(p.updated_at).toLocaleString("zh-TW")}
                          </Td>
                          <Td className="text-right">
                            {(p.status === "sent" || p.status === "partially_received") && (
                              <a
                                href={`/purchase/orders/receive?po=${p.id}`}
                                className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-700"
                              >
                                進貨
                              </a>
                            )}
                          </Td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function Th({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
  return (
    <th
      className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}
    >
      {children}
    </th>
  );
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}
function POStatusBadge({ status }: { status: POStatus }) {
  const cls: Record<POStatus, string> = {
    draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    sent: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
    partially_received: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    fully_received: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
    closed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
    cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  };
  return (
    <span className={`inline-block rounded px-2 py-0.5 text-xs ${cls[status]}`}>
      {STATUS_LABEL[status]}
    </span>
  );
}

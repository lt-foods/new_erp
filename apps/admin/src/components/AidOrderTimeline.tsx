"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type Order = {
  id: number;
  status: string;
  is_air_transfer: boolean | null;
  created_at: string;
  confirmed_at: string | null;
  shipping_at: string | null;
  ready_at: string | null;
  cancelled_at: string | null;
  completed_at: string | null;
};

type TransferRow = {
  id: number;
  transfer_no: string;
  source_location: number;
  dest_location: number;
  status: string;
  transfer_type: string;
  customer_order_id: number | null;
  next_transfer_id: number | null;
  shipped_at: string | null;
  received_at: string | null;
  notes: string | null;
  created_at: string;
};

type EventKind =
  | "order_created"
  | "order_confirmed"
  | "transfer_shipped"
  | "transfer_received"
  | "transfer_cancelled"
  | "order_ready"
  | "order_completed"
  | "order_cancelled";

type TimelineEvent = {
  kind: EventKind;
  at: string;
  title: string;
  detail?: string;
  status: "done" | "current" | "future" | "error";
};

const ORDER_STATUS_LABEL: Record<string, string> = {
  pending: "待確認",
  confirmed: "已確認",
  shipping: "派貨中",
  ready: "可取貨",
  completed: "已完成",
  cancelled: "已取消",
  expired: "逾期",
  reserved: "已保留",
  transferred_out: "已轉出",
};

export function AidOrderTimeline({ orderId }: { orderId: number }) {
  const [order, setOrder] = useState<Order | null>(null);
  const [transfers, setTransfers] = useState<TransferRow[]>([]);
  const [locations, setLocations] = useState<Map<number, string>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      setError(null);
      try {
        const sb = getSupabase();
        const { data: orderRow, error: oErr } = await sb
          .from("customer_orders")
          .select(
            "id, status, is_air_transfer, created_at, confirmed_at, shipping_at, ready_at, cancelled_at, completed_at",
          )
          .eq("id", orderId)
          .maybeSingle();
        if (oErr) throw oErr;
        if (!orderRow) {
          if (!cancelled) setOrder(null);
          return;
        }
        if (!cancelled) setOrder(orderRow as Order);

        // 找 chain：從 customer_order_id 找 terminal，再正反向 walk
        const { data: termRows } = await sb
          .from("transfers")
          .select(
            "id, transfer_no, source_location, dest_location, status, transfer_type, customer_order_id, next_transfer_id, shipped_at, received_at, notes, created_at",
          )
          .eq("customer_order_id", orderId);
        const terminal = ((termRows ?? []) as TransferRow[])[0] ?? null;

        const chain: TransferRow[] = [];
        if (terminal) {
          const transferCols =
            "id, transfer_no, source_location, dest_location, status, transfer_type, customer_order_id, next_transfer_id, shipped_at, received_at, notes, created_at";

          // 倒走找 head
          let head: TransferRow = terminal;
          const seen = new Set<number>([head.id]);
          for (;;) {
            const prevQuery = await sb
              .from("transfers")
              .select(transferCols)
              .eq("next_transfer_id", head.id);
            const prev = ((prevQuery.data ?? []) as TransferRow[])[0];
            if (!prev || seen.has(prev.id)) break;
            seen.add(prev.id);
            head = prev;
          }

          // 正向 walk
          let cursor: TransferRow | null = head;
          while (cursor) {
            chain.push(cursor);
            const nextId: number | null = cursor.next_transfer_id;
            if (nextId == null) break;
            const nextRes: { data: unknown } = await sb
              .from("transfers")
              .select(transferCols)
              .eq("id", nextId)
              .maybeSingle();
            cursor = (nextRes.data as TransferRow | null) ?? null;
          }
        }
        if (!cancelled) setTransfers(chain);

        // 撈 location names
        const locIds = Array.from(
          new Set(chain.flatMap((t) => [t.source_location, t.dest_location])),
        );
        if (locIds.length > 0) {
          const { data: locRows } = await sb
            .from("locations")
            .select("id, name")
            .in("id", locIds);
          const m = new Map<number, string>();
          for (const l of (locRows ?? []) as { id: number; name: string }[]) {
            m.set(l.id, l.name);
          }
          if (!cancelled) setLocations(m);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [orderId]);

  const events = useMemo<TimelineEvent[]>(() => {
    if (!order) return [];
    const list: TimelineEvent[] = [];
    const locName = (id: number) => locations.get(id) ?? `#${id}`;
    const isCancelled = order.status === "cancelled";

    list.push({
      kind: "order_created",
      at: order.created_at,
      title: "訂單建立",
      status: "done",
    });

    if (order.confirmed_at) {
      list.push({
        kind: "order_confirmed",
        at: order.confirmed_at,
        title: "訂單已確認",
        status: "done",
      });
    }

    for (const t of transfers) {
      const route = `${locName(t.source_location)} → ${locName(t.dest_location)}`;
      const isReturn = (t.notes ?? "").includes("Leg-3 退回 source") ||
        t.transfer_no.startsWith("AT-RET-");
      const shipTitle = isReturn
        ? `自動退回派出（${route}）`
        : `派貨（${route}）`;

      if (t.shipped_at) {
        list.push({
          kind: "transfer_shipped",
          at: t.shipped_at,
          title: shipTitle,
          detail: `#${t.transfer_no}`,
          status: t.status === "cancelled" ? "error" : "done",
        });
      }
      if (t.status === "cancelled") {
        const reason = (t.notes ?? "")
          .split("\n")
          .find((l) => l.includes("rejected") || l.includes("cancelled"));
        list.push({
          kind: "transfer_cancelled",
          at: t.shipped_at ?? t.created_at,
          title: reason?.includes("rejected") ? "拒收 / 取消" : "已撤回",
          detail: `#${t.transfer_no}${reason ? ` ${reason}` : ""}`,
          status: "error",
        });
      } else if (t.received_at) {
        list.push({
          kind: "transfer_received",
          at: t.received_at,
          title: `${locName(t.dest_location)} 收貨`,
          detail: `#${t.transfer_no}`,
          status: "done",
        });
      } else if (t.status === "shipped") {
        list.push({
          kind: "transfer_received",
          at: t.shipped_at ?? t.created_at,
          title: `${locName(t.dest_location)} 收貨`,
          detail: "待處理",
          status: "current",
        });
      } else if (t.status === "draft") {
        list.push({
          kind: "transfer_shipped",
          at: t.created_at,
          title: shipTitle,
          detail: `#${t.transfer_no} 排隊中`,
          status: "future",
        });
      }
    }

    if (order.ready_at) {
      list.push({
        kind: "order_ready",
        at: order.ready_at,
        title: "訂單可取貨",
        status: "done",
      });
    } else if (!isCancelled && order.status === "ready") {
      list.push({
        kind: "order_ready",
        at: new Date().toISOString(),
        title: "訂單可取貨",
        status: "current",
      });
    }

    if (order.completed_at) {
      list.push({
        kind: "order_completed",
        at: order.completed_at,
        title: "訂單已完成",
        status: "done",
      });
    } else if (!isCancelled && order.status === "completed") {
      list.push({
        kind: "order_completed",
        at: new Date().toISOString(),
        title: "訂單已完成",
        status: "done",
      });
    }

    if (order.cancelled_at || isCancelled) {
      list.push({
        kind: "order_cancelled",
        at: order.cancelled_at ?? new Date().toISOString(),
        title: "訂單已取消",
        status: "error",
      });
    }

    list.sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime());
    return list;
  }, [order, transfers, locations]);

  if (loading) {
    return (
      <div className="rounded-md border border-zinc-200 p-4 text-sm text-zinc-500 dark:border-zinc-800">
        載入互助轉移進度…
      </div>
    );
  }
  if (error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        Timeline 錯誤：{error}
      </div>
    );
  }
  if (!order) return null;

  return (
    <div className="rounded-md border border-zinc-200 p-4 dark:border-zinc-800">
      <h3 className="mb-3 text-sm font-semibold">
        互助轉移進度
        {order.is_air_transfer ? (
          <span className="ml-2 inline-block rounded bg-sky-100 px-1.5 py-0.5 text-[10px] text-sky-800 dark:bg-sky-950 dark:text-sky-300">
            ✈️ 空中轉
          </span>
        ) : (
          <span className="ml-2 inline-block rounded bg-violet-100 px-1.5 py-0.5 text-[10px] text-violet-800 dark:bg-violet-950 dark:text-violet-300">
            🏬 經總倉
          </span>
        )}
        <span className="ml-2 text-xs font-normal text-zinc-500">
          目前狀態：{ORDER_STATUS_LABEL[order.status] ?? order.status}
        </span>
      </h3>

      <ol className="relative space-y-3 border-l border-zinc-200 pl-5 dark:border-zinc-800">
        {events.map((ev, i) => (
          <li key={`${ev.kind}-${i}`} className="relative">
            <span
              className={`absolute -left-[1.625rem] top-1 inline-block h-3 w-3 rounded-full border-2 ${dotClass(ev.status)}`}
            />
            <div className="flex flex-wrap items-baseline gap-2">
              <span className={`text-sm font-medium ${textClass(ev.status)}`}>
                {ev.title}
              </span>
              <span className="text-[11px] text-zinc-500">
                {fmtDt(ev.at)}
              </span>
            </div>
            {ev.detail && (
              <div className="text-[11px] text-zinc-500">{ev.detail}</div>
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}

function dotClass(s: TimelineEvent["status"]) {
  switch (s) {
    case "done":
      return "border-emerald-500 bg-emerald-500";
    case "current":
      return "border-blue-500 bg-blue-500 animate-pulse";
    case "error":
      return "border-red-500 bg-red-500";
    case "future":
    default:
      return "border-zinc-300 bg-white dark:border-zinc-600 dark:bg-zinc-900";
  }
}

function textClass(s: TimelineEvent["status"]) {
  switch (s) {
    case "done":
      return "text-zinc-900 dark:text-zinc-100";
    case "current":
      return "text-blue-700 dark:text-blue-300";
    case "error":
      return "text-red-700 dark:text-red-300";
    case "future":
    default:
      return "text-zinc-500";
  }
}

function fmtDt(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString("zh-TW", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

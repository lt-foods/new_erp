// 取貨收據補印 — 共用邏輯（訂單明細單張補印 / 訂單頁批量補印都走這裡）
//
// 收據頁 /pickup/print 是以 order_pickup_events.id 為準（該表 append-only，
// 是「當時印了什麼」的權威來源）。小白單 /pickup/print-list 在取貨後幫不上忙 —
// 它只列 pending/reserved/ready 品項，取完貨會印成空單。
import { getSupabase } from "@/lib/supabase";

export type PickupEventRow = {
  id: number;
  order_id: number;
  event_type: string;      // picked_up | partial_pickup | pickup_undone
  created_at: string;
  notes: string | null;
};

// 撤銷取貨不刪原事件（表禁改禁刪），而是補一筆 pickup_undone，
// notes 固定為 `撤銷取貨事件 #<id>…`（rpc_undo_pickup，20260704000010）。
// 被撤銷的那次不該再補印收據。
export function undonePickupEventIds(rows: PickupEventRow[]): Set<number> {
  const undone = new Set<number>();
  for (const r of rows) {
    if (r.event_type !== "pickup_undone") continue;
    const m = /撤銷取貨事件 #(\d+)/.exec(r.notes ?? "");
    if (m) undone.add(Number(m[1]));
  }
  return undone;
}

// order_id → 可補印的取貨事件（已濾掉被撤銷的），依 id 升冪＝取貨先後。
// 沒有任何有效事件的訂單不會出現在 Map 裡。
export async function fetchReprintableEvents(
  orderIds: number[],
): Promise<Map<number, PickupEventRow[]>> {
  const out = new Map<number, PickupEventRow[]>();
  if (orderIds.length === 0) return out;
  const { data } = await getSupabase()
    .from("order_pickup_events")
    .select("id, order_id, event_type, created_at, notes")
    .in("order_id", orderIds)
    .in("event_type", ["picked_up", "partial_pickup", "pickup_undone"])
    .order("id", { ascending: true });
  const rows = (data ?? []) as unknown as PickupEventRow[];
  const undone = undonePickupEventIds(rows);
  for (const r of rows) {
    if (r.event_type === "pickup_undone" || undone.has(r.id)) continue;
    const list = out.get(r.order_id) ?? [];
    list.push(r);
    out.set(r.order_id, list);
  }
  return out;
}

export function pickupEventLabel(ev: PickupEventRow | undefined): string {
  if (!ev) return "—";
  const when = new Date(ev.created_at).toLocaleString("zh-TW", { hour12: false });
  return `${ev.event_type === "partial_pickup" ? "部分取貨" : "取貨"} ${when}`;
}

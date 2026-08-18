// 「一次到店結單」分組 —— 把已取貨的品項還原成「客人那一次拿走的組合」。
//
// ⚠️ 這份邏輯在會員 app 有一份一模一樣的副本（客服要看到跟團友手機上完全相同的
//    畫面）：apps/member/src/lib/pickups.ts。改這邊記得改那邊。
//
// 為什麼要有這個：訂單是**依團**開的，取貨是**依人**結的。客人一趟到店常常一次
// 拿走三、四個團的貨、當場付一次現金；平鋪的「已完成」列表拼不回那一次拿了什麼。
// 資料來源是 order_pickup_events（append-only，`/pickup/print` 的收據印的也是它）：
// 一次櫃台結單 = 每張訂單各一筆事件（「一次全取」逐張呼叫 rpc_record_pickup），
// 把時間相近、同一家店的事件併回一組，就是那一次的結單組合。

/**
 * 同一「次」結單的判定：同一家店 + 相鄰兩筆事件間隔 ≤ 10 分鐘。
 * 店員「一次全取」是一張單一張單連續呼叫 RPC，實務上整批落在幾秒內；10 分鐘是
 * 留給「先結一張、翻單、再結一張」的櫃台節奏。同一天再跑一趟會正確地分成兩次。
 */
const VISIT_GAP_MS = 10 * 60 * 1000;

export type VisitItemLike = {
  id: number;
  qty: number;
  subtotal: number;
  status: string;
};

export type VisitPickupLike = {
  id: number;
  picked_at: string;
  item_ids: number[];
};

export type VisitOrderLike = {
  id: number;
  store_name: string | null;
  items: VisitItemLike[] | null;
  pickups?: VisitPickupLike[];
};

/** 一次到店結單 */
export type PickupVisit = {
  key: string;
  /** 這一次最後一筆取貨事件的時間（＝櫃台結單完成的時間） */
  pickedAt: string;
  storeName: string | null;
  orderCount: number;
  qty: number;
  amount: number;
};

/** 「已完成」的渲染節點：結單標題，或標題底下的一張訂單卡 */
export type DoneNode<T> =
  | { kind: "visit"; key: string; visit: PickupVisit }
  | { kind: "order"; key: string; order: T };

/** 這張卡片實際列出來的貨值 / 件數（斷貨 / 取消的行不算，跟卡片上的件數同一套） */
export function visibleTotals(items: VisitItemLike[]): { qty: number; amount: number } {
  let qty = 0;
  let amount = 0;
  for (const it of items) {
    if (["cancelled", "expired"].includes(it.status)) continue;
    qty += Number(it.qty ?? 0);
    amount += Number(it.subtotal ?? 0);
  }
  return { qty, amount };
}

/**
 * 把訂單依取貨事件拆片，再把時間相近的併成一次結單。
 *
 * 一張單分兩次取完 → 拆成兩張卡，各自掛在自己那一次結單底下（這正是要看的東西）。
 * 對不到任何事件的品項（撤銷取貨、舊資料）→ 收在最後，維持原本的平鋪樣子。
 */
export function buildDoneNodes<T extends VisitOrderLike>(doneOrders: T[]): DoneNode<T>[] {
  type Slice = { order: T; pickedAt: string; storeKey: string };
  const slices: Slice[] = [];
  const orphans: T[] = [];

  for (const o of doneOrders) {
    const all = o.items ?? [];
    const events = [...(o.pickups ?? [])].sort((a, b) => a.id - b.id);
    const used = new Set<number>();
    for (const ev of events) {
      const ids = new Set((ev.item_ids ?? []).map(Number));
      // 只認現在還在這張單上的行：撤銷取貨會把行改回去，事件卻永遠留著
      const items = all.filter((it) => ids.has(Number(it.id)));
      if (items.length === 0) continue;
      for (const it of items) used.add(Number(it.id));
      slices.push({
        order: { ...o, items },
        pickedAt: ev.picked_at,
        storeKey: String(o.store_name ?? ""),
      });
    }
    const rest = all.filter((it) => !used.has(Number(it.id)));
    if (rest.length > 0) orphans.push({ ...o, items: rest });
  }

  // 新的結單排前面（「已完成」看的是「最近拿了什麼」，不是「最早訂了什麼」）
  slices.sort((a, b) => new Date(b.pickedAt).getTime() - new Date(a.pickedAt).getTime());

  const nodes: DoneNode<T>[] = [];
  let group: Slice[] = [];

  const flush = () => {
    if (group.length === 0) return;
    let qty = 0;
    let amount = 0;
    for (const s of group) {
      const t = visibleTotals(s.order.items ?? []);
      qty += t.qty;
      amount += t.amount;
    }
    // group 已依時間新→舊，第一筆就是這次結單的最後一個動作
    const head = group[0];
    const key = `v:${head.pickedAt}:${head.order.id}`;
    nodes.push({
      kind: "visit",
      key,
      visit: {
        key,
        pickedAt: head.pickedAt,
        storeName: head.order.store_name,
        orderCount: new Set(group.map((s) => s.order.id)).size,
        qty,
        amount,
      },
    });
    // 標題用最後一個動作的時間（＝結單完成），底下的卡片照櫃台實際結的順序
    // 由舊到新排 —— 一路往下讀就是那一次結單的過程，像一張收據。
    for (const s of [...group].reverse()) {
      nodes.push({
        kind: "order",
        key: `${key}:${s.order.id}:${(s.order.items ?? [])[0]?.id ?? 0}`,
        order: s.order,
      });
    }
    group = [];
  };

  for (const s of slices) {
    const prev = group[group.length - 1];
    const sameVisit =
      prev != null &&
      prev.storeKey === s.storeKey &&
      new Date(prev.pickedAt).getTime() - new Date(s.pickedAt).getTime() <= VISIT_GAP_MS;
    if (!sameVisit) flush();
    group.push(s);
  }
  flush();

  for (const o of orphans) {
    nodes.push({ kind: "order", key: `o:${o.id}:${(o.items ?? [])[0]?.id ?? 0}`, order: o });
  }
  return nodes;
}

const WEEKDAY = ["日", "一", "二", "三", "四", "五", "六"];

/** 結單標題的時間字樣：`8/12（三）15:32`（今年不印年份） */
export function formatVisitWhen(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  const y = d.getFullYear() === new Date().getFullYear() ? "" : `${d.getFullYear()}/`;
  return `${y}${d.getMonth() + 1}/${d.getDate()}（${WEEKDAY[d.getDay()]}）${hh}:${mm}`;
}

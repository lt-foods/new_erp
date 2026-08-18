// 「已完成」分頁的結單分組 —— 把已取貨的品項還原成「客人那一次到店拿走的組合」。
//
// 為什麼要有這個：訂單是**依團**開的，取貨是**依人**結的。客人一趟到店常常一次
// 拿走三、四個團的貨、當場付一次現金；但「已完成」分頁是照訂單平鋪的，那一次
// 到底拿了什麼、付了多少，客人自己在 app 上永遠拼不回來（店裡有印小白單，
// 手機上沒有）。店家因此要客人傳截圖、再由客服對著後台一張一張猜。
//
// 資料來源是 order_pickup_events（append-only，`/pickup/print` 的收據也是印它）：
// 一次櫃台結單 = 每張訂單各一筆事件（「一次全取」逐張呼叫 rpc_record_pickup），
// 所以把時間相近、同一家店的事件併回一組，就是那一次的結單組合。
//
// ⚠️ 這份邏輯在後台「會員畫面」有一份一模一樣的副本（會員來問時客服要看到跟團友
//    手機上完全相同的畫面）：apps/admin/src/lib/pickupVisits.ts。改這邊記得改那邊。
//
// 金額刻意不另立口徑：一次結單的金額 = 底下那幾張卡片各自的金額相加
// （＝該次取走品項的貨值）。訂單層級的折扣 / 運費沒有按行分攤，分身卡本來就是
// 這個算法（見 OrderCard 的 cardPayable），跟著它走畫面才會自洽 —— 標題的數字
// 跟卡片加起來對不上，是這個 repo 反覆被回報的老問題。

import type { OrderItem, OrderRow, PickupEvent } from "@/components/OrderCard";

/**
 * 同一「次」結單的判定：同一家店 + 相鄰兩筆事件間隔 ≤ 10 分鐘。
 *
 * 店員「一次全取」是一張單一張單連續呼叫 RPC，實務上整批落在幾秒內；抓 10 分鐘
 * 是留給「先結一張、翻單、再結一張」這種櫃台節奏。同一天下午再跑一趟（間隔以
 * 小時計）會正確地分成兩次。
 */
const VISIT_GAP_MS = 10 * 60 * 1000;

/** 一次到店結單 */
export type PickupVisit = {
  key: string;
  /** 這一次最後一筆取貨事件的時間（＝櫃台結單完成的時間） */
  pickedAt: string;
  storeName: string | null;
  /** 這一次涉及幾張訂單 */
  orderCount: number;
  /** 這一次拿走幾件 */
  qty: number;
  /** 這一次的商品金額（＝底下各卡片金額相加） */
  amount: number;
};

/**
 * 「已完成」分頁的渲染節點：結單標題，或標題底下的一張訂單卡。
 * 沒有取貨紀錄的卡片（舊資料 / liff-api 還沒部署）就是沒有標題的 order 節點。
 */
export type DoneNode =
  | { kind: "visit"; key: string; visit: PickupVisit }
  | { kind: "order"; key: string; order: OrderRow };

/** 這張卡片實際列出來的貨值 / 件數（＝ OrderCard 的 visibleItemsTotal / totalQty） */
function cardTotals(items: OrderItem[]): { qty: number; amount: number } {
  let qty = 0;
  let amount = 0;
  for (const it of items) {
    if (["cancelled", "expired"].includes(it.status)) continue;
    qty += Number(it.qty ?? 0);
    amount += Number(it.subtotal ?? 0);
  }
  return { qty, amount };
}

type Slice = {
  order: OrderRow;
  pickedAt: string;
  /** 分組用：同一家店才可能是同一次到店（跨店不可能同時發生） */
  storeKey: string;
};

/**
 * 把「已完成」分桶（每張單只帶已取品項的分身）再依取貨事件拆一次，
 * 然後把時間相近的併成一次結單。
 *
 * 一張單分兩次取完 → 拆成兩張卡，各自掛在自己那一次結單底下（這正是要看的東西）。
 * 對不到任何事件的品項 → 收在最後，維持原本的平鋪樣子。
 */
export function buildDoneNodes(doneOrders: OrderRow[]): DoneNode[] {
  const slices: Slice[] = [];
  const orphans: OrderRow[] = [];

  for (const o of doneOrders) {
    const events: PickupEvent[] = [...(o.pickups ?? [])].sort((a, b) => a.id - b.id);
    const used = new Set<number>();
    for (const ev of events) {
      const ids = new Set((ev.item_ids ?? []).map(Number));
      // 只認「現在還是已取貨」的行：撤銷取貨會把行改回去，事件卻永遠留著
      const items = o.items.filter((it) => ids.has(Number(it.id)));
      if (items.length === 0) continue;
      for (const it of items) used.add(Number(it.id));
      slices.push({
        order: { ...o, items },
        pickedAt: ev.picked_at,
        storeKey: String(o.store_name ?? ""),
      });
    }
    const rest = o.items.filter((it) => !used.has(Number(it.id)));
    if (rest.length > 0) orphans.push({ ...o, items: rest });
  }

  // 新的結單排前面（「已完成」看的是「我最近拿了什麼」，不是「我最早訂了什麼」）
  slices.sort((a, b) => new Date(b.pickedAt).getTime() - new Date(a.pickedAt).getTime());

  const nodes: DoneNode[] = [];
  let group: Slice[] = [];

  const flush = () => {
    if (group.length === 0) return;
    let qty = 0;
    let amount = 0;
    for (const s of group) {
      const t = cardTotals(s.order.items);
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
        key: `${key}:${s.order.id}:${s.order.items[0]?.id ?? 0}`,
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
    nodes.push({ kind: "order", key: `o:${o.id}:${o.items[0]?.id ?? 0}`, order: o });
  }
  return nodes;
}

/** 節點列表裡的訂單卡數量（分頁用；結單標題不算一筆） */
export function countOrderNodes(nodes: DoneNode[]): number {
  return nodes.reduce((n, x) => (x.kind === "order" ? n + 1 : n), 0);
}

/**
 * 只取前 n 張訂單卡（結單標題跟著它的卡片走）。
 * 標題落在切點上、底下一張卡都沒有時要丟掉，不然會出現孤兒標題。
 */
export function takeOrderNodes(nodes: DoneNode[], n: number): DoneNode[] {
  const out: DoneNode[] = [];
  let count = 0;
  for (const node of nodes) {
    if (node.kind === "order") {
      if (count >= n) break;
      count += 1;
    }
    out.push(node);
  }
  while (out.length > 0 && out[out.length - 1].kind === "visit") out.pop();
  return out;
}

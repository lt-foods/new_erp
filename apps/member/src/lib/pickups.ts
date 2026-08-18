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
 * 「已完成」分頁的一組：一次到店結單 + 那一次拿走的訂單卡。
 * visit 是 null 代表「對不到取貨紀錄」的那一落（舊資料 / liff-api 還沒部署），
 * 不畫外框、維持原本平鋪的樣子。
 */
export type PickupGroup = {
  key: string;
  visit: PickupVisit | null;
  orders: OrderRow[];
};

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
 * 對不到任何事件的品項 → 收在最後那一組（visit = null），維持原本的平鋪樣子。
 */
export function buildDoneGroups(doneOrders: OrderRow[]): PickupGroup[] {
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

  const groups: PickupGroup[] = [];
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
    groups.push({
      key,
      visit: {
        key,
        pickedAt: head.pickedAt,
        storeName: head.order.store_name,
        orderCount: new Set(group.map((s) => s.order.id)).size,
        qty,
        amount,
      },
      // 標題用最後一個動作的時間（＝結單完成），底下的卡片照櫃台實際結的順序
      // 由舊到新排 —— 一路往下讀就是那一次結單的過程，像一張收據。
      orders: [...group].reverse().map((s) => s.order),
    });
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

  if (orphans.length > 0) groups.push({ key: "no-visit", visit: null, orders: orphans });
  return groups;
}

/** 所有組別加起來的訂單卡數量（分頁用；結單標題不算一筆） */
export function countGroupOrders(groups: PickupGroup[]): number {
  return groups.reduce((n, g) => n + g.orders.length, 0);
}

/** 只取前 n 張訂單卡（整組被切到剩 0 張時整組不畫，不要留一個空外框） */
export function takeGroupOrders(groups: PickupGroup[], n: number): PickupGroup[] {
  const out: PickupGroup[] = [];
  let left = n;
  for (const g of groups) {
    if (left <= 0) break;
    out.push(g.orders.length <= left ? g : { ...g, orders: g.orders.slice(0, left) });
    left -= g.orders.length;
  }
  return out;
}

const WEEKDAY = ["日", "一", "二", "三", "四", "五", "六"];

/** 結單標題的時間字樣：`8/12（三）15:32`（今年不印年份，一行塞得下） */
export function formatVisitWhen(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  const y = d.getFullYear() === new Date().getFullYear() ? "" : `${d.getFullYear()}/`;
  return `${y}${d.getMonth() + 1}/${d.getDate()}（${WEEKDAY[d.getDay()]}）${hh}:${mm}`;
}

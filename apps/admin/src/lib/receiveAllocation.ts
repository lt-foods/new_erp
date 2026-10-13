// 收貨配單「預設勾誰」的計算（純函式，不碰 React、不碰資料庫），單獨測試：
//   node --test apps/admin/src/lib/receiveAllocation.test.mjs
//
// ⛔ 收貨視窗（components/ManualAllocateModal 的 receive 模式）與依客人分貨單
//    （transfers/print-sort）共用，挑法只能改這裡。兩邊各寫一份的話，倉庫照分貨單
//    分好的袋子，會跟門市按收貨時系統預設勾的客人對不上 —— 貨配給 A、通知發給 B。
//
// - BudgetRow / IncomingRow / CandidateOrder、greedyItemsByTime、normalizeReceivePreview：
//   從 ManualAllocateModal 原樣搬過來（只加 export），收貨視窗的行為不變。
// - buildSortSheet：分貨單用。把預設勾選拆成「這車分給客人」「門市現貨」「這車分剩的」。

export type BudgetRow = {
  sku_id: number;
  sku_code: string | null;
  name: string;
  cap: number; // 可配上限（receive 模式 = 既有可配 + 本次到貨；原始值可為負時已含在內）
  pool: number; // 【內部】店現貨池既有未取掛帳（receive 模式伺服端回傳；store 模式 0）
};

export type IncomingRow = { sku_id: number; sku_code: string | null; name: string; qty: number };

export type CandidateOrder = {
  order_id: number;
  order_no: string;
  member_id: number | null;
  customer: string | null;
  campaign_name: string | null;
  created_at: string;
  // 單頭狀態（receive 模式伺服端回傳；store 模式候選必為 confirmed 且閘門已過）
  status: string;
  arrived: boolean;
  // receive 模式逐品項（有 item_id，品項層級配貨用）；store 模式仍是 SKU 加總（無 item_id）
  items: Array<{ item_id?: number; sku_id: number; qty: number; backordered?: boolean }>;
};

// 依下單時間由早到晚、逐「品項」勾滿為止（伺服端已排好單序）。
// 品項層級（20260824050000）：多品項單裝不下全部時，裝得下的那幾項照給、
// 其餘轉待到貨 —— 不再整張鎖死。回傳的是 item_id 集合。
export function greedyItemsByTime(
  orders: CandidateOrder[],
  caps: Map<number, number>,
  onlyWithin?: Set<number>,
): Set<number> {
  const used = new Map<number, number>();
  const next = new Set<number>();
  for (const o of orders) {
    for (const it of o.items) {
      if (it.item_id == null) continue;
      if (onlyWithin && !onlyWithin.has(it.item_id)) continue;
      if (it.qty <= (caps.get(it.sku_id) ?? 0) - (used.get(it.sku_id) ?? 0)) {
        next.add(it.item_id);
        used.set(it.sku_id, (used.get(it.sku_id) ?? 0) + it.qty);
      }
    }
  }
  return next;
}

// 收貨視窗 loadPreview 的「預覽 RPC 回傳 → 正規化 → 可配上限（cap）」。
// 數量一律過 Number()（跟收貨視窗原本一樣，回傳是字串也照算）。
export function normalizeReceivePreview(d: unknown) {
  const raw = d as {
    store_id: number | null;
    incoming: IncomingRow[];
    budget: Array<{
      sku_id: number;
      sku_code: string | null;
      name: string;
      available: number;
      pool?: number;
    }>;
    orders: CandidateOrder[];
  };
  const incoming = (raw.incoming ?? []).map((r) => ({ ...r, qty: Number(r.qty) }));
  const incMap = new Map(incoming.map((r) => [r.sku_id, r.qty]));
  const orders = (raw.orders ?? []).map((o) => ({
    ...o,
    status: o.status ?? "confirmed",
    arrived: Boolean(o.arrived),
    items: (o.items ?? []).map((i) => ({
      item_id: i.item_id,
      sku_id: i.sku_id,
      qty: Number(i.qty),
      backordered: Boolean(i.backordered),
    })),
  }));
  // 可配上限 = 既有可配（可能為負；伺服端已把畫面上的派貨中單從「已承諾」
  // 排除）+ 本次到貨 —— 跟確認收貨後伺服端算出的預算一致
  const budgetRows = (raw.budget ?? []).map((b) => ({
    sku_id: b.sku_id,
    sku_code: b.sku_code,
    name: b.name,
    cap: Number(b.available) + (incMap.get(b.sku_id) ?? 0),
    pool: Number(b.pool) || 0,
  }));
  return { incoming, orders, budgetRows };
}

// ------------------------------------------------------------
// 依客人分貨單（transfers/print-sort）
// ------------------------------------------------------------

/** 分貨單上的一行：某位客人的某個商品要幾個（同一段裡同商品合成一行） */
export type SortSheetLine = { sku_id: number; sku_code: string | null; name: string; qty: number };

/** 分貨單上的一段＝一個袋子：同一個 member_id 合成一段；member_id 是 null 的一張單一段（不併同名） */
export type SortSheetCustomer = {
  key: string;
  member_id: number | null;
  customer: string;
  order_nos: string[]; // 照下單時間
  lines: SortSheetLine[]; // 照到貨清單的商品順序（不在這車的商品排在後面）
  qty: number;
};

/** 每個商品的對數（頁尾只印 inTruck 的；不在這車的只會出現在門市現貨段） */
export type SortSheetSku = {
  sku_id: number;
  sku_code: string | null;
  name: string;
  inTruck: boolean; // 這車有沒有這個商品（pv.incoming）
  shipped: number; // 這車到貨（派出）量；不在這車＝0
  toCustomers: number; // 這車分給客人的量（≤ shipped）
  surplus: number; // 這車分剩的 = shipped − toCustomers（沒裝進任何客人袋子）
  fromStore: number; // 預設勾選裡不由這車出的量：門市現有庫存拿
  fillDeficit: number; // 門市帳上原本不足（available < 0），這車分剩的會先補掉的量（≤ surplus）
};

export type SortSheet<M> = {
  meta: M; // 呼叫端帶進來的單頭資料（派貨單號等），原樣帶出，計算不看它
  customers: SortSheetCustomer[]; // 這車：倉庫照這段分袋
  fromStore: SortSheetCustomer[]; // 門市現貨：倉庫不用分，門市交貨時從現有庫存拿
  skus: SortSheetSku[]; // 這車的商品（照到貨清單）＋ 被勾到但不在這車的商品
};

const SORT_SHEET_NO_NAME = "（無名字）";

// 數量欄位是 NUMERIC（最多三位小數），加減後取到三位，避免 0.1+0.2 這種浮點尾數印上紙
const roundQty = (n: number) => Math.round(n * 1000) / 1000;

/**
 * 把收貨視窗的預設勾選（selectedItemIds，＝ greedyItemsByTime 的結果）拆成分貨單。
 * 固定成立：每個被勾的商品「這車 ＋ 門市現貨 ＝ 視窗預設勾選」，這車的商品「這車 ＋ 分剩 ＝ 到貨」。
 * - 照訂單順序（伺服端已依下單時間排好，跟 greedyItemsByTime 同一個順序）逐項累計：
 *   每個商品累計到「本車到貨量」為止算「這車」，超過的算「門市現貨」；
 *   同一項跨過界線就拆成兩段（前段這車、後段門市現貨）。
 *   會超過是因為收貨視窗的可配上限 = 既有可配（店裡原本多的）＋ 本次到貨。
 * - 被勾到、但這車根本沒有的商品（多品項單的其他品項，收貨視窗用門市現有庫存勾給客人）：
 *   整項算「門市現貨」—— 門市按收貨時會一起配給客人、一起通知，交貨時要從現貨拿。
 *   品名／編號取 budgetRows（預覽的 budget 種子含候選單全部 SKU）。
 * - 分剩 = 到貨量 − 這車分出量。既有可配為負（門市帳上已經欠）時，
 *   分剩的有一部分會先補掉那個缺口，另外記在 fillDeficit。
 * - 客人依名字排序（zh-TW）；同名照下單時間（sort 是穩定排序）。
 */
export function buildSortSheet<M>(
  pv: { incoming: IncomingRow[]; orders: CandidateOrder[]; budgetRows: BudgetRow[] },
  selectedItemIds: Set<number>,
  transferMeta: M,
): SortSheet<M> {
  // 商品排序：這車的照到貨清單，不在這車的照 budget 順序，兩邊都沒有的照出現順序
  const skuOrder = new Map<number, number>();
  for (const id of [...pv.incoming.map((r) => r.sku_id), ...pv.budgetRows.map((b) => b.sku_id)]) {
    if (!skuOrder.has(id)) skuOrder.set(id, skuOrder.size);
  }
  const budgetOf = new Map(pv.budgetRows.map((b) => [b.sku_id, b]));
  const skus = new Map<number, SortSheetSku>();
  const truckLeft = new Map<number, number>();
  for (const r of pv.incoming) {
    skus.set(r.sku_id, {
      sku_id: r.sku_id,
      sku_code: r.sku_code,
      name: r.name,
      inTruck: true,
      shipped: r.qty,
      toCustomers: 0,
      surplus: 0,
      fromStore: 0,
      fillDeficit: 0,
    });
    truckLeft.set(r.sku_id, r.qty);
  }
  const skuOf = (skuId: number): SortSheetSku => {
    let s = skus.get(skuId);
    if (!s) {
      const b = budgetOf.get(skuId);
      s = {
        sku_id: skuId,
        sku_code: b?.sku_code ?? null,
        name: b?.name || `#${skuId}`,
        inTruck: false,
        shipped: 0,
        toCustomers: 0,
        surplus: 0,
        fromStore: 0,
        fillDeficit: 0,
      };
      skus.set(skuId, s);
      if (!skuOrder.has(skuId)) skuOrder.set(skuId, skuOrder.size);
    }
    return s;
  };

  const truck = new Map<string, SortSheetCustomer>();
  const store = new Map<string, SortSheetCustomer>();
  const put = (
    section: Map<string, SortSheetCustomer>,
    o: CandidateOrder,
    sku: SortSheetSku,
    qty: number,
  ) => {
    const key = o.member_id != null ? `m:${o.member_id}` : `o:${o.order_id}`;
    let c = section.get(key);
    if (!c) {
      c = {
        key,
        member_id: o.member_id,
        customer: o.customer?.trim() || SORT_SHEET_NO_NAME,
        order_nos: [],
        lines: [],
        qty: 0,
      };
      section.set(key, c);
    }
    if (!c.order_nos.includes(o.order_no)) c.order_nos.push(o.order_no);
    const line = c.lines.find((l) => l.sku_id === sku.sku_id);
    if (line) line.qty = roundQty(line.qty + qty);
    else c.lines.push({ sku_id: sku.sku_id, sku_code: sku.sku_code, name: sku.name, qty });
    c.qty = roundQty(c.qty + qty);
  };

  for (const o of pv.orders) {
    for (const it of o.items) {
      if (it.item_id == null || !selectedItemIds.has(it.item_id)) continue;
      if (!(it.qty > 0)) continue; // 0 個（或怪資料）不印、不算
      const sku = skuOf(it.sku_id);
      const left = truckLeft.get(it.sku_id) ?? 0; // 不在這車＝0 → 整項門市現貨
      const fromTruck = Math.min(it.qty, Math.max(left, 0));
      const fromStore = roundQty(it.qty - fromTruck);
      if (fromTruck > 0) {
        put(truck, o, sku, fromTruck);
        truckLeft.set(it.sku_id, roundQty(left - fromTruck));
        sku.toCustomers = roundQty(sku.toCustomers + fromTruck);
      }
      if (fromStore > 0) {
        put(store, o, sku, fromStore);
        sku.fromStore = roundQty(sku.fromStore + fromStore);
      }
    }
  }

  const capOf = new Map(pv.budgetRows.map((b) => [b.sku_id, b.cap]));
  for (const sku of skus.values()) {
    if (!sku.inTruck) continue;
    sku.surplus = roundQty(sku.shipped - sku.toCustomers);
    // cap = 既有可配 + 本次到貨 → 既有可配 = cap − 到貨（查不到 cap 就當 0，不加小註）
    const available = roundQty((capOf.get(sku.sku_id) ?? sku.shipped) - sku.shipped);
    sku.fillDeficit = available < 0 ? Math.min(-available, sku.surplus) : 0;
  }

  const rank = (skuId: number) => skuOrder.get(skuId) ?? 0;
  const finish = (section: Map<string, SortSheetCustomer>) =>
    Array.from(section.values())
      .map((c) => ({ ...c, lines: [...c.lines].sort((a, b) => rank(a.sku_id) - rank(b.sku_id)) }))
      .sort((a, b) => a.customer.localeCompare(b.customer, "zh-TW"));

  return {
    meta: transferMeta,
    customers: finish(truck),
    fromStore: finish(store),
    skus: Array.from(skus.values()).sort(
      (a, b) => Number(b.inTruck) - Number(a.inTruck) || rank(a.sku_id) - rank(b.sku_id),
    ),
  };
}

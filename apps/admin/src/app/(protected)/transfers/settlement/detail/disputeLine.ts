// 月結明細頁「店家爭議」每一筆對到哪一行明細的純函式（不碰 React、不碰資料庫），單獨測試：
//   node --test "apps/admin/src/app/(protected)/transfers/settlement/detail/disputeLine.test.mjs"
//
// 爭議只錨定 transfer_item_id，外加提出當下的行快照 item_snapshot
// （entry_type, description, sku_id, qty_received, branch_amount, received_at；
//   唯一寫入處 rpc_store_review_settlement，20260715000120）。快照沒有單價、也沒有調撥單 id。
// 月結重算（draft／sent／disputed）會把明細整批刪掉重建，明細行的 id 會變、行也可能不見
// （產生月結的函式最新版 20260907030000），所以用 transfer_item_id＋類型去對「目前」的明細：
//   對得到 → 數量、單價、金額、調撥單都用目前那一行（跟下面明細表看到的一樣）；
//   對不到 → 只剩快照的數字，畫面標「此筆已不在目前月結明細」。
// 只決定要顯示什麼，爭議流程（標記已處理、重新送單）完全不經過這裡。

type Num = number | string;

/** 明細頁已載入的月結明細（只列這裡用得到的欄位；PostgREST 的 numeric 可能是字串） */
export type DisputeLineItem = {
  id: number;
  transfer_id: number;
  transfer_item_id: number;
  sku_id: number;
  qty_received: Num;
  unit_branch_price: Num | null;
  branch_amount: Num | null;
  received_at: string;
  entry_type: string;
  description: string | null;
};

export type DisputeLineSnapshot = {
  entry_type?: string;
  description?: string | null;
  sku_id?: number | null;
  qty_received?: Num | null;
  branch_amount?: Num | null;
  received_at?: string | null;
};

export type DisputeLineDispute = {
  transfer_item_id: number;
  item_snapshot: DisputeLineSnapshot | null;
  status: "open" | "resolved";
};

const FREE_TYPES = new Set(["free_in", "free_out"]);

/**
 * 這筆爭議對到目前明細的哪一行；對不到 → null。
 * 條件：transfer_item_id 相同、且類型相同（快照沒記類型時只比 transfer_item_id）。
 * 同一張月結裡同一組照理只有一行；萬一有多行，取第一行。
 */
export function findDisputeItem<T extends DisputeLineItem>(items: readonly T[], d: DisputeLineDispute): T | null {
  const snapType = d.item_snapshot?.entry_type;
  return (
    items.find(
      (it) => Number(it.transfer_item_id) === Number(d.transfer_item_id) && (!snapType || it.entry_type === snapType),
    ) ?? null
  );
}

/** 爭議那一行要顯示的內容（文字怎麼排由畫面決定） */
export type DisputeLineView = {
  entryType: string | null;
  receivedAt: string | null;
  /** 有值就顯示它（自由轉貨的描述），否則用 skuId 查商品名 */
  description: string | null;
  skuId: number | null;
  qty: number | null;
  /** 單價；自由轉貨（明細表也顯示「—」）或對不到明細時是 null */
  unitPrice: number | null;
  amount: number | null;
  /** 對得到明細時的調撥單 id（查單號用）；對不到是 null */
  transferId: number | null;
  /** 對得到的那一行明細 id（「看明細那一行」捲動用）；對不到是 null */
  itemId: number | null;
  /** 店家提出當下的金額，只在跟目前那一行不同時才有值（例：之後改過估價） */
  raisedAmount: number | null;
  /** true ＝明細確定已載入、卻找不到這一行（月結重算後那行不見了） */
  gone: boolean;
};

const num = (v: Num | null | undefined): number | null => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

/**
 * 組出爭議那一行要顯示的內容。
 * matched：findDisputeItem 的結果；itemsLoaded：明細有沒有成功載入
 * （還沒載入或載入失敗時不能說「已不在明細」，只用快照顯示、不標記）。
 */
export function describeDisputeLine(
  d: DisputeLineDispute,
  matched: DisputeLineItem | null,
  itemsLoaded: boolean,
): DisputeLineView {
  const snap = d.item_snapshot ?? {};
  const snapAmount = num(snap.branch_amount);
  if (matched) {
    const amount = num(matched.branch_amount);
    return {
      entryType: matched.entry_type,
      receivedAt: matched.received_at,
      description: matched.description || null,
      skuId: num(matched.sku_id),
      qty: num(matched.qty_received),
      unitPrice: FREE_TYPES.has(matched.entry_type) ? null : num(matched.unit_branch_price),
      amount,
      transferId: num(matched.transfer_id),
      itemId: matched.id,
      raisedAmount: snapAmount !== null && amount !== null && snapAmount !== amount ? snapAmount : null,
      gone: false,
    };
  }
  return {
    entryType: snap.entry_type ?? null,
    receivedAt: snap.received_at ?? null,
    description: snap.description || null,
    skuId: num(snap.sku_id),
    qty: num(snap.qty_received),
    unitPrice: null,
    amount: snapAmount,
    transferId: null,
    itemId: null,
    raisedAmount: null,
    gone: itemsLoaded,
  };
}

/**
 * 明細表每一行（明細 id）掛著的爭議狀態：有任何一筆未處理 → "open"，否則有已處理的 → "resolved"。
 * 沒有爭議的行不在 Map 裡。
 */
export function disputeStatusByItemId(
  items: readonly DisputeLineItem[],
  disputes: readonly DisputeLineDispute[],
): Map<number, "open" | "resolved"> {
  const out = new Map<number, "open" | "resolved">();
  for (const d of disputes) {
    const it = findDisputeItem(items, d);
    if (!it) continue;
    if (d.status === "open") out.set(it.id, "open");
    else if (!out.has(it.id)) out.set(it.id, "resolved");
  }
  return out;
}

/**
 * skus 對照表要查哪些商品：明細的 sku_id ＋ 爭議快照的 sku_id（那一行剛好不在明細裡時也查得到名字）。
 * 去重、去掉空值，依出現順序。
 */
export function skuIdsToLoad(
  items: readonly { sku_id: number | null }[],
  disputes: readonly DisputeLineDispute[],
): number[] {
  const ids = new Set<number>();
  for (const it of items) {
    const n = num(it.sku_id);
    if (n !== null) ids.add(n);
  }
  for (const d of disputes) {
    const n = num(d.item_snapshot?.sku_id);
    if (n !== null) ids.add(n);
  }
  return Array.from(ids);
}

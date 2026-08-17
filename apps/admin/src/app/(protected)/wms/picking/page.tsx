"use client";

// 批次撿貨工作站 v4 — 從總倉庫存派出（平板優化）
// - 上方下拉篩選：開團 / 商品 / 時間（結團時間區間），先縮小範圍再分配
// - 矩陣：SKU × 分店，只顯示篩選範圍內有需求的分店欄；點「需 N」一鍵填入
// - 提交時依 PO 自動 FIFO 切分多張 wave（邏輯與 v3 相同，未動）
// - 「依分店」：純檢視，每家店看到的 (PO × SKU) 待撿明細（吃同一組篩選）
// - 開團對應（po_item → campaign）由前端撈 purchase_request_items /
//   purchase_request_campaigns 組出來，與 view 的 po_campaigns CTE 同構，
//   不動 v_picking_demand_by_po（CREATE OR REPLACE VIEW 欄位順序限制多、風險高）。

import Link from "next/link";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { compareStoreOrder } from "@/lib/storeOrder";
import SpinButton from "@/components/SpinButton";
import { useAuth } from "@/components/AuthProvider";

type DemandRow = {
  po_id: number;
  po_no: string;
  po_status?: string;
  supplier_id: number;
  po_item_id: number;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  qty_ordered: number;
  gr_qty: number;
  qty_in_transit?: number;
  qty_shortage?: number;
  store_id: number | null;
  store_code: string | null;
  store_name: string | null;
  demand_qty: number;
  wave_qty: number;
  shipped_qty: number;
  is_restock_sourced?: boolean;
  // per (po_id, sku_id) 跨 store 已派真值（wave ＋ 補貨直派 transfer，與 RPC 守衛對齊）。
  // 同 (po, sku) 各 row 共享同值；NULL fallback 給未套 migration 的本地環境（會偏低，但不會 crash）。
  po_sku_already_wave?: number | null;
  // per (po_id, sku_id) 是否還有任一分店「需求 > 已派」。矩陣視角 server-side 過濾用。
  has_demand_left?: boolean;
};

type Supplier = { id: number; code: string; name: string };
type AllocKey = string; // `${sku_id}:${store_id}`
type ViewMode = "matrix" | "by_store";
// 現行成本價 / 分店價是否已設定（出貨守衛 _missing_dispatch_prices 的前端預警）
type PriceFlags = { cost: boolean; branch: boolean };

type CampaignInfo = {
  id: number;
  campaign_no: string;
  name: string;
  start_at: string | null;
  end_at: string | null;
  status: string;
};
type TimeFilter = "all" | "7" | "14" | "30" | "90";

type RestockRow = {
  restock_request_id: number;
  restock_status: string;
  store_id: number;
  store_code: string | null;
  store_name: string | null;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  demand_qty: number;
  gr_qty: number;        // HQ on_hand
  wave_qty: number;      // 已撿
};

function defaultWaveDate() {
  const d = new Date();
  d.setDate(d.getDate() + 1); // 預設配送日 = 隔天
  return d.toLocaleDateString("sv-SE");
}

// ===== 已挑清單（步驟 1 挑好的商品）的外部儲存 =====
// key 帶 tenant + user：樓下的人共用現場 iPad，A 挑的東西不可以殘留給 B。
// 拿不到 tenant / user（舊 DB 未套 tenants migration、或 session 還沒到）就不落地，
// 退回純 session 暫存 —— 不用預設值硬湊，寧可不持久化也不要串到別人的清單。
const PICKED_KEY_PREFIX = "wms-picking-picked-v2";
function pickedStorageKeyFor(tenantId: string | null | undefined, userId: string | null | undefined) {
  return tenantId && userId ? `${PICKED_KEY_PREFIX}:${tenantId}:${userId}` : null;
}

// 用 useSyncExternalStore 訂閱這個 module store，而不是 useState + effect 載入。理由：
//   1. tenant 是登入後才用 rpc_get_my_tenant 非同步拿到的 → storage key 晚一步才成立。
//      用 effect 載入會在 key 到位那一刻「用存檔覆蓋掉使用者剛挑好的東西」。
//   2. 跨分頁同步（storage 事件）天生就是外部 store 的訂閱，順手解掉。
//   3. 不需要在 effect body 裡 setState。
let pickedSkuIds: number[] = [];          // 唯一真相；localStorage 只是鏡像
let pickedOwnerKey: string | null = null; // 目前可以寫進哪一把 key；null = 不落地
// 是否曾經綁定過任何一把 key。用來分辨 pickedOwnerKey === null 的兩種來源：
//   (a) 從頭到現在都還沒拿到身分（tenant 非同步載入中）→ 記憶體裡的挑選是「還沒存檔的草稿」，
//       key 一到位要把它寫下去，否則使用者剛挑好的東西會掉。
//   (b) 曾經有身分、後來沒了（登出／session 失效）→ 記憶體裡的是「上一個人的」，
//       絕對不可以在下一把 key 綁定時寫進去。
let pickedEverBound = false;
// 「身分世代」：已挑清單的歸屬每換一次（換人、換 scope／換綁 key）就 +1。
// ⛔ 這是跨使用者資料污染的根本防線。React 的 passive effects 是同一輪一起跑的，
//    前面的 effect 換掉了 store 的內容與歸屬，**不會**讓後面 effect 的 closure 跟著更新
//    （阿審第三輪抓到的 P0 就是這個：prune effect 拿 A 的舊 pickedIds 寫進 B 的 key）。
//    所以寫入端必須帶上「它讀到資料時的世代」，對不上就整批拒絕 —— 不只修掉現在這一個洞，
//    以後任何人（含平行 session）新增寫入點也一樣擋得住。
// ⚠️ 每次 +1 之後一定要 emitPicked()，否則畫面上的世代會過期、之後的挑選會被自己擋掉。
let pickedEpoch = 0;
const pickedListeners = new Set<() => void>();
function emitPicked() { for (const l of pickedListeners) l(); }
function subscribePicked(cb: () => void) {
  pickedListeners.add(cb);
  return () => { pickedListeners.delete(cb); };
}
function getPickedSkuIds() { return pickedSkuIds; }
function getPickedEpoch() { return pickedEpoch; }
function readStoredPicked(key: string): number[] {
  try {
    const raw = localStorage.getItem(key);
    const arr = raw ? (JSON.parse(raw) as unknown) : [];
    if (!Array.isArray(arr)) return [];
    return arr.map(Number).filter((n) => Number.isInteger(n) && n > 0);
  } catch {
    return []; // 隱私模式 / JSON 壞掉：當作沒挑過，不讓工作台整頁掛掉
  }
}
function writeStoredPicked(key: string, ids: number[]) {
  try {
    localStorage.setItem(key, JSON.stringify(ids));
  } catch { /* 隱私模式：存不了就算了，畫面照常運作 */ }
}
// 一律寫進 store 目前綁定的 key（pickedOwnerKey）。還沒綁定（拿不到 tenant/user）就只留在記憶體。
// expectedEpoch = 呼叫端「讀到這批資料時」的世代，對不上就整批拒絕（連記憶體都不動）。
// 回傳有沒有寫進去，方便測試與除錯。
function setPickedSkuIds(ids: number[], expectedEpoch: number): boolean {
  if (expectedEpoch !== pickedEpoch) return false; // 換人／換 scope 了 —— 這批是上一個人的，丟掉
  pickedSkuIds = ids;
  if (pickedOwnerKey) writeStoredPicked(pickedOwnerKey, ids);
  emitPicked();
  return true;
}
// storage key 一成立（或換帳號 / 換租戶）就對齊一次。
// 「還沒綁定過」且本機已經挑了東西 → 把它寫下去（tenant 晚到不該讓剛挑的掉）；
// 其他情況（換 key、登出後再登入）→ 一律改讀新 key 的存檔，絕不把前一個帳號的清單帶過去。
function bindPickedStorage(key: string) {
  if (pickedOwnerKey === key) return;
  // ⚠️ 判斷依據是 pickedEverBound，不是 pickedOwnerKey === null。
  //    登出後 pickedOwnerKey 也會是 null，若用它判斷會把上一個人的清單寫進下一個人的 key。
  const draftBeforeAnyIdentity = !pickedEverBound;
  if (draftBeforeAnyIdentity && pickedSkuIds.length > 0) {
    // 同一個人的草稿落地，歸屬沒變 → 不動世代
    writeStoredPicked(key, pickedSkuIds);
  } else {
    // 改讀另一把 key 的存檔 = 歸屬換了 → 世代 +1，並且一定要 emit（讓畫面重新讀到新世代）
    pickedSkuIds = readStoredPicked(key);
    pickedEpoch += 1;
    emitPicked();
  }
  pickedOwnerKey = key;
  pickedEverBound = true;
}
// 身分沒了（登出 / session 失效 / 讀不到 tenant）→ 立刻停止寫 localStorage。
// ⚠️ 不清空記憶體：key 變 null 也可能只是「tenant 還在載入」，清了會把使用者剛挑好的弄丟。
//    上一個人的殘留由 bindPickedStorage 擋（pickedEverBound 為 true 時一律改讀新 key 的存檔）。
function unbindPickedStorage() {
  pickedOwnerKey = null;
}

// 已挑清單目前屬於哪一位使用者（auth user.id）。null = 還不知道是誰。
let pickedUserId: string | null = null;
// 換人就把記憶體裡的已挑清單清掉。
// 為什麼需要這個（storage key 已經隔離了，資料不會汙染）：風險不在資料，在人。
//   樓下共用現場 iPad，A 登出、B 登入，storage key 要等 tenant 的 RPC 回來才成立；
//   在那幾百毫秒裡畫面上還掛著 A 挑好的 30 樣，B 很可能以為是自己挑的，
//   直接按「下一步」→ 建單 → 把 A 要派的貨派出去。這種操作錯誤在現場很難事後發現。
//   user.id 是同步就有的（不必等 tenant），所以能在那個窗口之前先把畫面清乾淨。
// ⚠️ 只有「非 null → 另一個不同的非 null」才算換人。其他轉換一律不清：
//   null → 有值：首次登入 / session 剛載回來，記憶體是這個人自己的草稿，清了就是掉選
//   有值 → null：登出或 session 暫時失效，交給 unbindPickedStorage 停寫入就好
//   同一個 user：什麼都不做
function syncPickedUser(userId: string | null) {
  if (userId === null) return;
  if (pickedUserId === null) { pickedUserId = userId; return; }
  if (pickedUserId === userId) return;
  pickedUserId = userId;
  pickedOwnerKey = null;      // 新的 key 由 bindPickedStorage 接手；在那之前不准寫
  // ⚠️ 不動 pickedEverBound：留 true 才會讓下一次 bind 走「讀新 key 的存檔」那條路。
  //    若把它設回 false，bind 會把現在這個空陣列當成草稿寫下去，反而洗掉 B 自己存好的清單。
  pickedSkuIds = [];
  pickedEpoch += 1;           // 換人 = 歸屬換了 → 舊世代的寫入一律作廢
  emitPicked();
}
// 跨分頁：別的分頁改了同一個 key → 重讀，避免兩個分頁互相覆蓋
function refreshPickedFromStorage(key: string) {
  const stored = readStoredPicked(key);
  const same =
    stored.length === pickedSkuIds.length && stored.every((v, i) => v === pickedSkuIds[i]);
  if (same) return;
  pickedSkuIds = stored;
  emitPicked();
}

// 從 demand 算出「還有可分配量」的 sku_id 集合 —— 條件與 skuRows 的
// filter(totalAvailable > 0) 完全一致（per (po, sku) 去重後 Σgr − Σ已派）。
// 給「已挑清單失效清理」用，避免兩處條件飄移。
function alivePickableSkuIds(demand: DemandRow[]): Set<number> {
  const avail = new Map<number, number>();
  const poSkuSeen = new Set<string>();
  for (const r of demand) {
    if (r.store_id === null) continue; // 與 skuRows 同條件
    const poSkuKey = `${r.po_id}:${r.sku_id}`;
    if (poSkuSeen.has(poSkuKey)) continue;
    poSkuSeen.add(poSkuKey);
    avail.set(
      r.sku_id,
      (avail.get(r.sku_id) ?? 0) + Number(r.gr_qty) - Number(r.po_sku_already_wave ?? 0),
    );
  }
  const alive = new Set<number>();
  for (const [skuId, v] of avail) if (v > 0) alive.add(skuId);
  return alive;
}

// 把「請購單層級」的團清單收斂成「這個商品自己的團」。
//
// 為什麼需要：請購單有三種來源，老闆主要用 close_date（依結單日一次請購當天所有團的商品）。
// rpc_create_supplementary_pr_from_close_date（20260714000060）寫進去的是：
//   - purchase_request_items.source_campaign_id ← 只有 dq.first_campaign_id（該商品的第一團，不完整）
//   - purchase_request_campaigns                ← 該結單日「所有」closed/locked 團（與商品無關，太寬）
// 上面的 mapping 把兩者聯集（與 view 的 po_campaigns CTE 同構），於是一個商品下面會列出
// 那天結單的所有團 —— 老闆實測「安城湯麵」一列列出 24 團，含眼鏡袋、蟑螂剋星。
// campaign_items 才是「這個團真的有賣這個 sku」的唯一真相（UNIQUE (campaign_id, sku_id)），
// 拿它做交集把清單收回來。
//
// ⛔ 只收斂，不製造空集合 —— 三種情況一律原樣回傳（＝維持修改前的行為）：
//    (1) soldBySku 是 null：campaign_items 撈失敗 / 這個 role 讀不到 → 不過濾
//    (2) 這個 sku 一筆 campaign_items 都沒撈到 → 不過濾
//    (3) 交集為空（資料不一致、或需求純粹來自補貨申請而非開團）→ 不過濾
//    寧可多列一團，也不要讓老闆在派貨工作台找不到商品。
//    （商品清單 skuRows 本身不吃這個函式，商品數不會因此變動；見 skuRows 的 filter 條件。）
function narrowToSoldCampaigns(
  soldBySku: Map<number, Set<number>> | null,
  skuId: number,
  campaignIds: Iterable<number>,
): number[] {
  const all = Array.from(campaignIds);
  const sold = soldBySku?.get(skuId);
  if (!sold || sold.size === 0) return all;
  const hit = all.filter((cid) => sold.has(cid));
  return hit.length > 0 ? hit : all;
}

export default function PickingWorkstationPage() {
  const router = useRouter();
  // 矩陣視角只撈「還有庫存可分配」的列（has_stock_left），避免整張 view（線上上萬列）全撈。
  const [demand, setDemand] = useState<DemandRow[] | null>(null);
  // 依分店檢視要看「缺貨待到」的品項 → lazy 撈完整 view（切到該分頁才撈一次）。
  const [fullDemand, setFullDemand] = useState<DemandRow[] | null>(null);
  const [loadingFull, setLoadingFull] = useState(false);
  const [restockDemand, setRestockDemand] = useState<RestockRow[] | null>(null);
  const [suppliers, setSuppliers] = useState<Map<number, Supplier>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [viewMode, setViewMode] = useState<ViewMode>("matrix");

  const [allocs, setAllocs] = useState<Map<AllocKey, number>>(new Map());
  // restock alloc key: `${restock_request_id}:${sku_id}` -> qty
  const [restockAllocs, setRestockAllocs] = useState<Map<string, number>>(new Map());
  const [submitting, setSubmitting] = useState(false);
  const [submittingRrId, setSubmittingRrId] = useState<number | null>(null);
  const [reloadKey, setReloadKey] = useState(0);
  // 步驟 1「已挑清單」＝ sku_id 集合（與建單 scope 同粒度：submitAll 的 FIFO 是 per sku 運作）。
  // ⚠️ 這是獨立集合，絕不與「目前搜尋結果」做交集 —— 舊版就是死在交集上
  //    （搜商品 → 清單只剩 1 列 → 交集後只剩 1 樣，老闆說的「發現只選了一樣」）。
  //    已無可分配量的品項由「失效清理 effect」移除並明示提示（見 prunedNotice 底下）。
  // 存在 module store 裡（含 tenant/user scope、跨分頁同步），細節見檔頭。
  const { user, tenant } = useAuth();
  const authUserId = user?.id ?? null;
  const pickedStorageKey = pickedStorageKeyFor(tenant?.id, authUserId);
  const pickedIds = useSyncExternalStore(subscribePicked, getPickedSkuIds, getPickedSkuIds);
  // 讀到 pickedIds 的那一刻是「第幾世代」。所有寫入都要帶著它，換人後的舊世代寫入會被擋掉。
  const pickedEpoch = useSyncExternalStore(subscribePicked, getPickedEpoch, getPickedEpoch);
  const pickedSkus = useMemo(() => new Set(pickedIds), [pickedIds]);
  // 換人（user.id 從一個非 null 值變成另一個）→ 立刻清掉畫面上的已挑清單。
  // user.id 比 tenant 早到位，所以 B 不會在 tenant 載回來之前看到 A 挑好的東西。
  // ⚠️ 必須排在下面的 bind effect 之前（effect 依宣告順序執行）。
  useEffect(() => {
    syncPickedUser(authUserId);
  }, [authUserId]);
  // storage key 一成立（或換帳號 / 換租戶）就對齊一次；純寫外部系統，沒有 setState。
  // key 變回 null（登出 / session 失效）→ 立刻 unbind，之後的挑選不會再寫進上一個人的 key。
  useEffect(() => {
    if (pickedStorageKey) bindPickedStorage(pickedStorageKey);
    else unbindPickedStorage();
  }, [pickedStorageKey]);
  // 跨分頁：別的分頁改了同一把 key → 重讀（避免兩個分頁互相覆蓋）
  useEffect(() => {
    if (!pickedStorageKey) return;
    const onStorage = (e: StorageEvent) => {
      if (e.key === pickedStorageKey) refreshPickedFromStorage(pickedStorageKey);
    };
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, [pickedStorageKey]);
  // 已挑清單被自動移除時的提示（不靜默處理）
  const [prunedNotice, setPrunedNotice] = useState<string | null>(null);
  // 已挑清單失效清理：把「已無可分配量」（被別人派完 / 下架）的品項移除並提示。
  // ⚠️ 比對基準是「未經任何篩選」的 alivePickableSkuIds(demand)，不是搜尋結果 ——
  //    拿目前清單去交集正是舊版「選了 30 樣、按建單只剩 1 樣」的根因。
  // 放 effect 而不是 fetch 回呼：storage key 晚一步綁定（tenant 是登入後非同步拿到的），
  //    從 localStorage 灌回來的清單也會被重檢，不會因為「demand 先到、清單後到」而漏掉。
  //    清掉 stale 之後 pickedIds 變動會再跑一次，此時已無 stale → 直接 return，不會迴圈。
  // ⚠️⚠️ 一定要讀 live snapshot，不可以用 closure 的 pickedIds：
  //    同一輪 passive effects 裡，上面兩個 effect（換人重置 / 綁新 key）已經換掉 store 的
  //    內容與歸屬，但 React **不會**替這個 effect 更新 closure。用舊的 pickedIds 算出來的
  //    結果會被寫進「新那個人」的 key —— 阿審第三輪抓到的 P0 就是這條。
  //    pickedIds / pickedStorageKey 在依賴陣列裡只當「什麼時候該重檢」的觸發器，值本身不拿來算。
  useEffect(() => {
    if (!demand) return;
    const livePicked = getPickedSkuIds();
    const liveEpoch = getPickedEpoch();
    if (livePicked.length === 0) return;
    const aliveSkus = alivePickableSkuIds(demand);
    const stalePicks = livePicked.filter((id) => !aliveSkus.has(id));
    if (stalePicks.length === 0) return;
    // 對外部系統（module store + localStorage）收斂 + 一次性提示，
    // 本質上就是「effect 同步外部資料」，guard 保證不會連鎖重跑。
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setPrunedNotice(
      `已挑清單有 ${stalePicks.length} 個品項已無可分配量（可能被別人派完或已下架），已自動移除。`,
    );
    setPickedSkuIds(livePicked.filter((id) => aliveSkus.has(id)), liveEpoch);
    // pickedStorageKey 也放進來：明講「這個 effect 是在某個 owner scope 下 prune」，
    // 換人／換 scope 之後要再檢一次，而不是靠 effect 的宣告順序默契。
  }, [demand, pickedIds, pickedStorageKey]);
  // 矩陣分頁的兩步驟：select = 先挑商品；confirm = 確認數量並建單
  const [pickStep, setPickStep] = useState<"select" | "confirm">("select");
  // 缺價預警：sku_id → 現行成本/分店價是否存在。null = 未載入或此 role 看不到價格（不顯示）。
  const [priceFlags, setPriceFlags] = useState<Map<number, PriceFlags> | null>(null);
  const [canFixPrices, setCanFixPrices] = useState(false);
  const [priceEdit, setPriceEdit] = useState<{ skuId: number; scope: "cost" | "branch" } | null>(null);
  const [priceDraft, setPriceDraft] = useState("");

  // ===== 篩選（開團 / 商品 / 時間）＋ 平板顯示選項 =====
  // po_item_id → campaign_ids（前端組的 po_campaigns 對應）。null = 尚未載入。
  const [poItemCampaigns, setPoItemCampaigns] = useState<Map<number, number[]> | null>(null);
  const [campaignsById, setCampaignsById] = useState<Map<number, CampaignInfo> | null>(null);
  // sku_id → 這個 sku 真的被賣過的團（campaign_items）。用來把上面那份過寬的團清單收斂。
  // null = 沒撈到 / 撈失敗 → narrowToSoldCampaigns 一律不過濾（維持現行行為）。
  const [skuSoldCampaigns, setSkuSoldCampaigns] = useState<Map<number, Set<number>> | null>(null);
  // 總倉即時在庫（stock_balances.on_hand @ central_warehouse），純參考顯示。
  const [hqOnHand, setHqOnHand] = useState<Map<number, number> | null>(null);
  const [filterCampaign, setFilterCampaign] = useState<string>("all"); // "all" | "none" | `${campaign_id}`
  // 商品搜尋（取代原本的「商品」單選下拉 —— 單選會把清單縮到 1 列，正是掉選的根因）。
  // 比對 sku_label（商品名稱）＋ sku_code（品號），模糊、不分大小寫、去頭尾空白。
  const [skuQuery, setSkuQuery] = useState("");
  const [filterTime, setFilterTime] = useState<TimeFilter>("all");
  // 預設只顯示「篩選範圍內還有需求」的分店欄（17 間店的矩陣在平板上塞不下）。
  const [showAllStores, setShowAllStores] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setFullDemand(null); // reloadKey 變動（建單後）→ 讓依分店完整清單下次進去重撈
    (async () => {
      try {
        const sb = getSupabase();
        // 全部走 fetchAll 分頁，避免 PostgREST 1000 列上限把整張 PO 截掉。
        // .order() 給分頁一個穩定的 total order（否則跨頁可能漏/重複列）。
        // 矩陣視角只需可分配列 → .eq("has_stock_left", true)：線上 12,240 列 → ~37 列，
        // 13 趟分頁 → 1 趟，解決「派貨工作台讀取不出來」。
        // 再疊 .eq("has_demand_left", true)：需求全派完（含補貨直派、門市已收貨）的
        // 列自動下架 — 補貨帶囤貨的 PO（訂 51 件、需求 1 件）不再永遠掛在工作台。
        const [dRows, supRows, rrRows] = await Promise.all([
          fetchAllRows<DemandRow>(() =>
            sb.from("v_picking_demand_by_po").select("*")
              .eq("has_stock_left", true)
              .eq("has_demand_left", true)
              .order("po_item_id", { ascending: true })
              .order("store_id", { ascending: true, nullsFirst: false }),
          ),
          fetchAllRows<Supplier>(() => sb.from("suppliers").select("id, code, name").order("id", { ascending: true })),
          fetchAllRows<RestockRow>(() =>
            sb.from("v_picking_demand_no_po").select("*")
              .order("restock_request_id", { ascending: true })
              .order("sku_id", { ascending: true }),
          ),
        ]);
        if (cancelled) return;
        setError(null);
        setDemand(dRows);
        setRestockDemand(rrRows);
        // 已挑清單失效清理在獨立的 effect（依賴 demand + pickedIds），不在這個回呼裡做：
        // 回呼只跑一次，若 demand 比 tenant 先到位，此刻 store 還是空的、
        // bind 之後才從 localStorage 灌回來的那批就永遠漏檢（靜默失效）。
        const sm = new Map<number, Supplier>();
        for (const s of supRows) sm.set(s.id, s);
        setSuppliers(sm);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [reloadKey]);

  // 依分店檢視分頁：lazy 撈完整 view（含缺貨待到的品項），只在切到該分頁時撈一次。
  // in-flight 用 ref 而不是 loadingFull state 當 effect dep：
  // 舊寫法 setLoadingFull(true) 會讓 deps 變動 → cleanup 把 cancelled 設 true →
  // 撈回來的資料被丟掉、loadingFull 永遠卡 true，「依分店」分頁永遠顯示載入中。
  const fullDemandInflight = useRef(false);
  useEffect(() => {
    if (viewMode !== "by_store" || fullDemand !== null || fullDemandInflight.current) return;
    fullDemandInflight.current = true;
    let cancelled = false;
    setLoadingFull(true);
    (async () => {
      try {
        const sb = getSupabase();
        const data = await fetchAllRows<DemandRow>(() =>
          sb.from("v_picking_demand_by_po").select("*")
            .order("po_item_id", { ascending: true })
            .order("store_id", { ascending: true, nullsFirst: false }),
        );
        if (!cancelled) setFullDemand(data);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        fullDemandInflight.current = false;
        setLoadingFull(false);
      }
    })();
    return () => { cancelled = true; };
  }, [viewMode, fullDemand]);

  // ===== 缺價預警：抓畫面上所有 SKU 的現行成本價 / 分店價 =====
  // 與 DB 守衛 _missing_dispatch_prices 同條件（scope cost/branch、effective_to IS NULL、price>0）。
  // 只有讀得到 cost/branch 價的 HQ role 才檢查 — 其他 role 被 RLS 濾掉會整片誤判缺價。
  useEffect(() => {
    if (!demand && !restockDemand) return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: sess } = await sb.auth.getSession();
        const role =
          ((sess.session?.user?.app_metadata as { role?: string } | undefined)?.role ?? "");
        if (!["owner", "admin", "hq_manager", "hq_accountant"].includes(role)) {
          if (!cancelled) { setCanFixPrices(false); setPriceFlags(null); }
          return;
        }
        const ids = new Set<number>();
        for (const r of demand ?? []) ids.add(r.sku_id);
        for (const r of restockDemand ?? []) ids.add(r.sku_id);
        const all = Array.from(ids);
        const flags = new Map<number, PriceFlags>();
        for (const id of all) flags.set(id, { cost: false, branch: false });
        for (let i = 0; i < all.length; i += 150) {
          const chunk = all.slice(i, i + 150);
          const { data, error: e } = await sb
            .from("prices")
            .select("sku_id, scope, price")
            .in("scope", ["cost", "branch"])
            .is("effective_to", null)
            .gt("price", 0)
            .in("sku_id", chunk);
          if (e) throw new Error(e.message);
          for (const row of (data ?? []) as { sku_id: number; scope: "cost" | "branch" }[]) {
            const f = flags.get(row.sku_id);
            if (f) f[row.scope] = true;
          }
        }
        if (!cancelled) { setCanFixPrices(true); setPriceFlags(flags); }
      } catch {
        // 缺價檢查失敗不影響工作台主流程，僅不顯示預警
        if (!cancelled) { setCanFixPrices(false); setPriceFlags(null); }
      }
    })();
    return () => { cancelled = true; };
  }, [demand, restockDemand]);

  // ===== 開團對應 + 總倉在庫：demand 載入後補撈（失敗只影響篩選，不影響派貨） =====
  // po_item → campaign 與 view 的 po_campaigns CTE 同構：
  //   pri.po_item_id → prc.campaign_id（PR 掛的開團）∪ pri.source_campaign_id
  useEffect(() => {
    if (!demand) return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const poItemIds = Array.from(new Set(demand.map((r) => r.po_item_id).filter((v) => v != null)));
        const skuIds = Array.from(new Set([
          ...demand.map((r) => r.sku_id),
          ...(restockDemand ?? []).map((r) => r.sku_id),
        ]));

        type PriRow = { po_item_id: number; pr_id: number; source_campaign_id: number | null };
        const priRows: PriRow[] = [];
        for (let i = 0; i < poItemIds.length; i += 200) {
          const { data, error: e } = await sb
            .from("purchase_request_items")
            .select("po_item_id, pr_id, source_campaign_id")
            .in("po_item_id", poItemIds.slice(i, i + 200));
          if (e) throw new Error(e.message);
          priRows.push(...(((data ?? []) as PriRow[])));
        }
        const prIds = Array.from(new Set(priRows.map((r) => r.pr_id)));
        type PrcRow = { pr_id: number; campaign_id: number };
        const prcRows: PrcRow[] = [];
        for (let i = 0; i < prIds.length; i += 200) {
          const { data, error: e } = await sb
            .from("purchase_request_campaigns")
            .select("pr_id, campaign_id")
            .in("pr_id", prIds.slice(i, i + 200));
          if (e) throw new Error(e.message);
          prcRows.push(...(((data ?? []) as PrcRow[])));
        }
        const prToCampaigns = new Map<number, number[]>();
        for (const r of prcRows) {
          prToCampaigns.set(r.pr_id, [...(prToCampaigns.get(r.pr_id) ?? []), r.campaign_id]);
        }
        const mapping = new Map<number, Set<number>>();
        for (const r of priRows) {
          const set = mapping.get(r.po_item_id) ?? new Set<number>();
          if (r.source_campaign_id != null) set.add(r.source_campaign_id);
          for (const c of prToCampaigns.get(r.pr_id) ?? []) set.add(c);
          mapping.set(r.po_item_id, set);
        }

        const campaignIds = Array.from(new Set(Array.from(mapping.values()).flatMap((s) => Array.from(s))));
        const cMap = new Map<number, CampaignInfo>();
        for (let i = 0; i < campaignIds.length; i += 200) {
          const { data, error: e } = await sb
            .from("group_buy_campaigns")
            .select("id, campaign_no, name, start_at, end_at, status")
            .in("id", campaignIds.slice(i, i + 200));
          if (e) throw new Error(e.message);
          for (const c of (data ?? []) as CampaignInfo[]) cMap.set(c.id, c);
        }

        // 「這個團真的有賣這個 sku」對應（campaign_items）—— 把上面那份請購單層級的
        // 過寬清單收回來，用途見 narrowToSoldCampaigns。
        // 兩個維度都分批 200：URL 長度與本檔既有的 .in(...200) 查詢同級（已在線上跑很久）；
        // 每批再走 fetchAllRows 分頁，避免 PostgREST 1000 列靜默截斷把對應撈缺。
        // 失敗只清空 → 下面 set null → 不過濾，跟總倉在庫那塊同樣是「壞了也不擋派貨」。
        const sold = new Map<number, Set<number>>();
        try {
          type CiRow = { campaign_id: number; sku_id: number };
          for (let i = 0; i < skuIds.length; i += 200) {
            const skuChunk = skuIds.slice(i, i + 200);
            for (let j = 0; j < campaignIds.length; j += 200) {
              const campaignChunk = campaignIds.slice(j, j + 200);
              const rows = await fetchAllRows<CiRow>(() =>
                sb.from("campaign_items")
                  .select("campaign_id, sku_id")
                  .in("sku_id", skuChunk)
                  .in("campaign_id", campaignChunk)
                  .order("id", { ascending: true }));
              for (const r of rows) {
                let set = sold.get(r.sku_id);
                if (!set) { set = new Set<number>(); sold.set(r.sku_id, set); }
                set.add(r.campaign_id);
              }
            }
          }
        } catch {
          sold.clear();
        }

        // 總倉即時在庫（有些 role 讀不到 stock_balances → 留 null 不顯示，不報錯）
        const oh = new Map<number, number>();
        try {
          const { data: loc } = await sb
            .from("locations").select("id")
            .eq("type", "central_warehouse").eq("is_active", true).limit(1);
          const hqLocId = (((loc ?? []) as { id: number }[])[0])?.id ?? null;
          if (hqLocId != null) {
            for (let i = 0; i < skuIds.length; i += 200) {
              const { data, error: e } = await sb
                .from("stock_balances")
                .select("sku_id, on_hand")
                .eq("location_id", hqLocId)
                .in("sku_id", skuIds.slice(i, i + 200));
              if (e) throw new Error(e.message);
              for (const r of (data ?? []) as { sku_id: number; on_hand: number }[]) {
                oh.set(r.sku_id, Number(r.on_hand));
              }
            }
          }
        } catch {
          oh.clear();
        }

        if (!cancelled) {
          setPoItemCampaigns(new Map(Array.from(mapping.entries()).map(([k, v]) => [k, Array.from(v)])));
          setCampaignsById(cMap);
          setSkuSoldCampaigns(sold.size > 0 ? sold : null);
          setHqOnHand(oh.size > 0 ? oh : null);
        }
      } catch {
        // 對應載入失敗 → 下拉退化成「全部」，矩陣照常可派
        if (!cancelled) {
          setPoItemCampaigns(new Map());
          setCampaignsById(new Map());
          setSkuSoldCampaigns(null); // null = 不過濾團號（本來就沒團可濾）
          setHqOnHand(null);
        }
      }
    })();
    return () => { cancelled = true; };
  }, [demand, restockDemand]);

  // 補價：呼叫既有價格 wrapper RPC，成功後就地更新旗標（出貨守衛即放行）
  async function savePrice(skuId: number, scope: "cost" | "branch") {
    const val = Number(priceDraft);
    if (!Number.isFinite(val) || val <= 0) return;
    try {
      const sb = getSupabase();
      const { error: e } = await sb.rpc(
        scope === "cost" ? "rpc_set_cost_price" : "rpc_set_branch_price",
        { p_sku_id: skuId, p_price: val, p_reason: "派貨工作台補價" },
      );
      if (e) throw new Error(e.message);
      setPriceFlags((prev) => {
        if (!prev) return prev;
        const next = new Map(prev);
        const cur = next.get(skuId) ?? { cost: false, branch: false };
        next.set(skuId, { ...cur, [scope]: true });
        return next;
      });
      setPriceEdit(null);
      setPriceDraft("");
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  // 缺價 pill（文字標籤）＋ 點擊 inline 補價
  function renderPriceTags(skuId: number) {
    if (!canFixPrices || !priceFlags) return null;
    const f = priceFlags.get(skuId);
    if (!f) return null;
    const missing: ("cost" | "branch")[] = [];
    if (!f.cost) missing.push("cost");
    if (!f.branch) missing.push("branch");
    if (missing.length === 0) return null;
    return (
      <>
        {missing.map((scope) => {
          const label = scope === "cost" ? "缺成本" : "缺分店價";
          const isEditing = priceEdit?.skuId === skuId && priceEdit.scope === scope;
          if (isEditing) {
            const val = Number(priceDraft);
            const valid = Number.isFinite(val) && val > 0;
            return (
              <span key={scope} className="inline-flex items-center gap-1">
                <input
                  type="number"
                  min={0.01}
                  step="0.01"
                  autoFocus
                  value={priceDraft}
                  onChange={(e) => setPriceDraft(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Escape") { setPriceEdit(null); setPriceDraft(""); }
                  }}
                  placeholder={scope === "cost" ? "成本價" : "分店價"}
                  aria-label={`輸入${scope === "cost" ? "成本價" : "分店價"}`}
                  className="w-16 rounded border border-rose-300 px-1 py-0.5 font-mono text-[11px] tabular-nums dark:border-rose-700 dark:bg-zinc-800"
                />
                <SpinButton
                  onClick={() => savePrice(skuId, scope)}
                  disabled={!valid}
                  className="rounded bg-rose-600 px-1.5 py-0.5 text-[10px] font-medium text-white hover:bg-rose-700 disabled:opacity-40"
                >
                  儲存
                </SpinButton>
                <button
                  type="button"
                  onClick={() => { setPriceEdit(null); setPriceDraft(""); }}
                  className="rounded border border-zinc-300 px-1.5 py-0.5 text-[10px] text-zinc-500 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  取消
                </button>
              </span>
            );
          }
          return (
            <button
              key={scope}
              type="button"
              onClick={() => { setPriceEdit({ skuId, scope }); setPriceDraft(""); }}
              title={`此品項尚未設定${scope === "cost" ? "成本價" : "分店價"}，派貨會被擋下 — 點擊直接補價`}
              className="rounded bg-rose-100 px-1 py-0.5 text-[9px] font-medium text-rose-800 hover:bg-rose-200 dark:bg-rose-950 dark:text-rose-300 dark:hover:bg-rose-900"
            >
              {label}
            </button>
          );
        })}
      </>
    );
  }

  // ===== 合併視角資料：每個 (sku, store) 一格，跨 PO 加總 =====
  type StoreInfo = { store_id: number; store_code: string | null; store_name: string };
  type SkuRow = {
    sku_id: number;
    sku_code: string | null;
    sku_label: string;
    poList: {
      po_id: number;
      po_no: string;
      po_status?: string;
      gr_qty: number;
      qty_ordered: number;
      qty_in_transit: number;
      qty_shortage: number;
      already_wave_for_sku: number;
      is_restock_sourced: boolean;
    }[];                                  // 跨 PO 來源(去重)
    storeDemand: Map<number, number>;
    storeWave: Map<number, number>;
    storeShipped: Map<number, number>;
    totalOrdered: number;                 // 總訂購
    totalGr: number;                      // 總已到貨
    totalInTransit: number;               // 總在途(還會到)
    totalShortage: number;                // 總短少(永遠不會到)
    totalAlreadyWave: number;             // 總已撿
    totalAvailable: number;               // 可分配 = totalGr - totalAlreadyWave
    campaignIds: Set<number>;             // 此 SKU 對應的開團（跨 po_item 聯集），篩選用
  };

  const skuRows: SkuRow[] = useMemo(() => {
    if (!demand) return [];
    const grouped = new Map<number, SkuRow>();
    // PO×SKU level dedup（gr_qty 在同 PO 同 SKU 不同 store row 重複出現）
    const poSkuSeen = new Set<string>();
    for (const r of demand) {
      if (r.store_id === null) continue;
      let s = grouped.get(r.sku_id);
      if (!s) {
        s = {
          sku_id: r.sku_id,
          sku_code: r.sku_code,
          sku_label: r.sku_label,
          poList: [],
          storeDemand: new Map(),
          storeWave: new Map(),
          storeShipped: new Map(),
          totalOrdered: 0,
          totalGr: 0,
          totalInTransit: 0,
          totalShortage: 0,
          totalAlreadyWave: 0,
          totalAvailable: 0,
          campaignIds: new Set<number>(),
        };
        grouped.set(r.sku_id, s);
      }
      for (const cid of poItemCampaigns?.get(r.po_item_id) ?? []) s.campaignIds.add(cid);
      const poSkuKey = `${r.po_id}:${r.sku_id}`;
      if (!poSkuSeen.has(poSkuKey)) {
        poSkuSeen.add(poSkuKey);
        const inTransit = Number(r.qty_in_transit ?? 0);
        const shortage = Number(r.qty_shortage ?? 0);
        s.poList.push({
          po_id: r.po_id,
          po_no: r.po_no,
          po_status: r.po_status,
          gr_qty: Number(r.gr_qty),
          qty_ordered: Number(r.qty_ordered),
          qty_in_transit: inTransit,
          qty_shortage: shortage,
          // 用 view 欄位 po_sku_already_wave：per (po, sku) 跨 store 已派真值
          // （wave ＋ 補貨直派 transfer），與 RPC 守衛對齊。
          // fallback 給未套 migration 的本地環境（會偏低）。
          already_wave_for_sku: Number(r.po_sku_already_wave ?? 0),
          is_restock_sourced: !!r.is_restock_sourced,
        });
        s.totalOrdered += Number(r.qty_ordered);
        s.totalGr += Number(r.gr_qty);
        s.totalInTransit += inTransit;
        s.totalShortage += shortage;
      }
      s.storeDemand.set(r.store_id, (s.storeDemand.get(r.store_id) ?? 0) + Number(r.demand_qty));
      s.storeWave.set(r.store_id, (s.storeWave.get(r.store_id) ?? 0) + Number(r.wave_qty));
      s.storeShipped.set(r.store_id, (s.storeShipped.get(r.store_id) ?? 0) + Number(r.shipped_qty));
    }
    // 計算 totals
    for (const s of grouped.values()) {
      s.totalAlreadyWave = s.poList.reduce((sum, p) => sum + p.already_wave_for_sku, 0);
      s.totalAvailable = Math.max(0, s.totalGr - s.totalAlreadyWave);
      s.poList.sort((a, b) => a.po_id - b.po_id);
      // 團清單收斂成「這個商品真的有賣的團」。⚠️ 只換 campaignIds 的內容，
      // 不影響 totalAvailable，所以下面 filter(totalAvailable > 0) 的結果、
      // 也就是「有幾樣商品可以挑」完全不變（只影響顯示哪些團 + 開團篩選）。
      // 收斂也絕不會把非空變成空 → hasNoCampaignRows 的「無開團來源」判定同樣不變。
      s.campaignIds = new Set(narrowToSoldCampaigns(skuSoldCampaigns, s.sku_id, s.campaignIds));
    }
    return Array.from(grouped.values())
      // 只看有數量可以分配的 SKU(totalAvailable > 0)。已派完 / 還在途的都先隱藏,
      // 派貨工作台是「我現在可以分配什麼」,在途的等 PO 收貨後自然會回來。
      .filter((s) => s.totalAvailable > 0)
      .sort((a, b) => (a.sku_code ?? "").localeCompare(b.sku_code ?? ""));
  }, [demand, poItemCampaigns, skuSoldCampaigns]);

  const allStores: StoreInfo[] = useMemo(() => {
    if (!demand) return [];
    const m = new Map<number, StoreInfo>();
    for (const r of demand) {
      if (r.store_id !== null && !m.has(r.store_id)) {
        m.set(r.store_id, {
          store_id: r.store_id,
          store_code: r.store_code,
          store_name: r.store_name ?? `#${r.store_id}`,
        });
      }
    }
    // 分店欄位順序 = 老闆 2026-08-17 指定的那份（lib/storeOrder）；
    // 對不上的排最後、彼此照 store_code 排。⛔ 只排序，一家都不會少（.sort 不會改變長度）。
    return Array.from(m.values()).sort((a, b) =>
      compareStoreOrder(a.store_code, a.store_name, b.store_code, b.store_name),
    );
  }, [demand]);

  // ===== 篩選：開團 / 商品 / 時間 =====
  // 時間 = 開團結團時間（end_at，沒有就退 start_at）在最近 N 天內（含還沒結的）。
  const timeCutoff = useMemo(() => {
    if (filterTime === "all") return null;
    const d = new Date();
    d.setDate(d.getDate() - Number(filterTime));
    return d.getTime();
  }, [filterTime]);
  const campaignInTime = (cid: number): boolean => {
    if (timeCutoff === null) return true;
    const c = campaignsById?.get(cid);
    const ref = c?.end_at ?? c?.start_at;
    if (!ref) return false;
    return new Date(ref).getTime() >= timeCutoff;
  };
  // 開團下拉選項：目前矩陣有出現、且通過時間篩選的開團，依結團時間新→舊排。
  const campaignOptions: CampaignInfo[] = useMemo(() => {
    if (!campaignsById) return [];
    const ids = new Set<number>();
    for (const sk of skuRows) for (const cid of sk.campaignIds) ids.add(cid);
    return Array.from(ids)
      .filter((cid) => campaignInTime(cid))
      .map((cid) => campaignsById.get(cid))
      .filter((c): c is CampaignInfo => !!c)
      .sort((a, b) => (b.end_at ?? b.start_at ?? "").localeCompare(a.end_at ?? a.start_at ?? ""));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [skuRows, campaignsById, timeCutoff]);
  const hasNoCampaignRows = useMemo(
    () => skuRows.some((sk) => sk.campaignIds.size === 0),
    [skuRows],
  );

  // 選中的開團從清單消失（時間改了、需求派完了、對應還沒載入）→ 視同「全部」。
  // 用衍生值而不是 effect 改 state，避免 cascading render。
  const effFilterCampaign =
    filterCampaign === "all" || filterCampaign === "none"
      ? filterCampaign
      : campaignOptions.some((c) => String(c.id) === filterCampaign)
        ? filterCampaign
        : "all";

  // 商品搜尋比對：名稱 + 品號，模糊、不分大小寫、去頭尾空白（老闆：「我找商品完全是用商品的名稱」）。
  // 空字串 = 全部通過（等同舊版 filterSku="all"）。自由文字沒有「選中的值會失效」的問題，
  // 所以不需要舊版 effFilterSku 那種自我修正；搜不到就是 0 筆，由既有空狀態文案接住。
  const skuQueryNorm = skuQuery.trim().toLowerCase();
  const skuMatchesQuery = (skuLabel: string, skuCode: string | null): boolean => {
    if (skuQueryNorm === "") return true;
    return (
      skuLabel.toLowerCase().includes(skuQueryNorm) ||
      (skuCode ?? "").toLowerCase().includes(skuQueryNorm)
    );
  };

  const rowPassesFilters = (
    campaignIds: Iterable<number>,
    skuLabel: string,
    skuCode: string | null,
  ): boolean => {
    const cids = Array.from(campaignIds);
    if (filterTime !== "all" && !cids.some(campaignInTime)) return false;
    if (effFilterCampaign === "none" && cids.length > 0) return false;
    if (effFilterCampaign !== "all" && effFilterCampaign !== "none" && !cids.includes(Number(effFilterCampaign))) return false;
    if (!skuMatchesQuery(skuLabel, skuCode)) return false;
    return true;
  };
  const hasActiveFilter = effFilterCampaign !== "all" || skuQueryNorm !== "" || filterTime !== "all";
  // 目前選中的那一團（"all" / "none" / 對應還沒載入 → null）。給空狀態文案指名道姓用：
  // 團號過濾收乾淨之後，選一團而清單是空的，代表「這團的貨已經派完或還沒到」，
  // 不是系統壞了 —— 文案要講出團名，老闆才不會以為畫面掛掉。
  const selectedCampaign =
    effFilterCampaign === "all" || effFilterCampaign === "none"
      ? null
      : campaignsById?.get(Number(effFilterCampaign)) ?? null;

  // 通過全部篩選的矩陣列
  const filteredSkuRows = useMemo(
    () => skuRows.filter((sk) => rowPassesFilters(sk.campaignIds, sk.sku_label, sk.sku_code)),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [skuRows, effFilterCampaign, skuQueryNorm, filterTime, timeCutoff, campaignsById],
  );

  // ===== 步驟 1 的挑選清單 =====
  // 一列 = 一個商品（＝ skuRows 的粒度，與建單 scope 一致：看到多少就派多少）。
  // 團／採購單資訊在列內攤開顯示，但「不是可選項」——
  // allocs 的 key 是 `${sku_id}:${store_id}`（沒有 po_id），submitAll 的 FIFO 是 per sku 跑的，
  // 給使用者一個「只挑某一團」的選項，實際做不到，比沒有團資訊更危險（阿審 P1 判定）。
  const visiblePickRows = filteredSkuRows;

  // 每張採購單對應哪幾團（poList 只有 po_id，開團對應在 poItemCampaigns 上，需經 po_item 轉一手）
  const campaignsByPoId = useMemo(() => {
    const m = new Map<number, Set<number>>();
    if (!demand) return m;
    for (const r of demand) {
      const cids = poItemCampaigns?.get(r.po_item_id);
      if (!cids || cids.length === 0) continue;
      let set = m.get(r.po_id);
      if (!set) { set = new Set<number>(); m.set(r.po_id, set); }
      for (const cid of cids) set.add(cid);
    }
    return m;
  }, [demand, poItemCampaigns]);

  // 一列要攤開列出的團明細：只列「這一團真的到貨了」的採購單（gr_qty = 0 不列，避免以為有貨）
  function pickRowPoLines(sk: SkuRow) {
    return sk.poList
      .filter((po) => po.gr_qty > 0)
      .map((po) => ({
        po_id: po.po_id,
        po_no: po.po_no,
        grQty: po.gr_qty,
        available: Math.max(0, po.gr_qty - po.already_wave_for_sku),
        // campaignsByPoId 是 PO 層級（該 PO 所有 po_item 的團聯集），比 sk.campaignIds 更寬
        // → 一定要再用這個 sku 自己的 campaign_items 收斂一次，不能直接列出來。
        campaigns: narrowToSoldCampaigns(skuSoldCampaigns, sk.sku_id, campaignsByPoId.get(po.po_id) ?? [])
          .map((cid) => campaignsById?.get(cid))
          .filter((c): c is CampaignInfo => !!c),
      }));
  }

  // 已挑的列。⚠️ 比對基準是「未經任何篩選」的 skuRows，不是 filteredSkuRows ——
  // 拿目前搜尋結果去交集，正是老闆遇到的「選了 30 樣、按建單只剩 1 樣」的根因。
  const pickedRows = useMemo(
    () => skuRows.filter((sk) => pickedSkus.has(sk.sku_id)),
    [skuRows, pickedSkus],
  );
  const hasPicked = pickedRows.length > 0;

  function togglePick(skuId: number) {
    setPickedSkuIds(
      pickedIds.includes(skuId) ? pickedIds.filter((id) => id !== skuId) : [...pickedIds, skuId],
      pickedEpoch,
    );
  }
  // 「全部加入」= 把目前搜尋結果一次丟進已挑清單（是聯集，不會蓋掉先前挑的）
  function addAllVisiblePicks() {
    const next = new Set(pickedIds);
    for (const sk of visiblePickRows) next.add(sk.sku_id);
    setPickedSkuIds(Array.from(next), pickedEpoch);
  }

  // 本次建單納入的品項：有挑 → 只取挑中的（⚠️ 從 skuRows 取，不與 filteredSkuRows 交集）；
  // 沒挑 → 維持現行「篩選範圍內全部」語意，行為不變。
  const effectiveSkuRows = hasPicked ? pickedRows : filteredSkuRows;

  // 平板塞不下 17 欄 → 預設只顯示「本次建單範圍內還有未派需求、或已填擬分量」的分店欄。
  // 注意：分配上限（getSkuAllocTotal）永遠算全部分店，隱藏欄的擬分量照樣計入。
  const visibleStores: StoreInfo[] = useMemo(() => {
    if (showAllStores) return allStores;
    const kept = allStores.filter((st) =>
      effectiveSkuRows.some(
        (sk) => storeDemandLeft(sk, st.store_id) > 0 || getAlloc(sk.sku_id, st.store_id) > 0,
      ),
    );
    // 全部被濾光（例如需求都派完了）就退回顯示全部，避免空矩陣看不懂
    return kept.length > 0 ? kept : allStores;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [allStores, effectiveSkuRows, showAllStores, allocs]);
  const hiddenStoreCount = allStores.length - visibleStores.length;

  // 依分店視角（純檢視）
  type StoreSection = {
    storeId: number;
    storeCode: string | null;
    storeName: string;
    rows: DemandRow[];
  };
  const storeSections: StoreSection[] = useMemo(() => {
    // 依分店檢視用完整清單（含缺貨待到）；矩陣的 demand 只有可分配列，不夠。
    // 吃同一組 開團/商品/時間 篩選（逐列用 po_item → campaign 對應判斷）。
    if (!fullDemand) return [];
    const grouped = new Map<number, StoreSection>();
    for (const r of fullDemand) {
      if (r.store_id === null) continue;
      // ⚠️ 商品比對要用「該列自己的名稱/品號」：fullDemand 含缺貨待到的品項，
      //    拿矩陣那份 sku_id 集合去比會把它們整批濾掉。
      // 團清單同樣要先收斂成「這一列的商品自己的團」，否則選「眼鏡袋」那一團
      // 會把同一天結單的安城湯麵也一起列出來（與矩陣視角同一個根因）。
      if (!rowPassesFilters(
        narrowToSoldCampaigns(skuSoldCampaigns, r.sku_id, poItemCampaigns?.get(r.po_item_id) ?? []),
        r.sku_label,
        r.sku_code,
      )) continue;
      if (!grouped.has(r.store_id)) {
        grouped.set(r.store_id, {
          storeId: r.store_id,
          storeCode: r.store_code,
          storeName: r.store_name ?? `#${r.store_id}`,
          rows: [],
        });
      }
      grouped.get(r.store_id)!.rows.push(r);
    }
    // ⭐ 與上面矩陣視角的 allStores **用同一份順序**（lib/storeOrder，老闆 2026-08-17 指定）。
    //   這兩個是同一頁的兩個分頁（viewMode: matrix ↔ by_store），只改其中一邊的話，
    //   老闆切個分頁分店順序就變了 —— 他會當成 bug。
    //   ⚠ 這裡的欄位名是 storeCode / storeName（矩陣那邊是 store_code / store_name），別抄錯。
    //   ⛔ 只排序，一家都不會少（.sort 不會改變長度）。
    return Array.from(grouped.values()).sort((a, b) =>
      compareStoreOrder(a.storeCode, a.storeName, b.storeCode, b.storeName),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fullDemand, poItemCampaigns, skuSoldCampaigns, effFilterCampaign, skuQueryNorm, filterTime, timeCutoff, campaignsById]);

  // 補貨申請預設分配 = min(申請量 - 已撿, HQ 庫存) per (rr, sku)
  useEffect(() => {
    if (!restockDemand) return;
    setRestockAllocs((prev) => {
      const next = new Map(prev);
      for (const r of restockDemand) {
        const k = `${r.restock_request_id}:${r.sku_id}`;
        if (next.has(k)) continue;
        const cap = Math.max(
          0,
          Math.min(Number(r.demand_qty) - Number(r.wave_qty), Number(r.gr_qty)),
        );
        next.set(k, cap);
      }
      return next;
    });
  }, [restockDemand]);

  // 預設分配 = max(0, demand - wave) per (sku, store)，並夾在該 SKU 的可分配量之內。
  // wave_qty 已含撿貨單與補貨直派 transfer（不論是否已收貨），
  // shipped 是 wave 的子集合（已收貨的部分），再減會重複扣 → 不減。
  // ⚠️ cap 的由來：訂 108 只到 105 時，舊版預填 108 > 可分配 105 → 整列變紅、
  //    submitAll 的「超過可分配量」直接 throw → 整批建單失敗（部分到貨很常見）。
  useEffect(() => {
    if (!demand) return;
    setAllocs((prev) => {
      const next = new Map(prev);
      const agg = new Map<AllocKey, { demand: number; wave: number }>();
      // 每個 SKU 的可分配量，算式與 skuRows.totalAvailable 完全一致：
      // per (po, sku) 去重後 max(0, Σgr_qty − Σpo_sku_already_wave)。
      const availBySku = new Map<number, number>();
      const poSkuSeen = new Set<string>();
      for (const r of demand) {
        if (r.store_id === null) continue;
        const poSkuKey = `${r.po_id}:${r.sku_id}`;
        if (!poSkuSeen.has(poSkuKey)) {
          poSkuSeen.add(poSkuKey);
          availBySku.set(
            r.sku_id,
            (availBySku.get(r.sku_id) ?? 0) + Number(r.gr_qty) - Number(r.po_sku_already_wave ?? 0),
          );
        }
        const k: AllocKey = `${r.sku_id}:${r.store_id}`;
        const slot = agg.get(k) ?? { demand: 0, wave: 0 };
        slot.demand += Number(r.demand_qty);
        slot.wave += Number(r.wave_qty);
        agg.set(k, slot);
      }
      // headroom = 可分配量 − 已經存在的分配量（使用者手動改過的、上一輪預填的都先扣掉）
      const headroom = new Map<number, number>();
      for (const [skuId, av] of availBySku) headroom.set(skuId, Math.max(0, av));
      for (const [k, val] of next) {
        const skuId = Number(k.split(":")[0]);
        const room = headroom.get(skuId);
        if (room !== undefined) headroom.set(skuId, Math.max(0, room - val));
      }
      // 依 agg 的插入順序（= 查詢的 po_item_id, store_id 排序）逐格填，順序穩定可預期
      for (const [k, v] of agg.entries()) {
        if (next.has(k)) continue; // 使用者改過 / 已填過的格子不動（既有語意保留）
        const skuId = Number(k.split(":")[0]);
        const room = headroom.get(skuId) ?? 0;
        const give = Math.min(Math.max(0, v.demand - v.wave), room);
        next.set(k, give);
        headroom.set(skuId, room - give);
      }
      return next;
    });
  }, [demand]);

  // ===== Allocation Helpers =====
  function setAlloc(skuId: number, storeId: number, qty: number) {
    const k: AllocKey = `${skuId}:${storeId}`;
    setAllocs((prev) => {
      const next = new Map(prev);
      next.set(k, Math.max(0, qty));
      return next;
    });
  }
  // 受限版本:同 SKU 已分配總和不可超過 totalAvailable(即「可分配」上限)
  function setAllocCapped(skuId: number, storeId: number, requested: number, totalAvailable: number) {
    setAllocs((prev) => {
      const k: AllocKey = `${skuId}:${storeId}`;
      const cur = prev.get(k) ?? 0;
      let sum = 0;
      const prefix = `${skuId}:`;
      for (const [key, val] of prev) {
        if (key.startsWith(prefix)) sum += val;
      }
      const headroom = Math.max(0, totalAvailable - sum); // 還能再加多少
      const maxAllowed = cur + headroom;                  // 此格的最大允許值
      const capped = Math.max(0, Math.min(requested, maxAllowed));
      const next = new Map(prev);
      next.set(k, capped);
      return next;
    });
  }
  function getAlloc(skuId: number, storeId: number): number {
    return allocs.get(`${skuId}:${storeId}`) ?? 0;
  }
  function getSkuAllocTotal(skuRow: SkuRow): number {
    let sum = 0;
    for (const st of allStores) sum += getAlloc(skuRow.sku_id, st.store_id);
    return sum;
  }
  // 各店尚未派的需求 = max(0, demand − wave)。wave 已含撿貨單與補貨直派。
  function storeDemandLeft(sku: SkuRow, storeId: number): number {
    return Math.max(
      0,
      (sku.storeDemand.get(storeId) ?? 0) - (sku.storeWave.get(storeId) ?? 0),
    );
  }
  // ===== 整欄高亮：點進某一格數量時，那一欄（含表頭店名）一起亮起來 =====
  // 表頭固定之後店名一直在，但 17 間店的欄位長得都一樣，眼睛還是要在「格子」和「表頭」之間
  // 數欄位 —— 第 11 欄看成第 12 欄，貨就配給錯的店。亮起整欄是為了不用數。
  //
  // ⚠ 刻意「不」放進 React state：矩陣可到 180 列 × 17 欄 ≈ 3000 格，focusedStoreId 進 state
  //   會讓整張表每次點格子都重繪。這一頁本來就慢，拖慢的後果不只是頓 —— 還會延後身分綁定，
  //   加劇「按了加入卻沒進已挑清單」那個既有的間歇性 bug。
  // 這裡只碰 2 個節點（該欄的 <col> ＋ 表頭那一格 <th>），而且查詢範圍鎖在 colgroup / 表頭
  // 那一列（各約 20 個子節點），與列數完全無關：180 列跟 1 列一樣快。
  // 底色靠 <col> 帶（CSS 表格背景層：欄在列/格之下），所以不必逐格加 class。
  const colGroupRef = useRef<HTMLTableColElement>(null);
  const headRowRef = useRef<HTMLTableRowElement>(null);
  function highlightStoreCol(storeId: number | null) {
    const roots = [colGroupRef.current, headRowRef.current];
    // 先清乾淨再上色：不記錄上一次是哪一欄，換店別欄／切「顯示全部分店」而 DOM 節點被重用時
    // 才不會留下殘影（清除範圍同樣只有那 ~20 個子節點）。
    for (const root of roots) {
      for (const el of root?.querySelectorAll<HTMLElement>(".is-col-focus") ?? []) {
        el.classList.remove("is-col-focus");
      }
    }
    if (storeId === null) return;
    for (const root of roots) {
      root?.querySelector<HTMLElement>(`[data-store-col="${storeId}"]`)?.classList.add("is-col-focus");
    }
  }

  // 「⚖ 平均」自動分配:把 totalAvailable 平均分到「未派需求 > 0」的店,cap 在各店未派需求。
  // 若有店需求不足分到的份額,剩餘量會在下一輪重新平均。
  function autoDistribute(sku: SkuRow) {
    const stores = allStores;
    let pool = sku.totalAvailable;
    const give = new Map<number, number>();
    for (const s of stores) give.set(s.store_id, 0);
    for (let iter = 0; iter < 10 && pool > 0; iter += 1) {
      const eligible = stores.filter((s) => {
        const d = storeDemandLeft(sku, s.store_id);
        const cur = give.get(s.store_id) ?? 0;
        return cur < d;
      });
      if (eligible.length === 0) break;
      const base = Math.floor(pool / eligible.length);
      if (base === 0) {
        // pool < eligible 數量,依未派需求大小排序給 +1
        const sorted = [...eligible].sort(
          (a, b) => storeDemandLeft(sku, b.store_id) - storeDemandLeft(sku, a.store_id),
        );
        for (let i = 0; i < pool && i < sorted.length; i += 1) {
          const s = sorted[i];
          const d = storeDemandLeft(sku, s.store_id);
          const cur = give.get(s.store_id) ?? 0;
          if (cur < d) give.set(s.store_id, cur + 1);
        }
        pool = 0;
        break;
      }
      let givenThisRound = 0;
      for (const s of eligible) {
        const d = storeDemandLeft(sku, s.store_id);
        const cur = give.get(s.store_id) ?? 0;
        const add = Math.min(base, d - cur);
        give.set(s.store_id, cur + add);
        givenThisRound += add;
      }
      pool -= givenThisRound;
      if (givenThisRound === 0) break;
    }
    setAllocs((prev) => {
      const next = new Map(prev);
      for (const s of stores) {
        next.set(`${sku.sku_id}:${s.store_id}`, give.get(s.store_id) ?? 0);
      }
      return next;
    });
  }

  // ===== FIFO 規劃器：把每個 (sku, store) 的擬分量切分到含此 sku 的多張 PO =====
  // submitAll 與 involvedPosFor 共用（20260816 借調上線前兩處各養一份、已經開始漂移）。
  // 第一輪（既有跨團守衛，原樣保留）：只倒給「該店在此 PO 確實有需求」的 PO ——
  //   view 只在某店對某 PO 對應的開團 / 補貨有需求時才產生該 (po,sku,store) 列，
  //   「有列 = 有需求」，避免把別團需求倒給最舊的 PO。
  // 第二輪（跨團借調，20260816000050）：第一輪吃完還有剩、且該店該 SKU 確實還有
  //   未派需求（storeDemandLeft > 0，不是憑空多派）→ 從同 SKU 其他 PO 的「餘量」補。
  //   餘量 = 該 PO 剩餘容量 − max(0, 該 PO 自己的未派需求 − 第一輪已派給它的量)：
  //   借調永遠不吃來源 PO 自己團的客人還沒拿到的貨。DB 端步驟 4.5 是同一套算法的守衛，
  //   wave item 會被 RPC 標成「實際被服務的那一團」，訂單推進不會卡。
  function planWaveAllocations(scopeRows: SkuRow[]): {
    perPoAllocs: Map<number, Array<{ sku_id: number; store_id: number; qty: number }>>;
    insufficient: string[];
  } {
    const perPoAllocs = new Map<number, Array<{ sku_id: number; store_id: number; qty: number }>>();
    const insufficient: string[] = [];
    if (!demand) return { perPoAllocs, insufficient };

    const demandPoSkuStore = new Set<string>();
    // 該 PO 該 SKU「自己的未派需求」Σ max(0, demand − wave)，口徑同 view 的 demand_left
    //（wave_qty 含借調歸屬分支，之前借出去的量不會被重複保留）。
    const ownUnmet = new Map<string, number>();
    for (const r of demand) {
      if (r.store_id === null) continue;
      demandPoSkuStore.add(`${r.po_id}:${r.sku_id}:${r.store_id}`);
      const k = `${r.po_id}:${r.sku_id}`;
      ownUnmet.set(k, (ownUnmet.get(k) ?? 0) + Math.max(0, Number(r.demand_qty) - Number(r.wave_qty)));
    }

    // 可消耗的 PO 容量表 perPoSkuLeft.get(`${po}:${sku}`) = 該 PO 該 SKU 還可分配
    const perPoSkuLeft = new Map<string, number>();
    for (const sk of scopeRows) {
      for (const po of sk.poList) {
        perPoSkuLeft.set(`${po.po_id}:${sk.sku_id}`, Math.max(0, po.gr_qty - po.already_wave_for_sku));
      }
    }
    // 第一輪派給各 PO 的量（借調的保留量要先扣掉這些 —— 已經在服務自己團的需求了）
    const matchedTaken = new Map<string, number>();

    for (const sk of scopeRows) {
      for (const st of allStores) {
        const qty = getAlloc(sk.sku_id, st.store_id);
        if (qty <= 0) continue;
        let remaining = qty;
        // 第一輪：有需求的 PO
        for (const po of sk.poList) {
          if (remaining <= 0) break;
          if (!demandPoSkuStore.has(`${po.po_id}:${sk.sku_id}:${st.store_id}`)) continue;
          const k = `${po.po_id}:${sk.sku_id}`;
          const av = perPoSkuLeft.get(k) ?? 0;
          if (av <= 0) continue;
          const take = Math.min(remaining, av);
          const slot = perPoAllocs.get(po.po_id) ?? [];
          slot.push({ sku_id: sk.sku_id, store_id: st.store_id, qty: take });
          perPoAllocs.set(po.po_id, slot);
          perPoSkuLeft.set(k, av - take);
          matchedTaken.set(k, (matchedTaken.get(k) ?? 0) + take);
          remaining -= take;
        }
        // 第二輪：跨團借調（只在該店該 SKU 還有未派需求時啟動）
        if (remaining > 0 && storeDemandLeft(sk, st.store_id) > 0) {
          for (const po of sk.poList) {
            if (remaining <= 0) break;
            // 有需求的 PO 第一輪拿過了；這一輪只看「對該店沒需求、但有餘量」的 PO
            if (demandPoSkuStore.has(`${po.po_id}:${sk.sku_id}:${st.store_id}`)) continue;
            const k = `${po.po_id}:${sk.sku_id}`;
            const left = perPoSkuLeft.get(k) ?? 0;
            const reserve = Math.max(0, (ownUnmet.get(k) ?? 0) - (matchedTaken.get(k) ?? 0));
            const take = Math.min(remaining, Math.max(0, left - reserve));
            if (take <= 0) continue;
            const slot = perPoAllocs.get(po.po_id) ?? [];
            slot.push({ sku_id: sk.sku_id, store_id: st.store_id, qty: take });
            perPoAllocs.set(po.po_id, slot);
            perPoSkuLeft.set(k, left - take);
            remaining -= take;
          }
        }
        if (remaining > 0) {
          insufficient.push(`「${sk.sku_code ?? ""} ${sk.sku_label}」→ ${st.store_name} 缺 ${remaining}`);
        }
      }
    }
    return { perPoAllocs, insufficient };
  }

  // FIFO 提交：規劃（planWaveAllocations）後對每張 PO 各別發 RPC。
  // scopeRows = 本次要納入建單的品項；勾選了部分品項時只傳選取的，未勾選時傳全部。
  async function submitAll(scopeRows: SkuRow[] = skuRows) {
    if (!demand) return;
    setError(null);
    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      // 校驗：每個 SKU 的擬分總量 ≤ totalAvailable（只校驗本次納入的品項）
      const overSkus: string[] = [];
      for (const sk of scopeRows) {
        const allocSum = getSkuAllocTotal(sk);
        if (allocSum > sk.totalAvailable) {
          overSkus.push(`「${sk.sku_code ?? ""} ${sk.sku_label}」分配 ${allocSum} 超過可分配 ${sk.totalAvailable}`);
        }
      }
      if (overSkus.length > 0) throw new Error("超過可分配量：\n" + overSkus.join("\n"));

      const { perPoAllocs, insufficient } = planWaveAllocations(scopeRows);

      if (insufficient.length > 0) throw new Error("可分配量不足：\n" + insufficient.join("\n"));
      if (perPoAllocs.size === 0) throw new Error("沒有任何分配 — 請先填數量");

      // 對每個 PO 各發一次 RPC（配送日固定帶隔天，建單後可在總倉收件匣的撿貨單上調整）
      const waveDate = defaultWaveDate();
      const results: { po_no: string; wave_id: number; wave_code: string }[] = [];
      const failures: { po_no: string; error: string }[] = [];
      for (const [poId, allocations] of perPoAllocs.entries()) {
        const sample = demand.find((d) => d.po_id === poId);
        const poNo = sample?.po_no ?? `PO#${poId}`;
        try {
          const { data, error: e } = await sb.rpc("rpc_create_wave_from_po", {
            p_po_id: poId,
            p_wave_date: waveDate,
            p_allocations: allocations,
            p_operator: operator,
          });
          if (e) throw new Error(e.message);
          const r = data as { wave_id: number; wave_code: string };
          results.push({ po_no: poNo, wave_id: r.wave_id, wave_code: r.wave_code });
        } catch (err) {
          failures.push({ po_no: poNo, error: err instanceof Error ? err.message : String(err) });
        }
      }

      if (failures.length === 0) {
        if (results.length === 1) {
          alert(`✅ 已建立撿貨單 ${results[0].wave_code}`);
        } else {
          alert(
            `✅ 已建立 ${results.length} 張撿貨單：\n` +
              results.map((r) => `  ${r.po_no} → ${r.wave_code}`).join("\n"),
          );
        }
        // 這批已經建完 → 清空已挑清單。留著的話：全派完的品項下次進來會觸發
        // 「已無可分配量、自動移除」的黃色警示（剛建完單看到會以為出事）；
        // 部分派出的品項則殘留在清單裡、下次又被預填數量順手派出去。
        // 部分失敗（failures > 0）不清 —— 留在原地讓使用者修正後重送。
        // 帶 render 當下的世代：建單途中若換了人，這個清空會被擋掉（不會清到新那個人的清單）。
        setPickedSkuIds([], pickedEpoch);
        router.push("/hq/inbox?source=picking");
      } else {
        const okPart =
          results.length > 0
            ? `✅ 成功 ${results.length} 張：${results.map((r) => r.wave_code).join(", ")}\n\n`
            : "";
        const failPart =
          `⚠️ 失敗 ${failures.length} 張：\n` +
          failures.map((f) => `  ${f.po_no}: ${f.error}`).join("\n");
        throw new Error(okPart + failPart);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  // ============================================================
  // 渲染
  // ============================================================
  // ===== 本次建單納入的品項 =====
  // 舊版在這裡做「勾選 ∩ 目前清單」，搜商品時清單只剩 1 列 → 勾好的 30 樣被吃掉只剩 1 樣。
  // 現在改由步驟 1 的已挑清單決定（effectiveSkuRows 定義在 filteredSkuRows 附近），
  // 已挑清單完全不與目前清單做交集。

  // 本次擬分總量（限納入的品項）
  const totalAllocSum = useMemo(() => {
    let s = 0;
    for (const sk of effectiveSkuRows) for (const st of allStores) s += getAlloc(sk.sku_id, st.store_id);
    return s;
  }, [effectiveSkuRows, allStores, allocs]); // eslint-disable-line react-hooks/exhaustive-deps

  // 預估會切出幾張 wave（與 submitAll 同 FIFO 邏輯），可限定品項範圍
  function involvedPosFor(scopeRows: SkuRow[]): number {
    // 與 submitAll 完全同一支規劃器（含借調第二輪），預估的張數不會再跟實際切的漂移
    return planWaveAllocations(scopeRows).perPoAllocs.size;
  }
  const involvedPos = useMemo(
    () => involvedPosFor(effectiveSkuRows),
    [effectiveSkuRows, allStores, demand, allocs], // eslint-disable-line react-hooks/exhaustive-deps
  );

  // 本次建單範圍內缺成本/分店價的品項數（派貨時會被 DB 守衛 _missing_dispatch_prices 擋下）
  const missingPriceCount = useMemo(() => {
    if (!canFixPrices || !priceFlags) return 0;
    let n = 0;
    for (const sk of effectiveSkuRows) {
      const f = priceFlags.get(sk.sku_id);
      if (f && (!f.cost || !f.branch)) n += 1;
    }
    return n;
  }, [effectiveSkuRows, priceFlags, canFixPrices]);

  // ===== 補貨申請(無 PO 來源)分組 =====
  type RestockGroup = {
    rrId: number;
    rrStatus: string;
    storeId: number;
    storeCode: string | null;
    storeName: string;
    lines: RestockRow[];
  };
  const restockGroups: RestockGroup[] = useMemo(() => {
    if (!restockDemand) return [];
    const map = new Map<number, RestockGroup>();
    for (const r of restockDemand) {
      let g = map.get(r.restock_request_id);
      if (!g) {
        g = {
          rrId: r.restock_request_id,
          rrStatus: r.restock_status,
          storeId: r.store_id,
          storeCode: r.store_code,
          storeName: r.store_name ?? `#${r.store_id}`,
          lines: [],
        };
        map.set(r.restock_request_id, g);
      }
      g.lines.push(r);
    }
    return Array.from(map.values()).sort((a, b) => a.rrId - b.rrId);
  }, [restockDemand]);

  // 補貨申請不屬於任何開團：選了特定開團就整段隱藏；商品搜尋則濾到含命中品項的申請。
  const visibleRestockGroups = useMemo(() => {
    if (effFilterCampaign !== "all" && effFilterCampaign !== "none") return [];
    if (skuQueryNorm === "") return restockGroups;
    return restockGroups.filter((g) =>
      g.lines.some((ln) => skuMatchesQuery(ln.sku_label, ln.sku_code)),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [restockGroups, effFilterCampaign, skuQueryNorm]);

  function getRestockAlloc(rrId: number, skuId: number): number {
    return restockAllocs.get(`${rrId}:${skuId}`) ?? 0;
  }
  function setRestockAlloc(rrId: number, skuId: number, qty: number, max: number) {
    setRestockAllocs((prev) => {
      const next = new Map(prev);
      next.set(`${rrId}:${skuId}`, Math.max(0, Math.min(qty, max)));
      return next;
    });
  }

  async function submitRestockWave(group: RestockGroup) {
    setError(null);
    setSubmittingRrId(group.rrId);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      const allocations: { sku_id: number; store_id: number; qty: number }[] = [];
      for (const ln of group.lines) {
        const qty = getRestockAlloc(group.rrId, ln.sku_id);
        if (qty > 0) {
          allocations.push({ sku_id: ln.sku_id, store_id: group.storeId, qty });
        }
      }
      if (allocations.length === 0) {
        throw new Error("沒有任何分配 — 請先填數量");
      }
      const { data, error: e } = await sb.rpc("rpc_create_wave_from_restock", {
        p_restock_request_id: group.rrId,
        p_wave_date: defaultWaveDate(),
        p_allocations: allocations,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      const r = data as { wave_id: number; wave_code: string };
      alert(`✅ 已建立撿貨單 ${r.wave_code}`);
      setReloadKey((k) => k + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmittingRrId(null);
    }
  }

  // KPI 總覽 — 口徑對齊「本次建單範圍」（本次擬分 / 預計切幾張 wave 本來就是用 effectiveSkuRows，
  // 若這裡改用篩選範圍，挑了 30 樣時「可分配庫存」會顯示 180 樣的總和，四格互相打架）
  const kpis = useMemo(() => {
    let totalAvailable = 0, totalInTransit = 0, totalShortage = 0;
    let skuShortageCount = 0;
    for (const sk of effectiveSkuRows) {
      totalAvailable += sk.totalAvailable;
      totalInTransit += sk.totalInTransit;
      totalShortage += sk.totalShortage;
      if (sk.totalShortage > 0) skuShortageCount += 1;
    }
    return { totalAvailable, totalInTransit, totalShortage, skuShortageCount };
  }, [effectiveSkuRows]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">🚦 派貨工作台</h1>
          <p className="text-sm text-zinc-500">
            從總倉已到貨庫存派給各分店 — <strong>步驟 1</strong> 用商品名稱搜尋、把今天要撿的貨一樣一樣加進「已挑清單」;<strong>步驟 2</strong> 系統帶出各店要的數量,一次建立撿貨單。建單時依 PO 自動切分,需求派完的品項會自動下架。
          </p>
        </div>
        <Link
          href="/hq/inbox?source=picking"
          className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          撿貨單列表 →
        </Link>
      </header>

      {/* 篩選列：開團 / 商品 / 時間（平板友善的大下拉） */}
      {skuRows.length > 0 && (
        <div className="flex flex-wrap items-end gap-3 rounded-lg border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
          {/* div 不用 label 包：自訂 combobox 會被 label 的 click 轉發重新打開（見 verify skill 的坑） */}
          <div className="flex min-w-[240px] flex-1 flex-col gap-1 sm:max-w-sm">
            <span className="text-xs font-medium text-zinc-500">開團</span>
            <CampaignCombobox
              value={effFilterCampaign}
              options={campaignOptions}
              hasNoneOption={hasNoCampaignRows}
              onChange={setFilterCampaign}
            />
          </div>
          {/* 商品搜尋取代舊的單選下拉：單選會把清單縮到 1 列，把已勾的品項全吃掉。
              搜尋只影響「看得到什麼」，已挑清單完全不受影響。 */}
          <label className="flex min-w-[220px] flex-1 flex-col gap-1 sm:max-w-xs">
            <span className="text-xs font-medium text-zinc-500">商品搜尋（名稱 / 品號）</span>
            <div className="relative">
              <input
                type="search"
                value={skuQuery}
                onChange={(e) => setSkuQuery(e.target.value)}
                placeholder="打商品名稱,例如 蔥抓餅"
                aria-label="搜尋商品名稱或品號"
                className="h-11 w-full rounded-md border border-zinc-300 bg-white px-3 pr-9 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              />
              {skuQueryNorm !== "" && (
                <button
                  type="button"
                  onClick={() => setSkuQuery("")}
                  aria-label="清除搜尋"
                  className="absolute right-1 top-1 h-9 w-8 rounded text-zinc-400 hover:bg-zinc-100 hover:text-zinc-600 dark:hover:bg-zinc-700"
                >
                  ✕
                </button>
              )}
            </div>
          </label>
          <label className="flex w-40 flex-col gap-1">
            <span className="text-xs font-medium text-zinc-500" title="以開團的結團時間算（沒結團時間就看開團時間），含還沒結團的">時間</span>
            <select
              value={filterTime}
              onChange={(e) => setFilterTime(e.target.value as TimeFilter)}
              className="h-11 w-full rounded-md border border-zinc-300 bg-white px-3 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            >
              <option value="all">全部時間</option>
              <option value="7">近 7 天結團</option>
              <option value="14">近 14 天結團</option>
              <option value="30">近 30 天結團</option>
              <option value="90">近 90 天結團</option>
            </select>
          </label>
          {hasActiveFilter && (
            <button
              type="button"
              onClick={() => { setFilterCampaign("all"); setSkuQuery(""); setFilterTime("all"); }}
              className="h-11 rounded-md border border-zinc-300 px-4 text-sm text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
            >
              ✕ 清除篩選
            </button>
          )}
        </div>
      )}

      {/* KPI bar（口徑 = 本次建單範圍；沒挑任何品項時 = 篩選範圍，與舊版相同） */}
      {effectiveSkuRows.length > 0 && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <KpiCard label="可分配庫存" value={kpis.totalAvailable} accent="text-emerald-700 dark:text-emerald-400" hint="HQ 已到貨可派" />
          <KpiCard label="本次擬分" value={totalAllocSum} accent="text-blue-700 dark:text-blue-400" hint={involvedPos > 0 ? `預計切 ${involvedPos} 張 wave` : "尚未填入分配量"} />
          <KpiCard label="在途待到" value={kpis.totalInTransit} accent="text-amber-700 dark:text-amber-400" hint="PO 部分收,還會再來" />
          <KpiCard
            label={kpis.totalShortage > 0 ? "⚠ 短少" : "無短少"}
            value={kpis.totalShortage}
            accent={kpis.totalShortage > 0 ? "text-rose-700 dark:text-rose-400" : "text-zinc-400"}
            hint={kpis.skuShortageCount > 0 ? `${kpis.skuShortageCount} 品項受影響` : "—"}
          />
        </div>
      )}

      {/* Tab 切換 */}
      <div className="border-b border-zinc-200 dark:border-zinc-800">
        <nav className="-mb-px flex gap-4">
          <TabBtn active={viewMode === "matrix"} onClick={() => setViewMode("matrix")}>
            🧾 全清單矩陣（建單）
          </TabBtn>
          <TabBtn active={viewMode === "by_store"} onClick={() => setViewMode("by_store")}>
            🏬 依分店（檢視）
          </TabBtn>
        </nav>
      </div>

      {/* 兩步驟切換：先挑品、再看量。可隨時來回，allocs 是全域 Map，填過的數量不會掉。 */}
      {viewMode === "matrix" && (
        <div className="flex flex-wrap items-center gap-2">
          <StepBtn active={pickStep === "select"} onClick={() => setPickStep("select")}>
            ① 挑選商品{hasPicked ? `（已挑 ${pickedRows.length}）` : ""}
          </StepBtn>
          <span className="text-zinc-300 dark:text-zinc-600">→</span>
          <StepBtn active={pickStep === "confirm"} onClick={() => setPickStep("confirm")}>
            ② 確認數量並建單
          </StepBtn>
        </div>
      )}

      {/* 控制列 */}
      <div className="flex flex-wrap items-end gap-3 rounded-md border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
        <span className="text-xs text-zinc-500" title="建單後到「總倉收件匣 → 撿貨單」點配送日即可修改">
          📅 配送日預設隔天，建單後可在總倉收件匣的撿貨單上調整
        </span>
        <span className="text-xs text-zinc-500">
          {loading
            ? "載入中…"
            : viewMode === "matrix"
              ? pickStep === "select"
                ? `${visiblePickRows.length}${hasActiveFilter ? ` / ${skuRows.length}` : ""} 樣可挑 · 已挑 ${pickedRows.length} 樣`
                : `${effectiveSkuRows.length}${hasPicked || hasActiveFilter ? ` / ${skuRows.length}` : ""} 個品項 · ${visibleStores.length}${
                    hiddenStoreCount > 0 ? ` / ${allStores.length}` : ""
                  } 間分店${
                    hasPicked ? ` · 已挑 ${pickedRows.length} 樣` : ""
                  } · 擬分 ${totalAllocSum}${involvedPos > 0 ? ` · 預計切 ${involvedPos} 張撿貨單` : ""}`
              : loadingFull || fullDemand === null
                ? "載入完整清單中…"
                : `${storeSections.length} 間分店有待撿貨`}
        </span>
        {viewMode === "matrix" && pickStep === "confirm" && hiddenStoreCount > 0 && !showAllStores && (
          <button
            type="button"
            onClick={() => setShowAllStores(true)}
            className="text-xs text-blue-600 underline-offset-2 hover:underline dark:text-blue-400"
            title="預設只顯示篩選範圍內還有需求的分店欄"
          >
            另有 {hiddenStoreCount} 間分店無需求 — 顯示全部
          </button>
        )}
        {viewMode === "matrix" && pickStep === "confirm" && showAllStores && allStores.length > 0 && (
          <button
            type="button"
            onClick={() => setShowAllStores(false)}
            className="text-xs text-blue-600 underline-offset-2 hover:underline dark:text-blue-400"
          >
            只顯示有需求的分店
          </button>
        )}
        {viewMode === "matrix" && missingPriceCount > 0 && (
          <span className="text-xs font-medium text-rose-700 dark:text-rose-400">
            缺價 {missingPriceCount} 品項 — 補價前派貨會被擋
          </span>
        )}

        {viewMode === "matrix" && (
          <div className="ml-auto flex flex-wrap gap-2">
            {/* 老闆的流程是「挑 30-50 樣 → 列印 → 拿給樓下的人撿」，所以列印要跟著已挑清單走。
                用 query string 傳 sku_id：列印頁本來就跟工作台零耦合（自己撈 view），
                走網址參數不必共用 localStorage key（那把 key 綁 tenant/user，列印頁得再算一次）。
                長度：50 個 id 約 350 字元，遠低於瀏覽器上限。沒挑 → 不帶參數 → 印全部（行為不變）。 */}
            <Link
              href={
                hasPicked
                  ? `/picking/print-pick-list?skus=${pickedRows.map((sk) => sk.sku_id).join(",")}`
                  : "/picking/print-pick-list"
              }
              target="_blank"
              className="rounded-md border border-blue-300 bg-blue-50 px-3 py-2 text-sm font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
            >
              {hasPicked ? `📄 列印已挑 ${pickedRows.length} 樣` : "📄 列印全部待撿清單"}
            </Link>
            {pickStep === "select" ? (
              <SpinButton
                onClick={() => setPickStep("confirm")}
                disabled={skuRows.length === 0}
                className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
              >
                {hasPicked
                  ? `下一步：確認數量 (${pickedRows.length} 樣) →`
                  : "下一步：確認數量（未挑 = 全部）→"}
              </SpinButton>
            ) : (
              effectiveSkuRows.length > 0 && (
                <SpinButton
                  onClick={() => submitAll(effectiveSkuRows)}
                  disabled={submitting || totalAllocSum === 0}
                  className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
                >
                  {submitting
                    ? "建立中…"
                    : hasPicked
                      ? `🧾 建立撿貨單 (${effectiveSkuRows.length} 品項${involvedPos > 1 ? ` · ${involvedPos} 張` : ""})`
                      : `🧾 建立撿貨單${involvedPos > 1 ? ` (${involvedPos} 張)` : ""}`}
                </SpinButton>
              )
            )}
          </div>
        )}
      </div>

      {/* 已挑清單失效提示（驗收 #5：自動移除且要明示，不得靜默） */}
      {prunedNotice && (
        <div className="flex items-start justify-between gap-3 rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
          <span>⚠️ {prunedNotice}</span>
          <button
            type="button"
            onClick={() => setPrunedNotice(null)}
            className="shrink-0 rounded px-2 text-amber-700 hover:bg-amber-100 dark:text-amber-300 dark:hover:bg-amber-900"
          >
            知道了
          </button>
        </div>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <pre className="whitespace-pre-wrap font-mono text-xs">{error}</pre>
        </div>
      )}

      {demand === null ? (
        <div className="text-center text-sm text-zinc-500">載入中…</div>
      ) : viewMode === "matrix" ? (
        pickStep === "select" ? (
          /* ===== 步驟 1：挑選商品 — 純商品清單，不出現分店矩陣 ===== */
          <div className="flex flex-col gap-3">
            {/* 已挑清單：獨立集合，換搜尋字 / 換開團篩選都不會掉 */}
            <div className="rounded-md border border-blue-200 bg-blue-50/50 p-3 dark:border-blue-900 dark:bg-blue-950/20">
              <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                <span className="text-sm font-semibold text-blue-900 dark:text-blue-200">
                  ✅ 已挑選 · {pickedRows.length} 樣
                </span>
                <div className="flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={addAllVisiblePicks}
                    disabled={visiblePickRows.length === 0}
                    className="min-h-[44px] rounded-md border border-blue-300 bg-white px-3 text-sm font-medium text-blue-700 hover:bg-blue-100 disabled:opacity-40 dark:border-blue-700 dark:bg-zinc-900 dark:text-blue-300 dark:hover:bg-blue-950"
                  >
                    ＋ 全部加入（{visiblePickRows.length}）
                  </button>
                  {hasPicked && (
                    <button
                      type="button"
                      onClick={() => setPickedSkuIds([], pickedEpoch)}
                      className="min-h-[44px] rounded-md border border-zinc-300 px-3 text-sm text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                    >
                      清空
                    </button>
                  )}
                </div>
              </div>
              {pickedRows.length === 0 ? (
                <p className="text-xs text-zinc-500">
                  還沒挑任何商品 — 用上面的「商品搜尋」打商品名稱,找到就按「加入」;換搜尋字不會把已挑的洗掉。
                  不挑直接按「下一步」= 沿用舊行為(整個篩選範圍一起建單)。
                  {pickedStorageKey === null && "（目前無法記住已挑清單：讀不到帳號/租戶，重新整理會清空）"}
                </p>
              ) : (
                <div className="flex flex-wrap gap-1.5">
                  {pickedRows.map((sk) => (
                    <span
                      key={sk.sku_id}
                      className="inline-flex items-center gap-1 rounded-full border border-blue-300 bg-white py-1 pl-2.5 pr-1 text-xs dark:border-blue-800 dark:bg-zinc-900"
                    >
                      <span
                        className="max-w-[220px] truncate"
                        title={`${sk.sku_code ?? ""} ${sk.sku_label} · 可分配 ${sk.totalAvailable}`}
                      >
                        {sk.sku_label}
                      </span>
                      <span className="font-mono text-[10px] tabular-nums text-zinc-400">{sk.totalAvailable}</span>
                      <button
                        type="button"
                        onClick={() => togglePick(sk.sku_id)}
                        aria-label={`移除 ${sk.sku_label}`}
                        className="ml-0.5 h-6 w-6 rounded-full text-zinc-400 hover:bg-rose-100 hover:text-rose-700 dark:hover:bg-rose-950 dark:hover:text-rose-300"
                      >
                        ✕
                      </button>
                    </span>
                  ))}
                </div>
              )}
            </div>

            {/* 可挑清單：一列 = 一個商品，列內攤開這個商品有哪幾團／哪幾張採購單、各團各到多少 */}
            {skuRows.length === 0 ? (
              <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
                目前沒有可分配的品項(該派的都派完了;在途的等收貨後、新需求進來後會自動回來)。
              </div>
            ) : visiblePickRows.length === 0 ? (
              <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
                {skuQueryNorm !== ""
                  ? `找不到符合「${skuQuery.trim()}」的商品 — 換個關鍵字,或清除搜尋 / 篩選。`
                  : selectedCampaign
                    ? `「${selectedCampaign.campaign_no} ${selectedCampaign.name}」這一團目前沒有可派的品項 — 這團的貨可能已經派完,或是還沒到。換一團,或清除篩選看全部。`
                    : "目前的篩選條件下沒有可挑品項 — 換個開團 / 時間,或清除篩選。"}
                {pickedRows.length > 0 && (
                  <div className="mt-1 text-xs">（已挑的 {pickedRows.length} 樣不受影響,還在上面的清單裡）</div>
                )}
              </div>
            ) : (
              <ul className="divide-y divide-zinc-200 rounded-md border border-zinc-200 bg-white dark:divide-zinc-800 dark:border-zinc-800 dark:bg-zinc-900">
                {visiblePickRows.map((sk) => {
                  const picked = pickedSkus.has(sk.sku_id);
                  const poLines = pickRowPoLines(sk);
                  return (
                    <li
                      key={sk.sku_id}
                      className={`flex items-start gap-3 p-3 ${picked ? "bg-blue-50/60 dark:bg-blue-950/20" : ""}`}
                    >
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                          <span className="font-mono text-[11px] text-zinc-500">{sk.sku_code ?? "—"}</span>
                          <span className="text-sm font-medium">{sk.sku_label}</span>
                          <span
                            className="font-mono text-xs font-semibold tabular-nums text-emerald-700 dark:text-emerald-400"
                            title="可分配 = 總倉已到貨 − 已派。這就是建單時實際會派出去的上限"
                          >
                            可分配 {sk.totalAvailable}
                          </span>
                          {sk.poList.some((p) => p.is_restock_sourced) && (
                            <span
                              className="rounded bg-amber-100 px-1 py-0.5 text-[9px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                              title="此 PO 來源為補貨申請(restock)"
                            >
                              📦 補貨
                            </span>
                          )}
                          {renderPriceTags(sk.sku_id)}
                        </div>
                        {/* 老闆：「第一頁應該要有詳細開團的資訊」「相同的品名容易搞錯，第一團未到、第二團到了會派錯」
                            → 攤開列出這個商品有哪幾團／哪幾張採購單、各團各到了多少。
                            ⚠️ 只是資訊，不是可選項：建單是 per 商品跑 FIFO，挑不了單一團。
                            沒到貨的團（gr_qty = 0）不列，免得以為有貨。 */}
                        {/* 一張採購單 = 一張小卡：團在上、數量在下，兩行綁在同一個框裡。
                            舊版把團名和數量擠成一行、團一多就分不清哪個數字屬於哪一團
                            （正是老闆說的「第一團未到、第二團到了會派錯」）。
                            平板優先：團名 12px、數字 12px 且 tabular-nums，觸控不需要點。 */}
                        <ul className="mt-1 flex flex-col gap-1">
                          {poLines.length === 0 ? (
                            <li className="text-[11px] text-zinc-400">無已到貨的採購單</li>
                          ) : (
                            poLines.map((po) => (
                              <li
                                key={po.po_id}
                                className="rounded border border-zinc-100 bg-zinc-50 px-2 py-1 dark:border-zinc-800 dark:bg-zinc-800/40"
                              >
                                <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                                  {po.campaigns.length === 0 ? (
                                    <span className="text-xs text-zinc-400">無開團來源</span>
                                  ) : (
                                    po.campaigns.map((c) => (
                                      <span key={c.id} className="inline-flex min-w-0 items-baseline gap-1">
                                        <span className="shrink-0 rounded bg-white px-1 font-mono text-[10px] text-zinc-500 ring-1 ring-zinc-200 dark:bg-zinc-900 dark:text-zinc-400 dark:ring-zinc-700">
                                          {c.campaign_no}
                                        </span>
                                        <span className="truncate text-xs text-zinc-700 dark:text-zinc-300">{c.name}</span>
                                      </span>
                                    ))
                                  )}
                                </div>
                                <div className="mt-0.5 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs text-zinc-500">
                                  <span className="font-mono text-zinc-400" title="採購單號">{po.po_no}</span>
                                  <span className="font-mono tabular-nums" title="這一團(這張採購單)已到貨量">
                                    到 {po.grQty}
                                  </span>
                                  <span
                                    className="font-mono tabular-nums text-zinc-400"
                                    title="這張採購單此商品的已到貨 − 已派"
                                  >
                                    剩 {po.available}
                                  </span>
                                </div>
                              </li>
                            ))
                          )}
                        </ul>
                      </div>
                      {/* 觸控目標 ≥ 44px（平板現場單手點） */}
                      <button
                        type="button"
                        onClick={() => togglePick(sk.sku_id)}
                        className={`min-h-[44px] min-w-[104px] shrink-0 rounded-md px-3 text-sm font-semibold ${
                          picked
                            ? "border border-blue-300 bg-white text-blue-700 hover:bg-blue-50 dark:border-blue-700 dark:bg-zinc-900 dark:text-blue-300 dark:hover:bg-blue-950"
                            : "bg-blue-600 text-white hover:bg-blue-700"
                        }`}
                      >
                        {picked ? "✓ 已加入" : "＋ 加入"}
                      </button>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        ) : effectiveSkuRows.length === 0 ? (
          <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
            {skuRows.length === 0
              ? "目前沒有待派的品項(該派的都派完了;在途的等收貨後、新需求進來後會自動回來)。"
              : selectedCampaign
                ? `「${selectedCampaign.campaign_no} ${selectedCampaign.name}」這一團目前沒有待派的品項 — 這團的貨可能已經派完,或是還沒到。回步驟 1 挑商品,或換一團 / 清除篩選。`
                : "目前的篩選條件下沒有待派品項 — 回步驟 1 挑商品,或換個開團 / 時間、清除篩選。"}
          </div>
        ) : (
          // 捲動容器:左右 + 上下都在這一層(overflow-auto),表頭與品項欄的 sticky 都相對它定位。
          // ⚠ 高度上限不能拿掉 —— 舊版只寫 overflow-x-auto 而沒有 max-h:overflow-x 一旦不是
          //   visible,overflow-y 的 visible 就會被算成 auto,這個 div 因此仍是捲動容器,但高度
          //   等於內容高度、永遠捲不動 → thead 的 sticky top-0 黏在框頂,框卻跟著整頁捲走,
          //   等於固定表頭寫了等於沒寫(改中間某一格數字要拉回最上面才知道是哪一店)。
          // 高度取 100dvh − 7rem:捲到底時矩陣正好停在上方控制列(建立撿貨單鈕)底下、表頭落在
          //   可視範圍內。算式是 容器頂端(捲到底) = 視窗高 − 容器高 − 容器下方內容高,與上方內容
          //   多高無關;下方只剩 p-6 的 24px,所以扣 112px 會留約 90px 給控制列。
          //   用 dvh 不用 vh:平板瀏覽器工具列收合時 vh 會比實際可視高度大,表頭會被切掉(同 Modal.tsx)。
          // max-h 不是 h:品項少的時候框仍然只有內容高度,大螢幕不會變成一條扁框。
          // print: 兩個 —— 列印時把高度上限拿掉,否則直接對這一頁 Ctrl+P 只會印出一個螢幕的列
          //   (加高度上限之前不會)。正規列印走 /picking/print-pick-list,這只是別讓它變壞。
          <div className="max-h-[calc(100dvh-7rem)] overflow-auto rounded-md border border-zinc-200 bg-white print:max-h-none print:overflow-visible dark:border-zinc-800 dark:bg-zinc-900">
            {/* table-fixed + 明確總寬：auto layout 把 <col> 寬度當建議值,店一多就把店別欄
                壓窄、數量輸入框跟著縮,兩位數以上直接被裁掉。fixed layout 嚴格吃 <col> 寬度,
                超出容器交給外層的 overflow-auto 出捲軸;容器比較寬時 min-w-full 照舊撐滿。
                平板優化:訂購/已到/在途/短少/已派 收斂進品項欄的統計列,只留
                可分配 + 擬分合計 兩個數字欄;店別欄放大到 96px 裝大號觸控輸入框。
                總寬 = 品項 230 + 可分配 80(w-20) + 擬分 64(w-16) + 店別 n×96(w-24),
                改 colgroup 時要一起改這條。 */}
            <table
              className="min-w-full table-fixed divide-y divide-zinc-200 text-sm dark:divide-zinc-800"
              style={{ width: 230 + 80 + 64 + visibleStores.length * 96 }}
            >
              {/* data-store-col:整欄高亮認的就是這個屬性(見 highlightStoreCol) */}
              <colgroup ref={colGroupRef}>
                <col className="w-[230px]" />
                <col className="w-20" />
                <col className="w-16" />
                {visibleStores.map((st) => <col key={st.store_id} className="w-24" data-store-col={st.store_id} />)}
              </colgroup>
              {/* 底線用 shadow 不用 border:divide-y 的那條線掛在 tbody 上,thead 黏住時線會留在原地。
                  底色一定要逐格(th)給,不能只給 thead:border-collapse 下 thead 的背景在部分瀏覽器
                  不會畫出來,黏住的表頭會變透明、被底下的列穿過去。兩點都比照 orders/pivot 的寬表。 */}
              <thead className="sticky top-0 z-10 bg-zinc-50 shadow-[0_1px_0_0_rgb(228_228_231)] dark:bg-zinc-900 dark:shadow-[0_1px_0_0_rgb(39_39_42)]">
                <tr ref={headRowRef}>
                  {/* 勾選欄拿掉：選哪些品項改在步驟 1 決定（舊版勾選會被「目前清單」交集吃掉） */}
                  <Th className="sticky left-0 z-20 bg-zinc-50 py-2 dark:bg-zinc-900">品項 / 來源</Th>
                  <Th className="bg-zinc-50 py-2 text-center dark:bg-zinc-900" title="可分配剩餘 = 總倉已到貨 − 已派 − 本次擬分">可分配</Th>
                  <Th className="bg-zinc-50 py-2 text-center dark:bg-zinc-900" title="本次擬分合計(含被隱藏的分店欄)">擬分</Th>
                  {visibleStores.map((st) => (
                    <Th key={st.store_id} storeCol={st.store_id} className="bg-zinc-50 py-2 text-center dark:bg-zinc-900">
                      <div className="text-xs font-semibold normal-case text-zinc-700 dark:text-zinc-200">{st.store_name}</div>
                      <div className="font-mono text-[10px] font-normal text-zinc-400">{st.store_code}</div>
                    </Th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {/* 只渲染本次建單範圍的品項：有挑 → 挑中的那幾樣；沒挑 → 篩選範圍全部（舊行為） */}
                {effectiveSkuRows.map((sk) => {
                  const allocSum = getSkuAllocTotal(sk);
                  const overAlloc = allocSum > sk.totalAvailable;
                  const remaining = sk.totalAvailable - allocSum; // 可分配剩餘
                  const onHand = hqOnHand?.get(sk.sku_id);
                  return (
                    <tr key={sk.sku_id} className={overAlloc ? "bg-red-50 dark:bg-red-950/30" : ""}>
                      <Td className="sticky left-0 bg-white px-3 py-2.5 text-xs dark:bg-zinc-900">
                        <div className="flex items-start gap-2">
                          <div className="flex min-w-0 flex-1 items-start justify-between gap-2">
                          <div className="min-w-0 flex-1">
                            <div className="font-mono text-[11px] text-zinc-500">{sk.sku_code ?? "—"}</div>
                            {/* 品項欄是固定寬(table-fixed),截斷改用兩行,單行 truncate 只剩 ~10 個字 */}
                            <div className="line-clamp-2 text-[13px] font-medium" title={sk.sku_label}>{sk.sku_label}</div>
                            <div className="mt-1 flex flex-wrap items-center gap-1 text-[10px] text-zinc-400">
                              {sk.poList.length === 1
                                ? <span className="font-mono" title={`${sk.poList[0].po_status ?? ""} · 訂 ${sk.poList[0].qty_ordered}/已到 ${sk.poList[0].gr_qty}/在途 ${sk.poList[0].qty_in_transit}/短少 ${sk.poList[0].qty_shortage}`}>{sk.poList[0].po_no}</span>
                                : <span title={sk.poList.map((p) => `${p.po_no} (${p.po_status ?? ""}): 訂 ${p.qty_ordered}/到 ${p.gr_qty}/在途 ${p.qty_in_transit}/短少 ${p.qty_shortage}/撿 ${p.already_wave_for_sku}`).join("\n")}>跨 {sk.poList.length} 張 PO</span>}
                              {sk.poList.some((p) => p.is_restock_sourced) && (
                                <span
                                  className="rounded bg-amber-100 px-1 py-0.5 text-[9px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                                  title="此 PO 來源為補貨申請(restock)"
                                >
                                  📦 補貨
                                </span>
                              )}
                              {renderPriceTags(sk.sku_id)}
                            </div>
                            {/* 訂/到/途/短/派 收斂成統計列(原本各佔一欄,平板上擠掉店別欄) */}
                            <div className="mt-1 flex flex-wrap gap-x-2 gap-y-0.5 font-mono text-[10px] tabular-nums text-zinc-400">
                              <span title="向供應商訂購的總量">訂 {sk.totalOrdered}</span>
                              <span title="總倉已到貨" className="text-zinc-500 dark:text-zinc-300">到 {sk.totalGr}</span>
                              {sk.totalInTransit > 0 && (
                                <span title="PO 還沒結、還會繼續到的數量" className="text-amber-600 dark:text-amber-400">途 {sk.totalInTransit}</span>
                              )}
                              {sk.totalShortage > 0 && (
                                <span title="PO 結了但供應商少給的數量(永遠不會到)" className="text-rose-600 dark:text-rose-400">短 {sk.totalShortage}</span>
                              )}
                              <span title="已派出的數量(含撿貨單與補貨直派)">派 {sk.totalAlreadyWave}</span>
                              {onHand !== undefined && (
                                <span title="總倉即時在庫(stock_balances,純參考;派貨上限仍以 已到貨−已派 計)">倉 {onHand}</span>
                              )}
                            </div>
                          </div>
                          <SpinButton
                            type="button"
                            onClick={() => autoDistribute(sk)}
                            disabled={sk.totalAvailable === 0}
                            title={`依可分配 ${sk.totalAvailable} 平均分到各店(cap 在各店未派需求量)`}
                            className="shrink-0 self-center rounded-md border border-blue-300 bg-blue-50 px-2 py-1.5 text-[11px] font-medium text-blue-700 hover:bg-blue-100 disabled:opacity-40 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                          >
                            ⚖ 平均
                          </SpinButton>
                          </div>
                        </div>
                      </Td>
                      {/* 可分配 = 剩餘 (totalAvailable - allocSum) */}
                      <td className="px-2 py-2 text-center align-middle">
                        <div
                          title={`可分配上限 ${sk.totalAvailable} / 已分配 ${allocSum}${overAlloc ? ` / 超出 ${allocSum - sk.totalAvailable}` : ""}`}
                          className={`font-mono text-xl font-bold tabular-nums ${
                            overAlloc
                              ? "text-red-700 dark:text-red-400"
                              : remaining === 0
                                ? "text-zinc-300 dark:text-zinc-600"
                                : "text-emerald-700 dark:text-emerald-300"
                          }`}
                        >
                          {remaining}
                        </div>
                        <div className="font-mono text-[10px] tabular-nums text-zinc-400">/ {sk.totalAvailable}</div>
                      </td>
                      <NumCell value={allocSum} accent={overAlloc ? "danger" : "primary"} />
                      {visibleStores.map((st) => {
                        const value = getAlloc(sk.sku_id, st.store_id);
                        const demandQty = sk.storeDemand.get(st.store_id) ?? 0;
                        const demandLeft = storeDemandLeft(sk, st.store_id);
                        const maxForCell = value + Math.max(0, sk.totalAvailable - allocSum);
                        return (
                          <td key={st.store_id} className="px-1.5 py-2 text-center align-top">
                            <input
                              type="number"
                              inputMode="numeric"
                              value={value}
                              onChange={(e) => setAllocCapped(sk.sku_id, st.store_id, Number(e.target.value), sk.totalAvailable)}
                              // 觸發點是 focus 不是 hover：現場用 iPad,觸控沒有 hover 這回事。
                              // 只加不改：select() 照舊(點進去整數反白、直接打字就覆蓋),onChange 一個字沒動。
                              onFocus={(e) => { e.currentTarget.select(); highlightStoreCol(st.store_id); }}
                              onBlur={() => highlightStoreCol(null)}
                              min={0}
                              max={maxForCell}
                              step={1}
                              title={`未派需求 ${demandLeft}（原始需求 ${demandQty}）· 此格最多可填 ${maxForCell}`}
                              className={`h-10 w-full rounded-md border px-1 text-center font-mono text-base font-semibold tabular-nums dark:bg-zinc-800 ${
                                value === 0
                                  ? "border-zinc-200 text-zinc-300 dark:border-zinc-700"
                                  : "border-blue-400 text-blue-700 dark:border-blue-600 dark:text-blue-300"
                              }`}
                            />
                            {/* 需 = 尚未派的需求（demand − 已派，含補貨直派）；點一下直接填入(受可分配量 cap)。
                                派完顯示 ✓，別再邀請使用者重複派 */}
                            {demandLeft > 0 ? (
                              <button
                                type="button"
                                onClick={() => setAllocCapped(sk.sku_id, st.store_id, demandLeft, sk.totalAvailable)}
                                title={`點一下填入未派需求 ${demandLeft}(原始需求 ${demandQty};超過可分配量會自動夾住)`}
                                className="mt-1 w-full rounded bg-zinc-100 px-1 py-1 text-[11px] font-medium tabular-nums text-zinc-600 hover:bg-blue-100 hover:text-blue-700 dark:bg-zinc-800 dark:text-zinc-400 dark:hover:bg-blue-950 dark:hover:text-blue-300"
                              >
                                需 {demandLeft}
                              </button>
                            ) : demandQty > 0 ? (
                              <div className="mt-1 py-1 text-[11px] text-emerald-600 dark:text-emerald-500">✓ 已派</div>
                            ) : (
                              <div className="mt-1 py-1 text-[11px] text-zinc-300 dark:text-zinc-600">—</div>
                            )}
                          </td>
                        );
                      })}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )
      ) : (
        // 依分店視角 (純檢視) — 用 lazy 撈的完整清單
        fullDemand === null ? (
          <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
            載入完整清單中…
          </div>
        ) : storeSections.length === 0 ? (
          <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
            {hasActiveFilter ? "目前的篩選條件下沒有分店有待撿貨 — 換個條件或清除篩選。" : "沒有任何分店有待撿貨。"}
          </div>
        ) : storeSections.map((section) => {
          let totalDemand = 0, totalWave = 0, totalShipped = 0, totalAlloc = 0;
          for (const r of section.rows) {
            totalDemand += Number(r.demand_qty);
            totalWave += Number(r.wave_qty);
            totalShipped += Number(r.shipped_qty);
            totalAlloc += getAlloc(r.sku_id, r.store_id!);
          }
          return (
            <section
              key={section.storeId}
              className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
            >
              <header className="flex items-center justify-between gap-3 border-b border-zinc-200 px-3 py-2 dark:border-zinc-800">
                <div>
                  <h2 className="text-sm font-semibold">
                    {section.storeName}
                    <span className="ml-2 font-mono text-[11px] text-zinc-500">{section.storeCode}</span>
                  </h2>
                  <p className="text-[11px] text-zinc-500">
                    {section.rows.length} 筆 (PO×品項) · 訂單 {totalDemand}
                    {" · 已撿 "}{totalWave}
                    {" · 已派 "}{totalShipped}
                    {" · 本次擬分 "}{totalAlloc}
                  </p>
                </div>
              </header>

              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                  <thead className="bg-zinc-50 dark:bg-zinc-900">
                    <tr>
                      <Th>採購單</Th>
                      <Th>品項</Th>
                      <Th className="text-center">訂單</Th>
                      <Th className="text-center">已撿</Th>
                      <Th className="text-center">已派</Th>
                      <Th className="text-center">本次擬分(該品項合計)</Th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                    {section.rows
                      .sort((a, b) => a.po_no.localeCompare(b.po_no) || (a.sku_code ?? "").localeCompare(b.sku_code ?? ""))
                      .map((r, i) => {
                        const alloc = getAlloc(r.sku_id, r.store_id!);
                        return (
                          <tr key={`${r.po_id}:${r.sku_id}:${i}`}>
                            <Td className="px-3 py-2 font-mono text-[11px] text-zinc-600 dark:text-zinc-400">{r.po_no}</Td>
                            <Td className="px-3 py-2 text-xs">
                              <div className="font-mono text-[11px] text-zinc-500">{r.sku_code ?? "—"}</div>
                              <div className="truncate" title={r.sku_label}>{r.sku_label}</div>
                              <div className="mt-0.5 flex flex-wrap gap-1">{renderPriceTags(r.sku_id)}</div>
                            </Td>
                            <NumCell value={Number(r.demand_qty)} bold />
                            <NumCell value={Number(r.wave_qty)} muted />
                            <NumCell value={Number(r.shipped_qty)} muted />
                            <NumCell value={alloc} accent="primary" />
                          </tr>
                        );
                      })}
                  </tbody>
                </table>
              </div>
            </section>
          );
        })
      )}

      {/* === 補貨申請(無 PO 來源) section === */}
      {restockDemand !== null && visibleRestockGroups.length > 0 && (
        <section className="mt-2 rounded-md border border-amber-200 bg-amber-50/40 dark:border-amber-900 dark:bg-amber-950/20">
          <header className="border-b border-amber-200 px-4 py-2 dark:border-amber-900">
            <h2 className="text-sm font-semibold text-amber-900 dark:text-amber-200">
              📦 補貨申請(無 PO 來源)
              <span className="ml-2 text-xs font-normal text-amber-700/80 dark:text-amber-300/70">
                {visibleRestockGroups.length} 張申請 · 供給來自 HQ 即時庫存
              </span>
            </h2>
          </header>
          <div className="flex flex-col gap-3 p-3">
            {visibleRestockGroups.map((g) => {
              const allocSum = g.lines.reduce(
                (s, ln) => s + getRestockAlloc(g.rrId, ln.sku_id),
                0,
              );
              const canSubmit = allocSum > 0 && submittingRrId !== g.rrId;
              return (
                <div
                  key={g.rrId}
                  className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900"
                >
                  <div className="mb-2 flex flex-wrap items-baseline justify-between gap-2">
                    <div className="flex flex-wrap items-baseline gap-2">
                      <span className="font-mono text-sm font-semibold">
                        RR-{g.rrId}
                      </span>
                      <span className="inline-flex rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                        {g.rrStatus === "pending" ? "待處理" : "已批准"}
                      </span>
                      <span className="text-sm">{g.storeName}</span>
                      {g.storeCode && (
                        <span className="font-mono text-[11px] text-zinc-500">
                          {g.storeCode}
                        </span>
                      )}
                    </div>
                    <SpinButton
                      onClick={() => submitRestockWave(g)}
                      disabled={!canSubmit}
                      className="rounded-md bg-amber-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
                    >
                      {submittingRrId === g.rrId
                        ? "建立中…"
                        : `🧾 建立撿貨單 (擬分 ${allocSum})`}
                    </SpinButton>
                  </div>
                  <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                    <thead className="bg-zinc-50 dark:bg-zinc-950">
                      <tr>
                        <Th>品項</Th>
                        <Th className="text-center">申請量</Th>
                        <Th className="text-center" title="HQ 即時庫存 (on_hand)">HQ 庫存</Th>
                        <Th className="text-center">已撿</Th>
                        <Th className="text-center">本次撿</Th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                      {g.lines.map((ln) => {
                        const maxForLine = Math.max(
                          0,
                          Math.min(
                            Number(ln.demand_qty) - Number(ln.wave_qty),
                            Number(ln.gr_qty),
                          ),
                        );
                        const value = getRestockAlloc(g.rrId, ln.sku_id);
                        return (
                          <tr key={ln.sku_id}>
                            <Td className="text-xs">
                              <div className="font-mono text-[11px] text-zinc-500">
                                {ln.sku_code ?? "—"}
                              </div>
                              <div title={ln.sku_label}>{ln.sku_label}</div>
                              <div className="mt-0.5 flex flex-wrap gap-1">{renderPriceTags(ln.sku_id)}</div>
                            </Td>
                            <NumCell value={Number(ln.demand_qty)} bold />
                            <NumCell
                              value={Number(ln.gr_qty)}
                              accent={
                                Number(ln.gr_qty) < Number(ln.demand_qty)
                                  ? "danger"
                                  : undefined
                              }
                            />
                            <NumCell value={Number(ln.wave_qty)} muted />
                            <td className="px-2 py-1.5 text-center">
                              <input
                                type="number"
                                inputMode="numeric"
                                value={value}
                                min={0}
                                max={maxForLine}
                                step={1}
                                onChange={(e) =>
                                  setRestockAlloc(
                                    g.rrId,
                                    ln.sku_id,
                                    Number(e.target.value),
                                    maxForLine,
                                  )
                                }
                                onFocus={(e) => e.currentTarget.select()}
                                title={`最多可撿 ${maxForLine}(申請 ${ln.demand_qty}、庫存 ${ln.gr_qty}、已撿 ${ln.wave_qty})`}
                                className={`h-10 w-full max-w-[96px] rounded-md border px-1 text-center font-mono text-base font-semibold tabular-nums dark:bg-zinc-800 ${
                                  value === 0
                                    ? "border-zinc-200 text-zinc-300 dark:border-zinc-700"
                                    : "border-amber-400 text-amber-700 dark:border-amber-600 dark:text-amber-300"
                                }`}
                              />
                              <div className="mt-0.5 text-[10px] text-zinc-400">
                                ≤ {maxForLine}
                              </div>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              );
            })}
          </div>
        </section>
      )}
    </div>
  );
}

// ============================================================
// Helpers
// ============================================================

// 開團下拉：可搜尋（開團編號 / 名稱），清單只呈現最近 10 筆（options 已依結團時間新→舊排），
// 更多的靠輸入關鍵字縮小範圍。互動模式抄 SupplierCombobox（含 e.preventDefault() 防
// label click 轉發把剛關掉的下拉重新打開的坑）。
function CampaignCombobox({
  value,
  options,
  hasNoneOption,
  onChange,
}: {
  value: string; // "all" | "none" | `${campaign_id}`
  options: CampaignInfo[];
  hasNoneOption: boolean;
  onChange: (v: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const containerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    function onClickAway(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
        setQuery("");
      }
    }
    if (open) document.addEventListener("mousedown", onClickAway);
    return () => document.removeEventListener("mousedown", onClickAway);
  }, [open]);
  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  const selected =
    value !== "all" && value !== "none" ? options.find((c) => String(c.id) === value) ?? null : null;
  const q = query.trim().toLowerCase();
  const matched = q
    ? options.filter(
        (c) => c.campaign_no.toLowerCase().includes(q) || c.name.toLowerCase().includes(q),
      )
    : options;
  const shown = matched.slice(0, 10);
  const more = matched.length - shown.length;

  function pick(e: React.MouseEvent, v: string) {
    e.preventDefault(); // 取消 click 轉發，避免關閉後又被轉發的 click 重新打開
    onChange(v);
    setOpen(false);
    setQuery("");
  }
  const endDate = (c: CampaignInfo) => {
    const ref = c.end_at ?? c.start_at;
    return ref ? new Date(ref).toLocaleDateString("sv-SE") : "—";
  };

  return (
    <div ref={containerRef} className="relative">
      {!open ? (
        <button
          type="button"
          onClick={() => setOpen(true)}
          className="flex h-11 w-full items-center justify-between gap-2 rounded-md border border-zinc-300 bg-white px-3 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          {selected ? (
            <span className="flex min-w-0 items-baseline gap-2">
              <span className="shrink-0 font-mono text-xs text-zinc-500">{selected.campaign_no}</span>
              <span className="truncate">{selected.name}</span>
            </span>
          ) : value === "none" ? (
            <span>無開團來源（補貨等）</span>
          ) : (
            <span>全部開團</span>
          )}
          <span className="shrink-0 text-zinc-400">▾</span>
        </button>
      ) : (
        <input
          ref={inputRef}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              setOpen(false);
              setQuery("");
            } else if (e.key === "Enter") {
              e.preventDefault();
              if (shown.length > 0) {
                onChange(String(shown[0].id));
                setOpen(false);
                setQuery("");
              }
            }
          }}
          placeholder="搜尋開團編號或名稱…"
          className="h-11 w-full rounded-md border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
      )}

      {open && (
        <div className="absolute left-0 right-0 z-30 mt-1 max-h-80 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
          <button
            type="button"
            onClick={(e) => pick(e, "all")}
            className={`block w-full px-3 py-2.5 text-left text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800 ${
              value === "all" ? "bg-blue-50 dark:bg-blue-950" : ""
            }`}
          >
            全部開團
          </button>
          {hasNoneOption && (
            <button
              type="button"
              onClick={(e) => pick(e, "none")}
              className={`block w-full border-b border-zinc-200 px-3 py-2.5 text-left text-sm hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800 ${
                value === "none" ? "bg-blue-50 dark:bg-blue-950" : ""
              }`}
            >
              無開團來源（補貨等）
            </button>
          )}
          {shown.length === 0 ? (
            <p className="px-3 py-2.5 text-xs text-zinc-500">
              {q ? "找不到符合的開團" : "目前沒有待派的開團"}
            </p>
          ) : (
            shown.map((c) => (
              <button
                key={c.id}
                type="button"
                onClick={(e) => pick(e, String(c.id))}
                className={`block w-full px-3 py-2.5 text-left hover:bg-zinc-50 dark:hover:bg-zinc-800 ${
                  String(c.id) === value ? "bg-blue-50 dark:bg-blue-950" : ""
                }`}
              >
                <span className="flex items-baseline justify-between gap-2">
                  <span className="flex min-w-0 items-baseline gap-2">
                    <span className="shrink-0 font-mono text-xs text-zinc-500">{c.campaign_no}</span>
                    <span className="truncate text-sm">{c.name}</span>
                  </span>
                  <span className="shrink-0 text-[11px] text-zinc-400">結團 {endDate(c)}</span>
                </span>
              </button>
            ))
          )}
          {more > 0 && (
            <p className="border-t border-zinc-200 px-3 py-2 text-xs text-zinc-400 dark:border-zinc-800">
              另有 {more} 團未顯示 — 輸入開團編號或名稱縮小範圍
            </p>
          )}
        </div>
      )}
    </div>
  );
}

function TabBtn({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <SpinButton
      onClick={onClick}
      className={`whitespace-nowrap border-b-2 px-1 py-2 text-sm font-medium transition ${
        active
          ? "border-blue-600 text-blue-600 dark:border-blue-400 dark:text-blue-400"
          : "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700 dark:hover:text-zinc-300"
      }`}
    >
      {children}
    </SpinButton>
  );
}

// 兩步驟切換鈕（平板觸控目標 ≥ 44px）
function StepBtn({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <SpinButton
      onClick={onClick}
      className={`min-h-[44px] rounded-md px-4 text-sm font-semibold transition ${
        active
          ? "bg-blue-600 text-white"
          : "border border-zinc-300 text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
      }`}
    >
      {children}
    </SpinButton>
  );
}

function Th({
  children,
  className = "",
  title,
  storeCol,
}: {
  children: React.ReactNode;
  className?: string;
  title?: string;
  /** 這一格屬於哪一間分店 — 整欄高亮用來認欄位(不給就不輸出屬性,其他表照舊)。 */
  storeCol?: number;
}) {
  return <th title={title} data-store-col={storeCol} className={`px-2 py-1.5 text-left text-[11px] font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}

function KpiCard({ label, value, accent = "text-zinc-900 dark:text-zinc-100", hint }: { label: string; value: number; accent?: string; hint?: string }) {
  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-0.5 font-mono text-2xl font-semibold tabular-nums ${accent}`}>{value}</div>
      {hint && <div className="mt-0.5 text-[10px] text-zinc-400">{hint}</div>}
    </div>
  );
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-2 py-2 ${className}`}>{children}</td>;
}

function NumCell({
  value,
  bold = false,
  muted = false,
  accent,
}: {
  value: number;
  bold?: boolean;
  muted?: boolean;
  accent?: "primary" | "danger" | "transit";
}) {
  const isZero = value === 0;
  const cls = accent === "danger"
    ? "text-rose-600 font-medium"
    : accent === "transit"
      ? "text-amber-600 font-medium dark:text-amber-400"
      : accent === "primary"
        ? (isZero ? "text-zinc-300" : "text-blue-600 font-medium")
        : muted
          ? (isZero ? "text-zinc-300" : "text-zinc-500")
          : bold
            ? (isZero ? "text-zinc-300" : "text-zinc-700 dark:text-zinc-200")
            : "text-zinc-600 dark:text-zinc-400";
  return (
    <td className={`px-2 py-2 text-center font-mono text-sm tabular-nums ${cls}`}>
      {value}
    </td>
  );
}

"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import Spinner from "@/components/Spinner";
import {
  TransferReceiveModal,
  TRANSFER_TYPE_LABEL,
  parseWaveId,
  type Transfer,
  type Wave,
} from "@/components/TransferReceiveModal";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";
import { useUserBranchStoreId } from "@/lib/useDefaultStoreFromUser";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { fanoutPickupNotifications } from "@/lib/pickupNotify";
import { TransferOrdersModal, type ModalSkuLine } from "@/components/TransferOrdersModal";
import { ShortageAllocateModal } from "@/components/ShortageAllocateModal";
import {
  ManualAllocateModal,
  type AllocModalMode,
  type ReceiveLine,
} from "@/components/ManualAllocateModal";

type Location = { id: number; name: string };
type StoreLite = { id: number; location_id: number | null };
type StoreRow = { id: number; name: string; location_id: number | null };
// codes：本張 transfer 涵蓋的品項編號(sku_code) / 商品編號(product_code)，僅供搜尋比對用
// items：拆開的品項行（key = 合併同品相用的識別；自由轉貨掛虛擬 SKU，要用 description 當 key）
// product = 只有商品名（不含規格），給群組標題用；name = 商品名 / 規格，明細表用
type ItemLine = { key: string; skuId: number | null; product: string; name: string; skuCode: string | null; qty: number };
// extraQty / shortQty：這張單的派出量 vs 訂單需求量差額（見下方查詢註解）
//   extraQty = 多給、沒有訂單對應；shortQty = 不夠分，會有客人領不到
//   coveredQty = 缺口中已用「店內現貨減抵單」吸收的件數（shortQty 已淨掉這部分）
//   prefilledQty = 這批到貨其實是「補回店家先墊的現貨」的件數（店家已用店內現貨
//     把客人的貨交掉，總倉的貨照樣會來 — 見 20260805000220 migration）
//   backorderQty = 這組還掛著幾件「待補貨」（少發配貨沒配到、backorder_at 未解）。
//     收貨到店時會自動解除（20260811000050），但實體庫存對不上時不會放行 —
//     那種情況一定要留「⚖️ 配貨」入口給店家自己處理，所以 short 歸零也要顯示。
type ItemSummary = {
  lines: number;
  totalQty: number;
  names: string[];
  codes: string[];
  items: ItemLine[];
  extraQty: number;
  shortQty: number;
  coveredQty: number;
  prefilledQty: number;
  backorderQty: number;
};

// 列表上的一個可收合群組（product 模式＝同品相，wave 模式＝同撿貨單號）
type Group = {
  key: string;
  label: string;
  labelTitle: string; // hover 才看得到的完整品名 / 規格清單
  subLabel: string;
  mono: boolean; // label 是單號 → 等寬字
  transfers: Transfer[];
  totalQty: number;
  sortCode: string;
  waveDate: string | null; // 配送日，用來標「逾期 / 今天」
  extraQty: number;        // 這組總共被總倉多給幾件
  shortQty: number;        // 這組總共少了幾件（訂單比派出多，已淨掉現貨減抵）
  coveredQty: number;      // 這組用店內現貨減抵掉幾件
  prefilledQty: number;    // 這組有幾件是補回店家先墊的現貨
  backorderQty: number;    // 這組還有幾件掛著待補貨（少發配貨沒配到）
};

export default function TransfersInboxPage() {
  const [transfers, setTransfers] = useState<Transfer[] | null>(null);
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [locations, setLocations] = useState<Map<number, string>>(new Map());
  const [waves, setWaves] = useState<Map<number, Wave>>(new Map());
  const [itemSummary, setItemSummary] = useState<Map<number, ItemSummary>>(new Map());
  const [locationToStore, setLocationToStore] = useState<Map<number, number>>(new Map());
  const [transferCampaigns, setTransferCampaigns] = useState<Map<number, number[]>>(new Map());
  // 每張單的來源：campaign=開團派貨（背後有顧客訂單）/ restock=補貨 / free=自由轉貨・互助
  // 補貨與自由轉貨本來就沒有顧客訂單，畫面要講清楚，不然點開只看到「查不到訂單」會以為壞了
  const [sourceKinds, setSourceKinds] = useState<Map<number, string>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [opening, setOpening] = useState<Transfer | null>(null);
  // 點數量開的「訂單明細」彈窗：看這幾件分別是誰的訂單、多給的幾件沒人訂
  const [ordersFor, setOrdersFor] = useState<
    { transferId: number; transferNo: string; skuLines: ModalSkuLine[] } | null
  >(null);
  // 少發配貨對話框：這批不夠分時決定配給誰
  const [allocFor, setAllocFor] = useState<
    { transferId: number; skuId: number; skuName: string } | null
  >(null);
  // 手動配貨對話框（兩種模式）：
  //   receive = 「✋ 收貨·手動配」— 收貨前先勾這批單對到的訂單，確認才收貨＋配單
  //   store   = 「✋ 手動配單」常駐入口 — 收完貨之後（再）配，全店範圍
  const [allocModal, setAllocModal] = useState<
    { mode: AllocModalMode; storeName: string } | null
  >(null);
  const [locationFilter, setLocationFilter] = useState<number | "all">("all");
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [doneLimit, setDoneLimit] = useState(50);
  const [doneTotal, setDoneTotal] = useState(0);
  // 撿貨單號（wave）分頁：一次顯示 20 個 wave，滑到底自動載入下一批（+20）
  const [groupLimit, setGroupLimit] = useState(20);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [batchBusy, setBatchBusy] = useState(false);
  // 收貨後是否整批推播「到貨」給受影響會員；店家可自行開關，記在 localStorage（預設開）
  const [notifyMembers, setNotifyMembers] = useState<boolean>(() => {
    if (typeof window === "undefined") return true;
    return window.localStorage.getItem("inbound-notify-members") !== "0";
  });
  useEffect(() => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem("inbound-notify-members", notifyMembers ? "1" : "0");
    }
  }, [notifyMembers]);
  // 配單方式不是全域開關，而是每次收貨當下選：收貨按鈕都有兩顆 ——
  // 「收貨·自動配」＝收貨後依訂單時間自動配（原行為）；「✋收貨·手動配」＝
  // 先跳出這批單對到的訂單勾選，按「確認收貨」才一次完成收貨＋配單
  // （取消＝不收貨）。見 20260813000000 / 20260813010000 migration。
  // 檢視模式：product = 同品相（同分店 + 同配送日 + 同品項組合）的單合併成一列；
  // wave = 舊行為，依撿貨單號分組。店家幾乎都是一單一品，合併後畫面短很多 → 預設 product。
  type GroupMode = "product" | "wave";
  const [groupMode, setGroupMode] = useState<GroupMode>(() => {
    if (typeof window === "undefined") return "product";
    return window.localStorage.getItem("inbound-group-mode") === "wave" ? "wave" : "product";
  });
  // 技術欄位（調撥單號 / 調撥類型 / 派出時間 / 訂單連結 / KPI 說明）。
  // 店家看不懂也用不到，預設收起來；總倉要對單再自己打開，設定記在 localStorage。
  const [showDetail, setShowDetail] = useState<boolean>(() => {
    if (typeof window === "undefined") return false;
    return window.localStorage.getItem("inbound-show-detail") === "1";
  });
  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem("inbound-group-mode", groupMode);
    window.localStorage.setItem("inbound-show-detail", showDetail ? "1" : "0");
  }, [groupMode, showDetail]);
  // 載入完成時要不要自動展開群組 — 只有 wave 模式才展開（product 模式標題已經寫著品名+數量，
  // 展開只是把畫面拉長）。放 ref 是為了不讓 groupMode 進到抓資料的 effect deps 觸發重抓。
  const groupModeRef = useRef(groupMode);
  useEffect(() => { groupModeRef.current = groupMode; }, [groupMode]);

  // 今天（本地時區 YYYY-MM-DD），用來標群組的「逾期 / 今天到貨」
  const todayStr = useMemo(() => new Date().toLocaleDateString("sv-SE"), []);

  // 待收子篩選（僅在「未收」分頁內作用）
  type DateFilter = "tomorrow" | "today_or_earlier" | "all_pending" | null;
  const [dateFilter, setDateFilter] = useState<DateFilter>(null);
  // 分頁：未收(shipped) / 已收(received)，預設未收
  type InboxTab = "unreceived" | "received";
  const [tab, setTab] = useState<InboxTab>("unreceived");
  // 搜尋：撿貨單號(wave_code) / 調撥單號 / 分店 / 商品名 / 商品編號(product_code) / 品項編號(sku_code)
  const [search, setSearch] = useState("");
  // 已收貨只載入最近 doneLimit 筆，客端搜尋會漏掉更早的單（例：月結對帳回頭查
  // 上個月的 WAVE-xx）→ 搜尋字像單號時另外打一發後端 ilike 補查合併進列表。
  const [serverSearch, setServerSearch] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setServerSearch(search.trim()), 400);
    return () => clearTimeout(t);
  }, [search]);

  // 分店帳號鎖定：把 store.name 比對 user.app_metadata.stores，回該分店的 location_id。
  // 分店帳號只能看自己分店（dest_location = 該 location_id）；HQ/總倉回 null = 看全部。
  const storeLocOptions = useMemo(
    () =>
      stores
        .filter((s) => s.location_id != null)
        .map((s) => ({ id: s.location_id as number, name: s.name })),
    [stores],
  );
  const branchLocationId = useUserBranchStoreId(storeLocOptions);

  // 先載入分店清單（含 name + location_id），供分店帳號鎖定用。獨立 effect 只跑一次。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data } = await sb
        .from("stores")
        .select("id, name, location_id")
        .eq("is_active", true)
        .order("name");
      if (!cancelled) setStores((data as StoreRow[]) ?? []);
    })();
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        // 拆兩個 query 防止 NULL shipped_at 的 received 把 limit 用滿、擠掉真正待收的 shipped
        // 分店帳號：只撈自己分店 (dest_location = branchLocationId) 的 transfer
        let pendingQ = sb
          .from("transfers")
          .select(
            "id, transfer_no, source_location, dest_location, status, transfer_type, shipped_at, received_at, notes",
          )
          .eq("status", "shipped")
          .order("shipped_at", { ascending: false, nullsFirst: false });
        let doneQ = sb
          .from("transfers")
          .select(
            "id, transfer_no, source_location, dest_location, status, transfer_type, shipped_at, received_at, notes",
            { count: "exact" },
          )
          .eq("status", "received")
          .order("received_at", { ascending: false, nullsFirst: false })
          .limit(doneLimit);
        if (branchLocationId != null) {
          pendingQ = pendingQ.eq("dest_location", branchLocationId);
          doneQ = doneQ.eq("dest_location", branchLocationId);
        }
        const [{ data: pendingData, error: e1 }, { data: doneData, error: e2, count: doneCount }] = await Promise.all([
          pendingQ,
          doneQ,
        ]);
        if (e1) throw new Error(e1.message);
        if (e2) throw new Error(e2.message);
        if (!cancelled) setDoneTotal(doneCount ?? 0);
        const rows = ([...(pendingData ?? []), ...(doneData ?? [])] as Transfer[]);

        // 搜尋補查：老單被 doneLimit 擠出載入範圍時，用單號直接查後端合併進來
        if (serverSearch) {
          let extraQ = sb
            .from("transfers")
            .select(
              "id, transfer_no, source_location, dest_location, status, transfer_type, shipped_at, received_at, notes",
            )
            .ilike("transfer_no", `%${serverSearch}%`)
            .in("status", ["shipped", "received"])
            .order("id", { ascending: false })
            .limit(30);
          if (branchLocationId != null) extraQ = extraQ.eq("dest_location", branchLocationId);
          const { data: extraData } = await extraQ;
          const seen = new Set(rows.map((r) => r.id));
          for (const r of (extraData ?? []) as Transfer[]) {
            if (!seen.has(r.id)) rows.push(r);
          }
        }

        const locIds = Array.from(
          new Set(rows.flatMap((r) => [r.source_location, r.dest_location])),
        );
        const locMap = new Map<number, string>();
        if (locIds.length > 0) {
          const { data: locs } = await sb
            .from("locations")
            .select("id, name")
            .in("id", locIds);
          for (const l of (locs as Location[] | null) ?? []) {
            locMap.set(l.id, l.name);
          }
        }

        const waveIds = Array.from(
          new Set(rows.map((r) => parseWaveId(r.transfer_no)).filter((x): x is number => x !== null)),
        );
        const waveMap = new Map<number, Wave>();
        if (waveIds.length > 0) {
          const { data: ws } = await sb
            .from("picking_waves")
            .select("id, wave_code, wave_date, created_at")
            .in("id", waveIds);
          for (const w of (ws as Wave[] | null) ?? []) waveMap.set(w.id, w);
        }

        // 抓 transfer_items + skus 用於顯示「商品/數量」
        const summary = new Map<number, ItemSummary>();
        if (rows.length > 0) {
          const transferIds = rows.map((r) => r.id);
          // 走 fetchAllRows 分頁：待收 transfer 數不設限，×每張多列品項很容易破
          // PostgREST 1000 列上限；不分頁的話最新 wave（transfer_id 最大、排在尾端）
          // 的品項會整批被截掉 → summary.lines=0 → 品名全變「—」。
          // description = 自由轉貨（店轉店）的實際品名；有值時掛在虛擬 SKU（MISC-01
          // 「虛擬轉貨商品」）上，顯示要用 description 而不是虛擬 SKU 的佔位名稱。
          const items = await fetchAllRows<{
            transfer_id: number;
            sku_id: number;
            qty_shipped: number;
            description: string | null;
          }>(
            () =>
              sb
                .from("transfer_items")
                .select("transfer_id, sku_id, qty_shipped, description")
                .in("transfer_id", transferIds)
                .order("id"),
          );
          const skuIds = Array.from(new Set(items.map((it) => it.sku_id)));
          const skuNameMap = new Map<number, string>();
          // 群組標題只用商品名（同商品的多個規格會被去重成一筆），規格留給展開的明細
          const skuProductMap = new Map<number, string>();
          const skuOnlyCodeMap = new Map<number, string>();
          // sku_code = 品項編號、product_code = 商品編號（products embed）；供搜尋比對
          const skuCodeMap = new Map<number, string>();
          if (skuIds.length > 0) {
            const skuRows = await fetchAllRows<{
              id: number;
              product_name: string | null;
              variant_name: string | null;
              sku_code: string | null;
              products: { product_code: string | null } | null;
            }>(
              () =>
                sb
                  .from("skus")
                  .select("id, product_name, variant_name, sku_code, products(product_code)")
                  .in("id", skuIds)
                  .order("id"),
            );
            for (const s of skuRows) {
              const label = `${s.product_name ?? ""}${s.variant_name ? ` / ${s.variant_name}` : ""}`.trim() || `#${s.id}`;
              skuNameMap.set(s.id, label);
              skuProductMap.set(s.id, (s.product_name ?? "").trim() || label);
              if (s.sku_code) skuOnlyCodeMap.set(s.id, s.sku_code);
              const code = [s.sku_code, s.products?.product_code].filter(Boolean).join(" ").trim();
              if (code) skuCodeMap.set(s.id, code);
            }
          }
          const emptySummary = (): ItemSummary => ({ lines: 0, totalQty: 0, names: [], codes: [], items: [], extraQty: 0, shortQty: 0, coveredQty: 0, prefilledQty: 0, backorderQty: 0 });
          for (const tid of transferIds) summary.set(tid, emptySummary());
          for (const it of items) {
            const cur = summary.get(it.transfer_id) ?? emptySummary();
            cur.lines += 1;
            const qty = Number(it.qty_shipped);
            cur.totalQty += qty;
            const desc = it.description?.trim();
            const name = desc || (skuNameMap.get(it.sku_id) ?? `#${it.sku_id}`);
            cur.names.push(`${name} × ${qty}`);
            cur.items.push({
              key: desc ? `d:${desc}` : `s:${it.sku_id}`,
              // 自由轉貨掛在虛擬 SKU 上，對不到顧客訂單 → 不給 skuId
              skuId: desc ? null : it.sku_id,
              product: desc || skuProductMap.get(it.sku_id) || name,
              name,
              skuCode: desc ? null : skuOnlyCodeMap.get(it.sku_id) ?? null,
              qty,
            });
            const code = skuCodeMap.get(it.sku_id);
            if (code) cur.codes.push(code);
            summary.set(it.transfer_id, cur);
          }

          // 派出量 vs 該店該團的訂單需求量：多給（沒訂單對應）與不夠分（會有人領不到）。
          // 不是比 picking_wave_items 的 picked_qty vs qty — 線上 17429 列裡 over_pick
          // 是 0，用那個定義標籤永遠不會亮（見 20260805000050 migration）。
          // 件數與彈窗裡「派出 − 訂單合計」同一套 join，兩邊數字保證一致。
          // short 已淨掉店內現貨減抵（covered），見 20260805000170 migration。
          const { data: diffData } = await sb.rpc("rpc_get_ship_vs_demand_for_transfers", {
            p_transfer_ids: transferIds,
          });
          const diffs =
            (diffData as Record<string, { over?: number; short?: number; covered?: number; prefilled?: number; backorder?: number }> | null) ?? {};
          for (const [tid, d] of Object.entries(diffs)) {
            const cur = summary.get(Number(tid));
            if (!cur) continue;
            cur.extraQty = Number(d?.over) || 0;
            cur.shortQty = Number(d?.short) || 0;
            cur.coveredQty = Number(d?.covered) || 0;
            cur.prefilledQty = Number(d?.prefilled) || 0;
            cur.backorderQty = Number(d?.backorder) || 0;
          }
        }

        // 來源類型（開團 / 補貨 / 自由轉貨）— 決定要不要給「看訂單」入口
        const kindMap = new Map<number, string>();
        if (rows.length > 0) {
          const { data: kindData } = await sb.rpc("rpc_get_transfer_source_kinds", {
            p_transfer_ids: rows.map((r) => r.id),
          });
          for (const [tid, kind] of Object.entries((kindData as Record<string, string> | null) ?? {})) {
            kindMap.set(Number(tid), kind);
          }
        }

        // location → store mapping (for /orders link filter)
        const locStoreMap = new Map<number, number>();
        if (locIds.length > 0) {
          const { data: storeRows } = await sb
            .from("stores")
            .select("id, location_id")
            .in("location_id", locIds);
          for (const s of (storeRows ?? []) as StoreLite[]) {
            if (s.location_id) locStoreMap.set(s.location_id, s.id);
          }
        }

        // 抓每張 transfer 涵蓋的 campaign_ids（用於 /orders link 多選 filter）
        // 批次：一次傳全部 transfer id、回 { transfer_id: [campaign_ids] }，
        // 取代之前每張 transfer 各打一次 RPC（N+1，開頁 ~50+ round-trip）。
        const tcMap = new Map<number, number[]>();
        if (rows.length > 0) {
          const { data: tcData } = await sb.rpc("rpc_get_campaigns_for_transfers", {
            p_transfer_ids: rows.map((r) => r.id),
          });
          const obj = (tcData as Record<string, unknown> | null) ?? {};
          for (const [tid, cids] of Object.entries(obj)) {
            const ids = (Array.isArray(cids) ? cids : [])
              .map((x) => Number(x))
              .filter((x) => Number.isFinite(x));
            tcMap.set(Number(tid), ids);
          }
        }

        if (!cancelled) {
          setTransfers(rows);
          setLocations(locMap);
          setWaves(waveMap);
          setItemSummary(summary);
          setLocationToStore(locStoreMap);
          setTransferCampaigns(tcMap);
          setSourceKinds(kindMap);
          setError(null);
          const auto = new Set<string>();
          for (const r of rows) {
            if (r.status !== "shipped") continue;
            const wid = parseWaveId(r.transfer_no);
            auto.add(wid !== null ? `wave-${wid}` : "other");
          }
          // product 模式的群組 key 由內容算出、重載後仍相同 → 保留使用者展開的狀態，
          // 不要每次收完貨都把畫面重設。
          setExpanded((prev) => (groupModeRef.current === "wave" ? auto : prev));
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick, doneLimit, branchLocationId, serverSearch]);

  const destOptions = useMemo(() => {
    const set = new Map<number, string>();
    for (const t of transfers ?? []) {
      set.set(t.dest_location, locations.get(t.dest_location) ?? `#${t.dest_location}`);
    }
    return Array.from(set.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }, [transfers, locations]);

  const filtered = useMemo(() => {
    const today = new Date();
    const tomorrow = new Date();
    tomorrow.setDate(today.getDate() + 1);
    const todayStr = today.toLocaleDateString("sv-SE");
    const tomorrowStr = tomorrow.toLocaleDateString("sv-SE");
    const q = search.trim().toLowerCase();
    const matchSearch = (t: Transfer) => {
      if (!q) return true;
      const summary = itemSummary.get(t.id);
      const wid = parseWaveId(t.transfer_no);
      const wave = wid !== null ? waves.get(wid) : undefined;
      const haystack = [
        t.transfer_no,
        wave?.wave_code ?? "", // 撿貨單號
        locations.get(t.dest_location) ?? "",
        ...(summary?.names ?? []), // 商品名
        ...(summary?.codes ?? []), // 品項編號 sku_code / 商品編號 product_code
      ]
        .join(" ")
        .toLowerCase();
      return haystack.includes(q);
    };
    return (transfers ?? []).filter((t) => {
      if (locationFilter !== "all" && t.dest_location !== locationFilter) return false;
      if (!matchSearch(t)) return false;
      // 分頁為主篩選：已收 = received；未收 = shipped（再套待收子篩選）
      if (tab === "received") return t.status === "received";
      if (t.status !== "shipped") return false;
      if (dateFilter === null || dateFilter === "all_pending") return true;
      const wid = parseWaveId(t.transfer_no);
      const w = wid !== null ? waves.get(wid) : undefined;
      const wd = w?.wave_date ?? null;
      if (dateFilter === "tomorrow") return wd === tomorrowStr;
      if (dateFilter === "today_or_earlier") return !!wd && wd <= todayStr;
      return true;
    });
  }, [transfers, locationFilter, tab, dateFilter, waves, search, itemSummary, locations]);

  const groups = useMemo(() => {
    const map = new Map<string, Group>();
    if (groupMode === "wave") {
      for (const t of filtered) {
        const wid = parseWaveId(t.transfer_no);
        const key = wid !== null ? `wave-${wid}` : "other";
        let entry = map.get(key);
        if (!entry) {
          const w = wid !== null ? waves.get(wid) : undefined;
          entry = {
            key,
            label: w?.wave_code ?? (wid !== null ? `WAVE-${wid}` : "其他調撥"),
            labelTitle: "",
            subLabel: w ? `配送日 ${w.wave_date}` : "",
            mono: true,
            transfers: [],
            totalQty: 0,
            // 排序鍵＝撿貨單號（wave_code）；wave_code 已內含日期，字串遞減即最新在前
            sortCode: w?.wave_code ?? (wid !== null ? `WAVE-${wid}` : ""),
            waveDate: w?.wave_date ?? null,
            extraQty: 0,
            shortQty: 0,
            coveredQty: 0,
            prefilledQty: 0,
            backorderQty: 0,
          };
          map.set(key, entry);
        }
        entry.transfers.push(t);
        entry.totalQty += itemSummary.get(t.id)?.totalQty ?? 0;
        entry.extraQty += itemSummary.get(t.id)?.extraQty ?? 0;
        entry.shortQty += itemSummary.get(t.id)?.shortQty ?? 0;
        entry.coveredQty += itemSummary.get(t.id)?.coveredQty ?? 0;
        entry.prefilledQty += itemSummary.get(t.id)?.prefilledQty ?? 0;
        entry.backorderQty += itemSummary.get(t.id)?.backorderQty ?? 0;
      }
      return Array.from(map.values()).sort((a, b) => {
        // 「其他調撥」永遠墊底，其餘依撿貨單號遞減
        if (a.key === "other") return 1;
        if (b.key === "other") return -1;
        return b.sortCode.localeCompare(a.sortCode);
      });
    }

    // product 模式：同分店 + 同配送日 + 同品項組合 → 併成一列。
    // 配送日進 key 是刻意的：把 8/3 沒收到的跟 8/5 的併在一起會讓逾期的那批消失在總數裡。
    for (const t of filtered) {
      const s = itemSummary.get(t.id);
      const wid = parseWaveId(t.transfer_no);
      const w = wid !== null ? waves.get(wid) : undefined;
      const date = w?.wave_date ?? "";
      const lines = [...(s?.items ?? [])].sort((a, b) => a.key.localeCompare(b.key));
      const sig = lines.map((l) => l.key).join("|") || "empty";
      const key = `p-${t.dest_location}-${date}-${sig}`;
      let entry = map.get(key);
      if (!entry) {
        const dest = locations.get(t.dest_location) ?? `#${t.dest_location}`;
        // 標題只列商品名、去重、最多 3 個 — 一張單常含同商品的十幾個規格
        // （例：「水麥芽手撕蛋糕 / (A)經典原味」…(G)），全列出來標題會佔掉整個畫面。
        // 規格與 SKU 編號留在展開的明細表。
        const products = Array.from(new Set(lines.map((l) => l.product)));
        const shown = products.slice(0, 3).join("、");
        entry = {
          key,
          label: (products.length > 3 ? `${shown} …+${products.length - 3} 項` : shown) || "—",
          labelTitle: Array.from(new Set(lines.map((l) => l.name))).join("\n"),
          subLabel: [dest, date ? `配送日 ${date}` : ""].filter(Boolean).join(" · "),
          mono: false,
          transfers: [],
          totalQty: 0,
          // 未收：日期小的（逾期/今天）排前面；已收：日期大的（最近收的）排前面。見下方 sort。
          sortCode: `${date || "9999-99-99"}|${products.join("、")}|${dest}`,
          waveDate: date || null,
          extraQty: 0,
          shortQty: 0,
          coveredQty: 0,
          prefilledQty: 0,
          backorderQty: 0,
        };
        map.set(key, entry);
      }
      entry.transfers.push(t);
      entry.totalQty += s?.totalQty ?? 0;
      entry.extraQty += s?.extraQty ?? 0;
      entry.shortQty += s?.shortQty ?? 0;
      entry.coveredQty += s?.coveredQty ?? 0;
      entry.prefilledQty += s?.prefilledQty ?? 0;
      entry.backorderQty += s?.backorderQty ?? 0;
    }
    const asc = tab === "unreceived";
    return Array.from(map.values()).sort((a, b) =>
      asc ? a.sortCode.localeCompare(b.sortCode) : b.sortCode.localeCompare(a.sortCode),
    );
  }, [filtered, waves, itemSummary, locations, groupMode, tab]);

  // 切分頁 / 篩選 / 搜尋 / 檢視模式時，群組分頁歸零回第一頁（20 筆）
  useEffect(() => {
    setGroupLimit(20);
  }, [tab, dateFilter, locationFilter, search, groupMode]);

  // 切到「依撿貨單」時把待收的撿貨單展開（沿用舊行為 — 收起來只剩單號，看不到品名）；
  // 切回「合併同商品」則全部收起，標題本身就寫著品名與總數。
  function switchGroupMode(mode: GroupMode) {
    if (mode === groupMode) return;
    setGroupMode(mode);
    if (mode !== "wave") {
      setExpanded(new Set());
      return;
    }
    const auto = new Set<string>();
    for (const r of transfers ?? []) {
      if (r.status !== "shipped") continue;
      const wid = parseWaveId(r.transfer_no);
      auto.add(wid !== null ? `wave-${wid}` : "other");
    }
    setExpanded(auto);
  }

  const visibleGroups = useMemo(() => groups.slice(0, groupLimit), [groups, groupLimit]);

  // 滑到底自動載入下一批撿貨單號（+20），不用手動按。sentinel 進入視窗就 +20；
  // effect 依 groupLimit/groups.length 重建 observer，若 sentinel 仍在視窗內會連續補到看不見為止。
  const sentinelRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (groupLimit >= groups.length) return;
    const el = sentinelRef.current;
    if (!el) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting) setGroupLimit((n) => n + 20);
      },
      { rootMargin: "300px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [groupLimit, groups.length]);

  function toggle(key: string) {
    setExpanded((cur) => {
      const next = new Set(cur);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  function toggleSelected(id: number) {
    setSelected((cur) => {
      const next = new Set(cur);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  // 群組層的勾選：整組待收全勾 / 全取消
  function toggleGroupSelected(g: Group) {
    const ids = g.transfers.filter((t) => t.status === "shipped").map((t) => t.id);
    if (ids.length === 0) return;
    setSelected((cur) => {
      const next = new Set(cur);
      const allOn = ids.every((id) => next.has(id));
      for (const id of ids) {
        if (allOn) next.delete(id);
        else next.add(id);
      }
      return next;
    });
  }

  const pendingIds = useMemo(
    () =>
      (transfers ?? [])
        .filter((t) => t.status === "shipped" && (locationFilter === "all" || t.dest_location === locationFilter))
        .map((t) => t.id),
    [transfers, locationFilter],
  );

  // KPI summaries: 4 個分類,點 KPI card 就 filter list
  const summaries = useMemo(() => {
    const empty = { tomorrow: 0, todayOrEarlier: 0, allPending: 0, done: 0 };
    if (!transfers) return empty;
    const today = new Date();
    const tomorrow = new Date();
    tomorrow.setDate(today.getDate() + 1);
    const todayStr = today.toLocaleDateString("sv-SE");
    const tomorrowStr = tomorrow.toLocaleDateString("sv-SE");
    const acc = { ...empty };
    for (const t of transfers) {
      if (locationFilter !== "all" && t.dest_location !== locationFilter) continue;
      if (t.status === "received") { acc.done += 1; continue; }
      if (t.status !== "shipped") continue;
      acc.allPending += 1;
      const wid = parseWaveId(t.transfer_no);
      const w = wid !== null ? waves.get(wid) : undefined;
      if (!w?.wave_date) continue;
      if (w.wave_date === tomorrowStr) acc.tomorrow += 1;
      else if (w.wave_date <= todayStr) acc.todayOrEarlier += 1;
    }
    return acc;
  }, [transfers, waves, locationFilter]);

  function selectAllPending() {
    setSelected(new Set(pendingIds));
  }
  function clearSelection() {
    setSelected(new Set());
  }

  // 收貨狀態變動後重載列表,並通知側欄「收貨」badge 重抓(見 layout INBOUND_BADGE_REFRESH_EVENT)
  function reloadAndRefreshBadge() {
    setReloadTick((n) => n + 1);
    window.dispatchEvent(new Event("inbound-badge-refresh"));
  }

  // confirm 對話框裡的「是否通知會員」提示行（依開關狀態）
  const notifyHint = () =>
    notifyMembers
      ? "📩 收貨後會推播「到貨」通知給相關會員。"
      : "🔕 已關閉會員通知,本次收貨不推播。";

  // 由 dest_location 解析出 store（手動配單彈窗要 store id + 顯示名）
  const storeForLocation = (loc: number): { storeId: number; storeName: string } | null => {
    const sid = locationToStore.get(loc);
    if (!sid) return null;
    return { storeId: sid, storeName: locations.get(loc) ?? `#${loc}` };
  };

  // 「✋ 收貨·手動配」入口：不先收貨，直接開「這批單對到的訂單」勾選視窗，
  // 按「確認收貨」才一次完成收貨＋配單。多張限同一間店。
  const openManualReceive = (
    list: Transfer[],
    lines?: ReceiveLine[] | null,
    note?: string | null,
  ) => {
    const pending = list.filter((t) => t.status === "shipped");
    if (pending.length === 0) return;
    const dests = Array.from(new Set(pending.map((t) => t.dest_location)));
    if (dests.length > 1) {
      alert("✋ 手動配貨一次只能處理同一家分店的單,跨分店請分開點。");
      return;
    }
    const s = storeForLocation(dests[0]);
    if (!s) {
      alert("這批單的目的地不是分店,沒有顧客訂單可配 — 請用「收貨·自動配」直接入庫。");
      return;
    }
    setAllocModal({
      mode: {
        kind: "receive",
        transferIds: pending.map((t) => t.id),
        lines: lines ?? null,
        note: note ?? null,
      },
      storeName: s.storeName,
    });
  };

  // 單筆全收（自動配）— 直接 confirm + RPC,跟批次邏輯一樣(p_lines=null)。
  // 手動配不走這裡:「✋ 手動配」按鈕直接開 openManualReceive 的勾選視窗。
  async function quickReceive(t: Transfer) {
    const dest = locations.get(t.dest_location) ?? `#${t.dest_location}`;
    if (!confirm(`確認收貨 ${t.transfer_no}(送到 ${dest})?\n\n以「全收」(實收 = 派出量,無破損)處理。需要調整數量請點「調整」。\n${notifyHint()}`)) return;
    setBatchBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_receive_transfer", {
        p_transfer_id: t.id,
        p_lines: null,
        p_operator: operator,
        p_notes: null,
        p_auto_allocate: true,
      });
      if (e) throw new Error(translateRpcError(e));
      // 依「收貨後通知會員」設定推播到貨通知；失敗不影響收貨流程
      // （名單只含真的可取貨的訂單 — 沒配到的單不會被通知）
      if (notifyMembers) {
        const pushed = await fanoutPickupNotifications([t.id]).catch((err) => {
          console.warn("push fanout error:", err);
          return 0;
        });
        if (pushed > 0) alert(`📩 已推播 ${pushed} 位顧客`);
      }
      reloadAndRefreshBadge();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBatchBusy(false);
    }
  }

  // 退回收貨 — 把已收(received)的 transfer 退回待收(shipped)，沖銷入庫並還原訂單
  async function unreceive(t: Transfer) {
    const dest = locations.get(t.dest_location) ?? `#${t.dest_location}`;
    if (
      !confirm(
        `退回收貨 ${t.transfer_no}(送到 ${dest})?\n\n` +
        `會沖銷本次入庫的庫存、並把此調撥單改回「待收」。\n` +
        `若該批貨已被取貨/售出將無法退回。`,
      )
    )
      return;
    setBatchBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_unreceive_transfer", {
        p_transfer_id: t.id,
        p_operator: operator,
        p_notes: null,
      });
      if (e) throw new Error(translateRpcError(e));
      reloadAndRefreshBadge();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBatchBusy(false);
    }
  }

  async function batchReceive() {
    if (selected.size === 0) return;
    if (!confirm(`確認批次收貨 ${selected.size} 筆?\n\n所有品項都將以「全收」(實收 = 派出量,無破損)處理。需要編輯數量請點個別「收貨」按鈕。\n${notifyHint()}`)) return;
    await runBatchReceive(Array.from(selected));
    setSelected(new Set());
  }

  // 群組層「整組收貨」— 同品相合併後最常用的動作：一次收掉這個品項的全部待收單
  async function receiveGroup(g: Group) {
    const pending = g.transfers.filter((t) => t.status === "shipped");
    if (pending.length === 0) return;
    if (pending.length === 1) {
      await quickReceive(pending[0]);
      return;
    }
    const qty = pending.reduce((s, t) => s + (itemSummary.get(t.id)?.totalQty ?? 0), 0);
    if (
      !confirm(
        `確認收貨「${g.label}」全部 ${pending.length} 單(共 ${qty} 件)?\n\n` +
        `以「全收」(實收 = 派出量,無破損)處理。需要調整數量請展開後個別處理。\n${notifyHint()}`,
      )
    )
      return;
    const ids = pending.map((t) => t.id);
    await runBatchReceive(ids);
    setSelected((cur) => {
      const next = new Set(cur);
      for (const id of ids) next.delete(id);
      return next;
    });
  }

  async function runBatchReceive(ids: number[]) {
    if (ids.length === 0) return;
    setBatchBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      // 單一 round-trip 伺服端批次：序列處理避免 N 筆並行搶同店 row lock /
      // 重複跑 pickup_ready 造成的 statement timeout（見
      // 20260710000000_rpc_receive_transfer_batch.sql）。
      const { data, error: e } = await sb.rpc("rpc_receive_transfer_batch", {
        p_transfer_ids: ids,
        p_operator: operator,
        p_notes: "批次收貨",
        p_auto_allocate: true,
      });
      if (e) throw new Error(translateRpcError(e));

      const res = (data ?? {}) as {
        ok_count?: number;
        failed?: { id: number; error: string }[];
      };
      const okCount = res.ok_count ?? 0;
      const failures = (res.failed ?? []).map((f) => ({
        id: f.id,
        error: translateRpcError(f.error),
      }));

      // 依「收貨後通知會員」設定，對成功收貨的單整批推播（跨單去重同會員只推一次）
      let pushNote = "";
      if (notifyMembers && okCount > 0) {
        const failedIds = new Set((res.failed ?? []).map((f) => f.id));
        const okIds = ids.filter((id) => !failedIds.has(id));
        const pushed = await fanoutPickupNotifications(okIds).catch((err) => {
          console.warn("push fanout error:", err);
          return 0;
        });
        if (pushed > 0) pushNote = `\n📩 已推播 ${pushed} 位顧客`;
      }

      if (failures.length === 0) {
        alert(`✅ 批次收貨完成:${okCount} 筆${pushNote}`);
      } else {
        const failBrief = failures.slice(0, 5).map((f) => `  #${f.id}: ${f.error}`).join("\n");
        alert(
          `⚠ 部分成功:\n` +
          `成功 ${okCount} 筆 / 失敗 ${failures.length} 筆` +
          pushNote + `\n\n` +
          `失敗(前 5):\n${failBrief}` +
          (failures.length > 5 ? `\n…(還有 ${failures.length - 5} 筆)` : ""),
        );
      }
      reloadAndRefreshBadge();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBatchBusy(false);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">📦 收貨待辦</h1>
          <p className="text-sm text-zinc-500">
            {transfers === null ? (
              <Spinner size={14} className="inline-block align-[-2px]" />
            ) : (
              `待收 ${summaries.allPending} · 已收 ${summaries.done}`
            )}
          </p>
        </div>
        {branchLocationId == null && (
          <label className="flex items-center gap-2 text-sm">
            <span className="text-zinc-500">分店</span>
            <select
              value={String(locationFilter)}
              onChange={(e) =>
                setLocationFilter(e.target.value === "all" ? "all" : Number(e.target.value))
              }
              className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            >
              <option value="all">全部</option>
              {destOptions.map(([id, name]) => (
                <option key={id} value={id}>
                  {name}
                </option>
              ))}
            </select>
          </label>
        )}
      </header>

      {/* 分頁：未收 / 已收（預設未收） */}
      <div className="flex items-center gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {([
          { value: "unreceived", label: "未收", count: summaries.allPending },
          { value: "received", label: "已收", count: summaries.done },
        ] as const).map((tb) => {
          const active = tab === tb.value;
          return (
            <SpinButton
              key={tb.value}
              onClick={() => { setTab(tb.value); setDateFilter(null); setSelected(new Set()); }}
              className={`relative px-4 py-2 text-sm font-medium transition-colors ${
                active
                  ? "text-zinc-900 dark:text-zinc-100"
                  : "text-zinc-500 hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-200"
              }`}
            >
              {tb.label}
              <span className={`ml-1.5 ${active ? "" : "text-zinc-400 dark:text-zinc-500"}`}>
                ({tb.count})
              </span>
              {active && (
                <span className="absolute -bottom-px left-0 right-0 h-0.5 bg-zinc-900 dark:bg-zinc-100" />
              )}
            </SpinButton>
          );
        })}
      </div>

      {/* 搜尋 + 檢視模式（合併同商品 / 依撿貨單）+ 細節開關 */}
      <div className="flex flex-wrap items-center gap-2">
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="🔍 搜尋 商品 / 單號 / 分店"
          title="可搜尋 撿貨單號 / 調撥單號 / 分店 / 商品名 / 商品編號 / 品項編號"
          className="w-full min-w-[180px] flex-1 basis-[240px] rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
        />
        <div className="flex shrink-0 items-center rounded-md border border-zinc-300 p-0.5 text-xs dark:border-zinc-700">
          {([
            { value: "product", label: "合併同商品", hint: "同分店、同配送日、同品項的單併成一列，可整組收貨" },
            { value: "wave", label: "依撿貨單", hint: "依撿貨單號(WAVE)分組，總倉對單用" },
          ] as const).map((m) => (
            <SpinButton
              key={m.value}
              onClick={() => switchGroupMode(m.value)}
              title={m.hint}
              className={`rounded px-2.5 py-1 font-medium transition ${
                groupMode === m.value
                  ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                  : "text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-200"
              }`}
            >
              {m.label}
            </SpinButton>
          ))}
        </div>
        <label
          className="flex shrink-0 cursor-pointer items-center gap-1.5 whitespace-nowrap text-xs text-zinc-500 dark:text-zinc-400"
          title="顯示調撥單號 / 調撥類型 / 派出時間 / 訂單連結等對單用欄位"
        >
          <input
            type="checkbox"
            checked={showDetail}
            onChange={(e) => setShowDetail(e.target.checked)}
            className="cursor-pointer"
          />
          顯示單號等細節
        </label>
        {/* 手動配單常駐入口：收貨當下沒配完、或想事後再配都從這裡進。
            需要知道是哪家店 — 分店帳號自動鎖定;總倉請先在右上選分店 */}
        {(() => {
          const loc = branchLocationId ?? (locationFilter !== "all" ? locationFilter : null);
          const s = loc != null ? storeForLocation(loc) : null;
          return (
            <SpinButton
              onClick={() =>
                s &&
                setAllocModal({
                  mode: { kind: "store", storeId: s.storeId },
                  storeName: s.storeName,
                })
              }
              disabled={!s}
              title={
                s
                  ? "勾選要把店內現貨配給哪些已成立的訂單(不夠分時自己決定誰先拿)"
                  : "請先選擇分店(右上角)再手動配單"
              }
              className="shrink-0 rounded-md border border-emerald-300 px-2.5 py-1.5 text-xs font-medium text-emerald-700 hover:bg-emerald-50 disabled:opacity-50 dark:border-emerald-800 dark:text-emerald-400 dark:hover:bg-emerald-950"
            >
              ✋ 手動配單
            </SpinButton>
          );
        })()}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* KPI cards — 點任一張就 filter list,再點一次取消 */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <KpiCard
          label="🚚 明天到貨"
          hint="wave_date = 明天 的待收"
          showHint={showDetail}
          value={summaries.tomorrow}
          accent="text-blue-700 dark:text-blue-400"
          active={tab === "unreceived" && dateFilter === "tomorrow"}
          onClick={() =>
            tab === "unreceived" && dateFilter === "tomorrow"
              ? setDateFilter(null)
              : (setTab("unreceived"), setDateFilter("tomorrow"))
          }
        />
        <KpiCard
          label="⏳ 今日及更早"
          hint="wave_date ≤ 今天、還沒收"
          showHint={showDetail}
          value={summaries.todayOrEarlier}
          accent="text-amber-700 dark:text-amber-400"
          active={tab === "unreceived" && dateFilter === "today_or_earlier"}
          onClick={() =>
            tab === "unreceived" && dateFilter === "today_or_earlier"
              ? setDateFilter(null)
              : (setTab("unreceived"), setDateFilter("today_or_earlier"))
          }
        />
        <KpiCard
          label="📋 全部待收"
          hint="status = shipped"
          showHint={showDetail}
          value={summaries.allPending}
          accent="text-rose-700 dark:text-rose-400"
          active={tab === "unreceived" && dateFilter === "all_pending"}
          onClick={() =>
            tab === "unreceived" && dateFilter === "all_pending"
              ? setDateFilter(null)
              : (setTab("unreceived"), setDateFilter("all_pending"))
          }
        />
        <KpiCard
          label="✓ 已收"
          hint="status = received"
          showHint={showDetail}
          value={summaries.done}
          accent="text-emerald-700 dark:text-emerald-400"
          active={tab === "received"}
          onClick={() => { setTab("received"); setDateFilter(null); setSelected(new Set()); }}
        />
      </div>

      {/* 批次工具列（僅未收分頁） */}
      {tab === "unreceived" && pendingIds.length > 0 && (
        <div className="flex flex-wrap items-center gap-3 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
          <span className="text-xs text-zinc-500">
            {selected.size > 0
              ? `已選 ${selected.size} / ${pendingIds.length} 筆待收`
              : `待收 ${pendingIds.length} 筆`}
          </span>
          <SpinButton
            type="button"
            onClick={selectAllPending}
            disabled={selected.size === pendingIds.length}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            全選待收
          </SpinButton>
          {selected.size > 0 && (
            <SpinButton
              type="button"
              onClick={clearSelection}
              className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              清空
            </SpinButton>
          )}
          {/* 收貨後是否整批推播「到貨」給會員 — 適用單筆收貨 / 批次收貨 / 調整 modal，設定會記住 */}
          <label
            className="flex cursor-pointer items-center gap-1.5 text-xs text-zinc-600 dark:text-zinc-300"
            title="開啟:收貨完成後整批推播「您的商品到貨」給該店受影響的會員(不通知名單會自動排除)。關閉:收貨不推播。"
          >
            <input
              type="checkbox"
              checked={notifyMembers}
              onChange={(e) => setNotifyMembers(e.target.checked)}
              className="cursor-pointer"
            />
            {notifyMembers ? "📩 收貨後通知會員" : "🔕 收貨後不通知會員"}
          </label>
          {/* 批次收貨兩顆:自動配(原行為) / 手動配(先勾這批對到的訂單,確認才收貨) */}
          <SpinButton
            type="button"
            onClick={batchReceive}
            disabled={selected.size === 0 || batchBusy}
            title="收貨後依下單時間由早到晚自動配給訂單"
            className="ml-auto rounded-md bg-emerald-600 px-4 py-1.5 text-sm font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            {batchBusy ? "處理中…" : `✓ 批次收貨·自動配${selected.size > 0 ? ` (${selected.size})` : ""}`}
          </SpinButton>
          <SpinButton
            type="button"
            onClick={() =>
              openManualReceive((transfers ?? []).filter((t) => selected.has(t.id)))
            }
            disabled={selected.size === 0 || batchBusy}
            title="先跳出這批單對到的訂單勾選要配給誰,按「確認收貨」才完成收貨(限同一家分店)"
            className="rounded-md border border-emerald-600 px-4 py-1.5 text-sm font-semibold text-emerald-700 hover:bg-emerald-50 disabled:cursor-not-allowed disabled:border-zinc-300 disabled:text-zinc-400 dark:text-emerald-400 dark:hover:bg-emerald-950 dark:disabled:border-zinc-700 dark:disabled:text-zinc-500"
          >
            {`✋ 批次收貨·手動配${selected.size > 0 ? ` (${selected.size})` : ""}`}
          </SpinButton>
        </div>
      )}

      {transfers !== null && groups.length === 0 && (
        <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          沒有符合條件的調撥單。
        </div>
      )}

      <div className="flex flex-col gap-2">
        {visibleGroups.map((g) => {
          // 搜尋進行中時，展開所有符合的群組，避免結果被收合藏住
          const open = expanded.has(g.key) || !!search.trim();
          const pendingList = g.transfers.filter((t) => t.status === "shipped");
          const pendingCount = pendingList.length;
          const doneCount = g.transfers.length - pendingCount;
          const allSelected = pendingCount > 0 && pendingList.every((t) => selected.has(t.id));
          // 該收沒收的用紅字標出來 — 店家最常漏的就是前幾天沒收完的那批
          const dueTag =
            pendingCount > 0 && g.waveDate
              ? g.waveDate < todayStr
                ? "逾期"
                : g.waveDate === todayStr
                  ? "今天到貨"
                  : null
              : null;
          return (
            <section
              key={g.key}
              className="overflow-hidden rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
            >
              {/* 卡片標題：單號/品名 + 狀態膠囊 + 一排資訊膠囊（分店 / 配送日 / 件數 / 單數） */}
              <div className="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-zinc-200 bg-zinc-50 px-3 py-2.5 dark:border-zinc-800 dark:bg-zinc-900/60">
                {pendingCount > 0 && (
                  <input
                    type="checkbox"
                    checked={allSelected}
                    onChange={() => toggleGroupSelected(g)}
                    className="cursor-pointer"
                    title={`勾選這組 ${pendingCount} 筆待收`}
                  />
                )}
                <SpinButton
                  onClick={() => toggle(g.key)}
                  className="flex min-w-0 flex-1 items-start gap-2 text-left"
                >
                  <span className="mt-0.5 shrink-0 text-zinc-400">{open ? "▾" : "▸"}</span>
                  <span className="min-w-0">
                    {/* 標題只留品名/單號 — 狀態膠囊統一靠右對齊，長短不一的品名才不會
                        把膠囊推到每列不同位置，一整頁掃下來看不出哪些有狀況 */}
                    <span
                      title={g.labelTitle || undefined}
                      className={`block break-words ${
                        g.mono
                          ? "font-mono text-sm font-bold text-blue-700 dark:text-blue-400"
                          : "text-base font-bold text-zinc-900 dark:text-zinc-100"
                      }`}
                    >
                      {g.label}
                    </span>
                    <span className="mt-1.5 flex flex-wrap items-center gap-1.5">
                      {g.subLabel
                        .split(" · ")
                        .filter(Boolean)
                        .map((part, i) => (
                          <Chip key={i}>{part.startsWith("配送日") ? `📅 ${part}` : `🏬 ${part}`}</Chip>
                        ))}
                      <Chip>📦 共 {g.totalQty} 件</Chip>
                      <Chip>🧾 {g.transfers.length} 單</Chip>
                      {doneCount > 0 && pendingCount > 0 && <Chip>✅ 已收 {doneCount} 單</Chip>}
                    </span>
                  </span>
                </SpinButton>

                {/* 狀態膠囊：一律靠右，跟收貨按鈕同一區 */}
                <div className="flex shrink-0 flex-wrap items-center justify-end gap-1.5">
                  {pendingCount > 0 ? (
                    <Pill tone="amber">待收 {pendingCount} 單</Pill>
                  ) : (
                    <Pill tone="emerald">✓ 已收到</Pill>
                  )}
                  {dueTag && <Pill tone={dueTag === "逾期" ? "rose" : "amber"}>{dueTag}</Pill>}
                  {g.shortQty > 0 && <Pill tone="rose">⚠ 少 {g.shortQty} 件 · 訂單比到貨多</Pill>}
                  {g.backorderQty > 0 && <Pill tone="amber">⏳ 待補貨 {g.backorderQty} 件</Pill>}
                  {g.coveredQty > 0 && <Pill tone="violet">🏬 現貨減抵 {g.coveredQty} 件</Pill>}
                  {g.prefilledQty > 0 && (
                    <Pill tone="violet">🔄 補回先墊 {g.prefilledQty} 件</Pill>
                  )}
                  {g.extraQty > 0 && <Pill tone="blue">🎁 總倉多給 {g.extraQty} 件</Pill>}
                </div>

                {pendingCount > 0 && (
                  <div className="flex shrink-0 flex-col items-stretch gap-1">
                    <SpinButton
                      onClick={() => receiveGroup(g)}
                      disabled={batchBusy}
                      className="rounded-md bg-emerald-600 px-4 py-1.5 text-sm font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                      title={
                        (pendingCount > 1
                          ? `一次收掉這組 ${pendingCount} 筆(全收:實收 = 派出量)。`
                          : "直接全收(實收 = 派出量,無破損)。") +
                        "收貨後依下單時間由早到晚自動配給訂單"
                      }
                    >
                      ✓ 收貨·自動配{pendingCount > 1 ? ` ${pendingCount} 單` : ""}
                    </SpinButton>
                    <SpinButton
                      onClick={() => openManualReceive(g.transfers)}
                      disabled={batchBusy}
                      className="rounded-md border border-emerald-600 px-4 py-1.5 text-sm font-semibold text-emerald-700 hover:bg-emerald-50 disabled:opacity-50 dark:text-emerald-400 dark:hover:bg-emerald-950"
                      title="先跳出這批單對到的訂單勾選要配給誰,按「確認收貨」才完成收貨(取消=不收貨)"
                    >
                      ✋ 收貨·手動配{pendingCount > 1 ? ` ${pendingCount} 單` : ""}
                    </SpinButton>
                  </div>
                )}
              </div>

              {/* 明細表：編號 / 商品 / 數量 / 動作 */}
              {open && (
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[560px] text-sm">
                    <thead>
                      <tr className="border-b border-zinc-200 bg-white text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
                        <th className="w-8 px-3 py-2" />
                        <th className="px-3 py-2 text-left font-medium">編號</th>
                        <th className="px-3 py-2 text-left font-medium">商品</th>
                        <th className="px-3 py-2 text-right font-medium">數量</th>
                        <th className="px-3 py-2 text-right font-medium">動作</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                      {g.transfers.map((t) => {
                        const isShipped = t.status === "shipped";
                        const summary = itemSummary.get(t.id);
                        const storeId = locationToStore.get(t.dest_location);
                        const cids = transferCampaigns.get(t.id) ?? [];
                        const isSelected = selected.has(t.id);
                        const wid = parseWaveId(t.transfer_no);
                        const wave = wid !== null ? waves.get(wid) : undefined;
                        const srcKind = sourceKinds.get(t.id) ?? "campaign";
                        // 編號欄：合併同商品時看撿貨單號（哪一車來的），依撿貨單時看調撥單號
                        const code =
                          groupMode === "product" ? wave?.wave_code ?? t.transfer_no : t.transfer_no;
                        return (
                          <tr
                            key={t.id}
                            className={`transition hover:bg-zinc-50 dark:hover:bg-zinc-950 ${
                              isSelected ? "bg-blue-50 dark:bg-blue-950/30" : ""
                            }`}
                          >
                            <td className="px-3 py-2 align-top">
                              {isShipped && (
                                <input
                                  type="checkbox"
                                  checked={isSelected}
                                  onChange={() => toggleSelected(t.id)}
                                  className="cursor-pointer"
                                  title="勾選後可批次收貨"
                                />
                              )}
                            </td>
                            <td className="px-3 py-2 align-top font-mono text-xs text-zinc-500">
                              <div>{code}</div>
                              {showDetail && (
                                <div className="mt-0.5 font-sans text-[10px] text-zinc-400">
                                  {groupMode === "product" && <span className="mr-1">{t.transfer_no}</span>}
                                  {TRANSFER_TYPE_LABEL[t.transfer_type] ?? t.transfer_type}
                                  {t.shipped_at && (
                                    <span className="ml-1">
                                      派出 {new Date(t.shipped_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
                                    </span>
                                  )}
                                </div>
                              )}
                            </td>
                            <td className="px-3 py-2 align-top">
                              {/* 一列一個 SKU（品項編號 + 品名 / 規格 × 數量）— 一張單十幾個規格時
                                  串成一段會整片糊掉，這裡是唯一該看得到規格的地方 */}
                              {summary && summary.lines > 0 ? (
                                <ul className="space-y-0.5">
                                  {summary.items.map((it, i) => (
                                    <li key={i} className="break-words text-zinc-900 dark:text-zinc-100">
                                      {it.skuCode && (
                                        <span className="mr-1.5 font-mono text-[10px] text-zinc-400">{it.skuCode}</span>
                                      )}
                                      {it.name}
                                      {/* 點數量 → 這幾件分別是誰的訂單 */}
                                      {srcKind !== "free" ? (
                                        <SpinButton
                                          onClick={() =>
                                            setOrdersFor({
                                              transferId: t.id,
                                              transferNo: wave?.wave_code ?? t.transfer_no,
                                              skuLines: [it],
                                            })
                                          }
                                          className="ml-1 rounded font-semibold tabular-nums text-blue-600 underline decoration-dotted underline-offset-2 hover:text-blue-800 dark:text-blue-400"
                                          title="看這幾件對應哪幾筆訂單"
                                        >
                                          × {it.qty}
                                        </SpinButton>
                                      ) : (
                                        <span className="ml-1 font-semibold tabular-nums">× {it.qty}</span>
                                      )}
                                      {/* 有短少要配、已有現貨減抵（進去看/作廢減抵單）、
                                          或還掛著待補貨（20260811000060）都給入口 —
                                          待補貨在收貨時會自動解除，但實體庫存對不上時不放行，
                                          那種情況更需要店家自己進來看 */}
                                      {(summary.shortQty > 0 || summary.coveredQty > 0
                                        || summary.backorderQty > 0) && it.skuId != null && (
                                        <SpinButton
                                          onClick={() =>
                                            setAllocFor({
                                              transferId: t.id,
                                              skuId: it.skuId as number,
                                              skuName: it.name,
                                            })
                                          }
                                          className="ml-1.5 rounded border border-rose-300 px-1.5 py-0.5 text-[10px] font-medium text-rose-700 hover:bg-rose-50 dark:border-rose-800 dark:text-rose-400 dark:hover:bg-rose-950"
                                          title="這批不夠分 — 決定配給哪幾筆訂單，店內有現貨也可開減抵單補缺口"
                                        >
                                          ⚖️ 配貨
                                        </SpinButton>
                                      )}
                                    </li>
                                  ))}
                                </ul>
                              ) : (
                                <div className="text-zinc-400">—</div>
                              )}
                              <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-[11px] text-zinc-500">
                                {groupMode === "wave" && (
                                  <span>{locations.get(t.dest_location) ?? `#${t.dest_location}`}</span>
                                )}
                                {groupMode === "wave" && wave?.wave_date && <span>📅 {wave.wave_date}</span>}
                                {srcKind === "restock" && (
                                  <span
                                    className="rounded bg-violet-100 px-1.5 py-0.5 text-[10px] font-medium text-violet-700 dark:bg-violet-950 dark:text-violet-300"
                                    title="補貨申請（RR-xxx）產生的單，不是開團派貨；點數量可看對應的補貨申請"
                                  >
                                    🔁 補貨
                                  </span>
                                )}
                                {srcKind === "free" && (
                                  <span
                                    className="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px] font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
                                    title="沒有撿貨波次也沒掛訂單的單（自由轉貨 / 店對店），沒有可對應的單據"
                                  >
                                    ↔ 轉貨
                                  </span>
                                )}
                                {!isShipped && t.received_at && (
                                  <span className="text-emerald-700 dark:text-emerald-400">
                                    ✅ 收貨 {new Date(t.received_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
                                  </span>
                                )}
                                {showDetail && storeId && (
                                  <Link
                                    href={`/orders?${(() => {
                                      const qs = new URLSearchParams({ storeId: String(storeId) });
                                      if (cids.length > 0) qs.set("campaignIds", cids.join(","));
                                      return qs.toString();
                                    })()}`}
                                    className="text-blue-600 hover:underline dark:text-blue-400"
                                    title={cids.length > 0 ? `關聯 ${cids.length} 個開團` : undefined}
                                  >
                                    → 訂單{cids.length > 0 ? `(${cids.length} 團)` : ""}
                                  </Link>
                                )}
                              </div>
                            </td>
                            <td className="whitespace-nowrap px-3 py-2 text-right align-top">
                              {srcKind !== "free" ? (
                                <SpinButton
                                  onClick={() =>
                                    setOrdersFor({
                                      transferId: t.id,
                                      transferNo: wave?.wave_code ?? t.transfer_no,
                                      skuLines: summary?.items ?? [],
                                    })
                                  }
                                  disabled={!summary || summary.lines === 0}
                                  className="font-semibold tabular-nums text-blue-600 underline decoration-dotted underline-offset-2 hover:text-blue-800 disabled:text-zinc-400 disabled:no-underline dark:text-blue-400"
                                  title="看這張單對應哪幾筆訂單"
                                >
                                  {summary?.totalQty ?? 0}
                                </SpinButton>
                              ) : (
                                // 自由轉貨背後沒有任何單，不給死連結（補貨有 RR-xxx 可看）
                                <span className="font-semibold tabular-nums">{summary?.totalQty ?? 0}</span>
                              )}
                              {summary && summary.lines > 1 && (
                                <span className="ml-1 text-[10px] font-normal text-zinc-400">{summary.lines} 項</span>
                              )}
                              {summary && summary.shortQty > 0 && (
                                <div
                                  className="text-[10px] font-medium text-rose-600 dark:text-rose-400"
                                  title="訂單比這批到貨量多，這幾件會有客人領不到 — 點數量看是哪幾筆訂單"
                                >
                                  ⚠ 少 {summary.shortQty}
                                </div>
                              )}
                              {summary && summary.backorderQty > 0 && (
                                <div
                                  className="text-[10px] font-medium text-amber-600 dark:text-amber-400"
                                  title="這組還有幾件掛著「待補貨」（少發配貨沒配到）— 補的貨收進來會自動解除；沒自動解除代表店裡實際庫存對不上，點「配貨」進去處理"
                                >
                                  ⏳ 待補 {summary.backorderQty}
                                </div>
                              )}
                              {summary && summary.prefilledQty > 0 && (
                                <div
                                  className="text-[10px] font-medium text-violet-600 dark:text-violet-400"
                                  title="這幾件的客人早就用店內現貨交過了（減抵單 / 現貨直售），這批到貨是把店家先墊的貨補回架上 — 收貨後放回庫存即可，不會有人來領"
                                >
                                  🔄 補回先墊 {summary.prefilledQty}
                                </div>
                              )}
                              {summary && summary.coveredQty > 0 && (
                                <div
                                  className="text-[10px] font-medium text-violet-600 dark:text-violet-400"
                                  title="缺口已用店內現貨減抵單吸收 — 點「配貨」可看減抵單"
                                >
                                  🏬 減抵 {summary.coveredQty}
                                </div>
                              )}
                              {summary && summary.extraQty > 0 && (
                                <div
                                  className="text-[10px] font-medium text-blue-600 dark:text-blue-400"
                                  title="派出量比店裡的訂單需求還多，多出來的部分沒有訂單對應"
                                >
                                  🎁 多給 {summary.extraQty}
                                </div>
                              )}
                            </td>
                            <td className="whitespace-nowrap px-3 py-2 text-right align-top">
                              {isShipped ? (
                                <div className="flex justify-end gap-1">
                                  <SpinButton
                                    onClick={() => quickReceive(t)}
                                    disabled={batchBusy}
                                    className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                                    title="直接全收(實收 = 派出量,無破損),收貨後依下單時間由早到晚自動配給訂單"
                                  >
                                    收貨·自動配
                                  </SpinButton>
                                  <SpinButton
                                    onClick={() => openManualReceive([t])}
                                    disabled={batchBusy}
                                    className="rounded-md border border-emerald-600 px-3 py-1.5 text-xs font-semibold text-emerald-700 hover:bg-emerald-50 disabled:opacity-50 dark:text-emerald-400 dark:hover:bg-emerald-950"
                                    title="先跳出這張單對到的訂單勾選要配給誰,按「確認收貨」才完成收貨(取消=不收貨)"
                                  >
                                    ✋ 手動配
                                  </SpinButton>
                                  <SpinButton
                                    onClick={() => setOpening(t)}
                                    className="rounded-md border border-zinc-300 px-2 py-1.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                                    title="調整數量 / 標記破損 / 短收"
                                  >
                                    ✎ 調整
                                  </SpinButton>
                                </div>
                              ) : (
                                <div className="flex justify-end gap-1">
                                  <SpinButton
                                    onClick={() => setOpening(t)}
                                    className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                                  >
                                    看明細
                                  </SpinButton>
                                  <SpinButton
                                    onClick={() => unreceive(t)}
                                    disabled={batchBusy}
                                    className="rounded-md border border-amber-300 px-2 py-1 text-xs text-amber-700 hover:bg-amber-50 disabled:opacity-50 dark:border-amber-800 dark:text-amber-400 dark:hover:bg-amber-950"
                                    title="退回收貨：沖銷入庫、改回待收"
                                  >
                                    ↩ 退回
                                  </SpinButton>
                                </div>
                              )}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </section>
          );
        })}
      </div>

      {/* 撿貨單號分頁：一次顯示 20 個 wave，滑到底自動載入下一批（+20），不用手動按 */}
      {groups.length > groupLimit && (
        <div ref={sentinelRef} className="flex items-center justify-center py-4">
          <Spinner size={16} />
        </div>
      )}

      {/* 已收歷史分頁:目前 doneLimit 比 doneTotal 少時顯示（僅已收分頁） */}
      {tab === "received" && doneLimit < doneTotal && (
        <div className="flex items-center justify-center gap-3 py-2 text-xs text-zinc-500">
          <span>已顯示 {Math.min(doneLimit, doneTotal)} / {doneTotal} 筆已收歷史</span>
          <SpinButton
            onClick={() => setDoneLimit((n) => n + 50)}
            className="rounded-md border border-zinc-300 px-3 py-1.5 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            載入更多 (+50)
          </SpinButton>
          <SpinButton
            onClick={() => setDoneLimit(doneTotal)}
            className="rounded-md border border-zinc-300 px-3 py-1.5 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            載入全部
          </SpinButton>
        </div>
      )}

      {allocFor && (
        <ShortageAllocateModal
          transferId={allocFor.transferId}
          skuId={allocFor.skuId}
          skuName={allocFor.skuName}
          onClose={() => setAllocFor(null)}
          onSaved={() => reloadAndRefreshBadge()}
        />
      )}

      {allocModal && (
        <ManualAllocateModal
          mode={allocModal.mode}
          storeName={allocModal.storeName}
          notifyMembers={notifyMembers}
          onClose={() => setAllocModal(null)}
          onSaved={() => reloadAndRefreshBadge()}
        />
      )}

      {ordersFor && (
        <TransferOrdersModal
          transferId={ordersFor.transferId}
          transferNo={ordersFor.transferNo}
          skuLines={ordersFor.skuLines}
          onClose={() => setOrdersFor(null)}
        />
      )}

      {opening && (
        <TransferReceiveModal
          transfer={opening}
          srcName={locations.get(opening.source_location) ?? `#${opening.source_location}`}
          dstName={locations.get(opening.dest_location) ?? `#${opening.dest_location}`}
          wave={(() => {
            const wid = parseWaveId(opening.transfer_no);
            return wid !== null ? waves.get(wid) ?? null : null;
          })()}
          notifyMembers={notifyMembers}
          onClose={() => setOpening(null)}
          onSubmitted={() => {
            setOpening(null);
            reloadAndRefreshBadge();
          }}
          onManualReceive={(lines, note) => {
            // 調整彈窗按「✋ 收貨·手動配」→ 帶著改好的實收數量轉進勾單視窗，
            // 確認才收貨（調整彈窗先關掉，數量已在 lines 裡）
            const t = opening;
            setOpening(null);
            openManualReceive([t], lines, note);
          }}
        />
      )}
    </div>
  );
}

function Th({ children }: { children?: React.ReactNode }) {
  return (
    <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">
      {children}
    </th>
  );
}

// 卡片標題旁的狀態膠囊（待收 / 已收到 / 逾期）
function Pill({ tone, children }: { tone: "amber" | "emerald" | "rose" | "blue" | "violet"; children: React.ReactNode }) {
  const cls = {
    amber: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    emerald: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
    rose: "bg-rose-100 text-rose-700 dark:bg-rose-950 dark:text-rose-300",
    blue: "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300",
    violet: "bg-violet-100 text-violet-700 dark:bg-violet-950 dark:text-violet-300",
  }[tone];
  return (
    <span className={`inline-flex shrink-0 rounded-md px-2 py-0.5 text-[11px] font-medium ${cls}`}>
      {children}
    </span>
  );
}

// 標題下那排白底資訊膠囊（分店 / 配送日 / 件數 / 單數）
function Chip({ children }: { children: React.ReactNode }) {
  return (
    <span className="inline-flex items-center gap-1 rounded-md border border-zinc-200 bg-white px-2 py-0.5 text-[11px] text-zinc-600 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
      {children}
    </span>
  );
}

function KpiCard({
  label,
  hint,
  showHint,
  value,
  accent,
  active,
  onClick,
}: {
  label: string;
  hint?: string;
  // hint 是「wave_date ≤ 今天」這種對店家沒意義的欄位說明，預設只留 tooltip 不佔版面
  showHint?: boolean;
  value: number | string;
  accent: string;
  active?: boolean;
  onClick?: () => void;
}) {
  const Wrapper = onClick ? "button" : "div";
  return (
    <Wrapper
      type={onClick ? "button" : undefined}
      onClick={onClick}
      title={hint}
      className={`rounded-md border p-3 text-left transition ${
        active
          ? "border-blue-500 bg-blue-50 dark:border-blue-700 dark:bg-blue-950/40"
          : "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
      } ${onClick ? "hover:border-blue-400 hover:bg-zinc-50 dark:hover:bg-zinc-800/60" : ""}`}
    >
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-0.5 text-2xl font-semibold ${accent}`}>{value}</div>
      {hint && showHint && <div className="mt-0.5 text-[10px] text-zinc-400">{hint}</div>}
    </Wrapper>
  );
}

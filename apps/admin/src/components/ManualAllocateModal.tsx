"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { Modal } from "@/components/Modal";
import Spinner from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { orderListHref } from "@/lib/orderStatus";
import {
  fanoutPickupNotifications,
  pushArrivalNotifications,
  type NotifyTarget,
} from "@/lib/pickupNotify";

// 手動配貨：補貨到店數量不夠分給所有訂單時，由店家自己勾「這批配給誰」。
//
// 兩種模式（見 20260813000000 / 20260813010000 / 20260814000000 migration）：
// - receive：收貨前開（「✋ 收貨·手動配」按鈕）。列出**這批到貨單對到的訂單**，
//   勾完按「確認收貨」才一次完成收貨＋配單（同一交易；取消＝什麼都沒發生）。
//   「已確認」（等貨中）和「派貨中」（波次出貨時已配給他）都列：派貨中預設
//   勾選，取消勾選＝把該單拉回「已確認」、這批貨讓給別人（下批到貨可再配）。
// - store：收完貨之後想（再）配時用（「✋ 手動配單」常駐入口）。列出全店
//   貨已到齊、還沒配的訂單，勾選配單。
//
// 可配量算法跟自動配單（_advance_arrived_confirmed_orders）同一套：整單每個
// 品項都裝得下才能配、不拆單。送出時伺服端會再驗一次，勾了但裝不下的單會被
// 跳過並回報，不會硬推。
//
// **貨不夠分時，派貨中的單也一樣受額度擋**（Alex 2026-08-14：「少的也不能全部
// 訂單都可以勾選」）。派貨中＝出貨時就配給他的，所以預設**依訂單時間由早到晚
// 勾到額度用完為止**，勾不下的留空 —— 那些單確認收貨時會被拉回「已確認」，
// 客人畫面回到「待到貨」等下一批。這一關只能在前端做：伺服端收貨邏輯 C 是
// qty-blind 的（20260814000000），它只認「這張單還是不是 shipping」，
// 所以「不勾＝先拉回 confirmed」就是唯一攔得住的閘門，額度用完還能繼續勾
// 的話等於把不存在的貨許給客人。

export type ReceiveLine = { transfer_item_id: number; qty_received: number };

// 本批調撥的品項行（實收編輯用；20260824 起實收直接在配單視窗改，
// 預設 = WV 派出量、可少收也可多收，另開的「✎ 調整」彈窗已從分店流程移除）
type TransferItemLine = {
  id: number;
  transfer_id: number;
  sku_id: number;
  qty_shipped: number;
  description: string | null;
};

// 依下單時間由早到晚勾滿為止（伺服端已排好序）——「數量正確」時等於全選
function greedyByTime(
  orders: CandidateOrder[],
  caps: Map<number, number>,
  onlyWithin?: Set<number>,
): Set<number> {
  const used = new Map<number, number>();
  const next = new Set<number>();
  for (const o of orders) {
    if (onlyWithin && !onlyWithin.has(o.order_id)) continue;
    const ok = o.items.every(
      (it) => it.qty <= (caps.get(it.sku_id) ?? 0) - (used.get(it.sku_id) ?? 0),
    );
    if (!ok) continue;
    next.add(o.order_id);
    for (const it of o.items) used.set(it.sku_id, (used.get(it.sku_id) ?? 0) + it.qty);
  }
  return next;
}

export type AllocModalMode =
  | { kind: "store"; storeId: number }
  | {
      kind: "receive";
      transferIds: number[];
      // 調整彈窗轉過來的實收數量 / 備註（只支援單張；全收時為 null）
      lines?: ReceiveLine[] | null;
      note?: string | null;
    };

type BudgetRow = {
  sku_id: number;
  sku_code: string | null;
  name: string;
  cap: number; // 可配上限（receive 模式 = 既有可配 + 本次到貨；原始值可為負時已含在內）
  pool: number; // 【內部】店現貨池既有未取掛帳（receive 模式伺服端回傳；store 模式 0）
};

type IncomingRow = { sku_id: number; sku_code: string | null; name: string; qty: number };

type CandidateOrder = {
  order_id: number;
  order_no: string;
  member_id: number | null;
  customer: string | null;
  campaign_name: string | null;
  created_at: string;
  // 單頭狀態（receive 模式伺服端回傳；store 模式候選必為 confirmed 且閘門已過）
  status: string;
  arrived: boolean;
  items: Array<{ sku_id: number; qty: number }>;
};

// 「客人看到」欄：判定對齊會員端 apps/member OrderCard.orderPhase ——
// 取貨閘門放行＝待取貨；派貨中＝運送中；其餘＝待到貨。
function customerStatusLabel(o: Pick<CandidateOrder, "status" | "arrived">): string {
  if (o.arrived) return "待取貨";
  if (o.status === "shipping") return "運送中";
  return "待到貨";
}

type Data = {
  budget: BudgetRow[];
  incoming: IncomingRow[];
  orders: CandidateOrder[];
  waiting_count: number;
};

type AllocResult = {
  advanced: number;
  orders: Array<{ order_id: number; order_no: string; customer: string | null }>;
  skipped: Array<{ order_id: number; order_no: string | null; reason: string }>;
  notify: NotifyTarget[];
};

type ManualReceiveResult = {
  transfers_received?: number;
  pulled_back?: number;
  pullback_skipped?: Array<{ order_id: number; order_no: string | null; status: string }>;
  shipping_advanced?: number;
  allocation?: AllocResult | null;
  // 多給的量（沒有訂單主人）掛進【內部】店現貨池的結果（20260814010000）
  surplus?: Array<{ sku_id: number; qty: number }> | null;
  // 沒勾的候選訂單標「待補貨」的張數（20260824010000）
  backordered?: number;
};

const SKIP_REASON_LABEL: Record<string, string> = {
  not_found: "找不到訂單",
  not_eligible: "已被別人配走或狀態已變",
  not_arrived: "貨還沒到齊",
  insufficient_stock: "可配量不夠整張單",
};

const skipNoteOf = (skipped: AllocResult["skipped"]) =>
  skipped.length > 0
    ? `\n⚠ ${skipped.length} 張沒配成：\n` +
      skipped
        .slice(0, 5)
        .map(
          (s) => `  ${s.order_no ?? `#${s.order_id}`}：${SKIP_REASON_LABEL[s.reason] ?? s.reason}`,
        )
        .join("\n") +
      (skipped.length > 5 ? `\n  …（還有 ${skipped.length - 5} 張）` : "")
    : "";

export function ManualAllocateModal({
  mode,
  storeName,
  notifyMembers,
  onClose,
  onSaved,
}: {
  mode: AllocModalMode;
  storeName: string;
  // 收貨待辦頁的「收貨後通知會員」開關，當本彈窗通知選項的預設值
  notifyMembers: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [data, setData] = useState<Data | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [notify, setNotify] = useState(notifyMembers);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // receive 模式：本批品項行 + 實收編輯（item id → 輸入字串；預設 = 派出量）
  const [items, setItems] = useState<TransferItemLine[] | null>(null);
  const [qtyEdits, setQtyEdits] = useState<Map<number, string>>(new Map());
  // 使用者動過勾選後，實收改動只「修剪裝不下的」，不再整組重勾
  const touchedRef = useRef(false);

  // 依實收編輯組出 p_lines（只送 ≠ 派出量的行）。空白/負數回 invalid，
  // 由呼叫端決定要擋送出還是先不打 preview。多收（> 派出量）是合法的。
  const buildLines = useCallback(
    (
      list: TransferItemLine[],
      edits: Map<number, string>,
    ): { lines: ReceiveLine[]; invalid: boolean } => {
      const lines: ReceiveLine[] = [];
      for (const it of list) {
        const raw = edits.get(it.id);
        if (raw === undefined) continue;
        if (raw.trim() === "") return { lines: [], invalid: true };
        const v = Number(raw);
        if (Number.isNaN(v) || v < 0) return { lines: [], invalid: true };
        if (v !== it.qty_shipped) lines.push({ transfer_item_id: it.id, qty_received: v });
      }
      return { lines, invalid: false };
    },
    [],
  );

  // receive 模式：抓 preview（實收以 lines 為準）→ 更新額度與候選、重算勾選。
  // 沒動過勾選 → 依訂單時間勾滿（數量正確時＝全選）；動過 → 只把裝不下的修掉。
  const loadPreview = useCallback(
    async (lines: ReceiveLine[] | null) => {
      if (mode.kind !== "receive") return;
      const sb = getSupabase();
      const { data: d, error: e } = await sb.rpc("rpc_get_transfer_allocation_preview", {
        p_transfer_ids: mode.transferIds,
        p_lines: lines && lines.length > 0 ? lines : null,
      });
      if (e) throw new Error(e.message);
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
        items: (o.items ?? []).map((i) => ({ sku_id: i.sku_id, qty: Number(i.qty) })),
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
      setData({ budget: budgetRows, incoming, orders, waiting_count: 0 });

      const caps = new Map(budgetRows.map((b) => [b.sku_id, b.cap]));
      setSelected((cur) =>
        touchedRef.current ? greedyByTime(orders, caps, cur) : greedyByTime(orders, caps),
      );
    },
    [mode],
  );

  // store 模式：載入（貨已在店，沒有實收可調）
  const loadStore = useCallback(async () => {
    if (mode.kind !== "store") return;
    const sb = getSupabase();
    const { data: d, error: e } = await sb.rpc("rpc_get_manual_allocation_candidates", {
      p_store_id: mode.storeId,
    });
    if (e) throw new Error(e.message);
    const raw = d as {
      budget: Array<{ sku_id: number; sku_code: string | null; name: string; available: number }>;
      orders: CandidateOrder[];
      waiting_count: number;
    };
    setData({
      budget: (raw.budget ?? []).map((b) => ({ ...b, cap: Number(b.available), pool: 0 })),
      incoming: [],
      orders: (raw.orders ?? []).map((o) => ({
        ...o,
        // store 模式候選 = confirmed 且閘門已過（伺服端定義），標籤固定「待取貨」
        status: "confirmed",
        arrived: true,
        items: (o.items ?? []).map((i) => ({ sku_id: i.sku_id, qty: Number(i.qty) })),
      })),
      waiting_count: Number(raw.waiting_count) || 0,
    });
    setSelected(new Set());
  }, [mode]);

  useEffect(() => {
    if (mode.kind !== "store") return;
    let cancelled = false;
    (async () => {
      try {
        await loadStore();
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [mode.kind, loadStore]);

  // receive 模式：先抓本批品項行、種入實收預設（WV 派出量；調整彈窗轉來的
  // lines 蓋上去 — 舊入口相容），preview 交給下面的 debounce effect
  useEffect(() => {
    if (mode.kind !== "receive") return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: rows, error: e } = await sb
          .from("transfer_items")
          .select("id, transfer_id, sku_id, qty_shipped, description")
          .in("transfer_id", mode.transferIds)
          .order("id");
        if (e) throw new Error(e.message);
        if (cancelled) return;
        const list = ((rows as TransferItemLine[] | null) ?? []).map((r) => ({
          ...r,
          qty_shipped: Number(r.qty_shipped),
        }));
        const seed = new Map<number, string>();
        for (const it of list) seed.set(it.id, String(it.qty_shipped));
        for (const l of mode.lines ?? []) seed.set(l.transfer_item_id, String(l.qty_received));
        setItems(list);
        setQtyEdits(seed);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
    // mode 是穩定的 modal 參數，transferIds 不會中途變
  }, [mode]);

  // 實收一改（含初次載入）→ debounce 後重抓 preview；有空白/非法值先不打
  const editsKey = useMemo(
    () => (items ? items.map((it) => `${it.id}:${qtyEdits.get(it.id) ?? ""}`).join("|") : ""),
    [items, qtyEdits],
  );
  useEffect(() => {
    if (mode.kind !== "receive" || items === null) return;
    const { lines, invalid } = buildLines(items, qtyEdits);
    if (invalid) return;
    let cancelled = false;
    const t = setTimeout(() => {
      loadPreview(lines).catch((e) => {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      });
    }, 400);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
    // editsKey 涵蓋 items + qtyEdits 的內容變化
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode.kind, items, editsKey, buildLines, loadPreview]);

  const budgetMap = useMemo(() => {
    const m = new Map<number, BudgetRow>();
    for (const b of data?.budget ?? []) m.set(b.sku_id, b);
    return m;
  }, [data]);

  // 已勾選訂單佔掉的量（sku_id → qty）
  const usedMap = useMemo(() => {
    const m = new Map<number, number>();
    for (const o of data?.orders ?? []) {
      if (!selected.has(o.order_id)) continue;
      for (const it of o.items) m.set(it.sku_id, (m.get(it.sku_id) ?? 0) + it.qty);
    }
    return m;
  }, [data, selected]);

  const remaining = useCallback(
    (skuId: number) => (budgetMap.get(skuId)?.cap ?? 0) - (usedMap.get(skuId) ?? 0),
    [budgetMap, usedMap],
  );

  // 沒勾的單還裝不裝得下（整單每個品項都要在剩餘額度內，與伺服端同規則）
  const fits = useCallback(
    (o: CandidateOrder) => o.items.every((it) => it.qty <= remaining(it.sku_id)),
    [remaining],
  );

  function toggle(o: CandidateOrder) {
    touchedRef.current = true;
    setSelected((cur) => {
      const next = new Set(cur);
      if (next.has(o.order_id)) next.delete(o.order_id);
      // 派貨中的單也受額度擋：貨不夠分時不能全部勾（會許出不存在的貨）。
      // 要改配給別人 → 先取消勾別張，額度空出來才勾得起來。
      else if (fits(o)) next.add(o.order_id);
      return next;
    });
  }

  // 依訂單時間由早到晚勾滿為止 —— 跟自動配單同一套結果，店家可再手動增減。
  // 按了＝回到「未手動調整」狀態：之後改實收會重新整組勾滿。
  function presetByTime() {
    if (!data) return;
    touchedRef.current = false;
    const caps = new Map((data.budget ?? []).map((b) => [b.sku_id, b.cap]));
    setSelected(greedyByTime(data.orders, caps));
  }

  // 每個 SKU 的全部候選訂單總需求（跟有沒有勾選無關）—— surplus 預估用
  const totalNeedMap = useMemo(() => {
    const m = new Map<number, number>();
    for (const o of data?.orders ?? [])
      for (const it of o.items) m.set(it.sku_id, (m.get(it.sku_id) ?? 0) + it.qty);
    return m;
  }, [data]);

  // 多給的量（沒有訂單主人）＝確認收貨後會掛進【內部】店現貨池的預估。
  // 逐 SKU：min(本次到貨 − 已勾選需求, 可配上限 − 全部候選需求 − 池子既有掛帳)，
  // 夾 0 —— 與伺服端 _grow_internal_pool 同一套帳（沒勾的候選單還在等貨，
  // 他們下一批要領的量不掛進池子）。實際掛帳以確認當下伺服端重算為準。
  const surplusRows = useMemo(() => {
    if (mode.kind !== "receive" || !data) return [] as Array<{ sku_id: number; qty: number }>;
    const allNeed = totalNeedMap;
    const out: Array<{ sku_id: number; qty: number }> = [];
    for (const inc of data.incoming) {
      const b = budgetMap.get(inc.sku_id);
      const used = usedMap.get(inc.sku_id) ?? 0;
      const est = Math.min(
        inc.qty - used,
        (b?.cap ?? inc.qty) - (allNeed.get(inc.sku_id) ?? 0) - (b?.pool ?? 0),
      );
      if (est > 0) out.push({ sku_id: inc.sku_id, qty: est });
    }
    return out;
  }, [mode.kind, data, budgetMap, usedMap, totalNeedMap]);
  const surplusTotal = useMemo(
    () => surplusRows.reduce((s, r) => s + r.qty, 0),
    [surplusRows],
  );

  // 只顯示候選訂單有用到的 SKU（budget 種子是聯集，會多）
  const visibleBudget = useMemo(() => {
    if (!data) return [] as BudgetRow[];
    const refd = new Set<number>();
    for (const o of data.orders) for (const it of o.items) refd.add(it.sku_id);
    return data.budget.filter((b) => refd.has(b.sku_id));
  }, [data]);

  const selectedCount = selected.size;
  const isReceive = mode.kind === "receive";

  // 貨不夠分 → 有幾張「運送中」的單勾不起來（確認時會被拉回「已確認」）。
  // 只是把 checkbox 變灰的話店員會以為是壞掉，這裡明講會發生什麼事。
  const shortShipping = useMemo(
    () =>
      isReceive
        ? data?.orders.filter((o) => o.status === "shipping" && !selected.has(o.order_id)).length ??
          0
        : 0,
    [isReceive, data, selected],
  );

  async function save() {
    if (!data || busy) return;
    if (!isReceive && selectedCount === 0) return;

    // 實收（含使用者調整）：空白/非法值直接擋在這裡
    let recvLines: ReceiveLine[] = [];
    if (isReceive) {
      if (items === null) return;
      const built = buildLines(items, qtyEdits);
      if (built.invalid) {
        setError("有「實收」欄位是空白或不是有效數量 — 請填 0 或正整數（多收也可以填）。");
        return;
      }
      recvLines = built.lines;
    }
    // 對 WV 派出量的差異 → 確認訊息要講清楚會回報總倉
    const shortTotal = isReceive
      ? (items ?? []).reduce((s, it) => {
          const v = Number(qtyEdits.get(it.id) ?? it.qty_shipped);
          return s + Math.max(0, it.qty_shipped - v);
        }, 0)
      : 0;
    const overTotal = isReceive
      ? (items ?? []).reduce((s, it) => {
          const v = Number(qtyEdits.get(it.id) ?? it.qty_shipped);
          return s + Math.max(0, v - it.qty_shipped);
        }, 0)
      : 0;

    // 沒勾的「派貨中」訂單＝拉回：這批貨不配給他，單頭退回「已確認」
    const pullbackIds = isReceive
      ? data.orders
          .filter((o) => o.status === "shipping" && !selected.has(o.order_id))
          .map((o) => o.order_id)
      : [];
    // 沒勾的候選（含拉回的）＝這批不配給他 → 伺服端標「待補貨」，取貨頁
    // 一律擋住、客人畫面顯示「待到貨」；下一批貨收進來時自動重算解除。
    // （20260824010000：光退回「已確認」擋不住 —— 取貨閘門不看配單勾了誰，
    // 只看有沒有到貨＋數量排不排得到他。）
    const backorderIds = isReceive
      ? data.orders.filter((o) => !selected.has(o.order_id)).map((o) => o.order_id)
      : [];

    const notifyLine = notify
      ? "📩 完成後會推播「商品到貨」給可取貨的客人。"
      : "🔕 不會推播通知，請自行聯繫客人。";
    const backorderLine =
      backorderIds.length > 0
        ? `⤺ 沒勾的 ${backorderIds.length} 張訂單這批不配給他們：客人畫面顯示「待到貨」、` +
          `取貨頁不會放行，下一批貨到時可再配。\n`
        : "";
    const surplusLine =
      surplusTotal > 0
        ? `🏬 多給的 ${surplusTotal} 件沒有訂單主人，會掛進【內部】${storeName} 現貨池（可轉單給客人）。\n`
        : "";
    const varianceLine =
      (shortTotal > 0 ? `⚠ 少收 ${shortTotal} 件：等於向總倉提出退回，總倉會在收件匣決定。\n` : "") +
      (overTotal > 0 ? `💜 多收 ${overTotal} 件：照實入庫，並回報總倉收件匣。\n` : "");
    const msg = isReceive
      ? `確認收貨並配單？\n\n` +
        (selectedCount > 0
          ? `勾選的 ${selectedCount} 張訂單會標成「可取貨」。\n`
          : `沒有勾選訂單 — 只收貨不配單。\n`) +
        backorderLine +
        varianceLine +
        surplusLine +
        notifyLine
      : `確認把勾選的 ${selectedCount} 張訂單標成「可取貨」？\n\n沒勾的訂單維持原狀，下一批貨到時可再配。\n` +
        notifyLine;
    if (!confirm(msg)) return;

    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      if (isReceive && mode.kind === "receive") {
        // 一段式：收貨＋配單同一交易，失敗整包回滾（＝沒收貨）
        const { data: res, error: e } = await sb.rpc("rpc_receive_transfer_manual", {
          p_transfer_ids: mode.transferIds,
          p_operator: operator,
          p_order_ids: selectedCount > 0 ? Array.from(selected) : null,
          p_notes: mode.note ?? null,
          p_lines: recvLines.length > 0 ? recvLines : null,
          p_pullback_order_ids: pullbackIds.length > 0 ? pullbackIds : null,
          p_backorder_order_ids: backorderIds.length > 0 ? backorderIds : null,
        });
        if (e) throw new Error(translateRpcError(e));
        const r = (res ?? {}) as ManualReceiveResult;
        let pushNote = "";
        if (notify) {
          const pushed = await fanoutPickupNotifications(mode.transferIds).catch((err) => {
            console.warn("push fanout error:", err);
            return 0;
          });
          if (pushed > 0) pushNote = `\n📩 已推播 ${pushed} 位顧客`;
        }
        const alloc = r.allocation;
        // 配單總數 = 派貨中保留勾選推進的 + confirmed 走配額守衛推進的
        const advancedTotal = (r.shipping_advanced ?? 0) + (alloc?.advanced ?? 0);
        const pullSkipped = r.pullback_skipped ?? [];
        const surplusBooked = (r.surplus ?? []).reduce((s, x) => s + Number(x.qty), 0);
        alert(
          `✅ 收貨完成：${r.transfers_received ?? mode.transferIds.length} 單` +
            (advancedTotal > 0 ? `，配單 ${advancedTotal} 張訂單已可取貨` : "，未配單") +
            ((r.backordered ?? 0) > 0 ? `，${r.backordered} 張沒配到轉「待到貨」等下批` : "") +
            (surplusBooked > 0
              ? `\n🏬 多給 ${surplusBooked} 件已掛進【內部】${storeName} 現貨池`
              : "") +
            pushNote +
            skipNoteOf(alloc?.skipped ?? []) +
            (pullSkipped.length > 0
              ? `\n⚠ ${pullSkipped.length} 張拉不回（狀態已變）：` +
                pullSkipped.map((s) => s.order_no ?? `#${s.order_id}`).join("、")
              : ""),
        );
        onSaved();
        onClose();
        return;
      }

      // store 模式：純配單（貨已在店）
      if (mode.kind !== "store") return;
      const { data: res, error: e } = await sb.rpc("rpc_manual_allocate_confirmed_orders", {
        p_store_id: mode.storeId,
        p_order_ids: Array.from(selected),
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as AllocResult;

      let pushNote = "";
      if (notify && (r.notify ?? []).length > 0) {
        const pushed = await pushArrivalNotifications(r.notify).catch((err) => {
          console.warn("push arrival error:", err);
          return 0;
        });
        if (pushed > 0) pushNote = `\n📩 已推播 ${pushed} 位顧客`;
      }
      const skipped = r.skipped ?? [];
      alert(`✅ 配單完成：${r.advanced ?? 0} 張訂單已可取貨${pushNote}${skipNoteOf(skipped)}`);
      onSaved();
      if (skipped.length > 0) {
        // 有跳過的單就留在彈窗讓店家重看（額度已變，重載）
        await loadStore();
      } else {
        onClose();
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      open
      onClose={onClose}
      title={isReceive ? `✋ 配單 — ${storeName}` : `✋ 手動配單 — ${storeName}`}
      maxWidth="max-w-4xl"
    >
      <div className="space-y-3">
        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        {data === null && !error && (
          <div className="flex items-center justify-center gap-2 py-8 text-sm text-zinc-500">
            <Spinner size={16} /> 載入訂單…
          </div>
        )}

        {data && (
          <>
            {/* 通知開關：放最上面（Alex 2026-08-24），switch 樣式 */}
            <div className="flex items-center justify-end">
              <label
                className="flex cursor-pointer items-center gap-2 text-xs text-zinc-600 dark:text-zinc-300"
                title="開啟：完成後推播「您的商品到貨」給可取貨的客人（不通知名單會自動排除）。"
              >
                {notify ? "📩 完成後通知客人到貨" : "🔕 完成後不通知客人"}
                <span
                  className={`relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors ${
                    notify ? "bg-emerald-500" : "bg-zinc-300 dark:bg-zinc-600"
                  }`}
                >
                  <input
                    type="checkbox"
                    role="switch"
                    checked={notify}
                    onChange={(e) => setNotify(e.target.checked)}
                    className="peer sr-only"
                  />
                  <span
                    aria-hidden
                    className={`absolute h-4 w-4 rounded-full bg-white shadow transition-transform ${
                      notify ? "translate-x-[18px]" : "translate-x-0.5"
                    }`}
                  />
                  <span className="absolute inset-0 rounded-full ring-emerald-600 peer-focus-visible:ring-2" />
                </span>
              </label>
            </div>

            {/* 本次到貨：實收直接在這裡改（預設 = WV 派出量）。少收＝向總倉
                提出退回；多收也可以填，照實入庫並回報總倉。改了額度會即時重算。 */}
            {isReceive && items !== null && items.length > 0 && (
              <div className="space-y-1.5 rounded-md border border-blue-200 bg-blue-50/60 px-3 py-2 text-sm dark:border-blue-900 dark:bg-blue-950/30">
                <div className="flex items-center gap-2">
                  <span className="font-medium text-blue-800 dark:text-blue-300">📦 本次到貨</span>
                  <span className="text-[11px] text-zinc-500">
                    實收預設＝派出量，可直接修改（少收＝向總倉提出退回；多收照實入庫並回報總倉）
                  </span>
                </div>
                {items.map((it) => {
                  const raw = qtyEdits.get(it.id) ?? String(it.qty_shipped);
                  const num = Number(raw);
                  const blank = raw.trim() === "";
                  const bad = blank || Number.isNaN(num) || num < 0;
                  const diff = bad ? 0 : num - it.qty_shipped;
                  const name =
                    it.description?.trim() ||
                    budgetMap.get(it.sku_id)?.name ||
                    data.incoming.find((r) => r.sku_id === it.sku_id)?.name ||
                    `#${it.sku_id}`;
                  return (
                    <div key={it.id} className="flex flex-wrap items-center gap-2 text-xs">
                      <span className="min-w-[180px]">{name}</span>
                      <span className="text-zinc-500">
                        派出 <b className="tabular-nums">{it.qty_shipped}</b>
                      </span>
                      <span className="text-zinc-500">實收</span>
                      <input
                        inputMode="decimal"
                        value={raw}
                        disabled={busy}
                        onChange={(e) =>
                          setQtyEdits((cur) => new Map(cur).set(it.id, e.target.value))
                        }
                        className={`w-16 rounded-md border px-1.5 py-0.5 text-right font-mono text-sm font-semibold ${
                          bad
                            ? "border-red-400 bg-red-50 dark:bg-red-950"
                            : diff !== 0
                            ? "border-amber-400 bg-amber-50 dark:bg-amber-950"
                            : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800"
                        }`}
                      />
                      {!bad && diff < 0 && (
                        <span className="font-medium text-rose-600 dark:text-rose-400">
                          少收 {-diff} → 向總倉提出退回
                        </span>
                      )}
                      {!bad && diff > 0 && (
                        <span className="font-medium text-purple-600 dark:text-purple-400">
                          多收 {diff} → 照實入庫、回報總倉
                        </span>
                      )}
                      {bad && (
                        <span className="font-medium text-red-600 dark:text-red-400">
                          請填 0 或正整數
                        </span>
                      )}
                    </div>
                  );
                })}
              </div>
            )}

            <p className="text-sm text-zinc-600 dark:text-zinc-300">
              {isReceive
                ? "勾選要配到貨的訂單，按「確認收貨」才會完成收貨；關閉視窗則不收貨。" +
                  "「運送中」的訂單出貨時就是配給他的，已依訂單時間先後預先勾到" +
                  "這批貨分完為止 — 取消勾選會把該單退回「已確認」，把這批貨讓給別人。"
                : "勾選要先拿到貨的訂單 — 沒勾的維持原狀，下一批貨到時再配即可。"}
            </p>

            {shortShipping > 0 && (
              <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
                ⚠️ 這批貨不夠分：有 <b>{shortShipping}</b> 張「運送中」的訂單勾不起來。
                確認收貨後它們會轉「待到貨」（取貨頁不會放行），下一批貨到時可再配。
                要優先配給其中某一張，先取消勾別張、額度空出來就勾得起來了。
              </div>
            )}

            {/* 各 SKU 剩餘可配量。不夠分不用跳別頁 —— 沒勾到的一律轉「待到貨」，
                下一批到貨再配（20260824 拿掉「⚖️ 配貨」跳轉入口，Alex 定案）。 */}
            {visibleBudget.length > 0 && (
              <div className="flex flex-wrap gap-2 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs dark:border-zinc-800 dark:bg-zinc-900/60">
                {visibleBudget.map((b) => {
                  const rem = b.cap - (usedMap.get(b.sku_id) ?? 0);
                  return (
                    <span
                      key={b.sku_id}
                      className="inline-flex items-center gap-1 rounded-md border border-zinc-200 bg-white px-2 py-0.5 dark:border-zinc-700 dark:bg-zinc-800"
                      title={b.sku_code ?? undefined}
                    >
                      {b.name}
                      <b
                        className={
                          rem > 0 ? "text-emerald-700 dark:text-emerald-400" : "text-zinc-400"
                        }
                      >
                        剩 {Math.max(0, rem)}
                      </b>
                    </span>
                  );
                })}
                <SpinButton
                  onClick={presetByTime}
                  className="ml-auto rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-semibold text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900"
                  title="依下單時間由早到晚勾滿為止（跟自動配單同一套結果），可再手動增減"
                >
                  ⏱ 依訂單時間選好
                </SpinButton>
              </div>
            )}

            <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
              <table className="w-full min-w-[680px] text-sm">
                <thead>
                  <tr className="border-b border-zinc-200 bg-zinc-50 text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
                    <th className="w-10 px-3 py-2" />
                    <th className="px-3 py-2 text-left font-medium">訂單編號</th>
                    <th className="px-3 py-2 text-left font-medium">顧客</th>
                    <th className="px-3 py-2 text-left font-medium">客人看到</th>
                    <th className="px-3 py-2 text-left font-medium">商品</th>
                    <th className="px-3 py-2 text-left font-medium">下單時間</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {data.orders.map((o) => {
                    const checked = selected.has(o.order_id);
                    const canCheck = checked || fits(o);
                    return (
                      <tr
                        key={o.order_id}
                        onClick={() => canCheck && !busy && toggle(o)}
                        className={
                          checked
                            ? "cursor-pointer bg-emerald-50/70 dark:bg-emerald-950/20"
                            : canCheck
                            ? "cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-950"
                            : "opacity-50"
                        }
                        title={
                          canCheck
                            ? undefined
                            : o.status === "shipping"
                            ? "這批貨不夠分到這張單 — 確認收貨時會退回「已確認」等下一批。" +
                              "要優先配給他就先取消勾別張，額度空出來才勾得起來。"
                            : "剩餘可配量不夠整張單，先取消別張才能勾"
                        }
                      >
                        <td className="px-3 py-2">
                          <input
                            type="checkbox"
                            checked={checked}
                            disabled={!canCheck || busy}
                            onChange={() => toggle(o)}
                            onClick={(e) => e.stopPropagation()}
                            className="cursor-pointer"
                          />
                        </td>
                        <td className="px-3 py-2 font-mono text-xs">
                          <Link
                            href={orderListHref(o.order_no, o.status)}
                            target="_blank"
                            rel="noopener noreferrer"
                            onClick={(e) => e.stopPropagation()}
                            className="text-blue-600 hover:underline dark:text-blue-400"
                            title="開新分頁查看這張訂單（配單中的勾選不會遺失）"
                          >
                            {o.order_no} ↗
                          </Link>
                        </td>
                        <td className="max-w-[180px] truncate px-3 py-2" title={o.customer ?? ""}>
                          {o.customer || "—"}
                          {o.campaign_name && (
                            <div
                              className="max-w-[180px] truncate text-[10px] text-zinc-400"
                              title={o.campaign_name}
                            >
                              {o.campaign_name}
                            </div>
                          )}
                        </td>
                        <td className="whitespace-nowrap px-3 py-2">
                          <span
                            className={
                              "inline-flex rounded-md border px-1.5 py-0.5 text-[11px] " +
                              (o.status === "shipping"
                                ? "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-400"
                                : "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300")
                            }
                            title={
                              o.status === "shipping"
                                ? "出貨時已配給這張單；取消勾選會退回「已確認」（客人畫面變回「待到貨」）"
                                : "客人在會員端目前看到的狀態"
                            }
                          >
                            {customerStatusLabel(o)}
                          </span>
                        </td>
                        <td className="px-3 py-2 text-xs">
                          {o.items.map((it) => (
                            <div key={it.sku_id} className="whitespace-nowrap">
                              {budgetMap.get(it.sku_id)?.name ?? `#${it.sku_id}`}{" "}
                              <b className="tabular-nums">× {it.qty}</b>
                            </div>
                          ))}
                        </td>
                        <td className="whitespace-nowrap px-3 py-2 text-xs text-zinc-500">
                          {new Date(o.created_at).toLocaleString("zh-TW", {
                            dateStyle: "short",
                            timeStyle: "short",
                          })}
                        </td>
                      </tr>
                    );
                  })}
                  {/* 多給的跳出內部店：沒有訂單主人的剩餘量，確認收貨後會掛進
                      【內部】店現貨池（伺服端 _grow_internal_pool 以當下重算為準）。
                      勾選變動時數量即時跟著變，歸零就整列消失。 */}
                  {isReceive && surplusRows.length > 0 && (
                    <tr
                      className="bg-blue-50/60 dark:bg-blue-950/20"
                      title="到貨超過訂單需求的量沒有訂單主人，確認收貨後會自動掛進【內部】店現貨池，之後可從那張單轉單給客人"
                    >
                      <td className="px-3 py-2 text-center">🏬</td>
                      <td className="px-3 py-2 font-mono text-xs text-zinc-400">（自動）</td>
                      <td className="max-w-[180px] px-3 py-2">
                        【內部】{storeName}
                        <div className="text-[10px] text-zinc-400">
                          多給的貨掛進現貨池，可轉單給客人
                        </div>
                      </td>
                      <td className="whitespace-nowrap px-3 py-2">
                        <span className="inline-flex rounded-md border border-blue-200 bg-blue-50 px-1.5 py-0.5 text-[11px] text-blue-700 dark:border-blue-900 dark:bg-blue-950/40 dark:text-blue-400">
                          現貨池
                        </span>
                      </td>
                      <td className="px-3 py-2 text-xs">
                        {surplusRows.map((r) => (
                          <div key={r.sku_id} className="whitespace-nowrap">
                            {budgetMap.get(r.sku_id)?.name ?? `#${r.sku_id}`}{" "}
                            <b className="tabular-nums">× {r.qty}</b>
                          </div>
                        ))}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2 text-xs text-zinc-400">—</td>
                    </tr>
                  )}
                  {data.orders.length === 0 && surplusRows.length === 0 && (
                    <tr>
                      <td colSpan={6} className="px-3 py-6 text-center text-zinc-500">
                        {isReceive
                          ? "這批貨對不到任何等貨中的訂單 — 可直接確認收貨入庫。"
                          : "目前沒有可配的訂單。"}
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>

            {!isReceive && data.waiting_count > 0 && (
              <p className="text-[11px] text-zinc-500">
                另有 {data.waiting_count} 張已成立的訂單因為貨還沒到齊（或店內帳上沒庫存）
                暫時配不了，下一批貨收進來會出現在這裡。
              </p>
            )}

            <div className="flex flex-wrap items-center gap-3">
              <SpinButton
                onClick={save}
                disabled={busy || (!isReceive && selectedCount === 0)}
                className="ml-auto rounded-md bg-emerald-600 px-5 py-2 text-sm font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
              >
                {busy
                  ? "處理中…"
                  : isReceive
                  ? `✓ 確認收貨${selectedCount > 0 ? `·配單 ${selectedCount} 張` : ""}`
                  : `✓ 配單${selectedCount > 0 ? ` (${selectedCount} 張)` : ""}`}
              </SpinButton>
            </div>
            <p className="text-[11px] text-zinc-500">
              {isReceive
                ? "按「確認收貨」會一次完成入庫與配單（同一筆交易，失敗即整筆取消、不會收到一半）。" +
                  "配好的訂單會標成「可取貨」，並從【內部】店現貨池扣掉相應數量；" +
                  "沒勾的訂單一律轉「待到貨」（取貨頁不會放行），下一批貨到時可再配。" +
                  "多給的量（沒有訂單主人）會自動掛進【內部】店現貨池，之後可轉單給客人。" +
                  "伺服端會再驗一次可配量，裝不下的單會被跳過並告知，不會硬配。"
                : "配好的訂單會標成「可取貨」，取貨頁就能發貨；同時會從【內部】店現貨池" +
                  "扣掉相應數量，避免同一批貨再被轉單給別人。伺服端送出時會再驗一次可配量，" +
                  "若同時有別人在配、裝不下的單會被跳過並告知，不會硬配。"}
            </p>
          </>
        )}
      </div>
    </Modal>
  );
}

export default ManualAllocateModal;

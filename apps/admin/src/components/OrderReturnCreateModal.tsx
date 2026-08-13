"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { parseReturnNote } from "@/lib/returnNote";

const RETURNABLE_STATUSES = ["shipping", "ready", "partially_completed", "completed", "expired"] as const;

const STATUS_LABEL: Record<string, string> = {
  shipping: "派貨中",
  ready: "可取貨",
  partially_completed: "部分取貨",
  completed: "已完成",
  expired: "已過期",
};

type Store = { id: number; name: string; location_id: number | null };

type OrderRow = {
  id: number;
  order_no: string;
  status: string;
  pickup_store_id: number;
  nickname_snapshot: string | null;
  created_at: string;
  items_summary: string;
};

type DeliveredSku = {
  sku_id: number;
  sku_code: string;
  sku_name: string;
  delivered: number; // R：已收(訂單)量（含已取貨）
  picked: number; // P：已取貨量（status='picked_up'）
  returned_unpicked: number; // 已退量：一般退貨（未帶 |取貨後退回 tag）
  returned_picked: number; // 已退量：取貨後退回（帶 |取貨後退回 tag）
};

type LineInput = Record<number, string>;
type ReturnType = "normal" | "damage" | "expired";

const RETURN_TYPE_OPTIONS: { value: ReturnType; label: string }[] = [
  { value: "normal", label: "一般退貨" },
  { value: "damage", label: "破損" },
  { value: "expired", label: "過期" },
];

export default function OrderReturnCreateModal({
  open,
  onClose,
  onCreated,
  prefillStoreId,
  prefillOrderId,
}: {
  open: boolean;
  onClose: () => void;
  onCreated: (transferId: number) => void;
  prefillStoreId?: number | null;
  prefillOrderId?: number | null;
}) {
  const isPrefilled = prefillOrderId != null && prefillStoreId != null;
  const [stores, setStores] = useState<Store[] | null>(null);
  const [storeId, setStoreId] = useState<number | null>(prefillStoreId ?? null);
  const [orders, setOrders] = useState<OrderRow[] | null>(null);
  const [orderId, setOrderId] = useState<number | null>(prefillOrderId ?? null);
  const [skus, setSkus] = useState<DeliveredSku[] | null>(null);
  const [qtys, setQtys] = useState<LineInput>({});
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [returnType, setReturnType] = useState<ReturnType>("normal");
  const [orderStatus, setOrderStatus] = useState<string | null>(null);
  const [restockFirst, setRestockFirst] = useState(false);
  const restockTouched = useRef(false);

  // 訂單搜尋 combobox
  const [orderQuery, setOrderQuery] = useState("");
  const [orderOpen, setOrderOpen] = useState(false);
  const orderBoxRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!orderOpen) return;
    function onAway(e: MouseEvent) {
      if (orderBoxRef.current && !orderBoxRef.current.contains(e.target as Node)) {
        setOrderOpen(false);
      }
    }
    document.addEventListener("mousedown", onAway);
    return () => document.removeEventListener("mousedown", onAway);
  }, [orderOpen]);

  useEffect(() => {
    if (!open) return;
    (async () => {
      const { data } = await getSupabase()
        .from("stores")
        .select("id, name, location_id")
        .order("name");
      setStores((data ?? []).filter((s) => s.location_id !== null) as Store[]);
    })();
  }, [open]);

  useEffect(() => {
    if (open) {
      // 重新打開時：套用 prefill（若有）
      setStoreId(prefillStoreId ?? null);
      setOrderId(prefillOrderId ?? null);
    } else {
      setStoreId(null);
      setOrderId(null);
      setOrders(null);
      setSkus(null);
      setQtys({});
      setReason("");
      setError(null);
      setOrderQuery("");
      setOrderOpen(false);
      setReturnType("normal");
      setOrderStatus(null);
      setRestockFirst(false);
      restockTouched.current = false;
    }
  }, [open, prefillStoreId, prefillOrderId]);

  useEffect(() => {
    if (isPrefilled) return; // prefill 模式不載清單
    setOrderId(null);
    setOrders(null);
    setSkus(null);
    setQtys({});
    if (storeId === null) return;
    (async () => {
      // 一併撈每張訂單的 items（含 sku_code + 商品名）以便下拉直接顯示品項
      const { data } = await getSupabase()
        .from("customer_orders")
        .select(
          "id, order_no, status, pickup_store_id, nickname_snapshot, created_at, " +
            "customer_order_items(sku_id, qty, status, skus(sku_code, products(name)))"
        )
        .eq("pickup_store_id", storeId)
        .in("status", RETURNABLE_STATUSES as unknown as string[])
        .order("id", { ascending: false })
        .limit(100);

      type ApiItem = {
        sku_id: number | null;
        qty: number | null;
        status: string | null;
        skus:
          | { sku_code: string; products: { name?: string } | { name?: string }[] | null }
          | Array<{ sku_code: string; products: { name?: string } | { name?: string }[] | null }>
          | null;
      };
      type ApiOrder = {
        id: number;
        order_no: string;
        status: string;
        pickup_store_id: number;
        nickname_snapshot: string | null;
        created_at: string;
        customer_order_items: ApiItem[] | null;
      };

      const rows = ((data ?? []) as unknown as ApiOrder[]).map((o) => {
        const parts: string[] = [];
        for (const it of o.customer_order_items ?? []) {
          if (it.status === "cancelled" || it.status === "expired") continue;
          const skuObj = Array.isArray(it.skus) ? it.skus[0] : it.skus;
          if (!skuObj) continue;
          const prodObj = Array.isArray(skuObj.products) ? skuObj.products[0] : skuObj.products;
          const code = skuObj.sku_code ?? `#${it.sku_id}`;
          const name = prodObj?.name ?? "";
          const qty = Number(it.qty ?? 0);
          parts.push(name ? `${code}×${qty}（${name}）` : `${code}×${qty}`);
        }
        return {
          id: o.id,
          order_no: o.order_no,
          status: o.status,
          pickup_store_id: o.pickup_store_id,
          nickname_snapshot: o.nickname_snapshot,
          created_at: o.created_at,
          items_summary: parts.join("、"),
        } as OrderRow;
      });

      setOrders(rows);
    })();
  }, [storeId, isPrefilled]);

  useEffect(() => {
    setSkus(null);
    setQtys({});
    setOrderStatus(null);
    restockTouched.current = false;
    if (orderId === null || storeId === null) return;
    (async () => {
      const sb = getSupabase();
      const store = stores?.find((s) => s.id === storeId);
      if (!store?.location_id) return;

      // 訂單 status（決定 restock_first 預設 + 顯示）
      const { data: ordRow } = await sb
        .from("customer_orders")
        .select("status")
        .eq("id", orderId)
        .maybeSingle();
      setOrderStatus((ordRow as { status?: string } | null)?.status ?? null);

      // 訂單行（customer_order_items 是已派該店的 single source of truth）
      const { data: itemRows } = await sb
        .from("customer_order_items")
        .select("sku_id, qty, status, skus(sku_code, products(name))")
        .eq("order_id", orderId)
        .not("status", "in", "(cancelled,expired)");

      // deliveredMap.qty = 已收(訂單)量（含已取貨）；picked = 已取貨量（status='picked_up'）
      const deliveredMap = new Map<number, { qty: number; picked: number; sku_code: string; sku_name: string }>();
      // Supabase 自動 typegen 對 FK relation 一律當 array，雖然這裡實際是 1:1。
      // 用 unknown 中轉 cast，再對 array 取 [0]。
      type ItemRow = {
        sku_id: number;
        qty: number | null;
        status: string | null;
        skus: { sku_code: string; products: { name?: string } | { name?: string }[] | null } | Array<{
          sku_code: string;
          products: { name?: string } | { name?: string }[] | null;
        }> | null;
      };
      const rows = (itemRows ?? []) as unknown as ItemRow[];
      for (const row of rows) {
        if (row.sku_id == null) continue;
        const skuObj = Array.isArray(row.skus) ? row.skus[0] : row.skus;
        const prodObj = skuObj
          ? Array.isArray(skuObj.products)
            ? skuObj.products[0]
            : skuObj.products
          : null;
        const prev = deliveredMap.get(row.sku_id);
        const qty = Number(row.qty ?? 0);
        deliveredMap.set(row.sku_id, {
          qty: (prev?.qty ?? 0) + qty,
          picked: (prev?.picked ?? 0) + (row.status === "picked_up" ? qty : 0),
          sku_code: skuObj?.sku_code ?? prev?.sku_code ?? "",
          sku_name: prodObj?.name ?? prev?.sku_name ?? "",
        });
      }

      // 已退量（先前的 return_to_hq transfer 累加），依 notes |取貨後退回 tag 分兩池
      const { data: returnedRows } = await sb
        .from("transfers")
        .select("id, transfer_type, status, source_location, notes, transfer_items(sku_id, qty_shipped)")
        .eq("customer_order_id", orderId)
        .eq("transfer_type", "return_to_hq")
        .in("status", ["shipped", "received"])
        .eq("source_location", store.location_id);

      const returnedUnpickedMap = new Map<number, number>();
      const returnedPickedMap = new Map<number, number>();
      for (const t of (returnedRows ?? []) as Array<{
        notes: string | null;
        transfer_items: Array<{ sku_id: number; qty_shipped: number | null }>;
      }>) {
        const isRestock = parseReturnNote(t.notes).isRestock;
        const target = isRestock ? returnedPickedMap : returnedUnpickedMap;
        for (const ti of t.transfer_items ?? []) {
          if (ti.sku_id == null) continue;
          target.set(ti.sku_id, (target.get(ti.sku_id) ?? 0) + Number(ti.qty_shipped ?? 0));
        }
      }

      // 可退量改用「訂單追蹤量」(已收 − 已取 − 已退) 計算，不再前端讀 stock_balances：
      // stock_balances 有 RLS，store_manager 角色（JWT 無 location_id）讀不到、一律回 0，
      // 會把可退量誤卡成 0。實體庫存把關交給後端 rpc_outbound（SECURITY DEFINER、不受 RLS 限制）。
      const list: DeliveredSku[] = Array.from(deliveredMap.entries()).map(([sku_id, info]) => ({
        sku_id,
        sku_code: info.sku_code,
        sku_name: info.sku_name,
        delivered: info.qty,
        picked: info.picked,
        returned_unpicked: returnedUnpickedMap.get(sku_id) ?? 0,
        returned_picked: returnedPickedMap.get(sku_id) ?? 0,
      }));
      list.sort((a, b) => a.sku_code.localeCompare(b.sku_code));
      setSkus(list);
    })();
  }, [orderId, storeId, stores]);

  // 訂單 status='completed'（客戶已全取）預設勾「取貨後反悔先入庫」；
  // 其他 status（店端還有貨）預設不勾。使用者手動改過就不再覆蓋。
  useEffect(() => {
    if (restockTouched.current) return;
    setRestockFirst(orderStatus === "completed");
  }, [orderStatus]);

  // 有效可退量：依是否「客戶已取貨後退回」分流（皆為訂單追蹤量，不讀店端實體庫存）
  //   勾 restock：客戶取走又拿回 → 上限 = 已取貨量 − 已退(取貨後)量
  //   不勾：退店端未取貨的貨 → 上限 = (已收 − 已取) − 已退(一般)量
  const effRemaining = (s: DeliveredSku): number => {
    if (restockFirst) return Math.max(0, s.picked - s.returned_picked);
    return Math.max(0, s.delivered - s.picked - s.returned_unpicked);
  };

  // 整單是否有已取貨量；沒有就不能走「客戶已取貨後退回」（勾了也退不了）
  const hasPicked = useMemo(() => (skus ?? []).some((s) => s.picked > 0), [skus]);

  // 載到沒有已取貨的單時，強制取消「客戶已取貨後退回」勾選
  useEffect(() => {
    if (!hasPicked && restockFirst) setRestockFirst(false);
  }, [hasPicked, restockFirst]);

  const totalToReturn = useMemo(() => {
    if (!skus) return 0;
    return skus.reduce((acc, s) => acc + (Number(qtys[s.sku_id] ?? 0) || 0), 0);
  }, [skus, qtys]);

  const valid =
    storeId !== null &&
    orderId !== null &&
    skus !== null &&
    skus.length > 0 &&
    totalToReturn > 0 &&
    skus.every((s) => {
      const q = Number(qtys[s.sku_id] ?? 0) || 0;
      return q >= 0 && q <= effRemaining(s);
    });

  async function handleSubmit() {
    setError(null);
    if (!valid || orderId === null) {
      setError("請至少填一個退貨數量、且不可超過可退量");
      return;
    }
    const lines = (skus ?? [])
      .map((s) => ({ sku_id: s.sku_id, qty: Number(qtys[s.sku_id] ?? 0) || 0 }))
      .filter((l) => l.qty > 0);
    if (lines.length === 0) {
      setError("請至少填一個退貨數量");
      return;
    }
    setBusy(true);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_create_order_return", {
        p_order_id: orderId,
        p_lines: lines,
        p_reason: reason.trim() || null,
        p_movement_type: returnType === "damage" ? "damage" : "customer_return",
        p_restock_first: restockFirst,
      });
      if (err) throw err;
      const result = data as { return_transfer_id?: number; order_closed_as?: string | null };
      // 全數退貨收尾：後端把未取量退光的訂單自動取消/結案，提示操作者訂單會從未取清單消失
      if (result?.order_closed_as === "cancelled") {
        alert("已建立退貨單。此訂單商品已全數退回總倉，訂單已自動取消（不再出現在未取清單）。");
      } else if (result?.order_closed_as === "completed") {
        alert("已建立退貨單。剩餘未取商品已全數退回總倉，訂單已自動結案（已取部分照常計收）。");
      }
      onCreated(Number(result?.return_transfer_id ?? 0));
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(false);
    }
  }

  const inputCls =
    "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <Modal open={open} onClose={onClose} title="↩ 退貨回總倉" maxWidth="max-w-4xl">
      <div className="flex flex-col gap-4">
        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <p className="text-sm text-zinc-500">
          退量上限依是否「客戶已取貨後退回」分流：未勾 → 退店端「未取貨」的貨（上限 = 已收 − 已取 − 已退）；
          勾選 → 客戶取走又拿回（上限 = 已取貨量 − 已退）。實體庫存不足時由後端擋下。
        </p>

        {!isPrefilled && (
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">分店 *</span>
            <select
              value={storeId ?? ""}
              onChange={(e) => setStoreId(Number(e.target.value) || null)}
              className={inputCls}
              disabled={stores === null}
            >
              <option value="">— 請選 —</option>
              {(stores ?? []).map((s) => (
                <option key={s.id} value={s.id}>{s.name}</option>
              ))}
            </select>
          </label>
          <div className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">訂單 *</span>
            <div className="relative" ref={orderBoxRef}>
              <input
                type="text"
                value={orderOpen ? orderQuery : (() => {
                  if (orderId === null) return "";
                  const o = orders?.find((x) => x.id === orderId);
                  if (!o) return "";
                  return `${o.order_no} · ${STATUS_LABEL[o.status] ?? o.status}${o.nickname_snapshot ? ` · ${o.nickname_snapshot}` : ""}`;
                })()}
                onFocus={() => { setOrderOpen(true); setOrderQuery(""); }}
                onChange={(e) => { setOrderOpen(true); setOrderQuery(e.target.value); }}
                placeholder={
                  orders === null
                    ? storeId === null
                      ? "請先選分店"
                      : "載入中…"
                    : orders.length === 0
                      ? "此店沒有可退貨的訂單"
                      : "搜尋訂單號 / 人名 / 商品名稱…"
                }
                disabled={orders === null || (orders ?? []).length === 0}
                className={`${inputCls} w-full pr-8`}
                aria-label="訂單搜尋"
              />
              {orderId !== null && !orderOpen && (
                <button
                  type="button"
                  onClick={() => { setOrderId(null); setOrderQuery(""); setOrderOpen(true); }}
                  className="absolute right-2 top-1/2 -translate-y-1/2 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
                  aria-label="清除選擇"
                >
                  ×
                </button>
              )}

              {orderOpen && (orders?.length ?? 0) > 0 && (() => {
                const q = orderQuery.trim().toLowerCase();
                const filtered = q
                  ? (orders ?? []).filter((o) =>
                      o.order_no.toLowerCase().includes(q) ||
                      (o.nickname_snapshot ?? "").toLowerCase().includes(q) ||
                      (o.items_summary ?? "").toLowerCase().includes(q)
                    )
                  : (orders ?? []);
                return (
                  <ul
                    role="listbox"
                    className="absolute z-10 mt-1 max-h-72 w-full overflow-y-auto rounded-md border border-zinc-300 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900"
                  >
                    {filtered.length === 0 ? (
                      <li className="px-3 py-2 text-xs text-zinc-500">沒有符合的訂單</li>
                    ) : (
                      filtered.map((o) => (
                        <li
                          key={o.id}
                          role="option"
                          aria-selected={orderId === o.id}
                          onMouseDown={(e) => {
                            // mousedown 而非 click：避免 input blur 衝突
                            e.preventDefault();
                            setOrderId(o.id);
                            setOrderOpen(false);
                            setOrderQuery("");
                          }}
                          className={`cursor-pointer px-3 py-2 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800 ${
                            orderId === o.id ? "bg-blue-50 dark:bg-blue-950/40" : ""
                          }`}
                        >
                          <div className="font-mono text-zinc-900 dark:text-zinc-100">
                            {o.order_no} · <span className="text-zinc-500">{STATUS_LABEL[o.status] ?? o.status}</span>
                          </div>
                          {o.nickname_snapshot && (
                            <div className="text-zinc-600 dark:text-zinc-400">{o.nickname_snapshot}</div>
                          )}
                          {o.items_summary && (
                            <div className="text-zinc-500">{o.items_summary}</div>
                          )}
                        </li>
                      ))
                    )}
                  </ul>
                );
              })()}
            </div>
          </div>
        </div>
        )}

        {orderId !== null && (
          <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
            <table className="w-full text-sm">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                  <th className="px-3 py-2">SKU</th>
                  <th className="px-3 py-2">品名</th>
                  <th className="px-3 py-2 text-right">訂單量</th>
                  <th className="px-3 py-2 text-right">已取</th>
                  <th className="px-3 py-2 text-right">已退</th>
                  <th className="px-3 py-2 text-right">可退</th>
                  <th className="px-3 py-2 text-right">退多少 *</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                {skus === null ? (
                  <tr><td colSpan={7} className="p-4 text-center text-zinc-500">載入中…</td></tr>
                ) : skus.length === 0 ? (
                  <tr><td colSpan={7} className="p-4 text-center text-zinc-500">此訂單目前沒有可退的 SKU（全部已取消 / 過期）</td></tr>
                ) : skus.map((s) => {
                  // 顯示的已退量依當前模式（取貨後退回 / 一般）對應的那一池
                  const shownReturned = restockFirst ? s.returned_picked : s.returned_unpicked;
                  const cap = effRemaining(s);
                  return (
                    <tr key={s.sku_id}>
                      <td className="px-3 py-2 font-mono text-xs">{s.sku_code}</td>
                      <td className="px-3 py-2">{s.sku_name || "—"}</td>
                      <td className="px-3 py-2 text-right">{s.delivered}</td>
                      <td className="px-3 py-2 text-right text-zinc-500">{s.picked}</td>
                      <td className="px-3 py-2 text-right text-zinc-500">{shownReturned}</td>
                      <td className="px-3 py-2 text-right font-medium">
                        {cap}
                      </td>
                      <td className="px-3 py-2 text-right">
                        <input
                          type="number"
                          min="0"
                          max={cap}
                          step="1"
                          value={qtys[s.sku_id] ?? ""}
                          onChange={(e) => setQtys((m) => ({ ...m, [s.sku_id]: e.target.value }))}
                          className={`w-24 text-right ${inputCls}`}
                          disabled={cap <= 0}
                        />
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {orderId !== null && (
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="flex flex-col gap-1.5 text-sm">
              <span className="text-zinc-600 dark:text-zinc-400">退貨類型 *</span>
              <div className="flex flex-wrap gap-3">
                {RETURN_TYPE_OPTIONS.map((o) => (
                  <label key={o.value} className="flex cursor-pointer items-center gap-1.5">
                    <input
                      type="radio"
                      name="returnType"
                      checked={returnType === o.value}
                      onChange={() => setReturnType(o.value)}
                    />
                    {o.label}
                  </label>
                ))}
              </div>
              {returnType === "damage" && (
                <span className="text-xs text-amber-600 dark:text-amber-400">
                  破損 → 庫存異動記為 damage，會計可與一般退貨分流
                </span>
              )}
            </div>
            <div className="flex flex-col gap-1.5 text-sm">
              <label className={`flex items-center gap-2 ${hasPicked ? "cursor-pointer" : "cursor-not-allowed opacity-50"}`}>
                <input
                  type="checkbox"
                  checked={restockFirst}
                  disabled={!hasPicked}
                  onChange={(e) => {
                    restockTouched.current = true;
                    setRestockFirst(e.target.checked);
                  }}
                />
                <span>客戶已取貨後退回（先把退回商品入庫店端再退回總倉）</span>
              </label>
              <span className="text-xs text-zinc-500">
                {!hasPicked
                  ? "此訂單沒有已取貨的品項，無法走「取貨後退回」（此情況請用一般退貨）。"
                  : orderStatus === "completed"
                    ? "此訂單已完成（客戶已取貨），店端庫存通常為 0；勾選後系統自動先入庫再退回，免店員手動兩步。"
                    : "店端尚有未取貨庫存時不需勾選；僅「客戶取貨後又拿回來」才勾。"}
              </span>
            </div>
          </div>
        )}

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">退貨原因（選填）</span>
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className={`${inputCls} min-h-16`}
            placeholder="例：客戶取消、過期未取、收到瑕疵"
          />
        </label>

        <div className="flex gap-2">
          <SpinButton
            onClick={handleSubmit}
            disabled={busy || !valid}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
          >
            {busy ? "建立中…" : `建立退貨單（共退 ${totalToReturn}）`}
          </SpinButton>
          <SpinButton
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700"
          >
            取消
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

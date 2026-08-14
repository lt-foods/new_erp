"use client";

import { useEffect, useRef, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";

type Store = { id: number; name: string; code: string };
export type TransferItem = {
  id: number;
  sku_id: number;
  qty: number;
  product_name: string | null;
  variant_name: string | null;
  sku_code: string | null;
};
type MemberHit = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  home_store_id: number | null;
  home_store_name: string | null;
  no_new_order: boolean | null;
  admin_note: string | null;
};

function itemLabel(it: TransferItem): string {
  const base = it.product_name ?? `SKU #${it.sku_id}`;
  return it.variant_name ? `${base} / ${it.variant_name}` : base;
}

export function OrderTransferModal({
  orderId,
  orderNo,
  currentPickupStoreId,
  currentMemberLabel,
  items,
  open,
  onClose,
  onSubmitted,
  sameStoreOnly = false,
  partialOnly = false,
  canReturnToHq = false,
}: {
  orderId: number;
  orderNo: string;
  currentPickupStoreId: number | null;
  currentMemberLabel: string;
  items: TransferItem[];
  open: boolean;
  onClose: () => void;
  onSubmitted: (newOrderId: number) => void;
  // 貨還沒到店（status != 'ready'）只能同店換客人：接收店鎖定原店
  // (跟 DB rpc_transfer_order_* 20260807000000 的 gate 一致)
  sameStoreOnly?: boolean;
  // 部分取貨（partially_completed）的單：整單轉出會把已取走品項的營收標成
  // transferred_out 整張歸零，所以「全選全量」也強制走部分轉出 RPC
  // （剩餘 active 全轉走後原單由 _close_orders_all_items_settled 收尾成 completed）
  partialOnly?: boolean;
  // 訂單頁此刻有沒有顯示「↩ 退貨回總倉」鈕（= OrderDetail 的 canReturn）。
  // 只用來決定提示要不要指向那顆鈕，不參與任何轉出判斷；預設 false = 不提，寧可少講也別指向不存在的鈕
  canReturnToHq?: boolean;
}) {
  const [stores, setStores] = useState<Store[]>([]);
  const [toStore, setToStore] = useState<number | "">("");
  const [toMember, setToMember] = useState<number | "internal">("internal");
  const [pickedMember, setPickedMember] = useState<MemberHit | null>(null);
  const [term, setTerm] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [results, setResults] = useState<MemberHit[]>([]);
  const [searching, setSearching] = useState(false);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const searchWrapRef = useRef<HTMLDivElement | null>(null);
  const [reason, setReason] = useState("");
  // 空中轉：直接店對店、不經總倉；不勾 = 經總倉中轉（總倉需確認到貨再配送）
  const [isAir, setIsAir] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  // 每個品項的轉移勾選 + 數量（預設全選、全量 = 整單轉出）
  const [picks, setPicks] = useState<Record<number, { checked: boolean; qty: string }>>({});
  // 開窗（或換訂單）時重置勾選 — 用 render-time reset 而非 effect，避免 cascading render
  const [picksKey, setPicksKey] = useState<string | null>(null);
  const curPicksKey = open ? String(orderId) : null;
  if (curPicksKey !== picksKey) {
    setPicksKey(curPicksKey);
    const next: Record<number, { checked: boolean; qty: string }> = {};
    for (const it of items) next[it.id] = { checked: true, qty: String(it.qty) };
    setPicks(next);
    setIsAir(false);
    // 同店限定時直接鎖定接收店＝原店（select 也會 disabled）
    if (sameStoreOnly && currentPickupStoreId != null) setToStore(currentPickupStoreId);
  }

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data: ss } = await sb
        .from("stores")
        .select("id, name, code")
        .eq("is_active", true)
        .order("name");
      if (!cancelled) setStores((ss as Store[] | null) ?? []);
    })();
    return () => {
      cancelled = true;
    };
  }, [open]);

  // close member search dropdown when clicking outside
  useEffect(() => {
    if (!searchOpen) return;
    const onDown = (e: MouseEvent) => {
      if (!searchWrapRef.current?.contains(e.target as Node)) setSearchOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [searchOpen]);

  // debounced rpc_search_members (same RPC used by member page / order entry)
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (term.length < 1 && !searchOpen) {
      setSearching(false);
      return;
    }
    setSearching(true);
    debounceRef.current = setTimeout(async () => {
      try {
        const sb = getSupabase();
        const { data } = await sb.rpc("rpc_search_members", {
          p_term: term,
          p_limit: 10,
        });
        setResults((data as MemberHit[] | null) ?? []);
      } finally {
        setSearching(false);
      }
    }, 200);
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [term, searchOpen]);

  const submit = async () => {
    if (!toStore) {
      setErr("請選擇接收店");
      return;
    }
    if (sameStoreOnly && toStore !== currentPickupStoreId) {
      setErr("貨還沒到店：僅可同店換客人，不可轉到別店");
      return;
    }

    // 蒐集勾選的品項與數量
    const chosen: { item: TransferItem; qty: number }[] = [];
    for (const it of items) {
      const p = picks[it.id];
      if (!p?.checked) continue;
      const qtyN = Number(p.qty);
      if (!Number.isFinite(qtyN) || qtyN <= 0) {
        setErr(`「${itemLabel(it)}」轉移數量需大於 0`);
        return;
      }
      if (qtyN > it.qty) {
        setErr(`「${itemLabel(it)}」轉移數量不可超過 ${it.qty}`);
        return;
      }
      chosen.push({ item: it, qty: qtyN });
    }
    if (chosen.length === 0) {
      setErr("請至少選擇一項要轉移的品項");
      return;
    }

    // 整單轉出 = 全部品項都勾選且都轉全量；否則走部分轉出。
    // partialOnly（來源單已有取走品項）時全選全量也走部分轉出
    const isFull =
      !partialOnly &&
      chosen.length === items.length &&
      chosen.every((c) => c.qty === c.item.qty);

    if (toStore === currentPickupStoreId) {
      if (!confirm("接收店與原店相同（同店換客人）。確定繼續？")) return;
    }
    // 空中轉僅對跨店有意義；同店換客人沒有物理配送、一律非空中轉
    const airFlag = isAir && toStore !== currentPickupStoreId;
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: { user } } = await sb.auth.getUser();
      let newId: number;
      if (isFull) {
        const { data, error: e } = await sb.rpc("rpc_transfer_order_to_store", {
          p_order_id: orderId,
          p_to_pickup_store_id: toStore,
          p_to_member_id: toMember === "internal" ? null : toMember,
          p_to_channel_id: null,
          p_operator: user?.id,
          p_reason: reason || null,
          p_is_air_transfer: airFlag,
        });
        if (e) throw new Error(e.message);
        newId = data as number;
      } else {
        // 依 sku 彙總轉移數量（RPC 以 sku_id 拆單）
        const bySku = new Map<number, number>();
        for (const c of chosen) {
          bySku.set(c.item.sku_id, (bySku.get(c.item.sku_id) ?? 0) + c.qty);
        }
        const pItems = Array.from(bySku, ([sku_id, qty]) => ({ sku_id, qty }));
        const { data, error: e } = await sb.rpc("rpc_transfer_order_partial", {
          p_order_id: orderId,
          p_to_pickup_store_id: toStore,
          p_to_member_id: toMember === "internal" ? null : toMember,
          p_to_channel_id: null,
          p_operator: user?.id,
          p_reason: reason || null,
          p_items: pItems,
          p_is_air_transfer: airFlag,
        });
        if (e) throw new Error(e.message);
        newId = data as number;
      }
      onSubmitted(newId);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const chosenCount = items.filter((it) => picks[it.id]?.checked).length;
  const allChosen = items.length > 0 && chosenCount === items.length;
  // 「這裡選不到總倉」之後才指路，而且只在那顆鈕確定在畫面上時才指。
  // canReturnToHq=false 可能是「貨還沒到店」、也可能是互助單（走「↩ 退單（已收貨）」、不經總倉），
  // 光憑這個 prop 分不出是哪一種，兩者該走的出口又不同——寧可不講，也不要講一句只對一半的話
  const hqExitHint = canReturnToHq
    ? "貨要退回總倉請關掉這個視窗，改按「↩ 退貨回總倉」。"
    : null;

  return (
    <Modal open={open} onClose={onClose} title={`轉給別人 ${orderNo}`} maxWidth="max-w-lg">
      <div className="space-y-3 p-4 text-sm">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        <div className="rounded-md bg-zinc-50 p-2 text-xs text-zinc-600 dark:bg-zinc-900 dark:text-zinc-400">
          原訂單：{currentMemberLabel}（取貨店：
          {stores.find((s) => s.id === currentPickupStoreId)?.name ?? `#${currentPickupStoreId}`}）
        </div>

        {sameStoreOnly && (
          <div className="rounded-md border border-amber-200 bg-amber-50 p-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300">
            貨還沒到店：目前僅可<span className="font-medium">同店換客人</span>
            （轉給本店其他會員，不影響總倉派貨）。要轉到別店請等分店收貨後再轉。
          </div>
        )}

        <label className="flex flex-col gap-1">
          <span className="text-zinc-500">接收店</span>
          <select
            value={toStore}
            disabled={sameStoreOnly}
            onChange={(e) => {
              const v = e.target.value;
              setToStore(v === "" ? "" : Number(v));
              setToMember("internal");
              setPickedMember(null);
              setTerm("");
              setResults([]);
              setSearchOpen(false);
            }}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 請選擇 —</option>
            {(sameStoreOnly ? stores.filter((s) => s.id === currentPickupStoreId) : stores).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.code})
              </option>
            ))}
          </select>
        </label>

        {/* 接收店只從 stores 撈，總倉是 locations 的 central_warehouse、根本不在這個清單裡。
            店員想「退回總倉」時會挑到同名的分店，結果把客人的單轉進該店內部帳號、客人的訂單就消失了 */}
        <p className="text-xs text-amber-700 dark:text-amber-400">
          {sameStoreOnly ? (
            <>
              貨還沒到店，這裡只能<span className="font-medium">同店換客人</span>（換另一位客人來拿）
            </>
          ) : (
            <>
              這裡只能轉給<span className="font-medium">分店</span>：換一位客人拿，或轉給其他店
            </>
          )}
          ，<span className="font-medium">選不到總倉</span>。{hqExitHint}
        </p>

        {toStore !== "" && (
          <div className="flex flex-col gap-1">
            <span className="text-zinc-500">接收人</span>
            <div className="relative" ref={searchWrapRef}>
              <input
                value={
                  toMember === "internal" && !term && !searchOpen
                    ? "— 掛到接收店店長（內部 member）—"
                    : pickedMember
                      ? `${pickedMember.name ?? "—"} (${pickedMember.member_no})`
                      : term
                }
                onFocus={() => setSearchOpen(true)}
                onChange={(e) => {
                  if (pickedMember || toMember !== "internal") {
                    setPickedMember(null);
                    setToMember("internal");
                  }
                  setTerm(e.target.value);
                  setSearchOpen(true);
                }}
                placeholder="搜尋 會員編號 / 姓名 / 手機"
                className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1 pr-8 dark:border-zinc-700 dark:bg-zinc-800"
              />
              <SearchSpinner active={searching} />
              {searchOpen && (
                <div className="absolute left-0 right-0 top-full z-20 mt-1 max-h-80 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800">
                  <SpinButton
                    type="button"
                    onClick={() => {
                      setToMember("internal");
                      setPickedMember(null);
                      setTerm("");
                      setSearchOpen(false);
                    }}
                    className={`block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 dark:hover:bg-zinc-700 ${
                      toMember === "internal" ? "bg-zinc-50 dark:bg-zinc-900" : ""
                    }`}
                  >
                    — 掛到接收店店長（內部 member）—
                  </SpinButton>
                  {results.length > 0 && (
                    <div className="border-t border-zinc-100 dark:border-zinc-700">
                      <div className="px-2 py-1 text-xs font-medium text-zinc-400">會員</div>
                      {results.map((m) => (
                        <SpinButton
                          key={m.id}
                          type="button"
                          onClick={() => {
                            setToMember(m.id);
                            setPickedMember(m);
                            setTerm("");
                            setSearchOpen(false);
                          }}
                          className="block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 dark:hover:bg-zinc-700"
                        >
                          <span className="font-medium">{m.name ?? "—"}</span>
                          {m.admin_note && (
                            <span className="ml-1 rounded bg-amber-100 px-1 text-[9px] text-amber-800">
                              🔒 {m.admin_note}
                            </span>
                          )}
                          <span className="ml-2 text-zinc-500">
                            {m.member_no} · {m.phone ?? "—"}
                          </span>
                          {m.no_new_order && (
                            <span className="ml-2 font-medium text-red-600">🚫 黑名單禁加單</span>
                          )}
                          {m.home_store_name && (
                            <span className="ml-2 text-[11px] text-zinc-400">
                              主店：{m.home_store_name}
                            </span>
                          )}
                        </SpinButton>
                      ))}
                    </div>
                  )}
                  {term.length > 0 && results.length === 0 && (
                    <div className="border-t border-zinc-100 px-3 py-2 text-xs text-zinc-400 dark:border-zinc-700">
                      無符合會員
                    </div>
                  )}
                </div>
              )}
            </div>
            <span className="text-[11px] text-zinc-400">
              不選 = 自動建 / 用 store_internal member（適用：店長收下、內部處理）
            </span>
          </div>
        )}

        <div className="flex flex-col gap-1">
          <div className="flex items-center justify-between">
            <span className="text-zinc-500">轉移品項</span>
            {items.length > 1 && (
              <SpinButton
                type="button"
                onClick={() => {
                  setPicks((prev) => {
                    const next = { ...prev };
                    for (const it of items) {
                      next[it.id] = {
                        checked: !allChosen,
                        qty: next[it.id]?.qty ?? String(it.qty),
                      };
                    }
                    return next;
                  });
                }}
                className="text-xs text-blue-600 hover:underline"
              >
                {allChosen ? "全部取消" : "全選"}
              </SpinButton>
            )}
          </div>
          {items.length === 0 ? (
            <div className="rounded-md border border-zinc-200 p-2 text-xs text-zinc-400 dark:border-zinc-700">
              此訂單無可轉移品項
            </div>
          ) : (
            <div className="divide-y divide-zinc-100 rounded-md border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-700">
              {items.map((it) => {
                const p = picks[it.id] ?? { checked: true, qty: String(it.qty) };
                return (
                  <label
                    key={it.id}
                    className="flex items-start gap-2 px-2 py-1.5 text-sm"
                  >
                    <input
                      type="checkbox"
                      checked={p.checked}
                      onChange={(e) =>
                        setPicks((prev) => ({
                          ...prev,
                          [it.id]: { ...p, checked: e.target.checked },
                        }))
                      }
                      className="mt-1 h-4 w-4 shrink-0"
                    />
                    {/* 品名 / 選項一律完整換行顯示 — 之前用 truncate，長品名會把「選項」整段吃掉，
                        店員在轉單畫面看不到自己要轉的是哪個規格 */}
                    <span className="min-w-0 flex-1 break-words">
                      <span className="block">
                        {it.product_name ?? `SKU #${it.sku_id}`}
                      </span>
                      {it.variant_name && (
                        <span className="mt-0.5 block text-xs text-zinc-600 dark:text-zinc-300">
                          選項：{it.variant_name}
                        </span>
                      )}
                      {it.sku_code && (
                        <span className="mt-0.5 block font-mono text-[11px] text-zinc-400">
                          {it.sku_code}
                        </span>
                      )}
                    </span>
                    <input
                      type="number"
                      min={1}
                      max={it.qty}
                      step={1}
                      value={p.qty}
                      disabled={!p.checked}
                      onChange={(e) =>
                        setPicks((prev) => ({
                          ...prev,
                          [it.id]: { ...p, qty: e.target.value },
                        }))
                      }
                      className="w-16 shrink-0 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right disabled:opacity-40 dark:border-zinc-700 dark:bg-zinc-800"
                    />
                    <span className="w-10 shrink-0 text-xs text-zinc-400">/ {it.qty}</span>
                  </label>
                );
              })}
            </div>
          )}
          <span className="text-[11px] text-zinc-400">
            {partialOnly
              ? "此單已有品項取走：只會轉出勾選的未取品項，已取走的營收留在原單；未取品項全轉走後原單自動結案"
              : "預設全選全量 = 整單轉出；取消勾選或減少數量 = 部分轉出（原單保留剩餘）"}
          </span>
        </div>

        {toStore !== "" && toStore !== currentPickupStoreId && (
          <div className="flex flex-col gap-1">
            <label className="flex items-start gap-2 rounded-md border border-zinc-200 p-2 dark:border-zinc-700">
              <input
                type="checkbox"
                checked={isAir}
                onChange={(e) => setIsAir(e.target.checked)}
                className="mt-0.5 h-4 w-4"
              />
              <span className="min-w-0 flex-1">
                <span className="font-medium">空中轉（直接店對店、不經總倉）</span>
                <span className="mt-0.5 block text-[11px] text-zinc-400">
                  勾選 = 送出時就從本店出庫、建好轉移單，接收店在「收貨」頁收掉即可（不用總倉派貨），
                  月結自動一加一扣；不勾 = 經總倉中轉，總倉需確認到貨再配送
                </span>
              </span>
            </label>
          </div>
        )}

        <label className="flex flex-col gap-1">
          <span className="text-zinc-500">轉出原因</span>
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="例：客人棄單、改寄朋友店…"
            rows={2}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="flex justify-end gap-2 pt-1">
          <SpinButton
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={submit}
            disabled={busy || !toStore || chosenCount === 0}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white disabled:bg-zinc-300"
          >
            {busy ? "轉出中…" : "確認轉出"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

"use client";

// 現場銷售（門市 POS）—— 賣給沒有訂單的現場客。
//
// 與「🤝 配給客人（現貨直配）」的分工：
//   現貨直配 = 開一張「待取」單，客人之後回來取貨時才扣庫存（SpotSaleModal）。
//   現場銷售 = 客人人就在櫃台，開單與交貨是同一件事 —— 一次可買多樣，
//              送出當下就扣庫存、收錢、結案（rpc_create_walkin_sale）。
//
// 三個一定要記得的規矩（改這頁前先看 docs/PLAN-現場銷售POS.md）：
//   1. 可賣量是 **free_with_pool**（在庫 − 待客取 − 等貨中 − 在途池子），
//      不是 on_hand。別的客人正在等的貨不可以被現場客買走。
//   2. 缺貨可以在同一列勾「補庫存」，但那是**憑空生貨的入口** ——
//      只有店長以上按得動（RPC 也會再擋一次），而且每一筆都留 manual_adjust
//      紀錄（reason 以「現場銷售即時入帳」開頭）供事後稽核 / 導向盤點。
//   3. 商品清單一定要走 rpc_pos_search_products（一次撈），不要每列各打一次
//      rpc_get_spot_availability —— 那支是 per-SKU 的，一頁 30 列 = 掃 30 遍。

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { translateRpcError } from "@/lib/rpcError";
import { useRole, canSeeBranch } from "@/lib/role";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";

type StoreRow = { id: number; name: string; location_id: number | null; allowed_payment_methods: unknown };

type Product = {
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  on_hand: number;
  promised: number;
  waiting: number;
  pool_claimed: number;
  pool_arrived: number;
  free: number;
  free_with_pool: number;
  retail_price: number | null;
  branch_price: number | null;
  suggest_price: number;
};

type CartLine = {
  sku_id: number;
  label: string;
  sku_code: string | null;
  qty: number;
  unit_price: number;
  /** 這一列要在結帳當下補幾件庫存（0 = 不補） */
  addStock: number;
  /** 下架商品時的可賣量快照，用來畫「超賣」警告 */
  sellable: number;
  on_hand: number;
  promised: number;
  waiting: number;
};

type MemberHit = {
  id: number;
  member_no: string;
  name: string;
  phone: string | null;
  home_store_name: string | null;
  no_new_order: boolean;
};

// 付款方式：值對齊 stores.allowed_payment_methods 的 enum，寫進
// customer_orders.payment_method。⛔ 不要順手去寫 payment_status='paid' ——
// 全站有 4 個地方把 'paid' 當「這張單不用再處理」在用（會員端未結金額、
// 取貨頁的儲值金判斷…），現場銷售開始寫就會靜默改變那些行為。
// 「收到錢了」用既有語意表達就好：品項 picked_up → 未結金額自動是 0。
const PAY_LABEL: Record<string, string> = {
  cash: "現金",
  transfer: "轉帳",
  credit_card: "刷卡",
  linepay: "LINE Pay",
  wallet: "儲值金",
};
const PAY_FALLBACK = ["cash", "transfer"];

const num = (v: unknown) => (v == null ? 0 : Number(v));
const numOrNull = (v: unknown) => (v == null ? null : Number(v));

function skuLabel(p: Pick<Product, "product_name" | "variant_name">): string {
  const a = (p.product_name ?? "").trim();
  const b = (p.variant_name ?? "").trim();
  if (a && b && a !== b) return `${a} / ${b}`;
  return a || b || "—";
}

export default function PosPage() {
  const role = useRole();
  const showBranchPrice = canSeeBranch(role);
  // 補庫存是憑空生貨的入口 —— 角色清單對齊 rpc_create_walkin_sale 的 gate
  // （'' 是沒有顯式 role 的 legacy / dev admin，漏掉會把舊帳號全擋在外面）。
  const canAddStock =
    role !== null && ["owner", "admin", "hq_manager", "store_manager", ""].includes(role);

  const [stores, setStores] = useState<StoreRow[]>([]);
  const [pickedStoreId, setPickedStoreId] = useState<string>("");
  const branchStoreId = useUserBranchStoreId(stores);
  // 分店帳號一律鎖自己店：用**衍生值**而不是在 effect 裡 setState
  // （react-hooks/set-state-in-effect：effect 裡同步 setState 會 cascading render）
  const storeId = branchStoreId != null ? String(branchStoreId) : pickedStoreId;
  useDefaultStoreFromUser(stores, pickedStoreId, setPickedStoreId, branchStoreId == null);

  const [term, setTerm] = useState("");
  const [products, setProducts] = useState<Product[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);

  const [cart, setCart] = useState<CartLine[]>([]);
  const [customerName, setCustomerName] = useState("");
  const [member, setMember] = useState<MemberHit | null>(null);
  const [memberOpen, setMemberOpen] = useState(false);
  const [keepAsMember, setKeepAsMember] = useState(false);
  const [keepPhone, setKeepPhone] = useState("");
  const [payPick, setPayPick] = useState("cash");
  const [discount, setDiscount] = useState<number | "">("");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<{ order_id: number; order_no: string; total: number } | null>(null);

  const store = useMemo(() => stores.find((s) => String(s.id) === storeId) ?? null, [stores, storeId]);

  const payOptions = useMemo(() => {
    const raw = store?.allowed_payment_methods;
    const list = Array.isArray(raw) ? raw.filter((x): x is string => typeof x === "string") : [];
    // 門市沒設就給現金 + 轉帳；現金一律排第一（Alex 決議：預設現金）
    const opts = list.length > 0 ? list : PAY_FALLBACK;
    return opts.includes("cash") ? ["cash", ...opts.filter((o) => o !== "cash")] : opts;
  }, [store]);
  // 選到的方式不在這家店的清單裡（換店、或門市改過設定）就退回第一個
  // （＝現金，見 payOptions 的排序）。同樣用衍生值避免 effect 裡 setState。
  const payment = payOptions.includes(payPick) ? payPick : (payOptions[0] ?? "cash");

  // ---- 門市清單 ----
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: e } = await getSupabase()
        .from("stores")
        .select("id, name, location_id, allowed_payment_methods")
        .eq("is_active", true)
        .order("name");
      if (cancelled) return;
      if (e) setError(e.message);
      else setStores((data as StoreRow[]) ?? []);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // ---- 商品搜尋（debounce 250ms）----
  useEffect(() => {
    if (!storeId) return;
    let cancelled = false;
    const t = setTimeout(async () => {
      setSearching(true);
      const { data, error: e } = await getSupabase().rpc("rpc_pos_search_products", {
        p_store_id: Number(storeId),
        p_term: term.trim() || null,
        p_limit: 40,
      });
      if (cancelled) return;
      if (e) setError(translateRpcError(e));
      else {
        setProducts(
          ((data as Record<string, unknown>[]) ?? []).map((r) => ({
            sku_id: num(r.sku_id),
            sku_code: (r.sku_code as string) ?? null,
            product_name: (r.product_name as string) ?? null,
            variant_name: (r.variant_name as string) ?? null,
            on_hand: num(r.on_hand),
            promised: num(r.promised),
            waiting: num(r.waiting),
            pool_claimed: num(r.pool_claimed),
            pool_arrived: num(r.pool_arrived),
            free: num(r.free),
            free_with_pool: num(r.free_with_pool),
            retail_price: numOrNull(r.retail_price),
            branch_price: numOrNull(r.branch_price),
            suggest_price: num(r.suggest_price),
          })),
        );
      }
      setSearching(false);
    }, 250);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [storeId, term, reloadTick]);

  // 換店就把購物車清掉：可賣量、售價都是綁在店上的，留著只會結出錯的帳。
  // 放在下拉的 onChange（而不是 effect）—— 分店帳號的 storeId 是鎖死的衍生值，
  // 只有 HQ 換得動，這裡就是唯一的變更點。
  const changeStore = useCallback((v: string) => {
    setPickedStoreId(v);
    setCart([]);
    setDone(null);
  }, []);

  // ---- 會員搜尋 ----
  const [mTerm, setMTerm] = useState("");
  const [mHits, setMHits] = useState<MemberHit[]>([]);
  const [mSearching, setMSearching] = useState(false);
  useEffect(() => {
    const qq = mTerm.trim();
    if (!qq || !memberOpen) return;
    let cancelled = false;
    const t = setTimeout(async () => {
      setMSearching(true);
      const { data } = await getSupabase().rpc("rpc_search_members", { p_term: qq, p_limit: 8 });
      if (!cancelled) {
        setMHits((data as MemberHit[]) ?? []);
        setMSearching(false);
      }
    }, 250);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [mTerm, memberOpen]);

  // ---- 購物車操作 ----
  const addToCart = useCallback((p: Product) => {
    setDone(null);
    setCart((prev) => {
      const i = prev.findIndex((l) => l.sku_id === p.sku_id);
      if (i >= 0) {
        const next = [...prev];
        next[i] = { ...next[i], qty: next[i].qty + 1 };
        return next;
      }
      return [
        ...prev,
        {
          sku_id: p.sku_id,
          label: skuLabel(p),
          sku_code: p.sku_code,
          qty: 1,
          unit_price: p.suggest_price,
          addStock: 0,
          sellable: p.free_with_pool,
          on_hand: p.on_hand,
          promised: p.promised,
          waiting: p.waiting,
        },
      ];
    });
  }, []);

  const patchLine = useCallback((skuId: number, patch: Partial<CartLine>) => {
    setCart((prev) => prev.map((l) => (l.sku_id === skuId ? { ...l, ...patch } : l)));
  }, []);
  const removeLine = useCallback((skuId: number) => {
    setCart((prev) => prev.filter((l) => l.sku_id !== skuId));
  }, []);

  const itemsTotal = cart.reduce((s, l) => s + l.qty * l.unit_price, 0);
  const discNum = typeof discount === "number" ? discount : 0;
  const total = Math.max(0, itemsTotal - discNum);
  const shortLines = cart.filter((l) => l.qty > l.sellable + l.addStock);
  const zeroPriceLines = cart.filter((l) => l.unit_price <= 0);
  const addTotal = cart.reduce((s, l) => s + l.addStock, 0);
  const canCheckout =
    !busy &&
    !!storeId &&
    cart.length > 0 &&
    shortLines.length === 0 &&
    zeroPriceLines.length === 0 &&
    (member != null || customerName.trim().length > 0);

  async function checkout() {
    if (!canCheckout) return;
    const who = member?.name ?? customerName.trim();
    if (
      !confirm(
        `向「${who}」收 $${total}（${cart.length} 項 / ${cart.reduce((s, l) => s + l.qty, 0)} 件）？\n\n` +
          `送出後**立刻扣庫存並結案**（不是待取）。\n` +
          (addTotal > 0 ? `其中會先補 ${addTotal} 件庫存進帳。\n` : "") +
          `打錯可在訂單頁「撤銷取貨」還原。`,
      )
    )
      return;
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      // 勾了「順便建會員」→ 先開會員，再把 member_id 帶進結帳。
      // 撞號 / 停用之類的錯誤由 rpc_upsert_member 自己吐（20260831000050 之後
      // 它會把死號讓出來、活人回點得出名字的訊息），這裡不要自己判。
      let memberId = member?.id ?? null;
      if (!member && keepAsMember) {
        const { data: mid, error: me } = await sb.rpc("rpc_upsert_member", {
          p_id: null,
          p_member_no: null,
          p_phone: keepPhone.trim() || null,
          p_name: customerName.trim(),
          p_gender: null,
          p_birthday: null,
          p_email: null,
          p_tier_id: null,
          p_home_store_id: Number(storeId),
          p_status: "active",
          p_notes: "門市現場銷售建檔",
        });
        if (me) throw new Error(translateRpcError(me));
        memberId = Number(mid);
      }

      const { data: res, error: e } = await sb.rpc("rpc_create_walkin_sale", {
        p_store_id: Number(storeId),
        p_lines: cart.map((l) => ({
          sku_id: l.sku_id,
          qty: l.qty,
          unit_price: l.unit_price,
          add_stock_qty: l.addStock,
        })),
        p_operator: operator,
        p_member_id: memberId,
        p_customer_name: member ? null : customerName.trim(),
        p_payment_method: payment,
        p_discount_amount: discNum,
        p_notes: notes.trim() || null,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as { order_id?: number; order_no?: string; total?: number };
      setDone({
        order_id: num(r.order_id),
        order_no: r.order_no ?? "",
        total: num(r.total),
      });
      // 收乾淨，準備下一位客人；商品清單重抓（庫存已經變了）
      setCart([]);
      setCustomerName("");
      setMember(null);
      setKeepAsMember(false);
      setKeepPhone("");
      setDiscount("");
      setNotes("");
      setReloadTick((t) => t + 1);
      // 小票另開分頁，收銀畫面留在原地繼續結下一單
      window.open(`/pos/receipt?order=${num(r.order_id)}`, "_blank", "noopener");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <h1 className="text-lg font-semibold">🛒 現場銷售</h1>
        <span className="text-xs text-zinc-500">
          賣給沒有訂單的現場客：送出當下扣庫存、收錢、結案
        </span>
        <Link href="/pos/topups" className="text-xs text-zinc-500 underline">
          🧾 補庫存紀錄
        </Link>
        <span className="flex-1" />
        {branchStoreId == null ? (
          <select
            value={storeId}
            onChange={(e) => changeStore(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">選擇門市…</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        ) : (
          <span className="rounded-md border border-zinc-200 px-3 py-1.5 text-sm dark:border-zinc-800">
            {store?.name ?? "—"}
          </span>
        )}
      </div>

      {error && (
        <div className="whitespace-pre-wrap rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {done && (
        <div className="flex flex-wrap items-center gap-2 rounded-md border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200">
          <span>
            ✅ 已結帳 <b>{done.order_no}</b>（收 ${done.total}）
          </span>
          <Link href={`/pos/receipt?order=${done.order_id}`} target="_blank" className="underline">
            🧾 重印小票
          </Link>
          <Link href={`/orders?id=${done.order_id}`} className="underline">
            看訂單
          </Link>
        </div>
      )}

      {!storeId ? (
        <div className="rounded-md border border-zinc-200 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800">
          請先選擇門市
        </div>
      ) : (
        <div className="grid gap-3 lg:grid-cols-[1fr_420px]">
          {/* ───────── 左：商品 ───────── */}
          <div className="rounded-lg border border-zinc-200 dark:border-zinc-800">
            <div className="flex items-center gap-2 border-b border-zinc-200 p-2 dark:border-zinc-800">
              <input
                value={term}
                onChange={(e) => setTerm(e.target.value)}
                placeholder="🔍 商品名 / 規格 / SKU 編號 / 條碼"
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              />
              <SearchSpinner active={searching} />
            </div>
            <div className="max-h-[62vh] overflow-y-auto">
              {products === null ? (
                <div className="p-4 text-sm text-zinc-500">載入中…</div>
              ) : products.length === 0 ? (
                <div className="p-4 text-sm text-zinc-500">
                  {term.trim() ? "找不到商品" : "這家店目前沒有在庫商品 —— 搜尋商品名可以找出缺貨品項"}
                </div>
              ) : (
                <ul className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {products.map((p) => {
                    const sellable = p.free_with_pool;
                    const inCart = cart.find((l) => l.sku_id === p.sku_id);
                    return (
                      <li key={p.sku_id}>
                        <SpinButton
                          onClick={() => addToCart(p)}
                          className="block w-full px-3 py-2 text-left hover:bg-zinc-50 dark:hover:bg-zinc-800/60"
                        >
                          <div className="flex items-baseline gap-2">
                            <span className="min-w-0 flex-1 break-words text-sm font-medium">
                              {skuLabel(p)}
                            </span>
                            <span className="whitespace-nowrap text-sm font-semibold">
                              {p.suggest_price > 0 ? `$${p.suggest_price}` : "未設價"}
                            </span>
                          </div>
                          <div className="mt-0.5 flex flex-wrap items-center gap-x-2 text-[11px] text-zinc-500">
                            {p.sku_code && <span className="font-mono">{p.sku_code}</span>}
                            <span
                              className={
                                sellable > 0
                                  ? "font-semibold text-emerald-700 dark:text-emerald-400"
                                  : "font-semibold text-rose-600 dark:text-rose-400"
                              }
                            >
                              可賣 {sellable}
                            </span>
                            <span>
                              在庫 {p.on_hand}
                              {p.promised > 0 && ` · 待客取 ${p.promised}`}
                              {p.waiting > 0 && ` · 等貨中 ${p.waiting}`}
                              {p.pool_claimed > 0 && ` · 內部單 ${p.pool_claimed}`}
                            </span>
                            {showBranchPrice && p.branch_price != null && (
                              <span className="rounded bg-amber-100 px-1 font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                                分店 ${p.branch_price}
                              </span>
                            )}
                            {inCart && (
                              <span className="rounded bg-sky-100 px-1 font-semibold text-sky-800 dark:bg-sky-950 dark:text-sky-300">
                                車內 {inCart.qty}
                              </span>
                            )}
                          </div>
                        </SpinButton>
                      </li>
                    );
                  })}
                </ul>
              )}
            </div>
          </div>

          {/* ───────── 右：結帳 ───────── */}
          <div className="space-y-3">
            {/* 客人 */}
            <div className="rounded-lg border border-zinc-200 p-3 dark:border-zinc-800">
              <div className="mb-1 text-xs text-zinc-500">客人</div>
              {member ? (
                <div className="flex items-center gap-2 rounded-md border border-violet-300 bg-violet-50 px-3 py-2 text-sm dark:border-violet-800 dark:bg-violet-950/40">
                  <span className="min-w-0 flex-1">
                    <span className="font-medium">{member.name}</span>
                    <span className="ml-1.5 text-xs text-zinc-500">
                      {member.member_no}
                      {member.phone ? ` · ${member.phone}` : ""}
                    </span>
                  </span>
                  <SpinButton
                    onClick={() => setMember(null)}
                    className="shrink-0 text-xs text-zinc-500 underline"
                  >
                    改現場客
                  </SpinButton>
                </div>
              ) : (
                <>
                  <div className="flex gap-2">
                    <input
                      value={customerName}
                      onChange={(e) => setCustomerName(e.target.value)}
                      placeholder="客人名字（必填，例：王小姐）"
                      className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                    />
                    <SpinButton
                      onClick={() => setMemberOpen(true)}
                      className="shrink-0 rounded-md border border-zinc-300 px-3 py-2 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      選會員
                    </SpinButton>
                  </div>
                  {/* Alex 決議：預設不留成會員，但要能選擇留 */}
                  <label className="mt-2 flex items-center gap-2 text-xs text-zinc-600 dark:text-zinc-400">
                    <input
                      type="checkbox"
                      checked={keepAsMember}
                      onChange={(e) => setKeepAsMember(e.target.checked)}
                    />
                    順便建立為會員（不勾＝只留名字在這張單上）
                  </label>
                  {keepAsMember && (
                    <input
                      value={keepPhone}
                      onChange={(e) => setKeepPhone(e.target.value)}
                      placeholder="手機（選填，之後才能綁 LINE / 查訂單）"
                      className="mt-1.5 w-full rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                    />
                  )}
                </>
              )}
            </div>

            {/* 購物車 */}
            <div className="rounded-lg border border-zinc-200 dark:border-zinc-800">
              <div className="border-b border-zinc-200 px-3 py-2 text-xs text-zinc-500 dark:border-zinc-800">
                購物車（{cart.length} 項）
              </div>
              {cart.length === 0 ? (
                <div className="p-4 text-center text-sm text-zinc-500">左邊點商品加入</div>
              ) : (
                <ul className="max-h-[38vh] divide-y divide-zinc-100 overflow-y-auto dark:divide-zinc-800">
                  {cart.map((l) => {
                    const short = Math.max(0, l.qty - l.sellable);
                    const stillShort = Math.max(0, l.qty - l.sellable - l.addStock);
                    return (
                      <li key={l.sku_id} className="px-3 py-2 text-sm">
                        <div className="flex items-baseline gap-2">
                          <span className="min-w-0 flex-1 break-words font-medium">{l.label}</span>
                          <SpinButton
                            onClick={() => removeLine(l.sku_id)}
                            className="shrink-0 text-xs text-zinc-400 hover:text-rose-600"
                            aria-label="移除"
                          >
                            ✕
                          </SpinButton>
                        </div>
                        <div className="mt-1 flex items-center gap-2">
                          <input
                            type="number"
                            min={1}
                            value={l.qty}
                            onChange={(e) => {
                              const v = Math.floor(Number(e.target.value));
                              patchLine(l.sku_id, { qty: Number.isFinite(v) ? Math.max(1, v) : 1 });
                            }}
                            className="w-16 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                          />
                          <span className="text-xs text-zinc-400">×</span>
                          <input
                            type="number"
                            min={0}
                            value={l.unit_price}
                            onChange={(e) => {
                              const v = Number(e.target.value);
                              patchLine(l.sku_id, { unit_price: Number.isFinite(v) ? Math.max(0, v) : 0 });
                            }}
                            className="w-24 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                          />
                          <span className="flex-1 text-right font-semibold tabular-nums">
                            ${l.qty * l.unit_price}
                          </span>
                        </div>
                        {l.unit_price <= 0 && (
                          <div className="mt-1 text-[11px] font-semibold text-rose-600 dark:text-rose-400">
                            單價不可為 0（$0 的貨等於白送）
                          </div>
                        )}
                        {short > 0 && (
                          <div className="mt-1 rounded border border-amber-200 bg-amber-50 px-2 py-1 text-[11px] text-amber-800 dark:border-amber-900 dark:bg-amber-950/50 dark:text-amber-300">
                            <div>
                              可賣 <b>{l.sellable}</b> 件（在庫 {l.on_hand}
                              {l.promised > 0 && `、待客取 ${l.promised}`}
                              {l.waiting > 0 && `、等貨中 ${l.waiting}`}），這一列要 {l.qty} 件。
                            </div>
                            {canAddStock ? (
                              <label className="mt-1 flex items-center gap-1.5">
                                <input
                                  type="checkbox"
                                  checked={l.addStock > 0}
                                  onChange={(e) =>
                                    patchLine(l.sku_id, { addStock: e.target.checked ? short : 0 })
                                  }
                                />
                                架上有貨 → 先補
                                <input
                                  type="number"
                                  min={0}
                                  value={l.addStock}
                                  onChange={(e) => {
                                    const v = Math.floor(Number(e.target.value));
                                    patchLine(l.sku_id, { addStock: Number.isFinite(v) ? Math.max(0, v) : 0 });
                                  }}
                                  className="w-14 rounded border border-amber-300 bg-white px-1 py-0.5 text-right tabular-nums dark:border-amber-800 dark:bg-zinc-800"
                                />
                                件庫存
                              </label>
                            ) : (
                              <div className="mt-1">
                                架上真的有貨請找店長補庫存，或先到「庫存總覽」入帳。
                              </div>
                            )}
                            {stillShort > 0 && (
                              <div className="mt-1 font-semibold text-rose-700 dark:text-rose-400">
                                還差 {stillShort} 件，結不了帳。
                              </div>
                            )}
                          </div>
                        )}
                      </li>
                    );
                  })}
                </ul>
              )}
            </div>

            {/* 結帳 */}
            <div className="space-y-2 rounded-lg border border-zinc-200 p-3 dark:border-zinc-800">
              <div className="flex items-center justify-between text-sm">
                <span className="text-zinc-500">小計</span>
                <span className="tabular-nums">${itemsTotal}</span>
              </div>
              <div className="flex items-center justify-between text-sm">
                <span className="text-zinc-500">整單折扣</span>
                <input
                  type="number"
                  min={0}
                  value={discount}
                  onChange={(e) => {
                    const v = Number(e.target.value);
                    setDiscount(e.target.value === "" ? "" : Number.isFinite(v) ? Math.max(0, v) : 0);
                  }}
                  placeholder="0"
                  className="w-24 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                />
              </div>
              <div className="flex items-center justify-between border-t border-zinc-200 pt-2 dark:border-zinc-800">
                <span className="text-sm text-zinc-500">應收</span>
                <span className="text-xl font-bold tabular-nums">${total}</span>
              </div>
              <div className="flex flex-wrap gap-1.5">
                {payOptions.map((o) => (
                  <SpinButton
                    key={o}
                    onClick={() => setPayPick(o)}
                    className={`rounded-md border px-3 py-1.5 text-xs ${
                      payment === o
                        ? "border-sky-500 bg-sky-50 font-semibold text-sky-800 dark:bg-sky-950 dark:text-sky-300"
                        : "border-zinc-300 dark:border-zinc-700"
                    }`}
                  >
                    {PAY_LABEL[o] ?? o}
                  </SpinButton>
                ))}
              </div>
              <input
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="備註（選填）"
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              />
              {addTotal > 0 && (
                <div className="rounded border border-amber-200 bg-amber-50 px-2 py-1.5 text-[11px] text-amber-800 dark:border-amber-900 dark:bg-amber-950/50 dark:text-amber-300">
                  這筆會先補 <b>{addTotal}</b> 件庫存進帳（留下「現場銷售即時入帳」紀錄）。
                  常常要補代表帳跟實體長期對不上，記得排一次盤點。
                </div>
              )}
              <SpinButton
                onClick={checkout}
                disabled={!canCheckout}
                className="w-full rounded-md bg-sky-600 px-4 py-2.5 font-semibold text-white hover:bg-sky-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
              >
                {busy
                  ? "結帳中…"
                  : cart.length === 0
                    ? "購物車是空的"
                    : !member && !customerName.trim()
                      ? "請先填客人名字"
                      : `結帳 $${total}`}
              </SpinButton>
              <div className="text-center text-[11px] text-zinc-400">
                送出＝當場交貨並扣庫存（不是待取）。打錯可在訂單頁「撤銷取貨」。
              </div>
            </div>
          </div>
        </div>
      )}

      <Modal open={memberOpen} onClose={() => setMemberOpen(false)} title="選會員" maxWidth="max-w-md">
        <div className="space-y-2 text-sm">
          <input
            value={mTerm}
            onChange={(e) => setMTerm(e.target.value)}
            placeholder="🔍 姓名 / 電話 / 會員編號…"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          />
          {mSearching && mHits.length === 0 && <div className="text-xs text-zinc-500">搜尋中…</div>}
          <div className="max-h-72 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-700">
            {mHits.map((m) => (
              <SpinButton
                key={m.id}
                onClick={() => {
                  setMember(m);
                  setMemberOpen(false);
                  setMTerm("");
                  setKeepAsMember(false);
                }}
                disabled={m.no_new_order}
                title={m.no_new_order ? "此會員已被標記為不可新增訂單" : undefined}
                className="block w-full border-b border-zinc-100 px-3 py-2 text-left last:border-b-0 hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
              >
                <span className="font-medium">{m.name}</span>
                <span className="ml-1.5 text-xs text-zinc-500">
                  {m.member_no}
                  {m.phone ? ` · ${m.phone}` : ""}
                  {m.home_store_name ? ` · ${m.home_store_name}` : ""}
                </span>
              </SpinButton>
            ))}
          </div>
          <div className="text-[11px] text-zinc-400">
            不選會員也可以結帳 —— 訂單會掛在該店的「現場客」帳號下，名字記在單上。
          </div>
        </div>
      </Modal>
    </div>
  );
}

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
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { translateRpcError } from "@/lib/rpcError";
import { useRole, canSeeBranch } from "@/lib/role";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";
import {
  PosReceipt,
  PosReceiptPrintStyle,
  type ReceiptData,
} from "@/components/PosReceipt";

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

// ── 觸控尺寸（這頁是櫃台平板在用，手指點得到才算數）──────────────────
// 一律 ≥44px（Apple HIG 的最小觸控目標），主要動作再放大。
// 改樣式時不要把這些縮回桌機尺寸 —— 店員是站著用手指點，不是坐著用滑鼠。
const INPUT = "h-12 rounded-lg border border-zinc-300 bg-white px-4 text-base dark:border-zinc-700 dark:bg-zinc-800";
const BTN_SM = "h-11 rounded-lg border border-zinc-300 px-4 text-sm font-medium hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800";
const ICON_BTN = "grid size-11 shrink-0 place-items-center rounded-lg border border-zinc-300 text-xl font-bold leading-none select-none dark:border-zinc-700";

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
  const [keepAsMember, setKeepAsMember] = useState(false);
  const [keepPhone, setKeepPhone] = useState("");
  const [payPick, setPayPick] = useState("cash");
  const [discount, setDiscount] = useState<number | "">("");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // 結完帳的小白單資料 —— 就地列印用（不換頁、不開新分頁）
  const [receipt, setReceipt] = useState<ReceiptData | null>(null);

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
    setReceipt(null);
  }, []);

  // ---- 會員搜尋：直接掛在「客人」輸入框上 ----
  // 店員打的字有兩種用途，而且**不用先決定是哪一種**：
  //   打完就結帳 → 那串字就是現場客的名字（存 nickname_snapshot）
  //   下面有跳出人 → 點一下就綁成該會員的訂單
  // 所以不做「選會員」彈窗（多一次點擊、櫃台前最不需要的東西）。
  const [mHits, setMHits] = useState<MemberHit[]>([]);
  const [mSearching, setMSearching] = useState(false);
  const [hideHits, setHideHits] = useState(false);
  useEffect(() => {
    const qq = customerName.trim();
    // 已經綁了會員就不用再搜；1 個字搜出來的量沒有意義，2 個字起跳
    if (member || qq.length < 2) return;
    let cancelled = false;
    const t = setTimeout(async () => {
      setMSearching(true);
      const { data } = await getSupabase().rpc("rpc_search_members", { p_term: qq, p_limit: 6 });
      if (!cancelled) {
        setMHits((data as MemberHit[]) ?? []);
        setMSearching(false);
      }
    }, 250);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [customerName, member]);

  // 有輸入、還沒綁人、也沒被使用者關掉時才畫下拉
  // （不在 effect 裡清 mHits —— 那會踩 react-hooks/set-state-in-effect）
  const showHits = !member && !hideHits && customerName.trim().length >= 2;

  // ---- 購物車操作 ----
  const addToCart = useCallback((p: Product) => {
    setReceipt(null);
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

      // 小白單就地列印：資料在手上（購物車 + RPC 回的單號），不用換頁也不用
      // 再查一次 DB。之前開新分頁到 /pos/receipt 會 404 —— admin 是
      // `output: "export"` + `trailingSlash: true` 的靜態站，路徑要帶尾斜線，
      // 而且新分頁還會被瀏覽器的彈窗阻擋擋掉。
      setReceipt({
        storeName: store?.name ?? "",
        orderNo: r.order_no ?? "",
        customerName: who,
        memberNo: member?.member_no ?? null,
        memberPhone: member?.phone ?? null,
        createdAt: new Date().toISOString(),
        paymentMethod: payment,
        discount: discNum,
        lines: cart.map((l) => ({ label: l.label, qty: l.qty, unitPrice: l.unit_price })),
      });

      // 收乾淨，準備下一位客人；商品清單重抓（庫存已經變了）
      setCart([]);
      setCustomerName("");
      setMember(null);
      setKeepAsMember(false);
      setKeepPhone("");
      setDiscount("");
      setNotes("");
      setHideHits(false);
      setReloadTick((t) => t + 1);
      // 等小白單畫進 DOM 再叫列印（同 /pickup/print-list 的作法）
      setTimeout(() => window.print(), 300);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const cartQty = cart.reduce((s, l) => s + l.qty, 0);

  return (
    <>
      <PosReceiptPrintStyle />
      {/* 小白單：畫面上不顯示，只在列印時出現（同一個畫面直接跳列印，不換頁） */}
      {receipt && (
        <div className="hidden print:block">
          <PosReceipt data={receipt} />
        </div>
      )}

      <div className="pos-noprint space-y-4">
        {/* ───────── 頁首 ───────── */}
        <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
          <h1 className="text-xl font-bold tracking-tight">🛒 現場銷售</h1>
          <span className="hidden text-sm text-zinc-500 lg:inline dark:text-zinc-400">
            沒有訂單的現場客 · 送出即扣庫存結案
          </span>
          <span className="flex-1" />
          <Link href="/pos/topups" className={`${BTN_SM} grid place-items-center`}>
            🧾 補庫存紀錄
          </Link>
          {branchStoreId == null ? (
            <select
              value={pickedStoreId}
              onChange={(e) => changeStore(e.target.value)}
              className={`${INPUT} font-semibold`}
            >
              <option value="">選擇門市…</option>
              {stores.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          ) : (
            <span className="grid h-11 place-items-center rounded-lg bg-zinc-900 px-4 text-base font-semibold text-white dark:bg-zinc-100 dark:text-zinc-900">
              {store?.name ?? "—"}
            </span>
          )}
        </div>

        {error && (
          <div className="whitespace-pre-wrap rounded-lg border-l-4 border-red-500 bg-red-50 p-4 text-[15px] leading-relaxed text-red-900 dark:bg-red-950/60 dark:text-red-200">
            {error}
          </div>
        )}

        {receipt && (
          <div className="flex flex-wrap items-center gap-3 rounded-lg border-l-4 border-emerald-500 bg-emerald-50 px-4 py-3 text-emerald-900 dark:bg-emerald-950/60 dark:text-emerald-100">
            <span className="text-base font-semibold">
              ✅ 已結帳 {receipt.orderNo} · 收 $
              {Math.max(
                0,
                receipt.lines.reduce((a, l) => a + l.qty * l.unitPrice, 0) - receipt.discount,
              )}
            </span>
            <SpinButton
              onClick={() => window.print()}
              className="h-11 rounded-lg border border-emerald-600 px-4 text-sm font-semibold hover:bg-emerald-100 dark:hover:bg-emerald-900"
            >
              🧾 再列印一次
            </SpinButton>
            <Link
              href={`/orders?keyword=${encodeURIComponent(receipt.orderNo)}`}
              className="grid h-11 place-items-center px-2 text-sm underline underline-offset-2"
            >
              看訂單
            </Link>
          </div>
        )}

        {!storeId ? (
          <div className="rounded-lg border border-dashed border-zinc-300 p-12 text-center text-lg text-zinc-500 dark:border-zinc-700">
            請先選擇門市
          </div>
        ) : (
          <div className="grid items-start gap-4 lg:grid-cols-[minmax(0,1fr)_420px]">
            {/* ═══════════ 左：商品 ═══════════ */}
            <section className="overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
              <div className="flex items-center gap-2 border-b border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900/60">
                <input
                  value={term}
                  onChange={(e) => setTerm(e.target.value)}
                  placeholder="🔍 商品名 / 規格 / SKU 編號 / 條碼"
                  className={`${INPUT} w-full text-lg`}
                />
                <SearchSpinner active={searching} />
              </div>
              <div className="max-h-[66vh] overflow-y-auto">
                {products === null ? (
                  <div className="p-8 text-center text-base text-zinc-500">載入中…</div>
                ) : products.length === 0 ? (
                  <div className="p-8 text-center text-base text-zinc-500">
                    {term.trim()
                      ? "找不到商品"
                      : "這家店目前沒有在庫商品 —— 搜尋商品名可以找出缺貨品項"}
                  </div>
                ) : (
                  <ul className="divide-y divide-zinc-100 dark:divide-zinc-800">
                    {products.map((p) => {
                      const sellable = p.free_with_pool;
                      const inCart = cart.find((l) => l.sku_id === p.sku_id);
                      return (
                        <li key={p.sku_id}>
                          {/* 整列都是按鈕：手指點哪裡都會加入購物車 */}
                          <SpinButton
                            onClick={() => addToCart(p)}
                            className="block w-full px-4 py-4 text-left transition active:bg-sky-100 hover:bg-sky-50 dark:active:bg-sky-900/50 dark:hover:bg-sky-950/30"
                          >
                            <div className="flex items-start gap-3">
                              <span className="min-w-0 flex-1 break-words text-base font-semibold leading-snug text-zinc-900 dark:text-zinc-50">
                                {skuLabel(p)}
                              </span>
                              <span className="whitespace-nowrap text-xl font-bold text-zinc-900 dark:text-zinc-50">
                                {p.suggest_price > 0 ? `$${p.suggest_price}` : "未設價"}
                              </span>
                            </div>
                            <div className="mt-2 flex flex-wrap items-center gap-2 text-[13px]">
                              <span
                                className={
                                  sellable > 0
                                    ? "rounded-full bg-emerald-100 px-2.5 py-1 font-bold text-emerald-800 dark:bg-emerald-900/60 dark:text-emerald-200"
                                    : "rounded-full bg-rose-100 px-2.5 py-1 font-bold text-rose-800 dark:bg-rose-900/60 dark:text-rose-200"
                                }
                              >
                                可賣 {sellable}
                              </span>
                              {inCart && (
                                <span className="rounded-full bg-sky-600 px-2.5 py-1 font-bold text-white">
                                  車內 {inCart.qty}
                                </span>
                              )}
                              <span className="text-zinc-500 dark:text-zinc-400">
                                在庫 {p.on_hand}
                                {p.promised > 0 && ` · 待客取 ${p.promised}`}
                                {p.waiting > 0 && ` · 等貨中 ${p.waiting}`}
                                {p.pool_claimed > 0 && ` · 內部單 ${p.pool_claimed}`}
                              </span>
                              {showBranchPrice && p.branch_price != null && (
                                <span className="rounded bg-amber-100 px-2 py-0.5 font-semibold text-amber-900 dark:bg-amber-900/60 dark:text-amber-200">
                                  分店 ${p.branch_price}
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
            </section>

            {/* ═══════════ 右：結帳 ═══════════ */}
            <div className="space-y-4">
              {/* 客人 —— 輸入框本身就是會員搜尋框 */}
              <section className="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
                <div className="mb-2 text-xs font-bold uppercase tracking-wider text-zinc-400">
                  客人
                </div>
                {member ? (
                  <div className="flex items-center gap-2 rounded-lg border border-violet-300 bg-violet-50 px-3 py-3 dark:border-violet-800 dark:bg-violet-950/40">
                    <span className="min-w-0 flex-1">
                      <span className="text-base font-semibold">{member.name}</span>
                      <span className="mt-0.5 block text-[13px] text-zinc-500 dark:text-zinc-400">
                        {member.member_no}
                        {member.phone ? ` · ${member.phone}` : ""}
                        {member.home_store_name ? ` · ${member.home_store_name}` : ""}
                      </span>
                    </span>
                    <SpinButton
                      onClick={() => {
                        setMember(null);
                        setCustomerName("");
                        setHideHits(false);
                      }}
                      className={`${BTN_SM} bg-white dark:bg-zinc-900`}
                    >
                      改現場客
                    </SpinButton>
                  </div>
                ) : (
                  <>
                    <div className="relative">
                      <input
                        value={customerName}
                        onChange={(e) => {
                          setCustomerName(e.target.value);
                          setHideHits(false);
                        }}
                        placeholder="客人名字（可直接搜會員）"
                        className={`${INPUT} w-full text-lg`}
                      />
                      {showHits && (mHits.length > 0 || mSearching) && (
                        <div className="absolute z-20 mt-1 w-full overflow-hidden rounded-lg border border-zinc-200 bg-white shadow-xl dark:border-zinc-700 dark:bg-zinc-900">
                          {mSearching && mHits.length === 0 && (
                            <div className="px-4 py-3 text-base text-zinc-500">搜尋中…</div>
                          )}
                          {mHits.map((m) => (
                            <SpinButton
                              key={m.id}
                              onClick={() => {
                                setMember(m);
                                setKeepAsMember(false);
                              }}
                              disabled={m.no_new_order}
                              title={m.no_new_order ? "此會員已被標記為不可新增訂單" : undefined}
                              className="block w-full border-b border-zinc-100 px-4 py-3 text-left last:border-b-0 active:bg-violet-100 hover:bg-violet-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-zinc-800 dark:hover:bg-violet-950/40"
                            >
                              <span className="text-base font-medium">{m.name}</span>
                              <span className="mt-0.5 block text-[13px] text-zinc-500 dark:text-zinc-400">
                                {m.member_no}
                                {m.phone ? ` · ${m.phone}` : ""}
                                {m.home_store_name ? ` · ${m.home_store_name}` : ""}
                              </span>
                              {m.no_new_order && (
                                <span className="text-xs font-semibold text-rose-600">
                                  （已停用，不可新增訂單）
                                </span>
                              )}
                            </SpinButton>
                          ))}
                          <SpinButton
                            onClick={() => setHideHits(true)}
                            className="block h-12 w-full bg-zinc-50 px-4 text-left text-[13px] text-zinc-600 hover:bg-zinc-100 dark:bg-zinc-800/60 dark:text-zinc-300 dark:hover:bg-zinc-800"
                          >
                            都不是 —— 就用「{customerName.trim()}」當現場客
                          </SpinButton>
                        </div>
                      )}
                    </div>
                    {/* Alex 決議：預設不留成會員，但要能選擇留 */}
                    <label className="mt-2 flex min-h-11 items-center gap-2.5 text-[15px] text-zinc-600 dark:text-zinc-300">
                      <input
                        type="checkbox"
                        className="size-5"
                        checked={keepAsMember}
                        onChange={(e) => setKeepAsMember(e.target.checked)}
                      />
                      順便建立為會員
                      <span className="text-[13px] text-zinc-400">（不勾＝只留名字）</span>
                    </label>
                    {keepAsMember && (
                      <input
                        value={keepPhone}
                        onChange={(e) => setKeepPhone(e.target.value)}
                        placeholder="手機（選填，之後才能綁 LINE / 查訂單）"
                        className={`${INPUT} w-full`}
                      />
                    )}
                  </>
                )}
              </section>

              {/* 購物車 */}
              <section className="overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
                <div className="flex items-center justify-between border-b border-zinc-200 bg-zinc-50 px-4 py-3 dark:border-zinc-800 dark:bg-zinc-900/60">
                  <span className="text-xs font-bold uppercase tracking-wider text-zinc-400">
                    購物車
                  </span>
                  <span className="text-base font-semibold text-zinc-600 dark:text-zinc-300">
                    {cart.length} 項 · {cartQty} 件
                  </span>
                </div>
                {cart.length === 0 ? (
                  <div className="p-10 text-center text-base text-zinc-400">← 左邊點商品加入</div>
                ) : (
                  <ul className="max-h-[40vh] divide-y divide-zinc-100 overflow-y-auto dark:divide-zinc-800">
                    {cart.map((l) => {
                      const short = Math.max(0, l.qty - l.sellable);
                      const stillShort = Math.max(0, l.qty - l.sellable - l.addStock);
                      return (
                        <li key={l.sku_id} className="px-3 py-3">
                          <div className="flex items-start gap-2">
                            <span className="min-w-0 flex-1 break-words text-base font-semibold leading-snug">
                              {l.label}
                            </span>
                            <SpinButton
                              onClick={() => removeLine(l.sku_id)}
                              aria-label="移除"
                              className="grid size-11 shrink-0 place-items-center rounded-lg text-2xl leading-none text-zinc-300 active:bg-rose-100 hover:bg-rose-50 hover:text-rose-600 dark:hover:bg-rose-950"
                            >
                              ×
                            </SpinButton>
                          </div>
                          {/* 數量：−／＋ 大按鈕，手指不用瞄準小小的數字框 */}
                          <div className="mt-2 flex items-center gap-2">
                            <SpinButton
                              onClick={() => patchLine(l.sku_id, { qty: Math.max(1, l.qty - 1) })}
                              aria-label="減少數量"
                              className={`${ICON_BTN} active:bg-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800`}
                            >
                              −
                            </SpinButton>
                            <input
                              type="number"
                              min={1}
                              value={l.qty}
                              aria-label="數量"
                              onChange={(e) => {
                                const v = Math.floor(Number(e.target.value));
                                patchLine(l.sku_id, { qty: Number.isFinite(v) ? Math.max(1, v) : 1 });
                              }}
                              className="h-11 w-14 rounded-lg border border-zinc-300 bg-white text-center text-lg font-semibold tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                            />
                            <SpinButton
                              onClick={() => patchLine(l.sku_id, { qty: l.qty + 1 })}
                              aria-label="增加數量"
                              className={`${ICON_BTN} active:bg-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800`}
                            >
                              ＋
                            </SpinButton>
                            <span className="px-1 text-zinc-400">×</span>
                            <input
                              type="number"
                              min={0}
                              value={l.unit_price}
                              aria-label="單價"
                              onChange={(e) => {
                                const v = Number(e.target.value);
                                patchLine(l.sku_id, {
                                  unit_price: Number.isFinite(v) ? Math.max(0, v) : 0,
                                });
                              }}
                              className="h-11 w-20 rounded-lg border border-zinc-300 bg-white px-2 text-right text-lg tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                            />
                            <span className="flex-1 text-right text-xl font-bold tabular-nums">
                              ${l.qty * l.unit_price}
                            </span>
                          </div>
                          {l.unit_price <= 0 && (
                            <div className="mt-2 rounded-lg bg-rose-50 px-3 py-2 text-[14px] font-semibold text-rose-700 dark:bg-rose-950/60 dark:text-rose-300">
                              單價不可為 0（$0 的貨等於白送）
                            </div>
                          )}
                          {short > 0 && (
                            <div className="mt-2 rounded-lg border-l-4 border-amber-400 bg-amber-50 px-3 py-2.5 text-[14px] leading-relaxed text-amber-900 dark:bg-amber-950/60 dark:text-amber-200">
                              <div>
                                可賣 <b>{l.sellable}</b> 件（在庫 {l.on_hand}
                                {l.promised > 0 && `、待客取 ${l.promised}`}
                                {l.waiting > 0 && `、等貨中 ${l.waiting}`}），這一列要 {l.qty} 件。
                              </div>
                              {canAddStock ? (
                                <label className="mt-2 flex min-h-11 flex-wrap items-center gap-2 font-medium">
                                  <input
                                    type="checkbox"
                                    className="size-5"
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
                                    aria-label="補庫存數量"
                                    onChange={(e) => {
                                      const v = Math.floor(Number(e.target.value));
                                      patchLine(l.sku_id, {
                                        addStock: Number.isFinite(v) ? Math.max(0, v) : 0,
                                      });
                                    }}
                                    className="h-11 w-16 rounded-lg border border-amber-400 bg-white text-center text-lg font-semibold tabular-nums dark:bg-zinc-800"
                                  />
                                  件庫存
                                </label>
                              ) : (
                                <div className="mt-1.5">
                                  架上真的有貨請找店長補庫存，或先到「庫存總覽」入帳。
                                </div>
                              )}
                              {stillShort > 0 && (
                                <div className="mt-1.5 font-bold text-rose-700 dark:text-rose-300">
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
              </section>

              {/* 結帳 */}
              <section className="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
                <div className="flex items-center justify-between text-[15px] text-zinc-600 dark:text-zinc-300">
                  <span>小計</span>
                  <span className="tabular-nums">${itemsTotal}</span>
                </div>
                <div className="flex items-center justify-between text-[15px] text-zinc-600 dark:text-zinc-300">
                  <span>整單折扣</span>
                  <input
                    type="number"
                    min={0}
                    value={discount}
                    aria-label="整單折扣"
                    onChange={(e) => {
                      const v = Number(e.target.value);
                      setDiscount(
                        e.target.value === "" ? "" : Number.isFinite(v) ? Math.max(0, v) : 0,
                      );
                    }}
                    placeholder="0"
                    className="h-11 w-24 rounded-lg border border-zinc-300 bg-white px-3 text-right text-lg tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                  />
                </div>
                <div className="flex items-baseline justify-between border-t border-zinc-200 pt-3 dark:border-zinc-800">
                  <span className="text-[15px] font-medium text-zinc-500">應收</span>
                  <span className="text-4xl font-bold tabular-nums text-zinc-900 dark:text-zinc-50">
                    ${total}
                  </span>
                </div>

                <div>
                  <div className="mb-2 text-xs font-bold uppercase tracking-wider text-zinc-400">
                    付款方式
                  </div>
                  <div className="grid grid-cols-2 gap-2">
                    {payOptions.map((o) => (
                      <SpinButton
                        key={o}
                        onClick={() => setPayPick(o)}
                        className={
                          payment === o
                            ? "h-12 rounded-lg bg-zinc-900 text-base font-bold text-white dark:bg-zinc-100 dark:text-zinc-900"
                            : "h-12 rounded-lg border border-zinc-300 text-base text-zinc-600 active:bg-zinc-200 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                        }
                      >
                        {PAY_LABEL[o] ?? o}
                      </SpinButton>
                    ))}
                  </div>
                </div>

                <input
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  placeholder="備註（選填）"
                  className={`${INPUT} w-full`}
                />

                {addTotal > 0 && (
                  <div className="rounded-lg border-l-4 border-amber-400 bg-amber-50 px-3 py-2.5 text-[14px] leading-relaxed text-amber-900 dark:bg-amber-950/60 dark:text-amber-200">
                    這筆會先補 <b>{addTotal}</b> 件庫存進帳（留下「現場銷售即時入帳」紀錄）。
                    常常要補代表帳跟實體長期對不上，記得排一次盤點。
                  </div>
                )}

                <SpinButton
                  onClick={checkout}
                  disabled={!canCheckout}
                  className="h-16 w-full rounded-xl bg-sky-600 text-xl font-bold text-white shadow-sm transition active:bg-sky-800 hover:bg-sky-700 disabled:cursor-not-allowed disabled:bg-zinc-200 disabled:text-zinc-400 dark:disabled:bg-zinc-800 dark:disabled:text-zinc-500"
                >
                  {busy
                    ? "結帳中…"
                    : cart.length === 0
                      ? "購物車是空的"
                      : !member && !customerName.trim()
                        ? "請先填客人名字"
                        : `結帳 $${total}`}
                </SpinButton>
                <div className="text-center text-[13px] leading-relaxed text-zinc-400">
                  送出＝當場交貨並扣庫存（不是待取），並自動列印小白單。
                  <br />
                  打錯可在訂單頁「撤銷取貨」。
                </div>
              </section>
            </div>
          </div>
        )}
      </div>
    </>
  );
}

"use client";

// 📦 樓下收貨（iPad 專用頁）
//
// 為什麼要有這一頁：收貨現在只能辦公室用電腦按，樓下拿 iPad 做不了
//   —— 桌機側欄吃掉寬度、9 欄表格要左右拉、按鈕比手指小。
//   這一頁讓樓下倉管站在貨旁邊就能收完。
//
// ⛔ 這一頁是「新增」，現有 /wms/receiving 與 /purchase/orders/receive 一行不改。
//    辦公室維持用電腦開既有收貨頁處理單價／批號／效期／發票號／分店分配。
//
// 設計約束（都有出處，改之前先看）：
//   1. 走 rpc_arrive_and_distribute（最新版 20260512000002_arrive_no_auto_wave.sql:20）。
//      ⛔ 不可以改用 rpc_adjust_po_item_received —— 那支是「絕對值覆蓋」語意
//      （20260729000020_po_adjust_received_creates_gr.sql:9-14 檔頭寫明），
//      樓下多台 iPad 同時收同一張單會互相蓋掉（A 填 5、B 填 3 → 結果是 3 不是 8）。
//      arrive 是累加語意（每次收貨建一張 GR），符合分批到貨的現實，也才有 variance_reason。
//   2. 樓下畫面不出現：單價 / 批號 / 效期 / 瑕疵數 / 供應商發票號 / 備註 / 分店分配。
//      unit_cost 仍照 purchase_order_items.unit_cost 原值帶給 RPC（不可送 0 或 null，
//      成本會影響加權平均成本）；分店分配一律留給派貨工作台。
//   3. 觸控：所有可點元素 min-h-[44px] min-w-[44px] + touch-manipulation
//      （機制索引七之五；touch-manipulation 消掉 iOS ~350ms 的 double-tap 等待）。
//      輸入框 ≥16px，否則 iOS 一 focus 就把整頁放大。
//   4. ⛔ 重要資訊不可以只放在 title tooltip —— iPad 上根本沒有 tooltip
//      （picking/drafts/edit/page.tsx:859 有同樣的教訓註解）。
//   5. 側欄：不改全站 layout.tsx（會炸到所有頁面所有使用者），改用本頁自己
//      fixed 全屏蓋掉。用 z-40：Modal 與 layout 手機抽屜都是 z-50，不會被遮住。

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { publicProductUrl } from "@/lib/campaignCover";
import SpinButton from "@/components/SpinButton";

// ---------------------------------------------------------------- types

type WorkbenchPO = {
  id: number;
  po_no: string;
  status: string;
  sent_at: string | null;
  supplier_id: number;
  supplier_name: string;
  supplier_code: string | null;
  total_qty_ordered: number;
  total_qty_received: number;
  line_count: number;
  product_names: string[];
};

type SupplierGroup = {
  supplier_id: number;
  supplier_name: string;
  supplier_code: string | null;
  pos: WorkbenchPO[];
  remaining: number;
};

type ItemForm = {
  po_item_id: number;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  image_url: string | null;
  qty_ordered: number;
  qty_already: number;
  remaining: number;
  /** 採購單原本的成本。樓下看不到、不能改，但一定要原值帶給 RPC。 */
  unit_cost: number;
  /** 實到；字串是為了讓輸入框可以是空的（空 = 這項還沒核對，不會送出） */
  qty: string;
  variance_reason: string;
};

type Step = "supplier" | "po" | "items" | "done";

// 數量不符時的常用原因（一鍵填進既有 variance_reason 欄位，不新增資料表）
const REASON_PRESETS = ["缺貨", "破損", "送錯", "多送"] as const;

// ---------------------------------------------------------------- helpers

/** images[0] 可能是字串或 { url }（比照 campaigns/quick-control/page.tsx:207-212） */
function productImageUrl(images: unknown): string | null {
  if (!Array.isArray(images) || images.length === 0) return null;
  const first = images[0] as unknown;
  const path = typeof first === "string" ? first : (first as { url?: string | null })?.url ?? null;
  return publicProductUrl(path);
}

/** 只留數字與一個小數點（採購數量是 numeric(18,3)，不能寫死成整數） */
function sanitizeQty(v: string): string {
  const cleaned = v.replace(/[^\d.]/g, "");
  const firstDot = cleaned.indexOf(".");
  if (firstDot === -1) return cleaned;
  return cleaned.slice(0, firstDot + 1) + cleaned.slice(firstDot + 1).replace(/\./g, "");
}

function num(v: string): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** 商品名一律帶 variant_name：product_name 常常是上層品名，只印它現場會抓錯貨 */
function itemTitle(it: ItemForm): string {
  const main = it.product_name?.trim() || it.sku_code || `#${it.sku_id}`;
  const sub = it.variant_name?.trim();
  return sub ? `${main} / ${sub}` : main;
}

// 觸控目標統一寫法（機制索引七之五：用 min-h 撐高、不要加 py）
const BTN_BASE =
  "inline-flex items-center justify-center gap-1 rounded-xl font-semibold touch-manipulation " +
  "min-h-[56px] min-w-[56px] px-4 text-base disabled:cursor-not-allowed disabled:opacity-40";
const BTN_PRIMARY = `${BTN_BASE} bg-blue-600 text-white active:bg-blue-700`;
const BTN_GHOST = `${BTN_BASE} border border-zinc-300 bg-white text-zinc-800 active:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:active:bg-zinc-800`;

// ---------------------------------------------------------------- page

export default function IpadReceivingPage() {
  const [step, setStep] = useState<Step>("supplier");
  const [rows, setRows] = useState<WorkbenchPO[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");

  const [supplier, setSupplier] = useState<SupplierGroup | null>(null);
  const [po, setPO] = useState<WorkbenchPO | null>(null);
  const [items, setItems] = useState<ItemForm[] | null>(null);
  const [loadingItems, setLoadingItems] = useState(false);
  const [showDone, setShowDone] = useState(false); // 是否顯示「已收齊」的品項
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<{ gr_no: string; po_no: string; qty: number; lines: number } | null>(null);

  // 同步防重入鎖：React state 是非同步的，擋不住同一 tick 連點
  // （比照 purchase/orders/receive/page.tsx:104）
  const submitLock = useRef(false);

  const loadWorkbench = useCallback(async () => {
    const sb = getSupabase();
    const { data, error: e } = await sb.rpc("rpc_receiving_workbench");
    if (e) throw new Error(e.message);
    return ((data ?? []) as Array<Record<string, unknown>>)
      .map((r) => ({
        id: Number(r.id),
        po_no: String(r.po_no),
        status: String(r.status),
        sent_at: (r.sent_at as string | null) ?? null,
        supplier_id: Number(r.supplier_id),
        supplier_name: String(r.supplier_name),
        supplier_code: (r.supplier_code as string | null) ?? null,
        total_qty_ordered: Number(r.total_qty_ordered),
        total_qty_received: Number(r.total_qty_received),
        line_count: Number(r.line_count),
        product_names: Array.isArray(r.product_names)
          ? (r.product_names as unknown[]).map((n) => String(n))
          : [],
      }))
      // 只留還能收的單。rpc_arrive_and_distribute 本身也擋
      // （PO must be sent/partially_received），這裡先濾掉才不會讓樓下點了才吃錯誤。
      .filter((r) => r.status === "sent" || r.status === "partially_received");
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const list = await loadWorkbench();
        if (!cancelled) {
          setRows(list);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [loadWorkbench]);

  // 依廠商分組；搜尋同時比對廠商名 / 代碼 / 該廠商所有待收商品名
  const groups = useMemo<SupplierGroup[]>(() => {
    if (!rows) return [];
    const q = search.trim().toLowerCase();
    const map = new Map<number, SupplierGroup>();
    for (const r of rows) {
      let g = map.get(r.supplier_id);
      if (!g) {
        g = {
          supplier_id: r.supplier_id,
          supplier_name: r.supplier_name,
          supplier_code: r.supplier_code,
          pos: [],
          remaining: 0,
        };
        map.set(r.supplier_id, g);
      }
      g.pos.push(r);
      g.remaining += Math.max(0, r.total_qty_ordered - r.total_qty_received);
    }
    let list = Array.from(map.values());
    if (q) {
      list = list.filter((g) => {
        const haystack = [
          g.supplier_name,
          g.supplier_code ?? "",
          ...g.pos.map((p) => p.po_no),
          ...g.pos.flatMap((p) => p.product_names),
        ]
          .join(" ")
          .toLowerCase();
        return haystack.includes(q);
      });
    }
    return list.sort((a, b) => a.supplier_name.localeCompare(b.supplier_name, "zh-Hant"));
  }, [rows, search]);

  // 進到某張單：撈品項明細（已斷貨不列入，比照現有收貨頁 receive/page.tsx:197-199）
  const openPO = useCallback(async (target: WorkbenchPO) => {
    setLoadingItems(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: raw, error: e1 } = await sb
        .from("purchase_order_items")
        .select("id, sku_id, qty_ordered, qty_received, unit_cost, stockout_at")
        .eq("po_id", target.id)
        .order("id");
      if (e1) throw new Error(e1.message);

      type RawItem = {
        id: number;
        sku_id: number;
        qty_ordered: number;
        qty_received: number | null;
        unit_cost: number;
        stockout_at: string | null;
      };
      const live = ((raw as RawItem[] | null) ?? []).filter((r) => !r.stockout_at);

      type RawSku = {
        id: number;
        sku_code: string | null;
        product_name: string | null;
        variant_name: string | null;
        product: { images: unknown } | { images: unknown }[] | null;
      };
      const skuMap = new Map<number, { code: string | null; product: string | null; variant: string | null; img: string | null }>();
      const skuIds = Array.from(new Set(live.map((r) => r.sku_id)));
      if (skuIds.length > 0) {
        const { data: skus, error: e2 } = await sb
          .from("skus")
          .select("id, sku_code, product_name, variant_name, product:products(images)")
          .in("id", skuIds);
        if (e2) throw new Error(e2.message);
        for (const s of (skus as RawSku[] | null) ?? []) {
          const prod = Array.isArray(s.product) ? s.product[0] ?? null : s.product;
          skuMap.set(s.id, {
            code: s.sku_code,
            product: s.product_name,
            variant: s.variant_name,
            img: productImageUrl(prod?.images),
          });
        }
      }

      const forms: ItemForm[] = live.map((r) => {
        const s = skuMap.get(r.sku_id);
        const ordered = Number(r.qty_ordered);
        const already = Number(r.qty_received ?? 0);
        return {
          po_item_id: r.id,
          sku_id: r.sku_id,
          sku_code: s?.code ?? null,
          product_name: s?.product ?? null,
          variant_name: s?.variant ?? null,
          image_url: s?.img ?? null,
          qty_ordered: ordered,
          qty_already: already,
          remaining: Math.max(0, ordered - already),
          unit_cost: Number(r.unit_cost),
          // ⛔ 預設留空，不預先填滿：這一頁的用途是「核對」，
          //    預填等於鼓勵不看貨就送出，錯的庫存比漏收難救。
          qty: "",
          variance_reason: "",
        };
      });

      setPO(target);
      setItems(forms);
      setShowDone(false);
      setStep("items");
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setLoadingItems(false);
    }
  }, []);

  function patchItem(idx: number, patch: Partial<ItemForm>) {
    setItems((cur) => {
      if (!cur) return cur;
      const next = [...cur];
      next[idx] = { ...next[idx], ...patch };
      return next;
    });
  }

  function fillAllArrived() {
    setItems((cur) => (cur ? cur.map((f) => (f.remaining > 0 ? { ...f, qty: String(f.remaining) } : f)) : cur));
  }

  function clearAll() {
    setItems((cur) => (cur ? cur.map((f) => ({ ...f, qty: "", variance_reason: "" })) : cur));
  }

  // 每一項的判定：實到 ≠ 應到（且實到 > 0）就要填原因
  // —— 與現有收貨頁 receive/page.tsx:321-324 同一條規則，
  //    不照做的話 RPC 送出前的前端校驗會不一致。
  const checks = useMemo(() => {
    if (!items) return null;
    return items.map((f) => {
      const received = num(f.qty);
      const isOver = received > f.remaining;
      const isShort = received > 0 && received < f.remaining;
      const requiresReason = received > 0 && (isOver || isShort);
      return {
        received,
        isOver,
        isShort,
        requiresReason,
        reasonMissing: requiresReason && !f.variance_reason.trim(),
      };
    });
  }, [items]);

  const summary = useMemo(() => {
    if (!items || !checks) return null;
    let lines = 0;
    let qty = 0;
    let missing = 0;
    items.forEach((f, i) => {
      const c = checks[i];
      if (c.received > 0) {
        lines += 1;
        qty += c.received;
        if (c.reasonMissing) missing += 1;
      }
    });
    return { lines, qty, missing, total: items.length };
  }, [items, checks]);

  // 已收齊的品項預設收起來；但只要有人在裡面填了數字就強制顯示，
  // 免得「送出去的東西畫面上看不到」。
  const hiddenHasQty = useMemo(() => {
    if (!items || !checks) return false;
    return items.some((f, i) => f.remaining <= 0 && checks[i].received > 0);
  }, [items, checks]);
  const doneVisible = showDone || hiddenHasQty;

  async function submit() {
    if (!items || !checks || !po || submitLock.current) return;
    submitLock.current = true;
    setError(null);
    setSubmitting(true);
    try {
      const arrivals = items
        .map((f, i) => ({ f, c: checks[i] }))
        .filter(({ c }) => c.received > 0)
        .map(({ f, c }) => ({
          po_item_id: f.po_item_id,
          sku_id: f.sku_id,
          qty_received: c.received,
          // 樓下畫面上沒有「瑕疵」欄位 —— 瑕疵歸辦公室在既有收貨頁處理
          qty_damaged: 0,
          // 帶採購單原本的成本。⛔ 不可送 0 或 null：unit_cost > 0 才會重算
          // 加權平均成本（apply_movement_to_balance），送 0 會把成本洗掉。
          unit_cost: f.unit_cost,
          batch_no: null,
          expiry_date: null,
          variance_reason: f.variance_reason.trim() || null,
          // 分店分配一律留給派貨工作台
          allocations: [] as Array<{ store_id: number; qty: number }>,
        }));

      if (arrivals.length === 0) throw new Error("請至少填一項實到數量");

      const missing = checks.filter((c) => c.reasonMissing).length;
      if (missing > 0) throw new Error(`有 ${missing} 項數量跟應到不一樣，要先選原因才能送出。`);

      const { data: userRes } = await getSupabase().auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const { data, error: rpcErr } = await getSupabase().rpc("rpc_arrive_and_distribute", {
        p_po_id: po.id,
        p_arrivals: arrivals,
        p_operator: operator,
        // 樓下不填發票號與備註
        p_invoice_no: null,
        p_notes: null,
      });
      if (rpcErr) throw new Error(translateRpcError(rpcErr));

      const gr = (data as { gr_no?: string } | null)?.gr_no ?? "";
      setResult({
        gr_no: gr,
        po_no: po.po_no,
        qty: arrivals.reduce((s, a) => s + a.qty_received, 0),
        lines: arrivals.length,
      });
      // ⛔ 成功後**不釋放** submitLock，並且切到成功畫面（那一頁沒有送出鈕）。
      //    要再收下一張單一定得走 startNext()，那裡才會解鎖。
      setItems(null);
      setPO(null);
      setStep("done");
    } catch (e) {
      setError(translateRpcError(e));
      submitLock.current = false; // 失敗才解鎖，讓人修正後重試
    } finally {
      setSubmitting(false);
    }
  }

  async function startNext() {
    setResult(null);
    setError(null);
    setSearch("");
    setSupplier(null);
    setStep("supplier");
    setRows(null);
    submitLock.current = false;
    try {
      setRows(await loadWorkbench());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setRows([]);
    }
  }

  // ------------------------------------------------------------ render

  return (
    // 蓋掉桌機側欄：不改全站 layout.tsx，改用本頁自己全屏。
    // z-40 → Modal / 手機抽屜（都是 z-50）仍蓋得住這一頁。
    // 高度用 dvh 不用 vh：iPad 工具列收合時 vh 會比實際可視高度大，底部按鈕會被切掉。
    <div className="fixed inset-x-0 top-0 z-40 flex h-[100dvh] flex-col bg-zinc-100 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
      <Header
        step={step}
        supplier={supplier}
        po={po}
        onBack={() => {
          setError(null);
          if (step === "items") {
            setItems(null);
            setPO(null);
            setStep("po");
          } else if (step === "po") {
            setSupplier(null);
            setStep("supplier");
          }
        }}
      />

      <main className="flex-1 overflow-y-auto overscroll-contain px-4 pb-6 pt-4">
        {error && (
          <div className="mb-4 rounded-xl border border-red-300 bg-red-50 p-4 text-base font-medium text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
            ⚠ {error}
          </div>
        )}

        {step === "supplier" && (
          <SupplierStep
            rows={rows}
            groups={groups}
            search={search}
            onSearch={setSearch}
            onPick={(g) => {
              setSupplier(g);
              setStep("po");
            }}
          />
        )}

        {step === "po" && supplier && (
          <POStep supplier={supplier} busy={loadingItems} onPick={openPO} />
        )}

        {step === "items" && items && checks && (
          <ItemsStep
            items={items}
            checks={checks}
            doneVisible={doneVisible}
            forcedOpen={hiddenHasQty}
            onToggleDone={() => setShowDone((v) => !v)}
            onPatch={patchItem}
            onFillAll={fillAllArrived}
            onClearAll={clearAll}
          />
        )}

        {step === "done" && result && <DoneStep result={result} onNext={startNext} />}
      </main>

      {step === "items" && summary && (
        <footer className="border-t border-zinc-300 bg-white px-4 py-3 dark:border-zinc-700 dark:bg-zinc-900">
          <div className="flex items-center justify-between gap-3">
            <div className="text-base">
              <div className="font-semibold">
                已核對 {summary.lines} / {summary.total} 項
              </div>
              <div className="text-sm text-zinc-600 dark:text-zinc-400">
                合計 <span className="font-mono font-bold">{summary.qty}</span> 件
                {summary.missing > 0 && (
                  <span className="ml-2 font-semibold text-rose-600 dark:text-rose-400">
                    · {summary.missing} 項還沒選原因
                  </span>
                )}
              </div>
            </div>
            <SpinButton
              type="button"
              onClick={submit}
              disabled={summary.lines === 0 || summary.missing > 0 || submitting}
              className={`${BTN_BASE} min-w-[160px] bg-emerald-600 text-lg text-white active:bg-emerald-700 disabled:bg-zinc-300 dark:disabled:bg-zinc-700`}
            >
              {submitting ? "送出中…" : "✅ 確認收貨"}
            </SpinButton>
          </div>
          {/* ⛔ 停用原因一定要看得見，不可以只放 title：iPad 上沒有 tooltip */}
          {summary.lines === 0 && (
            <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
              還沒有任何一項填數量。點商品卡上的「全到」，或用 ＋／− 調數量。
            </p>
          )}
          {summary.missing > 0 && (
            <p className="mt-2 text-sm font-medium text-rose-600 dark:text-rose-400">
              有 {summary.missing} 項數量跟應到不一樣，要先選一個原因才能送出。
            </p>
          )}
        </footer>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- header

function Header({
  step,
  supplier,
  po,
  onBack,
}: {
  step: Step;
  supplier: SupplierGroup | null;
  po: WorkbenchPO | null;
  onBack: () => void;
}) {
  const canBack = step === "po" || step === "items";
  return (
    <header className="flex items-center gap-3 border-b border-zinc-300 bg-white px-4 py-3 dark:border-zinc-700 dark:bg-zinc-900">
      {canBack ? (
        <SpinButton type="button" onClick={onBack} className={`${BTN_GHOST} shrink-0`}>
          ← 返回
        </SpinButton>
      ) : null}
      <div className="min-w-0 flex-1">
        <div className="truncate text-lg font-bold">
          {step === "supplier" && "📦 樓下收貨 · ① 選廠商"}
          {step === "po" && `② 選採購單 · ${supplier?.supplier_name ?? ""}`}
          {step === "items" && `③ 核對數量 · ${po?.po_no ?? ""}`}
          {step === "done" && "✅ 收貨完成"}
        </div>
        {step === "items" && po && (
          <div className="truncate text-sm text-zinc-600 dark:text-zinc-400">{po.supplier_name}</div>
        )}
      </div>
      {/* 出口：不然樓下會被困在這一頁出不去 */}
      <Link href="/wms/receiving" className={`${BTN_GHOST} shrink-0`}>
        離開
      </Link>
    </header>
  );
}

// ---------------------------------------------------------------- ① 選廠商

function SupplierStep({
  rows,
  groups,
  search,
  onSearch,
  onPick,
}: {
  rows: WorkbenchPO[] | null;
  groups: SupplierGroup[];
  search: string;
  onSearch: (v: string) => void;
  onPick: (g: SupplierGroup) => void;
}) {
  return (
    <div className="flex flex-col gap-4">
      {/* 字級 ≥16px：低於 16px 的輸入框一 focus，iOS 就把整頁放大 */}
      <input
        value={search}
        onChange={(e) => onSearch(e.target.value)}
        placeholder="🔍 搜廠商或商品名"
        className="min-h-[56px] w-full rounded-xl border border-zinc-300 bg-white px-4 text-base dark:border-zinc-700 dark:bg-zinc-900"
      />

      {rows === null ? (
        <p className="p-6 text-center text-base text-zinc-500">載入中…</p>
      ) : groups.length === 0 ? (
        <p className="p-6 text-center text-base text-zinc-500">
          {rows.length === 0 ? "目前沒有待收的貨" : "沒有符合的廠商或商品"}
        </p>
      ) : (
        <ul className="flex flex-col gap-3">
          {groups.map((g) => (
            <li key={g.supplier_id}>
              <SpinButton
                type="button"
                onClick={() => onPick(g)}
                className={`${BTN_GHOST} w-full justify-between py-3 text-left`}
              >
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-xl font-bold">{g.supplier_name}</span>
                  <span className="block text-sm font-normal text-zinc-600 dark:text-zinc-400">
                    {g.pos.length} 張單 · 還沒到 {g.remaining} 件
                  </span>
                </span>
                <span className="shrink-0 text-2xl text-zinc-400">›</span>
              </SpinButton>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- ② 選採購單

function POStep({
  supplier,
  busy,
  onPick,
}: {
  supplier: SupplierGroup;
  busy: boolean;
  onPick: (p: WorkbenchPO) => Promise<void>;
}) {
  return (
    <ul className="flex flex-col gap-3">
      {supplier.pos.map((p) => {
        const left = Math.max(0, p.total_qty_ordered - p.total_qty_received);
        const preview = p.product_names.slice(0, 4).join("、");
        return (
          <li key={p.id}>
            <SpinButton
              type="button"
              disabled={busy}
              onClick={() => onPick(p)}
              className={`${BTN_GHOST} w-full flex-col items-start gap-1 py-3 text-left`}
            >
              <span className="flex w-full items-baseline justify-between gap-2">
                <span className="font-mono text-lg font-bold">{p.po_no}</span>
                <span className="shrink-0 text-sm font-normal text-zinc-600 dark:text-zinc-400">
                  {p.sent_at ? new Date(p.sent_at).toLocaleDateString("zh-TW") : "—"}
                </span>
              </span>
              <span className="text-sm font-normal text-zinc-600 dark:text-zinc-400">
                {p.line_count} 項 · 還沒到 {left} 件
                {p.status === "partially_received" && (
                  <span className="ml-2 rounded bg-amber-100 px-2 py-0.5 font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                    收過一部分
                  </span>
                )}
              </span>
              {preview && (
                <span className="w-full truncate text-sm font-normal text-zinc-500">
                  {preview}
                  {p.product_names.length > 4 ? " …" : ""}
                </span>
              )}
            </SpinButton>
          </li>
        );
      })}
    </ul>
  );
}

// ---------------------------------------------------------------- ③ 核對數量

type Check = {
  received: number;
  isOver: boolean;
  isShort: boolean;
  requiresReason: boolean;
  reasonMissing: boolean;
};

function ItemsStep({
  items,
  checks,
  doneVisible,
  forcedOpen,
  onToggleDone,
  onPatch,
  onFillAll,
  onClearAll,
}: {
  items: ItemForm[];
  checks: Check[];
  doneVisible: boolean;
  /** 已收齊區塊裡有人填了數字 → 強制攤開，收不起來（收起來會讓送出的東西看不到） */
  forcedOpen: boolean;
  onToggleDone: () => void;
  onPatch: (idx: number, patch: Partial<ItemForm>) => void;
  onFillAll: () => void;
  onClearAll: () => void;
}) {
  const pending = items.map((f, i) => ({ f, c: checks[i], i })).filter(({ f }) => f.remaining > 0);
  const finished = items.map((f, i) => ({ f, c: checks[i], i })).filter(({ f }) => f.remaining <= 0);

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap gap-2">
        <SpinButton type="button" onClick={onFillAll} className={BTN_GHOST}>
          全部都到齊
        </SpinButton>
        <SpinButton type="button" onClick={onClearAll} className={BTN_GHOST}>
          全部清空
        </SpinButton>
      </div>

      {pending.length === 0 && finished.length === 0 && (
        <p className="p-6 text-center text-base text-zinc-500">這張單沒有可收的品項</p>
      )}

      <ul className="flex flex-col gap-4">
        {pending.map(({ f, c, i }) => (
          <ItemCard key={f.po_item_id} item={f} check={c} onPatch={(p) => onPatch(i, p)} />
        ))}
      </ul>

      {finished.length > 0 && (
        <>
          <SpinButton
            type="button"
            onClick={onToggleDone}
            disabled={forcedOpen}
            className={BTN_GHOST}
          >
            {doneVisible ? "▲ 收起已收齊的" : `▼ 顯示已收齊的 ${finished.length} 項`}
          </SpinButton>
          {/* ⛔ 停用原因要看得見，不可以只放 title：iPad 上沒有 tooltip */}
          {forcedOpen && (
            <p className="-mt-2 text-sm text-zinc-600 dark:text-zinc-400">
              下面「已收齊」的品項裡有填了數字的，先攤開著不收起來，免得要送出的東西畫面上看不到。
            </p>
          )}
          {doneVisible && (
            <ul className="flex flex-col gap-4">
              {finished.map(({ f, c, i }) => (
                <ItemCard key={f.po_item_id} item={f} check={c} onPatch={(p) => onPatch(i, p)} />
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  );
}

function ItemCard({
  item,
  check,
  onPatch,
}: {
  item: ItemForm;
  check: Check;
  onPatch: (patch: Partial<ItemForm>) => void;
}) {
  const exact = check.received > 0 && !check.isOver && !check.isShort;
  const cardCls = check.reasonMissing
    ? "border-rose-400 bg-rose-50 dark:border-rose-700 dark:bg-rose-950/40"
    : exact
      ? "border-emerald-400 bg-emerald-50 dark:border-emerald-700 dark:bg-emerald-950/30"
      : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900";

  function step(delta: number) {
    const next = Math.max(0, num(item.qty) + delta);
    onPatch({ qty: String(next) });
  }

  return (
    <li className={`rounded-2xl border-2 p-4 ${cardCls}`}>
      <div className="flex items-start gap-4">
        {item.image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={item.image_url}
            alt={itemTitle(item)}
            loading="lazy"
            className="h-24 w-24 shrink-0 rounded-xl border border-zinc-200 object-cover dark:border-zinc-800"
          />
        ) : (
          // 無圖佔位：尺寸與有圖時一致，卡片不會破版
          <div className="flex h-24 w-24 shrink-0 items-center justify-center rounded-xl border border-zinc-200 bg-zinc-50 text-zinc-300 dark:border-zinc-800 dark:bg-zinc-950">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5} className="h-10 w-10">
              <path strokeLinecap="round" strokeLinejoin="round" d="M5 8h14l-1 11a2 2 0 0 1-2 1.8H8A2 2 0 0 1 6 19L5 8Z" />
              <path strokeLinecap="round" strokeLinejoin="round" d="M9 8V6.5a3 3 0 0 1 6 0V8" />
            </svg>
          </div>
        )}
        <div className="min-w-0 flex-1">
          <div className="text-xl font-bold leading-snug">{itemTitle(item)}</div>
          {item.sku_code && (
            <div className="mt-0.5 font-mono text-sm text-zinc-500">{item.sku_code}</div>
          )}
          <div className="mt-2 text-lg">
            應到 <span className="font-mono text-3xl font-bold">{item.remaining}</span> 件
          </div>
          {item.qty_already > 0 && (
            <div className="text-sm text-zinc-600 dark:text-zinc-400">
              訂 {item.qty_ordered} · 之前已收 {item.qty_already}
            </div>
          )}
        </div>
      </div>

      <div className="mt-4 flex flex-wrap items-center gap-2">
        <SpinButton
          type="button"
          onClick={() => step(-1)}
          disabled={num(item.qty) <= 0}
          className={`${BTN_GHOST} text-2xl`}
          aria-label="減一"
        >
          −
        </SpinButton>
        {/* text-2xl 遠大於 16px：低於 16px 的輸入框一 focus，iOS 會把整頁放大 */}
        <input
          inputMode="decimal"
          value={item.qty}
          onChange={(e) => onPatch({ qty: sanitizeQty(e.target.value) })}
          placeholder="0"
          aria-label="實到數量"
          className="min-h-[56px] w-28 rounded-xl border-2 border-zinc-300 bg-white px-3 text-center font-mono text-2xl font-bold dark:border-zinc-600 dark:bg-zinc-800"
        />
        <SpinButton
          type="button"
          onClick={() => step(1)}
          className={`${BTN_GHOST} text-2xl`}
          aria-label="加一"
        >
          ＋
        </SpinButton>
        <SpinButton
          type="button"
          onClick={() => onPatch({ qty: String(item.remaining) })}
          className={`${exact ? `${BTN_BASE} bg-emerald-600 text-white active:bg-emerald-700` : BTN_PRIMARY} ml-auto min-w-[110px] text-lg`}
        >
          {exact ? "✓ 全到" : "全到"}
        </SpinButton>
      </div>

      {check.requiresReason && (
        <div className="mt-4 rounded-xl border-2 border-amber-400 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-950/50">
          <div className="text-base font-bold text-amber-900 dark:text-amber-200">
            {check.isOver
              ? `⚠ 比應到多了 ${check.received - item.remaining} 件 —— 選一個原因`
              : `⚠ 比應到少了 ${item.remaining - check.received} 件 —— 選一個原因`}
          </div>
          <div className="mt-2 flex flex-wrap gap-2">
            {REASON_PRESETS.map((r) => {
              const on = item.variance_reason.trim() === r;
              return (
                <SpinButton
                  key={r}
                  type="button"
                  onClick={() => onPatch({ variance_reason: on ? "" : r })}
                  className={
                    on
                      ? `${BTN_BASE} bg-amber-600 text-white active:bg-amber-700`
                      : `${BTN_BASE} border-2 border-amber-400 bg-white text-amber-900 active:bg-amber-100 dark:bg-zinc-900 dark:text-amber-200`
                  }
                >
                  {r}
                </SpinButton>
              );
            })}
          </div>
          <input
            value={item.variance_reason}
            onChange={(e) => onPatch({ variance_reason: e.target.value })}
            placeholder="或自己打（例：司機說明天補）"
            aria-label="差異原因"
            className="mt-2 min-h-[56px] w-full rounded-xl border border-amber-400 bg-white px-3 text-base dark:border-amber-700 dark:bg-zinc-900"
          />
        </div>
      )}
    </li>
  );
}

// ---------------------------------------------------------------- ④ 完成

function DoneStep({
  result,
  onNext,
}: {
  result: { gr_no: string; po_no: string; qty: number; lines: number };
  onNext: () => Promise<void>;
}) {
  return (
    <div className="mx-auto flex max-w-lg flex-col items-center gap-5 py-10 text-center">
      <div className="text-6xl">✅</div>
      <div className="text-2xl font-bold">收貨完成</div>
      <div className="rounded-2xl border-2 border-emerald-300 bg-emerald-50 px-6 py-4 text-lg dark:border-emerald-800 dark:bg-emerald-950/40">
        <div className="font-mono font-bold">{result.po_no}</div>
        <div className="mt-1">
          {result.lines} 項 · 共 <span className="font-mono font-bold">{result.qty}</span> 件
        </div>
        {result.gr_no && (
          <div className="mt-1 font-mono text-sm text-zinc-600 dark:text-zinc-400">
            進貨單 {result.gr_no}
          </div>
        )}
      </div>
      <p className="text-base text-zinc-600 dark:text-zinc-400">
        這批貨已經進總倉。分店要分多少，辦公室會在派貨工作台處理。
      </p>
      <div className="flex flex-wrap justify-center gap-3">
        <SpinButton type="button" onClick={onNext} className={`${BTN_PRIMARY} text-lg`}>
          收下一張單
        </SpinButton>
        <Link href="/wms/receiving" className={`${BTN_GHOST} text-lg`}>
          離開
        </Link>
      </div>
    </div>
  );
}

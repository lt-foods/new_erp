"use client";

// 📄 採購單查看（iPad 專用頁）—— 唯讀 ＋ 逐列「寫入撿貨草稿」
//
// 這一頁在解什麼（老闆 2026-08-31 ⑦，9-01 補充）：
//   「補貨申請跟採購單，我想要有 ipad 版本」
//   → 「採購單我想要做**查看**，但是寫入撿貨草稿要能帶出數量」
//   樓下拿 iPad 想翻某張採購單看「訂多少 / 到多少 / 還差多少」，
//   順手把某一項寫進今天的撿貨草稿（數量自動帶）。
//
// ⛔⛔ 這一頁是**唯讀**的（除了寫撿貨草稿那條）：
//   · 不收貨、不改數量、不斷貨、不建單、不碰庫存。
//   · 要收貨請走 /wms/receiving/ipad（本頁 header 有出口）。
//   · 對既有頁面一行不改：/purchase/orders 與 /purchase/orders/receive 原封不動。
//
// ⛔ 範圍外（老闆 2026-09-02 問題 1 裁示「這次不做」）：補貨申請的 iPad 版。
//
// 設計約束（沿用 /wms/receiving/ipad 那一頁，⛔ 不要各走各的）：
//   1. 觸控目標 min-h-[44px]／主要按鈕 56px ＋ touch-manipulation；輸入框 ≥16px
//      （低於 16px 一 focus，iOS 就把整頁放大）。
//   2. ⛔ 重要資訊不可以只放在 title tooltip —— iPad 上根本沒有 tooltip。
//      按鈕變灰**一定要在畫面上寫出為什麼**。
//   3. 側欄：不改全站 layout.tsx，本頁自己 fixed 全屏蓋掉（z-40，讓 Modal 的 z-50 蓋得住）。
//      高度用 dvh 不用 vh（iPad 工具列收合時 vh 比可視高度大，底部會被切掉）。
//   4. 權限：/purchase/orders 在 layout 的 BRANCH_HIDDEN_HREFS 裡對分店帳號隱藏
//      （layout.tsx:130），本頁是它的 iPad 入口 ⇒ **不可以比它寬**，照同一條判定擋掉。
//
// 資料來源（都是既有的，⛔ 沒有新增任何 RPC / migration）：
//   · 清單 ＝ rpc_po_list（最新版 20260812000000_po_stockout_split_and_restore.sql:804；
//     server-side 搜尋／排序／分頁，搜的是單號/廠商/來源請購單/商品名）
//   · 明細 ＝ purchase_orders + purchase_order_items + skus
//     （查法逐項對齊 purchase/orders/receive/page.tsx:118-119,:130）

import { Suspense, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { translateRpcError } from "@/lib/rpcError";
import { describeDraftDbError } from "@/lib/pickingDraftView";
import { handoffMessage, handoffToDraft } from "@/lib/pickingDraftHandoff";
import { runExclusive, type BusyKind } from "@/lib/receivingBatch";
import { useAuth } from "@/components/AuthProvider";
import SpinButton from "@/components/SpinButton";

// ---------------------------------------------------------------- 共用樣式
// ⓘ 與 /wms/receiving/ipad/page.tsx:248-255 同一組。⛔ 兩頁要一起改，
//   否則樓下在兩頁按到大小不一樣的按鈕。
const BTN_BASE =
  "inline-flex items-center justify-center gap-1 rounded-xl font-semibold touch-manipulation " +
  "min-h-[56px] min-w-[56px] px-4 text-base disabled:cursor-not-allowed disabled:opacity-40";
const BTN_PRIMARY = `${BTN_BASE} bg-blue-600 text-white active:bg-blue-700`;
const BTN_GHOST = `${BTN_BASE} border border-zinc-300 bg-white text-zinc-800 active:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:active:bg-zinc-800`;
const BTN_SMALL =
  "inline-flex items-center justify-center gap-1 rounded-lg font-semibold touch-manipulation " +
  "min-h-[44px] px-3 text-sm disabled:cursor-not-allowed disabled:opacity-40";

const PAGE_SIZE = 30;

// ---------------------------------------------------------------- helpers

/** 分店帳號判定 —— 與 (protected)/layout.tsx:134 的 isBranchUser()、
 *  以及 /wms/receiving/ipad/page.tsx:200-204 的同名函式**逐字相同**。
 *  ⚠ 那兩支一個住在禁改的全站 layout、一個住在收貨頁，這裡是第三份抄本；
 *    改任何一份都要三份一起改。 */
function isBranchAccount(user: { app_metadata?: Record<string, unknown> } | null | undefined): boolean {
  const stores = user?.app_metadata?.stores;
  if (!Array.isArray(stores) || stores.length === 0) return false;
  return !stores.includes("總倉");
}

/** 商品名一律帶 variant_name —— 與 /wms/receiving/ipad/page.tsx:225-234 的 rowTitle() 同一條規則：
 *  product_name 常常是上層品名，只印它現場會抓錯貨
 *  （G00213-01 的 product_name 是「台南日曬手工麵」，真正的東西
 *   「(A)關廟刀削麵」在 variant_name）。 */
function skuTitle(r: {
  product_name: string | null;
  variant_name: string | null;
  sku_code: string | null;
  sku_id: number;
}): string {
  const main = r.product_name?.trim() || r.sku_code || `#${r.sku_id}`;
  const sub = r.variant_name?.trim();
  return sub ? `${main} / ${sub}` : main;
}

/** 整數就不要拖著 .000（numeric(18,3) 的浮點尾巴很難看） */
function fmtQty(n: number): string {
  return Number.isInteger(n) ? String(n) : String(Number(n.toFixed(3)));
}

const STATUS_ZH: Record<string, string> = {
  draft: "草稿",
  sent: "已下單",
  partially_received: "部分到貨",
  fully_received: "已收齊",
  closed: "已結案",
  cancelled: "已取消",
};

// ---------------------------------------------------------------- 外殼

function Shell({
  title,
  subtitle,
  right,
  children,
}: {
  title: string;
  subtitle?: React.ReactNode;
  right?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div className="fixed inset-x-0 top-0 z-40 flex h-[100dvh] flex-col bg-zinc-100 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
      <header className="shrink-0 border-b border-zinc-300 bg-white px-4 py-3 dark:border-zinc-700 dark:bg-zinc-900">
        <div className="flex items-center gap-3">
          <div className="min-w-0 flex-1">
            <div className="truncate text-xl font-bold">{title}</div>
            {subtitle && (
              <div className="truncate text-sm text-zinc-600 dark:text-zinc-400">{subtitle}</div>
            )}
          </div>
          {right}
        </div>
      </header>
      <main className="min-h-0 flex-1 overflow-y-auto px-4 py-4">{children}</main>
    </div>
  );
}

// ---------------------------------------------------------------- 清單

type PoRow = {
  id: number;
  po_no: string;
  supplier_name: string | null;
  status: string;
  expected_date: string | null;
  item_count: number;
  stockout_items: number;
};

function PoList() {
  const [rows, setRows] = useState<PoRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [search, setSearch] = useState("");
  const [dSearch, setDSearch] = useState("");
  const [page, setPage] = useState(1);
  const [error, setError] = useState<string | null>(null);

  // 搜尋 debounce 300ms —— 與 purchase/orders/page.tsx:175-178 同一個數字
  useEffect(() => {
    const t = setTimeout(() => {
      setDSearch(search);
      setPage(1); // 換關鍵字就回第一頁，否則會停在空白的第 3 頁
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error: err } = await getSupabase().rpc("rpc_po_list", {
          p_status: null, // 全部狀態；樓下要翻的常常是已結案的舊單
          p_supplier_id: null,
          p_search: dSearch.trim() || null,
          p_date_from: null,
          p_date_to: null,
          p_sort: "updated_at",
          p_dir: "desc",
          p_page: page,
          p_page_size: PAGE_SIZE,
        });
        if (cancelled) return;
        if (err) throw err;
        const resp = data as { total: number; rows: PoRow[] } | null;
        setRows(resp?.rows ?? []);
        setTotal(Number(resp?.total ?? 0));
        setError(null);
      } catch (e) {
        if (!cancelled) {
          setError(translateRpcError(e));
          // ⛔ 失敗時**不要**把 rows 設成空陣列：那會畫出「沒有符合的採購單」，
          //   跟「查詢壞了」長得一模一樣。留 null 讓下面只顯示錯誤。
          setRows(null);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [dSearch, page]);

  const maxPage = Math.max(1, Math.ceil(total / PAGE_SIZE));

  return (
    <Shell
      title="📄 採購單（查看）"
      subtitle="只能看，不能在這裡收貨或改數量"
      right={
        <Link href="/wms/receiving/ipad" className={`${BTN_GHOST} shrink-0`}>
          回收貨
        </Link>
      }
    >
      <div className="mb-4">
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          type="text"
          enterKeyHint="search"
          autoComplete="off"
          autoCorrect="off"
          spellCheck={false}
          placeholder="🔍 打單號、廠商名或商品名"
          aria-label="搜尋採購單"
          className="min-h-[56px] w-full rounded-xl border-2 border-zinc-300 bg-white px-4 text-lg dark:border-zinc-600 dark:bg-zinc-950"
        />
      </div>

      {error && (
        <div className="mb-4 rounded-xl border border-red-300 bg-red-50 p-4 text-base font-medium text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
          ⚠ 採購單清單載入失敗：{error}
        </div>
      )}

      {rows === null && !error && <p className="text-lg text-zinc-500">載入中…</p>}

      {rows !== null && rows.length === 0 && (
        <p className="text-lg text-zinc-500">
          {dSearch.trim() ? `找不到符合「${dSearch.trim()}」的採購單。` : "目前沒有採購單。"}
        </p>
      )}

      {rows !== null && rows.length > 0 && (
        <>
          {/* ⭐ 數字要誠實：講「第幾頁 / 共幾張」，⛔ 不寫「全部」——
              這裡拿到的只有當頁 PAGE_SIZE 筆（分頁在 DB 做）。 */}
          <p className="mb-2 text-sm text-zinc-600 dark:text-zinc-400">
            共 {total} 張，這是第 {page} / {maxPage} 頁（每頁 {PAGE_SIZE} 張）
          </p>
          <ul className="flex flex-col gap-3">
            {rows.map((r) => (
              <li key={r.id}>
                <Link
                  href={`/wms/receiving/ipad/po?po=${r.id}`}
                  className="block min-h-[56px] touch-manipulation rounded-2xl border-2 border-zinc-300 bg-white p-3 active:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:active:bg-zinc-800"
                >
                  <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                    <span className="font-mono text-lg font-bold">{r.po_no}</span>
                    <span className="rounded-md bg-zinc-100 px-2 py-0.5 text-sm dark:bg-zinc-800">
                      {STATUS_ZH[r.status] ?? r.status}
                    </span>
                    {r.stockout_items > 0 && (
                      <span className="rounded-md bg-rose-100 px-2 py-0.5 text-sm text-rose-800 dark:bg-rose-950 dark:text-rose-200">
                        斷貨 {r.stockout_items} 項
                      </span>
                    )}
                  </div>
                  <div className="mt-1 text-base text-zinc-700 dark:text-zinc-300">
                    {r.supplier_name || "（沒有廠商）"} · {r.item_count} 項
                    {r.expected_date && ` · 預計 ${r.expected_date}`}
                  </div>
                </Link>
              </li>
            ))}
          </ul>

          <div className="mt-4 flex items-center justify-between gap-3">
            <SpinButton
              type="button"
              disabled={page <= 1}
              onClick={() => setPage((p) => Math.max(1, p - 1))}
              className={BTN_GHOST}
            >
              ← 上一頁
            </SpinButton>
            <span className="text-base">
              {page} / {maxPage}
            </span>
            <SpinButton
              type="button"
              disabled={page >= maxPage}
              onClick={() => setPage((p) => p + 1)}
              className={BTN_GHOST}
            >
              下一頁 →
            </SpinButton>
          </div>
        </>
      )}
    </Shell>
  );
}

// ---------------------------------------------------------------- 明細

type PoHead = { id: number; po_no: string; status: string; sent_at: string | null; supplier_name: string };
type PoItem = {
  id: number;
  sku_id: number;
  qty_ordered: number;
  qty_received: number;
  stockout_at: string | null;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

function PoDetail({ poId }: { poId: number }) {
  const [head, setHead] = useState<PoHead | null>(null);
  const [items, setItems] = useState<PoItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  // ⭐ 防連點走與收貨頁同一套 runExclusive（@/lib/receivingBatch）：
  //   ref 才擋得住同一 tick 的連點，state 只是給畫面用的鏡像。
  const busyRef = useRef<BusyKind | null>(null);
  const [busy, setBusy] = useState<BusyKind | null>(null);
  /** 正在寫哪一列（顯示 spinner 用）。⛔ 與 busy 分開：busy 決定「全部變灰」。 */
  const [writingSku, setWritingSku] = useState<number | null>(null);
  /** 已經寫進草稿的 sku（改按鈕字樣；⛔ 不用來擋，重按會被草稿那邊略過並講出來） */
  const [written, setWritten] = useState<Set<number>>(new Set());
  const [draftNotice, setDraftNotice] = useState<string | null>(null);
  const [draftError, setDraftError] = useState<string | null>(null);

  // ⭐ 載入寫成 effect 裡的 async IIFE ＋ cancelled 旗標
  //   （同 purchase/orders/page.tsx:183-209 的既有寫法），⛔ 不用 useCallback + void load()：
  //   1. 樓下在清單與明細之間跳來跳去時，前一張單的回應可能晚於後一張 ——
  //      cancelled 保證只有最後一次的結果會進畫面（沒有它就會看到別張單的品項）。
  //   2. 那種寫法會踩 react-hooks/set-state-in-effect（本 repo 已有 13 處，
  //      ⛔ 不要再多一處）。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        // 查法逐項對齊 purchase/orders/receive/page.tsx:118-119
        const [{ data: po, error: poErr }, { data: rawItems, error: itemErr }] = await Promise.all([
          sb
            .from("purchase_orders")
            .select("id, po_no, status, sent_at, suppliers(name)")
            .eq("id", poId)
            .single(),
          sb
            .from("purchase_order_items")
            .select("id, sku_id, qty_ordered, qty_received, stockout_at")
            .eq("po_id", poId)
            .order("id"),
        ]);
        if (poErr) throw poErr;
        if (itemErr) throw itemErr;
        if (!po) throw new Error(`找不到採購單 #${poId}`);

        type Raw = {
          id: number;
          sku_id: number;
          qty_ordered: number;
          qty_received: number | null;
          stockout_at: string | null;
        };
        const raws = (rawItems ?? []) as Raw[];
        const skuIds = Array.from(new Set(raws.map((r) => Number(r.sku_id))));
        const skuMap = new Map<
          number,
          { sku_code: string | null; product_name: string | null; variant_name: string | null }
        >();
        if (skuIds.length > 0) {
          // ⚠ 分批 300 個 id：PostgREST 單次 1000 列上限 ＋ 網址長度（414）兩邊都要顧
          //   （同 /wms/receiving/ipad/page.tsx:149-152 的 SKU_CHUNK）。
          for (let i = 0; i < skuIds.length; i += 300) {
            const { data: sk, error: skErr } = await sb
              .from("skus")
              .select("id, sku_code, product_name, variant_name")
              .in("id", skuIds.slice(i, i + 300));
            if (skErr) throw skErr;
            for (const s of (sk ?? []) as {
              id: number;
              sku_code: string | null;
              product_name: string | null;
              variant_name: string | null;
            }[]) {
              skuMap.set(Number(s.id), {
                sku_code: s.sku_code,
                product_name: s.product_name,
                variant_name: s.variant_name,
              });
            }
          }
        }

        // ⛔ setState 全部集中在這裡（所有 await 都跑完之後）：中途才發現商品撈失敗時，
        //   畫面不會停在「表頭已換、品項還是上一張」的半新半舊狀態。
        if (cancelled) return;
        const sup = (po as { suppliers?: { name: string } | { name: string }[] | null }).suppliers;
        const supplierName = Array.isArray(sup) ? sup[0]?.name ?? "" : sup?.name ?? "";
        setHead({
          id: Number((po as { id: number }).id),
          po_no: (po as { po_no: string }).po_no,
          status: (po as { status: string }).status,
          sent_at: (po as { sent_at: string | null }).sent_at,
          supplier_name: supplierName,
        });
        setItems(
          raws.map((r) => {
            const s = skuMap.get(Number(r.sku_id));
            return {
              id: Number(r.id),
              sku_id: Number(r.sku_id),
              qty_ordered: Number(r.qty_ordered),
              qty_received: Number(r.qty_received ?? 0),
              stockout_at: r.stockout_at,
              sku_code: s?.sku_code ?? null,
              product_name: s?.product_name ?? null,
              variant_name: s?.variant_name ?? null,
            };
          }),
        );
        setError(null);
      } catch (e) {
        if (cancelled) return;
        setError(translateRpcError(e));
        // ⛔ 不要把 items 設成 []：那會畫出「這張單沒有品項」，與「查詢失敗」混淆
        setItems(null);
        setHead(null);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [poId]);

  /**
   * 把這一列寫進今天的撿貨草稿。
   *
   * ⭐⭐ 帶出的數量 ＝ **這一列的累計實收量（qty_received）**。
   *   ⚠ 與收貨頁那顆鈕（帶「這次實收」）**不是同一個數字** ——
   *     這一頁看的是整張單的累計，沒有「這一次」可言。
   *     ⇒ 畫面上一定要把數字寫出來，⛔ 不可以只寫「帶出數量」讓人自己猜是哪個。
   *
   * ⛔ 實收 0 的列不給按：帶 0 過去會建出一排 0 的格子，
   *   跟「查詢失敗」與「真的沒人要」三種情況在畫面上分不出來。
   */
  async function writeToDraft(it: PoItem) {
    if (!head) return;
    const label = skuTitle(it);
    const held = await runExclusive(busyRef, "draft", setBusy, async () => {
      setWritingSku(it.sku_id);
      setDraftNotice(null);
      setDraftError(null);
      try {
        const sb = getSupabase();
        const report = await handoffToDraft(
          {
            db: sb,
            fetchAll: fetchAllRows,
            describeError: describeDraftDbError,
            session: async () => {
              const { data } = await sb.auth.getSession();
              const tenantId = (
                data.session?.user?.app_metadata as Record<string, unknown> | undefined
              )?.tenant_id as string | undefined;
              if (!tenantId) throw new Error("JWT 缺 tenant_id claim、無法寫入撿貨草稿");
              return { tenantId, uid: data.session?.user?.id ?? null };
            },
          },
          {
            skus: [
              { sku_id: it.sku_id, sku_code: it.sku_code, label, qty: it.qty_received },
            ],
            source: {
              po_nos: [head.po_no],
              // ⓘ 這一頁帶的是**累計**實收，不對應單一張進貨單 → gr_nos 留空才誠實。
              gr_nos: [],
              at: new Date().toISOString(),
            },
            // ⭐⭐ ⛔ 不可以是 "this_receipt"（阿審 2026-09-02 P1）：
            //   這一頁餵的是 qty_received ＝ **整張單累計實收**，沒有「這一次」可言。
            //   標錯口徑，共用訊息就會把「累計 80」講成「這次收 80」，
            //   老闆會以為今天真的到了 80 件。
            qtyBasis: "cumulative",
          },
        );
        const msg = handoffMessage(report);
        setDraftNotice(msg.notice);
        setDraftError(msg.error);
        // ⓘ raced（被別台搶先加）也算「這一列處理過了」：商品確實在草稿裡，
        //   按鈕字樣要跟著改，不然他會一直重按。
        if (report.added.length > 0 || report.skipped.length > 0 || report.raced.length > 0) {
          setWritten((prev) => new Set(prev).add(it.sku_id));
        }
      } finally {
        setWritingSku(null);
      }
    });
    // ⓘ 這一頁的 busyRef 只有 writeToDraft 在用（唯一的 kind 是 "draft"），
    //   所以 held 只可能是 "draft" ⇒ 不必像收貨頁那樣分三種講法。
    //   ⚠ 哪天這一頁多一個非同步動作，這裡就要跟著分支。
    if (held) {
      setDraftError("上一筆還在寫入撿貨草稿，等它跑完再按。");
    }
  }

  return (
    <Shell
      title={head ? `📄 ${head.po_no}` : `📄 採購單 #${poId}`}
      subtitle={
        head
          ? `${head.supplier_name || "（沒有廠商）"} · ${STATUS_ZH[head.status] ?? head.status}${
              head.sent_at ? ` · 送單 ${head.sent_at.slice(0, 10)}` : ""
            }`
          : undefined
      }
      right={
        <Link href="/wms/receiving/ipad/po" className={`${BTN_GHOST} shrink-0`}>
          ← 清單
        </Link>
      }
    >
      {error && (
        <div className="mb-4 rounded-xl border border-red-300 bg-red-50 p-4 text-base font-medium text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
          ⚠ 這張採購單載入失敗：{error}
        </div>
      )}

      {draftNotice && (
        <div className="mb-4 rounded-xl border-2 border-indigo-300 bg-indigo-50 p-3 text-base text-zinc-800 dark:border-indigo-800 dark:bg-indigo-950/40 dark:text-zinc-200">
          {draftNotice}
          <p className="mt-2">
            <Link
              href="/picking/drafts"
              className="font-semibold text-indigo-700 underline dark:text-indigo-300"
            >
              去撿貨草稿頁分各店 →
            </Link>
          </p>
        </div>
      )}
      {draftError && (
        <div className="mb-4 rounded-xl border-2 border-rose-300 bg-rose-50 p-3 text-base font-medium text-rose-800 dark:border-rose-800 dark:bg-rose-950/50 dark:text-rose-200">
          {draftError}
        </div>
      )}

      {items === null && !error && <p className="text-lg text-zinc-500">載入中…</p>}

      {items !== null && items.length === 0 && (
        <p className="text-lg text-zinc-500">這張採購單沒有任何品項。</p>
      )}

      {items !== null && items.length > 0 && (
        <ul className="flex flex-col gap-3">
          {items.map((it) => {
            const short = it.qty_ordered - it.qty_received;
            const canWrite = it.qty_received > 0;
            return (
              <li
                key={it.id}
                className="rounded-2xl border-2 border-zinc-300 bg-white p-3 dark:border-zinc-700 dark:bg-zinc-900"
              >
                <div className="text-lg font-bold">{skuTitle(it)}</div>
                <div className="mt-0.5 font-mono text-sm text-zinc-500">{it.sku_code ?? "—"}</div>

                <div className="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-base">
                  <span>
                    訂購 <span className="font-bold">{fmtQty(it.qty_ordered)}</span>
                  </span>
                  <span>
                    實收 <span className="font-bold">{fmtQty(it.qty_received)}</span>
                  </span>
                  {/* ⛔ 只在真的少於訂購時才講「短少」：超收時 short 是負數，
                      印成「短少 -5」是說了一件不是事實的事。 */}
                  {short > 0 && (
                    <span className="text-amber-800 dark:text-amber-300">
                      短少 <span className="font-bold">{fmtQty(short)}</span>
                    </span>
                  )}
                  {short < 0 && (
                    <span className="text-sky-800 dark:text-sky-300">
                      超收 <span className="font-bold">{fmtQty(-short)}</span>
                    </span>
                  )}
                  {it.stockout_at && (
                    <span className="rounded-md bg-rose-100 px-2 py-0.5 text-sm text-rose-800 dark:bg-rose-950 dark:text-rose-200">
                      已標斷貨
                    </span>
                  )}
                </div>

                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <SpinButton
                    type="button"
                    disabled={!canWrite || (busy !== null && writingSku !== it.sku_id)}
                    onClick={() => writeToDraft(it)}
                    className={`${BTN_SMALL} bg-indigo-600 text-white active:bg-indigo-700 disabled:bg-zinc-300 dark:disabled:bg-zinc-700`}
                  >
                    {writingSku === it.sku_id
                      ? "寫入中…"
                      : written.has(it.sku_id)
                        ? "📋 再寫一次"
                        : "📋 寫入撿貨草稿"}
                  </SpinButton>
                  {/* ⛔ 停用原因與帶出的數字都要看得見（iPad 沒有 tooltip）。
                      ⭐ 這句話要精確到「哪一個數字」：這一頁帶的是**累計實收**，
                         與收貨頁那顆鈕（帶「這次實收」）不是同一個數字。 */}
                  <span className="text-sm text-zinc-600 dark:text-zinc-400">
                    {!canWrite
                      ? "這一項還沒有收到任何貨，沒有數量可以帶。"
                      : busy !== null && writingSku !== it.sku_id
                        ? "上一筆還在寫，等它跑完。"
                        : `會把累計實收 ${fmtQty(it.qty_received)} 件帶進今天的撿貨草稿（各店依未派需求分，不扣庫存）。`}
                  </span>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </Shell>
  );
}

// ---------------------------------------------------------------- 入口

function PoPageInner() {
  const { user, loading: authLoading } = useAuth();
  const params = useSearchParams();
  const raw = params.get("po");
  const poId = raw && /^\d+$/.test(raw) ? Number(raw) : null;

  // 分店帳號：明確擋下並給出口。⛔ 不可以白畫面、不可以無聲失敗。
  // （與 /wms/receiving/ipad/page.tsx:992-1018 同一套處理）
  if (authLoading || isBranchAccount(user)) {
    return (
      <div className="fixed inset-x-0 top-0 z-40 flex h-[100dvh] flex-col items-center justify-center gap-5 bg-zinc-100 px-6 text-center dark:bg-zinc-950">
        {authLoading ? (
          <p className="text-lg text-zinc-500">載入中…</p>
        ) : (
          <>
            <div className="text-5xl">🔒</div>
            <div className="text-2xl font-bold">這個功能限總部使用</div>
            <p className="max-w-md text-base text-zinc-600 dark:text-zinc-400">
              採購單是總部的單據，分店帳號不能看這一頁。
            </p>
            <Link href="/" className={`${BTN_PRIMARY} text-lg`}>
              回首頁
            </Link>
          </>
        )}
      </div>
    );
  }

  return poId === null ? <PoList /> : <PoDetail poId={poId} />;
}

export default function IpadPoPage() {
  // useSearchParams 需要 Suspense 邊界（同 purchase/orders/receive/page.tsx:74-79）
  return (
    <Suspense fallback={<div className="p-6 text-lg text-zinc-500">載入中…</div>}>
      <PoPageInner />
    </Suspense>
  );
}

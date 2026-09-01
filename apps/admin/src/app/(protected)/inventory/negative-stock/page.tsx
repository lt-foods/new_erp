"use client";

/**
 * 負庫存報表（總倉用）—— 一頁看完全部倉別 `stock_balances.on_hand < 0` 的每一列。
 *
 * 由來：「取貨有貨就給」（退貨大案 F）上線後會真的做出負庫存
 *   （老闆 2026-08-22 裁示：K 沒做完 F 不可上線）。庫存總覽一次只看得到
 *   一間店，負庫存散在 15 個倉別裡沒有人看得到全貌。
 *
 * ⛔ 純唯讀：本頁只有 SELECT，不呼叫任何 RPC、不寫任何一張表。
 *   要修正負庫存請走盤點（/inventory/stocktake）或庫存總覽的「＋ 新增庫存」。
 *
 * 資料來源與庫存總覽同一套（inventory/page.tsx）：
 *   · 清單 = stock_balances（location_id / sku_id / on_hand / last_movement_at）
 *   · 展開 = stock_movements 最近 N 筆（同一支查詢，只多了 id 的 tiebreak）
 *   差別只有：拿掉「單一倉別」限制、加上 on_hand < 0，並改成「負最多的排最前面」。
 *
 * 分頁：走伺服端 range + count:exact，**不是**把整份撈回前端再切。
 *   → 每次請求最多 PAGE_SIZE 列，結構上碰不到 PostgREST 的 1000 列上限；
 *     總筆數由 count 標頭給，就算超過 1000 也是真實數字，不會被靜默截掉
 *     （公司踩過的坑就是「靜默截斷」，畫面看起來正常但後面的資料整批消失）。
 */

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { useAuth } from "@/components/AuthProvider";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import SpinButton from "@/components/SpinButton";
import { maskLineUserId } from "@/lib/maskLineUserId";

type Loc = { id: number; code: string; name: string; type: string; is_active: boolean };
type StoreRow = { id: number; name: string; location_id: number | null; is_active: boolean };
type NegRow = {
  location_id: number;
  sku_id: number;
  on_hand: number;
  last_movement_at: string | null;
};
type Sku = { id: number; sku_code: string; product_name: string | null; variant_name: string | null };
type Movement = {
  id: number;
  quantity: number;
  movement_type: string;
  source_doc_type: string | null;
  source_doc_id: number | null;
  reason: string | null;
  notes: string | null;
  created_at: string;
  /** ★ 前端往回推算出來的，**不是** DB 欄位 —— stock_movements 沒有存餘額。
   *  推法見 buildMovementDetail()。撈不到目前在庫時為 null（不猜、直接顯示「—」）。 */
  balanceAfter: number | null;
  /** 同上，這一筆「異動之前」的餘額。給「轉負」徽章的 tooltip 用 ——
   *  ⛔ 不可以在畫面上用 balanceAfter - quantity 現算：那又是一次浮點減法。 */
  balanceBefore: number | null;
};
type MovementDetail = {
  /** 展開當下重撈的在庫量，往回推餘額的錨點 */
  onHandNow: number | null;
  moves: Movement[];
  /** 把餘額壓成負數的那一筆（找不到＝更早之前就已經是負的） */
  culpritId: number | null;
  /** false ＝ 異動筆數撞到 MOVE_LIMIT，看到的不是完整歷史 */
  complete: boolean;
};

const PAGE_SIZE = 100;
/** 展開列一次撈幾筆異動。與庫存總覽的 50 筆同量級，多給一倍是因為
 *  本頁的用途就是「往回找元凶」，被截斷的機會比單純看近況高。 */
const MOVE_LIMIT = 100;

// 對照 stock_movements.movement_type 的 **最新版** CHECK：
//   20260713000000_stock_movements_allow_transfer_cancel.sql:26-41 —— 共 13 個值。
// 全 repo 只有三支 migration 動過這條 constraint（20260422120003 建 11 個 →
//   20260512000007 加 transfer_reject → 20260713000000 加 transfer_cancel），
//   下面 13 個就是完整清單，沒有第 14 種。
//   查法：grep -rln "stock_movements_movement_type_check\|movement_type IN (" supabase/migrations
//
// ⚠ 這份與 inventory/page.tsx:64 是兩份（那邊目前**只有最早的 11 個**，
//   transfer_reject / transfer_cancel 在庫存總覽會顯示英文原始值）。
//   刻意照抄而不是抽成共用檔：庫存總覽是熱門檔案（近期 #865 / #834 / #766 都動過），
//   為了一個顯示用字典去改它會讓別人的 PR 多一個衝突點。
//   查無對應時直接顯示原始值，不會靜靜吃掉新增的類型。
const MOVE_LABEL: Record<string, string> = {
  purchase_receipt: "進貨",
  return_to_supplier: "退供應商",
  sale: "銷售出貨",
  customer_return: "客退入庫",
  transfer_out: "調撥出",
  transfer_in: "調撥入",
  // 對方拒收 → 貨回流到出貨的那一端（20260512000007:9-10）
  transfer_reject: "拒收回流",
  // 在途被撤回 → 貨記回出貨來源（20260713000000:12-13）
  transfer_cancel: "撤回回流",
  stocktake_gain: "盤盈",
  stocktake_loss: "盤虧",
  damage: "報廢/損壞",
  manual_adjust: "手動調整",
  reversal: "沖銷",
};

const LINE_ID_RE = /U[0-9a-f]{32}/gi;
/** 原因／備註是自由輸入，可能被貼進 LINE User ID —— 比照 inventory/page.tsx:80 遮掉 */
function maskFreeText(s: string | null): string {
  if (!s) return "";
  return s.replace(LINE_ID_RE, (m) => maskLineUserId(m));
}

function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}
function fmtQty(v: number): string {
  // NUMERIC(18,3) — 去掉無意義小數
  return Number(v.toFixed(3)).toLocaleString("zh-TW");
}
function fmtDateTime(s: string | null): string {
  if (!s) return "—";
  return new Date(s).toLocaleString("zh-TW", { hour12: false });
}

/** 商品名一律帶 variant_name：product_name 常常是上層品名，只看它會抓錯貨
 *  （比照 wms/receiving/ipad/page.tsx:230 的 rowTitle）。 */
function skuTitle(sku: Sku | undefined, skuId: number): string {
  const main = sku?.product_name?.trim() || sku?.sku_code || `sku#${skuId}`;
  const sub = sku?.variant_name?.trim();
  return sub ? `${main} / ${sub}` : main;
}

/** 分店帳號判定 —— 與 (protected)/layout.tsx:137 的 isBranchUser() 等價。
 *  ⚠ 那支住在全站 layout，這裡照抄一份（比照 wms/receiving/ipad/page.tsx:200）；改那邊記得改這邊。
 *  ⚠ 刻意**不**用 role.ts 的 isHqRole()：它的 HQ_ROLES 是 owner/admin/hq_manager/
 *    hq_accountant/""，與 stock_balances 的 RLS 對不起來 ——
 *    RLS 放行的是 owner/purchaser/warehouse/reporter（20260422120003:390）
 *    ＋ admin/hq_manager（20260614000042:25）。用 isHqRole 會把倉管(warehouse)、
 *    採購(purchaser)擋在門外，卻放 hq_accountant 進來看一頁空白。 */
function isBranchAccount(user: { app_metadata?: Record<string, unknown> } | null | undefined): boolean {
  const stores = user?.app_metadata?.stores;
  if (!Array.isArray(stores) || stores.length === 0) return false;
  return !stores.includes("總倉");
}

/**
 * 把「最近 N 筆異動」還原成每一筆的「異動後餘額」，並找出把它壓成負的那一筆。
 *
 * 為什麼用推的：stock_movements **沒有**餘額欄位（20260422120003:47-78 的建表
 *   只有 quantity，沒有 balance_after / on_hand_after）。
 * 為什麼推得準：stock_balances.on_hand 全站只有一個地方會改 ——
 *   trigger apply_movement_to_balance（20260422120003:240，全 repo 唯一一版，
 *   也是唯一一句 `UPDATE stock_balances ... SET on_hand =`）。
 *   所以 on_hand 恆等於這個 (倉別, SKU) 所有 movement 的 quantity 總和，
 *   從最新那筆往回一路減，得到的就是每一筆當下的餘額。
 *
 * moves 必須是「由新到舊、且從最新那筆開始不中斷」——
 *   中間漏一筆整排就會錯開，所以查詢排序用 (created_at DESC, id DESC)：
 *   created_at 預設 NOW()＝交易開始時間，同一筆交易寫入的多列會完全相同，
 *   只靠它排序在同交易多列時是不定序（id 是 BIGSERIAL，補上才有全序）。
 */
function buildMovementDetail(
  raw: Movement[],
  onHandNow: number | null,
  hitLimit: boolean,
): MovementDetail {
  if (onHandNow == null) {
    return {
      onHandNow: null,
      moves: raw.map((m) => ({ ...m, balanceAfter: null, balanceBefore: null })),
      culpritId: null,
      complete: !hitLimit,
    };
  }

  // ⭐⭐ 整段算術一律先換成「千分之一件」的整數再做，⛔ 不可以直接用小數相減。
  //   數量是 NUMERIC(18,3)（20260422120003:52），JSON 回來就是 JS 浮點數。
  //   直接連減會累積誤差，讓「本來剛好是 0」變成 -5.5e-17 之類的極小負數，
  //   於是「這筆之前還沒負」的判斷失敗、迴圈繼續往更舊走 →
  //   **指到錯的元凶、或整個回 null 而在畫面上謊稱「更早之前就已經是負的」**。
  //   ⚠ 這不是理論風險：離線隨機測試 40 萬組三位小數序列找得到反例，
  //     例如由舊到新 [-1.1, -0.001, -0.001, -0.3, +0.05, -0.7]（on_hand = -2.052）
  //     真正的元凶是第一筆，小數版卻回 null。反例已固定成單元測試。
  //   乘 1000 四捨五入後就是 NUMERIC(18,3) 的精確整數值，加減完全沒有誤差
  //   （庫存量級離 Number.MAX_SAFE_INTEGER ≈ 9.0e15 很遠，不會溢位）。
  const milli = (v: number) => Math.round(v * 1000);
  const fromMilli = (v: number) => v / 1000;

  let runningMilli = milli(onHandNow);
  // 由新到舊走：目前是負的，一路往回找到「這筆之前還沒負」的那一筆＝元凶。
  // 中途遇到餘額已經 ≥ 0 就停 —— 再往舊找的都是另一段歷史，不是造成現在這個負數的原因。
  let culpritId: number | null = null;
  let culpritSettled = false;
  const moves = raw.map((m) => {
    const afterMilli = runningMilli;
    const beforeMilli = runningMilli - milli(m.quantity);
    runningMilli = beforeMilli;
    if (!culpritSettled) {
      if (afterMilli >= 0) {
        culpritSettled = true; // 這一刻還不是負的 → 不必再往舊找
      } else if (beforeMilli >= 0) {
        culpritId = m.id; // 這筆之前還沒負、之後負了 → 就是它
        culpritSettled = true;
      }
    }
    return { ...m, balanceAfter: fromMilli(afterMilli), balanceBefore: fromMilli(beforeMilli) };
  });

  return { onHandNow, moves, culpritId, complete: !hitLimit };
}

export default function NegativeStockPage() {
  const { user, loading: authLoading } = useAuth();
  const branchBlocked = !authLoading && isBranchAccount(user);

  const [locs, setLocs] = useState<Loc[]>([]);
  const [stores, setStores] = useState<StoreRow[]>([]);

  const [locationId, setLocationId] = useState<string>("");
  const [page, setPage] = useState(1);

  // rows === null ＝ 載入中。刻意不另開 loading 布林：那個非得在 effect body
  // 同步 setState(true) 不可，就是 react-hooks/set-state-in-effect 擋的寫法。
  const [rows, setRows] = useState<NegRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [skuMap, setSkuMap] = useState<Map<number, Sku>>(new Map());

  const [expanded, setExpanded] = useState<string | null>(null);
  const [moveCache, setMoveCache] = useState<Map<string, MovementDetail>>(new Map());
  const [moveLoading, setMoveLoading] = useState(false);

  // 篩選來源（一次載入）
  useEffect(() => {
    if (authLoading || branchBlocked) return;
    let cancelled = false;
    void (async () => {
      // 先讓出一個 microtask：getSupabase() 會同步 throw（缺環境變數時），
      // 不讓出的話 catch 裡的 setState 會落在 effect body 的同一個 tick
      // ——就是 react-hooks/set-state-in-effect 講的連鎖 render。
      // ⛔ 不要改成 eslint-disable（寫法比照 wms/receiving/ipad/page.tsx:644）。
      await Promise.resolve();
      if (cancelled) return;
      try {
        const sb = getSupabase();
        const [l, s] = await Promise.all([
          // ⚠ 兩張表都**不**加 is_active 篩選：兩店合併（rpc_merge_stores）會把
          //   負庫存刻意留在來源倉別、同時停用來源店（20260817000040:254-259）。
          //   只撈 active 的話，那些負庫存會變成一列沒有名字的「#12」——
          //   而這一頁的重點就是「一個都不能漏」，寧可多列也不要靜靜吃掉。
          sb.from("locations").select("id, code, name, type, is_active").order("type").order("name"),
          // is_active 是拿來標「已停用」徽章的。
          // ⚠ 停用旗標要看 **stores** 不是 locations：rpc_merge_stores 關的是
          //   `UPDATE stores SET is_active = FALSE`（:256），全 repo 沒有任何一句
          //   `UPDATE locations`（grep -rn "UPDATE locations" supabase/migrations → 0 命中）
          //   ⇒ 早先這裡讀 locations.is_active 的徽章其實**永遠不會亮**。
          sb.from("stores").select("id, name, location_id, is_active").order("name"),
        ]);
        if (cancelled) return;
        setLocs((l.data as Loc[]) ?? []);
        setStores((s.data as StoreRow[]) ?? []);
      } catch {
        /* 篩選下拉載不出來不影響主表；主表自己會報錯 */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [authLoading, branchBlocked]);

  // 主查詢
  useEffect(() => {
    if (authLoading || branchBlocked) return;
    let cancelled = false;
    void (async () => {
      await Promise.resolve(); // 同上：避開 effect body 同步 setState
      if (cancelled) return;
      try {
        const sb = getSupabase();
        let q = sb
          .from("stock_balances")
          .select("location_id, sku_id, on_hand, last_movement_at", { count: "exact" })
          .lt("on_hand", 0)
          // 負最多的排最前面。後兩個 order 是分頁用的 tiebreak ——
          // on_hand 會大量打平（−1 特別多），只用它排序時 range 分頁會跨頁
          // 漏列／重複列（@/lib/fetchAllRows 檔頭講的是同一件事）。
          // 補上 (location_id, sku_id) 就是主鍵的後兩段，保證全序。
          .order("on_hand", { ascending: true })
          .order("location_id", { ascending: true })
          .order("sku_id", { ascending: true })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
        if (locationId) q = q.eq("location_id", Number(locationId));
        const { data, count, error: qErr } = await q;
        if (qErr) throw qErr;
        if (cancelled) return;

        const pageRows = ((data as unknown as NegRow[]) ?? []).map((r) => ({
          ...r,
          on_hand: num(r.on_hand),
        }));
        setError(null);
        setRows(pageRows);
        setTotal(count ?? 0);

        // 商品名只撈本頁看得到的那些（≤ PAGE_SIZE 個 id），
        // 不會因為全站負庫存變多就把 in() 的網址撐爆。
        const skuIds = Array.from(new Set(pageRows.map((r) => r.sku_id)));
        if (skuIds.length === 0) {
          setSkuMap(new Map());
          return;
        }
        const { data: sk } = await sb
          .from("skus")
          .select("id, sku_code, product_name, variant_name")
          .in("id", skuIds);
        if (cancelled) return;
        const sm = new Map<number, Sku>();
        for (const s of (sk as Sku[]) ?? []) sm.set(s.id, s);
        setSkuMap(sm);
      } catch (e) {
        if (!cancelled) {
          setRows([]);
          setError(e instanceof Error ? e.message : String(e));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [locationId, page, authLoading, branchBlocked]);

  const storeByLoc = useMemo(() => {
    const m = new Map<number, StoreRow>();
    for (const s of stores) if (s.location_id != null) m.set(s.location_id, s);
    return m;
  }, [stores]);
  const locById = useMemo(() => new Map(locs.map((l) => [l.id, l])), [locs]);
  const locLabel = (id: number) => {
    const l = locById.get(id);
    if (!l) return `#${id}`;
    return storeByLoc.get(id)?.name ?? l.name;
  };

  /** 換條件／換頁：把表格打回「載入中」狀態並收起展開列。
   *  放在事件處理器裡（不是 effect），才不會踩 set-state-in-effect。 */
  function resetView() {
    setRows(null);
    setExpanded(null);
  }
  function changeLocation(v: string) {
    setLocationId(v);
    setPage(1);
    resetView();
  }
  function goPage(p: number) {
    setPage(p);
    resetView();
  }

  async function toggleExpand(key: string, loc: number, sku: number) {
    if (expanded === key) {
      setExpanded(null);
      return;
    }
    setExpanded(key);
    if (moveCache.has(key)) return;
    setMoveLoading(true);
    try {
      const sb = getSupabase();
      const [mv, bal] = await Promise.all([
        sb
          .from("stock_movements")
          .select("id, quantity, movement_type, source_doc_type, source_doc_id, reason, notes, created_at")
          .eq("location_id", loc)
          .eq("sku_id", sku)
          // id 的 tiebreak 不可省：同一筆交易寫入的多列 created_at 完全相同
          // （DEFAULT NOW() 是交易時間），少了它同交易多列是不定序，
          // 往回推的餘額就會亂跳（見 buildMovementDetail 的說明）。
          .order("created_at", { ascending: false })
          .order("id", { ascending: false })
          .limit(MOVE_LIMIT),
        // 餘額當下重撈一次：上面那張表是「列表載入當時」的快照，
        // 隔了一段時間才點開的話會跟異動清單對不起來，往回推的餘額整排錯開。
        sb.from("stock_balances").select("on_hand").eq("location_id", loc).eq("sku_id", sku).maybeSingle(),
      ]);
      const raw = ((mv.data as Movement[]) ?? []).map((m) => ({
        ...m,
        quantity: num(m.quantity),
        balanceAfter: null,
        balanceBefore: null,
      }));
      const balRow = bal.data as { on_hand: number } | null;
      const detail = buildMovementDetail(raw, balRow ? num(balRow.on_hand) : null, raw.length >= MOVE_LIMIT);
      setMoveCache((c) => new Map(c).set(key, detail));
    } finally {
      setMoveLoading(false);
    }
  }

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);
  const colCount = 5;

  // 分店帳號：明確擋下並給出口。⛔ 不可以白畫面、不可以無聲失敗。
  // （資料層本來就擋得住 —— stock_balances 的 store_read_own 只放行自己店的
  //   倉別；這一層是為了不要讓人看到一頁只有自己店、卻自稱「全部門市」的報表。）
  if (authLoading || branchBlocked) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-4 p-6 text-center">
        {authLoading ? (
          <p className="text-sm text-zinc-500">載入中…</p>
        ) : (
          <>
            <div className="text-4xl">🔒</div>
            <div className="text-lg font-semibold">這個功能限總部使用</div>
            <p className="max-w-md text-sm text-zinc-600 dark:text-zinc-400">
              這一頁是把全部門市的負庫存放在一起看，分店帳號不能用。
              自己店的庫存請看「庫存總覽」。
            </p>
            <div className="flex flex-wrap justify-center gap-3">
              <Link
                href="/inventory"
                className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700"
              >
                去庫存總覽
              </Link>
              <Link
                href="/"
                className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                回首頁
              </Link>
            </div>
          </>
        )}
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">負庫存報表</h1>
          <p className="text-sm text-zinc-500">
            {rows === null ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（${fromIdx}-${toIdx}）`}
          </p>
        </div>
        <Link
          href="/inventory"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          ← 庫存總覽
        </Link>
      </header>

      <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs leading-relaxed text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
        這裡列出所有「帳上是負數」的庫存：這個倉別的這樣商品，出的比進的多。
        負最多的排在最前面。點一列可以往回看它的庫存異動，找出是哪一筆壓成負的。
        <br />
        這一頁<span className="font-semibold">只看不改</span>。要把數字修回來，走
        <Link href="/inventory/stocktake" className="mx-1 underline hover:text-zinc-900 dark:hover:text-zinc-100">
          盤點
        </Link>
        或
        <Link href="/inventory" className="mx-1 underline hover:text-zinc-900 dark:hover:text-zinc-100">
          庫存總覽
        </Link>
        的「＋ 新增庫存」。
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
        <select
          value={locationId}
          onChange={(e) => changeLocation(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部倉別</option>
          {locs
            .filter((l) => l.is_active)
            .map((l) => (
              <option key={l.id} value={l.id}>
                {storeByLoc.get(l.id)?.name ?? l.name}
                {l.type === "central_warehouse" ? "（總倉）" : ""}
                {/* 收掉的店照樣留在選單裡（它的負庫存還在，要查得到），標出來就好 */}
                {storeByLoc.get(l.id)?.is_active === false ? "（已停用）" : ""}
              </option>
            ))}
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <Table>
        <THead>
          <Th>倉別 / 門市</Th>
          <Th>商品 / SKU</Th>
          <Th align="right">負幾個</Th>
          <Th align="right">最後異動</Th>
          <Th />
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={colCount} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={colCount}>
              {locationId ? "這個倉別目前沒有負庫存。" : "目前全站沒有負庫存。"}
            </EmptyRow>
          ) : (
            rows.flatMap((r) => {
              const key = `${r.location_id}-${r.sku_id}`;
              const sku = skuMap.get(r.sku_id);
              const loc = locById.get(r.location_id);
              const store = storeByLoc.get(r.location_id);
              const open = expanded === key;
              const out: React.ReactNode[] = [
                <Tr key={key} onClick={() => toggleExpand(key, r.location_id, r.sku_id)}>
                  <Td className="text-xs">
                    {locLabel(r.location_id)}
                    {loc?.type === "central_warehouse" && <span className="ml-1 text-zinc-400">（總倉）</span>}
                    {/* 收掉的店照樣列出來（兩店合併刻意把負庫存留在原地），但要標出來，
                        不然看的人會納悶「這間店不是關了嗎」。
                        ⚠ 旗標讀 **stores.is_active**，不是 locations.is_active ——
                          rpc_merge_stores 關的是 stores（20260817000040:256），
                          全 repo 沒有任何一句 `UPDATE locations`，
                          讀 locations 的話這個徽章永遠不會亮。 */}
                    {store != null && !store.is_active && (
                      <span
                        className="ml-1 rounded bg-zinc-200 px-1 text-[10px] text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
                        title="這間門市已經停用（例如兩店合併收店），但它名下還有負庫存沒有處理掉"
                      >
                        已停用
                      </span>
                    )}
                  </Td>
                  <Td>
                    <div className="font-medium text-zinc-900 dark:text-zinc-100">{skuTitle(sku, r.sku_id)}</div>
                    <div className="font-mono text-xs text-zinc-500">{sku?.sku_code ?? `sku#${r.sku_id}`}</div>
                  </Td>
                  <Td align="right" className="font-mono font-semibold text-red-600 dark:text-red-400">
                    {fmtQty(r.on_hand)}
                  </Td>
                  <Td align="right" className="text-xs text-zinc-500">
                    <span title={fmtDateTime(r.last_movement_at)}>
                      {r.last_movement_at
                        ? new Date(r.last_movement_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" })
                        : "—"}
                    </span>
                  </Td>
                  <Td align="right" className="text-xs text-zinc-400">
                    {open ? "▾" : "▸"}
                  </Td>
                </Tr>,
              ];
              if (open) {
                const detail = moveCache.get(key);
                out.push(
                  <tr key={`${key}-detail`} className="bg-zinc-50 dark:bg-zinc-900/50">
                    <td colSpan={colCount} className="px-4 py-3">
                      <div className="text-xs font-medium text-zinc-500">
                        最近 {MOVE_LIMIT} 筆庫存異動
                        {detail?.complete === false && (
                          <span className="ml-2 text-amber-600 dark:text-amber-400">
                            （已達 {MOVE_LIMIT} 筆上限，更早的異動沒有列出來）
                          </span>
                        )}
                      </div>
                      {moveLoading && !detail ? (
                        <div className="py-3 text-center text-sm text-zinc-500">載入中…</div>
                      ) : !detail || detail.moves.length === 0 ? (
                        <div className="py-3 text-center text-sm text-zinc-500">無異動紀錄</div>
                      ) : (
                        <>
                          {/* 展開時的在庫是重撈的，可能已經跟列表那一刻不一樣了。
                              ⛔ 不可以無條件寫「更早之前就已經是負的」—— 剛被盤點/補帳
                              修回正的那一列也會落在 culpritId == null 這一支，
                              照寫就是在畫面上講一句不成立的話。 */}
                          {detail.onHandNow != null && detail.onHandNow >= 0 ? (
                            <div className="mt-1 text-xs text-emerald-700 dark:text-emerald-400">
                              這一列現在已經不是負的了（目前在庫 {fmtQty(detail.onHandNow)}）
                              —— 列表載入之後被補回來了，重新整理就會從清單上消失。
                            </div>
                          ) : (
                            detail.culpritId == null &&
                            detail.onHandNow != null && (
                              <div className="mt-1 text-xs text-zinc-500">
                                這 {detail.moves.length} 筆裡面找不到「從不是負的變成負的」那一筆
                                —— 更早之前就已經是負的了。
                              </div>
                            )
                          )}
                          <div className="mt-2 overflow-x-auto">
                            <table className="min-w-full text-xs">
                              <thead className="text-zinc-500">
                                <tr>
                                  <th className="px-2 py-1 text-left">時間</th>
                                  <th className="px-2 py-1 text-left">類型</th>
                                  <th className="px-2 py-1 text-right">數量</th>
                                  <th
                                    className="px-2 py-1 text-right"
                                    title="stock_movements 沒有存餘額欄位；這一欄是用「目前在庫」往回減每一筆數量推算出來的"
                                  >
                                    異動後餘額 *
                                  </th>
                                  <th className="px-2 py-1 text-left">來源單據</th>
                                  <th className="px-2 py-1 text-left">原因 / 備註</th>
                                </tr>
                              </thead>
                              <tbody>
                                {detail.moves.map((m) => {
                                  const isCulprit = m.id === detail.culpritId;
                                  return (
                                    <tr
                                      key={m.id}
                                      className={`border-t border-zinc-200 dark:border-zinc-800 ${
                                        isCulprit ? "bg-red-50 dark:bg-red-950/40" : ""
                                      }`}
                                    >
                                      <td className="px-2 py-1 whitespace-nowrap text-zinc-500">{fmtDateTime(m.created_at)}</td>
                                      <td className="px-2 py-1">
                                        {MOVE_LABEL[m.movement_type] ?? m.movement_type}
                                        {isCulprit && (
                                          <span
                                            className="ml-1 rounded bg-red-200 px-1 text-[10px] font-medium text-red-800 dark:bg-red-900 dark:text-red-300"
                                            // ⛔ 這裡不可以寫 balanceAfter - quantity 現算
                                            //   —— 那是又一次浮點減法（見 buildMovementDetail
                                            //   的說明）。兩個數字都用整數算好才傳進來。
                                            title={
                                              m.balanceAfter == null || m.balanceBefore == null
                                                ? undefined
                                                : `這筆之前餘額 ${fmtQty(m.balanceBefore)}，之後變成 ${fmtQty(m.balanceAfter)}`
                                            }
                                          >
                                            轉負
                                          </span>
                                        )}
                                      </td>
                                      <td
                                        className={`px-2 py-1 text-right font-mono ${
                                          m.quantity < 0
                                            ? "text-red-600 dark:text-red-400"
                                            : "text-emerald-600 dark:text-emerald-400"
                                        }`}
                                      >
                                        {m.quantity > 0 ? "+" : ""}
                                        {fmtQty(m.quantity)}
                                      </td>
                                      <td
                                        className={`px-2 py-1 text-right font-mono ${
                                          m.balanceAfter != null && m.balanceAfter < 0
                                            ? "text-red-600 dark:text-red-400"
                                            : "text-zinc-500"
                                        }`}
                                      >
                                        {m.balanceAfter == null ? "—" : fmtQty(m.balanceAfter)}
                                      </td>
                                      <td className="px-2 py-1 text-zinc-500">
                                        {m.source_doc_type
                                          ? `${m.source_doc_type}${m.source_doc_id ? ` #${m.source_doc_id}` : ""}`
                                          : "—"}
                                      </td>
                                      <td className="px-2 py-1 text-zinc-500">
                                        {maskFreeText(m.reason) || "—"}
                                        {m.notes ? (
                                          <span className="text-zinc-400"> · {maskFreeText(m.notes)}</span>
                                        ) : null}
                                      </td>
                                    </tr>
                                  );
                                })}
                              </tbody>
                            </table>
                          </div>
                          <p className="mt-2 text-[11px] text-zinc-400">
                            * 「異動後餘額」是用目前在庫（
                            {detail.onHandNow == null ? "撈不到" : fmtQty(detail.onHandNow)}
                            ）往回推算的，系統沒有把每一筆的餘額存下來。
                          </p>
                        </>
                      )}
                    </td>
                  </tr>,
                );
              }
              return out;
            })
          )}
        </TBody>
      </Table>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn disabled={page === 1} onClick={() => goPage(1)}>
            « 第一頁
          </PagerBtn>
          <PagerBtn disabled={page === 1} onClick={() => goPage(page - 1)}>
            ‹ 上頁
          </PagerBtn>
          <span className="px-2 text-zinc-500">
            {page} / {totalPages}
          </span>
          <PagerBtn disabled={page === totalPages} onClick={() => goPage(page + 1)}>
            下頁 ›
          </PagerBtn>
          <PagerBtn disabled={page === totalPages} onClick={() => goPage(totalPages)}>
            最末頁 »
          </PagerBtn>
        </div>
      )}
    </div>
  );
}

function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return (
    <SpinButton
      onClick={onClick}
      disabled={disabled}
      className="rounded-md border border-zinc-300 px-2 py-1 transition-colors hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800"
    >
      {children}
    </SpinButton>
  );
}

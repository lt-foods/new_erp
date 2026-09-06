"use client";

// 店家「退貨」頁（2026-09-04，老闆草圖版三段式）
//
// ① 發起退貨   ＋我要退貨 → 選商品＋數量 → 原因四選 → 送出
// ② 進度列表   日期｜商品｜數量｜原因｜狀態｜總倉回覆（誰按的／自動）
// ③ 收貨差額   店家回報過的少收／多給 → 總倉處理結果（唯讀，讀既有 shortage_resolution 家族）
//
// ⭐ 老闆 2026-09-04 裁示 2（乙案）：送出**不扣庫存**，總倉按「同意收回」那一刻才扣，
//   不同意＝什麼都沒動過。後端三支：20260904020000／020010／020020。
// ⭐ 老闆 2026-09-04 裁示 3：收貨差額的處理進度**搬進這一頁**一起看（＝③）。
//
// ⛔ 這一頁完全不改總倉端 —— 退貨單走既有的 return_to_hq 隊伍，
//   總倉那兩顆鈕與 48 小時自動同意（20260903010020）零改動就吃得到。

import { useEffect, useMemo, useState } from "react";
import { LoadingBlock } from "@/components/Spinner";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { parseReturnNote } from "@/lib/returnNote";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";
import SpinButton from "@/components/SpinButton";
import StoreReturnCreateModal from "@/components/StoreReturnCreateModal";

// 48h 自動同意寫的操作者就是這個全零 sentinel（20260903010020:129、:69）——
// 「received_by = 全零 ⇒ 自動；其餘 ⇒ 有人按的」是那支檔自己定的判準，這裡逐字沿用。
const SYSTEM_OPERATOR = "00000000-0000-0000-0000-000000000000";

// ③ 差額只看最近這段時間，避免一次撈整間店的歷史。
const DIFF_WINDOW_DAYS = 90;

type StoreRow = { id: number; name: string; location_id: number | null };

type TransferRow = {
  id: number;
  transfer_no: string;
  status: string;
  notes: string | null;
  created_at: string;
  shipped_at: string | null;
  received_at: string | null;
  received_by: string | null;
  updated_by: string | null;
  updated_at: string | null;
  dest_location: number;
};

type ItemRow = {
  id: number;
  transfer_id: number;
  sku_id: number | null;
  qty_shipped: number;
  qty_received: number | null;
  out_movement_id: number | null;
  shortage_resolution: string | null;
  shortage_resolution_at: string | null;
  shortage_resolution_by: string | null;
  /**
   * 「不同意退貨」把實收補回派出量**之前**的實收量（20260903000200:99 新增的欄位）。
   * ⚠️ 只有 shortage_resolution === "reject_return" 的列上才有意義 —— 其他 resolution
   * 的列 DB 一律寫 NULL，⛔ 不要拿它算別的東西（出處：ExceptionsContent.tsx:312-316、:693）。
   */
  shortage_prev_qty_received: number | null;
  damage_qty: number | null;
};

type SkuRow = { id: number; sku_code: string | null; product_name: string | null; variant_name: string | null };

// ⛔ 判準逐字對齊三個現成的地方，改了退貨單就會在總倉那邊消失：
//   hq/inbox/page.tsx:189-191（那兩顆鈕的出現條件）
//   wms/transfers/page.tsx:181-183（內部調撥頁的橘色標籤）
//   20260903010020:143（48 小時自動同意的母體 LIKE '[order return%'）
function isOrderReturn(notes: string | null): boolean {
  return !!notes && notes.startsWith("[order return");
}

// 老闆逐字定的三種狀態字樣（需求暨計畫_店家退貨頁_2026-09-04.md:23）
const STATUS_VIEW: Record<string, { label: string; cls: string }> = {
  shipped: {
    label: "🚚 等總倉",
    cls: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  },
  received: {
    label: "✅ 已入倉",
    cls: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  },
  cancelled: {
    label: "❌ 不同意 · 自己收回",
    cls: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  },
};

// ③ 的處理結果字樣。
//
// ⭐⭐ 字樣的**正本在總倉端**：apps/admin/src/components/ExceptionsContent.tsx 的
//   RESOLUTION_LABEL。店家看到的字必須跟總倉那個人按下去時看到的字一模一樣，
//   不然兩邊會以為在講不同的事。
//
// 🔴 第一輪抄錯了版本：這個工地的基準是 7587aba7（#904），那時候 repo 裡的
//   ExceptionsContent 還寫著老闆 2026-09-02 §刀2 明令禁用的那種「連字號」舊字樣，
//   #906 已經把它改掉並上線了。
//   ⚠️ 本檔刻意**連註解都不寫出那個舊字串**（寫法沿用 TransferShortageResolveModal:171），
//     這樣驗證腳本掃「禁用字樣 0 次」才是真的 0。
//   ⇒ 本輪改成照抄**已上線 main（1c35b0d1，含 #906）**的版本：
//      git show main:apps/admin/src/components/ExceptionsContent.tsx  ← :206-233
//      （鏡像庫 D:\1人公司\_備份_GitHub_20260831\new_erp.git，零網路撈得到）
//   ⛔ label 的字**一個字都不要動**。驗證腳本會直接從那個鏡像撈出來逐字比對，
//     改了就 FAIL。
//   ⛔ 待辦（技術債）：#906 合併進本分支之後，這一份要改成從共用常數 import，
//     不要長期留兩份。
//
// ⚠️ emoji 刻意**不寫進 label**，另外放 icon 欄位 —— label 要能跟正本逐字相等。
// ⚠️ note 是我自己寫給店家看的白話，不是抄的；每一句都只留「不管出貨端是誰都成立」
//   的話（③ 這一區的單有可能是總倉派的，也有可能是別家店調過來的）。
//   ⛔ 所以不可以寫「總倉會再送一批」「照總倉送出去的數量算錢」這種把出貨端
//     講死成總倉的句子 —— 那是 TransferShortageResolveModal 六審學到的同一課。
const RESOLUTION_VIEW: Record<string, { icon: string; label: string; note: string; cls: string }> = {
  redispatch: {
    icon: "🔁",
    label: "同意退・補貨",
    note: "少收的數量以原出庫成本記回「原本送貨出去的那一邊」。",
    cls: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  },
  restock_hq: {
    icon: "🏭",
    label: "同意退・不補貨",
    note: "少收的數量以原出庫成本記回「原本送貨出去的那一邊」，不會自動再送給店家。",
    cls: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  },
  reject_return: {
    // ⛔ 不可以寫成「系統會去跟店家收錢」—— 沒有任何程式在加錢，
    //   差別只在「沒有產生那張會扣錢的沖帳單」。
    // ⚠️ 「實收被改成派出量」只改數字、不動庫存（20260903000200 那一段一筆
    //   stock_movements 都沒寫）⇒ 不可以寫成「貨補進店裡的庫存」。
    icon: "💰",
    label: "不同意退貨-跟店家收錢",
    note: "這一批照送出去的數量跟你們算錢（少收的部分不會退），你們的實收也被改成派出量 —— 只改數字，架上的貨沒有變多。",
    cls: "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
  },
  over_ack: {
    icon: "👍",
    label: "多收知道了",
    // 出處：rpc_ack_transfer_over（20260824020000:1571-1617）整支只有一個 UPDATE
    //   transfer_items，**一筆庫存都不寫** —— 多出來那幾件是收貨當下就照實收入帳的。
    note: "多出來的那幾件收貨當下就已經入你們店的帳了，總倉只是確認知道（這一步不動庫存）。",
    cls: "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300",
  },
  // ── 以下 4 個是畫面已經不給按的舊值，但歷史資料還有（DB CHECK 仍允許八值：
  //    20260903000020:44-49）⇒ 照正本的字樣顯示並標「（舊）」。
  //    ⚠️⚠️ accept 與 reject_return **後端行為相同、語意相反**
  //    （accept＝舊月結按實收收錢時代的「公司吃」；reject_return＝派出量制的「店家吃」），
  //    ⛔ 兩者的說明絕對不可以寫成一樣（出處：ExceptionsContent.tsx:235-240）。
  accept: {
    icon: "",
    label: "當作沒了（舊）",
    note: "舊制的處理方式：那幾件當作沒了，當時是按實收算錢的（＝公司吸收）。現在畫面上已經沒有這顆鈕。",
    cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  },
  vendor_claim: {
    icon: "",
    label: "供應商求償（舊）",
    note: "舊制的處理方式，現在畫面上已經沒有這顆鈕。",
    cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  },
  cancel_orders: {
    icon: "",
    label: "取消客戶訂單（舊）",
    note: "舊制的處理方式，現在畫面上已經沒有這顆鈕。",
    cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  },
  replenish: {
    icon: "",
    label: "補出貨（舊）",
    note: "舊制的處理方式，現在畫面上已經沒有這顆鈕。",
    cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  },
};

function skuLabel(s: SkuRow | undefined, id: number | null): string {
  if (!s) return id != null ? `品項#${id}` : "—";
  return `${s.product_name ?? ""}${s.variant_name ? ` / ${s.variant_name}` : ""}`.trim() || (s.sku_code ?? `#${s.id}`);
}

function fmtDate(v: string | null): string {
  return v ? new Date(v).toLocaleDateString("zh-TW") : "—";
}
function fmtDateTime(v: string | null): string {
  return v ? new Date(v).toLocaleString("zh-TW") : "—";
}
function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

export default function StoreReturnsPage() {
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [storeId, setStoreId] = useState<string>("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  // ② 的資料
  const [returns, setReturns] = useState<TransferRow[]>([]);
  const [returnItems, setReturnItems] = useState<ItemRow[]>([]);
  // ③ 的資料
  const [diffItems, setDiffItems] = useState<ItemRow[]>([]);
  const [diffTransfers, setDiffTransfers] = useState<Map<number, TransferRow>>(new Map());
  // 共用
  const [skus, setSkus] = useState<Map<number, SkuRow>>(new Map());
  const [names, setNames] = useState<Map<string, string>>(new Map());
  const [onHand, setOnHand] = useState<Map<number, number>>(new Map());

  const branchStoreId = useUserBranchStoreId(stores);
  useDefaultStoreFromUser(stores, storeId, setStoreId);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: e } = await getSupabase()
        .from("stores")
        .select("id, name, location_id")
        .eq("is_active", true)
        .order("name");
      if (cancelled) return;
      if (e) setError(e.message);
      else setStores((data ?? []) as StoreRow[]);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const store = useMemo(
    () => stores.find((s) => String(s.id) === storeId) ?? null,
    [stores, storeId],
  );
  const storeLoc = store?.location_id ?? null;

  useEffect(() => {
    if (storeLoc == null) {
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        const TCOLS =
          "id, transfer_no, status, notes, created_at, shipped_at, received_at, received_by, updated_by, updated_at, dest_location";

        // ── ② 這家店送出的退貨單（含舊路徑那條，兩種 notes 都以 [order return 開頭）──
        //
        // 🔴 第一輪是「先撈最近 200 張 return_to_hq、再在前端濾 notes 前綴」。那是錯的：
        //   9/01 起每一次「同意退回」都會自動產一張 return_to_hq 的**短收沖帳單**
        //   （20260901000010:317-324、20260903000020:268、20260903000200:375），
        //   出貨端剛好也寫這家店 ⇒ 它們跟真的退貨單搶同一個 200 張的名額。
        //   一家店一天被總倉處理十幾筆短收，兩三個星期就能把 200 張吃光，
        //   店家真正送出的退貨單**整批消失在畫面上**（而且什麼錯誤都不會報）。
        // ⇒ 改成把前綴條件**下推到 SQL**，讓「最近 200 張」是從真退貨單裡數的。
        //   `.like` 用 % 當萬用字元：本 repo 既有用法 stores/page.tsx:114
        //   `q.like("code", "LELE-%")`。⛔ 前綴字串與 isOrderReturn / 總倉收件匣 /
        //   48h cron 必須完全一致，驗證腳本 B 段會拿四邊互比。
        const { data: retRaw, error: e1 } = await sb
          .from("transfers")
          .select(TCOLS)
          .eq("transfer_type", "return_to_hq")
          .eq("source_location", storeLoc)
          .like("notes", "[order return%")
          .order("id", { ascending: false })
          .limit(200);
        if (e1) throw new Error(e1.message);
        // 第二層（同一個判準，前端再濾一次）：SQL 的 LIKE 與 JS 的 startsWith 對
        // 「notes 是 NULL」等邊界的處理不完全一樣，留著這一層才不會有漏網的。
        // ⚠️ 它**不是**第一輪那個「唯一的過濾」了 —— 現在真正在防漏單的是上面那行 .like。
        const rets = ((retRaw ?? []) as TransferRow[]).filter((t) => isOrderReturn(t.notes));

        // ── ③ 這家店收到的貨裡，實收 ≠ 派出的那些 ──
        const since = new Date(Date.now() - DIFF_WINDOW_DAYS * 86400_000).toISOString();
        const { data: diffTRaw, error: e2 } = await sb
          .from("transfers")
          .select(TCOLS)
          .eq("dest_location", storeLoc)
          .eq("status", "received")
          .gte("received_at", since)
          .order("id", { ascending: false })
          .limit(500);
        if (e2) throw new Error(e2.message);
        const diffTs = (diffTRaw ?? []) as TransferRow[];

        // ── 明細（兩段共用一次查詢；分頁走 fetchAllRows 避開 PostgREST 1000 列截斷）──
        const allTIds = [...rets.map((t) => t.id), ...diffTs.map((t) => t.id)];
        let items: ItemRow[] = [];
        if (allTIds.length > 0) {
          items = await fetchAllRows<ItemRow>(() =>
            sb
              .from("transfer_items")
              .select(
                "id, transfer_id, sku_id, qty_shipped, qty_received, out_movement_id, shortage_resolution, shortage_resolution_at, shortage_resolution_by, shortage_prev_qty_received, damage_qty",
              )
              .in("transfer_id", allTIds)
              .order("id", { ascending: true }),
          );
        }
        const retIdSet = new Set(rets.map((t) => t.id));
        const diffIdSet = new Set(diffTs.map((t) => t.id));
        const retItems = items.filter((it) => retIdSet.has(it.transfer_id));
        // ③ 的母體。⚠️ 兩欄相減 PostgREST 做不到，只能撈回來自己比。
        //
        // 🔴 第一輪的條件只有「實收 ≠ 派出」，所以總倉按「不同意退貨」之後那一列會
        //   **整列從店家畫面消失**：20260903000200:412 起 reject_return 會把
        //   qty_received 補成 qty_shipped（舊值搬進 shortage_prev_qty_received）
        //   ⇒ 差額變 0 ⇒ 被這個條件濾掉。
        //   店家回報少收、總倉決定不同意（＝要照派出量跟他收錢），他卻只會看到
        //   「那一列不見了」，什麼都不知道 —— 這正是要付錢的那一種結果。
        // ⇒ 改成「有差額**或**有處理結果」都要顯示。
        // ⭐ 撤銷（rpc_undo_transfer_item_shortage，20260903000200）會把
        //   shortage_resolution 清成 NULL、把實收改回舊值 ⇒ 差額回來、resolution 沒了，
        //   這一列自動回到「⏳ 未處理」，與總倉那一頁 #904 的行為一致。
        const dItems = items.filter(
          (it) =>
            diffIdSet.has(it.transfer_id) &&
            (num(it.qty_received) !== num(it.qty_shipped) || it.shortage_resolution != null),
        );

        // ── 商品名 ──
        const skuIds = Array.from(
          new Set([...retItems, ...dItems].map((it) => it.sku_id).filter((x): x is number => x != null)),
        );
        const skuMap = new Map<number, SkuRow>();
        if (skuIds.length > 0) {
          const rows = await fetchAllRows<SkuRow>(() =>
            sb
              .from("skus")
              .select("id, sku_code, product_name, variant_name")
              .in("id", skuIds)
              .order("id", { ascending: true }),
          );
          for (const s of rows) skuMap.set(s.id, s);
        }

        // ── 店裡現在還有幾件（給「等總倉」那些單做扣不動的預警）──
        const holdMap = new Map<number, number>();
        if (skuIds.length > 0) {
          const bals = await fetchAllRows<{ sku_id: number; on_hand: number }>(() =>
            sb
              .from("stock_balances")
              .select("sku_id, on_hand")
              .eq("location_id", storeLoc)
              .in("sku_id", skuIds)
              .order("sku_id", { ascending: true }),
          );
          for (const b of bals) holdMap.set(b.sku_id, num(b.on_hand));
        }

        // ── 誰按的（既有機制 rpc_get_staff_names，20260428170000，回 { id, display_name }）──
        const uids = Array.from(
          new Set(
            [
              ...rets.map((t) => (t.status === "cancelled" ? t.updated_by : t.received_by)),
              ...dItems.map((it) => it.shortage_resolution_by),
            ].filter((x): x is string => !!x && x !== SYSTEM_OPERATOR),
          ),
        );
        const nameMap = new Map<string, string>();
        if (uids.length > 0) {
          const { data: ns } = await sb.rpc("rpc_get_staff_names", { p_uids: uids });
          for (const n of (ns as { id: string; display_name: string }[] | null) ?? []) {
            nameMap.set(n.id, n.display_name);
          }
        }

        if (cancelled) return;
        setReturns(rets);
        setReturnItems(retItems);
        setDiffItems(dItems);
        setDiffTransfers(new Map(diffTs.map((t) => [t.id, t])));
        setSkus(skuMap);
        setNames(nameMap);
        setOnHand(holdMap);
        setError(null);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [storeLoc, reloadKey]);

  const returnById = useMemo(() => new Map(returns.map((t) => [t.id, t])), [returns]);

  // 每個 SKU「還在等總倉回覆、而且還沒扣過庫存」的總件數 —— 用來跟在庫比對，
  // 比不過就代表總倉按同意時會扣不動（20260904020010 會擋下來），要當場提醒店家。
  const pendingBySku = useMemo(() => {
    const m = new Map<number, number>();
    for (const it of returnItems) {
      const t = returnById.get(it.transfer_id);
      if (!t || t.status !== "shipped" || it.out_movement_id != null || it.sku_id == null) continue;
      m.set(it.sku_id, (m.get(it.sku_id) ?? 0) + num(it.qty_shipped));
    }
    return m;
  }, [returnItems, returnById]);

  function replyOf(t: TransferRow): string {
    if (t.status === "shipped") return "—";
    if (t.status === "received") {
      const who =
        t.received_by === SYSTEM_OPERATOR
          ? "自動（滿 48 小時沒人處理）"
          : (t.received_by ? names.get(t.received_by) : null) ?? "總倉";
      return `${who}・${fmtDateTime(t.received_at)}`;
    }
    if (t.status === "cancelled") {
      const who = (t.updated_by ? names.get(t.updated_by) : null) ?? "總倉";
      const m = (t.notes ?? "").match(/\[rejected:\s*([^\]]*)\]/);
      const why = m && m[1].trim() ? `（${m[1].trim()}）` : "";
      return `${who}${why}・${fmtDateTime(t.updated_at)}`;
    }
    return "—";
  }

  const branchLocked = branchStoreId != null;
  const visibleStores = branchLocked ? stores.filter((s) => s.id === branchStoreId) : stores;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">↩ 退貨</h1>
          <p className="text-sm text-zinc-500">
            要退回總倉的貨在這裡送出，總倉回你什麼也在這裡看。收貨數量對不上的處理進度在最下面。
          </p>
          <p className="mt-0.5 text-xs text-zinc-400">
            送出<strong>不會</strong>馬上扣庫存 —— 帳上的數字不變，旁邊標「退貨中 N」；
            總倉按「同意收回」那一刻才真的扣，不同意就什麼都沒動過。
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <select
            value={storeId}
            onChange={(e) => setStoreId(e.target.value)}
            disabled={branchLocked}
            className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm disabled:opacity-70 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選門市 —</option>
            {visibleStores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
          <SpinButton
            onClick={() => setShowCreate(true)}
            disabled={storeLoc == null}
            className="rounded-md bg-orange-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-orange-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            ＋ 我要退貨
          </SpinButton>
        </div>
      </header>

      {/* ⭐ 用 showCreate 決定「掛不掛上去」而不是只傳 open —— 關掉時整個 unmount，
          彈窗裡選到一半的商品/數量/原因就跟著歸零，不必在元件裡再寫一段清空邏輯。 */}
      {showCreate && store && storeLoc != null && (
        <StoreReturnCreateModal
          open
          onClose={() => setShowCreate(false)}
          onCreated={() => {
            setShowCreate(false);
            setReloadKey((k) => k + 1);
          }}
          storeId={store.id}
          storeName={store.name}
          storeLocationId={storeLoc}
        />
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {store == null ? (
        <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          請先在右上角選一家門市。
        </div>
      ) : storeLoc == null ? (
        <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
          「{store.name}」還沒設定倉庫位置（location），不能退貨。請聯繫總部。
        </div>
      ) : (
        <>
          {/* ── ② 進度列表 ── */}
          <section className="flex flex-col gap-2">
            <h2 className="text-base font-semibold">我送出的退貨</h2>
            <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
              <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                <thead className="bg-zinc-50 dark:bg-zinc-900">
                  <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                    <th className="px-3 py-2">日期</th>
                    <th className="px-3 py-2">單號</th>
                    <th className="px-3 py-2">商品</th>
                    <th className="px-3 py-2 text-right">數量</th>
                    <th className="px-3 py-2">原因</th>
                    <th className="px-3 py-2">狀態</th>
                    <th className="px-3 py-2">總倉回覆</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {loading ? (
                    <tr>
                      <td colSpan={7}>
                        <LoadingBlock />
                      </td>
                    </tr>
                  ) : returnItems.length === 0 ? (
                    <tr>
                      <td colSpan={7} className="p-6 text-center text-zinc-500">
                        還沒有送出過退貨。
                      </td>
                    </tr>
                  ) : (
                    returnItems.map((it) => {
                      const t = returnById.get(it.transfer_id);
                      if (!t) return null;
                      const parsed = parseReturnNote(t.notes);
                      const reasonText = parsed.isDamage ? "破損" : parsed.reason ?? "退貨";
                      const sv = STATUS_VIEW[t.status] ?? {
                        label: t.status,
                        cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
                      };
                      // 這一列會不會扣不動：只有「等總倉、而且還沒扣過」的才要問這件事
                      const waiting = t.status === "shipped" && it.out_movement_id == null;
                      const short =
                        waiting &&
                        it.sku_id != null &&
                        (onHand.get(it.sku_id) ?? 0) < (pendingBySku.get(it.sku_id) ?? 0);
                      return (
                        <tr key={it.id} className="align-top">
                          <td className="px-3 py-2 text-xs text-zinc-500">
                            {fmtDate(t.shipped_at ?? t.created_at)}
                          </td>
                          <td className="px-3 py-2 font-mono text-xs">{t.transfer_no}</td>
                          <td className="px-3 py-2 text-xs">
                            {skuLabel(it.sku_id != null ? skus.get(it.sku_id) : undefined, it.sku_id)}
                            {waiting ? (
                              <span className="ml-2 inline-block rounded bg-amber-100 px-1 py-0.5 text-[10px] text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                                退貨中 · 還沒扣
                              </span>
                            ) : it.out_movement_id != null && t.status === "shipped" ? (
                              <span
                                className="ml-2 inline-block rounded bg-zinc-100 px-1 py-0.5 text-[10px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
                                title="這張是從「內部調撥 → ↩ 退貨回總倉」建的舊式退貨單，送出當下就把貨從店裡扣掉了"
                              >
                                送出時已扣
                              </span>
                            ) : null}
                            {short && (
                              <div className="mt-0.5 text-[11px] text-red-600 dark:text-red-400">
                                ⚠ 店裡現在只剩 {onHand.get(it.sku_id!) ?? 0} 件，
                                但還在等回覆的退貨有 {pendingBySku.get(it.sku_id!) ?? 0} 件 ——
                                總倉按同意時會扣不動而失敗。請先把貨留回來。
                              </div>
                            )}
                          </td>
                          <td className="px-3 py-2 text-right tabular-nums">{num(it.qty_shipped)}</td>
                          <td className="px-3 py-2 text-xs">{reasonText}</td>
                          <td className="px-3 py-2">
                            <span className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ${sv.cls}`}>
                              {sv.label}
                            </span>
                          </td>
                          <td className="px-3 py-2 text-xs text-zinc-500">{replyOf(t)}</td>
                        </tr>
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>
            <p className="text-[11px] text-zinc-400">
              只列這家店送出的退貨（最近 200 張單）。⛔ 系統為了對帳自動產生的「短收沖帳單」不會列在這裡。
            </p>
          </section>

          {/* ── ③ 收貨差額進度（唯讀）── */}
          <section className="flex flex-col gap-2">
            <h2 className="text-base font-semibold">收貨數量對不上的處理進度</h2>
            <p className="text-xs text-zinc-500">
              你們在「收貨」頁填的實收跟送貨那一邊派出的數量不一樣時，那筆差額會排到總倉那邊等處理。
              這一區<strong>只能看</strong>，要處理是總倉那邊按。
            </p>
            <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
              <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                <thead className="bg-zinc-50 dark:bg-zinc-900">
                  <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                    <th className="px-3 py-2">收貨日</th>
                    <th className="px-3 py-2">調撥單號</th>
                    <th className="px-3 py-2">商品</th>
                    {/* ⚠️ 這一區的單不一定是總倉派的（店↔店調撥也會進來，dest 是你們就算），
                        所以欄位名不可以寫死「總倉派出」—— 同 P1-3 那一課。 */}
                    <th className="px-3 py-2 text-right">派出量</th>
                    <th className="px-3 py-2 text-right">你們實收</th>
                    <th className="px-3 py-2 text-right">差額</th>
                    <th className="px-3 py-2">總倉處理結果</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {loading ? (
                    <tr>
                      <td colSpan={7}>
                        <LoadingBlock />
                      </td>
                    </tr>
                  ) : diffItems.length === 0 ? (
                    <tr>
                      <td colSpan={7} className="p-6 text-center text-zinc-500">
                        最近 {DIFF_WINDOW_DAYS} 天收的貨數量都對得上，沒有差額。
                      </td>
                    </tr>
                  ) : (
                    diffItems.map((it) => {
                      const t = diffTransfers.get(it.transfer_id);
                      // ⭐ 「不同意退貨」那一列的 qty_received 已經被後端補成 qty_shipped
                      //   （20260903000200:412），現值算出來是 0 ⇒ 要顯示「當初少收幾件」
                      //   必須用補回前的舊值。判準逐字對齊總倉那一頁
                      //   （ExceptionsContent.tsx:693-697 的 baseRecv）。
                      //   ⛔ 不要對所有 resolution 都套 prev：DB 只在 reject_return 的列上寫它。
                      const rejected = it.shortage_resolution === "reject_return";
                      const baseRecv =
                        rejected && it.shortage_prev_qty_received != null
                          ? num(it.shortage_prev_qty_received)
                          : num(it.qty_received);
                      const diff = baseRecv - num(it.qty_shipped);
                      const rv = it.shortage_resolution ? RESOLUTION_VIEW[it.shortage_resolution] : undefined;
                      const who = it.shortage_resolution_by ? names.get(it.shortage_resolution_by) : null;
                      return (
                        <tr key={it.id} className="align-top">
                          <td className="px-3 py-2 text-xs text-zinc-500">{fmtDate(t?.received_at ?? null)}</td>
                          <td className="px-3 py-2 font-mono text-xs">{t?.transfer_no ?? `#${it.transfer_id}`}</td>
                          <td className="px-3 py-2 text-xs">
                            {skuLabel(it.sku_id != null ? skus.get(it.sku_id) : undefined, it.sku_id)}
                            {num(it.damage_qty) > 0 && (
                              <span className="ml-2 text-[11px] text-zinc-500">（含破損 {num(it.damage_qty)}）</span>
                            )}
                          </td>
                          <td className="px-3 py-2 text-right tabular-nums">{num(it.qty_shipped)}</td>
                          <td className="px-3 py-2 text-right tabular-nums">
                            {baseRecv}
                            {/* 實收被總倉改過的話要講出來，不然店家會以為自己當初填錯了 */}
                            {rejected && it.shortage_prev_qty_received != null && (
                              <div className="text-[10px] font-normal text-zinc-400">
                                （已被改成 {num(it.qty_shipped)}）
                              </div>
                            )}
                          </td>
                          <td
                            className={`px-3 py-2 text-right tabular-nums font-medium ${
                              diff < 0
                                ? "text-red-600 dark:text-red-400"
                                : diff > 0
                                  ? "text-sky-700 dark:text-sky-400"
                                  : "text-zinc-400"
                            }`}
                          >
                            {diff > 0 ? `多收 +${diff}` : diff < 0 ? `少收 ${diff}` : "—"}
                          </td>
                          <td className="px-3 py-2">
                            {rv ? (
                              <>
                                <span className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ${rv.cls}`}>
                                  {rv.icon ? `${rv.icon} ` : ""}
                                  {rv.label}
                                </span>
                                <div className="mt-0.5 text-[11px] text-zinc-500">{rv.note}</div>
                                <div className="text-[11px] text-zinc-400">
                                  {(who ?? "總倉")}・{fmtDateTime(it.shortage_resolution_at)}
                                </div>
                              </>
                            ) : it.shortage_resolution ? (
                              // 安全網：DB CHECK 現在的八個值 RESOLUTION_VIEW 都認得
                              //（20260903000020:44-49）⇒ 這一支今天走不到。
                              // 留著是因為哪天有人加了第九個值，店家會看到英文代碼但**不會白畫面**，
                              // 而且看得出「總倉已經處理過了」。⛔ 不要在這裡自己編一套翻譯。
                              <>
                                <span className="inline-flex whitespace-nowrap rounded bg-zinc-100 px-2 py-0.5 text-xs text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
                                  {it.shortage_resolution}
                                </span>
                                <div className="mt-0.5 text-[11px] text-zinc-500">總倉處理過了，但這個畫面還不認得這種處理方式，請問總部。</div>
                              </>
                            ) : (
                              <>
                                <span className="inline-flex whitespace-nowrap rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                                  ⏳ 未處理
                                </span>
                                <div className="mt-0.5 text-[11px] text-zinc-500">總倉還沒回覆這一筆。</div>
                              </>
                            )}
                          </td>
                        </tr>
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>
            <p className="text-[11px] text-zinc-400">
              只列最近 {DIFF_WINDOW_DAYS} 天、實收跟派出不一樣的品項；
              總倉按了「不同意退貨」之後實收會被改成派出量（差額歸零），那幾列<strong>還是會留在這裡</strong>，
              上面顯示的是被改之前的數字。
            </p>
          </section>
        </>
      )}
    </div>
  );
}

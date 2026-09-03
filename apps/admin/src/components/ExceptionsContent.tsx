"use client";

// ⚠️ 異常處理 — 抽離自舊 /wms/exceptions 頁,目前由 /hq/inbox?source=exception 內嵌使用
// 集中顯示倉儲全鏈路異常:
//   1. 進貨短少 — PO fully_received 但 gr_qty < qty_ordered
//   2. 進貨破損 — GR qty_damaged > 0
//   3. 過量進貨 — GR cumulative qty_received > qty_ordered
//   4. 收貨短少 — Transfer received 但 qty_received < qty_shipped
//
// 「訂單短少」(customer_shortage) 於 2026-08-11 移除:它是前瞻推算
// (v_order_shortage),供應商短交後必然大量出現,實際短交已由
// 進貨短少/收貨短少覆蓋 → v_hq_exceptions 已不再回傳此來源
// (20260811020010),此處的分頁與批次處理 UI 一併拿掉。
//
// 資料與分頁:全部走 server-side。rpc_hq_exceptions(type, page, page_size)
// 後端 union 4 來源(v_hq_exceptions)做真分頁,一次回傳 { total, counts(各 tab), rows(當前頁) }。
//
// 第 6 個分頁「已處理」(2026-08-22)——**唯讀**,跟上面 5 個是兩套完全不同的資料:
//   上面 5 個 = 還沒處理的(rpc_hq_exceptions / v_hq_exceptions);
//   「已處理」= transfer_items.shortage_resolution IS NOT NULL(PostgREST 直查,零 RPC 零 migration)。
// 起因:短收處理視窗兩顆都不可逆,按完那筆就從清單消失,員工不知道自己按了哪顆
//   (2026-08-22 員工回報)。⇒ 這一頁回答「我按了什麼」。
// 2026-09-03 老闆:「要可以撤銷」⇒ 每一列多一顆「撤銷」
//   (rpc_undo_transfer_item_shortage,20260903000200)。它做的事等同
//   rpc_unreceive_transfer 的反向邏輯 H,但只針對單筆:沖銷記回出貨端的入庫、
//   取消 draft 重派撿貨單、作廢短收沖帳單、還原「不同意退貨」補上去的實收,
//   然後清掉 shortage_* 欄位 ⇒ 那一列回到收件匣。
//   ⚠️ 撤銷成功後這一頁的那一列會**消失**(這頁讀的是 transfer_items 現值,不是歷史表)。
//   軌跡由 RPC 往 transfers.notes 追加一行「撤銷處理(MM/DD HH:MI)：…」保存。
// ⛔ 「已處理」不計入徽章:onCountChange 只在上面 5 個分頁的 effect 裡呼叫,口徑仍是
//   rpc_hq_exceptions 的 counts.all(見 hq/inbox/page.tsx:952-972 對這個口徑的說明)。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "./SpinButton";
import { TransferShortageResolveModal, type ShortageContext } from "./TransferShortageResolveModal";

// 上面 5 個「還沒處理」的分頁 —— 這個型別同時被下面的 row type guard 用來擋掉
// DB view 可能回傳的已廢棄 type,所以**不可以**把 "resolved" 併進來。
type ExceptionTab = "all" | "po_shortage" | "po_damage" | "po_over" | "transfer_short" | "transfer_over";
type Tab = ExceptionTab | "resolved";

const TAB_LABEL: Record<ExceptionTab, string> = {
  all: "全部",
  po_shortage: "進貨短少",
  po_damage: "進貨破損",
  po_over: "過量進貨",
  transfer_short: "收貨短少",
  transfer_over: "收貨多收",
};

// 分頁列用(含「已處理」)。TAB_LABEL 本身要保持只有 5 個 —— 它兼任 type guard。
const TAB_BAR_LABEL: Record<Tab, string> = { ...TAB_LABEL, resolved: "已處理" };

// 與 /hq/inbox 其他來源一致的每頁筆數
const PAGE_SIZE = 20;

type ExceptionType = "po_shortage" | "po_damage" | "po_over" | "transfer_short" | "transfer_over";

type ExceptionRow = {
  key: string;
  type: ExceptionType;
  ts: string;
  doc_no: string;
  doc_link: string;
  sku_label: string;
  sku_code: string | null;
  expected: number;
  actual: number;
  diff: number;
  reason: string | null;
  extra: string;
  // 該筆異常的地點:PO/GR 收貨倉、收貨分店、取貨店(v_hq_exceptions.warehouse_name)
  warehouse_name: string | null;
  shortage_ctx?: ShortageContext;
  // transfer_over：按「知道了」要用的 transfer_item_id
  over_item_id?: number;
};

// rpc_hq_exceptions 回傳的單列(= v_hq_exceptions 扁平欄位)
// type 保留 string:DB view 若尚未套 20260811020010,可能還會回 customer_shortage,
// 前端一律濾掉(見下方 filter)。
type ViewRow = {
  type: ExceptionType | string;
  row_key: string;
  ts: string | null;
  doc_no: string;
  sku_code: string | null;
  sku_label: string;
  expected: number | string;
  actual: number | string;
  diff: number | string;
  reason: string | null;
  extra: string;
  transfer_item_id: number | null;
  transfer_id: number | null;
  transfer_no: string | null;
  sku_id: number | null;
  qty_shipped: number | string | null;
  qty_received: number | string | null;
  shortage_qty: number | string | null;
  dest_location: number | null;
  dest_store_id: number | null;
  dest_store_name: string | null;
  customer_order_id: number | null;
  shortage_resolution: string | null;
  warehouse_name: string | null;
};

// ⛔ 口徑不變:徽章讀的是 counts.all = 上面 4 類的總和,「已處理」不在裡面。
type ExceptionCounts = Record<ExceptionTab, number>;

const EMPTY_COUNTS: ExceptionCounts = {
  all: 0, po_shortage: 0, po_damage: 0, po_over: 0, transfer_short: 0, transfer_over: 0,
};

function docLinkFor(r: ViewRow): string {
  if (r.type === "transfer_short" || r.type === "transfer_over") return `/wms/inbound`;
  return `/wms/receiving`;
}

// ===== 「已處理」分頁 =====

// 「按了哪顆」的字樣。
//   redispatch / restock_hq = 老闆 2026-08-21 逐字定的按鈕字樣
//   (TransferShortageResolveModal.tsx:122 / :160,兩處要一致,改一邊要改兩邊)。
//   其餘 4 個是 2026-08-22 起畫面已經不給按的舊值,但歷史資料還有
//   (DB CHECK 仍允許六值:20260811020000:66-69)⇒ 照實顯示並標「(舊)」。
const RESOLUTION_LABEL: Record<string, string> = {
  redispatch: "同意退回-補貨",
  restock_hq: "同意退回-不補貨",
  // 2026-09-03 補上的第三顆（TransferShortageResolveModal.tsx 的字樣，改一邊要改兩邊）
  reject_return: "不同意退貨-跟店家收錢",
  // 收貨多收的「知道了」(rpc_ack_transfer_over,20260824020000)也寫在同一欄
  // ⇒ 這一頁本來就撈得到它,沒有字樣會直接顯示 "over_ack"。
  over_ack: "多收知道了",
  accept: "當作沒了（舊）",
  vendor_claim: "供應商求償（舊）",
  cancel_orders: "取消客戶訂單（舊）",
  replenish: "補出貨（舊）",
};

const WAVE_STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  picking: "撿貨中",
  picked: "已撿完",
  shipped: "已派貨出倉",
  cancelled: "已取消",
};

// 一次最多拉幾筆。到頂會在畫面上明講「只顯示最近 N 筆」,不靜靜截斷。
// (PostgREST 單次 select 預設上限就是 1000 列,見 lib/fetchAllRows.ts 檔頭)
const RESOLVED_CAP = 1000;
// .in() 會把 id 全塞進 URL,一次上千個會爆 URL 長度 → 反查一律分批。
const IN_CHUNK = 200;

type SBClient = ReturnType<typeof getSupabase>;

async function selectByIds<T>(
  sb: SBClient,
  table: string,
  cols: string,
  col: string,
  ids: Array<number | string>,
): Promise<T[]> {
  const uniq = Array.from(new Set(ids));
  const out: T[] = [];
  for (let i = 0; i < uniq.length; i += IN_CHUNK) {
    const { data, error } = await sb.from(table).select(cols).in(col, uniq.slice(i, i + IN_CHUNK));
    if (error) throw new Error(`${table}: ${error.message}`);
    out.push(...((data ?? []) as unknown as T[]));
  }
  return out;
}

type ResolvedRow = {
  id: number;
  at: string | null;
  by_name: string | null;
  transfer_no: string;
  dest_name: string;
  sku_code: string | null;
  sku_label: string;
  shortage_qty: number;
  /** 派出量 —— 撤銷確認框要講「實收會改回幾件」時用 */
  qty_shipped: number;
  /**
   * 「不同意退貨」把實收補回派出量之前的實收量(transfer_items.shortage_prev_qty_received,
   * 20260903000200)。⚠️ 只有 resolution === "reject_return" 的列上才有意義 ——
   * 其他 resolution 的列 DB 一律寫 NULL,不要拿它算別的東西。
   */
  prev_qty: number | null;
  resolution: string;
  notes: string | null;
  wave_code: string | null;
  wave_status: string | null;
  /** 補派撿貨單的建立日(yyyy-mm-dd)—— 跳到「📋 撿貨單」時拿來把日期範圍框到那一天 */
  wave_created_date: string | null;
};

function isoDate(d: Date): string {
  // 用本地時間切日期字串(不能用 toISOString,那是 UTC,台灣半夜會差一天)
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export default function ExceptionsContent({
  showHeader = true,
  onCountChange,
  onGotoPicking,
}: {
  showHeader?: boolean;
  onCountChange?: (count: number) => void;
  /**
   * 「已處理」列上的補派撿貨單號被點到時呼叫,由掛載處(hq/inbox)去切「📋 撿貨單」分頁。
   * 不傳就只顯示單號、不做成可點 —— 這支元件自己不碰收件匣的分頁狀態。
   */
  onGotoPicking?: (waveCode: string, createdDate: string | null) => void;
}) {
  const [rows, setRows] = useState<ExceptionRow[] | null>(null);
  const [counts, setCounts] = useState<ExceptionCounts | null>(null);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("all");
  const [resolveCtx, setResolveCtx] = useState<ShortageContext | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [page, setPage] = useState(1);
  const [prevTab, setPrevTab] = useState<Tab>(tab);

  // === 「已處理」分頁專屬 state(唯讀) ===
  const [resolvedRows, setResolvedRows] = useState<ResolvedRow[] | null>(null);
  const [resolvedError, setResolvedError] = useState<string | null>(null);
  // DB 端真實筆數(count: exact);> RESOLVED_CAP 時畫面要明講只顯示最近幾筆
  const [resolvedTotal, setResolvedTotal] = useState(0);
  const [dateFrom, setDateFrom] = useState(() => {
    const d = new Date();
    d.setDate(d.getDate() - 30);
    return isoDate(d);
  });
  const [dateTo, setDateTo] = useState(() => isoDate(new Date()));
  const [search, setSearch] = useState("");

  // 切換分頁籤 → 回第 1 頁(render 階段調整 state,非 effect → 不觸發 set-state-in-effect,也不會 flash 舊頁)
  if (prevTab !== tab) {
    setPrevTab(tab);
    setPage(1);
  }

  // 收貨多收「知道了」：標 over_ack，該列從收件匣移除（多收的量早已照實入分店帳）
  async function ackOver(transferItemId: number, docNo: string) {
    if (!confirm(`確認已知悉 ${docNo} 的多收？\n\n多收的量已照實入分店帳，這列會從收件匣移除。`)) return;
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_ack_transfer_over", {
        p_transfer_item_id: transferItemId,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  // 「已處理」列的撤銷（2026-09-03 老闆：「要可以撤銷」）
  //   走 rpc_undo_transfer_item_shortage(20260903000200)—— 一支 RPC 裡把該撤的都撤掉：
  //   沖銷記回出貨端的入庫、取消 draft 重派撿貨單、作廢短收沖帳單、
  //   還原「不同意退貨」補上去的實收，最後清掉處理標記 ⇒ 那一列回到收件匣。
  // ⚠️ 確認框只講**這一列真的會發生**的事（依 resolution 分支），不要三種混在一起講：
  //   同一句話對別的 resolution 就是假的（本檔隔壁 TransferShortageResolveModal 的第一鐵則）。
  // ⛔ 擋下來的三種情況由 RPC 判斷並回中文訊息（撿貨單已派貨出倉 / 沖回的貨已被派走 /
  //   沖帳月份已鎖定），前端不預先猜 —— 猜錯會變成「畫面說可以、按下去被擋」。
  async function undoResolution(r: ResolvedRow) {
    const label = RESOLUTION_LABEL[r.resolution] ?? r.resolution;
    const detail =
      r.resolution === "reject_return"
        ? `・實收會改回 ${r.prev_qty ?? "原本"} 件（現在是 ${r.qty_shipped} 件）\n・這一筆會回到「收貨短少」清單重新等處理`
        : r.resolution === "over_ack"
          ? "・這一筆會回到「收貨多收」清單"
          : r.resolution === "redispatch"
            ? "・記回出貨端的那幾件會被沖銷（貨已經被派出去的話會擋下來）\n・補派的撿貨單會被取消（已派貨出倉的話會擋下來）\n・短收沖帳單會作廢（月結重算時那筆退款就沒了）\n・這一筆會回到「收貨短少」清單重新等處理"
            : r.resolution === "restock_hq"
              ? "・記回出貨端的那幾件會被沖銷（貨已經被派出去的話會擋下來）\n・短收沖帳單會作廢（月結重算時那筆退款就沒了）\n・這一筆會回到「收貨短少」清單重新等處理"
              : "・這一筆的處理標記會清掉，回到收件匣重新等處理";
    if (
      !confirm(
        `要撤銷 ${r.transfer_no}／${r.sku_label} 的「${label}」嗎？\n\n${detail}\n\n（撤銷紀錄會寫進那張派貨單的備註，總倉收件匣看得到）`,
      )
    ) {
      return;
    }
    try {
      setResolvedError(null);
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_undo_transfer_item_shortage", {
        p_transfer_item_id: r.id,
        p_operator: operator,
        p_notes: null,
      });
      if (e) throw new Error(e.message);
      // 撤掉之後這一列就不再是「已處理」→ 重抓這一頁。
      // ⚠️ 上面 5 個分頁的徽章數字**這一刻不會動**：那支 effect 在 tab === "resolved"
      //   時整支跳過（:255）。切回去的時候才重抓，那時就會看到它回到「收貨短少」。
      setReloadTick((t) => t + 1);
    } catch (e) {
      setResolvedError(e instanceof Error ? e.message : String(e));
    }
  }

  // server-side 抓當前 tab + page(rpc_hq_exceptions 一次回 total / 各 tab counts / 當頁 rows)
  // ⛔ tab === "resolved" 時整支跳過:那一頁不是 rpc_hq_exceptions 的資料,
  //   跑下去只會拿錯的 total/rows 覆蓋掉;onCountChange 也就不會被錯的口徑呼叫。
  useEffect(() => {
    if (tab === "resolved") return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: err } = await sb.rpc("rpc_hq_exceptions", {
          p_type: tab,
          p_page: page,
          p_page_size: PAGE_SIZE,
        });
        if (err) throw err;
        if (cancelled) return;

        const resp = (data ?? { total: 0, counts: {}, rows: [] }) as {
          total: number;
          counts: Partial<ExceptionCounts>;
          rows: ViewRow[];
        };

        const mapped: ExceptionRow[] = (resp.rows ?? [])
          // DB view 未套 20260811020010 前的防禦:customer_shortage 一律不顯示
          .filter((r): r is ViewRow & { type: ExceptionType } => r.type in TAB_LABEL && r.type !== "all")
          .map((r) => ({
          key: r.row_key,
          type: r.type,
          ts: r.ts ?? "—",
          doc_no: r.doc_no,
          doc_link: docLinkFor(r),
          sku_code: r.sku_code,
          sku_label: r.sku_label,
          expected: Number(r.expected),
          actual: Number(r.actual),
          diff: Number(r.diff),
          reason: r.reason,
          extra: r.extra,
          warehouse_name: r.warehouse_name,
          shortage_ctx:
            r.type === "transfer_short" && r.transfer_item_id != null
              ? {
                  transfer_item_id: r.transfer_item_id,
                  transfer_id: r.transfer_id ?? 0,
                  transfer_no: r.transfer_no ?? `#${r.transfer_id}`,
                  sku_id: r.sku_id ?? 0,
                  sku_code: r.sku_code,
                  sku_label: r.sku_label,
                  qty_shipped: Number(r.qty_shipped),
                  qty_received: Number(r.qty_received),
                  shortage_qty: Number(r.shortage_qty),
                  dest_location: r.dest_location ?? 0,
                  dest_store_id: r.dest_store_id,
                  dest_store_name: r.dest_store_name ?? `位置 #${r.dest_location ?? "?"}`,
                }
              : undefined,
          over_item_id:
            r.type === "transfer_over" && r.transfer_item_id != null
              ? r.transfer_item_id
              : undefined,
        }));

        const cnts: ExceptionCounts = {
          all: resp.counts?.all ?? 0,
          po_shortage: resp.counts?.po_shortage ?? 0,
          po_damage: resp.counts?.po_damage ?? 0,
          po_over: resp.counts?.po_over ?? 0,
          transfer_short: resp.counts?.transfer_short ?? 0,
          transfer_over: resp.counts?.transfer_over ?? 0,
        };

        setRows(mapped);
        setTotal(resp.total ?? 0);
        setCounts(cnts);
        setError(null);
        if (onCountChange) onCountChange(cnts.all);

        // 處理掉項目後列表縮短 → 修正超出範圍的頁碼(在 async 內、非 effect body,不觸發 set-state-in-effect)
        if (mapped.length === 0 && page > 1 && (resp.total ?? 0) > 0) {
          setPage(Math.max(1, Math.ceil((resp.total ?? 0) / PAGE_SIZE)));
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [tab, page, reloadTick, onCountChange]);

  // 「已處理」分頁 —— PostgREST 直查,零 RPC 零 migration。
  //
  // 為什麼是「一次抓完 + 前端搜尋分頁」而不是 server-side 分頁:
  //   要搜的欄位(派貨單號、品名)不在 transfer_items 上,跨表搜尋做 server-side
  //   得先把 transfers / skus 查成 id 清單再回頭 .in(),兩邊都可能上千個 id;
  //   而這份資料本來就很小(2026-08-21 正式庫唯讀實測:已處理過的總共 139 筆
  //   ——restock_hq 85 / accept 31 / redispatch 23,見機制索引「短收差額」節),
  //   預設 30 天更遠低於上限 ⇒ 一次抓完最簡單也最不會出錯。
  //   ⚠️ 真的破 RESOLVED_CAP 時**畫面會明講**「只顯示最近 N 筆」,不靜靜截斷。
  //
  // ⚠️ 日期篩的是 shortage_resolution_at(處理時間,不是出貨/收貨時間)。
  //   三個版本的 resolve RPC 都無條件寫這個欄位
  //   (20260607000040:57-63 / 20260810000010 / 20260811020000:262-270)
  //   ⇒ 走畫面按出來的紀錄一定有值。
  useEffect(() => {
    if (tab !== "resolved") return;
    let cancelled = false;
    (async () => {
      setResolvedRows(null);
      setResolvedError(null);
      try {
        const sb = getSupabase();

        // ① 主查詢:已處理的短收明細
        let q = sb
          .from("transfer_items")
          .select(
            "id, transfer_id, sku_id, qty_shipped, qty_received, shortage_prev_qty_received, shortage_resolution, shortage_resolution_at, shortage_resolution_by, shortage_resolution_notes, shortage_redispatch_wave_id",
            { count: "exact" },
          )
          .not("shortage_resolution", "is", null)
          // id 當第二排序鍵:同一秒處理好幾筆時才有穩定順序
          .order("shortage_resolution_at", { ascending: false })
          .order("id", { ascending: false })
          .range(0, RESOLVED_CAP - 1);
        if (dateFrom) q = q.gte("shortage_resolution_at", `${dateFrom}T00:00:00`);
        if (dateTo) q = q.lte("shortage_resolution_at", `${dateTo}T23:59:59.999`);
        const { data, count, error: err } = await q;
        if (err) throw new Error(err.message);
        if (cancelled) return;

        type ItemRow = {
          id: number;
          transfer_id: number | null;
          sku_id: number | null;
          qty_shipped: number | string | null;
          qty_received: number | string | null;
          shortage_prev_qty_received: number | string | null;
          shortage_resolution: string;
          shortage_resolution_at: string | null;
          shortage_resolution_by: string | null;
          shortage_resolution_notes: string | null;
          shortage_redispatch_wave_id: number | null;
        };
        const items = (data ?? []) as unknown as ItemRow[];

        // ② 反查:派貨單 / 品項 / 補派撿貨單 / 收貨端店名 / 誰按的
        const [transfers, skus, waves] = await Promise.all([
          selectByIds<{ id: number; transfer_no: string; dest_location: number | null }>(
            sb, "transfers", "id, transfer_no, dest_location", "id",
            items.map((i) => i.transfer_id).filter((x): x is number => x != null),
          ),
          selectByIds<{ id: number; sku_code: string | null; product_name: string | null; variant_name: string | null }>(
            // skus.product_name 是熱路徑 denorm 欄(20260422120001:80,90),
            // v_hq_exceptions 的品名也是用它組的(20260811020010:110)
            // ⇒ 跟隔壁「收貨短少」分頁的品名長一模一樣,不另外 JOIN products。
            sb, "skus", "id, sku_code, product_name, variant_name", "id",
            items.map((i) => i.sku_id).filter((x): x is number => x != null),
          ),
          selectByIds<{ id: number; wave_code: string; status: string; created_at: string }>(
            sb, "picking_waves", "id, wave_code, status, created_at", "id",
            items.map((i) => i.shortage_redispatch_wave_id).filter((x): x is number => x != null),
          ),
        ]);
        if (cancelled) return;

        const transferMap = new Map(transfers.map((t) => [t.id, t]));
        const skuMap = new Map(skus.map((s) => [s.id, s]));
        const waveMap = new Map(waves.map((w) => [w.id, w]));

        // 收貨端名稱:先 stores.location_id,再 locations.name,最後「位置 #N」——
        // 逐字照 v_hq_exceptions 的做法(20260811020010:128-132),兩個分頁才會叫同一個名字。
        const destLocs = transfers.map((t) => t.dest_location).filter((x): x is number => x != null);
        const [stores, locations] = await Promise.all([
          selectByIds<{ id: number; name: string; location_id: number | null }>(
            sb, "stores", "id, name, location_id", "location_id", destLocs,
          ),
          selectByIds<{ id: number; name: string }>(sb, "locations", "id, name", "id", destLocs),
        ]);
        if (cancelled) return;
        const storeNameByLoc = new Map<number, string>();
        // view 是 ORDER BY ds.id LIMIT 1 → 同一個 location 有多家店時取 id 最小那家
        for (const s of [...stores].sort((a, b) => a.id - b.id)) {
          if (s.location_id != null && !storeNameByLoc.has(s.location_id)) {
            storeNameByLoc.set(s.location_id, s.name);
          }
        }
        const locNameById = new Map(locations.map((l) => [l.id, l.name]));

        // 誰按的 —— 既有機制 rpc_get_staff_names(20260428170000,回 { id, display_name })
        const uids = Array.from(
          new Set(items.map((i) => i.shortage_resolution_by).filter((x): x is string => !!x)),
        );
        const nameMap = new Map<string, string>();
        if (uids.length > 0) {
          const { data: ns } = await sb.rpc("rpc_get_staff_names", { p_uids: uids });
          for (const n of (ns as { id: string; display_name: string }[] | null) ?? []) {
            nameMap.set(n.id, n.display_name);
          }
        }
        if (cancelled) return;

        const mapped: ResolvedRow[] = items.map((i) => {
          const t = i.transfer_id != null ? transferMap.get(i.transfer_id) : undefined;
          const s = i.sku_id != null ? skuMap.get(i.sku_id) : undefined;
          const w = i.shortage_redispatch_wave_id != null ? waveMap.get(i.shortage_redispatch_wave_id) : undefined;
          const loc = t?.dest_location ?? null;
          const label = `${s?.product_name ?? ""}${s?.variant_name ? ` / ${s.variant_name}` : ""}`.trim();
          // 「少幾件」= 派出 − 實收。⚠️ reject_return 從 20260903000200 起會把實收補回
          //   派出量(純紀錄),那一列現值算出來是 0 ⇒ 要用補回前的數字才是當初的少收量。
          //   ⛔ 不要對所有 resolution 都套 prev:DB 只在 reject_return 的列上寫它。
          const baseRecv =
            i.shortage_resolution === "reject_return" && i.shortage_prev_qty_received != null
              ? Number(i.shortage_prev_qty_received)
              : Number(i.qty_received ?? 0);
          return {
            id: i.id,
            at: i.shortage_resolution_at,
            by_name: i.shortage_resolution_by ? (nameMap.get(i.shortage_resolution_by) ?? null) : null,
            transfer_no: t?.transfer_no ?? `#${i.transfer_id ?? "?"}`,
            dest_name:
              (loc != null ? storeNameByLoc.get(loc) : undefined) ??
              (loc != null ? locNameById.get(loc) : undefined) ??
              `位置 #${loc ?? "?"}`,
            sku_code: s?.sku_code ?? null,
            sku_label: label || `品項#${i.sku_id ?? "?"}`,
            shortage_qty: Number(i.qty_shipped ?? 0) - baseRecv,
            qty_shipped: Number(i.qty_shipped ?? 0),
            prev_qty:
              i.shortage_prev_qty_received != null ? Number(i.shortage_prev_qty_received) : null,
            resolution: i.shortage_resolution,
            notes: i.shortage_resolution_notes,
            wave_code: w?.wave_code ?? null,
            wave_status: w?.status ?? null,
            wave_created_date: w?.created_at ? w.created_at.slice(0, 10) : null,
          };
        });

        setResolvedRows(mapped);
        setResolvedTotal(count ?? mapped.length);
      } catch (e) {
        if (!cancelled) {
          setResolvedRows([]);
          setResolvedError(e instanceof Error ? e.message : String(e));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [tab, dateFrom, dateTo, reloadTick]);

  // 搜尋:派貨單號 / 品名 / 品號 / 店名 / 備註(前端做,母體是上面一次抓回來的整段日期範圍)
  const filteredResolved = useMemo(() => {
    const kw = search.trim().toLowerCase();
    if (!kw) return resolvedRows ?? [];
    return (resolvedRows ?? []).filter((r) =>
      [r.transfer_no, r.sku_label, r.sku_code, r.dest_name, r.notes, r.wave_code]
        .filter((x): x is string => !!x)
        .some((x) => x.toLowerCase().includes(kw)),
    );
  }, [resolvedRows, search]);

  const c = counts ?? EMPTY_COUNTS;
  const isResolved = tab === "resolved";
  // 上面 5 個分頁 = server-side 分頁(total 來自 RPC);
  // 「已處理」= 一次抓完後前端分頁(母體是搜尋過的 filteredResolved)。
  const viewTotal = isResolved ? filteredResolved.length : total;
  const viewReady = isResolved ? resolvedRows !== null : rows !== null;
  const totalPages = Math.max(1, Math.ceil(viewTotal / PAGE_SIZE));
  const currentPage = Math.min(page, totalPages);
  const resolvedPageRows = filteredResolved.slice((currentPage - 1) * PAGE_SIZE, currentPage * PAGE_SIZE);

  // 分頁控制列 — 表格上、下各放一份
  // (手機不用滑過整頁 20 列才能換頁),樣式對齊 /hq/inbox 其他來源
  const paginationBar = viewReady && viewTotal > PAGE_SIZE ? (
    <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
      <span className="text-xs text-zinc-500">
        共 {viewTotal} 筆 · 顯示 {(currentPage - 1) * PAGE_SIZE + 1} - {Math.min(currentPage * PAGE_SIZE, viewTotal)}
      </span>
      <SpinButton onClick={() => setPage(1)} disabled={currentPage === 1}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        « 第一頁
      </SpinButton>
      <SpinButton onClick={() => setPage(currentPage - 1)} disabled={currentPage === 1}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        ‹ 上頁
      </SpinButton>
      <span className="text-xs text-zinc-500">{currentPage} / {totalPages}</span>
      <SpinButton onClick={() => setPage(currentPage + 1)} disabled={currentPage === totalPages}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        下頁 ›
      </SpinButton>
      <SpinButton onClick={() => setPage(totalPages)} disabled={currentPage === totalPages}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        最末頁 »
      </SpinButton>
    </div>
  ) : null;

  return (
    <div className="flex flex-1 flex-col gap-4">
      {showHeader && (
        <header>
          <h1 className="text-xl font-semibold">⚠️ 異常處理</h1>
          <p className="text-sm text-zinc-500">
            {counts === null ? "載入中…" : `共 ${c.all} 筆異常 · 進貨短少 ${c.po_shortage} / 進貨破損 ${c.po_damage} / 過量 ${c.po_over} / 收貨短少 ${c.transfer_short} / 收貨多收 ${c.transfer_over}`}
          </p>
        </header>
      )}

      {(isResolved ? resolvedError : error) && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {isResolved ? resolvedError : error}
        </div>
      )}

      <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["all", "po_shortage", "po_damage", "po_over", "transfer_short", "transfer_over", "resolved"] as const).map((t) => {
          const active = tab === t;
          return (
            <SpinButton
              key={t}
              onClick={() => setTab(t)}
              className={`-mb-px border-b-2 px-3 py-2 text-sm ${
                active
                  ? "border-rose-600 font-semibold text-rose-700 dark:text-rose-300"
                  : "border-transparent text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
              }`}
            >
              {TAB_BAR_LABEL[t]}
              {/* 「已處理」故意不掛數字:它跟旁邊 5 個不同母體(且會隨日期範圍變),
                  掛在同一排會被讀成「又多了 N 件要處理」。 */}
              {t !== "resolved" && <span className="ml-1 text-xs text-zinc-400">{c[t]}</span>}
            </SpinButton>
          );
        })}
      </div>

      {isResolved && (
        <>
          {/* 這一頁在回答什麼 —— ⭐ 每一句都要指得出出處(見下方註解),⛔ 不寫絕對句 */}
          <div className="rounded-md border border-zinc-300 bg-zinc-50 p-3 text-xs leading-relaxed text-zinc-700 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
            <div className="font-semibold">這一頁是處理紀錄，按錯了可以用最右邊的「↩ 撤銷」收回。</div>
            <div className="mt-1 font-semibold">「↩ 撤銷」會做什麼？</div>
            <ul className="mt-0.5 list-disc space-y-1 pl-4">
              <li>
                <span className="font-bold">共同的：</span>那一筆的處理標記會清掉，
                <span className="font-bold">回到「收貨短少」/「收貨多收」清單</span>重新等處理，
                店家的實收也就改得動了。撤銷紀錄會寫進那張派貨單的備註。
              </li>
              <li>
                撤銷「<span className="font-bold">同意退回</span>」兩顆 → 記回原本送貨出去那一邊的數量會被
                <span className="font-bold">沖銷</span>、短收沖帳單會<span className="font-bold">作廢</span>
                （月結重算時那筆退款就沒了）；「補貨」那顆另外開的補派撿貨單會一起取消。
              </li>
              <li>
                撤銷「<span className="font-bold">不同意退貨</span>」→ 按下去時被補回派出量的
                <span className="font-bold">實收會改回原本的數字</span>（「少幾件」那一欄顯示的就是原本少收多少）。
              </li>
              <li>
                ⚠️ <span className="font-bold">這三種情況系統會擋下來</span>，訊息會直接寫在畫面上：
                補派的撿貨單<span className="font-bold">已經派貨出倉</span>（請先到「📋 撿貨單」把它取消）、
                記回去的貨<span className="font-bold">已經被派出去了</span>（出貨端庫存不夠沖銷）、
                沖帳落在<span className="font-bold">已經鎖定的對帳單月份</span>。
                另外舊值「取消客戶訂單」不給撤（客人已經收到取消通知）。
              </li>
              <li>
                ⚠️ 撤銷成功後<span className="font-bold">這一頁就查不到那一筆了</span> ——
                這一頁顯示的是「現在的處理狀態」，不是歷史帳。要看軌跡請看那張派貨單的備註。
              </li>
            </ul>
          </div>
          {/*
            上面每一句的出處(⛔ 改文字前先確認出處還成立)。
            ⚠️ 2026-09-03 整段換過:上一版的出處對應的是「這一頁按不了任何東西 /
              紀錄不會變回未處理」那組句子,撤銷做上去之後那些句子已經全部改寫。

            ① 「處理標記會清掉、回到清單」→ rpc_undo_transfer_item_shortage 尾段那個 UPDATE
               把 shortage_resolution / _at / _by / _notes / _restock_movement_id /
               _redispatch_wave_id / _return_transfer_id / _prev_qty_received 八個欄位寫成 NULL
               (20260903000200 的邏輯 e);而 v_hq_exceptions 兩個分支都要求
               shortage_resolution IS NULL 才列出來
               (v_hq_exceptions 最新版 20260824020000_receive_allocate_rework.sql:
                transfer_short 的 WHERE 在 :1497-1499、transfer_over 在 :1557-1558;
                查法 git grep -ln "CREATE OR REPLACE VIEW public.v_hq_exceptions",
                共 3 版、20260824020000 是最後一支)⇒ 清掉就會自己回到清單。
            ② 「店家的實收也就改得動了」→ rpc_adjust_received_transfer 守衛 B 擋的條件就是
               shortage_resolution IS NOT NULL(且不是 over_ack)
               —— 20260903000005 定的,20260903000200 只改它的錯誤訊息、判定一字未改。
            ③ 「撤銷紀錄會寫進那張派貨單的備註」→ 同一支 RPC 最後 UPDATE transfers.notes
               追加一行「撤銷處理(MM/DD HH:MI)：…」;而 v_hq_exceptions 的 reason 欄就是
               「店家收貨備註：」|| t.notes(20260824020000:1467 transfer_short、
               :1529 transfer_over,兩段那個 CASE 都只有這一個 WHEN ⇒ 無條件成立;
               2026-09-03 已對線上 pg_get_viewdef 再確認一次),
               前端把 reason 畫成「⚠ …」那一行 ⇒ 總倉收件匣真的看得到。
            ④ 「同意退回兩顆:沖銷 / 沖帳單作廢 / 撿貨單一起取消」→ 同一支 RPC 的
               邏輯 a(對 shortage_restock_movement_id 寫一筆 reversal)、
               邏輯 c(shortage_return_transfer_id 那張 return_to_hq 改 status='cancelled';
               月結 F 段白名單只吃 received/closed ⇒ 一改就不再沖帳)、
               邏輯 b(shortage_redispatch_wave_id 且 status='draft' → cancelled + 稽核紀錄)。
               ⛔ 刻意寫「原本送貨出去的那一邊」不寫「總倉」:沖回的目的地是
               transfers.source_location,restock_hq 沒有總倉守衛(redispatch 才有),
               店對店的單貨是回到原本那家店。
            ⑤ 「不同意退貨:實收會改回原本的數字」→ reject_return 在 20260903000200 起會把
               qty_received 補回 qty_shipped、舊值存進 shortage_prev_qty_received,
               撤銷時由邏輯 d 拿它還原。「少幾件」那一欄顯示的也是用它算的(見上面 baseRecv)。
            ⑥ 「這三種情況系統會擋下來」→ 同一支 RPC 的守衛 B(picking_waves.status
               NOT IN ('draft','cancelled') → RAISE)、邏輯 a 的實體守衛
               (stock_balances.on_hand < 要沖銷的量 → RAISE)、守衛 C
               (沖帳單所在月份的 store_monthly_settlements.status IN
                ('confirmed','settled','remitted') → RAISE);
               「取消客戶訂單不給撤」→ 守衛 A(shortage_resolution='cancel_orders' → RAISE),
               前端那一列因此不畫按鈕、只寫「不給撤銷」。
               ⛔ 這幾句一定要寫成「會擋下來」而不是「不能按」——按得下去,是 RPC 回錯誤,
                 錯誤訊息會出現在畫面上方那個紅框(setResolvedError)。
            ⑦ 「撤銷成功後這一頁就查不到那一筆」→ 這一頁的主查詢是
               .not("shortage_resolution","is",null)(見上面那支 effect)⇒ 清掉標記就撈不到。
               ⛔ 這句要留著:員工會以為撤銷後還能在這裡看到「我撤過」的紀錄。
          */}

          {/* 篩選 — 日期(打 DB)+ 搜尋(前端,母體是整段日期範圍) */}
          <div className="flex flex-wrap items-center gap-2">
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="🔍 搜尋 派貨單號 / 品名 / 店"
              className="flex-1 min-w-[180px] rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
            />
            <input
              type="date"
              value={dateFrom}
              onChange={(e) => setDateFrom(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
            />
            <span className="text-xs text-zinc-500">～</span>
            <input
              type="date"
              value={dateTo}
              onChange={(e) => setDateTo(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
            />
            <span className="text-xs text-zinc-500">（依處理時間，預設最近 30 天）</span>
          </div>

          {/* 筆數 —— 20 筆以內不會有分頁列,不放這行就完全看不到自己在看幾筆。
              ⛔ 措辭刻意用「目前顯示」不用「共」:破 RESOLVED_CAP 時上面那個琥珀框
              講的「共 N 筆」是 DB 端真實筆數,兩個數字會不一樣,都寫「共」會互相打臉。 */}
          {resolvedRows !== null && (
            <div className="text-xs text-zinc-500">
              目前顯示 {filteredResolved.length} 筆
              {search.trim() && resolvedRows.length !== filteredResolved.length
                ? `（這段日期抓回 ${resolvedRows.length} 筆，搜尋後剩這些）`
                : ""}
            </div>
          )}

          {/* 上限到了要明講,不可以靜靜截斷 */}
          {resolvedTotal > RESOLVED_CAP && (
            <div className="rounded-md border border-amber-300 bg-amber-50 p-2 text-xs text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-200">
              這段日期共 {resolvedTotal} 筆，<span className="font-bold">只顯示最近 {RESOLVED_CAP} 筆</span>
              （較舊的沒抓進來，請把日期範圍縮小再看）。
            </div>
          )}
        </>
      )}

      {/* 分頁 — 表格上方(手機優先看得到) */}
      {paginationBar}

      {isResolved ? (
        <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                <th className="px-3 py-2">處理時間</th>
                <th className="px-3 py-2">誰按的</th>
                <th className="px-3 py-2">派貨單</th>
                <th className="px-3 py-2">店</th>
                <th className="px-3 py-2">品項</th>
                <th className="px-3 py-2 text-right">少幾件</th>
                <th className="px-3 py-2">按了哪顆</th>
                <th className="px-3 py-2">補派的撿貨單</th>
                <th className="px-3 py-2">備註</th>
                <th className="px-3 py-2"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {resolvedRows === null ? (
                <tr><td colSpan={10} className="p-6 text-center text-zinc-500">載入中…</td></tr>
              ) : resolvedPageRows.length === 0 ? (
                <tr><td colSpan={10} className="p-6 text-center text-zinc-500">
                  這段日期沒有處理紀錄{search.trim() ? "（或沒有符合搜尋的）" : ""}
                </td></tr>
              ) : resolvedPageRows.map((r) => (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                  <td className="px-3 py-2 text-xs whitespace-nowrap">
                    {r.at ? r.at.slice(0, 16).replace("T", " ") : "—"}
                  </td>
                  <td className="px-3 py-2 text-xs whitespace-nowrap">{r.by_name ?? "—"}</td>
                  <td className="px-3 py-2 font-mono text-xs whitespace-nowrap">{r.transfer_no}</td>
                  <td className="px-3 py-2 text-xs whitespace-nowrap font-medium">{r.dest_name}</td>
                  <td className="px-3 py-2 text-xs min-w-[220px]">
                    {r.sku_code && <div className="font-mono text-[10px] text-zinc-500">{r.sku_code}</div>}
                    <div>{r.sku_label}</div>
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs font-bold text-rose-600 whitespace-nowrap">
                    {r.shortage_qty}
                  </td>
                  <td className="px-3 py-2 text-xs whitespace-nowrap">
                    <span className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ${
                      r.resolution === "redispatch"
                        ? "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300"
                        : r.resolution === "restock_hq"
                          ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                          : "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
                    }`}>
                      {/* 對不上的值照原樣顯示 —— DB CHECK 允許六值(20260811020000:66-69),
                          以後多一種也不會變成空白或 undefined */}
                      {RESOLUTION_LABEL[r.resolution] ?? r.resolution}
                    </span>
                  </td>
                  <td className="px-3 py-2 text-xs whitespace-nowrap">
                    {r.wave_code == null ? (
                      <span className="text-zinc-400">—</span>
                    ) : (
                      <>
                        {onGotoPicking ? (
                          <SpinButton
                            onClick={() => onGotoPicking(r.wave_code!, r.wave_created_date)}
                            title="跳到「📋 撿貨單」，並把日期框到這張單建立的那天、搜尋框填入單號"
                            className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                          >
                            {r.wave_code}
                          </SpinButton>
                        ) : (
                          <span className="font-mono">{r.wave_code}</span>
                        )}
                        {r.wave_status && (
                          <span className="ml-1 text-[10px] text-zinc-500">
                            （{WAVE_STATUS_LABEL[r.wave_status] ?? r.wave_status}）
                          </span>
                        )}
                      </>
                    )}
                  </td>
                  <td className="px-3 py-2 text-xs text-zinc-500 min-w-[160px]">{r.notes ?? "—"}</td>
                  <td className="px-3 py-2 text-xs whitespace-nowrap">
                    {/* 「取消客戶訂單」是舊值且不給撤（客人已收到取消通知，RPC 也會擋）
                        ⇒ 不畫按鈕，直接把理由寫出來，不要做一顆按下去一定失敗的鈕。
                        其餘一律給按 —— 會不會擋得住由 RPC 判斷（撿貨單已派貨出倉 /
                        沖回的貨已被派走 / 月份已鎖定），前端不預先猜。 */}
                    {r.resolution === "cancel_orders" ? (
                      <span className="text-[10px] text-zinc-400" title="客人已經收到取消通知，不能一鍵撤銷">
                        不給撤銷
                      </span>
                    ) : (
                      <SpinButton
                        onClick={() => undoResolution(r)}
                        className="rounded-md border border-zinc-300 px-2 py-1 text-xs font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800"
                        title="撤銷這一筆處理：回到收件匣重新等處理（詳細後果看上面的說明）"
                      >
                        ↩ 撤銷
                      </SpinButton>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">類型</th>
              <th className="px-3 py-2">單號</th>
              <th className="px-3 py-2">地點</th>
              <th className="px-3 py-2">品項</th>
              <th className="px-3 py-2 text-right">預期</th>
              <th className="px-3 py-2 text-right">實際</th>
              <th className="px-3 py-2 text-right">差額</th>
              <th className="px-3 py-2">原因 / 備註</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">沒有異常,系統運作正常 ✓</td></tr>
            ) : rows.map((r) => (
              <tr key={r.key} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                <td className="px-3 py-2 whitespace-nowrap">
                  <span className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ${
                    r.type === "po_shortage" ? "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300" :
                    r.type === "po_damage" ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300" :
                    r.type === "po_over" ? "bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300" :
                    r.type === "transfer_over" ? "bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-300" :
                    "bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300"
                  }`}>{TAB_LABEL[r.type]}</span>
                </td>
                <td className="px-3 py-2 font-mono text-xs whitespace-nowrap">{r.doc_no}</td>
                <td className="px-3 py-2 text-xs whitespace-nowrap font-medium">{r.warehouse_name ?? "—"}</td>
                <td className="px-3 py-2 text-xs min-w-[220px]">
                  {r.sku_code && <div className="font-mono text-[10px] text-zinc-500">{r.sku_code}</div>}
                  <div>{r.sku_label}</div>
                </td>
                <td className="px-3 py-2 text-right font-mono text-xs whitespace-nowrap">{r.expected}</td>
                <td className="px-3 py-2 text-right font-mono text-xs whitespace-nowrap">{r.actual}</td>
                <td className="px-3 py-2 text-right font-mono text-xs font-bold text-rose-600 whitespace-nowrap">{r.diff > 0 ? `-${r.diff}` : `+${Math.abs(r.diff)}`}</td>
                <td className="px-3 py-2 text-xs text-zinc-500">
                  {r.reason && <div className="text-amber-700 dark:text-amber-400 whitespace-nowrap">⚠ {r.reason}</div>}
                  <div className="whitespace-nowrap">{r.extra}</div>
                </td>
                <td className="px-3 py-2 text-xs whitespace-nowrap">
                  {r.type === "transfer_short" && r.shortage_ctx ? (
                    <SpinButton
                      onClick={() => setResolveCtx(r.shortage_ctx ?? null)}
                      className="rounded-md bg-blue-600 px-3 py-1 text-xs font-semibold text-white hover:bg-blue-700"
                    >
                      處理
                    </SpinButton>
                  ) : r.type === "transfer_over" && r.over_item_id != null ? (
                    <SpinButton
                      onClick={() => ackOver(r.over_item_id as number, r.doc_no)}
                      className="rounded-md bg-violet-600 px-3 py-1 text-xs font-semibold text-white hover:bg-violet-700"
                      title="標記已知悉：分店多收的量已照實入分店帳，這列從收件匣移除"
                    >
                      知道了
                    </SpinButton>
                  ) : (
                    <Link href={r.doc_link} className="text-blue-600 hover:underline dark:text-blue-400">前往 →</Link>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      )}

      {/* 分頁 — 表格下方再放一份 */}
      {paginationBar}

      {resolveCtx && (
        <TransferShortageResolveModal
          ctx={resolveCtx}
          onClose={() => setResolveCtx(null)}
          onSubmitted={() => {
            setResolveCtx(null);
            setReloadTick((t) => t + 1);
          }}
        />
      )}
    </div>
  );
}

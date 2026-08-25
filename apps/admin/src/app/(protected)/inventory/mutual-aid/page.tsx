"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { ProductImagesField } from "@/components/ProductImagesField";
import { printViaIframe } from "@/lib/printIframe";
import { withBasePath } from "@/lib/basePath";
import { useUserBranchStoreId } from "@/lib/useDefaultStoreFromUser";
import { shortOrderNo } from "@/lib/orderTitle";
import { translateRpcError } from "@/lib/rpcError";
import {
  TRANSFER_LINK_SELECT, type TransferLink,
  activeQty, aidRouteLabel, aidStageLabel, isAidInFlight, linkItems,
} from "@/lib/aidTransfer";
import { orderStatusLabel } from "@/lib/orderStatus";

type Store = { id: number; code: string; name: string };
type SkuOption = { id: number; sku_code: string; product_name: string; variant_name: string | null };

type PostType = "offer" | "request";

type Post = {
  id: number;
  post_type: PostType;
  offering_store_id: number;
  /** 手動現貨可能沒有 SKU（店家直接手打的商品） */
  sku_id: number | null;
  qty_available: number;
  qty_remaining: number;
  expires_at: string;
  note: string | null;
  status: "active" | "exhausted" | "expired" | "cancelled";
  source_customer_order_id: number | null;
  spot_price: number | null;
  spot_description: string | null;
  spot_title: string | null;
  spot_unit: string | null;
  spot_images: string[] | null;
  /** false = 只有 offering_store_id 那間店的會員看得到（liff-api 直接濾掉） */
  spot_visible_to_other_stores: boolean;
  created_at: string;
  created_by: string | null;
  store_name?: string;
  sku_label?: string;
  source_order_no?: string | null;
  replies_count?: number;
};

type PendingOrder = {
  id: number;
  order_no: string;
  pickup_store_id: number;
  status: string;
  member_name: string | null;
  member_phone: string | null;
  items: {
    campaign_item_id: number | null;
    sku_id: number | null;
    qty: number;
    sku_label: string;
    /** 會員 App 沒有自訂標題時會組出的字串（product_name／variant_name）。
     *  上架表單拿它當「商品標題」的預設值，店家沒動就不寫進 spot_title。 */
    default_title: string;
    unit_price: number | null;
    product_description: string | null;
  }[];
};

/** 「我提供出去的／我收到的」一列 = 一趟轉移（customer_order_transfer_links 一列） */
type ProvidedRow = {
  linkId: number;
  transferred_at: string;
  is_air_transfer: boolean;
  /** 這趟是哪一則互助貼文促成的；舊資料（連結表回填出來的）認不出來就是 null */
  board_id: number | null;
  reason: string | null;
  source_store: string;
  source_store_id: number | null;
  source_order_no: string;
  dest_store: string;
  dest_store_id: number | null;
  dest_order_id: number;
  dest_order_no: string;
  dest_status: string;
  qty: number;
  labels: string[];
  /** 這張轉入單身上總共有幾趟轉移。>1 = 舊的併入單（多店混一張），
   *  取消整張會把別家店的貨一起取消掉 → 不出取消鈕 */
  link_count: number;
  /** 同店互轉（變更取貨人）：商品未離開本店，無配送階段、不出取消／退回／隨貨單鈕 */
  same_store: boolean;
  /** 這一趟是怎麼來的：aid=互助板認領、order=訂單轉單、unknown=連結表上線前的舊資料
   *  （2026-08-24 之前的轉移由回填補建，原始 reason 已遺失，判不出來就不要猜） */
  origin: "aid" | "order" | "unknown";
  /** 同店互轉的兩位客人（原客人 → 新客人）；跨店列不用 */
  from_party: string | null;
  to_party: string | null;
};

type Reply = {
  id: number;
  board_id: number;
  author_id: string | null;
  author_label: string | null;
  body: string;
  created_at: string;
};

const STATUS_LABEL: Record<Post["status"], string> = {
  active: "進行中",
  exhausted: "已認領",
  expired: "已過期",
  cancelled: "已取消",
};

const STATUS_COLOR: Record<Post["status"], string> = {
  active: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  exhausted: "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-400",
  expired: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

/** TipTap HTML → 純文字（textarea 預填用）：區塊標籤轉換行、去標籤、還原常見 entity */
function stripHtmlToText(raw: string | null | undefined): string {
  if (!raw) return "";
  return raw
    .replace(/<\/(p|div|h[1-6]|li|tr|blockquote)\s*>/gi, "\n")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/(&#0*39;|&apos;)/gi, "'")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

const TYPE_LABEL: Record<PostType, string> = {
  offer: "釋出",
  request: "需求",
};

const TYPE_COLOR: Record<PostType, string> = {
  offer: "bg-pink-100 text-pink-800 dark:bg-pink-950 dark:text-pink-300",
  request: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
};

export default function MutualAidPage() {
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  // same_store 是獨立分頁：同店變更取貨人的轉出店＝接收店，掛在「我轉出／我接收」
  // 底下會變成同一筆出現兩次（2026-08-25 回報）→ 拉到與「進行中」同層。
  const [view, setView] = useState<"active" | "history" | "provided" | "received" | "same_store">("active");
  const [filter, setFilter] = useState<"all" | "request" | "offer">("all");
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [requestModalOpen, setRequestModalOpen] = useState(false);
  const [offerModalOpen, setOfferModalOpen] = useState(false);
  const [manualModalOpen, setManualModalOpen] = useState(false);
  const [threadPost, setThreadPost] = useState<Post | null>(null);

  // 貼文數變動（發文/關貼/認領）後重載列表，並通知側欄「互助交流板」badge 重抓
  // (見 layout AID_BADGE_REFRESH_EVENT)
  function reloadAndRefreshBadge() {
    setReloadTick((n) => n + 1);
    window.dispatchEvent(new Event("aid-badge-refresh"));
  }

  // 載入 stores 一次
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data } = await sb.from("stores").select("id, code, name").eq("is_active", true).order("name");
      if (!cancelled) setStores((data ?? []) as Store[]);
    })();
    return () => { cancelled = true; };
  }, []);

  // 載入 posts（「我提供出去的」是另一份資料來源，由 ProvidedList 自己撈）
  useEffect(() => {
    if (view === "provided" || view === "received" || view === "same_store") return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        let q = sb
          .from("mutual_aid_board")
          .select("id, post_type, offering_store_id, sku_id, qty_available, qty_remaining, expires_at, note, status, source_customer_order_id, spot_price, spot_description, spot_title, spot_unit, spot_images, spot_visible_to_other_stores, created_at, created_by");
        // 歷史 = 已結束（已認領／已過期／已取消），對齊 rpc_purge_expired_aid_board
        // 20260824000000 起到期不再刪除，這三種狀態才查得到完整歷史
        q = view === "active" ? q.eq("status", "active") : q.neq("status", "active");
        q = q.order("created_at", { ascending: false }).limit(200);
        if (filter !== "all") q = q.eq("post_type", filter);
        const { data, error: e } = await q;
        if (e) throw new Error(e.message);
        const rows = ((data as Post[] | null) ?? []);
        if (rows.length === 0) {
          if (!cancelled) setPosts([]);
          return;
        }
        // 手打的手動現貨沒有 sku_id，別把 null 塞進 .in() 查詢
        const skuIds = Array.from(new Set(rows.map((r) => r.sku_id).filter((x): x is number => x != null)));
        const storeIds = Array.from(new Set(rows.map((r) => r.offering_store_id)));
        const boardIds = rows.map((r) => r.id);
        const orderIds = Array.from(new Set(rows.map((r) => r.source_customer_order_id).filter((x): x is number => x != null)));

        const [skuRes, storeRes, replyRes, orderRes] = await Promise.all([
          skuIds.length > 0
            ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds)
            : Promise.resolve({ data: [], error: null }),
          sb.from("stores").select("id, name").in("id", storeIds),
          sb.from("mutual_aid_replies").select("board_id").in("board_id", boardIds),
          orderIds.length > 0
            ? sb.from("customer_orders").select("id, order_no").in("id", orderIds)
            : Promise.resolve({ data: [], error: null }),
        ]);
        const skuMap = new Map<number, SkuOption>(((skuRes.data ?? []) as SkuOption[]).map((s) => [s.id, s]));
        const storeMap = new Map<number, string>(((storeRes.data ?? []) as { id: number; name: string }[]).map((s) => [s.id, s.name]));
        const orderMap = new Map<number, string>(((orderRes.data ?? []) as { id: number; order_no: string }[]).map((o) => [o.id, o.order_no]));
        const replyCount = new Map<number, number>();
        for (const r of (replyRes.data ?? []) as { board_id: number }[]) {
          replyCount.set(r.board_id, (replyCount.get(r.board_id) ?? 0) + 1);
        }
        const enriched = rows.map((r) => {
          const sku = r.sku_id != null ? skuMap.get(r.sku_id) : undefined;
          return {
            ...r,
            store_name: storeMap.get(r.offering_store_id) ?? `#${r.offering_store_id}`,
            // 沒 SKU 的手打商品只有 spot_title 可以顯示
            sku_label: sku
              ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} (${sku.sku_code})`
              : r.sku_id != null
                ? `品項#${r.sku_id}`
                : r.spot_title ?? "（未命名）",
            source_order_no: r.source_customer_order_id ? orderMap.get(r.source_customer_order_id) ?? null : null,
            replies_count: replyCount.get(r.id) ?? 0,
          };
        });
        if (!cancelled) setPosts(enriched);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [view, filter, reloadTick]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">互助交流板</h1>
          <p className="text-sm text-zinc-500">
            分店貼出需求或可釋出的商品，其他分店認領後由系統自動完成訂單轉移。
          </p>
        </div>
        <div className="flex gap-2">
          {/* 「我轉出／我接收」列的是轉移紀錄不是貼文，整份清單列印不適用；
              那兩頁每一列有自己的隨貨單列印鈕（走 /transfers/print-aid 兩聯） */}
          {view !== "provided" && view !== "received" && view !== "same_store" && (
            <SpinButton
              type="button"
              onClick={() => printViaIframe(withBasePath(`/inventory/mutual-aid/print?type=${filter}&view=${view}`))}
              title="列印目前這個分頁的整份貼文清單（A4 橫式）；單獨一則請按該列右邊的 🖨️"
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
            >
              🖨️ 列印
            </SpinButton>
          )}
          <SpinButton
            type="button"
            onClick={() => setRequestModalOpen(true)}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700"
          >
            📢 我要求助
          </SpinButton>
          <SpinButton
            type="button"
            onClick={() => setOfferModalOpen(true)}
            className="rounded-md bg-pink-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-pink-700"
          >
            📦 我有庫存可提供
          </SpinButton>
          <SpinButton
            type="button"
            onClick={() => setManualModalOpen(true)}
            className="rounded-md bg-emerald-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-700"
          >
            ➕ 手動新增現貨
          </SpinButton>
        </div>
      </header>

      <div className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["active", "history", "provided", "received", "same_store"] as const).map((v) => (
          <SpinButton
            key={v}
            type="button"
            onClick={() => setView(v)}
            className={
              view === v
                ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
                : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {v === "active" ? "進行中"
              : v === "history" ? "歷史"
              : v === "provided" ? "我轉出"
              : v === "received" ? "我接收"
              : "同店變更取貨人"}
          </SpinButton>
        ))}
      </div>

      {view === "provided" || view === "received" || view === "same_store" ? (
        <ProvidedList
          stores={stores}
          direction={view === "provided" ? "out" : view === "received" ? "in" : "same"}
        />
      ) : (
      <>
      <div className="inline-flex w-fit overflow-hidden rounded-md border border-zinc-300 text-xs dark:border-zinc-700">
        {(["all", "request", "offer"] as const).map((opt) => (
          <SpinButton
            key={opt}
            type="button"
            onClick={() => setFilter(opt)}
            className={`px-3 py-1.5 ${
              filter === opt
                ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                : "bg-white text-zinc-600 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
            }`}
          >
            {opt === "all" ? "全部" : opt === "request" ? "需求中" : "釋出中"}
          </SpinButton>
        ))}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {posts === null ? (
        <div className="text-sm text-zinc-500">載入中…</div>
      ) : posts.length === 0 ? (
        <div className="rounded-md border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500 dark:border-zinc-700">
          {view === "active" ? "目前沒有進行中的" : "沒有已結束的"}
          {filter === "request" ? "需求" : filter === "offer" ? "釋出" : ""}貼文
        </div>
      ) : (
        <ul className="space-y-2">
          {posts.map((p) => (
            <li key={p.id} className="flex items-start gap-2 rounded-md border border-zinc-200 bg-white p-3 transition hover:border-zinc-400 hover:shadow-sm dark:border-zinc-800 dark:bg-zinc-900 dark:hover:border-zinc-600">
              <SpinButton
                type="button"
                onClick={() => setThreadPost(p)}
                className="block min-w-0 flex-1 text-left"
              >
                <div className="mb-1 flex flex-wrap items-center gap-2">
                  <span className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${TYPE_COLOR[p.post_type]}`}>
                    {TYPE_LABEL[p.post_type]}
                  </span>
                  <span className={`rounded px-1.5 py-0.5 text-[10px] ${STATUS_COLOR[p.status]}`}>
                    {STATUS_LABEL[p.status]}
                  </span>
                  <span className="text-sm font-medium">{p.store_name}</span>
                  <span className="text-sm">{p.sku_label}</span>
                  {p.post_type === "offer" && p.source_customer_order_id == null && (
                    <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                      手動
                    </span>
                  )}
                  {/* 沒選商品的手動現貨別店認領不了 —— 在列表就標出來，
                      不用點進去才發現（20260816000000） */}
                  {p.post_type === "offer" && p.sku_id == null && (
                    <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-800 dark:bg-amber-950 dark:text-amber-300" title="沒有選商品，別的分店無法認領；請點進貼文用「✏️ 修改內容」補選">
                      待補商品
                    </span>
                  )}
                  {p.post_type === "offer" && !p.spot_visible_to_other_stores && (
                    <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                      🔒 限本店會員
                    </span>
                  )}
                  <span className="ml-auto text-xs text-zinc-500">💬 {p.replies_count} 留言</span>
                </div>
                <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-500">
                  <span>
                    {p.post_type === "request" ? "需要" : "釋出"}{" "}
                    <span className="font-mono text-zinc-700 dark:text-zinc-300">{p.qty_remaining}</span>
                    {p.qty_remaining !== p.qty_available && (
                      <span className="ml-1 text-[10px] text-zinc-400">/ 原 {p.qty_available}</span>
                    )}
                  </span>
                  <span>到期 <span className="text-zinc-700 dark:text-zinc-300">{fmtDt(p.expires_at)}</span></span>
                  {p.source_order_no && (
                    <span>源訂單 <span className="font-mono text-zinc-700 dark:text-zinc-300">{p.source_order_no}</span></span>
                  )}
                  {p.note && <span className="text-zinc-700 dark:text-zinc-300">「{p.note}」</span>}
                </div>
              </SpinButton>
              {/* 每一則都要能單獨印（不論狀態）—— 板上的貨常常是靠紙本在店裡流動，
                  已認領 / 已過期的也要印得回來歸檔、對帳 */}
              <SpinButton
                type="button"
                onClick={() => printViaIframe(withBasePath(`/inventory/mutual-aid/print?id=${p.id}`))}
                title="列印這一則（A4 直式：內容 + 留言 + 認領簽收欄）"
                className="shrink-0 rounded-md border border-zinc-300 px-2 py-1.5 text-xs text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
              >
                🖨️
              </SpinButton>
            </li>
          ))}
        </ul>
      )}
      </>
      )}

      <RequestModal
        open={requestModalOpen}
        onClose={() => setRequestModalOpen(false)}
        stores={stores}
        onPosted={() => {
          setRequestModalOpen(false);
          reloadAndRefreshBadge();
        }}
      />

      <OfferModal
        open={offerModalOpen}
        onClose={() => setOfferModalOpen(false)}
        stores={stores}
        onPosted={() => {
          setOfferModalOpen(false);
          reloadAndRefreshBadge();
        }}
      />

      <ManualSpotModal
        open={manualModalOpen}
        onClose={() => setManualModalOpen(false)}
        stores={stores}
        onPosted={() => {
          setManualModalOpen(false);
          reloadAndRefreshBadge();
        }}
      />

      {threadPost && (
        <ThreadModal
          post={threadPost}
          stores={stores}
          onEdited={() => reloadAndRefreshBadge()}
          onClose={() => setThreadPost(null)}
          onClosed={() => {
            setThreadPost(null);
            reloadAndRefreshBadge();
          }}
        />
      )}
    </div>
  );
}

// ============================================================
// 提供紀錄 —— 這則貼文被哪幾家店接走 / 補上了
//
// 點開貼文只看得到留言、看不到「誰真的出了貨」（2026-08-24 回報）。
// 認領／提供的本體是訂單轉移，所以紀錄在 customer_order_transfer_links，
// 不在 mutual_aid_board 也不在留言。
//
// ⚠ 這裡用 reason 認貼文，不是用 aid_board_id：那一欄是 20260824060000 才加的，
// SQL 有沒有先套上正式庫不是前端控制得了的（#827 就發生過「PR 合併了、
// migration 沒套」）。撈不存在的欄位整段會 400。伺服端先用 `#<id>` 收窄，
// 再在前端用嚴格的 regex 濾掉 #2490 這種誤中。
// ============================================================
function AidClaimLog({ post }: { post: Post }) {
  const [rows, setRows] = useState<ProvidedRow[] | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const SEL =
          TRANSFER_LINK_SELECT + ", reason, " +
          "src:customer_orders!customer_order_transfer_links_source_order_id_fkey(" +
          "id, order_no, pickup_store_id, store:stores!customer_orders_pickup_store_id_fkey(name)), " +
          "dest:customer_orders!customer_order_transfer_links_dest_order_id_fkey(" +
          "id, order_no, status, pickup_store_id, " +
          "store:stores!customer_orders_pickup_store_id_fkey(name), " +
          "items:customer_order_items(id, qty, status, source, " +
          "sku:skus(sku_code, product_name, variant_name)))";

        // 兩條路一起撈，因為單靠 reason 只找得到新資料：
        //   (1) reason 帶貼文編號 —— 兩個對話框的預設值都是「互助板提供／認領 #N」。
        //   (2) 載體單反查 —— 手動現貨認領時 rpc_claim_manual_spot 會在載體單
        //       （AB-xx-000n）的品項 notes 蓋「[互助板認領 #N]」，而那張載體單
        //       只為這一次認領而生 → 從它轉出去的那一趟就是這次認領。
        //       線上 4 筆歷史認領（#119/#206/#207/#208）全靠這條才查得到是古華店；
        //       它們的 reason 在連結表回填時已經被換成「[回填] …」了。
        const [reasonRes, carrierRes] = await Promise.all([
          sb.from("customer_order_transfer_links").select(SEL)
            .ilike("reason", `%#${post.id}%`)
            .order("transferred_at", { ascending: true }).limit(50),
          sb.from("customer_order_items").select("order_id")
            .ilike("notes", `%互助板認領 #${post.id}%`).limit(50),
        ]);
        if (cancelled) return;

        const carrierIds = Array.from(
          new Set(((carrierRes.data ?? []) as { order_id: number }[]).map((r) => r.order_id)),
        );
        const byCarrier = carrierIds.length > 0
          ? await sb.from("customer_order_transfer_links").select(SEL)
              .in("source_order_id", carrierIds)
              .order("transferred_at", { ascending: true }).limit(50)
          : { data: [], error: null };
        if (cancelled) return;
        if (reasonRes.error && carrierRes.error) { setRows([]); return; }

        // 「互助板提供 #249」/「互助板認領 #249」；#2490 不能算進來。
        // 只用來濾 (1) —— (2) 是從載體單直接反查的，本身就精準。
        const exact = new RegExp(`互助板[^#]*#${post.id}(?!\\d)`);
        type StoreRef = { name: string } | { name: string }[] | null;
        type RawSku = { sku_code: string; product_name: string; variant_name: string | null };
        type Raw = TransferLink & {
          reason: string | null;
          src: { id: number; order_no: string; pickup_store_id: number | null; store: StoreRef } | null;
          dest: {
            id: number; order_no: string; status: string; pickup_store_id: number | null;
            store: StoreRef;
            items: { id: number; qty: number; status: string; source: string | null; sku: RawSku | RawSku[] | null }[] | null;
          } | null;
        };
        const nameOf = (s: StoreRef) => (Array.isArray(s) ? s[0]?.name : s?.name) ?? "—";
        // 一趟轉移可能兩條路都撈到（新資料的 reason 有編號、又剛好是手動現貨），
        // 以 link id 去重
        const merged = new Map<number, Raw>();
        for (const r of (reasonRes.data ?? []) as unknown as Raw[]) {
          if (exact.test(r.reason ?? "")) merged.set(r.id, r);
        }
        for (const r of (byCarrier.data ?? []) as unknown as Raw[]) merged.set(r.id, r);
        const list = [...merged.values()]
          .sort((a, b) => a.transferred_at.localeCompare(b.transferred_at))
          .flatMap((r): ProvidedRow[] => {
          const src = r.src, dest = r.dest;
          if (!src || !dest) return [];
          const mine = linkItems(r, dest.items ?? []);
          const active = mine.filter((it) => !["cancelled", "expired"].includes(it.status));
          // 這趟被取消（品項全滅）也要顯示原本搬過什麼，不能只寫「共 0」——
          // 狀態徽章會講「已取消」，內容退回全品項
          const shown = active.length > 0 ? active : mine;
          return [{
            linkId: r.id,
            transferred_at: r.transferred_at,
            is_air_transfer: r.is_air_transfer === true,
            board_id: post.id,
            reason: r.reason,
            source_store: nameOf(src.store),
            source_store_id: src.pickup_store_id,
            source_order_no: src.order_no,
            dest_store: nameOf(dest.store),
            dest_store_id: dest.pickup_store_id,
            dest_order_id: dest.id,
            dest_order_no: dest.order_no,
            dest_status: dest.status,
            qty: activeQty(mine),
            labels: shown.map((it) => {
              const sku = Array.isArray(it.sku) ? it.sku[0] : it.sku;
              return sku
                ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} ×${Number(it.qty)}`
                : `品項 ×${Number(it.qty)}`;
            }),
            link_count: 1,
            // 認領／提供必然跨店（同店的貼文自己就能收），不會是同店互轉
            same_store: false,
            from_party: null,
            to_party: null,
            origin: "aid",
          }];
        });
        setRows(list);
      } catch {
        if (!cancelled) setRows([]);
      }
    })();
    return () => { cancelled = true; };
  }, [post.id]);

  // 需求貼文＝別人「提供」給貼文店；釋出貼文＝別人「認領」走
  const verb = post.post_type === "request" ? "提供" : "認領";

  if (rows === null) {
    return <div className="text-xs text-zinc-500">載入{verb}紀錄…</div>;
  }

  // 貼文自己記的已成交量 vs 查得到明細的量。
  // 兩者對不起來只有一個原因：那些轉移發生在 customer_order_transfer_links
  // （20260824000100）之前，回填時原始 reason 已經遺失、認不出屬於哪一則貼文。
  // 這種時候要明講「有人接走但查不到是誰」—— 直接不顯示會被當成沒人認領。
  const settled = Number(post.qty_available) - Number(post.qty_remaining);
  const logged = rows.reduce((s, r) => s + r.qty, 0);
  const untraced = Math.max(0, settled - logged);

  return (
    <div className="rounded-md border border-zinc-200 bg-zinc-50 p-2 dark:border-zinc-800 dark:bg-zinc-950">
      <div className="mb-1.5 flex items-center gap-2 text-[11px] font-semibold text-zinc-600 dark:text-zinc-400">
        <span>{verb}紀錄</span>
        {rows.length > 0 && <span className="font-normal text-zinc-500">{rows.length} 筆</span>}
      </div>

      {rows.length === 0 && untraced === 0 && (
        <div className="text-xs text-zinc-500">
          尚無人{verb}。{post.post_type === "request" ? "別家店按「🤝 我可以提供」後會出現在這裡。" : "別家店按「✋ 我要認領」後會出現在這裡。"}
        </div>
      )}

      {untraced > 0 && (
        <div className="rounded border border-amber-200 bg-amber-50 p-2 text-[11px] text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300">
          另有 {untraced} 件已被{verb}，但這批轉移早於系統開始記錄明細，查不到是哪一家店。
        </div>
      )}

      <div className="flex flex-col gap-1.5">
        {rows.map((r) => (
          <div
            key={r.linkId}
            className="rounded border border-zinc-200 bg-white p-2 text-xs dark:border-zinc-800 dark:bg-zinc-900"
          >
            <div className="mb-1 flex flex-wrap items-center gap-1.5">
              <span className="rounded bg-pink-100 px-1.5 py-0.5 text-[10px] font-semibold text-pink-800 dark:bg-pink-950 dark:text-pink-300">
                {post.post_type === "request" ? r.source_store : r.dest_store}
              </span>
              <span className="text-[10px] text-zinc-500">{aidRouteLabel(r.is_air_transfer)}</span>
              <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px] text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
                {aidStageLabel(r.dest_status, r.is_air_transfer)}
              </span>
              <span className="ml-auto text-[10px] text-zinc-500">{fmtDt(r.transferred_at)}</span>
            </div>
            <div className="text-zinc-700 dark:text-zinc-300">{r.labels.join("、") || `共 ${r.qty}`}</div>
            <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[10px] text-zinc-500">
              <span>
                {post.post_type === "request" ? "送到" : "送給"}{" "}
                <span className="text-zinc-700 dark:text-zinc-300">{r.dest_store}</span>
              </span>
              <span>
                單號 <span className="font-mono text-zinc-700 dark:text-zinc-300">{shortOrderNo(r.dest_order_no)}</span>
              </span>
              <SpinButton
                type="button"
                onClick={() =>
                  printViaIframe(
                    withBasePath(`/transfers/print-aid?order_id=${r.dest_order_id}&link=${r.linkId}`),
                  )
                }
                title="列印這一趟的互助出貨單（兩聯：司機聯 + 存查聯）"
                className="ml-auto rounded border border-zinc-300 px-1.5 py-0.5 text-[10px] text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
              >
                🖨️ 隨貨單
              </SpinButton>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ============================================================
// 我轉出／我接收 —— 本店的訂單轉移總覽，一趟轉移一列
//
// 為什麼不是查訂單而是查 customer_order_transfer_links：
// 轉入單掛在**收貨店**名下，轉出店的訂單列表一列都撈不到；而且一張轉入單可以
// 有多個來源（追加轉入把好幾家店的貨併進同一張，線上 TF0486 有 3 家店的 5 個
// 品項），拿訂單當單位就會把別家店的貨也算成自己的。連結表才是 1:1 的「一趟」。
// 2026-08-24 起互助轉單一律開新單（20260824060000），但舊資料還是併在一起的，
// 所以這裡一律用 linkItems() 只取這一趟真正搬過去的品項。
//
// 母體＝**所有**訂單轉移（老闆 2026-08-25 指示：訂單頁轉單與互助認領都整合到
// 這裡呈現）。跨店列分「還在路上／對方已收」；同店互轉（換客人，貨沒離開店）
// 自成一籤，不混進配送語意的分組。分店帳號鎖自己店；總倉／未綁店看全站。
// ============================================================
/** 轉移列右側的標籤。三種語意各一個顏色，掃一眼就分得出來：
 *  路徑（貨怎麼走）／狀態（走到哪）／來源（為什麼會有這一趟）。 */
const CHIP_TONE = {
  sky:     "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300",
  amber:   "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  violet:  "bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-300",
  emerald: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  rose:    "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
  blue:    "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  teal:    "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300",
  zinc:    "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  faint:   "border border-dashed border-zinc-300 text-zinc-400 dark:border-zinc-700",
} as const;

function Chip({ tone, title, children }: {
  tone: keyof typeof CHIP_TONE; title?: string; children: React.ReactNode;
}) {
  return (
    <span
      title={title}
      className={`shrink-0 whitespace-nowrap rounded px-1.5 py-0.5 text-[11px] font-medium ${CHIP_TONE[tone]}`}
    >
      {children}
    </span>
  );
}

/** 狀態標籤的顏色：完成類綠、取消類紅、在途類琥珀。 */
function stageTone(status: string): keyof typeof CHIP_TONE {
  if (["cancelled", "expired"].includes(status)) return "rose";
  if (["ready", "completed", "partially_completed"].includes(status)) return "emerald";
  return "amber";
}

/** 來源標籤：這一趟是怎麼發生的。 */
function originChip(origin: ProvidedRow["origin"], boardId: number | null) {
  if (origin === "aid") {
    return <Chip tone="blue" title="由互助交流板的貼文認領而來">互助板 #{boardId}</Chip>;
  }
  if (origin === "order") {
    return <Chip tone="teal" title="由訂單頁的「轉給別人」直接轉移">訂單轉單</Chip>;
  }
  return (
    <Chip tone="faint" title="2026-08-24 轉移連結表上線前的舊資料，當時未記錄來源，無法判定">
      來源未記錄
    </Chip>
  );
}

function ProvidedList({ stores, direction }: {
  stores: Store[];
  // out=本店轉出、in=轉入本店、same=同店變更取貨人（轉出店＝接收店，自成一頁）
  direction: "out" | "in" | "same";
}) {
  const myStoreId = useUserBranchStoreId(stores);
  const [rows, setRows] = useState<ProvidedRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  // 只有跨店才分階段：transit=運送中（預設）、done=已簽收。同店沒有配送階段。
  const [bucket, setBucket] = useState<"transit" | "done">("transit");
  const [busyLink, setBusyLink] = useState<number | null>(null);
  const [reloadTick, setReloadTick] = useState(0);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("customer_order_transfer_links")
          // aid_board_id 是 20260824060000 加的欄位，該 migration 已套上正式庫
          // （2026-08-25 實測欄位存在）才改成一起撈 —— 它是「這趟是不是互助」
          // 唯一可靠的依據；reason 只是後備（RPC 預設寫「互助板提供／認領 #N」）。
          .select(
            TRANSFER_LINK_SELECT + ", reason, aid_board_id, " +
              "src:customer_orders!customer_order_transfer_links_source_order_id_fkey(" +
              "id, order_no, pickup_store_id, nickname_snapshot, member:members(name), " +
              "store:stores!customer_orders_pickup_store_id_fkey(name)), " +
              "dest:customer_orders!customer_order_transfer_links_dest_order_id_fkey(" +
              "id, order_no, status, pickup_store_id, nickname_snapshot, member:members(name), " +
              "store:stores!customer_orders_pickup_store_id_fkey(name), " +
              "items:customer_order_items(id, qty, status, source, " +
              "sku:skus(sku_code, product_name, variant_name)))",
          )
          .order("transferred_at", { ascending: false })
          .limit(300);
        if (cancelled) return;
        if (e) throw new Error(e.message);
        type StoreRef = { name: string } | { name: string }[] | null;
        type RawSku = { sku_code: string; product_name: string; variant_name: string | null };
        type RawOrder = {
          id: number; order_no: string; pickup_store_id: number | null;
          nickname_snapshot: string | null; member: StoreRef; store: StoreRef;
        };
        type Raw = TransferLink & {
          reason: string | null;
          aid_board_id: number | null;
          src: RawOrder | null;
          dest: (RawOrder & {
            status: string;
            items: { id: number; qty: number; status: string; source: string | null; sku: RawSku | RawSku[] | null }[] | null;
          }) | null;
        };
        const nameOf = (s: StoreRef) => (Array.isArray(s) ? s[0]?.name : s?.name) ?? "—";
        // 同店互轉的「對面那位客人」：訂單暱稱優先、退會員名（內部單＝【內部】xx店）
        const nickOf = (o: RawOrder) =>
          o.nickname_snapshot?.trim() ||
          ((Array.isArray(o.member) ? o.member[0]?.name : o.member?.name) ?? null);
        const raws = (data ?? []) as unknown as Raw[];
        // 同一張轉入單有幾趟：舊的併入單（多店混一張）取消整張會殃及別家店的貨，
        // 要在列上把取消鈕關掉。要在「店別過濾之前」算 —— 別家店那幾趟不在
        // 過濾後的清單裡，但它們的貨還是掛在同一張單上。
        const linkCountByDest = new Map<number, number>();
        for (const r of raws) {
          if (r.dest) linkCountByDest.set(r.dest.id, (linkCountByDest.get(r.dest.id) ?? 0) + 1);
        }
        const list = raws.flatMap((r): ProvidedRow[] => {
          const src = r.src, dest = r.dest;
          if (!src || !dest) return [];
          const sameStore = src.pickup_store_id === dest.pickup_store_id;
          // 同店變更取貨人的轉出店＝接收店，掛在「我轉出／我接收」底下會變成
          // 同一筆出現兩次（2026-08-25 回報）→ 獨立成一個分頁，轉出與接收合看，
          // 列上直接寫清楚「原客人 → 新客人」。
          if (direction === "same" ? !sameStore : sameStore) return [];
          // 分店帳號：out 看自己轉出去的、in 看轉進本店的、same 就是本店；HQ 看全站
          if (myStoreId != null) {
            const mineStore = direction === "in" ? dest.pickup_store_id : src.pickup_store_id;
            if (mineStore !== myStoreId) return [];
          }
          const mine = linkItems(r, dest.items ?? []);
          const active = mine.filter((it) => !["cancelled", "expired"].includes(it.status));
          const qty = activeQty(mine);
          // 這趟被取消（品項全滅）也要留在列表上 —— 不然取消完那一列就人間蒸發，
          // 兩邊都以為沒發生過；顯示退回全品項並讓狀態徽章講「已取消」
          const shown = active.length > 0 ? active : mine;
          return [{
            linkId: r.id,
            transferred_at: r.transferred_at,
            is_air_transfer: r.is_air_transfer === true,
            board_id: r.aid_board_id ?? (Number(/互助板[^#]*#(\d+)/.exec(r.reason ?? "")?.[1]) || null),
            // 判來源：有貼文編號＝互助；reason 空＝轉單 RPC 當下寫的（互助對話框
            // 一定會預填「互助板認領 #N」，所以空的只可能是訂單頁轉單）；
            // 「[回填]」是連結表上線前補建的舊資料，原始 reason 已遺失 → 不猜。
            origin: (r.aid_board_id ?? (Number(/互助板[^#]*#(\d+)/.exec(r.reason ?? "")?.[1]) || null)) != null
              ? "aid"
              : r.reason == null ? "order" : "unknown",
            reason: r.reason,
            source_store: nameOf(src.store),
            source_store_id: src.pickup_store_id,
            source_order_no: src.order_no,
            dest_store: nameOf(dest.store),
            dest_store_id: dest.pickup_store_id,
            dest_order_id: dest.id,
            dest_order_no: dest.order_no,
            dest_status: dest.status,
            qty,
            labels: shown.map((it) => {
              const sku = Array.isArray(it.sku) ? it.sku[0] : it.sku;
              return sku
                ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} ×${Number(it.qty)}`
                : `品項 ×${Number(it.qty)}`;
            }),
            link_count: linkCountByDest.get(dest.id) ?? 1,
            same_store: sameStore,
            from_party: sameStore ? nickOf(src) : null,
            to_party: sameStore ? nickOf(dest) : null,
          }];
        });
        setRows(list);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    })();
    return () => { cancelled = true; };
  }, [myStoreId, direction, reloadTick]);

  // 取消這一趟：未到貨（pending/confirmed/shipping）走 rpc_cancel_aid_order，
  // 已到貨（ready）由收貨方走 rpc_return_aid_order 退回原店。
  // 兩支 RPC 取消後都會把數量還給互助板貼文（20260824080000）。
  async function cancelLeg(r: ProvidedRow, kind: "cancel" | "return") {
    if (busyLink != null) return;
    const items = r.labels.join("、") || `共 ${r.qty}`;
    const what = kind === "cancel"
      ? `取消本次轉出（${items}）？\n商品將退回來源訂單，互助板貼文的數量也會一併還原。`
      : direction === "in"
        // 收貨方退回：貨在自己架上，按下去就是把它送回去
        ? `將本批商品退回 ${r.source_store}？\n系統將建立反向調撥單，來源訂單與貼文數量一併還原。`
        // 轉出方要求退回：貨在對方店裡，按下去會從**對方**店出庫、送回本店。
        // 對方沒有按鈕可擋，所以話要講白（老闆 2026-08-25：兩邊都要能退回）。
        : `要求 ${r.dest_store} 將本批商品退回本店（${items}）？\n` +
          `系統將立即建立反向調撥單，自 ${r.dest_store} 出庫送回本店，來源訂單與貼文數量一併還原。\n` +
          `商品目前仍在對方店內，請先與對方確認後再執行。`;
    if (!confirm(what)) return;
    setBusyLink(r.linkId);
    try {
      const sb = getSupabase();
      const { data: { user } } = await sb.auth.getUser();
      if (!user?.id) { alert("尚未登入"); return; }
      const { error: e } = await sb.rpc(
        kind === "cancel" ? "rpc_cancel_aid_order" : "rpc_return_aid_order",
        { p_order_id: r.dest_order_id, p_reason: `互助板${direction === "out" ? "提供方" : "收貨方"}${kind === "cancel" ? "取消" : "退回"}`, p_operator: user.id },
      );
      if (e) { alert(translateRpcError(e)); return; }
      setReloadTick((n) => n + 1);
      window.dispatchEvent(new Event("aid-badge-refresh"));
    } finally {
      setBusyLink(null);
    }
  }

  if (error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {error}
      </div>
    );
  }
  if (rows === null) return <div className="text-sm text-zinc-500">載入中…</div>;

  const inFlight = rows.filter((r) => isAidInFlight(r.dest_status));
  const done = rows.filter((r) => !isAidInFlight(r.dest_status));
  // 同店沒有配送階段（商品未離開本店）→ 不分籤，整份一起看
  const shown = direction === "same" ? rows : bucket === "done" ? done : inFlight;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        {direction !== "same" && (
          <div className="inline-flex w-fit overflow-hidden rounded-md border border-zinc-300 text-xs dark:border-zinc-700">
            {(["transit", "done"] as const).map((v) => (
              <SpinButton
                key={v}
                type="button"
                onClick={() => setBucket(v)}
                className={`px-3 py-1.5 ${
                  bucket === v
                    ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                    : "bg-white text-zinc-600 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
                }`}
              >
                {/* ⚠ 不要叫「已完成」：done 那格說的是**這一筆轉移**送達了，
                    不是來源單完成了。來源單（OV-/AB-/RR- 現貨池）通常還掛著
                    一堆沒動過的品項，2026-08-24 就被誤讀成「OV-2-0001 變已完成」。 */}
                {v === "transit"
                  ? `運送中 (${inFlight.length})`
                  : `${direction === "out" ? "對方已簽收" : "已簽收"} (${done.length})`}
              </SpinButton>
            ))}
          </div>
        )}
        <span className="text-xs text-zinc-500">
          {direction === "same"
            ? "商品未離開本店，僅將訂單改掛至另一位客人；如需還原請至轉入單再次轉移"
            : myStoreId == null
              ? `全站店對店${direction === "out" ? "轉出" : "轉入"}（總倉視角），含互助認領與訂單轉單`
              : direction === "out"
                ? "本店轉出的商品（互助認領＋訂單轉單）。未送達可「取消提供」，已送達可「要求退回」"
                : "其他分店轉入本店的商品（互助認領＋訂單轉單）。未送達可「取消轉入」，已送達可「退回原店」"}
        </span>
      </div>

      {shown.length === 0 ? (
        <div className="rounded-md border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500 dark:border-zinc-700">
          {direction === "same"
            ? "本店沒有同店變更取貨人的紀錄"
            : bucket === "done"
              ? `無${direction === "out" ? "對方已簽收的轉出" : "已簽收的轉入"}紀錄`
              : `目前無運送中的${direction === "out" ? "轉出" : "轉入"}`}
        </div>
      ) : (
        <ul className="space-y-2">
          {shown.map((r) => (
            <li
              key={r.linkId}
              className="flex items-start gap-2 rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900"
            >
              {/* 左：這一趟是誰給誰、什麼東西、對應哪兩張單 */}
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline gap-2">
                  <span className="truncate text-sm font-semibold text-zinc-900 dark:text-zinc-50">
                    {myStoreId == null
                      ? (r.same_store
                          ? `${r.source_store}：${r.from_party ?? "原客人"} → ${r.to_party ?? "新客人"}`
                          : `${r.source_store} → ${r.dest_store}`)
                      : r.same_store
                        ? `${r.from_party ?? "原客人"} → ${r.to_party ?? "新客人"}`
                        : `${direction === "out" ? "轉予" : "來自"} ${direction === "out" ? r.dest_store : r.source_store}`}
                  </span>
                  <span className="shrink-0 text-xs text-zinc-400">{fmtDt(r.transferred_at)}</span>
                </div>
                <div className="mt-1 text-sm text-zinc-800 dark:text-zinc-100">
                  {r.labels.join("、") || `共 ${r.qty}`}
                </div>
                <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-zinc-500">
                  <span>
                    來源單 <span className="font-mono text-zinc-700 dark:text-zinc-300">{r.source_order_no}</span>
                  </span>
                  <span aria-hidden className="text-zinc-300 dark:text-zinc-600">→</span>
                  {/* 轉入單掛在收貨店名下 —— 連結一定要帶 storeId，否則分店帳號的
                      門市篩選會預設帶回自己店、搜出 0 筆（看起來像貨憑空消失） */}
                  <Link
                    className="font-mono text-blue-600 underline dark:text-blue-400"
                    href={`/orders?q=${encodeURIComponent(r.dest_order_no)}${r.dest_store_id != null ? `&storeId=${r.dest_store_id}` : ""}`}
                  >
                    {shortOrderNo(r.dest_order_no)}
                  </Link>
                  {r.reason && !r.reason.startsWith("[回填]") && (
                    <span className="text-zinc-700 dark:text-zinc-300">「{r.reason}」</span>
                  )}
                </div>
              </div>

              {/* 中：標籤靠右橫排 —— 路徑／狀態／來源，三種語意三個顏色 */}
              <div className="flex shrink-0 flex-wrap items-center justify-end gap-1.5 sm:w-[15rem]">
                {r.same_store ? (
                  <Chip tone="violet" title="商品未離開本店，只是把訂單改掛給另一位客人">
                    🔁 同店變更取貨人
                  </Chip>
                ) : (
                  <Chip tone={r.is_air_transfer ? "sky" : "amber"}
                        title={r.is_air_transfer ? "店對店直送，不經總倉" : "先送到總倉，再由總倉派送到收貨店"}>
                    {aidRouteLabel(r.is_air_transfer)}
                  </Chip>
                )}
                {r.same_store ? (
                  <Chip tone={stageTone(r.dest_status)} title="轉入單目前的狀態（同店變更取貨人無配送階段）">
                    {orderStatusLabel(r.dest_status)}
                  </Chip>
                ) : (
                  <Chip tone={stageTone(r.dest_status)} title="本次轉移的進度（非來源訂單的狀態）">
                    {aidStageLabel(r.dest_status, r.is_air_transfer)}
                  </Chip>
                )}
                {originChip(r.origin, r.board_id)}
              </div>

              {/* 同店互轉：沒有隨貨單（貨沒出門）、也不走互助的取消／退回 RPC
                  （要反悔就到轉入單用「轉給別人」轉回來）→ 整欄不出 */}
              {!r.same_store && (
              <div className="flex shrink-0 flex-col items-stretch gap-1.5">
                {/* 隨貨單走 /transfers/print-aid（兩聯：司機聯 + 存查聯），
                    帶 link 才只印這一趟的貨、來源店也才標得對 */}
                <SpinButton
                  type="button"
                  onClick={() =>
                    printViaIframe(
                      withBasePath(`/transfers/print-aid?order_id=${r.dest_order_id}&link=${r.linkId}`),
                    )
                  }
                  title="列印這一趟的互助出貨單（兩聯：司機聯 + 存查聯）"
                  className="rounded-md border border-zinc-300 px-2 py-1.5 text-xs text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                >
                  🖨️
                </SpinButton>
                {/* 取消規則：分界線是「貨到收貨店了沒」。
                    未到（pending/confirmed/shipping）→ 兩邊都能取消（rpc_cancel_aid_order）；
                    已到（ready）→ 只有收貨方能退回原店（rpc_return_aid_order，貨在他們架上）；
                    completed/cancelled → 沒有動作。
                    舊的併入單（link_count > 1）整張取消會殃及別家店的貨 → 導去訂單頁。 */}
                {isAidInFlight(r.dest_status) && (
                  r.link_count === 1 ? (
                    <SpinButton
                      type="button"
                      disabled={busyLink != null}
                      onClick={() => cancelLeg(r, "cancel")}
                      className="rounded-md border border-red-300 px-2 py-1.5 text-xs text-red-700 hover:bg-red-50 disabled:opacity-50 dark:border-red-900 dark:text-red-400 dark:hover:bg-red-950"
                    >
                      {busyLink === r.linkId ? "處理中…" : direction === "out" ? "取消提供" : "取消轉入"}
                    </SpinButton>
                  ) : (
                    <span
                      className="rounded-md border border-dashed border-zinc-300 px-2 py-1.5 text-center text-[10px] text-zinc-400 dark:border-zinc-700"
                      title="此轉入單併有其他分店的商品（舊資料），整張取消會一併取消他店商品；請至轉入單的訂單頁個別處理"
                    >
                      多筆併單
                    </span>
                  )
                )}
                {/* 已到貨（ready）→ 兩邊都能退回（老闆 2026-08-25）。
                    收貨方＝貨在自己架上，直接送回；轉出方＝要求對方退回，
                    同一支 rpc_return_aid_order（它沒有「限收貨店」的守衛），
                    會從對方店出庫、建反向調撥。文案在 cancelLeg 裡分開講。 */}
                {r.dest_status === "ready" && (
                  r.link_count === 1 ? (
                    <SpinButton
                      type="button"
                      disabled={busyLink != null}
                      onClick={() => cancelLeg(r, "return")}
                      title={
                        direction === "in"
                          ? "把這批貨送回原店（建反向調撥、來源單還原、貼文數量還回去）"
                          : "貨已經在對方店裡：按下去會從對方店出庫、送回本店。請先跟對方講一聲"
                      }
                      className="rounded-md border border-red-300 px-2 py-1.5 text-xs text-red-700 hover:bg-red-50 disabled:opacity-50 dark:border-red-900 dark:text-red-400 dark:hover:bg-red-950"
                    >
                      {busyLink === r.linkId ? "處理中…" : direction === "in" ? "退回原店" : "要求退回"}
                    </SpinButton>
                  ) : (
                    <span
                      className="rounded-md border border-dashed border-zinc-300 px-2 py-1.5 text-center text-[10px] text-zinc-400 dark:border-zinc-700"
                      title="此轉入單併有其他分店的商品（舊資料），整張退回會一併退回他店商品；請至轉入單的訂單頁個別處理"
                    >
                      多筆併單
                    </span>
                  )
                )}
              </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ============================================================
// Common: SKU search input
// ============================================================
function SkuSearchInput({
  value, onChange,
}: {
  value: SkuOption | null;
  onChange: (s: SkuOption | null) => void;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SkuOption[]>([]);
  const [open, setOpen] = useState(false);
  const [searching, setSearching] = useState(false);

  useEffect(() => {
    setSearching(true);
    const t = setTimeout(async () => {
      try {
        let q = getSupabase()
          .from("skus").select("id, sku_code, product_name, variant_name")
          .eq("status", "active")
          .order("updated_at", { ascending: false })
          .limit(20);
        const s = query.trim();
        if (s) {
          const safe = s.replace(/[%,()]/g, " ").trim();
          q = q.or(`sku_code.ilike.%${safe}%,product_name.ilike.%${safe}%,variant_name.ilike.%${safe}%`);
        }
        const { data } = await q;
        setResults((data as SkuOption[]) ?? []);
      } finally {
        setSearching(false);
      }
    }, query ? 250 : 0);
    return () => clearTimeout(t);
  }, [query]);

  return (
    <div className="relative">
      <input
        value={value ? `${value.product_name}${value.variant_name ? ` / ${value.variant_name}` : ""} (${value.sku_code})` : query}
        onFocus={() => setOpen(true)}
        onChange={(e) => {
          if (value) onChange(null);
          setQuery(e.target.value);
          setOpen(true);
        }}
        placeholder="搜尋商品 / 品項"
        className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 pr-7 dark:border-zinc-700 dark:bg-zinc-800"
      />
      <SearchSpinner active={searching} className="right-1" />
      {open && results.length > 0 && !value && (
        <div
          className="absolute left-0 right-0 top-full z-20 mt-1 max-h-60 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800"
          onMouseLeave={() => setOpen(false)}
        >
          {results.map((s) => (
            <SpinButton
              key={s.id}
              type="button"
              onClick={() => { onChange(s); setOpen(false); }}
              className="block w-full px-2 py-1.5 text-left text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
            >
              <span className="font-medium">{s.product_name}</span>
              {s.variant_name && <span className="ml-1 text-zinc-500">/ {s.variant_name}</span>}
              <span className="ml-2 font-mono text-zinc-400">{s.sku_code}</span>
            </SpinButton>
          ))}
        </div>
      )}
    </div>
  );
}

/** ISO timestamp → <input type="datetime-local"> 需要的本地時間字串 */
function toLocalInput(iso: string): string {
  const d = new Date(iso);
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}

function defaultExpiresAt() {
  const d = new Date(Date.now() + 7 * 86400_000);
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}

// ============================================================
// Request Modal — 我要求助
// ============================================================
function RequestModal({
  open, onClose, stores, onPosted,
}: {
  open: boolean;
  onClose: () => void;
  stores: Store[];
  onPosted: () => void;
}) {
  const [storeId, setStoreId] = useState<number | "">("");
  const [picked, setPicked] = useState<SkuOption | null>(null);
  const [qty, setQty] = useState("");
  const [expiresAt, setExpiresAt] = useState(defaultExpiresAt);
  const [note, setNote] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setStoreId(""); setPicked(null); setQty(""); setNote(""); setErr(null);
      setExpiresAt(defaultExpiresAt());
    }
  }, [open]);

  async function submit() {
    if (submitting) return;
    setErr(null);
    if (!storeId) { setErr("請選求助店"); return; }
    if (!picked) { setErr("請選品項"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("數量需 > 0"); return; }
    const expDate = new Date(expiresAt);
    if (expDate <= new Date()) { setErr("到期時間需在未來"); return; }

    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_post_aid_board", {
        p_offering_store_id: storeId,
        p_sku_id: picked.id,
        p_qty_available: qtyN,
        p_expires_at: expDate.toISOString(),
        p_note: note.trim() || null,
        p_operator: operator,
        p_post_type: "request",
        p_source_customer_order_id: null,
      });
      if (e) { setErr(e.message); return; }
      onPosted();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="📢 我要求助" maxWidth="max-w-lg">
      <div className="flex flex-col gap-3 text-sm">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}
        <label>
          <span className="mb-1 block text-xs text-zinc-500">求助店 <span className="text-red-500">*</span></span>
          <select
            value={storeId}
            onChange={(e) => setStoreId(e.target.value ? Number(e.target.value) : "")}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選店 —</option>
            {stores.map((s) => (<option key={s.id} value={s.id}>{s.name} ({s.code})</option>))}
          </select>
        </label>
        <div>
          <span className="mb-1 block text-xs text-zinc-500">需要的品項 <span className="text-red-500">*</span></span>
          <SkuSearchInput value={picked} onChange={setPicked} />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <label>
            <span className="mb-1 block text-xs text-zinc-500">需要數量 <span className="text-red-500">*</span></span>
            <input
              value={qty}
              onChange={(e) => setQty(e.target.value)}
              inputMode="decimal"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">到期時間 <span className="text-red-500">*</span></span>
            <input
              type="datetime-local"
              value={expiresAt}
              onChange={(e) => setExpiresAt(e.target.value)}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
        </div>
        <label>
          <span className="mb-1 block text-xs text-zinc-500">備註（選填）</span>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="例：客人要、想多進"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="mt-2 flex justify-end gap-2">
          <SpinButton type="button" onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</SpinButton>
          <SpinButton
            type="button"
            onClick={submit}
            disabled={submitting}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {submitting ? "送出中…" : "發佈求助"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

/**
 * 「其他分店的會員也看得到」開關。上架表單與 ThreadModal 編輯區共用。
 *
 * 開（預設）= 維持既有行為：別店會員在現貨專區看得到這張卡，但金額隱藏。
 * 關         = 別店會員的列表與詳情都查不到（過濾在 liff-api，不是前端藏）。
 */
function VisibilityToggle({
  checked, onChange, storeName,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  storeName: string | null;
}) {
  return (
    <label className="flex cursor-pointer items-start gap-2 rounded-md border border-zinc-200 p-2 dark:border-zinc-800">
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 shrink-0 accent-emerald-600"
      />
      <span className="text-xs">
        <span className="font-medium text-zinc-700 dark:text-zinc-300">其他分店的會員也看得到</span>
        <span className="mt-0.5 block text-zinc-500">
          {checked
            ? "所有會員都看得到這項商品；跨店的金額照舊隱藏（顯示鎖頭）。"
            : `只有${storeName ? `「${storeName}」` : "釋出店"}的會員看得到，其他分店的會員完全查不到這一筆。`}
        </span>
      </span>
    </label>
  );
}

// ============================================================
// Manual Spot Modal — 手動新增現貨（不需要來源訂單）
//
// 和 OfferModal 的差別：那支是「把客人棄單的訂單釋出去」，一切資料都從訂單帶；
// 這支是店家直接把店裡有的東西上架 —— 可以從商品庫挑 SKU 帶出名字，
// 也可以整個手打（店裡自製、臨時進的貨，主檔根本沒有）。
// 這種貼文**不會出現認領按鈕**：沒有訂單可以轉移給別店。
// ============================================================
function ManualSpotModal({
  open, onClose, stores, onPosted,
}: {
  open: boolean;
  onClose: () => void;
  stores: Store[];
  onPosted: () => void;
}) {
  const [storeId, setStoreId] = useState<number | "">("");
  const [picked, setPicked] = useState<SkuOption | null>(null);
  const [title, setTitle] = useState("");
  const [qty, setQty] = useState("");
  const [unit, setUnit] = useState("");
  const [price, setPrice] = useState("");
  const [expiresAt, setExpiresAt] = useState(defaultExpiresAt);
  const [desc, setDesc] = useState("");
  const [images, setImages] = useState<string[]>([]);
  const [note, setNote] = useState("");
  // 預設「其他分店的會員也看得到」（維持既有行為：跨店看得到卡片、金額隱藏）
  const [visibleToOthers, setVisibleToOthers] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setStoreId(""); setPicked(null); setTitle(""); setQty(""); setUnit("");
      setPrice(""); setDesc(""); setImages([]); setNote(""); setErr(null);
      setVisibleToOthers(true);
      setExpiresAt(defaultExpiresAt());
    }
  }, [open]);

  // 挑了 SKU → 帶出標題當起點（和會員端 spotProductTitle() 同一套組法）；
  // 已經手打過的標題不覆蓋，清掉選擇也不清標題（打過的字不該憑空消失）。
  function pickSku(s: SkuOption | null) {
    setPicked(s);
    if (!s) return;
    const def = `${s.product_name}${s.variant_name ? `／${s.variant_name}` : ""}`;
    setTitle((cur) => (cur.trim() === "" ? def : cur));
  }

  async function submit() {
    if (submitting) return;
    setErr(null);
    if (!storeId) { setErr("請選釋出店"); return; }
    const titleTrim = title.trim();
    // 商品必選：別店認領＝把這個 SKU 轉單過去，沒 SKU 就沒東西可以轉
    // （20260816000000；主檔沒有的商品請先去「商品」頁建一筆）
    if (!picked) { setErr("請從商品庫選商品 —— 沒選商品的話別的分店無法認領"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("數量需 > 0"); return; }
    let priceN: number | null = null;
    if (price.trim() !== "") {
      priceN = Number(price);
      if (!Number.isFinite(priceN) || priceN <= 0) { setErr("金額需 > 0（留空 = 不顯示金額）"); return; }
    }
    const expDate = new Date(expiresAt);
    if (Number.isNaN(expDate.getTime())) { setErr("到期時間格式不正確"); return; }
    if (expDate <= new Date()) { setErr("到期時間需在未來"); return; }

    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_post_manual_spot", {
        p_offering_store_id: storeId,
        p_sku_id: picked?.id ?? null,
        p_spot_title: titleTrim || null,
        p_qty_available: qtyN,
        p_expires_at: expDate.toISOString(),
        p_spot_price: priceN,
        p_spot_description: desc.trim() || null,
        p_spot_unit: unit.trim() || null,
        p_spot_images: images.length > 0 ? images : null,
        p_note: note.trim() || null,
        p_operator: operator,
        p_visible_to_other_stores: visibleToOthers,
      });
      if (e) { setErr(e.message); return; }
      onPosted();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="➕ 手動新增現貨" maxWidth="max-w-2xl">
      <div className="flex flex-col gap-3 text-sm">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}
        <p className="rounded-md border border-emerald-200 bg-emerald-50/50 p-2 text-xs text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950/30 dark:text-emerald-300">
          直接上架店裡現有的東西，不需要來源訂單。名稱 / 說明 / 圖片都可以自己改寫。
          <br />
          <strong>商品要從商品庫選</strong>：別店認領＝把這個商品轉單過去，沒選就沒東西可以轉
          （主檔還沒有的商品，請先到「商品」頁建一筆）。
        </p>

        <label>
          <span className="mb-1 block text-xs text-zinc-500">釋出店 <span className="text-red-500">*</span></span>
          <select
            value={storeId}
            onChange={(e) => setStoreId(e.target.value ? Number(e.target.value) : "")}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選店 —</option>
            {stores.map((s) => (<option key={s.id} value={s.id}>{s.name} ({s.code})</option>))}
          </select>
        </label>

        <div>
          <span className="mb-1 block text-xs text-zinc-500">
            從商品庫選商品 <span className="text-red-500">*</span>
            <span className="ml-1 text-zinc-400">（帶出名稱與圖片；別店要認領一定要有它）</span>
          </span>
          <SkuSearchInput value={picked} onChange={pickSku} />
          {picked && (
            <SpinButton
              type="button"
              onClick={() => setPicked(null)}
              className="mt-1 text-[11px] text-zinc-500 underline hover:text-zinc-700 dark:hover:text-zinc-300"
            >
              清除選擇，重新搜尋
            </SpinButton>
          )}
        </div>

        <label>
          <span className="mb-1 block text-xs text-zinc-500">
            商品標題{!picked && <span className="text-red-500"> *</span>}
            <span className="ml-1 text-zinc-400">（會員 App 現貨專區顯示的名稱）</span>
          </span>
          <input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder={picked ? "留空 = 沿用商品名稱" : "例：今日現滷拼盤"}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="grid grid-cols-4 gap-3">
          <label>
            <span className="mb-1 block text-xs text-zinc-500">數量 <span className="text-red-500">*</span></span>
            <input
              value={qty}
              onChange={(e) => setQty(e.target.value)}
              inputMode="decimal"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">單位</span>
            <input
              value={unit}
              onChange={(e) => setUnit(e.target.value)}
              placeholder={picked ? "留空 = 商品單位" : "包 / 份"}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">金額</span>
            <input
              value={price}
              onChange={(e) => setPrice(e.target.value)}
              inputMode="decimal"
              placeholder="留空 = 不顯示"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">到期時間 <span className="text-red-500">*</span></span>
            <input
              type="datetime-local"
              value={expiresAt}
              onChange={(e) => setExpiresAt(e.target.value)}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
        </div>

        <label>
          <span className="mb-1 block text-xs text-zinc-500">商品說明（會顯示在會員 App 的商品詳情）</span>
          <textarea
            value={desc}
            onChange={(e) => setDesc(e.target.value)}
            rows={4}
            placeholder="這批貨的狀況、口味、注意事項…"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div>
          <span className="mb-1 block text-xs text-zinc-500">
            商品圖片{picked && <span className="ml-1 text-zinc-400">（留空 = 沿用商品主檔的圖）</span>}
          </span>
          <ProductImagesField value={images} onChange={setImages} />
        </div>

        <VisibilityToggle
          checked={visibleToOthers}
          onChange={setVisibleToOthers}
          storeName={stores.find((s) => s.id === storeId)?.name ?? null}
        />

        <label>
          <span className="mb-1 block text-xs text-zinc-500">備註（選填，店對店內部訊息，不會給會員看）</span>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="mt-2 flex justify-end gap-2">
          <SpinButton type="button" onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</SpinButton>
          <SpinButton
            type="button"
            onClick={submit}
            disabled={submitting}
            className="rounded-md bg-emerald-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            {submitting ? "上架中…" : "上架"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

// ============================================================
// Offer Modal — 我有庫存可提供（從既有訂單釋出）
// ============================================================
function OfferModal({
  open, onClose, stores, onPosted,
}: {
  open: boolean;
  onClose: () => void;
  stores: Store[];
  onPosted: () => void;
}) {
  const [storeId, setStoreId] = useState<number | "">("");
  const [orders, setOrders] = useState<PendingOrder[] | null>(null);
  const [orderSearch, setOrderSearch] = useState("");
  const [pickedOrder, setPickedOrder] = useState<PendingOrder | null>(null);
  const [pickedItemIdx, setPickedItemIdx] = useState(0);
  const [qty, setQty] = useState("");
  const [expiresAt, setExpiresAt] = useState(defaultExpiresAt);
  const [note, setNote] = useState("");
  // 商品標題 / 釋出單價 / 商品說明：預填 SKU 組出的標題、來源訂單原價、
  // 商品主檔原文，店家可改。價低於原價時會員端會以刪除線顯示原價。
  const [spotTitle, setSpotTitle] = useState("");
  const [spotPrice, setSpotPrice] = useState("");
  const [spotDesc, setSpotDesc] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setStoreId(""); setOrders(null); setOrderSearch(""); setPickedOrder(null); setPickedItemIdx(0);
      setQty(""); setNote(""); setSpotTitle(""); setSpotPrice(""); setSpotDesc(""); setErr(null);
      setExpiresAt(defaultExpiresAt());
    }
  }, [open]);

  // 載入該店 pending orders
  useEffect(() => {
    if (!open || !storeId) { setOrders(null); return; }
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error: e } = await sb
        .from("customer_orders")
        .select(`
          id, order_no, pickup_store_id, status,
          member:members(name, phone),
          items:customer_order_items(campaign_item_id, sku_id, qty, status, unit_price, sku:skus(sku_code, product_name, variant_name, product:products(description)))
        `)
        .eq("pickup_store_id", storeId)
        // partially_completed 也要列：內部現貨池的單臨櫃賣掉一件就變這個狀態，
        // 只列 ready 的話「店裡明明還有貨」卻挑不到單，店家只好改發手動現貨
        // （轉單 RPC 本來就接受這兩個狀態，20260814000020）
        .in("status", ["ready", "partially_completed"])
        .order("id", { ascending: false })
        .limit(200);
      if (cancelled) return;
      if (e) { setErr(e.message); return; }
      type RawProduct = { description: string | null };
      type RawSku = { sku_code: string; product_name: string; variant_name: string | null; product?: RawProduct | RawProduct[] | null };
      type RawItem = { campaign_item_id: number | null; sku_id: number | null; qty: number; status: string; unit_price: number | string | null; sku: RawSku | RawSku[] | null };
      type RawMember = { name: string | null; phone: string | null };
      type RawOrder = {
        id: number; order_no: string; pickup_store_id: number; status: string;
        member: RawMember | RawMember[] | null;
        items: RawItem[];
      };
      const enriched: PendingOrder[] = ((data as unknown as RawOrder[] | null) ?? []).map((o) => {
        const memberObj = Array.isArray(o.member) ? o.member[0] : o.member;
        return {
          id: o.id,
          order_no: o.order_no,
          pickup_store_id: o.pickup_store_id,
          status: o.status,
          member_name: memberObj?.name ?? null,
          member_phone: memberObj?.phone ?? null,
          items: (o.items ?? [])
            // 排除已 cancelled / expired 的 item — 不該算進可釋出範圍
            .filter((it) => it.status !== "cancelled" && it.status !== "expired" && it.status !== "picked_up")
            .map((it) => {
              const sku = Array.isArray(it.sku) ? it.sku[0] : it.sku;
              const product = sku ? (Array.isArray(sku.product) ? sku.product[0] : sku.product) : null;
              const priceN = Number(it.unit_price);
              return {
                campaign_item_id: it.campaign_item_id,
                sku_id: it.sku_id,
                qty: Number(it.qty),
                sku_label: sku
                  ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} (${sku.sku_code})`
                  : `品項#${it.sku_id}`,
                // 和會員端 spotProductTitle() 的組法一字不差（全形／、不含 sku_code）
                default_title: sku
                  ? `${sku.product_name}${sku.variant_name ? `／${sku.variant_name}` : ""}`
                  : `品項#${it.sku_id}`,
                unit_price: Number.isFinite(priceN) ? priceN : null,
                product_description: product?.description ?? null,
              };
            }),
        };
      }).filter((o) => o.items.length > 0);
      setOrders(enriched);
    })();
    return () => { cancelled = true; };
  }, [open, storeId]);

  // 選了訂單 → 自動帶該 item 的數量、標題、原價、商品說明（後三者可改）
  useEffect(() => {
    const item = pickedOrder?.items[pickedItemIdx];
    if (item) {
      setQty(String(item.qty));
      setSpotTitle(item.default_title);
      setSpotPrice(item.unit_price != null ? String(item.unit_price) : "");
      setSpotDesc(stripHtmlToText(item.product_description));
    }
  }, [pickedOrder, pickedItemIdx]);

  // 搜尋過濾：品項 / 訂單編號 / 會員姓名 / 電話（空白分隔多關鍵字 = AND）
  const filteredOrders = useMemo(() => {
    if (!orders) return null;
    const terms = orderSearch.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (terms.length === 0) return orders;
    return orders.filter((o) => {
      const haystack = [o.order_no, o.member_name ?? "", o.member_phone ?? "", ...o.items.map((it) => it.sku_label)]
        .join(" ")
        .toLowerCase();
      return terms.every((t) => haystack.includes(t));
    });
  }, [orders, orderSearch]);

  async function submit() {
    if (submitting) return;
    setErr(null);
    if (!storeId) { setErr("請選釋出店"); return; }
    if (!pickedOrder) { setErr("請選要釋出的訂單"); return; }
    const item = pickedOrder.items[pickedItemIdx];
    if (!item || !item.sku_id) { setErr("選定 item 沒 sku_id"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("數量需 > 0"); return; }
    const expDate = new Date(expiresAt);
    if (expDate <= new Date()) { setErr("到期時間需在未來"); return; }
    const priceRaw = spotPrice.trim();
    let priceN: number | null = null;
    if (priceRaw !== "") {
      priceN = Number(priceRaw);
      if (!Number.isFinite(priceN) || priceN <= 0) { setErr("釋出單價需 > 0（留空 = 沿用原價）"); return; }
    }
    // 沒改的值送 null（= 沿用原價 / 商品主檔原文 / SKU 組出的標題），改了才存進板上
    const spotPriceParam = priceN != null && priceN !== item.unit_price ? priceN : null;
    const descTrim = spotDesc.trim();
    const spotDescParam =
      descTrim !== "" && descTrim !== stripHtmlToText(item.product_description) ? descTrim : null;
    const titleTrim = spotTitle.trim();
    const spotTitleParam = titleTrim !== "" && titleTrim !== item.default_title ? titleTrim : null;

    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_post_aid_board", {
        p_offering_store_id: storeId,
        p_sku_id: item.sku_id,
        p_qty_available: qtyN,
        p_expires_at: expDate.toISOString(),
        p_note: note.trim() || null,
        p_operator: operator,
        p_post_type: "offer",
        p_source_customer_order_id: pickedOrder.id,
        p_spot_price: spotPriceParam,
        p_spot_description: spotDescParam,
        p_spot_title: spotTitleParam,
      });
      if (e) { setErr(e.message); return; }
      onPosted();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="📦 我有庫存可提供（從既有訂單釋出）" maxWidth="max-w-2xl">
      <div className="flex flex-col gap-3 text-sm">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}
        <label>
          <span className="mb-1 block text-xs text-zinc-500">釋出店 <span className="text-red-500">*</span></span>
          <select
            value={storeId}
            onChange={(e) => {
              setStoreId(e.target.value ? Number(e.target.value) : "");
              setOrderSearch(""); setPickedOrder(null); setPickedItemIdx(0); setQty("");
            }}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選店 —</option>
            {stores.map((s) => (<option key={s.id} value={s.id}>{s.name} ({s.code})</option>))}
          </select>
        </label>

        {storeId !== "" && (
          <div>
            <span className="mb-1 block text-xs text-zinc-500">選擇要釋出的訂單 <span className="text-red-500">*</span></span>
            {orders === null ? (
              <div className="text-xs text-zinc-500">載入訂單中…</div>
            ) : orders.length === 0 ? (
              <div className="rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500 dark:border-zinc-700">該店目前沒有可釋出的 pending / confirmed / reserved 訂單</div>
            ) : (
              <>
                <input
                  value={orderSearch}
                  onChange={(e) => setOrderSearch(e.target.value)}
                  placeholder="搜尋品項 / 訂單編號 / 姓名 / 電話…"
                  className="mb-1.5 w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-xs dark:border-zinc-700 dark:bg-zinc-800"
                />
                {filteredOrders && filteredOrders.length === 0 ? (
                  <div className="rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500 dark:border-zinc-700">沒有符合「{orderSearch.trim()}」的訂單</div>
                ) : (
              <div className="max-h-60 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-800">
                {(filteredOrders ?? []).map((o) => (
                  <SpinButton
                    key={o.id}
                    type="button"
                    onClick={() => { setPickedOrder(o); setPickedItemIdx(0); }}
                    className={`block w-full border-b border-zinc-100 px-2 py-1.5 text-left text-xs last:border-b-0 dark:border-zinc-800 ${
                      pickedOrder?.id === o.id ? "bg-pink-50 dark:bg-pink-950" : "hover:bg-zinc-50 dark:hover:bg-zinc-800"
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <span><span className="font-mono">{o.order_no}</span> · {o.member_name ?? "—"}{o.member_phone && <span className="text-zinc-500"> · {o.member_phone}</span>} · <span className="text-zinc-500">{o.status}</span></span>
                      <span className="text-zinc-500">{o.items.length} 項</span>
                    </div>
                    {pickedOrder?.id === o.id && o.items.length > 1 && (
                      <div className="mt-1 flex flex-wrap gap-1">
                        {o.items.map((it, idx) => (
                          <SpinButton
                            key={idx}
                            type="button"
                            onClick={(e) => { e.stopPropagation(); setPickedItemIdx(idx); }}
                            className={`rounded border px-1.5 py-0.5 text-[10px] ${
                              pickedItemIdx === idx
                                ? "border-pink-500 bg-pink-100 text-pink-800 dark:bg-pink-950 dark:text-pink-300"
                                : "border-zinc-300 text-zinc-600 dark:border-zinc-700 dark:text-zinc-400"
                            }`}
                          >
                            {it.sku_label} × {it.qty}
                          </SpinButton>
                        ))}
                      </div>
                    )}
                    {pickedOrder?.id === o.id && o.items.length === 1 && (
                      <div className="mt-1 text-[10px] text-zinc-500">{o.items[0].sku_label} × {o.items[0].qty}</div>
                    )}
                  </SpinButton>
                ))}
              </div>
                )}
              </>
            )}
          </div>
        )}

        <label>
          <span className="mb-1 block text-xs text-zinc-500">商品標題（會員 App 現貨專區顯示的名稱，可改寫）</span>
          <input
            value={spotTitle}
            onChange={(e) => setSpotTitle(e.target.value)}
            placeholder="選了品項會自動帶入商品名稱，可直接改寫"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="grid grid-cols-3 gap-3">
          <label>
            <span className="mb-1 block text-xs text-zinc-500">釋出數量 <span className="text-red-500">*</span></span>
            <input
              value={qty}
              onChange={(e) => setQty(e.target.value)}
              inputMode="decimal"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">釋出單價</span>
            <input
              value={spotPrice}
              onChange={(e) => setSpotPrice(e.target.value)}
              inputMode="decimal"
              placeholder="留空 = 原價"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
            {(() => {
              const orig = pickedOrder?.items[pickedItemIdx]?.unit_price;
              const n = Number(spotPrice);
              if (orig == null) return null;
              if (spotPrice.trim() !== "" && Number.isFinite(n) && n < orig) {
                return (
                  <span className="mt-0.5 block text-[11px] text-emerald-600 dark:text-emerald-400">
                    低於原價 <s>${orig.toLocaleString()}</s> — App 會用刪除線顯示原價
                  </span>
                );
              }
              return <span className="mt-0.5 block text-[11px] text-zinc-400">原價 ${orig.toLocaleString()}</span>;
            })()}
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">到期時間 <span className="text-red-500">*</span></span>
            <input
              type="datetime-local"
              value={expiresAt}
              onChange={(e) => setExpiresAt(e.target.value)}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
        </div>
        <label>
          <span className="mb-1 block text-xs text-zinc-500">商品說明（會顯示在會員 App 的商品詳情，可改寫）</span>
          <textarea
            value={spotDesc}
            onChange={(e) => setSpotDesc(e.target.value)}
            rows={4}
            placeholder="選了品項會自動帶入商品主檔的說明，可直接改寫"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <label>
          <span className="mb-1 block text-xs text-zinc-500">備註（選填，店對店內部訊息，不會給會員看）</span>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="例：客人棄單、效期將至"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="mt-2 flex justify-end gap-2">
          <SpinButton type="button" onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</SpinButton>
          <SpinButton
            type="button"
            onClick={submit}
            disabled={submitting}
            className="rounded-md bg-pink-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-pink-700 disabled:opacity-50"
          >
            {submitting ? "送出中…" : "發佈釋出"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

// ============================================================
// Thread Modal
// ============================================================
function ThreadModal({
  post, stores, onClose, onClosed, onEdited,
}: {
  post: Post;
  stores: Store[];
  onClose: () => void;
  onClosed: () => void;
  /** 編輯標題/單價/到期/說明存檔後呼叫（父層重抓列表；modal 留在原地） */
  onEdited: () => void;
}) {
  const [replies, setReplies] = useState<Reply[] | null>(null);
  const [body, setBody] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [closing, setClosing] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [currentUserId, setCurrentUserId] = useState<string | null>(null);
  const [claimOpen, setClaimOpen] = useState(false);
  const [fulfillOpen, setFulfillOpen] = useState(false);
  // 發佈後編輯商品標題 / 釋出單價 / 到期時間 / 商品說明（僅 offer + active）。
  // originalPrice / originalDesc / originalTitle 是「沿用值」：原價來自來源訂單、
  // 原文與標題來自商品主檔 / SKU，編輯表單要靠它們判斷「改回原值 = 清除自訂」。
  const [editOpen, setEditOpen] = useState(false);
  // 存檔後 post prop 還是父層舊資料（列表重抓不會回填 modal），標頭單價用這個本地值蓋
  const [savedSpotPrice, setSavedSpotPrice] = useState<number | null>(post.spot_price);
  const [savedSpotTitle, setSavedSpotTitle] = useState<string | null>(post.spot_title);
  const [editPrice, setEditPrice] = useState(post.spot_price != null ? String(post.spot_price) : "");
  const [editDesc, setEditDesc] = useState(post.spot_description ?? "");
  const [editTitle, setEditTitle] = useState(post.spot_title ?? "");
  const [editUnit, setEditUnit] = useState(post.spot_unit ?? "");
  const [editImages, setEditImages] = useState<string[]>(post.spot_images ?? []);
  const [editQty, setEditQty] = useState(String(post.qty_available));
  const [editVisible, setEditVisible] = useState(post.spot_visible_to_other_stores);
  // 存檔後 post prop 仍是父層舊資料，標頭的「限本店」標記用本地值蓋
  const [savedVisible, setSavedVisible] = useState(post.spot_visible_to_other_stores);
  const [editExpiresAt, setEditExpiresAt] = useState(() => toLocalInput(post.expires_at));
  // 存檔後 post prop 仍是父層舊資料，標頭到期時間 / 數量用本地值蓋
  const [savedExpiresAt, setSavedExpiresAt] = useState(post.expires_at);
  const [savedQty, setSavedQty] = useState<{ available: number; remaining: number }>({
    available: post.qty_available,
    remaining: post.qty_remaining,
  });
  const [originalPrice, setOriginalPrice] = useState<number | null>(null);
  const [originalDesc, setOriginalDesc] = useState("");
  const [originalTitle, setOriginalTitle] = useState("");
  const [savingEdit, setSavingEdit] = useState(false);
  const canEdit = post.post_type === "offer" && post.status === "active";
  /** 手動現貨：沒有來源訂單（數量可以直接改；認領走 rpc_claim_manual_spot） */
  const isManual = post.post_type === "offer" && post.source_customer_order_id == null;
  /** 補選商品後 post prop 還是父層舊資料，認領鈕的判斷用這個本地值蓋 */
  const [savedSkuId, setSavedSkuId] = useState<number | null>(post.sku_id);
  const [editSku, setEditSku] = useState<SkuOption | null>(null);
  /** 可認領＝有來源訂單（原本那條），或手動現貨但已經選好商品 */
  const canClaim = post.post_type === "offer" && post.status === "active" &&
    (!isManual || savedSkuId != null);

  useEffect(() => {
    if (!canEdit) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [priceRes, skuRes] = await Promise.all([
        post.source_customer_order_id != null
          ? sb.from("customer_order_items").select("unit_price")
              .eq("order_id", post.source_customer_order_id).eq("sku_id", post.sku_id)
              .limit(1).maybeSingle()
          : Promise.resolve({ data: null }),
        // 手打的手動現貨沒有 SKU，沒有主檔可以查（標題/說明也就沒有「沿用值」）
        post.sku_id != null
          ? sb.from("skus").select("product_name, variant_name, product:products(description)")
              .eq("id", post.sku_id).maybeSingle()
          : Promise.resolve({ data: null }),
      ]);
      if (cancelled) return;
      const priceN = Number((priceRes.data as { unit_price?: number | string } | null)?.unit_price);
      setOriginalPrice(Number.isFinite(priceN) ? priceN : null);
      const skuRow = skuRes.data as {
        product_name?: string | null;
        variant_name?: string | null;
        product?: { description: string | null } | { description: string | null }[] | null;
      } | null;
      const productRaw = skuRow?.product;
      const product = Array.isArray(productRaw) ? productRaw[0] : productRaw;
      const desc = stripHtmlToText(product?.description);
      setOriginalDesc(desc);
      // 和會員端 spotProductTitle() 的組法一字不差（全形／）
      const title = skuRow?.product_name
        ? `${skuRow.product_name}${skuRow.variant_name ? `／${skuRow.variant_name}` : ""}`
        : "";
      setOriginalTitle(title);
      // 沒有自訂說明/標題時，編輯框預填原值（跟上架表單同一套預填邏輯）
      if (post.spot_description == null && desc) setEditDesc((cur) => (cur === "" ? desc : cur));
      if (post.spot_title == null && title) setEditTitle((cur) => (cur === "" ? title : cur));
    })();
    return () => { cancelled = true; };
    // post.id 換了整個 modal 會重掛，這裡跑一次就好
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [post.id, canEdit]);

  async function saveEdit() {
    if (savingEdit) return;
    setErr(null);
    const raw = editPrice.trim();
    let priceN: number | null = null;
    if (raw !== "") {
      priceN = Number(raw);
      if (!Number.isFinite(priceN) || priceN <= 0) { setErr("釋出單價需 > 0（留空 = 沿用原價）"); return; }
    }
    // 與原值相同就存 NULL（= 沿用），跟上架表單同語意
    const spotPriceParam = priceN != null && priceN !== originalPrice ? priceN : null;
    const descTrim = editDesc.trim();
    const spotDescParam = descTrim !== "" && descTrim !== originalDesc ? descTrim : null;
    const titleTrim = editTitle.trim();
    const spotTitleParam = titleTrim !== "" && titleTrim !== originalTitle ? titleTrim : null;
    // 沒 SKU 的手打商品沒有 fallback，標題不能清空（DB 也會擋，這裡先講人話）
    if (post.sku_id == null && spotTitleParam == null) {
      setErr("這則是手打的商品、沒有商品主檔可沿用，標題不能留空");
      return;
    }
    const expDate = new Date(editExpiresAt);
    if (Number.isNaN(expDate.getTime())) { setErr("到期時間格式不正確"); return; }
    if (expDate <= new Date()) { setErr("到期時間需在未來（要立刻下架請用「結束此貼」）"); return; }
    // 數量只有手動現貨能改；從訂單釋出的貼文 qty 和認領扣量綁在一起，不送這個參數
    let qtyParam: number | null = null;
    if (isManual) {
      const qtyN = Number(editQty);
      if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("數量需 > 0"); return; }
      qtyParam = qtyN;
    }
    setSavingEdit(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_update_aid_board_listing", {
        p_board_id: post.id,
        p_operator: operator,
        p_spot_price: spotPriceParam,
        p_spot_description: spotDescParam,
        p_expires_at: expDate.toISOString(),
        p_spot_title: spotTitleParam,
        // 圖片留空 = 清除自訂、回沿用商品主檔的圖
        p_spot_images: editImages.length > 0 ? editImages : null,
        p_spot_unit: editUnit.trim() || null,
        p_qty_available: qtyParam,
        // 只有手動現貨開放這個開關，訂單來源的送 null（= 不動，維持看得到）
        p_visible_to_other_stores: isManual ? editVisible : null,
        // 補選商品：沒挑就送 null（= 不動）；訂單來源的貼文 SKU 綁著來源品項不可改
        p_sku_id: isManual && editSku ? editSku.id : null,
      });
      if (e) { setErr(e.message); return; }
      setSavedSpotPrice(spotPriceParam);
      setSavedSpotTitle(spotTitleParam);
      setSavedExpiresAt(expDate.toISOString());
      if (editSku) setSavedSkuId(editSku.id);
      // 已認領的量要留著（伺服端同一套算法），不能直接把 remaining 蓋成新總量
      if (qtyParam != null) {
        setSavedQty((prev) => ({
          available: qtyParam,
          remaining: Math.max(0, qtyParam - Math.max(0, prev.available - prev.remaining)),
        }));
      }
      if (isManual) setSavedVisible(editVisible);
      setEditOpen(false);
      onEdited();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSavingEdit(false);
    }
  }

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [{ data: rRes }, { data: uRes }] = await Promise.all([
        sb.from("mutual_aid_replies")
          .select("id, board_id, author_id, author_label, body, created_at")
          .eq("board_id", post.id)
          .order("created_at", { ascending: true }),
        sb.auth.getUser(),
      ]);
      if (cancelled) return;
      setReplies((rRes as Reply[] | null) ?? []);
      setCurrentUserId(uRes.user?.id ?? null);
    })();
    return () => { cancelled = true; };
  }, [post.id, tick]);

  const canClose = post.status === "active" && (currentUserId === post.created_by || true);

  async function postReply() {
    if (submitting) return;
    setErr(null);
    if (!body.trim()) { setErr("請輸入留言"); return; }
    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_post_aid_reply", {
        p_board_id: post.id,
        p_body: body,
        p_operator: operator,
      });
      if (e) { setErr(e.message); return; }
      setBody("");
      setTick((n) => n + 1);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  async function closePost() {
    if (closing) return;
    if (!confirm("確定要結束這則互助貼文？")) return;
    setClosing(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_close_aid_board", {
        p_board_id: post.id,
        p_status: "cancelled",
        p_operator: operator,
      });
      if (e) { setErr(e.message); return; }
      onClosed();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setClosing(false);
    }
  }

  return (
    <Modal open={true} onClose={onClose} title={`互助貼文 #${post.id}`} maxWidth="max-w-2xl">
      <div className="flex flex-col gap-3 text-sm">
        {/* Post header */}
        <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs dark:border-zinc-800 dark:bg-zinc-950">
          <div className="mb-1 flex flex-wrap items-center gap-2">
            <span className={`rounded px-1.5 py-0.5 text-[10px] ${STATUS_COLOR[post.status]}`}>
              {STATUS_LABEL[post.status]}
            </span>
            <span className="font-medium text-zinc-700 dark:text-zinc-300">{post.store_name}</span>
            <span className="text-zinc-500">釋出</span>
            <span>{post.sku_label}</span>
            {isManual && (
              <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                手動{post.sku_id == null ? "・手打商品" : ""}
              </span>
            )}
            {!savedVisible && (
              <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                🔒 限本店會員
              </span>
            )}
            {savedSpotTitle && (
              <span className="rounded bg-blue-100 px-1.5 py-0.5 text-[10px] text-blue-800 dark:bg-blue-950 dark:text-blue-300">
                App 標題：{savedSpotTitle}
              </span>
            )}
            <SpinButton
              type="button"
              onClick={() => printViaIframe(withBasePath(`/inventory/mutual-aid/print?id=${post.id}`))}
              title="列印這一則（A4 直式：內容 + 留言 + 認領簽收欄）"
              className="ml-auto shrink-0 rounded-md border border-zinc-300 px-2 py-0.5 text-[11px] text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
            >
              🖨️ 列印
            </SpinButton>
          </div>
          <div className="flex flex-wrap gap-x-4 gap-y-1 text-zinc-500">
            <span>
              {post.post_type === "request" ? "尚需" : "可釋"}{" "}
              <span className="font-mono text-zinc-700 dark:text-zinc-300">{savedQty.remaining}</span>
              {savedQty.remaining !== savedQty.available && (
                <span className="ml-1 text-[10px] text-zinc-400">/ 原 {savedQty.available}</span>
              )}
            </span>
            <span>到期 <span className="text-zinc-700 dark:text-zinc-300">{fmtDt(savedExpiresAt)}</span></span>
            <span>發佈 {fmtDt(post.created_at)}</span>
            {post.post_type === "offer" && (
              <span>
                單價{" "}
                <span className="font-mono text-zinc-700 dark:text-zinc-300">
                  {savedSpotPrice != null
                    ? `$${savedSpotPrice}`
                    : originalPrice != null
                      ? `$${originalPrice}`
                      : "沿用原價"}
                </span>
                {savedSpotPrice != null && originalPrice != null && originalPrice > savedSpotPrice && (
                  <s className="ml-1 text-zinc-400">${originalPrice}</s>
                )}
              </span>
            )}
            {post.note && <div className="basis-full pt-1 text-zinc-700 dark:text-zinc-300">「{post.note}」</div>}
          </div>
        </div>

        {/* 發佈後編輯：商品標題 / 釋出單價 / 單位 / 數量 / 到期時間 / 商品說明 / 圖片
            （僅 offer + active；改完會員端即時生效。數量只有手動現貨能改） */}
        {canEdit && editOpen && (
          <div className="flex flex-col gap-2 rounded-md border border-blue-200 bg-blue-50/40 p-3 text-xs dark:border-blue-900 dark:bg-blue-950/20">
            <label>
              <span className="mb-1 block text-zinc-500">商品標題（會員 App 現貨專區顯示的名稱，可改寫）</span>
              <input
                value={editTitle}
                onChange={(e) => setEditTitle(e.target.value)}
                placeholder={originalTitle || (post.sku_id == null ? "手打商品，標題必填" : "留空 = 沿用商品名稱")}
                className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
              />
            </label>
            {/* 補選商品：沒選 SKU 的手動現貨別店認領不了（沒東西可以轉單）。
                選了就不能改回「沒有」—— 送 NULL 是「不動」，不是清除。 */}
            {isManual && (
              <div>
                <span className="mb-1 block text-zinc-500">
                  商品（SKU）
                  {savedSkuId == null && (
                    <span className="ml-1 text-amber-600 dark:text-amber-400">— 沒選商品的話，別的分店無法認領</span>
                  )}
                </span>
                {savedSkuId != null && !editSku ? (
                  <div className="flex items-center gap-2">
                    <span className="rounded bg-white px-2 py-1 dark:bg-zinc-800">{post.sku_label ?? `#${savedSkuId}`}</span>
                    <span className="text-[11px] text-zinc-400">已可被認領；要換商品請在下方重新搜尋</span>
                  </div>
                ) : null}
                <div className="mt-1">
                  <SkuSearchInput value={editSku} onChange={setEditSku} />
                </div>
              </div>
            )}
            {isManual && (
              <div className="grid grid-cols-2 gap-2">
                <label>
                  <span className="mb-1 block text-zinc-500">數量</span>
                  <input
                    value={editQty}
                    onChange={(e) => setEditQty(e.target.value)}
                    inputMode="decimal"
                    className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
                  />
                  <span className="mt-0.5 block text-[11px] text-zinc-400">改總量會保留已被認領的部分（剩餘量 = 新總量 − 已認領）</span>
                </label>
                <label>
                  <span className="mb-1 block text-zinc-500">單位</span>
                  <input
                    value={editUnit}
                    onChange={(e) => setEditUnit(e.target.value)}
                    placeholder={post.sku_id != null ? "留空 = 商品單位" : "包 / 份"}
                    className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
                  />
                </label>
              </div>
            )}
            <label>
              <span className="mb-1 block text-zinc-500">釋出單價</span>
              <input
                value={editPrice}
                onChange={(e) => setEditPrice(e.target.value)}
                inputMode="decimal"
                placeholder={originalPrice != null ? "留空 = 原價" : "留空 = 不顯示"}
                className="w-40 rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
              />
              {(() => {
                // 手動現貨沒有來源訂單 → 沒有「原價」可比，也就沒有刪除線那套
                if (originalPrice == null) {
                  return <span className="ml-2 text-[11px] text-zinc-400">沒有來源訂單，留空的話 App 不顯示金額</span>;
                }
                const n = Number(editPrice);
                if (editPrice.trim() !== "" && Number.isFinite(n) && n < originalPrice) {
                  return (
                    <span className="ml-2 text-[11px] text-emerald-600 dark:text-emerald-400">
                      低於原價 <s>${originalPrice.toLocaleString()}</s> — App 會用刪除線顯示原價
                    </span>
                  );
                }
                return <span className="ml-2 text-[11px] text-zinc-400">原價 ${originalPrice.toLocaleString()}</span>;
              })()}
            </label>
            <label>
              <span className="mb-1 block text-zinc-500">到期時間</span>
              <input
                type="datetime-local"
                value={editExpiresAt}
                onChange={(e) => setEditExpiresAt(e.target.value)}
                className="rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
              />
              <span className="ml-2 text-[11px] text-zinc-400">
                到期後會員端自動下架；要立刻收回請用「結束此貼」
              </span>
            </label>
            <label>
              <span className="mb-1 block text-zinc-500">商品說明（會顯示在會員 App 的商品詳情，可改寫）</span>
              <textarea
                value={editDesc}
                onChange={(e) => setEditDesc(e.target.value)}
                rows={4}
                className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
              />
            </label>
            <div>
              <span className="mb-1 block text-zinc-500">
                商品圖片
                {post.sku_id != null && <span className="ml-1 text-zinc-400">（留空 = 沿用商品主檔的圖）</span>}
              </span>
              <ProductImagesField value={editImages} onChange={setEditImages} />
            </div>
            {isManual && (
              <VisibilityToggle
                checked={editVisible}
                onChange={setEditVisible}
                storeName={post.store_name ?? null}
              />
            )}
            <div className="flex justify-end gap-2">
              <SpinButton
                onClick={() => setEditOpen(false)}
                className="rounded border border-zinc-300 px-3 py-1.5 dark:border-zinc-700"
              >
                取消
              </SpinButton>
              <SpinButton
                onClick={saveEdit}
                disabled={savingEdit}
                className="rounded bg-blue-600 px-3 py-1.5 font-medium text-white hover:bg-blue-500 disabled:opacity-50"
              >
                {savingEdit ? "儲存中…" : "儲存修改"}
              </SpinButton>
            </div>
          </div>
        )}

        {/* 提供紀錄：這則貼文被哪幾家店接走 / 補上了 */}
        <AidClaimLog post={post} />

        {/* Replies thread */}
        <div className="flex flex-col gap-2 max-h-80 overflow-y-auto pr-1">
          {replies === null ? (
            <div className="text-xs text-zinc-500">載入留言…</div>
          ) : replies.length === 0 ? (
            <div className="text-xs text-zinc-500">尚無留言。第一個留言開始討論吧！</div>
          ) : (
            replies.map((r) => (
              <div
                key={r.id}
                className="rounded-md border border-zinc-200 bg-white p-2 text-xs dark:border-zinc-800 dark:bg-zinc-900"
              >
                <div className="mb-1 flex items-center justify-between text-[10px] text-zinc-500">
                  <span className="font-medium text-zinc-700 dark:text-zinc-300">{r.author_label ?? "匿名"}</span>
                  <span>{fmtDt(r.created_at)}</span>
                </div>
                <div className="whitespace-pre-wrap text-zinc-700 dark:text-zinc-300">{r.body}</div>
              </div>
            ))
          )}
        </div>

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        {/* Reply form */}
        {post.status === "active" ? (
          <div>
            <textarea
              value={body}
              onChange={(e) => setBody(e.target.value)}
              onKeyDown={(e) => {
                if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
                  e.preventDefault();
                  postReply();
                }
              }}
              placeholder="留言（Ctrl+Enter 送出）"
              rows={2}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-xs dark:border-zinc-700 dark:bg-zinc-800"
            />
            <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
              <div className="flex flex-wrap gap-2">
                {/* 手動現貨也能認領（20260816000000）：認領當下才在釋出店建一張
                    載體單再轉給認領店。但沒選商品（SKU）就沒東西可以轉 —— 那種
                    貼文要先按「✏️ 修改內容」補選商品。 */}
                {post.post_type === "offer" && canClaim && (
                  <SpinButton
                    type="button"
                    onClick={() => setClaimOpen(true)}
                    className="rounded-md border border-pink-400 bg-pink-50 px-3 py-1.5 text-xs font-medium text-pink-700 hover:bg-pink-100 dark:border-pink-700 dark:bg-pink-950 dark:text-pink-300 dark:hover:bg-pink-900"
                    title={isManual
                      ? "把這批現貨轉給接收店（系統會在釋出店開一張內部載體單再轉單）"
                      : "把釋出店的訂單轉成接收店的（走 5b-1 棄單轉出）"}
                  >
                    ✋ 我要認領
                  </SpinButton>
                )}
                {post.post_type === "offer" && !canClaim && (
                  <span className="self-center text-[11px] text-amber-600 dark:text-amber-400">
                    這則還沒選商品 → 別店認領不了，請按「✏️ 修改內容」補選商品
                  </span>
                )}
                {canEdit && !editOpen && (
                  <SpinButton
                    type="button"
                    onClick={() => setEditOpen(true)}
                    className="rounded-md border border-blue-400 bg-blue-50 px-3 py-1.5 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                    title="修改標題 / 單價 / 到期 / 說明 / 圖片（會員端即時生效）"
                  >
                    ✏️ 修改內容
                  </SpinButton>
                )}
                {post.post_type === "request" && (
                  <SpinButton
                    type="button"
                    onClick={() => setFulfillOpen(true)}
                    className="rounded-md border border-blue-400 bg-blue-50 px-3 py-1.5 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                    title="從我的 pending 訂單挑一張轉給求助店"
                  >
                    🤝 我可以提供
                  </SpinButton>
                )}
                {canClose && (
                  <SpinButton
                    type="button"
                    onClick={closePost}
                    disabled={closing}
                    className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs text-zinc-600 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                  >
                    {closing ? "處理中…" : "結束此貼"}
                  </SpinButton>
                )}
              </div>
              <SpinButton
                type="button"
                onClick={postReply}
                disabled={submitting || !body.trim()}
                className="rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
              >
                {submitting ? "送出中…" : "送出留言"}
              </SpinButton>
            </div>
          </div>
        ) : (
          <div className="rounded-md border border-zinc-200 bg-zinc-50 p-2 text-xs text-zinc-500 dark:border-zinc-800 dark:bg-zinc-950">
            此貼已關閉（{STATUS_LABEL[post.status]}），無法再留言。
          </div>
        )}
      </div>

      {claimOpen && (
        <ClaimOfferDialog
          post={post}
          skuId={savedSkuId}
          stores={stores}
          onCancel={() => setClaimOpen(false)}
          onDone={() => {
            setClaimOpen(false);
            onClosed();
          }}
        />
      )}
      {fulfillOpen && (
        <FulfillRequestDialog
          post={post}
          stores={stores}
          onCancel={() => setFulfillOpen(false)}
          onDone={() => {
            setFulfillOpen(false);
            onClosed();
          }}
        />
      )}
    </Modal>
  );
}

// ============================================================
// Claim Offer Dialog — 認領釋出（receiving store 從釋出方拿訂單）
// ============================================================
function ClaimOfferDialog({
  post, skuId, stores, onCancel, onDone,
}: {
  post: Post;
  /** 補選商品後父層 post 還是舊資料，SKU 一律吃 thread modal 的本地值 */
  skuId: number | null;
  stores: Store[];
  onCancel: () => void;
  onDone: () => void;
}) {
  const [toStore, setToStore] = useState<number | "">("");
  const [qty, setQty] = useState(String(post.qty_remaining));
  const [isAir, setIsAir] = useState(false);
  const [reason, setReason] = useState(`互助板認領 #${post.id}`);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const isManual = post.source_customer_order_id == null;

  async function submit() {
    if (busy) return;
    setErr(null);
    if (!toStore) { setErr("請選接收店"); return; }
    if (!isManual && !post.source_customer_order_id) { setErr("此 offer 缺 source_customer_order_id（資料異常）"); return; }
    if (isManual && !skuId) { setErr("這則貼文還沒選商品，請先用「✏️ 修改內容」補選"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("認領數量需 > 0"); return; }
    if (qtyN > post.qty_remaining) { setErr(`認領數量超過剩餘量 ${post.qty_remaining}`); return; }
    setBusy(true);
    try {
      const sb = getSupabase();
      const { data: { user } } = await sb.auth.getUser();
      if (!user?.id) { setErr("未登入"); return; }
      // 手動現貨沒有來源訂單 → 走 rpc_claim_manual_spot：它會在釋出店建一張
      // 載體單、當場轉給接收店、扣貼文量，全部在同一個交易裡（20260816000000）
      if (isManual) {
        const { error: eM } = await sb.rpc("rpc_claim_manual_spot", {
          p_board_id: post.id,
          p_to_store_id: toStore,
          p_qty: qtyN,
          p_operator: user.id,
          p_reason: reason || null,
          p_is_air_transfer: isAir,
        });
        if (eM) { setErr(eM.message); return; }
        onDone();
        return;
      }
      const { error: e1 } = await sb.rpc("rpc_transfer_order_partial", {
        p_order_id: post.source_customer_order_id,
        p_to_pickup_store_id: toStore,
        p_to_member_id: null,
        p_to_channel_id: null,
        p_operator: user.id,
        p_reason: reason || null,
        p_items: [{ sku_id: post.sku_id, qty: qtyN }],
        p_is_air_transfer: isAir,
        // 互助的轉單一律開自己的新單，不併進收貨店既有的容器單（20260824060000）
        p_aid_board_id: post.id,
      });
      if (e1) { setErr(e1.message); return; }
      // 統一走 consume RPC：reach 0 自動 exhausted、>0 保持 active 可分批
      const { error: e2 } = await sb.rpc("rpc_consume_aid_board", {
        p_board_id: post.id,
        p_qty: qtyN,
        p_operator: user.id,
      });
      if (e2) { setErr(`轉移成功但扣量失敗：${e2.message}`); return; }
      onDone();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-zinc-900/60 p-4" onClick={onCancel}>
      <div className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900" onClick={(e) => e.stopPropagation()}>
        <h3 className="mb-3 text-base font-semibold">認領釋出</h3>
        {err && (
          <div className="mb-2 rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{err}</div>
        )}
        <div className="mb-3 rounded bg-zinc-50 p-2 text-xs dark:bg-zinc-950">
          {isManual ? (
            <>
              把「{post.store_name}」的現貨 <span className="font-medium">{post.spot_title ?? post.sku_label}</span> 轉給接收店：
              系統會在釋出店開一張內部載體單再轉單，接收店在「收貨」頁收貨後就能出給客人。
            </>
          ) : (
            <>
              從「{post.store_name}」的訂單 <span className="font-mono">{post.source_order_no ?? `#${post.source_customer_order_id}`}</span> 取出指定數量、開新單給接收店（走 5b-1 partial transfer）。
            </>
          )}
        </div>
        <div className="mb-3 grid grid-cols-2 gap-3 text-sm">
          <label>
            <span className="mb-1 block text-xs text-zinc-500">接收店 <span className="text-red-500">*</span></span>
            <select
              value={toStore}
              onChange={(e) => setToStore(e.target.value ? Number(e.target.value) : "")}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
            >
              <option value="">— 選店 —</option>
              {stores.filter((s) => s.id !== post.offering_store_id).map((s) => (
                <option key={s.id} value={s.id}>{s.name} ({s.code})</option>
              ))}
            </select>
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">認領數量 <span className="text-red-500">*</span></span>
            <input
              value={qty}
              onChange={(e) => setQty(e.target.value)}
              inputMode="decimal"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
            <div className="mt-1 text-[10px] text-zinc-500">剩餘可認 {post.qty_remaining}{post.qty_remaining !== post.qty_available && `（原 ${post.qty_available}）`}</div>
          </label>
        </div>
        {/* 空中轉的差別要在按下去之前就講清楚 —— 線上實際的互助幾乎都沒勾，
            結果貨要多繞總倉一趟、還得等總倉收了才派得動（2026-08-25 老闆指示） */}
        <label className="mb-3 flex items-start gap-2 rounded-md border border-zinc-200 p-2 text-sm dark:border-zinc-700">
          <input type="checkbox" checked={isAir} onChange={(e) => setIsAir(e.target.checked)} className="mt-0.5 h-4 w-4" />
          <span className="min-w-0 flex-1">
            <span className="font-medium">空中轉（店對店直送、不經總倉）</span>
            <span className="mt-0.5 block text-[11px] text-zinc-500">
              勾選 = 送出當下就從轉出店出庫，<span className="font-medium">直接進接收店的「收貨」頁</span>，
              月結自動一加一扣；不勾 = 經總倉中轉，要等總倉收到貨再派給接收店。
            </span>
          </span>
        </label>
        <label className="mb-3 block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">原因（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="flex justify-end gap-2">
          <SpinButton type="button" onClick={onCancel} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</SpinButton>
          <SpinButton
            type="button"
            onClick={submit}
            disabled={busy}
            className="rounded-md bg-pink-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-pink-700 disabled:opacity-50"
          >
            {busy ? "處理中…" : "確認認領"}
          </SpinButton>
        </div>
      </div>
    </div>
  );
}

// ============================================================
// Fulfill Request Dialog — 提供需求（從我的訂單挑一張轉給求助店）
// ============================================================
function FulfillRequestDialog({
  post, stores, onCancel, onDone,
}: {
  post: Post;
  stores: Store[];
  onCancel: () => void;
  onDone: () => void;
}) {
  const [myStore, setMyStore] = useState<number | "">("");
  const [orders, setOrders] = useState<PendingOrder[] | null>(null);
  const [pickedOrderId, setPickedOrderId] = useState<number | null>(null);
  const [qty, setQty] = useState(String(post.qty_remaining));
  const [isAir, setIsAir] = useState(false);
  const [reason, setReason] = useState(`互助板提供 #${post.id}`);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // 載入我店符合 sku 的 pending orders
  useEffect(() => {
    if (!myStore) { setOrders(null); return; }
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error: e } = await sb
        .from("customer_orders")
        .select(`
          id, order_no, pickup_store_id, status,
          member:members(name, phone),
          items:customer_order_items!inner(sku_id, qty, status, sku:skus(sku_code, product_name, variant_name))
        `)
        .eq("pickup_store_id", myStore)
        .eq("status", "ready")
        .eq("items.sku_id", post.sku_id)
        .not("items.status", "in", "(cancelled,expired,picked_up)")
        .order("id", { ascending: false })
        .limit(50);
      if (cancelled) return;
      if (e) { setErr(e.message); return; }
      type RawSku = { sku_code: string; product_name: string; variant_name: string | null };
      type RawItem = { sku_id: number | null; qty: number; status: string; sku: RawSku | RawSku[] | null };
      type RawMember = { name: string | null; phone: string | null };
      type RawOrder = {
        id: number; order_no: string; pickup_store_id: number; status: string;
        member: RawMember | RawMember[] | null;
        items: RawItem[];
      };
      const enriched: PendingOrder[] = ((data as unknown as RawOrder[] | null) ?? []).map((o) => {
        const memberObj = Array.isArray(o.member) ? o.member[0] : o.member;
        return {
          id: o.id, order_no: o.order_no, pickup_store_id: o.pickup_store_id, status: o.status,
          member_name: memberObj?.name ?? null,
          member_phone: memberObj?.phone ?? null,
          items: (o.items ?? [])
            .filter((it) => it.status !== "cancelled" && it.status !== "expired" && it.status !== "picked_up")
            .map((it) => {
            const sku = Array.isArray(it.sku) ? it.sku[0] : it.sku;
            return {
              campaign_item_id: null, sku_id: it.sku_id, qty: Number(it.qty),
              // 這個 modal（回應求助）用不到單價/說明/自訂標題，補 null 滿足共用型別
              unit_price: null, product_description: null,
              sku_label: sku ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} (${sku.sku_code})` : `品項#${it.sku_id}`,
              default_title: sku ? `${sku.product_name}${sku.variant_name ? `／${sku.variant_name}` : ""}` : `品項#${it.sku_id}`,
            };
          }),
        };
      });
      setOrders(enriched);
    })();
    return () => { cancelled = true; };
  }, [myStore, post.sku_id]);

  async function submit() {
    if (busy) return;
    setErr(null);
    if (!myStore) { setErr("請選提供店"); return; }
    if (!pickedOrderId) { setErr("請選要轉移的訂單"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("提供數量需 > 0"); return; }
    if (qtyN > post.qty_remaining) { setErr(`提供數量超過剩餘需求 ${post.qty_remaining}`); return; }
    setBusy(true);
    try {
      const sb = getSupabase();
      const { data: { user } } = await sb.auth.getUser();
      if (!user?.id) { setErr("未登入"); return; }
      const { error: e1 } = await sb.rpc("rpc_transfer_order_partial", {
        p_order_id: pickedOrderId,
        p_to_pickup_store_id: post.offering_store_id,
        p_to_member_id: null,
        p_to_channel_id: null,
        p_operator: user.id,
        p_reason: reason || null,
        p_items: [{ sku_id: post.sku_id, qty: qtyN }],
        p_is_air_transfer: isAir,
        // 互助的轉單一律開自己的新單，不併進求助店既有的容器單（20260824060000）
        p_aid_board_id: post.id,
      });
      if (e1) { setErr(e1.message); return; }
      const { error: e2 } = await sb.rpc("rpc_consume_aid_board", {
        p_board_id: post.id,
        p_qty: qtyN,
        p_operator: user.id,
      });
      if (e2) { setErr(`轉移成功但扣量失敗：${e2.message}`); return; }
      onDone();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-zinc-900/60 p-4" onClick={onCancel}>
      <div className="w-full max-w-lg rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900" onClick={(e) => e.stopPropagation()}>
        <h3 className="mb-3 text-base font-semibold">提供需求</h3>
        {err && (
          <div className="mb-2 rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{err}</div>
        )}
        <div className="mb-3 rounded bg-zinc-50 p-2 text-xs dark:bg-zinc-950">
          求助店「{post.store_name}」尚需 {post.sku_label}（剩餘 {post.qty_remaining}{post.qty_remaining !== post.qty_available && `／原 ${post.qty_available}`}）。
          選一張你店的 pending 訂單轉給他（走 5b-1 棄單轉出）。
        </div>
        <label className="mb-3 block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">提供店（你的店） <span className="text-red-500">*</span></span>
          <select
            value={myStore}
            onChange={(e) => { setMyStore(e.target.value ? Number(e.target.value) : ""); setPickedOrderId(null); }}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選店 —</option>
            {stores.filter((s) => s.id !== post.offering_store_id).map((s) => (
              <option key={s.id} value={s.id}>{s.name} ({s.code})</option>
            ))}
          </select>
        </label>
        {myStore !== "" && (
          <div className="mb-3">
            <span className="mb-1 block text-xs text-zinc-500">挑一張含此品項的 pending 訂單 <span className="text-red-500">*</span></span>
            {orders === null ? (
              <div className="text-xs text-zinc-500">載入訂單中…</div>
            ) : orders.length === 0 ? (
              <div className="rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500 dark:border-zinc-700">該店沒有含此品項的可轉移訂單</div>
            ) : (
              <div className="max-h-48 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-800">
                {orders.map((o) => (
                  <SpinButton
                    key={o.id}
                    type="button"
                    onClick={() => setPickedOrderId(o.id)}
                    className={`block w-full border-b border-zinc-100 px-2 py-1.5 text-left text-xs last:border-b-0 dark:border-zinc-800 ${
                      pickedOrderId === o.id ? "bg-blue-50 dark:bg-blue-950" : "hover:bg-zinc-50 dark:hover:bg-zinc-800"
                    }`}
                  >
                    <span className="font-mono">{o.order_no}</span> · {o.member_name ?? "—"} · 數量 {o.items.find((it) => it.sku_id === post.sku_id)?.qty ?? "—"} · <span className="text-zinc-500">{o.status}</span>
                  </SpinButton>
                ))}
              </div>
            )}
          </div>
        )}
        <label className="mb-3 block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">提供數量 <span className="text-red-500">*</span></span>
          <input
            value={qty}
            onChange={(e) => setQty(e.target.value)}
            inputMode="decimal"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
          />
          <div className="mt-1 text-[10px] text-zinc-500">剩餘需求 {post.qty_remaining}（≤ 此值；不足部分維持需求中）</div>
        </label>
        {/* 空中轉的差別要在按下去之前就講清楚 —— 線上實際的互助幾乎都沒勾，
            結果貨要多繞總倉一趟、還得等總倉收了才派得動（2026-08-25 老闆指示） */}
        <label className="mb-3 flex items-start gap-2 rounded-md border border-zinc-200 p-2 text-sm dark:border-zinc-700">
          <input type="checkbox" checked={isAir} onChange={(e) => setIsAir(e.target.checked)} className="mt-0.5 h-4 w-4" />
          <span className="min-w-0 flex-1">
            <span className="font-medium">空中轉（店對店直送、不經總倉）</span>
            <span className="mt-0.5 block text-[11px] text-zinc-500">
              勾選 = 送出當下就從轉出店出庫，<span className="font-medium">直接進接收店的「收貨」頁</span>，
              月結自動一加一扣；不勾 = 經總倉中轉，要等總倉收到貨再派給接收店。
            </span>
          </span>
        </label>
        <label className="mb-3 block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">原因（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="flex justify-end gap-2">
          <SpinButton type="button" onClick={onCancel} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</SpinButton>
          <SpinButton
            type="button"
            onClick={submit}
            disabled={busy}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {busy ? "處理中…" : "確認提供"}
          </SpinButton>
        </div>
      </div>
    </div>
  );
}

function fmtDt(s: string) {
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return s;
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  return `${y}/${m}/${day} ${hh}:${mm}`;
}

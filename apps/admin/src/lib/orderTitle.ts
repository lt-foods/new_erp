// 訂單卡標題：一般團購單印開團名稱，內部 sentinel 團改印品項名。
//
// 為什麼要有例外：店內現貨轉手給客人的單（__INTERNAL_RESTOCK__-TFxxxx）
// 全部掛在共用 sentinel 團「【內部】補貨申請」底下 —— 那個名字是內部帳本用語，
// 一個商品字都沒有。直接印出來，客人看到的就是一張標題「【內部】補貨申請」、
// 品項只有規格「一尾 139 × 2」的卡片，完全認不出自己買了什麼
// （2026-08-11 回報；線上 94 張、84 位真會員中獎）。
//
// 一般團購單維持印開團名稱 —— 客人是照開團名下單的，改成商品名反而對不上。
//
// ⚠️ 這是會員 app 那份的副本（後台「會員畫面」＝團友手機上的畫面，客服對帳時
//    兩邊要一模一樣）：apps/member/src/lib/orderTitle.ts。改這邊記得改那邊。

import { cleanCampaignText } from "@/lib/text";

export type TitleItemLike = {
  product_name?: string | null;
  variant_name?: string | null;
  status?: string | null;
};

export type TitleOrderLike = {
  /** v_customer_order_summary.campaign_no（20260811000050 起才有） */
  campaign_no?: string | null;
  campaign_name?: string | null;
  items?: TitleItemLike[] | null;
};

/**
 * 內部 sentinel 團：campaign_no 以 '__' 開頭（= /shop 擋掉內部團用的同一條判斷）。
 * campaign_name 的「【內部】」前綴是備援 —— 舊 payload（view 還沒補 campaign_no
 * 之前的快取回應）也要能認出來，否則就會漏印成內部用語。
 */
export function isInternalCampaign(order: TitleOrderLike): boolean {
  const no = (order.campaign_no ?? "").trim();
  if (no) return no.startsWith("__");
  return (order.campaign_name ?? "").trim().startsWith("【內部】");
}

/** 一列品項要用哪個名字：商品名優先，沒有才退規格名 */
function itemName(it: TitleItemLike): string {
  return cleanCampaignText(it.product_name) || cleanCampaignText(it.variant_name) || "";
}

function distinctItemNames(items: TitleItemLike[]): string[] {
  const out: string[] = [];
  for (const it of items) {
    const n = itemName(it);
    if (n && !out.includes(n)) out.push(n);
  }
  return out;
}

/**
 * 內部 sentinel 團底下的單「實際上是哪一條路來的」。
 *
 * 那些單全部掛在共用假團 `__INTERNAL_RESTOCK__`「【內部】補貨申請」下面
 * （共用是刻意的：全站 10+ 處濾網現成，另開新 sentinel 漏一處就會外顯給客人）。
 * 代價是後台訂單明細的「開團」欄會照實印出那個名字 —— 一張現貨直配單寫著
 * 「【內部】補貨申請」，店員會以為是補貨（2026-08-16 回報）。
 *
 * 來源判斷一律用 **order_no 前綴**，不要用 notes 內文比對：
 * 單號是建單時就決定、之後不會被編輯，notes 是自由文字會被人改掉。
 */
export type InternalOrderSource = { label: string; hint: string };

export function internalOrderSource(orderNo: string | null | undefined): InternalOrderSource | null {
  const no = (orderNo ?? "").trim();
  if (!no) return null;
  if (no.startsWith("WS-")) {
    return { label: "🛒 現場銷售", hint: "門市臨櫃結帳，當場交貨扣庫存（開單即完成）" };
  }
  if (no.startsWith("SP-")) {
    return { label: "🤝 現貨直配", hint: "店內現貨直接配給客人（待取，取貨時才扣庫存收款）" };
  }
  if (no.startsWith("RR-")) {
    return { label: "📦 補貨申請", hint: "店家跟總倉叫貨；貨到店後掛在【內部】店名下" };
  }
  if (no.startsWith("OV-")) {
    return { label: "📥 收貨多給", hint: "到貨超過訂單需求的量，沒有主人先掛在店內" };
  }
  if (/-TF\d+$/.test(no)) {
    return { label: "↔ 轉單轉入", hint: "從別張訂單轉過來的品項" };
  }
  if (/-INT\d+$/.test(no)) {
    return { label: "🏪 內部叫貨", hint: "店家自己下的內部單" };
  }
  return null;
}

/**
 * 單號的「給人看」版本。
 *
 * 內部共用假團底下的單號長這樣：`__INTERNAL_RESTOCK__-TF0497`。前綴是帳本代號，
 * 店員看不懂也不該看到（2026-08-24 回報：互助板上印出來整串沒人知道是什麼），
 * 但尾碼 TF0497 是店裡真的會拿來對帳的號 —— 所以只砍前綴、留尾碼並補上中文。
 * 一般單號（GRP-…、RR-…、AB-…）原樣回傳。
 */
export function shortOrderNo(orderNo: string | null | undefined): string {
  const no = (orderNo ?? "").trim();
  if (!no) return "—";
  const m = /^__[A-Z_]+__-(.+)$/.exec(no);
  if (!m) return no;
  const tail = m[1];
  return /^TF\d+$/i.test(tail) ? `轉單 ${tail}` : tail;
}

export function orderCardTitle(order: TitleOrderLike): string {
  const campaign = cleanCampaignText(order.campaign_name);
  if (!isInternalCampaign(order)) return campaign || "訂單";

  const items = order.items ?? [];
  // 斷貨 / 取消的品項不拿來當標題（那些行卡片上已經畫成刪除線）；
  // 整張都被取消時退回用全部品項，才不會變成沒有標題的空卡片。
  const active = items.filter((it) => !["cancelled", "expired"].includes(String(it.status ?? "")));
  const names = distinctItemNames(active.length > 0 ? active : items);

  if (names.length === 0) return campaign || "訂單";
  if (names.length <= 2) return names.join("、");
  return `${names[0]} 等 ${names.length} 項`;
}

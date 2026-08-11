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

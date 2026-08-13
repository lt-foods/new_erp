// Map known Postgres RAISE EXCEPTION messages → Chinese.
// Add patterns as more surface in production.

import { campaignStatusLabel } from "@/lib/campaignStatus";
import { orderStatusLabel } from "@/lib/orderStatus";

type Rule = { pattern: RegExp; render: (m: RegExpMatchArray) => string };

const TRANSFER_STATUS_ZH: Record<string, string> = {
  draft: "草稿",
  confirmed: "已確認",
  shipped: "已出貨",
  received: "已收到",
  closed: "已結案",
  cancelled: "已取消",
};
const tStatus = (s: string) => TRANSFER_STATUS_ZH[s] ?? s;

const RESTOCK_STATUS_ZH: Record<string, string> = {
  pending: "待處理",
  approved_transfer: "已派貨",
  approved_pr: "已轉採購",
  shipped: "已出貨",
  received: "已收貨",
  rejected: "已拒絕",
  cancelled: "已取消",
};
const restockStatus = (s: string) => RESTOCK_STATUS_ZH[s] ?? s;

const cStatus = campaignStatusLabel;
const oStatus = orderStatusLabel;

const RULES: Rule[] = [
  {
    // 新版（含 SKU）：'Insufficient stock for SKU <code> (<name>): available=X, required=Y'
    pattern: /Insufficient stock for SKU\s+(\S+)\s*(?:\(([^)]*)\))?\s*:\s*available=([\d.]+),\s*required=([\d.]+)/i,
    render: (m) => {
      const code = m[1];
      const name = (m[2] ?? "").trim();
      const skuLabel = name ? `${code}（${name}）` : code;
      return `庫存不足：${skuLabel} 總倉只剩 ${fmt(m[3])} 件，本次需要 ${fmt(m[4])} 件`;
    },
  },
  {
    // 舊版（向後相容，無 SKU 資訊）
    pattern: /Insufficient stock:\s*available=([\d.]+),\s*required=([\d.]+)/i,
    render: (m) => `庫存不足：總倉只剩 ${fmt(m[1])} 件，本次需要 ${fmt(m[2])} 件`,
  },
  {
    pattern: /Insufficient points:\s*available=([\d.]+),\s*required=([\d.]+)/i,
    render: (m) => `點數不足：可用 ${fmt(m[1])} 點，本次需要 ${fmt(m[2])} 點`,
  },
  {
    pattern: /Insufficient wallet:\s*available=([\d.]+),\s*required=([\d.]+)/i,
    render: (m) => `儲值金不足：可用 $${fmt(m[1])}，本次需要 $${fmt(m[2])}`,
  },
  { pattern: /Outbound quantity must be positive/i, render: () => "出庫數量必須大於 0" },
  { pattern: /Inbound quantity must be positive/i, render: () => "入庫數量必須大於 0" },
  {
    pattern: /^qty must be > 0$/i,
    render: () => "數量必須大於 0（如需刪除品項請聯絡總部）",
  },
  {
    pattern: /campaign \d+ is (\w+); only open\/closed campaigns accept manual entry/i,
    render: (m) =>
      `此團狀態為「${cStatus(m[1])}」，僅「開團中」或「已收單」可以加單。`,
  },
  {
    pattern: /訂單狀態為\s+(\w+)[,，]?\s*僅\s*待確認\s*訂單可改數量/,
    render: (m) =>
      `訂單狀態為「${oStatus(m[1])}」，僅「待確認」訂單可改數量。`,
  },
  {
    pattern: /store\s+(\d+)\s+has no location_id(?:\s+mapped)?/i,
    render: (m) =>
      `分店 #${m[1]} 尚未綁定庫位（location_id 為空）。請到「分店設定」幫該店設定對應的庫位後再試。`,
  },
  {
    pattern: /source or dest store has no location_id/i,
    render: () => "來源或目的分店尚未綁定庫位，請先到「分店設定」補上。",
  },
  {
    pattern: /no locations defined for tenant/i,
    render: () => "此 tenant 尚未建立任何庫位。請先到「庫位設定」建立至少一個總倉/門市庫位。",
  },
  {
    pattern: /sku\s+(\d+)\s+allocation total\s+([\d.]+)\s+exceeds received\s+([\d.]+)/i,
    render: (m) =>
      `SKU #${m[1]} 的分店分配總和 ${fmt(m[2])} 超過實到數量 ${fmt(m[3])}，請重新分配。`,
  },
  // ===== Aid transfer 系列 =====
  {
    pattern: /aid order \d+ has no transferred_from_order_id/i,
    render: () => "找不到原源訂單（transferred_from_order_id 為空），無法派貨。",
  },
  {
    pattern: /source order \d+ has no pickup_store/i,
    render: () => "原源訂單沒有設定取貨分店，無法決定 source location。",
  },
  {
    pattern: /aid order \d+ is (\w+), only confirmed can ship/i,
    render: (m) => `此訂單目前是「${m[1]}」狀態，只有「confirmed」可以派貨。`,
  },
  {
    pattern: /no central warehouse location for tenant/i,
    render: () => "找不到總倉 location（type=central_warehouse）。請先到 locations 設定建立一個總倉。",
  },
  {
    pattern: /source and dest store share location_id/i,
    render: () => "來源店和目的店是同一個庫位，無法派貨。",
  },
  {
    pattern: /order \d+ has no aid_transfer items/i,
    render: () => "此訂單沒有任何 aid_transfer 來源的品項，無法派貨。",
  },
  {
    pattern: /order \d+ is shipping but has no terminal transfer/i,
    render: () => "此互助單是 shipping 狀態但找不到對應的派貨單（transfer），資料不一致。請聯繫工程師。",
  },
  {
    pattern: /transfer \d+ already received, cannot cancel chain/i,
    render: () => "transfer chain 中已有單據被收貨，無法整個撤回。",
  },
  {
    pattern: /transfer \d+ is (\w+), only shipped can be rejected/i,
    render: (m) => `transfer 目前是「${m[1]}」狀態，只有「shipped」可以拒收。`,
  },
  {
    pattern: /order \d+ is (\w+), only pending\/confirmed\/shipping can be cancelled/i,
    render: (m) => `訂單目前是「${m[1]}」狀態，只有 pending / confirmed / shipping 可以取消。`,
  },
  {
    pattern: /transfer \d+ is in status (\w+), expected shipped/i,
    render: (m) => `transfer 目前是「${m[1]}」狀態，預期應為「shipped」。`,
  },
  // ===== Transfer 批次 RPC 錯誤(distribute / arrive_at_hq / batch_delete) =====
  {
    pattern: /^p_transfer_ids is empty$/i,
    render: () => "請先選擇至少一筆要處理的單據。",
  },
  {
    pattern: /^not found$/i,
    render: () => "找不到此調撥單。",
  },
  {
    pattern: /^status=(\w+),\s*expected draft\/confirmed$/i,
    render: (m) => `狀態為「${tStatus(m[1])}」,只有 待審核(草稿 / 已確認) 可以配送。`,
  },
  {
    pattern: /^status=(\w+),\s*only draft can be deleted$/i,
    render: (m) => `狀態為「${tStatus(m[1])}」,只有 草稿 可以刪除。`,
  },
  // FK 違反 — 刪除 transfer 時被其他 table 引用
  {
    pattern: /update or delete on table "transfers" violates foreign key constraint "[^"]+" on table "([^"]+)"/i,
    render: (m) => {
      const tableMap: Record<string, string> = {
        picking_wave_items: "撿貨單明細",
        customer_order_items: "客戶訂單",
        member_aid_settlement: "會員互助結算",
        restock_requests: "補貨申請",
        store_monthly_settlement: "分店月結算",
        stock_movements: "庫存異動",
        transfer_items: "調撥明細",
        transfer_relationships: "調撥串接",
      };
      const zh = tableMap[m[1]] ?? m[1];
      return `無法刪除:此調撥單已被「${zh}」引用,請先撤回或解除關聯後再刪。`;
    },
  },
  {
    pattern: /^status=(\w+),\s*expected shipped$/i,
    render: (m) => `狀態為「${tStatus(m[1])}」,只有 已出貨 可以到倉。`,
  },
  {
    pattern: /^source_location\s+(\d+)\s+is not HQ\s+(\d+)$/i,
    render: (m) => `來源庫位 #${m[1]} 不是總倉(#${m[2]}),不可批次配送。`,
  },
  // ===== rpc_return_aid_order (#234) =====
  {
    pattern: /order \d+ is not an aid order/i,
    render: () => "這不是互助單，不能用「退單（已收貨）」。一般訂單請用「退訂單」退回總倉。",
  },
  {
    pattern: /aid order \d+ is \w+ \(not yet received\)/i,
    render: () => "此互助單尚未收貨，請用「取消」（收貨前撤回），不是退單。",
  },
  {
    pattern: /aid order \d+ already completed \(picked up\)/i,
    render: () => "此互助單已取貨、貨已不在店，需先處理顧客退貨；本退單僅適用「已收貨未取貨」。",
  },
  {
    pattern: /aid order \d+ status=\w+ cannot be returned \(expected ready\)/i,
    render: () => "此互助單目前狀態無法退單（僅「已收貨未取貨」可退）。",
  },
  {
    pattern: /no received transfer found for aid order \d+/i,
    render: () => "找不到此互助單已收貨的調撥單，無法退單（資料不一致，請聯繫工程師）。",
  },
  // ===== rpc_create_order_return =====
  {
    pattern: /invalid p_movement_type\s+(\S+)\s*\(must be customer_return or damage\)/i,
    render: (m) => `退貨類型「${m[1]}」不合法，只能是「一般退貨」或「破損」。`,
  },
  // ===== rpc_delete_campaign（開團刪除守門） =====
  {
    // 舊訊息（僅 draft 可刪）向後相容保留
    pattern: /campaign \d+ is (\w+), only draft can be deleted/i,
    render: (m) =>
      `此開團目前為「${cStatus(m[1])}」，只有「草稿」可以刪除。`,
  },
  {
    pattern: /campaign \d+ is open, cannot delete/i,
    render: () => "「開團中（上架）」的開團無法刪除，請先結單或取消後再刪除。",
  },
  {
    pattern: /campaign \d+ has \d+ orders?, cannot delete/i,
    render: () => "此開團已有顧客訂單，無法刪除。請先取消相關訂單，或改用「批次取消」。",
  },
  {
    pattern: /campaign \d+ still referenced by other records, cannot delete/i,
    render: () =>
      "此開團仍被其他資料（如採購單／撿貨波）參照，無法刪除。請先解除關聯後再試。",
  },
  {
    pattern: /campaign \d+ not found/i,
    render: () => "找不到此開團（可能已被刪除）。",
  },
  // ===== rpc_merge_member（會員合併守門） =====
  {
    // 新版（20260714000070+）：只有同 (團, 頻道, 訂單類型) 兩邊都有進行中訂單才擋
    pattern: /merge would collide: source \d+ and target \d+ both have an active order in the same campaign\/channel, cannot merge/i,
    render: () =>
      "兩筆會員在「同一團、同一頻道」都有進行中的訂單，無法自動合併（會撞單）。請先把其中一筆的該訂單處理掉（取消／轉單）後再合併。",
  },
  {
    // 舊版守門（20260714000070 之前）：目標(已綁 LINE)會員有任何訂單就擋。保留以相容舊部署的錯誤訊息。
    pattern: /target member \d+ already has orders, cannot merge/i,
    render: () =>
      "目標（已綁 LINE）會員已經有訂單，無法把另一筆併進來。此功能僅支援把（可含訂單的）未綁 LINE 會員，併入「尚無訂單」的 LINE 會員；請改選一個沒有訂單的會員作為合併目標。",
  },
  {
    // 舊版守門（20260618000030 之前）：來源有訂單就擋。保留以相容舊部署的錯誤訊息。
    pattern: /source member \d+ has orders, cannot merge/i,
    render: () =>
      "來源會員仍有訂單，無法合併。請先處理（取消／轉移）來源會員的訂單後再合併。",
  },
  {
    pattern: /source member \d+ is already bound to LINE/i,
    render: () => "來源會員已綁定 LINE，請改以「未綁 LINE 的那筆」為來源。",
  },
  {
    pattern: /source member \d+ is already merged/i,
    render: () => "來源會員已經合併過了。",
  },
  // ===== rpc_member_gdpr_delete / rpc_member_purge（會員刪除） =====
  {
    pattern: /member \d+ is a store-internal member, cannot purge/i,
    render: () => "此為分店內部會員（補貨／叫貨用），無法刪除。",
  },
  {
    pattern: /member \d+ not found/i,
    render: () => "找不到此會員（可能已被刪除）。",
  },
  // ===== rpc_register_damage =====
  {
    pattern: /damage_qty must be > 0/i,
    render: () => "損壞數量必須大於 0。",
  },
  {
    pattern: /transfer_item\s+(\d+)\s+not found/i,
    render: (m) => `找不到調撥明細 #${m[1]}。`,
  },
  {
    pattern: /transfer\s+(\d+)\s+status=(\w+),\s*only received\/closed allows damage register/i,
    render: (m) => `調撥單 #${m[1]} 狀態為「${tStatus(m[2])}」,只有 已收到 / 已結案 可登記損壞。`,
  },
  {
    pattern: /damage_qty\s+([\d.]+)\s+exceeds remaining\s+\(qty_received\s+([\d.]+)\s+-\s+already_damaged\s+([\d.]+)\)/i,
    render: (m) =>
      `損壞數量 ${fmt(m[1])} 超過可登記量 ${fmt(Number(m[2]) - Number(m[3]) + "")}(已收 ${fmt(m[2])}、已登記損壞 ${fmt(m[3])})。`,
  },
  // ===== rpc_delete_product（商品刪除守門） =====
  {
    pattern: /product \d+ is active, cannot delete/i,
    render: () => "商品「上架中」無法刪除，請先將商品下架後再刪除。",
  },
  {
    pattern: /product \d+ has campaigns, cannot delete/i,
    render: () => "此商品仍有關聯開團，無法刪除。請先刪除或取消相關開團後再試。",
  },
  {
    pattern: /product \d+ has orders, cannot delete/i,
    render: () => "此商品已有顧客訂單，無法刪除。",
  },
  {
    pattern: /product \d+ still referenced by other records, cannot delete/i,
    render: () =>
      "此商品仍被其他資料（如庫存／採購／調撥）參照，無法刪除。請先解除關聯後再試。",
  },
  // ===== rpc_delete_restock_request（補貨申請刪除守門） =====
  {
    pattern: /restock request \d+ is (\w+), only pending can be deleted/i,
    render: (m) => `此補貨申請狀態為「${restockStatus(m[1])}」，只有「待處理」可以刪除。`,
  },
  {
    pattern: /permission denied: role (\w+) cannot delete restock request/i,
    render: (m) => `權限不足：角色「${m[1]}」無法刪除補貨申請。`,
  },
  {
    pattern: /store role can only delete request for own store/i,
    render: () => "門市角色只能刪除自己店的補貨申請。",
  },
  {
    pattern: /restock request \d+ already has picking waves, cannot delete/i,
    render: () => "此補貨申請已建立撿貨單，無法刪除。請先處理撿貨單後再試。",
  },
  {
    pattern: /restock request \d+ (?:internal order )?still referenced(?: by other records)?, cannot delete/i,
    render: () => "此補貨申請仍被其他資料參照，無法刪除。請先解除關聯後再試。",
  },
  {
    pattern: /restock request \d+ not found/i,
    render: () => "找不到此補貨申請（可能已被刪除）。",
  },
  {
    pattern: /product \d+ not found/i,
    render: () => "找不到此商品（可能已被刪除）。",
  },
  // ===== rpc_delete_free_transfer（自由轉貨刪除守門） =====
  {
    pattern: /permission denied: role (\w+) cannot delete free transfer/i,
    render: (m) => `權限不足：角色「${m[1]}」無法刪除自由轉貨。`,
  },
  {
    pattern: /transfer \d+ is not a free transfer \((?:type=)?(\w+)\), cannot delete/i,
    render: () => "此調撥單不是自由轉貨（例如互助接力單、總倉派貨），無法在此刪除。",
  },
  {
    pattern: /store role can only delete free transfer involving own store/i,
    render: () => "門市角色只能刪除自己店參與的自由轉貨。",
  },
  {
    pattern: /transfer \d+ is (\w+), only draft can be deleted/i,
    render: (m) => `此自由轉貨狀態為「${tStatus(m[1])}」，只有「草稿」（總倉配送前）可以刪除。`,
  },
  {
    pattern: /transfer \d+ already referenced by picking waves, cannot delete/i,
    render: () => "此調撥單已被撿貨單引用，無法刪除。",
  },
  {
    pattern: /transfer \d+ still referenced by other records, cannot delete/i,
    render: () => "此調撥單仍被其他資料參照，無法刪除。請先解除關聯後再試。",
  },
  {
    pattern: /transfer (\d+) not found/i,
    render: () => "找不到此調撥單（可能已被刪除）。",
  },
  // ===== rpc_unmerge_member（復原合併） =====
  {
    pattern: /^merge_not_found(?::|$)/i,
    render: () => "找不到這筆合併紀錄（可能已被其他人復原）。請關掉視窗重開一次。",
  },
  {
    pattern: /^merge_already_reverted(?::|$)/i,
    render: () => "這筆合併已經復原過了。請關掉視窗重開一次看最新狀態。",
  },
  {
    pattern: /^merge_state_changed(?::|$)/i,
    render: () =>
      "來源會員目前的狀態已經不是「被併入此會員」（可能已被刪除，或又被合併到別人身上），無法自動復原。請聯絡工程師處理。",
  },
  {
    pattern: /^unmerge_needs_manual(?::|$)/i,
    render: () =>
      "這筆合併在「復原」功能上線前完成，且動到了點數／儲值／卡片，沒有足夠資料可以安全還原，請聯絡工程師處理。",
  },
  {
    pattern: /^unmerge_would_collide(?::|$)/i,
    render: () =>
      "來源會員身上已經有同一團、同通路的有效訂單，訂單搬回去會撞單。請先處理掉其中一筆再復原。",
  },
  {
    pattern: /^unmerge_balance_insufficient:\s*目標會員目前(點數|儲值金)\s*([\d.]+)\s*少於當初併入的\s*([\d.]+)/,
    render: (m) =>
      `無法復原：本會員目前的${m[1]}只有 ${fmt(m[2])}，少於當初併入的 ${fmt(m[3])}，扣回去會變負數。`
      + `請先確認這筆${m[1]}的去向並手動調整後再復原。`,
  },
  // ===== 店家守衛（rpc_record_pickup / rpc_bind_store_line_follower） =====
  {
    // 訊息本體已是中文（如「此訂單的取貨店是「三峽店」…」），只把機器前綴拿掉
    pattern: /^wrong_store:\s*(.+)$/i,
    render: (m) => m[1],
  },
  // ===== 撿貨單號碼衝突(同秒多筆提交時的 race) =====
  {
    pattern: /duplicate key value violates unique constraint "picking_waves_tenant_id_wave_code_key"/i,
    render: () => "撿貨單號碼衝突（同時有多筆提交）。請稍候 1-2 秒後重試一次即可。",
  },
  // 通用 unique 衝突 fallback,把 raw error 中文化
  {
    pattern: /duplicate key value violates unique constraint "([^"]+)"/i,
    render: (m) => `資料重複衝突(${m[1]})，請重試或聯繫工程師。`,
  },
];

function fmt(s: string): string {
  const n = Number(s);
  if (!Number.isFinite(n)) return s;
  return Number.isInteger(n) ? String(n) : String(n);
}

// supabase-js's PostgrestError shape varies across SDK versions: <=2.104 returns
// a plain object { message, details, hint, code }; >=2.105 returns an Error
// subclass. Plus auth/fetch wrappers throw { error: ... }. Extract a usable
// string from any of these instead of letting String(obj) produce "[object Object]".
function extractErrorMessage(raw: unknown): string {
  if (raw == null) return String(raw);
  if (typeof raw === "string") return raw;
  if (raw instanceof Error) return raw.message;
  if (typeof raw === "object") {
    const o = raw as Record<string, unknown>;
    if (typeof o.message === "string" && o.message) return o.message;
    if (typeof o.error === "string" && o.error) return o.error;
    if (o.error && typeof o.error === "object") {
      const inner = o.error as Record<string, unknown>;
      if (typeof inner.message === "string" && inner.message) return inner.message;
    }
    try {
      const j = JSON.stringify(o);
      if (j && j !== "{}") return j;
    } catch {
      /* circular — fall through */
    }
  }
  return String(raw);
}

export function translateRpcError(raw: unknown): string {
  const msg = extractErrorMessage(raw);
  for (const r of RULES) {
    const m = msg.match(r.pattern);
    if (m) return r.render(m);
  }
  return msg;
}

// Map known Postgres RAISE EXCEPTION messages → Chinese.
// Add patterns as more surface in production.

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
    render: () => "訂單是 shipping 狀態但找不到對應的 transfer，資料不一致。請聯繫工程師。",
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
  // ===== rpc_create_order_return =====
  {
    pattern: /invalid p_movement_type\s+(\S+)\s*\(must be customer_return or damage\)/i,
    render: (m) => `退貨類型「${m[1]}」不合法，只能是「一般退貨」或「破損」。`,
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

export function translateRpcError(raw: unknown): string {
  const msg = raw instanceof Error ? raw.message : String(raw);
  for (const r of RULES) {
    const m = msg.match(r.pattern);
    if (m) return r.render(m);
  }
  return msg;
}

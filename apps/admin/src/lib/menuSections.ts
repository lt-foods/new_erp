// 公告 / 教學中心的「功能分類」— 對齊左側 NAV（apps/admin/src/app/(protected)/layout.tsx）。
// 教學影片與優化更新都依這份清單的「個別功能項」分組，方便後台/分店人員依功能查看。
// 新增功能時，這裡加一個 key + label，公告 entry 再用該 key 掛上即可。

export type MenuKey =
  | "dashboard"
  | "campaigns" | "products" | "suppliers"
  | "region-preference" | "member-analytics" | "product-analytics"
  | "orders" | "pickup" | "inbound" | "members" | "transfers" | "restock" | "mutual-aid"
  | "pr" | "po" | "inventory" | "reorder-rules" | "stocktake"
  | "hq-inbox" | "receiving" | "picking"
  | "receivables" | "settlement"
  | "candidates" | "calendar"
  | "staff" | "stores" | "fb-pages"
  | "general";

export type MenuItem = { key: MenuKey; label: string };
export type MenuGroup = { group: string | null; items: MenuItem[] };

// 順序與分組刻意對齊左側選單；最後加一個「入門 / 通用」收沒有對應單一功能的內容。
export const MENU_GROUPS: MenuGroup[] = [
  { group: null, items: [{ key: "dashboard", label: "儀表板" }] },
  {
    group: "核心業務",
    items: [
      { key: "campaigns", label: "開團" },
      { key: "products", label: "商品" },
      { key: "suppliers", label: "供應商" },
    ],
  },
  {
    group: "分店業務",
    items: [
      { key: "orders", label: "訂單" },
      { key: "pickup", label: "取貨" },
      { key: "inbound", label: "收貨" },
      { key: "members", label: "會員" },
      { key: "transfers", label: "內部調撥" },
      { key: "restock", label: "補貨申請" },
      { key: "mutual-aid", label: "互助交流板" },
    ],
  },
  {
    group: "進銷存",
    items: [
      { key: "pr", label: "請購單" },
      { key: "po", label: "採購單" },
      { key: "inventory", label: "庫存總覽" },
      { key: "reorder-rules", label: "補貨規則" },
      { key: "stocktake", label: "盤點" },
    ],
  },
  {
    group: "倉儲 (WMS)",
    items: [
      { key: "hq-inbox", label: "總倉收件匣" },
      { key: "receiving", label: "進貨待辦" },
      { key: "picking", label: "派貨工作台" },
    ],
  },
  {
    group: "財務",
    items: [
      { key: "receivables", label: "HQ 應收" },
      { key: "settlement", label: "月結算" },
    ],
  },
  {
    group: "分析",
    items: [
      { key: "region-preference", label: "地區偏好" },
      { key: "member-analytics", label: "會員分析" },
      { key: "product-analytics", label: "商品分析" },
    ],
  },
  {
    group: "社群選品",
    items: [
      { key: "candidates", label: "候選池" },
      { key: "calendar", label: "週曆" },
    ],
  },
  {
    group: "設定",
    items: [
      { key: "staff", label: "員工管理" },
      { key: "stores", label: "門市" },
      { key: "fb-pages", label: "FB 粉絲團" },
    ],
  },
  {
    group: "入門 / 通用",
    items: [{ key: "general", label: "入門 / 通用" }],
  },
];

// 平攤成依序的功能清單
export const MENU_ITEMS: MenuItem[] = MENU_GROUPS.flatMap((g) => g.items);

export const MENU_LABEL: Record<MenuKey, string> = Object.fromEntries(
  MENU_ITEMS.map((m) => [m.key, m.label]),
) as Record<MenuKey, string>;

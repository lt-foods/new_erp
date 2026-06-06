/**
 * 全站單一設定來源。改品牌、網域、定價、FAQ 都改這裡一處。
 * （行銷／定價策略全文見 docs/GTM-定價-SEO-行銷策略.md）
 */

/** 品牌名（改這裡全站替換：頁面、OG 圖、JSON-LD 一起換） */
export const BRAND_NAME = "揪好團";

/** 正式網域後改這裡（SEO 絕對網址、canonical、sitemap 都讀這個）。目前為 placeholder，待確認網域 */
export const SITE_URL = "https://www.jiohaotuan.com";

export const TAGLINE = "開團到對帳，一條龍搞定";
export const SUB_TAGLINE = "團購店與加盟總部專用的營運系統";

export const CONTACT = {
  demoUrl: "#demo",
  trialUrl: "#trial",
  email: "hello@jiohaotuan.com",
  /** 在地 SEO（桃園總部） */
  region: "桃園",
  country: "TW",
};

export type Plan = {
  id: string;
  name: string;
  audience: string;
  /** 月繳價（新台幣／月）；null = 客製報價 */
  monthly: number | null;
  /** 年繳價（新台幣／年）；null = 客製報價 */
  yearly: number | null;
  highlight?: boolean;
  badge?: string;
  limits: string[];
  features: string[];
  cta: string;
};

export const PLANS: Plan[] = [
  {
    id: "starter",
    name: "Starter 團購主",
    audience: "個人團購主 / 單店起步",
    monthly: 590,
    yearly: 5900,
    limits: ["1 家門市", "月訂單 800 張", "2 個員工帳號", "2,000 位會員"],
    features: [
      "開團 / 商品 / 文案自動生成",
      "LINE 社群 +1 接龍下單",
      "會員 App（QR / 訂單查詢 / 取貨確認）",
      "訂單 / 取貨 / 退貨",
      "基礎庫存與報表",
    ],
    cta: "免費試用 14 天",
  },
  {
    id: "pro",
    name: "Pro 成長店",
    audience: "穩定出單的單店",
    monthly: 1680,
    yearly: 16800,
    highlight: true,
    badge: "最受歡迎",
    limits: ["1 家門市", "月訂單 5,000 張", "8 個員工帳號", "20,000 位會員"],
    features: [
      "Starter 全部功能",
      "撿貨 / 派貨工作台（波次撿貨）",
      "採購 / 供應商整合",
      "完整庫存 / 盤點 / 補貨規則",
      "錢包餘額 / 點數",
      "推播通知 + 電子發票",
    ],
    cta: "免費試用 14 天",
  },
  {
    id: "chain",
    name: "Chain 連鎖",
    audience: "3–10 店小型連鎖",
    monthly: 4980,
    yearly: 49800,
    limits: ["3–10 家門市", "月訂單 30,000 張", "30 個員工帳號", "會員不限"],
    features: [
      "Pro 全部功能",
      "多店總部統管 / 跨店調撥",
      "加盟拆帳 / 權限分層",
      "應付帳款 / 零用金",
      "資料匯出（唯讀 API）",
    ],
    cta: "預約 Demo",
  },
  {
    id: "enterprise",
    name: "Enterprise 加盟總部",
    audience: "10 店以上加盟體系",
    monthly: null,
    yearly: null,
    limits: ["門市不限", "訂單不限", "帳號不限", "白標支援"],
    features: [
      "Chain 全部功能",
      "白標（自有 LOGO / 網域 / OA）",
      "完整開放 API",
      "專屬客戶成功窗口 + SLA",
      "上線陪跑與客製",
    ],
    cta: "聯絡我們",
  },
];

/** 年繳折數說明（送 2 個月 ≈ 83 折） */
export const ANNUAL_NOTE = "年繳省 2 個月（約 83 折）";

export type Feature = { title: string; desc: string; icon: string };

export const FEATURES: Feature[] = [
  {
    icon: "🛒",
    title: "開團・接龍下單",
    desc: "LINE 社群 +1 接龍、小幫手、會員 App 三種下單來源自動進系統，告別手抄漏單。商品文案一鍵生成。",
  },
  {
    icon: "📦",
    title: "撿貨・派貨 WMS",
    desc: "到貨自動分配、波次撿貨一鍵成單，跨團邊界控制不撿錯。出貨不再一箱一箱對。",
  },
  {
    icon: "📊",
    title: "庫存・採購",
    desc: "庫存單一真實來源（SSOT）、盤點、補貨規則、供應商整合，進銷存一條龍。",
  },
  {
    icon: "📱",
    title: "會員 App / LIFF",
    desc: "顧客在 LINE 內查訂單、確認取貨、看錢包餘額與點數，客服電話少一半。",
  },
  {
    icon: "🏪",
    title: "加盟總部統管",
    desc: "一個後台管 100 家門市，跨店調撥、加盟拆帳、權限分層（多租戶 RLS）。",
  },
  {
    icon: "🧾",
    title: "對帳・發票",
    desc: "訂單、退貨、錢包、應付帳款全打通，整合電子發票，月底對帳不再加班。",
  },
];

export type Pain = { problem: string; solution: string };

export const PAINS: Pain[] = [
  { problem: "接龍 200 則留言，一則一則數", solution: "+1 留言自動進訂單，不漏單" },
  { problem: "Excel 對團購帳，月底加班", solution: "訂單到錢包全打通，自動對帳" },
  { problem: "撿錯一箱貨，整團客訴", solution: "波次撿貨一鍵分配，撿錯歸零" },
  { problem: "客人一直問「我的單到了沒」", solution: "會員 App 自己查、自己確認取貨" },
  { problem: "開分店，系統就要重做一套", solution: "總部一個後台，多店統管即開即用" },
];

export type Faq = { q: string; a: string };

export const FAQS: Faq[] = [
  {
    q: "這套系統適合個人團購主嗎？",
    a: "適合。Starter 方案就是為個人團購主與單店起步設計，月費 NT$590 起，含開團接龍、會員 App、訂單取貨，免綁卡試用 14 天。",
  },
  {
    q: "和一般的接龍表單工具差在哪？",
    a: "表單工具只解決「收單」，我們是團購全鏈路：開團、接龍下單、採購、到貨、波次撿貨、取貨核銷、退貨、錢包點數、對帳、電子發票，並原生支援多店與加盟總部。",
  },
  {
    q: "支援 LINE 下單嗎？",
    a: "支援。顧客可在 LINE 社群以 +1 接龍留言下單，也可用小幫手或會員 App（LINE LIFF）下單，三種來源都自動匯入系統。",
  },
  {
    q: "年繳和月繳怎麼算？",
    a: "年繳等於只付 10 個月、用 12 個月（約 83 折，省 2 個月）。例如 Pro 月繳 NT$1,680，年繳 NT$16,800。",
  },
  {
    q: "我有很多加盟店，能統一管理嗎？",
    a: "可以。Chain 方案支援 3–10 店總部統管、跨店調撥與加盟拆帳；10 店以上請洽 Enterprise，提供白標、開放 API 與專屬 SLA。",
  },
  {
    q: "舊的會員和商品資料能搬過來嗎？",
    a: "可以。提供資料搬遷服務，從 Excel 或舊系統匯入會員、商品與歷史訂單，並安排上線陪跑。",
  },
];

export const SEO_KEYWORDS = [
  "團購系統",
  "社群團購系統",
  "團購軟體",
  "開團系統",
  "團購 ERP",
  "團購店 POS",
  "團購接龍系統",
  "團購結單系統",
  "LINE 團購系統",
  "LINE 接龍",
  "團購對帳",
  "團購撿貨",
  "團購庫存管理",
  "加盟團購系統",
  "多店團購管理",
  "團購會員 App",
];

// 分店在畫面／紙上的固定顯示順序。
//
// 老闆 2026-08-17 親自列的順序（共 16 間）：
//   三峽、中和、文山、永和、忠順、環球、平鎮、古華、
//   林口、南平、泰山、湖口、經國、松山、龍潭、全民
// 那是他撿貨、送貨時腦子裡的順序；原本三個頁面各自用 store_code 的 localeCompare 排，
// 跟他心裡的順序完全對不上，同一家店在三頁還會在不同位置。
//
// ⛔⛔ 這支**只排序、絕對不過濾**。
//   少一欄 ＝ 樓下少撿一家店的貨，是這個專案最不能出的事
//   （PR #744 的根因就是把勾選悄悄丟掉）。comparator 這種形狀本來就沒辦法把東西弄不見，
//   而下面 compareStoreOrder 對「查不到名次」的店也只是往後排，不是丟掉。
//
// ⭐ 對不上名次的（code 打錯、新開的分店、已經收掉的店）→ **一律排到最後面**，
//   彼此之間維持原本的 store_code 排序。這是刻意的設計：
//   這張表的 code 是人工對出來的，本來就可能有錯 —— 錯的代價必須是「排在後面」，
//   ⛔ 不可以是「不見了」。
//
// ⭐ 比對順序是 **code 先比、比不到再比 name**，兩邊都先做正規化。
//   code 萬一對錯，名稱還是一條救得回來的線。
//
// 順序表要改就改這裡一處：三個呼叫端（撿貨草稿的編輯＋列印、派貨工作台矩陣、
// 列印撿貨單）import 的是同一份，⛔ 不要各自複製一份，否則以後改順序一定會漏改。

type StoreOrderEntry = { code: string; name: string };

/**
 * 老闆 2026-08-17 指定的順序。**陣列位置就是名次**，所以順序要改＝直接搬動這幾列。
 *
 * code / name 與 `docs/GUIDE-社群推廣連結.md` 的門市對照表逐項核對過（PR #607 那份）。
 *
 * ⓘ 這裡**故意只列老闆講的那 16 間**。他沒列到的（四號、板橋、萬華、淡水）都是
 *   已經收掉或不在這條撿貨動線上的店 —— 它們會自動落到最後面，
 *   ⛔ 但一樣照常顯示，不會被藏起來。
 */
const STORE_ORDER: readonly StoreOrderEntry[] = [
  { code: "LELE-三峽", name: "三峽店" },
  { code: "LELE-中和", name: "中和店" },
  { code: "LELE-文山", name: "文山店" },
  { code: "LELE-永和", name: "永和店" },
  { code: "LELE-忠順", name: "忠順店" },
  { code: "LELE-環球", name: "環球店" },
  { code: "S001", name: "平鎮店" },
  { code: "LELE-古華", name: "古華店" },
  { code: "LELE-林口", name: "林口店" },
  { code: "LELE-南平", name: "南平店" },
  { code: "LELE-泰山", name: "泰山店" },
  { code: "LELE-湖口", name: "湖口店" },
  { code: "LELE-經國", name: "經國店" },
  { code: "S002", name: "松山店" },
  { code: "LELE-龍潭", name: "龍潭店" },
  { code: "QM-全民", name: "全民" },
];

/** 對不上名次的店排這個位置 ＝ 最後面。刻意用有限的數字，見 compareStoreOrder 的說明。 */
const UNRANKED = Number.MAX_SAFE_INTEGER;

/**
 * 比對前的正規化：去掉所有空白 + 轉大寫。
 *
 * `\s` 在 JS 正則含全形空白 U+3000 與 BOM，所以貼進資料庫時多打的空白都吃得掉。
 * 轉大寫是為了 `S001` / `s001` 這種純英數 code（中文字不受影響）。
 */
function normalizeStoreKey(v: string | null | undefined): string {
  return (v ?? "").replace(/\s+/g, "").toUpperCase();
}

/**
 * 正規化後的 key → 名次。
 *
 * ⭐ 分三輪由硬到軟建表：先全部的 code、再全部的全名、最後去掉「店」的簡稱。
 *   同一個 key 只認第一次登記的。這樣萬一哪天新增的店讓別名撞在一起，
 *   保證是「某家店的正牌 code」贏，⛔ 不會被別家的簡稱蓋掉。
 *   （今天這 16 間的 code／全名／簡稱彼此都不重複，這是給未來的護欄。）
 */
const RANK_BY_KEY: ReadonlyMap<string, number> = (() => {
  const m = new Map<string, number>();
  const passes: ((s: StoreOrderEntry) => string)[] = [
    (s) => s.code,
    (s) => s.name,
    (s) => s.name.replace(/店$/, ""), // 老闆列的是「三峽」，資料庫裡是「三峽店」
  ];
  for (const pick of passes) {
    STORE_ORDER.forEach((s, i) => {
      const k = normalizeStoreKey(pick(s));
      if (k && !m.has(k)) m.set(k, i);
    });
  }
  return m;
})();

/**
 * 這家店排第幾（0 起算）。對不上 → UNRANKED（排最後面）。
 *
 * ⭐ code 先比、比不到再比 name。
 */
export function storeOrderRank(
  code: string | null | undefined,
  name: string | null | undefined,
): number {
  return (
    RANK_BY_KEY.get(normalizeStoreKey(code)) ?? RANK_BY_KEY.get(normalizeStoreKey(name)) ?? UNRANKED
  );
}

/**
 * 三個頁面共用的分店排序比較器。
 *
 * 參數攤成四個而不是收成物件，是因為三個呼叫端的欄位名不一樣
 * （草稿是 `code` / `name`，另外兩頁是 `store_code` / `store_name`），
 * 攤開之後每個呼叫端都只是改**一行**，看 diff 一眼就知道只動了排序。
 *
 * ⚠ 名次比大小、**不相減**：現在 UNRANKED 是有限數字，相減沒事；
 *   但哪天有人順手改成 Infinity，`Infinity - Infinity` 就是 NaN ——
 *   比較器回 NaN 是未定義行為，整排順序會亂掉而且完全看不出來。
 *   一開始就寫成大小比，這個坑就永遠踩不到。
 */
export function compareStoreOrder(
  aCode: string | null | undefined,
  aName: string | null | undefined,
  bCode: string | null | undefined,
  bName: string | null | undefined,
): number {
  const ra = storeOrderRank(aCode, aName);
  const rb = storeOrderRank(bCode, bName);
  if (ra !== rb) return ra < rb ? -1 : 1;
  // 名次一樣 ＝ 兩家都對不上名次（或資料重複）→ 退回原本的 code 排序，
  // 至少維持「同一份資料排出來永遠一樣」。
  return (aCode ?? "").localeCompare(bCode ?? "");
}

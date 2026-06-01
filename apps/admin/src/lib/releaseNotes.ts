// 系統更新公告 (Release Notes)
//
// 新增一則公告：在陣列「最前面」加一筆（最新的放最上面）。
// id 必須唯一且只增不減（建議用日期 + 流水號），它同時是「使用者已讀/不再顯示」
// 的判斷依據 —— 只要最新一筆的 id 跟使用者上次勾選「不再顯示」的 id 不同，
// 公告就會再次自動跳出、鈴鐺也會亮紅點。

export type ReleaseTag = "feature" | "improvement" | "fix";

export type ReleaseNote = {
  /** 唯一識別碼，只增不減，例如 "2026-06-01"。同時作為已讀判斷依據。 */
  id: string;
  /** 顯示用日期 */
  date: string;
  /** 公告標題 */
  title: string;
  /** 條列內容 */
  items: { tag: ReleaseTag; text: string }[];
};

// 最新的放最前面
export const RELEASE_NOTES: ReleaseNote[] = [
  {
    id: "2026-06-01",
    date: "2026-06-01",
    title: "選品週曆優化 & 全新更新公告",
    items: [
      { tag: "feature", text: "右上角新增「更新公告」鈴鐺，可隨時點開查看歷史更新；有新公告時會自動跳出並顯示紅點。" },
      { tag: "improvement", text: "選品週曆卡片的商品名稱過長時會收成兩行，滑鼠移上去即可顯示完整內文。" },
    ],
  },
];

/** 最新一則公告（陣列第一筆） */
export const LATEST_RELEASE: ReleaseNote | undefined = RELEASE_NOTES[0];

/** localStorage key：儲存使用者按下「不再顯示」時最新公告的 id */
export const RELEASE_NOTES_DISMISS_KEY = "new_erp-release-notes-dismissed";

export const TAG_LABEL: Record<ReleaseTag, string> = {
  feature: "新功能",
  improvement: "優化",
  fix: "修正",
};

export const TAG_COLOR: Record<ReleaseTag, string> = {
  feature:
    "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300",
  improvement:
    "bg-sky-100 text-sky-700 dark:bg-sky-900/30 dark:text-sky-300",
  fix: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300",
};

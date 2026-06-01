// 系統更新公告 (Release Notes)
//
// 新增一則公告：在陣列「最前面」加一筆（最新的放最上面）。
// id 必須唯一且只增不減（建議用日期 + 流水號），它同時是「使用者已讀/不再顯示」
// 的判斷依據 —— 只要最新一筆的 id 跟使用者上次勾選「不再顯示」的 id 不同，
// 公告就會再次自動跳出、鈴鐺也會亮紅點。

export type ReleaseTag = "feature" | "improvement" | "fix" | "tutorial";

export type ReleaseMedia = {
  /**
   * 主要顯示來源（放在 public/ 下）。
   * - 影片（建議，手機相容性最佳）：".mp4"，例如 "/release-notes/2026-06-01.mp4"
   * - 圖片 / 動態 GIF：".gif" / ".png"
   * 註：大型動畫 GIF 在手機（iOS Safari）有解碼記憶體上限，可能整張無法顯示，故優先用 mp4。
   */
  src: string;
  /** 影片封面圖（第一幀），影片載入前 / 無法自動播放時顯示 */
  poster?: string;
  /** 替代文字 */
  alt: string;
  /** 圖說（顯示在下方） */
  caption?: string;
};

export type ReleaseNote = {
  /** 唯一識別碼，只增不減，例如 "2026-06-01"。同時作為已讀判斷依據。 */
  id: string;
  /** 顯示用日期 */
  date: string;
  /** 公告標題 */
  title: string;
  /** 條列內容 */
  items: { tag: ReleaseTag; text: string }[];
  /** 操作教學圖（GIF / 截圖），顯示於完整公告頁 */
  media?: ReleaseMedia[];
};

/** 完整公告頁的路徑 */
export const RELEASE_NOTES_PAGE = "/release-notes";

// 最新的放最前面
export const RELEASE_NOTES: ReleaseNote[] = [
  {
    id: "2026-06-01-onboarding",
    date: "2026-06-01",
    title: "📱 會員 App 新手教學：安裝 App ＋ LINE 登入",
    items: [
      {
        tag: "tutorial",
        text: "完整步驟一次看懂：用手機瀏覽器打開網頁 → 加入主畫面（安裝 App）→ 用 LINE 登入 → 取得 6 位數驗證碼 → 回到 App 輸入驗證碼 → 完成登入，開始選購。",
      },
      {
        tag: "tutorial",
        text: "把網頁「加入主畫面」後，就能像一般 App 一樣從桌面圖示開啟；登入只要用 LINE，不必記帳號密碼。完整影片教學請見下方。",
      },
    ],
    media: [
      {
        src: "/release-notes/member-onboarding.mp4",
        poster: "/release-notes/member-onboarding.png",
        alt: "會員 App 新手教學：打開網頁、加入主畫面、用 LINE 登入、輸入 6 位數驗證碼、完成登入",
        caption: "會員 App 新手教學：① 開網頁選門市 → ② 加入主畫面 → ③ 用 LINE 登入 → ④ 取得驗證碼 → ⑤ 回 App 輸入驗證碼 → ⑥ 完成，開始使用。",
      },
    ],
  },
  {
    id: "2026-06-01",
    date: "2026-06-01",
    title: "🔔 新增更新公告通知，系統有更新不再錯過",
    items: [
      {
        tag: "feature",
        text: "畫面右上角多了一個小鈴鐺 🔔。每次系統有新功能或調整，鈴鐺上會出現紅點提醒你；點一下就能看到這次更新了哪些東西。下次想回顧時，隨時點鈴鐺都能再看一遍。",
      },
      {
        tag: "feature",
        text: "有新公告時，登入後會自動跳出來讓你知道。看完如果不想再被提醒，勾選下方的「不再顯示此公告」再關掉就可以了，之後它就不會再自動跳出。",
      },
      {
        tag: "improvement",
        text: "選品週曆裡的商品名稱如果太長，現在只會顯示前面兩行，讓版面更整齊；想看完整名稱時，把滑鼠移到名稱上停一下，就會顯示全部文字。",
      },
    ],
    media: [
      {
        src: "/release-notes/2026-06-01.mp4",
        poster: "/release-notes/2026-06-01.png",
        alt: "更新公告操作教學：點開鈴鐺、勾選不再顯示、週曆名稱滑過顯示完整內容",
        caption: "操作示範：點右上角鈴鐺看公告 →（看完可勾「不再顯示此公告」）→ 週曆過長的商品名稱滑鼠移上去會顯示完整內容。",
      },
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
  tutorial: "教學",
};

export const TAG_COLOR: Record<ReleaseTag, string> = {
  feature:
    "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300",
  improvement:
    "bg-sky-100 text-sky-700 dark:bg-sky-900/30 dark:text-sky-300",
  fix: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300",
  tutorial:
    "bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300",
};

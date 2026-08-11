// 結單日（group_buy_campaigns.cutoff_date）的統一顯示。
// 櫃台要靠它分辨同一個團的不同批次 / 回答客人「我這張是哪一次訂的」，
// 而且要跟會員端「我的訂單」印的那個結單日對得起來。
// 內部補貨等沒有團的單子沒有結單日 → 兩個元件都直接不畫（不要印「—」佔位）。

// 螢幕用：團名旁邊的灰底小標（/pickup 列表與確認視窗）
export function CutoffChip({ date }: { date?: string | null }) {
  if (!date) return null;
  return (
    <span
      className="rounded bg-zinc-200 px-1.5 py-0.5 font-mono text-[10px] font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
      title="此團的結單日"
    >
      結單日 {date}
    </span>
  );
}

// 80mm 熱感應單用：接在團名後面，不佔一整行（單子已經很長）。
// 熱感應只有黑白，別用顏色區分 — 一律跟團名同一個灰階。
export function CutoffText({ date }: { date?: string | null }) {
  if (!date) return null;
  return <span className="ml-1.5">· 結單日 {date}</span>;
}

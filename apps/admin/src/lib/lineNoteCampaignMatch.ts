// 記事本「指定團」：貼文內文跟候選團有多像。
//
// 2026-09-24 生鮮小舖：牙刷貼文比系統開團早 9 小時貼出去，掛在「未認出團」，
// 小幫手手動指定時選到清單最上面的直筒褲團 → 7 則 +1 全部被當成直筒褲的留言、
// 還有一位被人工加了 3 件直筒褲。所以指定視窗把像的團排前面，對不上的要再確認一次。
//
// 判準盡量跟 worker 的 matchCampaign（supabase/functions/_shared/lineNoteParse.ts）同一套：
// 🔖 團號章優先、內文含團名 / 團號 / 商品代碼就算中；都沒有才退到字元 bigram 重疊率。

const loose = (s: string) => String(s ?? "").normalize("NFKC").toLowerCase().replace(/\s+/g, "");
// bigram 只看文字與數字：emoji、括號、#、{} 這些兩邊寫法常不一樣
const bare = (s: string) => loose(s).replace(/[^\p{L}\p{N}]/gu, "");

function bigrams(s: string): string[] {
  const chars = Array.from(s);
  const out: string[] = [];
  for (let i = 0; i + 1 < chars.length; i++) out.push(chars[i] + chars[i + 1]);
  return out;
}

/** 貼文像不像這一團：0（完全對不上）～ 1（內文含團名 / 團號 / 代碼，或團號章相符） */
export function campaignMatchScore(postText: string, c: { name: string | null; campaign_no: string | null }): number {
  const raw = String(postText ?? "");
  const tag = raw.match(/\u{1F516}\s*團號\s*([A-Za-z0-9][A-Za-z0-9-]{2,})/u)?.[1];
  if (tag) return loose(tag) === loose(c.campaign_no ?? "") ? 1 : 0;

  const t = loose(raw);
  const keys: string[] = [];
  if (c.campaign_no) keys.push(c.campaign_no);
  if (c.name) {
    keys.push(c.name);
    const m = c.name.match(/([A-Za-z]?\d{4,}[A-Za-z0-9-]*)\s*#|#\s*([A-Za-z]?\d{3,}[A-Za-z0-9-]*)/);
    const code = m?.[1] ?? m?.[2];
    if (code && code.length >= 4) keys.push(code);
  }
  if (keys.some((k) => { const nk = loose(k); return nk.length >= 3 && t.includes(nk); })) return 1;

  const grams = bigrams(bare(c.name ?? ""));
  if (grams.length === 0) return 0;
  const tb = bare(raw);
  return grams.filter((g) => tb.includes(g)).length / grams.length;
}

/** 低於這個就要跳確認框（例：直筒褲 vs 牙刷貼文 = 0） */
export const WEAK_MATCH = 0.5;

/** 貼文標題：第一個非空白行，最多 40 字（確認框用） */
export function postTitle(text: string): string {
  const first = String(text ?? "").split(/\r?\n/).map((s) => s.trim()).find(Boolean) ?? "（沒有內文）";
  return first.length > 40 ? first.slice(0, 40) + "…" : first;
}

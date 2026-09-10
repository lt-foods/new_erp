// @ts-nocheck
// ─────────────────────────────────────────────────────────────────────────────
// 開團貼文的版型渲染（預覽、發文、存 DB 三邊都走這一份）
//
// 版型照小幫手手貼的樣子：團名開頭、接著金額、再來才是文案，#開團 收尾。
// 2026-09-10 老闆指定：先團名、再商品；只有一個品項就不印品名／代碼、直接金額；
// 多品項才 (A) 品名 ＋ 下一行金額；結單時間印「客人收單」（customer_end_at，沒設就是店家收單）。
//
// 文案本體吃 campaign.description —— 那本來就是商品那邊寫好的行銷文（線上近兩週 377/395 團有）。
// {{title}} / {{items}} / {{deadline}} / {{howto}} 是「聰明版」：文案自己已經寫過的就不再重複一次。
// 從記事本匯進來的團，description 常常就是整篇貼文（標題＋(A)(B)品項＋⏰結單都在裡面），
// 照樣接上去會變成品項印兩次、結單寫兩行。
// {{name}} 維持原樣（照印）；{{end_at}} / {{deadline}} 印的是客人看的結單時間（客人收單，沒設就是店家收單）。
// {{tag}} 是團號章（🔖 團號 GRP-…）：爬回來的時候靠它精準認出是哪一團，不用猜團名。
// 自訂模板沒寫 {{tag}} 也會被 withPostTag 補在文末 —— 章一定要有，不然這篇就只能靠猜。
// ─────────────────────────────────────────────────────────────────────────────
import { buildPostTag, withPostTag } from "./lineNoteParse.ts";
import { applyDeco, DECO_CLOSE, DECO_OPEN, decoPrice, decoTextPrices, htmlToText, stripLineDeco } from "./lineNoteDeco.ts";

export const TZ = "Asia/Taipei";

export const DEFAULT_TEMPLATE = `{{title}}

{{items}}

{{deadline}}

{{description}}

{{howto}}
#開團
{{tag}}`;

// 留言教學：單品的貼文上沒有代碼，教學就不要提代碼（+1 沒帶代碼時 RPC 會落到唯一那一項）
const HOWTO_MULTI = "📝 留言「會員編號 6 碼 ＋ 品項代碼＋數量」，例：123456 A+1 B+2";
const HOWTO_SINGLE = "📝 留言「會員編號 6 碼 ＋ 數量」，例：123456 +1";

// 比對標題用：去掉表情符號、空白、標點，只留文字
function bareText(s: string) {
  return String(s ?? "").normalize("NFKC").toLowerCase()
    .replace(/[\s\p{P}\p{S}\p{M}\p{C}]/gu, "");   // \p{M}/\p{C} 要一起拿掉：emoji 後面的 VS16、ZWJ 都藏在那裡
}

// 品項名在 DB 裡是「團名 (A) 空心菜200g」，直接印會變成「(A) 團名 (A) 空心菜200g」。
// 去掉團名前綴和重複的代碼（「(A) 」「A. 」「A、」都算），只留真正的品名。
function itemLabel(name: string, code: string, campaignName: string) {
  let t = String(name ?? "").trim();
  const cn = String(campaignName ?? "").trim();
  if (cn && t.startsWith(cn)) t = t.slice(cn.length).trim();
  t = t.replace(new RegExp(`^(?:[(（]${code}[)）]|${code}[.．、:：])\\s*`), "").trim();
  return t || String(name ?? "").trim();
}

function earliest(a: string | null | undefined, b: string | null | undefined): string | null {
  if (!a) return b ?? null;
  if (!b) return a;
  return new Date(a).getTime() <= new Date(b).getTime() ? a : b;
}

function fmtTaipei(iso: string | null | undefined) {
  if (!iso) return "";
  const p = new Intl.DateTimeFormat("zh-TW", { timeZone: TZ, month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date(iso));
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? "";
  return `${g("month")}/${g("day")} ${g("hour")}:${g("minute")}`;
}

// 貼文的金額一律用零售價（老闆 2026-09-10 交代）：unit_price 是團購價、開團後可以另外改低，
// 社群貼文要的是現行零售價（payload 的 retail_price，20260910040000）。沒設零售價（NULL / 0）才退回團購價。
function postPrice(it: any): number | null {
  const retail = Number(it?.retail_price);
  if (Number.isFinite(retail) && retail > 0) return retail;
  return it?.unit_price == null ? null : Number(it.unit_price);
}

// 文案裡已經標起來的金額（記事本佔位字還原的、獨立一行的 $數字、💰 後面的數字）
function decoPricesIn(desc: string): number[] {
  return [...desc.matchAll(new RegExp(`${DECO_OPEN}\\$?(\\d+(?:\\.\\d+)?)${DECO_CLOSE}`, "g"))].map((m) => Number(m[1]));
}

export function renderTemplate(template: string | null, payload: any) {
  const c = payload.campaign ?? {};
  const items = payload.items ?? [];
  const single = items.length === 1;

  // 文案：富文字 HTML 轉純文字 → 記事本佔位字還原（金額順手標起來）→ 文案自己寫的價格也標起來
  let desc = decoTextPrices(stripLineDeco(htmlToText(c.description ?? "")));

  // 文案開頭幾行裡有一行就是團名（匯進來的團幾乎都是第一行，也有先喊一句口號再寫品名的）
  // → 那一行搬到最上面當標題，不要印兩次。用文案的那一行而不是 c.name，
  // 小幫手打在標題上的表情符號才留得住。太短的行只認完全一樣，免得誤中。
  let title = c.name ?? "";
  const bareName = bareText(c.name ?? "");
  const lines = desc.split("\n");
  let seen = 0;
  for (let i = 0; i < lines.length && seen < 3; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    seen++;
    const bare = bareText(line);
    const hit = bareName && (bare === bareName || (bare.length >= 4 && (bareName.includes(bare) || bare.includes(bareName))));
    if (!hit) continue;
    title = line;
    lines.splice(i, 1);
    desc = lines.join("\n").replace(/^\n+/, "");
    break;
  }

  // 商品：只有一項 → 直接金額（沒有品名、沒有代碼）；多項 → (A) 品名 ＋ 下一行金額
  const itemLines = items.map((it: any) => {
    const p = postPrice(it);
    const price = p == null ? "" : decoPrice(`$${p}`);
    if (single) return price;
    const label = itemLabel(it.name, it.code, c.name);
    return `(${it.code}) ${label}${price ? `\n${price}` : ""}`;
  }).filter(Boolean).join("\n");
  // 文案自己就列了 (A)(B) 或 A. B. 品項 → 不重複；單品而文案已經寫了同一個金額（「一個$125」）→ 也不重複
  const descHasItems = /(^|\n)\s*(?:[(（][A-Za-z][)）]|[A-Za-z][.．、:：])/.test(desc);
  const descHasThisPrice = single && postPrice(items[0]) != null && decoPricesIn(desc).includes(postPrice(items[0]));
  const descHasDeadline = /結單|收單|截單/.test(desc);
  // 客人看的結單時間 = 客人收單（customer_end_at，20260910050000）跟店家收單取早的那個；
  // 客人收單沒設就是店家收單。店家收單是小幫手還能補單的最後期限，客人不用知道。
  const closeAt = earliest(c.customer_end_at, c.end_at);
  const deadline = closeAt ? `⏰ ${fmtTaipei(closeAt)} 結單` : "";

  const rendered = (template || DEFAULT_TEMPLATE)
    .replaceAll("{{tag}}", buildPostTag(c.campaign_no))
    .replaceAll("{{title}}", title)
    .replaceAll("{{items}}", descHasItems || descHasThisPrice ? "" : itemLines)
    .replaceAll("{{deadline}}", descHasDeadline ? "" : deadline)
    .replaceAll("{{howto}}", single ? HOWTO_SINGLE : HOWTO_MULTI)
    .replaceAll("{{name}}", c.name ?? "")
    .replaceAll("{{campaign_no}}", c.campaign_no ?? "")
    .replaceAll("{{description}}", desc)
    .replaceAll("{{end_at}}", fmtTaipei(closeAt))
    .replaceAll("{{start_at}}", fmtTaipei(c.start_at))
    .replaceAll("{{pickup_deadline}}", fmtTaipei(c.pickup_deadline))
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return withPostTag(rendered, c.campaign_no);
}

// 真的會貼出去的字：版型渲染完，把標起來的金額換成 emoji。
export function renderPostText(payload: any) {
  return applyDeco(renderTemplate(payload.post_template, payload));
}

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
// {{name}} 維持原樣（照印）。{{deadline}} / {{end_at}} 是客人看的結單時間（客人收單，沒設就是店家收單）；
// 店家收單是小幫手還能補單的最後期限，貼文上不印。
// 結單那一行放在金額後面（老闆 2026-09-10 的範例）：文案自己有價格時就插進文案裡金額那一段的後面，
// 文案自己寫的「⏰9/14結單」換成系統的時間。
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

// 留言教學（老闆 2026-09-10 定稿：不提會員編號）。單品的貼文上沒有代碼，教學就不要提代碼
// （+1 沒帶代碼時 RPC 會落到唯一那一項）。
const HOWTO_MULTI = "📝 留言「品項代碼＋數量」，例：A+1 B+2";
const HOWTO_SINGLE = "📝 留言「數量」，例：+1";

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
  if (!it) return null;
  const retail = Number(it?.retail_price);
  if (Number.isFinite(retail) && retail > 0) return retail;
  return it?.unit_price == null ? null : Number(it.unit_price);
}

// 這一行已經有價格了嗎（純文字 189元／$189、已標起來的、或小幫手自己打的鍵帽數字）
const LINE_HAS_PRICE = new RegExp(`\\d\\s*元|\\$\\s*\\d|${DECO_OPEN}|[0-9]\\uFE0F\\u20E3`);
// 整行只有一個金額（「💰一袋189元」「$109」，已經被標起來的樣子）
const PRICE_ONLY_LINE = new RegExp(`^\\s*(?:💰[^\\d\\n$💰]{0,6})?${DECO_OPEN}\\$?(\\d+(?:\\.\\d+)?)${DECO_CLOSE}\\s*元?\\s*$`);

const ITEM_LINE = /^\s*(?:[(（]([A-Za-z])[)）]|([A-Za-z])[.．、:：])\s*(.*)$/;

function injectItemPrices(desc: string, items: any[]): string {
  const byCode = new Map<string, any>(items.map((it: any) => [String(it.code ?? "").toUpperCase(), it]));
  const lines = desc.split("\n");
  let injected = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(ITEM_LINE);
    if (!m) continue;
    const rest = m[3] ?? "";
    if (/[(（][A-Za-z][)）]/.test(rest)) continue;          // 「(A)韭菜盒／(B)高麗菜盒」一行列兩個，不碰
    const p = postPrice(byCode.get((m[1] ?? m[2]).toUpperCase()));
    if (p == null || LINE_HAS_PRICE.test(lines[i])) continue;
    // 記事本寫法：價格寫在下一行（「(A)空心菜200g／($)(3)(5)」）→ 跟零售價一樣就併進品項那一行；
    // 不一樣就兩行都不動，預覽看得到、讓人去改團或改文案
    let j = i + 1;
    while (j < lines.length && !lines[j].trim()) j++;
    const nm = j < lines.length ? lines[j].match(PRICE_ONLY_LINE) : null;
    if (nm) {
      if (Number(nm[1]) !== p) continue;
      lines.splice(j, 1);
    }
    lines[i] = `${lines[i].trimEnd()} ${decoPrice(String(p))} 元`;
    injected++;
  }
  if (!injected) return desc;
  // 接完之後，文案裡整行只寫同一個金額的「💰一袋189元」就是多的；緊跟在品項後面的那種上面已經處理過，不碰
  const prices = new Set(items.map((it: any) => postPrice(it)).filter((x) => x != null));
  let prevText = "";
  return lines.filter((line) => {
    const m = line.match(PRICE_ONLY_LINE);
    const drop = m && prices.has(Number(m[1])) && !ITEM_LINE.test(prevText);
    if (line.trim()) prevText = line;
    return !drop;
  }).join("\n");
}

// 小幫手自己寫的結單那一行：「⏰9/14結單」「📅 9/8（二）晚上六點結單」—— 開頭最多三個字（表情符號），
// 接著日期，結尾是結單／收單／截單。「結單後15-25天到貨」那種句子不算。
const HELPER_DEADLINE_LINE = /^[^\d\n]{0,3}\d{1,2}[\/／月]\d{1,2}.*(?:結單|收單|截單)[^\d\n]{0,3}$/;

// 把系統的結單那一行插進文案：先把小幫手自己寫的結單行拿掉（時間以系統為準），
// 再找文案裡第一段連續的金額行（「💰95元」或「(A) 韭菜盒 1️⃣8️⃣9️⃣ 元」），插在那一段後面、前後各空一行。
// 文案裡沒有金額行就不插（回 placed=false，走版型的 {{deadline}}）。
function placeDeadline(desc: string, deadline: string): { desc: string; placed: boolean } {
  if (!deadline) return { desc, placed: false };
  const lines = desc.split("\n").filter((l) => !HELPER_DEADLINE_LINE.test(l.trim()));
  const isPrice = (l: string) => l.includes(DECO_OPEN) || (ITEM_LINE.test(l) && LINE_HAS_PRICE.test(l));
  const start = lines.findIndex(isPrice);
  if (start < 0) return { desc: lines.join("\n"), placed: false };
  let end = start;
  while (end + 1 < lines.length && isPrice(lines[end + 1])) end++;
  const after = lines[end + 1];
  lines.splice(end + 1, 0, "", deadline, ...(after !== undefined && after.trim() ? [""] : []));
  return { desc: lines.join("\n"), placed: true };
}

// 整行只有金額的那一行，上面沒有空行就補一行（緊跟在品項後面的那種是那一項的價格，不拆開）
function spaceOutPriceLines(desc: string): string {
  const out: string[] = [];
  for (const line of desc.split("\n")) {
    const prev = out.length ? out[out.length - 1] : "";
    if (PRICE_ONLY_LINE.test(line) && prev.trim() && !ITEM_LINE.test(prev)) out.push("");
    out.push(line);
  }
  return out.join("\n");
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

  // 標題一律印團名（老闆 2026-09-10：「商品 G02580 title 是 兒童防擠壓飲料杯托 (顏色隨機)」，
  // 不要拿文案裡的「【兒童防擠壓飲料杯托｜顏色隨機】」當標題）。文案開頭幾行裡跟團名一樣的那一行
  // （匯進來的團幾乎都是第一行，也有先喊一句口號再寫品名的）拿掉，不要印兩次。
  // 太短的行只認完全一樣，免得誤中。
  const title = c.name ?? "";
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
    lines.splice(i, 1);
    desc = lines.join("\n").replace(/^\n+/, "");
    break;
  }

  // 商品（老闆 2026-09-10 的範例）：只有一項 → 「💰1️⃣0️⃣5️⃣ 元」一行，沒有品名、沒有代碼；
  // 多項 → 「(A) 韭菜盒 1️⃣8️⃣9️⃣ 元」金額接在同一行
  const itemLines = items.map((it: any) => {
    const p = postPrice(it);
    const price = p == null ? "" : `${decoPrice(String(p))} 元`;
    if (single) return price ? `💰${price}` : "";
    const label = itemLabel(it.name, it.code, c.name);
    return `(${it.code}) ${label}${price ? ` ${price}` : ""}`;
  }).filter(Boolean).join("\n");

  // 文案自己列了 (A)(B) 品項但那一行沒寫價格（也不是像記事本那樣價格寫在下一行）→
  // 把金額接在那一行後面，變成跟我們自己產的一樣「(A) 韭菜盒 1️⃣8️⃣9️⃣ 元」。
  // 接完之後，文案裡只寫著同一個金額的「💰一袋189元」那種整行就是多的，拿掉。
  desc = injectItemPrices(desc, items);
  // 老闆 2026-09-10：金額行跟上一行之間要空一行（「💰1️⃣0️⃣5️⃣元」直接貼在文案下面太擠）
  desc = spaceOutPriceLines(desc);
  // 結單那一行：客人看的結單時間 = 客人收單（customer_end_at，20260910050000）跟店家收單取早的那個；
  // 客人收單沒設就是店家收單。文案自己有金額時插在金額那一段後面，沒有就走版型的 {{deadline}}。
  const closeAt = earliest(c.customer_end_at, c.end_at);
  const deadline = closeAt ? `⏰ ${fmtTaipei(closeAt)} 結單` : "";
  const placed = placeDeadline(desc, deadline);
  desc = placed.desc;
  // 文案自己就列了 (A)(B) 或 A. B. 品項 → 不重複；單品而文案已經寫了同一個金額（「一個$125」）→ 也不重複
  const descHasItems = /(^|\n)\s*(?:[(（][A-Za-z][)）]|[A-Za-z][.．、:：])/.test(desc);
  const descHasThisPrice = single && postPrice(items[0]) != null && decoPricesIn(desc).includes(postPrice(items[0]));

  const rendered = (template || DEFAULT_TEMPLATE)
    .replaceAll("{{tag}}", buildPostTag(c.campaign_no))
    .replaceAll("{{title}}", title)
    .replaceAll("{{items}}", descHasItems || descHasThisPrice ? "" : itemLines)
    .replaceAll("{{deadline}}", placed.placed ? "" : deadline)
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

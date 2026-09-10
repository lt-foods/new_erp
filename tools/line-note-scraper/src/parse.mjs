// 記事本留言 → 「+1」訂單行的解析器。純函式、無相依，方便測試。
//
// 支援的寫法（每一行各自解析，一則留言可以有多筆）：
//   +1            → qty 1
//   ＋２ / + 3     → 全形、空白都吃
//   A+1 / A +2    → code A, qty
//   A1+1 / B-2+1  → code 可含數字、連字號（品項編號）
//   +1 A          → qty 在前、code 在後
//   A x2 / A*2 / A×2 / A２個 / A 2份 → code + 數量
//   2份 / 3組 / 1個（沒 code）→ qty
//   -1 / A-1 / 取消 / 退 → cancel:true（qty 為負或標記）
//
// 不猜的：純數字「2」、只有品名沒數量的行、聊天內容。這些回空陣列。

const FULLWIDTH_DIGITS = "０１２３４５６７８９";

export function normalize(text) {
  return String(text ?? "")
    .replace(/[０-９]/g, (ch) => String(FULLWIDTH_DIGITS.indexOf(ch)))
    .replace(/[＋]/g, "+")
    .replace(/[－—–]/g, "-")
    .replace(/[×Ｘｘ＊]/g, "x")
    .replace(/[　]/g, " ")
    .replace(/[：]/g, ":");
}

const UNIT = "(?:份|個|组|組|包|盒|箱|瓶|罐|袋|條|片|支|入|件|套|杯|顆|粒|斤|台|本)?";
// 品項代碼：英文字母開頭，可接數字／連字號（A、B2、C-1、AB）
const CODE = "([A-Za-z][A-Za-z0-9-]{0,7})";
const CANCEL_WORDS = /(取消|退|刪|删|不要了|改為0|改成0)/;

const MULTI_CODE_FIRST = /^\s*(?:[A-Za-z][A-Za-z0-9-]{0,7}\s*[+-]\s*\d{1,3}\s*){2,}$/;
const MULTI_QTY_FIRST = /^\s*(?:[+-]\s*\d{1,3}\s*[A-Za-z][A-Za-z0-9-]{0,7}\s*){2,}$/;
const TOKEN_CODE_FIRST = /[A-Za-z][A-Za-z0-9-]{0,7}\s*[+-]\s*\d{1,3}/g;
const TOKEN_QTY_FIRST = /[+-]\s*\d{1,3}\s*[A-Za-z][A-Za-z0-9-]{0,7}/g;

const PATTERNS = [
  // A+1 / A +2 / B-2+1 / 取消 A-1
  { re: new RegExp(`^\\s*${CODE}\\s*([+-])\\s*(\\d{1,3})${UNIT}\\s*$`), map: (m) => ({ code: m[1], sign: m[2], qty: m[3] }) },
  // +1 A / +2 B2
  { re: new RegExp(`^\\s*([+-])\\s*(\\d{1,3})${UNIT}\\s*${CODE}\\s*$`), map: (m) => ({ code: m[3], sign: m[1], qty: m[2] }) },
  // +1 / + 3
  { re: new RegExp(`^\\s*([+-])\\s*(\\d{1,3})${UNIT}\\s*$`), map: (m) => ({ code: null, sign: m[1], qty: m[2] }) },
  // A x2 / A*2 / A 2份 / A2份（要有單位或 x，避免把 A2 品號當成 A×2）
  { re: new RegExp(`^\\s*${CODE}\\s*(?:x\\s*(\\d{1,3})${UNIT}|(\\d{1,3})(?:份|個|组|組|包|盒|箱|瓶|罐|袋|條|片|支|件|套|杯|顆|粒|斤|台|本))\\s*$`), map: (m) => ({ code: m[1], sign: "+", qty: m[2] ?? m[3] }) },
  // 2份 / 3組（沒 code，但有單位）
  { re: /^\s*(\d{1,3})(?:份|個|组|組|包|盒|箱|瓶|罐|袋|條|片|支|件|套|杯|顆|粒|斤|台|本)\s*$/, map: (m) => ({ code: null, sign: "+", qty: m[1] }) },
];

/**
 * @param {string} text 留言原文
 * @returns {{code:string|null, qty:number, cancel:boolean, line:string}[]}
 */
export function parseOrderLines(text) {
  const out = [];
  const norm = normalize(text);
  const segments = [];
  for (const rawLine of norm.split(/\r?\n|[,，;；、/]/)) {
    // 同一行寫多筆：整行都是「代碼+號+數」重複（A+1 B+5）或「號+數+代碼」重複（+1 A +2 B）才拆，
    // 其他（B-2 +1 這種代碼帶連字號的）交給下面的單筆規則
    if (MULTI_CODE_FIRST.test(rawLine)) segments.push(...(rawLine.match(TOKEN_CODE_FIRST) ?? []));
    else if (MULTI_QTY_FIRST.test(rawLine)) segments.push(...(rawLine.match(TOKEN_QTY_FIRST) ?? []));
    else segments.push(rawLine);
  }
  for (const rawLine of segments) {
    const line = rawLine.trim();
    if (!line) continue;
    const cancelWord = CANCEL_WORDS.test(line);
    // 把「取消」「退」這類字先拿掉再比對數量
    const body = line.replace(CANCEL_WORDS, " ").trim();
    let hit = null;
    for (const p of PATTERNS) {
      const m = body.match(p.re);
      if (m) { hit = p.map(m); break; }
    }
    if (!hit) {
      // 「取消」單獨一行也算一筆取消（qty 0，讓人工看）
      if (cancelWord && body === "") out.push({ code: null, qty: 0, cancel: true, line });
      continue;
    }
    const qty = Number(hit.qty);
    if (!Number.isFinite(qty) || qty <= 0) continue;
    const cancel = cancelWord || hit.sign === "-";
    out.push({ code: hit.code ? hit.code.toUpperCase() : null, qty, cancel, line });
  }
  return out;
}

/**
 * 從留言抓「6 碼會員編號」（members.member_no = 'M' + 6 碼）。
 * 只認獨立的 6 位數（前後不是數字），所以手機號碼（10 碼）、A1 這種品號都不會誤抓；
 * 允許寫成 M123456。回 { hint, rest }，rest 是把編號拿掉後的文字（拿去解析 +1）。
 */
export function extractMemberNo(text) {
  const norm = normalize(text);
  const m = norm.match(/(?<![0-9])[Mm]?([0-9]{6})(?![0-9])/);
  if (!m) return { hint: null, rest: norm };
  const rest = (norm.slice(0, m.index) + " " + norm.slice(m.index + m[0].length)).trim();
  return { hint: m[1], rest };
}

/**
 * 留言 → { memberNo, memberNoSource, orders[] }，給 worker 落地用。
 * 6 碼先從留言內文找；沒有就看留言者的暱稱（很多社群規定暱稱要帶會員編號：
 * 「涂003886」「Sherry061016/松山」「Ting/616582松山」）。
 */
export function parseNoteComment(text, authorName = "") {
  const { hint, rest } = extractMemberNo(text);
  if (hint) return { memberNo: hint, memberNoSource: "text", orders: parseOrderLines(rest) };
  const fromName = extractMemberNo(authorName).hint;
  return { memberNo: fromName, memberNoSource: fromName ? "name" : null, orders: parseOrderLines(rest) };
}

// ── 貼文 ↔ 團 的比對 ────────────────────────────────────────────────────────
// 兩邊都正規化（NFKC、去空白、小寫）再比 includes。團名常有前後空白、全形字、
// "N6090802#" / "#B2967" 這種代碼；記事本內文又常只寫商品名。依序試：
// 團號 → 團名 → 團名裡的代碼 → 該團品項的商品名（團只有 ≤3 項時才用，免得誤中）。
// 多個團都命中取「命中字串最長」的；一樣長就不猜（回 null，留給人工）。
// ⚠ 以上都是「猜」，只用在沒蓋團號章的貼文（小幫手手貼的）。蓋了章的走精準比對。
export function normalizeForMatch(s) {
  return String(s ?? "").normalize("NFKC").toLowerCase().replace(/\s+/g, "");
}

export function matchCampaign(text, campaigns) {
  const t = normalizeForMatch(text);
  if (!t) return null;
  // 蓋過團號章的貼文只認那個章，**不退回模糊比對**：章在但那一團不在候選清單裡
  // （已結算 / 已取消 / 超出 limit）就回 null 讓它留成 unlinked，退回去猜的話
  // 很可能中到另一個「團名剛好是子字串」的團，那就是認錯團。
  const tagged = extractPostTag(text);
  if (tagged) {
    const want = normalizeForMatch(tagged);
    return (campaigns ?? []).find((c) => normalizeForMatch(c.campaign_no) === want) ?? null;
  }
  let best = null;
  let tie = false;
  for (const c of campaigns ?? []) {
    const keys = [];
    if (c.campaign_no) keys.push(c.campaign_no);
    if (c.name) {
      keys.push(c.name);
      const m = String(c.name).match(/([A-Za-z]?\d{4,}[A-Za-z0-9-]*)\s*#|#\s*([A-Za-z]?\d{3,}[A-Za-z0-9-]*)/);
      const code = m?.[1] ?? m?.[2];
      if (code && code.length >= 4) keys.push(code);
    }
    const items = c.campaign_items ?? [];
    if (items.length > 0 && items.length <= 3) {
      for (const it of items) {
        const pn = it?.skus?.product_name;
        if (pn && normalizeForMatch(pn).length >= 4) keys.push(pn);
      }
    }
    for (const k of keys) {
      const nk = normalizeForMatch(k);
      if (nk.length < 3 || !t.includes(nk)) continue;
      if (!best || nk.length > best.len) { best = { c, len: nk.length }; tie = false; }
      else if (nk.length === best.len && best.c.id !== c.id) tie = true;
    }
  }
  return best && !tie ? best.c : null;
}

// ── 貼文編號（🔖 團號）─────────────────────────────────────────────────────
// 系統發出去的每一篇貼文都在文末蓋一個「🔖 團號 GRP-…」的章，讓爬回來的時候
// **一眼認得出是哪一團**，不用靠團名子字串去猜（matchCampaign 猜錯 = 把客人的
// +1 加到別的團上，比漏認嚴重得多；20260910000000 那次松山「雲林小農🍀阿土伯」
// 就是團名對不上而整篇認不出來）。
//
// 小幫手自己手貼的文沒有這個章，照樣走下面的模糊比對 —— 但只要是從後台
// 「LINE 記事本」發的（含預覽複製去手貼的），比對就是精準的。
export const POST_TAG_MARK = "\u{1F516}";                    // 🔖

/** 貼文文末的團號章。campaign_no 空的話回空字串（不硬蓋一個假的章）。 */
export function buildPostTag(campaignNo) {
  const no = String(campaignNo ?? "").trim();
  return no ? `${POST_TAG_MARK} 團號 ${no}` : "";
}

/**
 * 從貼文內文把團號章挖出來；沒蓋章回 null。
 * ⚠「團號」兩個字是必要的，不能只認 🔖 —— 手貼的文很可能自己就用了 🔖 當裝飾
 * （「🔖 好物推薦」），只認符號會把它當成蓋了章，然後因為對不到團而回 null，
 * 反而害本來模糊比對得出來的貼文變成 unlinked。
 */
export function extractPostTag(text) {
  const m = String(text ?? "").match(/\u{1F516}\s*團號\s*([A-Za-z0-9][A-Za-z0-9-]{2,})/u);
  return m ? m[1] : null;
}

/** 沒蓋章就補一個蓋在最後（自訂模板沒寫 {{tag}} 也一樣有章）。 */
export function withPostTag(text, campaignNo) {
  const tag = buildPostTag(campaignNo);
  if (!tag || extractPostTag(text)) return String(text ?? "");
  const body = String(text ?? "").trimEnd();
  return body ? `${body}\n${tag}` : tag;
}

/** 貼文標題：取第一個非空白行，最多 60 字 */
export function postTitle(text) {
  const first = String(text ?? "").split(/\r?\n/).map((s) => s.trim()).find(Boolean) ?? "";
  return first.length > 60 ? first.slice(0, 60) + "…" : first;
}

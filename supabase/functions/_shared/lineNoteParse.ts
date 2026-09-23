// @ts-nocheck — JS 移植，不做型別檢查
// ⚠ 這是 tools/line-note-scraper/src/parse.mjs 的複本（Edge Function 只能 bundle supabase/functions 底下的檔案）。
// 改規則時兩邊一起改；tools 那邊有單元測試（npm test）。
// deno-lint-ignore-file no-explicit-any

// 記事本留言 → 「+1」訂單行的解析器。純函式、無相依，方便測試。
//
// 支援的寫法（每一行各自解析，一則留言可以有多筆）：
//   +1            → qty 1
//   加1 / 打1 / 加一 / A加1 / 加1 A → 同 +1（社群慣用「加1」「打1」，2026-09-14 起）
//   ＋２ / + 3     → 全形、空白都吃
//   A+1 / A +2    → code A, qty
//   A1+1 / B-2+1  → code 可含數字、連字號（品項編號）
//   +1 A          → qty 在前、code 在後
//   A x2 / A*2 / A×2 / A２個 / A 2份 → code + 數量
//   2份 / 3組 / 1個（沒 code）→ qty
//   -1 / A-1 / 取消 / 退 → cancel:true（qty 為負或標記）
//
// 不猜的：純數字「2」、只有品名沒數量的行、聊天內容。這些回空陣列。
//   「A, B+1」這種有代碼沒寫數量的：整則都不加單（不猜 A 要幾個；以前會只加 B、A 靜靜漏掉）。
//   每個品項都要自己寫數量（A+1, B+1）才自動加單。

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

// ── 可調整的規則（後台「LINE 記事本 → 解析規則」分頁可以改，存在 line_note_parse_settings）──
// 預設值＝寫死那時候的行為。沒存過設定的租戶、或設定讀不到時一律用它。
export const DEFAULT_PARSE_CONFIG = Object.freeze({
  // 「A 2份」「2份」認得的數量單位（「入」刻意不在裡面：A2入 是 2 入裝，不是 2 份）
  units: ["份", "個", "组", "組", "包", "盒", "箱", "瓶", "罐", "袋", "條", "片", "支", "件", "套", "杯", "顆", "粒", "斤", "台", "本"],
  // 出現這些字＝取消
  cancelWords: ["取消", "退", "刪", "删", "不要了", "改為0", "改成0"],
  // 後面緊接數字時當「+」用的字（「加1」「打1」「加一」）
  plusWords: ["加", "打"],
  allowNoCode: true,     // 沒寫品項也收：+1、加1、2份（只有一個品項的團）
  allowQtyFirst: true,   // 數量寫前面：+1 A
  allowTimes: true,      // 乘號／單位：A x2、A*2、A 2份
  fixTypos: true,        // 常見錯字：A+I、A十1、A+1.
  rejectBareCode: true,  // 有品項沒寫數量（A, B+1）→ 整則不加；關掉＝只加有寫數量的那幾個
});

const strList = (v, fallback) => {
  if (!Array.isArray(v)) return fallback;
  const out = [...new Set(v.map((x) => String(x ?? "").trim()).filter((x) => x && x.length <= 10))].slice(0, 50);
  return out;
};
const bool = (v, fallback) => (typeof v === "boolean" ? v : fallback);

/** 任何來源（DB jsonb / 後台草稿）的設定 → 補齊預設、濾掉壞值 */
export function normalizeParseConfig(cfg) {
  const c = cfg && typeof cfg === "object" ? cfg : {};
  const d = DEFAULT_PARSE_CONFIG;
  return {
    units: strList(c.units, [...d.units]),
    cancelWords: strList(c.cancelWords, [...d.cancelWords]),
    // 「+」字只收單一個中文／符號字，不收英數（「A」當加號會把品號吃掉）
    plusWords: strList(c.plusWords, [...d.plusWords]).filter((w) => w.length === 1 && !/[A-Za-z0-9\s]/.test(w)),
    allowNoCode: bool(c.allowNoCode, d.allowNoCode),
    allowQtyFirst: bool(c.allowQtyFirst, d.allowQtyFirst),
    allowTimes: bool(c.allowTimes, d.allowTimes),
    fixTypos: bool(c.fixTypos, d.fixTypos),
    rejectBareCode: bool(c.rejectBareCode, d.rejectBareCode),
  };
}

const esc = (w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const alt = (ws) => (ws.length ? ws.map(esc).join("|") : "(?!)");   // 空清單＝永遠不中

// 品項代碼：英文字母開頭，可接數字／連字號（A、B2、C-1、AB）
const CODE = "([A-Za-z][A-Za-z0-9-]{0,7})";
const CN_DIGITS = "一二三四五六七八九";

// 手機打字常見的錯字（2026-09-15 松山那批留言實際出現，人看得懂、機器解不出來就整則漏單）：
//   「A+I」「I+ I」→ + - 後面的大寫 I / 小寫 l / 全形｜ 當 1（後頭不接英數才換，避免動到品號）
//   「A十｜」      → 品項代碼後面的「十」當 +（後面要接數字／一～九／｜）
//   「A+1.」      → 行尾的句號／驚嘆號拿掉
const TYPO_PLUS_TEN = /([A-Za-z])\s*十\s*(?=[0-9一二三四五六七八九｜|Il])/g;
const TYPO_ONE = /([+-])\s*[｜|Il](?![A-Za-z0-9])/g;
function fixTypos(s) {
  return s.replace(TYPO_PLUS_TEN, "$1+").replace(TYPO_ONE, (_, sign) => sign + "1").replace(/[.。!！]+[ \t]*$/gm, "");
}

const MULTI_CODE_FIRST = /^\s*(?:[A-Za-z][A-Za-z0-9-]{0,7}\s*[+-]\s*\d{1,3}\s*){2,}$/;
const MULTI_QTY_FIRST = /^\s*(?:[+-]\s*\d{1,3}\s*[A-Za-z][A-Za-z0-9-]{0,7}\s*){2,}$/;
const TOKEN_CODE_FIRST = /[A-Za-z][A-Za-z0-9-]{0,7}\s*[+-]\s*\d{1,3}/g;
const TOKEN_QTY_FIRST = /[+-]\s*\d{1,3}\s*[A-Za-z][A-Za-z0-9-]{0,7}/g;
const BARE_CODE = new RegExp(`^${CODE}$`);

// 設定 → 編好的 regex。純粹由設定內容決定，所以用內容當 key 快取（不是「這次呼叫」的狀態）。
const compiled = new Map();
function compile(cfg) {
  const key = JSON.stringify(cfg);
  const hit = compiled.get(key);
  if (hit) return hit;
  const units = alt(cfg.units);
  const UNIT = `(?:${alt([...cfg.units, "入"])})?`;
  const patterns = [
    // A+1 / A +2 / B-2+1 / 取消 A-1
    { re: new RegExp(`^\\s*${CODE}\\s*([+-])\\s*(\\d{1,3})${UNIT}\\s*$`), map: (m) => ({ code: m[1], sign: m[2], qty: m[3] }) },
  ];
  // +1 A / +2 B2
  if (cfg.allowQtyFirst) patterns.push({ re: new RegExp(`^\\s*([+-])\\s*(\\d{1,3})${UNIT}\\s*${CODE}\\s*$`), map: (m) => ({ code: m[3], sign: m[1], qty: m[2] }) });
  // +1 / + 3
  if (cfg.allowNoCode) patterns.push({ re: new RegExp(`^\\s*([+-])\\s*(\\d{1,3})${UNIT}\\s*$`), map: (m) => ({ code: null, sign: m[1], qty: m[2] }) });
  // A x2 / A*2 / A 2份 / A2份（要有單位或 x，避免把 A2 品號當成 A×2）
  if (cfg.allowTimes) patterns.push({ re: new RegExp(`^\\s*${CODE}\\s*(?:x\\s*(\\d{1,3})${UNIT}|(\\d{1,3})(?:${units}))\\s*$`), map: (m) => ({ code: m[1], sign: "+", qty: m[2] ?? m[3] }) });
  // 2份 / 3組（沒 code，但有單位）
  if (cfg.allowNoCode) patterns.push({ re: new RegExp(`^\\s*(\\d{1,3})(?:${units})\\s*$`), map: (m) => ({ code: null, sign: "+", qty: m[1] }) });
  const out = {
    patterns,
    cancel: new RegExp(`(${alt(cfg.cancelWords)})`),
    // 「加1」「打1」「加一」→「+1」。只在後面緊接數字（或一～九）時才換，
    // 「加油」「打包」「追加」這種不動；「加一點」換成「+1點」後也對不到任何 pattern，仍是非下單。
    plus: cfg.plusWords.length ? new RegExp(`(?:${alt(cfg.plusWords)})\\s*([0-9一二三四五六七八九])`, "g") : null,
  };
  if (compiled.size > 50) compiled.clear();
  compiled.set(key, out);
  return out;
}

/**
 * @param {string} text 留言原文
 * @param {object} [config] 解析規則（normalizeParseConfig 的格式）；不給＝預設
 * @returns {{code:string|null, qty:number, cancel:boolean, line:string}[]}
 */
export function parseOrderLines(text, config) {
  const cfg = normalizeParseConfig(config);
  const rx = compile(cfg);
  const out = [];
  let norm = normalize(text);
  if (rx.plus) norm = norm.replace(rx.plus, (_, d) => "+" + (CN_DIGITS.includes(d) ? String(CN_DIGITS.indexOf(d) + 1) : d));
  if (cfg.fixTypos) norm = fixTypos(norm);
  const segments = [];
  for (const rawLine of norm.split(/\r?\n|[,，;；、/]/)) {
    // 同一行寫多筆：整行都是「代碼+號+數」重複（A+1 B+5）或「號+數+代碼」重複（+1 A +2 B）才拆，
    // 其他（B-2 +1 這種代碼帶連字號的）交給下面的單筆規則
    if (MULTI_CODE_FIRST.test(rawLine)) segments.push(...(rawLine.match(TOKEN_CODE_FIRST) ?? []));
    else if (cfg.allowQtyFirst && MULTI_QTY_FIRST.test(rawLine)) segments.push(...(rawLine.match(TOKEN_QTY_FIRST) ?? []));
    else segments.push(rawLine);
  }
  for (const rawLine of segments) {
    const line = rawLine.trim();
    if (!line) continue;
    const cancelWord = rx.cancel.test(line);
    // 把「取消」「退」這類字先拿掉再比對數量
    const body = line.replace(rx.cancel, " ").trim();
    let hit = null;
    for (const p of rx.patterns) {
      const m = body.match(p.re);
      if (m) { hit = p.map(m); break; }
    }
    if (!hit) {
      // 光一個代碼沒數量（「A, B+1」的 A）→ 整則放棄，別只加一半
      if (cfg.rejectBareCode && BARE_CODE.test(body)) return [];
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
export function parseNoteComment(text, authorName = "", config) {
  const { hint, rest } = extractMemberNo(text);
  if (hint) return { memberNo: hint, memberNoSource: "text", orders: parseOrderLines(rest, config) };
  const fromName = extractMemberNo(authorName).hint;
  return { memberNo: fromName, memberNoSource: fromName ? "name" : null, orders: parseOrderLines(rest, config) };
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

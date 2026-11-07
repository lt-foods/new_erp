// shop2000 平台的 HTTP client + HTML 解析。
//
// 平台特性（2026-11-07 實測，辛普森 www.simpsons.com.tw 與 www.shop2000.com.tw/有鮮實業 都一樣）：
// - 登入：POST /shop2000_prog/member/mem_login.aspx（email_mem / mem_pw / vdir / http_ref），
//   成功回一段含「會員登入成功」的 HTML，cookie 是 msn<storeId> / msn_chk<storeId>。
// - 分類列表 /product/<pc1sn>：沒登入只會看到「本分類需有權限方能瀏覽」。
//   分頁是對同一個網址 POST form1（p / RecordCount / pc2sn / vorder_p），不是 GET 參數。
// - 商品詳細 /product/p<psn>。
// - 自訂網域（simpsons.com.tw）的 vdir 是空字串；平台網域的 vdir 是 "/店名"。
//
// HTML 大量不閉合標籤（<td 沒有 </td>），不用 DOM parser，全部用字串切。

const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

export class Shop2000Client {
  /**
   * @param {object} opts
   * @param {string} opts.url   任一個該店的網址（用來推 origin / vdir）
   * @param {string} opts.email
   * @param {string} opts.password
   * @param {number} [opts.delayMs]  每次請求之間的間隔（禮貌一點）
   * @param {(msg: string) => void} [opts.log]
   */
  constructor({ url, email, password, delayMs = 400, log = () => {} }) {
    const u = new URL(url);
    this.origin = u.origin;
    this.vdir = vdirOf(u); // 保持 percent-encoding：會進 Referer 標頭，非 ASCII 會被 fetch 拒絕（ByteString）
    this.email = email;
    this.password = password;
    this.delayMs = delayMs;
    this.log = log;
    this.cookies = new Map();
    this.loggedIn = false;
    this._last = 0;
  }

  get storeHome() {
    return this.origin + this.vdir;
  }

  /** /product/xxx → 完整網址（自動補 vdir） */
  productUrl(path) {
    return `${this.storeHome}/product/${path}`;
  }

  async _throttle() {
    const wait = this._last + this.delayMs - Date.now();
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    this._last = Date.now();
  }

  _cookieHeader() {
    return [...this.cookies].map(([k, v]) => `${k}=${v}`).join("; ");
  }

  _storeCookies(res) {
    const set = res.headers.getSetCookie?.() ?? [];
    for (const line of set) {
      const [kv] = line.split(";");
      const i = kv.indexOf("=");
      if (i > 0) this.cookies.set(kv.slice(0, i).trim(), kv.slice(i + 1).trim());
    }
  }

  /** @returns {Promise<string>} */
  async request(url, { method = "GET", form, referer } = {}) {
    await this._throttle();
    const headers = { "User-Agent": UA, Cookie: this._cookieHeader() };
    if (referer) headers.Referer = referer;
    let body;
    if (form) {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      body = new URLSearchParams(form).toString();
    }
    const res = await fetch(url, { method, headers, body, redirect: "manual" });
    this._storeCookies(res);
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      if (!loc) throw new Error(`redirect without location: ${url}`);
      return this.request(new URL(loc, url).toString(), { referer });
    }
    if (!res.ok) throw new Error(`HTTP ${res.status} ${method} ${url}`);
    return res.text();
  }

  async login() {
    const ref = this.productUrl("");
    // 先 GET 一次拿平台的基本 cookie（實測沒有也能登，但保險）
    await this.request(ref);
    const html = await this.request(`${this.origin}/shop2000_prog/member/mem_login.aspx`, {
      method: "POST",
      referer: ref,
      form: {
        vdir: decodeURIComponent(this.vdir), // 表單欄位要原文
        http_ref: ref,
        email_mem: this.email,
        mem_pw: this.password,
      },
    });
    const m = html.match(/會員登入成功[^\\'"]*(?:\\n)*[^'"]*/);
    if (!/會員登入成功/.test(html)) {
      const msg = html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 200);
      throw new Error(`登入失敗：${msg || "(空白回應)"}`);
    }
    this.loggedIn = true;
    const level = (html.match(/會員等級：([^\\'"<]+)/) || [])[1]?.trim();
    this.log(`登入成功 ${this.email}${level ? `（${level}）` : ""}`);
    return { level, raw: m?.[0] };
  }

  async ensureLogin() {
    if (!this.loggedIn) await this.login();
  }

  /**
   * 抓一個分類（/product/<pc1sn>）的全部頁。
   * @param {string} pc1sn 分類 id（網址 /product/ 後面那串數字）
   * @param {object} [opts]
   * @param {number} [opts.maxPages]
   * @param {string} [opts.sub]   次分類 id（pc2sn），預設 all
   * @param {(html: string, page: number) => void} [opts.onRawPage]
   */
  async scrapeCategory(pc1sn, { maxPages = Infinity, sub = "all", onRawPage } = {}) {
    await this.ensureLogin();
    // 次分類：第一頁 GET /product/<pc1sn>/<pc2sn>，之後分頁 POST 帶 pc2sn（頁面本身會把 pc2sn 填回 form1）
    const url = this.productUrl(sub && sub !== "all" ? `${pc1sn}/${sub}` : pc1sn);
    let html = await this.request(url);
    if (/本分類需有權限方能瀏覽/.test(html)) {
      // cookie 失效 → 重登一次
      this.loggedIn = false;
      await this.login();
      html = await this.request(url);
      if (/本分類需有權限方能瀏覽/.test(html)) throw new Error(`登入後仍無權限瀏覽 ${url}`);
    }
    const first = parseListing(html, { baseUrl: url });
    onRawPage?.(html, 1);
    const pc2sn = first.sub || sub || "all";
    const items = [...first.items];
    const total = first.recordCount;
    const pageSize = first.items.length || 1;
    const pages = Math.min(maxPages, Math.max(1, Math.ceil(total / pageSize)));
    this.log(`分類 ${[first.category || pc1sn, first.subcategory].filter(Boolean).join(" / ")}：共 ${total} 筆 / ${pages} 頁`);
    for (let p = 2; p <= pages; p++) {
      const pageHtml = await this.request(url, {
        method: "POST",
        referer: url,
        form: { pc2sn, vorder_p: first.order || "", p: String(p), RecordCount: String(total) },
      });
      onRawPage?.(pageHtml, p);
      const parsed = parseListing(pageHtml, { baseUrl: url });
      this.log(`  第 ${p} 頁：${parsed.items.length} 筆`);
      items.push(...parsed.items);
    }
    // 同一筆不會出現兩次；萬一分頁期間商品排序變動，用 psn 去重
    const seen = new Set();
    const uniq = items.filter((it) => (seen.has(it.psn) ? false : (seen.add(it.psn), true)));
    // 列表裡藏的 <a href> 一律指向平台網域；輸出改用這家店自己的網域（自訂網域店家才對得上）
    for (const it of uniq) it.url = this.productUrl(`p${it.psn}`);
    return { ...first, items: uniq, pages };
  }

  /** 店家首頁 → 第一層分類清單（登入後才看得到「限」會員分類） */
  async discoverCategories() {
    await this.ensureLogin();
    const html = await this.request(this.storeHome || this.origin);
    const cats = parseCategories(html);
    this.log(`首頁找到 ${cats.length} 個分類：${cats.map((c) => `${c.name}${c.count != null ? `(${c.count})` : ""}`).join("、")}`);
    return cats;
  }

  /** 抓商品詳細頁 /product/p<psn> */
  async scrapeDetail(psn, { onRaw } = {}) {
    await this.ensureLogin();
    const url = this.productUrl(`p${psn}`);
    const html = await this.request(url);
    onRaw?.(html);
    return parseDetail(html, { url });
  }
}

/** 平台網域 www.shop2000.com.tw/店名/... → "/店名"（保持 URL encode）；自訂網域 → "" */
export function vdirOf(u) {
  if (u.hostname.toLowerCase() === "www.shop2000.com.tw") {
    const seg = u.pathname.split("/").filter(Boolean)[0];
    return seg ? `/${seg}` : "";
  }
  return "";
}

// ---------- 解析 ----------

export function stripTags(s) {
  return decodeEntities(
    String(s ?? "")
      .replace(/\r\n?/g, "\n")
      .replace(/<br\s*\/?>\s*/gi, "\n") // <br> 後面跟著的原始換行是排版用的，不算第二個換行
      .replace(/<\/(div|p|li|tr)>/gi, "\n")
      .replace(/<[^>]+>/g, ""),
  )
    .replace(/[ \t\u00a0]+/g, " ")
    .replace(/[ \t]*\n[ \t]*/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function decodeEntities(s) {
  return s
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)));
}

function num(s) {
  if (s == null) return null;
  const n = Number(String(s).replace(/[^\d.-]/g, ""));
  return Number.isFinite(n) ? n : null;
}

function attr(block, name) {
  const m = block.match(new RegExp(`\\b${name}=(?:'([^']*)'|"([^"]*)"|([^\\s>]+))`, "i"));
  return m ? (m[1] ?? m[2] ?? m[3]) : null;
}

/** 列表頁 */
export function parseListing(html, { baseUrl } = {}) {
  const title = stripTags((html.match(/<title>([^<]*)/i) || [])[1] || "");
  const category = stripTags((html.match(/<div class=p1_tl\s*>([^<]*)</) || [])[1] || "");
  const recordCount = num((html.match(/var RecordCount='(\d+)'/) || [])[1]) ?? 0;
  const order = (html.match(/document\.form1\.vorder_p\.value='([^']*)'/) || [])[1] || "";
  const sub = (html.match(/document\.form1\.pc2sn\.value='([^']*)'/) || [])[1] || "";
  // 次分類名稱：<option value='1209823' >⚡現貨速發(可下超過)...161
  let subcategory = null;
  if (sub && sub !== "all") {
    const m = html.match(new RegExp(`<option value='${sub}'\\s*>([^<]*)`));
    if (m) subcategory = stripTags(m[1]).replace(/\.\.\.\d+\s*$/, "").trim() || null;
  }

  const items = [];
  const parts = html.split(/<td class=p_td\s*>/);
  for (const block of parts.slice(1)) {
    const li = block.match(/<li psn=(\d+)\s*>([\s\S]*?)<\/li>/);
    if (!li) continue;
    const psn = li[1];
    const name = stripTags(li[2]);
    const img = block.match(/<img class='pimg'[^>]*>/);
    const imgPath = img ? attr(img[0], "imgPath") : null;
    const imgstr = img ? attr(img[0], "imgstr") : null;
    const src = img ? attr(img[0], "src") : null;
    const link = (block.match(/<a href='([^']*\/product\/p\d+)'/) || [])[1] || null;
    const shortDesc = stripTags((block.match(/<div class=pd_l\s*>([\s\S]*?)<\/div>/) || [])[1] || "");
    const prices = parsePriceBlock(block);
    const stock = parseStockBlock(block);
    const tags = [...block.matchAll(/<span class=tag_br\s*>([^<]*)</g)].map((m) => stripTags(m[1]));
    items.push({
      psn,
      name,
      url: link || (baseUrl ? new URL(`p${psn}`, baseUrl).toString() : null),
      image: src || null,
      images: imageList(imgPath, psn, imgstr),
      short_desc: shortDesc,
      ...prices,
      ...stock,
      tags,
    });
  }
  return { title, category, subcategory, recordCount, order, sub, items };
}

/**
 * 這個分類還能不能下單（以名稱判斷）。回傳跳過的理由，可以下單回 null。
 *   - 一律跳過：下架 / 不上架 / 待處理 / 待重盤 / 重盤後有欠 / 會員需知、須知、守則
 *   - 過期才跳過：「11/4 收單」「9/3結單」日期已過；「2026年9月商品」月份已過
 *   - 出清區不跳過（還能下單）
 * 年份沒寫的 M/D 用今年；離今天超過半年就當成去年 / 明年（12 月看到「1/5 收單」是明年）。
 */
export function skipCategoryReason(name, now = new Date()) {
  const n = String(name ?? "");
  const m0 = n.match(/下架|不上架|待處理|待重盤|重盤後有欠|會員需知|須知|守則/);
  if (m0) return `分類名稱含「${m0[0]}」`;
  // 台北時間的今天（只比日期）
  const tp = new Date(now.getTime() + 8 * 3600_000);
  const today = Date.UTC(tp.getUTCFullYear(), tp.getUTCMonth(), tp.getUTCDate());
  const md = n.match(/(\d{1,2})\s*\/\s*(\d{1,2})\s*(?:收單|結單|截止)/);
  if (md) {
    const mon = Number(md[1]) - 1, day = Number(md[2]);
    if (mon >= 0 && mon < 12 && day >= 1 && day <= 31) {
      let y = tp.getUTCFullYear();
      let t = Date.UTC(y, mon, day);
      const HALF_YEAR = 183 * 86400_000;
      if (t - today > HALF_YEAR) t = Date.UTC(y - 1, mon, day);
      else if (today - t > HALF_YEAR) t = Date.UTC(y + 1, mon, day);
      if (t < today) return `${md[1]}/${md[2]} 已過收單日`;
    }
  }
  const ym = n.match(/(20\d\d)\s*年\s*(\d{1,2})\s*月/);
  if (ym) {
    const cur = tp.getUTCFullYear() * 12 + tp.getUTCMonth();
    if (Number(ym[1]) * 12 + Number(ym[2]) - 1 < cur) return `${ym[1]}年${ym[2]}月 已過`;
  }
  return null;
}

/**
 * 店家首頁（或任一頁）左側選單的第一層分類。
 * 每個分類都有一個隱藏連結 <a style='display:none;' href='…/product/<id>'>名稱</a>，
 * 數量在 topcls 那一列的 <span class=pt9 >...25</span>。
 */
export function parseCategories(html) {
  const out = new Map();
  for (const m of html.matchAll(/<a style='display:none;'\s*href='[^']*\/product\/(\d+)'\s*>([^<]*)<\/a>/g)) {
    out.set(m[1], { pc1sn: m[1], name: stripTags(m[2]), count: null });
  }
  for (const m of html.matchAll(/topcls\('(\d+)',''\)[^>]*>([^<]*)(?:<span class=pt9\s*>\.\.\.(\d+)<\/span>)?/g)) {
    const c = out.get(m[1]) ?? { pc1sn: m[1], name: stripTags(m[2]), count: null };
    if (!c.name) c.name = stripTags(m[2]);
    if (m[3]) c.count = Number(m[3]);
    out.set(m[1], c);
  }
  return [...out.values()];
}

/** 圖片編號字串 '|1||2||3|' → 大圖網址清單 */
export function imageList(imgPath, psn, imgstr) {
  if (!imgPath || !imgstr) return [];
  return imgstr
    .split("||")
    .map((s) => s.replace(/\|/g, "").trim())
    .filter(Boolean)
    .map((n) => `${imgPath}/${psn}-${n}o.jpg`);
}

function parsePriceBlock(block) {
  const grab = (label) => {
    const m = block.match(new RegExp(`<LG>${label}</LG>\\s*<span class=price1>([^<]*)</span>`));
    return m ? num(m[1]) : null;
  };
  const original = block.match(/\(<LG>原價<\/LG>\s*([^)<]*)\)/);
  return {
    price_general: grab("一般價"),
    price_member: grab("會員價"),
    price_original: original ? num(original[1]) : null,
  };
}

function parseStockBlock(block) {
  // 有規格：<Div class='stk inblock showOp' spcOp='茶樹;櫻桃' spcStk='0;3'>庫存 <stkT0>0;3</stkT0>
  // 無規格：<div class='stk'>庫存 <stkT0>2</stkT0>
  // 沒顯示庫存：不限量或店家沒開
  const stk = block.match(/<[Dd]iv class='stk[^>]*>[\s\S]*?<stkT0>([^<]*)<\/stkT0>/);
  if (!stk) return { stock: null, options: [] };
  const head = stk[0].slice(0, stk[0].indexOf(">") + 1);
  const spcOp = attr(head, "spcOp");
  const spcStk = attr(head, "spcStk");
  if (spcOp != null && spcStk != null) {
    const names = spcOp.split(";");
    const stocks = spcStk.split(";");
    const options = names.map((n, i) => ({ name: decodeEntities(n.trim()), stock: num(stocks[i]) }));
    return { stock: options.reduce((a, o) => a + (o.stock ?? 0), 0), options };
  }
  return { stock: num(stk[1]), options: [] };
}

/** 商品詳細頁 */
export function parseDetail(html, { url } = {}) {
  const name = stripTags((html.match(/<span id=product_name>([\s\S]*?)<\/span>/) || [])[1] || "");
  const ogImage = (html.match(/property="og:image" content="([^"]*)"/) || [])[1] || null;
  const field = (label) => {
    const m = html.match(new RegExp(`<LG>${label}</LG>：<td class=p_tiem[^>]*>([\\s\\S]*?)(?=<tr>|</table>)`));
    return m ? m[1] : null;
  };
  const crumbsHtml = field("分類位置") || "";
  const breadcrumb = [...crumbsHtml.matchAll(/topcls\('(\d*)','(\d*)'\);\s*>([^<]*)</g)].map((m) => ({
    pc1sn: m[1] || null,
    pc2sn: m[2] || null,
    name: stripTags(m[3]),
  }));
  const code = field("商品代碼");
  const shortDesc = field("簡要說明");
  const stockField = field("庫存");
  const stockTotal = stockField ? num((stockField.match(/<stkT0>([^<]*)</) || [])[1]) : null;

  // 規格：<div class=pt11g>規格：</div> … <input type=radio name='FIELD0' value='茶樹舒緩'> 茶樹舒緩 … <stkT0>0</stkT0>
  const specHtml = field("規格") || "";
  const specGroups = [];
  for (const g of specHtml.split(/<div class=pt11g\s*>/).slice(1)) {
    const gname = stripTags(g.slice(0, g.indexOf("</div>"))).replace(/：$/, "");
    const opts = [...g.matchAll(/<input type=radio name='FIELD\d+' value='([^']*)'[^>]*>([\s\S]*?)(?=<Div class=spc_div|<\/div><\/div>|$)/g)].map(
      (m) => {
        const seg = m[2];
        const st = seg.match(/<stkT0>([^<]*)<\/stkT0>/);
        return {
          name: decodeEntities(m[1]),
          stock: st ? num(st[1]) : null,
          sold_out: /saleout/.test(seg),
        };
      },
    );
    specGroups.push({ name: gname, options: opts });
  }

  const priceBlock = (html.match(/<TABLE class=price_tb>[\s\S]*?<\/TABLE>/) || [])[0] || "";
  const prices = parsePriceBlock(priceBlock);

  const freeShip = html.match(/<div class='dis_mem'\s*>([\s\S]*?)<\/div>/);
  const shipping = [...(html.match(/貨運方式：[\s\S]*?<\/table>/) || [""])[0].matchAll(/<div class=tag_br[^>]*>([\s\S]*?)<\/div>/g)].map((m) =>
    stripTags(m[1]),
  );
  const payment = [...(html.match(/付款方式：[\s\S]*?<\/table>/) || [""])[0].matchAll(/<div class=tag_y[^>]*>([\s\S]*?)<\/div>/g)].map((m) =>
    stripTags(m[1]),
  );

  // 圖片：var imgstr = '|2||3||4|'; + imgArea 的路徑
  const imgstr = (html.match(/var imgstr = '([^']*)'/) || [])[1] || "";
  const imgBase = (html.match(/src=(https:\/\/img\d\.shop2000\.com\.tw\/\d+\/p\d+)\/(\d+)-'\+gno\+ 'o\.jpg/) || []);
  const psn = (url && url.match(/\/product\/p(\d+)/)?.[1]) || imgBase[2] || null;

  // 商品說明：<div class=shadow8 …><table class=tbFix100 …><td class='txtl'> … </table>
  const descHtml = (html.match(/<div class=shadow8[^>]*><table class=tbFix100[^>]*>[\s\S]*?<td class='txtl'\s*>([\s\S]*?)<\/table>/) || [])[1] || "";

  return {
    psn,
    name,
    url: url || null,
    product_code: code ? stripTags(code) : null,
    breadcrumb,
    category: breadcrumb[0]?.name || null,
    subcategory: breadcrumb[1]?.name || null,
    short_desc: shortDesc ? stripTags(shortDesc) : "",
    ...prices,
    stock: stockTotal,
    spec_groups: specGroups,
    free_shipping: freeShip ? stripTags(freeShip[1]) : null,
    shipping_methods: shipping,
    payment_methods: payment,
    image: ogImage,
    images: imageList(imgBase[1], psn, imgstr),
    description: stripTags(descHtml),
    description_html: descHtml.trim(),
  };
}

// ---------- 平台 adapter（給 cli.mjs 用的統一介面） ----------
//
// 每個平台檔案都要 export 一個 `platform`：
//   name            平台 key（vendors.json 的 platform 欄）
//   match(url)      這個網址是不是這個平台（--url 沒指定平台時自動判斷）
//   createClient({ url, email, password, delayMs, log })
//     .login()                      測登入
//     .scrape(url, { maxPages, limit, onRaw })  回 { category, items: [標準欄位列] }
//
// 標準欄位列（所有平台都要對齊這一套，CSV 欄位順序見 output.mjs）：
//   psn, product_code, name, category, subcategory, price_general, price_member, price_original,
//   stock, options[], spec, short_desc, tags[], free_shipping, shipping_methods[], payment_methods[],
//   image, images[], url, description, description_html

function toRow(item, detail) {
  const options = detail?.spec_groups?.length
    ? detail.spec_groups.flatMap((g) => g.options.map((o) => `${o.name}${o.stock != null ? `=${o.stock}` : ""}`))
    : item.options.map((o) => `${o.name}${o.stock != null ? `=${o.stock}` : ""}`);
  return {
    psn: item.psn,
    product_code: detail?.product_code ?? null,
    name: item.name || detail?.name,
    category: detail?.category ?? null,
    subcategory: detail?.subcategory ?? null,
    price_general: detail?.price_general ?? item.price_general,
    price_member: detail?.price_member ?? item.price_member,
    price_original: detail?.price_original ?? item.price_original,
    stock: detail?.stock ?? item.stock,
    options,
    spec: detail?.spec_groups ?? null,
    short_desc: detail?.short_desc || item.short_desc,
    tags: item.tags,
    free_shipping: detail?.free_shipping ?? null,
    shipping_methods: detail?.shipping_methods ?? [],
    payment_methods: detail?.payment_methods ?? [],
    image: detail?.image || item.image,
    images: detail?.images?.length ? detail.images : item.images,
    url: item.url,
    description: detail?.description ?? null,
    description_html: detail?.description_html ?? null,
  };
}

const EMPTY_ITEM = (psn, url) => ({ psn, name: "", url, image: null, images: [], short_desc: "", tags: [], options: [], stock: null, price_general: null, price_member: null, price_original: null });

export const platform = {
  name: "shop2000",
  match(url) {
    const u = new URL(url);
    return u.hostname.toLowerCase() === "www.shop2000.com.tw" || /\/product\/(p\d+|\d+(\/\d+)?)\/?$/.test(u.pathname);
  },
  createClient(opts) {
    const client = new Shop2000Client(opts);
    const api = {
      login: () => client.login(),
      /** url 是分類（/product/<id>）或單一商品（/product/p<id>） */
      async scrape(url, { maxPages = Infinity, limit, detail = true, onRaw, includeAll = false } = {}) {
        const m = new URL(url).pathname.match(/\/product\/(p?)(\d+)(?:\/(\d+))?\/?$/);
        if (!m) {
          // 店家首頁（沒有 /product/…）或 /product/all（全店）→ 自動找出所有分類，逐一抓
          const path = new URL(url).pathname;
          if (/\/product\//.test(path) && !/\/product\/all\/?$/i.test(path)) {
            throw new Error(`看不懂的 shop2000 網址（要店家首頁、/product/<分類id>[/<次分類id>] 或 /product/p<商品id>）：${url}`);
          }
          const found = await client.discoverCategories();
          if (!found.length) throw new Error(`首頁找不到任何分類：${url}`);
          const cats = includeAll ? found : found.filter((c) => {
            const why = skipCategoryReason(c.name);
            if (why) client.log(`跳過分類「${c.name}」：${why}`);
            return !why;
          });
          const all = [];
          const seen = new Set();
          for (const c of cats) {
            const r = await api.scrape(client.productUrl(c.pc1sn), { maxPages, limit, detail, onRaw, includeAll });
            for (const row of r.items) if (!seen.has(row.psn)) { seen.add(row.psn); all.push(row); }
          }
          return { category: null, items: all };
        }
        let items;
        let category = null;
        let subcategory = null;
        if (m[1] === "p") {
          items = [EMPTY_ITEM(m[2], client.productUrl(`p${m[2]}`))];
        } else {
          const sub = m[3] || "all";
          const listing = await client.scrapeCategory(m[2], { maxPages, sub, onRawPage: (html, p) => onRaw?.(`list-${m[2]}-${sub}-p${p}.html`, html) });
          category = listing.category;
          subcategory = listing.subcategory;
          items = listing.items;
        }
        if (limit) items = items.slice(0, Number(limit));
        const rows = [];
        for (let i = 0; i < items.length; i++) {
          const it = items[i];
          let d = null;
          if (detail) {
            try {
              d = await client.scrapeDetail(it.psn, { onRaw: (html) => onRaw?.(`p${it.psn}.html`, html) });
              if (!d.category && category) d.category = category;
            } catch (e) {
              client.log(`詳細頁失敗 p${it.psn}：${e.message}`);
            }
            if ((i + 1) % 20 === 0 || i === items.length - 1) client.log(`詳細頁 ${i + 1}/${items.length}`);
          } else if (category) {
            it.category = category;
          }
          const row = toRow(it, d);
          if (!row.category) row.category = category;
          if (!row.subcategory) row.subcategory = subcategory;
          rows.push(row);
        }
        if (includeAll) return { category, items: rows };
        // 商品自己掛的分類 / 次分類過期了也不要（例：統一「2026年9月商品 / 9/3結單商品」）
        const kept = rows.filter((r) => {
          const why = skipCategoryReason(r.category) || skipCategoryReason(r.subcategory);
          return !why;
        });
        if (kept.length < rows.length) client.log(`過濾掉 ${rows.length - kept.length} 筆（分類已下架 / 已過收單日）`);
        return { category, items: kept };
      },
    };
    return api;
  },
};

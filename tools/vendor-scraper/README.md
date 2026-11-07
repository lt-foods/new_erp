# vendor-scraper — 廠商網站商品爬蟲

用會員帳號登入廠商網站，把分類列表（含分頁）＋每個商品的詳細頁抓下來，輸出 JSON / CSV。
跑在自己電腦上，不碰主站、不寫 DB。零依賴（Node 22+ 內建 fetch）。

**平台 adapter 制**：廠商站多半開在某個電商平台上，同平台的站長得一樣。一個平台寫一支
`src/platforms/<name>.mjs`，`vendors.json` 一家廠商一筆（平台 + 網址清單），要加新廠商 /
新頁面只改 `vendors.json`。目前有：

| 平台 | 廠商 | 備註 |
|---|---|---|
| `shop2000` | 辛普森德日韓 `www.simpsons.com.tw`、有鮮實業 `www.shop2000.com.tw/有鮮實業`、晨一 `www.shop2000.com.tw/one999`、人和 `www.shop2000.com.tw/人和食緣食品批發`、YCB `www.shop2000.com.tw/youcanbuy2`、全富 `www.shop2000.com.tw/全富水產`、金鑽 `www.shop2000.com.tw/FDG`、女王家 `www.shop2000.com.tw/queenhouse`、金賀家 `www.shop2000.com.tw/聯合行銷`、米嵐 `www.shop2000.com.tw/米嵐各國批發`、173批發 `www.shop2000.com.tw/naomi8888`、富士山 `www.shop2000.com.tw/japanshop999`、康名 `www.shop2000.com.tw/飛天寶`、統一 `lansoneshop`、艾雅 `aya`、億品鄉、兆洋水產行團購批發 | 沒登入看不到任何商品；價格依會員等級（辛普森「VVIP 轉批等級」、有鮮「超級VVIP」） |

LINE 記事本那支在 `tools/line-note-scraper/`，是另一條線（LINE 非官方協定），不在這裡。

## 安裝

```bash
cd tools/vendor-scraper
cp .env.example .env     # 填帳密
```

## 使用

```bash
npm run vendors                      # 列出 vendors.json 的廠商 / 平台 / 網址
npm run login                        # 只測登入（每家都登一次）
npm run scrape                       # 每一家：所有網址的列表 + 每個商品詳細頁
npm run scrape -- youxian            # 只抓有鮮
npm run scrape -- simpsons --no-detail           # 只抓列表（快很多；沒有商品代碼 / 說明 / 運送方式）
npm run scrape -- simpsons --limit 5 --pages 1 --raw   # 試跑：前 5 筆，順便存原始 HTML
node src/cli.mjs scrape --url 'https://www.shop2000.com.tw/有鮮實業/product/p62295130' --vendor youxian   # 臨時抓一頁
```

預設跳過已經不能下單的分類：名稱含下架 / 不上架 / 待處理 / 待重盤 / 會員需知、守則，
或「M/D 收單」「YYYY年M月」已經過了的（出清區照抓）。要全抓加 `--include-all`。

選項：`--out <dir>`（預設 `out/`）、`--delay <ms>`（每個請求間隔，預設 400）、`--pages N`、`--limit N`、
`--raw`、`--no-detail`、`--images main|all`（下載圖片）、
`--url <網址>`（配 `--vendor <key>` 用那家的帳號與名稱；不在清單的平台用 `--platform`）。

圖片：商品圖是公開網址（不用登入），CSV / JSON 裡本來就有 `image`（主圖）/ `images`（全部大圖）。
要檔案本身加 `--images main`（每個商品一張主圖，辛普森 388 筆約 80MB）或 `--images all`
（全部大圖，辛普森 2,400 多張、約 500MB），存到 `images/<psn>-<n>.jpg`，`image_files` 欄回填相對路徑。
已經抓好的結果事後補圖：`node src/cli.mjs images out/<vendor>/<時間>/products.json --mode all`。

輸出：`out/<vendor>/<時間>/products.json`、`products.csv`（有 BOM，Excel 直接開）。`out/` 已 gitignore。
同一家列了多個網址時合併成一份，同一個商品出現在兩個分類只留一筆（`source_url` 記第一次出現的網址）。

## 帳密

`.env`：

- 平台共用：`SHOP2000_EMAIL` / `SHOP2000_PASSWORD`（`<PLATFORM>_EMAIL`，平台名大寫）
- 某家另外的帳號：`VENDOR_YOUXIAN_EMAIL` / `VENDOR_YOUXIAN_PASSWORD`（`VENDOR_<KEY>_…`，key 大寫、非英數改底線），優先於平台共用。

## 新增廠商 / 新頁面

`vendors.json`：

```json
"xxx": {
  "name": "廠商名",
  "platform": "shop2000",
  "urls": [
    "https://www.shop2000.com.tw/店名/product/<分類id>",
    "https://www.shop2000.com.tw/店名/product/<另一個分類id>",
    "https://www.shop2000.com.tw/店名/product/p<商品id>"
  ]
}
```

shop2000 的網址：店家首頁（`www.shop2000.com.tw/店名`）或 `/product/all` 會自動找出所有分類逐一抓；`/product/<數字>` 是分類（抓整個分類含分頁）、`/product/<數字>/<數字>` 是分類下的某個次分類、`/product/p<數字>` 是單一商品。
`platform` 不填會用網址猜（shop2000：平台網域或 `/product/<數字>` 結尾）。

## 新增平台

1. `src/platforms/<name>.mjs`，export `platform = { name, match(url), createClient({ url, email, password, delayMs, log }) }`，
   client 要有 `login()` 和 `scrape(url, { maxPages, limit, detail, onRaw })` → `{ category, items }`。
   `items` 每列要對齊標準欄位（見 `shop2000.mjs` 底部註解 / 下表），CLI 跟輸出層完全不認平台。
2. 在 `src/platforms/index.mjs` 登記。
3. 加 `<name>.test.mjs`（用去識別化的 HTML 片段，不要 commit 整頁）。

## 欄位

| 欄位 | 說明 |
|---|---|
| `vendor` / `vendor_key` / `source_url` | 廠商、key、從哪個網址抓到的 |
| `psn` | 平台商品 id（shop2000：網址 `/product/p<psn>`） |
| `product_code` | 廠商自己的商品代碼（有鮮有、辛普森大多沒填） |
| `name` / `short_desc` | 品名、簡要說明（效期、箱規常寫在這） |
| `category` / `subcategory` | 分類麵包屑 |
| `price_general` / `price_member` / `price_original` | 一般價 / 會員價（本帳號等級）/ 原價；沒顯示的是 `null` |
| `stock` / `options` | 總庫存；有規格時每個規格的庫存（`"茶樹=0 | 櫻桃=3"`）。店家沒開庫存顯示 → `null`（不是 0） |
| `spec` | 規格群組原始結構（只在 JSON） |
| `tags` / `free_shipping` | 「40件免運」標籤、免運規則全文 |
| `shipping_methods` / `payment_methods` | 貨運 / 付款方式 |
| `image` / `images` / `image_files` | 主圖網址、全部大圖網址、下載後的本機路徑（有 `--images` 才有） |
| `description` / `description_html` | 商品說明純文字 / 原始 HTML（只在 JSON） |

## shop2000 平台細節（改解析時看）

- 登入：POST `/shop2000_prog/member/mem_login.aspx`，欄位 `email_mem / mem_pw / vdir / http_ref`。
  成功回一段含「會員登入成功」的 HTML，cookie 是 `msn<storeId>` / `msn_chk<storeId>`。
  自訂網域（simpsons.com.tw）的 `vdir` 是空字串，平台網域是 `/店名`。
- 分頁不是 GET 參數：對同一個分類網址 **POST** `form1`（`p` / `RecordCount` / `pc2sn=all` / `vorder_p`），每頁 40 筆。
- HTML 大量不閉合標籤（`<td` 沒 `</td>`），所以不用 DOM parser，全部字串切：
  列表用 `<td class=p_td>` 切塊，詳細頁用 `<LG>欄名</LG>：<td class=p_tiem>` 定位。
- 列表裡的 `<a href>` 一律指向 `www.shop2000.com.tw/店名/…`，就算店家有自訂網域；輸出改用該店自己的網域。
- 規格的「每規格價格」是前端 `gen_option()` 動態算的（`spcPriceVir`），HTML 裡沒有，目前不抓。
- 在 Claude Code 雲端環境跑要加 `NODE_USE_ENV_PROXY=1`（Node 內建 fetch 預設不走 HTTPS_PROXY）。

## 測試

```bash
npm test
```

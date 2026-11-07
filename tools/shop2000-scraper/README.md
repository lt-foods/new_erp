# shop2000-scraper — 廠商商品爬蟲（shop2000 平台）

把開在 **shop2000** 平台上的廠商網站（辛普森德日韓 `www.simpsons.com.tw`、有鮮實業
`www.shop2000.com.tw/有鮮實業` …）用會員帳號登入後，整個分類的商品連同詳細頁抓下來，
輸出 JSON / CSV。跑在自己電腦上，不碰主站、不寫 DB。零依賴（Node 22+ 內建 fetch）。

這些站**沒登入看不到任何商品**（「本分類需有權限方能瀏覽」），會員等級不同價格也不同
（目前帳號在辛普森是「VVIP 轉批等級」、有鮮是「超級VVIP」），所以抓到的 `price_member`
是這個帳號看到的批價。

## 安裝

```bash
cd tools/shop2000-scraper
cp .env.example .env     # 填 SHOP2000_EMAIL / SHOP2000_PASSWORD
```

## 使用

```bash
npm run login                       # 只測登入（兩家都登一次）
npm run scrape                      # vendors.json 裡每一家：分類列表 + 每個商品詳細頁
npm run scrape -- youxian           # 只抓有鮮
npm run scrape -- simpsons --no-detail       # 只抓列表（快很多；沒有商品代碼 / 說明 / 運送方式）
npm run scrape -- simpsons --limit 5 --pages 1 --raw   # 試跑：前 5 筆，順便存原始 HTML
node src/cli.mjs scrape --url 'https://www.shop2000.com.tw/有鮮實業/product/p62295130'   # 單一商品或任一分類
```

選項：`--out <dir>`（預設 `out/`）、`--delay <ms>`（每個請求間隔，預設 400）、`--pages N`、`--limit N`、`--raw`。

輸出：`out/<vendor>/<時間>/products.json`、`products.csv`（有 BOM，Excel 直接開）。
`out/` 已 gitignore。

## 欄位

| 欄位 | 來源 | 說明 |
|---|---|---|
| `psn` | 列表 | shop2000 商品 id（網址 `/product/p<psn>`） |
| `product_code` | 詳細 | 廠商自己的商品代碼（有鮮有、辛普森大多沒填） |
| `name` / `short_desc` | 列表 | 品名、簡要說明（效期、箱規常寫在這） |
| `category` / `subcategory` | 詳細 | 分類位置麵包屑 |
| `price_general` / `price_member` / `price_original` | 列表＋詳細 | 一般價 / 會員價（本帳號等級）/ 原價；沒顯示的是 `null` |
| `stock` / `options` | 列表＋詳細 | 總庫存；有規格時每個規格的庫存（`"茶樹=0 | 櫻桃=3"`）。店家沒開庫存顯示 → `null`（不是 0） |
| `spec` | 詳細 | 規格群組原始結構（只在 JSON） |
| `tags` / `free_shipping` | 列表 / 詳細 | 「40件免運」標籤、免運規則全文 |
| `shipping_methods` / `payment_methods` | 詳細 | 貨運 / 付款方式 |
| `image` / `images` | 列表＋詳細 | 主圖、全部大圖（`-<n>o.jpg`） |
| `description` / `description_html` | 詳細 | 商品說明純文字 / 原始 HTML |

## 新增一家廠商

只要是 shop2000 平台（網址有 `/product/<數字>`、登入表單打 `/shop2000_prog/member/mem_login.aspx`），
在 `vendors.json` 加一筆就好：

```json
"xxx": { "name": "廠商名", "url": "https://www.shop2000.com.tw/店名/product/<分類id>" }
```

`url` 給**分類**網址會抓整個分類（含分頁）；給 `/product/p<psn>` 只抓那一個商品。
要用不同帳號登那家：`.env` 加 `SHOP2000_XXX_EMAIL` / `SHOP2000_XXX_PASSWORD`。

不是 shop2000 的廠商（自架站、其他平台）要另外寫 client，`src/shop2000.mjs` 的
`parseListing` / `parseDetail` 不會對得上。

## 平台細節（改解析時看）

- 登入：POST `/shop2000_prog/member/mem_login.aspx`，欄位 `email_mem / mem_pw / vdir / http_ref`。
  成功回一段含「會員登入成功」的 HTML，cookie 是 `msn<storeId>` / `msn_chk<storeId>`。
  自訂網域（simpsons.com.tw）的 `vdir` 是空字串，平台網域是 `/店名`。
- 分頁不是 GET 參數：對同一個分類網址 **POST** `form1`（`p` / `RecordCount` / `pc2sn=all` / `vorder_p`），
  每頁 40 筆。
- HTML 大量不閉合標籤（`<td` 沒 `</td>`、`<tr>` 直接接下一個 `<tr>`），所以不用 DOM parser，
  全部字串切：列表用 `<td class=p_td>` 切塊，詳細頁用 `<LG>欄名</LG>：<td class=p_tiem>` 定位。
- 列表裡的 `<a href>` 一律指向 `www.shop2000.com.tw/店名/…`，就算店家有自訂網域；輸出改用該店自己的網域。
- 規格的「每規格價格」是前端 `gen_option()` 動態算的（`spcPriceVir`），HTML 裡沒有，目前不抓。
- 在 Claude Code 雲端環境跑要加 `NODE_USE_ENV_PROXY=1`（Node 內建 fetch 預設不走 HTTPS_PROXY）。

## 測試

```bash
npm test     # 解析器單元測試（用去識別化的 HTML 片段）
```

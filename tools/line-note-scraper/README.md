# line-note-scraper — LINE 記事本留言爬蟲

把 LINE **群組**／**社群（OpenChat）** 記事本裡的貼文與留言抓下來，順手把「+1」解析成訂單行，輸出 JSON / CSV。跑在自己電腦上，不碰主站。

> ⚠️ 走的是 LINE **非官方**客戶端協定（[linejs](https://github.com/evex-dev/linejs)），違反 LINE 使用條款、帳號可能被停權。
> **只能用備用帳號**，把那支帳號拉進要抓的群組／社群就好，不要用本人或公司主帳號。

## 安裝（Node 22+）

```bash
cd tools/line-note-scraper
npx jsr add @evex/linejs      # 會寫 .npmrc（@jsr registry）並補 package.json 相依
npm install
```

## 使用

```bash
npm run login                       # 印出 QR，用備用帳號的手機掃；再輸入畫面上的 PIN
npm run groups                      # 列出群組(c…) / 社群(s…) / 社群聊天室(m…) 的 homeId
npm run posts -- <homeId>           # 最近 20 篇貼文
npm run comments -- <homeId> <postId>
npm run scrape -- <homeId> --since 2026-09-01     # 全部貼文 + 留言 → out/<homeId>/<時間>/
```

輸出檔：

| 檔案 | 內容 |
|---|---|
| `posts.json` / `comments.json` | 正規化後的貼文與留言（含 `raw` 原始回應） |
| `comments.csv` | 一則留言一列 |
| `orders.csv` | 解析出來的 +1（一筆一列：貼文、留言者、品項代碼、數量、是否取消、原文） |
| `summary.csv` | 每篇貼文 × 品項代碼的數量小計 |

+1 的寫法支援 `+1`、`＋２`、`A+1`、`B-2 +1`、`+1 A`、`A x2`、`A 2份`、`2份`、`-1` / `取消 A+1`（負數）。
規則在 `src/parse.mjs`，測試 `npm test`。純數字、`A2` 這種分不清品號還是數量的**不猜**，留給人看 `comments.csv`。

## 打不通的時候

第一次一定加 `--verbose`：

```bash
node src/cli.mjs posts <homeId> --verbose
```

記事本 API 沒有 wire trace，程式會依序試 host × 路徑前綴 × channel，第一組回 `code: 0` 的就記住。
全部失敗會把每次嘗試印出來，整段貼回來就能調。也可以用環境變數硬指定：

| 變數 | 說明 |
|---|---|
| `LINE_DEVICE` | 模擬的裝置，預設 `ANDROIDSECONDARY`（`DESKTOPWIN` 拿不到 channel token） |
| `LINE_NOTE_HOST` | 記事本 host，候選：登入用的 endpoint、`gw.line.naver.jp`、`ga2.line.naver.jp` |
| `LINE_NOTE_PREFIX` | 路徑前綴：群組 `/mh` 或 `/ext/note/nt`，社群 `/sn` |
| `LINE_NOTE_CHANNEL` | channel id：HOME `1341209850`、TIMELINE `1341209950`、NOTE `1655599932`、SQUARE_NOTE `1657618623` |
| `LINE_STORAGE` | token 存放檔，預設 `./storage.json`（**不要 commit**） |

回應欄位名沒實測過，`normalizePost` / `normalizeComment` 寫成寬鬆版；欄位對不上時開 `--raw`，看 `raw.json` 再對。

## 身分辨識

- 群組：留言帶留言者的 LINE mid（`u…`）＋當下暱稱。
- 社群：只有社群成員 id（`p…`）＋社群暱稱，**拿不到真實帳號**。要歸戶只能靠暱稱對會員，或讓客人自己點連結綁定。

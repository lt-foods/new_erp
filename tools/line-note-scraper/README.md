# line-note-scraper — LINE 記事本留言爬蟲

把 LINE **群組**／**社群（OpenChat）** 記事本裡的貼文與留言抓下來，順手把「+1」解析成訂單行，輸出 JSON / CSV。跑在自己電腦上，不碰主站。

> ⚠️ 走的是 LINE **非官方**客戶端協定（[linejs](https://github.com/evex-dev/linejs)），違反 LINE 使用條款、帳號可能被停權。
> **只能用備用帳號**，把那支帳號拉進要抓的群組／社群就好，不要用本人或公司主帳號。

## 安裝（Node 22+）

```bash
cd tools/line-note-scraper
npm install
```

`.npmrc`（`@jsr:registry`）已經 commit 進來了，直接 `npm install` 就好。
**不要再跑 `npx jsr add @evex/linejs`** —— 這個 repo 根目錄有 package.json，
jsr 會把 `.npmrc` 寫到 **repo 根目錄**而不是這個資料夾，而 npm 只讀 cwd 的 `.npmrc`
（不會往上層找），於是 `@jsr/evex__linejs` 照樣去打 registry.npmjs.org、回 404 Not Found。

## 使用

```bash
npm run login                       # 印出 QR，用備用帳號的手機掃；再輸入畫面上的 PIN
npm run groups                      # 列出群組(c…) / 社群(s…) / 社群聊天室(m…) 的 homeId
npm run posts -- <homeId>           # 最近 20 篇貼文
npm run comments -- <homeId> <postId>
npm run scrape -- <homeId> --since 2026-09-01     # 全部貼文 + 留言 → out/<homeId>/<時間>/
```

發文到記事本（文字＋圖片）：

```bash
node src/cli.mjs post <homeId> --text "🍓 草莓開團
A 大盒 250
B 小盒 150
留言 A+1 / B+2"
node src/cli.mjs post <homeId> --file post.txt --image 1.jpg --image 2.jpg   # 圖片要 JPEG
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

## 接後台（worker 模式）

後台「設定 → LINE 記事本」頁面負責帳號登入、社群設定、看留言結果；真的跟 LINE 講話的是這支 worker，
跑在你自己的電腦或 VPS 上，用 service_role 輪詢 `line_note_jobs`。

```bash
cp .env.example .env      # 填 SUPABASE_URL、SUPABASE_SERVICE_ROLE_KEY
npm run worker
```

流程：

1. 後台 → 帳號 → 新增 → 登入：worker 把 QR 寫進 DB，後台顯示，備用帳號手機掃、輸入 PIN。
2. 後台 → 社群設定 → 新增：選帳號、按「從帳號載入清單」挑社群（m…）、選渠道（決定取貨店）、讀留言時間、開團自動發文。
3. 開團：團的狀態變成「開團中」且有勾到該渠道 → 自動排一篇貼文（套模板，A/B/C 依開團品項順序）。
4. 到讀留言時間（或按「立即讀取」）：worker 讀留言 → 抓「會員編號 6 碼 + A+1」→ `rpc_line_note_apply_comment` 用既有加單 RPC 建單。
5. 後台 → 貼文與留言：看每則留言的結果，「找不到會員」「錯誤」可重試或忽略。

worker 一次只跑一支，多個帳號各自有 `storage/account-<id>.json`。登出會清 token。

## 部署到雲端（worker 常駐）

worker 是一支要一直活著的 Node 程序，**Supabase / Vercel / GitHub Pages 跑不了**。
要能跑常駐程序的機器。建議放台灣（LINE 帳號從國外 IP 上線容易被鎖）。

### A. 自己一台 VM（推薦：GCP asia-east1 彰化，e2-micro 免費額度就夠）

1. 開一台 Ubuntu 22.04/24.04，SSH 進去。
2. 一鍵裝：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/lt-foods/new_erp/main/tools/line-note-scraper/deploy/setup-vm.sh | bash
   ```
3. 填 `~/new_erp/tools/line-note-scraper/.env`（`SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`），然後
   ```bash
   cd ~/new_erp/tools/line-note-scraper && docker compose up -d --build && docker compose logs -f
   ```
4. 後台「LINE 記事本 → 帳號 → 登入」掃 QR。token 存在 docker volume，重開機不用重掃。

更新程式：`cd ~/new_erp && git pull && cd tools/line-note-scraper && docker compose up -d --build`

### B. Fly.io（沒台灣機房，用東京）

`fly.toml` 已備好，照檔頭的指令跑。

### 環境變數

跟本機一樣（`.env.example`）。雲端不用 `.env`，直接設在平台上：
`SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`，可選 `LINE_POST_MAX_IMAGES`、`VERBOSE=1`。

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

# 社群推廣連結 — 設定與清單

`/join` 是給社群流量的註冊落地頁（一顆 LINE 按鈕完成註冊）。這份文件是拿去推廣時
要用的東西：縮網址怎麼設、每個社群發哪一條、事後怎麼看成效。

---

## 1. 縮網址用 PicSee（pse.is）

比較過台灣幾家之後選它，理由是這三點剛好命中我們的情況：

1. **預設會沿用目標頁的預覽卡** —— 我們已經在 `/join` 設好 OG（標題／說明／店家 banner），
   PicSee 預設就是抓目標網頁的圖文，不用重設；真的想針對某個社群換標題換圖也能自己覆蓋。
2. **建完之後還能改目標網址** —— 這點很重要。之後如果換自訂網域、或 `/join` 改路徑，
   已經貼出去的連結不用重發（is.gd / TinyURL 免費版做不到，貼出去就定生死）。
3. **有點擊統計 + QR code** —— 實體 DM 直接用它產的 QR，不用另外找工具。

> 註冊：<https://picsee.io> → 免費帳號即可。全部功能免費，不需要付費方案。

### 設定步驟

1. 註冊 PicSee 帳號（建議用公司共用信箱，不要綁個人）
2. 貼下面第 3 節的**原始連結**進去 → 產生短網址
3. 短碼建議自己指定成看得懂的，例如 `pse.is/baozima-zhonghe`，別用隨機碼
4. 預覽卡先不要動 —— 讓它抓 `/join` 的 OG 就好；確認預覽長對了再考慮客製
5. 各社群發各自那一條（**不要**全部共用一條，不然分不出成效）

### ⚠️ 一個絕對不能踩的雷

**縮網址只能用在 `/join` 這種一般網頁，不可以拿去縮 `https://liff.line.me/...` 的 LIFF 連結。**

縮網址本質上是跨網域 302，而 LIFF 一跨出註冊的 Endpoint 網域，context 就沒了
（`isInClient()` 變 false、沒有自動登入、LINE 還會跳「此為外部網站」），
接下來任何登入動作都是 400 —— 這個坑 2026-08 已經踩過一次，細節見 CLAUDE.md 的
「LIFF app 的 Endpoint URL 必須跟會員站同網域」。

`/join` 不受影響：它走的是自家 OAuth（`line-oauth-start`），完全不碰 LIFF SDK。

---

## 2. src 命名規則

`?src=` 是事後分辨「哪個社群帶得進人」的唯一依據，規則只有兩條：

- **一律用英數與連字號**，不要用中文。中文會被 percent-encode 成一長串亂碼，
  貼原始連結時很難看，之後查 log 也難對。
- 格式 `<平台>-<地區或社群>`，例如 `fb-zhonghe`、`line-banqiao`、`ig`。

---

## 3. 連結清單（貼這些去 PicSee 縮）

### A. 通用連結（不指定門市，客人自己選）

| 用途 | src | 原始連結 |
| --- | --- | --- |
| FB 社團 / 粉專 | `fb` | `https://new-erp-admin.vercel.app/join?src=fb` |
| LINE 群組 / 官方帳號 | `line` | `https://new-erp-admin.vercel.app/join?src=line` |
| IG 限動 / 個人簡介 | `ig` | `https://new-erp-admin.vercel.app/join?src=ig` |
| 實體 DM / 海報 QR | `qr` | `https://new-erp-admin.vercel.app/join?src=qr` |

### B. 各門市專屬連結（門市已帶好，客人點進去直接按註冊）

| 門市 | store code | src | 原始連結 |
| --- | --- | --- | --- |
| 三峽店 | `LELE-三峽` | `fb-sanxia` | `https://new-erp-admin.vercel.app/join?store=LELE-%E4%B8%89%E5%B3%BD&src=fb-sanxia` |
| 中和店 | `LELE-中和` | `fb-zhonghe` | `https://new-erp-admin.vercel.app/join?store=LELE-%E4%B8%AD%E5%92%8C&src=fb-zhonghe` |
| 南平店 | `LELE-南平` | `fb-nanping` | `https://new-erp-admin.vercel.app/join?store=LELE-%E5%8D%97%E5%B9%B3&src=fb-nanping` |
| 古華店 | `LELE-古華` | `fb-guhua` | `https://new-erp-admin.vercel.app/join?store=LELE-%E5%8F%A4%E8%8F%AF&src=fb-guhua` |
| 四號店 | `LELE-四號` | `fb-sihao` | `https://new-erp-admin.vercel.app/join?store=LELE-%E5%9B%9B%E8%99%9F&src=fb-sihao` |
| 忠順店 | `LELE-忠順` | `fb-zhongshun` | `https://new-erp-admin.vercel.app/join?store=LELE-%E5%BF%A0%E9%A0%86&src=fb-zhongshun` |
| 文山店 | `LELE-文山` | `fb-wenshan` | `https://new-erp-admin.vercel.app/join?store=LELE-%E6%96%87%E5%B1%B1&src=fb-wenshan` |
| 板橋店 | `LELE-板橋` | `fb-banqiao` | `https://new-erp-admin.vercel.app/join?store=LELE-%E6%9D%BF%E6%A9%8B&src=fb-banqiao` |
| 林口店 | `LELE-林口` | `fb-linkou` | `https://new-erp-admin.vercel.app/join?store=LELE-%E6%9E%97%E5%8F%A3&src=fb-linkou` |
| 永和店 | `LELE-永和` | `fb-yonghe` | `https://new-erp-admin.vercel.app/join?store=LELE-%E6%B0%B8%E5%92%8C&src=fb-yonghe` |
| 泰山店 | `LELE-泰山` | `fb-taishan` | `https://new-erp-admin.vercel.app/join?store=LELE-%E6%B3%B0%E5%B1%B1&src=fb-taishan` |
| 淡水店 | `LELE-淡水` | `fb-danshui` | `https://new-erp-admin.vercel.app/join?store=LELE-%E6%B7%A1%E6%B0%B4&src=fb-danshui` |
| 湖口店 | `LELE-湖口` | `fb-hukou` | `https://new-erp-admin.vercel.app/join?store=LELE-%E6%B9%96%E5%8F%A3&src=fb-hukou` |
| 環球店 | `LELE-環球` | `fb-huanqiu` | `https://new-erp-admin.vercel.app/join?store=LELE-%E7%92%B0%E7%90%83&src=fb-huanqiu` |
| 萬華店 | `LELE-萬華` | `fb-wanhua` | `https://new-erp-admin.vercel.app/join?store=LELE-%E8%90%AC%E8%8F%AF&src=fb-wanhua` |
| 經國店 | `LELE-經國` | `fb-jingguo` | `https://new-erp-admin.vercel.app/join?store=LELE-%E7%B6%93%E5%9C%8B&src=fb-jingguo` |
| 龍潭店 | `LELE-龍潭` | `fb-longtan` | `https://new-erp-admin.vercel.app/join?store=LELE-%E9%BE%8D%E6%BD%AD&src=fb-longtan` |
| 全民 | `QM-全民` | `fb-quanmin` | `https://new-erp-admin.vercel.app/join?store=QM-%E5%85%A8%E6%B0%91&src=fb-quanmin` |
| 平鎮店 | `S001` | `fb-pingzhen` | `https://new-erp-admin.vercel.app/join?store=S001&src=fb-pingzhen` |
| 松山店 | `S002` | `fb-songshan` | `https://new-erp-admin.vercel.app/join?store=S002&src=fb-songshan` |

> 門市代號含中文（`LELE-中和`）是現況，不是筆誤。放進網址會被編碼成
> `store=LELE-%E4%B8%AD%E5%92%8C`，功能完全正常（已實測 OAuth 全程可還原），
> 縮網址之後使用者也看不到這段。

---

## 4. 看成效

PicSee 後台看的是「點擊」，我們自己的 log 看的是「真的進到頁面 / 真的按了註冊」，
兩邊搭配才知道哪一段在流失。

```sql
-- 各社群：到訪數 vs 按下註冊數
SELECT detail->>'src' AS src,
       COUNT(*) FILTER (WHERE source = 'join_page_view')   AS views,
       COUNT(*) FILTER (WHERE source = 'join_cta_clicked') AS clicks
  FROM client_error_logs
 WHERE source IN ('join_page_view','join_cta_clicked')
   AND created_at >= now() - interval '30 days'
 GROUP BY 1
 ORDER BY views DESC;
```

```sql
-- 真的變成會員的有幾個（對照上面的 clicks 看轉換率）
SELECT date_trunc('day', b.bound_at) AS d, COUNT(*) AS new_members
  FROM member_line_bindings b
 WHERE b.unbound_at IS NULL AND b.bound_at >= now() - interval '30 days'
 GROUP BY 1 ORDER BY 1 DESC;
```

漏斗會長這樣：`PicSee 點擊 → join_page_view → join_cta_clicked → member_line_bindings`。
某一段掉特別多就知道要修哪裡（例如 view 高但 click 低 = 落地頁說服力不夠；
click 高但沒變成會員 = LINE 登入那段卡住，去查 `client_error_logs` 的 error 筆）。

---

## 5. 之後想讓網址更漂亮

現在正式站是 `new-erp-admin.vercel.app`（Vercel project 當初取錯名字，實際部署的是
會員站，見 HANDOFF-2026-04-24）。縮網址之後客人看不到這串，所以不急，
但如果哪天要處理，順序是：

1. 買一個短網域（例如 `bzm.tw`）
2. 綁到 Vercel，**同時**更新 LINE Login 的 callback URL、LIFF app 的 Endpoint URL、
   `NEXT_PUBLIC_SITE_URL`（OG 用）
3. PicSee 那些連結的目標網址一次改掉（不用重發連結 —— 這就是選 PicSee 的理由之一）

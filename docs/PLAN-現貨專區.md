# PLAN — 會員 App「現貨專區」

> 狀態：**已施工完成**（2026-08-01）。程式碼、migration、edge function 都上了。
> 分支：`claude/merchant-products-cross-store-hide-5c9v47`
>
> **上線前還差一步（要人做）**：設環境變數 `NEXT_PUBLIC_LINE_OA_ID`，或在 admin
> `/stores` 幫各店填「LINE@ ID」。兩者都空的話按鈕還是在，但只能「複製訊息」
> 讓使用者自己貼，不會直接開對話。見 §5.5。

---

## 0. 一句話

店家在互助交流板按「我有庫存可提供」釋出的現貨，會出現在會員 App 底部正中間的「現貨專區」；
**只有自己所在店家釋出的商品看得到金額**，跨店的金額隱藏；點商品可以用 LINE 直接詢問店家。

---

## 1. 資料定義

| 項目 | 內容 |
|---|---|
| 資料來源 | `mutual_aid_board` 的 `post_type='offer'`（互助交流板「我有庫存可提供」） |
| 上架條件 | `status='active'` ＋ `expires_at > now()` ＋ `qty_remaining > 0` |
| 不收錄 | `post_type='request'`（我要求助，是店對店求援不是貨）；板上 `note`（店對店內部備註，不外流） |
| 自動下架 | 被認領光（`exhausted`）／到期（既有 cron `purge-expired-aid-board` 每 10 分鐘跑）／店家取消 —— 三種都自動從 App 消失，不必另外做 |
| 單價來源 | 該貼文 `source_customer_order_id` 的訂單中，對應 `sku_id` 的 `customer_order_items.unit_price` |
| 會員所在店 | `members.home_store_id`；未綁定會員退回 JWT 的 `store_id`（掃碼進站那間） |

**命名分工**：對會員講「現貨專區」（現成的貨、不用等團購結單）；卡片上仍標「◯◯店 釋出」當來源。
對店家端（admin 互助交流板）用語完全不動。

---

## 2. 底部 tab bar：4 格 → 5 格，凸起中央鍵

```
                    ╭───────╮
                    │  📦   │   ← 56px 品牌漸層圓鈕，往上凸 14px
┌────────┬────────┬─┴───────┴─┬────────┬────────┐
│  商品  │  訂單  │ 現貨專區  │  通知  │   我   │
└────────┴────────┴───────────┴────────┴────────┘
```

- 圓鈕：56×56、`brand-gradient`、白色箱子 icon、`ring-4 ring-white`（打穿 bar 的邊）、往上 `-translate-y-3.5`
- 圓鈕下方仍有 12px 的「現貨專區」小字，維持五格語意一致
- active 時圓鈕加外圈光暈（`shadow` 加深）＋文字轉 `--brand-strong`
- **`PageShell` 的 `paddingBottom` 要從 `calc(92px + safe-area)` 加到 `calc(104px + safe-area)`**，否則凸起的鈕會蓋到頁尾內容
- `MemberTabBar` 在 `/shop/c/[id]` 本來就 `return null`（那頁有自己的 sticky 下單 bar），不受影響

### ⚠ 路由的坑

tab active 判斷是 `pathname.startsWith(t.href)`。所以現貨專區**必須是獨立頂層路由 `/spot`**，
不能掛在 `/shop/...` 底下 —— 否則進現貨專區時「商品」tab 會一起亮。
`PageShell` 的 `TOP_LEVEL_PATHS` 也要加 `/spot`（不然會多長一顆返回鍵）。

---

## 3. `/spot` 頁面

```
┌─────────────────────────────┐
│ 現貨專區            （大標題）│
├─────────────────────────────┤
│  [ 全部 (8) ][ 松山店 (3) ]  │  segmented control
├──────────────┬──────────────┤
│ [本店釋出]   │[古華店 釋出] │
│   商品圖     │   商品圖      │
│ 上海小籠湯包 │ 日夜藍莓護眼  │
│ 可提供 3 包  │ 可提供 1 盒   │
│ $149         │🔒跨店·金額不顯示│
└──────────────┴──────────────┘
        整張卡可點 → /spot/[id]
```

- 排序：本店的一律排前面（看得到金額、真的拿得到貨），其餘最新在前
- 分頁：`全部` / `〈本店名〉`（原本分頁下有一段金額規則說明，2026-08-01 拿掉 —— 卡片上的鎖頭已經講得夠清楚）
- **點卡片 → `/spot/[id]` 詳情頁**（2026-08-01 加）：大圖、品名、金額或鎖頭、
  可提供數量／釋出分店／剩餘時間／商品編號、商品說明，底部常駐「用 LINE 詢問店家」。
  LINE CTA 從卡片移到詳情頁 —— 一張小卡上疊兩個可點區域太容易誤觸。
  商品說明要走 `cleanCampaignText`：後台 TipTap 存的是 HTML，直接印會露出
  `<p>`/`<br>` 標籤字樣。
- 到期倒數**只有列表卡片不顯示**（2026-08-01 拿掉，卡片上太吵）；詳情頁的「剩餘時間」列保留
- 空狀態：📦「目前沒有店家釋出現貨」／分頁下是「你的店目前沒有現貨」
- 下拉重新整理
- 未登入 / session 過期 → redirect 回 `/`

---

## 4. 金額隱藏（本需求核心）

**一定要在後端擋，不能只有 UI 藏。**

1. 後端先算 `myStoreId`（`members.home_store_id`，未綁定退回 JWT `store_id`）
2. **只對 `offering_store_id === myStoreId` 的貼文**去查來源訂單單價 —— 跨店那幾筆連查都不查
3. Response 中跨店的 `unit_price` 恆為 `null`、`is_my_store=false`
4. 前端拿到 `is_my_store=false` 就畫鎖頭膠囊「跨店 · 金額不顯示」

驗收：直接看 raw response，跨店那筆 `unit_price` 必須是 `null`（測試文件 T2-5）。
**改動時別把它退化成前端過濾。**

---

## 5. LINE 詢問

### 5.1 觸發方式

**在 `/spot/[id]` 詳情頁底部常駐一條「💬 用 LINE 詢問店家」**。

原本 CTA 放在列表卡片上，2026-08-01 改成整張卡連到詳情頁、CTA 移進詳情頁 ——
一張小卡上疊兩個可點區域（進詳情 vs 跳 LINE）太容易誤觸，而且詳情頁才有空間
把品名、數量、到期時間攤開讓人看清楚再決定要不要問。

### 5.2 訊息範本

**本店商品**（看得到金額）：
```
您好，我想詢問今日現貨
「上海小籠湯包-附蒸籠紙／一包」
金額：$149
請問店家目前還有貨嗎？
```

**跨店商品**（金額被隱藏 → 訊息**絕對不能帶金額**，否則等於從另一個出口把價格漏出去）：
```
您好，我想詢問今日現貨
「德國保健品Doppelherz多寶雙心／一盒」（古華店釋出）
請問可以幫我調貨嗎？
```

### 5.3 訊息發給誰

**一律發給「會員所在店」的 LINE@**，跨店商品也是。

理由：會員只跟自己的店往來、也只跟自己的店結帳；跨店的貨本來就是由自己的店走互助板去別店調。
所以跨店那則的收尾才改成「請問可以幫我調貨嗎？」而不是「還有貨嗎」。
這同時也守住金額隱藏 —— 價格由自己的店回報，不會從別店的報價外洩。

### 5.4 兩種跑法：PWA 與 LIFF 走不同路（2026-08-01）

這個 App 有兩種載入型態，送訊息的方式不一樣，**不能只寫一條**：

| 型態 | 做法 | 使用者體感 |
|---|---|---|
| **LIFF**（LINE 內建瀏覽器） | `liff.sendMessages([{type:'text',text}])` | 文字直接進 LINE 對話，**人留在 App 裡**，不被踢走 |
| **PWA / 一般瀏覽器** | `line.me/R/oaMessage/{basicId}/?{text}` universal link | 跳去 LINE 開對話並預填，使用者自己按送出 |

實作在 `lib/lineInquiry.ts` 的 `sendLineInquiry()`，退路是一路往下掉：
`liff.sendMessages` →（失敗）`liff.openWindow(external)` →（失敗）`location.href` 導頁
→（連 LINE@ id 都沒有）複製訊息到剪貼簿。

⚠ **兩個前提**：
1. LIFF app 要開 **`chat_message.write`** scope，否則 `sendMessages` 一定 reject
   （會自動掉到 universal link，功能不會壞，只是體驗差一截）。
   → **2026-08-01 Alex 確認已開**，不用再查 LINE Developers。
2. `sendMessages` 送進的是「開啟這個 LIFF 的那個聊天室」。從 OA 聊天室 / 圖文選單
   進來就是送給該 OA；從其他入口進來沒有 chat context，一樣掉到 universal link。

`basicId` 要含 `@`（URL 編碼成 `%40`）；`buildLineOaMessageUrl` 會自動補。

非同步偵測 LIFF 還沒回來之前一律先當 PWA —— 那條路哪裡都能用，不會卡住。

另外 `initLiff()` 需要 **`NEXT_PUBLIC_LIFF_ID`** 有設，否則直接回 null、永遠走 PWA 那條。
這個值只存在 Vercel 環境變數裡（會編進前端 bundle），repo 內查不到。
要確認的話最快是直接在 LINE 裡開 App 走一次 T5b-1。

### 5.5 ⚠ 資料前置（會擋到上線）

查過線上：**20 間啟用中的店，`stores.line_oa_basic_id` 全是 `NULL`**，
而且 admin 的 `/stores` 表單只有 代碼／名稱／location／取貨窗／付款方式／啟用／備註，**沒有 LINE@ 欄位**。

處理方式（不需要 migration，欄位早就存在）：

1. **加環境變數 `NEXT_PUBLIC_LINE_OA_ID`** 當租戶層預設值 —— 填 包子媽生鮮小舖 主帳號的 LINE@ ID。
   有了它，功能第一天就能動，不必等 20 間店逐間填。
2. **admin `/stores` 表單加一個「LINE@ ID」欄位**（寫進既有的 `line_oa_basic_id`），
   之後哪間店要用自己的 LINE@ 就自己填，填了就覆蓋預設值。
3. 解析順序：`該會員所在店的 line_oa_basic_id` → `NEXT_PUBLIC_LINE_OA_ID` → 都沒有就
   **複製訊息到剪貼簿**，請使用者自己貼給店家。

   ⚠ 原本這裡的規則是「都沒有就不顯示 CTA 按鈕」。實際上線後 20 間店的
   `line_oa_basic_id` 全是 NULL、env 也沒設 → 按鈕整個不見，看起來像功能壞掉。
   **2026-08-01 改成按鈕一律出現**，最差也要留一條路（複製）給使用者走。

`line_oa_basic_id` 要一併從後端回給前端（放在 `list_spot_products` 的 response，
只回會員所在店那一間的，不外流其他店的聯絡方式）。

---

## 6. 檔案異動清單

| 檔案 | 動作 | 說明 |
|---|---|---|
| `supabase/functions/liff-api/index.ts` | 改 | action `list_released_products` → **`list_spot_products`**；response 加 `my_store_line_oa_id`。2026-08-01 再加 **`get_spot_product`**（單筆詳情，上架條件與列表一致，知道 id 也繞不過去）。改完重新部署 |
| `apps/member/src/app/spot/page.tsx` | 新增 | 現貨專區列表頁（由 `/shop/released` 搬過來改名） |
| `apps/member/src/app/spot/[id]/page.tsx` | 新增 | 現貨商品詳情頁（2026-08-01）；底部常駐 LINE 詢問列 |
| `apps/member/src/app/shop/released/page.tsx` | 刪除 | 還沒進 main、沒人收藏過網址，直接改名不留 redirect |
| `apps/member/src/components/SpotProductCard.tsx` | 改名 | 由 `ReleasedProductCard` 而來；type `ReleasedProduct` → `SpotProduct`。2026-08-01 整張卡改成連到 `/spot/[id]`，卡上的 LINE CTA 移進詳情頁 |
| `apps/member/src/lib/lineInquiry.ts` | 新增 | 組訊息文字 + `line.me/R/oaMessage` URL；本店/跨店兩種範本都在這裡，單一真相來源 |
| `apps/member/src/components/MemberTabBar.tsx` | 改 | 4 tab → 5 tab，中間插入現貨專區凸起圓鈕 |
| `apps/member/src/components/PageShell.tsx` | 改 | `TOP_LEVEL_PATHS` 加 `/spot`；`paddingBottom` 92px → 104px |
| `apps/member/src/app/shop/page.tsx` | 改 | ~~加現貨導流區塊~~ → **2026-08-01 已移除**：有了中間 tab 之後這塊是重複入口，`/shop` 回到只管團購（連 `list_spot_products` 的呼叫也一起拿掉，不再多打一支 API） |
| `apps/admin/src/app/(protected)/stores/page.tsx` | 改 | 表單加「LINE@ ID」欄位（寫 `line_oa_basic_id`），含 `Store` type 與存檔路徑 |
| `apps/member/.env` / Vercel | 設定 | 加 `NEXT_PUBLIC_LINE_OA_ID` |
| `docs/TEST-member-released-products.md` | 改名 | → `docs/TEST-member-spot-zone.md`，內容同步 |

**沒有 migration、不動任何 RPC、不動 admin 互助交流板的既有流程。**
店家操作完全照舊：按「我有庫存可提供」發貼文，會員端就自動看得到。

---

## 7. 施工順序

1. 後端：action 改名 + 回傳 `my_store_line_oa_id` → curl 部署 → 驗 OPTIONS 200 / 無 auth 401
2. admin `/stores` 加 LINE@ ID 欄位；設好 `NEXT_PUBLIC_LINE_OA_ID`
3. `lineInquiry.ts` + `SpotProductCard`（含兩種訊息範本）
4. `/shop/released` → `/spot`
5. `MemberTabBar` 5 格凸起鍵 + `PageShell` padding 與 `TOP_LEVEL_PATHS`
6. ~~`/shop` 區塊改名、縮 4 張、改連結~~ → 後來整塊移除（見 §6、§9）
7. `npx tsc --noEmit` + `next build`（member 與 admin 都要）+ 只看新檔的 lint
8. 更新測試文件、commit、push

---

## 8. 驗收重點

| # | 項目 | 預期 |
|---|---|---|
| A1 | tab bar | 5 格，現貨專區在正中間且圓鈕凸起；進 `/spot` 時只有它亮，「商品」不亮 |
| A2 | 頁尾不被蓋 | `/spot` 與其他頁捲到底，最後一列內容不被凸起鈕蓋住 |
| A3 | 本店卡 | 顯示 `$金額` |
| A4 | **跨店卡** | 畫面沒有任何金額；**raw response 的 `unit_price` 是 `null`** |
| A5 | 本店 LINE 詢問 | 開 LINE 對話，訊息含品名 + `金額：$xxx` |
| A6 | **跨店 LINE 詢問** | 開 LINE 對話，訊息含品名 +「（◯◯店釋出）」，**不含任何金額**，結尾是「請問可以幫我調貨嗎？」 |
| A7 | LINE@ 沒設定 | 按鈕**照樣出現**：LIFF 下直送成功；PWA 下退到複製訊息。不能整顆消失 |
| A12 | LIFF 送訊息 | 在 LINE 內開 App → 按詢問 → 文字直接進對話、人留在 App，顯示「已送出詢問訊息」 |
| A8 | 板上 0 則 | `/spot` 空狀態（`/shop` 已無現貨區塊，見 §6） |
| A9 | 被認領光 / 到期 | 該筆自動從 App 消失 |
| A10 | 迴歸 | `/shop` 團購列表、banner、排序、`/orders`、`/notifications`、`/me` 全部照舊 |
| A11 | 詳情頁 | 點卡片進得去；直接用網址開已下架 / 別租戶的 id 一律 404 落到空狀態 |

---

## 9. 已決策 / 未決

**已決策（2026-08-01 與 Alex 對過）**
- 中間 tab 樣式 → **凸起中央鍵**
- 會員互動 → **不直接下單，點了用 LINE 詢問店家**
- `/shop` 首頁橫向區塊 → 原本決定「保留，縮成 4 張」，**2026-08-01 改為整塊移除**：
  中間 tab 上線後這塊變成重複入口，商品頁回到只管團購。

**未決（施工中若沒回覆就照下面預設走）**
- `NEXT_PUBLIC_LINE_OA_ID` 要填哪個 LINE@ → 預設填 包子媽生鮮小舖 主帳號
- 跨店訊息收尾用「請問可以幫我調貨嗎？」→ 若要照原句「請問店家目前還有貨嗎？」也行，改一行字
- tab 圓鈕要不要掛「本店現貨 N 件」badge → 預設**不掛**（會多一支輪詢 API 打在每一頁），要的話另開

---

## 10. 之後可能的延伸（本期不做）

- 會員直接下單／預留：現有 `rpc_transfer_order_to_store` 是**店對店轉單**，不是會員購買。
  真要做等於新開一條「會員下單 → 佔用釋出量 → 生成訂單」的流程，含扣 `qty_remaining`、
  併發搶單、取消回補、與互助板認領互斥。屬於獨立一期。
- 「現貨」的定義擴大：目前只收互助板 offer。未來若要納入店內即時庫存（`stock_on_hand`），
  `list_spot_products` 的 response 形狀已經足夠通用，加一個 `source` 欄位區分即可。

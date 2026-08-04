# 測試項目 — apps/member `/join` 社群推廣註冊頁

**需求：** 要一個可以貼到各大社群（FB 社團、LINE 群、IG）的註冊落地頁，
上面一顆 LINE SSO 按鈕就能讓客人完成登入＋註冊。

**對應變更：**
- `apps/member/src/app/join/page.tsx` — 新頁：品牌 hero、賣點、流程、一顆 LINE CTA、分享按鈕。
- `apps/member/src/app/join/layout.tsx` — OG / Twitter metadata（分享預覽卡）。
- `apps/member/src/lib/lineAuth.ts` — **新檔**，從首頁抽出的登入原語（LIFF 旗標、pair code、`runLiffSession`…）。
- `apps/member/src/lib/useLineLogin.ts` — **新檔**，整段登入狀態機，`/` 與 `/join` 共用。
- `apps/member/src/app/page.tsx` — 改用 `useLineLogin`，**行為不變**（純重構）。
- `apps/member/.env.example` — 新增 `NEXT_PUBLIC_SITE_URL`（只給 OG 絕對網址用）。

**重點：** 註冊不需要表單。`liff-session` 查不到 binding 又拿到 store 時會直接
auto-register，所以「用 LINE 登入」＝「用 LINE 註冊」，一顆按鈕就結束。

---

## 1. 首頁回歸（重構沒有改行為）

抽 hook 動到的是登入這條最容易壞的路，先確認首頁沒退步。

- [ ] `/` 未登入、無 `?store=` → 顯示門市下拉，選店後出現「用 LINE 註冊 / 登入」
- [ ] `/` 帶 `?store=S001` → 直接顯示該店與 LINE 按鈕，不再問一次門市
- [ ] `/` 已登入（localStorage 有 member_jwt + member_id）→ 自動跳走
      （PWA / LINE 內 → `/shop`；一般瀏覽器 → `/me`）
- [ ] PWA（加到主畫面後開啟）按登入 → 進「請完成 LINE 登入」等待畫面，
      完成後切回 App 自動進入，**不需要**輸入驗證碼
- [ ] PWA 展開「用驗證碼手動同步」→ 6 碼可用（退路仍在）
- [ ] 「更換其他門市」→ 回到門市選擇（本次順帶把 `last_store_id` 一起清掉，
      重整後不會又跳回舊店）

## 2. `/join` 門市解析

門市是註冊唯一需要使用者決定的事，四條來源都要對。

- [ ] `/join?store=S002` → 卡片直接顯示「取貨門市：板橋店」，CTA 可按
- [ ] `/join`（無參數、多間店、localStorage 也沒有）→ 顯示門市下拉，
      CTA 下方以**品牌色**顯示「請先選擇取貨門市」（不是灰字註腳）
- [ ] `/join`（無參數）但租戶只有一間店 → 自動帶入該店，不問使用者
- [ ] `/join`（無參數）且 localStorage 有 `last_store_id` → 沿用上次的店
- [ ] 未選門市時按 CTA → 不是沒反應，而是把門市選單展開
- [ ] 按「更換」→ 展開下拉；選完自動收起
- [ ] `list_stores` 失敗（斷網 / 後端掛）→ 退成手動輸入門市代號，頁面不整個卡死

## 3. `/join` LINE 登入（四種執行環境）

登入路徑走的是與首頁同一份 `useLineLogin`，這裡驗的是「/join 也吃得到」。

- [ ] **一般手機瀏覽器**：按 CTA → 導 `line-oauth-start` → LINE 授權 → 回站 → 進 `/shop`
- [ ] **LINE app 內（從 LIFF 連結進來）**：`liff.init()` 自動登入 → 不用按任何按鈕就進 `/shop`
- [ ] **LINE 內建瀏覽器（貼在群組被直接點開）**：第一次按 CTA 走 OAuth；
      回來仍沒登入時顯示「用其他瀏覽器開啟」指引 + 複製連結，**不會**無限彈
- [ ] **PWA standalone**：按 CTA → 等待畫面 → 完成後切回自動進入
- [ ] 全新 LINE 帳號按一次 CTA → 直接成為會員（`members` 多一筆、
      `member_line_bindings` 多一筆），**沒有**要求填手機 / 姓名 / 生日
- [ ] 已是會員的 LINE 帳號按 CTA → 直接登入既有帳號，不會重複建立

驗證 SQL：

```sql
-- 剛剛那支 LINE 帳號有沒有真的被建起來
SELECT m.id, m.member_no, m.name, b.line_user_id, b.store_id, b.bound_at
  FROM member_line_bindings b JOIN members m ON m.id = b.member_id
 WHERE b.unbound_at IS NULL
 ORDER BY b.bound_at DESC LIMIT 5;
```

## 4. 分享預覽卡（OG）

這頁是要被轉貼的，預覽卡不對等於白做。

- [ ] `curl -s https://<站台>/join | grep -E 'og:(title|image|url)'`
      → 三個都在，且 `og:image` / `og:url` 是**絕對網址**
- [ ] `og:image` 直接用瀏覽器開得起來（`/brand/banner.jpg`，1800×600）
- [ ] 貼到 LINE 聊天室 → 出現帶圖預覽卡（標題「加入包子媽生鮮小舖 — 用 LINE 一鍵註冊」）
- [ ] 貼到 FB 社團 → 同上（首次可用 FB Sharing Debugger 清快取）
- [ ] Vercel 若沒設 `NEXT_PUBLIC_SITE_URL` → 預設 `https://new-erp-admin.vercel.app`
      （這個 project 名字叫 admin，但部署的是會員站，見 HANDOFF-2026-04-24）

## 5. 推廣成效追蹤

每個社群發不同的 `?src=`，事後才知道哪裡帶得進人。

- [ ] `/join?src=fb-中和團購` 進站 → `client_error_logs` 出現一筆 `join_page_view`，
      `detail->>'src'` = `fb-中和團購`
- [ ] 同一次瀏覽重整 → 不會灌成兩筆（sessionStorage 旗標擋掉）
- [ ] 按 CTA → 出現 `join_cta_clicked`，`src` 與上面同一個
- [ ] LINE 授權轉一圈回來後 `src` 仍讀得到（存在 localStorage，不靠 URL）
- [ ] `?utm_source=` 也吃得到（同義）

成效統計 SQL：

```sql
-- 各社群帶進多少到訪 / 多少人真的按了註冊
SELECT detail->>'src' AS src,
       COUNT(*) FILTER (WHERE source = 'join_page_view')   AS views,
       COUNT(*) FILTER (WHERE source = 'join_cta_clicked') AS clicks
  FROM client_error_logs
 WHERE source IN ('join_page_view','join_cta_clicked')
   AND created_at >= now() - interval '30 days'
 GROUP BY 1 ORDER BY views DESC;
```

## 6. 分享按鈕

- [ ] 支援 `navigator.share` 的手機 → 叫得出系統分享匣
- [ ] 不支援（桌機 Chrome）→ 連結複製到剪貼簿，按鈕文字變「✓ 連結已複製」
- [ ] 剪貼簿被擋（LINE webview 常見）→ 直接把連結印在畫面上讓使用者長按複製
- [ ] 分享出去的連結帶 `src=share`（分得出是會員幫忙轉的）且保留目前門市

## 7. 隱私說明

社群來的人第一個疑慮就是「會不會被看到我的聊天紀錄」。

- [ ] CTA 下方看得到「只取得 LINE 顯示名稱與大頭貼，不會讀取聊天內容 / 好友名單」
- [ ] 這句話與實際請求的 scope 一致（`line-oauth-start` 是 `profile openid`，沒有其他）

---

## 驗證紀錄

| 項目 | 結果 |
| --- | --- |
| `npx tsc --noEmit` | ✅ 無錯誤 |
| `npx next build --webpack` | ✅ 通過，`/join` 為 static prerender |
| `npx eslint src` | ✅ 未新增錯誤（重構前 24 → 重構後 21） |
| OG tag 產出 | ✅ 已確認絕對網址（build 產物 `.next/server/app/join.html`） |
| `/join` 三種門市狀態畫面 | ✅ 本機 headless 截圖確認 |
| `/` 回歸 | ✅ 本機 headless 截圖確認與重構前一致 |

真機（LINE app / LINE 內建瀏覽器 / iOS PWA）尚未測 —— 上線後照第 3 節逐項走一次。

---
name: verify
description: 在無真實登入的情況下，用 Playwright + fixture 驗證 admin app 的 UI 改動
---

# admin app UI 驗證流程

admin 是 client-side Supabase auth 的靜態 Next app，可以完全不碰線上 DB 驗證 UI：

1. 起 dev server：`cd apps/admin && npx next dev -p 3100`（Supabase env 已在環境變數，Next 會自己吃）。
2. Playwright 用預裝 Chromium：`chromium.launch({ executablePath: "/opt/pw-browsers/chromium" })` — 不要 `npx playwright install`（版本對不上會失敗）。`playwright` npm 包裝在 scratchpad，不要裝進 repo。
3. 假登入：往 localStorage 塞 `sb-<project-ref>-auth-token`（ref 取自 `NEXT_PUBLIC_SUPABASE_URL` 的 hostname 第一段），value 是 supabase session JSON：`{access_token: <格式合法的假JWT，exp 放未來>, expires_at: <未來epoch秒>, refresh_token, user:{id,aud:"authenticated",...}}`。
4. 用 `context.route()` 攔 `**/auth/v1/**` 與 `**/rest/v1/**` 回 fixture JSON。必要的 stub：
   - `rpc/rpc_get_my_tenant` → `[{id,name,status:"active",trial_expires_at:null}]`（status 不是 active 會被 TrialGate 擋）
   - 其他 rpc / 資料表 → 按頁面需要給，fallback 回 `[]`
5. **進頁後會有自動彈出的 release-notes dialog 擋住整頁**，先按 Escape 或關閉鈕再操作。

## 坑

- Field 元件用 `<label>` 包整個欄位：label 的 click 轉發會讓自訂 dropdown「選完馬上重開」（React 同步 re-render 換掉按鈕後，瀏覽器把 click 轉發到新渲染的觸發鈕）。選項按鈕的 onClick 要 `e.preventDefault()`。桌機/手機模擬都會發生。

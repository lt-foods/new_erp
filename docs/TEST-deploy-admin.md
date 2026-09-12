# deploy-admin 測試項目 — GH Pages 自動部署

**對應 workflow:** `.github/workflows/deploy-admin.yml`
**部署目標:** `https://erp.www161616.com/` — 2026-09-12 起改用自訂網域，站台掛在**網域根目錄**
**舊網址:** `https://lt-foods.github.io/new_erp/` — ⛔ 已不是驗收標準，不要再拿 `/new_erp` 前綴當通過條件

## 1. Workflow 設定 / Infra

### 1.1 Workflow 觸發
- [ ] `on: push` to `main`、且 paths 涵蓋 `apps/admin/**` + `.github/workflows/deploy-admin.yml`
- [ ] `on: workflow_dispatch` 可手動觸發
- [ ] concurrency group 防重疊

### 1.2 權限
- [ ] `permissions: contents: read + pages: write + id-token: write`
- [ ] 只在 main 部署（feature branch PR 不應 deploy）

### 1.3 Repo secrets
- [ ] `NEXT_PUBLIC_SUPABASE_URL` 已設定
- [ ] `NEXT_PUBLIC_SUPABASE_ANON_KEY` 已設定
- [ ] Workflow 正確注入兩者為 `NEXT_PUBLIC_*` env vars（build time baked in）

### 1.4 GH Pages 啟用
- [ ] Pages source = `GitHub Actions`（不是 branch-based）

### 1.5 自訂網域（2026-09-12 新增）
- [ ] Cloudflare DNS：`erp` → `lt-foods.github.io`，**必須是「DNS only」灰雲**
      （開橘色雲代理，GitHub 發不出憑證，會一直卡在不安全）
- [ ] **DNS 先生效，才合併 PR**。順序顛倒的話後台會連不上
- [ ] repo Settings → Pages → Custom domain 顯示 `erp.www161616.com`
      （⚠️ 這一步只有 `lt-foods` 的管理者看得到，一定要人工確認過才算數）
- [ ] 同頁 HTTPS 憑證狀態正常。首次簽發最久約 1 小時，期間瀏覽器可能顯示不安全

## 2. Build 階段

### 2.1 安裝 + build
- [ ] `npm install --no-audit --no-fund` 成功（monorepo root）
- [ ] 「Check NEXT_PUBLIC_SITE_URL is set」步驟通過
      （值為空就 fail 是**刻意設計**，不是壞掉：少了它分享縮圖會安靜消失）
- [ ] job 層 env：`NEXT_PUBLIC_BASE_PATH` 是**空字串**、
      `NEXT_PUBLIC_SITE_URL` = `https://erp.www161616.com`
- [ ] `npm run build` 成功、輸出 `apps/admin/out/`

### 2.2 Static export 產物
- [ ] `out/index.html` 存在，資源路徑**不含** `/new_erp/`（根目錄部署）
- [ ] `out/CNAME` 存在，內容剛好是 `erp.www161616.com` ＋ 一個換行 = **18 bytes**，
      **不可有 CR 或 BOM**（`od -A x -t x1z out/CNAME` 最後兩個位元組要是 `6d 0a`）
- [ ] `out/_next/static/*` 存在
- [ ] `out/products/`、`out/products/new/`、`out/products/edit/`、`out/login/` 都有 index.html
- [ ] `out/.nojekyll` 存在（防 GitHub Jekyll 處理 _next/）
- [ ] `out/welcome/index.html` 的 `og:url` / `og:image` 指向 `https://erp.www161616.com/...`
      （⛔ 不可以是 `lt-foods.github.io`，也不可以是 `localhost`）

## 3. Deploy 階段

### 3.1 Upload artifact
- [ ] 使用 `actions/upload-pages-artifact@v3`、path = `apps/admin/out`

### 3.2 Deploy job
- [ ] `actions/deploy-pages@v4` 成功
- [ ] 自訂網域生效後，以 `https://erp.www161616.com/` 為準
      （`page_url` 在自訂網域套用前後可能顯示不同值，不要只看它就判定失敗）

## 4. 部署後驗證

### 4.1 URL 可達
- [ ] `https://erp.www161616.com/` 回 200、顯示後台首頁
- [ ] `https://erp.www161616.com/login/` 載入
- [ ] `https://erp.www161616.com/products/` 載入（需登入）
- [ ] 舊網址 `https://lt-foods.github.io/new_erp/` 會不會自動轉到新網址
      —— ⚠️ **2026-09-12 尚未實測**，上線後點一次確認，不要假設它一定會轉

### 4.2 Supabase client runtime
- [ ] 打開 DevTools Network 看第一個 Supabase 呼叫的 URL 是
      `anfyoeviuhmzzrhilwtm.supabase.co`（不是 `xxxxx.supabase.co`）
- [ ] 登入 admin user（`cktalex@gmail.com`）→ `/products` 看到 3 筆（B3 留下的測試資料）

### 4.3 Assets / basePath 正確
- [ ] `<link>`、`<script>` tag 的 href/src 是 `/_next/...`（根目錄，**不帶** `/new_erp`）
- [ ] 分頁 favicon 有正常顯示（basePath 補錯會 404、退回預設黑 icon）
- [ ] 沒有 404 靜態資源

## 5. 驗收門檻

全部 §1-§4 勾完 + 第一次 deploy 成功 + 登入流程在公開網址能跑通才能標 done。

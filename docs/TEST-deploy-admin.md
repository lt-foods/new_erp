# deploy-admin 測試項目 — GH Pages 自動部署

**對應 workflow:** `.github/workflows/deploy-admin.yml`
**部署目標:** `https://www161616.github.io/new_erp/`

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

## 2. Build 階段

### 2.1 安裝 + build
- [ ] `npm ci` 成功（monorepo root）
- [ ] `NEXT_PUBLIC_BASE_PATH=/new_erp` 傳入 build
- [ ] `npm run build` 成功、輸出 `apps/admin/out/`

### 2.2 Static export 產物
- [ ] `out/index.html` 存在、URL prefix 含 `/new_erp/`
- [ ] `out/_next/static/*` 存在
- [ ] `out/products/`、`out/products/new/`、`out/products/edit/`、`out/login/` 都有 index.html
- [ ] `out/.nojekyll` 存在（防 GitHub Jekyll 處理 _next/）

## 3. Deploy 階段

### 3.1 Upload artifact
- [ ] 使用 `actions/upload-pages-artifact@v3`、path = `apps/admin/out`

### 3.2 Deploy job
- [ ] `actions/deploy-pages@v4` 成功
- [ ] 輸出的 `page_url` 對應 `https://www161616.github.io/new_erp/`

## 4. 部署後驗證

### 4.1 URL 可達
- [ ] `https://www161616.github.io/new_erp/` 回 200、顯示 `new_erp — 團購店 ERP` 首頁
- [ ] `/new_erp/login/` 載入
- [ ] `/new_erp/products/` 載入（需登入）

### 4.2 Supabase client runtime
- [ ] `window.__NEXT_DATA__` 含正確 basePath
- [ ] 打開 DevTools Network 看第一個 Supabase 呼叫的 URL 是 `anfyoeviuhmzzrhilwtm.supabase.co`（不是 `xxxxx.supabase.co`）
- [ ] 登入 admin user（`cktalex@gmail.com`）→ `/products` 看到 3 筆（B3 留下的測試資料）

### 4.3 Assets / basePath 正確
- [ ] `<link>`、`<script>` tag 的 href/src 都帶 `/new_erp/_next/`
- [ ] 沒有 404 靜態資源

## 5. 驗收門檻

全部 §1-§4 勾完 + 第一次 deploy 成功 + 登入流程在公開網址能跑通才能標 done。

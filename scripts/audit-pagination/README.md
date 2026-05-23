# audit-pagination 驗證腳本

本目錄存放對應 `docs/AUDIT-資料截斷風險清單-*.md` 各風險項的驗證腳本。

## 命名規則

`test-<風險編號>-<簡述>.mjs`

例如：`test-11-12-campaign-detail-ordered-qty.mjs` 對應 AUDIT #11 + #12。

## 共同前置

每隻腳本都需要 `apps/admin/.env.local` 中的下列環境變數（Service Role Key 才能繞 RLS 灌測試資料）：

```
NEXT_PUBLIC_SUPABASE_URL=...
SUPABASE_SERVICE_ROLE_KEY=...
TEST_TENANT_ID=...           # 測試 tenant
```

## 共同設計

1. **塞測試資料時用獨立 prefix**（例如 `audit_pagination_<編號>_*`），方便事後清理。
2. 數量必須 **超過 1000**（建議 1100–1500），才能觸發 PostgREST 截斷情境。
3. 結束前 **務必清掉**測試資料，並印出 PASS/FAIL。
4. 任何失敗都應 `process.exit(1)` 讓 CI 抓得到。

## 跑法

```bash
node scripts/audit-pagination/test-XX-xxx.mjs
```

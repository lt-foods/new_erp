# 漂漂館上線順序（PR #796）

這份只在 PR #796 從 Draft 轉為準備上線時使用。現在**不要執行**。

## 唯一順序

1. 在 Supabase SQL Editor 整份執行：
   `supabase/migrations/20260820000100_piaopiao_independent_portal.sql`

   若有任何錯誤：立刻停止，不要重貼、不要跳下一步。

2. 在同一處整份執行唯讀驗收：
   `scripts/verify-piaopiao-portal-migration.sql`

   只有結果第一句是 ✅ 才能下一步；任何 ❌ 都停止。

3. 重載資料庫對外欄位快取：

   ```sql
   NOTIFY pgrst, 'reload schema';
   ```

4. 部署後端，順序固定：`liff-api` → `piaopiao-api` → `piaopiao-publisher-admin`。
   每支部署後先驗它真的能回應；`liff-api` 部署後要先看一般商城 `/shop` 和現貨 `/spot` 都正常。

5. 最後才更新會員網站與 ERP 後台，並以測試帳號建一樣測試商品。
   必驗：一般商城看不到該團、漂漂館看得到、手機分享帶圖片＋連結、一般團購與現貨正常。

## 不能倒退的規則

- 資料庫未完成前，不能更新任何後端或網站。
- 已建出任何漂漂館團後，不能退回舊版 `liff-api`；否則漂漂團可能混回一般商城。
- 真要停用，只停上架帳號與漂漂館入口，保留新版一般商城篩選。

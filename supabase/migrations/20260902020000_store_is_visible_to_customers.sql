-- ============================================================
-- 2026-09-02：門市可以「照常營運，但客人看不到」
--
-- 需求（老闆 2026-09-02）：新開的「金」(S007) 要正常做生意，但還不想讓客人
--   知道它的存在。現況是門市名單對任何人都公開 —— liff-api 的 list_stores
--   掛在「不需要 Token 的 actions」那一區（liff-api/index.ts:1771-1773），
--   不用登入、打開會員頁就拿得到全部門市。
--
-- 為什麼不能用現成的 is_active=FALSE：
--   停用是「整家店下線」，不是「客人看不到」——派貨產生調撥會被擋、月結整家
--   跳過、收貨與庫存都受影響。而且 rpc_delete_store 是把停用當成刪除的一部分
--   （20260713000000:82-83 刪除時一併 is_active=FALSE），語意上已經被佔走。
--   「金」是要正常營運的真門市，停用等於不能用。
--
-- 為什麼是新欄位而不是改 is_active 的語意：
--   is_active 回答「這家店還在不在」，本欄位回答「客人的取貨店選單要不要列它」。
--   兩個軸正交：正常營運的店可以不公開；已停用／已刪除的店本來就哪裡都不出現
--   （軟刪除會一併關掉 is_active，所以 listStores 只篩 is_active 沒有漏洞）。
--
-- 影響面（2026-09-02 逐處查證）：
--   * 客人端唯一「列出全部門市」的地方只有 listStores（liff-api/index.ts:232-237）；
--     同檔另外 8 處碰 stores 的查詢（:92 /:124 /:279 /:294 /:344 /:434 /:714 /:853）
--     全部是「用 id 或 code 查特定幾家」，一處都不受影響。
--   * 客人端前端不直讀 stores 表，門市清單唯一來源是
--     apps/member/src/lib/useLineLogin.ts:141 打 list_stores。
--   * 後台門市頁 apps/admin/src/app/(protected)/stores/page.tsx:104 是「明列欄位」
--     的 select、update 也只帶特定欄位 → 加欄位對後台零影響。
--     ⇒ 總部與其他店家照樣看得到「金」（老闆 2026-09-02 裁示：不擋店家）。
--
-- ⚠ 本欄位只管「選單列不列」，不是權限鎖：
--   客人端的門市也可以從網址參數 / localStorage 指定
--   （useLineLogin.ts:88-100、:189-196、:224-229），知道代碼的人仍綁得到。
--   這正好也是「已經是金的客人不受影響」的實現方式（老闆驗收條件之一）。
--   真要禁止選取是另一個題目，本次不做。
--
-- 不加索引：stores 全表 25 列，多一個布林條件走 seq scan 比維護索引便宜。
--
-- Rollback：
--   ALTER TABLE stores DROP COLUMN is_visible_to_customers;
--   不急著刪也無妨 —— 預設 TRUE 對誰都無害，行為跟沒這欄位一模一樣。
-- ============================================================

ALTER TABLE stores
  ADD COLUMN IF NOT EXISTS is_visible_to_customers BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN stores.is_visible_to_customers IS
  '客人端取貨店選單要不要列出這家店（TRUE=列出，預設）。FALSE 只是不列進選單，門市照常營運：收貨、派貨、庫存、月結全不受影響，總部後台與其他店家照樣看得到。';

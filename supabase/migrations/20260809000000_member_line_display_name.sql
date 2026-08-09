-- ============================================================================
-- 2026-08-09: 會員端「顯示名稱」與後台名稱分家
-- ----------------------------------------------------------------------------
-- 背景：members.name 一欄同時扛兩個互相打架的用途 ——
--   (a) 會員端 /me 顯示給客人自己看的名字
--   (b) 後台列表 / 搜尋 / 揀貨單上店員辨識這個人的名字
-- 會員在 /me 把姓名改成「小美」，店員就再也搜不到「陳小美(松山)」。
--
-- 修法：新增 members.line_display_name
--   - line_display_name：LINE 端的顯示名稱。**只由 LINE 登入時同步**，
--     會員與後台都不可編輯（要改請客人去改自己的 LINE 名稱）。
--     會員端 App 一律顯示這個（fallback → name）。
--   - name：維持現狀，後台照舊用（列表 / 搜尋 / 單據）。
--     差別只在會員端不再顯示、也不再能改（liff-api 的 update_me 已拿掉 name）。
--
-- **本檔刻意只做加欄位 + backfill，不動任何後台正在用的 view / function。**
--   v_admin_member_list、rpc_search_members、rpc_upsert_member 全部原封不動；
--   後台的行為與這次改動前完全一致（新欄位對後台是不存在的）。
--   註：view 的 m.* 在建立當下就展開成欄位清單，所以 v_admin_member_list
--   不會、也不該自己冒出 line_display_name —— 後台若哪天要顯示 / 搜尋
--   LINE 名稱，再另開 migration 重建 view 與 rpc_search_members。
--
-- 已知待辦（本檔不做，等後台改動一起處理）：
--   rpc_member_gdpr_delete（20260618000040）清 PII 時沒清 line_display_name，
--   GDPR 刪除後這欄的 LINE 名稱會殘留。要補的話是在該 function 的
--   `UPDATE members SET name = NULL, ...` 那段加上 `line_display_name = NULL`。
--
-- Rollback：ALTER TABLE public.members DROP COLUMN IF EXISTS line_display_name;
-- ============================================================================

ALTER TABLE public.members
  ADD COLUMN IF NOT EXISTS line_display_name TEXT;

COMMENT ON COLUMN public.members.line_display_name IS
  'LINE 顯示名稱（每次 LINE 登入由 liff-session / line-oauth-callback 同步）。會員端 App 顯示這個；會員與後台皆不可編輯。後台的名字仍是 members.name';

-- backfill：已綁 LINE 的會員，現有 name 幾乎都是 auto-register 從 LINE 帶進來的，
-- 拿它當起始值最接近事實；之後任何一次 LINE 登入都會覆寫成當下的真值。
-- 沒綁 LINE 的（後台建檔 / 樂樂匯入）留 NULL，會員端 fallback 回 name。
-- 只寫新欄位，members.name 一個字都沒動。
--
-- set_config：members 有 touch_updated_at trigger，這支 backfill 會掃過所有
-- 已綁 LINE 的會員（線上約兩萬筆），不擋掉的話每一筆的 updated_at 都會被
-- 蓋成 migration 執行時間 —— 後台會員列表預設就是照「更新」排序，整個列表
-- 會變成一坨同一時間、店員再也看不出誰最近有動。GUC 是 20260611000010 為了
-- 同一個理由加進 touch_updated_at() 的。
SELECT set_config('app.skip_updated_at', '1', false);

UPDATE public.members
   SET line_display_name = name
 WHERE line_user_id IS NOT NULL
   AND line_display_name IS NULL
   AND name IS NOT NULL;

SELECT set_config('app.skip_updated_at', '', false);

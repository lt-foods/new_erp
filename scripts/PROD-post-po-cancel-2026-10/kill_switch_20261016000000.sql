-- ============================================================================
-- ⚠️ 會改正式庫（只改一個時間）：一鍵關掉 20261016000000「叫貨後才取消的件數照派原店」
-- ----------------------------------------------------------------------------
-- 做了什麼（只有這一件）
--   把分界時間 _picking_po_rule_cutover() 改成回 'infinity'（永遠不到）。
--   ⇒ 沒有任何採購單品項套新規則 ⇒ 派貨工作台、建撿貨單、分店追加、取消前提醒，
--     立刻回到貼 migration 之前的行為（數字跟改前一樣）。不用動任何其他東西。
--
-- 關掉之後會怎樣
--   * 叫貨後才取消的件數，又會跟以前一樣留在總倉。
--   * 已經照派原店建好的撿貨單、派貨單不會被改（這裡只改一個時間，不改任何一筆資料）。
--   * 前端的提醒、工作台的提示字會自動不出現（查不到要提醒的品項）。
--
-- 要重新打開：重貼一次 supabase/migrations/20261016000000_picking_post_po_cancel_to_store.sql
--   （分界時間會回到檔案裡寫的上線日，那天之後成立的採購單品項重新套用）。
--
-- 執行方式：整份貼進 Supabase SQL Editor、按一次 Run。可以重貼。
--   第 0 段：分界時間那支函式必須在、而且是 20261016000000 建的，否則停下、一行都不改。
-- ============================================================================

-- 0. 前置檢查（只讀）
DO $precheck$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public'
       AND p.proname = '_picking_po_rule_cutover'
       AND pg_get_function_identity_arguments(p.oid) = ''
       AND position('post_po_cancel_to_store:20261016000000' IN p.prosrc) > 0
  ) THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。找不到 20261016000000 建的 public._picking_po_rule_cutover()（migration 沒貼過、或已經還原），不用關';
  END IF;
END
$precheck$;

-- 1. 分界時間改成永遠不到
CREATE OR REPLACE FUNCTION public._picking_po_rule_cutover()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
  -- post_po_cancel_to_store:20261016000000（一鍵關掉：永遠不到 ⇒ 回到改前的行為）
  SELECT 'infinity'::TIMESTAMPTZ
$$;

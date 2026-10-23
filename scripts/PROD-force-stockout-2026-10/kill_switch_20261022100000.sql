-- ============================================================================
-- ⚠️ 會改正式庫（只清空一張名單）：一鍵關掉 20261022100000「已到貨也能斷貨」
-- ----------------------------------------------------------------------------
-- 做了什麼（只有這一件）
--   把「誰能按」的名單 po_force_stockout_operators 整張清空。
--   ⇒ 下一次打開（或重新整理）採購單頁，任何人都看不到「已到貨也能斷貨」那顆鈕；
--     就算有人直接叫後端，預覽與執行也會回「沒有權限」。不用重新登入。
--
-- 關掉之後會怎樣
--   * 已經用這顆鈕取消的客人品項不會被改回來（這裡只清名單，不碰任何訂單）。
--   * 原本的「⛔ 斷貨」鈕、刪除品項、退貨等其他功能都不受影響。
--
-- 要重新打開：貼開權限範本 grant_operator_TEMPLATE.sql（一個人貼一次）。
--
-- 執行方式：整份貼進 Supabase SQL Editor、按一次 Run。可以重貼（清空的名單再清一次也沒事）。
--   第 0 段：名單表必須在、而且是 20261022100000 建的，否則停下、一行都不改。
-- ============================================================================

DO $kill$
DECLARE
  v_oid REGCLASS := to_regclass('public.po_force_stockout_operators');
  v_n   INTEGER;
BEGIN
  -- 0. 前置檢查（只讀）
  IF v_oid IS NULL
     OR position('po_force_stockout:20261022100000' IN coalesce(obj_description(v_oid, 'pg_class'), '')) = 0 THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。找不到 20261022100000 建的名單表 po_force_stockout_operators（migration 沒貼過、或已經還原），不用關';
  END IF;

  -- 1. 清空名單
  DELETE FROM public.po_force_stockout_operators;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RAISE NOTICE '✅ 已關掉：名單清空（拿掉 % 人）。重新整理採購單頁之後，任何人都看不到「已到貨也能斷貨」。', v_n;
END
$kill$;

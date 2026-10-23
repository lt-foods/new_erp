-- ============================================================================
-- ⚠️ 會改正式庫：還原 20261022100000「已到貨也能斷貨」——把本檔新加的東西全部拿掉
-- ----------------------------------------------------------------------------
-- 拿掉什麼（都是 20261022100000 新加的；既有的表、函式一個都不碰）
--   * 函式：rpc_force_stockout_po_item、rpc_preview_force_stockout、rpc_can_force_stockout、_force_stockout_plan
--   * 名單表：po_force_stockout_operators（連同裡面的名單）
--
-- 拿掉之後會怎樣
--   * 前端已經上線的話：採購單頁叫不到 rpc_can_force_stockout ⇒ 當成「不能按」，按鈕不出現；其他功能照常。
--   * 已經用這顆鈕取消的客人品項不會被改回來（還原只拿掉程式，不碰任何訂單）。
--     那些品項的編輯歷史原因寫著「已到貨斷貨（採購單品項 #N）：…」，之後要查還查得到。
--   * 要再打開：重貼 migration，再貼一次開權限範本（名單會跟著表一起拿掉）。
--
-- 只想先關掉、不想拿掉程式：改貼 kill_switch_20261022100000.sql（只清名單）。
--
-- 執行方式：整份貼進 Supabase SQL Editor、按一次 Run。可以重貼（已經拿掉的會跳過）。
--   第 0 段：現存的同名東西都必須是 20261022100000 建的（有它的記號），不是就停下、一行都不改。
-- ============================================================================

-- 0. 前置檢查（只讀）
DO $precheck$
DECLARE
  v_oid REGCLASS := to_regclass('public.po_force_stockout_operators');
  v_bad TEXT;
BEGIN
  IF v_oid IS NOT NULL
     AND position('po_force_stockout:20261022100000' IN coalesce(obj_description(v_oid, 'pg_class'), '')) = 0 THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。po_force_stockout_operators 不是 20261022100000 建的（說明裡沒有記號），請先找工程師確認';
  END IF;

  v_bad := (SELECT string_agg(p.oid::regprocedure::text, '、')
              FROM pg_proc p
              JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public'
               AND p.proname IN ('_force_stockout_plan', 'rpc_can_force_stockout',
                                 'rpc_preview_force_stockout', 'rpc_force_stockout_po_item')
               AND position('po_force_stockout:20261022100000' IN p.prosrc) = 0);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。這幾支同名函式不是 20261022100000 建的：%，請先找工程師確認', v_bad;
  END IF;
END
$precheck$;

BEGIN;

DROP FUNCTION IF EXISTS public.rpc_force_stockout_po_item(BIGINT, TEXT, BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS public.rpc_preview_force_stockout(BIGINT);
DROP FUNCTION IF EXISTS public.rpc_can_force_stockout();
DROP FUNCTION IF EXISTS public._force_stockout_plan(BIGINT, UUID);
DROP TABLE IF EXISTS public.po_force_stockout_operators;

COMMIT;

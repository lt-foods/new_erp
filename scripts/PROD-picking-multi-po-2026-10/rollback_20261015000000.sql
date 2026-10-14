-- ============================================================================
-- ⚠️ 會改正式庫（只拿掉一支只讀 view）：還原 20261015000000
-- ----------------------------------------------------------------------------
-- 什麼時候用
--   貼完 supabase/migrations/20261015000000_picking_multi_po_campaigns.sql 之後，
--   postcheck_readonly.sql 有 ❌，或撿貨草稿／派貨工作台因為這支 view 出問題，就貼這一份。
--
-- 做了什麼（只有這一件）
--   拿掉 public.v_picking_multi_po_campaigns 這一支只讀 view。
--   不動任何資料表、任何一筆資料、其他 view、任何函式；不加 CASCADE
--   （萬一有別的東西建在它上面，會直接報錯停下，不會連帶拿掉別人的東西）。
--
-- 還原之後會怎樣
--   * 前端還沒合併：完全回到貼 migration 之前的樣子。
--   * 前端已經合併：撿貨草稿每一樣商品都會走「多張採購單檢查失敗」——各店數量全部留 0、
--     紅字請人照訂單樞紐自己填；派貨工作台最上面多一行紅字「多張採購單檢查失敗」，
--     其他功能照常。要恢復就重貼一次 migration。
--
-- 執行方式
--   整份貼進 Supabase SQL Editor、按一次 Run。
--   第 0 段前置檢查放最前面：同名的東西如果不是 20261015000000 建的那支 view，直接停下，一行都不會改。
--   整份可以重貼（已經拿掉了再貼，也只是什麼都不做）。
-- ============================================================================

-- 0. 前置檢查（只讀）
DO $precheck$
DECLARE
  v_oid     REGCLASS;
  v_kind    "char";
  v_comment TEXT;
BEGIN
  v_oid := to_regclass('public.v_picking_multi_po_campaigns');
  IF v_oid IS NULL THEN
    RAISE NOTICE '找不到 public.v_picking_multi_po_campaigns（已經拿掉了，或從來沒貼過），這次什麼都不會改';
    RETURN;
  END IF;
  v_kind := (SELECT c.relkind FROM pg_class c WHERE c.oid = v_oid);
  v_comment := obj_description(v_oid, 'pg_class');
  IF v_kind <> 'v'
     OR position('picking_multi_po_campaigns:20261015000000' IN coalesce(v_comment, '')) = 0 THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。public.v_picking_multi_po_campaigns 不是 20261015000000 的版本（說明裡沒有記號），請先找工程師確認';
  END IF;
END
$precheck$;

-- 1. 只拿掉這一支 view
DROP VIEW IF EXISTS public.v_picking_multi_po_campaigns;

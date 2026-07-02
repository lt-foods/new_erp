-- ============================================================================
-- 2026-07-02: PR 品項自動帶入預設供應商（trigger fallback + draft backfill）
-- ----------------------------------------------------------------------------
-- 需求（PR2607020424 實案）：
--   產品主檔有設「預設供應商」（products.default_supplier_id，ProductForm 維護），
--   但所有建 PR 的 RPC（close_date / campaigns / 單團 / 補貨）帶供應商時
--   只查 supplier_skus.is_preferred；該 SKU 若沒建 supplier_skus 對照
--   （例：sku 2497 櫻桃，產品預設供應商=包子媽，supplier_skus 0 筆），
--   suggested_supplier_id 就是 NULL，使用者每張單都要手動指派。
--
-- 修法：BEFORE INSERT trigger on purchase_request_items —
--   插入時若 suggested_supplier_id IS NULL：
--     1) 先查 supplier_skus 的 is_preferred 供應商（維持既有優先序）
--     2) 再 fallback 產品主檔 products.default_supplier_id
--   兩者都限 suppliers.is_active = TRUE。
--   選 trigger 而非逐支改 RPC：一次覆蓋全部現有與未來的建單路徑，
--   也避免 CREATE OR REPLACE 疊改多支函式的覆蓋回歸風險
--   （rpc_create_pr_from_close_date / rpc_append_campaign_to_pr 最新版在
--    20260625000000、rpc_create_pr_from_campaigns 在 20260513000001、
--    單團與 blank 在 20260505000000、補貨在 20260606000050 — 全部不動）。
--   既有 RPC 已自帶 supplier_skus 查詢者，查得到就不會進 trigger 的 WHEN。
--
-- Backfill：現存 draft 狀態 PR 的未指派品項，以同一 fallback 鏈補上
--   （只動 draft — submitted/cancelled 不碰；suggested_ 本來就是草稿階段可改的建議值）。
--
-- Rollback：
--   DROP TRIGGER trg_pri_fill_default_supplier ON public.purchase_request_items;
--   DROP FUNCTION public.trg_pri_fill_default_supplier();
--   （backfill 不可逆，但只影響 draft 的建議值，可在 UI 改回）
-- ============================================================================

CREATE OR REPLACE FUNCTION public.trg_pri_fill_default_supplier()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID;
BEGIN
  SELECT tenant_id INTO v_tenant FROM purchase_requests WHERE id = NEW.pr_id;

  -- 1) supplier_skus 偏好供應商（維持既有優先序）
  SELECT ss.supplier_id INTO NEW.suggested_supplier_id
    FROM supplier_skus ss
    JOIN suppliers sup ON sup.id = ss.supplier_id AND sup.is_active
   WHERE ss.tenant_id = v_tenant
     AND ss.sku_id = NEW.sku_id
     AND ss.is_preferred = TRUE
   LIMIT 1;

  -- 2) fallback：產品主檔預設供應商
  IF NEW.suggested_supplier_id IS NULL THEN
    SELECT p.default_supplier_id INTO NEW.suggested_supplier_id
      FROM skus s
      JOIN products p ON p.id = s.product_id
      JOIN suppliers sup ON sup.id = p.default_supplier_id AND sup.is_active
     WHERE s.id = NEW.sku_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pri_fill_default_supplier ON public.purchase_request_items;
CREATE TRIGGER trg_pri_fill_default_supplier
BEFORE INSERT ON public.purchase_request_items
FOR EACH ROW
WHEN (NEW.suggested_supplier_id IS NULL)
EXECUTE FUNCTION public.trg_pri_fill_default_supplier();

COMMENT ON FUNCTION public.trg_pri_fill_default_supplier() IS
  'PR 品項插入時自動帶預設供應商：supplier_skus.is_preferred → products.default_supplier_id（皆限 active）';

-- ============================================================================
-- Backfill：draft PR 的未指派品項補建議供應商（同一 fallback 鏈）
-- ============================================================================
UPDATE purchase_request_items pri
   SET suggested_supplier_id = COALESCE(
         (SELECT ss.supplier_id
            FROM supplier_skus ss
            JOIN suppliers sup ON sup.id = ss.supplier_id AND sup.is_active
           WHERE ss.tenant_id = pr.tenant_id
             AND ss.sku_id = pri.sku_id
             AND ss.is_preferred = TRUE
           LIMIT 1),
         (SELECT p.default_supplier_id
            FROM skus s
            JOIN products p ON p.id = s.product_id
            JOIN suppliers sup ON sup.id = p.default_supplier_id AND sup.is_active
           WHERE s.id = pri.sku_id)
       )
  FROM purchase_requests pr
 WHERE pr.id = pri.pr_id
   AND pr.status = 'draft'
   AND pri.suggested_supplier_id IS NULL
   -- 只動真的補得到值的列，避免無效 UPDATE 空轉 updated_at
   AND (
     EXISTS (SELECT 1
               FROM supplier_skus ss
               JOIN suppliers sup ON sup.id = ss.supplier_id AND sup.is_active
              WHERE ss.tenant_id = pr.tenant_id
                AND ss.sku_id = pri.sku_id
                AND ss.is_preferred = TRUE)
     OR EXISTS (SELECT 1
                  FROM skus s
                  JOIN products p ON p.id = s.product_id
                  JOIN suppliers sup ON sup.id = p.default_supplier_id AND sup.is_active
                 WHERE s.id = pri.sku_id)
   );

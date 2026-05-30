-- ============================================================
-- 2026-06-30: 請購單(PR)審核通過時，同步「分店價」到商品(prices scope=branch)
--
-- 需求：PR 品項填的 franchise_price（分店價），在審核通過那一刻同步成為
-- 商品的現行分店價，不必再到商品頁手動改價。
--
-- 設計：擴寫 rpc_approve_purchase_request — 原本只改 PR review_status/status，
-- 新增一段：對該 PR 每個 franchise_price 有填(>0) 的品項，呼叫既有
-- rpc_upsert_price(scope='branch') 寫入。rpc_upsert_price 會自動把舊的
-- branch 現價 effective_to 收掉、開新一筆（時間序版本控管），故重複審核同價
-- 也只是新增一筆相同價的版本 — 為避免洗無意義的價格歷史，只在「新價與現行
-- branch 價不同」時才寫。
--
-- 只同步分店價（branch），不動售價(retail)/成本(cost)。
--
-- 基底版本：20260423120003_purchase_v02_review_arrival.sql 的
--   rpc_approve_purchase_request（已 dump 線上確認一致，無其他 hotfix）。
-- 依賴：rpc_upsert_price(uuid,bigint,text,bigint,numeric,timestamptz,text,uuid)
--   （20260424120001 / 20260514000001 系列，scope='branch' 已支援）。
-- Rollback：CREATE OR REPLACE 回 20260423120003 的版本（移除價格同步段）。
--   已寫入的 branch price 版本為正常改價資料、不需回收。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_approve_purchase_request(p_pr_id bigint, p_note text, p_operator uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_pr   RECORD;
  v_item RECORD;
  v_cur  NUMERIC;
  v_now  TIMESTAMPTZ := NOW();
BEGIN
  SELECT * INTO v_pr FROM purchase_requests
   WHERE id = p_pr_id AND review_status = 'pending_review' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PR % not found or not pending_review', p_pr_id;
  END IF;

  UPDATE purchase_requests
     SET review_status = 'approved',
         review_note = p_note,
         reviewed_by = p_operator,
         reviewed_at = v_now,
         updated_by = p_operator,
         status = CASE WHEN status = 'draft' THEN 'submitted' ELSE status END,
         submitted_at = CASE WHEN status = 'draft' THEN v_now ELSE submitted_at END
   WHERE id = p_pr_id;

  -- 同步分店價：對每個 franchise_price 有填(>0) 的品項，若與現行 branch 價不同則更新
  FOR v_item IN
    SELECT sku_id, franchise_price
      FROM purchase_request_items
     WHERE pr_id = p_pr_id
       AND franchise_price IS NOT NULL
       AND franchise_price > 0
  LOOP
    -- 現行 branch 價（effective_to IS NULL 為當前生效）
    SELECT price INTO v_cur
      FROM prices
     WHERE tenant_id = v_pr.tenant_id
       AND sku_id = v_item.sku_id
       AND scope = 'branch'
       AND scope_id IS NULL
       AND effective_to IS NULL
     ORDER BY effective_from DESC
     LIMIT 1;

    -- 只有「沒設過」或「價格有變」才寫，避免洗無意義的價格歷史
    IF v_cur IS DISTINCT FROM v_item.franchise_price THEN
      PERFORM public.rpc_upsert_price(
        v_pr.tenant_id, v_item.sku_id, 'branch', NULL, v_item.franchise_price,
        v_now, format('PR %s 審核通過同步分店價', v_pr.pr_no), p_operator
      );
    END IF;
  END LOOP;
END;
$function$;

COMMENT ON FUNCTION public.rpc_approve_purchase_request(bigint, text, uuid) IS
  '審核通過請購單。20260630 起：同時把品項填的 franchise_price 同步成商品現行'
  '分店價(prices scope=branch，僅在與現價不同時寫)。';

-- ============================================================================
-- 20260925000000_auto_open_activates_draft_products.sql
--
-- 自動開團：商品還是「草稿」的話順手上架，不要卡住。
-- 9/25 早上 08:00 九個排定開團的草稿一個都沒開 —— 商品是建團當下一起建的，
-- 都還停在 draft，rpc_auto_open_scheduled_campaigns 照手動開團的檢查擋下來
-- （auto_open_error 寫「下列商品尚未上架」）。快速開團頁在「立即開團」時本來就會把商品
-- 設成 active（rpc_upsert_product p_status='active'），自動開團比照：品項的商品是 draft
-- 且 SKU 是 active → 直接 active。inactive / discontinued（人刻意下架的）維持擋住。
--
-- 基底：rpc_auto_open_scheduled_campaigns @ 20260924040000（唯一一版）。
-- rollback：還原 20260924040000 的版本。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_auto_open_scheduled_campaigns()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r        RECORD;
  v_err    TEXT;
  v_opened INT := 0;
BEGIN
  FOR r IN
    SELECT id, close_type FROM group_buy_campaigns
     WHERE status = 'draft' AND auto_open AND start_at IS NOT NULL AND start_at <= NOW()
     ORDER BY start_at, id
  LOOP
    v_err := NULL;
    IF r.close_type = 'food_train' THEN
      v_err := '美食列車要手動開團（開團時要推播給客人）';
    ELSIF NOT EXISTS (SELECT 1 FROM campaign_items WHERE campaign_id = r.id) THEN
      v_err := '沒有任何商品，無法自動開團';
    ELSE
      -- 草稿商品順手上架（同快速開團頁「立即開團」的行為）
      UPDATE products p SET status = 'active'
       WHERE p.status = 'draft'
         AND p.id IN (SELECT s.product_id FROM campaign_items ci
                        JOIN skus s ON s.id = ci.sku_id AND s.status = 'active'
                       WHERE ci.campaign_id = r.id);
      SELECT '下列商品已下架或停售，無法自動開團：'
             || string_agg(DISTINCT p.product_code || ' ' || p.name, '、')
        INTO v_err
        FROM campaign_items ci
        JOIN skus s     ON s.id = ci.sku_id
        JOIN products p ON p.id = s.product_id
       WHERE ci.campaign_id = r.id AND p.status <> 'active'
      HAVING count(*) > 0;
    END IF;

    IF v_err IS NOT NULL THEN
      UPDATE group_buy_campaigns SET auto_open_error = v_err
       WHERE id = r.id AND auto_open_error IS DISTINCT FROM v_err;
      CONTINUE;
    END IF;

    BEGIN
      UPDATE group_buy_campaigns
         SET status = 'open', auto_open = FALSE, auto_open_error = NULL
       WHERE id = r.id AND status = 'draft';
      v_opened := v_opened + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE group_buy_campaigns SET auto_open_error = left('自動開團失敗：' || SQLERRM, 500)
       WHERE id = r.id;
    END;
  END LOOP;
  RETURN v_opened;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_auto_open_scheduled_campaigns() FROM PUBLIC, anon, authenticated;

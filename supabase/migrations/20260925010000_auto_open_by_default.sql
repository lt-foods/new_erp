-- ============================================================================
-- 20260925010000_auto_open_by_default.sql
--
-- 老闆指示：不用勾，草稿的開團時間到了就自動開團（畫面上的勾選拿掉）。
-- 母體：status='draft'、start_at 已到、而且 start_at 是「排在未來」的（start_at >= created_at − 5 分鐘：
--   建團時就填了未來的開團時間），並且 start_at 在 2026-09-25 之後 —— 舊的陳年草稿
--   （例：GRP-20260821-001、GRP-20260805-029）不要突然被開出來。
-- auto_open 欄位留著不用；auto_open_error 照寫（後台沒畫，但查得到）。
--
-- 基底：rpc_auto_open_scheduled_campaigns @ 20260925000000。
-- rollback：還原 20260925000000 的版本。
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
     WHERE status = 'draft'
       AND start_at IS NOT NULL AND start_at <= NOW()
       AND start_at >= created_at - INTERVAL '5 minutes'
       AND start_at >= TIMESTAMPTZ '2026-09-25 00:00:00+08'
     ORDER BY start_at, id
  LOOP
    v_err := NULL;
    IF r.close_type = 'food_train' THEN
      v_err := '美食列車要手動開團（開團時要推播給客人）';
    ELSIF NOT EXISTS (SELECT 1 FROM campaign_items WHERE campaign_id = r.id) THEN
      v_err := '沒有任何商品，無法自動開團';
    ELSE
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

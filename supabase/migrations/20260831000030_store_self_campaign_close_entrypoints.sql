-- ============================================================================
-- 店家自開團 (4/5)：**所有**結單入口都要走自開團分支
-- ============================================================================
-- 20260831000010 只改了 rpc_close_campaign。但全站有三個入口會把團從 open 推走，
-- 另外兩個都是直接 `UPDATE ... SET status='closed'`：
--
--   1. rpc_close_campaign              ← 已處理（開團列表的「結單」鈕、手機團控）
--   2. rpc_auto_close_expired_campaigns ← pg_cron 每分鐘掃 end_at 到期
--   3. rpc_bulk_set_campaign_status     ← 開團列表的「批次結單」
--
-- 漏掉 2 / 3 的後果正是 CLAUDE.md「把某個角色的動作按鈕拿掉之前，先確認狀態機
-- 還有別人推得動」記的那種洞：團被切成 closed、訂單留在 pending、**團不會切到 receiving**，
-- 收貨頁根本不會出現這個團，店家什麼都看不到，畫面上不會報錯，只會安靜地不動。
-- 而且 2 是自動的 —— 只要店家開團時填了結單時間就一定會踩到。
--
-- 兩支都改成「自開團委派給 rpc_close_campaign，總倉團的行為一字不動」。
--
-- 基底版本：
--   rpc_auto_close_expired_campaigns = 20260605000014_auto_close_expired_campaigns.sql
--   rpc_bulk_set_campaign_status     = 20260514000012_cleanup_sku_on_deactivate_and_bulk_campaign_status.sql
-- Rollback：兩支各 CREATE OR REPLACE 回上列基底版本。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. rpc_auto_close_expired_campaigns（pg_cron 每分鐘）
--
--    總倉團維持原本的「單句 UPDATE 切 closed、不建 PR」——
--    自動結單本來就不建 PR（那是 rpc_close_campaign 手動路徑的行為），
--    這裡不順手改掉。
--    自開團逐張走 rpc_close_campaign：它會確認訂單 + 把團切到 receiving。
--    單張失敗只記 WARNING 不中斷 —— 一張壞掉不能讓整批到期團都關不掉。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_auto_close_expired_campaigns()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT := 0;
  v_hq    INT := 0;
  r       RECORD;
BEGIN
  -- 店家自開團：一定要走 rpc_close_campaign，否則團不會切到 receiving
  FOR r IN
    SELECT id FROM group_buy_campaigns
     WHERE status = 'open'
       AND end_at IS NOT NULL
       AND end_at < NOW()
       AND owner_store_id IS NOT NULL
  LOOP
    BEGIN
      PERFORM public.rpc_close_campaign(r.id, NULL);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'auto-close store campaign % failed: %', r.id, SQLERRM;
    END;
  END LOOP;

  -- 總倉團：基底 20260605000014 的行為，一字未動（只多一個 owner_store_id IS NULL）
  WITH closed AS (
    UPDATE group_buy_campaigns
       SET status     = 'closed',
           updated_at = NOW()
     WHERE status     = 'open'
       AND end_at IS NOT NULL
       AND end_at < NOW()
       AND owner_store_id IS NULL
    RETURNING id
  )
  SELECT COUNT(*) INTO v_hq FROM closed;

  RETURN v_count + v_hq;
END;
$$;

COMMENT ON FUNCTION public.rpc_auto_close_expired_campaigns IS
  '每分鐘 cron 掃 end_at 到期的 open 活動切成 closed。'
  '店家自開團改走 rpc_close_campaign（要確認訂單並切到 receiving），總倉團維持原本的單句 UPDATE。';

-- ----------------------------------------------------------------------------
-- 2. rpc_bulk_set_campaign_status（開團列表「批次結單」）
--    基底 20260514000012，只在 open → closed 那一步分流。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_bulk_set_campaign_status(
  p_ids    BIGINT[],
  p_status TEXT
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
  v_cur    TEXT;
  v_owner  BIGINT;
  v_count  INTEGER := 0;
BEGIN
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;
  IF p_status NOT IN ('draft','open','closed','cancelled') THEN
    RAISE EXCEPTION 'invalid bulk target status: %', p_status;
  END IF;

  FOREACH v_id IN ARRAY p_ids LOOP
    SELECT status, owner_store_id INTO v_cur, v_owner FROM group_buy_campaigns
      WHERE id = v_id AND tenant_id = v_tenant;
    IF v_cur IS NULL THEN
      CONTINUE; -- 跨 tenant / 不存在
    END IF;
    IF v_cur = p_status THEN
      CONTINUE; -- 已是目標
    END IF;

    -- 合法轉換：
    --   draft → open / cancelled
    --   open  → closed / cancelled
    --   closed → cancelled
    IF NOT (
         (v_cur = 'draft'  AND p_status IN ('open','cancelled'))
      OR (v_cur = 'open'   AND p_status IN ('closed','cancelled'))
      OR (v_cur = 'closed' AND p_status = 'cancelled')
    ) THEN
      CONTINUE; -- 跳過不合法的轉換
    END IF;

    -- 額外保護：draft→open 前要有 campaign_items
    IF v_cur = 'draft' AND p_status = 'open' THEN
      PERFORM 1 FROM campaign_items WHERE campaign_id = v_id LIMIT 1;
      IF NOT FOUND THEN
        CONTINUE;
      END IF;
    END IF;

    -- 20260831：店家自開團的結單不是單純改一個欄位（要確認訂單 + 切 receiving），
    -- 委派給 rpc_close_campaign。它會把 status 切到 'receiving'（＝等收貨）。
    IF v_cur = 'open' AND p_status = 'closed' AND v_owner IS NOT NULL THEN
      BEGIN
        PERFORM public.rpc_close_campaign(v_id, auth.uid());
        v_count := v_count + 1;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'bulk close store campaign % failed: %', v_id, SQLERRM;
      END;
      CONTINUE;
    END IF;

    UPDATE group_buy_campaigns
       SET status     = p_status,
           updated_by = auth.uid(),
           updated_at = NOW()
     WHERE id = v_id AND tenant_id = v_tenant;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.rpc_bulk_set_campaign_status IS
  '批次改開團狀態。店家自開團的 open→closed 委派給 rpc_close_campaign'
  '（要確認訂單並切到 receiving），其餘維持基底 20260514000012 的行為。';

GRANT EXECUTE ON FUNCTION public.rpc_bulk_set_campaign_status(BIGINT[], TEXT) TO authenticated;

-- ============================================================================
-- 20260927040000_line_note_close_on_manual_close.sql
--
-- 手動關團也要留「結單」留言（老闆 9/27：「手動也要」）。
-- 9/27 芝芝有機小農蔬菜（客人收單 18:00）17:59 被手動關成已結束，18:00 tick 到時
-- _line_note_enqueue_due_closes 要 g.status='open' → 7 篇貼文一則都沒留。
--
-- 做法：group_buy_campaigns 的 status 從 open 離開（closed / locked / receiving…，
-- 不含 draft / cancelled）時，trigger 直接替該團所有 posted 貼文排 kind='close' 工作
-- （payload.trigger='manual_close'）。close_notified_at 已寫的不排 → 客人收單先到、
-- 之後再手動關不會留兩次；反之亦然。
-- 每分鐘的 rpc_auto_close_expired_campaigns（店家收單 end_at 到期自動關）**不留**：
-- 9/25 老闆說店家結單不是客人結單（20260925030000），它用 set_config 旗標讓 trigger 跳過。
-- 客人收單時間到的那條路（_line_note_enqueue_due_closes）不動。
--
-- worker 的 jobClose 原本「團不是 open 就跳過」，同批改成只跳過 draft / cancelled。
--
-- 基底：rpc_auto_close_expired_campaigns @ 20260831000060（只多一行 set_config，其餘一字未動）。
-- rollback：DROP TRIGGER trg_line_note_on_campaign_close ON group_buy_campaigns;
--   DROP FUNCTION _line_note_on_campaign_close(); rpc_auto_close_expired_campaigns 還原 20260831000060。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._line_note_on_campaign_close()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  IF OLD.status <> 'open' OR NEW.status IN ('open', 'draft', 'cancelled') THEN
    RETURN NEW;
  END IF;
  -- 店家收單到期的自動關團不留言（rpc_auto_close_expired_campaigns 設的旗標）
  IF COALESCE(current_setting('line_note.skip_close', true), '') = '1' THEN
    RETURN NEW;
  END IF;

  INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, payload, created_by)
  SELECT p.tenant_id, 'close', c.account_id, p.community_id, p.id,
         jsonb_build_object('trigger', 'manual_close'), NEW.updated_by
    FROM line_note_posts p
    JOIN line_note_communities c ON c.id = p.community_id
   WHERE p.campaign_id = NEW.id
     AND p.status = 'posted' AND p.line_post_id IS NOT NULL AND p.close_notified_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM line_note_jobs j
                      WHERE j.kind = 'close' AND j.post_id = p.id AND j.status IN ('queued', 'running'));
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_on_campaign_close() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_line_note_on_campaign_close ON public.group_buy_campaigns;
CREATE TRIGGER trg_line_note_on_campaign_close
  AFTER UPDATE OF status ON public.group_buy_campaigns
  FOR EACH ROW EXECUTE FUNCTION public._line_note_on_campaign_close();

-- 自動關團：基底 20260831000060，只加 set_config 那一行。
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
  -- 店家收單到期 ≠ 客人結單：這條路不排結單留言（20260927040000）
  PERFORM set_config('line_note.skip_close', '1', true);

  -- 店家自開團：一定要走 _close_store_campaign，否則團不會切到 receiving
  FOR r IN
    SELECT id FROM group_buy_campaigns
     WHERE status = 'open'
       AND end_at IS NOT NULL
       AND end_at < NOW()
       AND owner_store_id IS NOT NULL
  LOOP
    BEGIN
      PERFORM public._close_store_campaign(r.id, NULL);
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
  '店家自開團改走 _close_store_campaign（確認訂單並切到 receiving），'
  '總倉團維持原本的單句 UPDATE。不排 LINE 記事本結單留言（20260927040000）。';

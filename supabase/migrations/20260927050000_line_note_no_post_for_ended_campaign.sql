-- ============================================================================
-- 20260927050000_line_note_no_post_for_ended_campaign.sql
--
-- 收單時間已過的團「改回開團中」不要自動發記事本。
--
-- 9/27 19:45 / 19:48 GRP-20260922-004、GRP-20260922-012（客人收單 9/24、店家收單 9/25
-- 都過了）在開團編輯表單被改回「開團中」、幾十秒後又改回已收單。狀態一變成 open，
-- trg_line_note_on_campaign_open 就對「開了自動發文、還沒貼過這團」的社群發文 ——
-- 其他 7 個社群 9/22 已經有貼文（ON CONFLICT DO NOTHING 跳過），只剩經國店沒有，
-- 結果兩篇早就結單的團今天貼到經國店去，客人看到卻不能下單。
--
-- 修法：客人收單時間（customer_end_at）或店家收單時間（end_at）任一已過，
-- 變成 open 也不發（其餘守衛與 loop 一字不動）。真的要對過期的團發文，
-- 開團列表的「LINE 記事本」彈窗手動勾社群還是可以（rpc_line_note_queue_posts 不動：
-- 已收單的團仍可補加單，那條是刻意留的）。
--
-- 基底：_line_note_on_campaign_open @ 20260927010000（只加一個時間守衛）。
-- rollback：函式還原到 20260927010000 那版。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._line_note_on_campaign_open()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c RECORD;
  v_post BIGINT;
BEGIN
  -- 只在「剛變成 open」時跑：INSERT 直接看 NEW，UPDATE 要 OLD 不是 open
  IF NEW.status <> 'open' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'open' THEN RETURN NEW; END IF;
  -- 補貨申請的 sentinel 團（20260612000020）建立時就是 open，不是要發的團
  IF NEW.campaign_no = '__INTERNAL_RESTOCK__' THEN RETURN NEW; END IF;
  -- 這團開團時不發記事本（開團表單的開關）
  IF NOT COALESCE(NEW.line_note_enabled, TRUE) THEN RETURN NEW; END IF;
  -- 收單時間已過的團（多半是已收單的團被改回開團中）不發：客人看到也下不了單
  IF (NEW.customer_end_at IS NOT NULL AND NEW.customer_end_at <= NOW())
     OR (NEW.end_at IS NOT NULL AND NEW.end_at <= NOW()) THEN
    RETURN NEW;
  END IF;

  FOR v_c IN
    SELECT c.id AS community_id, c.account_id, c.post_mode
      FROM line_note_communities c
      JOIN line_note_accounts a ON a.id = c.account_id AND a.status = 'active'
     WHERE c.tenant_id = NEW.tenant_id
       AND c.auto_post_on_open
       AND c.share_from_community_id IS NULL
       AND (NEW.owner_store_id IS NULL OR c.store_id = NEW.owner_store_id)
       AND public._line_note_takes_channel(c.sales_channels, NEW.sales_channel)
  LOOP
    INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, share_state, created_by, updated_by)
    VALUES (NEW.tenant_id, v_c.community_id, NEW.id, 'queued',
            CASE WHEN v_c.post_mode = 'immediate' THEN 'none' ELSE 'scheduled' END,
            NEW.updated_by, NEW.updated_by)
    ON CONFLICT (community_id, campaign_id) DO NOTHING
    RETURNING id INTO v_post;
    IF v_post IS NOT NULL THEN
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
      VALUES (NEW.tenant_id, 'post', v_c.account_id, v_c.community_id, v_post, NEW.updated_by);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

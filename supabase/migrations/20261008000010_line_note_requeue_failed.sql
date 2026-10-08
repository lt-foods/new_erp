-- ============================================================================
-- LINE 記事本：一鍵重發「發文失敗」的貼文
--
-- 背景（2026-10-08）：早上 LINE 暫時限制帳號使用社群，78 篇開團貼文被標「發文失敗」。
-- 失敗的列在後台只有「刪除紀錄」可以按，要補發只能一團一團開「LINE 記事本」彈窗重勾，
-- 一天十幾團 × 8 個社群根本按不完。
--
-- rpc_line_note_requeue_failed(p_campaign_id = NULL)：
--   把（這個 tenant / 這一團的）發文失敗、以及「排隊中但沒有工作在跑」的貼文，
--   依團分組丟給 rpc_line_note_queue_posts（20260929000000）重新排入 ——
--   規則完全沿用它（只發開團中／已收單、門市自開團不發、子群不另外發、社群要收這類團、
--   帳號要登入、已經在 LINE 上的跳過），這裡不另外寫一套。
--   團已鎖定之後的失敗列不重發（客人已經不能 +1，發了也沒用）。
--
-- 回傳：重新排入幾篇、略過幾篇、略過的原因（去重）。
-- rollback：DROP FUNCTION public.rpc_line_note_requeue_failed(BIGINT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_line_note_requeue_failed(p_campaign_id BIGINT DEFAULT NULL)
RETURNS TABLE (out_queued INT, out_skipped INT, out_errors TEXT[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant  UUID := public._line_note_require_admin();
  r         RECORD;
  q         RECORD;
  v_queued  INT := 0;
  v_skipped INT := 0;
  v_errors  TEXT[] := ARRAY[]::TEXT[];
BEGIN
  FOR r IN
    SELECT p.campaign_id, array_agg(p.community_id ORDER BY p.community_id) AS cids
      FROM line_note_posts p
      JOIN group_buy_campaigns g ON g.id = p.campaign_id
     WHERE p.tenant_id = v_tenant
       AND p.line_post_id IS NULL
       AND (p.status = 'failed'
            -- 工作在 try 之前就死掉時，貼文會停在排隊中、卻沒有工作在跑（10/7 南平、六甲各一篇）
            OR (p.status = 'queued' AND NOT EXISTS (
                  SELECT 1 FROM line_note_jobs j
                   WHERE j.kind = 'post' AND j.post_id = p.id AND j.status IN ('queued', 'running'))))
       AND g.status IN ('open', 'closed')
       AND g.owner_store_id IS NULL
       AND (p_campaign_id IS NULL OR p.campaign_id = p_campaign_id)
     GROUP BY p.campaign_id
     ORDER BY p.campaign_id
  LOOP
    FOR q IN SELECT * FROM public.rpc_line_note_queue_posts(r.campaign_id, r.cids) LOOP
      IF q.out_status = 'queued' THEN
        v_queued := v_queued + 1;
      ELSE
        v_skipped := v_skipped + 1;
        IF q.out_error IS NOT NULL AND NOT (q.out_error = ANY (v_errors)) THEN
          v_errors := v_errors || q.out_error;
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  RETURN QUERY SELECT v_queued, v_skipped, v_errors;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_line_note_requeue_failed(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_requeue_failed(BIGINT) TO authenticated;

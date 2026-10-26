-- ============================================================================
-- 20261026000000_line_note_campaign_promo.sql
--
-- LINE 記事本：開團「推廣文」—— 針對某一團另外寫一段文字，機器人一次送到勾選的社群聊天室
-- （Alex 2026-10-26：「針對開團再寫推廣文，透過機器人一次發送到全部社團」）。
--
-- 每個社群送兩樣東西（跟結單提醒同一套動作）：
--   1. 推廣文字（聊天室訊息；可選擇在文末自動帶這團的商城連結）
--   2. 這團在該社群的記事本貼文卡片（LINE「分享貼文」，客人點進去就能 +1）
--      —— 該社群還沒有這團的貼文（沒發、已回收、已結單）就只送文字。
--
-- 這支：
--   - line_note_promos：一則推廣文一列（團、文字、要不要附卡片／連結、誰在什麼時候送的）。
--   - line_note_jobs 加 kind='promo' 與 promo_id：一個社群一筆工作，走 worker 的節流
--     （帳號暫停、每分鐘分享額度、跟結單提醒共用「每帳號每 N 分鐘一則」的慢速間隔），
--     不在任何 handler 裡自己迴圈送（CLAUDE.md「LINE 社群：分享到聊天室不能爆量」）。
--   - rpc_line_note_queue_promo：排工作。範圍規則跟 rpc_line_note_queue_posts 同一套
--     （門市自開團不發、社群要收這一類的團、帳號要登入）；團要是開團中、而且還沒過收單時間。
--     子群可以送（推廣文字送到子群自己的聊天室，卡片用子群那一列的貼文 id）。
--   - rpc_line_note_campaign_promos：開團彈窗列這團送過的推廣文、每個社群送到哪了。
--
-- 全部是新物件，沒有覆蓋既有 function（kind_check 基底 @ 20260929040000，只多 'promo'）。
--
-- rollback：
--   DROP FUNCTION public.rpc_line_note_campaign_promos(BIGINT);
--   DROP FUNCTION public.rpc_line_note_queue_promo(BIGINT, TEXT, BOOLEAN, BOOLEAN, BIGINT[]);
--   DELETE FROM line_note_jobs WHERE kind = 'promo';
--   ALTER TABLE line_note_jobs DROP COLUMN promo_id;
--   kind_check 還原 20260929040000；DROP TABLE line_note_promos;
--   worker 還原到 20261026000000 之前的版本（沒有 jobPromo，排進來的 promo 會被標失敗）。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 推廣文
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.line_note_promos (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  campaign_id  BIGINT NOT NULL REFERENCES public.group_buy_campaigns(id) ON DELETE CASCADE,
  text         TEXT NOT NULL CHECK (length(btrim(text)) BETWEEN 1 AND 2000),
  with_card    BOOLEAN NOT NULL DEFAULT TRUE,   -- 文字後面接這團的記事本貼文卡片
  with_link    BOOLEAN NOT NULL DEFAULT TRUE,   -- 文末自動帶這團的商城連結（worker 用 buildShopLink 產）
  created_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_line_note_promos_campaign ON public.line_note_promos (campaign_id, created_at DESC);

ALTER TABLE public.line_note_promos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lnpr_hq_read ON public.line_note_promos;
CREATE POLICY lnpr_hq_read ON public.line_note_promos FOR SELECT
  USING (tenant_id = (SELECT public._current_tenant_id())
         AND (SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', ''))
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']));
GRANT SELECT ON public.line_note_promos TO authenticated;

COMMENT ON TABLE public.line_note_promos IS
  '開團推廣文（20261026000000）：一列一則，送到各社群的進度在 line_note_jobs（kind=promo, promo_id）。';

-- ----------------------------------------------------------------------------
-- 2. 工作佇列：kind='promo'，一個社群一筆
-- ----------------------------------------------------------------------------
ALTER TABLE public.line_note_jobs
  ADD COLUMN IF NOT EXISTS promo_id BIGINT REFERENCES public.line_note_promos(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS idx_line_note_jobs_promo ON public.line_note_jobs (promo_id) WHERE promo_id IS NOT NULL;

ALTER TABLE public.line_note_jobs DROP CONSTRAINT IF EXISTS line_note_jobs_kind_check;
ALTER TABLE public.line_note_jobs ADD CONSTRAINT line_note_jobs_kind_check
  CHECK (kind IN ('login', 'logout', 'list_homes', 'post', 'read', 'close', 'remind', 'share', 'reopen', 'refresh', 'promo'));

-- ----------------------------------------------------------------------------
-- 3. 排推廣文
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_queue_promo(
  p_campaign_id   BIGINT,
  p_text          TEXT,
  p_with_card     BOOLEAN,
  p_with_link     BOOLEAN,
  p_community_ids BIGINT[]
) RETURNS TABLE (
  out_community_id BIGINT,
  out_job_id       BIGINT,
  out_status       TEXT,
  out_error        TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_text   TEXT := btrim(COALESCE(p_text, ''));
  v_g      RECORD;
  v_promo  BIGINT;
  v_cid    BIGINT;
  v_c      RECORD;
  v_job    BIGINT;
BEGIN
  SELECT g.status, g.owner_store_id, g.sales_channel, g.customer_end_at, g.end_at INTO v_g
    FROM group_buy_campaigns g WHERE g.id = p_campaign_id AND g.tenant_id = v_tenant;
  IF v_g.status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF v_g.status <> 'open' THEN
    RAISE EXCEPTION '只有開團中的團可以發推廣文';
  END IF;
  IF v_g.owner_store_id IS NOT NULL THEN
    RAISE EXCEPTION '門市自開團不發 LINE 記事本';
  END IF;
  IF COALESCE(v_g.customer_end_at, v_g.end_at) <= NOW() THEN
    RAISE EXCEPTION '這團已經過了收單時間，不用再推廣';
  END IF;
  IF v_text = '' THEN RAISE EXCEPTION '請先寫推廣文'; END IF;
  IF length(v_text) > 2000 THEN RAISE EXCEPTION '推廣文太長了（最多 2000 字，現在 % 字）', length(v_text); END IF;
  IF COALESCE(array_length(p_community_ids, 1), 0) = 0 THEN RAISE EXCEPTION '請至少勾一個社群'; END IF;

  -- 手滑點兩下：同一團同一段字 2 分鐘內不收第二次（不然每個聊天室都會收到兩則）
  IF EXISTS (
    SELECT 1 FROM line_note_promos pr
     WHERE pr.campaign_id = p_campaign_id AND pr.text = v_text
       AND pr.created_at > NOW() - INTERVAL '2 minutes'
  ) THEN
    RAISE EXCEPTION '同一則推廣文剛剛已經送出了，不用再按一次';
  END IF;

  INSERT INTO line_note_promos (tenant_id, campaign_id, text, with_card, with_link, created_by)
  VALUES (v_tenant, p_campaign_id, v_text, COALESCE(p_with_card, TRUE), COALESCE(p_with_link, TRUE), auth.uid())
  RETURNING id INTO v_promo;

  FOR v_cid IN
    SELECT DISTINCT x FROM unnest(p_community_ids) AS x
  LOOP
    SELECT lc.id, lc.account_id, lc.sales_channels, a.status AS a_status
      INTO v_c
      FROM line_note_communities lc
      JOIN line_note_accounts a ON a.id = lc.account_id
     WHERE lc.id = v_cid AND lc.tenant_id = v_tenant;
    IF v_c.id IS NULL THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT, '找不到這個社群'::TEXT;
      CONTINUE;
    END IF;
    -- 範圍規則同 rpc_line_note_queue_posts（自開團上面已經整團擋掉，這裡只剩類別）
    IF NOT public._line_note_takes_channel(v_c.sales_channels, v_g.sales_channel) THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT,
        '這個社群沒有開放「' || public._line_note_channel_label(v_g.sales_channel) || '」的團';
      CONTINUE;
    END IF;
    IF v_c.a_status <> 'active' THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT, 'LINE 帳號沒有登入'::TEXT;
      CONTINUE;
    END IF;

    INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, promo_id, created_by)
    VALUES (v_tenant, 'promo', v_c.account_id, v_cid, v_promo, auth.uid())
    RETURNING id INTO v_job;
    RETURN QUERY SELECT v_cid, v_job, 'queued'::TEXT, NULL::TEXT;
  END LOOP;

  -- 一個社群都排不進去就不留這則（彈窗的紀錄只列真的有送的）
  IF NOT EXISTS (SELECT 1 FROM line_note_jobs j WHERE j.promo_id = v_promo) THEN
    DELETE FROM line_note_promos WHERE id = v_promo;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_queue_promo(BIGINT, TEXT, BOOLEAN, BOOLEAN, BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_queue_promo(BIGINT, TEXT, BOOLEAN, BOOLEAN, BIGINT[]) TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. 這團送過的推廣文（新的在前），每則帶各社群的進度
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_campaign_promos(p_campaign_id BIGINT)
RETURNS TABLE (
  promo_id   BIGINT,
  text       TEXT,
  with_card  BOOLEAN,
  with_link  BOOLEAN,
  created_at TIMESTAMPTZ,
  sends      JSONB
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
BEGIN
  RETURN QUERY
  SELECT pr.id, pr.text, pr.with_card, pr.with_link, pr.created_at,
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'job_id', j.id,
                    'community_id', j.community_id,
                    'home_name', COALESCE(NULLIF(lc.home_name, ''), lc.home_id, '（社群已刪除）'),
                    'status', j.status,
                    'error', j.error,
                    'result', j.result,
                    'finished_at', j.finished_at
                  ) ORDER BY lc.home_name NULLS LAST, j.id)
             FROM line_note_jobs j
             LEFT JOIN line_note_communities lc ON lc.id = j.community_id
            WHERE j.promo_id = pr.id
         ), '[]'::jsonb)
    FROM line_note_promos pr
   WHERE pr.tenant_id = v_tenant AND pr.campaign_id = p_campaign_id
   ORDER BY pr.created_at DESC
   LIMIT 20;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_campaign_promos(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_campaign_promos(BIGINT) TO authenticated;

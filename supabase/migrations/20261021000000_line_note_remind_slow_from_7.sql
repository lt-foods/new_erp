-- ============================================================================
-- LINE 記事本：結單提醒改成早上 07:00 開始、每個帳號每 2 分鐘一則慢慢發
--
-- 背景：10/15、10/19、10/21 早上帳號連續被 LINE「限制使用社群」（code=403），每次都是從
--   結單提醒那一段開始：一篇今天結單的貼文分享一張卡，一個社群一天最多 88 張，
--   08:00／08:30／09:00 排進來後照每分鐘 5 則（chat_per_min）連打 15～20 分鐘，
--   累積 ~70 張就被鎖（小幫手前一天被鎖過的話 ~45 張就鎖）。而且越鎖越久：
--   10/8 五分鐘解，10/19 起一鎖 17 小時～2 天。每分鐘 N 則擋不住，要拉長整段時間。
--   結單時間幾乎都是 23:59（近 10 天 2,564／2,653），提早開始、慢慢發一整個早上來得及。
--
-- 這支：
--   - line_note_accounts.remind_every_min（預設 2，1～30）：同一個帳號的結單提醒每幾分鐘才發一則，
--     worker 依帳號讀（chat_per_min 照舊一起算）。後台帳號分頁可改。
--   - v_line_note_accounts 補出這一欄；rpc_line_note_account_set_remind_every_min 改值。
--   - remind_time 預設 08:00 → 07:00，現有社群全部改成 07:00（Alex 2026-10-21 指示）。
--   - _line_note_enqueue_due_reminds：依結單時間先後排、同帳號各社群輪流（不再一個聊天室連發 88 張），
--     worker 照 id 順序撿。
--
-- 基底：v_line_note_accounts @ 20261012000000（= 線上 pg_get_viewdef）、
--       _line_note_enqueue_due_reminds @ 20260925030000（= 線上 pg_get_functiondef）。
-- rollback：_line_note_enqueue_due_reminds 還原 20260925030000；
--           v_line_note_accounts 還原 20261012000000；DROP FUNCTION rpc_line_note_account_set_remind_every_min(BIGINT, INT)；
--           ALTER TABLE line_note_accounts DROP COLUMN remind_every_min（worker 讀不到時退回每 2 分鐘）；
--           remind_time 要改回原本各社群的時間（08:00／08:30／09:00）請到後台逐一調。
-- ============================================================================

ALTER TABLE line_note_accounts
  ADD COLUMN IF NOT EXISTS remind_every_min INT NOT NULL DEFAULT 2
    CHECK (remind_every_min BETWEEN 1 AND 30);

COMMENT ON COLUMN line_note_accounts.remind_every_min IS
  '結單提醒這個帳號每幾分鐘才發一則（20261021000000）。早上一口氣分享幾十張會被 LINE 限制使用社群，被擋就調大。';

ALTER TABLE line_note_communities ALTER COLUMN remind_time SET DEFAULT '07:00';
UPDATE line_note_communities SET remind_time = '07:00' WHERE remind_time IS DISTINCT FROM '07:00';

-- 基底：20261012000000，只在最後加一欄
CREATE OR REPLACE VIEW public.v_line_note_accounts AS
 SELECT id,
    tenant_id,
    label,
    status,
    line_mid,
    display_name,
    qr_image,
    qr_url,
    pin_code,
    last_error,
    last_seen_at,
    created_at,
    updated_at,
    chat_per_min,
    remind_every_min
   FROM line_note_accounts
  WHERE tenant_id = ((auth.jwt() ->> 'tenant_id'::text)::uuid)
    AND (COALESCE((auth.jwt() -> 'app_metadata'::text) ->> 'role'::text, ''::text)
         = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'assistant'::text, ''::text]));

CREATE OR REPLACE FUNCTION public.rpc_line_note_account_set_remind_every_min(p_id BIGINT, p_n INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
BEGIN
  IF p_n IS NULL OR p_n < 1 OR p_n > 30 THEN
    RAISE EXCEPTION '結單提醒間隔要在 1～30 分鐘之間';
  END IF;
  UPDATE line_note_accounts
     SET remind_every_min = p_n, updated_by = auth.uid()
   WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION '找不到帳號'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_account_set_remind_every_min(BIGINT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_account_set_remind_every_min(BIGINT, INT) TO authenticated;

-- 基底：20260925030000。條件不變，只改插入順序：先結單的先發（11:00／12:00 結單的排前面），
-- 同一個結單時間內各社群輪流（rn = 該社群第幾篇）。line_note_jobs.id 照這個順序發號，worker 照 id 撿。
CREATE OR REPLACE FUNCTION public._line_note_enqueue_due_reminds()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_n     INT;
  v_today DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
BEGIN
  WITH due AS (
    SELECT p.id AS post_id, p.tenant_id, p.community_id, c.account_id, g.customer_end_at,
           row_number() OVER (PARTITION BY p.community_id ORDER BY g.customer_end_at, p.id) AS rn
      FROM line_note_posts p
      JOIN group_buy_campaigns g ON g.id = p.campaign_id
      JOIN line_note_communities c ON c.id = p.community_id
     WHERE p.status = 'posted' AND p.remind_shared_at IS NULL AND p.line_post_id IS NOT NULL
       AND c.remind_enabled AND c.remind_time ~ '^\d{1,2}:\d{2}$'
       AND g.status = 'open'
       AND g.customer_end_at IS NOT NULL
       AND (g.customer_end_at AT TIME ZONE 'Asia/Taipei')::date = v_today
       AND g.customer_end_at > now()
       AND ((v_today + c.remind_time::time) AT TIME ZONE 'Asia/Taipei') <= now()
       AND ((v_today + c.remind_time::time) AT TIME ZONE 'Asia/Taipei') >  now() - INTERVAL '10 minutes'
       AND NOT EXISTS (SELECT 1 FROM line_note_jobs j
                        WHERE j.kind = 'remind' AND j.post_id = p.id AND j.status IN ('queued', 'running'))
  ), ins AS (
    INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id)
    SELECT tenant_id, 'remind', account_id, community_id, post_id FROM due
     ORDER BY customer_end_at, rn, community_id
    RETURNING id
  )
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_enqueue_due_reminds() FROM PUBLIC, anon, authenticated;

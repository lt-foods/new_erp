-- ============================================================================
-- 20260909100000_line_note_community_sync.sql
--
-- 社群清單跟著帳號走：帳號登入（或按「同步社群」）之後，那個 LINE 帳號加入的
-- 每一個群組／社群就自己出現在社群設定裡，不用一個一個手動新增 homeId。
--
-- 自動長出來的一律是**關的**（listen_enabled = FALSE、auto_post_on_open = FALSE）——
-- 備用帳號身上常常還有私人群組，自動開監聽等於未經同意就去爬別人的對話、
-- 開團還會自動發文進去。要哪幾個由店家自己開。
--
-- 已經存在的社群只更新名字／類型／synced_at，**設定一個字都不動** ——
-- 同步不能把店家調好的讀取時間、模板洗掉。
--
-- 刪除掉的不要再自己長回來：line_note_home_dismissals 記「這個 home 我不要」，
-- 同步的新增那半會跳過它。刻意做成**獨立的表**而不是在 line_note_communities
-- 上加 dismissed_at：那張表身上有 UNIQUE (tenant_id, home_id)，加軟刪除欄位就會
-- 變成「查詢母體 ≠ 索引母體」（見 CLAUDE.md 會員那條：查得到的人都說沒人用、
-- 存下去卻一定撞）。手動「新增社群」照樣建得起來，建起來之後同步只會走更新那半，
-- 所以 dismissal 留著也不會擋到人。
--
-- 新表 + 新欄位 + 一支新 RPC；rpc_line_note_community_delete 基底是
-- 20260908010000（唯一前版，已 grep 確認），只在刪除後多寫一筆 dismissal。
-- rollback：
--   還原 20260908010000 的 rpc_line_note_community_delete；
--   DROP FUNCTION public.rpc_line_note_community_sync(BIGINT, JSONB);
--   DROP TABLE line_note_home_dismissals;
--   ALTER TABLE line_note_communities DROP COLUMN synced_at;
-- ============================================================================

ALTER TABLE line_note_communities
  ADD COLUMN IF NOT EXISTS synced_at TIMESTAMPTZ;
COMMENT ON COLUMN line_note_communities.synced_at IS
  '最後一次在帳號的群組清單裡看到這個社群的時間。NULL = 手動新增的，沒同步過。';

CREATE TABLE IF NOT EXISTS line_note_home_dismissals (
  tenant_id    UUID NOT NULL,
  home_id      TEXT NOT NULL,
  dismissed_by UUID,
  dismissed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, home_id)
);
COMMENT ON TABLE line_note_home_dismissals IS
  '店家從社群設定刪掉的 home：同步時不要再自動長回來（手動新增不受影響）。';
ALTER TABLE line_note_home_dismissals ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 同步：worker 拿到帳號的群組清單後呼叫（service_role）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_community_sync(
  p_account_id BIGINT,
  p_homes      JSONB
) RETURNS TABLE (out_added INT, out_updated INT, out_skipped INT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant  UUID;
  v_h       JSONB;
  v_home    TEXT;
  v_kind    TEXT;
  v_added   INT := 0;
  v_updated INT := 0;
  v_skipped INT := 0;
BEGIN
  SELECT tenant_id INTO v_tenant FROM line_note_accounts WHERE id = p_account_id;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'account % not found', p_account_id; END IF;

  FOR v_h IN SELECT * FROM jsonb_array_elements(COALESCE(p_homes, '[]'::jsonb)) LOOP
    v_home := TRIM(COALESCE(v_h ->> 'homeId', ''));
    CONTINUE WHEN v_home = '';
    v_kind := CASE WHEN v_h ->> 'kind' IN ('group','square','square_chat')
                   THEN v_h ->> 'kind' ELSE 'square_chat' END;

    -- 已經有了：只更新名字／類型，設定一個字都不動
    UPDATE line_note_communities
       SET home_name = COALESCE(NULLIF(v_h ->> 'name', ''), home_name),
           home_kind = v_kind,
           synced_at = NOW()
     WHERE tenant_id = v_tenant AND home_id = v_home;
    IF FOUND THEN v_updated := v_updated + 1; CONTINUE; END IF;

    -- 店家刪掉過的不要再長回來
    IF EXISTS (SELECT 1 FROM line_note_home_dismissals
                WHERE tenant_id = v_tenant AND home_id = v_home) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- 新的一律是關的：備用帳號身上常有私人群組，不能自動去爬、也不能自動發文
    INSERT INTO line_note_communities
      (tenant_id, account_id, home_id, home_name, home_kind,
       listen_enabled, auto_post_on_open, read_times, read_days, synced_at)
    VALUES
      (v_tenant, p_account_id, v_home, NULLIF(v_h ->> 'name', ''), v_kind,
       FALSE, FALSE, ARRAY['12:00'], 3, NOW());
    v_added := v_added + 1;
  END LOOP;

  RETURN QUERY SELECT v_added, v_updated, v_skipped;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_community_sync(BIGINT, JSONB) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 刪除：順手記一筆「我不要這個」，同步才不會下一輪又把它長回來
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_community_delete(p_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_home   TEXT;
BEGIN
  DELETE FROM line_note_communities WHERE id = p_id AND tenant_id = v_tenant
  RETURNING home_id INTO v_home;
  IF v_home IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;

  INSERT INTO line_note_home_dismissals (tenant_id, home_id, dismissed_by)
  VALUES (v_tenant, v_home, auth.uid())
  ON CONFLICT (tenant_id, home_id) DO UPDATE
     SET dismissed_at = NOW(), dismissed_by = auth.uid();
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_delete(BIGINT) TO authenticated;

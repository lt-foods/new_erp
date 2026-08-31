-- ============================================================================
-- 店家自開團：**第四個**結單入口 —— rpc_upsert_campaign
-- ============================================================================
-- 災情（Alex 2026-08-31 回報：「我在松山開了一個 test，然後結單，但是沒看到收貨」）：
--   GRP-20260831-015（松山店自開團，owner_store_id=2）結單後 status 是 'closed'
--   而不是 'receiving'，那張訂單 GRP-20260831-015-0001 也還停在 'pending'
--   → 收貨頁的母體是 receiving/ready 的自開團，撈不到它；
--     店家畫面上不會報錯，只會什麼都沒有。
--
-- 為什麼漏掉：20260831000030 盤點結單入口時只找「原始碼裡出現字面 'closed'」
--   的函式，找到三支（rpc_close_campaign / 自動結單 cron / 批次結單）。
--   但 rpc_upsert_campaign 寫的是 `status = COALESCE(p_status, status)` ——
--   字面上沒有 'closed'，grep 不到，而開團編輯視窗（CampaignForm）的狀態
--   下拉就有「已收單」，選下去就是這一條路。
--   ⚠ 教訓：盤「誰會改這個欄位」要用「誰 UPDATE 這張表」當母體
--     （pg_proc.prosrc ~* 'UPDATE\s+group_buy_campaigns'），
--     不能用「誰寫得出那個值」—— 參數化的寫入一定漏掉。
--   本次已用該母體重新盤過，17 支寫 group_buy_campaigns 的函式裡，
--   會把團移出 'open' 的只有這四支，其餘（PR 相關的 →locked、finalize 的
--   →completed、quick control 只能 →open、改日期那幾支不動 status）都不影響。
--
-- 修法：rpc_upsert_campaign 遇到自開團的 open → closed，**委派給
--   rpc_close_campaign**（確認訂單 + 切 receiving），不要自己寫 status。
--   另外擋住「已經 receiving/ready 的自開團被重新存成 closed」——
--   編輯視窗的狀態下拉沒有 receiving 這個選項，再存一次就會把團退回去，
--   收貨頁又會少一團。
--
-- 基底版本：20260831000010_store_self_campaign_close_and_receive.sql
--   （16 參數版，逐字保留，只加上面那段分流）
-- Rollback：CREATE OR REPLACE 回 20260831000010 的 rpc_upsert_campaign。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_upsert_campaign(
  p_id               BIGINT,
  p_campaign_no      TEXT,
  p_name             TEXT,
  p_description      TEXT        DEFAULT NULL,
  p_cover_image_url  TEXT        DEFAULT NULL,
  p_status           TEXT        DEFAULT 'draft',
  p_close_type       TEXT        DEFAULT 'regular',
  p_start_at         TIMESTAMPTZ DEFAULT NULL,
  p_end_at           TIMESTAMPTZ DEFAULT NULL,
  p_pickup_deadline  DATE        DEFAULT NULL,
  p_pickup_days      INTEGER     DEFAULT NULL,
  p_total_cap_qty    NUMERIC     DEFAULT NULL,
  p_notes            TEXT        DEFAULT NULL,
  p_is_for_shop      BOOLEAN     DEFAULT TRUE,
  p_sales_channel    TEXT        DEFAULT NULL,
  p_owner_store_id   BIGINT      DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_id          BIGINT;
  v_prev_status TEXT;
  v_owner       BIGINT;
  v_write_status TEXT;
  v_do_close    BOOLEAN := FALSE;
BEGIN
  IF p_sales_channel IS NOT NULL AND p_sales_channel NOT IN ('main', 'piaopiao') THEN
    RAISE EXCEPTION 'invalid sales_channel: %', p_sales_channel;
  END IF;

  IF p_owner_store_id IS NOT NULL THEN
    PERFORM public._assert_own_store(p_owner_store_id);
    IF NOT EXISTS (
      SELECT 1 FROM stores WHERE id = p_owner_store_id AND tenant_id = v_tenant
    ) THEN
      RAISE EXCEPTION 'store % not in tenant', p_owner_store_id;
    END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO group_buy_campaigns (
      tenant_id, campaign_no, name, description, cover_image_url,
      status, close_type, start_at, end_at, pickup_deadline, pickup_days,
      total_cap_qty, notes, is_for_shop, sales_channel, owner_store_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, p_campaign_no, p_name, p_description, p_cover_image_url,
      COALESCE(p_status,'draft'), COALESCE(p_close_type,'regular'),
      p_start_at, p_end_at, p_pickup_deadline, p_pickup_days,
      p_total_cap_qty, p_notes, COALESCE(p_is_for_shop, TRUE),
      COALESCE(p_sales_channel, 'main'), p_owner_store_id,
      auth.uid(), auth.uid()
    ) RETURNING id INTO v_id;
  ELSE
    SELECT status, owner_store_id INTO v_prev_status, v_owner
      FROM group_buy_campaigns
     WHERE id = p_id AND tenant_id = v_tenant
     FOR UPDATE;
    IF v_prev_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;

    v_write_status := COALESCE(p_status, v_prev_status);

    -- 20260831：自開團的「結單」不是單純改一個欄位（要確認訂單 + 切 receiving）
    IF v_owner IS NOT NULL AND p_status = 'closed' THEN
      IF v_prev_status = 'open' THEN
        v_do_close     := TRUE;            -- 下面委派給 rpc_close_campaign
        v_write_status := v_prev_status;   -- 這一次 UPDATE 先不要動 status
      ELSIF v_prev_status IN ('receiving', 'ready') THEN
        -- 已經結過單、正在等收貨 / 已收齊：狀態下拉沒有這兩個選項，
        -- 存檔時不能把它退回 closed（退回去收貨頁就少一團）
        v_write_status := v_prev_status;
      END IF;
    END IF;

    -- owner_store_id 刻意不在 UPDATE 清單裡：團一旦開出去、客人已經下單，
    -- 換主辦店等於把別人的訂單搬走，沒有任何一段流程接得住。
    UPDATE group_buy_campaigns SET
      campaign_no = COALESCE(p_campaign_no, campaign_no),
      name = COALESCE(p_name, name),
      description = p_description,
      cover_image_url = p_cover_image_url,
      status = v_write_status,
      close_type = COALESCE(p_close_type, close_type),
      start_at = p_start_at,
      end_at = p_end_at,
      pickup_deadline = p_pickup_deadline,
      pickup_days = p_pickup_days,
      total_cap_qty = p_total_cap_qty,
      notes = p_notes,
      is_for_shop = COALESCE(p_is_for_shop, is_for_shop),
      sales_channel = COALESCE(p_sales_channel, sales_channel),
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;

    IF v_do_close THEN
      PERFORM public.rpc_close_campaign(v_id, auth.uid());
    END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign TO authenticated;

COMMENT ON FUNCTION public.rpc_upsert_campaign IS
  '建立／更新開團。p_owner_store_id 非 NULL = 店家自開團（只在建立時生效，'
  '更新不接受換主辦店）。自開團的 open→closed 委派給 rpc_close_campaign，'
  '且不允許把 receiving/ready 退回 closed。基底 20260831000010。';

-- ----------------------------------------------------------------------------
-- 補救：已經被上面那個洞卡在 'closed' 的自開團
--
-- 走真正的結單路徑（先還原成 open 再呼叫 rpc_close_campaign），不要在這裡
-- 自己複製一份「確認訂單 + 切 receiving」的邏輯 —— 那正是日後兩邊走鐘的來源。
-- 還原成 open 是安全的：trg_campaigns_lock_on_open 只在 draft→open 才動作。
-- 冪等：跑完就沒有 status='closed' 的自開團，重跑什麼都不會做。
-- ----------------------------------------------------------------------------
DO $$
DECLARE r RECORD; v_res JSONB;
BEGIN
  FOR r IN
    SELECT id, campaign_no, COALESCE(updated_by, created_by) AS actor
      FROM group_buy_campaigns
     WHERE owner_store_id IS NOT NULL
       AND status = 'closed'
  LOOP
    UPDATE group_buy_campaigns SET status = 'open' WHERE id = r.id;
    v_res := public.rpc_close_campaign(r.id, r.actor);
    RAISE NOTICE 'repaired store campaign % (%): %', r.id, r.campaign_no, v_res;
  END LOOP;
END $$;

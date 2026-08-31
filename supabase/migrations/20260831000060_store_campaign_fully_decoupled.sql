-- ============================================================================
-- 店家自開團：跟總倉完全脫鉤（Alex 2026-08-31：「不能跟總倉那邊有任何掛鉤」）
-- ============================================================================
-- 在這之前，「自開團不會進總倉流程」靠的是**狀態值**：結單後走 'receiving'，
-- 而所有請購彙整的母體都是 status='closed'，所以撈不到。這個保證是真的，
-- 但它是「間接」的 —— 只要有任何一條路把自開團寫成 'closed'（就是 #877 修的
-- 那個洞：編輯視窗的狀態下拉），總倉當天的 close_date 請購單就會把它吞進去，
-- 變成總倉替店家的團下單。#877 補了那條路，但這種保證的形狀本身就不對：
-- 它要求「未來每一個改 status 的人都記得」。
--
-- 這一支改成**結構性**的：不管狀態是什麼、不管誰呼叫，
-- 自開團就是進不了總倉的兩張連結表。
--
--   1. purchase_request_campaigns  ← 團 ↔ 請購單的唯一連結（6 支函式會寫）
--   2. picking_wave_items.campaign_id ← 團 ↔ 撿貨波次（7 支函式會寫）
--
-- 用 BEFORE INSERT trigger 擋在這兩個路口，而不是在那 13 支函式各加守衛：
--   * 13 支要一支一支改，而且每支都是幾 KB 的大函式，逐字重寫本身就有
--     蓋掉 prior fix 的風險（CLAUDE.md 記過好幾次）；
--   * 漏一支就等於沒擋，而且是靜默的；
--   * 之後新增的路徑不會自動被涵蓋 —— 這正是 #877 那個洞的形狀。
--   路口只有兩個，擋住就結束了。
--
-- 另外把「自開團的結單」抽成獨立的 _close_store_campaign()：
--   結單的四個入口（結單鈕 / 編輯視窗 / 批次結單 / pg_cron）以後都直接呼叫它，
--   **不再繞經 rpc_close_campaign**（那支是總倉的請購流程）。
--   rpc_close_campaign 自己遇到自開團也是委派給它然後直接 RETURN，
--   所以自開團的路徑上一行總倉的程式碼都不會執行。
--
-- 基底版本：
--   rpc_close_campaign               = 20260831000010（＝ 20260512000001 + 店家分支）
--   rpc_upsert_campaign              = 20260831000055
--   rpc_bulk_set_campaign_status     = 20260831000030
--   rpc_auto_close_expired_campaigns = 20260831000030
-- Rollback：
--   DROP TRIGGER trg_prc_no_store_campaign ON purchase_request_campaigns;
--   DROP TRIGGER trg_pwi_no_store_campaign ON picking_wave_items;
--   DROP FUNCTION public._reject_store_campaign_in_hq_flow();
--   四支函式 CREATE OR REPLACE 回上列基底版本；
--   DROP FUNCTION public._close_store_campaign(BIGINT, UUID);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 兩個路口的閘門
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reject_store_campaign_in_hq_flow()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_store TEXT;
  v_no    TEXT;
BEGIN
  SELECT st.name, gc.campaign_no
    INTO v_store, v_no
    FROM group_buy_campaigns gc
    JOIN stores st ON st.id = gc.owner_store_id
   WHERE gc.id = NEW.campaign_id;

  IF v_store IS NOT NULL THEN
    RAISE EXCEPTION
      '店家自開團（% ・%）不能進總倉流程：這團的貨由店家自己採購、自己收貨，不請購也不撿貨',
      COALESCE(v_no, NEW.campaign_id::TEXT), v_store;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._reject_store_campaign_in_hq_flow() IS
  '擋住店家自開團被掛進請購單 / 撿貨波次。掛在兩張連結表的 BEFORE INSERT，'
  '不依賴 campaign.status，也不需要每支請購 / 撿貨函式各自加守衛。';

DROP TRIGGER IF EXISTS trg_prc_no_store_campaign ON public.purchase_request_campaigns;
CREATE TRIGGER trg_prc_no_store_campaign
  BEFORE INSERT ON public.purchase_request_campaigns
  FOR EACH ROW
  WHEN (NEW.campaign_id IS NOT NULL)
  EXECUTE FUNCTION public._reject_store_campaign_in_hq_flow();

-- picking_wave_items.campaign_id 對補貨波次是 NULL，WHEN 讓那些列完全不進函式
DROP TRIGGER IF EXISTS trg_pwi_no_store_campaign ON public.picking_wave_items;
CREATE TRIGGER trg_pwi_no_store_campaign
  BEFORE INSERT ON public.picking_wave_items
  FOR EACH ROW
  WHEN (NEW.campaign_id IS NOT NULL)
  EXECUTE FUNCTION public._reject_store_campaign_in_hq_flow();

-- ----------------------------------------------------------------------------
-- 2. _close_store_campaign — 自開團的結單（獨立，不碰任何總倉的東西）
--
--    內容逐字取自 20260831000010 rpc_close_campaign 的店家分支。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._close_store_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID;
  v_status      TEXT;
  v_owner_store BIGINT;
  v_actor       UUID;
  v_confirmed   INTEGER := 0;
  r             RECORD;
BEGIN
  SELECT tenant_id, status, owner_store_id, COALESCE(p_operator, updated_by, created_by)
    INTO v_tenant, v_status, v_owner_store, v_actor
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_owner_store IS NULL THEN
    RAISE EXCEPTION 'campaign % 不是店家自開團', p_campaign_id;
  END IF;
  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'campaign % not in open status (current: %)', p_campaign_id, v_status;
  END IF;

  UPDATE group_buy_campaigns
     SET status = 'receiving',
         updated_by = COALESCE(p_operator, updated_by),
         updated_at = NOW()
   WHERE id = p_campaign_id;

  -- 訂單 pending → confirmed（口徑比照 _lock_orders_after_pr_aggregation，
  -- 差別只在原因寫的是結單而不是 PR）
  FOR r IN
    SELECT id FROM customer_orders
     WHERE tenant_id   = v_tenant
       AND campaign_id = p_campaign_id
       AND status      = 'pending'
     FOR UPDATE
  LOOP
    UPDATE customer_orders
       SET status       = 'confirmed',
           confirmed_at = NOW(),
           updated_by   = COALESCE(p_operator, updated_by),
           updated_at   = NOW()
     WHERE id = r.id;

    -- operator_id 是 NOT NULL，而自動結單（pg_cron）沒有登入者 ——
    -- 退回開團者；真的都沒有就不寫這一列，不要為了一列 audit 讓整個結單失敗
    -- （結不了單 = 團不會切到 receiving = 收貨頁不會出現它）。
    IF v_actor IS NOT NULL THEN
      INSERT INTO customer_order_audit_log
        (tenant_id, order_id, entity_type, entity_id, field,
         before_value, after_value, edit_reason, operator_id)
      VALUES
        (v_tenant, r.id, 'order', NULL, 'status',
         to_jsonb('pending'::text), to_jsonb('confirmed'::text),
         '店家自開團結單自動確認', v_actor);
    END IF;

    v_confirmed := v_confirmed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'closed', true,
    'pr_id', NULL,
    'action', 'store_receiving',
    'owner_store_id', v_owner_store,
    'orders_confirmed', v_confirmed,
    'reason', '店家自開團：不經總倉、不開單，請到「收貨」對這個團收貨'
  );
END;
$$;

COMMENT ON FUNCTION public._close_store_campaign(BIGINT, UUID) IS
  '店家自開團結單：status → receiving、該團 pending 訂單 → confirmed。'
  '完全不碰請購 / 採購 / 撿貨 / 調撥。結單的四個入口都呼叫這一支。';

REVOKE ALL ON FUNCTION public._close_store_campaign(BIGINT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._close_store_campaign(BIGINT, UUID) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. rpc_close_campaign — 店家分支改成委派後直接 RETURN
--    基底 20260831000010，總倉那一段（步驟 1~4）一字未動。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_close_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant             UUID;
  v_status             TEXT;
  v_close_date         DATE;
  v_owner_store        BIGINT;
  v_other_open_count   INTEGER;
  v_existing_pr_id     BIGINT;
  v_existing_pr_status TEXT;
  v_new_pr_id          BIGINT;
  v_new_pr_no          TEXT;
  v_append_result      JSONB;
BEGIN
  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei'), owner_store_id
    INTO v_tenant, v_status, v_close_date, v_owner_store
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'campaign % not in open status (current: %)', p_campaign_id, v_status;
  END IF;

  -- 店家自開團：整段交給 _close_store_campaign，下面一行總倉的程式碼都不跑
  IF v_owner_store IS NOT NULL THEN
    RETURN public._close_store_campaign(p_campaign_id, p_operator);
  END IF;

  -- 1. 切 status
  UPDATE group_buy_campaigns
     SET status = 'closed',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_campaign_id;

  -- 2. 找該 close_date 是否已有 close_date 型 PR（campaign-type 不影響此判斷）
  SELECT id, status INTO v_existing_pr_id, v_existing_pr_status
    FROM purchase_requests
   WHERE tenant_id = v_tenant
     AND source_type = 'close_date'
     AND source_close_date = v_close_date
     AND status <> 'cancelled'
   LIMIT 1;

  IF v_existing_pr_id IS NOT NULL THEN
    -- 2a. PR 在 draft → 自動 append 此 campaign 商品（既有行為）
    IF v_existing_pr_status = 'draft' THEN
      BEGIN
        v_append_result := public.rpc_append_campaign_to_pr(
          v_existing_pr_id, p_campaign_id, p_operator
        );
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', v_existing_pr_id,
          'action', 'appended',
          'append', v_append_result
        );
      EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', v_existing_pr_id,
          'action', 'append_failed',
          'reason', SQLERRM
        );
      END;
    ELSE
      -- 2b. PR 已鎖（submitted / partially_ordered / fully_ordered）
      --     → 自動為當前 campaign 建 campaign-type PR（新行為）
      BEGIN
        v_new_pr_id := public.rpc_create_pr_from_campaign(p_campaign_id, p_operator);
        SELECT pr_no INTO v_new_pr_no FROM purchase_requests WHERE id = v_new_pr_id;
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', v_new_pr_id,
          'pr_no', v_new_pr_no,
          'action', 'created_secondary',
          'reason', format('既有 close_date PR id=%s 已鎖（%s）；改為此 campaign 建獨立 PR',
                            v_existing_pr_id, v_existing_pr_status),
          'locked_pr_id', v_existing_pr_id,
          'locked_pr_status', v_existing_pr_status
        );
      EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', NULL,
          'action', 'create_failed',
          'reason', SQLERRM,
          'locked_pr_id', v_existing_pr_id,
          'locked_pr_status', v_existing_pr_status
        );
      END;
    END IF;
  END IF;

  -- 3. 還有其他 open campaign 在同 close_date → 先不建 PR
  --    （自開團不算在內：它從來不會進總倉的 close_date PR）
  SELECT COUNT(*) INTO v_other_open_count
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status = 'open'
     AND owner_store_id IS NULL
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = v_close_date
     AND id <> p_campaign_id;

  IF v_other_open_count > 0 OR v_close_date IS NULL THEN
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', NULL, 'action', 'deferred',
      'reason', 'other open campaigns exist on close_date'
    );
  END IF;

  -- 4. auto-create close_date PR（同日全結 + 從未建過 PR）
  BEGIN
    v_new_pr_id := public.rpc_create_pr_from_close_date(v_close_date, p_operator);
    SELECT pr_no INTO v_new_pr_no FROM purchase_requests WHERE id = v_new_pr_id;
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', v_new_pr_id, 'pr_no', v_new_pr_no, 'action', 'created'
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', NULL, 'action', 'create_failed', 'reason', SQLERRM
    );
  END;
END;
$$;

COMMENT ON FUNCTION public.rpc_close_campaign(BIGINT, UUID) IS
  '結單。總倉團＝既有的請購單自動建立 / append（基底 20260512000001，一字未動）。'
  '店家自開團＝整段委派給 _close_store_campaign 後直接 RETURN，不跑任何總倉程式碼。';

-- ----------------------------------------------------------------------------
-- 4. rpc_upsert_campaign — 編輯視窗切「已收單」改成直接呼叫 _close_store_campaign
--    基底 20260831000055，只把 rpc_close_campaign 換成 _close_store_campaign。
-- ----------------------------------------------------------------------------
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
  v_tenant       UUID := public._current_tenant_id();
  v_id           BIGINT;
  v_prev_status  TEXT;
  v_owner        BIGINT;
  v_write_status TEXT;
  v_do_close     BOOLEAN := FALSE;
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

    -- 自開團的「結單」不是單純改一個欄位（要確認訂單 + 切 receiving）
    IF v_owner IS NOT NULL AND p_status = 'closed' THEN
      IF v_prev_status = 'open' THEN
        v_do_close     := TRUE;            -- 下面交給 _close_store_campaign
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
      PERFORM public._close_store_campaign(v_id, auth.uid());
    END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign TO authenticated;

COMMENT ON FUNCTION public.rpc_upsert_campaign IS
  '建立／更新開團。p_owner_store_id 非 NULL = 店家自開團（只在建立時生效，'
  '更新不接受換主辦店）。自開團的 open→closed 交給 _close_store_campaign，'
  '且不允許把 receiving/ready 退回 closed。基底 20260831000055。';

-- ----------------------------------------------------------------------------
-- 5. 另外兩個結單入口也改成直接呼叫 _close_store_campaign
--    基底 20260831000030，只把 rpc_close_campaign 換掉。
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
  '總倉團維持原本的單句 UPDATE。';

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

    -- 自開團的結單不是單純改一個欄位（要確認訂單 + 切 receiving）
    IF v_cur = 'open' AND p_status = 'closed' AND v_owner IS NOT NULL THEN
      BEGIN
        PERFORM public._close_store_campaign(v_id, auth.uid());
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
  '批次改開團狀態。店家自開團的 open→closed 交給 _close_store_campaign'
  '（確認訂單並切到 receiving），其餘維持基底 20260514000012 的行為。';

GRANT EXECUTE ON FUNCTION public.rpc_bulk_set_campaign_status(BIGINT[], TEXT) TO authenticated;

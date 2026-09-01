-- ============================================================================
-- 店家自開團：結單／編輯補上「只能動自己店的團」守衛
-- ============================================================================
-- 需求（Alex 2026-09-01）：「店家要可以關自己的團然後儲存。」
--
-- DB 這一側本來就通（實測：松山店長走 rpc_upsert_campaign 把自己的團切
-- 'closed'，團確實變 'receiving'、訂單變 'confirmed'）。真正擋住店長的是
-- 前端 —— CampaignForm 的「儲存」鈕包在 isAdmin 後面，店長看到的是
-- 「僅管理員可儲存開團」，狀態下拉選了「已收單」也存不下去。前端同批放行。
--
-- 但放行前必須先補這個洞：**兩條結單路徑都沒有店家守衛**。
-- 線上實測（交易內 ROLLBACK）：平鎮店店長對松山店的團呼叫
-- rpc_upsert_campaign(p_status => 'closed') → **成功**，團被關掉。
--
-- 為什麼漏掉：rpc_upsert_campaign 的 _assert_own_store 只在
-- `p_owner_store_id IS NOT NULL` 時才呼叫，而那個參數只有「建立自開團」
-- 才會帶（CampaignForm 編輯既有團時根本不送）。既有團走的是
-- `SELECT ... INTO v_owner` 那條路，一路上沒有人問過「這是你的店嗎」。
-- rpc_close_campaign 則是從頭到尾沒有守衛。
-- 之前沒炸只是因為店長在畫面上按不到任何入口 —— 一開放就是跨店可關。
--
-- 兩處補法：
--   1. _close_store_campaign（**所有**結單入口的共同下游：rpc_close_campaign、
--      rpc_upsert_campaign、rpc_bulk_set_campaign_status、pg_cron 自動結單）
--      → 守在這裡一次擋掉四條路，形狀跟 20260831000060 的兩個路口 trigger 一致。
--      pg_cron 沒有 JWT → _is_branch_scoped_user() 為 false → _assert_own_store
--      直接 RETURN，自動結單不受影響。
--   2. rpc_upsert_campaign 讀到既有團的 v_owner 之後
--      → 蓋掉「改團名／改日期／改上架」這些不經過結單邏輯的編輯。
--
-- HQ / admin / legacy（'' 角色）不受影響：_assert_own_store 對非分店帳號
-- 直接 RETURN。分店帳號跨店則回 `wrong_store`。
--
-- 基底版本：兩支都是 20260831000060_store_campaign_fully_decoupled.sql
--   （用 pg_get_functiondef 逐字取出線上定義，各只插入一行 PERFORM）
-- Rollback：兩支各 CREATE OR REPLACE 回 20260831000060。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. _close_store_campaign — 四個結單入口的共同下游
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._close_store_campaign(p_campaign_id bigint, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- 20260901：分店帳號只能結自己店的團。守在這裡一次蓋掉四個結單入口
  -- （rpc_close_campaign / rpc_upsert_campaign / 批次結單 / pg_cron 自動結單）。
  -- pg_cron 沒有 JWT → _is_branch_scoped_user() false → 這行直接 RETURN。
  PERFORM public._assert_own_store(v_owner_store);

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
$function$;

COMMENT ON FUNCTION public._close_store_campaign(BIGINT, UUID) IS
  '店家自開團的結單：切 receiving + 訂單 pending→confirmed，不進總倉流程。'
  '四個結單入口的共同下游，店家守衛（_assert_own_store）就掛在這裡。';

-- ----------------------------------------------------------------------------
-- 2. rpc_upsert_campaign — 編輯既有自開團也要是自己店的
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_campaign(
  p_id bigint,
  p_campaign_no text,
  p_name text,
  p_description text DEFAULT NULL::text,
  p_cover_image_url text DEFAULT NULL::text,
  p_status text DEFAULT 'draft'::text,
  p_close_type text DEFAULT 'regular'::text,
  p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_pickup_deadline date DEFAULT NULL::date,
  p_pickup_days integer DEFAULT NULL::integer,
  p_total_cap_qty numeric DEFAULT NULL::numeric,
  p_notes text DEFAULT NULL::text,
  p_is_for_shop boolean DEFAULT true,
  p_sales_channel text DEFAULT NULL::text,
  p_owner_store_id bigint DEFAULT NULL::bigint
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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

    -- 20260901：編輯既有的自開團 = 只能編自己店的。
    -- 上面那道 _assert_own_store 只看 p_owner_store_id，而編輯視窗（CampaignForm）
    -- 根本不送那個參數 —— 沒有這一行，任何分店帳號都改得動別家店的團
    -- （含把它切成 'closed' 直接結單，線上實測過真的過得去）。
    IF v_owner IS NOT NULL THEN
      PERFORM public._assert_own_store(v_owner);
    END IF;

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
$function$;

COMMENT ON FUNCTION public.rpc_upsert_campaign IS
  '新增／編輯開團。店家自開團的 open→closed 交給 _close_store_campaign；'
  '分店帳號只能編自己店的自開團（_assert_own_store），總倉團行為不變。';

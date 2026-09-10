-- ============================================================================
-- 20260910050000_campaign_customer_end_at.sql
--
-- 開團多一個時間：客人收單。順序是 開團 → 客人收單 → 店家收單（老闆 2026-09-10 交代）。
--   客人收單 (customer_end_at)：商城對客人關閉、LINE 貼文寫的結單時間。
--   店家收單 (end_at)：最後收單時間，小幫手還能補單；到了才自動結團（cron 照舊看 end_at）。
-- NULL = 跟店家收單同時，舊資料一律 NULL、行為不變。
--
-- 動到的東西：
--   1. group_buy_campaigns.customer_end_at TIMESTAMPTZ
--   2. rpc_upsert_campaign 加 p_customer_end_at（放最後、有預設值；照 20260831000010 的做法
--      先把所有 overload 砍掉再建，不然 PostgREST 兩個都吃就變 ambiguous）
--      + 守衛：客人收單不能晚於店家收單。
--      UPDATE 是無條件覆寫（不是 COALESCE）：其他呼叫端（快速開團、循環批次）都是建團或
--      同一個流程裡的 draft→open，這一欄本來就是 NULL；只有編輯視窗會改它，留空就要能清掉。
--   3. rpc_place_member_order_guarded：客人下單的閘門改看 LEAST(customer_end_at, end_at)
--      （LEAST 會略過 NULL，所以沒設就是原本的 end_at）
--   4. 兩支記事本 payload RPC 帶出 customer_end_at（貼文的 {{deadline}} 用它）
--   liff-api 的商城清單／團詳細／分享預覽也改看 LEAST(customer_end_at, end_at)（同一批部署）。
--
-- 基底：rpc_upsert_campaign @ 20260901050000（唯一前版，已 grep 確認）、
--       rpc_place_member_order_guarded @ 20260814000010（唯一前版）、
--       rpc_line_note_post_payload / rpc_line_note_preview_payload @ 20260910040000。
-- rollback：把上述基底重套（upsert 一樣要先砍 overload），
--           ALTER TABLE group_buy_campaigns DROP COLUMN customer_end_at;
-- ============================================================================

ALTER TABLE public.group_buy_campaigns
  ADD COLUMN IF NOT EXISTS customer_end_at TIMESTAMPTZ;
COMMENT ON COLUMN public.group_buy_campaigns.customer_end_at IS
  '客人收單：商城對客人關閉、LINE 貼文結單時間。NULL = 跟店家收單 (end_at) 同時。';

-- ----------------------------------------------------------------------------
-- 2. rpc_upsert_campaign — 加 p_customer_end_at
-- ----------------------------------------------------------------------------
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT 'public.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'rpc_upsert_campaign'
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.sig;
  END LOOP;
END $$;

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
  p_owner_store_id bigint DEFAULT NULL::bigint,
  p_customer_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone
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

  -- 客人收單（商城關閉、貼文結單）一定在店家收單之前；NULL = 跟店家收單同時
  IF p_customer_end_at IS NOT NULL AND p_end_at IS NOT NULL AND p_customer_end_at > p_end_at THEN
    RAISE EXCEPTION '客人收單時間不能晚於店家收單時間';
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
      status, close_type, start_at, end_at, customer_end_at, pickup_deadline, pickup_days,
      total_cap_qty, notes, is_for_shop, sales_channel, owner_store_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, p_campaign_no, p_name, p_description, p_cover_image_url,
      COALESCE(p_status,'draft'), COALESCE(p_close_type,'regular'),
      p_start_at, p_end_at, p_customer_end_at, p_pickup_deadline, p_pickup_days,
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
      customer_end_at = p_customer_end_at,
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

-- ----------------------------------------------------------------------------
-- 3. rpc_place_member_order_guarded — 客人下單閘門看客人收單
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_place_member_order_guarded(
  p_tenant UUID,
  p_campaign_id BIGINT,
  p_channel_id BIGINT,
  p_member_id BIGINT,
  p_pickup_store_id BIGINT,
  p_items JSONB,
  p_notes TEXT DEFAULT NULL,
  p_source TEXT DEFAULT 'liff'
) RETURNS TABLE (
  order_id BIGINT,
  order_no TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign group_buy_campaigns%ROWTYPE;
  v_member members%ROWTYPE;
  v_source TEXT := CASE WHEN p_source = 'pwa' THEN 'pwa' ELSE 'liff' END;
  v_requested_count INT := 0;
  v_requested_total NUMERIC := 0;
  v_total_sold NUMERIC := 0;
  v_order_id BIGINT;
  v_order_no TEXT;
  v_seq INT;
  v_req RECORD;
  v_ci RECORD;
  v_item_sold NUMERIC;
  v_existing_qty NUMERIC;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant required';
  END IF;
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'campaign_id required';
  END IF;
  IF p_channel_id IS NULL THEN
    RAISE EXCEPTION 'channel_id required';
  END IF;
  IF p_member_id IS NULL THEN
    RAISE EXCEPTION 'member_id required';
  END IF;
  IF p_pickup_store_id IS NULL THEN
    RAISE EXCEPTION 'pickup_store_id required';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items required';
  END IF;

  SELECT * INTO v_campaign
    FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = p_tenant
     AND gbc.id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found';
  END IF;
  IF v_campaign.status <> 'open' THEN
    RAISE EXCEPTION 'campaign not open';
  END IF;
  IF COALESCE(v_campaign.is_for_shop, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'campaign not available';
  END IF;
  -- 客人下單看的是「客人收單」（LEAST 會略過 NULL：沒設就退回店家收單）
  IF LEAST(v_campaign.customer_end_at, v_campaign.end_at) IS NOT NULL
     AND LEAST(v_campaign.customer_end_at, v_campaign.end_at) <= NOW() THEN
    RAISE EXCEPTION 'campaign already ended';
  END IF;

  SELECT * INTO v_member
    FROM members m
   WHERE m.tenant_id = p_tenant
     AND m.id = p_member_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member not found';
  END IF;
  IF COALESCE(v_member.no_new_order, false) THEN
    RAISE EXCEPTION 'member blocked';
  END IF;

  PERFORM 1 FROM stores s WHERE s.tenant_id = p_tenant AND s.id = p_pickup_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_store_id required';
  END IF;

  PERFORM 1 FROM line_channels lc WHERE lc.tenant_id = p_tenant AND lc.id = p_channel_id AND lc.is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no active channel for tenant';
  END IF;

  FOR v_req IN
    SELECT
      (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
      (x ->> 'qty')::NUMERIC AS qty
    FROM jsonb_array_elements(p_items) AS x
  LOOP
    IF v_req.campaign_item_id IS NULL OR v_req.qty IS NULL OR v_req.qty <= 0 THEN
      RAISE EXCEPTION 'qty must be > 0';
    END IF;
  END LOOP;

  SELECT COUNT(*), COALESCE(SUM(qty), 0)
    INTO v_requested_count, v_requested_total
    FROM (
      SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
             SUM((x ->> 'qty')::NUMERIC) AS qty
        FROM jsonb_array_elements(p_items) AS x
       GROUP BY (x ->> 'campaign_item_id')::BIGINT
    ) req;

  IF v_requested_count = 0 OR v_requested_total <= 0 THEN
    RAISE EXCEPTION 'items required';
  END IF;

  SELECT COALESCE(SUM(coi.qty), 0)
    INTO v_total_sold
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE co.tenant_id = p_tenant
     AND co.campaign_id = p_campaign_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND coi.status NOT IN ('cancelled', 'expired')
     AND COALESCE(co.order_kind, 'normal') = 'normal';

  IF COALESCE(v_campaign.total_cap_qty, 0) > 0
     AND v_total_sold + v_requested_total > v_campaign.total_cap_qty THEN
    RAISE EXCEPTION 'sold out';
  END IF;

  FOR v_req IN
    SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
           SUM((x ->> 'qty')::NUMERIC) AS qty
      FROM jsonb_array_elements(p_items) AS x
     GROUP BY (x ->> 'campaign_item_id')::BIGINT
  LOOP
    SELECT ci.id, ci.sku_id, ci.unit_price, ci.cap_qty
      INTO v_ci
      FROM campaign_items ci
     WHERE ci.tenant_id = p_tenant
       AND ci.campaign_id = p_campaign_id
       AND ci.id = v_req.campaign_item_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'campaign item not found';
    END IF;

    SELECT COALESCE(SUM(coi.qty), 0)
      INTO v_item_sold
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE co.tenant_id = p_tenant
       AND co.campaign_id = p_campaign_id
       AND coi.campaign_item_id = v_req.campaign_item_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND coi.status NOT IN ('cancelled', 'expired')
       AND COALESCE(co.order_kind, 'normal') = 'normal';

    IF COALESCE(v_ci.cap_qty, 0) > 0 AND v_item_sold + v_req.qty > v_ci.cap_qty THEN
      RAISE EXCEPTION 'item sold out';
    END IF;
  END LOOP;

  SELECT co.id, co.order_no
    INTO v_order_id, v_order_no
    FROM customer_orders co
   WHERE co.tenant_id = p_tenant
     AND co.campaign_id = p_campaign_id
     AND co.channel_id = p_channel_id
     AND co.member_id = p_member_id
     AND COALESCE(co.order_kind, 'normal') = 'normal'
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
   FOR UPDATE;

  IF v_order_id IS NULL THEN
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders co
     WHERE co.tenant_id = p_tenant
       AND co.campaign_id = p_campaign_id;
    v_order_no := v_campaign.campaign_no || '-' || lpad(v_seq::TEXT, 4, '0');

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, order_kind, notes
    ) VALUES (
      p_tenant, v_order_no, p_campaign_id, p_channel_id, p_member_id,
      v_member.name, p_pickup_store_id, 'pending', 'normal', NULLIF(p_notes, '')
    )
    RETURNING id INTO v_order_id;
  ELSE
    UPDATE customer_orders co
       SET nickname_snapshot = COALESCE(v_member.name, co.nickname_snapshot),
           pickup_store_id = p_pickup_store_id,
           notes = NULLIF(p_notes, ''),
           updated_at = NOW()
     WHERE co.id = v_order_id;
  END IF;

  FOR v_req IN
    SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
           SUM((x ->> 'qty')::NUMERIC) AS qty
      FROM jsonb_array_elements(p_items) AS x
     GROUP BY (x ->> 'campaign_item_id')::BIGINT
  LOOP
    SELECT ci.sku_id, ci.unit_price
      INTO v_ci
      FROM campaign_items ci
     WHERE ci.tenant_id = p_tenant
       AND ci.campaign_id = p_campaign_id
       AND ci.id = v_req.campaign_item_id;

    SELECT coi.qty INTO v_existing_qty
      FROM customer_order_items coi
     WHERE coi.order_id = v_order_id
       AND coi.campaign_item_id = v_req.campaign_item_id
     FOR UPDATE;

    IF v_existing_qty IS NULL THEN
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status, source
      ) VALUES (
        p_tenant, v_order_id, v_req.campaign_item_id, v_ci.sku_id, v_req.qty, v_ci.unit_price, 'pending', v_source
      );
    ELSE
      UPDATE customer_order_items coi
         SET qty = v_existing_qty + v_req.qty,
             source = v_source,
             updated_at = NOW()
       WHERE coi.order_id = v_order_id
         AND coi.campaign_item_id = v_req.campaign_item_id;
    END IF;
  END LOOP;

  order_id := v_order_id;
  order_no := v_order_no;
  RETURN NEXT;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_place_member_order_guarded(UUID, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, TEXT, TEXT) TO service_role;

-- ----------------------------------------------------------------------------
-- 4. 記事本 payload 帶 customer_end_at
-- ----------------------------------------------------------------------------
-- worker 發文用：把團的內容整包回來（模板由 worker 套）
CREATE OR REPLACE FUNCTION public.rpc_line_note_post_payload(p_post_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'post_id',       p.id,
    'home_id',       c.home_id,
    'home_kind',     c.home_kind,
    'account_id',    c.account_id,
    'post_template', c.post_template,
    'campaign', jsonb_build_object(
       'id', g.id, 'campaign_no', g.campaign_no, 'name', g.name,
       'description', g.description, 'status', g.status,
       'cover_image_url', g.cover_image_url,
       'start_at', g.start_at, 'end_at', g.end_at, 'customer_end_at', g.customer_end_at,
       'pickup_deadline', g.pickup_deadline),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'code', ic.code, 'campaign_item_id', ic.campaign_item_id,
                'name', ic.item_name, 'unit_price', ic.unit_price, 'retail_price', ic.retail_price,
                'cap_qty', ic.cap_qty, 'images', ic.images)
                ORDER BY ic.code)
               FROM public._line_note_item_codes(g.id) ic), '[]'::jsonb)
  )
  FROM line_note_posts p
  JOIN line_note_communities c ON c.id = p.community_id
  JOIN group_buy_campaigns g ON g.id = p.campaign_id
  WHERE p.id = p_post_id;
$$;

CREATE OR REPLACE FUNCTION public.rpc_line_note_preview_payload(
  p_community_id BIGINT,
  p_campaign_id  BIGINT
) RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'home_id',       c.home_id,
    'home_kind',     c.home_kind,
    'account_id',    c.account_id,
    'post_template', c.post_template,
    'campaign', jsonb_build_object(
       'id', g.id, 'campaign_no', g.campaign_no, 'name', g.name,
       'description', g.description, 'status', g.status,
       'cover_image_url', g.cover_image_url,
       'start_at', g.start_at, 'end_at', g.end_at, 'customer_end_at', g.customer_end_at,
       'pickup_deadline', g.pickup_deadline),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'code', ic.code, 'campaign_item_id', ic.campaign_item_id,
                'name', ic.item_name, 'unit_price', ic.unit_price, 'retail_price', ic.retail_price,
                'cap_qty', ic.cap_qty, 'images', ic.images)
                ORDER BY ic.code)
               FROM public._line_note_item_codes(g.id) ic), '[]'::jsonb)
  )
  FROM line_note_communities c
  JOIN group_buy_campaigns g ON g.id = p_campaign_id AND g.tenant_id = c.tenant_id
  WHERE c.id = p_community_id;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_preview_payload(BIGINT, BIGINT) TO authenticated;

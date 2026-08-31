-- ============================================================================
-- 店家自開團 (2/5)：開團 → 結單 → 收貨 → 配單
-- ============================================================================
-- 全流程**不產生任何單據**（不請購、不採購、不撿貨、不出倉、不開進貨單）：
--
--   開團  rpc_store_create_campaign（店長自己開，店家守衛只能開自己店的）
--   結單  rpc_close_campaign 自開團分支 → status='receiving' + 訂單 pending→confirmed
--   收貨  rpc_receive_store_campaign（收貨頁直接對「團」收）→ 只寫 stock_movements
--   配單  收貨完自動呼叫 _advance_arrived_confirmed_orders → 訂單 confirmed→ready
--
-- 結單後的 campaign status 刻意用 **'receiving'**（狀態 CHECK 早就有這個值，
-- 20260623000000），不是 'closed'：
--   * 語意剛好就是「等收貨」，收貨頁就是對這個團收；
--   * 全部的請購彙整（rpc_create_pr_from_close_date / 補單 / append）母體都是
--     `status = 'closed'` —— 用 'receiving' 就**結構性地**不可能被總倉的請購單
--     吞進去，不必去改那幾支大函式（改它們才是真的容易漏掉 prior fix）。
--     唯一吃 'receiving' 的是 rpc_create_pr_from_campaigns（手動多選建單），
--     所以那支另外加守衛，見最後一段。
--   全數收齊後 → 'ready'（同樣是既有的狀態值）。
--
-- 訂單狀態走法（與總倉團的差別）：
--   總倉團：pending →(建 PR) confirmed →(撿貨波次) shipping →(收貨) ready
--   自開團：pending →(結單)   confirmed → ────────────────→(收貨) ready
--   沒有 shipping 這一段 —— shipping 的語意是「總倉已派貨」，自開團沒有人派貨。
--
-- 收貨為什麼只寫 stock_movements 就夠：
--   貨要進 on_hand 本來就得有這一筆（跟「新增庫存」是同一種東西），
--   而它同時就是「這團到了幾件」的帳 —— 取貨閘門的供給側直接讀它
--   （見 20260831000020）。所以不需要另外一張單來記同一件事。
--   記法：movement_type='purchase_receipt'、source_doc_type='campaign'、
--        source_doc_id=團 id。
--
-- 基底版本（逐字保留 prior fix，只加本功能所需）：
--   rpc_close_campaign            = 20260512000001_close_campaign_auto_new_pr.sql
--   rpc_upsert_campaign           = 20260822001000_upsert_campaign_sales_channel.sql
--   rpc_create_pr_from_campaigns  = 20260812010000_pr_from_campaigns_locked_delta.sql
-- Rollback：上列三支 CREATE OR REPLACE 回基底版本；
--   DROP FUNCTION public.rpc_receive_store_campaign(BIGINT, JSONB, UUID, TEXT),
--                 public.rpc_store_campaign_inbound(BIGINT),
--                 public.rpc_store_create_campaign(BIGINT,TEXT,JSONB,TIMESTAMPTZ,DATE,TEXT,TEXT,TEXT,NUMERIC,TEXT),
--                 public._store_campaign_demand(BIGINT),
--                 public._assert_own_store(BIGINT);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 店家守衛：這個 store_id 是不是呼叫者自己的店
--    判準與 _assert_stocktake_store_scope（20260826010000）一致，差別只在
--    那支收 location_id、這支收 store_id。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._assert_own_store(p_store_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_my_stores  JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_store_name TEXT;
BEGIN
  IF NOT public._is_branch_scoped_user() THEN
    RETURN;   -- HQ / legacy 帳號不鎖
  END IF;

  SELECT s.name INTO v_store_name
    FROM stores s
   WHERE s.id = p_store_id
     AND s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid;

  IF v_store_name IS NULL OR NOT (v_my_stores ? v_store_name) THEN
    RAISE EXCEPTION 'wrong_store: 這不是你的店，分店帳號只能操作自己店的資料';
  END IF;
END;
$$;

COMMENT ON FUNCTION public._assert_own_store(BIGINT) IS
  '分店角色只能操作自己店（store id 版）。判準同 _assert_stocktake_store_scope。';

REVOKE ALL ON FUNCTION public._assert_own_store(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._assert_own_store(BIGINT) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 1. _store_campaign_demand — 這個自開團每個 SKU 要幾件、已經收了幾件
--
--    需求側的 active 集合 ('pending','reserved','ready') 與 rpc_record_pickup
--    的 v_active_remaining、_close_orders_all_items_settled 同一套（CLAUDE.md）。
--    供給側＝掛在這個團身上的入庫異動（就是收貨寫的那一筆）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._store_campaign_demand(p_campaign_id BIGINT)
RETURNS TABLE (sku_id BIGINT, demand NUMERIC, received NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH camp AS (
    SELECT gc.id, gc.tenant_id, gc.owner_store_id, st.location_id
      FROM group_buy_campaigns gc
      JOIN stores st ON st.id = gc.owner_store_id
     WHERE gc.id = p_campaign_id
  ),
  need AS (
    SELECT coi.sku_id, SUM(coi.qty) AS demand
      FROM camp c
      JOIN customer_orders co ON co.campaign_id = c.id
                             AND co.tenant_id = c.tenant_id
                             AND co.pickup_store_id = c.owner_store_id
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.status IN ('pending','reserved','ready')
       AND coi.qty > 0
     GROUP BY coi.sku_id
  ),
  got AS (
    SELECT sm.sku_id, SUM(sm.quantity) AS received
      FROM camp c
      JOIN stock_movements sm ON sm.tenant_id       = c.tenant_id
                             AND sm.location_id     = c.location_id
                             AND sm.source_doc_type = 'campaign'
                             AND sm.source_doc_id   = c.id
     GROUP BY sm.sku_id
  )
  SELECT COALESCE(n.sku_id, g.sku_id),
         COALESCE(n.demand, 0),
         COALESCE(g.received, 0)
    FROM need n
    FULL JOIN got g ON g.sku_id = n.sku_id;
$$;

COMMENT ON FUNCTION public._store_campaign_demand(BIGINT) IS
  '店家自開團每個 SKU 的需求量（active 訂單品項）與已收量（掛在該團的入庫異動）。'
  '收貨頁與取貨閘門供給側共用同一份口徑。';

REVOKE ALL ON FUNCTION public._store_campaign_demand(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._store_campaign_demand(BIGINT) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. rpc_upsert_campaign — 加 p_owner_store_id
--    既有 15 參數的呼叫端（CampaignForm / 批次建立 / 手機團控）沿用預設值，
--    行為完全不變（NULL → 總倉團）。
--
--    ⚠ owner_store_id 只在**建立**時決定，更新時不接受變更：團一旦開出去、
--      客人已經下單，換主辦店等於把別人的訂單搬走，沒有任何一段流程接得住。
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
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
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
    -- owner_store_id 刻意不在 UPDATE 清單裡：見函式檔頭
    UPDATE group_buy_campaigns SET
      campaign_no = COALESCE(p_campaign_no, campaign_no),
      name = COALESCE(p_name, name),
      description = p_description,
      cover_image_url = p_cover_image_url,
      status = COALESCE(p_status, status),
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
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign TO authenticated;

COMMENT ON FUNCTION public.rpc_upsert_campaign IS
  '建立／更新開團。p_owner_store_id 非 NULL = 店家自開團（只在建立時生效，'
  '更新不接受換主辦店）。基底 20260822001000。';

-- ----------------------------------------------------------------------------
-- 3. rpc_store_create_campaign — 店長開自己店的團（一次帶品項）
--
--    刻意獨立一支而不是把 rpc_upsert_campaign 開給分店角色：
--    後者能建**總倉團**（owner_store_id = NULL），開給分店等於讓任何店長
--    開出全站可見、要總倉買單的團。這支強制寫上主辦店，且過 _assert_own_store。
--
--    p_items: [{"sku_id":1,"unit_price":100,"cap_qty":null,"sort_order":0}, ...]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_create_campaign(
  p_store_id        BIGINT,
  p_name            TEXT,
  p_items           JSONB,
  p_end_at          TIMESTAMPTZ DEFAULT NULL,
  p_pickup_deadline DATE        DEFAULT NULL,
  p_description     TEXT        DEFAULT NULL,
  p_cover_image_url TEXT        DEFAULT NULL,
  p_close_type      TEXT        DEFAULT 'regular',
  p_total_cap_qty   NUMERIC     DEFAULT NULL,
  p_status          TEXT        DEFAULT 'open'
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_id       BIGINT;
  v_no       TEXT;
  v_it       JSONB;
  v_sku      BIGINT;
  v_price    NUMERIC;
  v_count    INT := 0;
BEGIN
  -- 角色：店長 / 店員 + 所有管理層級。'' 是沒有顯式 role 的 legacy admin，
  -- 漏掉它會把舊帳號全擋在外面（CLAUDE.md）。
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'insufficient_role: % 不能開團', v_role;
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'p_store_id required';
  END IF;
  PERFORM public._assert_own_store(p_store_id);

  IF NOT EXISTS (SELECT 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant) THEN
    RAISE EXCEPTION 'store % not in tenant', p_store_id;
  END IF;

  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'p_name required';
  END IF;

  IF p_status NOT IN ('draft','open') THEN
    RAISE EXCEPTION 'p_status must be draft or open, got %', p_status;
  END IF;

  -- food_train 是總倉的主題專區，不開放給店家自己掛
  IF p_close_type NOT IN ('regular','fast','limited') THEN
    RAISE EXCEPTION 'invalid close_type for store campaign: %', p_close_type;
  END IF;

  IF p_close_type = 'fast' AND p_end_at IS NULL THEN
    RAISE EXCEPTION 'fast campaign requires end_at';
  END IF;

  v_no := public.rpc_next_campaign_no();

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, description, cover_image_url,
    status, close_type, start_at, end_at, pickup_deadline,
    total_cap_qty, is_for_shop, sales_channel, owner_store_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, btrim(p_name), p_description, p_cover_image_url,
    p_status, p_close_type, NOW(), p_end_at, p_pickup_deadline,
    p_total_cap_qty, TRUE, 'main', p_store_id,
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_id;

  FOR v_it IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
  LOOP
    v_sku := NULLIF(v_it ->> 'sku_id', '')::BIGINT;
    IF v_sku IS NULL THEN
      CONTINUE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM skus WHERE id = v_sku AND tenant_id = v_tenant) THEN
      RAISE EXCEPTION 'sku % not in tenant', v_sku;
    END IF;

    -- 價格：呼叫端沒帶就退回現行零售價。一件都不能是 0 —— 那就是
    -- 20260703000010 擋的「0 元加單金額」，客人下單金額整個歸零。
    v_price := COALESCE(NULLIF(v_it ->> 'unit_price', '')::NUMERIC, 0);
    IF v_price <= 0 THEN
      SELECT p.price INTO v_price
        FROM prices p
       WHERE p.sku_id = v_sku
         AND p.tenant_id = v_tenant
         AND p.scope = 'retail'
         AND p.effective_to IS NULL
       ORDER BY p.effective_from DESC NULLS LAST
       LIMIT 1;
    END IF;
    IF COALESCE(v_price, 0) <= 0 THEN
      RAISE EXCEPTION '無法開團：SKU % 沒有售價，請填入團購價或先設定零售價',
        (SELECT sku_code FROM skus WHERE id = v_sku);
    END IF;

    INSERT INTO campaign_items (
      tenant_id, campaign_id, sku_id, unit_price, cap_qty, sort_order,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_id, v_sku, v_price,
      NULLIF(v_it ->> 'cap_qty', '')::NUMERIC,
      COALESCE((v_it ->> 'sort_order')::INT, v_count),
      auth.uid(), auth.uid()
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION '至少要選一個商品';
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_store_create_campaign IS
  '店家自開團：一次建立 campaign + campaign_items，強制寫上 owner_store_id 並過 '
  '_assert_own_store（分店只能開自己店的）。不產生任何請購／採購單據。';

REVOKE ALL ON FUNCTION public.rpc_store_create_campaign FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_store_create_campaign TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. rpc_close_campaign — 自開團分支（不開任何單據）
--    基底 20260512000001，總倉團那一段（步驟 1~4）一字未動。
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
  v_confirmed          INTEGER := 0;
  v_actor              UUID;
  r                    RECORD;
BEGIN
  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei'), owner_store_id,
         COALESCE(p_operator, updated_by, created_by)
    INTO v_tenant, v_status, v_close_date, v_owner_store, v_actor
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'campaign % not in open status (current: %)', p_campaign_id, v_status;
  END IF;

  -- ==========================================================================
  -- 0. 店家自開團：不請購、不採購、不撿貨、不出倉、**不開任何單據**。
  --    結單 = 凍結需求（訂單推 confirmed）+ 把團切到 'receiving'，
  --    店家在收貨頁對這個團收貨。
  -- ==========================================================================
  IF v_owner_store IS NOT NULL THEN
    UPDATE group_buy_campaigns
       SET status = 'receiving',
           updated_by = p_operator,
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
             updated_by   = p_operator,
             updated_at   = NOW()
       WHERE id = r.id;

      -- operator_id 是 NOT NULL，而自動結單（pg_cron）沒有登入者 ——
      -- 退回開團者；真的都沒有就不寫這一列，不要為了一列 audit 讓整個結單失敗
      -- （結不了單 = 團不會出現在收貨頁 = 店家什麼都看不到）。
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
  '店家自開團（owner_store_id 非 NULL）＝ status 走 receiving、訂單推 confirmed，'
  '不建 PR、不開任何單據，改由收貨頁對團收貨（rpc_receive_store_campaign）。';

-- ----------------------------------------------------------------------------
-- 5. rpc_store_campaign_inbound — 收貨頁的「店家自開團待收貨」母體
--
--    p_store_id NULL = 該帳號可見的所有店（HQ 看全部、分店看自己）。
--
--    母體是「還有沒收到的量」，不是「status='receiving'」——
--    收齊之後團會被切成 'ready'，但**結單後還可以加單**（訂單頁 / 加單頁），
--    加完需求就又大於已收量了。只認 receiving 的話那批加單的貨永遠不會回到
--    收貨頁，店家收了貨也沒地方登記，客人就一直卡在 confirmed。
--    所以 ready 的團只要又欠貨就會自己回到清單上。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_store_campaign_inbound(
  p_store_id BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH camps AS (
    SELECT gc.id, gc.campaign_no, gc.name, gc.end_at, gc.updated_at,
           gc.owner_store_id, st.name AS store_name
      FROM group_buy_campaigns gc
      JOIN stores st ON st.id = gc.owner_store_id
     WHERE gc.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
       AND gc.owner_store_id IS NOT NULL
       AND gc.status IN ('receiving', 'ready')
       AND (p_store_id IS NULL OR gc.owner_store_id = p_store_id)
       -- 分店帳號只看自己店的
       AND (NOT public._is_branch_scoped_user()
            OR gc.owner_store_id = ANY (public._jwt_store_ids()))
  ),
  lines AS (
    SELECT c.id AS campaign_id,
           jsonb_agg(
             jsonb_build_object(
               'sku_id',    d.sku_id,
               'sku_code',  s.sku_code,
               'label',     COALESCE(s.product_name, '') ||
                            CASE WHEN COALESCE(s.variant_name, '') <> ''
                                 THEN ' / ' || s.variant_name ELSE '' END,
               'unit',      s.base_unit,
               'demand',    d.demand,
               'received',  d.received,
               'remaining', GREATEST(d.demand - d.received, 0)
             ) ORDER BY s.sku_code
           ) AS items,
           SUM(d.demand)   AS total_demand,
           SUM(d.received) AS total_received
      FROM camps c
      CROSS JOIN LATERAL public._store_campaign_demand(c.id) d
      JOIN skus s ON s.id = d.sku_id
     GROUP BY c.id
  )
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'campaign_id',    c.id,
             'campaign_no',    c.campaign_no,
             'name',           c.name,
             'store_id',       c.owner_store_id,
             'store_name',     c.store_name,
             'end_at',         c.end_at,
             'closed_at',      c.updated_at,
             'total_demand',   COALESCE(l.total_demand, 0),
             'total_received', COALESCE(l.total_received, 0),
             'items',          COALESCE(l.items, '[]'::jsonb)
           ) ORDER BY c.updated_at DESC
         ), '[]'::jsonb)
    FROM camps c
    LEFT JOIN lines l ON l.campaign_id = c.id
   -- 只列還欠貨的：收齊的團（含結單後沒再加單的）不要一直佔著收貨頁
   WHERE COALESCE(l.total_demand, 0) - COALESCE(l.total_received, 0) > 0;
$$;

COMMENT ON FUNCTION public.rpc_store_campaign_inbound(BIGINT) IS
  '收貨頁「店家自開團待收貨」清單：還欠貨的自開團（receiving 或 ready 但需求 > 已收，'
  '結單後加單會讓收齊的團自己回到清單）+ 每個 SKU 的需求／已收／未收。'
  '分店帳號只看得到自己店的團。';

REVOKE ALL ON FUNCTION public.rpc_store_campaign_inbound(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_store_campaign_inbound(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. rpc_receive_store_campaign — 對「團」收貨（不開單）
--
--    p_lines: [{"sku_id":1,"qty":5,"unit_cost":80}, ...]；NULL = 依未收量全收。
--    unit_cost 省略時取該 SKU 目前成本（_current_cost_price），
--    避免 avg_cost 缺值時報表算 0 元（同 20260814030000 的教訓）。
--
--    收完立刻配單：_advance_arrived_confirmed_orders 只吃**這一團**的訂單
--    （p_order_ids），不讓自開團的貨外溢去推同店別團的 confirmed 單。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_store_campaign(
  p_campaign_id BIGINT,
  p_lines       JSONB DEFAULT NULL,
  p_operator    UUID  DEFAULT NULL,
  p_notes       TEXT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID;
  v_store     BIGINT;
  v_loc       BIGINT;
  v_status    TEXT;
  v_actor     UUID;
  v_line      JSONB;
  v_sku       BIGINT;
  v_qty       NUMERIC;
  v_cost      NUMERIC;
  v_skus      BIGINT[] := '{}';
  v_orders    BIGINT[];
  v_received  NUMERIC := 0;
  v_advanced  INT := 0;
  v_left      NUMERIC;
  r           RECORD;
BEGIN
  SELECT gc.tenant_id, gc.owner_store_id, gc.status,
         COALESCE(p_operator, auth.uid(), gc.updated_by, gc.created_by)
    INTO v_tenant, v_store, v_status, v_actor
    FROM group_buy_campaigns gc
   WHERE gc.id = p_campaign_id
   FOR UPDATE;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_store IS NULL THEN
    RAISE EXCEPTION 'campaign % 不是店家自開團，請走原本的收貨流程', p_campaign_id;
  END IF;
  IF v_status NOT IN ('receiving','ready') THEN
    RAISE EXCEPTION 'campaign % 還沒結單或已結案（目前 %），不能收貨', p_campaign_id, v_status;
  END IF;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'operator required';   -- stock_movements.operator_id 是 NOT NULL
  END IF;

  PERFORM public._assert_own_store(v_store);

  SELECT location_id INTO v_loc FROM stores WHERE id = v_store;
  IF v_loc IS NULL THEN
    RAISE EXCEPTION 'store % 沒有綁倉別，無法入庫', v_store;
  END IF;

  -- p_lines 省略 → 依「還沒收的量」全收
  IF p_lines IS NULL THEN
    SELECT jsonb_agg(jsonb_build_object('sku_id', d.sku_id,
                                        'qty', d.demand - d.received))
      INTO p_lines
      FROM public._store_campaign_demand(p_campaign_id) d
     WHERE d.demand - d.received > 0;
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RETURN jsonb_build_object('received_qty', 0, 'orders_advanced', 0,
                              'reason', '沒有待收的數量');
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku := NULLIF(v_line ->> 'sku_id', '')::BIGINT;
    v_qty := COALESCE(NULLIF(v_line ->> 'qty', '')::NUMERIC, 0);
    IF v_sku IS NULL OR v_qty <= 0 THEN
      CONTINUE;
    END IF;

    -- 只收這個團真的有在賣的 SKU，避免打錯 sku_id 把庫存加到別的商品上
    IF NOT EXISTS (
      SELECT 1 FROM campaign_items ci
       WHERE ci.campaign_id = p_campaign_id AND ci.sku_id = v_sku
    ) THEN
      RAISE EXCEPTION 'sku % 不在這個團的品項裡', v_sku;
    END IF;

    v_cost := COALESCE(NULLIF(v_line ->> 'unit_cost', '')::NUMERIC,
                       public._current_cost_price(v_tenant, v_sku), 0);

    PERFORM public.rpc_inbound(
      v_tenant, v_loc, v_sku, v_qty, v_cost,
      'purchase_receipt', 'campaign', p_campaign_id, v_actor);

    v_received := v_received + v_qty;
    IF NOT (v_sku = ANY (v_skus)) THEN
      v_skus := array_append(v_skus, v_sku);
    END IF;
  END LOOP;

  IF p_notes IS NOT NULL AND btrim(p_notes) <> '' THEN
    UPDATE group_buy_campaigns
       SET notes = CASE WHEN COALESCE(notes,'') = '' THEN p_notes
                        ELSE notes || E'\n' || p_notes END
     WHERE id = p_campaign_id;
  END IF;

  -- 配單：只推這一團的 confirmed 單
  IF array_length(v_skus, 1) IS NOT NULL THEN
    SELECT ARRAY_AGG(co.id) INTO v_orders
      FROM customer_orders co
     WHERE co.tenant_id       = v_tenant
       AND co.campaign_id     = p_campaign_id
       AND co.pickup_store_id = v_store
       AND co.status          = 'confirmed';

    IF v_orders IS NOT NULL THEN
      v_advanced := public._advance_arrived_confirmed_orders(
        v_store, v_skus, v_actor, NOW(), v_orders);
    END IF;
  END IF;

  -- 全部收齊 → 團切 'ready'，從收貨頁的待收清單消失
  SELECT COALESCE(SUM(GREATEST(d.demand - d.received, 0)), 0)
    INTO v_left
    FROM public._store_campaign_demand(p_campaign_id) d;

  IF v_left <= 0 THEN
    UPDATE group_buy_campaigns
       SET status = 'ready', updated_by = v_actor, updated_at = NOW()
     WHERE id = p_campaign_id AND status = 'receiving';
  END IF;

  RETURN jsonb_build_object(
    'received_qty',    v_received,
    'orders_advanced', v_advanced,
    'remaining_qty',   v_left,
    'campaign_status', (SELECT status FROM group_buy_campaigns WHERE id = p_campaign_id)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_receive_store_campaign(BIGINT, JSONB, UUID, TEXT) IS
  '店家自開團收貨：只寫 stock_movements（purchase_receipt / source_doc_type=campaign），'
  '不產生任何單據，因此也不進月結算（月結母體全是 transfers）。'
  '收完立刻把該團 confirmed 的訂單推 ready（沿用 _advance_arrived_confirmed_orders 的雙守衛）。'
  '全數收齊後把團切成 ready。p_lines 省略 = 全收未收量。';

REVOKE ALL ON FUNCTION public.rpc_receive_store_campaign(BIGINT, JSONB, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_receive_store_campaign(BIGINT, JSONB, UUID, TEXT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 7. rpc_create_pr_from_campaigns — 守衛：自開團不得併進總倉請購單
--    基底 20260812010000，只在既有的 tenant/status 守衛後多一段。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_campaigns(
  p_campaign_ids BIGINT[],
  p_operator     UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_pr_id          BIGINT;
  v_pr_no          TEXT;
  v_dest_loc       BIGINT;
  v_delta_count    INTEGER;
  v_min_close_date DATE;
BEGIN
  IF p_campaign_ids IS NULL OR array_length(p_campaign_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_campaign_ids is empty';
  END IF;

  -- 守衛：所有 campaigns 都必須屬同 tenant 且已結單（v2：補上 'locked'）
  IF EXISTS (
    SELECT 1 FROM group_buy_campaigns
     WHERE id = ANY(p_campaign_ids)
       AND (tenant_id <> v_tenant
            OR status NOT IN ('closed','locked','ordered','receiving','ready','completed'))
  ) THEN
    RAISE EXCEPTION 'some campaigns not in tenant or not closed yet';
  END IF;

  -- 20260831：店家自開團的貨由店家自己採購、不經總倉，併進來等於讓總倉替
  -- 店家的團下單（而且店端是直接在收貨頁對團收貨，沒有請購這一步）。
  IF EXISTS (
    SELECT 1 FROM group_buy_campaigns
     WHERE id = ANY(p_campaign_ids)
       AND owner_store_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '店家自開團不能併進總倉請購單（該團的貨由店家自行採購）';
  END IF;
  -- 取最小 close_date 作 source_close_date（向下相容用、實際資料看 join 表）
  SELECT MIN(DATE(end_at AT TIME ZONE 'Asia/Taipei')) INTO v_min_close_date
    FROM group_buy_campaigns
   WHERE id = ANY(p_campaign_ids);

  -- dest location
  SELECT id INTO v_dest_loc FROM locations WHERE tenant_id = v_tenant ORDER BY id LIMIT 1;
  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined';
  END IF;

  -- v2：先算差額（目前需求 − 該團結單日所有未取消 close_date PR 已請購量），
  -- 空的話直接 RAISE，不浪費 pr_no、不留殘 header（比照 20260714000060 補單）。
  CREATE TEMP TABLE _camp_pr_delta ON COMMIT DROP AS
  WITH sel AS (
    SELECT id, DATE(end_at AT TIME ZONE 'Asia/Taipei') AS close_date
      FROM group_buy_campaigns
     WHERE id = ANY(p_campaign_ids)
  ),
  demand AS (
    SELECT
      coi.sku_id,
      s.close_date,
      MIN(co.campaign_id) AS first_campaign_id,
      SUM(coi.qty)        AS qty
      FROM sel s
      JOIN customer_orders co        ON co.campaign_id = s.id
      JOIN customer_order_items coi  ON coi.order_id = co.id
     WHERE co.tenant_id = v_tenant
       AND co.status  NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id, s.close_date
  ),
  already AS (
    SELECT pri.sku_id, pr.source_close_date AS close_date, SUM(pri.qty_requested) AS qty
      FROM purchase_requests pr
      JOIN purchase_request_items pri ON pri.pr_id = pr.id
     WHERE pr.tenant_id = v_tenant
       AND pr.source_type = 'close_date'
       AND pr.source_close_date IN (SELECT DISTINCT close_date FROM sel)
       AND pr.status <> 'cancelled'
     GROUP BY 1, 2
  )
  -- 同 SKU 跨結單日合併成一列（差額各自沖銷完再相加）
  SELECT
    d.sku_id,
    MIN(d.first_campaign_id) AS first_campaign_id,
    SUM(GREATEST(d.qty - COALESCE(a.qty, 0), 0)) AS delta_qty
    FROM demand d
    LEFT JOIN already a
           ON a.sku_id = d.sku_id AND a.close_date = d.close_date
   GROUP BY d.sku_id
  HAVING SUM(GREATEST(d.qty - COALESCE(a.qty, 0), 0)) > 0;

  SELECT COUNT(*) INTO v_delta_count FROM _camp_pr_delta;

  IF v_delta_count = 0 THEN
    RAISE EXCEPTION '所選團購的需求已全數納入既有請購單（結單日 close_date PR），沒有可補的請購量';
  END IF;

  -- PR header（source_type 沿用 close_date、close_date 取最小值 — v1 相容）
  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date,
    source_location_id, status, total_amount, notes,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'close_date', v_min_close_date,
    v_dest_loc, 'draft', 0,
    '針對團購建單（僅帶尚未請購的差額）',
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  -- 寫入 join 表：全部所選團（含差額 0 者；trigger 只會補有品項的那幾團）
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_pr_id, unnest(p_campaign_ids), v_tenant
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  -- 差額 → PR items（含售價 snapshot，沿用 v1）
  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested,
    suggested_supplier_id, unit_cost,
    retail_price, franchise_price,
    source_campaign_id,
    created_by, updated_by
  )
  SELECT
    v_pr_id, dq.sku_id, dq.delta_qty,
    ss.supplier_id, COALESCE(ss.default_unit_cost, 0),
    pr_retail.price, pr_franchise.price,
    dq.first_campaign_id, p_operator, p_operator
  FROM _camp_pr_delta dq
  LEFT JOIN LATERAL (
    SELECT supplier_id, default_unit_cost
      FROM supplier_skus
     WHERE tenant_id = v_tenant AND sku_id = dq.sku_id AND is_preferred = TRUE
     LIMIT 1
  ) ss ON TRUE
  LEFT JOIN LATERAL (
    SELECT price FROM prices WHERE sku_id = dq.sku_id AND scope = 'retail'
     ORDER BY effective_from DESC NULLS LAST LIMIT 1
  ) pr_retail ON TRUE
  LEFT JOIN LATERAL (
    SELECT price FROM prices WHERE sku_id = dq.sku_id AND scope = 'franchise'
     ORDER BY effective_from DESC NULLS LAST LIMIT 1
  ) pr_franchise ON TRUE;

  -- total snapshot
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  RETURN v_pr_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_pr_from_campaigns(BIGINT[], UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_pr_from_campaigns IS
  '從多選 campaigns 建 PR（v2, 20260812010000）：接受 closed/locked/ordered/receiving/ready/completed；'
  '品項只帶「目前需求 − 該團結單日未取消 close_date PR 已請購量」的差額（對齊結單日補單算法），'
  '差額全 0 → RAISE、不留空單。不鎖團、不 auto-confirm（重複建單不重複算量）。';

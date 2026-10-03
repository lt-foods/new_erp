-- ============================================================================
-- ⚠️ 會寫入正式庫：還原 20261001020000（請購還是草稿時可以重開＋關團只補差額）
-- ----------------------------------------------------------------------------
-- 什麼時候用
--   貼完 supabase/migrations/20261001020000_reopen_draft_pr_and_delta_append.sql 之後，
--   postcheck_readonly.sql 有任何 ❌，或實際關團／重開／請購數量看起來不對，就貼這一份。
--
-- 做了什麼（只有這些）
--   把兩支函式換回 20261001020000 之前的版本，內容**逐字照抄**原檔，一個字都沒改：
--     ① rpc_quick_update_campaign_control
--        ← supabase/migrations/20260814000010_fix_guarded_order_ambiguous_refs.sql:14-183
--          （函式本體＋原本的 REVOKE／GRANT；SECURITY DEFINER、SET search_path = public 照原樣）
--        ＋ 說明文字（COMMENT）← 20260814000000_quick_campaign_reopen_after_pr.sql:159-160
--          （0010 沒有重設說明文字，所以 20261001020000 之前線上掛的是 0000 那句；
--            20261001020000 把它換成中文，這裡換回去）
--     ② rpc_append_campaign_to_pr
--        ← supabase/migrations/20260625000000_pr_create_lock_campaign_and_orders.sql:240-382
--          （函式本體＋COMMENT；SECURITY DEFINER、沒有 SET search_path 照原樣）
--   兩支的執行權限（EXECUTE）20261001020000 本來就沒改（CREATE OR REPLACE 會保留原權限），
--   這裡照 ① 原檔再下一次 REVOKE／GRANT，② 原檔本來就沒有 GRANT，不另外加。
--   不動任何資料表、不刪任何一筆資料。
--
-- 還原之後會失去什麼（回到 10/1 以前的舊行為）
--   * 手機團控：已鎖定的團又不能重開；已關團但連到任何請購單（就算還是草稿）也不能重開。
--     錯誤訊息回到英文（例：「already has purchase request linkage; cannot reopen」）。
--   * 關團併進當天草稿：又變成「加整團量」，不是差額。
--     ⚠️ 所以還原之後，**已經重開過、又要再關團的團會重複叫貨**（整團量再加一次）。
--     還原後如果有團是「收單中」而且已經連著草稿請購單，關團後要到請購單頁按
--     「同步最新開團數量」把多出來的量修回去，或先跟工程師確認再關。
--   * 已經寫進 purchase_request_item_campaigns（來源團明細）的列**不會被刪**：
--     - 那些是正確的歸屬，#982 的三個補單入口、#1049 的同步、#982 的防重守衛都會繼續讀它，
--       讀到的數字是對的。
--     - 但舊版併入函式**不會再寫明細**，只加品項總數。之後如果舊版把整團量加到一列
--       「已經有明細」的品項上，#982 的防重守衛會因為「品項總數 ≠ 明細加總」擋下來 →
--       關團回 append_failed（團停在已關團，沒有進請購單）。這是 10/1 以前就存在的舊行為。
--
-- 執行方式
--   貼進 Supabase SQL Editor（autocommit，沒有交易保護）。
--   * 第 0 段前置檢查放最前面：不像正式庫、或兩支都已經是舊版 → 直接停，一行都不會改。
--   * 只要還有一支是新版就放行；後面兩段都是 CREATE OR REPLACE，**整份可重貼**
--     （例：貼到一半斷線，再貼一次就好）。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. 前置檢查
--   (a) 這是正式庫：客人訂單 ≥ 2000 筆或請購單 ≥ 200 張（跟驗證檔的擋法相反）。
--       ℹ️ 故意寫寬：緊急還原時不能被誤擋；在測試庫誤跑頂多是把測試庫換回舊版。
--   (b) 兩支函式至少一支還是新版（用新版才有的字串判斷，見下方）。
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_orders     BIGINT;
  v_prs        BIGINT;
  v_quick_new  BOOLEAN;
  v_append_new BOOLEAN;
BEGIN
  SELECT COUNT(*) INTO v_orders FROM public.customer_orders;
  SELECT COUNT(*) INTO v_prs FROM public.purchase_requests;

  IF v_orders < 2000 AND v_prs < 200 THEN
    RAISE EXCEPTION '⛔ 這個資料庫不像正式庫（客人訂單 % 筆、請購單 % 張），本還原檔只給正式庫用。已停止，什麼都沒改。',
      v_orders, v_prs;
  END IF;

  -- 新版特徵字串（20261001020000 才有，舊版沒有）
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'rpc_quick_update_campaign_control'
       AND strpos(p.prosrc, '已送出，不能重開') > 0
  ) INTO v_quick_new;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'rpc_append_campaign_to_pr'
       AND strpos(p.prosrc, '_pr_campaign_sku_remaining_rows') > 0
  ) INTO v_append_new;

  IF NOT v_quick_new AND NOT v_append_new THEN
    RAISE EXCEPTION '兩支函式都已經是舊版（找不到新版特徵字串），不用還原。已停止，什麼都沒改。';
  END IF;

  RAISE NOTICE '前置檢查通過：正式庫（訂單 % 筆、請購單 % 張）；目前新版：手機團控=%、併入請購=%。開始還原。',
    v_orders, v_prs, v_quick_new, v_append_new;
END
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. rpc_quick_update_campaign_control
--    以下逐字照抄 20260814000010_fix_guarded_order_ambiguous_refs.sql:14-183
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_quick_update_campaign_control(
  p_campaign_id BIGINT,
  p_status TEXT DEFAULT NULL,
  p_end_at TIMESTAMPTZ DEFAULT NULL,
  p_total_cap_qty_delta NUMERIC DEFAULT NULL
) RETURNS TABLE (
  id BIGINT,
  status TEXT,
  end_at TIMESTAMPTZ,
  total_cap_qty NUMERIC,
  sold_qty NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user UUID := auth.uid();
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_campaign group_buy_campaigns%ROWTYPE;
  v_sold_qty NUMERIC := 0;
  v_next_status TEXT;
  v_next_end_at TIMESTAMPTZ;
  v_next_total_cap_qty NUMERIC;
BEGIN
  IF v_role NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  SELECT * INTO v_campaign
    FROM group_buy_campaigns gbc
   WHERE gbc.id = p_campaign_id
     AND gbc.tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id;
  END IF;

  IF v_campaign.status NOT IN ('draft', 'open', 'closed') THEN
    RAISE EXCEPTION 'campaign % is %, cannot quick-control', p_campaign_id, v_campaign.status;
  END IF;

  IF NOT (
       v_campaign.close_type IN ('food_train', 'fast', 'limited')
    OR COALESCE(v_campaign.total_cap_qty, 0) > 0
    OR EXISTS (
      SELECT 1
        FROM campaign_items ci
       WHERE ci.tenant_id = v_tenant
         AND ci.campaign_id = p_campaign_id
         AND COALESCE(ci.cap_qty, 0) > 0
    )
  ) THEN
    RAISE EXCEPTION 'campaign % is not a quick-control campaign', p_campaign_id;
  END IF;

  SELECT COALESCE(SUM(coi.qty), 0)
    INTO v_sold_qty
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE co.tenant_id = v_tenant
     AND co.campaign_id = p_campaign_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND coi.status NOT IN ('cancelled', 'expired')
     AND COALESCE(co.order_kind, 'normal') = 'normal';

  v_next_status := COALESCE(p_status, v_campaign.status);
  v_next_end_at := COALESCE(p_end_at, v_campaign.end_at);
  v_next_total_cap_qty := v_campaign.total_cap_qty;

  IF p_status IS NOT NULL THEN
    IF p_status <> 'open' THEN
      RAISE EXCEPTION 'invalid quick target status: %', p_status;
    END IF;

    IF p_status = 'open' THEN
      IF v_campaign.status NOT IN ('draft', 'closed', 'open') THEN
        RAISE EXCEPTION 'campaign % is %, cannot open', p_campaign_id, v_campaign.status;
      END IF;

      PERFORM 1 FROM campaign_items ci WHERE ci.campaign_id = p_campaign_id LIMIT 1;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'campaign % has no items', p_campaign_id;
      END IF;

      IF v_campaign.status = 'closed' AND EXISTS (
        SELECT 1
          FROM purchase_request_campaigns prc
          JOIN purchase_requests pr ON pr.id = prc.pr_id
         WHERE prc.tenant_id = v_tenant
           AND prc.campaign_id = p_campaign_id
           AND pr.status <> 'cancelled'
      ) THEN
        RAISE EXCEPTION 'campaign % already has purchase request linkage; cannot reopen', p_campaign_id;
      END IF;

      IF v_next_end_at IS NULL OR v_next_end_at <= NOW() THEN
        RAISE EXCEPTION 'future end_at is required when opening/reopening';
      END IF;
    END IF;
  END IF;

  IF p_end_at IS NOT NULL THEN
    IF p_end_at <= NOW() THEN
      RAISE EXCEPTION 'end_at must be in the future';
    END IF;
    IF v_campaign.status = 'closed' AND v_next_status <> 'open' THEN
      RAISE EXCEPTION 'closed campaigns must be reopened, not only extended';
    END IF;
  END IF;

  IF p_total_cap_qty_delta IS NOT NULL THEN
    IF p_total_cap_qty_delta <= 0 THEN
      RAISE EXCEPTION 'cap delta must be > 0';
    END IF;
    v_next_total_cap_qty := COALESCE(v_campaign.total_cap_qty, v_sold_qty) + p_total_cap_qty_delta;
  END IF;

  UPDATE group_buy_campaigns gbc
     SET status = v_next_status,
         end_at = v_next_end_at,
         total_cap_qty = v_next_total_cap_qty,
         updated_by = v_user,
         updated_at = NOW()
   WHERE gbc.id = p_campaign_id
     AND gbc.tenant_id = v_tenant;

  IF p_status IS NOT NULL AND v_next_status IS DISTINCT FROM v_campaign.status THEN
    INSERT INTO campaign_audit_log (
      tenant_id, campaign_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_tenant, p_campaign_id, 'campaign', p_campaign_id, 'status',
      to_jsonb(v_campaign.status), to_jsonb(v_next_status),
      'quick_control', v_user
    );
  END IF;

  IF p_end_at IS NOT NULL AND v_next_end_at IS DISTINCT FROM v_campaign.end_at THEN
    INSERT INTO campaign_audit_log (
      tenant_id, campaign_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_tenant, p_campaign_id, 'campaign', p_campaign_id, 'end_at',
      to_jsonb(v_campaign.end_at), to_jsonb(v_next_end_at),
      'quick_control', v_user
    );
  END IF;

  IF p_total_cap_qty_delta IS NOT NULL AND v_next_total_cap_qty IS DISTINCT FROM v_campaign.total_cap_qty THEN
    INSERT INTO campaign_audit_log (
      tenant_id, campaign_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_tenant, p_campaign_id, 'campaign', p_campaign_id, 'total_cap_qty',
      to_jsonb(v_campaign.total_cap_qty), to_jsonb(v_next_total_cap_qty),
      'quick_control', v_user
    );
  END IF;

  RETURN QUERY
  SELECT p_campaign_id, v_next_status, v_next_end_at, v_next_total_cap_qty, v_sold_qty;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) TO authenticated;

-- 說明文字：以下逐字照抄 20260814000000_quick_campaign_reopen_after_pr.sql:159-160
COMMENT ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) IS
  'Mobile quick control for food_train/fast/limited campaigns: open/reopen, future end_at, positive total cap delta. Closing must use rpc_close_campaign.';


-- ----------------------------------------------------------------------------
-- 2. rpc_append_campaign_to_pr
--    以下逐字照抄 20260625000000_pr_create_lock_campaign_and_orders.sql:240-382
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_append_campaign_to_pr(p_pr_id bigint, p_campaign_id bigint, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant      UUID;
  v_pr_status   TEXT;
  v_pr_close_date DATE;
  v_camp_status TEXT;
  v_camp_close_date DATE;
  v_camp_tenant UUID;
  v_inserted    INTEGER := 0;
  v_updated     INTEGER := 0;
  v_demand RECORD;
BEGIN
  SELECT tenant_id, status, source_close_date
    INTO v_tenant, v_pr_status, v_pr_close_date
    FROM purchase_requests
   WHERE id = p_pr_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PR % not found', p_pr_id;
  END IF;

  IF v_pr_status <> 'draft' THEN
    RAISE EXCEPTION 'PR % is not in draft status (current: %); cannot append',
      p_pr_id, v_pr_status;
  END IF;

  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei')
    INTO v_camp_tenant, v_camp_status, v_camp_close_date
    FROM group_buy_campaigns
   WHERE id = p_campaign_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_camp_tenant <> v_tenant THEN
    RAISE EXCEPTION 'tenant mismatch';
  END IF;

  IF v_camp_status <> 'closed' THEN
    RAISE EXCEPTION 'campaign % not in closed status (current: %)',
      p_campaign_id, v_camp_status;
  END IF;

  IF v_pr_close_date IS NOT NULL AND v_camp_close_date <> v_pr_close_date THEN
    RAISE EXCEPTION 'close_date mismatch: PR=%, campaign=%',
      v_pr_close_date, v_camp_close_date;
  END IF;

  FOR v_demand IN
    SELECT
      coi.sku_id,
      SUM(coi.qty) AS qty_total
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.campaign_id = p_campaign_id
       AND co.tenant_id = v_tenant
       AND co.status NOT IN ('cancelled','expired')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id
  LOOP
    UPDATE purchase_request_items
       SET qty_requested = qty_requested + v_demand.qty_total,
           updated_by = p_operator
     WHERE pr_id = p_pr_id AND sku_id = v_demand.sku_id;

    IF FOUND THEN
      v_updated := v_updated + 1;
    ELSE
      INSERT INTO purchase_request_items (
        pr_id, sku_id, qty_requested,
        suggested_supplier_id, unit_cost,
        retail_price, franchise_price,
        source_campaign_id,
        created_by, updated_by
      )
      SELECT
        p_pr_id, v_demand.sku_id, v_demand.qty_total,
        ss.supplier_id, COALESCE(ss.default_unit_cost, 0),
        pr_retail.price, pr_franchise.price,
        p_campaign_id, p_operator, p_operator
      FROM (SELECT 1) dummy
      LEFT JOIN LATERAL (
        SELECT supplier_id, default_unit_cost
          FROM supplier_skus
         WHERE tenant_id = v_tenant
           AND sku_id = v_demand.sku_id
           AND is_preferred = TRUE
         LIMIT 1
      ) ss ON TRUE
      LEFT JOIN LATERAL (
        SELECT price FROM prices
         WHERE sku_id = v_demand.sku_id AND scope = 'retail'
         ORDER BY effective_from DESC NULLS LAST
         LIMIT 1
      ) pr_retail ON TRUE
      LEFT JOIN LATERAL (
        SELECT price FROM prices
         WHERE sku_id = v_demand.sku_id AND scope = 'franchise'
         ORDER BY effective_from DESC NULLS LAST
         LIMIT 1
      ) pr_franchise ON TRUE;

      v_inserted := v_inserted + 1;
    END IF;
  END LOOP;

  -- sync purchase_request_campaigns join 表
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (p_pr_id, p_campaign_id, v_tenant)
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = p_pr_id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id = p_pr_id;

  -- *** Stage 4 新增:鎖該 campaign + auto-confirm 訂單 ***
  UPDATE group_buy_campaigns
     SET status     = 'locked',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_campaign_id AND status = 'closed';

  PERFORM public._lock_orders_after_pr_aggregation(
    ARRAY[p_campaign_id], p_operator, p_pr_id
  );

  RETURN jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
END;
$function$;

COMMENT ON FUNCTION public.rpc_append_campaign_to_pr IS
  '把指定 closed campaign 併入既有 draft PR;'
  '尾巴自動把該 campaign 推進到 locked、把 pending 訂單推進到 confirmed(寫稽核)';

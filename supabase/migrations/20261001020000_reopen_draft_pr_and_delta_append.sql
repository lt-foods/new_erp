-- ============================================================================
-- 2026-10-01: 請購還是草稿時可以重開＋關團只補差額
-- ----------------------------------------------------------------------------
-- 規格：公司\01_進行中\需求暨計畫_NEW-ERP請購草稿階段可重開與關團只補差額_2026-10-01.md
--      （T1、T2；老闆 10/1 點頭：Q1 A 已確認訂單維持已確認、Q2 A 改到別天結單照現況）
--
-- 目的
--   包子媽關團後常要再打開讓客人下單。現況兩層擋：
--     ① 已鎖定（locked）的團，手機團控一律不能操作；
--     ② 已關團但已有請購連結，也擋重開（英文訊息）。
--   而且就算放寬，再關團時 rpc_append_campaign_to_pr 會把「整團量」再加一次 → 重複叫貨。
--   本檔：
--     T1 重開規則只看一件事「這團連到的請購單送出去了沒」：
--        全部還是草稿、且沒有任何品項轉成採購單 → 可以重開（已關團／已鎖定都一樣）；
--        否則擋，回中文原因（含請購單號）。
--     T2 關團併進草稿只補差額（同 #982 另外三個入口），並寫來源團明細
--        purchase_request_item_campaigns。
--
-- 基底版本（用 CREATE ... FUNCTION 前綴查最後一支重建版，d7af99f0）
--   rpc_quick_update_campaign_control → 20260814000010_fix_guarded_order_ambiguous_refs.sql:14-183（Alex 8/14）
--   rpc_append_campaign_to_pr         → 20260625000000_pr_create_lock_campaign_and_orders.sql:240-382
--   只呼叫、不改：_pr_campaign_sku_remaining_rows（唯一定義 20260921001000:240）、
--                _lock_orders_after_pr_aggregation（唯一定義 20260625000000:45）
--
-- 只動哪幾段
--   rpc_quick_update_campaign_control
--     * 狀態白名單加 locked；locked 只放行「重開」（p_status='open'），延長／加名額維持擋。
--     * 「已關團＋有請購連結一律擋」換成「已關團／已鎖定：連到的未取消請購單任一張非草稿、
--       或任一品項已轉採購單（purchase_request_items.po_item_id IS NOT NULL）才擋」。
--     * RAISE 訊息改中文（保留語意）。
--     * ⭐ 其餘逐字保留，包含 Alex 8/14 的表別名寫法（gbc. / ci. / coi. / co.）——
--       那是修「column reference is ambiguous」會員 APP 下單 500 的那一刀，不可退回。
--     * 不動訂單確認狀態（Q1 A）；重開仍需未來的收單時間。
--   rpc_append_campaign_to_pr
--     * 原本「整團量」迴圈（20260625000000:294-350）換成：
--       _pr_campaign_sku_remaining_rows(ARRAY[團]) 只取 delta_qty > 0，加進「這張」草稿；
--       差額 0 不新增、不報錯（關團流程 rpc_close_campaign 會照常鎖團、鎖訂單）。
--     * 寫入順序照 #982／#1049：來源團明細 → 品項總數 → 表頭總額
--       （反了會被 trg_pri_cross_close_date_duplicate_guard 擋，20260921001000:541-549）。
--     * 鎖團、鎖訂單、purchase_request_campaigns 連結、總金額重算、close_date mismatch
--       檢查（Q2 A）照舊。函式宣告列（無 SET search_path）照基底不動。
--
-- 鎖的順序（避免死鎖）
--   照 #982 的建單入口（20260921001000:708-713、:1119-1124；20260923090000:57-62）：
--     先鎖團（group_buy_campaigns FOR UPDATE）→ 才碰請購單；
--   請購單之後照 #1049 _pr_apply_qty_sync（20261001000000:624-631、:681-683）：
--     請購單表頭 FOR UPDATE → 明細／品項依 (團, 商品) 固定順序寫（本函式只有一個團 → ORDER BY sku_id）。
--   ℹ️ 基底是「先鎖請購單、團不鎖」；改成先鎖團，跟唯一的程式呼叫端 rpc_close_campaign
--      （20260831000060:205-209 先 FOR UPDATE 團再呼叫本函式）同一順序。
--
-- 執行方式（老闆貼 SQL Editor = autocommit、沒有交易保護）
--   第 0 段前置檢查放最前面，缺任何相依就 RAISE、後面一行都不會跑。
--   之後只有兩個 CREATE OR REPLACE FUNCTION ＋ COMMENT，**整份可重貼**。
--   沒有 DDL 改表、沒有洗資料、沒有動 GRANT（CREATE OR REPLACE 保留原有權限）。
--
-- Rollback
--   重跑 20260814000010_fix_guarded_order_ambiguous_refs.sql:14-183（rpc_quick_update_campaign_control
--   與其 REVOKE/GRANT）以及 20260625000000_pr_create_lock_campaign_and_orders.sql:240-382
--   （rpc_append_campaign_to_pr 與其 COMMENT）。
--   ⚠️ rollback 不會回收本檔執行期間已寫進去的 purchase_request_item_campaigns 列；
--      那些列本來就是正確的歸屬，舊版函式不讀它也不會壞（#982 三個入口與守衛都讀它）。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有 CREATE OR REPLACE 之前
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF to_regclass('public.purchase_request_item_campaigns') IS NULL THEN
    v_missing := v_missing || 'table public.purchase_request_item_campaigns (#982, 20260921001000)';
  END IF;
  IF to_regclass('public.purchase_request_campaigns') IS NULL THEN
    v_missing := v_missing || 'table public.purchase_request_campaigns';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = '_pr_campaign_sku_remaining_rows'
       AND pg_get_function_identity_arguments(p.oid) = 'p_campaign_ids bigint[]'
  ) THEN
    v_missing := v_missing || 'function public._pr_campaign_sku_remaining_rows(bigint[])';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = '_lock_orders_after_pr_aggregation'
  ) THEN
    v_missing := v_missing || 'function public._lock_orders_after_pr_aggregation';
  END IF;

  -- 兩支要被取代的函式本身必須存在（簽名不變，CREATE OR REPLACE 才會蓋到同一支）
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'rpc_quick_update_campaign_control'
       AND pg_get_function_identity_arguments(p.oid)
           = 'p_campaign_id bigint, p_status text, p_end_at timestamp with time zone, p_total_cap_qty_delta numeric'
  ) THEN
    v_missing := v_missing || 'function public.rpc_quick_update_campaign_control(bigint, text, timestamptz, numeric)';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'rpc_append_campaign_to_pr'
       AND pg_get_function_identity_arguments(p.oid) = 'p_pr_id bigint, p_campaign_id bigint, p_operator uuid'
  ) THEN
    v_missing := v_missing || 'function public.rpc_append_campaign_to_pr(bigint, bigint, uuid)';
  END IF;

  -- #982 防重守衛必須在（本檔不動它，但寫入順序是照它設計的）
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE NOT tgisinternal AND tgname = 'trg_pri_cross_close_date_duplicate_guard'
  ) THEN
    v_missing := v_missing || 'trigger trg_pri_cross_close_date_duplicate_guard (#982)';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE NOT tgisinternal AND tgname = 'trg_pric_cross_close_date_duplicate_guard'
  ) THEN
    v_missing := v_missing || 'trigger trg_pric_cross_close_date_duplicate_guard (#982)';
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。缺少：\n%',
      array_to_string(v_missing, E'\n');
  END IF;
END
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. rpc_quick_update_campaign_control
--    基底 20260814000010:14-183。只動：狀態白名單、locked 只能重開、
--    重開守衛（全部草稿才放行）、訊息中文。表別名寫法逐字保留。
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
  v_block_pr_no TEXT;
  v_block_pr_status TEXT;
BEGIN
  IF v_role NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION '權限不足（insufficient_role）';
  END IF;

  SELECT * INTO v_campaign
    FROM group_buy_campaigns gbc
   WHERE gbc.id = p_campaign_id
     AND gbc.tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到這個團（id=%）', p_campaign_id;
  END IF;

  -- 2026-10-01：加 locked（請購單還是草稿時可以重開，見下方重開守衛）
  IF v_campaign.status NOT IN ('draft', 'open', 'closed', 'locked') THEN
    RAISE EXCEPTION '這個團目前狀態是 %，不能用手機團控操作', v_campaign.status;
  END IF;

  -- 2026-10-01：已鎖定的團本案只放行「重開收單」；只延長、加整團名額維持擋
  IF v_campaign.status = 'locked'
     AND (p_status IS DISTINCT FROM 'open' OR p_total_cap_qty_delta IS NOT NULL) THEN
    RAISE EXCEPTION '這個團已鎖定（已進請購單），只能「重開收單」，不能只延長或加名額';
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
    RAISE EXCEPTION '這個團不是手機團控可操作的團（不是美食列車／限時／限量，也沒有設上限）';
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
      RAISE EXCEPTION '手機團控只能改成「收單中」，不能改成 %', p_status;
    END IF;

    IF p_status = 'open' THEN
      IF v_campaign.status NOT IN ('draft', 'closed', 'open', 'locked') THEN
        RAISE EXCEPTION '這個團目前狀態是 %，不能開團', v_campaign.status;
      END IF;

      PERFORM 1 FROM campaign_items ci WHERE ci.campaign_id = p_campaign_id LIMIT 1;
      IF NOT FOUND THEN
        RAISE EXCEPTION '這個團還沒有任何商品，不能開團';
      END IF;

      -- 2026-10-01：重開守衛只看「請購單送出去了沒」（已關團／已鎖定同一條規則）
      --   這團連到的未取消請購單（三種連法都算：團↔請購單連結、來源團明細、
      --   舊資料的 source_campaign_id），任一張不是草稿、或任一品項已轉採購單 → 擋。
      --   全部是草稿且沒有品項轉採購單 → 放行；再關團時 rpc_append_campaign_to_pr 只補差額。
      IF v_campaign.status IN ('closed', 'locked') THEN
        SELECT pr.pr_no, pr.status
          INTO v_block_pr_no, v_block_pr_status
          FROM purchase_requests pr
         WHERE pr.tenant_id = v_tenant
           AND pr.status <> 'cancelled'
           AND (
                 EXISTS (
                   SELECT 1
                     FROM purchase_request_campaigns prc
                    WHERE prc.pr_id = pr.id
                      AND prc.tenant_id = v_tenant
                      AND prc.campaign_id = p_campaign_id
                 )
              OR EXISTS (
                   SELECT 1
                     FROM purchase_request_items pri
                     JOIN purchase_request_item_campaigns pric ON pric.pr_item_id = pri.id
                    WHERE pri.pr_id = pr.id
                      AND pric.tenant_id = v_tenant
                      AND pric.campaign_id = p_campaign_id
                 )
              OR EXISTS (
                   SELECT 1
                     FROM purchase_request_items pri
                    WHERE pri.pr_id = pr.id
                      AND pri.source_campaign_id = p_campaign_id
                 )
               )
           AND (
                 pr.status <> 'draft'
              OR EXISTS (
                   SELECT 1
                     FROM purchase_request_items pri
                    WHERE pri.pr_id = pr.id
                      AND pri.po_item_id IS NOT NULL
                 )
               )
         ORDER BY pr.id
         LIMIT 1;

        IF v_block_pr_no IS NOT NULL THEN
          IF v_block_pr_status = 'draft' THEN
            RAISE EXCEPTION '請購單 % 已有品項轉成採購單，不能重開；要加量請到請購單頁', v_block_pr_no;
          END IF;
          RAISE EXCEPTION '請購單 % 已送出，不能重開；要加量請到請購單頁', v_block_pr_no;
        END IF;
      END IF;

      IF v_next_end_at IS NULL OR v_next_end_at <= NOW() THEN
        RAISE EXCEPTION '開團／重開要設定未來的收單時間';
      END IF;
    END IF;
  END IF;

  IF p_end_at IS NOT NULL THEN
    IF p_end_at <= NOW() THEN
      RAISE EXCEPTION '收單時間要設在未來';
    END IF;
    IF v_campaign.status = 'closed' AND v_next_status <> 'open' THEN
      RAISE EXCEPTION '已關團的團要用「重開收單」，不能只延長';
    END IF;
  END IF;

  IF p_total_cap_qty_delta IS NOT NULL THEN
    IF p_total_cap_qty_delta <= 0 THEN
      RAISE EXCEPTION '加名額的數量要大於 0';
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

COMMENT ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) IS
  '手機團控：延長／重開／加整團名額。已關團或已鎖定的團，只有在連到的請購單全部還是草稿、'
  '且沒有品項轉採購單時才能重開（2026-10-01）；已鎖定的團只能重開，不能只延長或加名額。';


-- ----------------------------------------------------------------------------
-- 2. rpc_append_campaign_to_pr
--    基底 20260625000000:240-382。只動：先鎖團、整團量迴圈換成只補差額＋寫來源團明細。
--    宣告列、守衛、purchase_request_campaigns 連結、總金額重算、鎖團、鎖訂單照舊。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_append_campaign_to_pr(p_pr_id bigint, p_campaign_id bigint, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant      UUID;
  v_pr_status   TEXT;
  v_pr_no       TEXT;
  v_pr_close_date DATE;
  v_camp_status TEXT;
  v_camp_close_date DATE;
  v_camp_tenant UUID;
  v_inserted    INTEGER := 0;
  v_updated     INTEGER := 0;
  v_demand RECORD;
  v_item_count  INTEGER;
  v_item_id     BIGINT;
  v_item_qty    NUMERIC;
  v_item_source BIGINT;
  v_item_po     BIGINT;
  v_attr_count  INTEGER;
BEGIN
  -- 鎖的順序：先團、後請購單（同 #982 建單入口、同 rpc_close_campaign 呼叫端），見檔頭
  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei')
    INTO v_camp_tenant, v_camp_status, v_camp_close_date
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  SELECT tenant_id, status, source_close_date, pr_no
    INTO v_tenant, v_pr_status, v_pr_close_date, v_pr_no
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

  IF v_camp_tenant <> v_tenant THEN
    RAISE EXCEPTION 'tenant mismatch';
  END IF;

  -- 差額 helper 用登入者的租戶算需求；租戶對不上會算出 0 而默默不加 → 直接擋
  IF public._current_tenant_id() IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION '目前登入的租戶與請購單 % 不符，不能併入', v_pr_no;
  END IF;

  IF v_camp_status <> 'closed' THEN
    RAISE EXCEPTION 'campaign % not in closed status (current: %)',
      p_campaign_id, v_camp_status;
  END IF;

  IF v_pr_close_date IS NOT NULL AND v_camp_close_date <> v_pr_close_date THEN
    RAISE EXCEPTION 'close_date mismatch: PR=%, campaign=%',
      v_pr_close_date, v_camp_close_date;
  END IF;

  -- 2026-10-01：只補差額（同團＋商品：目前需求 − 所有未取消請購單已請購量）。
  --   差額 ≤ 0 的商品一律略過（負差額由 #1049「同步最新開團數量」人工處理），
  --   差額全是 0 時本迴圈一筆都不跑、不報錯。
  --   寫入順序：來源團明細 → 品項總數（反了會被 #982 守衛擋）。
  FOR v_demand IN
    SELECT r.sku_id, r.delta_qty
      FROM public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id]) r
     WHERE r.campaign_id = p_campaign_id
       AND r.delta_qty > 0
     ORDER BY r.sku_id
  LOOP
    SELECT COUNT(*)
      INTO v_item_count
      FROM purchase_request_items pri
     WHERE pri.pr_id = p_pr_id
       AND pri.sku_id = v_demand.sku_id;

    -- 主線沒有 UNIQUE(pr_id, sku_id)；同商品多列時不知道要加在哪一列，
    -- 而且拆採購單是用 (pr, 供應商, 商品) 對回品項（20260428120000:385-391），多列會對錯 → 不自動加
    IF v_item_count > 1 THEN
      RAISE EXCEPTION '請購單 % 的同一商品（sku_id=%）有 % 列，系統無法判斷差額要加在哪一列；請到請購單頁人工處理',
        v_pr_no, v_demand.sku_id, v_item_count;
    END IF;

    IF v_item_count = 1 THEN
      SELECT pri.id, pri.qty_requested, pri.source_campaign_id, pri.po_item_id
        INTO v_item_id, v_item_qty, v_item_source, v_item_po
        FROM purchase_request_items pri
       WHERE pri.pr_id = p_pr_id
         AND pri.sku_id = v_demand.sku_id;

      IF v_item_po IS NOT NULL THEN
        RAISE EXCEPTION '請購單 % 的商品（sku_id=%）已轉成採購單，不能再加量；請到請購單頁處理',
          v_pr_no, v_demand.sku_id;
      END IF;

      SELECT COUNT(*)
        INTO v_attr_count
        FROM purchase_request_item_campaigns pric
       WHERE pric.pr_item_id = v_item_id;

      IF v_attr_count > 0 THEN
        -- 這一列已有各團明細：本團那筆加上差額（沒有就新增一筆）
        INSERT INTO purchase_request_item_campaigns AS pric (
          pr_item_id, campaign_id, tenant_id, qty_requested
        ) VALUES (
          v_item_id, p_campaign_id, v_tenant, v_demand.delta_qty
        )
        ON CONFLICT (pr_item_id, campaign_id) DO UPDATE
           SET qty_requested = pric.qty_requested + EXCLUDED.qty_requested;
      ELSIF v_item_source = p_campaign_id THEN
        -- 舊資料（沒有明細、只記 source_campaign_id = 本團）：整列歸本團再加差額。
        -- 同 #982 priority 1（20260921001000:1166-1189）與 rpc_add_pr_store_demands（20260924010000:189-196）。
        INSERT INTO purchase_request_item_campaigns (
          pr_item_id, campaign_id, tenant_id, qty_requested
        ) VALUES (
          v_item_id, p_campaign_id, v_tenant, v_item_qty + v_demand.delta_qty
        );
      ELSE
        -- 舊資料且不是本團的：補明細會讓「品項總數 ≠ 明細加總」被 #982 守衛退回，
        -- 另開一列又會撞到拆採購單的一商品一列假設 → 不自動加
        RAISE EXCEPTION '請購單 % 的商品（sku_id=%）是沒有來源團明細的舊資料，系統無法把本團差額併進去；請到請購單頁人工處理',
          v_pr_no, v_demand.sku_id;
      END IF;

      UPDATE purchase_request_items
         SET qty_requested = qty_requested + v_demand.delta_qty,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = v_item_id;

      v_updated := v_updated + 1;
    ELSE
      -- 這張單還沒有這個商品：新增一列＋來源團明細，同一句寫（同 #982 新增差額單的寫法）
      WITH inserted AS (
        INSERT INTO purchase_request_items (
          pr_id, sku_id, qty_requested,
          suggested_supplier_id, unit_cost,
          retail_price, franchise_price,
          source_campaign_id,
          created_by, updated_by
        )
        SELECT
          p_pr_id, v_demand.sku_id, v_demand.delta_qty,
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
        ) pr_franchise ON TRUE
        RETURNING id
      )
      INSERT INTO purchase_request_item_campaigns (
        pr_item_id, campaign_id, tenant_id, qty_requested
      )
      SELECT i.id, p_campaign_id, v_tenant, v_demand.delta_qty
        FROM inserted i;

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
  '把指定 closed campaign 併入既有 draft PR：只補同團+商品尚未請購的差額（2026-10-01），'
  '並寫 purchase_request_item_campaigns；差額 0 不新增也不報錯。'
  '尾巴自動把該 campaign 推進到 locked、把 pending 訂單推進到 confirmed(寫稽核)';

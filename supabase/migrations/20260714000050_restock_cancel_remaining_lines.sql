-- ============================================================================
-- 2026-07-14: 補貨申請部分開單後，剩餘品相可「刪除、不再補貨」
-- ----------------------------------------------------------------------------
-- 需求（cktalex 2026-07-04 回報，接續 20260714000040）：
--   依品相分張開請購單後，沒開單的品相可能根本不想補了。原本申請會卡在
--   pending 直到「全品相都開單」；現在允許把剩餘品相刪除（不再補貨），
--   刪完若全品相都已處理（開單或刪除）→ 申請直接結案 approved_pr。
--
-- 變更：
--   Part 0  restock_request_lines 加 cancelled_at / cancelled_by（軟刪，
--     保留稽核；硬刪會讓 qty/金額歷史消失）。
--   Part 1  新 RPC rpc_cancel_restock_lines(p_request_id, p_line_ids)：
--     - 只在申請已有品相開過請購單時可用（整張不補貨走既有「拒絕」）。
--     - p_line_ids = NULL → 全部尚未開單且未刪除的品相。
--     - 已開請購單 / 已刪除的品相不可再刪。
--     - 同步把 sentinel RR-{id} customer_order 對應 sku 的 pending 明細
--       標 'cancelled'（報表/需求彙總不再看到這筆需求）。
--     - 刪完若無剩餘品相 → status='approved_pr'（header linked_pr_id 在
--       第一張 PR 開立時已寫入，CHECK 約束滿足）。
--   Part 2  rpc_approve_restock_lines_to_pr 改版（基底 20260714000040）：
--     - 預設選取（NULL）排除已刪除品相
--     - 明確指定已刪除品相 → RAISE
--     - 「全開單完成」判斷改為「無 未開單且未刪除 的品相」
--
-- 基底版本（依 CLAUDE.md 規則 grep 全歷史、以時間最新版擴寫）：
--   rpc_approve_restock_lines_to_pr ← 20260714000040_restock_pr_by_variant.sql（唯一版本）
--
-- Rollback：
--   DROP FUNCTION public.rpc_cancel_restock_lines(BIGINT, BIGINT[]);
--   rpc_approve_restock_lines_to_pr → 重跑 20260714000040 的 CREATE OR REPLACE。
--   ALTER TABLE restock_request_lines DROP COLUMN cancelled_at, DROP COLUMN cancelled_by;
--   （已標 cancelled 的 customer_order_items 不自動還原）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Part 0: 明細層軟刪欄位
-- ----------------------------------------------------------------------------
ALTER TABLE public.restock_request_lines
  ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancelled_by UUID;

COMMENT ON COLUMN public.restock_request_lines.cancelled_at IS
  '品相刪除（不再補貨）時間；NULL = 有效明細。'
  '與 linked_pr_id 互斥 — 已開請購單的品相不可刪。';

-- ----------------------------------------------------------------------------
-- Part 1: rpc_cancel_restock_lines — 刪除剩餘品相（不再補貨）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_cancel_restock_lines(
  p_request_id BIGINT,
  p_line_ids   BIGINT[] DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID := public._current_tenant_id();
  v_user      UUID := auth.uid();
  v_role      TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req       RECORD;
  v_selected  BIGINT[];
  v_bad       BIGINT;
  v_remaining INTEGER;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot cancel restock lines', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'request % already processed (status=%)', p_request_id, v_req.status;
  END IF;

  -- 只服務「依品相分張」流程的收尾；整張不補貨走既有「拒絕」（留 reason 稽核）
  IF NOT EXISTS (
    SELECT 1 FROM restock_request_lines
     WHERE request_id = p_request_id AND linked_pr_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '補貨申請 #% 尚未開立任何請購單；整張不補貨請用「拒絕」', p_request_id;
  END IF;

  -- 選取明細：未指定 → 全部尚未開單且未刪除的品相
  IF p_line_ids IS NULL OR COALESCE(array_length(p_line_ids, 1), 0) = 0 THEN
    SELECT array_agg(id) INTO v_selected
      FROM restock_request_lines
     WHERE request_id = p_request_id AND tenant_id = v_tenant
       AND linked_pr_id IS NULL AND cancelled_at IS NULL;
  ELSE
    SELECT t.id INTO v_bad
      FROM unnest(p_line_ids) AS t(id)
     WHERE NOT EXISTS (
             SELECT 1 FROM restock_request_lines l
              WHERE l.id = t.id
                AND l.request_id = p_request_id
                AND l.tenant_id  = v_tenant
           )
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '明細 #% 不屬於補貨申請 #%', v_bad, p_request_id;
    END IF;

    SELECT l.id INTO v_bad
      FROM restock_request_lines l
     WHERE l.id = ANY (p_line_ids) AND l.linked_pr_id IS NOT NULL
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '明細 #% 已開請購單，不可刪除', v_bad;
    END IF;

    SELECT l.id INTO v_bad
      FROM restock_request_lines l
     WHERE l.id = ANY (p_line_ids) AND l.cancelled_at IS NOT NULL
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '明細 #% 已刪除', v_bad;
    END IF;

    SELECT array_agg(DISTINCT t.id) INTO v_selected
      FROM unnest(p_line_ids) AS t(id);
  END IF;

  IF v_selected IS NULL OR COALESCE(array_length(v_selected, 1), 0) = 0 THEN
    RAISE EXCEPTION '補貨申請 #% 沒有可刪除的品項', p_request_id;
  END IF;

  UPDATE restock_request_lines
     SET cancelled_at = NOW(),
         cancelled_by = v_user,
         updated_by   = v_user
   WHERE id = ANY (v_selected);

  -- 同步取消 sentinel RR-{id} 訂單的對應明細（需求彙總/報表不再列入）
  UPDATE customer_order_items coi
     SET status     = 'cancelled',
         updated_by = v_user,
         updated_at = NOW()
    FROM customer_orders co
   WHERE co.id = coi.order_id
     AND co.tenant_id = v_tenant
     AND co.order_kind = 'restock'
     AND co.external_order_no = 'RR-' || p_request_id::TEXT
     AND coi.status = 'pending'
     AND coi.sku_id IN (
           SELECT sku_id FROM restock_request_lines WHERE id = ANY (v_selected)
         );

  SELECT COUNT(*) INTO v_remaining
    FROM restock_request_lines
   WHERE request_id = p_request_id
     AND linked_pr_id IS NULL AND cancelled_at IS NULL;

  IF v_remaining = 0 THEN
    -- 全品相都處理完（開單或刪除）→ 結案；linked_pr_id 於第一張 PR 已寫入
    UPDATE restock_requests
       SET status      = 'approved_pr',
           approved_by = v_user,
           approved_at = NOW(),
           updated_by  = v_user
     WHERE id = p_request_id;
  END IF;

  RETURN COALESCE(array_length(v_selected, 1), 0);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_cancel_restock_lines(BIGINT, BIGINT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_restock_lines(BIGINT, BIGINT[]) TO authenticated;

COMMENT ON FUNCTION public.rpc_cancel_restock_lines(BIGINT, BIGINT[]) IS
  '補貨申請剩餘品相刪除（不再補貨，軟刪）：限已有品相開過請購單的 pending 申請；'
  'p_line_ids=NULL → 全部未開單品相。同步取消 sentinel RR- 訂單對應明細；'
  '刪完無剩餘品相 → 申請結案 approved_pr。';

-- ----------------------------------------------------------------------------
-- Part 2: rpc_approve_restock_lines_to_pr — 排除已刪除品相
--         （基底 20260714000040，改動：預設選取/驗證/完成判斷排除 cancelled）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_approve_restock_lines_to_pr(
  p_request_id BIGINT,
  p_line_ids   BIGINT[] DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID := public._current_tenant_id();
  v_user      UUID := auth.uid();
  v_role      TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req       RECORD;
  v_pr_id     BIGINT;
  v_hq_loc    BIGINT;
  v_no        TEXT;
  v_selected  BIGINT[];
  v_bad       BIGINT;
  v_remaining INTEGER;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot approve restock', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'request % already processed (status=%)', p_request_id, v_req.status;
  END IF;

  -- 選取明細：未指定 → 全部尚未開單且未刪除的明細
  IF p_line_ids IS NULL OR COALESCE(array_length(p_line_ids, 1), 0) = 0 THEN
    SELECT array_agg(id) INTO v_selected
      FROM restock_request_lines
     WHERE request_id = p_request_id AND tenant_id = v_tenant
       AND linked_pr_id IS NULL AND cancelled_at IS NULL;
  ELSE
    -- 守衛：每個 id 都必須屬於本申請
    SELECT t.id INTO v_bad
      FROM unnest(p_line_ids) AS t(id)
     WHERE NOT EXISTS (
             SELECT 1 FROM restock_request_lines l
              WHERE l.id = t.id
                AND l.request_id = p_request_id
                AND l.tenant_id  = v_tenant
           )
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '明細 #% 不屬於補貨申請 #%', v_bad, p_request_id;
    END IF;

    -- 守衛：不可重複開單
    SELECT l.id INTO v_bad
      FROM restock_request_lines l
     WHERE l.id = ANY (p_line_ids)
       AND l.linked_pr_id IS NOT NULL
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '明細 #% 已開過請購單，不可重複開單', v_bad;
    END IF;

    -- 守衛（20260714000050）：已刪除的品相不可開單
    SELECT l.id INTO v_bad
      FROM restock_request_lines l
     WHERE l.id = ANY (p_line_ids)
       AND l.cancelled_at IS NOT NULL
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '明細 #% 已刪除，不可開請購單', v_bad;
    END IF;

    SELECT array_agg(DISTINCT t.id) INTO v_selected
      FROM unnest(p_line_ids) AS t(id);
  END IF;

  IF v_selected IS NULL OR COALESCE(array_length(v_selected, 1), 0) = 0 THEN
    RAISE EXCEPTION '補貨申請 #% 沒有可開請購單的品項', p_request_id;
  END IF;

  SELECT id INTO v_hq_loc FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;

  -- 每次呼叫都建新 PR（沿用 20260606000050「不 append 既有 draft」原則）
  v_no := public.rpc_next_pr_no();
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_location_id, status, raw_line_text,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, v_hq_loc, 'draft',
    'restock request #' || p_request_id::TEXT,
    v_user, v_user
  ) RETURNING id INTO v_pr_id;

  -- 鏡像選取的明細進 PR（suggested_supplier 由 trg_pri_fill_default_supplier 補）
  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, raw_line, notes, created_by, updated_by
  )
  SELECT v_pr_id, l.sku_id, l.qty,
         'restock #' || p_request_id::TEXT,
         l.notes, v_user, v_user
    FROM restock_request_lines l
   WHERE l.id = ANY (v_selected);

  -- stamp 明細層對照
  UPDATE restock_request_lines
     SET linked_pr_id = v_pr_id,
         updated_by   = v_user
   WHERE id = ANY (v_selected);

  SELECT COUNT(*) INTO v_remaining
    FROM restock_request_lines
   WHERE request_id = p_request_id
     AND linked_pr_id IS NULL AND cancelled_at IS NULL;

  IF v_remaining = 0 THEN
    -- 全品相都處理完（開單或刪除）→ 申請完成，進 approved_pr
    UPDATE restock_requests
       SET status       = 'approved_pr',
           linked_pr_id = COALESCE(linked_pr_id, v_pr_id),
           approved_by  = v_user,
           approved_at  = NOW(),
           updated_by   = v_user
     WHERE id = p_request_id;
  ELSE
    -- 部分開單 → 停留 pending，header 記第一張 PR 方便 Inbox 連結
    UPDATE restock_requests
       SET linked_pr_id = COALESCE(linked_pr_id, v_pr_id),
           updated_by   = v_user
     WHERE id = p_request_id;
  END IF;

  RETURN v_pr_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_approve_restock_lines_to_pr(BIGINT, BIGINT[]) IS
  '補貨申請依品相開請購單：為選取明細建新 draft PR 並 stamp 明細 linked_pr_id；'
  'p_line_ids=NULL → 全部未開單且未刪除明細。可重複呼叫分多張 PR；'
  '全品相處理完（開單或刪除）後申請進 approved_pr，否則停留 pending。';

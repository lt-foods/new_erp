-- ============================================================================
-- 2026-07-14: 補貨申請可依「品相」（明細 SKU）分開開請購單
-- ----------------------------------------------------------------------------
-- 需求（cktalex 2026-07-03 回報）：
--   一張補貨申請常混多個品相（同商品不同規格/等級，例 (A)250g-300g、
--   (B)300g-350g），不同品相對不同供應商。HQ Inbox 的「下訂單」目前
--   一鍵把整張申請鏡像成一張請購單，無法依品相分張。
--
-- 變更：
--   Part 0  restock_request_lines 加 linked_pr_id（每條明細記自己進了哪張 PR）。
--   Part 1  新 RPC rpc_approve_restock_lines_to_pr(p_request_id, p_line_ids)：
--     - 為「選取的明細」建一張新 draft PR 並鏡像 lines、stamp 明細 linked_pr_id。
--     - p_line_ids = NULL → 全部尚未開單的明細（= 舊整張下訂單行為）。
--     - 可重複呼叫：每次選不同品相 → 各自成一張 PR。
--     - 全部明細都開單後 → 申請 status='approved_pr'（header linked_pr_id
--       停留在第一張 PR，明細層 linked_pr_id 才是完整對照）。
--     - 部分開單時申請停留 pending，HQ Inbox 可繼續處理剩餘品相。
--   Part 2  rpc_approve_restock_to_pr 改為薄包裝：呼叫 Part 1（p_line_ids=NULL）。
--     行為與 20260606000050 版一致（整張建新 PR），另外多 stamp 明細。
--   Part 3  rpc_approve_restock_to_transfer 加守衛：已有品相開過請購單的申請
--     不可再整張「派貨」（避免已下訂的品相被重複派庫存；剩餘品相請繼續開 PR）。
--     派貨工作台 wave 流只吃 approved_transfer，經此守衛後不會出現
--     「部分品相已開 PR 又進 wave」的狀態，v_picking_demand_no_po /
--     rpc_create_wave_from_restock 不需要動。
--   Part 4  rpc_delete_restock_request 加守衛：已有品相開過請購單的 pending
--     申請不可刪（明細 CASCADE 硬刪會讓已建的 PR 失去來源對照）。
--   Part 5  rpc_reject_restock 加守衛：已有品相開過請購單的申請不可整張拒絕
--     （已下訂的品相會照常進貨，rejected 狀態會與事實矛盾）。
--
-- 基底版本（依 CLAUDE.md 規則 grep 全歷史、以時間最新版擴寫）：
--   rpc_approve_restock_to_pr       ← 20260606000050_rpc_approve_restock_to_pr_always_new.sql
--   rpc_approve_restock_to_transfer ← 20260612000040_approve_restock_via_picking_workstation.sql
--   rpc_delete_restock_request      ← 20260714000030_rpc_delete_restock_request_store_scope.sql
--   rpc_reject_restock              ← 20260515000002_rpc_store_self_service.sql（唯一版本）
--   （suggested_supplier fallback 由 20260709000030 的 BEFORE INSERT trigger
--    trg_pri_fill_default_supplier 覆蓋，本檔 insert 不需帶供應商。）
--
-- Rollback：
--   DROP FUNCTION public.rpc_approve_restock_lines_to_pr(BIGINT, BIGINT[]);
--   rpc_approve_restock_to_pr       → 重跑 20260606000050 的 CREATE OR REPLACE。
--   rpc_approve_restock_to_transfer → 重跑 20260612000040 的對應區塊。
--   rpc_delete_restock_request      → 重跑 20260714000030 的 CREATE OR REPLACE。
--   rpc_reject_restock              → 重跑 20260515000002 的 CREATE OR REPLACE。
--   ALTER TABLE restock_request_lines DROP COLUMN linked_pr_id;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Part 0: 明細層 PR 對照欄位
-- ----------------------------------------------------------------------------
ALTER TABLE public.restock_request_lines
  ADD COLUMN IF NOT EXISTS linked_pr_id BIGINT REFERENCES public.purchase_requests(id);

COMMENT ON COLUMN public.restock_request_lines.linked_pr_id IS
  '此明細（品相）被鏡像進哪張請購單；NULL = 尚未開單。'
  '整張申請可拆多張 PR — header 的 linked_pr_id 只記第一張，這裡才是完整對照。';

CREATE INDEX IF NOT EXISTS idx_restock_lines_linked_pr
  ON public.restock_request_lines (linked_pr_id)
  WHERE linked_pr_id IS NOT NULL;

-- 既有 approved_pr 申請 backfill：整張都進了 header 那張 PR
UPDATE public.restock_request_lines l
   SET linked_pr_id = r.linked_pr_id
  FROM public.restock_requests r
 WHERE r.id = l.request_id
   AND r.linked_pr_id IS NOT NULL
   AND l.linked_pr_id IS NULL;

-- ----------------------------------------------------------------------------
-- Part 1: rpc_approve_restock_lines_to_pr — 依品相（明細）開請購單
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

  -- 選取明細：未指定 → 全部尚未開單的明細
  IF p_line_ids IS NULL OR COALESCE(array_length(p_line_ids, 1), 0) = 0 THEN
    SELECT array_agg(id) INTO v_selected
      FROM restock_request_lines
     WHERE request_id = p_request_id AND tenant_id = v_tenant
       AND linked_pr_id IS NULL;
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
   WHERE request_id = p_request_id AND linked_pr_id IS NULL;

  IF v_remaining = 0 THEN
    -- 全品相都開單 → 申請完成，進 approved_pr
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

REVOKE ALL ON FUNCTION public.rpc_approve_restock_lines_to_pr(BIGINT, BIGINT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_approve_restock_lines_to_pr(BIGINT, BIGINT[]) TO authenticated;

COMMENT ON FUNCTION public.rpc_approve_restock_lines_to_pr(BIGINT, BIGINT[]) IS
  '補貨申請依品相開請購單：為選取明細建新 draft PR 並 stamp 明細 linked_pr_id；'
  'p_line_ids=NULL → 全部未開單明細。可重複呼叫分多張 PR；'
  '全明細開單後申請進 approved_pr，否則停留 pending。';

-- ----------------------------------------------------------------------------
-- Part 2: rpc_approve_restock_to_pr — 薄包裝（整張 = 全部剩餘品相）
--         （基底 20260606000050；對外行為不變：整張建一張新 PR）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_approve_restock_to_pr(
  p_request_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.rpc_approve_restock_lines_to_pr(p_request_id, NULL);
END;
$$;

COMMENT ON FUNCTION public.rpc_approve_restock_to_pr(BIGINT) IS
  '把補貨申請 approve_pr 化：整張（剩餘全部品相）建一張新 draft PR。'
  '自 20260714000040 起為 rpc_approve_restock_lines_to_pr 的薄包裝。';

-- ----------------------------------------------------------------------------
-- Part 3: rpc_approve_restock_to_transfer — 守衛已部分開單的申請
--         （基底 20260612000040，僅插入一段守衛，其餘逐字保留）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_approve_restock_to_transfer(p_request_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req    RECORD;
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

  -- 20260714000040 守衛：已有品相開過請購單 → 不可整張派貨（會重複供貨）
  IF EXISTS (
    SELECT 1 FROM restock_request_lines
     WHERE request_id = p_request_id AND linked_pr_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '補貨申請 #% 已有品相開立請購單，不可再整張派貨；剩餘品相請繼續以請購單處理',
      p_request_id;
  END IF;

  -- 只更新狀態:後續由派貨工作台 rpc_create_wave_from_restock 接手
  UPDATE restock_requests
     SET status = 'approved_transfer',
         linked_transfer_id = NULL,
         approved_by = v_user,
         approved_at = NOW(),
         updated_by  = v_user,
         updated_at  = NOW()
   WHERE id = p_request_id;

  RETURN p_request_id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_approve_restock_to_transfer(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_approve_restock_to_transfer(BIGINT) IS
  '審核通過補貨申請、轉派貨工作台處理(不直接建 transfer)。實際 transfer 由 wave 流產出。'
  '已有品相開立請購單的申請不可整張派貨（20260714000040）。';

-- ----------------------------------------------------------------------------
-- Part 4: rpc_delete_restock_request — 守衛已部分開單的申請
--         （基底 20260714000030，僅插入守門 3，其餘逐字保留）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_delete_restock_request(
  p_request_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req    RECORD;
  v_waves  INTEGER;
  v_pr_lines INTEGER;
BEGIN
  -- role 守門：HQ 職能 + 門市職能（空字串放行 — 對齊既有 restock RPC）
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot delete restock request', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'restock request % not found', p_request_id;
  END IF;

  -- 門市角色只能刪自己店的申請（店名 claim → store id，見 20260707000070）
  IF v_role IN ('store_manager','store_staff')
     AND NOT (v_req.requesting_store_id = ANY (public._jwt_store_ids())) THEN
    RAISE EXCEPTION 'store role can only delete request for own store';
  END IF;

  -- 守門 1：只有 pending 可刪 — 已派貨/已轉採購的單有下游單據，走各自流程
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'restock request % is %, only pending can be deleted',
      p_request_id, v_req.status;
  END IF;

  -- 守門 2：雙重保險 — 已有撿貨波引用（正常 pending 不會有；建波會把狀態
  -- 推到 approved_transfer，這裡防的是資料不一致）
  SELECT COUNT(*) INTO v_waves
    FROM picking_waves
   WHERE source_restock_request_id = p_request_id;
  IF v_waves > 0 THEN
    RAISE EXCEPTION 'restock request % already has picking waves, cannot delete', p_request_id;
  END IF;

  -- 守門 3（20260714000040）：pending 但已有品相開立請購單 → 不可刪
  -- （明細 CASCADE 硬刪會讓已建的 PR 失去來源對照）
  SELECT COUNT(*) INTO v_pr_lines
    FROM restock_request_lines
   WHERE request_id = p_request_id AND linked_pr_id IS NOT NULL;
  IF v_pr_lines > 0 THEN
    RAISE EXCEPTION 'restock request % already has lines sent to purchase request, cannot delete', p_request_id;
  END IF;

  -- 連帶刪內部 sentinel 訂單 RR-{id}（items 為 ON DELETE CASCADE）。
  -- 舊資料（20260612000020 之前建的申請）沒有 RR- 訂單，刪 0 筆是正常的。
  BEGIN
    DELETE FROM customer_orders
     WHERE tenant_id = v_tenant
       AND order_kind = 'restock'
       AND external_order_no = 'RR-' || p_request_id::TEXT;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'restock request % internal order still referenced, cannot delete', p_request_id;
  END;

  -- 實體硬刪：restock_request_lines 為 ON DELETE CASCADE
  BEGIN
    DELETE FROM restock_requests
     WHERE id = p_request_id AND tenant_id = v_tenant;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'restock request % still referenced by other records, cannot delete', p_request_id;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_restock_request(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_restock_request(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_restock_request(BIGINT) IS
  '補貨申請刪除（硬刪）：限 pending、無撿貨波引用、無品相已開請購單；'
  '連帶刪建單時自動掛的內部 RR-{id} customer_order（items 為 CASCADE）；'
  'lines 由 ON DELETE CASCADE 連帶刪；同 tenant；'
  'HQ 職能全刪、門市職能限自己店（_jwt_store_ids）。';

-- ----------------------------------------------------------------------------
-- Part 5: rpc_reject_restock — 守衛已部分開單的申請
--         （基底 20260515000002，僅插入一段守衛，其餘逐字保留）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_reject_restock(
  p_request_id BIGINT,
  p_reason     TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req    RECORD;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot reject restock', v_role;
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'rejection reason required';
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'request % already processed (status=%)', p_request_id, v_req.status;
  END IF;

  -- 20260714000040 守衛：已有品相開立請購單 → 不可整張拒絕
  IF EXISTS (
    SELECT 1 FROM restock_request_lines
     WHERE request_id = p_request_id AND linked_pr_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '補貨申請 #% 已有品相開立請購單，不可整張拒絕；剩餘品相請繼續以請購單處理',
      p_request_id;
  END IF;

  UPDATE restock_requests
     SET status = 'rejected',
         rejected_by = v_user,
         rejected_at = NOW(),
         rejected_reason = TRIM(p_reason),
         updated_by = v_user
   WHERE id = p_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_reject_restock(BIGINT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_reject_restock(BIGINT, TEXT) IS
  'HQ 拒絕補貨申請（reason 必填）；已有品相開立請購單的申請不可整張拒絕（20260714000040）。';

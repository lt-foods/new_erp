-- ============================================================
-- 總倉收件匣異常：總部處理歷程／結案／重開追蹤
--
-- live 異常仍由 v_hq_exceptions 計算，絕不在收貨 RPC 或庫存流程加 trigger。
-- 第一次總部留下紀錄時才把當下來源資料快照寫入 case；event 永遠 append-only。
-- 收貨短少的真正帳務動作沿用最新版 rpc_resolve_transfer_item_shortage，並在同
-- 一 transaction 內於其成功後才結案，避免「看起來已結案、其實帳沒改」的假紀錄。
--
-- 基底：v_hq_exceptions = 20260811020010；
--       rpc_resolve_transfer_item_shortage = 20260811020000（本檔不改寫）。
-- Rollback：DROP FUNCTION 本檔新增的 6 支函式；DROP TABLE hq_exception_events,
--           hq_exception_cases（已寫歷程須先匯出，不可直接刪除）。
-- ============================================================

CREATE TABLE public.hq_exception_cases (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL,
  row_key     TEXT NOT NULL,
  type        TEXT NOT NULL CHECK (type IN ('po_shortage','po_damage','po_over','transfer_short')),
  source_ref  JSONB NOT NULL,
  snapshot    JSONB NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
  result      TEXT,
  opened_by   UUID NOT NULL,
  opened_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_by UUID,
  resolved_at TIMESTAMPTZ,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, row_key)
);

CREATE INDEX idx_hq_exception_cases_status
  ON public.hq_exception_cases (tenant_id, status, updated_at DESC);

CREATE TABLE public.hq_exception_events (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL,
  case_id     BIGINT NOT NULL REFERENCES public.hq_exception_cases(id),
  action      TEXT NOT NULL CHECK (action IN ('opened','note','resolved','reopened')),
  note        TEXT,
  result      TEXT,
  created_by  UUID NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_hq_exception_events_case
  ON public.hq_exception_events (case_id, created_at, id);

COMMENT ON TABLE public.hq_exception_cases IS
  '總倉異常案件：live 異常第一次由總部處理時，從 v_hq_exceptions 擷取快照；重開只改追蹤狀態，絕不改庫存或收貨。';
COMMENT ON TABLE public.hq_exception_events IS
  '總倉異常處理歷程（append-only）：opened/note/resolved/reopened。';

CREATE TRIGGER trg_no_mut_hq_exception_events
  BEFORE UPDATE OR DELETE ON public.hq_exception_events
  FOR EACH ROW EXECUTE FUNCTION public.forbid_append_only_mutation();

ALTER TABLE public.hq_exception_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hq_exception_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY hq_exception_cases_hq_read ON public.hq_exception_cases
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') IN ('owner','admin','hq_manager')
  );
CREATE POLICY hq_exception_events_hq_read ON public.hq_exception_events
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') IN ('owner','admin','hq_manager')
  );

-- 取得並鎖住案件。前端不能傳快照：資料必須由當下的 live view 取得。
CREATE OR REPLACE FUNCTION public._hq_exception_capture_case(
  p_row_key TEXT,
  p_operator UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role       TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_tenant     UUID := public._current_tenant_id();
  v_row        public.v_hq_exceptions%ROWTYPE;
  v_source_tenant UUID;
  v_case_id    BIGINT;
  v_source_ref JSONB;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager') THEN
    RAISE EXCEPTION '僅總部帳號可處理異常';
  END IF;
  IF auth.uid() IS NULL OR auth.uid() <> p_operator THEN
    RAISE EXCEPTION 'operator 必須是目前登入的總部帳號';
  END IF;

  -- 已有案件（包括已結案後重新開啟）不必再依賴 live view；否則原始紅字
  -- 消失後會無法繼續追蹤。首次建立才從 live row 取不可回改的快照。
  SELECT id INTO v_case_id
    FROM public.hq_exception_cases
   WHERE tenant_id = v_tenant AND row_key = p_row_key
   FOR UPDATE;
  IF FOUND THEN RETURN v_case_id; END IF;

  SELECT * INTO v_row FROM public.v_hq_exceptions WHERE row_key = p_row_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION '異常 % 已不在待處理清單，不能新增紀錄', p_row_key;
  END IF;

  CASE v_row.type
    WHEN 'po_shortage', 'po_over' THEN
      SELECT tenant_id INTO v_source_tenant FROM public.purchase_orders WHERE id = v_row.doc_id;
      v_source_ref := jsonb_build_object('purchase_order_id', v_row.doc_id, 'sku_id', v_row.sku_id);
    WHEN 'po_damage' THEN
      SELECT gr.tenant_id INTO v_source_tenant
        FROM public.goods_receipt_items gri
        JOIN public.goods_receipts gr ON gr.id = gri.gr_id
       WHERE gri.id = substring(v_row.row_key FROM '^po-dmg-([0-9]+)$')::BIGINT;
      v_source_ref := jsonb_build_object('goods_receipt_item_id', substring(v_row.row_key FROM '^po-dmg-([0-9]+)$')::BIGINT, 'sku_id', v_row.sku_id);
    WHEN 'transfer_short' THEN
      SELECT tenant_id INTO v_source_tenant FROM public.transfers WHERE id = v_row.transfer_id;
      v_source_ref := jsonb_build_object('transfer_id', v_row.transfer_id, 'transfer_item_id', v_row.transfer_item_id, 'sku_id', v_row.sku_id);
    ELSE
      RAISE EXCEPTION '未知異常類型 %', v_row.type;
  END CASE;
  IF v_source_tenant IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION '異常 % 不屬於目前公司', p_row_key;
  END IF;

  INSERT INTO public.hq_exception_cases (
    tenant_id, row_key, type, source_ref, snapshot, opened_by
  ) VALUES (
    v_tenant, v_row.row_key, v_row.type, v_source_ref,
    jsonb_build_object(
      'row_key', v_row.row_key, 'type', v_row.type, 'source_ref', v_source_ref,
      'occurred_at', v_row.ts, 'doc_no', v_row.doc_no, 'sku_id', v_row.sku_id,
      'sku_code', v_row.sku_code, 'sku_label', v_row.sku_label,
      'expected', v_row.expected, 'actual', v_row.actual, 'diff', v_row.diff,
      'reason', v_row.reason, 'extra', v_row.extra, 'warehouse_name', v_row.warehouse_name
    ), p_operator
  ) ON CONFLICT (tenant_id, row_key) DO UPDATE
    SET updated_at = public.hq_exception_cases.updated_at
  RETURNING id INTO v_case_id;

  IF NOT EXISTS (SELECT 1 FROM public.hq_exception_events WHERE case_id = v_case_id) THEN
    -- 店家填的短收／破損說明是第一筆歷程的一部分，不能只留在會變動的 live view。
    INSERT INTO public.hq_exception_events (tenant_id, case_id, action, note, created_by)
    VALUES (v_tenant, v_case_id, 'opened', NULLIF(TRIM(v_row.reason), ''), p_operator);
  END IF;
  RETURN v_case_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_hq_exception_add_note(
  p_row_key TEXT,
  p_note TEXT,
  p_operator UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case_id BIGINT;
BEGIN
  IF NULLIF(TRIM(p_note), '') IS NULL THEN RAISE EXCEPTION '處理經過不可空白'; END IF;
  v_case_id := public._hq_exception_capture_case(p_row_key, p_operator);
  IF EXISTS (SELECT 1 FROM public.hq_exception_cases WHERE id = v_case_id AND status = 'resolved') THEN
    RAISE EXCEPTION '此案件已結案，請先重新開啟追蹤';
  END IF;
  INSERT INTO public.hq_exception_events (tenant_id, case_id, action, note, created_by)
  SELECT tenant_id, id, 'note', TRIM(p_note), p_operator FROM public.hq_exception_cases WHERE id = v_case_id;
  UPDATE public.hq_exception_cases SET updated_at = NOW() WHERE id = v_case_id;
  RETURN v_case_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_hq_exception_resolve(
  p_row_key TEXT,
  p_result TEXT,
  p_note TEXT,
  p_operator UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case_id BIGINT;
BEGIN
  IF NULLIF(TRIM(p_result), '') IS NULL THEN RAISE EXCEPTION '結案必須填最後結果'; END IF;
  v_case_id := public._hq_exception_capture_case(p_row_key, p_operator);
  IF EXISTS (SELECT 1 FROM public.hq_exception_cases WHERE id = v_case_id AND type = 'transfer_short') THEN
    RAISE EXCEPTION '收貨短少必須用既有處理方式完成真正帳務動作，不能只標結案';
  END IF;
  IF EXISTS (SELECT 1 FROM public.hq_exception_cases WHERE id = v_case_id AND status = 'resolved') THEN
    RAISE EXCEPTION '此案件已結案，請先重新開啟追蹤';
  END IF;
  UPDATE public.hq_exception_cases
     SET status = 'resolved', result = TRIM(p_result), resolved_by = p_operator, resolved_at = NOW(), updated_at = NOW()
   WHERE id = v_case_id;
  INSERT INTO public.hq_exception_events (tenant_id, case_id, action, note, result, created_by)
  SELECT tenant_id, id, 'resolved', NULLIF(TRIM(p_note), ''), TRIM(p_result), p_operator
    FROM public.hq_exception_cases WHERE id = v_case_id;
  RETURN v_case_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_hq_exception_reopen(
  p_case_id BIGINT,
  p_reason TEXT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_tenant UUID := public._current_tenant_id();
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager') THEN RAISE EXCEPTION '僅總部帳號可重新開啟異常'; END IF;
  IF auth.uid() IS NULL OR auth.uid() <> p_operator THEN RAISE EXCEPTION 'operator 必須是目前登入的總部帳號'; END IF;
  IF NULLIF(TRIM(p_reason), '') IS NULL THEN RAISE EXCEPTION '重新開啟必須填原因'; END IF;
  UPDATE public.hq_exception_cases
     SET status = 'open', result = NULL, resolved_by = NULL, resolved_at = NULL, updated_at = NOW()
   WHERE id = p_case_id AND tenant_id = v_tenant AND status = 'resolved';
  IF NOT FOUND THEN RAISE EXCEPTION '案件不存在、不屬於目前公司，或尚未結案'; END IF;
  INSERT INTO public.hq_exception_events (tenant_id, case_id, action, note, created_by)
  VALUES (v_tenant, p_case_id, 'reopened', TRIM(p_reason), p_operator);
END;
$$;

-- 收貨短少：帳務動作與案件結案同一交易；既有函式失敗即不會留下結案紀錄。
CREATE OR REPLACE FUNCTION public.rpc_resolve_transfer_shortage_with_history(
  p_transfer_item_id BIGINT,
  p_resolution TEXT,
  p_notes TEXT,
  p_result TEXT,
  p_operator UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case_id BIGINT;
BEGIN
  IF NULLIF(TRIM(p_result), '') IS NULL THEN RAISE EXCEPTION '結案必須填最後結果'; END IF;
  v_case_id := public._hq_exception_capture_case('tshort-' || p_transfer_item_id::TEXT, p_operator);
  IF EXISTS (SELECT 1 FROM public.hq_exception_cases WHERE id = v_case_id AND status = 'resolved') THEN
    RAISE EXCEPTION '此案件已結案，請先重新開啟追蹤';
  END IF;
  PERFORM public.rpc_resolve_transfer_item_shortage(p_transfer_item_id, p_resolution, p_notes, p_operator);
  UPDATE public.hq_exception_cases
     SET status = 'resolved', result = TRIM(p_result), resolved_by = p_operator, resolved_at = NOW(), updated_at = NOW()
   WHERE id = v_case_id;
  INSERT INTO public.hq_exception_events (tenant_id, case_id, action, note, result, created_by)
  SELECT tenant_id, id, 'resolved', NULLIF(TRIM(p_notes), ''), TRIM(p_result), p_operator
    FROM public.hq_exception_cases WHERE id = v_case_id;
  RETURN v_case_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_hq_exception_cases(
  p_status TEXT DEFAULT 'all'
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_tenant UUID := public._current_tenant_id();
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager') THEN RAISE EXCEPTION '僅總部帳號可查看異常歷程'; END IF;
  IF p_status NOT IN ('all','open','resolved') THEN RAISE EXCEPTION 'invalid status'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', c.id, 'row_key', c.row_key, 'type', c.type, 'source_ref', c.source_ref,
      'snapshot', c.snapshot, 'status', c.status, 'result', c.result,
      'opened_at', c.opened_at, 'resolved_at', c.resolved_at, 'updated_at', c.updated_at,
      'is_live', EXISTS (SELECT 1 FROM public.v_hq_exceptions live WHERE live.row_key = c.row_key),
      'events', COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at, e.id)
                              FROM public.hq_exception_events e WHERE e.case_id = c.id), '[]'::jsonb)
    ) ORDER BY c.updated_at DESC, c.id DESC)
    FROM public.hq_exception_cases c
    WHERE c.tenant_id = v_tenant AND (p_status = 'all' OR c.status = p_status)
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_hq_exception_add_note(TEXT, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_hq_exception_resolve(TEXT, TEXT, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_hq_exception_reopen(BIGINT, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_resolve_transfer_shortage_with_history(BIGINT, TEXT, TEXT, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_hq_exception_cases(TEXT) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_hq_exception_add_note(TEXT, TEXT, UUID) FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_hq_exception_resolve(TEXT, TEXT, TEXT, UUID) FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_hq_exception_reopen(BIGINT, TEXT, UUID) FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_resolve_transfer_shortage_with_history(BIGINT, TEXT, TEXT, TEXT, UUID) FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_hq_exception_cases(TEXT) FROM public, anon;
REVOKE EXECUTE ON FUNCTION public._hq_exception_capture_case(TEXT, UUID) FROM public, anon, authenticated;

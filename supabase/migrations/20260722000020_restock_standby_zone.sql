-- ============================================================
-- 補貨申請「候補區」：總倉收件匣可把 pending 申請轉入候補，
-- 待處理列表不再被「等貨源」的申請刷整排，也不會漏掉真的要補的。
--
-- 需求（總倉 2026/7/22 回報）：
--   1. 收件匣 restock 卡片加「轉候補」按鈕（可再轉回待處理）
--   2. stage tab 多一個「候補」分類，候補中的申請不算在「待處理」
--
-- 設計：不動 status state machine（pending 照舊），只加 standby_at 旗標。
--   候補中的申請 status 仍是 'pending'，所有既有 RPC
--   （派貨 / 下訂單 / 拒絕 / 刪除 / 斷貨 propagation / picking demand）
--   都不用改、照樣可以直接對候補中的申請操作。
--
-- 內容：
--   1. restock_requests + standby_at / standby_by 欄位
--   2. rpc_restock_set_standby(p_request_id, p_standby) — HQ 轉入 / 轉出候補
--   3. v_hq_inbox：restock 的 pending + standby_at → stage='standby'
--      （基底：20260612000050_v_hq_inbox_return_to_hq_pending.sql，
--        保留 return_to_hq+shipped 算 pending 的修正；其他 source 不動）
--   4. rpc_inbox_counts：stage grid 加 'standby'
--      （基底：20260608000010_hq_inbox_view_and_counts.sql）
--   rpc_hq_inbox_keys 不用改：p_stage 直接透傳 'standby' 即可。
--
-- Rollback:
--   DROP FUNCTION rpc_restock_set_standby(BIGINT, BOOLEAN);
--   ALTER TABLE restock_requests DROP COLUMN standby_at, DROP COLUMN standby_by;
--   v_hq_inbox 還原 20260612000050 版本；rpc_inbox_counts 還原 20260608000010 版本。
-- ============================================================

ALTER TABLE restock_requests
  ADD COLUMN IF NOT EXISTS standby_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS standby_by UUID;

COMMENT ON COLUMN restock_requests.standby_at IS
  '候補區旗標：非 NULL 且 status=pending = 候補中（等貨源，先不出現在待處理）。approve/reject 後不清、只看 pending 判斷。';

-- ----------------------------------------------------------------
-- rpc_restock_set_standby — HQ 把 pending 申請轉入 / 轉出候補
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_restock_set_standby(
  p_request_id BIGINT,
  p_standby    BOOLEAN DEFAULT TRUE
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
    RAISE EXCEPTION 'permission denied: role % cannot set restock standby', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'request % already processed (status=%)', p_request_id, v_req.status;
  END IF;

  UPDATE restock_requests
     SET standby_at = CASE WHEN p_standby THEN NOW() ELSE NULL END,
         standby_by = CASE WHEN p_standby THEN v_user ELSE NULL END,
         updated_by = v_user
   WHERE id = p_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_restock_set_standby(BIGINT, BOOLEAN)
  TO authenticated;

-- ----------------------------------------------------------------
-- v_hq_inbox — restock 加 'standby' stage（其他 source 照舊）
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_hq_inbox AS
SELECT
  'restock-' || id::text                                AS row_key,
  'restock'::text                                       AS source,
  CASE
    WHEN status = 'pending' AND standby_at IS NOT NULL                          THEN 'standby'
    WHEN status = 'pending'                                                     THEN 'pending'
    WHEN status IN ('approved_transfer','approved_pr','shipped')                THEN 'in_transit'
    WHEN status = 'received'                                                    THEN 'done'
    ELSE 'rejected'
  END                                                   AS stage,
  requested_at                                          AS ts,
  id                                                    AS source_id
FROM public.restock_requests

UNION ALL

SELECT
  'transfer-' || id::text,
  'transfer',
  CASE
    WHEN status IN ('draft','confirmed')                       THEN 'pending'
    WHEN status = 'shipped' AND transfer_type = 'return_to_hq' THEN 'pending'
    WHEN status = 'shipped'                                    THEN 'in_transit'
    WHEN status = 'received'                                   THEN 'done'
    ELSE 'rejected'
  END,
  created_at,
  id
FROM public.transfers

UNION ALL

SELECT
  'aid-' || co.id::text,
  'aid',
  CASE
    WHEN co.status IN ('pending','confirmed')                     THEN 'pending'
    WHEN co.status = 'shipping'                                   THEN 'in_transit'
    WHEN co.status IN ('ready','completed','partially_completed') THEN 'done'
    ELSE 'rejected'
  END,
  co.updated_at,
  co.id
FROM public.customer_orders co
WHERE EXISTS (
  SELECT 1 FROM public.customer_order_items coi
  WHERE coi.order_id = co.id AND coi.source = 'aid_transfer'
)

UNION ALL

SELECT DISTINCT
  'shortage-' || order_id::text,
  'shortage',
  CASE
    WHEN shortage_resolution IS NULL                              THEN 'pending'
    WHEN shortage_resolution IN ('notified','waiting_next_po')    THEN 'in_transit'
    WHEN shortage_resolution IN ('cancelled','reallocated')       THEN 'done'
    ELSE 'pending'
  END,
  order_updated_at,
  order_id
FROM public.v_order_shortage;

-- ----------------------------------------------------------------
-- rpc_inbox_counts — stage grid 加 'standby'（目前只有 restock 會有值）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_inbox_counts()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH src(source) AS (VALUES ('restock'),('transfer'),('aid'),('shortage')),
       stg(stage)  AS (VALUES ('pending'),('standby'),('in_transit'),('done'),('rejected')),
       grid AS (SELECT s.source, st.stage FROM src s CROSS JOIN stg st),
       counts AS (
         SELECT v.source, v.stage, COUNT(*)::int AS cnt
         FROM v_hq_inbox v
         GROUP BY v.source, v.stage
       )
  SELECT jsonb_object_agg(g.source, stages_obj)
  FROM (
    SELECT
      g.source,
      jsonb_object_agg(g.stage, COALESCE(c.cnt, 0)) AS stages_obj
    FROM grid g
    LEFT JOIN counts c ON c.source = g.source AND c.stage = g.stage
    GROUP BY g.source
  ) g;
$$;

COMMENT ON FUNCTION public.rpc_inbox_counts() IS
  'HQ 收件匣計數:一次回傳 4 來源 × 5 階段(含 standby 候補)的數字(JSONB)。';

-- ============================================================
-- 2026-08-08: 召回模組 — schema
--
-- 場景：總倉派貨派錯（品項 / 數量 / 店別 / 品質效期），但貨已出倉。
--   同一張撿貨單派出去的貨散在三種狀態：還在車上（transfer 未收）、
--   店裡沒動（已收、訂單未取）、客人已經領走（picked_up）。
--   要能從「總倉收件匣 → 撿貨單 → 已完成」那一列一鍵發起，
--   並且有畫面比對「要召回多少 vs 實際回來多少」。
--
-- 設計要點（PRD: docs/PRD-召回模組.md）
--
--   1. 不新增 customer_order_items.status='recalled'。
--      理由與斷貨（20260702020000）逐字相同：status 被十幾支 view / RPC 用
--      `NOT IN ('cancelled','expired')` 過濾，新增值會讓被召回的品項繼續算進
--      撿貨需求、繼續跟客人收錢。沿用 status='cancelled' + recalled_at 區分，
--      CLAUDE.md 記載的四個金額加總點（v_customer_order_summary /
--      rpc_wallet_pay_order / v_admin_orders_list / 前端）自動正確。
--
--   2. 回收進度一律「推導」不落地。
--      qty_returned / qty_intercepted / qty_in_return 全部由 view 即時算：
--        - 已回收 ← transfers(recall_id, status IN ('received','closed')).qty_received
--        - 在途   ← transfers(recall_id, status='shipped').qty_shipped
--        - 攔截   ← product_recall_events(event_type='intercepted').qty
--      這樣總倉照既有 /wms/inbound 走 rpc_receive_transfer 收貨即可，
--      **不需要**改那支已經被改過八次的函式（再塞副作用就是下一個事故源）。
--
--   3. 目標量的三桶快照（snap_in_transit / snap_unpicked / snap_picked_up）
--      在開單當下寫死。現場之後怎麼變都不影響「當初要召回多少」這個對帳基準。
--
-- Rollback:
--   DROP VIEW IF EXISTS v_recall_summary, v_recall_line_progress;
--   DROP TABLE IF EXISTS product_recall_events, product_recall_lines, product_recalls;
--   DROP SEQUENCE IF EXISTS recall_no_seq;
--   ALTER TABLE transfers             DROP COLUMN IF EXISTS recall_id;
--   ALTER TABLE customer_order_items  DROP COLUMN IF EXISTS recall_id, DROP COLUMN IF EXISTS recalled_at;
--   ALTER TABLE customer_orders       DROP COLUMN IF EXISTS recalled_at;
--
-- TEST: docs/TEST-warehouse-recall.md
-- ============================================================

-- ------------------------------------------------------------
-- 1. 召回單主檔
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS product_recalls (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  recall_no      TEXT NOT NULL,
  -- 從哪張撿貨單發起。NULL 保留給未來其他入口（例如直接從某張 transfer 發起）
  source_wave_id BIGINT REFERENCES picking_waves(id),
  reason_code    TEXT NOT NULL DEFAULT 'other'
                   CHECK (reason_code IN ('wrong_sku','wrong_qty','wrong_store',
                                          'quality','expiry','supplier_recall','other')),
  reason         TEXT,
  status         TEXT NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','issued','completed','cancelled')),
  issued_at      TIMESTAMPTZ,
  issued_by      UUID,
  completed_at   TIMESTAMPTZ,
  completed_by   UUID,
  cancelled_at   TIMESTAMPTZ,
  cancelled_by   UUID,
  notes          TEXT,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, recall_no)
);

COMMENT ON TABLE product_recalls IS
  '召回單主檔：總倉派貨錯誤後的回收追蹤單。draft 可改可刪、issued 之後目標量鎖定（要改就沖銷或另開一張）';
COMMENT ON COLUMN product_recalls.source_wave_id IS
  '發起來源撿貨單（/hq/inbox?source=picking 的「已完成」那一列）';

CREATE INDEX IF NOT EXISTS idx_recalls_tenant_status
  ON product_recalls (tenant_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_recalls_wave
  ON product_recalls (source_wave_id) WHERE source_wave_id IS NOT NULL;

-- 單號序號：與 _next_transfer_no 同型（TR / RC 各自一條 sequence）
CREATE SEQUENCE IF NOT EXISTS recall_no_seq;

CREATE OR REPLACE FUNCTION public._next_recall_no()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN 'RC' || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYMMDD')
              || lpad(nextval('recall_no_seq')::TEXT, 4, '0');
END;
$$;

-- ------------------------------------------------------------
-- 2. 召回明細（店 × 品項，一格一行）
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS product_recall_lines (
  id                 BIGSERIAL PRIMARY KEY,
  tenant_id          UUID NOT NULL,
  recall_id          BIGINT NOT NULL REFERENCES product_recalls(id) ON DELETE CASCADE,
  store_id           BIGINT NOT NULL REFERENCES stores(id),
  sku_id             BIGINT NOT NULL REFERENCES skus(id),
  -- 該格對應的開團（picking_wave_items.campaign_id）；彙整請購可能為 NULL
  campaign_id        BIGINT REFERENCES group_buy_campaigns(id),
  -- 該格對應的原派貨單（picking_wave_items.generated_transfer_id）
  source_transfer_id BIGINT REFERENCES transfers(id),

  qty_dispatched     NUMERIC(18,3) NOT NULL DEFAULT 0,
  qty_target         NUMERIC(18,3) NOT NULL CHECK (qty_target > 0),

  -- 開單當下的三桶快照（對帳基準，之後不再變動）
  snap_in_transit    NUMERIC(18,3) NOT NULL DEFAULT 0,  -- A：派貨單還是 shipped
  snap_unpicked      NUMERIC(18,3) NOT NULL DEFAULT 0,  -- B：已收、訂單未取
  snap_picked_up     NUMERIC(18,3) NOT NULL DEFAULT 0,  -- C：客人已領走

  -- 追不回、人工沖銷
  qty_written_off    NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty_written_off >= 0),
  written_off_reason TEXT,
  settled_at         TIMESTAMPTZ,
  settled_by         UUID,

  notes              TEXT,
  created_by         UUID,
  updated_by         UUID,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (recall_id, store_id, sku_id)
);

COMMENT ON TABLE product_recall_lines IS
  '召回明細：一格 = 一家店的一個品項。qty_target 是對帳左半邊，回收量全部由 v_recall_line_progress 推導';
COMMENT ON COLUMN product_recall_lines.snap_in_transit IS
  'A 桶快照：開單當下派貨單仍為 shipped（貨在車上）的量';
COMMENT ON COLUMN product_recall_lines.snap_unpicked IS
  'B 桶快照：開單當下已到店、顧客訂單品項尚未取貨的量';
COMMENT ON COLUMN product_recall_lines.snap_picked_up IS
  'C 桶快照：開單當下客人已領走的量（需聯繫客人拿回）';
COMMENT ON COLUMN product_recall_lines.qty_written_off IS
  '追不回而人工沖銷的量；差額 = 已回收 + 沖銷 − 目標，為 0 才可結案';

CREATE INDEX IF NOT EXISTS idx_recall_lines_recall
  ON product_recall_lines (recall_id);
CREATE INDEX IF NOT EXISTS idx_recall_lines_store
  ON product_recall_lines (tenant_id, store_id, recall_id);
CREATE INDEX IF NOT EXISTS idx_recall_lines_open
  ON product_recall_lines (recall_id) WHERE settled_at IS NULL;

-- ------------------------------------------------------------
-- 3. 事件流水（append-only）
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS product_recall_events (
  id         BIGSERIAL PRIMARY KEY,
  tenant_id  UUID NOT NULL,
  recall_id  BIGINT NOT NULL REFERENCES product_recalls(id) ON DELETE CASCADE,
  line_id    BIGINT REFERENCES product_recall_lines(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL CHECK (event_type IN (
               'created','issued','order_cancelled','order_split','intercepted',
               'store_shipped','customer_return','written_off',
               'completed','cancelled','note'
             )),
  qty        NUMERIC(18,3),
  ref_type   TEXT CHECK (ref_type IN ('transfer','customer_order','customer_order_item','wave')),
  ref_id     BIGINT,
  payload    JSONB,
  note       TEXT,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE product_recall_events IS
  '召回事件流水（append-only）：攔截 / 拆單 / 出貨 / 客退 / 沖銷都留一筆，出事可逐筆回溯';

CREATE INDEX IF NOT EXISTS idx_recall_events_recall
  ON product_recall_events (recall_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_recall_events_line
  ON product_recall_events (line_id) WHERE line_id IS NOT NULL;
-- 攔截量的推導來源，查詢頻繁
CREATE INDEX IF NOT EXISTS idx_recall_events_intercept
  ON product_recall_events (line_id, event_type) WHERE event_type = 'intercepted';

-- ------------------------------------------------------------
-- 4. 既有表加欄位
-- ------------------------------------------------------------

ALTER TABLE transfers
  ADD COLUMN IF NOT EXISTS recall_id BIGINT REFERENCES product_recalls(id);

COMMENT ON COLUMN transfers.recall_id IS
  '這張 transfer 是為哪張召回單而生：店端退回總倉（return_to_hq）或被攔截的派貨單。'
  '回收進度由此欄推導，總倉照既有流程 rpc_receive_transfer 收貨即可';

CREATE INDEX IF NOT EXISTS idx_transfers_recall
  ON transfers (recall_id) WHERE recall_id IS NOT NULL;

ALTER TABLE customer_order_items
  ADD COLUMN IF NOT EXISTS recall_id   BIGINT REFERENCES product_recalls(id),
  ADD COLUMN IF NOT EXISTS recalled_at TIMESTAMPTZ;

COMMENT ON COLUMN customer_order_items.recalled_at IS
  '召回取消標記；非 NULL 時 status=cancelled 是因總倉召回而非一般取消 / 斷貨（stockout_at）。'
  'UI 顯示優先序：召回 > 斷貨 > 一般取消';

CREATE INDEX IF NOT EXISTS idx_coi_recall
  ON customer_order_items (recall_id) WHERE recall_id IS NOT NULL;

ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS recalled_at TIMESTAMPTZ;

COMMENT ON COLUMN customer_orders.recalled_at IS
  '整筆訂單因召回而結束的時間；部分召回（還有其他品項）不會設';

-- ------------------------------------------------------------
-- 5. 進度推導 view
-- ------------------------------------------------------------

-- 每一格的回收進度。所有回收量都是推導值，沒有同步問題。
--   qty_intercepted     A 桶：攔截整張派貨單，貨帳直接退回總倉
--   qty_returned        B/C 桶：召回 transfer 已被總倉收貨（qty_received）
--   qty_in_return       B/C 桶：召回 transfer 已出貨、總倉還沒收（在途回程）
--   qty_order_cancelled 因本次召回被取消 / 拆單取消的訂單品項量
DROP VIEW IF EXISTS v_recall_line_progress;
CREATE VIEW v_recall_line_progress AS
SELECT
  l.id                                        AS line_id,
  l.tenant_id,
  l.recall_id,
  l.store_id,
  s.name                                      AS store_name,
  l.sku_id,
  sk.sku_code,
  -- skus 沒有 name 欄；沿用其他 view 的 product_name + variant_name 組法
  COALESCE(sk.product_name, '') ||
    CASE WHEN COALESCE(sk.variant_name, '') <> ''
         THEN ' ' || sk.variant_name ELSE '' END AS sku_name,
  l.campaign_id,
  l.source_transfer_id,
  l.qty_dispatched,
  l.qty_target,
  l.snap_in_transit,
  l.snap_unpicked,
  l.snap_picked_up,
  l.qty_written_off,
  l.written_off_reason,
  l.settled_at,
  l.notes,
  COALESCE(iv.qty, 0)                         AS qty_intercepted,
  COALESCE(rt.qty_received, 0)                AS qty_returned_by_transfer,
  COALESCE(rt.qty_in_transit, 0)              AS qty_in_return,
  COALESCE(oc.qty, 0)                         AS qty_order_cancelled,
  -- 已回收 = 攔截（貨從沒離開總倉帳） + 店端退回且總倉已收
  COALESCE(iv.qty, 0) + COALESCE(rt.qty_received, 0)                        AS qty_recovered,
  -- 差額：>= 0 表示回夠了（含沖銷）。結案閘門看這個。
  COALESCE(iv.qty, 0) + COALESCE(rt.qty_received, 0) + l.qty_written_off
    - l.qty_target                                                          AS qty_diff
FROM product_recall_lines l
JOIN stores s  ON s.id  = l.store_id
JOIN skus   sk ON sk.id = l.sku_id
LEFT JOIN LATERAL (
  SELECT COALESCE(SUM(e.qty), 0) AS qty
    FROM product_recall_events e
   WHERE e.line_id = l.id
     AND e.event_type = 'intercepted'
) iv ON TRUE
LEFT JOIN LATERAL (
  -- 該格的召回 transfer：掛同一張召回單、從該店 location 出、含該 SKU
  SELECT
    COALESCE(SUM(ti.qty_received) FILTER (WHERE t.status IN ('received','closed')), 0) AS qty_received,
    COALESCE(SUM(ti.qty_shipped)  FILTER (WHERE t.status = 'shipped'), 0)              AS qty_in_transit
    FROM transfers t
    JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = l.sku_id
   WHERE t.recall_id     = l.recall_id
     AND t.transfer_type = 'return_to_hq'
     AND t.status IN ('shipped','received','closed')
     AND t.source_location = s.location_id
) rt ON TRUE
LEFT JOIN LATERAL (
  SELECT COALESCE(SUM(coi.qty), 0) AS qty
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE coi.recall_id       = l.recall_id
     AND coi.sku_id          = l.sku_id
     AND co.pickup_store_id  = l.store_id
) oc ON TRUE;

COMMENT ON VIEW v_recall_line_progress IS
  '召回明細 + 推導回收進度。qty_diff = 攔截 + 已收回 + 沖銷 − 目標；0 才算回收完成';

-- 召回單層級彙總（列表頁 / KPI 用）
DROP VIEW IF EXISTS v_recall_summary;
CREATE VIEW v_recall_summary AS
SELECT
  r.id                                                     AS recall_id,
  r.tenant_id,
  r.recall_no,
  r.source_wave_id,
  w.wave_code,
  w.wave_date,
  r.reason_code,
  r.reason,
  r.status,
  r.issued_at,
  r.completed_at,
  r.cancelled_at,
  r.notes,
  r.created_at,
  r.created_by,
  COUNT(p.line_id)                                         AS line_count,
  COUNT(DISTINCT p.store_id)                               AS store_count,
  COUNT(DISTINCT p.sku_id)                                 AS sku_count,
  COALESCE(SUM(p.qty_target), 0)                           AS total_target,
  COALESCE(SUM(p.qty_intercepted), 0)                      AS total_intercepted,
  COALESCE(SUM(p.qty_returned_by_transfer), 0)             AS total_returned,
  COALESCE(SUM(p.qty_in_return), 0)                        AS total_in_return,
  COALESCE(SUM(p.qty_written_off), 0)                      AS total_written_off,
  COALESCE(SUM(p.qty_recovered), 0)                        AS total_recovered,
  COALESCE(SUM(p.qty_target), 0)
    - COALESCE(SUM(p.qty_recovered), 0)
    - COALESCE(SUM(p.qty_written_off), 0)                  AS total_outstanding,
  COALESCE(SUM(p.snap_picked_up), 0)                       AS total_customer_held,
  COUNT(*) FILTER (WHERE p.qty_diff < 0)                   AS open_line_count,
  COUNT(DISTINCT p.store_id) FILTER (WHERE p.qty_diff < 0) AS open_store_count
FROM product_recalls r
LEFT JOIN picking_waves w ON w.id = r.source_wave_id
LEFT JOIN v_recall_line_progress p ON p.recall_id = r.id
GROUP BY r.id, r.tenant_id, r.recall_no, r.source_wave_id, w.wave_code, w.wave_date,
         r.reason_code, r.reason, r.status, r.issued_at, r.completed_at,
         r.cancelled_at, r.notes, r.created_at, r.created_by;

COMMENT ON VIEW v_recall_summary IS
  '召回單彙總：列表頁與對帳頁 KPI。total_outstanding > 0 = 還沒回夠';

-- ------------------------------------------------------------
-- 6. RLS
-- ------------------------------------------------------------
-- 讀：總倉全看；店端只看有自己店的召回單（要在召回明細頁按「出貨退回總倉」）。
-- 寫：一律走 SECURITY DEFINER RPC，不開任何 INSERT/UPDATE/DELETE policy。
-- 角色一律讀 app_metadata（頂層 role 永遠是 'authenticated'，CLAUDE.md）。

ALTER TABLE product_recalls        ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_recall_lines   ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_recall_events  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS recalls_hq_read ON product_recalls;
CREATE POLICY recalls_hq_read ON product_recalls
  FOR SELECT TO authenticated USING (
    tenant_id = public._current_tenant_id()
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('owner','admin','hq_manager','hq_accountant','assistant','')
  );

DROP POLICY IF EXISTS recalls_store_read ON product_recalls;
CREATE POLICY recalls_store_read ON product_recalls
  FOR SELECT TO authenticated USING (
    tenant_id = public._current_tenant_id()
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('store_manager','store_staff','clerk')
    AND EXISTS (
      SELECT 1 FROM product_recall_lines l
       WHERE l.recall_id = product_recalls.id
         AND l.store_id = ANY (public._jwt_store_ids())
    )
  );

DROP POLICY IF EXISTS recall_lines_hq_read ON product_recall_lines;
CREATE POLICY recall_lines_hq_read ON product_recall_lines
  FOR SELECT TO authenticated USING (
    tenant_id = public._current_tenant_id()
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('owner','admin','hq_manager','hq_accountant','assistant','')
  );

DROP POLICY IF EXISTS recall_lines_store_read ON product_recall_lines;
CREATE POLICY recall_lines_store_read ON product_recall_lines
  FOR SELECT TO authenticated USING (
    tenant_id = public._current_tenant_id()
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('store_manager','store_staff','clerk')
    AND store_id = ANY (public._jwt_store_ids())
  );

DROP POLICY IF EXISTS recall_events_hq_read ON product_recall_events;
CREATE POLICY recall_events_hq_read ON product_recall_events
  FOR SELECT TO authenticated USING (
    tenant_id = public._current_tenant_id()
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('owner','admin','hq_manager','hq_accountant','assistant','')
  );

DROP POLICY IF EXISTS recall_events_store_read ON product_recall_events;
CREATE POLICY recall_events_store_read ON product_recall_events
  FOR SELECT TO authenticated USING (
    tenant_id = public._current_tenant_id()
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        IN ('store_manager','store_staff','clerk')
    AND EXISTS (
      SELECT 1 FROM product_recall_lines l
       WHERE l.id = product_recall_events.line_id
         AND l.store_id = ANY (public._jwt_store_ids())
    )
  );

-- view 走呼叫者權限（security_invoker）才會套上面的 RLS；
-- 沒設的話 view owner 是 postgres，店端會看到全部人的召回單。
ALTER VIEW v_recall_line_progress SET (security_invoker = on);
ALTER VIEW v_recall_summary       SET (security_invoker = on);

GRANT SELECT ON v_recall_line_progress TO authenticated;
GRANT SELECT ON v_recall_summary       TO authenticated;
GRANT SELECT ON product_recalls, product_recall_lines, product_recall_events TO authenticated;

-- updated_at trigger（沿用既有 touch_updated_at）
DROP TRIGGER IF EXISTS trg_touch_recalls ON product_recalls;
CREATE TRIGGER trg_touch_recalls BEFORE UPDATE ON product_recalls
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_recall_lines ON product_recall_lines;
CREATE TRIGGER trg_touch_recall_lines BEFORE UPDATE ON product_recall_lines
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

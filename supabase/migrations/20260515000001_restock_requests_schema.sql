-- ============================================================
-- Case 2 (restock request) schema：分店補貨申請表
--
-- 新表：
--   - restock_requests：單頭，分店建單、HQ 派貨/進貨/拒絕
--   - restock_request_lines：line（sku_id + qty + unit_price snapshot）
--
-- Status 流轉：
--   pending → approved_transfer (HQ 派庫存) → shipped → received
--   pending → approved_pr (HQ 改採購) → shipped (PR收貨後派) → received
--   pending → rejected
--   pending → cancelled (建單者取消)
--
-- TEST: docs/TEST-store-self-service.md §1.3, §1.4, §1.5
-- Rollback:
--   DROP TABLE restock_request_lines;
--   DROP TABLE restock_requests;
-- ============================================================

CREATE TABLE restock_requests (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL,
  requesting_store_id  BIGINT NOT NULL REFERENCES stores(id),

  status               TEXT NOT NULL DEFAULT 'pending'
                         CHECK (status IN (
                           'pending',
                           'approved_transfer',
                           'approved_pr',
                           'shipped',
                           'received',
                           'rejected',
                           'cancelled'
                         )),

  notes                TEXT,

  -- 流程時間戳
  requested_by         UUID,
  requested_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  approved_by          UUID,
  approved_at          TIMESTAMPTZ,
  rejected_by          UUID,
  rejected_at          TIMESTAMPTZ,
  rejected_reason      TEXT,

  -- 連結（被 approve 後填）
  linked_transfer_id   BIGINT REFERENCES transfers(id),
  linked_pr_id         BIGINT REFERENCES purchase_requests(id),

  -- 稽核四欄位
  created_by           UUID,
  updated_by           UUID,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- approved_transfer 必有 linked_transfer_id；approved_pr 必有 linked_pr_id；rejected 必有 reason
  CHECK (
    (status <> 'approved_transfer' OR linked_transfer_id IS NOT NULL)
    AND
    (status <> 'approved_pr'        OR linked_pr_id       IS NOT NULL)
    AND
    (status <> 'rejected'           OR rejected_reason    IS NOT NULL)
  )
);

COMMENT ON TABLE restock_requests IS
  '分店補貨申請：分店建 → HQ 派貨 (走 transfer) 或進貨 (掛 PR)；走完進月結';

CREATE INDEX idx_restock_status
  ON restock_requests (tenant_id, requesting_store_id, status);
CREATE INDEX idx_restock_pending
  ON restock_requests (tenant_id) WHERE status = 'pending';
CREATE INDEX idx_restock_linked_transfer
  ON restock_requests (linked_transfer_id) WHERE linked_transfer_id IS NOT NULL;
CREATE INDEX idx_restock_linked_pr
  ON restock_requests (linked_pr_id) WHERE linked_pr_id IS NOT NULL;

CREATE TRIGGER trg_touch_restock_requests
  BEFORE UPDATE ON restock_requests
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ----------------------------------------------------------------
-- restock_request_lines
-- ----------------------------------------------------------------
CREATE TABLE restock_request_lines (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  request_id   BIGINT NOT NULL REFERENCES restock_requests(id) ON DELETE CASCADE,
  sku_id       BIGINT NOT NULL REFERENCES skus(id),
  qty          NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  unit_price   NUMERIC(18,4) NOT NULL CHECK (unit_price >= 0),
  notes        TEXT,
  created_by   UUID,
  updated_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (request_id, sku_id)
);

COMMENT ON TABLE restock_request_lines IS
  'restock_request lines：sku_id + qty；unit_price 是建單時的 branch 價 snapshot';

CREATE INDEX idx_restock_lines_sku ON restock_request_lines (tenant_id, sku_id);

CREATE TRIGGER trg_touch_restock_request_lines
  BEFORE UPDATE ON restock_request_lines
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ----------------------------------------------------------------
-- RLS：分店看自己 store；HQ role 看全部；空 role 視為 admin（dev/legacy）
-- ----------------------------------------------------------------
ALTER TABLE restock_requests       ENABLE ROW LEVEL SECURITY;
ALTER TABLE restock_request_lines  ENABLE ROW LEVEL SECURITY;

CREATE POLICY restock_select ON restock_requests
  FOR SELECT
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      -- HQ role 全看
      COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','assistant',''])
      OR
      -- 分店 role 只看自家店
      (
        COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
          = ANY (ARRAY['store_manager','store_staff'])
        AND requesting_store_id::TEXT = (auth.jwt() ->> 'store_id')
      )
    )
  );

CREATE POLICY restock_lines_select ON restock_request_lines
  FOR SELECT
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND request_id IN (SELECT id FROM restock_requests)
  );

-- 寫入只走 RPC（SECURITY DEFINER），不開放直接 INSERT/UPDATE

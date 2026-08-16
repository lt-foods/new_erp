-- ============================================================================
-- 撿貨草稿（picking drafts）— 切片 A：骨架
--
-- 這一頁在解什麼（老闆 2026-08-16）：
--   「樓下今天要撿 50 樣商品，如果包子媽突然要插商品進來、或是車子載不下不送了，
--     我就可以先在草稿上修改。確定的出貨商品其實是要等樓下撿完後才能知道。
--     等確定了，再轉到派貨工作台。」
--   → 草稿 = 撿貨清單（可改）；派貨工作台 = 出貨清單（建了就成立）。
--
-- ⛔⛔ 本檔的硬規定（老闆強調過兩次：「完全不會扣庫存，這很重要」）：
--   1. 全檔只有 CREATE TABLE / CREATE INDEX / CREATE POLICY / CREATE TRIGGER /
--      COMMENT，物件全是本檔新建的。
--      **沒有任何 ALTER 既有表、沒有任何 CREATE OR REPLACE 既有 view / function。**
--      （唯二的 ALTER 是對本檔剛建好的兩張新表 ENABLE ROW LEVEL SECURITY —
--        Postgres 開 RLS 只有這個語法，不是在動既有物件。）
--   2. 沒有新增任何 FUNCTION。草稿的寫入走 PostgREST 直寫這兩張表 + RLS，
--      不走 SECURITY DEFINER —— SECURITY DEFINER 會繞過 RLS，反而讓「這頁碰不到
--      別的表」變成要靠讀 code 才能相信。RLS policy 只能授權它自己那張表，
--      所以「草稿頁在 DB 層碰不到任何既有資料」是結構保證，不是靠自律。
--   3. 因此本檔也沒有引用任何庫存 / 建單 RPC
--      （rpc_inbound / rpc_outbound / rpc_create_wave_from_po /
--        generate_transfer_from_wave / rpc_create_wave_from_restock 一支都沒有）。
--
-- 沿用的既有慣例（皆已 grep 驗證）：
--   - status 用全站慣例 'draft'（20260422120001 / ...3 / ...4 / ...5 /
--     20260423120000 / 20260423120002 都是 `DEFAULT 'draft' CHECK (status IN (...))`）
--   - 稽核四欄位 created_by / updated_by / created_at / updated_at（new_erp 慣例）
--   - touch_updated_at() trigger（20260422120001:272 建的既有函式，只是掛上來、沒有動它）
--   - 明細鍵 UNIQUE (draft_id, sku_id, store_id) 對齊 picking_wave_items 的
--     UNIQUE (wave_id, sku_id, store_id)（20260423120002:61）
--   - RLS 抄 community_product_candidates 的 ccp_hq_all（20260513000006:134）：
--     單一 FOR ALL policy、USING 與 WITH CHECK 同條件、tenant 從 auth.jwt() 頂層讀、
--     role 從 app_metadata 讀（頂層 'role' 是 Postgres 角色、永遠是 authenticated，
--     這個坑 repo 踩過兩次：20260502010000、20260807000040）
--
-- ⭐ sku_id / store_id **刻意不建外鍵**（CEO 2026-08-17 裁示）：
--   picking_wave_items 對 skus/stores 是有外鍵的（20260423120002:50-51），本檔刻意不比照。
--   三個理由：
--   1. 外鍵會是這個 PR 唯一的既有耦合點 —— Postgres 會在 skus/stores 上掛參照完整性檢查，
--      「被草稿引用中的商品硬刪除會被擋」。拿掉之後「完全不影響既有」是**結構上的事實**，
--      不需要靠「只影響 rpc_delete_product、而它本來就有 foreign_key_violation 分支」
--      這種需要信任鏈的說明。與本檔不做 SECURITY DEFINER RPC 是同一個道理。
--   2. 草稿是暫時性資料（撿完就完成），不該擋住主資料的操作。
--   3. 快照已經接住了：snapshot_sku_code / snapshot_sku_label 存的是加入當下的樣子，
--      商品被刪掉照樣印得出來 —— 這正是「快照」該有的語意：**記當時的樣子，不跟現在的資料綁死**。
--   ⚠️ 代價是可能出現孤兒列（引用到已刪除的商品／分店）。這一點**由前端負責顯示**：
--      查不到就印快照名稱並標「已不存在 / 已停用」，⛔ 絕不靜默跳過那一列
--      （靜默丟棄正是 PR #744 的根因）。見 apps/admin/src/lib/pickingDraftView.ts。
--   ⓘ draft_id 的外鍵**保留**（ON DELETE CASCADE）—— 那是本檔自己的表，刪草稿要連帶清明細。
--
-- Rollback：
--   DROP TABLE IF EXISTS picking_draft_items;
--   DROP TABLE IF EXISTS picking_drafts;
--   （兩張都是本檔新建、沒有任何既有物件依賴它們，drop 掉不影響現行系統。）
-- ============================================================================

-- ============================================================
-- 1. 草稿單頭
-- ============================================================

CREATE TABLE picking_drafts (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL,
  name        TEXT NOT NULL,
  -- 老闆拍板只有兩種狀態，且「已完成」是**手動按**的
  -- （一張草稿可能分兩天用完，系統不自作主張關掉）
  status      TEXT NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft','done')),
  created_by  UUID,
  updated_by  UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE picking_drafts IS
  '(2026-08-17) 撿貨草稿單頭：樓下撿貨前的「可改清單」。純快照、不回寫任何既有表、完全不扣庫存；確定後才到派貨工作台建正式撿貨單。';

COMMENT ON COLUMN picking_drafts.status IS
  'draft=進行中 / done=已完成（老闆手動按；一張草稿可分多次轉到派貨工作台，不會因為轉出就自動關閉）';

-- 列表頁預設「進行中在上、新的在前」
CREATE INDEX idx_picking_drafts_list
  ON picking_drafts (tenant_id, status, created_at DESC);

-- ============================================================
-- 2. 草稿明細（SKU × 分店 一格一列）
-- ============================================================

-- 為什麼一格一列（而不是「只存有數量的格子」）：
--   老闆要求草稿頁「要能列出所有分店，不只有需求的」（可能有庫存就多給沒下訂單的店），
--   而且樓下要能把某一格改成 0（車子載不下、這家不送了）卻**不是**把整樣商品刪掉。
--   所以 qty 允許 0（CHECK qty >= 0），加入商品時就替所有啟用分店各建一列。
--   ⚠ 與 picking_wave_items 的 `CHECK (qty > 0)` 不同是刻意的：那是正式撿貨單、
--     0 沒有意義；這是草稿、0 代表「這家這次不給」，是有意義的狀態。
CREATE TABLE picking_draft_items (
  id                     BIGSERIAL PRIMARY KEY,
  tenant_id              UUID NOT NULL,
  draft_id               BIGINT NOT NULL REFERENCES picking_drafts(id) ON DELETE CASCADE,
  -- ⚠ sku_id / store_id 刻意沒有外鍵，見檔頭「刻意不建外鍵」那一段。
  --   後果（孤兒列）由前端負責顯示，不靜默跳過。
  sku_id                 BIGINT NOT NULL,
  store_id               BIGINT NOT NULL,
  qty                    NUMERIC(18,3) NOT NULL DEFAULT 0 CHECK (qty >= 0),

  -- ---- 快照欄位（切片 A 只填身分那三個，數量快照是切片 B 的事）----
  -- 老闆原話：「這個草稿頁其實就是像**商品快照**，在草稿頁上的更動，不會立即更新
  --            原本派貨工作台的資料。」
  -- ⭐ 這些欄位切片 A 用不到也先建好：切片 B（對照現況）一定要有「加入當下的值」
  --    才算得出落差；等到那時候才 ALTER 一張已經有正式資料的表，才是真正的風險。
  snapshot_at            TIMESTAMPTZ,
  snapshot_sku_code      TEXT,
  snapshot_sku_label     TEXT,
  snapshot_close_date    DATE,
  snapshot_demand_qty    NUMERIC(18,3),
  snapshot_available_qty NUMERIC(18,3),
  snapshot_extra         JSONB NOT NULL DEFAULT '{}'::jsonb,

  note                   TEXT,
  created_by             UUID,
  updated_by             UUID,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- 對齊 picking_wave_items 的 UNIQUE (wave_id, sku_id, store_id)：
  -- 同一張草稿的同一格只會有一列，重複加入同一樣商品不會長出第二份矩陣
  UNIQUE (draft_id, sku_id, store_id)
);

COMMENT ON TABLE picking_draft_items IS
  '(2026-08-17) 撿貨草稿明細：一列 = 一格 (SKU × 分店)。qty 允許 0（= 這家這次不給，但商品還在清單上要印給樓下看）。';

COMMENT ON COLUMN picking_draft_items.snapshot_at IS
  '加入這一格時「拍照」的時間點；NULL = 尚未拍過快照（切片 A 建的列會有值，數量快照留給切片 B 補）';
COMMENT ON COLUMN picking_draft_items.snapshot_sku_code IS
  '加入當下的品號。存起來是因為草稿是快照：商品之後改名 / 下架，列印給樓下的紙本仍要是當初挑的那樣東西';
COMMENT ON COLUMN picking_draft_items.snapshot_sku_label IS
  '加入當下的品名（product_name + variant_name，與 v_picking_demand_by_po.sku_label 同構）';
COMMENT ON COLUMN picking_draft_items.snapshot_close_date IS
  '加入當下這樣商品的結單日（老闆指定列印要看到；來源 v_po_demand_by_store.close_date）。切片 A 不填，切片 B/C 補';
COMMENT ON COLUMN picking_draft_items.snapshot_demand_qty IS
  '加入當下這家店對這樣商品的需求量（需求 − 已派）。切片 B「對照現況」用來算落差；NULL = 還沒拍';
COMMENT ON COLUMN picking_draft_items.snapshot_available_qty IS
  '加入當下這樣商品的可分配量（= 進貨量 − 已派量，跨店共用、同 SKU 各列同值）。切片 B 用；NULL = 還沒拍';
COMMENT ON COLUMN picking_draft_items.snapshot_extra IS
  '快照的逃生口：切片 B/C/D 之後若還要記別的（例如來源 PO、團號），寫進這裡即可，不必再 ALTER 一張已有正式資料的表';

CREATE INDEX idx_picking_draft_items_draft
  ON picking_draft_items (draft_id);
CREATE INDEX idx_picking_draft_items_sku
  ON picking_draft_items (tenant_id, sku_id);

-- ============================================================
-- 3. updated_at 自動更新（掛既有的 touch_updated_at()，沒有改它）
-- ============================================================

CREATE TRIGGER trg_touch_picking_drafts
  BEFORE UPDATE ON picking_drafts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_touch_picking_draft_items
  BEFORE UPDATE ON picking_draft_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================================================
-- 4. RLS
--
-- 老闆 2026-08-17 確認：樓下撿貨的人**共用一個總部帳號**
-- → 不需要新增功能權限 key（不動 staffPerms.ts、不動 _is_valid_staff_perm 白名單）。
-- 給誰：對齊 apps/admin/src/lib/role.ts 的 HQ_ROLES + assistant
--       = 側欄看得到「派貨工作台」的那群人（分店帳號本來就看不到派貨工作台，
--         見 layout.tsx 的 BRANCH_HIDDEN_HREFS）。草稿是總倉的撿貨清單，
--         分店不需要也不應該看到。
-- '' = 沒有顯式 role 的 legacy/dev admin，對齊 role.ts 的 ADMIN_ROLES 註解與
--      20260807000040 的作法（少了它，舊 admin 帳號會被自己擋掉）。
-- ============================================================

ALTER TABLE picking_drafts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE picking_draft_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY pd_hq_all
  ON picking_drafts
  FOR ALL
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','assistant',''])
  )
  WITH CHECK (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','assistant',''])
  );

CREATE POLICY pdi_hq_all
  ON picking_draft_items
  FOR ALL
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','assistant',''])
  )
  WITH CHECK (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','assistant',''])
  );

-- ============================================================================
-- 門市記帳本（現金帳）1/2：schema + 權限 helper + 預設科目
-- ============================================================================
-- 需求（Alex 2026-09-22）：「幫我做一個記帳系統在日結那邊，盡量完整，
--   然後只有該店的店長可以看到」。
--
-- 定位：日結報表（rpc_daily_pickup_settlement）回答的是「今天交了多少貨、
--   收了多少錢」，但門市關帳時真正要對的是**抽屜裡的現金**：
--     開帳現金 ＋ 取貨收現 ＋ 其他現金收入 − 現金支出 = 應有現金
--     實點現金 − 應有現金 = 差異
--   支出（房租、水電、包材、進貨貨款…）與非取貨的收入系統裡完全沒有地方記，
--   店長只能記在紙上。這一組表就是那本帳。
--
-- ⛔ 為什麼不用 day-1 的 petty_cash_accounts / petty_cash_transactions /
--    expenses（20260423120005）：
--      * 線上 petty_cash_transactions / expenses **0 筆**、沒有任何前端呼叫，
--        petty_cash_accounts 只有 2026-05-10 種的 5 筆 demo（20 家活躍門市只涵蓋 5 家）。
--      * 它整組跟 vendor_bills / vendor_payments / expenses 互相 FK 綁死，
--        本次不做 AP，掛上去等於被迫維護三張空表的外鍵。
--      * 它的 RLS 寫的是 `auth.jwt() ->> 'role'`（頂層 role 永遠是 'authenticated'，
--        CLAUDE.md 記過兩次的坑）→ 不論如何都要整組重寫。
--      * account 上有 denormalized `balance` ＋ trigger，會跟流水帳漂移。
--    同 pos_sales 那次的判斷（20260901010000 檔頭）：day-1 骨架不是正主，
--    照著它做只會把新功能綁在沒人用過的結構上。**本檔不動那三張表**，
--    也不要在新路徑裡寫它們。
--
-- 三張表：
--   store_ledger_categories  科目（tenant 共用 store_id IS NULL ＋ 每店自訂）
--   store_ledger_entries     逐筆收支（append-only 語意：作廢留列、不刪）
--   store_daily_closings     每店每日關帳快照（應有/實點/差異）
--
-- 權限（「只有該店的店長可以看到」）：
--   * 分店角色 store_manager → **只有自己店**（app_metadata.stores 店名 →
--     _jwt_store_ids()）。store_staff 一律看不到（連 tab 都不出現）。
--   * 總部層級（owner/admin/hq_manager/hq_accountant/''，且 stores 為空或含「總倉」）
--     → 全部門市都看得到。老闆／會計要對帳、加盟店月結也要查得到這本帳。
--     （PRD-應付帳款零用金-v0.2 §1：加盟主互不看對方金流，總部看得到全部。）
--   * **綁在單一分店的 admin**（線上 2 個：全民 a0989560545@、中和店 meimeicyndi@）
--     不是總部 → 走店長那條，只看自己那家店。
--   * 其餘角色（assistant / piaopiao_publisher / disabled / 沒 role 又沒 stores 的
--     分店帳號）一律 false。
--   寫入與讀取同一組人（店長要能自己記帳、自己關帳；總部能協助訂正）。
--
-- ⚠ 線上 33 個分店帳號**沒有任何一個有 store_id**，店歸屬一律看
--   app_metadata.stores（店名陣列，20260808000020）。這裡沿用既有的
--   _jwt_store_ids()（20260707000070），不要自己另外抄一份判斷。
--
-- 基底版本：無（新表、新函式）。
-- Rollback：
--   DROP TABLE public.store_daily_closings;
--   DROP TABLE public.store_ledger_entries;
--   DROP TABLE public.store_ledger_categories;
--   DROP FUNCTION public._store_ledger_can_view(BIGINT);
--   DROP FUNCTION public._store_ledger_is_hq();
--   DROP FUNCTION public._store_ledger_is_manager();
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 權限 helper
--    三支都是 parameterless / 單參數的 STABLE SECURITY DEFINER，
--    RLS 用 (SELECT …) 包起來 → initplan，每列不重算（CLAUDE.md 的 RLS initplan 教訓）。
--    ⚠ 店號那一段要寫成 `(SELECT _jwt_store_ids()) @> ARRAY[store_id]`：
--      `store_id = ANY ((SELECT _jwt_store_ids()))` 會被當成 ANY(子查詢) 而不是 ANY(陣列)，
--      直接炸 `operator does not exist: bigint = bigint[]`（2026-09-22 套用時踩到）。
--      不包 (SELECT …) 的 `= ANY (_jwt_store_ids())` 也對，但那就每列重算一次。
-- ----------------------------------------------------------------------------

-- 總部層級：HQ role 且「沒綁店」或「綁的是總倉」
CREATE OR REPLACE FUNCTION public._store_ledger_is_hq()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
           = ANY (ARRAY['owner','admin','hq_manager','hq_accountant',''])
     AND (
       jsonb_typeof(COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb)) <> 'array'
       OR jsonb_array_length(COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb)) = 0
       OR (auth.jwt() -> 'app_metadata' -> 'stores') ? '總倉'
     );
$$;

-- 店長層級：可以看「自己店」那本帳的角色。
-- store_staff 刻意不在清單內 —— 需求就是「只有該店的店長」。
CREATE OR REPLACE FUNCTION public._store_ledger_is_manager()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
           = ANY (ARRAY['store_manager','owner','admin','hq_manager','hq_accountant','']);
$$;

CREATE OR REPLACE FUNCTION public._store_ledger_can_view(p_store_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public._store_ledger_is_hq()
      OR (
        p_store_id IS NOT NULL
        AND public._store_ledger_is_manager()
        AND p_store_id = ANY (public._jwt_store_ids())
      );
$$;

COMMENT ON FUNCTION public._store_ledger_is_hq() IS
  '門市記帳本：呼叫者是不是總部層級（HQ role 且沒綁店或綁總倉）→ 全門市可見。';
COMMENT ON FUNCTION public._store_ledger_is_manager() IS
  '門市記帳本：呼叫者的 role 是不是「店長層級」（store_manager ＋ HQ role）。store_staff 不在內。';
COMMENT ON FUNCTION public._store_ledger_can_view(BIGINT) IS
  '門市記帳本：呼叫者能不能看這家店的帳（總部全部；店長只有 app_metadata.stores 對應的自己店）。';

GRANT EXECUTE ON FUNCTION public._store_ledger_is_hq() TO authenticated;
GRANT EXECUTE ON FUNCTION public._store_ledger_is_manager() TO authenticated;
GRANT EXECUTE ON FUNCTION public._store_ledger_can_view(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. 科目 store_ledger_categories
--    store_id IS NULL = 全店共用（本檔種的系統科目）；有值 = 該店自己加的。
--    affects_profit = FALSE 的科目只動現金、不進損益（例：現金存入銀行、
--    總部撥入零用金）—— 沒有這一欄的話，把現金拿去存銀行會被算成當天「虧錢」。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.store_ledger_categories (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID    NOT NULL,
  store_id       BIGINT  REFERENCES public.stores(id),
  kind           TEXT    NOT NULL CHECK (kind IN ('income','expense')),
  name           TEXT    NOT NULL CHECK (btrim(name) <> ''),
  affects_profit BOOLEAN NOT NULL DEFAULT TRUE,
  is_system      BOOLEAN NOT NULL DEFAULT FALSE,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order     INT     NOT NULL DEFAULT 500,
  created_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by     UUID,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS store_ledger_categories_name_uniq
  ON public.store_ledger_categories (tenant_id, COALESCE(store_id, 0), kind, name);
CREATE INDEX IF NOT EXISTS idx_slc_scope
  ON public.store_ledger_categories (tenant_id, store_id, kind, sort_order);

COMMENT ON TABLE public.store_ledger_categories IS
  '門市記帳本科目。store_id IS NULL = 全店共用（系統預設）；有值 = 該店自訂。'
  'affects_profit=FALSE 只影響現金不進損益（存銀行／總部撥款）。';

-- ----------------------------------------------------------------------------
-- 3. 逐筆收支 store_ledger_entries
--    作廢＝寫 voided_at，不刪列（店長事後要看得到「那筆記錯的 3,000 去哪了」）。
--    payment_method='cash' 才進現金結算；其他（轉帳／刷卡）只進損益。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.store_ledger_entries (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID   NOT NULL,
  store_id       BIGINT NOT NULL REFERENCES public.stores(id),
  entry_date     DATE   NOT NULL,
  direction      TEXT   NOT NULL CHECK (direction IN ('income','expense')),
  category_id    BIGINT REFERENCES public.store_ledger_categories(id),
  amount         NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  payment_method TEXT   NOT NULL DEFAULT 'cash'
                   CHECK (payment_method IN ('cash','transfer','credit_card','line_pay','other')),
  counterparty   TEXT,
  note           TEXT,
  receipt_no     TEXT,
  photo_url      TEXT,
  created_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by     UUID,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  voided_at      TIMESTAMPTZ,
  voided_by      UUID,
  void_reason    TEXT
);

CREATE INDEX IF NOT EXISTS idx_sle_store_date
  ON public.store_ledger_entries (tenant_id, store_id, entry_date DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_sle_category
  ON public.store_ledger_entries (category_id) WHERE voided_at IS NULL;

COMMENT ON TABLE public.store_ledger_entries IS
  '門市記帳本逐筆收支（現金帳）。作廢寫 voided_at 不刪列；payment_method=cash 才進現金結算。';

-- ----------------------------------------------------------------------------
-- 4. 每日關帳 store_daily_closings
--    關帳當下把數字**存成快照**：日後取貨被撤銷／補記，已關的那天不會自己變。
--    要更新就得「重開 → 再關」，而那會留下 reopened_by / reopen_reason。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.store_daily_closings (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID   NOT NULL,
  store_id        BIGINT NOT NULL REFERENCES public.stores(id),
  closing_date    DATE   NOT NULL,
  status          TEXT   NOT NULL DEFAULT 'closed' CHECK (status IN ('closed','reopened')),
  opening_cash    NUMERIC(14,2) NOT NULL DEFAULT 0,
  sales_total     NUMERIC(14,2) NOT NULL DEFAULT 0,
  sales_cash      NUMERIC(14,2) NOT NULL DEFAULT 0,
  sales_noncash   NUMERIC(14,2) NOT NULL DEFAULT 0,
  income_cash     NUMERIC(14,2) NOT NULL DEFAULT 0,
  income_noncash  NUMERIC(14,2) NOT NULL DEFAULT 0,
  expense_cash    NUMERIC(14,2) NOT NULL DEFAULT 0,
  expense_noncash NUMERIC(14,2) NOT NULL DEFAULT 0,
  expected_cash   NUMERIC(14,2) NOT NULL DEFAULT 0,
  counted_cash    NUMERIC(14,2) NOT NULL DEFAULT 0,
  diff_cash       NUMERIC(14,2) NOT NULL DEFAULT 0,
  note            TEXT,
  closed_by       UUID,
  closed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reopened_by     UUID,
  reopened_at     TIMESTAMPTZ,
  reopen_reason   TEXT,
  CONSTRAINT store_daily_closings_uniq UNIQUE (tenant_id, store_id, closing_date)
);

CREATE INDEX IF NOT EXISTS idx_sdc_store_date
  ON public.store_daily_closings (tenant_id, store_id, closing_date DESC);

COMMENT ON TABLE public.store_daily_closings IS
  '門市每日關帳快照（開帳／取貨收現／收支／應有／實點／差異）。status=closed 時該日帳目鎖定。';

-- ----------------------------------------------------------------------------
-- 5. RLS：讀走 policy，寫一律走 SECURITY DEFINER RPC（不 GRANT INSERT/UPDATE）
-- ----------------------------------------------------------------------------
ALTER TABLE public.store_ledger_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_ledger_entries    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_daily_closings    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS slc_read ON public.store_ledger_categories;
CREATE POLICY slc_read ON public.store_ledger_categories FOR SELECT TO authenticated
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (
      (SELECT public._store_ledger_is_hq())
      OR (
        (SELECT public._store_ledger_is_manager())
        AND (store_id IS NULL OR (SELECT public._jwt_store_ids()) @> ARRAY[store_id])
      )
    )
  );

DROP POLICY IF EXISTS sle_read ON public.store_ledger_entries;
CREATE POLICY sle_read ON public.store_ledger_entries FOR SELECT TO authenticated
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (
      (SELECT public._store_ledger_is_hq())
      OR (
        (SELECT public._store_ledger_is_manager())
        AND (SELECT public._jwt_store_ids()) @> ARRAY[store_id]
      )
    )
  );

DROP POLICY IF EXISTS sdc_read ON public.store_daily_closings;
CREATE POLICY sdc_read ON public.store_daily_closings FOR SELECT TO authenticated
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (
      (SELECT public._store_ledger_is_hq())
      OR (
        (SELECT public._store_ledger_is_manager())
        AND (SELECT public._jwt_store_ids()) @> ARRAY[store_id]
      )
    )
  );

COMMENT ON POLICY slc_read ON public.store_ledger_categories IS
  '總部全看；店長看共用科目＋自己店的自訂科目；store_staff 看不到。';
COMMENT ON POLICY sle_read ON public.store_ledger_entries IS
  '總部全看；店長只看自己店；store_staff 看不到。';
COMMENT ON POLICY sdc_read ON public.store_daily_closings IS
  '總部全看；店長只看自己店；store_staff 看不到。';

GRANT SELECT ON public.store_ledger_categories TO authenticated;
GRANT SELECT ON public.store_ledger_entries    TO authenticated;
GRANT SELECT ON public.store_daily_closings    TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.store_ledger_categories_id_seq TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.store_ledger_entries_id_seq    TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.store_daily_closings_id_seq    TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. updated_at trigger（沿用既有的 touch_updated_at()）
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_touch_slc ON public.store_ledger_categories;
CREATE TRIGGER trg_touch_slc BEFORE UPDATE ON public.store_ledger_categories
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_sle ON public.store_ledger_entries;
CREATE TRIGGER trg_touch_sle BEFORE UPDATE ON public.store_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 7. 預設科目（每個 tenant 一套共用科目，store_id IS NULL）
--    是門市真的會記的那些帳，不是會計科目表 —— 店長看得懂才會用。
--    最後兩組 affects_profit=FALSE：只搬現金、不是賺賠。
-- ----------------------------------------------------------------------------
INSERT INTO public.store_ledger_categories (tenant_id, store_id, kind, name, affects_profit, is_system, sort_order)
SELECT t.id, NULL, c.kind, c.name, c.affects_profit, TRUE, c.sort_order
  FROM public.tenants t
 CROSS JOIN (VALUES
   ('expense','進貨貨款',      TRUE,  100),
   ('expense','房租',          TRUE,  110),
   ('expense','水電瓦斯',      TRUE,  120),
   ('expense','電話網路',      TRUE,  130),
   ('expense','薪資工資',      TRUE,  140),
   ('expense','員工伙食',      TRUE,  150),
   ('expense','包材耗材',      TRUE,  160),
   ('expense','清潔用品',      TRUE,  170),
   ('expense','文具用品',      TRUE,  180),
   ('expense','運費',          TRUE,  190),
   ('expense','設備維修',      TRUE,  200),
   ('expense','設備採購',      TRUE,  210),
   ('expense','行銷廣告',      TRUE,  220),
   ('expense','稅金規費',      TRUE,  230),
   ('expense','銀行手續費',    TRUE,  240),
   ('expense','退款給客人',    TRUE,  250),
   ('expense','現金短少',      TRUE,  260),
   ('expense','雜支',          TRUE,  300),
   ('expense','現金存入銀行',  FALSE, 900),
   ('expense','繳回總部現金',  FALSE, 910),
   ('income', '其他收入',      TRUE,  100),
   ('income', '代收款',        TRUE,  110),
   ('income', '資源回收',      TRUE,  120),
   ('income', '現金溢出',      TRUE,  130),
   ('income', '總部撥入零用金',FALSE, 900),
   ('income', '店主存入現金',  FALSE, 910)
 ) AS c(kind, name, affects_profit, sort_order)
 WHERE NOT EXISTS (
   SELECT 1 FROM public.store_ledger_categories x
    WHERE x.tenant_id = t.id AND x.store_id IS NULL AND x.kind = c.kind AND x.name = c.name
 );

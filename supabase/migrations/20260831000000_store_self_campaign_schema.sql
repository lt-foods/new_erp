-- ============================================================================
-- 店家自開團 (1/5)：schema 與可見性
-- ============================================================================
-- 需求（Alex 2026-08-31）：
--   各店家可以開自己的團 → 只有自己店的客人跟店長看得到 → 產生的訂單只由該店
--   負責 → 結單 → 收貨 → 配單 ready，**完全不經由總倉**：
--   不請購、不採購、不撿貨、不出倉，**也不開進貨單**（不產生任何單據），
--   月結算不記入。App 上跟快團／限量一樣出現在商品頁最上方。
--
-- 為什麼是新欄位而不是新的 close_type：
--   close_type 回答的是「收單怎麼結束」（regular / fast / limited / food_train），
--   sales_channel 回答的是「哪個店面」（main / piaopiao）。「這團的貨誰負責、
--   走不走總倉」是**第三個軸**（履約），跟前兩者正交 —— 店家自開團一樣可以是
--   限量團。硬塞進 close_type 會重演 20260820000100 檔頭記的那個教訓。
--   所以：owner_store_id IS NULL = 總倉團（今天的行為，一律不變）、
--         owner_store_id = N     = N 店自開團。
--
-- 「不開單」怎麼還能收貨：
--   收貨的對象**就是團本身**（結單後 status='receiving'，收貨頁直接列出該店
--   status='receiving' 的自開團與各 SKU 需求）。收貨只寫一筆庫存異動
--   （stock_movements，source_doc_type='campaign' / source_doc_id=團 id），
--   那是庫存帳不是單據 —— 貨要進 on_hand 本來就得有這一筆，跟「新增庫存」同一
--   種東西。所以全流程沒有任何 transfers / purchase_orders / picking_waves 列。
--
--   連帶好處：月結算（store_monthly_settlement_items）整張表以 transfer_id /
--   transfer_item_id 為鍵、母體全是 transfers，自開團一列都不會產生 →
--   **結構性地**不入月結，不需要在月結那邊加任何排除條件（加了反而會漏）。
--
-- Rollback：
--   DROP POLICY 後重跑 20260623000000 的 gbc_store_read 與
--   20260425120000 的 auth_read_group_buy_campaigns；
--   DROP FUNCTION public._is_branch_scoped_user();
--   ALTER TABLE group_buy_campaigns DROP COLUMN owner_store_id;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. group_buy_campaigns.owner_store_id — 這團是哪一家店自己開的
-- ----------------------------------------------------------------------------
ALTER TABLE public.group_buy_campaigns
  ADD COLUMN IF NOT EXISTS owner_store_id BIGINT REFERENCES public.stores(id);

COMMENT ON COLUMN public.group_buy_campaigns.owner_store_id IS
  '店家自開團的主辦店。NULL = 總倉團（既有行為：全店可見、走請購→採購→撿貨→出倉）。'
  '非 NULL = 該店自開團：只有該店的會員與員工看得到，結單後不進 PR、不開任何單據，'
  '直接在收貨頁對這個團收貨（只寫 stock_movements），因此也不進月結算。';

-- 部分索引：只有自開團才進索引，總倉團（絕大多數）不佔空間
CREATE INDEX IF NOT EXISTS idx_campaigns_owner_store
  ON public.group_buy_campaigns (tenant_id, owner_store_id, status)
  WHERE owner_store_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 2. 可見性 helper
--
--    「分店身分」的判準與 _assert_stocktake_store_scope（20260826010000）、
--    rpc_inbound_pending_count、前端 isBranchUser 完全同一套：
--    role ∈ (store_manager, store_staff) 且 app_metadata.stores 非空且不含「總倉」。
--    其餘（owner / admin / hq_manager / purchaser / assistant / '' legacy）都不鎖 ——
--    CLAUDE.md 記過：漏掉 '' 會把舊管理員帳號全擋在外面。
--
--    ⚠ 角色一律讀 app_metadata.role。頂層 auth.jwt()->>'role' 永遠是
--      'authenticated'（Postgres 角色）—— 現行 gbc_hq_all 就是踩了這個坑而
--      **從來沒有對任何人成立過**，所以本檔的 SELECT 政策必須自己把 HQ 放行。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._is_branch_scoped_user()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
           IN ('store_manager', 'store_staff')
     AND jsonb_typeof(COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb)) = 'array'
     AND jsonb_array_length(COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb)) > 0
     AND NOT (COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb) ? '總倉');
$$;

COMMENT ON FUNCTION public._is_branch_scoped_user() IS
  '當前使用者是不是「只看自己店」的分店帳號（store_manager/store_staff + stores 非空 + 不含總倉）。'
  '判準與 _assert_stocktake_store_scope / rpc_inbound_pending_count / 前端 isBranchUser 一致。';

REVOKE ALL ON FUNCTION public._is_branch_scoped_user() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._is_branch_scoped_user() TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. RLS：店家自開團只給主辦店的人看
--
--    兩支 SELECT 政策是 OR 的關係，所以**兩支都要加**同一個條件，
--    漏一支等於沒鎖。
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS auth_read_group_buy_campaigns ON public.group_buy_campaigns;
CREATE POLICY auth_read_group_buy_campaigns ON public.group_buy_campaigns
  FOR SELECT TO authenticated
  USING (
    tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
    AND (
      owner_store_id IS NULL
      OR NOT (SELECT public._is_branch_scoped_user())
      OR owner_store_id = ANY (public._jwt_store_ids())
    )
  );

DROP POLICY IF EXISTS gbc_store_read ON public.group_buy_campaigns;
CREATE POLICY gbc_store_read ON public.group_buy_campaigns
  FOR SELECT TO authenticated
  USING (
    tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
    AND status = ANY (ARRAY['open','closed','locked','ordered','receiving','ready','completed'])
    AND (
      owner_store_id IS NULL
      OR NOT (SELECT public._is_branch_scoped_user())
      OR owner_store_id = ANY (public._jwt_store_ids())
    )
  );

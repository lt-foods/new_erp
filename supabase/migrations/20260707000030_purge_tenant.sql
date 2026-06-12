-- ============================================================================
-- 2026-07-07: rpc_purge_tenant — 一鍵刪除整個試用租戶 — SaaS 化 Phase 3
-- ----------------------------------------------------------------------------
-- 硬性需求（docs/PLAN-試用租戶註冊.md §5）：試用租戶資料要能一鍵全刪。
--
-- 設計：
--   - 不手寫 ~100 張表的 DELETE：動態掃 pg catalog，刪掉 public schema 裡
--     「所有帶 tenant_id 欄位的表」中該租戶的列。未來新表只要照慣例帶
--     tenant_id 就自動納入，不會漏。
--   - session_replication_role='replica'（SET LOCAL，tx 結束自動還原）：
--     一次繞過 append-only trigger（forbid_append_only_mutation 等）與
--     FK trigger → 不用煩惱刪除順序；整包單一 transaction，要嘛全刪要嘛全留。
--     ⚠️ Supabase 的 postgres role 有權設此參數（部署前先在 trial project 實測；
--     若被拒，fallback 改為迴圈內 ALTER TABLE ... DISABLE TRIGGER USER）。
--   - 孤兒清理 pass：replica 模式下 ON DELETE CASCADE「不會」觸發，
--     少數沒有 tenant_id 的子表（如 sku_packs → skus）會留下孤兒列。
--     主迴圈後動態掃 pg_constraint：對「沒有 tenant_id 欄位、FK 指向
--     public 表」的表，刪掉 parent 已不存在的列；反覆 pass 直到收斂
--     （處理多層 chain）。正常情況下 FK 保證孤兒不存在，所以這步只會
--     刪到本次 purge 自己製造的孤兒，不會誤殺。
--   - 雙保險：tenants.is_protected = TRUE 一律拒絕；status 僅限 trial/suspended。
--   - auth.users 不在 public schema，函式只「回傳」該租戶的 user id 清單，
--     實際刪除由 edge function tenant-purge 走 Auth Admin API。
--   - Storage（products bucket 路徑 = {tenant_id}/...）也由 edge function
--     按 prefix 清，不在本函式。
--
-- 權限：只給 service_role。呼叫入口統一是 edge function tenant-purge
-- （驗 caller = 該租戶 owner 本人，或平台管理 secret）。
--
-- 基底：全新物件。tenants 表 = 20260707000000。
-- rollback：DROP FUNCTION public.rpc_purge_tenant(UUID, TEXT);
--           DROP TABLE public.tenant_purge_log;
--           （已 purge 的資料無法還原 — 這是功能本身的語意）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 刪除紀錄（平台層、append-only；欄位刻意叫 purged_tenant_id，
--    避免被下面「掃 tenant_id 欄位」的動態迴圈掃到而自刪）
-- ----------------------------------------------------------------------------

CREATE TABLE tenant_purge_log (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  purged_tenant_id UUID NOT NULL,
  tenant_name      TEXT NOT NULL,
  requested_by     TEXT NOT NULL,   -- 'self:<auth user id>' 或 'platform'
  table_counts     JSONB NOT NULL,  -- {table_name: deleted_rows}（僅列出 >0 的）
  auth_user_count  INT NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE tenant_purge_log ENABLE ROW LEVEL SECURITY;
-- 不開 policy：只有 service_role / definer 函式可讀寫

-- ----------------------------------------------------------------------------
-- 2. rpc_purge_tenant
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_purge_tenant(
  p_tenant_id    UUID,
  p_requested_by TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant   public.tenants%ROWTYPE;
  v_table    TEXT;
  v_count    BIGINT;
  v_counts   JSONB := '{}'::jsonb;
  v_user_ids UUID[];
  v_fk       RECORD;
  v_pass     INT;
  v_pass_del BIGINT;
  v_key      TEXT;
BEGIN
  SELECT * INTO v_tenant FROM public.tenants WHERE id = p_tenant_id;
  IF v_tenant.id IS NULL THEN
    RAISE EXCEPTION 'rpc_purge_tenant: tenant not found: %', p_tenant_id;
  END IF;
  IF v_tenant.is_protected THEN
    RAISE EXCEPTION 'rpc_purge_tenant: tenant is protected, refuse to purge';
  END IF;
  IF v_tenant.status NOT IN ('trial', 'suspended') THEN
    RAISE EXCEPTION 'rpc_purge_tenant: only trial/suspended tenants can be purged, got %', v_tenant.status;
  END IF;

  -- 該租戶的 auth users（回傳給 edge fn 走 Auth Admin API 刪）
  SELECT COALESCE(array_agg(u.id), '{}')
    INTO v_user_ids
    FROM auth.users u
   WHERE u.raw_app_meta_data ->> 'tenant_id' = p_tenant_id::text;

  -- 關 trigger（append-only / FK）— 僅本 transaction
  PERFORM set_config('session_replication_role', 'replica', true);

  -- 主迴圈：所有帶 tenant_id 欄位的一般表（排除 partition 子表，刪 parent 即涵蓋）
  FOR v_table IN
    SELECT c.relname
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_class c     ON c.oid = a.attrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND a.attname = 'tenant_id'
       AND NOT a.attisdropped
       AND c.relkind IN ('r', 'p')
       AND NOT c.relispartition
     ORDER BY c.relname
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE tenant_id = $1', v_table)
      USING p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    IF v_count > 0 THEN
      v_counts := v_counts || jsonb_build_object(v_table, v_count);
    END IF;
  END LOOP;

  -- 孤兒清理 pass：沒有 tenant_id 的表、FK 指向 public 表 → 刪 parent 已消失的列。
  -- 反覆到收斂（多層 chain）；超過 10 pass 視為 FK 環，直接 raise rollback。
  FOR v_pass IN 1..11 LOOP
    IF v_pass > 10 THEN
      RAISE EXCEPTION 'rpc_purge_tenant: orphan cleanup did not converge (FK cycle?)';
    END IF;
    v_pass_del := 0;

    FOR v_fk IN
      SELECT cc.relname AS child_tbl,
             pc.relname AS parent_tbl,
             (SELECT string_agg(format('t.%I = p.%I', ca.attname, pa.attname), ' AND ')
                FROM unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(cnum, pnum, ord)
                JOIN pg_catalog.pg_attribute ca ON ca.attrelid = con.conrelid AND ca.attnum = k.cnum
                JOIN pg_catalog.pg_attribute pa ON pa.attrelid = con.confrelid AND pa.attnum = k.pnum
             ) AS join_cond,
             (SELECT string_agg(format('t.%I IS NOT NULL', ca.attname), ' AND ')
                FROM unnest(con.conkey) AS k(cnum)
                JOIN pg_catalog.pg_attribute ca ON ca.attrelid = con.conrelid AND ca.attnum = k.cnum
             ) AS notnull_cond
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class cc      ON cc.oid = con.conrelid
        JOIN pg_catalog.pg_namespace cn  ON cn.oid = cc.relnamespace
        JOIN pg_catalog.pg_class pc      ON pc.oid = con.confrelid
        JOIN pg_catalog.pg_namespace pn  ON pn.oid = pc.relnamespace
       WHERE con.contype = 'f'
         AND cn.nspname = 'public'
         AND pn.nspname = 'public'
         AND NOT EXISTS (   -- child 自己有 tenant_id 的，主迴圈已處理
               SELECT 1 FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = con.conrelid
                  AND a.attname = 'tenant_id'
                  AND NOT a.attisdropped
             )
    LOOP
      EXECUTE format(
        'DELETE FROM public.%I t WHERE %s AND NOT EXISTS (SELECT 1 FROM public.%I p WHERE %s)',
        v_fk.child_tbl, v_fk.notnull_cond, v_fk.parent_tbl, v_fk.join_cond
      );
      GET DIAGNOSTICS v_count = ROW_COUNT;
      IF v_count > 0 THEN
        v_pass_del := v_pass_del + v_count;
        v_key := 'orphan:' || v_fk.child_tbl;
        v_counts := v_counts
          || jsonb_build_object(v_key, COALESCE((v_counts ->> v_key)::bigint, 0) + v_count);
      END IF;
    END LOOP;

    EXIT WHEN v_pass_del = 0;
  END LOOP;

  -- 墓碑（tenants 自己沒有 tenant_id 欄位，不會被主迴圈掃到）
  UPDATE public.tenants
     SET status = 'deleted', purged_at = now()
   WHERE id = p_tenant_id;

  INSERT INTO public.tenant_purge_log
    (purged_tenant_id, tenant_name, requested_by, table_counts, auth_user_count)
  VALUES
    (p_tenant_id, v_tenant.name, p_requested_by, v_counts, COALESCE(array_length(v_user_ids, 1), 0));

  RETURN jsonb_build_object(
    'tables', v_counts,
    'auth_user_ids', to_jsonb(COALESCE(v_user_ids, '{}'))
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_purge_tenant IS
  '一鍵刪除試用租戶全部資料（tenant-purge edge fn 專用）。protected / 非 trial·suspended 一律拒絕。';

REVOKE EXECUTE ON FUNCTION public.rpc_purge_tenant FROM authenticated, anon, public;
GRANT EXECUTE ON FUNCTION public.rpc_purge_tenant TO service_role;

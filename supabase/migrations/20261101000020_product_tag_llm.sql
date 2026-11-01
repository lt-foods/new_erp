-- ============================================================================
-- 20261101000020_product_tag_llm.sql
--
-- 新品自動貼標（docs/PLAN-選品系統-外部來源與向量媒合.md Phase A）。
--
-- 現況（2026-11-01 實查）：4,390 個商品只有 1,732 個有標籤；近 30 天新增 960 個、
-- 0 個有標籤 —— 規則標籤 rpc_apply_product_tag_rules 只在 8/9 跑過一次，沒有掛在
-- 任何流程上。沒標籤的 2,658 個裡規則能補 1,974 個，剩下 684 個（規則沒中：品名太
-- 短、外語、新品類）交給 LLM。
--
-- 本檔做三件事：
--   1. product_tag_map.source 加 'llm'（重跑規則不會動它，跟 manual 一樣保留；
--      人工改過就把 source 改成 manual）。
--   2. 規則套用抽成內部函式 _product_tag_apply_rules(tenant, only_missing)，
--      rpc_apply_product_tag_rules 改成呼叫它（行為不變、簽名不變）。
--      基底：20260809000020 建立的版本（後續沒被 CREATE OR REPLACE 過，已 grep 確認）。
--   3. 排程 _product_tag_tick()（每 30 分鐘）：先對沒標籤的商品跑規則，還是沒標籤的
--      才打 Edge Function product-tag（Claude），省 LLM 費用。
--      Edge Function 走 rpc_product_tag_llm_claim / rpc_product_tag_llm_write 兩支
--      service_role 專用 RPC 讀寫，模型只回標籤 code，DB 端驗 code 存在才寫。
--
-- products 新增兩欄：tag_llm_at（LLM 處理過的時間，NULL = 還沒）、tag_llm_error。
-- LLM 回「沒有適合的標籤」也算處理過（tag_llm_at 有值、沒有 map 列），避免每 30 分鐘
-- 重送同一批；一天後 tick 會重新撿（規則 / 標籤字彙有改時才有意義）。
--
-- 需要的 vault 秘密（不進 migration，套完後另外跑）：
--   SELECT vault.create_secret('https://<ref>.functions.supabase.co/product-tag', 'product_tag_worker_url');
--   SELECT vault.create_secret('<隨機字串>', 'product_tag_cron_secret');
--   -- 同一個隨機字串設成 Edge Function secret PRODUCT_TAG_CRON_SECRET；另外要 ANTHROPIC_API_KEY
-- 沒設好時 tick 只跑規則、不打 LLM，cron 不會炸。
--
-- rollback：
--   SELECT cron.unschedule('product-tag-tick');
--   DROP FUNCTION public._product_tag_tick();
--   DROP FUNCTION public.rpc_product_tag_llm_claim(INT);
--   DROP FUNCTION public.rpc_product_tag_llm_write(BIGINT, TEXT[], TEXT);
--   -- rpc_apply_product_tag_rules 指回 20260809000020 的版本；DROP _product_tag_apply_rules
--   ALTER TABLE products DROP COLUMN tag_llm_at, DROP COLUMN tag_llm_error;
--   DELETE FROM product_tag_map WHERE source = 'llm';  -- 再把 CHECK 改回 ('rule','manual')
-- ============================================================================

-- 1. source 加 'llm'
ALTER TABLE public.product_tag_map DROP CONSTRAINT IF EXISTS product_tag_map_source_check;
ALTER TABLE public.product_tag_map
  ADD CONSTRAINT product_tag_map_source_check CHECK (source IN ('rule', 'manual', 'llm'));
COMMENT ON COLUMN public.product_tag_map.source IS
  'rule = 規則標的（重跑會被重算）；manual = 人工指定；llm = 模型標的。manual / llm 重跑規則一律保留';

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS tag_llm_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS tag_llm_error TEXT;
COMMENT ON COLUMN public.products.tag_llm_at IS
  'LLM 自動貼標處理過的時間（含「沒有適合標籤」）。NULL = 還沒送過；一天後 tick 會重撿';

-- 2. 規則套用抽成內部函式
CREATE OR REPLACE FUNCTION public._product_tag_apply_rules(p_tenant UUID, p_only_missing BOOLEAN DEFAULT TRUE)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before   BIGINT;
  v_after    BIGINT;
  v_untagged BIGINT;
  v_targets  BIGINT;
BEGIN
  SELECT count(*) INTO v_before FROM product_tag_map WHERE tenant_id = p_tenant;

  CREATE TEMP TABLE _targets ON COMMIT DROP AS
    SELECT p.id, p.name
      FROM products p
     WHERE p.tenant_id = p_tenant
       AND (NOT p_only_missing OR NOT EXISTS (
             SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id));
  SELECT count(*) INTO v_targets FROM _targets;

  -- 重算範圍內的規則列先清掉（manual / llm 列不動）
  DELETE FROM product_tag_map m
   USING _targets t
   WHERE m.product_id = t.id AND m.source = 'rule' AND m.tenant_id = p_tenant;

  -- 1) 一般規則：命中就加，可累加
  INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
  SELECT DISTINCT p_tenant, t.id, tg.id, 'rule'
    FROM _targets t
    JOIN product_tag_rules r ON r.tenant_id = p_tenant AND r.is_active
                            AND r.exclusive_group IS NULL
                            AND t.name ~* r.pattern
    JOIN product_tags tg ON tg.tenant_id = p_tenant AND tg.code = r.tag_code
  ON CONFLICT (product_id, tag_id) DO NOTHING;

  -- 2) 互斥群組（溫層）：同群組只取 priority 最小的那條命中規則
  INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
  SELECT p_tenant, x.product_id, tg.id, 'rule'
    FROM (
      SELECT DISTINCT ON (t.id, r.exclusive_group)
             t.id AS product_id, r.tag_code
        FROM _targets t
        JOIN product_tag_rules r ON r.tenant_id = p_tenant AND r.is_active
                                AND r.exclusive_group IS NOT NULL
                                AND t.name ~* r.pattern
       ORDER BY t.id, r.exclusive_group, r.priority, r.id
    ) x
    JOIN product_tags tg ON tg.tenant_id = p_tenant AND tg.code = x.tag_code
  ON CONFLICT (product_id, tag_id) DO NOTHING;

  -- 3) 常溫＝「是食品，但沒被判成冷凍/冷藏」；非食品不給溫層
  INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
  SELECT p_tenant, t.id, (SELECT id FROM product_tags WHERE tenant_id = p_tenant AND code = 'ambient'), 'rule'
    FROM _targets t
   WHERE EXISTS (
           SELECT 1 FROM product_tag_map m JOIN product_tags g ON g.id = m.tag_id
            WHERE m.product_id = t.id AND g.tag_group IN ('生鮮','食品'))
     AND NOT EXISTS (
           SELECT 1 FROM product_tag_map m JOIN product_tags g ON g.id = m.tag_id
            WHERE m.product_id = t.id AND g.code IN ('frozen','chilled'))
  ON CONFLICT (product_id, tag_id) DO NOTHING;

  SELECT count(*) INTO v_after FROM product_tag_map WHERE tenant_id = p_tenant;
  SELECT count(*) INTO v_untagged
    FROM products p
   WHERE p.tenant_id = p_tenant
     AND NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id);

  DROP TABLE IF EXISTS _targets;

  RETURN jsonb_build_object(
    'scope',    CASE WHEN p_only_missing THEN 'only_missing' ELSE 'all' END,
    'targets',  v_targets,
    'rows_before', v_before,
    'rows_after',  v_after,
    'untagged_products', v_untagged
  );
END;
$$;
REVOKE ALL ON FUNCTION public._product_tag_apply_rules(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- 既有 RPC 改成委派（簽名、回傳、權限檢查都不變）
CREATE OR REPLACE FUNCTION public.rpc_apply_product_tag_rules(p_only_missing BOOLEAN DEFAULT TRUE)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner', 'admin', '') THEN
    RAISE EXCEPTION 'insufficient_role: 只有負責人 / 管理員可以重跑商品標籤';
  END IF;
  RETURN public._product_tag_apply_rules(v_tenant, p_only_missing);
END;
$$;

-- 3. LLM 讀寫 RPC（service_role 專用）
--    claim：撿「沒有任何標籤 且 (沒送過 LLM 或 送過超過一天)」的商品，標 tag_llm_at 當作已領走
--    （同一批不會被下一次 tick 重複送；LLM 失敗時 write 會把 tag_llm_at 清掉讓它重撿）。
CREATE OR REPLACE FUNCTION public.rpc_product_tag_llm_claim(p_limit INT DEFAULT 40)
RETURNS TABLE (id BIGINT, tenant_id UUID, name TEXT, short_name TEXT, description TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  WITH picked AS (
    SELECT p.id
      FROM products p
     WHERE p.status <> 'discontinued'
       AND NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id)
       AND (p.tag_llm_at IS NULL OR p.tag_llm_at < now() - INTERVAL '1 day')
     ORDER BY p.created_at DESC
     LIMIT GREATEST(COALESCE(p_limit, 40), 1)
     FOR UPDATE SKIP LOCKED
  ),
  marked AS (
    UPDATE products p SET tag_llm_at = now(), tag_llm_error = NULL
      FROM picked WHERE p.id = picked.id
    RETURNING p.id, p.tenant_id, p.name, p.short_name, p.description
  )
  SELECT m.id, m.tenant_id, m.name, m.short_name, LEFT(m.description, 300)
    FROM marked m;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_product_tag_llm_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_product_tag_llm_claim(INT) TO service_role;

--    write：p_tag_codes 只寫存在的 code；空陣列 = 模型說沒有適合的（tag_llm_at 維持、不寫列）；
--    p_error 有值 = 呼叫失敗，清 tag_llm_at 讓下一輪重撿。
--    溫層補常溫的規則跟規則標籤同一套（食品沒說冷凍/冷藏 → 常溫）。
CREATE OR REPLACE FUNCTION public.rpc_product_tag_llm_write(p_product_id BIGINT, p_tag_codes TEXT[], p_error TEXT DEFAULT NULL)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID;
  v_n      INT := 0;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT tenant_id INTO v_tenant FROM products WHERE id = p_product_id;
  IF v_tenant IS NULL THEN RETURN 0; END IF;

  IF p_error IS NOT NULL THEN
    UPDATE products SET tag_llm_at = NULL, tag_llm_error = LEFT(p_error, 500) WHERE id = p_product_id;
    RETURN 0;
  END IF;

  INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
  SELECT v_tenant, p_product_id, t.id, 'llm'
    FROM product_tags t
   WHERE t.tenant_id = v_tenant AND t.is_active
     AND t.code = ANY (COALESCE(p_tag_codes, ARRAY[]::TEXT[]))
  ON CONFLICT (product_id, tag_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- 常溫補位（同 _product_tag_apply_rules 第 3 步）
  INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
  SELECT v_tenant, p_product_id, t.id, 'llm'
    FROM product_tags t
   WHERE t.tenant_id = v_tenant AND t.code = 'ambient'
     AND EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags g ON g.id = m.tag_id
                  WHERE m.product_id = p_product_id AND g.tag_group IN ('生鮮','食品'))
     AND NOT EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags g ON g.id = m.tag_id
                      WHERE m.product_id = p_product_id AND g.code IN ('frozen','chilled'))
  ON CONFLICT (product_id, tag_id) DO NOTHING;

  UPDATE products SET tag_llm_error = NULL WHERE id = p_product_id;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_product_tag_llm_write(BIGINT, TEXT[], TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_product_tag_llm_write(BIGINT, TEXT[], TEXT) TO service_role;

-- 4. 排程 tick：規則先、LLM 後
CREATE OR REPLACE FUNCTION public._product_tag_tick()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID;
  v_url    TEXT;
  v_secret TEXT;
BEGIN
  FOR v_tenant IN
    SELECT DISTINCT p.tenant_id FROM products p
     WHERE NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id)
  LOOP
    PERFORM public._product_tag_apply_rules(v_tenant, TRUE);
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM products p
     WHERE p.status <> 'discontinued'
       AND NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id)
       AND (p.tag_llm_at IS NULL OR p.tag_llm_at < now() - INTERVAL '1 day')
  ) THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_url    FROM vault.decrypted_secrets WHERE name = 'product_tag_worker_url'  LIMIT 1;
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'product_tag_cron_secret' LIMIT 1;
  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE NOTICE 'product-tag-tick: vault 缺 product_tag_worker_url / product_tag_cron_secret，只跑規則';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-product-tag-secret', v_secret),
    body    := '{"action":"tick"}'::jsonb,
    timeout_milliseconds := 120000
  );
END;
$$;
REVOKE ALL ON FUNCTION public._product_tag_tick() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule('product-tag-tick')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'product-tag-tick');
SELECT cron.schedule('product-tag-tick', '*/30 * * * *', $cron$ SELECT public._product_tag_tick(); $cron$);

-- 5. 立刻補一輪規則（沒標籤的 2,658 個裡規則能補約 1,974 個）
SELECT public._product_tag_apply_rules(t.tenant_id, TRUE)
  FROM (SELECT DISTINCT tenant_id FROM public.products) t;
